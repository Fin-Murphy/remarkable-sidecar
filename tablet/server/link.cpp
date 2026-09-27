#include "link.h"

#include <QMetaObject>
#include <QtEndian>
#include <arpa/inet.h>
#include <cstring>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <unistd.h>
#include <zlib.h>

namespace {

bool readExact(int fd, void *buf, size_t n) {
    auto *p = static_cast<char *>(buf);
    while (n > 0) {
        ssize_t r = recv(fd, p, n, 0);
        if (r <= 0) return false;
        p += r;
        n -= size_t(r);
    }
    return true;
}

bool writeAll(int fd, const void *buf, size_t n) {
    auto *p = static_cast<const char *>(buf);
    while (n > 0) {
        ssize_t r = send(fd, p, n, MSG_NOSIGNAL);
        if (r <= 0) return false;
        p += r;
        n -= size_t(r);
    }
    return true;
}

void setOpt(int fd, int level, int name, int value) { setsockopt(fd, level, name, &value, sizeof value); }

}  // namespace

Link::Link(QObject *context, QByteArray address, quint16 port, int width, int height)
    : context_(context), address_(std::move(address)), port_(port), width_(width), height_(height) {}

Link::~Link() { stop(); }

bool Link::start() {
    listenFd_ = socket(AF_INET, SOCK_STREAM, 0);
    setOpt(listenFd_, SOL_SOCKET, SO_REUSEADDR, 1);
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port_);
    if (inet_pton(AF_INET, address_.constData(), &addr.sin_addr) != 1 ||
        bind(listenFd_, reinterpret_cast<sockaddr *>(&addr), sizeof addr) != 0 || listen(listenFd_, 1) != 0) {
        qWarning("link: cannot listen on %s:%u: %s", address_.constData(), port_, strerror(errno));
        close(listenFd_);
        listenFd_ = -1;
        return false;
    }
    qInfo("link: listening on %s:%u", address_.constData(), port_);
    thread_ = std::thread([this] { run(); });
    return true;
}

void Link::stop() {
    if (stopping_.exchange(true)) return;
    // Unblock accept()/recv() so the thread can finish.
    if (int fd = clientFd_.load(); fd >= 0) shutdown(fd, SHUT_RDWR);
    if (listenFd_ >= 0) shutdown(listenFd_, SHUT_RDWR);
    if (thread_.joinable()) thread_.join();
    if (listenFd_ >= 0) close(listenFd_);
}

void Link::sendInput(quint8 kind, int x, int y, int pressure) {
    uchar msg[8] = {0x90, kind};
    qToLittleEndian<quint16>(quint16(x), msg + 2);
    qToLittleEndian<quint16>(quint16(y), msg + 4);
    qToLittleEndian<quint16>(quint16(pressure), msg + 6);
    std::lock_guard<std::mutex> lock(sendMutex_);
    if (int fd = clientFd_.load(); fd >= 0) writeAll(fd, msg, sizeof msg);  // a failure shows up in recv()
}

void Link::post(std::function<void()> fn) {
    QMetaObject::invokeMethod(context_, std::move(fn), Qt::QueuedConnection);
}

void Link::run() {
    while (!stopping_) {
        int fd = accept(listenFd_, nullptr, nullptr);
        if (fd < 0) {
            if (stopping_) break;
            continue;
        }
        // Notice a vanished Mac (e.g. a pulled cable) within ~10 s, so we can accept the next one.
        setOpt(fd, IPPROTO_TCP, TCP_NODELAY, 1);
        setOpt(fd, SOL_SOCKET, SO_KEEPALIVE, 1);
        setOpt(fd, IPPROTO_TCP, TCP_KEEPIDLE, 4);
        setOpt(fd, IPPROTO_TCP, TCP_KEEPINTVL, 2);
        setOpt(fd, IPPROTO_TCP, TCP_KEEPCNT, 3);
        qInfo("link: Mac connected");
        post([this] { if (onConnected) onConnected(true); });
        serve(fd);
        {
            // Under the send lock, so sendInput() never writes to a closed (or reused) descriptor.
            std::lock_guard<std::mutex> lock(sendMutex_);
            clientFd_ = -1;
            close(fd);
        }
        qInfo("link: Mac disconnected");
        post([this] { if (onConnected) onConnected(false); });
    }
}

bool Link::serve(int fd) {
    // HELLO: 0x81, "RMSC", u16 version, u16 width, u16 height (little-endian).
    uchar hello[11] = {0x81, 'R', 'M', 'S', 'C'};
    qToLittleEndian<quint16>(1, hello + 5);
    qToLittleEndian<quint16>(width_, hello + 7);
    qToLittleEndian<quint16>(height_, hello + 9);
    {
        // Publish the descriptor only after HELLO, so INPUT never precedes it.
        std::lock_guard<std::mutex> lock(sendMutex_);
        if (!writeAll(fd, hello, sizeof hello)) return false;
        clientFd_ = fd;
    }

    QList<Rect> pending;
    for (;;) {
        quint8 type;
        if (!readExact(fd, &type, 1)) return false;
        switch (type) {
        case 0x01: {  // RECT
            uchar h[13];
            if (!readExact(fd, h, sizeof h)) return false;
            const int x = qFromLittleEndian<quint16>(h), y = qFromLittleEndian<quint16>(h + 2);
            const int w = qFromLittleEndian<quint16>(h + 4), hgt = qFromLittleEndian<quint16>(h + 6);
            const quint8 hint = h[8];
            const quint32 len = qFromLittleEndian<quint32>(h + 9);
            if (w <= 0 || hgt <= 0 || x + w > width_ || y + hgt > height_ || len > 16u << 20) {
                qWarning("link: bad RECT %d,%d %dx%d len %u", x, y, w, hgt, len);
                return false;
            }
            QByteArray compressed(int(len), Qt::Uninitialized);
            if (!readExact(fd, compressed.data(), len)) return false;
            Rect r{QRect(x, y, w, hgt), hint, QByteArray(w * hgt, Qt::Uninitialized)};
            uLongf outLen = uLongf(r.pixels.size());
            if (uncompress(reinterpret_cast<Bytef *>(r.pixels.data()), &outLen,
                           reinterpret_cast<const Bytef *>(compressed.constData()), len) != Z_OK ||
                outLen != uLongf(r.pixels.size())) {
                qWarning("link: RECT payload does not decompress to %dx%d bytes", w, hgt);
                return false;
            }
            pending.append(std::move(r));
            break;
        }
        case 0x02:  // FULL_REFRESH
            post([this] { if (onFullRefresh) onFullRefresh(); });
            break;
        case 0x03:  // FRAME_END
            if (!pending.isEmpty()) post([this, rects = std::move(pending)] { if (onFrame) onFrame(rects); });
            pending = {};
            break;
        default:
            qWarning("link: unknown message type 0x%02x", type);
            return false;
        }
    }
}

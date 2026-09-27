#include "pen.h"

#include <QDir>
#include <QFile>
#include <QtDebug>
#include <fcntl.h>
#include <linux/input.h>
#include <poll.h>
#include <unistd.h>

// Digitizer axes are rotated against the portrait display (same mapping as KOReader's rM2 port):
// display x follows ABS_Y, display y follows ABS_X reversed.
static const int kWidth = 1404, kHeight = 1872;

PenReader::~PenReader() { stop(); }

bool PenReader::start() {
    // Find the pen by name; event numbers can change between boots.
    for (const QString &dev : QDir("/sys/class/input").entryList({"event*"})) {
        QFile name("/sys/class/input/" + dev + "/device/name");
        if (name.open(QIODevice::ReadOnly) && name.readAll().trimmed() == "Wacom I2C Digitizer") {
            fd_ = open(("/dev/input/" + dev).toLatin1().constData(), O_RDONLY | O_CLOEXEC);
            break;
        }
    }
    if (fd_ < 0) {
        qWarning("pen: digitizer not found");
        return false;
    }
    if (ioctl(fd_, EVIOCGRAB, 1) != 0) qWarning("pen: could not grab the digitizer exclusively");
    thread_ = std::thread([this] { run(); });
    return true;
}

void PenReader::stop() {
    if (stopping_.exchange(true)) return;
    if (thread_.joinable()) thread_.join();
    if (fd_ >= 0) {
        ioctl(fd_, EVIOCGRAB, 0);
        close(fd_);
    }
}

void PenReader::run() {
    input_absinfo ax{}, ay{};
    ioctl(fd_, EVIOCGABS(ABS_X), &ax);
    ioctl(fd_, EVIOCGABS(ABS_Y), &ay);
    qInfo("pen: ABS_X %d..%d, ABS_Y %d..%d", ax.minimum, ax.maximum, ay.minimum, ay.maximum);
    if (ax.maximum <= ax.minimum || ay.maximum <= ay.minimum) return;

    int rawX = 0, rawY = 0, pressure = 0;
    bool touching = false, wasTouching = false, near = false;
    int lastX = -1, lastY = -1;
    input_event events[64];
    while (!stopping_) {
        pollfd p{fd_, POLLIN, 0};
        if (poll(&p, 1, 250) <= 0) continue;  // wake up regularly to notice stop()
        const ssize_t n = read(fd_, events, sizeof events);
        if (n <= 0) break;
        for (int i = 0; i < int(n / sizeof(input_event)); ++i) {
            const input_event &e = events[i];
            if (e.type == EV_ABS && e.code == ABS_X) rawX = e.value;
            else if (e.type == EV_ABS && e.code == ABS_Y) rawY = e.value;
            else if (e.type == EV_ABS && e.code == ABS_PRESSURE) pressure = e.value;
            else if (e.type == EV_KEY && e.code == BTN_TOUCH) touching = e.value;
            else if (e.type == EV_KEY && (e.code == BTN_TOOL_PEN || e.code == BTN_TOOL_RUBBER)) near = e.value;
            else if (e.type == EV_SYN && e.code == SYN_REPORT) {
                inRange = near || touching;
                const int x = qBound(0, int(qint64(rawY - ay.minimum) * kWidth / (ay.maximum - ay.minimum)), kWidth - 1);
                const int y = qBound(0, int(qint64(ax.maximum - rawX) * kHeight / (ax.maximum - ax.minimum)), kHeight - 1);
                const int pr = qBound(0, pressure, 4095);
                const bool moved = x != lastX || y != lastY;
                if (touching && !wasTouching) onEvent(1, x, y, pr);
                else if (!touching && wasTouching) onEvent(3, x, y, 0);
                else if (touching && moved) onEvent(2, x, y, pr);
                else if (near && moved) onEvent(0, x, y, 0);
                wasTouching = touching;
                lastX = x;
                lastY = y;
            }
        }
    }
    if (wasTouching) onEvent(3, lastX, lastY, 0);  // never leave the Mac with the button held
}

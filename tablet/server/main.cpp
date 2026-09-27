// rM2 Sidecar tablet server: shows the Mac's virtual display on the reMarkable 2.
// Implements PROTOCOL.md v1: RECTs are collected until FRAME_END, then applied as one update in
// the e-ink mode chosen by their waveform hint. FULL_REFRESH triggers a ghost-clearing flash.
//
// Input: the pen (read directly from evdev, see pen.cpp) is sent as hover/down/move/up; a finger
// tap is sent as touch_tap, a finger held still for 600 ms as touch_long_press (right click).
// The session ends (and run.sh brings xochitl back) when the power button is pressed, on SIGTERM
// (the Mac's Disconnect), or when no Mac has been connected for --grace seconds.
//
// Usage: rm2sidecar [--listen ADDRESS] [--port PORT] [--grace SECONDS] [--dump PNG] [--no-input]
//   --listen  address to listen on (default 127.0.0.1: the Mac reaches it through an SSH tunnel,
//             so the port is not exposed on USB or Wi-Fi)
//   --grace   quit after this long without a Mac (default 0 = never; 60 s allowed at startup)
//   --dump    save the framebuffer to PNG after every frame (for offline tests)

#include "link.h"
#include "pen.h"

#include <QCommandLineParser>
#include <QGuiApplication>
#include <QKeyEvent>
#include <QPainter>
#include <QQmlApplicationEngine>
#include <QQuickPaintedItem>
#include <QQuickWindow>
#include <QSocketNotifier>
#include <QTimer>
#include <csignal>
#include <unistd.h>

#ifdef RM2_EPAPER
#include "../epaper_private.h"
#include <QMetaEnum>

// The one place that maps the protocol's waveform hint to an EPScreenModeItem mode
// (Pen, Mono, Animation, UI, Content, Sleep). Chosen from the user's watched refresh test.
static const char *modeForHint(quint8 hint) {
    return hint == 0 ? "Animation"  // fast: content is changing quickly
                     : "Content";   // quality
}
#endif

static const int kWidth = 1404, kHeight = 1872;

// SIGTERM/SIGINT (e.g. run.sh's time limit) -> a clean app.quit(), so the epaper plugin can finish
// its panel updates before xochitl takes the screen back. Self-pipe: only write() in the handler.
static int signalPipe[2];

// The power button arrives as Qt::Key_PowerOff (xochitl, which normally handles it, is stopped).
struct PowerKeyQuits : QObject {
    using QObject::QObject;
    bool eventFilter(QObject *, QEvent *e) override {
        if (e->type() == QEvent::KeyPress && static_cast<QKeyEvent *>(e)->key() == Qt::Key_PowerOff) {
            qInfo("power key: quitting");
            QCoreApplication::quit();
            return true;
        }
        return false;
    }
};
static void onSignal(int) { char c = 1; (void)!write(signalPipe[1], &c, 1); }

// Shows the framebuffer and turns finger touches (delivered by Qt, already rotated to display
// pixels via QT_QPA_EVDEV_TOUCHSCREEN_PARAMETERS) into tap / long-press gestures.
class Canvas : public QQuickPaintedItem {
public:
    QImage image{kWidth, kHeight, QImage::Format_Grayscale8};
    std::function<void(quint8 kind, QPoint)> onGesture;  // 4 touch_tap, 5 touch_long_press
    std::function<bool()> ignoreTouch;                   // e.g. while the pen is in range

    explicit Canvas(QQuickItem *parent) : QQuickPaintedItem(parent) {
        image.fill(Qt::white);
        setAcceptedMouseButtons(Qt::LeftButton);
        longPress_.setSingleShot(true);
        longPress_.setInterval(600);
        QObject::connect(&longPress_, &QTimer::timeout, [this] {
            if (onGesture) onGesture(5, pressPos_);
            pressed_ = false;  // the release that follows is not a tap
        });
    }
    void paint(QPainter *p) override { p->drawImage(0, 0, image); }

protected:
    void mousePressEvent(QMouseEvent *e) override {
        pressed_ = !(ignoreTouch && ignoreTouch());
        pressPos_ = e->position().toPoint();
        if (pressed_) longPress_.start();
    }
    void mouseMoveEvent(QMouseEvent *e) override {
        if (pressed_ && (e->position().toPoint() - pressPos_).manhattanLength() > 30) {
            pressed_ = false;  // a swipe, not a tap or long press
            longPress_.stop();
        }
    }
    void mouseReleaseEvent(QMouseEvent *) override {
        longPress_.stop();
        if (pressed_ && onGesture) onGesture(4, pressPos_);
        pressed_ = false;
    }

private:
    QTimer longPress_;
    QPoint pressPos_;
    bool pressed_ = false;
};

// A strip of status text at the top; the Mac's next full frame paints over it.
static QRect drawBanner(QImage &image, const QString &text) {
    const QRect r(0, 0, image.width(), 70);
    QPainter p(&image);
    p.fillRect(r, Qt::white);
    p.setPen(Qt::black);
    QFont f = p.font(); f.setPixelSize(34); p.setFont(f);
    p.drawText(r.adjusted(24, 0, -24, 0), Qt::AlignVCenter, text);
    p.drawLine(r.bottomLeft(), r.bottomRight());
    return r;
}

int main(int argc, char *argv[]) {
    QGuiApplication app(argc, argv);
    QCommandLineParser cli;
    cli.addOptions({{"listen", "Address to listen on.", "address", "127.0.0.1"},
                    {"port", "TCP port.", "port", "9876"},
                    {"grace", "Quit after this many seconds without a Mac (0 = never).", "seconds", "0"},
                    {"dump", "Save the framebuffer to this PNG after every frame.", "png"},
                    {"no-input", "Don't send pen or touch input to the Mac."},
                    {"verbose", "Log every frame's size and transfer time."}});
    cli.process(app);

    app.installEventFilter(new PowerKeyQuits(&app));
    if (pipe(signalPipe) == 0) {
        auto *notifier = new QSocketNotifier(signalPipe[0], QSocketNotifier::Read, &app);
        QObject::connect(notifier, &QSocketNotifier::activated, &app, [] { qInfo("signal: quitting"); QCoreApplication::quit(); });
        std::signal(SIGTERM, onSignal);
        std::signal(SIGINT, onSignal);
    }

    // A visible QML Window sized to the screen, like reMarkable's hello_remarkable. (A C++
    // QQuickWindow + showFullScreen() never got its scene changes onto the panel.)
    QQmlApplicationEngine engine;
    engine.loadData("import QtQuick\nWindow { width: 1404; height: 1872; visible: true }");
    if (engine.rootObjects().isEmpty()) return 1;
    auto *window = qobject_cast<QQuickWindow *>(engine.rootObjects().first());

    auto *canvas = new Canvas(window->contentItem());
    canvas->setSize(QSizeF(kWidth, kHeight));
    const QString address = QString("%1:%2").arg(cli.value("listen"), cli.value("port"));
    canvas->update(drawBanner(canvas->image, "rM2 Sidecar: waiting for the Mac on " + address));

#ifdef RM2_EPAPER
    // One mode item over the whole screen; its mode applies to whatever is updated next.
    QQuickItem *modeItem = EPScreenModeItem::create(window->contentItem());
    modeItem->setSize(QSizeF(kWidth, kHeight));
    modeItem->setZ(1);
    const QMetaEnum modes = modeItem->metaObject()->enumerator(modeItem->metaObject()->indexOfEnumerator("Mode"));
    auto setModeForHint = [=](quint8 hint) {
        const int mode = modes.keyToValue(modeForHint(hint));
        if (modeItem->property("mode").toInt() != mode) modeItem->setProperty("mode", mode);
    };
    QObject *framebuffer = EPFramebuffer::instance();
#endif

    // Without a Mac for --grace seconds (a Mac crash, a pulled cable), end the session.
    QTimer noMac;
    noMac.setSingleShot(true);
    const int grace = cli.value("grace").toInt();
    QObject::connect(&noMac, &QTimer::timeout, [grace] {
        qInfo("no Mac for %d s: quitting", grace);
        QCoreApplication::quit();
    });
    if (grace > 0) noMac.start(qMax(grace, 60) * 1000);  // give the Mac time to connect at startup

    Link link(&app, cli.value("listen").toLatin1(), cli.value("port").toUShort(), kWidth, kHeight);
    link.verbose = cli.isSet("verbose");
    link.onConnected = [&](bool connected) {
        if (connected) {
            noMac.stop();
        } else {
            canvas->update(drawBanner(canvas->image, "rM2 Sidecar: Mac disconnected, waiting on " + address));
            if (grace > 0) noMac.start(grace * 1000);
        }
    };
    link.onFrame = [&](const QList<Rect> &rects) {
        bool fast = false;
        for (const Rect &r : rects) {
            for (int y = 0; y < r.rect.height(); ++y)
                memcpy(canvas->image.scanLine(r.rect.y() + y) + r.rect.x(),
                       r.pixels.constData() + y * r.rect.width(), size_t(r.rect.width()));
            fast |= r.hint == 0;
        }
#ifdef RM2_EPAPER
        setModeForHint(fast ? 0 : 1);
#else
        Q_UNUSED(fast);
#endif
        for (const Rect &r : rects) canvas->update(r.rect);  // one render pass for the frame
        if (cli.isSet("dump")) canvas->image.save(cli.value("dump"));
    };
    link.onFullRefresh = [&] {
#ifdef RM2_EPAPER
        QMetaObject::invokeMethod(framebuffer, "clearGhosting");
#endif
        qInfo("full refresh");
    };
    if (!link.start()) return 2;

    PenReader pen;
    if (!cli.isSet("no-input")) {
        pen.onEvent = [&](quint8 kind, int x, int y, int pressure) { link.sendInput(kind, x, y, pressure); };
        pen.start();
        canvas->ignoreTouch = [&] { return pen.inRange.load(); };  // palm rejection
        canvas->onGesture = [&](quint8 kind, QPoint p) {
            link.sendInput(kind, qBound(0, p.x(), kWidth - 1), qBound(0, p.y(), kHeight - 1), 0);
        };
    }

    const int result = app.exec();
    pen.stop();  // sends a final pen_up if needed, while the link is still up
    link.stop();
    return result;
}

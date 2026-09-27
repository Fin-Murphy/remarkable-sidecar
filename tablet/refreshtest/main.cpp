// Phase 2 refresh-speed test for the reMarkable 2 epaper Qt Quick backend.
//
// Shows a full-screen QImage (the way the Sidecar server will) and changes it on a schedule:
// full-screen changes, small patches, typing, and full-screen changes under each EPScreenMode.
// Only the changed rectangle is invalidated, so patches are real partial updates. Every step is
// labelled on screen ("STEP n: ...") for a person watching, and logged with timestamps next to
// the epaper plugin's own logs (QT_LOGGING_RULES="rm.*=true").
//
// Usage: refreshtest [--auto] [--tiny] [--no-modeitem]
//   --auto         start after 2 s instead of waiting for a tap (a tap wait gives up after 90 s)
//   --tiny         only the full-screen steps
//   --no-modeitem  don't create the EPScreenModeItem

#include "../epaper_private.h"

#include <QElapsedTimer>
#include <QGuiApplication>
#include <QMetaEnum>
#include <QMetaMethod>
#include <QPainter>
#include <QQmlApplicationEngine>
#include <QQuickPaintedItem>
#include <QQuickWindow>
#include <QScreen>
#include <QTimer>
#include <functional>

static QElapsedTimer clock_;
#define LOG(...) qInfo("[%7lld ms] %s", clock_.elapsed(), qPrintable(QString::asprintf(__VA_ARGS__)))

// Paints a QImage. (A QSGImageNode-based item crashed under the epaper backend.)
class Canvas : public QQuickPaintedItem {
public:
    QImage image;
    std::function<void()> onTap;
    explicit Canvas(QQuickItem *parent) : QQuickPaintedItem(parent) { setAcceptedMouseButtons(Qt::AllButtons); }
    void paint(QPainter *p) override { p->drawImage(0, 0, image); }
    void mousePressEvent(QMouseEvent *) override { if (onTap) onTap(); }
};

class UpdateWatcher : public QObject {
    Q_OBJECT
public:
    using QObject::QObject;
public slots:
    void onUpdated(const QRect &r) { LOG("fb updated %d,%d %dx%d", r.x(), r.y(), r.width(), r.height()); }
};

static void dumpMetaObject(const char *what, const QObject *o) {
    const QMetaObject *m = o->metaObject();
    LOG("=== %s: class %s", what, m->className());
    for (int i = m->methodOffset(); i < m->methodCount(); ++i)
        LOG("  method %s", m->method(i).methodSignature().constData());
    for (int i = m->propertyOffset(); i < m->propertyCount(); ++i) {
        QMetaProperty p = m->property(i);
        LOG("  property %s %s = %s", p.typeName(), p.name(), qPrintable(p.read(o).toString()));
    }
    for (int i = m->enumeratorOffset(); i < m->enumeratorCount(); ++i) {
        QMetaEnum e = m->enumerator(i);
        QStringList keys;
        for (int k = 0; k < e.keyCount(); ++k) keys << QString("%1=%2").arg(e.key(k)).arg(e.value(k));
        LOG("  enum %s { %s }", e.name(), qPrintable(keys.join(", ")));
    }
}

int main(int argc, char *argv[]) {
    clock_.start();
    QGuiApplication app(argc, argv);
    const QStringList args = app.arguments();
    const bool autoStart = args.contains("--auto");
    const bool tinyRun = args.contains("--tiny");

    // Create the window like reMarkable's hello_remarkable (a visible QML Window sized to the
    // screen). A C++ QQuickWindow + showFullScreen() never got its scene changes onto the panel.
    QQmlApplicationEngine engine;
    engine.loadData("import QtQuick\nWindow { width: Screen.width; height: Screen.height; visible: true }");
    if (engine.rootObjects().isEmpty()) return 1;
    QQuickWindow &window = *qobject_cast<QQuickWindow *>(engine.rootObjects().first());
    const QSize size = window.screen()->size();
    const QRect all(QPoint(0, 0), size);
    LOG("screen %dx%d", size.width(), size.height());

    auto *canvas = new Canvas(window.contentItem());
    canvas->setSize(size);
    canvas->image = QImage(size, QImage::Format_Grayscale8);
    canvas->image.fill(Qt::white);
    QImage &img = canvas->image;

    // Per-region update mode: one EPScreenModeItem over the whole screen.
    QQuickItem *modeItem = args.contains("--no-modeitem") ? nullptr : EPScreenModeItem::create(window.contentItem());
    QMetaEnum modeEnum;
    if (modeItem) {
        modeItem->setSize(size);
        modeItem->setZ(1);
        modeEnum = modeItem->metaObject()->enumerator(modeItem->metaObject()->indexOfEnumerator("Mode"));
        dumpMetaObject("EPScreenModeItem", modeItem);
    }

    QObject *fb = EPFramebuffer::instance();
    if (fb) {
        dumpMetaObject("EPFramebuffer", fb);
        QObject::connect(fb, SIGNAL(framebufferUpdated(QRect)), new UpdateWatcher(&app), SLOT(onUpdated(QRect)));
    }

    // ---- drawing helpers; each returns the rectangle it changed ----
    const int band = 90;  // step label strip at the top
    auto label = [&](const QString &text) {
        QPainter p(&img);
        p.fillRect(0, 0, size.width(), band, Qt::white);
        QFont f = p.font(); f.setPixelSize(44); f.setBold(true); p.setFont(f);
        p.setPen(Qt::black);
        p.drawText(QRect(20, 0, size.width() - 40, band), Qt::AlignVCenter, text);
        return QRect(0, 0, size.width(), band);
    };
    auto fullScreen = [&](int kind) {
        QPainter p(&img);
        const QRect body(0, band, size.width(), size.height() - band);
        switch (kind) {
        case 0: p.fillRect(body, Qt::white); break;
        case 1: p.fillRect(body, Qt::black); break;
        case 2:  // 16-step gray ramp
            for (int i = 0; i < 16; ++i)
                p.fillRect(QRect(i * size.width() / 16, band, size.width() / 16 + 1, body.height()), QColor(i * 17, i * 17, i * 17));
            break;
        case 3: {  // a page of text
            p.fillRect(body, Qt::white);
            QFont f = p.font(); f.setPixelSize(30); p.setFont(f); p.setPen(Qt::black);
            const QString line = "The quick brown fox jumps over the lazy dog. 0123456789 ";
            for (int y = band + 50; y < size.height() - 20; y += 42) p.drawText(40, y, line + line);
            break;
        }
        }
        return all;
    };
    auto setMode = [&](const char *key) {
        bool ok = false;
        const int v = modeEnum.isValid() ? modeEnum.keyToValue(key, &ok) : -1;
        LOG("set mode %s -> %d (%s)", key, v, ok && modeItem && modeItem->setProperty("mode", v) ? "ok" : "FAILED");
    };
    const char *kinds[] = {"white", "black", "gray ramp", "text page"};

    // ---- the script ----
    // Steps with the same name form one numbered group; the label strip only changes (and is
    // only redrawn) when a new group starts, so patch steps stay small partial updates.
    struct Step { int delayMs; QString name; std::function<QRect()> run; };
    QList<Step> steps;
    int groups = 0;
    auto add = [&](int delayMs, const QString &name, std::function<QRect()> fn) {
        if (steps.isEmpty() || !steps.last().name.endsWith(": " + name)) ++groups;
        steps.append({delayMs, QString("STEP %1: %2").arg(groups).arg(name), fn});
    };

    // A. Full screen, default mode (UI).
    for (int k : {1, 0, 2, 3, 0})
        add(3000, QString("full screen %1").arg(kinds[k]), [&, k] { return fullScreen(k); });
    if (!tinyRun) {
        // B. Patches, one per second, then fast ones every 250 ms.
        for (int i = 0; i < 6; ++i)
            add(1000, "200px squares, one per second", [&, i] {
                const QRect r(100 + i * 200, 300 + i * 200, 200, 200);
                QPainter(&img).fillRect(r, Qt::black);
                return r;
            });
        for (int i = 0; i < 12; ++i)
            add(250, "64px squares, one per 250 ms", [&, i] {
                const QRect r(100 + i * 96, 1550, 64, 64);
                QPainter(&img).fillRect(r, i % 2 ? Qt::darkGray : Qt::black);
                return r;
            });
        // Typing: one character every 150 ms.
        const QString typed = "Typing test: one character every 150 ms.";
        for (int i = 1; i <= typed.size(); ++i)
            add(i == 1 ? 1500 : 150, "typing, one character per 150 ms", [&, i, typed] {
                const QRect r(40, 1650, size.width() - 80, 60);
                QPainter p(&img);
                QFont f = p.font(); f.setPixelSize(36); p.setFont(f);
                p.fillRect(r, Qt::white); p.setPen(Qt::black);
                p.drawText(r, Qt::AlignVCenter, typed.left(i));
                return r;
            });
        // C. The same full-screen changes under each screen mode.
        for (const char *mode : {"Content", "UI", "Animation", "Mono", "Pen"}) {
            add(3000, QString("mode %1: white").arg(mode), [&, mode] { setMode(mode); return fullScreen(0); });
            for (int k : {1, 2, 3})
                add(3000, QString("mode %1: %2").arg(mode, kinds[k]), [&, k] { return fullScreen(k); });
        }
        add(3000, "mode UI: white", [&] { setMode("UI"); return fullScreen(0); });
        // D. Ghost clearing (a full-screen flash).
        add(3000, "text page (then clearGhosting)", [&] { return fullScreen(3); });
        add(3000, "clearGhosting()", [&] {
            LOG("clearGhosting invoked: %s", fb && QMetaObject::invokeMethod(fb, "clearGhosting") ? "ok" : "FAILED");
            return QRect();
        });
    }
    add(3000, "DONE - quitting in 5 s", [] { QTimer::singleShot(5000, qApp, &QCoreApplication::quit); return QRect(); });

    int current = -1;
    std::function<void()> next = [&] {
        if (++current >= steps.size()) return;
        const Step &s = steps[current];
        const QRect changed = s.run();
        if (current == 0 || steps[current - 1].name != s.name) canvas->update(label(s.name));
        LOG("%s  (dirty %d,%d %dx%d)", qPrintable(s.name), changed.x(), changed.y(), changed.width(), changed.height());
        canvas->update(changed);
        if (current + 1 < steps.size()) QTimer::singleShot(steps[current + 1].delayMs, next);
    };
    auto start = [&](const char *why) {
        if (current >= 0) return;
        canvas->onTap = nullptr;
        LOG("starting (%s)", why);
        QTimer::singleShot(1000, next);
    };

    label(autoStart ? "Refresh test starting..." : "Tap anywhere to start the refresh test");
    canvas->onTap = [&] { start("tap"); };
    QTimer::singleShot(autoStart ? 2000 : 90000, [&] { start(autoStart ? "auto" : "no tap within 90 s"); });
    return app.exec();
}

#include "main.moc"

// Minimal declarations for classes exported by /usr/lib/plugins/scenegraph/libqsgepaper.so
// (reMarkable's epaper Qt Quick backend). There are no public headers; these were read from the
// plugin's exported symbols. Only static functions and constructors are declared, everything
// else is reached through the Qt meta-object system (signals, slots, properties, enums).
#pragma once
#include <QQuickItem>
#include <new>

class EPFramebuffer : public QObject {
public:
    static EPFramebuffer *instance();  // the object is created by the epaper backend
};

// A QQuickItem whose "mode" property picks the e-ink update mode for the screen area it covers.
// Mode keys (from the plugin's meta-object): Pen, Mono, Animation, UI, Content, Sleep.
class EPScreenModeItem : public QQuickItem {
public:
    explicit EPScreenModeItem(QQuickItem *parent = nullptr);
    // The real class may be larger than this declaration, so construct it in an oversized buffer.
    static QQuickItem *create(QQuickItem *parent) {
        void *memory = ::operator new(4096);
        memset(memory, 0, 4096);
        return new (memory) EPScreenModeItem(parent);
    }
};

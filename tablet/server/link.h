// TCP server side of PROTOCOL.md v1 (one Mac at a time), running on its own thread.
#pragma once

#include <QByteArray>
#include <QList>
#include <QObject>
#include <QRect>
#include <atomic>
#include <functional>
#include <mutex>
#include <thread>

struct Rect {
    QRect rect;
    quint8 hint;       // 0 = fast, 1 = quality
    QByteArray pixels; // rect.width() * rect.height() bytes of 8-bit gray, row-major
};

class Link {
public:
    // Callbacks run on the thread of `context` (the GUI thread), in protocol order.
    std::function<void(QList<Rect>)> onFrame;  // all RECTs up to a FRAME_END
    std::function<void()> onFullRefresh;
    std::function<void(bool)> onConnected;

    bool verbose = false;  // log each frame's size and how long its bytes took to arrive

    Link(QObject *context, QByteArray address, quint16 port, int width, int height);
    ~Link();
    bool start();  // binds and starts the thread; false if the port can't be bound
    void stop();
    // Sends an INPUT message to the connected Mac, if any. Thread-safe.
    // kind: 0 hover_move, 1 pen_down, 2 pen_move, 3 pen_up, 4 touch_tap, 5 touch_long_press.
    void sendInput(quint8 kind, int x, int y, int pressure);

private:
    void run();
    bool serve(int fd);  // returns when the Mac disconnects or breaks the protocol
    void post(std::function<void()> fn);

    QObject *context_;
    QByteArray address_;
    quint16 port_;
    int width_, height_;
    int listenFd_ = -1;
    std::atomic<int> clientFd_{-1};
    std::mutex sendMutex_;  // the socket thread (HELLO) and input threads both write
    std::atomic<bool> stopping_{false};
    std::thread thread_;
};

// Reads the reMarkable 2 pen (the "Wacom I2C Digitizer" evdev device) on its own thread and
// turns it into protocol INPUT events in display pixels. The device is grabbed exclusively while
// this runs and released on stop/exit.
#pragma once

#include <QtGlobal>
#include <atomic>
#include <functional>
#include <thread>

class PenReader {
public:
    // Called on the reader thread. kind: 0 hover_move, 1 pen_down, 2 pen_move, 3 pen_up.
    std::function<void(quint8 kind, int x, int y, int pressure)> onEvent;
    std::atomic<bool> inRange{false};  // pen near the screen (used to ignore palm touches)

    ~PenReader();
    bool start();
    void stop();

private:
    void run();
    int fd_ = -1;
    std::atomic<bool> stopping_{false};
    std::thread thread_;
};

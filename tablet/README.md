# rM2 Sidecar: tablet side

A Qt Quick app for the reMarkable 2 (OS 3.28.0.172) that shows the Mac's virtual display and sends pen and touch input back to the Mac. It implements [`../PROTOCOL.md`](../PROTOCOL.md) v1.

It runs **with xochitl stopped**, and only through `run.sh`, which always brings xochitl back.

## Layout

| path | what |
|------|------|
| `server/` | The tablet server, `rm2sidecar`. |
| `refreshtest/` | Phase 2 refresh-speed test: full-screen changes, patches, typing, and each e-ink mode. |
| `epaper_private.h` | Declarations for `EPFramebuffer` and `EPScreenModeItem` from the device's `libqsgepaper.so`. There are no public headers. |
| `run.sh` | On-device wrapper that stops xochitl, runs apps, and restarts xochitl. |
| `build.sh`, `Dockerfile` | Cross-compile inside Docker with the official SDK. |
| `deploy.sh` | Copies files to `/home/root/rm2sidecar/`, the only place we write on the tablet. |
| `Dockerfile.hosttest`, `test_sender.py` | Offline protocol test on the Mac, with no tablet needed. `test_sender.py --calibrate` also checks pen and touch input against the real tablet. |

## Build

You need Docker. You also need the SDK installer `remarkable-production-image-5.8.203-rm2-public-aarch64-toolchain.sh` in `~/rm2-sdk/`. It's on reMarkable's developer links page; override the location with `RM2_SDK_DIR`.

```sh
./build.sh server         # -> server/build/rm2sidecar (32-bit ARM)
./build.sh refreshtest
```

## Offline test (no tablet)

```sh
docker build -t rm2-hosttest -f Dockerfile.hosttest .
docker run --rm -v "$PWD":/src -w /src/server rm2-hosttest sh -c 'cmake -S . -B build-host -DEPAPER=OFF && cmake --build build-host'
mkdir -p /tmp/rm2dump
docker run -d --name rm2srv -p 127.0.0.1:9876:9876 -v "$PWD":/src -v /tmp/rm2dump:/dump \
    -e QT_QPA_PLATFORM=offscreen rm2-hosttest /src/server/build-host/rm2sidecar --listen 0.0.0.0 --dump /dump/frame.png
python3 test_sender.py --png /tmp/rm2dump/frame.png   # pixel-exact check and protocol-error handling
# or point the Mac app at it: open ../mac/build/RM2Sidecar.app --args --host 127.0.0.1
docker rm -f rm2srv
```

## Deploy and run on the tablet

```sh
./deploy.sh server/build/rm2sidecar start.sh session.batch
```

Normally, the Mac app's **Connect** starts everything:

1. It runs `ssh root@<tablet> sh /home/root/rm2sidecar/start.sh`.
   - `start.sh` starts `run.sh -f session.batch`, or reuses a session that's already running.
   - It prints `READY` once the server listens, or `ERROR: <reason>` if one of run.sh's guards refuses.
2. It opens `ssh -N -L 127.0.0.1:19876:127.0.0.1:9876` and connects through that.

`session.batch` runs `rm2sidecar --listen 127.0.0.1 --grace 30` with an 8-hour absolute backstop. The server listens on loopback only, so it isn't reachable on USB or Wi-Fi without SSH.

A session ends, and xochitl comes back, when any of these happens:

- you press the **power button**;
- the Mac chooses **Disconnect** or quits (ssh kills the server, and run.sh restarts xochitl);
- no Mac has been connected for **30 s** (a Mac crash or a pulled cable);
- the 8 h backstop is reached.

Other server options:

- `--verbose` logs each frame's size and how long its bytes took to arrive.
- To run several apps with one xochitl stop and start, use `./run.sh -f FILE`, where each line of `FILE` is `SECONDS BINARY [ARGS]`.

## Input

- **Pen.** `server/pen.cpp` reads the "Wacom I2C Digitizer" device, which it finds by name because event numbers can change between boots. It holds an exclusive grab only while running.
  - Mapping, taken from KOReader: display x = `ABS_Y`, display y = `max − ABS_X`.
  - Events: hover → `hover_move`; contact → `pen_down`, `pen_move`, `pen_up`, with pressure 0–4095.
- **Touch.** Touch comes from Qt, already rotated by `QT_QPA_EVDEV_TOUCHSCREEN_PARAMETERS`.
  - A tap sends `touch_tap` (a click).
  - A finger held still for 600 ms sends `touch_long_press` (a right click).
  - Touches are ignored while the pen is in range, as palm rejection.
- **Calibration check** with the tablet server running. Homebrew Python can't reach 10.11.99.1 because of macOS Local Network privacy, so tunnel over SSH:
  ```sh
  ssh -f -N -L 127.0.0.1:9877:10.11.99.1:9876 root@10.11.99.1
  python3 test_sender.py --host 127.0.0.1 --port 9877 --calibrate
  ```
  Quit the Mac app first: the server accepts one Mac at a time.

## Safety rules that `run.sh` enforces

- It won't run if the battery is at 30% or less.
- It won't run unless `fw_printenv upgrade_available` is `0`. Right after a firmware update, xochitl's failure handler would switch root partitions.
- It won't run if xochitl has already been started **3 times in the last 10 minutes**. xochitl allows only 4 starts per 10 minutes, and a 5th start makes `remarkable-fail.sh` reboot the tablet.
  - Each restart is logged in `/home/root/rm2sidecar/.xochitl-starts`.
  - A start at boot counts too, if the tablet has been up for less than 10 minutes.
- Each app gets a time limit.
- A trap and an independent watchdog both restart xochitl, even if `run.sh` itself is killed.

## E-ink modes

The server maps each protocol waveform hint to an `EPScreenModeItem` mode in one place, `modeForHint()` in `server/main.cpp`:

- `0` (fast) → `Animation`
- `1` (quality) → `Content`

These were chosen from a watched test. The available modes are `Pen`, `Mono`, `Animation`, `UI` (the default), `Content` and `Sleep`.

`FULL_REFRESH` calls `EPFramebuffer::clearGhosting()`.

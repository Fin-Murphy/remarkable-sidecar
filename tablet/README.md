# rM2 Sidecar: tablet side

A Qt Quick app for the reMarkable 2 (OS 3.28.0.172) that shows the Mac's virtual display. It implements [`../PROTOCOL.md`](../PROTOCOL.md) v1.

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
| `Dockerfile.hosttest`, `test_sender.py` | Offline protocol test on the Mac, with no tablet needed. |

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
./deploy.sh server/build/rm2sidecar
ssh root@10.11.99.1 'cd /home/root/rm2sidecar && ./run.sh 600 ./rm2sidecar'
```

- The server listens on `10.11.99.1:9876`, the USB interface only, so it isn't reachable over Wi-Fi.
- Start the Mac app with no `--host` option.
- To quit, press the tablet's **power button**, or wait for the time limit. xochitl comes back either way.
- To run several apps with a single xochitl stop and start, use `./run.sh -f FILE`, where each line of `FILE` is `SECONDS BINARY [ARGS]`.

## Safety rules that `run.sh` enforces

- It won't run if the battery is at 30% or less.
- It won't run unless `fw_printenv upgrade_available` is `0`. Right after a firmware update, xochitl's failure handler would switch root partitions.
- It needs at least **210 s between runs**. xochitl allows only 4 starts per 10 minutes, and a 5th start makes `remarkable-fail.sh` reboot the tablet.
- Each app gets a time limit.
- A trap and an independent watchdog both restart xochitl, even if `run.sh` itself is killed.

## E-ink modes

The server maps each protocol waveform hint to an `EPScreenModeItem` mode in one place, `modeForHint()` in `server/main.cpp`:

- `0` (fast) → `Animation`
- `1` (quality) → `Content`

These were chosen from a watched test. The available modes are `Pen`, `Mono`, `Animation`, `UI` (the default), `Content` and `Sleep`.

`FULL_REFRESH` calls `EPFramebuffer::clearGhosting()`.

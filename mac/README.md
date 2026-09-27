# rM2 Sidecar (Mac side)

rM2 Sidecar is a menu-bar app. It creates a 1404x1872 virtual display, captures it with ScreenCaptureKit at 4 fps in grayscale, and streams the dirty rects to the tablet. It also turns tablet input into mouse events. The wire format is in [`../PROTOCOL.md`](../PROTOCOL.md).

## Build

```sh
swift build              # debug build, for a compile check
./build-app.sh           # release build of build/RM2Sidecar.app, signed (see below)
```

`build-app.sh` signs with your "Apple Development" identity if you have one. That way your Screen Recording and Accessibility grants survive rebuilds. To choose an identity yourself, set `SIGN_IDENTITY`. Use `SIGN_IDENTITY=-` for ad-hoc signing, but then you have to grant both permissions again after every rebuild.

## Run

```sh
open build/RM2Sidecar.app --args --host 127.0.0.1                            # against the mock
open build/RM2Sidecar.app                                                    # against the tablet (10.11.99.1:9876)
open build/RM2Sidecar.app --stdout /tmp/rm2.log --args --host 127.0.0.1      # with a log file
```

- To change the host and port, use `--host` and `--port`, or set `RM2_HOST` and `RM2_PORT`.
- The app connects on launch and retries every 2 s.
- The virtual display is removed when the app quits.

## Permissions

On first launch, macOS asks for two permissions:

- **Screen Recording.** Grant it, then quit and relaunch the app. The app can't capture until it's relaunched.
- **Accessibility.** Needed for pen input. It takes effect immediately.

If either is missing, the menu shows a "Grant…" item that opens the right Settings pane.

## Mock tablet

```sh
python3 ../mock/mock_tablet.py                   # saves mock_frame.png, logs bytes every 2 s
python3 ../mock/mock_tablet.py --script-input    # also moves, drags and clicks on the virtual display
```

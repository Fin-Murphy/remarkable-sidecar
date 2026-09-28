# rM2 Sidecar (Mac side)

rM2 Sidecar is a Dock app with one small window (`AppWindow.swift`): the session state, Connect/Disconnect, and a Grant… button for each missing permission. Closing the window quits. It creates a 1404x1872 virtual display, captures it with ScreenCaptureKit at 4 fps in grayscale, and streams the dirty rects to the tablet. It also turns tablet input into mouse events. The wire format is in [`../docs/PROTOCOL.md`](../docs/PROTOCOL.md). Setup and everyday use are in the [top-level README](../README.md); this file is for development.

## Build

```sh
swift build              # debug build, for a compile check
./build-app.sh           # release build of build/RM2Sidecar.app, signed (see below)
```

`build-app.sh` signs with your "Apple Development" identity if you have one. That way your Screen Recording and Accessibility grants survive rebuilds. To choose an identity yourself, set `SIGN_IDENTITY` in `../config.local`. Use `SIGN_IDENTITY=-` for ad-hoc signing, but then you have to grant both permissions again after every rebuild.

`build-app.sh` also bakes `RM2_HOST`, `RM2_WIFI_HOST` and `RM2_PORT` from `../config.local` into the app's `LSEnvironment`, so they apply when the app is opened from Finder. Command-line flags still override them.

The app icon is drawn in code by `make-icon.swift`; `build-app.sh` turns it into `AppIcon.icns` (with `iconutil`) and only redraws it when that script changes.

## Run

```sh
open build/RM2Sidecar.app                                                # then click Connect in its window
open build/RM2Sidecar.app --args --connect                               # connect right away
open build/RM2Sidecar.app --args --host 127.0.0.1 --no-launch            # against the mock (no SSH)
open build/RM2Sidecar.app --stdout /tmp/rm2.log --args --connect         # with a log file
```

- **Connect** starts the tablet side over SSH (`/usr/bin/ssh`, key auth, BatchMode), tunnels to it, and connects.
  - The tablet's host key is checked against the entry for `10.11.99.1`, whichever address is used.
  - **Disconnect** or **Quit** ends the tablet session, and the reMarkable UI comes back within a few seconds.
- **Window states:** Disconnected / Starting tablet… / Connected / Reconnecting… / *the error's reason*.
  - Guard refusals are shown in words, for example "Tablet busy (its screen app restarted too often). Try again in 90 s".
  - The app never retries starting the tablet on its own.
- **Options:**
  - `--host` sets the SSH host (default `10.11.99.1`); `--port` sets the server's port on the tablet (default `9876`); `--wifi-host` names the Wi-Fi host (default: `remarkable.local`, then the last Wi-Fi address the tablet reported). The environment variables `RM2_HOST`, `RM2_PORT` and `RM2_WIFI_HOST` do the same.
  - `--no-launch` connects straight to `host:port` at launch, without SSH.
- **Scripting:** `kill -USR2 <pid>` = Connect, `kill -USR1 <pid>` = Disconnect.
- **Menu-bar status items:** Control Center's items on the reMarkable display (clock, Wi-Fi, battery, sound) are left out of the capture. That way a clock showing seconds doesn't keep the e-ink busy. Your main display is unaffected.
  - The capture filter never changes while running: ScreenCaptureKit's `updateContentFilter` sometimes stopped the stream silently.
- **Stall watchdog:** ScreenCaptureKit calls back about 4 times a second even when idle. If it goes silent for 3 s, the app logs "Capture stalled…" and restarts the stream.
- **Tests:**
  - `--test-window` opens a window on the reMarkable display that changes twice a second and moves every second. This is the regression check that window changes produce frames.
  - `open --env RM2_TEST_STALL=1 …` silently stops the stream after 10 s, to check the watchdog.
- The virtual display is removed when the app quits.
- **Text size.** At launch the display is set to "looks like 702 × 936" (HiDPI, 2x). That's the full 1404 × 1872 pixels, drawn at double size.
  - For bigger text, pick 600 × 800 or 540 × 720 in System Settings → Displays → reMarkable 2. These are slightly softer because they're scaled.
  - 1404 × 1872 (1x) is available but tiny.
- **Orientation** (`Orientation.swift`): Portrait, Landscape ↓ or Landscape ↑ (where the tablet's thick edge goes), chosen in the window and saved in the app's defaults (`orientation`).
  - The tablet side doesn't know about it: it always gets portrait 1404 × 1872 frames and sends input in those coordinates.
  - In landscape the virtual display offers the same sizes turned sideways (936 × 702 etc.), keeping the chosen one. Each captured 1872 × 1404 frame is turned 90° into the panel's orientation before diffing. Input is turned back with the same mapping, so a tap lands on what's drawn under it.
  - Switching sends the next frame whole. Frames are skipped until the display's mode has switched, so a half-switched frame never reaches the tablet.

## Permissions

Screen Recording (needs a relaunch after granting) and Accessibility (for pen input). See the [top-level README](../README.md#6-first-launch-and-permissions).

## Mock tablet

```sh
python3 ../tools/mock_tablet.py                   # saves mock_frame.png, logs bytes every 2 s
python3 ../tools/mock_tablet.py --script-input    # also moves, drags and clicks on the virtual display
open build/RM2Sidecar.app --args --host 127.0.0.1 --no-launch   # then point the app at it
```

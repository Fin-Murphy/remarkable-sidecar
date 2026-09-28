# Handoff: rM2 Sidecar session of 2026-09-28

Untracked working note. Delete it once the work below is committed.

Nothing is committed. Three pieces of work sit together in the working tree on `main`:

1. Connection fixes (done and tested on the tablet).
2. Dock app with its own window and icon (done; mostly tested).
3. Portrait/landscape orientation (written but **not compiled or tested**; this is where to pick up).

The user asked to commit only once they say so. They haven't decided whether it should be one commit
or separate ones, so ask.

## 1. Connection fixes (done, tested on the device)

The bug: Connect failed until the user reconnected several times, and later never worked. Cause: a
leftover ssh tunnel (`ssh -N -L 127.0.0.1:19876:127.0.0.1:9876`) from an earlier app run held local
port 19876. Such tunnels leaked because:

- `openTunnel()` only recorded the ssh process after a 1.5 s wait;
- a superseded Connect still opened its own tunnel;
- nothing cleaned up after a crash or force quit.

Whether a retry worked was a timing race (the Wi-Fi SSH handshake takes 0.9–2.1 s against the
1.5 s check). Every failure also left a tablet session that later restarted xochitl, so the run.sh
start-limit guard eventually refused everything.

Fixes:

- `mac/Sources/RM2Sidecar/Tablet.swift`:
  - The tunnel is recorded under the lock as it starts, replacing the previous one.
  - `killOrphanedTunnels()` runs `pkill -P 1 -f '^/usr/bin/ssh .* -L 127\.0\.0\.1:19876:'`, so it
    only kills ssh processes whose parent has already died.
  - `openTunnel()` waits up to 10 s until ssh is actually listening (checked with `lsof`) or has
    exited, instead of a fixed 1.5 s.
  - The `start.sh` ssh timeout went from 45 to 90 s.
- `mac/Sources/RM2Sidecar/Sidecar.swift`: `connect()` doesn't open a tunnel if Disconnect was chosen
  meanwhile (it checks the generation).
- `tablet/device/run.sh`: a session lock (`exec 8>>.session.lock; flock -n 8`). A second run.sh is
  refused with exit 6. The session's apps, time-limit subshell and watchdog inherit the lock, so it's
  released only after xochitl is back.
- `tablet/device/start.sh`:
  - Runs one at a time via `.start.lock`, by polling, because BusyBox `flock` has no `-w`. The fd is
    closed for run.sh with `9>&-`.
  - Returns READY only if `netstat -tln` shows 127.0.0.1:9876 listening.
  - If a session is still ending, it waits up to 15 s for `.session.lock`.
- `docs/SAFETY.md` and `tablet/README.md` are updated.
- **Already deployed to the tablet:** run.sh and start.sh are in `/home/root/rm2sidecar/`, and their
  md5 matches the repo.

Tests that passed on the device:

- A leftover tunnel is cleaned up and Connect succeeds.
- Connect → Disconnect while starting → Connect leaves no leaked tunnel, and no tunnels remain after
  Quit.
- Two `start.sh` runs 0.3 s apart start one session.
- A direct run.sh during a session is refused.
- Disconnect then Connect 0.5 s later waits for xochitl, then starts a new session.
- With another program on port 19876, the error is clear.

## 2. Dock app window (done)

The user chose: Dock only, no menu-bar item; closing the window quits the app; a minimal window; an
icon drawn in code.

- `MenuBar.swift` was renamed with `git mv` to `AppWindow.swift`, an AppKit window. It has:
  - a status dot and text;
  - a Connect/Disconnect button;
  - a "⚠ … not granted  [Grant…]" row per missing permission, refreshed when the app becomes active;
  - `windowWillClose` → `NSApp.terminate`.
- `main.swift`: `.regular` activation policy, `makeMainMenu()` (About/Hide/Quit and
  Minimize/Close), and the window shown at launch.
- `mac/Info.plist`: `LSUIElement` removed, `CFBundleIconFile` = `AppIcon`.
- `mac/make-icon.swift` (new and untracked, so remember to `git add` it) draws the icon.
  `build-app.sh` renders it into `.build/AppIcon.icns` with `iconutil`, only when the script has
  changed.
- READMEs are updated.
- Checked from screenshots: the Disconnected, Starting and long-error states, and the app showing in
  the Dock.
- **Not yet checked:** that closing the window quits the app (the old session couldn't click UI; no
  Accessibility), and how the permission rows look (both permissions are granted on this Mac).

## 3. Orientation (NOT compiled yet; resume here)

The user chose three options: Portrait, Landscape ↓ (thick edge at the bottom, tablet turned
counter-clockwise) and Landscape ↑ (thick edge at the top, turned clockwise).

The tablet side is unchanged: it always gets portrait 1404×1872 frames and sends input in panel
coordinates. All the work is on the Mac:

- `Orientation.swift` (new):
  - `displaySize`
  - `displayPoint(panelX:panelY:)`: the one mapping.
    - Landscape ↓ (`landscapeGripDown`): display = (y, 1403 − x).
    - Landscape ↑ (`landscapeGripUp`): display = (1871 − y, x).
  - `panelFrame(from:stride:)`: rotates a captured frame into the panel layout.
- `VirtualDisplay.swift`:
  - `init(orientation:)`, with the descriptor's max pixels set to 1872×1872.
  - `setOrientation()` re-applies `CGVirtualDisplaySettings` with the rotated mode list, then selects
    the same text-size index.
  - The retrying mode selection moved into `selectMode(size:attempts:)`.
- `Capture.swift`:
  - The orientation is passed in.
  - `configuration(for:)`.
  - `setOrientation()` calls `stream.updateConfiguration` when switching between portrait and
    landscape.
  - The frame callback skips frames until the buffer size and the display's aspect match the
    orientation, then calls `orientation.panelFrame`.
- `Input.swift`: an `orientation` var; panel coordinates go through `displayPoint`, scaled by
  `displaySize`.
- `Sidecar.swift`:
  - `init(..., orientation:)` and `setOrientation()`.
  - On a direction-only change (↓ ↔ ↑), `latest` is reversed (a 180° turn) and pumped, because the
    display doesn't change so no new frame comes.
  - Otherwise `latest = nil`. In both cases `sent = nil`.
- `AppWindow.swift`: an `NSSegmentedControl` with tooltips, plus an `onOrientation` callback.
- `main.swift`: reads and saves the choice in UserDefaults under the key `orientation`, and wires the
  window callback to `display.setOrientation` and `sidecar.setOrientation`.
- READMEs are updated.

Next steps:

1. `cd mac && swift build`, and fix any compile errors. Suspect spots:
   - tuple comparisons like `(width, height) == orientation.displaySize` and
     `Self.pointSizes.firstIndex { $0 == portrait }`;
   - `(config.width, config.height) = orientation.displaySize`.
2. `./build-app.sh`.
3. The user will test against the real tablet themselves; they explicitly said not to set up a mock.
   Risks to tell them about:
   - Re-applying settings on a live CGVirtualDisplay might not take.
     - Fallback: offer all portrait and landscape modes from creation, and only select between them.
   - After a portrait↔landscape switch, ScreenCaptureKit might not send a new complete frame on an
     idle screen, so the tablet would look stale until something changes.
   - Rotation cost is about 2.6 M pixels per frame with an unspecialized loop. It's probably fine at
     4 fps in release; specialize the loops if it's slow.

## Device state and rules

- The tablet (rM2, OS 3.28.0.172) is on Wi-Fi at 192.168.0.60 (`remarkable.local`). USB wasn't
  connected. The last time it was checked, its battery was at 89% and no session was running.
- Follow the memory files: the safety rules, the xochitl start limit, and never deploying while a
  session is live. Check `pidof rm2sidecar` in the same command as any copy.
- The user's own app instance may be running, and they may connect at any time.
- The app's stdout goes to /dev/null when it's opened from Finder. For logs, use
  `open build/RM2Sidecar.app --stdout <file>`.

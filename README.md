# reMarkable Sidecar

This is a Swift-based (Mac-native) application for turning your reMarkable 2 e-ink tablet into a second monitor, like Apple's Sidecar, via USB or Wi-Fi as desired.
It has all the same basic use cases as any other sidecar: reference sheets, extra info, etc. Since it's e-ink, it is best used for text-based applications.

My current use for it is as a Claude terminal. I have my Claude display separately in the e-ink terminal while all the rest of my work lives on the screen in front of me.

<!-- Photo of the tablet in use goes here: ![rM2 Sidecar in use](docs/photo.jpg) -->

> **What to expect.** It's e-ink: changes show up within about a second, in grayscale, and the Mac
> captures the display 4 times a second. It's great for text, documents and terminals. It's poor for
> scrolling-heavy work and useless for video. While it's connected, the tablet's normal reMarkable
> app is paused, and it comes back when you disconnect.

## Contents

- [Compatibility](#compatibility)
- [Before you start: safety](#before-you-start-safety)
- [Requirements](#requirements)
- [Setup](#setup)
- [Using it](#using-it)
- [Wi-Fi (optional)](#wi-fi-optional)
- [Troubleshooting](#troubleshooting)
- [How it works](#how-it-works)
- [Development](#development)
- [Credits](#credits)

## Compatibility

| | Status |
|---|---|
| reMarkable 2, OS **3.28.0.172** | Tested |
| reMarkable 2, other OS 3.x versions | Untested. You need the SDK that matches your OS version, and the tablet's private display API may differ. |
| reMarkable 1, Paper Pro, Paper Pro Move | Not supported |
| macOS 14 or newer | Required. Tested on macOS 26 on Apple Silicon; Intel is untested. |

Check your tablet's OS version in **Settings → General → About**.

## Before you start: safety

rM2 Sidecar is designed so that **a reboot undoes anything it does** to the tablet:

- It writes only to `/home/root/rm2sidecar/`.
- It installs nothing into the system, and nothing starts at boot.
- When a session ends, the tablet's normal app always comes back.

Please still **back up your tablet first**, because the rM2 has no official recovery tool.
[docs/SAFETY.md](docs/SAFETY.md) has the backup commands, the rules the tablet side enforces, what
never to do, and how to remove rM2 Sidecar completely.

Also turn off automatic updates while you use it (**Settings → General → Software**). An OS update
needs a matching rebuild of the tablet side.

## Requirements

- A Mac with macOS 14 or newer, and the Xcode Command Line Tools (`xcode-select --install`).
- A USB-C cable for the tablet.
- **Docker Desktop**, [OrbStack](https://orbstack.dev) or [Colima](https://github.com/abiosoft/colima).
  Docker is only used to **build** the tablet program, not to run it:
  - the tablet has a 32-bit ARM Linux processor, so its program must be compiled with reMarkable's
    official SDK;
  - that SDK only runs on Linux, and Docker gives your Mac a small Linux environment to run it in.

  Once the tablet side is built, you don't need Docker running to use rM2 Sidecar.
- **The reMarkable 2 SDK** for your tablet's OS version, from
  [developer.remarkable.com/links](https://developer.remarkable.com/links). Pick the `rm2` toolchain
  for your Mac's processor: `aarch64` for Apple Silicon, `x86_64` for Intel. For OS 3.28.0.172 on
  Apple Silicon that's `remarkable-production-image-5.8.203-rm2-public-aarch64-toolchain.sh`
  (about 400 MB). It isn't included here; download it yourself.

## Setup

### 1. Let your Mac log in to the tablet

Plug the tablet in with USB. Its SSH password is on the tablet under **Settings → General → About →
Copyrights and licenses** (under **Help** on some OS versions), at the bottom of the page.

```sh
ls ~/.ssh/id_*.pub || ssh-keygen -t ed25519   # make a key if you don't have one
ssh-copy-id root@10.11.99.1                   # asks for the tablet's password once
ssh root@10.11.99.1 cat /etc/version          # should print a version without asking for a password
```

The app always connects with this key. Your password is never stored anywhere.

### 2. Get the code and your settings file

```sh
git clone https://github.com/Fin-Murphy/remarkable-sidecar.git
cd remarkable-sidecar
cp config.example config.local
```

`config.local` holds anything specific to your machine: the SDK location, a different tablet
address, your code-signing identity. It's git-ignored. The defaults work for most setups, so you
may not need to change anything; each setting is explained in [config.example](config.example).

### 3. Build the tablet side

Put the SDK installer in `~/rm2-sdk/`, or set `RM2_SDK_DIR` and `RM2_SDK_FILE` in `config.local`.
Start Docker, then:

```sh
tablet/build.sh
```

The first run installs the SDK into a Docker image, which takes a few minutes. The result is
`tablet/server/build/rm2sidecar`.

### 4. Copy it to the tablet

```sh
tablet/deploy.sh
```

This copies the server and its scripts to `/home/root/rm2sidecar/`. Nothing runs yet.

### 5. Build the Mac app

```sh
mac/build-app.sh
```

This creates `mac/build/RM2Sidecar.app`. You can move it to `/Applications` if you like.

It's signed with your "Apple Development" identity if you have one, which you get free by signing in
to Xcode with an Apple ID. Otherwise it's signed ad hoc. That works too, but macOS then asks for
permissions again after every rebuild.

### 6. First launch and permissions

```sh
open mac/build/RM2Sidecar.app
```

The rM2 Sidecar window opens, the app appears in the Dock, and a new "reMarkable 2" display appears
in **System Settings → Displays**, to the left of your main screen. macOS asks for two permissions:

- **Screen Recording:** grant it, then quit the app (⌘Q or close its window) and open it again. It
  can't capture the screen until it's relaunched.
- **Accessibility:** lets the pen move and click your mouse. It works straight away.

If either is missing, the window shows a **Grant…** button that opens the right Settings page.

### 7. Connect

Click **Connect** in the window. The app starts the tablet side over SSH, and within about
5 seconds the window shows **Connected (USB)** and the tablet shows the new display. Drag windows
onto it past the left edge of your main screen. Closing the window quits the app, which ends the
session and brings the tablet's own app back.

## Using it

**Window states:** gray Disconnected, orange Starting tablet… or Reconnecting…, green Connected (USB
or Wi-Fi), red with the reason when something went wrong.

**Pen and touch:**

| On the tablet | On the Mac |
|---|---|
| Pen hovering | Moves the cursor |
| Pen touching the screen | Click, or drag while it moves |
| Two quick pen taps | Double-click |
| Finger tap | Click |
| Finger held for about 0.6 s | Right-click |
| Power button | Ends the session |

Touch is ignored while the pen is near the screen, so resting your hand doesn't click.

**Orientation.** Choose it in the window, any time, even while connected:

- **Portrait:** the tablet upright, with its thick edge on the left.
- **Landscape ↓:** the tablet on its side, with the thick edge at the bottom.
- **Landscape ↑:** the tablet on its side, with the thick edge at the top.

The app remembers your choice. In landscape the Mac's reMarkable display is 1872 × 1404, and the pen
and touch follow the rotation.

**Text size.** The display starts at "looks like 702 × 936" (936 × 702 in landscape): all the
tablet's pixels, drawn at double size. For bigger text, choose a smaller size in **System Settings →
Displays → reMarkable 2**. Your text size is kept when you rotate.

**Ending a session.** Choose **Disconnect** or **Quit**, or press the tablet's power button. The
normal reMarkable screen returns within a few seconds. A session also ends by itself if the Mac has
been gone for 30 seconds (for example, you pulled the cable), and after 8 hours at most.

**Ghosting.** After activity stops for 2 seconds, the tablet flashes once to clean up leftover
images. The menu-bar clock, Wi-Fi and battery icons are hidden on the tablet, so a clock showing
seconds doesn't keep it busy.

**Battery.** The tablet doesn't sleep during a session and only charges over USB.

## Wi-Fi (optional)

The app uses USB whenever the cable is plugged in. If it isn't, the app tries Wi-Fi: first
`remarkable.local`, then the last Wi-Fi address the tablet reported. Everything still goes through
encrypted SSH.

To allow it, turn on reMarkable's own SSH-over-Wi-Fi switch once, over USB:

```sh
ssh root@10.11.99.1 rm-ssh-over-wlan on    # 'off' undoes it
```

- **Security:** anyone on your network who knows the tablet's root password can then log in to it.
  That's usually fine at home, but don't leave it on for shared or public Wi-Fi. The app itself only
  uses your key, and checks that it's talking to the same tablet it knows over USB.
- **Power saving:** Wi-Fi power saving causes lag spikes, so it's turned off during a session and
  restored afterwards.
- **Address:** if `remarkable.local` doesn't work on your network, give the tablet a fixed address
  in your router, or set `RM2_WIFI_HOST` in `config.local` and rebuild the app.

## Troubleshooting

- **"Tablet busy (its screen app restarted too often). Try again in N s."** The reMarkable app may
  only restart 4 times in 10 minutes, or the tablet reboots itself, so the tablet side refuses once
  there have been 3. Wait the time shown. See [docs/SAFETY.md](docs/SAFETY.md).
- **"Can't reach the tablet by USB or Wi-Fi."** Check the cable, and that the tablet is awake.
  `ssh root@10.11.99.1 true` should succeed without a password.
- **SSH asks for a password, or "Permission denied".** Redo step 1 (`ssh-copy-id`).
- **"Host key verification failed".** The app checks every connection against the tablet's USB host
  key. Run `ssh root@10.11.99.1 true` once over USB and answer `yes`. If you reset your tablet, first
  remove its old key with `ssh-keygen -R 10.11.99.1`.
- **The tablet shows the display but it never changes.** Quit and reopen the app. If it keeps
  happening, check that Screen Recording is granted, and open the app with a log to see what's
  wrong: `open mac/build/RM2Sidecar.app --stdout /tmp/rm2.log`.
- **Python tools can't reach 10.11.99.1** ("No route to host"). That's macOS's Local Network privacy
  blocking them. Tunnel through SSH instead; see [tablet/README.md](tablet/README.md).
- **`tablet/build.sh` says "SDK installer not found".** Check `RM2_SDK_DIR` and `RM2_SDK_FILE` in
  `config.local`, and that the file name matches what you downloaded.

## How it works

```
Mac (Dock app)                                            reMarkable 2 (tablet server)
virtual display 1404×1872
 → capture 4×/s, grayscale, changed areas only
 → zlib-compressed rects ─────── SSH tunnel (USB/Wi-Fi) ──→ draw on e-ink (fast or quality mode)
 ← mouse moves and clicks ←───────────────────────────────── pen and touch events
```

- **The Mac side** (`mac/`, Swift) creates the virtual display, captures it with ScreenCaptureKit,
  sends only what changed, and turns tablet input into mouse events.
- **The tablet side** (`tablet/server/`, C++/Qt) draws through reMarkable's own e-ink plugin, reads
  the pen, and runs only while a session is active, through `tablet/device/run.sh`.

The wire format is in [docs/PROTOCOL.md](docs/PROTOCOL.md).

## Development

```
mac/                   Mac app (Swift package); developer notes in mac/README.md
tablet/server/         tablet server (C++/Qt 6)
tablet/device/         files that run on the tablet: run.sh, start.sh, session.batch
tablet/docker/         SDK build image, plus a desktop-Linux image for offline tests
tablet/experiments/    e-ink refresh-speed experiment
tools/                 mock_tablet.py (fake tablet for the Mac app), test_sender.py (fake Mac for the server)
docs/                  PROTOCOL.md, SAFETY.md, RESOURCES.md
```

You can work on either half without a tablet:

- `tools/mock_tablet.py` plays the tablet for the Mac app.
- `tools/test_sender.py` plays the Mac for a desktop-Linux build of the server.

See [mac/README.md](mac/README.md) and [tablet/README.md](tablet/README.md).

## Credits

- [VNSee](https://github.com/matteodelabre/vnsee), the original "reMarkable as a second screen"
  project, which showed this was possible.
- [remarkable2-framebuffer](https://github.com/ddvk/remarkable2-framebuffer), for explaining how the
  rM2's display works.
- [KOReader](https://github.com/koreader/koreader), for the rM2 pen coordinate mapping.
- [DeskPad](https://github.com/Stengo/DeskPad), for the `CGVirtualDisplay` declarations.
- [remarkable_mouse](https://github.com/Evidlo/remarkable_mouse), for the pen-as-mouse idea.
- reMarkable's [SDK and developer examples](https://developer.remarkable.com).
- More reMarkable projects: [awesome-reMarkable](https://github.com/reHackable/awesome-reMarkable)
  and [docs/RESOURCES.md](docs/RESOURCES.md).

Not affiliated with reMarkable AS. Modifying your tablet is at your own risk and may affect your
warranty.

## License

[MIT](LICENSE)

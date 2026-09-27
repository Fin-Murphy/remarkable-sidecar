# rM2 Sidecar wire protocol, version 1

This is plain TCP. The tablet server listens on `127.0.0.1:9876`. The Mac reaches it through an SSH port forward (`ssh -L 127.0.0.1:19876:127.0.0.1:9876 root@<tablet>`) and connects as the client.

- This means the port isn't exposed on the tablet's USB or Wi-Fi interfaces.
- USB and Wi-Fi use the same path.
- The server can also bind a network address directly (`--listen 10.11.99.1`), and the protocol is the same either way.

- All integers are **little-endian**.
- Every message starts with a `u8` type byte.
- There are no other length prefixes, so both sides must know every type's layout. An unknown type is a protocol error, and the receiver closes the connection.

## Coordinates

The display is 1404 x 1872 pixels in portrait orientation. `(0,0)` is the top-left pixel, x grows to the right and y grows downward. RECT and INPUT use the same pixel space.

## Tablet -> Mac

### 0x81 HELLO (11 bytes)

The tablet sends HELLO once, immediately after accepting the connection.

| offset | type  | field            | value              |
|-------:|-------|------------------|--------------------|
| 0      | u8    | type             | `0x81`             |
| 1      | 4 x u8| magic            | ASCII `RMSC`       |
| 5      | u16   | protocol_version | `1`                |
| 7      | u16   | width            | `1404`             |
| 9      | u16   | height           | `1872`             |

The Mac closes the connection if any of these is wrong: the magic, the version, or the size (it only supports 1404x1872). It then retries after 2 s.

After a valid HELLO, the Mac sends one full-frame RECT (`0,0 1404x1872`, hint 1) followed by FRAME_END. From then on it sends only what changes.

### 0x90 INPUT (8 bytes)

| offset | type | field    |
|-------:|------|----------|
| 0      | u8   | type = `0x90` |
| 1      | u8   | kind     |
| 2      | u16  | x        |
| 4      | u16  | y        |
| 6      | u16  | pressure (0-4095, may be 0) |

`x` and `y` are display pixels, already rotated and mapped by the tablet. The Mac clamps them to the display.

| kind | name             | Mac action |
|-----:|------------------|------------|
| 0    | hover_move       | Moves the cursor. If the pen is down, it's a drag instead. |
| 1    | pen_down         | Left mouse down. Two downs within the system double-click interval and 8 pt of each other count as a double click. |
| 2    | pen_move         | Left drag while the pen is down, otherwise a cursor move. |
| 3    | pen_up           | Left mouse up. |
| 4    | touch_tap        | Moves the cursor, then left down and up (a click). |
| 5    | touch_long_press | Moves the cursor, then right down and up (a right click). |

Any other kind value is a protocol error. The Mac currently ignores pressure. It also ignores INPUT that arrives before HELLO.

## Mac -> tablet

### 0x01 RECT (14-byte header + payload)

| offset | type | field          |
|-------:|------|----------------|
| 0      | u8   | type = `0x01`  |
| 1      | u16  | x              |
| 3      | u16  | y              |
| 5      | u16  | w              |
| 7      | u16  | h              |
| 9      | u8   | waveform_hint  |
| 10     | u32  | payload_len    |
| 14     | payload_len bytes | payload |

- The payload is a **zlib** stream (RFC 1950, with the 2-byte header and the Adler-32 trailer, so not raw deflate). It decompresses to exactly `w*h` bytes of 8-bit gray, row-major, where 0 is black and 255 is white.
- The rect always lies within the display: `x+w <= 1404` and `y+h <= 1872`.
- The Mac diffs in 64x64 tiles, so rects are usually aligned to 64. Rects clipped at the right or bottom edge are narrower or shorter. Don't depend on the alignment.

`waveform_hint` values:

- `0`, fast (DU or similar): content is changing quickly. That means the previous change was less than 1 s ago, or the pen is down.
- `1`, quality (GC16): the first change after a quiet period, and the initial full frame.

### 0x02 FULL_REFRESH (1 byte)

This message has no body. The tablet should do a full GC16 flash of the whole screen from its current framebuffer to clear ghosting.

The Mac sends it once when two conditions hold: no changes for 2 s, and at least one fast (`hint 0`) RECT since the last FULL_REFRESH.

### 0x03 FRAME_END (1 byte)

This message has no body. It marks the end of the RECTs that came from one captured frame. It is sent after every batch of RECTs, and only then. An idle screen sends no FRAME_ENDs.

**This message was added to the original spec.** Without it, the tablet can't tell when a frame's rects have all arrived. It would either have to start an e-ink update per rect, which means more flashing and more waveform passes over overlapping areas, or guess with a timer. With FRAME_END, the tablet can blit every RECT into its framebuffer as it arrives, then start one partial update over the union (or the list) of the dirty rects when FRAME_END arrives.

A tablet that doesn't care can ignore it, but it still has to parse it (1 byte).

## Flow control and timing

- The Mac captures at 4 fps, and ScreenCaptureKit only delivers frames when something changed. The Mac diffs against the last frame it **sent**, not the last frame it captured.
- The Mac never queues frames. If the previous batch hasn't been handed to the kernel yet, the current frame is skipped. The next batch then contains every change since the last send. So a slow tablet sees fewer, larger updates rather than a growing backlog.
- To keep this working, the tablet should read the socket promptly, for example on a separate thread from the e-ink refresh, and coalesce any rects that pile up.
- The Mac sends nothing while the screen is idle.
- The Mac enables TCP keepalive (idle 2 s, interval 1 s, 3 probes) and reconnects every 2 s.
  - If it can't reconnect within 40 s, it gives up and shows "Tablet session ended".
  - It never restarts the tablet side on its own.
- The tablet server ends its session in any of these cases:
  - no Mac has been connected for `--grace` seconds (30 in the everyday session);
  - it gets SIGTERM (the Mac's Disconnect or Quit);
  - the power button is pressed.

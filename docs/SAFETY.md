# Safety, backup and recovery

rM2 Sidecar is built so that **a reboot undoes anything it does** to your tablet. Please still
back up first. The rM2 has no official recovery tool, so a full restore is hard (see
[Recovery](#recovery)).

## What rM2 Sidecar changes on the tablet

- It copies a few files into `/home/root/rm2sidecar/` (about 2 MB). It writes nowhere else.
- It installs nothing into the system, and nothing starts at boot.
- While a session runs, the reMarkable app (`xochitl`) is stopped, so the tablet shows your Mac
  screen instead. `run.sh` always starts it again when the session ends.
- During a session it turns Wi-Fi power saving off, and restores it afterwards.
- Setup appends your Mac's SSH key to `/home/root/.ssh/authorized_keys`.
- Only if you choose Wi-Fi: reMarkable's own `rm-ssh-over-wlan on` creates one marker file in
  `/home/root/.config/remarkable/`, which lets SSH accept connections over Wi-Fi.

To remove everything:

```sh
ssh root@10.11.99.1 'rm -rf /home/root/rm2sidecar; rm-ssh-over-wlan off'
```

Then delete your key's line from `/home/root/.ssh/authorized_keys` on the tablet.

## Rules `run.sh` enforces

`device/run.sh` is the only way the tablet side is started. It refuses to run, or cleans up, in
these cases:

- **Battery at 30% or less:** it won't start.
- **A firmware update pending** (`fw_printenv upgrade_available` isn't `0`): it won't start. Right
  after an update, the reMarkable app's failure handler switches root partitions, and we never
  want to trigger that.
- **The start limit.** systemd allows `xochitl` to start only **4 times in 10 minutes**. A 5th
  start fails, and the tablet's failure handler **reboots** it. `run.sh` counts every restart (and
  the boot start) and refuses once there have been 3 in the last 10 minutes. The Mac app shows
  this as "Tablet busy… try again in N s".
- **Every exit path restarts `xochitl`:** a normal exit, a crash, the time limit, and an
  independent watchdog that runs even if `run.sh` itself is killed.

## Don't do these

These can leave the tablet unable to boot, or lock you out:

- Install Toltec, rm2fb or VNSee on an OS newer than 3.3.2. That is their last supported version, and Toltec's own site
  warns that newer versions will soft-brick.
- Write to `/`, `/usr`, `/etc` or `/lib`. The root filesystem is small and nearly full, and it's
  replaced by every OS update anyway.
- Enable anything to start at boot (`systemctl enable`). If it crashes, it crashes every boot.
- Run `dd` with `of=` pointing at a device, or `fw_setenv`.
- Flash or downgrade firmware halfway through something else, or on a low battery.

## Backing up

Do this once, before your first session. Keep the tablet on USB, charged and awake. It takes
about 15 minutes and 9 GB of disk space.

```sh
mkdir -p ~/rm2-backup/$(date +%Y%m%d-%H%M%S) && cd "$_"

# 1. A record of the device: OS version, partition table, boot environment.
ssh root@10.11.99.1 'cat /etc/version /usr/share/remarkable/update.conf; fdisk -l /dev/mmcblk2; fw_printenv; df -h' > device-state.txt

# 2. Raw images of the whole internal storage (read-only on the tablet).
ssh root@10.11.99.1 'dd if=/dev/mmcblk2 bs=4M' > mmcblk2.img
ssh root@10.11.99.1 'dd if=/dev/mmcblk2boot0 bs=4M' > mmcblk2boot0.img
ssh root@10.11.99.1 'dd if=/dev/mmcblk2boot1 bs=4M' > mmcblk2boot1.img

# 3. A consistent copy of your notebooks and settings. The reMarkable app is stopped while
#    this runs (the screen freezes), then started again. That uses one of its 4 starts.
ssh root@10.11.99.1 'systemctl stop xochitl; tar -cf - -C / home; systemctl start xochitl' > home.tar
```

Check the boot areas copied exactly. These two lines should print the same checksums:

```sh
ssh root@10.11.99.1 'sha256sum /dev/mmcblk2boot0 /dev/mmcblk2boot1'
shasum -a 256 mmcblk2boot0.img mmcblk2boot1.img
```

The checksum of `mmcblk2.img` won't match the tablet's exactly: its partitions are mounted and
change slightly (logs, journals) while you copy. That's why `home.tar` is taken separately, with
the reMarkable app stopped. It's the copy to restore your documents from.

**Keep the backup private.** It contains your tablet's serial number, saved Wi-Fi passwords and
all your notebooks.

## Recovery

In order of what you should try:

1. **Reboot.** Hold the power button until the tablet restarts. Nothing rM2 Sidecar does survives
   a reboot, apart from the files in `/home/root/rm2sidecar/`, which are only run on request.
2. **The fallback root partition.** The rM2 keeps two copies of its system (A/B partitions) and
   falls back automatically if one fails to boot.
3. **Documents only.** To restore your notebooks from `home.tar`:
   ```sh
   ssh root@10.11.99.1 systemctl stop xochitl
   ssh root@10.11.99.1 'tar -xf - -C /' < home.tar
   ssh root@10.11.99.1 systemctl start xochitl
   ```
4. **Last resort: rewriting the whole storage.** reMarkable's official recovery tool covers only
   the Paper Pro family, not the rM2. The community route is
   [ddvk/remarkable2-recovery](https://github.com/ddvk/remarkable2-recovery). It needs a USB-C
   breakout board and a pogo-pin adapter to boot the tablet into USB recovery mode, after which its
   storage appears on your computer and the images can be written back.
   **Getting the pogo-pin orientation wrong can permanently damage the tablet.** Follow that
   project's instructions exactly.

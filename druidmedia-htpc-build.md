# build instructions

This file now describes the automated test workflow.

The split is:

1. `build-druidhtpc.sh` runs on the host and creates the VM definition plus its two virtual disks.
2. `druidhtpc-arch-setup.sh` runs inside the Arch live environment in that VM and performs the actual install/configuration.

## 1. Host prerequisites

Before starting, make sure the following are true on the host:

* `build-druidhtpc.sh` points at a valid Arch ISO path.
* libvirt/QEMU tooling is installed and working for `qemu:///session`.
* `virt-install`, `virsh`, `virt-viewer`, and `qemu-img` are available.
* you have built one `dvbstreamer-t2-*.pkg.tar.zst` package in a clean Arch environment
* that package is staged in `packages/` beside `druidhtpc-arch-setup.sh`

For the package build workflow, see `druidhtpc-dvbstreamer-build.md`.

## 2. What the VM builder creates

`build-druidhtpc.sh` creates:

* one OS disk at 64 GB
* one recording disk at 40 GB
* a UEFI Arch VM named `druidhtpc-test-env`
* a SPICE display opened with `virt-viewer`

This matches the installer's expectation that the guest will see:

* `/dev/sda` as the OS SSD
* `/dev/sdb` as the recording HDD

## 3. Build and boot the VM

Run on the host:

```bash
cd /home/chris/src/druidhtpc
./build-druidhtpc.sh
```

This will:

1. remove any previous test VM with the same name
2. recreate both virtual disks
3. boot the Arch ISO under libvirt
4. open the VM console with `virt-viewer`

## 4. Inside the Arch live environment

Once the VM boots into the Arch ISO:

```bash
loadkeys uk
timedatectl set-timezone Europe/London
```

Confirm the expected disks are present:

```bash
lsblk
```

You should see:

* `/dev/sda` as the 64 GB OS disk
* `/dev/sdb` as the 40 GB recording disk

## 5. Make the repo available inside the VM

The installer expects the repo contents and the staged `dvbstreamer-t2` package to be available inside the live environment.

Any transfer method is fine. Use whichever is quickest at the time:

### Option A: Temporary web server from the host

On the host:

```bash
cd /home/chris/src
python3 -m http.server 8000
```

Then inside the VM, if the host is reachable from the guest, fetch an archive or individual files.

### Option B: Copy the repo in with `scp`

If you have SSH access set up between host and guest, copy the repo directory and package into the live environment.

### Option C: Shared folder or manual transfer

A shared folder, ISO, or any manual copy method is also fine. The important point is simply that inside the live environment you have:

* `druidhtpc-arch-setup.sh`
* the `packages/` directory containing exactly one `dvbstreamer-t2-*.pkg.tar.*`

## 6. Run the installer inside the VM

From the directory containing `druidhtpc-arch-setup.sh` inside the guest:

```bash
chmod +x druidhtpc-arch-setup.sh
./druidhtpc-arch-setup.sh
```

The installer will:

1. partition `/dev/sda` into ESP, Slot A, Slot B, and shared home
2. partition `/dev/sdb` into one recording-data partition
3. format and mount the filesystems
4. `pacstrap` the Arch base system and UI packages
5. create the `chris` user
6. install the staged `dvbstreamer-t2` package with `pacman -U`
7. configure systemd-boot entries for Slot A and Slot B
8. configure IceWM autologin, X startup, Kodi toggle script, and vidtv helpers

If the package staging directory is missing, or contains zero or multiple matching `dvbstreamer-t2` packages, the installer will stop with an error.

## 7. Reboot and test

Once the installer completes:

```bash
reboot
```

At boot, hold the space bar if you want to force the systemd-boot menu.

## 8. Verify the A/B layout

After booting into Slot A:

```bash
findmnt /
findmnt /home
findmnt /data
```

Expected:

* `/` on the Slot A partition
* `/home` on the shared home partition
* `/data` on the recording disk

Then reboot and select Slot B from the boot menu.

Run the same checks again:

```bash
findmnt /
findmnt /home
findmnt /data
```

Expected:

* `/` now on the Slot B partition
* `/home` unchanged
* `/data` unchanged

That confirms the A/B root swap is working while shared user data and recording storage stay stable.

## 9. Notes for this test workflow

* this document is for the scripted VM path, not the older fully-manual Arch install path
* `build-druidhtpc.sh` does not install Arch by itself; it only creates and boots the VM
* `druidhtpc-arch-setup.sh` is the installer that must be run from inside the VM
* the current installer assumes `/dev/sda` and `/dev/sdb`, which matches the VM builder's SATA disk layout
* vidtv setup is provisioned automatically, but it still depends on the guest kernel actually shipping `dvb_vidtv_bridge`

## 10. Fast rerun loop

When iterating:

1. rebuild or replace the staged `dvbstreamer-t2` package if needed
2. rerun `./build-druidhtpc.sh` on the host
3. re-enter the live environment
4. rerun `./druidhtpc-arch-setup.sh` inside the fresh VM

That gives you a clean repeatable test loop for the eventual physical HTPC install.


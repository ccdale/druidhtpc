# druidhtpc

This is a fantastic, highly optimized HTPC (Home Theatre PC) project.

Using Arch Linux with IceWM gives you an ultra-lightweight X11 environment that boots in seconds and leaves almost all your system RAM and CPU cycles available for raw video decoding and your dvbstreamer processes.

Avoiding Kodi at boot to mitigate its video player memory leak is a very smart design choice, and IceWM is the perfect tool for that since its global keybindings file (~/.icewm/keys) hooks directly into X11 events seamlessly.

To build a reliable foundation for this "whole machine" project, we need to carefully map out your dual-partition active/passive fallback layout and your X11 remote mapping.

------------------------------

## Part 1: The A/B Partition Layout (Active/Passive Fallback)
To allow seamless switching when an Arch update breaks a component, you need an A/B partition layout similar to how Android or ChromeOS operates.
Instead of traditional GRUB, the cleanest way to manage this on Arch is using systemd-boot. It reads simple text files and makes switching your active boot partition completely painless.
## 1. Disk Layout
The system uses two drives to separate the OS from the high-write recording workload:

### Drive 1: SSD (OS drive, ~120 GB)
Four partitions:

* Partition 1 (ESP): ~1 GB, FAT32, mounted at `/boot`. Holds kernel images and systemd-boot configs for both slots.
* Partition 2 (Slot A): ~15 GB, ext4 or BTRFS. Main root filesystem (`/`).
* Partition 3 (Slot B): ~15 GB, ext4 or BTRFS. Backup/upgrade root filesystem.
* Partition 4 (Home): ~25 GB, ext4 or BTRFS. Shared `/home` — mounted by both slots so user config and settings survive A/B switching.

### Drive 2: HDD (recording drive, size to suit)
A single partition formatted ext4, mounted at `/data`. Used exclusively for raw TS recording buffers before they are processed and transferred to the NAS. Keeping recordings on a spinning HDD protects the SSD from continuous high-write workload and gives you generous buffer space without eating into the OS layout.

## 2. The systemd-boot Configurations
Inside your shared /boot/loader/entries/, you will maintain two simple configuration files.
slot-a.conf:

title   Arch Linux (Slot A - Active)
linux   /vmlinuz-linux
initrd  /intel-ucode.img (or amd-ucode.img)
initrd  /initramfs-linux.img
options root=PARTUUID=11111111-1111-1111-1111-111111111111 rw quiet

slot-b.conf:

title   Arch Linux (Slot B - Fallback/Testing)
linux   /vmlinuz-linux-b
initrd  /intel-ucode.img (or amd-ucode.img)
initrd  /initramfs-linux-b.img
options root=PARTUUID=22222222-2222-2222-2222-222222222222 rw quiet

(Note: You will use PARTUUID rather than standard UUIDs to ensure the bootloader never confuses the two roots).
## 3. The Upgrade Strategy
When you want to run updates safely:

   1. Mount Slot B to a temporary directory (e.g., /mnt/slotb).
   2. Use rsync -axHAWXS --numeric-ids / /mnt/slotb to mirror your working active slot to the passive slot.
   3. Use chroot or pacman --root=/mnt/slotb -Syu to upgrade the passive slot to the latest Arch packages.
   4. Copy the updated kernel/initramfs from Slot B over to your /boot partition as vmlinuz-linux-b.
   5. Reboot. If the new update breaks ccatv or X11, simply hit the down arrow on your keyboard at the boot menu to instantly drop back into your rock-solid Slot A.

------------------------------
## Part 2: X11 Remote Control Triggering in IceWM
To allow your Media Center Edition (MCE) remote control to launch and clean up Kodi without using a mouse or keyboard, you can leverage IceWM’s native X11 shortcut engine alongside lirc or xdotool.
Modern Linux kernels recognize MCE IR receivers natively as standard USB keyboards. When you press the "Green Button" or "Home" button on an MCE remote, it typically sends a specific X11 keysym like XF86AudioMedia, XF86WWW, or a standard key combination.
## 1. Identify Your Remote's Key Name
To see exactly what key name X11 assigns to your MCE remote button, open your terminal inside your running IceWM session and run:

xev -event keyboard

Press the launch button on your remote. Look at the terminal output for the keysym value in parentheses (for example: keysym 0x1008ff32, XF86AudioMedia).
## 2. Configure IceWM to Launch Kodi on Demand
Open your IceWM keys configuration file:

mkdir -p ~/.icewm
nano ~/.icewm/keys

Add a line binding that specific keysym to launch Kodi:

key "XF86AudioMedia" kodi

## 3. Handling the Memory Leak Atomically
Because you mentioned Kodi leaks memory the longer it runs, you can turn this shortcut into a smart toggle script instead of launching Kodi directly. If Kodi is closed, it opens it. If it is already open, it force-closes it to clear out the leaked memory completely.
Create a small launcher script at /home/chris/scripts/toggle-kodi.sh:

#!/usr/bin/env bashset -euo pipefail
if pgrep -x "kodi-x11" > /dev/null; then
    echo "Kodi is running. Terminating to free memory leak..."
    pkill -x "kodi-x11"else
    echo "Launching clean Kodi session..."
    kodi &fi

Make it executable (chmod +x ~/scripts/toggle-kodi.sh), and then map your IceWM key directly to your script instead:

key "XF86AudioMedia" /home/chris/scripts/toggle-kodi.sh

------------------------------
## Part 3: Virtual Hardware Testing with vidtv (VirtualBox / GNOME Boxes)

Before deploying changes to the real HTPC hardware, you can validate the entire DVB software stack — dvbstreamer, ccatv, channel scanning, and IceWM key bindings — inside a virtual machine using the Linux **vidtv** kernel module. This gives you a fully synthetic DVB adapter that behaves like real hardware without requiring a physical tuner card.

### What vidtv provides
`vidtv` (Virtual DVB driver) is in mainline Linux but is **not compiled by default**. It requires two kernel config options to be enabled: `DVB_TEST_DRIVERS` and `DVB_VIDTV`. Before using it, confirm the Arch stock kernel includes these (or build a custom kernel for the VM with them enabled):

```
zcat /proc/config.gz | grep -E 'DVB_TEST_DRIVERS|DVB_VIDTV'
# Both should show =m or =y
```

When loaded, it registers a synthetic DVB adapter under `/dev/dvb/adapter0/` that exposes the full standard V4L DVB API — meaning every tool that works on real tuner hardware (`dvbv5-scan`, `dvbv5-zap`, `dvb-fe-tool`, `dvbstreamer`) works identically against the virtual device.

The driver is split into three kernel modules: `dvb_vidtv_bridge`, `dvb_vidtv_tuner`, and `dvb_vidtv_demod`. The bridge pulls in the others automatically. It generates a valid MPEG-TS stream containing a single audio-only service named **"Beethoven"** (provider: LinuxTV.org), carrying a SMPTE 302M encoded sine wave — enough to exercise the full DVB pipeline including PAT, PMT, SDT, NIT, and EIT table parsing. It supports DVB-T, DVB-T2, DVB-S, DVB-S2, and DVB-C frontends on the same adapter.

### VM setup (VirtualBox or GNOME Boxes)
Because `vidtv` is a pure kernel module with no dependency on USB or PCI passthrough, it works inside any Linux guest VM without any special device assignment:

1. Create an Arch Linux VM in VirtualBox or GNOME Boxes using the same Arch ISO you use for the real machine. A minimal install (1–2 GB RAM, 20 GB disk) is sufficient.
2. Inside the guest, confirm the kernel version is 5.10 or later:
   ```
   uname -r
   ```
3. Load the virtual DVB adapter (the bridge module pulls in tuner and demod):
   ```
   sudo modprobe dvb_vidtv_bridge
   ```
4. Verify the adapter appeared:
   ```
   ls /dev/dvb/
   # Expected: adapter0/
   dvb-fe-tool
   # Should report: "Dummy demod for DVB-T/T2/C/S/S2" with supported delivery systems
   ```

### Scanning channels against the virtual adapter
With `dvb-tools` installed (`pacman -S v4l-utils`), create a minimal scan file targeting the default vidtv frequency. For DVB-C (the default delivery system):

```
# ~/vidtv.conf
[Channel]
FREQUENCY = 474000000
MODULATION = QAM/AUTO
SYMBOL_RATE = 6940000
INNER_FEC = AUTO
DELIVERY_SYSTEM = DVBC/ANNEX_A
```

For DVB-T, only `FREQUENCY` and `DELIVERY_SYSTEM = DVBT` are strictly required (vidtv does not heavily validate scan file parameters). Then scan:

```
dvbv5-scan ~/vidtv.conf
```

This should lock at 474 MHz and report the "Beethoven" service from provider "LinuxTV.org".

### Testing dvbstreamer and ccatv in the guest
Once the channel is visible, the full stack can be exercised as it would be on the real machine:

1. Tune to the synthetic service and record 10 seconds to disk:
   ```
   dvbv5-zap -c dvb_channel.conf "beethoven" -o music.ts -P -t 10
   ```
   Or stream live to the DVR interface in one terminal and consume with mplayer in another:
   ```
   # terminal 1
   dvbv5-zap -c dvb_channel.conf "beethoven" -P -r &
   # terminal 2
   mplayer /dev/dvb/adapter0/dvr0
   ```
2. Point `dvbstreamer` at the virtual adapter using the same configuration file format you use in production. Any bugs in service selection, stream remultiplexing, or RTP output will surface here without needing the real tuner.
3. Because vidtv generates a stable, deterministic MPEG-TS bitstream, you can record short clips and run automated assertions on them (e.g., verify PAT/PMT parse correctly, check for PCR continuity with a tool such as DVBInspector).

### Simulating degraded signal conditions
There is no runtime sysfs/debugfs interface for signal quality yet (it is listed as a future improvement in the driver docs). Instead, signal degradation is controlled at module load time via parameters:

```bash
# Load with a high probability of losing lock on a bad signal
sudo modprobe dvb_vidtv_bridge drop_tslock_prob_on_low_snr=90 recover_tslock_prob_on_good_snr=10

# Restrict valid frequencies to force a bad-signal scenario at other frequencies
sudo modprobe dvb_vidtv_bridge vidtv_valid_dvb_t_freqs=474000000 max_frequency_shift_hz=1000
```

To change behaviour, `rmmod dvb_vidtv_bridge` and reload with different parameters.

### Making vidtv load automatically in the test VM
Add a module load entry so the virtual adapter is always present after boot:

```
echo "dvb_vidtv_bridge" | sudo tee /etc/modules-load.d/vidtv.conf
```

### Workflow integration with A/B slots
The VM mirrors the Slot B testing philosophy: it is the first environment where Arch package updates, kernel upgrades, or dvbstreamer configuration changes are validated before being rsynced to the real machine's passive slot. The recommended order is:

1. Test change in vidtv VM → confirm DVB pipeline is healthy.
2. rsync to Slot B on the real machine and reboot into Slot B.
3. Validate with the physical tuner card on real RF.
4. Promote Slot B to active if all tests pass.

------------------------------
## Next Steps for the Architecture
Both slots should mount `/home` (SSD partition 4) and `/data` (HDD) via their `/etc/fstab` using `PARTUUID` references, so recordings, user config, and cached channel data are all preserved regardless of which boot slot is active.


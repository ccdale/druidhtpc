# druidhtpc

Automated Arch-based HTPC build workflow with A/B root slots, shared home/data layout, and VM-first validation.

## Repository layout

- `build-druidhtpc.sh`: host-side VM provisioning (libvirt/QEMU + SPICE + virtiofs shared work directory).
- `druidhtpc-arch-setup.sh`: guest-side installer script run from the Arch live environment.
- `druidhtpc-slot-update`: installed root helper that clones the active slot and updates the inactive slot.
- `backup-druidmedia.sh`: on-demand backup of the old media server's configuration and databases.
- `druidmedia-htpc-build.md`: end-to-end build/run workflow for host and guest.
- `druidmedia-physical-build.md`: USB preparation and physical media-server installation.
- [live-steps.md](live-steps.md): pickup checklist for staging the prepared USB and installing the physical PC.
- `druidhtpc-dvbstreamer-build.md`: clean Arch container/chroot package build instructions for `dvbstreamer-t2`.

## High-level workflow

1. Build `dvbstreamer-t2` in a clean Arch environment.
2. Stage the package in `work/packages/`.
3. Run `./build-druidhtpc.sh` on the host.
4. Boot the Arch ISO in the VM, mount `/work` via virtiofs.
5. Run `/work/druidhtpc/druidhtpc-arch-setup.sh` inside the VM.

## Notes

- The installer selects the physical OS and recording disks by size (240–275 GB and 480–550 GB respectively), or the configured VM disks by size. Verify the displayed disk identities and confirm before either disk is erased.
- The installer defaults to package staging at guest `/work/packages` (host `work/packages/`).
- The installer creates `chris` with UID 1000 and primary group `chris` with GID 1000, matching ownership in the Debian media-server backup. Conflicting existing IDs cause installation to stop rather than renumber accounts. Both root slots retain these IDs.
- The installer adds the `chris@stone` SSH public key to Chris's `authorized_keys`, installs OpenSSH, and enables `sshd` at boot.
- No default user password is set by automation; set one post-install with `arch-chroot /mnt passwd chris`.
- Both slots mount `192.168.50.96:/volume1/druidshare` at `/mnt/nas` on demand using NFSv3 and systemd automount. The installer includes `nfs-utils`; an unavailable NAS does not block boot. Accessing the share triggers the mount, and hard NFS mounts retry interrupted I/O rather than risking data corruption. Check it after boot with `ls /mnt/nas` and `findmnt /mnt/nas`.
- The installer registers the `ccapkgs` repository using its documented `Optional TrustAll` signature policy and installs `ccatv`. Publish the package and its dependencies to the repository before building; installation stops if they cannot be installed.

## Backing up the media server

When `druidmedia` is quiet, check there are no recordings, post-processing,
playback, or imminent scheduled recordings. Then, from this checkout:

```bash
ssh druidmedia 'bash -s -- --confirm-quiet' < ./backup-druidmedia.sh
```

The script runs as the SSH user on `druidmedia2` and requires its NAS export
at `/mnt/nas`. It refuses to proceed if ccatv reports an active recording or
job, or a scheduled job is due within two hours. It stops the ccatv user
services that were running, checks for remaining recording processes, and
stops Kodi if it was running. It restarts those services and Kodi on success
or failure. Kodi restart requires the graphical session's `DISPLAY` in the
user systemd manager. Check the reported errors if any restart fails.

The archive contains Kodi, DVBStreamer adapter databases, ccatv and DVBStreamer
configuration, comskip configuration, the ccatv database and its SQLite
sidecars, and the Schedules Direct token cache. It excludes recordings, old
user service units, helper scripts, and DVBStreamer logs. It checks SQLite
databases and verifies the archive and SHA-256 before publishing both under
`/mnt/nas/backups`. Backups are unencrypted and can contain credentials.
Do not let anyone start a recording during the backup; the check cannot
prevent external/manual recording activity. If the script or host is forcibly
terminated, check the services and Kodi manually.

## Restoring the media-server backup

Restore is disabled by default. To import the verified Debian backup during installation, run inside the live guest:

```bash
RESTORE_MEDIA_BACKUP=1 /work/druidhtpc/druidhtpc-arch-setup.sh
```

By default, the installer temporarily mounts the NAS read-only and verifies
`backups/druidmedia-2026-11-15-111810.tar.gz` against its `.sha256` file before
extracting directly into `/home/chris`, without copying the archive to local
disk. To choose a new backup, use the path printed by the backup script:

```bash
RESTORE_MEDIA_BACKUP=1 MEDIA_BACKUP=/mnt/nas/backups/druidmedia-REPLACE.tar.gz \
  /work/druidhtpc/druidhtpc-arch-setup.sh
```

The named archive must be directly under `/mnt/nas/backups`, with its
corresponding `.sha256` file. The temporary mount is removed on completion or
failure. Copy the updated installer to the USB work partition before using
this option on the physical machine.

It restores Kodi, DVBStreamer and comskip settings, ccatv config and SQLite database files, and the Schedules Direct token cache, preserving numeric ownership and permissions. Debian user service units and local helper scripts are omitted in favor of the Arch package. The archive contains credentials: opt in only on a trusted VM or the replacement server.

ccatv services remain disabled. Before starting them, review restored NAS/recording paths, tuner adapters, and API/web settings for the new host; importing config does not adapt them automatically. Avoid running the restored recording schedule alongside the old server. Once ready, from Chris's session:

```bash
systemctl --user enable --now ccatv.service ccatv-api.service ccatv-web.service
```

## Updating the inactive slot

From a booted Slot A or Slot B system, run:

```bash
sudo druidhtpc-slot-update
```

The command detects the active root, clones it to the inactive slot, corrects the cloned root UUID, runs `pacman -Syu` inside the inactive slot, and publishes that slot's kernel and initramfs to the shared ESP. Reboot and select the updated slot from the systemd-boot menu to test it. Additional arguments are passed to `pacman`, for example `sudo druidhtpc-slot-update --noconfirm`.

## License

GPL-3.0-or-later. See `LICENSE`.
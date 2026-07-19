# druidhtpc

Automated Arch-based HTPC build workflow with A/B root slots, shared home/data layout, and VM-first validation.

## Repository layout

- `build-druidhtpc.sh`: host-side VM provisioning (libvirt/QEMU + SPICE + virtiofs shared work directory).
- `druidhtpc-arch-setup.sh`: guest-side installer script run from the Arch live environment.
- `druidmedia-htpc-build.md`: end-to-end build/run workflow for host and guest.
- `druidhtpc-dvbstreamer-build.md`: clean Arch container/chroot package build instructions for `dvbstreamer-t2`.

## High-level workflow

1. Build `dvbstreamer-t2` in a clean Arch environment.
2. Stage the package in `work/packages/`.
3. Run `./build-druidhtpc.sh` on the host.
4. Boot the Arch ISO in the VM, mount `/work` via virtiofs.
5. Run `/work/druidhtpc/druidhtpc-arch-setup.sh` inside the VM.

## Notes

- The installer defaults to package staging at guest `/work/packages` (host `work/packages/`).
- No default user password is set by automation; set one post-install with `arch-chroot /mnt passwd chris`.

## License

GPL-3.0-or-later. See `LICENSE`.
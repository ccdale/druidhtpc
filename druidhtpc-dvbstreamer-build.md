# dvbstreamer-t2 build instructions

This note describes how to build a clean Arch package for `dvbstreamer-t2` on this Manjaro host without building it inside the HTPC installer VM.

The goal is:

1. Build `dvbstreamer-t2` in a real Arch userspace.
2. Copy the resulting `*.pkg.tar.zst` file into host `$HOME/src/druidhtpc/work/packages/`.
3. Let the installer copy that package into the target VM and install it with `pacman -U`.

## Why do it this way?

This avoids several problems:

- no AUR build logic inside the installer
- no `makepkg` privilege split inside the target VM
- no dependency on AUR/network availability during install
- easier reruns while iterating in GNOME Boxes or VirtualBox
- package is built in Arch rather than Manjaro

## Option 1: Build in an Arch container with Docker

Docker is already installed on this machine, so this is the simplest route.

### 1. Create a host working directory

```bash
mkdir -p ~/build/dvbstreamer-t2
cd ~/build/dvbstreamer-t2
```

### 2. Start an Arch container

```bash
docker run --rm -it \
  -v "$PWD:/work" \
  archlinux:latest bash
```

This gives you a clean Arch environment with your host directory mounted at `/work`.

Important: do not `chown` `/work` inside the container. It is a bind mount of your host directory, so ownership changes in the container are applied to the host filesystem using raw numeric UID/GID values.

### 3. Prepare the Arch container

Inside the container:

```bash
pacman -Syu --noconfirm
pacman -S --noconfirm base-devel git
mkdir -p /work/build
groupadd -g 1002 buildergrp
useradd -m -u 1001 -g 1002 builder
```

The `1001:1002` values above match the host `chris` user shown by `id` on this machine. If your host UID/GID differ, adjust them before creating the user.

### 4. Clone the AUR repo and install dependencies as root

Still inside the container:

```bash
cd /work/build
git clone https://aur.archlinux.org/dvbstreamer-t2.git
cd dvbstreamer-t2

# Inspect PKGBUILD arrays if you want to see exactly what will be installed
source PKGBUILD
printf '%s\n' "${depends[@]}" "${makedepends[@]}"

# Install build-time and runtime dependencies from the official Arch repos
pacman -S --needed --noconfirm "${depends[@]}" "${makedepends[@]}"
```

### 5. Build the package as a normal user

Still inside the container:

```bash
su - builder
cd /work/build/dvbstreamer-t2
makepkg
exit
```

The built package should appear on the host under:

```bash
~/build/dvbstreamer-t2/build/dvbstreamer-t2/
```

You are looking for a file like:

```bash
dvbstreamer-t2-<version>-x86_64.pkg.tar.zst
```

### 5. Copy the package into this repo

Back on the host:

```bash
mkdir -p /home/chris/src/druidhtpc/work/packages
cp ~/build/dvbstreamer-t2/build/dvbstreamer-t2/dvbstreamer-t2-[0-9]*-x86_64.pkg.tar.zst /home/chris/src/druidhtpc/work/packages/
```

Only copy the main package. Do not copy the `dvbstreamer-t2-debug-...` package into the staging directory.

### 6. Run the HTPC installer

The installer now expects exactly one staged package in guest `/work/packages/` (host `$HOME/src/druidhtpc/work/packages/`).

```bash
cd /home/chris/src/druidhtpc
sudo ./druidhtpc-arch-setup.sh
```

If you want to use a different staging directory, set `PACKAGE_STAGING_DIR` before running the script:

```bash
PACKAGE_STAGING_DIR=/some/other/path sudo ./druidhtpc-arch-setup.sh
```

## Option 2: Build in an Arch container with Podman

If you prefer Podman, the workflow is almost identical:

```bash
mkdir -p ~/build/dvbstreamer-t2
cd ~/build/dvbstreamer-t2

podman run --rm -it \
  -v "$PWD:/work" \
  docker.io/library/archlinux:latest bash
```

Then run the same commands inside the container:

```bash
pacman -Syu --noconfirm
pacman -S --noconfirm base-devel git
mkdir -p /work/build
groupadd -g 1002 buildergrp
useradd -m -u 1001 -g 1002 builder
cd /work/build
git clone https://aur.archlinux.org/dvbstreamer-t2.git
cd dvbstreamer-t2
source PKGBUILD
pacman -S --needed --noconfirm "${depends[@]}" "${makedepends[@]}"
su - builder
cd /work/build/dvbstreamer-t2
makepkg
exit
```

After that, copy the resulting package into:

```bash
/home/chris/src/druidhtpc/work/packages/
```

## Option 3: Manual Arch chroot/bootstrap root

If you want a persistent Arch build root instead of a container, use an Arch bootstrap tarball.

### 1. Download and extract the bootstrap tarball

```bash
mkdir -p ~/arch-bootstrap
cd ~/arch-bootstrap
curl -LO https://geo.mirror.pkgbuild.com/iso/latest/archlinux-bootstrap-x86_64.tar.zst
tar --zstd -xvf archlinux-bootstrap-x86_64.tar.zst
```

This creates a directory like `root.x86_64`.

### 2. Move it into a stable location and enter it

```bash
sudo mv root.x86_64 /var/lib/archbuild-root
sudo arch-chroot /var/lib/archbuild-root
```

### 3. Initialize the Arch environment

Inside the chroot:

```bash
pacman-key --init
pacman-key --populate archlinux
pacman -Syu --noconfirm
pacman -S --noconfirm base-devel git
groupadd -g 1002 buildergrp
useradd -m -u 1001 -g 1002 builder
```

Again, adjust `1001:1002` if your host user has different IDs.

### 4. Build the package

Inside the chroot:

```bash
mkdir -p /root/build
cd /root/build
git clone https://aur.archlinux.org/dvbstreamer-t2.git
cd dvbstreamer-t2
source PKGBUILD
pacman -S --needed --noconfirm "${depends[@]}" "${makedepends[@]}"
su - builder
cd /root/build/dvbstreamer-t2
makepkg
exit
```

### 5. Copy the package out to the repo staging directory

From another host shell, or after leaving the chroot:

```bash
sudo mkdir -p /home/chris/src/druidhtpc/work/packages
sudo cp /var/lib/archbuild-root/root/build/dvbstreamer-t2/dvbstreamer-t2-[0-9]*-x86_64.pkg.tar.zst /home/chris/src/druidhtpc/work/packages/
sudo chown chris:chris /home/chris/src/druidhtpc/work/packages/dvbstreamer-t2-[0-9]*-x86_64.pkg.tar.zst
```

## Updating the package later

When you want a newer build:

1. Delete the old `dvbstreamer-t2-*.pkg.tar.*` from `$HOME/src/druidhtpc/work/packages/`.
2. Rebuild in the Arch container or chroot.
3. Copy in the new package.
4. Re-run the installer or install manually inside a VM with `pacman -U`.

## Verifying what the installer expects

The installer looks for exactly one matching file:

```bash
$HOME/src/druidhtpc/work/packages/dvbstreamer-t2-[0-9]*-*.pkg.tar.*
```

If there are zero matches or more than one match, the installer exits with a clear error. In particular, do not stage the `dvbstreamer-t2-debug-...` package.

## Manual install into an existing VM

If you already have a VM installed and just want to test the package manually:

1. Copy the package into the VM using `scp`, a shared folder, or a temporary web server.
2. Install it in the guest:

```bash
sudo pacman -U /path/to/dvbstreamer-t2-<version>-x86_64.pkg.tar.zst
```

## Recommended workflow for this project

For this HTPC project, the most practical loop is:

1. Build `dvbstreamer-t2` in an Arch container on the host.
2. Copy the package into `$HOME/src/druidhtpc/work/packages/`.
3. Rebuild test VMs in GNOME Boxes as needed.
4. Use the same package artifact for repeated installer runs until you intentionally update it.

That keeps the VM installer deterministic and moves package-building complexity into a controlled Arch environment.

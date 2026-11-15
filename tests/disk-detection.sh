#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
cleanup() {
  rm -f -- "${tmp}/bin/lsblk" "${tmp}/bin/systemd-detect-virt" \
    "${tmp}/bin/blkdiscard" "${tmp}/bin/sfdisk" "${tmp}/destructive" "${tmp}/output"
  rmdir -- "${tmp}/bin" "${tmp}"
}
trap cleanup EXIT
mkdir -p "${tmp}/bin"

cat > "${tmp}/bin/lsblk" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *PATH,SIZE,TYPE,RM,RO,TRAN*)
    if [[ "${FAIL_LIST:-0}" == 1 ]]; then exit 1; fi
    printf '%s\n' "${DISKS}";;
  *MOUNTPOINTS*)
    if [[ "${FAIL_MOUNTS:-0}" == 1 ]]; then exit 1; fi
    if [[ "${*: -1}" == "${MOUNTED_DISK:-}" ]]; then echo /work; fi;;
  *) echo "Mock disk details";;
esac
EOF
cat > "${tmp}/bin/systemd-detect-virt" <<'EOF'
#!/usr/bin/env bash
[[ "${IS_VM:-0}" == 1 ]]
EOF
cat > "${tmp}/bin/blkdiscard" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${DESTRUCTIVE_LOG}"
EOF
cat > "${tmp}/bin/sfdisk" <<'EOF'
#!/usr/bin/env bash
exit 77
EOF
chmod +x "${tmp}/bin/"*
export PATH="${tmp}/bin:${PATH}" DESTRUCTIVE_LOG="${tmp}/destructive"
export IS_VM=0 MOUNTED_DISK= FAIL_MOUNTS=0 FAIL_LIST=0

run_case() {
  local name="$1" input="$2" expected_status="$3" expected_text="$4" destructive="$5"
  local status=0
  : > "${DESTRUCTIVE_LOG}"
  printf '%s\n' "${input}" | bash "${repo}/druidhtpc-arch-setup.sh" > "${tmp}/output" 2>&1 || status=$?
  if [[ "${status}" != "${expected_status}" ]] ||
     ! grep -qF -- "${expected_text}" "${tmp}/output" ||
     { [[ "${destructive}" == yes ]] && [[ ! -s "${DESTRUCTIVE_LOG}" ]]; } ||
     { [[ "${destructive}" == no ]] && [[ -s "${DESTRUCTIVE_LOG}" ]]; }; then
    echo "FAIL: ${name} (status ${status})" >&2
    cat "${tmp}/output" >&2
    exit 1
  fi
  echo "PASS: ${name}"
}

physical=$'/dev/sda 500107862016 disk 0 0 sata\n/dev/nvme0n1 250059350016 disk 0 0 nvme\n/dev/sdb 250059350016 disk 1 0 usb'
export DISKS="${physical}"
run_case "physical disk order and USB exclusion" ERASE 77 'OS disk: /dev/nvme0n1' yes
grep -qF -- '-f /dev/nvme0n1' "${DESTRUCTIVE_LOG}"
grep -qF 'Recording disk: /dev/sda' "${tmp}/output"
run_case "explicit confirmation required" no 1 'Confirmation not given' no
export FAIL_LIST=1
run_case "disk enumeration failure rejected" ERASE 1 'Unable to enumerate disks' no
export FAIL_LIST=0

export DISKS="${physical}"$'\n/dev/sdc 256000000000 disk 0 0 sata'
run_case "ambiguous OS disks" ERASE 1 'Could not uniquely identify' no
export DISKS="${physical}"$'\n/dev/sdc 500000000000 disk 0 0 sata'
run_case "ambiguous recording disks" ERASE 1 'Could not uniquely identify' no
export DISKS=$'/dev/sda 500107862016 disk 0 0 sata\n/dev/sdb 250059350016 disk 0 0 usb'
run_case "USB cannot be selected" ERASE 1 'Could not uniquely identify' no

export DISKS="${physical}" MOUNTED_DISK=/dev/nvme0n1
run_case "mounted disk rejected" ERASE 1 'is mounted' no
export MOUNTED_DISK= FAIL_MOUNTS=1
run_case "mount inspection failure rejected" ERASE 1 'Unable to check mounts' no
export FAIL_MOUNTS=0

export DISKS=$'/dev/sdb 68719476736 disk 0 0 sata\n/dev/sda 42949672960 disk 0 0 sata' IS_VM=1
run_case "VM disks detected by size" ERASE 77 'OS disk: /dev/sdb' yes
export IS_VM=0
run_case "VM sizes rejected on physical host" ERASE 1 'Could not uniquely identify' no
export IS_VM=1 DISKS="${DISKS}"$'\n/dev/sdc 250059350016 disk 0 0 sata'
run_case "partial physical match cannot fall back to VM disks" ERASE 1 'Could not uniquely identify' no

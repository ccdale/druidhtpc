#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" != --confirm-quiet || $# != 1 ]]; then
  echo "Usage: ssh druidmedia 'bash -s -- --confirm-quiet' < backup-druidmedia.sh" >&2
  echo "Confirm there is no recording or playback and no imminent scheduled recording first." >&2
  exit 2
fi

backup_dir="${BACKUP_DIR:-/mnt/nas/backups}"
database="${HOME}/.local/share/ccatv/ccatv.sqlite3"
uid="$(id -u)"
units=(ccatv.service ccatv-api.service ccatv-web.service)
active_units=()
stopped_units=()
kodi_was_stopped=0
staging_dir=""
published_archive=""
published_checksum=""
complete=0

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

process_running() {
  local status=0
  pgrep -u "${uid}" -x "$1" >/dev/null || status=$?
  case "${status}" in
    0) return 0 ;;
    1) return 1 ;;
    *) fail "Cannot inspect process $1 (pgrep exit ${status})." ;;
  esac
}

cleanup() {
  local status=$? i restart_failed=0 kodi_status=0
  trap - EXIT INT TERM
  set +e
  if (( ! complete )); then
    [[ -z "${published_checksum}" ]] || rm -f -- "${published_checksum}" || status=1
    [[ -z "${published_archive}" ]] || rm -f -- "${published_archive}" || status=1
  fi
  if [[ -n "${staging_dir}" ]]; then
    rm -f -- "${staging_dir}/backup.tar.gz" "${staging_dir}/backup.sha256" || status=1
    rmdir -- "${staging_dir}" || status=1
  fi
  for ((i=${#stopped_units[@]}-1; i>=0; i--)); do
    if ! systemctl --user start "${stopped_units[i]}"; then
      echo "ERROR: Could not restart ${stopped_units[i]}." >&2
      restart_failed=1
    fi
  done
  if (( kodi_was_stopped )); then
    pgrep -u "${uid}" -x kodi.bin >/dev/null || kodi_status=$?
    if (( kodi_status > 1 )); then
      echo "ERROR: Could not inspect Kodi; check and restart it manually." >&2
      restart_failed=1
    elif (( kodi_status == 1 )) && ! systemd-run --user --collect --unit="druidmedia-backup-kodi-$$" /usr/bin/kodi; then
      echo "ERROR: Could not restart Kodi." >&2
      restart_failed=1
    elif (( kodi_status == 1 )); then
      local ready=0
      for ((i=0; i<30; i++)); do
        kodi_status=0
        pgrep -u "${uid}" -x kodi.bin >/dev/null || kodi_status=$?
        if (( kodi_status == 0 )); then ready=1; break; fi
        if (( kodi_status > 1 )); then break; fi
        sleep 1
      done
      if (( ! ready )); then
        echo "ERROR: Kodi did not start; reopen it from the desktop." >&2
        restart_failed=1
      fi
    fi
  fi
  if (( restart_failed )); then status=1; fi
  if (( complete )); then
    echo "Backup archive: ${archive}"
    echo "Restore with RESTORE_MEDIA_BACKUP=1 MEDIA_BACKUP=${archive}"
  fi
  exit "${status}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

[[ "$(hostname -s)" == druidmedia2 ]] || fail "This script must run on druidmedia2."
[[ "${uid}" == 1000 ]] || fail "Run as the original chris user (UID 1000), not root."
[[ -d "${backup_dir}" ]] || fail "Backup directory does not exist: ${backup_dir}"
mount_info="$(findmnt -rn -T "${backup_dir}" -o SOURCE,FSTYPE)" ||
  fail "Cannot inspect the backup directory mount."
read -r nas_source nas_type <<< "${mount_info}"
[[ "${nas_source}" == 192.168.50.96:/volume1/druidshare && "${nas_type}" == nfs* ]] ||
  fail "Backup directory is not on the expected NAS NFS export."

for path in .kodi .dvbstreamer .config/ccatv .config/dvbstreamer .config/comskip \
  .local/share/ccatv/ccatv.sqlite3 .local/state/ccatv/schedules_direct_token_cache.json; do
  [[ -e "${HOME}/${path}" ]] || fail "Required source is missing: ${HOME}/${path}"
done
shopt -s nullglob
adapter_files=("${HOME}"/.dvbstreamer/adapter*.db)
(( ${#adapter_files[@]} > 0 )) || fail "No DVBStreamer adapter databases found."

for unit in "${units[@]}"; do
  state="$(systemctl --user show "${unit}" --property=ActiveState --value)" ||
    fail "Cannot inspect ${unit}."
  case "${state}" in
    active) active_units+=("${unit}") ;;
    inactive|failed) ;;
    *) fail "${unit} is in unexpected state: ${state}" ;;
  esac
done

check_recordings() {
  local counts
  counts="$(sqlite3 -readonly "${database}" \
    "SELECT (SELECT count(*) FROM recordings WHERE lower(state) IN ('recording','running','post_processing')) + (SELECT count(*) FROM scheduler_jobs WHERE lower(state) = 'running'), (SELECT count(*) FROM scheduler_jobs WHERE lower(state) = 'scheduled' AND (datetime(start_at_utc) IS NULL OR datetime(start_at_utc) <= datetime('now','+2 hours')));")" ||
    fail "Cannot inspect ccatv recording and schedule state."
  [[ "${counts}" == '0|0' ]] ||
    fail "An active recording/job or a recording due within two hours was found (${counts})."
}

check_recordings
if process_running kodi.bin; then
  [[ "$(systemctl --user show-environment | grep -c '^DISPLAY=')" == 1 ]] ||
    fail "Cannot restart Kodi: the user service manager has no DISPLAY."
fi

echo "Stopping active ccatv services and Kodi for a consistent backup."
for unit in ccatv-web.service ccatv-api.service; do
  for active in "${active_units[@]}"; do
    if [[ "${unit}" == "${active}" ]]; then
      stopped_units+=("${unit}")
      systemctl --user stop "${unit}" || fail "Could not stop ${unit}."
    fi
  done
done
check_recordings
for active in "${active_units[@]}"; do
  if [[ "${active}" == ccatv.service ]]; then
    stopped_units+=("${active}")
    systemctl --user stop "${active}" || fail "Could not stop ${active}."
  fi
done

for process in ccatv-service ccatv-web dvbstreamer ffmpeg comskip; do
  if process_running "${process}"; then
    fail "${process} is still running; refusing to back up live data."
  fi
done
check_recordings

if process_running kodi.bin; then
  mapfile -t kodi_pids < <(pgrep -u "${uid}" -x kodi.bin)
  (( ${#kodi_pids[@]} == 1 )) || fail "Expected exactly one Kodi process."
  kodi_was_stopped=1
  kill -TERM "${kodi_pids[0]}" || fail "Could not request Kodi shutdown."
  for ((i=0; i<30; i++)); do
    if ! process_running kodi.bin; then break; fi
    sleep 1
  done
  if process_running kodi.bin; then fail "Kodi did not stop within 30 seconds."; fi
fi

for db in "${database}" "${adapter_files[@]}" "${HOME}"/.kodi/userdata/Database/*.db; do
  result="$(sqlite3 -readonly "${db}" 'PRAGMA quick_check;')" ||
    fail "Could not check database: ${db}"
  [[ "${result}" == ok ]] || fail "Database integrity check failed: ${db}: ${result}"
done

staging_dir="$(mktemp -d "${backup_dir}/.druidmedia-pending.XXXXXXXX")"
archive="${backup_dir}/druidmedia-$(date +%Y-%m-%d-%H%M%S)-${staging_dir##*.}.tar.gz"
[[ ! -e "${archive}" && ! -e "${archive}.sha256" ]] || fail "Backup destination already exists."

cd "${HOME}"
adapter_paths=()
for file in "${adapter_files[@]}"; do
  adapter_paths+=("${file#${HOME}/}")
  for sidecar in "${file}-wal" "${file}-shm" "${file}-journal"; do
    [[ ! -e "${sidecar}" ]] || adapter_paths+=("${sidecar#${HOME}/}")
  done
done
ccatv_files=(.local/share/ccatv/ccatv.sqlite3*)
tar --create --gzip --file="${staging_dir}/backup.tar.gz" --numeric-owner \
  --no-recursion .dvbstreamer --recursion \
  .kodi .config/ccatv .config/dvbstreamer .config/comskip \
  "${adapter_paths[@]}" "${ccatv_files[@]}" .local/state/ccatv/schedules_direct_token_cache.json
tar --list --gzip --file="${staging_dir}/backup.tar.gz" >/dev/null
digest="$(sha256sum "${staging_dir}/backup.tar.gz")"
digest="${digest%% *}"
printf '%s  %s\n' "${digest}" "${archive}" > "${staging_dir}/backup.sha256"
printf '%s  %s\n' "${digest}" "${staging_dir}/backup.tar.gz" | sha256sum --check --strict -

ln -- "${staging_dir}/backup.tar.gz" "${archive}"
published_archive="${archive}"
ln -- "${staging_dir}/backup.sha256" "${archive}.sha256"
published_checksum="${archive}.sha256"
complete=1

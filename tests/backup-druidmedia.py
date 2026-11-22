#!/usr/bin/env python3
import hashlib
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import tarfile
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "backup-druidmedia.sh"


class BackupTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.home = root / "home"
        self.dest = root / "backup"
        self.bin = root / "bin"
        for path in (
            self.home / ".kodi/userdata/Database",
            self.home / ".dvbstreamer",
            self.home / ".config/ccatv",
            self.home / ".config/dvbstreamer",
            self.home / ".config/comskip",
            self.home / ".local/share/ccatv/recordings",
            self.home / ".local/state/ccatv",
            self.dest,
            self.bin,
        ):
            path.mkdir(parents=True, exist_ok=True)
        self.db = self.home / ".local/share/ccatv/ccatv.sqlite3"
        with sqlite3.connect(self.db) as db:
            db.executescript(
                "CREATE TABLE recordings (state TEXT);"
                "CREATE TABLE scheduler_jobs (state TEXT, start_at_utc TEXT);"
            )
        for db in (
            self.home / ".dvbstreamer/adapter0.db",
            self.home / ".kodi/userdata/Database/MyVideos.db",
        ):
            with sqlite3.connect(db) as connection:
                connection.execute("CREATE TABLE sample (value TEXT)")
        (self.home / ".dvbstreamer/debug.log").write_text("excluded")
        (self.home / ".dvbstreamer").chmod(0o700)
        (self.home / ".local/share/ccatv/recordings/video.ts").write_text("excluded")
        (self.home / ".local/state/ccatv/schedules_direct_token_cache.json").write_text("{}")
        (self.home / ".config/ccatv/settings").write_text("test")
        self.log = root / "services.log"
        commands = {
            "hostname": "echo druidmedia2",
            "id": "echo 1000",
            "findmnt": 'echo "192.168.50.96:/volume1/druidshare nfs"',
            "pgrep": (
                'if [ "$4" = kodi.bin ] && [ -e "$KODI_STATE" ]; then echo 12345; '
                'else exit 1; fi'
            ),
            "systemctl": (
                'echo "$*" >> "$TEST_LOG"\n'
                'case "$2" in show) echo active ;; show-environment) echo DISPLAY=:0 ;; '
                'stop) if [ "${FAIL_STOP:-}" = "$3" ]; then exit 1; fi; '
                'if [ "${RACE_RECORDING:-}" = 1 ] && [ "$3" = ccatv-api.service ]; then '
                'sqlite3 "$HOME/.local/share/ccatv/ccatv.sqlite3" '
                '"INSERT INTO recordings VALUES (\'recording\')"; fi ;; '
                'start) if [ "${FAIL_START:-}" = "$3" ]; then exit 1; fi ;; esac'
            ),
            "systemd-run": 'echo "restart kodi" >> "$TEST_LOG"; touch "$KODI_STATE"',
            "tar": f'if [ "${{FAIL_TAR:-}}" = 1 ]; then echo "tar failed" >&2; exit 1; fi\n'
            f'exec "{shutil.which("tar")}" "$@"',
            "ln": f'if [ "${{FAIL_SECOND_LINK:-}}" = 1 ] && [ -e "$LINK_STATE" ]; then '
            'echo "link failed" >&2; exit 1; fi\n'
            f'touch "$LINK_STATE"; exec "{shutil.which("ln")}" "$@"',
        }
        for name, body in commands.items():
            path = self.bin / name
            path.write_text("#!/bin/sh\n" + body + "\n")
            path.chmod(0o755)
        self.env = os.environ | {
            "HOME": str(self.home),
            "BACKUP_DIR": str(self.dest),
            "TEST_LOG": str(self.log),
            "KODI_STATE": str(root / "kodi-running"),
            "LINK_STATE": str(root / "link-created"),
            "PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
        }
        bash_env = root / "bash-env"
        bash_env.write_text(
            'kill() { echo "stop kodi" >> "$TEST_LOG"; rm "$KODI_STATE"; }\n'
        )
        self.env["BASH_ENV"] = str(bash_env)

    def run_backup(self, *args, **env):
        return subprocess.run(
            ["bash", str(SCRIPT), *args],
            env=self.env | env,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_explicit_confirmation_required(self):
        result = self.run_backup()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.log.exists())
        self.assertEqual(list(self.dest.iterdir()), [])

    def test_active_or_imminent_recording_prevents_stops(self):
        for sql in (
            "INSERT INTO recordings VALUES ('recording')",
            "INSERT INTO scheduler_jobs VALUES ('scheduled', datetime('now', '+1 hour'))",
        ):
            with self.subTest(sql=sql), sqlite3.connect(self.db) as db:
                db.execute("DELETE FROM recordings")
                db.execute("DELETE FROM scheduler_jobs")
                db.execute(sql)
                db.commit()
                result = self.run_backup("--confirm-quiet")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("active recording/job", result.stderr)
                self.assertNotIn(" stop ", self.log.read_text())
                self.assertEqual(list(self.dest.iterdir()), [])

    def test_backup_contents_checksum_and_restart_order(self):
        result = self.run_backup("--confirm-quiet")
        self.assertEqual(result.returncode, 0, result.stderr)
        archives = list(self.dest.glob("*.tar.gz"))
        self.assertEqual(len(archives), 1)
        archive = archives[0]
        digest, filename = Path(str(archive) + ".sha256").read_text().strip().split("  ")
        self.assertEqual(filename, str(archive))
        self.assertEqual(digest, hashlib.sha256(archive.read_bytes()).hexdigest())
        with tarfile.open(archive, "r:gz") as tar:
            names = set(tar.getnames())
            self.assertEqual(tar.getmember(".dvbstreamer").mode, 0o700)
        self.assertIn(".dvbstreamer/adapter0.db", names)
        self.assertIn(".kodi/userdata/Database/MyVideos.db", names)
        self.assertIn(".local/share/ccatv/ccatv.sqlite3", names)
        self.assertIn(".local/state/ccatv/schedules_direct_token_cache.json", names)
        self.assertNotIn(".dvbstreamer/debug.log", names)
        self.assertNotIn(".local/share/ccatv/recordings/video.ts", names)
        extraction = Path(self.tmp.name) / "restored"
        extraction.mkdir()
        subprocess.run(
            [
                "tar", "--extract", "--gzip", f"--file={archive}",
                f"--directory={extraction}", "--wildcards", "--anchored", "--",
                ".kodi", ".dvbstreamer", ".config/ccatv", ".config/dvbstreamer",
                ".config/comskip", ".local/share/ccatv/ccatv.sqlite3*",
                ".local/state/ccatv/schedules_direct_token_cache.json",
            ],
            check=True,
        )
        self.assertTrue((extraction / ".dvbstreamer/adapter0.db").is_file())
        self.assertTrue((extraction / ".kodi/userdata/Database/MyVideos.db").is_file())
        actions = [line for line in self.log.read_text().splitlines() if " show " not in line]
        self.assertEqual(actions, [
            "--user stop ccatv-web.service",
            "--user stop ccatv-api.service",
            "--user stop ccatv.service",
            "--user start ccatv.service",
            "--user start ccatv-api.service",
            "--user start ccatv-web.service",
        ])
        self.assertEqual(len(list(self.dest.iterdir())), 2)

    def test_stop_failure_restarts_previously_active_services(self):
        result = self.run_backup("--confirm-quiet", FAIL_STOP="ccatv-api.service")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Could not stop ccatv-api.service", result.stderr)
        self.assertIn("--user start ccatv-api.service", self.log.read_text())
        self.assertIn("--user start ccatv-web.service", self.log.read_text())
        self.assertNotIn("--user stop ccatv.service", self.log.read_text())
        self.assertEqual(list(self.dest.iterdir()), [])

    def test_recording_started_during_api_shutdown_aborts(self):
        result = self.run_backup("--confirm-quiet", RACE_RECORDING="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("active recording/job", result.stderr)
        self.assertNotIn("--user stop ccatv.service", self.log.read_text())
        self.assertIn("--user start ccatv-api.service", self.log.read_text())
        self.assertEqual(list(self.dest.iterdir()), [])

    def test_archive_failure_restarts_services_and_kodi(self):
        Path(self.env["KODI_STATE"]).touch()
        result = self.run_backup("--confirm-quiet", FAIL_TAR="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("tar failed", result.stderr)
        self.assertIn("stop kodi", self.log.read_text())
        self.assertIn("restart kodi", self.log.read_text())
        self.assertIn("--user start ccatv.service", self.log.read_text())
        self.assertTrue(Path(self.env["KODI_STATE"]).exists())
        self.assertEqual(list(self.dest.iterdir()), [])

    def test_checksum_publish_failure_removes_partial_archive(self):
        result = self.run_backup("--confirm-quiet", FAIL_SECOND_LINK="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("link failed", result.stderr)
        self.assertIn("--user start ccatv.service", self.log.read_text())
        self.assertEqual(list(self.dest.iterdir()), [])

    def test_restart_failure_reports_error_and_preserves_backup(self):
        result = self.run_backup("--confirm-quiet", FAIL_START="ccatv-api.service")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Could not restart ccatv-api.service", result.stderr)
        self.assertIn("Backup archive:", result.stdout)
        self.assertEqual(len(list(self.dest.glob("*.tar.gz"))), 1)


if __name__ == "__main__":
    unittest.main()

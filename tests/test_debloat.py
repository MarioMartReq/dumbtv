"""Run package safety checks against fake ADB, never a television."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


def entries(path):
    return [line.split("#", 1)[0].strip() for line in path.read_text().splitlines()
            if line.split("#", 1)[0].strip()]


class DebloatTests(unittest.TestCase):
    def run_debloat(self, config, installed, *, dry_run=True, overrides=None):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            scripts = repo / "scripts"
            scripts.mkdir()
            for name in ("debloat.sh", "lib.sh"):
                shutil.copy2(ROOT / "scripts" / name, scripts / name)
            shutil.copytree(ROOT / "data", repo / "data")
            (repo / "dumbtv.conf").write_text(config)
            packages = set(installed)
            for name in ("packages.txt", "user-apps.txt"):
                packages.update(entries(repo / "data/fireos" / name))
            replies = {
                "getprop ro.build.version.sdk": {"out": "30"},
                "getprop ro.product.manufacturer": {"out": "Amazon"},
                "cmd package help": {"out": "install-existing"},
                "ps -A -o NAME": {"out": ""},
                "reboot": {"out": ""},
                "getprop sys.boot_completed": {"out": "1"},
                "dumpsys activity activities": {"out": ""},
            }
            for package in packages:
                replies[f"pm path {package}"] = {
                    "out": "package:/example/base.apk" if package in installed else "",
                    "code": 0 if package in installed else 1,
                }
            for setting in entries(repo / "data/fireos/settings.txt"):
                replies[f"settings put {setting}"] = {"out": ""}
            replies.update(overrides or {})
            responses, log = repo / "responses.json", repo / "calls.jsonl"
            responses.write_text(json.dumps(replies))
            sleep = repo / "sleep"
            sleep.write_text("#!/bin/sh\nexit 0\n")
            sleep.chmod(0o755)
            env = dict(os.environ, ADB=str(ROOT / "tests/fake_verify_adb.py"),
                       SERIAL="test-tv", CONF=str(repo / "dumbtv.conf"),
                       PATH=str(repo) + os.pathsep + os.environ["PATH"],
                       FAKE_ADB_RESPONSES=str(responses), FAKE_ADB_LOG=str(log))
            result = subprocess.run(
                ["bash", str(scripts / "debloat.sh"), "--dry-run" if dry_run else "-y"],
                env=env, capture_output=True, text=True, timeout=15,
            )
            calls = [" ".join(json.loads(line)[3:]) for line in log.read_text().splitlines()]
            self.assertNotIn("unexpected command", result.stdout + result.stderr)
            return result, calls

    def test_prime_video_protected_even_in_extra_removals(self):
        result, _ = self.run_debloat('REMOVE_EXTRA="com.amazon.firebat"\n',
                                     {"com.amazon.firebat"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertRegex(result.stdout + result.stderr,
                         r"com\.amazon\.firebat\s+SKIP \(never-disable list\)")

    def test_keep_installed_app_outside_removal_lists(self):
        result, _ = self.run_debloat('KEEP_APPS="com.netflix.ninja"\n',
                                     {"com.netflix.ninja"})
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_unknown_keep_entry_stops_before_package_changes(self):
        result, calls = self.run_debloat('KEEP_APPS="example.misspelled"\n',
                                         set(), overrides={
            "pm path example.misspelled": {"out": "", "code": 1},
        })
        self.assertEqual(result.returncode, 1)
        self.assertIn("typo?", result.stderr)
        self.assertFalse(any(command.startswith("pm uninstall") for command in calls))

    def test_unexpected_disable_failure_stops_before_next_package_and_reboot(self):
        first, following = "com.amazon.ceviche", "com.amazon.katoch"
        result, calls = self.run_debloat("", {first, following}, dry_run=False, overrides={
            f"pm uninstall -k --user 0 {first}": {"out": "Failure"},
            f"pm disable-user --user 0 {first}": {"out": "Unexpected failure"},
            f"pm uninstall -k --user 0 {following}": {"out": "Success"},
        })
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("SUSPECT", result.stdout)
        self.assertNotIn(f"pm uninstall -k --user 0 {following}", calls)
        self.assertNotIn("reboot", calls)


if __name__ == "__main__":
    unittest.main()

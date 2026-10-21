"""Exercise reboot detection without a device or real sleeps."""
import os
from pathlib import Path
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]


class RebootTests(unittest.TestCase):
    def test_boot_status_with_legacy_and_modern_line_endings(self):
        for reply, booted in [("1\r\n", True), ("1\n", True), ("0\r\n", False)]:
            with self.subTest(reply=reply):
                result = subprocess.run(
                    ["bash", "-c", '''
source "$1"
dev() {
  case "$*" in
    reboot) ;;
    'getprop sys.boot_completed') printf '%s' "$BOOT_REPLY" ;;
    *) return 1 ;;
  esac
}
sleep() { :; }
reboot_wait
''', "test", str(ROOT / "scripts/lib.sh")],
                    env=dict(os.environ, ADB="true", SERIAL="test-tv", BOOT_REPLY=reply),
                    capture_output=True, text=True, timeout=5,
                )
                self.assertEqual(result.returncode, 0 if booted else 1, result.stderr)
                if booted:
                    self.assertIn("booted", result.stderr)
                else:
                    self.assertIn("did not report boot_completed", result.stderr)


if __name__ == "__main__":
    unittest.main()

"""Exercise the real script and plist with fake VPN, Keychain and launchctl.

Run: python3 -m unittest discover -s tests -v
No real credentials, routes, VPN sessions or launchd jobs are accessed.
"""

import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest


FAKE_COMMAND = r'''#!/usr/bin/python3
import json
import os
from pathlib import Path
import plistlib
import sys

root = Path(os.environ["VPN_TEST_ROOT"])
state_path = root / "state.json"
state = json.loads(state_path.read_text())
name = Path(sys.argv[0]).name
args = sys.argv[1:]
code = 0
event = None

if name == "security":
    event = "keychain"
    if state.get("keychain_failures", 0):
        state["keychain_failures"] -= 1
        code = 1
    else:
        print("fake-password")
elif name == "token":
    state["tokens"] = state.get("tokens", 0) + 1
    event = "otp"
    print("fake-otp-" + str(state["tokens"]))
elif name == "sleep":
    event = "sleep:" + args[0]
elif name == "sudo":
    event = "UNEXPECTED_SUDO"
    code = 99
elif name == "vpn":
    if args == ["status"]:
        print("state: " + state.get("vpn", "Disconnected"))
    elif args == ["disconnect"]:
        event = "disconnect"
        state["vpn"] = "Disconnected"
    elif args == ["-s"]:
        event = "connect"
        credentials = sys.stdin.read().splitlines()
        if not credentials[2].startswith("fake-password,fake-otp-"):
            raise RuntimeError("Unexpected test credentials")
        if state.get("reject_attempts", 0):
            state["reject_attempts"] -= 1
            state["vpn"] = "Disconnected"
            code = 1
        else:
            state["vpn"] = "Connected"
elif name == "launchctl":
    if args[0] == "print":
        code = 0 if state.get("loaded") else 113
    elif args[0] == "bootout":
        event = "unschedule"
        if state.get("bootout_failure"):
            code = 1
        else:
            state["loaded"] = False
    elif args[0] == "bootstrap":
        event = "schedule"
        with open(args[2], "rb") as source:
            state["plist"] = plistlib.load(source)
        if state.get("bootstrap_failure"):
            code = 1
        else:
            assert not state.get("loaded"), "Duplicate job"
            state["loaded"] = True

if event:
    state.setdefault("events", []).append(event)
state_path.write_text(json.dumps(state))
sys.exit(code)
'''


class ReconnectTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="vpn-reconnect-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for command in ("security", "token", "vpn", "launchctl", "sleep", "sudo"):
            path = self.bin / command
            path.write_text(FAKE_COMMAND)
            path.chmod(0o700)

        original = Path(__file__).resolve().parents[1] / "vpn-script.sh"
        source = original.read_text()
        source = source.replace("/opt/cisco/secureclient/bin/vpn", str(self.bin / "vpn"))
        source = source.replace("/bin/launchctl", str(self.bin / "launchctl"))
        source = source.replace('YUBIKEY_PATH="~/yksofttoken/yksoft"',
                                'YUBIKEY_PATH="' + str(self.bin / "token") + '"')
        # Keep the existing route code unmodified but stub its entry point.
        source = source.replace("# Parse command line arguments", '''
apply_local_route_exceptions_with_retries() { echo TEST_ROUTE_REPAIR; }
# Parse command line arguments''')
        directory = self.root / "scripts & tools"
        directory.mkdir()
        self.script = directory / "vpn-script.sh"
        self.script.write_text(source)
        self.env = dict(os.environ, HOME=str(self.root), VPN_TEST_ROOT=str(self.root),
                        PATH=str(self.bin) + ":/usr/bin:/bin:/usr/sbin:/sbin")
        self.write_state({})

    def write_state(self, state):
        (self.root / "state.json").write_text(json.dumps(state))

    def state(self):
        return json.loads((self.root / "state.json").read_text())

    def run_script(self, *args, expected=0):
        result = subprocess.run(["/bin/bash", str(self.script), *args], env=self.env,
                                capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        self.assertNotIn("fake-password", result.stdout + result.stderr)
        self.assertNotIn("fake-otp-", result.stdout + result.stderr)
        self.assertNotIn("UNEXPECTED_SUDO", self.state().get("events", []))
        return result

    def test_connect_schedules_seven_hours_without_routes(self):
        result = self.run_script("connect")
        state = self.state()
        self.assertTrue(state["loaded"])
        self.assertNotIn("TEST_ROUTE_REPAIR", result.stdout)
        self.assertNotIn("sleep:15", state["events"])
        plist = state["plist"]
        self.assertEqual(plist["StartInterval"], 7 * 60 * 60)
        self.assertEqual(plist["ProgramArguments"], ["/bin/bash", str(self.script), "_reconnect"])
        self.assertNotIn("RunAtLoad", plist)
        self.assertEqual(self.root, Path(plist["StandardOutPath"]).parents[2].parent)
        path = self.root / "Library/Application Support/SecureClientAutoLogin/reconnect.plist"
        subprocess.run(["/usr/bin/plutil", "-lint", str(path)], check=True, capture_output=True)
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(path.parent.stat().st_mode & 0o777, 0o700)

    def test_explicit_route_option_still_works(self):
        result = self.run_script("connect", "--fix-routes")
        self.assertIn("TEST_ROUTE_REPAIR", result.stdout)
        self.assertTrue(self.state()["loaded"])

    def test_repeat_connect_replaces_job(self):
        self.run_script("connect")
        self.run_script("c")
        events = self.state()["events"]
        self.assertEqual(events.count("schedule"), 2)
        self.assertEqual(events.count("unschedule"), 1)
        second_connect = events.index("connect", events.index("connect") + 1)
        self.assertLess(events.index("unschedule"), second_connect)
        self.assertTrue(self.state()["loaded"])

    def test_disconnect_stops_job_before_disconnect(self):
        self.write_state({"loaded": True, "vpn": "Connected"})
        self.run_script("disconnect")
        state = self.state()
        self.assertFalse(state["loaded"])
        self.assertEqual(state["events"][:2], ["unschedule", "disconnect"])
        self.assertEqual(state["vpn"], "Disconnected")

    def test_worker_retries_with_fresh_otp_without_rescheduling(self):
        self.write_state({"loaded": True, "vpn": "Connected", "reject_attempts": 1})
        self.run_script("_reconnect")
        state = self.state()
        self.assertEqual(state["vpn"], "Connected")
        self.assertEqual(state["tokens"], 2)
        self.assertEqual(state["events"].count("disconnect"), 1)
        self.assertEqual(state["events"].count("connect"), 2)
        self.assertIn("sleep:60", state["events"])
        self.assertNotIn("schedule", state["events"])
        self.assertNotIn("unschedule", state["events"])

    def test_worker_recovers_from_keychain_failure(self):
        self.write_state({"loaded": True, "keychain_failures": 1})
        self.run_script("_reconnect")
        self.assertEqual(self.state()["vpn"], "Connected")
        self.assertIn("sleep:60", self.state()["events"])

    def test_failed_connect_does_not_schedule(self):
        self.write_state({"reject_attempts": 1})
        self.run_script("connect", expected=1)
        self.assertNotIn("schedule", self.state()["events"])

    def test_scheduler_failure_is_reported(self):
        self.write_state({"bootstrap_failure": True})
        result = self.run_script("connect", expected=1)
        self.assertIn("could not be scheduled", result.stdout)

    def test_failed_job_stop_does_not_disconnect_or_start_duplicate(self):
        self.write_state({"loaded": True, "vpn": "Connected", "bootout_failure": True})
        self.run_script("disconnect", expected=1)
        self.run_script("connect", expected=1)
        self.assertEqual(self.state()["events"], ["unschedule", "unschedule"])
        self.assertEqual(self.state()["vpn"], "Connected")

    def test_status_reports_scheduler(self):
        self.assertIn("disabled", self.run_script("status").stdout)
        self.write_state({"loaded": True, "vpn": "Connected"})
        self.assertIn("enabled", self.run_script("status").stdout)

    def test_invalid_options_have_no_side_effects(self):
        self.run_script("connect", "--invalid", expected=1)
        self.run_script("disconnect", "extra", expected=1)
        self.run_script("connect", "--help")
        self.assertEqual(self.state(), {})


if __name__ == "__main__":
    unittest.main()

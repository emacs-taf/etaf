"""Owned-window capture routing preflight; never captures a real screen."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
CAPTURE = ROOT / "scripts/capture-emacs-window.sh"
RECORDER_SOURCE = ROOT / "scripts/record-emacs-window.swift"


class WindowCaptureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.build.cleanup)
        cls.recorder = Path(cls.build.name) / "recorder"
        subprocess.run(
            ["xcrun", "swiftc", "-parse-as-library", "-warnings-as-errors", "-O",
             str(RECORDER_SOURCE), "-o", str(cls.recorder)], check=True,
        )

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name)
        self.output = self.path / "a frame.png"
        self.log = self.path / "arguments.json"
        self.environment = dict(os.environ)
        self.environment.update(
            PATH=f"{self.path}:{os.environ['PATH']}",
            ETAF_GUI_CAPTURE_PID=str(os.getpid()),
            CAPTURE_TEST_LOG=str(self.log),
            CAPTURE_TEST_ID="123",
        )
        self.script("osascript", "#!/bin/sh\ncat >/dev/null\nprintf '%s\\n' \"$CAPTURE_TEST_ID\"\n")
        self.capture = self.script(
            "screencapture",
            "#!/usr/bin/env python3\n"
            "import json, os, pathlib, sys\n"
            "pathlib.Path(os.environ['CAPTURE_TEST_LOG']).write_text(json.dumps(sys.argv[1:]))\n"
            "pathlib.Path(sys.argv[-1]).write_bytes(b'capture stub')\n"
        )
        self.environment["ETAF_GUI_SCREENCAPTURE"] = str(self.capture)

    def script(self, name, contents):
        path = self.path / name
        path.write_text(contents)
        path.chmod(0o755)
        return path

    def run_capture(self, *arguments):
        return subprocess.run(
            [str(CAPTURE), *arguments], env=self.environment,
            capture_output=True, text=True, check=False,
        )

    def test_screenshot_captures_exact_owned_window_without_shadow(self):
        result = self.run_capture("-x", str(self.output))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(self.log.read_text()),
                         ["-l", "123", "-o", "-x", str(self.output)])

    def test_screenshot_resolves_replacement_window_for_next_capture(self):
        for window_id in ("123", "456"):
            self.environment["CAPTURE_TEST_ID"] = window_id
            result = self.run_capture("-x", str(self.output))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(self.log.read_text())[1], window_id)

    def test_missing_owner_fails_without_invoking_capture(self):
        self.script("osascript", "#!/bin/sh\nexit 1\n")
        result = self.run_capture("-x", str(self.output))
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.log.exists())

    def test_invalid_pid_fails_without_invoking_capture(self):
        self.environment["ETAF_GUI_CAPTURE_PID"] = "1; echo unsafe"
        result = self.run_capture("-x", str(self.output))
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.log.exists())

    def test_window_replacement_during_capture_rejects_image(self):
        counter = self.path / "counter"
        self.script("osascript", f'''#!/bin/sh
cat >/dev/null
if [ -f '{counter}' ]; then echo 456; else touch '{counter}'; echo 123; fi
''')
        result = self.run_capture("-x", str(self.output))
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.output.exists())

    def test_video_rejects_missing_or_invalid_owner_before_capture(self):
        for arguments in ([], ["0", str(self.output), "ready"],
                          ["123; echo unsafe", str(self.output), "ready"]):
            result = subprocess.run(
                [str(self.recorder), *arguments],
                env=self.environment, capture_output=True, check=False,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(self.log.exists())



if __name__ == "__main__":
    unittest.main()

"""Owned-window capture routing preflight; never captures a real screen."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
CAPTURE = ROOT / "scripts/capture-emacs-window.sh"
RUNNER = ROOT / "scripts/run-emacs-gui-verification.sh"
RECORDER_SOURCE = ROOT / "scripts/record-emacs-window.swift"


class RecorderCanvasTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.build.cleanup)
        source = RECORDER_SOURCE.read_text()
        # Run the actual polling guard with fixture-only providers. Compiling
        # the rest of the recorder also keeps its real validation available;
        # the recorder's main and all capture APIs remain uninvoked.
        guard = source.split("                let nextID = try windowID(pid: pid)\n", 1)[1]
        guard_end = '                    try emit(["event": "window-replaced", "window_id": id, "pid": pid])\n                }'
        guard = ("let nextID = try windowID(pid: pid)\n" + guard.split(
            guard_end, 1)[0] + guard_end)
        driver = r'''
struct FixtureFilter {
    let contentRect: CGRect
    let pointPixelScale: Double
}
final class FixtureStream {
    var updates = 0
    func updateContentFilter(_ filter: FixtureFilter) async throws { updates += 1 }
}
extension RecordEmacsWindow {
    static func checkFixture(_ input: [String: Any]) async -> [String: Any] {
        let pid: pid_t = 123
        var id = CGWindowID(input["current_id"] as! Int)
        var currentFilter = FixtureFilter(contentRect: CGRect(x: 0, y: 0, width: 500, height: 400),
                                          pointPixelScale: 2)
        let configuration = SCStreamConfiguration()
        configuration.width = 1000
        configuration.height = 800
        let stream = FixtureStream()
        var reads = 0
        func windowID(pid: pid_t) throws -> CGWindowID { CGWindowID(input["next_id"] as! Int) }
        func filter(pid: pid_t, id: CGWindowID) async throws -> FixtureFilter {
            reads += 1
            return FixtureFilter(contentRect: CGRect(x: 0, y: 0,
                width: input["width"] as! Double, height: input["height"] as! Double),
                pointPixelScale: input["scale"] as! Double)
        }
        func emit(_ values: [String: Any]) throws {}
        var failure: String?
        do {
''' + guard + r'''
        } catch { failure = String(describing: error) }
        return ["error": failure as Any? ?? NSNull(), "filter_reads": reads,
                "updates": stream.updates, "window_id": id]
    }
}
func checkFrameFixture(_ input: [String: Any]) throws -> [String: Any] {
    var image: CVPixelBuffer?
    guard CVPixelBufferCreate(kCFAllocatorDefault, 1000, 800, kCVPixelFormatType_32BGRA,
                            nil, &image) == kCVReturnSuccess, let image else {
        throw CaptureFailure("Cannot create fixture pixels")
    }
    var format: CMVideoFormatDescription?
    guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
        imageBuffer: image, formatDescriptionOut: &format) == noErr, let format else {
        throw CaptureFailure("Cannot create fixture video format")
    }
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 60),
        presentationTimeStamp: CMTime(value: 1, timescale: 60), decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
        imageBuffer: image, formatDescription: format, sampleTiming: &timing,
        sampleBufferOut: &sample) == noErr, let sample else {
        throw CaptureFailure("Cannot create fixture sample")
    }
    let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true)!
        as! [NSMutableDictionary]
    attachments[0][SCStreamFrameInfo.status.rawValue] = SCFrameStatus.complete.rawValue
    attachments[0][SCStreamFrameInfo.contentScale.rawValue] = input["content_scale"] as! Double
    attachments[0][SCStreamFrameInfo.scaleFactor.rawValue] = input["backing_scale"] as! Double
    attachments[0][SCStreamFrameInfo.contentRect.rawValue] = CGRect(
        x: input["x"] as! Double, y: input["y"] as! Double,
        width: input["width"] as! Double, height: input["height"] as! Double).dictionaryRepresentation
    let events = CaptureEvents(pixelScale: 2)
    events.inspectScreenSample(sample)
    let result = events.state()
    return ["error": result.failure as Any? ?? NSNull(), "frames": result.frames]
}
@main
struct CanvasFixtureMain {
    static func main() async throws {
        let input = try JSONSerialization.jsonObject(with: FileHandle.standardInput.readDataToEndOfFile())
            as! [String: Any]
        let result = input["frame"] as? Bool == true
            ? try checkFrameFixture(input) : await RecordEmacsWindow.checkFixture(input)
        try RecordEmacsWindow.emit(result)
    }
}
'''
        path = Path(cls.build.name) / "canvas-fixture.swift"
        path.write_text(source.replace("@main\nstruct RecordEmacsWindow",
                                       "struct RecordEmacsWindow", 1) + driver)
        cls.fixture = Path(cls.build.name) / "canvas-fixture"
        subprocess.run(
            ["xcrun", "swiftc", "-parse-as-library", "-warnings-as-errors", "-O",
             str(path), "-o", str(cls.fixture)], check=True,
        )

    def check_canvas(self, next_id, width, height, scale=2):
        result = subprocess.run(
            [str(self.fixture)], input=json.dumps(dict(current_id=123, next_id=next_id,
                width=width, height=height, scale=scale)),
            capture_output=True, text=True, check=True, timeout=10,
        )
        return json.loads(result.stdout)

    def test_same_id_fit_uses_fresh_geometry(self):
        result = self.check_canvas(123, 400, 300)
        self.assertIsNone(result["error"])
        self.assertEqual(result["filter_reads"], 1)
        self.assertEqual(result["updates"], 0)

    def test_same_id_growth_rejects_either_dimension(self):
        for width, height in ((501, 400), (500, 401)):
            with self.subTest(width=width, height=height):
                result = self.check_canvas(123, width, height)
                self.assertIsNotNone(result["error"])
                self.assertIn("exceeds original native-pixel canvas", result["error"])
                self.assertEqual(result["updates"], 0)

    def test_replacement_fit_updates_filter(self):
        result = self.check_canvas(456, 400, 300)
        self.assertIsNone(result["error"])
        self.assertEqual(result["filter_reads"], 1)
        self.assertEqual(result["updates"], 1)
        self.assertEqual(result["window_id"], 456)

    def test_replacement_growth_rejects_before_filter_update(self):
        for width, height in ((501, 400), (500, 401)):
            with self.subTest(width=width, height=height):
                result = self.check_canvas(456, width, height)
                self.assertIn("exceeds original native-pixel canvas", result["error"])
                self.assertEqual(result["updates"], 0)
                self.assertEqual(result["window_id"], 123)

    def test_exact_native_canvas_boundary(self):
        for identifier in (123, 456):
            for width, height, scale in ((500, 400, 2), (1000, 800, 1)):
                with self.subTest(identifier=identifier, scale=scale):
                    result = self.check_canvas(identifier, width, height, scale)
                    self.assertIsNone(result["error"])
                    self.assertEqual(result["filter_reads"], 1)

    def test_fractional_native_pixel_overflow_rejects(self):
        for identifier in (123, 456):
            for width, height in ((500.01, 400), (500, 400.01)):
                with self.subTest(identifier=identifier, width=width, height=height):
                    self.assertIsNotNone(self.check_canvas(identifier, width, height)["error"])

    def test_unusable_fresh_geometry_is_rejected(self):
        for identifier in (123, 456):
            for width, height, scale in ((0, 400, 2), (500, 0, 2), (500, 400, 0)):
                with self.subTest(identifier=identifier, width=width, height=height, scale=scale):
                    result = self.check_canvas(identifier, width, height, scale)
                    self.assertIsNotNone(result["error"])
                    self.assertEqual(result["updates"], 0)

    def check_frame(self, width, height, x=0, y=0, content_scale=1, backing_scale=2):
        result = subprocess.run(
            [str(self.fixture)], input=json.dumps(dict(frame=True, width=width, height=height,
                x=x, y=y, content_scale=content_scale, backing_scale=backing_scale)),
            capture_output=True, text=True, check=True, timeout=10,
        )
        return json.loads(result.stdout)

    def test_native_frame_exact_boundary_and_padding(self):
        for width, height, x, y in ((500, 400, 0, 0), (400, 300, 50, 50)):
            with self.subTest(width=width, height=height):
                result = self.check_frame(width, height, x, y)
                self.assertIsNone(result["error"])
                self.assertEqual(result["frames"], 1)

    def test_native_frame_extent_cannot_exceed_buffer(self):
        for width, height in ((501, 400), (500, 401), (500.01, 400)):
            with self.subTest(width=width, height=height):
                result = self.check_frame(width, height)
                self.assertIsNotNone(result["error"])
                self.assertEqual(result["frames"], 0)

    def test_native_frame_content_cannot_extend_outside_buffer(self):
        for x, y in ((-1, 0), (0, -1), (1, 0), (0, 1)):
            with self.subTest(x=x, y=y):
                result = self.check_frame(500, 400, x, y)
                self.assertIsNotNone(result["error"])
                self.assertEqual(result["frames"], 0)

    def test_scaled_frame_stays_rejected(self):
        result = self.check_frame(400, 320, content_scale=0.8)
        self.assertIn("scaled", result["error"])
        self.assertEqual(result["frames"], 0)


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

    def run_recorder_lifecycle(self, recorder):
        source = RUNNER.read_text().rsplit('[ "$#" -ge 1 ] || usage', 1)[0]
        self.environment.update(TEST_RECORDER=str(recorder), TEST_RUN_DIR=str(self.path))
        return subprocess.run(
            ["sh", "-c", source + '''
GUI_RUN_DIR=$TEST_RUN_DIR
GUI_RECORDER=$TEST_RECORDER
GUI_DAEMON_PID=$ETAF_GUI_CAPTURE_PID
start_recorder
stop_recorder
'''], env=self.environment, capture_output=True, text=True, timeout=10, check=False,
        )

    def test_runner_waits_for_verified_frame_and_stops_owned_recorder(self):
        recorder = self.script(
            "recorder-stub", "#!/usr/bin/env python3\n"
            "import json, os, pathlib, signal, sys\n"
            "signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))\n"
            "pathlib.Path(os.environ['CAPTURE_TEST_LOG']).write_text(json.dumps(sys.argv[1:]))\n"
            "pathlib.Path(sys.argv[3]).write_text('verified frame')\n"
            "signal.pause()\n",
        )
        result = self.run_recorder_lifecycle(recorder)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(self.log.read_text()),
                         [str(os.getpid()), str(self.path / "recording.mov"),
                          str(self.path / "recorder.ready")])

    def test_runner_rejects_recording_exit_before_ready(self):
        recorder = self.script("recorder-stub", "#!/bin/sh\nexit 1\n")
        result = self.run_recorder_lifecycle(recorder)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("exited before", result.stderr)

    def test_selector_rejects_other_owners_helpers_and_ambiguous_frames(self):
        source = CAPTURE.read_text().split("<<'JXA'\n", 1)[1].split("\nJXA", 1)[0]
        source = source[source.index("function run(argv)"):]

        def window(identifier, **overrides):
            result = dict(kCGWindowNumber=identifier, kCGWindowOwnerPID=123,
                          kCGWindowOwnerName="Emacs", kCGWindowLayer=0,
                          kCGWindowAlpha=1, kCGWindowName="*target*",
                          kCGWindowBounds=dict(Width=1000, Height=800))
            result.update(overrides)
            return result

        def select(windows):
            # Evaluate the actual JXA selector against a fixed WindowServer
            # inventory.  The test does not enumerate or capture live windows.
            fixture = (
                "var ObjC = {deepUnwrap: function(x) {return x;}, "
                "castRefToObject: function(x) {return x;}};\n"
                "var $ = {CGWindowListCopyWindowInfo: function() {return "
                + json.dumps(windows) + ";}};\n"
            )
            script = source.replace("function run(argv) {",
                                    "function run(argv) {\n" + fixture, 1)
            return subprocess.run(
                ["/usr/bin/osascript", "-l", "JavaScript", "-", "123"],
                input=script, capture_output=True, text=True, check=False,
            )

        candidates = [
            window(1, kCGWindowOwnerPID=456),
            window(2, kCGWindowOwnerName="Other"),
            window(3, kCGWindowName=""),
            window(4, kCGWindowAlpha=0),
            window(5, kCGWindowLayer=1),
            window(6, kCGWindowBounds=dict(Width=1000, Height=24)),
            window(7),
        ]
        result = select(candidates)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "7")
        self.assertNotEqual(select(candidates + [window(8)]).returncode, 0)
        self.assertNotEqual(select(candidates[:5]).returncode, 0)


if __name__ == "__main__":
    unittest.main()

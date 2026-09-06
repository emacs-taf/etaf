#!/bin/sh

# Select an owned frame each time: fullscreen transitions can replace its
# WindowServer ID.  Never fall back to capturing the desktop.
set -eu

usage() {
    echo "usage: $0 --window-id PID | -x OUTPUT" >&2
    exit 2
}

window_id() {
    case $1 in
        ''|*[!0-9]*) echo "invalid Emacs capture PID: $1" >&2; return 1 ;;
    esac
    [ "$1" -gt 1 ] && kill -0 "$1" 2>/dev/null || {
        echo "Emacs capture process is not alive: $1" >&2
        return 1
    }
    osascript -l JavaScript - "$1" <<'JXA'
ObjC.import("CoreGraphics");
function run(argv) {
    var pid = Number(argv[0]);
    var windows = ObjC.deepUnwrap(ObjC.castRefToObject(
        $.CGWindowListCopyWindowInfo($.kCGWindowListOptionAll,
                                    $.kCGNullWindowID)));
    var candidates = windows.filter(function (window) {
        var bounds = window.kCGWindowBounds;
        return window.kCGWindowOwnerPID === pid &&
            window.kCGWindowOwnerName === "Emacs" &&
            window.kCGWindowLayer === 0 && window.kCGWindowAlpha > 0 &&
            window.kCGWindowName && bounds &&
            bounds.Width > 0 && bounds.Height > 0;
    });
    candidates.sort(function (a, b) {
        return b.kCGWindowBounds.Width * b.kCGWindowBounds.Height -
            a.kCGWindowBounds.Width * a.kCGWindowBounds.Height;
    });
    if (!candidates.length) {
        throw new Error("No named Emacs frame owned by PID " + pid);
    }
    if (candidates.length > 1 &&
        candidates[0].kCGWindowBounds.Width * candidates[0].kCGWindowBounds.Height ===
        candidates[1].kCGWindowBounds.Width * candidates[1].kCGWindowBounds.Height) {
        throw new Error("Ambiguous largest Emacs frame for PID " + pid);
    }
    return String(candidates[0].kCGWindowNumber);
}
JXA
}

[ "$#" -eq 2 ] || usage
case $1 in
    --window-id) window_id "$2" ;;
    -x)
        GUI_CAPTURE_PID=${ETAF_GUI_CAPTURE_PID:?ETAF_GUI_CAPTURE_PID is required}
        GUI_CAPTURE_ID=$(window_id "$GUI_CAPTURE_PID")
        GUI_CAPTURE_BIN=${ETAF_GUI_SCREENCAPTURE:-/usr/sbin/screencapture}
        "$GUI_CAPTURE_BIN" -l "$GUI_CAPTURE_ID" -o -x "$2"
        # Reject a capture made while macOS replaced the intended frame.
        GUI_CAPTURE_AFTER=$(window_id "$GUI_CAPTURE_PID")
        if [ "$GUI_CAPTURE_ID" != "$GUI_CAPTURE_AFTER" ]; then
            rm -f -- "$2"
            echo "Emacs frame changed during screenshot; capture again" >&2
            exit 1
        fi
        ;;
    *) usage ;;
esac

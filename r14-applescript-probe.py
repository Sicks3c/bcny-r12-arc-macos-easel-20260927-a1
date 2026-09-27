#!/usr/bin/env python3
import hashlib
import json
import re
import subprocess
import sys
import time
from urllib.parse import urlsplit

SCRIPT = r'''
set savedDelimiters to AppleScript's text item delimiters
set fieldSeparator to ASCII character 9
set outputRows to {}
tell application id "company.thebrowser.Browser"
    set end of outputRows to "APP" & fieldSeparator & (version as text)
    repeat with currentWindow in every window
        set windowID to (id of currentWindow as text)
        set end of outputRows to "W" & fieldSeparator & windowID
        repeat with currentSpace in every space of currentWindow
            set end of outputRows to "S" & fieldSeparator & windowID & fieldSeparator & (id of currentSpace as text)
        end repeat
        repeat with currentTab in every tab of currentWindow
            set tabURL to ""
            try
                set tabURL to (URL of currentTab as text)
            end try
            set end of outputRows to "T" & fieldSeparator & windowID & fieldSeparator & (id of currentTab as text) & fieldSeparator & tabURL
        end repeat
    end repeat
end tell
set AppleScript's text item delimiters to linefeed
set rendered to outputRows as text
set AppleScript's text item delimiters to savedDelimiters
return rendered
'''

ID_RE = re.compile(r"^[A-Za-z0-9_-]{8,128}$")


def exact_easel_id(raw):
    try:
        parsed = urlsplit(raw.strip())
    except ValueError:
        return None
    try:
        if parsed.scheme != "https" or (parsed.hostname or "").lower() != "arc.net":
            return None
        if parsed.port is not None or parsed.username is not None or parsed.password is not None:
            return None
    except ValueError:
        return None
    if parsed.query or parsed.fragment:
        return None
    pieces = parsed.path.split("/")
    if len(pieces) != 3 or pieces[0] != "" or pieces[1] != "e":
        return None
    if not ID_RE.fullmatch(pieces[2]):
        return None
    return pieces[2]


def classify_error(stderr, timed_out=False):
    lower = stderr.lower()
    if timed_out:
        return "timeout_no_prompt_interaction"
    if "-1743" in lower or "not authorized to send apple events" in lower:
        return "apple_events_not_authorized"
    if "-600" in lower or "isn't running" in lower:
        return "application_not_running"
    if "-1728" in lower or "can't get" in lower:
        return "object_model_unavailable"
    return "other_osascript_error"


def snapshot():
    try:
        completed = subprocess.run(
            ["/usr/bin/osascript", "-e", SCRIPT],
            capture_output=True,
            text=True,
            timeout=25,
            check=False,
        )
    except subprocess.TimeoutExpired:
        return {"status": "ERROR", "error_class": classify_error("", timed_out=True)}
    if completed.returncode != 0:
        return {
            "status": "ERROR",
            "osascript_rc": completed.returncode,
            "error_class": classify_error(completed.stderr),
        }

    versions = []
    windows = []
    spaces = []
    tabs = []
    malformed = 0
    for line in completed.stdout.splitlines():
        fields = line.split("\t")
        if len(fields) == 2 and fields[0] == "APP":
            versions.append(fields[1])
        elif len(fields) == 2 and fields[0] == "W":
            windows.append(fields[1])
        elif len(fields) == 3 and fields[0] == "S":
            spaces.append((fields[1], fields[2]))
        elif len(fields) == 4 and fields[0] == "T":
            tabs.append((fields[1], fields[2], fields[3]))
        elif line:
            malformed += 1

    route_ids = [candidate for _, _, raw_url in tabs if (candidate := exact_easel_id(raw_url))]
    unique_route_ids = sorted(set(route_ids))
    safe = {
        "status": "OK",
        "app_version": versions[0] if len(versions) == 1 else "unexpected",
        "window_count": len(windows),
        "space_count": len(spaces),
        "tab_count": len(tabs),
        "window_ids_unique": len(windows) == len(set(windows)),
        "space_id_pairs_unique": len(spaces) == len(set(spaces)),
        "tab_id_pairs_unique": len([(w, t) for w, t, _ in tabs]) == len(set((w, t) for w, t, _ in tabs)),
        "relationship_window_refs_valid": all(w in set(windows) for w, _ in spaces)
        and all(w in set(windows) for w, _, _ in tabs),
        "malformed_row_count": malformed,
        "route_candidate_tab_count": len(route_ids),
        "route_candidate_unique_id_count": len(unique_route_ids),
        "raw_url_emitted": False,
        "raw_id_emitted": False,
        "title_reads": 0,
        "content_reads": 0,
    }
    if len(route_ids) == 1 and len(unique_route_ids) == 1:
        safe["easel_id_utf8_length"] = len(unique_route_ids[0].encode())
        safe["easel_id_sha256"] = hashlib.sha256(unique_route_ids[0].encode()).hexdigest()
    else:
        safe["easel_id_utf8_length"] = 0
        safe["easel_id_sha256"] = "absent"
    return safe


def self_test():
    good = "https://" + "arc.net" + "/e/" + ("A" * 12)
    assert exact_easel_id(good) == "A" * 12
    assert exact_easel_id(good + "?x=1") is None
    assert exact_easel_id("http://arc.net/e/" + ("A" * 12)) is None
    assert exact_easel_id("https://example.com/e/" + ("A" * 12)) is None
    assert exact_easel_id("https://arc.net:bad/e/" + ("A" * 12)) is None
    print("self_test=PASS cases=5 raw_target_values=0")


def main():
    if len(sys.argv) == 2 and sys.argv[1] == "--self-test":
        self_test()
        return
    if len(sys.argv) != 1:
        raise SystemExit(2)

    first = snapshot()
    result = {
        "schema": 1,
        "query_surface": ["application.version", "window.id", "space.id", "tab.id", "tab.URL"],
        "sample_count": 1,
        "samples": [first],
        "ordinary_tab_control_created": False,
        "execute_javascript_invocations": 0,
        "clipboard_actions": 0,
        "screenshots": 0,
        "object_actions": 0,
        "content_reads": 0,
    }
    if first.get("status") != "OK":
        result["decision"] = "STOP_APPLESCRIPT_ERROR"
    elif first["route_candidate_tab_count"] == 1 and first["route_candidate_unique_id_count"] == 1:
        time.sleep(2)
        second = snapshot()
        time.sleep(2)
        third = snapshot()
        result["samples"].extend([second, third])
        result["sample_count"] = 3
        comparable = all(sample.get("status") == "OK" for sample in result["samples"])
        hashes = [sample.get("easel_id_sha256") for sample in result["samples"]]
        result["unique_and_stable"] = comparable and len(set(hashes)) == 1
        result["decision"] = "STOP_EXACT_ONE_VALIDATED" if result["unique_and_stable"] else "STOP_STABILITY_FAILED"
    elif first["route_candidate_tab_count"] == 0:
        result["decision"] = "STOP_ZERO_CANDIDATES"
    else:
        result["decision"] = "STOP_MULTIPLE_OR_DUPLICATE_CANDIDATES"
    print(json.dumps(result, sort_keys=True, indent=2))


if __name__ == "__main__":
    main()

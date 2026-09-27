#!/bin/bash
set -euo pipefail
umask 077

OUT="$RUNNER_TEMP/evidence"
RAW="$RUNNER_TEMP/raw"
PROFILE_ROOT='/Users/runner/Library/Application Support/Arc'
CACHE_ROOT='/Users/runner/Library/Caches/company.thebrowser.Browser'
PREF_FILE='/Users/runner/Library/Preferences/company.thebrowser.Browser.plist'
mkdir -p "$OUT" "$RAW"
if [[ -e "$PROFILE_ROOT" || -e "$CACHE_ROOT" || -e "$PREF_FILE" ]]; then
  echo 'fresh_profile_precheck=FAIL' > "$OUT/fresh-profile-precheck.txt"
  exit 6
fi
echo 'fresh_profile_precheck=PASS' > "$OUT/fresh-profile-precheck.txt"

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

cleanup() {
  set +e
  if [[ -n "${ARC_APP:-}" ]]; then
    while read -r target_pid; do
      [[ -n "$target_pid" ]] && kill "$target_pid"
    done < <(ps -axo pid=,command= | awk -v n="$ARC_APP/Contents/" 'index($0,n){print $1}')
  fi
  sleep 2
  if [[ -n "${MOUNT_POINT:-}" ]]; then hdiutil detach "$MOUNT_POINT" -force >/dev/null 2>&1; fi
  [[ "$HOME" == /Users/runner ]]
  rm -rf "$PROFILE_ROOT" "$CACHE_ROOT"
  rm -f "$PREF_FILE"
  {
    echo "timestamp=$(now)"
    if [[ -n "${ARC_APP:-}" ]] && ps -axo command= | grep -F "$ARC_APP/Contents/" | grep -v grep >/dev/null; then echo "target_processes=present"; else echo "target_processes=absent"; fi
    if [[ -e "$PROFILE_ROOT" ]]; then echo "profile=present"; else echo "profile=absent"; fi
    if [[ -n "${MOUNT_POINT:-}" && -e "$MOUNT_POINT" ]]; then echo "mount=present"; else echo "mount=absent"; fi
  } > "$OUT/native-teardown.txt"
}
trap cleanup EXIT

{
  echo "timestamp=$(now)"
  sw_vers
  echo "architecture=$(uname -m)"
  echo "arm64_capability=$(sysctl -n hw.optional.arm64 2>/dev/null || echo unknown)"
  launchctl print "gui/$(id -u)" >/dev/null 2>&1 && echo "gui_launch_domain=available" || echo "gui_launch_domain=unavailable"
  console_name="$(stat -f %Su /dev/console 2>/dev/null || echo unavailable)"
  [[ "$console_name" != root && "$console_name" != loginwindow && "$console_name" != unavailable ]] && echo "console_user_session=available" || echo "console_user_session=unavailable"
  swift --version | head -1
} > "$OUT/runtime.txt"
[[ "$(uname -m)" == arm64 ]]
[[ "$(sysctl -n hw.optional.arm64)" == 1 ]]

URL='https://releases.arc.net/release/Arc-1.166.0-87668.dmg'
EXPECTED='b956b4f7b4cd7fca43ae7028163041135fd503c3af2d193ccedcf9edd00f0aec'
curl -fsSIL --max-time 120 "$URL" > "$RAW/headers.txt"
curl -fL --retry 3 --retry-all-errors --connect-timeout 30 --max-time 1200 -o "$RAW/Arc.dmg" "$URL"
ACTUAL="$(shasum -a 256 "$RAW/Arc.dmg" | awk '{print $1}')"
{
  echo "timestamp=$(now)"
  echo "url=$URL"
  echo "bytes=$(stat -f %z "$RAW/Arc.dmg")"
  echo "sha256=$ACTUAL"
  echo "expected_sha256=$EXPECTED"
  [[ "$ACTUAL" == "$EXPECTED" ]] && echo "hash_gate=PASS" || echo "hash_gate=FAIL"
  grep -Ei '^(HTTP/|location:|content-type:|content-length:|etag:|last-modified:)' "$RAW/headers.txt" || true
} > "$OUT/package.txt"
[[ "$ACTUAL" == "$EXPECTED" ]]

hdiutil attach -readonly -nobrowse "$RAW/Arc.dmg" > "$RAW/attach.txt"
MOUNT_POINT="$(awk -F '\t' '/\/Volumes\// {print $NF}' "$RAW/attach.txt" | tail -1)"
ARC_APP="$MOUNT_POINT/Arc.app"
test -d "$ARC_APP"
PLIST="$ARC_APP/Contents/Info.plist"
BIN="$ARC_APP/Contents/MacOS/Arc"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")" == 1.166.0 ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")" == 87668 ]]

set +e
codesign --verify --deep --strict --verbose=4 "$ARC_APP" > "$RAW/codesign.txt" 2>&1; CODE_RC=$?
codesign -dv --verbose=4 "$ARC_APP" > "$RAW/details.txt" 2>&1; DETAIL_RC=$?
codesign -d -r- "$ARC_APP" > "$RAW/requirement.txt" 2>&1; REQ_RC=$?
spctl --assess --type execute --verbose=4 "$ARC_APP" > "$RAW/gatekeeper.txt" 2>&1; GATE_RC=$?
set -e
{
  echo "timestamp=$(now)"
  echo "version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
  echo "build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
  echo "bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")"
  echo "minimum_os=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PLIST")"
  echo "architectures=$(lipo -archs "$BIN")"
  echo "codesign_rc=$CODE_RC details_rc=$DETAIL_RC requirement_rc=$REQ_RC gatekeeper_rc=$GATE_RC"
  grep -E '^(Identifier|TeamIdentifier|Authority|Runtime Version|Timestamp|Format|CodeDirectory)' "$RAW/details.txt" || true
  cat "$RAW/requirement.txt"
  cat "$RAW/gatekeeper.txt"
} > "$OUT/signature.txt"
[[ "$CODE_RC" == 0 && "$DETAIL_RC" == 0 && "$REQ_RC" == 0 && "$GATE_RC" == 0 ]]
grep -Fq 'TeamIdentifier=S6N382Y83G' "$OUT/signature.txt"
grep -Fq 'source=Notarized Developer ID' "$OUT/signature.txt"

strings -a "$BIN" | grep -E '(^|[^A-Za-z])(EaselClient\.createEasel|EaselClient\.deleteEasel|EaselLibraryClient\.deleteEasel|creatorOnly|publicReadWrite|readOnly|New Easel|Account Preferences|Delete Account)([^A-Za-z]|$)' | LC_ALL=C sort -u > "$OUT/static-cleanup-contracts.txt" || true
grep -Fq 'EaselClient.createEasel' "$OUT/static-cleanup-contracts.txt"
grep -Fq 'EaselClient.deleteEasel' "$OUT/static-cleanup-contracts.txt"

swiftc "$GITHUB_WORKSPACE/ax-map.swift" -o "$RAW/ax-map"
swiftc "$GITHUB_WORKSPACE/ax-step.swift" -o "$RAW/ax-step"
swiftc "$GITHUB_WORKSPACE/ax-signup.swift" -o "$RAW/ax-signup"
swiftc "$GITHUB_WORKSPACE/ax-capability.swift" -o "$RAW/ax-capability"
swiftc "$GITHUB_WORKSPACE/ax-process-gate.swift" -o "$RAW/ax-process-gate"
swiftc "$GITHUB_WORKSPACE/ax-signup-keyboard.swift" -o "$RAW/ax-signup-keyboard"
open -na "$ARC_APP"
sleep 35
PID="$(ps -axo pid=,command= | awk -v n="$ARC_APP/Contents/MacOS/Arc" 'index($0,n){print $1; exit}')"
test -n "$PID"
"$RAW/ax-map" "$PID" > "$OUT/ax-tree.tsv"
{
  echo "timestamp=$(now)"
  echo "pid_count=$(ps -axo command= | grep -F "$ARC_APP/Contents/" | grep -v grep | wc -l | tr -d ' ')"
  echo "ax_nodes=$(($(wc -l < "$OUT/ax-tree.tsv")-1))"
  echo "new_easel_hits=$(grep -iEc 'new easel' "$OUT/ax-tree.tsv" || true)"
  echo "account_preferences_hits=$(grep -iEc 'account preferences' "$OUT/ax-tree.tsv" || true)"
  echo "delete_easel_hits=$(grep -iEc 'delete easel|delete.*easel|easel.*delete' "$OUT/ax-tree.tsv" || true)"
  echo "ax_values_read=0"
  echo "ax_actions_performed=0"
  echo "keyboard_events=0"
  echo "screenshots=0"
  echo "account_actions=0"
  echo "object_actions=0"
} > "$OUT/preflight-summary.txt"

if [[ "${COV_STAGE:-}" == next ]]; then
  "$RAW/ax-step" "$PID" right > "$OUT/action.txt"
  sleep 8
  "$RAW/ax-map" "$PID" > "$OUT/ax-tree-after.tsv"
  {
    echo "after_nodes=$(($(wc -l < "$OUT/ax-tree-after.tsv")-1))"
    echo "after_right_hits=$(grep -Ec $'AXButton\\t[^\\t]*\\t[^\\t]*\\tRight\\t' "$OUT/ax-tree-after.tsv" || true)"
    echo "after_signin_hits=$(grep -iEc 'sign in|sign up|email|password|account' "$OUT/ax-tree-after.tsv" || true)"
    echo "ax_values_read=0"
    echo "ax_actions_performed=1"
    echo "keyboard_events=0"
    echo "screenshots=0"
    echo "account_actions=0"
    echo "object_actions=0"
  } > "$OUT/after-summary.txt"
fi

if [[ "${COV_STAGE:-}" == signup-a ]]; then
  test -n "${MAIL_ID:-}"
  test -n "${MAIL_TOKEN:-}"
  MAIL_STATUS="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 30 -H "Authorization: Bearer $MAIL_TOKEN" "https://api.mail.tm/accounts/$MAIL_ID")"
  unset MAIL_ID MAIL_TOKEN
  echo "mailbox_owner_precheck=$MAIL_STATUS" > "$OUT/mailbox-precheck.txt"
  [[ "$MAIL_STATUS" == 200 ]]
  "$RAW/ax-step" "$PID" right > "$OUT/action-right.txt"
  sleep 8
  "$RAW/ax-map" "$PID" > "$OUT/ax-tree-signup.tsv"
  "$RAW/ax-signup" "$PID" > "$OUT/action-signup.txt"
  sleep 45
  "$RAW/ax-map" "$PID" > "$OUT/ax-tree-post-signup.tsv"
  {
    echo "post_signup_nodes=$(($(wc -l < "$OUT/ax-tree-post-signup.tsv")-1))"
    echo "post_signup_windows=$(awk -F '\t' '$2==\"AXWindow\"{n++} END{print n+0}' "$OUT/ax-tree-post-signup.tsv")"
    echo "post_signup_new_easel_hits=$(grep -iEc 'new easel' "$OUT/ax-tree-post-signup.tsv" || true)"
    echo "post_signup_library_hits=$(grep -iEc 'view library|view easels' "$OUT/ax-tree-post-signup.tsv" || true)"
    echo "post_signup_account_hits=$(grep -iEc 'account preferences|delete account|sign out|log out' "$OUT/ax-tree-post-signup.tsv" || true)"
    echo "ax_values_written=4"
    echo "ax_values_read=0"
    echo "ax_actions_performed=2"
    echo "keyboard_events=0"
    echo "screenshots=0"
    echo "object_actions=0"
    echo "share_actions=0"
  } > "$OUT/post-signup-summary.txt"
fi

if [[ "${COV_STAGE:-}" == privacy-map ]]; then
  "$RAW/ax-step" "$PID" right > "$OUT/action-right.txt"
  sleep 8
  "$RAW/ax-map" "$PID" > "$OUT/ax-tree-signup.tsv"
  "$RAW/ax-capability" "$PID" '0,0,14' > "$OUT/privacy-capabilities.txt"
  {
    echo "ax_values_read=0"
    echo "ax_values_written=0"
    echo "ax_actions_performed=1"
    echo "keyboard_events=0"
    echo "screenshots=0"
    echo "account_actions=0"
    echo "object_actions=0"
    echo "share_actions=0"
  } > "$OUT/privacy-map-summary.txt"
fi

if [[ "${COV_STAGE:-}" == signup-a-keyboard ]]; then
  test -n "${MAIL_ID:-}"
  test -n "${MAIL_TOKEN:-}"
  MAIL_STATUS="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 30 -H "Authorization: Bearer $MAIL_TOKEN" "https://api.mail.tm/accounts/$MAIL_ID")"
  unset MAIL_ID MAIL_TOKEN
  echo "mailbox_owner_precheck=$MAIL_STATUS" > "$OUT/mailbox-precheck.txt"
  [[ "$MAIL_STATUS" == 200 ]]
  "$RAW/ax-step" "$PID" right > "$OUT/action-right.txt"
  sleep 8
  "$RAW/ax-map" "$PID" > "$OUT/ax-tree-signup.tsv"
  [[ "$(ps -p "$PID" -o comm= | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')" == "$BIN" ]]
  "$RAW/ax-process-gate" "$PID" "$BIN" > "$OUT/process-gate.txt"
  set +e
  "$RAW/ax-signup-keyboard" "$PID" > "$OUT/action-signup-keyboard.txt"
  INPUT_RC=$?
  unset ARC_NAME ARC_EMAIL ARC_PASSWORD
  set -e
  echo "input_rc=$INPUT_RC" > "$OUT/input-result.txt"
  [[ "$INPUT_RC" == 0 ]]
  sleep 45
  "$RAW/ax-map" "$PID" > "$OUT/ax-tree-post-signup.tsv"
  {
    echo "post_signup_nodes=$(($(wc -l < "$OUT/ax-tree-post-signup.tsv")-1))"
    echo "post_signup_windows=$(awk -F '\t' '$2==\"AXWindow\"{n++} END{print n+0}' "$OUT/ax-tree-post-signup.tsv")"
    echo "post_signup_new_easel_hits=$(grep -iEc 'new easel' "$OUT/ax-tree-post-signup.tsv" || true)"
    echo "post_signup_library_hits=$(grep -iEc 'view library|view easels' "$OUT/ax-tree-post-signup.tsv" || true)"
    echo "post_signup_account_hits=$(grep -iEc 'account preferences|delete account|sign out|log out' "$OUT/ax-tree-post-signup.tsv" || true)"
    echo "credential_values_logged=0"
    echo "object_actions=0"
    echo "share_actions=0"
  } > "$OUT/post-signup-summary.txt"
fi

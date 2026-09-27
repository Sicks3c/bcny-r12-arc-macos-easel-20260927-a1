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
swiftc "$GITHUB_WORKSPACE/ax-signup-secure-opaque.swift" -o "$RAW/ax-signup-secure-opaque"
swiftc "$GITHUB_WORKSPACE/ax-geometry.swift" -o "$RAW/ax-geometry"
swiftc "$GITHUB_WORKSPACE/ax-checkbox-calibration.swift" -o "$RAW/ax-checkbox-calibration"
swiftc "$GITHUB_WORKSPACE/ax-checkbox-calibration-hid.swift" -o "$RAW/ax-checkbox-calibration-hid"
swiftc "$GITHUB_WORKSPACE/ax-create-account.swift" -o "$RAW/ax-create-account"
swiftc "$GITHUB_WORKSPACE/ax-login-nav.swift" -o "$RAW/ax-login-nav"
swiftc "$GITHUB_WORKSPACE/ax-login-input-calibration.swift" -o "$RAW/ax-login-input-calibration"
swiftc "$GITHUB_WORKSPACE/ax-login-a-once.swift" -o "$RAW/ax-login-a-once"
swiftc "$GITHUB_WORKSPACE/ax-view-easels-once.swift" -o "$RAW/ax-view-easels-once"
swiftc "$GITHUB_WORKSPACE/ax-create-blank-easel-once.swift" -o "$RAW/ax-create-blank-easel-once"
swiftc "$GITHUB_WORKSPACE/ax-easel-route-hash.swift" -o "$RAW/ax-easel-route-hash"
swiftc "$GITHUB_WORKSPACE/ax-easel-item-capability.swift" -o "$RAW/ax-easel-item-capability"
if [[ "${COV_STAGE:-}" == favorite-selector-map ]]; then
  FAVORITE_SOURCE="$GITHUB_WORKSPACE/ax-favorite-selector-map.swift"
  FORBIDDEN_FAVORITE_SOURCE_HITS="$({ LC_ALL=C grep -Ec 'AXUIElementPerformAction|AXUIElementSetAttributeValue|AXUIElementCopyParameterizedAttributeValue|CGEvent(Post|Create|Source|Tap)|postToPid|\.post\(tap:|CGWindowListCreateImage|screencapture|NSPasteboard|kAXValueAttribute' "$FAVORITE_SOURCE" || true; })"
  echo "forbidden_favorite_source_hits=$FORBIDDEN_FAVORITE_SOURCE_HITS" > "$OUT/favorite-source-audit.txt"
  [[ "$FORBIDDEN_FAVORITE_SOURCE_HITS" == 0 ]]
  swiftc "$FAVORITE_SOURCE" -o "$RAW/ax-favorite-selector-map"
fi
if [[ "${COV_STAGE:-}" == easel-item-diagnostic ]]; then
  FORBIDDEN_SOURCE_API_HITS="$({ LC_ALL=C grep -Ec 'AXUIElementPerformAction|AXUIElementSetAttributeValue|AXUIElementCopyElementAtPosition|AXUIElementCopyParameterizedAttributeValue|CGEvent(Post|Create|Source|Tap)|postToPid|\.post\(tap:|CGWindowListCreateImage|screencapture|NSPasteboard' "$GITHUB_WORKSPACE/ax-easel-item-diagnostic.swift" || true; })"
  KAXVALUE_ATTRIBUTE_COPY_HITS="$({ LC_ALL=C grep -Ec 'copyAttribute\([^,]+,[[:space:]]*kAXValueAttribute' "$GITHUB_WORKSPACE/ax-easel-item-diagnostic.swift" || true; })"
  FORBIDDEN_CONTENT_ATTRIBUTE_HITS="$({ LC_ALL=C grep -Ec 'kAXDescriptionAttribute|kAXHelpAttribute|kAXURLAttribute|kAXDocumentAttribute|kAXFilenameAttribute' "$GITHUB_WORKSPACE/ax-easel-item-diagnostic.swift" || true; })"
  FORBIDDEN_ITEM_LITERAL_HITS="$({ LC_ALL=C grep -Eic 'arc\.net/e/|Untitled Easel|Easel Canvas View' "$GITHUB_WORKSPACE/ax-easel-item-diagnostic.swift" || true; })"
  {
    echo "forbidden_source_api_hits=$FORBIDDEN_SOURCE_API_HITS"
    echo "kaxvalue_attribute_copy_hits=$KAXVALUE_ATTRIBUTE_COPY_HITS"
    echo "forbidden_content_attribute_hits=$FORBIDDEN_CONTENT_ATTRIBUTE_HITS"
    echo "forbidden_item_literal_hits=$FORBIDDEN_ITEM_LITERAL_HITS"
    if [[ "$FORBIDDEN_SOURCE_API_HITS" == 0 && "$KAXVALUE_ATTRIBUTE_COPY_HITS" == 0 && "$FORBIDDEN_CONTENT_ATTRIBUTE_HITS" == 0 && "$FORBIDDEN_ITEM_LITERAL_HITS" == 0 ]]; then
      echo 'diagnostic_source_audit=PASS'
    else
      echo 'diagnostic_source_audit=FAIL'
    fi
  } > "$OUT/diagnostic-source-audit.txt"
  [[ "$FORBIDDEN_SOURCE_API_HITS" == 0 && "$KAXVALUE_ATTRIBUTE_COPY_HITS" == 0 && "$FORBIDDEN_CONTENT_ATTRIBUTE_HITS" == 0 && "$FORBIDDEN_ITEM_LITERAL_HITS" == 0 ]]
  swiftc "$GITHUB_WORKSPACE/ax-easel-item-diagnostic.swift" -o "$RAW/ax-easel-item-diagnostic"
fi
if [[ "${COV_STAGE:-}" == easel-topology-selection-diagnostic ]]; then
  TOPOLOGY_SELECTION_SOURCE="$GITHUB_WORKSPACE/ax-easel-topology-selection-diagnostic.swift"
  FORBIDDEN_SOURCE_API_HITS="$({ LC_ALL=C grep -Ec 'AXUIElementPerformAction|AXUIElementSetAttributeValue|AXUIElementCopyElementAtPosition|AXUIElementCopyParameterizedAttributeValue|CGEvent(Post|Create|Source|Tap)|postToPid|\.post\(tap:|CGWindowListCreateImage|screencapture|NSPasteboard' "$TOPOLOGY_SELECTION_SOURCE" || true; })"
  FORBIDDEN_SELECTION_VALUE_COPY_HITS="$({ LC_ALL=C grep -Ec '(copyAttribute|AXUIElementCopyAttributeValue)\([^,]+,[[:space:]]*kAX(Selected|Focused|SelectedChildren|SelectedRows|SelectedColumns|SelectedCells)Attribute' "$TOPOLOGY_SELECTION_SOURCE" || true; })"
  KAXVALUE_ATTRIBUTE_COPY_HITS="$({ LC_ALL=C grep -Ec 'copyAttribute\([^,]+,[[:space:]]*kAXValueAttribute' "$TOPOLOGY_SELECTION_SOURCE" || true; })"
  FORBIDDEN_CONTENT_ATTRIBUTE_HITS="$({ LC_ALL=C grep -Ec 'kAXDescriptionAttribute|kAXHelpAttribute|kAXURLAttribute|kAXDocumentAttribute|kAXFilenameAttribute' "$TOPOLOGY_SELECTION_SOURCE" || true; })"
  FORBIDDEN_ITEM_LITERAL_HITS="$({ LC_ALL=C grep -Eic 'arc\.net/e/|Untitled Easel|Easel Canvas View' "$TOPOLOGY_SELECTION_SOURCE" || true; })"
  {
    echo "forbidden_source_api_hits=$FORBIDDEN_SOURCE_API_HITS"
    echo "forbidden_selection_value_copy_hits=$FORBIDDEN_SELECTION_VALUE_COPY_HITS"
    echo "kaxvalue_attribute_copy_hits=$KAXVALUE_ATTRIBUTE_COPY_HITS"
    echo "forbidden_content_attribute_hits=$FORBIDDEN_CONTENT_ATTRIBUTE_HITS"
    echo "forbidden_item_literal_hits=$FORBIDDEN_ITEM_LITERAL_HITS"
    if [[ "$FORBIDDEN_SOURCE_API_HITS" == 0 && "$FORBIDDEN_SELECTION_VALUE_COPY_HITS" == 0 && "$KAXVALUE_ATTRIBUTE_COPY_HITS" == 0 && "$FORBIDDEN_CONTENT_ATTRIBUTE_HITS" == 0 && "$FORBIDDEN_ITEM_LITERAL_HITS" == 0 ]]; then
      echo 'topology_selection_source_audit=PASS'
    else
      echo 'topology_selection_source_audit=FAIL'
    fi
  } > "$OUT/topology-selection-source-audit.txt"
  [[ "$FORBIDDEN_SOURCE_API_HITS" == 0 && "$FORBIDDEN_SELECTION_VALUE_COPY_HITS" == 0 && "$KAXVALUE_ATTRIBUTE_COPY_HITS" == 0 && "$FORBIDDEN_CONTENT_ATTRIBUTE_HITS" == 0 && "$FORBIDDEN_ITEM_LITERAL_HITS" == 0 ]]
  swiftc "$TOPOLOGY_SELECTION_SOURCE" -o "$RAW/ax-easel-topology-selection-diagnostic"
fi
open -na "$ARC_APP"
sleep 35
PID_SCAN="$(ps -axo pid=,comm= | awk -v n="$BIN" '
  { pid=$1; $1=""; sub(/^[[:space:]]+/, ""); if ($0 == n) { matches++; selected=pid } }
  END { printf "%d\t%s\n", matches+0, selected }
')"
IFS=$'\t' read -r PID_COUNT PID <<< "$PID_SCAN"
[[ "$PID_COUNT" == 1 ]]
[[ "$PID" =~ ^[0-9]+$ ]]
if [[ "${COV_STAGE:-}" == easel-item-capability-map || "${COV_STAGE:-}" == easel-item-diagnostic || "${COV_STAGE:-}" == easel-topology-selection-diagnostic ]]; then
  "$RAW/ax-process-gate" "$PID" "$BIN" > "$OUT/initial-process-gate.txt"
  {
    echo "timestamp=$(now)"
    echo "pid_count=$(ps -axo command= | grep -F "$ARC_APP/Contents/" | grep -v grep | wc -l | tr -d ' ')"
    echo "generic_ax_map_skipped=true"
    echo "kaxvalue_attribute_reads=0"
    echo "ax_actions_performed=0"
    echo "keyboard_events=0"
    echo "screenshots=0"
    echo "account_actions=0"
    echo "object_actions=0"
  } > "$OUT/preflight-summary.txt"
else
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
fi

if [[ "${COV_STAGE:-}" == easel-topology-selection-diagnostic ]]; then
  [[ "$(ps -p "$PID" -o comm= | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')" == "$BIN" ]]
  "$RAW/ax-process-gate" "$PID" "$BIN" > "$OUT/process-gate.txt"
  "$RAW/ax-login-nav" "$PID" "$BIN" > "$OUT/login-navigation.txt"
  set +e
  "$RAW/ax-login-a-once" "$PID" "$BIN" > "$OUT/login-a-once.txt"
  LOGIN_RC=$?
  unset ARC_EMAIL ARC_PASSWORD
  set -e
  echo "login_rc=$LOGIN_RC" > "$OUT/login-result.txt"
  if (( LOGIN_RC != 0 )); then
    exit "$LOGIN_RC"
  fi

  sleep 60
  "$RAW/ax-process-gate" "$PID" "$BIN" > "$OUT/signed-in-process-gate.txt"
  set +e
  "$RAW/ax-view-easels-once" "$PID" "$BIN" > "$OUT/view-easels-action.txt"
  VIEW_RC=$?
  set -e
  echo "view_easels_rc=$VIEW_RC" > "$OUT/view-easels-result.txt"
  if (( VIEW_RC != 0 )); then
    exit "$VIEW_RC"
  fi

  sleep 15
  "$RAW/ax-process-gate" "$PID" "$BIN" > "$OUT/post-view-process-gate.txt"
  set +e
  "$RAW/ax-easel-topology-selection-diagnostic" "$PID" "$BIN" > "$OUT/easel-topology-selection-diagnostic.txt"
  TOPOLOGY_SELECTION_RC=$?
  set -e
  echo "topology_selection_diagnostic_rc=$TOPOLOGY_SELECTION_RC" > "$OUT/topology-selection-diagnostic-result.txt"
  if (( TOPOLOGY_SELECTION_RC != 0 )); then
    exit "$TOPOLOGY_SELECTION_RC"
  fi

  BAD_SCHEMA_LINES="$({ LC_ALL=C grep -Ev '^[a-z0-9_]+=(true|false|PASS|FAIL|SKIPPED|-?[0-9]+)$' "$OUT/easel-topology-selection-diagnostic.txt" || true; } | wc -l | tr -d ' ')"
  DUPLICATE_KEYS="$(cut -d= -f1 "$OUT/easel-topology-selection-diagnostic.txt" | LC_ALL=C sort | uniq -d | wc -l | tr -d ' ')"
  {
    printf '%s\n' \
      diagnostic_schema declared_no_perform_action_calls declared_no_set_attribute_calls \
      declared_no_selection_value_reads declared_no_event_post_calls declared_no_hit_test_calls \
      declared_no_parameterized_value_calls declared_no_screenshot_calls declared_no_pasteboard_calls \
      easel_item_title_reads easel_item_static_content_reads easel_item_description_reads \
      easel_item_help_reads easel_web_url_attribute_reads easel_route_reads \
      known_chrome_title_gates_enabled known_search_placeholder_gate_enabled process_gate
    for snapshot in snapshot1 snapshot2; do
      for key in \
        standard_window_count library_candidate_count grid_count image_count label_count canvas_count \
        sign_out_count close_library_count hide_easels_count \
        canvas_path_present canvas_role_exact canvas_subrole_exact canvas_identifier_exact canvas_tuple_exact \
        window_unique candidate_unique grid_unique image_unique label_unique canvas_unique \
        window_fixed_equal candidate_fixed_equal grid_fixed_equal image_fixed_equal label_fixed_equal canvas_fixed_equal \
        core_path_ready uniqueness_ready fixed_identity_ready menu_paths_ready window_main window_focused \
        sheet_dialog_popover_count secure_login_field_count parent_chain_ready parent_error_count \
        parent_first_error_rc pid_equality_ready pid_error_count pid_first_error_rc \
        candidate_descendant_of_canvas fixed_child_error_count fixed_child_first_error_rc depth_ready topology_ready; do
        echo "${snapshot}_${key}"
      done
      for menu in sign_out close_library hide_easels; do
        for key in path_present role_exact subrole_exact identifier_exact title_exact enabled_exact value_settable_exact actions_exact tuple_exact; do
          echo "${snapshot}_menu_${menu}_${key}"
        done
      done
      for node in grid image label; do
        printf '%s\n' \
          "${snapshot}_${node}_attribute_names_rc" \
          "${snapshot}_${node}_attribute_names_count" \
          "${snapshot}_${node}_attribute_names_type_correct"
        for attribute in selected focused selected_children selected_rows selected_columns selected_cells; do
          printf '%s\n' \
            "${snapshot}_${node}_${attribute}_advertised" \
            "${snapshot}_${node}_${attribute}_settable_rc" \
            "${snapshot}_${node}_${attribute}_settable"
        done
      done
      echo "${snapshot}_semantic_selection_candidate_count"
      echo "${snapshot}_focus_candidate_count"
    done
    printf '%s\n' snapshot2_process_gate selection_probe_stable selection_capability_ready diagnostic_complete
  } | LC_ALL=C sort > "$RAW/topology-selection-required-keys.txt"
  cut -d= -f1 "$OUT/easel-topology-selection-diagnostic.txt" | LC_ALL=C sort > "$RAW/topology-selection-actual-keys.txt"
  MISSING_KEYS="$(comm -23 "$RAW/topology-selection-required-keys.txt" "$RAW/topology-selection-actual-keys.txt" | wc -l | tr -d ' ')"
  EXTRA_KEYS="$(comm -13 "$RAW/topology-selection-required-keys.txt" "$RAW/topology-selection-actual-keys.txt" | wc -l | tr -d ' ')"
  [[ "$BAD_SCHEMA_LINES" == 0 && "$DUPLICATE_KEYS" == 0 && "$MISSING_KEYS" == 0 && "$EXTRA_KEYS" == 0 ]]
  grep -Fxq 'diagnostic_schema=2' "$OUT/easel-topology-selection-diagnostic.txt"
  grep -Fxq 'diagnostic_complete=true' "$OUT/easel-topology-selection-diagnostic.txt"

  SELECTION_READY="$(awk -F= '$1=="selection_capability_ready"{print $2}' "$OUT/easel-topology-selection-diagnostic.txt")"
  [[ "$SELECTION_READY" == true || "$SELECTION_READY" == false ]]
  [[ -z "${ARC_EMAIL+x}" && -z "${ARC_PASSWORD+x}" ]]

  ROUTE_HITS="$({ LC_ALL=C grep -ERai '(^|[^A-Za-z0-9.-])(https://)?arc\.net/e/[A-Za-z0-9_-]{8,128}([^A-Za-z0-9_-]|$)' "$OUT" || true; } | wc -l | tr -d ' ')"
  EMAIL_HITS="$({ LC_ALL=C grep -ERai '[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}' "$OUT" || true; } | wc -l | tr -d ' ')"
  GENERIC_SECRET_HITS="$({ LC_ALL=C grep -ERa -- '-----BEGIN (RSA|EC|OPENSSH|DSA|PGP) PRIVATE KEY-----|github_pat_[A-Za-z0-9_]+|gh[pousr]_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|Bearer[[:space:]]+[A-Za-z0-9._~+/=-]{16,}|eyJ[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{8,}' "$OUT" || true; } | wc -l | tr -d ' ')"
  ITEM_CONTENT_HITS="$({ LC_ALL=C grep -ERai 'Untitled Easel|Easel Canvas View' "$OUT" || true; } | wc -l | tr -d ' ')"
  {
    echo "exact_arc_easel_route_hits=$ROUTE_HITS"
    echo "email_pattern_hits=$EMAIL_HITS"
    echo "generic_secret_pattern_hits=$GENERIC_SECRET_HITS"
    echo "item_content_pattern_hits=$ITEM_CONTENT_HITS"
    echo "credential_environment_names_present=0"
    echo "exact_secret_value_scan=unavailable_encrypted_repository_secrets"
  } > "$OUT/topology-selection-route-secret-scan.txt"
  [[ "$ROUTE_HITS" == 0 && "$EMAIL_HITS" == 0 && "$GENERIC_SECRET_HITS" == 0 && "$ITEM_CONTENT_HITS" == 0 ]]

  {
    echo "login_rc=$LOGIN_RC"
    echo "view_easels_rc=$VIEW_RC"
    echo "topology_selection_diagnostic_rc=$TOPOLOGY_SELECTION_RC"
    echo "diagnostic_complete=1"
    echo "workflow_success_instrumentation_only=true"
    echo "selection_capability_ready=$SELECTION_READY"
    echo "login_navigation_actions=3"
    echo "sign_in_press=1"
    echo "view_easels_press=1"
    echo "view_easels_retries=0"
    echo "diagnostic_action_invocations=0"
    echo "selection_value_reads=0"
    echo "item_value_reads=0"
    echo "parameterized_value_invocations=0"
    echo "scroll_to_visible_invocations=0"
    echo "show_menu_invocations=0"
    echo "context_menu_actions=0"
    echo "right_clicks=0"
    echo "delete_actions=0"
    echo "new_easel_actions=0"
    echo "content_actions=0"
    echo "marker_actions=0"
    echo "share_actions=0"
    echo "confirm_actions=0"
    echo "cancel_actions=0"
    echo "sign_out_actions=0"
    echo "screenshots=0"
    echo "objects_created=0"
  } > "$OUT/easel-topology-selection-diagnostic-summary.txt"
fi

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
  if (( INPUT_RC != 0 )); then
    exit "$INPUT_RC"
  fi
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

if [[ "${COV_STAGE:-}" == signup-a-secure-opaque ]]; then
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
  "$RAW/ax-signup-secure-opaque" "$PID" > "$OUT/action-signup-secure-opaque.txt"
  INPUT_RC=$?
  unset ARC_NAME ARC_EMAIL ARC_PASSWORD
  set -e
  echo "input_rc=$INPUT_RC" > "$OUT/input-result.txt"
  if (( INPUT_RC != 0 )); then
    exit "$INPUT_RC"
  fi
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

if [[ "${COV_STAGE:-}" == privacy-geometry ]]; then
  "$RAW/ax-step" "$PID" right > "$OUT/action-right.txt"
  sleep 8
  "$RAW/ax-map" "$PID" > "$OUT/ax-tree-signup.tsv"
  [[ "$(ps -p "$PID" -o comm= | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')" == "$BIN" ]]
  "$RAW/ax-process-gate" "$PID" "$BIN" > "$OUT/process-gate.txt"
  "$RAW/ax-geometry" "$PID" > "$OUT/privacy-geometry.txt"
  {
    echo "form_navigation_actions=1"
    echo "privacy_actions=0"
    echo "keyboard_events=0"
    echo "screenshots=0"
    echo "credential_actions=0"
    echo "account_actions=0"
    echo "object_actions=0"
    echo "share_actions=0"
  } > "$OUT/privacy-geometry-summary.txt"
fi

if [[ "${COV_STAGE:-}" == checkbox-calibration ]]; then
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
  "$RAW/ax-checkbox-calibration" "$PID" > "$OUT/checkbox-calibration.txt"
  CALIBRATION_RC=$?
  unset ARC_NAME ARC_EMAIL ARC_PASSWORD
  set -e
  echo "calibration_rc=$CALIBRATION_RC" > "$OUT/calibration-result.txt"
  if (( CALIBRATION_RC != 0 )); then
    exit "$CALIBRATION_RC"
  fi
  "$RAW/ax-map" "$PID" > "$OUT/ax-tree-post-calibration.tsv"
  {
    echo "create_press=0"
    echo "account_actions=0"
    echo "object_actions=0"
    echo "share_actions=0"
    echo "screenshots=0"
  } > "$OUT/calibration-summary.txt"
fi

if [[ "${COV_STAGE:-}" == checkbox-calibration-hid ]]; then
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
  "$RAW/ax-checkbox-calibration-hid" "$PID" > "$OUT/checkbox-calibration-hid.txt"
  CALIBRATION_RC=$?
  unset ARC_NAME ARC_EMAIL ARC_PASSWORD
  set -e
  echo "calibration_rc=$CALIBRATION_RC" > "$OUT/calibration-result.txt"
  if (( CALIBRATION_RC != 0 )); then
    exit "$CALIBRATION_RC"
  fi
  "$RAW/ax-map" "$PID" > "$OUT/ax-tree-post-calibration.tsv"
  {
    echo "create_press=0"
    echo "account_actions=0"
    echo "object_actions=0"
    echo "share_actions=0"
    echo "screenshots=0"
  } > "$OUT/calibration-summary.txt"
fi

if [[ "${COV_STAGE:-}" == create-account-a ]]; then
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
  "$RAW/ax-create-account" "$PID" > "$OUT/create-account.txt"
  CREATE_RC=$?
  unset ARC_NAME ARC_EMAIL ARC_PASSWORD
  set -e
  echo "create_rc=$CREATE_RC" > "$OUT/create-result.txt"
  sleep 60
  "$RAW/ax-map" "$PID" > "$OUT/ax-tree-post-create.tsv"

  FORM_HITS="$(awk -F '\t' '$4=="Name" || $4=="Email" || $4=="Password" || $4=="Confirm Password" || $4=="PrivacyCheckbox" || $6=="Create an account" {n++} END{print n+0}' "$OUT/ax-tree-post-create.tsv")"
  NEW_EASEL_HITS="$(awk -F '\t' '$2=="AXMenuItem" && $4=="newEaselMenuItemId" && $5=="New Easel" && $9=="true" && $11=="AXCancel,AXPick,AXPress" {n++} END{print n+0}' "$OUT/ax-tree-post-create.tsv")"
  VIEW_LIBRARY_HITS="$(awk -F '\t' '$2=="AXMenuItem" && $5=="View Library" && $9=="true" && $11=="AXCancel,AXPick,AXPress" {n++} END{print n+0}' "$OUT/ax-tree-post-create.tsv")"
  VIEW_EASELS_HITS="$(awk -F '\t' '$2=="AXMenuItem" && $5=="View Easels & Notes" && $9=="true" && $11=="AXCancel,AXPick,AXPress" {n++} END{print n+0}' "$OUT/ax-tree-post-create.tsv")"
  awk -F '\t' 'tolower($0) ~ /account preferences|delete account|sign out/ {print}' "$OUT/ax-tree-post-create.tsv" > "$OUT/account-cleanup-candidates.tsv"
  {
    echo "create_rc=$CREATE_RC"
    echo "form_hits=$FORM_HITS"
    echo "new_easel_exact_enabled_hits=$NEW_EASEL_HITS"
    echo "view_library_exact_enabled_hits=$VIEW_LIBRARY_HITS"
    echo "view_easels_exact_enabled_hits=$VIEW_EASELS_HITS"
    echo "cleanup_candidate_rows=$(wc -l < "$OUT/account-cleanup-candidates.tsv" | tr -d ' ')"
    echo "object_actions=0"
    echo "share_actions=0"
  } > "$OUT/post-create-gates.txt"
  if (( CREATE_RC != 0 )) || (( FORM_HITS != 0 )) || (( NEW_EASEL_HITS != 1 )) || (( VIEW_LIBRARY_HITS != 1 )) || (( VIEW_EASELS_HITS != 1 )); then
    exit 220
  fi
fi

if [[ "${COV_STAGE:-}" == recovery-signin-map ]]; then
  [[ "$(ps -p "$PID" -o comm= | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')" == "$BIN" ]]
  "$RAW/ax-process-gate" "$PID" "$BIN" > "$OUT/process-gate.txt"
  "$RAW/ax-step" "$PID" signin > "$OUT/action-signin.txt"
  sleep 8
  "$RAW/ax-map" "$PID" > "$OUT/ax-tree-signin.tsv"
  {
    echo "signin_form_nodes=$(($(wc -l < "$OUT/ax-tree-signin.tsv")-1))"
    echo "email_identifier_hits=$(awk -F '\t' '$4==\"Email\"{n++} END{print n+0}' "$OUT/ax-tree-signin.tsv")"
    echo "password_identifier_hits=$(awk -F '\t' '$4==\"Password\"{n++} END{print n+0}' "$OUT/ax-tree-signin.tsv")"
    echo "signin_description_hits=$(awk -F '\t' '$6==\"Sign in\" || $6==\"Sign In\"{n++} END{print n+0}' "$OUT/ax-tree-signin.tsv")"
    echo "ax_values_read=0"
    echo "ax_values_written=0"
    echo "keyboard_events=0"
    echo "screenshots=0"
    echo "account_state_actions=0"
    echo "object_actions=0"
    echo "share_actions=0"
  } > "$OUT/recovery-signin-map-summary.txt"
fi

if [[ "${COV_STAGE:-}" == login-form-map ]]; then
  [[ "$(ps -p "$PID" -o comm= | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')" == "$BIN" ]]
  "$RAW/ax-process-gate" "$PID" "$BIN" > "$OUT/process-gate.txt"
  "$RAW/ax-login-nav" "$PID" "$BIN" > "$OUT/login-navigation.txt"
  "$RAW/ax-map" "$PID" > "$OUT/ax-tree-login-form.tsv"
  EMAIL_HITS="$(grep -Ec $'^[^\t]+\tAXTextField\t[^\t]*\tEmail\t' "$OUT/ax-tree-login-form.tsv" || true)"
  PASSWORD_HITS="$(grep -Ec $'^[^\t]+\tAXTextField\t[^\t]*\tPassword\t' "$OUT/ax-tree-login-form.tsv" || true)"
  SIGNIN_HITS="$(grep -Ec $'^[^\t]+\tAXButton\t[^\t]*\t[^\t]*\t[^\t]*\tSign in\t' "$OUT/ax-tree-login-form.tsv" || true)"
  {
    echo "login_form_nodes=$(($(wc -l < "$OUT/ax-tree-login-form.tsv")-1))"
    echo "email_identifier_hits=$EMAIL_HITS"
    echo "password_identifier_hits=$PASSWORD_HITS"
    echo "signin_description_hits=$SIGNIN_HITS"
    echo "ax_values_read=0"
    echo "ax_values_written=0"
    echo "keyboard_events=0"
    echo "screenshots=0"
    echo "account_state_actions=0"
    echo "object_actions=0"
    echo "share_actions=0"
  } > "$OUT/login-form-map-summary.txt"
fi

if [[ "${COV_STAGE:-}" == login-input-calibration ]]; then
  [[ "$(ps -p "$PID" -o comm= | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')" == "$BIN" ]]
  "$RAW/ax-process-gate" "$PID" "$BIN" > "$OUT/process-gate.txt"
  "$RAW/ax-login-nav" "$PID" "$BIN" > "$OUT/login-navigation.txt"
  "$RAW/ax-map" "$PID" > "$OUT/ax-tree-login-form.tsv"
  set +e
  "$RAW/ax-login-input-calibration" "$PID" "$BIN" > "$OUT/login-input-calibration.txt"
  CALIBRATION_RC=$?
  unset ARC_EMAIL ARC_PASSWORD
  set -e
  echo "calibration_rc=$CALIBRATION_RC" > "$OUT/calibration-result.txt"
  if (( CALIBRATION_RC != 0 )); then
    exit "$CALIBRATION_RC"
  fi
  "$RAW/ax-map" "$PID" > "$OUT/ax-tree-post-calibration.tsv"
  {
    echo "navigation_actions=3"
    echo "pid_scoped_unicode_fields=2"
    echo "email_in_memory_length_hash_checks=1"
    echo "password_post_input_reads=0"
    echo "sign_in_state_transitions=2"
    echo "sign_in_press=0"
    echo "cleared_fields=2"
    echo "screenshots=0"
    echo "account_state_actions=0"
    echo "object_actions=0"
    echo "share_actions=0"
    echo "backend_actions=0"
    echo "credential_values_logged=0"
  } > "$OUT/login-input-calibration-summary.txt"
fi

if [[ "${COV_STAGE:-}" == login-a-once ]]; then
  [[ "$(ps -p "$PID" -o comm= | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')" == "$BIN" ]]
  "$RAW/ax-process-gate" "$PID" "$BIN" > "$OUT/process-gate.txt"
  "$RAW/ax-login-nav" "$PID" "$BIN" > "$OUT/login-navigation.txt"
  "$RAW/ax-map" "$PID" > "$OUT/ax-tree-login-form.tsv"
  set +e
  "$RAW/ax-login-a-once" "$PID" "$BIN" > "$OUT/login-a-once.txt"
  LOGIN_RC=$?
  unset ARC_EMAIL ARC_PASSWORD
  set -e
  echo "login_rc=$LOGIN_RC" > "$OUT/login-result.txt"
  if (( LOGIN_RC != 0 )); then
    exit "$LOGIN_RC"
  fi

  sleep 60
  "$RAW/ax-process-gate" "$PID" "$BIN" > "$OUT/post-login-process-gate.txt"
  "$RAW/ax-map" "$PID" > "$OUT/ax-tree-post-login.tsv"
  NEXT_HITS="$(awk -F '\t' '$1=="A/0/0/15" && $2=="AXButton" && $3=="" && $4=="" && $5=="" && $6=="Next" && $9=="true" && $10=="false" && $11=="AXPress" {n++} END{print n+0}' "$OUT/ax-tree-post-login.tsv")"
  SKIP_HITS="$(awk -F '\t' '$1=="A/0/0/16" && $2=="AXButton" && $3=="" && $4=="" && $5=="" && $6=="Skip for now" && $9=="true" && $10=="false" && $11=="AXPress" {n++} END{print n+0}' "$OUT/ax-tree-post-login.tsv")"
  SIGNOUT_HITS="$(awk -F '\t' '$1=="A/1/1/0/15" && $2=="AXMenuItem" && $3=="" && $4=="_NS:1753" && $5=="Sign Out" && $6=="" && $9=="true" && $10=="false" && $11=="AXCancel,AXPick,AXPress" {n++} END{print n+0}' "$OUT/ax-tree-post-login.tsv")"
  LOGIN_FORM_HITS="$(awk -F '\t' '($1=="A/0/0/6" && $2=="AXTextField" && $4=="Email") || ($1=="A/0/0/8" && $2=="AXTextField" && $3=="AXSecureTextField" && $4=="Password") || ($1=="A/0/0/10" && $2=="AXButton" && $6=="Sign in") {n++} END{print n+0}' "$OUT/ax-tree-post-login.tsv")"
  POST_STATE=unknown_fail_closed
  if (( NEXT_HITS == 1 && SKIP_HITS == 1 && SIGNOUT_HITS == 1 && LOGIN_FORM_HITS == 0 )); then
    POST_STATE=known_optional_services
  fi
  {
    echo "login_rc=$LOGIN_RC"
    echo "post_state=$POST_STATE"
    echo "next_exact_hits=$NEXT_HITS"
    echo "skip_exact_hits=$SKIP_HITS"
    echo "sign_out_exact_hits=$SIGNOUT_HITS"
    echo "login_form_exact_hits=$LOGIN_FORM_HITS"
    echo "navigation_actions=3"
    echo "pid_scoped_unicode_fields=2"
    echo "email_in_memory_length_hash_checks=1"
    echo "password_post_input_reads=0"
    echo "sign_in_press=1"
    echo "sign_in_retries=0"
    echo "post_login_ax_actions=0"
    echo "account_state_actions=1"
    echo "onboarding_actions=0"
    echo "screenshots=0"
    echo "object_actions=0"
    echo "share_actions=0"
    echo "other_backend_actions=0"
    echo "credential_values_logged=0"
  } > "$OUT/login-a-once-summary.txt"
  [[ "$POST_STATE" == known_optional_services ]] || exit 88
fi

if [[ "${COV_STAGE:-}" == favorite-selector-map ]]; then
  [[ "$(ps -p "$PID" -o comm= | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')" == "$BIN" ]]
  "$RAW/ax-process-gate" "$PID" "$BIN" > "$OUT/process-gate.txt"
  "$RAW/ax-login-nav" "$PID" "$BIN" > "$OUT/login-navigation.txt"
  set +e
  "$RAW/ax-login-a-once" "$PID" "$BIN" > "$OUT/login-a-once.txt"
  LOGIN_RC=$?
  unset ARC_EMAIL ARC_PASSWORD
  set -e
  echo "login_rc=$LOGIN_RC" > "$OUT/login-result.txt"
  if (( LOGIN_RC != 0 )); then
    exit "$LOGIN_RC"
  fi
  sleep 60
  "$RAW/ax-process-gate" "$PID" "$BIN" > "$OUT/post-login-process-gate.txt"
  "$RAW/ax-favorite-selector-map" "$PID" "$BIN" > "$OUT/favorite-selector-map-1.tsv"
  sleep 4
  "$RAW/ax-process-gate" "$PID" "$BIN" > "$OUT/post-login-process-gate-2.txt"
  "$RAW/ax-favorite-selector-map" "$PID" "$BIN" > "$OUT/favorite-selector-map-2.tsv"
  cmp "$OUT/favorite-selector-map-1.tsv" "$OUT/favorite-selector-map-2.tsv"
  FAVORITE_ROWS="$(awk -F '\t' 'NR>1 && tolower($0) ~ /favorite|top app/ {n++} END{print n+0}' "$OUT/favorite-selector-map-1.tsv")"
  PREVIEW_ROWS="$(awk -F '\t' 'NR>1 && tolower($0) ~ /preview|outlook|google calendar/ {n++} END{print n+0}' "$OUT/favorite-selector-map-1.tsv")"
  MOVE_ROWS="$(awk -F '\t' 'NR>1 && tolower($0) ~ /move to|pin tab|pinned/ {n++} END{print n+0}' "$OUT/favorite-selector-map-1.tsv")"
  {
    echo "login_rc=$LOGIN_RC"
    echo "stable_maps=2"
    echo "map_byte_equal=true"
    echo "favorite_or_top_app_rows=$FAVORITE_ROWS"
    echo "preview_or_provider_rows=$PREVIEW_ROWS"
    echo "move_or_pin_rows=$MOVE_ROWS"
    echo "login_navigation_actions=3"
    echo "sign_in_press=1"
    echo "post_login_ax_actions=0"
    echo "tab_actions=0"
    echo "favorite_actions=0"
    echo "preview_actions=0"
    echo "provider_actions=0"
    echo "easel_actions=0"
    echo "screenshots=0"
    echo "ax_value_reads=0"
    echo "ax_value_writes=0"
  } > "$OUT/favorite-selector-summary.txt"
fi

if [[ "${COV_STAGE:-}" == view-easels-map ]]; then
  [[ "$(ps -p "$PID" -o comm= | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')" == "$BIN" ]]
  "$RAW/ax-process-gate" "$PID" "$BIN" > "$OUT/process-gate.txt"
  "$RAW/ax-login-nav" "$PID" "$BIN" > "$OUT/login-navigation.txt"
  "$RAW/ax-map" "$PID" > "$OUT/ax-tree-login-form.tsv"
  set +e
  "$RAW/ax-login-a-once" "$PID" "$BIN" > "$OUT/login-a-once.txt"
  LOGIN_RC=$?
  unset ARC_EMAIL ARC_PASSWORD
  set -e
  echo "login_rc=$LOGIN_RC" > "$OUT/login-result.txt"
  if (( LOGIN_RC != 0 )); then
    exit "$LOGIN_RC"
  fi

  sleep 60
  "$RAW/ax-process-gate" "$PID" "$BIN" > "$OUT/signed-in-process-gate.txt"
  "$RAW/ax-map" "$PID" > "$OUT/ax-tree-signed-in.tsv"
  set +e
  "$RAW/ax-view-easels-once" "$PID" "$BIN" > "$OUT/view-easels-action.txt"
  VIEW_RC=$?
  set -e
  echo "view_easels_rc=$VIEW_RC" > "$OUT/view-easels-result.txt"
  if (( VIEW_RC != 0 )); then
    exit "$VIEW_RC"
  fi

  sleep 15
  "$RAW/ax-process-gate" "$PID" "$BIN" > "$OUT/post-view-process-gate.txt"
  "$RAW/ax-map" "$PID" > "$OUT/ax-tree-view-easels.tsv"
  WINDOW_ROWS="$(awk -F '\t' '$2=="AXWindow" {n++} END{print n+0}' "$OUT/ax-tree-view-easels.tsv")"
  MENU_ROWS="$(awk -F '\t' '$2=="AXMenuItem" {n++} END{print n+0}' "$OUT/ax-tree-view-easels.tsv")"
  NEW_EASEL_HITS="$(awk -F '\t' '$2=="AXMenuItem" && $4=="newEaselMenuItemId" && $5=="New Easel" && $9=="true" && $11=="AXCancel,AXPick,AXPress" {n++} END{print n+0}' "$OUT/ax-tree-view-easels.tsv")"
  DELETE_ENABLED_HITS="$(awk -F '\t' '$2=="AXMenuItem" && $5=="Delete" && $9=="true" && $11=="AXCancel,AXPick,AXPress" {n++} END{print n+0}' "$OUT/ax-tree-view-easels.tsv")"
  DELETE_ANY_HITS="$(awk -F '\t' '$2=="AXMenuItem" && $5=="Delete" {n++} END{print n+0}' "$OUT/ax-tree-view-easels.tsv")"
  {
    echo "login_rc=$LOGIN_RC"
    echo "view_easels_rc=$VIEW_RC"
    echo "post_view_nodes=$(($(wc -l < "$OUT/ax-tree-view-easels.tsv")-1))"
    echo "post_view_window_rows=$WINDOW_ROWS"
    echo "post_view_menu_rows=$MENU_ROWS"
    echo "new_easel_exact_enabled_hits=$NEW_EASEL_HITS"
    echo "delete_exact_enabled_hits=$DELETE_ENABLED_HITS"
    echo "delete_exact_any_hits=$DELETE_ANY_HITS"
    echo "login_navigation_actions=3"
    echo "sign_in_press=1"
    echo "view_easels_press=1"
    echo "retries=0"
    echo "post_view_ax_actions=0"
    echo "post_view_map_ax_values_read=0"
    echo "post_view_map_ax_values_written=0"
    echo "screenshots=0"
    echo "context_menu_actions=0"
    echo "right_clicks=0"
    echo "delete_actions=0"
    echo "new_easel_actions=0"
    echo "share_actions=0"
    echo "onboarding_actions=0"
    echo "sign_out_actions=0"
  } > "$OUT/view-easels-map-summary.txt"
fi

if [[ "${COV_STAGE:-}" == create-blank-easel-map ]]; then
  [[ "$(ps -p "$PID" -o comm= | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')" == "$BIN" ]]
  "$RAW/ax-process-gate" "$PID" "$BIN" > "$OUT/process-gate.txt"
  "$RAW/ax-login-nav" "$PID" "$BIN" > "$OUT/login-navigation.txt"
  "$RAW/ax-map" "$PID" > "$OUT/ax-tree-login-form.tsv"
  set +e
  "$RAW/ax-login-a-once" "$PID" "$BIN" > "$OUT/login-a-once.txt"
  LOGIN_RC=$?
  unset ARC_EMAIL ARC_PASSWORD
  set -e
  echo "login_rc=$LOGIN_RC" > "$OUT/login-result.txt"
  if (( LOGIN_RC != 0 )); then
    exit "$LOGIN_RC"
  fi

  sleep 60
  "$RAW/ax-process-gate" "$PID" "$BIN" > "$OUT/signed-in-process-gate.txt"
  "$RAW/ax-view-easels-once" "$PID" "$BIN" > "$OUT/view-empty-action.txt"
  sleep 15
  "$RAW/ax-process-gate" "$PID" "$BIN" > "$OUT/empty-overlay-process-gate.txt"
  "$RAW/ax-map" "$PID" > "$OUT/ax-tree-empty-overlay.tsv"
  EMPTY_ITEM_ROLES="$(awk -F '\t' '$1 ~ /^A\/0\/0(\/|$)/ && ($2=="AXRow" || $2=="AXCell" || $2=="AXList" || $2=="AXOutline" || $2=="AXTable") {n++} END{print n+0}' "$OUT/ax-tree-empty-overlay.tsv")"
  EMPTY_DELETE_ENABLED="$(awk -F '\t' '$2=="AXMenuItem" && $5=="Delete" && $9=="true" {n++} END{print n+0}' "$OUT/ax-tree-empty-overlay.tsv")"
  EMPTY_SEARCH="$(awk -F '\t' '$1=="A/0/0/4" && $2=="AXTextField" && $8=="Search Easels…" && $9=="true" && $10=="true" && $11=="AXConfirm,AXShowMenu" {n++} END{print n+0}' "$OUT/ax-tree-empty-overlay.tsv")"
  [[ "$EMPTY_ITEM_ROLES" == 0 && "$EMPTY_DELETE_ENABLED" == 0 && "$EMPTY_SEARCH" == 1 ]]

  set +e
  "$RAW/ax-create-blank-easel-once" "$PID" "$BIN" > "$OUT/create-blank-easel-action.txt"
  CREATE_RC=$?
  set -e
  echo "create_blank_rc=$CREATE_RC" > "$OUT/create-blank-result.txt"
  if (( CREATE_RC != 0 )); then
    exit "$CREATE_RC"
  fi

  sleep 20
  "$RAW/ax-process-gate" "$PID" "$BIN" > "$OUT/post-create-process-gate.txt"
  "$RAW/ax-easel-route-hash" "$PID" "$BIN" > "$OUT/easel-route-hash.txt"
  "$RAW/ax-map" "$PID" | LC_ALL=C sed -E 's#(https://)?arc\.net/e/[A-Za-z0-9_-]{8,128}#[REDACTED_EASEL_ROUTE]#g' > "$OUT/ax-tree-blank-postcreate.tsv"

  "$RAW/ax-view-easels-once" "$PID" "$BIN" > "$OUT/view-postcreate-action.txt"
  sleep 15
  "$RAW/ax-process-gate" "$PID" "$BIN" > "$OUT/post-reopen-process-gate.txt"
  "$RAW/ax-map" "$PID" | LC_ALL=C sed -E 's#(https://)?arc\.net/e/[A-Za-z0-9_-]{8,128}#[REDACTED_EASEL_ROUTE]#g' > "$OUT/ax-tree-postcreate-library.tsv"
  POST_WINDOWS="$(awk -F '\t' '$2=="AXWindow" {n++} END{print n+0}' "$OUT/ax-tree-postcreate-library.tsv")"
  POST_MENU_ROWS="$(awk -F '\t' '$2=="AXMenuItem" {n++} END{print n+0}' "$OUT/ax-tree-postcreate-library.tsv")"
  POST_ITEM_ROLES="$(awk -F '\t' '$1 ~ /^A\/0\/0(\/|$)/ && ($2=="AXRow" || $2=="AXCell" || $2=="AXList" || $2=="AXOutline" || $2=="AXTable") {n++} END{print n+0}' "$OUT/ax-tree-postcreate-library.tsv")"
  POST_DELETE_ENABLED="$(awk -F '\t' '$2=="AXMenuItem" && $5=="Delete" && $9=="true" {n++} END{print n+0}' "$OUT/ax-tree-postcreate-library.tsv")"
  POST_DELETE_ANY="$(awk -F '\t' '$2=="AXMenuItem" && $5=="Delete" {n++} END{print n+0}' "$OUT/ax-tree-postcreate-library.tsv")"
  POST_SEARCH="$(awk -F '\t' '$2=="AXTextField" && $8=="Search Easels…" && $9=="true" && $10=="true" && $11=="AXConfirm,AXShowMenu" {n++} END{print n+0}' "$OUT/ax-tree-postcreate-library.tsv")"
  POST_CLOSE="$(awk -F '\t' '$2=="AXMenuItem" && $4=="_NS:451" && $5=="Close Library" && $9=="true" && $11=="AXCancel,AXPick,AXPress" {n++} END{print n+0}' "$OUT/ax-tree-postcreate-library.tsv")"
  POST_HIDE="$(awk -F '\t' '$2=="AXMenuItem" && $4=="_NS:1516" && $5=="Hide Easels" && $9=="true" && $11=="AXCancel,AXPick,AXPress" {n++} END{print n+0}' "$OUT/ax-tree-postcreate-library.tsv")"
  {
    echo "login_rc=$LOGIN_RC"
    echo "create_blank_rc=$CREATE_RC"
    echo "precreate_item_structural_roles=$EMPTY_ITEM_ROLES"
    echo "precreate_enabled_delete_rows=$EMPTY_DELETE_ENABLED"
    echo "precreate_search_easels_exact_hits=$EMPTY_SEARCH"
    echo "blank_postcreate_nodes=$(($(wc -l < "$OUT/ax-tree-blank-postcreate.tsv")-1))"
    echo "postcreate_library_nodes=$(($(wc -l < "$OUT/ax-tree-postcreate-library.tsv")-1))"
    echo "postcreate_window_rows=$POST_WINDOWS"
    echo "postcreate_menu_rows=$POST_MENU_ROWS"
    echo "postcreate_item_structural_roles=$POST_ITEM_ROLES"
    echo "postcreate_enabled_delete_rows=$POST_DELETE_ENABLED"
    echo "postcreate_any_delete_rows=$POST_DELETE_ANY"
    echo "postcreate_search_easels_hits=$POST_SEARCH"
    echo "postcreate_close_library_hits=$POST_CLOSE"
    echo "postcreate_hide_easels_hits=$POST_HIDE"
    echo "login_navigation_actions=3"
    echo "sign_in_press=1"
    echo "view_easels_presses=2"
    echo "close_library_press=1"
    echo "new_easel_press=1"
    echo "new_easel_retries=0"
    echo "objects_created_max=1"
    echo "content_actions=0"
    echo "marker_actions=0"
    echo "share_actions=0"
    echo "context_menu_actions=0"
    echo "right_clicks=0"
    echo "delete_actions=0"
    echo "confirm_actions=0"
    echo "cancel_actions=0"
    echo "screenshots=0"
    echo "raw_url_emitted=0"
    echo "raw_id_emitted=0"
  } > "$OUT/create-blank-easel-map-summary.txt"
fi

if [[ "${COV_STAGE:-}" == easel-item-capability-map ]]; then
  [[ "$(ps -p "$PID" -o comm= | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')" == "$BIN" ]]
  "$RAW/ax-process-gate" "$PID" "$BIN" > "$OUT/process-gate.txt"
  "$RAW/ax-login-nav" "$PID" "$BIN" > "$OUT/login-navigation.txt"
  set +e
  "$RAW/ax-login-a-once" "$PID" "$BIN" > "$OUT/login-a-once.txt"
  LOGIN_RC=$?
  unset ARC_EMAIL ARC_PASSWORD
  set -e
  echo "login_rc=$LOGIN_RC" > "$OUT/login-result.txt"
  if (( LOGIN_RC != 0 )); then
    exit "$LOGIN_RC"
  fi

  sleep 60
  "$RAW/ax-process-gate" "$PID" "$BIN" > "$OUT/signed-in-process-gate.txt"
  set +e
  "$RAW/ax-view-easels-once" "$PID" "$BIN" > "$OUT/view-easels-action.txt"
  VIEW_RC=$?
  set -e
  echo "view_easels_rc=$VIEW_RC" > "$OUT/view-easels-result.txt"
  if (( VIEW_RC != 0 )); then
    exit "$VIEW_RC"
  fi

  sleep 15
  "$RAW/ax-process-gate" "$PID" "$BIN" > "$OUT/post-view-process-gate.txt"
  set +e
  "$RAW/ax-easel-item-capability" "$PID" "$BIN" > "$OUT/easel-item-capability.txt"
  CAPABILITY_RC=$?
  set -e
  echo "capability_rc=$CAPABILITY_RC" > "$OUT/capability-result.txt"
  if (( CAPABILITY_RC != 0 )); then
    exit "$CAPABILITY_RC"
  fi

  [[ -z "${ARC_EMAIL+x}" && -z "${ARC_PASSWORD+x}" ]]
  ROUTE_HITS="$({ LC_ALL=C grep -ERai '(^|[^A-Za-z0-9.-])(https://)?arc\.net/e/[A-Za-z0-9_-]{8,128}([^A-Za-z0-9_-]|$)' "$OUT" || true; } | wc -l | tr -d ' ')"
  EMAIL_HITS="$({ LC_ALL=C grep -ERai '[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}' "$OUT" || true; } | wc -l | tr -d ' ')"
  GENERIC_SECRET_HITS="$({ LC_ALL=C grep -ERa -- '-----BEGIN (RSA|EC|OPENSSH|DSA|PGP) PRIVATE KEY-----|github_pat_[A-Za-z0-9_]+|gh[pousr]_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|Bearer[[:space:]]+[A-Za-z0-9._~+/=-]{16,}|eyJ[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{8,}' "$OUT" || true; } | wc -l | tr -d ' ')"
  {
    echo "exact_arc_easel_route_hits=$ROUTE_HITS"
    echo "email_pattern_hits=$EMAIL_HITS"
    echo "generic_secret_pattern_hits=$GENERIC_SECRET_HITS"
    echo "credential_environment_names_present=0"
    echo "exact_secret_value_scan=unavailable_encrypted_repository_secrets"
  } > "$OUT/route-secret-scan.txt"
  [[ "$ROUTE_HITS" == 0 && "$EMAIL_HITS" == 0 && "$GENERIC_SECRET_HITS" == 0 ]]

  {
    echo "login_rc=$LOGIN_RC"
    echo "view_easels_rc=$VIEW_RC"
    echo "capability_rc=$CAPABILITY_RC"
    echo "login_navigation_actions=3"
    echo "sign_in_press=1"
    echo "view_easels_press=1"
    echo "view_easels_retries=0"
    echo "post_login_ax_value_reads=0"
    echo "item_capability_action_invocations=0"
    echo "scroll_to_visible_invocations=0"
    echo "show_menu_invocations=0"
    echo "context_menu_actions=0"
    echo "right_clicks=0"
    echo "delete_actions=0"
    echo "new_easel_actions=0"
    echo "content_actions=0"
    echo "marker_actions=0"
    echo "share_actions=0"
    echo "confirm_actions=0"
    echo "cancel_actions=0"
    echo "sign_out_actions=0"
    echo "screenshots=0"
    echo "objects_created=0"
  } > "$OUT/easel-item-capability-summary.txt"
fi

if [[ "${COV_STAGE:-}" == easel-item-diagnostic ]]; then
  [[ "$(ps -p "$PID" -o comm= | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')" == "$BIN" ]]
  "$RAW/ax-process-gate" "$PID" "$BIN" > "$OUT/process-gate.txt"
  "$RAW/ax-login-nav" "$PID" "$BIN" > "$OUT/login-navigation.txt"
  set +e
  "$RAW/ax-login-a-once" "$PID" "$BIN" > "$OUT/login-a-once.txt"
  LOGIN_RC=$?
  unset ARC_EMAIL ARC_PASSWORD
  set -e
  echo "login_rc=$LOGIN_RC" > "$OUT/login-result.txt"
  if (( LOGIN_RC != 0 )); then
    exit "$LOGIN_RC"
  fi

  sleep 60
  "$RAW/ax-process-gate" "$PID" "$BIN" > "$OUT/signed-in-process-gate.txt"
  set +e
  "$RAW/ax-view-easels-once" "$PID" "$BIN" > "$OUT/view-easels-action.txt"
  VIEW_RC=$?
  set -e
  echo "view_easels_rc=$VIEW_RC" > "$OUT/view-easels-result.txt"
  if (( VIEW_RC != 0 )); then
    exit "$VIEW_RC"
  fi

  sleep 15
  "$RAW/ax-process-gate" "$PID" "$BIN" > "$OUT/post-view-process-gate.txt"
  set +e
  "$RAW/ax-easel-item-diagnostic" "$PID" "$BIN" > "$OUT/easel-item-diagnostic.txt"
  DIAGNOSTIC_RC=$?
  set -e
  echo "diagnostic_rc=$DIAGNOSTIC_RC" > "$OUT/diagnostic-result.txt"
  if (( DIAGNOSTIC_RC != 0 )); then
    exit "$DIAGNOSTIC_RC"
  fi

  BAD_SCHEMA_LINES="$({ LC_ALL=C grep -Ev '^[a-z0-9_]+=(true|false|PASS|FAIL|SKIPPED|-?[0-9]+)$' "$OUT/easel-item-diagnostic.txt" || true; } | wc -l | tr -d ' ')"
  DUPLICATE_KEYS="$(cut -d= -f1 "$OUT/easel-item-diagnostic.txt" | LC_ALL=C sort | uniq -d | wc -l | tr -d ' ')"
  [[ "$BAD_SCHEMA_LINES" == 0 && "$DUPLICATE_KEYS" == 0 ]]
  for required_key in \
    diagnostic_schema process_gate probe_topology_started probe_topology_finished \
    standard_window_count library_candidate_count grid_count image_count label_count canvas_count \
    grid_role_subrole_expected image_role_subrole_expected label_role_subrole_expected \
    grid_enabled_expected image_enabled_expected label_enabled_expected \
    sign_out_count close_library_count hide_easels_count window_main window_focused \
    parent_chain_to_window pid_equality_all candidate_descendant_of_canvas topology_ready \
    fixed_path_child_copy_error_count fixed_path_child_copy_first_error_rc \
    probe_parameterized_grid_finished probe_parameterized_image_finished probe_parameterized_label_finished \
    parameterized_grid_rc parameterized_image_rc parameterized_label_rc \
    probe_settable_grid_finished probe_settable_image_finished probe_settable_label_finished \
    settable_grid_total settable_image_total settable_label_total \
    value_settable_grid value_settable_image value_settable_label \
    probe_window_relation_finished window_relation_grid_rc top_level_relation_grid_rc \
    window_relation_grid_unsupported_normalized top_level_relation_grid_unsupported_normalized \
    probe_position_window_finished probe_size_window_finished \
    probe_position_scroll_finished probe_size_scroll_finished \
    probe_position_grid_finished probe_size_grid_finished \
    probe_position_image_finished probe_size_image_finished \
    probe_position_label_finished probe_size_label_finished \
    probe_activation_grid_finished probe_activation_image_finished probe_activation_label_finished \
    probe_display_finished probe_containment_finished probe_stability_finished \
    geometry_axvalue_decode_count \
    capability_ready geometry_ready diagnostic_complete; do
    [[ "$(grep -Ec "^${required_key}=" "$OUT/easel-item-diagnostic.txt")" == 1 ]]
  done
  grep -Fxq 'diagnostic_schema=1' "$OUT/easel-item-diagnostic.txt"
  grep -Fxq 'diagnostic_complete=true' "$OUT/easel-item-diagnostic.txt"

  CAPABILITY_READY="$(awk -F= '$1=="capability_ready"{print $2}' "$OUT/easel-item-diagnostic.txt")"
  GEOMETRY_READY="$(awk -F= '$1=="geometry_ready"{print $2}' "$OUT/easel-item-diagnostic.txt")"
  [[ "$CAPABILITY_READY" == true || "$CAPABILITY_READY" == false ]]
  [[ "$GEOMETRY_READY" == true || "$GEOMETRY_READY" == false ]]
  [[ -z "${ARC_EMAIL+x}" && -z "${ARC_PASSWORD+x}" ]]

  ROUTE_HITS="$({ LC_ALL=C grep -ERai '(^|[^A-Za-z0-9.-])(https://)?arc\.net/e/[A-Za-z0-9_-]{8,128}([^A-Za-z0-9_-]|$)' "$OUT" || true; } | wc -l | tr -d ' ')"
  EMAIL_HITS="$({ LC_ALL=C grep -ERai '[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}' "$OUT" || true; } | wc -l | tr -d ' ')"
  GENERIC_SECRET_HITS="$({ LC_ALL=C grep -ERa -- '-----BEGIN (RSA|EC|OPENSSH|DSA|PGP) PRIVATE KEY-----|github_pat_[A-Za-z0-9_]+|gh[pousr]_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|Bearer[[:space:]]+[A-Za-z0-9._~+/=-]{16,}|eyJ[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{8,}' "$OUT" || true; } | wc -l | tr -d ' ')"
  ITEM_CONTENT_HITS="$({ LC_ALL=C grep -ERai 'Untitled Easel|Easel Canvas View' "$OUT" || true; } | wc -l | tr -d ' ')"
  {
    echo "exact_arc_easel_route_hits=$ROUTE_HITS"
    echo "email_pattern_hits=$EMAIL_HITS"
    echo "generic_secret_pattern_hits=$GENERIC_SECRET_HITS"
    echo "item_content_pattern_hits=$ITEM_CONTENT_HITS"
    echo "credential_environment_names_present=0"
    echo "exact_secret_value_scan=unavailable_encrypted_repository_secrets"
  } > "$OUT/route-secret-scan.txt"
  [[ "$ROUTE_HITS" == 0 && "$EMAIL_HITS" == 0 && "$GENERIC_SECRET_HITS" == 0 && "$ITEM_CONTENT_HITS" == 0 ]]

  {
    echo "login_rc=$LOGIN_RC"
    echo "view_easels_rc=$VIEW_RC"
    echo "diagnostic_rc=$DIAGNOSTIC_RC"
    echo "diagnostic_complete=1"
    echo "workflow_success_instrumentation_only=true"
    echo "capability_ready=$CAPABILITY_READY"
    echo "geometry_ready=$GEOMETRY_READY"
    echo "login_navigation_actions=3"
    echo "sign_in_press=1"
    echo "view_easels_press=1"
    echo "view_easels_retries=0"
    echo "diagnostic_action_invocations=0"
    echo "ax_value_attribute_reads=0"
    echo "geometry_axvalue_decode_probe=true"
    echo "parameterized_value_invocations=0"
    echo "scroll_to_visible_invocations=0"
    echo "show_menu_invocations=0"
    echo "context_menu_actions=0"
    echo "right_clicks=0"
    echo "delete_actions=0"
    echo "new_easel_actions=0"
    echo "content_actions=0"
    echo "marker_actions=0"
    echo "share_actions=0"
    echo "confirm_actions=0"
    echo "cancel_actions=0"
    echo "sign_out_actions=0"
    echo "screenshots=0"
    echo "objects_created=0"
  } > "$OUT/easel-item-diagnostic-summary.txt"
fi

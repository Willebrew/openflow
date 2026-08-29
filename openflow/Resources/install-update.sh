#!/bin/zsh
set -u

PLAN_PATH="${1:-}"
if [[ -z "$PLAN_PATH" || ! -f "$PLAN_PATH" ]]; then
  exit 2
fi

read_plan_value() {
  /usr/bin/plutil -extract "$1" raw -o - "$PLAN_PATH"
}

PARENT_PID="$(read_plan_value parentPID)"
CURRENT_APP="$(read_plan_value currentAppPath)"
STAGED_APP="$(read_plan_value stagedAppPath)"
BACKUP_APP="$(read_plan_value backupAppPath)"
SUCCESS_MARKER="$(read_plan_value successMarkerPath)"
RESULT_PATH="$(read_plan_value resultPath)"
VERSION="$(read_plan_value version)"
HELPER_PATH="$0"

write_result() {
  local status="$1"
  local detail="$2"
  /bin/cat > "$RESULT_PATH" <<EOF
{"status":"$status","detail":"$detail","version":"$VERSION"}
EOF
}

relaunch_current() {
  if [[ -d "$CURRENT_APP" ]]; then
    /usr/bin/open -n "$CURRENT_APP" >/dev/null 2>&1 || true
  fi
}

fail_install() {
  write_result "failed" "$1"
  relaunch_current
  /bin/rm -f "$PLAN_PATH" "$HELPER_PATH"
  exit 1
}

for _ in {1..300}; do
  if ! /bin/kill -0 "$PARENT_PID" >/dev/null 2>&1; then
    break
  fi
  /bin/sleep 0.1
done

if /bin/kill -0 "$PARENT_PID" >/dev/null 2>&1; then
  fail_install "openflow did not quit before the update timeout"
fi

if [[ ! -d "$STAGED_APP" ]]; then
  fail_install "the staged app is missing"
fi

/usr/bin/codesign --verify --deep --strict "$STAGED_APP" >/dev/null 2>&1 ||
  fail_install "the staged app failed code-signature verification"
# codesign treats a separate -R argument as a requirement *file*. The
# requirement must be passed as -R=... so it is parsed as a specification.
/usr/bin/codesign --verify \
  -R='anchor apple generic and identifier "com.neuroquestlabs.openflow" and certificate leaf[subject.OU] = PXAS7J4XKW' \
  "$STAGED_APP" >/dev/null 2>&1 ||
  fail_install "the staged app is not signed by the expected NeuroQuest Labs Developer ID"
/usr/sbin/spctl --assess --type execute "$STAGED_APP" >/dev/null 2>&1 ||
  fail_install "Gatekeeper rejected the staged app"

/bin/rm -rf "$BACKUP_APP" || fail_install "the previous backup could not be removed"
/bin/mv "$CURRENT_APP" "$BACKUP_APP" ||
  fail_install "the current app could not be moved; reinstall openflow in Applications"

if ! /bin/mv "$STAGED_APP" "$CURRENT_APP"; then
  /bin/mv "$BACKUP_APP" "$CURRENT_APP" >/dev/null 2>&1 || true
  fail_install "the new app could not be moved into place"
fi

/usr/bin/open -n "$CURRENT_APP" --args --openflow-update-complete "$SUCCESS_MARKER" \
  >/dev/null 2>&1 || true

for _ in {1..200}; do
  if [[ -f "$SUCCESS_MARKER" ]]; then
    write_result "installed" "launch confirmed"
    /bin/rm -f "$SUCCESS_MARKER" "$PLAN_PATH" "$HELPER_PATH"
    exit 0
  fi
  /bin/sleep 0.1
done

/usr/bin/pkill -x openflow >/dev/null 2>&1 || true
/bin/rm -rf "$CURRENT_APP"
if /bin/mv "$BACKUP_APP" "$CURRENT_APP"; then
  write_result "rolled_back" "the updated app did not confirm launch"
  relaunch_current
else
  write_result "failed" "the updated app failed and rollback could not be completed"
fi
/bin/rm -f "$PLAN_PATH" "$HELPER_PATH"
exit 1

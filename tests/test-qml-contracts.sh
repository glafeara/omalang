#!/bin/bash
# Static regressions for Panel↔backend contracts. Quickshell's typed
# IpcHandler prevents standalone Panel.qml linting, so these pin the
# agreements that a refactor on either side could silently break.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
panel="$here/../Panel.qml"
backend="$here/../backend.sh"
manifest="$here/../manifest.json"
pass=0 fail=0

expect() {
  local name="$1" condition="$2"
  if eval "$condition"; then echo "PASS $name"; pass=$((pass + 1))
  else echo "FAIL $name"; fail=$((fail + 1)); fi
}

# Every backend command the QML invokes must exist as a case arm; a renamed
# arm would otherwise surface only as a runtime usage error in the panel.
qml_commands="$(grep -oE 'runBackend\(\["[a-z]+"' "$panel" | sed -E 's/.*"([a-z]+)"/\1/' ; grep -oE 'backendPath, "[a-z]+"' "$panel" | sed -E 's/.*"([a-z]+)"/\1/')"
missing=""
for cmd in $qml_commands; do
  grep -qE "^  ${cmd}\)" "$backend" || missing="$missing $cmd"
done
expect "every backend command the QML calls has a case arm ($(echo $qml_commands | tr '\n' ' '))" \
  '[ -z "$missing" ]'

# remove and move are index-based — a code can appear twice with different
# variants, so passing a code would delete or move the wrong entry.
expect "remove is called with an index, never a code" \
  'grep -q "runBackend(\[\"remove\", index\])" "$panel"'
expect "move is called with two indices" \
  'grep -q "runBackend(\[\"move\", index, to\])" "$panel"'

# The widget id is load-bearing in three places; they must agree.
id="$(grep -oE '"id": *"[^"]+"' "$manifest" | sed -E 's/.*: *"([^"]+)"/\1/')"
expect "manifest id, moduleName and ipcTarget agree" \
  'grep -q "moduleName: \"$id\"" "$panel" && grep -q "ipcTarget: \"$id\"" "$panel"'

# The base Panel would publish a second IpcHandler for the same target.
expect "base panel IPC stays off next to the widget's own handler" \
  'grep -q "manageIpc: false" "$panel" && grep -q "IpcHandler {" "$panel"'

# Every settings key the QML reads must be declared in the manifest schema,
# or the settings UI silently drifts from what the widget consumes.
setting_keys="$(grep -oE 'setting\("[A-Za-z]+"' "$panel" | sed -E 's/setting\("([A-Za-z]+)"/\1/' | sort -u)"
missing=""
for key in $setting_keys; do
  grep -q "\"key\": \"$key\"" "$manifest" || missing="$missing $key"
done
expect "every setting the QML reads is declared in the manifest schema" \
  '[ -z "$missing" ]'

# The OSD is visual-only: an empty input region is what keeps the flash from
# stealing clicks and keys from whatever the user is typing into.
expect "OSD window keeps an empty input mask" \
  'grep -q "mask: Region {}" "$panel"'

# Omarchy instantiates the widget once per monitor; OSD and IPC are seat-
# global and must stay single-owner or N monitors flash N stacked windows.
expect "OSD and IPC are gated to a single primary instance" \
  'grep -q "property bool primaryInstance" "$panel" && grep -q "if (!root.primaryInstance) return" "$panel" && grep -q "enabled: root.primaryInstance" "$panel"'

# A refresh during an in-flight devices query must queue, not vanish — the
# in-flight reply carries pre-switch state and the next poll is 10s away.
expect "dropped refreshes are queued and re-run, with a stall guard" \
  'grep -q "refreshPending" "$panel" && grep -q "queryStallTimer" "$panel"'

# With no catalog match activeIndex is -1 and (i+1)%n would pin cycling to
# row 0 — Hyprland must do the cycling then.
expect "cycling falls back to switchxkblayout next when the catalog cannot match" \
  'grep -q "switchxkblayout all next" "$panel"'

# One SUPER+SPACE emits activelayout once per device; adopting the keymap in
# the event handler is what keeps replays from flashing twice.
expect "the event handler adopts the new keymap before the async refresh" \
  'grep -A3 "root.showOsd(root.labelForKeymap(keymap))" "$panel" | grep -q "root.activeKeymap = keymap"'

# The manifest bounds osdDurationMs; a hand-edited settings file must not
# park the flash on screen for minutes.
expect "OSD duration is clamped in QML, not only in the manifest" \
  'grep -q "Math.min(5000, Math.max(200," "$panel"'

echo "----"
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]

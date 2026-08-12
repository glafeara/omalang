#!/bin/bash
# Backend suite for Omalang. Runs against a fake hyprctl and temporary
# config files — the only way to exercise both config dialects (input.conf
# and input.lua), since their kb_layout lines are edited by different sed
# patterns and a mistake in either silently corrupts the user's input file.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
backend="$here/../backend.sh"
export PATH="$here/fake:$PATH"
pass=0 fail=0

fresh() { # [conf|lua]
  FAKE_DIR="$(mktemp -d)"
  export FAKE_LOG="$FAKE_DIR/hyprctl.log"
  : > "$FAKE_LOG"
  export LANGUAGES_INPUT_CONF="$FAKE_DIR/input.conf"
  export LANGUAGES_INPUT_LUA="$FAKE_DIR/input.lua"
  export LANGUAGES_XKB_RULES="$FAKE_DIR/base.lst"
  # input.lua only exists on lua installs — its presence is the dialect switch.
  # The lua fixture mirrors the real file: kb_layout on its own line inside a
  # multi-line hl.config block, which is what the backend's line-anchored
  # grep/sed patterns are written against.
  if [[ ${1:-conf} == lua ]]; then
    printf 'hl.config({\n  input = {\n    kb_layout = "us,ru",\n  },\n})\n' > "$LANGUAGES_INPUT_LUA"
  else
    rm -f "$LANGUAGES_INPUT_LUA"
    printf 'input {\n  kb_layout = us,ru\n  kb_options = grp:win_space_toggle\n}\n' > "$LANGUAGES_INPUT_CONF"
  fi
  cat > "$LANGUAGES_XKB_RULES" <<'EOF'
! model
  pc86            Generic 86-key PC

! layout
  us              English (US)
  ru              Russian
  de              German

! variant
  dvorak          us: English (Dvorak)
EOF
}

expect() { # name condition-expr
  if eval "$2"; then echo "PASS $1"; pass=$((pass+1))
  else echo "FAIL $1"; fail=$((fail+1)); fi
  rm -rf "$FAKE_DIR"
}

reloads() { grep -cx "reload" "$FAKE_LOG"; }

# --- available -------------------------------------------------------------

fresh conf
out="$(bash "$backend" available)"; rc=$?
expect "available: layout section only, code<TAB>name" \
  '[ "$rc" = 0 ] && [ "$(printf "%s\n" "$out" | wc -l)" = 3 ] && printf "%s\n" "$out" | grep -qx "ru	Russian" && ! printf "%s\n" "$out" | grep -q pc86 && ! printf "%s\n" "$out" | grep -q dvorak'

# --- current ---------------------------------------------------------------

fresh conf
out="$(bash "$backend" current)"
expect "conf: current reads kb_layout" '[ "$out" = "us,ru" ]'

fresh lua
out="$(bash "$backend" current)"
expect "lua: current reads quoted kb_layout" '[ "$out" = "us,ru" ]'

fresh lua
printf -- '-- kb_layout = "xx"\nhl.config({\n  input = {\n    kb_layout = "us",\n  },\n})\n' > "$LANGUAGES_INPUT_LUA"
out="$(bash "$backend" current)"
expect "lua: comment lines never win" '[ "$out" = "us" ]'

# --- add -------------------------------------------------------------------

fresh conf
bash "$backend" add de; rc=$?
expect "conf: add appends the code and reloads once" \
  '[ "$rc" = 0 ] && grep -qE "^  kb_layout = us,ru,de$" "$LANGUAGES_INPUT_CONF" && [ "$(reloads)" = 1 ]'

fresh conf
bash "$backend" add ru; rc=$?
expect "conf: duplicate add is a silent no-op, no reload" \
  '[ "$rc" = 0 ] && grep -qE "^  kb_layout = us,ru$" "$LANGUAGES_INPUT_CONF" && [ "$(reloads)" = 0 ]'

fresh conf
: > "$LANGUAGES_INPUT_CONF"
bash "$backend" add de; rc=$?
expect "conf: add with no kb_layout line appends an input block" \
  '[ "$rc" = 0 ] && grep -qE "^  kb_layout = de$" "$LANGUAGES_INPUT_CONF"'

fresh conf
bash "$backend" add 'de;rm -rf /' >/dev/null 2>&1; rc=$?
expect "add: a code that is not [a-z0-9_]+ is rejected before any write" \
  '[ "$rc" != 0 ] && grep -qE "^  kb_layout = us,ru$" "$LANGUAGES_INPUT_CONF" && [ "$(reloads)" = 0 ]'

fresh lua
bash "$backend" add de; rc=$?
expect "lua: add edits the quoted assignment in place" \
  '[ "$rc" = 0 ] && grep -qF "kb_layout = \"us,ru,de\"" "$LANGUAGES_INPUT_LUA" && [ "$(reloads)" = 1 ]'

fresh lua
echo '-- no live assignment here' > "$LANGUAGES_INPUT_LUA"
bash "$backend" add de; rc=$?
expect "lua: add with no live assignment appends an hl.config call" \
  '[ "$rc" = 0 ] && grep -qF "hl.config({ input = { kb_layout = \"de\" } })" "$LANGUAGES_INPUT_LUA"'

# --- remove ----------------------------------------------------------------

fresh conf
bash "$backend" remove us; rc=$?
expect "conf: remove keeps the rest, untouched lines stay" \
  '[ "$rc" = 0 ] && grep -qE "^  kb_layout = ru$" "$LANGUAGES_INPUT_CONF" && grep -q kb_options "$LANGUAGES_INPUT_CONF" && [ "$(reloads)" = 1 ]'

fresh lua
bash "$backend" remove ru; rc=$?
expect "lua: remove rewrites the quoted list" \
  '[ "$rc" = 0 ] && grep -qF "kb_layout = \"us\"" "$LANGUAGES_INPUT_LUA"'

fresh conf
printf 'input {\n  kb_layout = us\n}\n' > "$LANGUAGES_INPUT_CONF"
bash "$backend" remove us >/dev/null 2>&1; rc=$?
expect "remove: the last remaining layout is refused, no reload" \
  '[ "$rc" != 0 ] && grep -qE "^  kb_layout = us$" "$LANGUAGES_INPUT_CONF" && [ "$(reloads)" = 0 ]'

fresh conf
bash "$backend" remove de; rc=$?
expect "remove: an absent code leaves the list as it was" \
  '[ "$rc" = 0 ] && grep -qE "^  kb_layout = us,ru$" "$LANGUAGES_INPUT_CONF"'

# --- usage -----------------------------------------------------------------

fresh conf
bash "$backend" bogus >/dev/null 2>&1; rc=$?
expect "unknown command fails with usage" '[ "$rc" != 0 ]'

echo "----"
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]

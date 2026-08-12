#!/bin/bash
# Backend suite for Omalang. Runs against a fake hyprctl and temporary
# config files — the only way to exercise both config dialects (input.conf
# and input.lua), since their kb_layout lines are edited by different sed
# patterns and a mistake in either silently corrupts the user's input file.
# kb_variant is positional and parallel to kb_layout, so every mutation is
# checked for keeping the two lists in step.
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
  # The compositor fallback only speaks when a test sets it explicitly.
  unset FAKE_OPT_KB_LAYOUT FAKE_OPT_KB_VARIANT FAKE_FAIL_RELOAD
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
  phonetic        ru: Russian (Phonetic)
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
expect "available: layouts and variants, code<TAB>name" \
  '[ "$rc" = 0 ] && [ "$(printf "%s\n" "$out" | wc -l)" = 5 ] && printf "%s\n" "$out" | grep -qx "ru	Russian" && printf "%s\n" "$out" | grep -qx "us(dvorak)	English (Dvorak)" && ! printf "%s\n" "$out" | grep -q pc86'

# --- current / variants ----------------------------------------------------

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

fresh conf
printf 'input {\n  kb_layout = us,ru\n  kb_variant = ,phonetic\n}\n' > "$LANGUAGES_INPUT_CONF"
out="$(bash "$backend" variants)"
expect "conf: variants reads kb_variant" '[ "$out" = ",phonetic" ]'

fresh conf
printf 'input {\n  kb_layout = us,ru # us at work\n}\n' > "$LANGUAGES_INPUT_CONF"
out="$(bash "$backend" current)"
expect "conf: an inline # comment is not part of the list" '[ "$out" = "us,ru" ]'

fresh lua
printf 'hl.config({\n  input = {\n    kb_layout = "us,ru", -- keep "us" first\n  },\n})\n' > "$LANGUAGES_INPUT_LUA"
out="$(bash "$backend" current)"
expect "lua: a trailing comment with quotes does not hijack the value" '[ "$out" = "us,ru" ]'

fresh conf
: > "$LANGUAGES_INPUT_CONF"
export FAKE_OPT_KB_LAYOUT="us,ru"
out="$(bash "$backend" current)"
expect "current falls back to the compositor when the file has no live line" '[ "$out" = "us,ru" ]'

# --- add -------------------------------------------------------------------

fresh conf
bash "$backend" add de; rc=$?
expect "conf: add appends the code and reloads once" \
  '[ "$rc" = 0 ] && grep -qE "^  kb_layout = us,ru,de$" "$LANGUAGES_INPUT_CONF" && ! grep -q kb_variant "$LANGUAGES_INPUT_CONF" && [ "$(reloads)" = 1 ]'

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

fresh conf
bash "$backend" add us 'dvo rak' >/dev/null 2>&1; rc=$?
expect "add: an invalid variant is rejected before any write" \
  '[ "$rc" != 0 ] && ! grep -q kb_variant "$LANGUAGES_INPUT_CONF" && [ "$(reloads)" = 0 ]'

fresh lua
bash "$backend" add de; rc=$?
expect "lua: add edits the quoted assignment in place" \
  '[ "$rc" = 0 ] && grep -qF "kb_layout = \"us,ru,de\"" "$LANGUAGES_INPUT_LUA" && [ "$(reloads)" = 1 ]'

fresh lua
echo '-- no live assignment here' > "$LANGUAGES_INPUT_LUA"
bash "$backend" add de; rc=$?
expect "lua: add with no live assignment appends a readable multi-line block" \
  '[ "$rc" = 0 ] && grep -qE "^    kb_layout = \"de\",$" "$LANGUAGES_INPUT_LUA" && [ "$(bash "$backend" current)" = "de" ]'

# The stock-Omarchy first run: input.lua exists but every kb_layout line is
# commented, the effective list lives in the compositor. The first add must
# extend that list — not replace it — and the appended block must be
# editable by the second and third mutation.
fresh lua
printf -- '--     kb_layout = "us,dk,eu",\n' > "$LANGUAGES_INPUT_LUA"
export FAKE_OPT_KB_LAYOUT="us,ru"
bash "$backend" add de; rc=$?
expect "stock lua: first add extends the compositor list, not replaces it" \
  '[ "$rc" = 0 ] && grep -qE "^    kb_layout = \"us,ru,de\",$" "$LANGUAGES_INPUT_LUA"'

fresh lua
printf -- '--     kb_layout = "us,dk,eu",\n' > "$LANGUAGES_INPUT_LUA"
export FAKE_OPT_KB_LAYOUT="us,ru"
bash "$backend" add de && bash "$backend" add fr && bash "$backend" remove 0; rc=$?
expect "stock lua: the appended block stays editable by later mutations" \
  '[ "$rc" = 0 ] && grep -qE "^    kb_layout = \"ru,de,fr\",$" "$LANGUAGES_INPUT_LUA" && [ "$(grep -cE "^[[:space:]]*kb_layout = \"" "$LANGUAGES_INPUT_LUA")" = 1 ]'

fresh lua
printf -- '--     kb_layout = "us,dk,eu",\n' > "$LANGUAGES_INPUT_LUA"
export FAKE_OPT_KB_LAYOUT="ru,us"
export FAKE_OPT_KB_VARIANT="phonetic"
bash "$backend" add de; rc=$?
expect "stock lua: compositor variants are carried into the first write" \
  '[ "$rc" = 0 ] && grep -qE "^    kb_layout = \"ru,us,de\",$" "$LANGUAGES_INPUT_LUA" && grep -qE "^    kb_variant = \"phonetic,,\",$" "$LANGUAGES_INPUT_LUA"'

fresh conf
printf 'input {\n  kb_layout = us,r|u\n}\n' > "$LANGUAGES_INPUT_CONF"
bash "$backend" add de >/dev/null 2>&1; rc=$?
expect "an unparseable kb_layout entry refuses every mutation, file untouched" \
  '[ "$rc" != 0 ] && grep -qF "kb_layout = us,r|u" "$LANGUAGES_INPUT_CONF" && [ "$(reloads)" = 0 ]'

fresh conf
export FAKE_FAIL_RELOAD=1
bash "$backend" add de >/dev/null 2>&1; rc=$?
expect "a failed hyprctl reload is not reported as success" '[ "$rc" != 0 ]'

# --- add with variants -----------------------------------------------------

fresh conf
bash "$backend" add us dvorak; rc=$?
expect "conf: adding a variant creates a padded kb_variant line" \
  '[ "$rc" = 0 ] && grep -qE "^  kb_layout = us,ru,us$" "$LANGUAGES_INPUT_CONF" && grep -qE "^  kb_variant = ,,dvorak$" "$LANGUAGES_INPUT_CONF" && [ "$(reloads)" = 1 ]'

fresh conf
bash "$backend" add us dvorak && bash "$backend" add us dvorak; rc=$?
expect "conf: duplicate code+variant pair is a no-op" \
  '[ "$rc" = 0 ] && grep -qE "^  kb_layout = us,ru,us$" "$LANGUAGES_INPUT_CONF" && [ "$(reloads)" = 1 ]'

fresh conf
bash "$backend" add us dvorak && bash "$backend" add us; rc=$?
expect "conf: us(dvorak) is added despite bare us; a second bare us stays a no-op" \
  '[ "$rc" = 0 ] && grep -qE "^  kb_layout = us,ru,us$" "$LANGUAGES_INPUT_CONF" && [ "$(reloads)" = 1 ]'

fresh lua
bash "$backend" add ru phonetic; rc=$?
expect "lua: adding a variant appends a padded kb_variant assignment" \
  '[ "$rc" = 0 ] && grep -qF "kb_layout = \"us,ru,ru\"" "$LANGUAGES_INPUT_LUA" && grep -qF "kb_variant = \",,phonetic\"" "$LANGUAGES_INPUT_LUA"'

# --- remove ----------------------------------------------------------------

fresh conf
bash "$backend" remove 0; rc=$?
expect "conf: remove by index keeps the rest, untouched lines stay" \
  '[ "$rc" = 0 ] && grep -qE "^  kb_layout = ru$" "$LANGUAGES_INPUT_CONF" && grep -q kb_options "$LANGUAGES_INPUT_CONF" && [ "$(reloads)" = 1 ]'

fresh conf
printf 'input {\n  kb_layout = us,ru,de\n  kb_variant = dvorak,,\n}\n' > "$LANGUAGES_INPUT_CONF"
bash "$backend" remove 0; rc=$?
expect "conf: removing a layout removes its variant slot, not another's" \
  '[ "$rc" = 0 ] && grep -qE "^  kb_layout = ru,de$" "$LANGUAGES_INPUT_CONF" && grep -qE "^  kb_variant = $" "$LANGUAGES_INPUT_CONF"'

fresh conf
printf 'input {\n  kb_layout = us,ru\n  kb_variant = dvorak,phonetic\n}\n' > "$LANGUAGES_INPUT_CONF"
bash "$backend" remove 0; rc=$?
expect "conf: the surviving layout keeps its own variant" \
  '[ "$rc" = 0 ] && grep -qE "^  kb_layout = ru$" "$LANGUAGES_INPUT_CONF" && grep -qE "^  kb_variant = phonetic$" "$LANGUAGES_INPUT_CONF"'

fresh lua
bash "$backend" remove 1; rc=$?
expect "lua: remove rewrites the quoted list" \
  '[ "$rc" = 0 ] && grep -qF "kb_layout = \"us\"" "$LANGUAGES_INPUT_LUA"'

fresh conf
printf 'input {\n  kb_layout = us\n}\n' > "$LANGUAGES_INPUT_CONF"
bash "$backend" remove 0 >/dev/null 2>&1; rc=$?
expect "remove: the last remaining layout is refused, no reload" \
  '[ "$rc" != 0 ] && grep -qE "^  kb_layout = us$" "$LANGUAGES_INPUT_CONF" && [ "$(reloads)" = 0 ]'

fresh conf
bash "$backend" remove 5 >/dev/null 2>&1; rc=$?
expect "remove: an out-of-range index is refused, no reload" \
  '[ "$rc" != 0 ] && grep -qE "^  kb_layout = us,ru$" "$LANGUAGES_INPUT_CONF" && [ "$(reloads)" = 0 ]'

fresh conf
bash "$backend" remove us >/dev/null 2>&1; rc=$?
expect "remove: a non-numeric argument is refused" '[ "$rc" != 0 ]'

# --- move ------------------------------------------------------------------

fresh conf
printf 'input {\n  kb_layout = us,ru,de\n  kb_variant = dvorak,,\n}\n' > "$LANGUAGES_INPUT_CONF"
bash "$backend" move 0 2; rc=$?
expect "conf: move carries the variant with its layout" \
  '[ "$rc" = 0 ] && grep -qE "^  kb_layout = ru,de,us$" "$LANGUAGES_INPUT_CONF" && grep -qE "^  kb_variant = ,,dvorak$" "$LANGUAGES_INPUT_CONF" && [ "$(reloads)" = 1 ]'

fresh conf
bash "$backend" move 1 0; rc=$?
expect "conf: move to the front changes the default layout" \
  '[ "$rc" = 0 ] && grep -qE "^  kb_layout = ru,us$" "$LANGUAGES_INPUT_CONF" && [ "$(reloads)" = 1 ]'

fresh conf
bash "$backend" move 1 1; rc=$?
expect "move: same from and to is a no-op, no reload" \
  '[ "$rc" = 0 ] && grep -qE "^  kb_layout = us,ru$" "$LANGUAGES_INPUT_CONF" && [ "$(reloads)" = 0 ]'

fresh conf
bash "$backend" move 0 5 >/dev/null 2>&1; rc=$?
expect "move: an out-of-range target is refused" \
  '[ "$rc" != 0 ] && grep -qE "^  kb_layout = us,ru$" "$LANGUAGES_INPUT_CONF" && [ "$(reloads)" = 0 ]'

fresh lua
bash "$backend" move 0 1; rc=$?
expect "lua: move rewrites the quoted list" \
  '[ "$rc" = 0 ] && grep -qF "kb_layout = \"ru,us\"" "$LANGUAGES_INPUT_LUA"'

# --- usage -----------------------------------------------------------------

fresh conf
bash "$backend" bogus >/dev/null 2>&1; rc=$?
expect "unknown command fails with usage" '[ "$rc" != 0 ]'

echo "----"
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]

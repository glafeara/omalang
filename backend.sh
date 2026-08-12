#!/bin/bash

# Backend for the Omalang (glafeara.languages) bar widget. Persists the layout list in the
# user's Hyprland input config and reloads Hyprland so the change applies
# immediately. On Lua-config installs (Hyprland >= 0.56 with hyprland.lua)
# the source of truth is the kb_layout line in ~/.config/hypr/input.lua;
# older installs keep it in input.conf. Variants are kept simple on purpose:
# one code per language.

set -euo pipefail

INPUT_LUA="${LANGUAGES_INPUT_LUA:-$HOME/.config/hypr/input.lua}"
INPUT_CONF="${LANGUAGES_INPUT_CONF:-$HOME/.config/hypr/input.conf}"

use_lua() { [[ -f $INPUT_LUA ]]; }

xkb_rules() {
  for f in "${LANGUAGES_XKB_RULES:-}" /usr/share/X11/xkb/rules/base.lst /usr/share/X11/xkb/rules/evdev.lst; do
    [[ -n $f && -f $f ]] && { echo "$f"; return 0; }
  done
  return 1
}

# Prints "code<TAB>display name" for every xkb layout known to the system.
available() {
  awk '
    /^! layout/ { in_section = 1; next }
    /^!/        { in_section = 0 }
    in_section && NF {
      code = $1
      $1 = ""
      sub(/^[ \t]+/, "")
      print code "\t" $0
    }
  ' "$(xkb_rules)"
}

# The last active kb_layout assignment wins in both config dialects, so that
# is the one we read and edit. Lua comment lines (--) never match the
# leading-whitespace-then-kb_layout pattern, so only live lines are seen.
# A config without a kb_layout line yet is a valid starting point, not an
# error — the trailing || true keeps grep's no-match exit from killing the
# script under pipefail, so `add` can reach its append-a-fresh-line branch.
current() {
  if use_lua; then
    grep -E '^[[:space:]]*kb_layout[[:space:]]*=' "$INPUT_LUA" 2>/dev/null \
      | tail -1 \
      | sed -E 's/.*"([^"]*)".*/\1/' \
      | tr -d ' ' || true
  else
    grep -E '^[[:space:]]*kb_layout[[:space:]]*=' "$INPUT_CONF" 2>/dev/null \
      | tail -1 \
      | sed -E 's/^[[:space:]]*kb_layout[[:space:]]*=[[:space:]]*//' \
      | tr -d ' ' || true
  fi
}

write_layouts() {
  local new="$1"
  [[ -n $new ]] || { echo "refusing to write an empty kb_layout" >&2; exit 1; }
  if use_lua; then
    if grep -qE '^[[:space:]]*kb_layout[[:space:]]*=[[:space:]]*"' "$INPUT_LUA"; then
      sed -i -E "s|^([[:space:]]*kb_layout[[:space:]]*=[[:space:]]*\")[^\"]*(\".*)|\1${new}\2|" "$INPUT_LUA"
    else
      # No live assignment to edit — append one; later hl.config calls
      # override earlier ones, so this wins over the Omarchy default.
      printf '\nhl.config({ input = { kb_layout = "%s" } })\n' "$new" >>"$INPUT_LUA"
    fi
  else
    if grep -qE '^[[:space:]]*kb_layout[[:space:]]*=' "$INPUT_CONF" 2>/dev/null; then
      sed -i -E "s|^([[:space:]]*kb_layout[[:space:]]*=[[:space:]]*).*|\1${new}|" "$INPUT_CONF"
    else
      printf '\ninput {\n  kb_layout = %s\n}\n' "$new" >>"$INPUT_CONF"
    fi
  fi
  hyprctl reload >/dev/null
}

case "${1:-}" in
  available)
    available
    ;;
  current)
    current
    ;;
  add)
    code="${2:?usage: backend.sh add <layout-code>}"
    [[ $code =~ ^[a-z0-9_]+$ ]] || { echo "invalid layout code: $code" >&2; exit 1; }
    cur="$(current)"
    IFS=',' read -ra layouts <<<"$cur"
    for l in "${layouts[@]}"; do [[ $l == "$code" ]] && exit 0; done
    if [[ -z $cur ]]; then
      write_layouts "$code"
    else
      write_layouts "$cur,$code"
    fi
    ;;
  remove)
    code="${2:?usage: backend.sh remove <layout-code>}"
    cur="$(current)"
    IFS=',' read -ra layouts <<<"$cur"
    kept=()
    for l in "${layouts[@]}"; do [[ $l == "$code" ]] || kept+=("$l"); done
    if ((${#kept[@]} == 0)); then
      echo "cannot remove the last remaining layout" >&2
      exit 1
    fi
    write_layouts "$(IFS=','; echo "${kept[*]}")"
    ;;
  *)
    echo "usage: backend.sh {available|current|add <code>|remove <code>}" >&2
    exit 1
    ;;
esac

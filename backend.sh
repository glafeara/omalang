#!/bin/bash

# Backend for the Omalang (glafeara.languages) bar widget. Persists the layout
# list in the user's Hyprland input config and reloads Hyprland so the change
# applies immediately. On Lua-config installs (Hyprland >= 0.56 with
# hyprland.lua) the source of truth is the kb_layout line in
# ~/.config/hypr/input.lua; older installs keep it in input.conf.
#
# kb_variant is positional and parallel to kb_layout, so every edit here
# rewrites both lines together — editing only kb_layout would silently shift
# variants onto the wrong layouts. Because the same layout code can appear
# twice with different variants (us + us(dvorak)), remove and move address
# entries by index, not by code.

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

# Prints "key<TAB>display name" for everything addable: plain layouts as
# "us", variants as "us(dvorak)". The variant description in the rules list
# is already the full human name ("English (Dvorak)"), which is also the
# exact keymap name Hyprland reports for it — that match is what lets the
# panel recognize a variant layout as active.
available() {
  local rules
  rules="$(xkb_rules)"
  awk '
    /^! layout/ { in_section = 1; next }
    /^!/        { in_section = 0 }
    in_section && NF {
      code = $1
      $1 = ""
      sub(/^[ \t]+/, "")
      print code "\t" $0
    }
  ' "$rules"
  awk '
    /^! variant/ { in_section = 1; next }
    /^!/         { in_section = 0 }
    in_section && NF >= 2 && $2 ~ /:$/ {
      variant = $1
      layout = $2
      sub(/:$/, "", layout)
      $1 = ""; $2 = ""
      sub(/^[ \t]+/, "")
      print layout "(" variant ")\t" $0
    }
  ' "$rules"
}

# The last active assignment wins in both config dialects, so that is the
# one we read and edit. Lua comment lines (--) never match the
# leading-whitespace-then-key pattern, so only live lines are seen. A config
# without the line yet is a valid starting point, not an error — the
# trailing || true keeps grep's no-match exit from killing the script under
# pipefail, so `add` can reach its append-a-fresh-line branch.
read_input_value() { # key
  local key="$1"
  if use_lua; then
    grep -E "^[[:space:]]*${key}[[:space:]]*=" "$INPUT_LUA" 2>/dev/null \
      | tail -1 \
      | sed -E 's/.*"([^"]*)".*/\1/' \
      | tr -d ' ' || true
  else
    grep -E "^[[:space:]]*${key}[[:space:]]*=" "$INPUT_CONF" 2>/dev/null \
      | tail -1 \
      | sed -E "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//" \
      | tr -d ' ' || true
  fi
}

current() { read_input_value kb_layout; }
current_variants() { read_input_value kb_variant; }

has_live_line() { # key
  local key="$1"
  if use_lua; then
    grep -qE "^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\"" "$INPUT_LUA"
  else
    grep -qE "^[[:space:]]*${key}[[:space:]]*=" "$INPUT_CONF" 2>/dev/null
  fi
}

# Rewrites one key's line in place, appending a fresh assignment when no
# live line exists. No reload here — callers set every line first and
# reload once.
set_input_value() { # key value
  local key="$1" new="$2"
  if use_lua; then
    if grep -qE "^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\"" "$INPUT_LUA"; then
      sed -i -E "s|^([[:space:]]*${key}[[:space:]]*=[[:space:]]*\")[^\"]*(\".*)|\1${new}\2|" "$INPUT_LUA"
    else
      # No live assignment to edit — append one; later hl.config calls
      # override earlier ones, so this wins over the Omarchy default.
      printf '\nhl.config({ input = { %s = "%s" } })\n' "$key" "$new" >>"$INPUT_LUA"
    fi
  else
    if grep -qE "^[[:space:]]*${key}[[:space:]]*=" "$INPUT_CONF" 2>/dev/null; then
      sed -i -E "s|^([[:space:]]*${key}[[:space:]]*=[[:space:]]*).*|\1${new}|" "$INPUT_CONF"
    else
      printf '\ninput {\n  %s = %s\n}\n' "$key" "$new" >>"$INPUT_CONF"
    fi
  fi
}

# Loads the parallel lists into $layouts / $variants, with variants padded
# (or truncated) to the layouts' length so every index addresses a pair.
layouts=()
variants=()
read_state() {
  local cur vcur i
  cur="$(current)"
  vcur="$(current_variants)"
  layouts=()
  variants=()
  [[ -n $cur ]] && IFS=',' read -ra layouts <<<"$cur"
  [[ -n $vcur ]] && IFS=',' read -ra variants <<<"$vcur"
  for ((i = ${#variants[@]}; i < ${#layouts[@]}; i++)); do variants[i]=""; done
  variants=("${variants[@]:0:${#layouts[@]}}")
}

join() { local IFS=','; echo "$*"; }

# Writes both lines and reloads. The kb_variant line is written whenever any
# slot is non-empty; an existing line is blanked rather than left behind
# with stale positions, and a config that never had one stays without one.
write_state() {
  local joined vjoined
  joined="$(join "${layouts[@]}")"
  [[ -n $joined ]] || { echo "refusing to write an empty kb_layout" >&2; exit 1; }
  vjoined="$(join "${variants[@]}")"
  set_input_value kb_layout "$joined"
  if [[ $vjoined =~ [a-zA-Z0-9] ]]; then
    set_input_value kb_variant "$vjoined"
  elif has_live_line kb_variant; then
    set_input_value kb_variant ""
  fi
  hyprctl reload >/dev/null
}

require_index() { # value length usage
  [[ $1 =~ ^[0-9]+$ ]] || { echo "usage: $3" >&2; exit 1; }
  (($1 < $2)) || { echo "index $1 out of range (have $2 layouts)" >&2; exit 1; }
}

case "${1:-}" in
  available)
    available
    ;;
  current)
    current
    ;;
  variants)
    current_variants
    ;;
  add)
    code="${2:?usage: backend.sh add <layout-code> [<variant>]}"
    variant="${3:-}"
    [[ $code =~ ^[a-z0-9_]+$ ]] || { echo "invalid layout code: $code" >&2; exit 1; }
    [[ -z $variant || $variant =~ ^[a-zA-Z0-9_-]+$ ]] || { echo "invalid variant: $variant" >&2; exit 1; }
    read_state
    for ((i = 0; i < ${#layouts[@]}; i++)); do
      [[ ${layouts[i]} == "$code" && ${variants[i]} == "$variant" ]] && exit 0
    done
    layouts+=("$code")
    variants+=("$variant")
    write_state
    ;;
  remove)
    idx="${2:?usage: backend.sh remove <index>}"
    read_state
    require_index "$idx" "${#layouts[@]}" "backend.sh remove <index>"
    if ((${#layouts[@]} == 1)); then
      echo "cannot remove the last remaining layout" >&2
      exit 1
    fi
    layouts=("${layouts[@]:0:idx}" "${layouts[@]:idx+1}")
    variants=("${variants[@]:0:idx}" "${variants[@]:idx+1}")
    write_state
    ;;
  move)
    from="${2:?usage: backend.sh move <from-index> <to-index>}"
    to="${3:?usage: backend.sh move <from-index> <to-index>}"
    read_state
    require_index "$from" "${#layouts[@]}" "backend.sh move <from-index> <to-index>"
    require_index "$to" "${#layouts[@]}" "backend.sh move <from-index> <to-index>"
    ((from == to)) && exit 0
    l="${layouts[from]}" v="${variants[from]}"
    layouts=("${layouts[@]:0:from}" "${layouts[@]:from+1}")
    variants=("${variants[@]:0:from}" "${variants[@]:from+1}")
    layouts=("${layouts[@]:0:to}" "$l" "${layouts[@]:to}")
    variants=("${variants[@]:0:to}" "$v" "${variants[@]:to}")
    write_state
    ;;
  *)
    echo "usage: backend.sh {available|current|variants|add <code> [<variant>]|remove <index>|move <from> <to>}" >&2
    exit 1
    ;;
esac

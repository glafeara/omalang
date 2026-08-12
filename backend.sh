#!/bin/bash

# Backend for the Omalang (glafeara.languages) bar widget. Persists the layout
# list in the user's Hyprland input config and reloads Hyprland so the change
# applies immediately. On Lua-config installs (Hyprland >= 0.56 with
# hyprland.lua) the source of truth is the kb_layout line in
# ~/.config/hypr/input.lua; older installs keep it in input.conf.
#
# Stock Omarchy ships input.lua with every kb_layout line commented out — the
# effective list is computed by the system defaults. When the user file has no
# live line, the current state is therefore read from the compositor
# (hyprctl getoption) and the first mutation appends a fresh assignment, so a
# first Add extends the real list instead of replacing it with one entry.
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
# leading-whitespace-then-key pattern, so only live lines are seen. Inline
# comments are stripped before the value is taken: a conf `# tail` would
# otherwise be glued onto the list, and a lua `-- keep "us" first` would
# hijack the greedy quote match — which is why the lua extraction takes the
# FIRST quoted string, never the last quote on the line. A config without
# the line yet is a valid starting point, not an error — the trailing
# || true keeps grep's no-match exit from killing the script under
# pipefail, so callers can fall back to the compositor's state.
read_input_value() { # key
  local key="$1"
  if use_lua; then
    grep -E "^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\"" "$INPUT_LUA" 2>/dev/null \
      | tail -1 \
      | sed -E 's/^[^"]*"([^"]*)".*/\1/' \
      | tr -d ' ' || true
  else
    grep -E "^[[:space:]]*${key}[[:space:]]*=" "$INPUT_CONF" 2>/dev/null \
      | tail -1 \
      | sed -E 's/[[:space:]]*#.*$//' \
      | sed -E "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//" \
      | tr -d ' ' || true
  fi
}

current_file() { read_input_value kb_layout; }
current_file_variants() { read_input_value kb_variant; }

# What the compositor actually runs — the fallback source of truth when the
# user file has no live line (stock Omarchy keeps kb_layout commented and
# computes the list in the system defaults).
compositor_value() { # kb_layout|kb_variant
  hyprctl getoption "input:$1" 2>/dev/null \
    | awk '/^[[:space:]]*str:/ { print $2; exit }' \
    | tr -d ' ' || true
}

has_live_line() { # key
  local key="$1"
  if use_lua; then
    grep -qE "^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\"" "$INPUT_LUA"
  else
    grep -qE "^[[:space:]]*${key}[[:space:]]*=" "$INPUT_CONF" 2>/dev/null
  fi
}

# Rewrites one key's line in place, appending a fresh assignment when no
# live line exists. The lua append is multi-line on purpose: the read side
# is anchored on a line starting with the key, and a one-line hl.config
# call would be invisible to it — written once and never seen again.
# No reload here — callers set every line first and reload once.
set_input_value() { # key value
  local key="$1" new="$2"
  if use_lua; then
    if grep -qE "^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\"" "$INPUT_LUA"; then
      sed -i -E "s|^([[:space:]]*${key}[[:space:]]*=[[:space:]]*\")[^\"]*(\".*)|\1${new}\2|" "$INPUT_LUA"
    else
      # Later hl.config calls override earlier ones, so this wins over the
      # Omarchy default.
      printf '\nhl.config({\n  input = {\n    %s = "%s",\n  },\n})\n' "$key" "$new" >>"$INPUT_LUA"
    fi
  else
    if grep -qE "^[[:space:]]*${key}[[:space:]]*=" "$INPUT_CONF" 2>/dev/null; then
      sed -i -E "s|^([[:space:]]*${key}[[:space:]]*=[[:space:]]*).*|\1${new}|" "$INPUT_CONF"
    else
      printf '\ninput {\n  %s = %s\n}\n' "$key" "$new" >>"$INPUT_CONF"
    fi
  fi
}

# Every token that will ever be written back must match what `add` accepts.
# A value that fails this came from a config this parser does not fully
# understand — refusing to touch it is the only edit that cannot corrupt
# it. This also keeps sed replacements safe: validated tokens contain no
# sed metacharacters (| & \ ").
valid_code() { [[ $1 =~ ^[a-z0-9_]+$ ]]; }
valid_variant() { [[ -z $1 || $1 =~ ^[a-zA-Z0-9_-]+$ ]]; }

# Loads the parallel lists into $layouts / $variants, with variants padded
# (or truncated) to the layouts' length so every index addresses a pair.
# Falls back to the compositor when the file has no live kb_layout line.
layouts=()
variants=()
read_state() {
  local cur vcur i
  cur="$(current_file)"
  if [[ -n $cur ]]; then
    vcur="$(current_file_variants)"
  else
    cur="$(compositor_value kb_layout)"
    vcur="$(compositor_value kb_variant)"
  fi
  layouts=()
  variants=()
  [[ -n $cur ]] && IFS=',' read -ra layouts <<<"$cur"
  [[ -n $vcur ]] && IFS=',' read -ra variants <<<"$vcur"
  for ((i = ${#variants[@]}; i < ${#layouts[@]}; i++)); do variants[i]=""; done
  variants=("${variants[@]:0:${#layouts[@]}}")
  for ((i = 0; i < ${#layouts[@]}; i++)); do
    valid_code "${layouts[i]}" || {
      echo "unparseable kb_layout entry: '${layouts[i]}' — fix the config by hand" >&2
      exit 1
    }
    valid_variant "${variants[i]}" || {
      echo "unparseable kb_variant entry: '${variants[i]}' — fix the config by hand" >&2
      exit 1
    }
  done
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
    # The effective list: the file's when it has a live line, else the
    # compositor's — the same view every mutation starts from.
    read_state
    join "${layouts[@]}"
    ;;
  variants)
    read_state
    join "${variants[@]}"
    ;;
  add)
    code="${2:?usage: backend.sh add <layout-code> [<variant>]}"
    variant="${3:-}"
    valid_code "$code" || { echo "invalid layout code: $code" >&2; exit 1; }
    valid_variant "$variant" || { echo "invalid variant: $variant" >&2; exit 1; }
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

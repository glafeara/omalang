# Omalang — keyboard layouts in the Omarchy bar

Switch, add and remove keyboard layouts from the
[Omarchy](https://github.com/basecamp/omarchy) bar — with a centered
on-screen indicator flashing the new layout after every switch, including
switches made with the Hyprland keybinding (`SUPER+SPACE`).

![The Omalang panel](preview.png)

The bar shows the active layout's abbreviation (`US`, `RU`, …). The panel
lists your layouts with their full names; a search box over the complete
xkb layout catalog adds a new one. The layout list is not the widget's own
state: it lives in the `kb_layout` line of your Hyprland input config, the
same file Omarchy already uses for input overrides — so what the widget
shows is what the compositor actually runs, and changes survive restarts
with or without the widget.

## Requirements

Everything is stock Omarchy — the widget adds no dependencies:

- **Hyprland** — layouts are read from `hyprctl devices`, switched with
  `hyprctl switchxkblayout`, and the switch indicator listens on Hyprland's
  event socket.
- **xkeyboard-config** — the layout catalog behind "Add language…" is
  parsed from the system's xkb rules list
  (`/usr/share/X11/xkb/rules/base.lst`).

No sudo, no daemons: the config edited is your own file in `~/.config`.

## Install

```bash
omarchy plugin add https://github.com/glafeara/omalang.git
omarchy plugin enable glafeara.languages right
```

`plugin add` is interactive by default; add `--yes` to that command to skip
its prompt. The explicit plugin id and `right` placement make
`plugin enable` non-interactive. The plugin itself is one QML file and one
shell script.

## Using it

**In the bar:** the label is the active layout's abbreviation. Left click
opens and closes the panel, right click cycles to the next layout.

**In the panel:** click a language to switch to it. The active one is
marked with a check. Hovering a row shows its trash-can button — that
removes the language from the layout list (the last remaining language
cannot be removed). "Add language…" opens a search over every layout the
system's xkb catalog knows; picking one appends it to the list.

**The indicator:** after every layout switch — from the panel, the bar's
right click, or the Hyprland keybinding — the new layout's abbreviation
flashes in the middle of the screen, in the same card style as the stock
Omarchy OSDs. It is visual only: its input region is empty, so it never
steals a click or a keystroke from what you are typing. Device replays are
filtered out — Hyprland re-announces the layout when a device (re)appears,
a connecting bluetooth headset included, and that is not a switch worth
flashing. On input-method setups (fcitx5) the virtual keyboard's stale
state is ignored too.

**Switching is compositor-wide** (`switchxkblayout all`), the same thing
the stock Omarchy keybinding does, so the widget and the keybinding never
fight over which device's layout counts.

## Settings

| Key | Default | Range |
| --- | --- | --- |
| `osdDurationMs` | `750` | 200–5000 |
| `showOsd` | `true` | `false` disables the centered indicator |

```bash
omarchy bar set glafeara.languages osdDurationMs 1200
omarchy bar set glafeara.languages showOsd false   # no flash on switch
```

## IPC

```bash
omarchy-shell glafeara.languages open     # also: close, toggle
```

## What it touches

- **Your Hyprland input config** — the single `kb_layout` line, edited in
  place, followed by `hyprctl reload` so the change applies immediately.
  On Lua-config installs (Hyprland ≥ 0.56 with `hyprland.lua`) that is
  `~/.config/hypr/input.lua`; older installs keep it in
  `~/.config/hypr/input.conf`. Nothing else in the file is rewritten, and
  an edit that would leave the line empty is refused.
- `hyprctl devices` / `hyprctl switchxkblayout` — read the active layout,
  switch it. Read-only apart from the switch itself.
- `/usr/share/X11/xkb/rules/{base,evdev}.lst` — read-only, the layout
  catalog for "Add language…".

Everything runs as your user. No install or uninstall scripts, no
services, no network, no telemetry.

## Tests

`tests/` holds a backend suite that runs against a fake `hyprctl` and
temporary config files — both the `input.conf` and the `input.lua`
dialects, since the sed edits differ:

```bash
bash tests/run.sh
```

## Uninstall

```bash
omarchy plugin remove glafeara.languages
```

That disables the widget and deletes the plugin directory. Your layout
list stays in your Hyprland input config — it was yours before the widget,
it stays yours after.

## License

MIT — see [LICENSE](LICENSE).

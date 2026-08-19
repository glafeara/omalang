import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Commons
import qs.Ui

// Languages: bar label with the active layout abbreviation, a popup panel to
// switch / add / remove layouts, and a centered OSD flashing the abbreviation
// after every switch. The layout list is persisted by backend.sh into the
// kb_layout line of ~/.config/hypr/input.conf.
Panel {
  id: root
  moduleName: "glafeara.languages"
  ipcTarget: "glafeara.languages"
  // The base Panel would publish open/close/toggle for this target; the
  // handler below does that and more, so keep the base one off.
  manageIpc: false

  readonly property string backendPath: String(Qt.resolvedUrl("backend.sh")).replace(/^file:\/\//, "")

  // Omarchy builds one bar — and so one instance of this widget — per
  // monitor. Layout state is global to the seat, so exactly one instance
  // (the one on the first screen) owns the OSD and the IPC target; the
  // rest only paint their bar label and panel. Without this, N monitors
  // mean N stacked OSD windows and duplicate IPC handlers on one target.
  readonly property bool primaryInstance: {
    var w = root.QsWindow.window
    var screens = Quickshell.screens
    if (!w || !w.screen || screens.length === 0) return true
    return String(w.screen.name) === String(screens[0].name)
  }

  property string keyboardName: ""
  // {code, variant} pairs in kb_layout order, e.g. [{us,""},{us,"dvorak"}],
  // read from hyprctl so the panel always reflects what the compositor
  // actually runs. Kept as pairs because the same code can appear twice
  // with different variants — rows are addressed by index, never by code.
  property var layouts: []
  property string activeKeymap: ""
  // code -> display name and back, parsed from the system xkb rules list.
  property var namesByCode: ({})
  property var codesByName: ({})
  property var availableOptions: []
  property bool busy: false
  property string lastError: ""

  property string osdText: ""
  property bool osdVisible: false

  // Keyboard-and-mouse row cursor, per the CursorSurface contract: hover and
  // key presses both move this one root-level state, so exactly one row is
  // highlighted no matter how it got the cursor.
  property int cursorIndex: -1
  property bool cursorActive: false
  // Who parked the cursor on its row. A pointer-parked cursor leaves with
  // the pointer; a keyboard-parked one survives a stray mouse pass-through.
  property bool cursorFromPointer: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color hoverFill: bar ? Style.hoverFillFor(bar.foreground, Color.accent) : "transparent"

  // Catalog key for a pair: "us" or "us(dvorak)" — the same shape the
  // backend's `available` emits and the IPC talks.
  function keyFor(entry) {
    return entry.variant ? entry.code + "(" + entry.variant + ")" : entry.code
  }

  readonly property int activeIndex: {
    for (var i = 0; i < layouts.length; i++) {
      if (String(namesByCode[keyFor(layouts[i])] || "") === activeKeymap) return i
    }
    return -1
  }

  readonly property string displayMode: String(root.setting("displayMode", "flag"))

  readonly property string activeCode: {
    if (activeIndex >= 0) return String(layouts[activeIndex].code).toLowerCase()
    var key = codesByName[String(activeKeymap)]
    if (key) return String(key).replace(/\(.*$/, "").toLowerCase()
    return fallbackAbbrev(activeKeymap).toLowerCase()
  }

  function flagPathFor(code) {
    if (!code) return ""
    var c = String(code).toLowerCase().trim().replace(/[^a-z0-9_]/g, "")
    if (c === "en") c = "us"
    return Qt.resolvedUrl("flags/" + c + ".svg")
  }

  readonly property string barLabel: activeIndex >= 0
    ? abbrevFor(layouts[activeIndex].code)
    : (activeKeymap !== "" ? fallbackAbbrev(activeKeymap) : "")

  function abbrevFor(code) {
    return String(code).toUpperCase().substring(0, 3)
  }

  // When the keymap name has no known code (custom variants, older Hyprland),
  // fall back to the first letters of the name, KeyboardLayout-widget style.
  function fallbackAbbrev(keymap) {
    return String(keymap).split(/\s+/)[0].substring(0, 2).toUpperCase()
  }

  function labelForKeymap(keymap) {
    var key = codesByName[String(keymap)]
    // Variant keys look like "us(dvorak)"; the flash shows the code alone.
    return key ? abbrevFor(String(key).replace(/\(.*$/, "")) : fallbackAbbrev(keymap)
  }

  function nameFor(entry) {
    var named = namesByCode[keyFor(entry)]
    if (named) return String(named)
    var base = namesByCode[entry.code]
    if (base && entry.variant) return String(base) + " (" + entry.variant + ")"
    return String(base || keyFor(entry))
  }

  // A refresh that lands while a devices query is in flight must not be
  // dropped — the in-flight query carries pre-switch state, and the next
  // scheduled poll can be 10s away. It is queued and re-run when the query
  // exits, stock keyboard-layout-widget style.
  property bool refreshPending: false
  function refresh() {
    if (queryProc.running) {
      root.refreshPending = true
      return
    }
    queryProc.running = true
  }

  // fcitx5, ydotool and friends bind virtual keyboards that can take over
  // the seat's main flag, so on such setups no real keyboard is ever main —
  // fall back to a device that looks like an actual keyboard, then to any
  // real device at all (they all report the same layout state anyway). A
  // roster of nothing but virtual devices resolves to none: guessing from
  // a virtual keyboard would pin the bar to its stale layout.
  function selectKeyboard(keyboards) {
    const typed = keyboards.filter(k => String(k.name).indexOf("virtual") === -1)
    return typed.find(k => k.main)
      ?? typed.find(k => k.name === root.keyboardName)
      ?? typed.find(k => String(k.name).indexOf("keyboard") !== -1)
      ?? typed[typed.length - 1]
  }

  // switchxkblayout is a hyprctl command rather than a dispatcher, so it has
  // to be run rather than sent over the dispatch socket. "all" rather than a
  // device name: with fcitx5 in the seat the main flag sits on its virtual
  // keyboard, and addressing every device is what the stock keybinding does.
  function switchTo(index) {
    if (!root.bar) return
    root.bar.run("hyprctl switchxkblayout all " + index)
    refreshTimer.restart()
  }

  function cycleLayout() {
    if (root.layouts.length < 2) return
    // When the catalog cannot name the active keymap (missing rules file,
    // exotic layout) activeIndex is -1 and index arithmetic would always
    // land on 0 — let Hyprland do the cycling instead.
    if (root.activeIndex < 0) {
      if (!root.bar) return
      root.bar.run("hyprctl switchxkblayout all next")
      refreshTimer.restart()
      return
    }
    switchTo((root.activeIndex + 1) % root.layouts.length)
  }

  function runBackend(args) {
    if (actionProc.running) return false
    root.busy = true
    actionProc.command = ["bash", root.backendPath].concat(args.map(String))
    actionProc.running = true
    return true
  }

  // Accepts a catalog key: "us" or "us(dvorak)".
  function addLanguage(key) {
    if (!key) return
    var m = String(key).match(/^([a-z0-9_]+)\((.+)\)$/)
    if (m) runBackend(["add", m[1], m[2]])
    else runBackend(["add", key])
  }

  function removeLanguage(index) {
    if (root.layouts.length < 2) return
    if (index < 0 || index >= root.layouts.length) return
    runBackend(["remove", index])
  }

  // Order is meaning here: the first layout is the default and SUPER+SPACE
  // cycles in list order. The cursor follows the row it was on — but only
  // once the backend actually accepted the move; a busy backend must not
  // leave the cursor pointing at a neighbour of an unchanged list, and a
  // failed move puts it back.
  property int _cursorBeforeMove: -1
  function moveLayout(index, delta) {
    var to = index + delta
    if (index < 0 || index >= root.layouts.length) return
    if (to < 0 || to >= root.layouts.length) return
    if (!runBackend(["move", index, to])) return
    root._cursorBeforeMove = index
    root.cursorIndex = to
  }

  function moveCursor(dy) {
    if (root.layouts.length === 0) return
    root.cursorActive = true
    root.cursorFromPointer = false
    if (root.cursorIndex < 0)
      root.cursorIndex = root.activeIndex >= 0 ? root.activeIndex : 0
    else
      root.cursorIndex = Math.max(0, Math.min(root.layouts.length - 1, root.cursorIndex + dy))
  }

  onLayoutsChanged: {
    if (cursorIndex >= layouts.length) cursorIndex = layouts.length - 1
  }

  function showOsd(label) {
    if (!root.primaryInstance) return
    if (setting("showOsd", true) !== true || label === "") return
    root.osdText = label
    root.osdVisible = true
    osdTimer.restart()
  }

  Component.onCompleted: {
    if (!availableProc.running) availableProc.running = true
    refresh()
  }

  onOpenedChanged: {
    if (opened) {
      root.lastError = ""
      root.cursorActive = false
      root.cursorIndex = -1
      root.cursorFromPointer = false
      refresh()
      Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    }
  }

  IpcHandler {
    // Only one instance may claim the target — two handlers on one target
    // is a bug in Omarchy's book, and layout state is seat-global anyway.
    enabled: root.primaryInstance
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    // The active layout's catalog key ("us", "us(dvorak)"), so scripts can
    // feed it straight back into `set`. Falls back to the raw keymap name
    // when the catalog does not know the active keymap.
    function status(): string {
      if (root.activeIndex >= 0) return root.keyFor(root.layouts[root.activeIndex])
      return root.activeKeymap !== "" ? root.activeKeymap : "unknown"
    }
    function list(): string {
      var lines = []
      for (var i = 0; i < root.layouts.length; i++)
        lines.push(i + "\t" + root.keyFor(root.layouts[i]) + "\t" + root.nameFor(root.layouts[i])
          + (i === root.activeIndex ? "\t*" : ""))
      return lines.join("\n")
    }
    function next(): string {
      if (root.layouts.length < 2) return "error: only one layout configured"
      root.cycleLayout()
      return "ok"
    }
    // Takes an index from `list` or a catalog key; a bare code matches the
    // first entry with that code.
    function set(target: string): string {
      var t = String(target).trim()
      if (t === "") return "error: usage: set <index|code>"
      if (/^[0-9]+$/.test(t)) {
        if (Number(t) >= root.layouts.length) return "error: index out of range"
        root.switchTo(Number(t))
        return "ok"
      }
      for (var i = 0; i < root.layouts.length; i++) {
        if (root.keyFor(root.layouts[i]) === t || root.layouts[i].code === t) {
          root.switchTo(i)
          return "ok"
        }
      }
      return "error: no such layout: " + t
    }
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (!event || !event.name) return
      var name = String(event.name)
      // A config reload can change kb_layout without emitting activelayout.
      if (name === "configreloaded") {
        root.refresh()
        return
      }
      if (name.indexOf("activelayout") === -1) return
      var data = String(event.data || "")
      // "KEYBOARDNAME,LAYOUTNAME" — skip virtual keyboards (fcitx5,
      // ydotool) so their stale layout never flashes on screen.
      var comma = data.indexOf(",")
      if (comma <= 0) return
      if (data.substring(0, comma).indexOf("virtual") !== -1) return
      // Hyprland replays activelayout on startup and whenever a device
      // (re)appears — a bluetooth headset connecting is enough, and one
      // SUPER+SPACE emits the event once per device. Only an actual change
      // of keymap is a switch worth flashing, and adopting the new keymap
      // right here — before the async devices query lands — is what keeps
      // the second device's replay from flashing a second time. Until the
      // first devices query there is nothing to compare against: stay quiet.
      var keymap = data.substring(comma + 1)
      if (root.activeKeymap !== "" && keymap !== root.activeKeymap) {
        root.showOsd(root.labelForKeymap(keymap))
        root.activeKeymap = keymap
      }
      root.refresh()
    }
  }

  Process {
    id: queryProc
    command: ["hyprctl", "-j", "devices"]
    onRunningChanged: {
      if (running) {
        queryStallTimer.restart()
        return
      }
      queryStallTimer.stop()
      if (root.refreshPending) {
        root.refreshPending = false
        Qt.callLater(root.refresh)
      }
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        let kb
        try {
          kb = root.selectKeyboard(JSON.parse(text || "{}").keyboards ?? [])
        } catch (e) {
          return
        }
        if (!kb || !kb.active_keymap) return

        root.keyboardName = String(kb.name || "")
        root.activeKeymap = String(kb.active_keymap)
        // kb_variant is positional and parallel to kb_layout; keep the pair
        // together per index so a variant never drifts onto another layout.
        var codes = String(kb.layout || "").split(",").map(s => s.trim())
        var vars = String(kb.variant || "").split(",").map(s => s.trim())
        var pairs = []
        for (var i = 0; i < codes.length; i++) {
          if (codes[i] === "") continue
          pairs.push({ code: codes[i], variant: vars[i] || "" })
        }
        root.layouts = pairs
      }
    }
  }

  Process {
    id: availableProc
    command: ["bash", root.backendPath, "available"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var names = {}
        var codes = {}
        var opts = []
        var lines = String(text || "").split("\n")
        for (var i = 0; i < lines.length; i++) {
          var tab = lines[i].indexOf("\t")
          if (tab <= 0) continue
          var code = lines[i].substring(0, tab).trim()
          var name = lines[i].substring(tab + 1).trim()
          if (code === "" || name === "") continue
          names[code] = name
          codes[name] = code
          opts.push({ value: code, label: name, description: code })
        }
        root.namesByCode = names
        root.codesByName = codes
        root.availableOptions = opts
      }
    }
  }

  Process {
    id: actionProc
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var err = String(text || "").trim()
        if (err !== "") root.lastError = err
      }
    }
    onExited: function(exitCode) {
      root.busy = false
      if (exitCode === 0) {
        root.lastError = ""
      } else if (root._cursorBeforeMove >= 0) {
        // The move never happened; put the cursor back on the row it left.
        root.cursorIndex = root._cursorBeforeMove
      }
      root._cursorBeforeMove = -1
      root.refresh()
      refreshTimer.restart()
    }
  }

  // A hung hyprctl must not wedge the widget: queryProc.running would stay
  // true and every later refresh would queue behind it forever.
  Timer {
    id: queryStallTimer
    interval: 5000
    onTriggered: queryProc.running = false
  }

  // hyprctl needs a beat before devices reports the new state.
  Timer {
    id: refreshTimer
    interval: 600
    onTriggered: root.refresh()
  }

  Timer {
    interval: 10000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  Timer {
    id: osdTimer
    // Clamped to the manifest schema's range — a hand-edited settings value
    // must not park the flash on screen for minutes.
    interval: Math.min(5000, Math.max(200, Number(root.setting("osdDurationMs", 750)) || 750))
    onTriggered: root.osdVisible = false
  }

  visible: barLabel !== ""
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.displayMode === "flag" ? "     " : (root.displayMode === "both" ? "       " + root.barLabel : root.barLabel)
    fontSize: Style.font.body
    horizontalMargin: root.displayMode === "flag" ? 6 : 7
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.cycleLayout()
      else root.toggle()
    }

    labelVisible: false

    Row {
      anchors.centerIn: parent
      anchors.verticalCenterOffset: 0
      spacing: Style.space(6)

      Rectangle {
        id: flagBadge
        visible: root.displayMode !== "text" && flagImg.status === Image.Ready
        width: Style.space(19)
        height: Style.space(13)
        anchors.verticalCenter: parent.verticalCenter
        radius: Style.space(2)
        color: "transparent"
        clip: true

        Image {
          id: flagImg
          anchors.fill: parent
          source: root.flagPathFor(root.activeCode)
          sourceSize.width: 38
          sourceSize.height: 26
          fillMode: Image.PreserveAspectCrop
          smooth: true
        }

        Rectangle {
          anchors.fill: parent
          radius: parent.radius
          color: "transparent"
          border.color: Qt.rgba(1, 1, 1, 0.18)
          border.width: 1
        }
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        anchors.verticalCenterOffset: 1
        visible: root.displayMode !== "flag" || flagImg.status !== Image.Ready
        text: root.barLabel
        color: button.active && button.useActiveColor ? button.activeColor : button.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
        renderType: Text.NativeRendering
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(480))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: addPicker.popupOpen
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) { if (dy !== 0) root.moveCursor(dy) }
      onActivateRequested: {
        if (root.cursorActive && root.cursorIndex >= 0) root.switchTo(root.cursorIndex)
      }
      onDeleteRequested: {
        if (root.cursorActive && root.cursorIndex >= 0) root.removeLanguage(root.cursorIndex)
      }
      onTextKey: function(t) {
        if (t === "a" || t === "/") addPicker.open()
        else if (t === "r") root.refresh()
        // Shifted j/k reorder the row under the cursor — order is the
        // cycle order and the default layout, so it deserves keys too.
        else if (t === "J" && root.cursorActive) root.moveLayout(root.cursorIndex, 1)
        else if (t === "K" && root.cursorActive) root.moveLayout(root.cursorIndex, -1)
      }

      Column {
        id: column
        width: parent.width
        spacing: Style.space(8)

        PanelSectionHeader {
          text: "LANGUAGES"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        // The outer column's gap is section rhythm; the rows themselves sit
        // nearly flush, like every other list panel on the bar.
        Column {
          width: column.width
          spacing: Style.space(2)

          Repeater {
            model: root.layouts

            // CursorSurface for the house row chrome: shared hover fill with
            // the hover-cursor border, selected fill on the active layout,
            // and the same 60ms color easing as every other list panel.
            // Per the CursorSurface contract, visuals derive from the root
            // cursor state — hover feeds that state instead of painting.
            delegate: CursorSurface {
              id: row
              required property int index
              required property var modelData
              readonly property bool isActive: index === root.activeIndex

              width: column.width
              height: Style.space(34)
              foreground: root.foreground
              hasCursor: root.cursorActive && root.cursorIndex === row.index
              current: isActive

              MouseArea {
                id: rowMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.switchTo(row.index)
                onContainsMouseChanged: {
                  if (containsMouse) {
                    root.cursorActive = true
                    root.cursorIndex = row.index
                    root.cursorFromPointer = true
                  } else if (root.cursorFromPointer && root.cursorIndex === row.index) {
                    // The pointer left and no neighbour claimed the cursor:
                    // a mouse-parked highlight must not outlive the mouse.
                    // The index guard keeps enter/exit races between adjacent
                    // rows from wiping a freshly claimed cursor.
                    root.cursorActive = false
                    root.cursorIndex = -1
                    root.cursorFromPointer = false
                  }
                }
              }

              Rectangle {
                id: rowFlagBadge
                anchors.left: parent.left
                anchors.leftMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(20)
                height: Style.space(14)
                radius: Style.space(2)
                color: "transparent"
                clip: true

                Image {
                  id: rowFlagImg
                  anchors.fill: parent
                  source: root.flagPathFor(row.modelData.code)
                  sourceSize.width: 40
                  sourceSize.height: 28
                  fillMode: Image.PreserveAspectCrop
                  smooth: true
                }

                Rectangle {
                  anchors.fill: parent
                  radius: parent.radius
                  color: "transparent"
                  border.color: Qt.rgba(1, 1, 1, 0.15)
                  border.width: 1
                }
              }

              Text {
                id: rowAbbrev
                anchors.left: rowFlagBadge.right
                anchors.leftMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                text: root.abbrevFor(row.modelData.code)
                color: row.isActive ? Color.accent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
              }

              Text {
                anchors.left: rowAbbrev.right
                anchors.leftMargin: Style.space(10)
                anchors.right: rowButtons.visible ? rowButtons.left
                  : (activeCheck.visible ? activeCheck.left : parent.right)
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                text: root.nameFor(row.modelData)
                color: row.isActive ? root.foreground : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
              }

              // One check, at the row's right edge; the cursor-only action
              // buttons take that slot when they show, so they never stack.
              Text {
                id: activeCheck
                anchors.right: parent.right
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                visible: row.isActive && !rowButtons.visible
                text: "✓"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }

              Row {
                id: rowButtons
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(2)
                visible: row.hasCursor

                PanelActionButton {
                  iconText: "↑"
                  tooltipText: "Move up"
                  foreground: root.dim
                  fontFamily: root.fontFamily
                  enabled: !root.busy && row.index > 0
                  onClicked: root.moveLayout(row.index, -1)
                }

                PanelActionButton {
                  iconText: "↓"
                  tooltipText: "Move down"
                  foreground: root.dim
                  fontFamily: root.fontFamily
                  enabled: !root.busy && row.index < root.layouts.length - 1
                  onClicked: root.moveLayout(row.index, 1)
                }

                PanelActionButton {
                  visible: root.layouts.length > 1
                  iconText: "󰆴"
                  tooltipText: "Remove"
                  foreground: root.dim
                  hoverColor: root.bar ? root.bar.urgent : Color.urgent
                  fontFamily: root.fontFamily
                  enabled: !root.busy
                  onClicked: root.removeLanguage(row.index)
                }
              }
            }
          }
        }

        PanelSeparator {
          foreground: root.foreground
        }

        // No section header here: the trigger already says "Add language…",
        // and a header repeating it right above reads as a duplicate.
        SearchableDropdown {
          id: addPicker
          width: column.width
          showLabel: false
          value: ""
          triggerLabel: root.busy ? "Working…" : "Add language…"
          placeholderText: "Search layouts…"
          options: root.availableOptions
          foreground: root.foreground
          fontFamily: root.fontFamily
          onChanged: function(newValue) {
            root.addLanguage(newValue)
            addPicker.value = ""
          }
        }

        PanelSeparator {
          foreground: root.foreground
        }

        Row {
          width: column.width
          spacing: Style.space(6)

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "Display:"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Item { width: Style.space(2); height: 1 }

          Repeater {
            model: [
              { id: "flag", label: "Flag" },
              { id: "text", label: "Text" },
              { id: "both", label: "Both" }
            ]

            delegate: CursorSurface {
              id: modeChip
              required property var modelData
              readonly property bool isSelected: root.displayMode === modelData.id
              width: (column.width - Style.space(80)) / 3
              height: Style.space(26)
              radius: Style.space(4)
              color: isSelected ? Qt.rgba(1, 1, 1, 0.12) : "transparent"
              border.color: isSelected ? Color.accent : Qt.rgba(1, 1, 1, 0.1)
              border.width: 1

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  if (root.bar) {
                    root.bar.run("omarchy bar set glafeara.languages displayMode " + modeChip.modelData.id)
                  }
                }
              }

              Text {
                anchors.centerIn: parent
                text: modeChip.modelData.label
                color: modeChip.isSelected ? Color.accent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: modeChip.isSelected
              }
            }
          }
        }

        Text {
          width: column.width
          visible: root.lastError !== ""
          text: root.lastError
          color: root.bar ? root.bar.urgent : Color.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }
    }
  }

  // Centered on-screen indicator flashing the abbreviation of the layout
  // just switched to. It follows the monitor Hyprland has focused — that is
  // where the user is typing, which need not be the monitor this widget's
  // bar instance lives on.
  PanelWindow {
    id: osdWindow
    visible: root.osdVisible
    screen: {
      var focusedName = Hyprland.focusedMonitor ? String(Hyprland.focusedMonitor.name || "") : ""
      var screens = Quickshell.screens
      for (var i = 0; i < screens.length; i++) {
        if (String(screens[i].name) === focusedName) return screens[i]
      }
      return root.QsWindow.window ? root.QsWindow.window.screen : null
    }
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omalang-osd"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    // Keep the input region empty so the flash never steals clicks from
    // whatever the user is typing into.
    mask: Region {}

    BorderSurface {
      id: osdCard
      anchors.centerIn: parent
      color: Color.popups.background
      // Mirrors the theme's decoration:rounding, like the stock OSD card.
      radius: Style.cornerRadius
      borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))
      width: Style.space(160)
      height: Style.space(130)

      Column {
        anchors.centerIn: parent
        spacing: Style.space(10)

        Rectangle {
          id: osdFlagBadge
          visible: osdFlagImg.status === Image.Ready && root.displayMode !== "text"
          anchors.horizontalCenter: parent.horizontalCenter
          width: Style.space(80)
          height: Style.space(54)
          radius: Style.space(6)
          color: "transparent"
          clip: true

          Image {
            id: osdFlagImg
            anchors.fill: parent
            source: root.flagPathFor(root.osdText)
            sourceSize.width: 160
            sourceSize.height: 108
            fillMode: Image.PreserveAspectCrop
            smooth: true
          }

          Rectangle {
            anchors.fill: parent
            radius: parent.radius
            color: "transparent"
            border.color: Qt.rgba(1, 1, 1, 0.22)
            border.width: 1
          }
        }

        Text {
          id: osdLabel
          anchors.horizontalCenter: parent.horizontalCenter
          text: root.osdText
          color: Color.popups.text
          font.family: root.fontFamily
          font.pixelSize: (osdFlagBadge.visible ? Style.font.titleLarge : Style.font.displayLarge * 2)
          font.bold: true
        }
      }
    }
  }
}

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
  ipcTarget: ""
  manageIpc: false

  readonly property string backendPath: String(Qt.resolvedUrl("backend.sh")).replace(/^file:\/\//, "")

  property string keyboardName: ""
  // xkb codes in kb_layout order, e.g. ["us", "ru"], read from hyprctl so the
  // panel always reflects what the compositor actually runs.
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

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color hoverFill: bar ? Style.hoverFillFor(bar.foreground, Color.accent) : "transparent"

  readonly property int activeIndex: {
    for (var i = 0; i < layouts.length; i++) {
      if (String(namesByCode[layouts[i]] || "") === activeKeymap) return i
    }
    return -1
  }

  readonly property string barLabel: activeIndex >= 0
    ? abbrevFor(layouts[activeIndex])
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
    var code = codesByName[String(keymap)]
    return code ? abbrevFor(code) : fallbackAbbrev(keymap)
  }

  function nameFor(code) {
    return String(namesByCode[code] || code)
  }

  function refresh() {
    if (!queryProc.running) queryProc.running = true
  }

  // fcitx5 binds a virtual keyboard that takes over the seat's main flag, so
  // on such setups no real keyboard is ever main — fall back to a device that
  // looks like an actual keyboard, then to any real device at all (they all
  // report the same layout state anyway).
  function selectKeyboard(keyboards) {
    const typed = keyboards.filter(k => !String(k.name).startsWith("hl-virtual-keyboard"))
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
    switchTo((root.activeIndex + 1) % root.layouts.length)
  }

  function runBackend(args) {
    if (actionProc.running) return
    root.busy = true
    actionProc.command = ["bash", root.backendPath].concat(args)
    actionProc.running = true
  }

  function addLanguage(code) {
    if (!code) return
    runBackend(["add", String(code)])
  }

  function removeLanguage(code) {
    if (root.layouts.length < 2) return
    runBackend(["remove", String(code)])
  }

  function showOsd(label) {
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
      refresh()
      Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    }
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (!event || !event.name) return
      if (String(event.name).indexOf("activelayout") === -1) return
      var data = String(event.data || "")
      // "KEYBOARDNAME,LAYOUTNAME" — skip the input method's virtual keyboard
      // so its stale us layout never flashes on screen.
      if (data.startsWith("hl-virtual-keyboard")) return
      var comma = data.indexOf(",")
      if (comma > 0) {
        // Hyprland replays activelayout on startup and whenever a device
        // (re)appears — a bluetooth headset connecting is enough. Only an
        // actual change of keymap is a switch worth flashing on screen, and
        // until the first devices query lands there is nothing to compare
        // against, so stay quiet.
        var keymap = data.substring(comma + 1)
        if (root.activeKeymap !== "" && keymap !== root.activeKeymap)
          root.showOsd(root.labelForKeymap(keymap))
      }
      root.refresh()
    }
  }

  Process {
    id: queryProc
    command: ["hyprctl", "-j", "devices"]
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
        root.layouts = String(kb.layout || "").split(",").map(s => s.trim()).filter(s => s !== "")
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
      if (exitCode === 0) root.lastError = ""
      root.refresh()
      refreshTimer.restart()
    }
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
    interval: Math.max(200, Number(root.setting("osdDurationMs", 750)) || 750)
    onTriggered: root.osdVisible = false
  }

  visible: barLabel !== ""
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.barLabel
    fontSize: Style.font.body
    horizontalMargin: 7
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.cycleLayout()
      else root.toggle()
    }

    // The stock label is 10px regular — too faint to read at a glance next to
    // the bar's 13px icons. Hide it (it still sizes the slot) and paint the
    // abbreviation bold at body size instead.
    labelVisible: false

    Text {
      anchors.centerIn: parent
      // Box-centering puts cap-height ink a hair above the optical center the
      // bar icons sit on; one pixel down lines the label up with them.
      anchors.verticalCenterOffset: 1
      text: root.barLabel
      color: button.active && button.useActiveColor ? button.activeColor : button.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      font.bold: true
      renderType: Text.NativeRendering
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
            delegate: CursorSurface {
              id: row
              required property int index
              required property string modelData
              readonly property bool isActive: index === root.activeIndex

              width: column.width
              height: Style.space(34)
              foreground: root.foreground
              hasCursor: rowMouse.containsMouse
              current: isActive

              MouseArea {
                id: rowMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.switchTo(row.index)
              }

              Text {
                id: rowAbbrev
                anchors.left: parent.left
                anchors.leftMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                text: root.abbrevFor(row.modelData)
                color: row.isActive ? Color.accent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
              }

              Text {
                anchors.left: rowAbbrev.right
                anchors.leftMargin: Style.space(10)
                anchors.right: removeButton.visible ? removeButton.left : parent.right
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                text: root.nameFor(row.modelData) + (row.isActive ? "  ✓" : "")
                color: row.isActive ? root.foreground : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
              }

              PanelActionButton {
                id: removeButton
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                visible: root.layouts.length > 1 && rowMouse.containsMouse
                iconText: "󰆴"
                tooltipText: "Remove"
                foreground: root.dim
                hoverColor: root.bar ? root.bar.urgent : Color.urgent
                fontFamily: root.fontFamily
                enabled: !root.busy
                onClicked: root.removeLanguage(row.modelData)
              }
            }
          }
        }

        PanelSeparator {
          foreground: root.foreground
        }

        PanelSectionHeader {
          text: "ADD LANGUAGE"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

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

  // Centered on-screen indicator: a visual-only overlay on this widget's own
  // monitor, flashing the abbreviation of the layout just switched to.
  PanelWindow {
    id: osdWindow
    visible: root.osdVisible
    screen: root.QsWindow.window ? root.QsWindow.window.screen : null
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
      width: Math.max(osdLabel.implicitHeight, osdLabel.implicitWidth) + Style.space(48)
      height: osdLabel.implicitHeight + Style.space(48)

      Text {
        id: osdLabel
        anchors.centerIn: parent
        text: root.osdText
        color: Color.popups.text
        font.family: root.fontFamily
        font.pixelSize: Style.font.displayLarge * 2
        font.bold: true
      }
    }
  }
}

import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import qs.Commons as Commons
import "Model.js" as Model
import "Schedule.js" as Schedule

Panel {
  id: root
  moduleName: "albertus.monitor"
  ipcTarget: "omarchy.monitor"
  manageIpc: false

  // manageIpc: false so this panel can own the single IpcHandler the target
  // permits — needed for the brightness + state methods below.
  property int brightnessPercent: 0
  property int pendingBrightnessPercent: 0
  property bool brightnessSetQueued: false
  property bool brightnessAvailable: false
  property string internalMonitor: ""
  property string externalMonitor: ""
  property string focusedMonitor: ""
  property bool internalEnabled: false
  property bool mirrorEnabled: false
  property string monitorScale: ""
  property var displays: []
  property int enabledDisplayCount: 0

  // Carry sub-notch touchpad deltas between wheel events.
  property real wheelAccumulator: 0

  // Cursor model shared by keyboard and mouse. Sections:
  //   "brightness" - single slider row, selectedIndex = -1 sentinel
  //                  (mirrors Audio's slider rows). Only present if a
  //                  controllable backlight was detected.
  //   "scale"      - 6 Button scale presets; treated as a single
  //                  horizontal row from j/k's perspective. h/l moves
  //                  between presets, identical to bluetooth's header.
  //   "monitors"   - vertical display row list for enabling/disabling displays;
  //                  j/k walks each row.
  // Mouse hover on a target updates root state via the components' `hovered`
  // signal so keyboard cursor and pointer share one highlight.
  readonly property var scalePresets: ["1", "1.25", "1.6", "2", "3", "4"]
  readonly property var scaleValues: {
    for (var i = 0; i < displays.length; i++) {
      var display = displays[i]
      if (display && display.focused)
        return Model.availableScales(scalePresets, display.width, display.height)
    }
    return scalePresets
  }
  property string focusSection: "scale"
  property int selectedIndex: 0
  property bool cursorActive: false

  // Text size slider — curated macOS-style notches (px). The panel snaps to
  // these stops; the CLI (omarchy-display-text-size) accepts any integer in range.
  readonly property var textSizeStops: [9, 10, 11, 12, 14, 16, 20]
  // While a change is in flight, the chosen stop index overrides the live
  // base-size so the knob doesn't snap back during the file round-trip. -1 =
  // no pending change; follow Style.font.baseSize.
  property int textSizePreviewIndex: -1

  // A text-size change reflows the whole panel (both font and spacing scale),
  // which slides rows under a stationary pointer and fires synthetic hover.
  // While true, hover is not allowed to hijack the keyboard focus section —
  // otherwise h/l on the text-size slider can jump focus to another row.
  property bool reflowingText: false
  function markReflowing() {
    root.reflowingText = true
    reflowSettle.restart()
  }

  readonly property var visibleSections: {
    var list = []
    if (brightnessAvailable) list.push("brightness")
    list.push("textsize")
    list.push("scale")
    if (displays.length > 1) list.push("monitors")
    return list
  }

  function sectionCount(section) {
    if (section === "brightness") return 0  // only the slider sentinel at -1
    if (section === "textsize") return 0    // slider sentinel at -1, like brightness
    if (section === "scale") return scaleValues.length
    if (section === "monitors") return displays.length
    return 0
  }

  function sectionIsSingleRow(section) {
    // brightness and text size are lone sliders; scale presets sit horizontally.
    return section === "brightness" || section === "textsize" || section === "scale"
  }

  function sectionFirstIndex(section) {
    if (section === "brightness" || section === "textsize") return -1
    return 0
  }

  function moveCursor(delta) {
    var sections = visibleSections
    if (!sections || sections.length === 0) return
    var sIdx = sections.indexOf(focusSection)
    if (sIdx < 0) {
      focusSection = sections[0]
      selectedIndex = sectionFirstIndex(focusSection)
      return
    }
    var inSingleRow = sectionIsSingleRow(focusSection)
    var max = inSingleRow ? 0 : sectionCount(focusSection) - 1

    if (delta > 0) {
      if (!inSingleRow && selectedIndex < max) { selectedIndex = selectedIndex + 1; return }
      if (sIdx < sections.length - 1) {
        focusSection = sections[sIdx + 1]
        selectedIndex = sectionFirstIndex(focusSection)
      }
    } else {
      if (!inSingleRow && selectedIndex > 0) { selectedIndex = selectedIndex - 1; return }
      if (sIdx > 0) {
        var prev = sections[sIdx - 1]
        focusSection = prev
        // Coming up from below — land on the last navigable row of the prev
        // section, or its sentinel for single-row sections.
        selectedIndex = sectionIsSingleRow(prev) ? sectionFirstIndex(prev) : sectionCount(prev) - 1
      }
    }
  }

  // h/l: in scale section, walks the preset row; everywhere else, no-op
  // because adjustBrightness handles horizontal motion on the brightness
  // slider.
  function moveCursorH(delta) {
    if (focusSection !== "scale") return
    var next = selectedIndex + delta
    if (next < 0) next = 0
    if (next > scaleValues.length - 1) next = scaleValues.length - 1
    selectedIndex = next
  }

  function adjustBrightness(delta) {
    if (focusSection !== "brightness") return
    if (!brightnessAvailable) return
    manualBrightness(root.brightnessPercent + delta)
  }

  function activateCursor() {
    if (focusSection === "scale" && selectedIndex >= 0 && selectedIndex < scaleValues.length) {
      setScale(scaleValues[selectedIndex])
      return
    }
    if (focusSection === "monitors" && selectedIndex >= 0 && selectedIndex < displays.length) {
      var d = displays[selectedIndex]
      if (d) toggleDisplay(d.name, d.enabled)
    }
    // brightness: no separate action; the slider value is the action.
  }

  function clampCursor() {
    var sections = visibleSections
    if (!sections || !sections.length) return
    if (sections.indexOf(focusSection) < 0) {
      focusSection = sections[0]
      selectedIndex = sectionFirstIndex(focusSection)
      return
    }
    var count = sectionCount(focusSection)
    if (sectionIsSingleRow(focusSection)) {
      // brightness/text size use the -1 sentinel; scale clamps into the presets.
      if (focusSection === "brightness" || focusSection === "textsize") selectedIndex = -1
      else if (selectedIndex < 0 || selectedIndex >= count) selectedIndex = 0
      return
    }
    if (count === 0) {
      var sIdx = sections.indexOf(focusSection)
      focusSection = sIdx > 0 ? sections[sIdx - 1] : sections[0]
      selectedIndex = sectionFirstIndex(focusSection)
      return
    }
    if (selectedIndex > count - 1) selectedIndex = count - 1
    if (selectedIndex < 0) selectedIndex = 0
  }

  // Keep the keyboard-focused row inside the viewport when the panel grows
  // taller than its allotted height (lots of displays). Mirrors audio's
  // ensureCursorVisible helper.
  function ensureCursorVisible(item) {
    var scrollArea = panel.loadedContent ? panel.loadedContent.scrollArea : null
    if (!item || !scrollArea) return
    var flick = scrollArea.contentItem
    if (!flick || flick.contentY === undefined) return
    var pt = item.mapToItem(flick.contentItem || flick, 0, 0)
    var top = pt.y
    var bottom = top + (item.height || 0)
    var viewTop = flick.contentY
    var viewBottom = viewTop + flick.height
    var margin = 6
    if (top < viewTop + margin) flick.contentY = Math.max(0, top - margin)
    else if (bottom > viewBottom - margin)
      flick.contentY = bottom + margin - flick.height
  }

  function brightnessIpc(percent) {
    var value = Number(percent)
    root.setBrightness(value)
    return "got " + root.pendingBrightnessPercent
  }

  function stateIpc() {
    return JSON.stringify({
      brightness: root.brightnessPercent,
      brightnessAvailable: root.brightnessAvailable,
      focusedMonitor: root.focusedMonitor,
      scale: root.monitorScale,
      displays: root.displays
    })
  }

  ShellIpc {
    target: "omarchy.monitor"

    function brightness(percent: string): string { return root.brightnessIpc(percent) }
    function state(): string { return root.stateIpc() }
    function open() { root.open() }
    function close() { root.close() }
    function toggle() { root.toggle() }
    function show() { root.open() }
    function hide() { root.close() }
  }

  function refresh() {
    if (!stateProc.running) stateProc.running = true
  }

  // ---------------- brightness schedule (Service.qml) ----------------
  // Same editor as the Night Light panel: the switch in the hero toggles the
  // schedule; schedule edits are a draft until Save.

  readonly property var schedule: bar && bar.shell ? bar.shell.serviceFor("albertus.monitor") : null
  readonly property bool scheduleReady: !!schedule && schedule.stateLoaded
  readonly property bool scheduleOn: scheduleReady && schedule.enabled
  readonly property bool scheduleManual: scheduleReady && schedule.overrideActive
  readonly property var schedulePoints: scheduleReady ? schedule.points : []

  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.4)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property real rowHeight: Style.spacing.controlHeight
  readonly property real timeWidth: Style.space(60)
  readonly property real valueWidth: Style.space(92)
  readonly property real modeWidth: Style.space(84)
  readonly property real stepWidth: Style.space(64)
  readonly property real colGap: Style.space(6)
  readonly property real plotInset: Style.space(6)

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  property var draft: []
  property bool dirty: false
  property bool editing: false
  function syncDraft() {
    draft = schedulePoints.map(function(p) { return Object.assign({}, p) })
    dirty = false
  }
  onSchedulePointsChanged: if (!dirty) syncDraft()
  onScheduleOnChanged: if (!scheduleOn) editing = false
  function editDraft(index, patch) {
    if (index < 0 || index >= draft.length) return
    var next = draft.slice()
    next[index] = Object.assign({}, next[index], patch)
    draft = Schedule.normalizePoints(next)
    dirty = true
  }
  function addDraftPoint() {
    draft = Schedule.normalizePoints(draft.concat([Schedule.suggestPoint(draft)]))
    dirty = true
  }
  function removeDraftPoint(index) {
    var next = draft.slice()
    next.splice(index, 1)
    draft = next
    dirty = true
  }
  function saveSchedule() {
    if (schedule && dirty) schedule.setPoints(draft)
    dirty = false
    editing = false
  }
  function clockLabel(ms) { return Qt.formatTime(new Date(ms), "HH:mm") }
  function transitionNext(t) {
    var i = Schedule.TRANSITIONS.indexOf(t)
    return Schedule.TRANSITIONS[(i + 1) % Schedule.TRANSITIONS.length]
  }
  function transitionIcon(t) {
    if (t === "fade") return String.fromCodePoint(0xF0533)   // md-trending_down
    if (t === "steps") return String.fromCodePoint(0xF04CD)  // md-stairs
    return String.fromCodePoint(0xF0054)                     // md-arrow_right
  }

  // With the schedule on, a manual brightness holds until the next point;
  // off, the slider works exactly as before.
  function manualBrightness(value) {
    if (scheduleOn) {
      brightnessPercent = Model.clampBrightness(value)
      schedule.setOverride(brightnessPercent)
    } else {
      setBrightness(value)
    }
  }

  function setBrightness(value) {
    var percent = Model.clampBrightness(value)
    root.brightnessPercent = percent
    root.pendingBrightnessPercent = percent

    if (setBrightnessProc.running) {
      root.brightnessSetQueued = true
      return
    }

    root.brightnessSetQueued = false
    setBrightnessProc.command = ["omarchy-brightness-display", "--no-osd", "--monitor", root.focusedMonitor, percent + "%"]
    setBrightnessProc.running = true
  }

  function previewBrightness(value) {
    root.brightnessPercent = Model.clampBrightness(value)
    brightnessDebounce.restart()
  }

  function showBrightnessOsd(percent) {
    if (!bar || !bar.shell) return
    bar.shell.summon("omarchy.osd", JSON.stringify({
      icon: "brightness",
      value: percent
    }))
  }

  function normalizeScale(scale) {
    return Model.normalizeScale(scale)
  }

  function activeScaleIndex() {
    for (var i = 0; i < displays.length; i++) {
      var display = displays[i]
      if (display && display.focused)
        return Model.matchingScaleIndex(scaleValues, monitorScale, display.width, display.height)
    }
    return -1
  }

  function effectiveScale(scale) {
    for (var i = 0; i < displays.length; i++) {
      var display = displays[i]
      if (display && display.focused)
        return Model.cleanScale(scale, display.width, display.height)
    }
    return normalizeScale(scale)
  }

  // Playful mood-name for a given brightness percent. Bands intentionally
  // span ~10–20 points so casual tweaks change the label, while small
  // nudges within one band don't.
  function brightnessName(percent) {
    return Model.brightnessName(percent, Commons.I18n.t)
  }

  function updateDisplays(displaysJson) {
    var parsed = Model.parseDisplays(displaysJson)
    root.displays = parsed.displays
    root.enabledDisplayCount = parsed.enabledDisplayCount
  }

  function toggleDisplay(name, enabled) {
    if (!name) return
    if (enabled && root.enabledDisplayCount <= 1) return

    // hyprctl keyword is rejected under the Lua config ("non-legacy parsers"),
    // so drive the monitor through the hl.monitor eval API instead.
    var output = '"' + name.replace(/[\\"]/g, "\\$&") + '"'
    // hl.monitor updates the existing rule. Keep its mode, position and scale
    // when bringing the display back.
    var expr = enabled
      ? 'hl.monitor({ output = ' + output + ', disabled = true })'
      : 'hl.monitor({ output = ' + output + ', disabled = false })'
    actionProc.command = ["hyprctl", "eval", expr]
    if (!actionProc.running) actionProc.running = true
  }

  function setScale(scale) {
    actionProc.command = ["bash", "-c", "omarchy-hyprland-monitor-scaling " + scale]
    if (!actionProc.running) actionProc.running = true
  }

  // ---- Text size (shell base font + GTK text-scaling, via one CLI) ----
  function nearestTextStop(px) {
    var best = 0
    var bestDist = 1e9
    for (var i = 0; i < textSizeStops.length; i++) {
      var d = Math.abs(textSizeStops[i] - px)
      if (d < bestDist) { bestDist = d; best = i }
    }
    return best
  }

  // Effective stop index: the pending choice while a change is in flight,
  // otherwise whatever Style's live base-size rounds to.
  function currentTextIndex() {
    return textSizePreviewIndex >= 0 ? textSizePreviewIndex : nearestTextStop(Style.font.baseSize)
  }

  // px shown in the header: the pending stop if any, else the true base-size
  // (which may be an off-notch value set from the CLI).
  function displayedTextPx() {
    return textSizePreviewIndex >= 0 ? textSizeStops[textSizePreviewIndex] : Style.font.baseSize
  }

  function setTextSize(px) {
    textScaleProc.command = ["omarchy-display-text-size", String(px)]
    if (!textScaleProc.running) textScaleProc.running = true
  }

  function adjustTextSize(deltaSteps) {
    var idx = currentTextIndex() + deltaSteps
    if (idx < 0) idx = 0
    if (idx > textSizeStops.length - 1) idx = textSizeStops.length - 1
    markReflowing()
    textSizePreviewIndex = idx
    setTextSize(textSizeStops[idx])
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Component.onCompleted: refresh()

  // KeyboardPanel primes focus at open-time, so SUPER-bound IPC summons land
  // with j/k ready to navigate. Keep a default landing point, but don't paint
  // the cursor until hover or the first navigation key.
  onOpenedChanged: {
    if (opened) {
      refresh()
      syncDraft()
      editing = false
      if (brightnessAvailable) {
        focusSection = "brightness"
        selectedIndex = -1
      } else {
        focusSection = "scale"
        selectedIndex = 0
      }
      cursorActive = false
    }
  }

  onBrightnessAvailableChanged: clampCursor()
  onDisplaysChanged: clampCursor()
  onScaleValuesChanged: clampCursor()
  onVisibleSectionsChanged: clampCursor()

  // Only poll while the panel is open; the bar glyph tracks monitor count via
  // Quickshell.screens, and open-time refresh + Component.onCompleted cover the
  // rest. External brightness changes are reflected whenever the panel is open.
  Timer {
    interval: 5000
    running: root.opened
    repeat: true
    onTriggered: root.refresh()
  }

  Process {
    id: stateProc
    command: ["omarchy-monitor-state"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var lines = String(text || "").split("\n")
        var brightness = String(lines[0] || "").trim()
        root.brightnessAvailable = brightness !== "unavailable" && brightness !== ""
        root.brightnessPercent = root.brightnessAvailable ? Math.max(0, Math.min(100, parseInt(brightness, 10))) : 0
        root.internalMonitor = String(lines[1] || "").trim()
        root.externalMonitor = String(lines[2] || "").trim()
        root.internalEnabled = String(lines[3] || "").trim() !== ""
        root.mirrorEnabled = String(lines[4] || "").trim() === root.externalMonitor && root.externalMonitor !== ""
        root.focusedMonitor = String(lines[5] || "").trim()
        root.monitorScale = root.normalizeScale(String(lines[6] || "").trim())
        root.updateDisplays(String(lines[7] || "[]").trim())
      }
    }
  }

  Timer {
    id: brightnessDebounce
    interval: 180
    repeat: false
    onTriggered: root.setBrightness(root.brightnessPercent)
  }

  Process {
    id: setBrightnessProc
    stdout: StdioCollector { waitForEnd: true }
    // Do NOT call refresh() after a brightness set completes. The local
    // brightnessPercent we just wrote is authoritative; re-reading via
    // `omarchy-brightness-display` races the hardware/driver and can
    // return an empty string, which the parser then coerces to 0 —
    // visible as a "bounce to zero" after h/l keypresses. External
    // brightness changes are still picked up by the 5s periodic refresh,
    // the open-time refresh, and Component.onCompleted.
    onRunningChanged: {
      if (running) return
      if (root.brightnessSetQueued) {
        root.setBrightness(root.pendingBrightnessPercent)
      }
    }
  }

  Process {
    id: actionProc
    stdout: StdioCollector { waitForEnd: true }
    onRunningChanged: if (!running) root.refresh()
  }

  // Applies text size via the CLI, which rewrites the shell override file;
  // Style picks the new base-size up through its own file watch, so there's
  // nothing to refresh here.
  Process {
    id: textScaleProc
    stdout: StdioCollector { waitForEnd: true }
  }

  // Clears the hover-suppression flag once the reflow triggered by a text-size
  // change has settled.
  Timer {
    id: reflowSettle
    interval: 300
    repeat: false
    onTriggered: root.reflowingText = false
  }

  // Once Style's base-size catches up to the pending choice, drop the preview
  // so the slider tracks the live value again. The change itself reflows the
  // panel, so suppress hover for a beat while it lands.
  Connections {
    target: Style
    function onFontBaseSizeChanged() {
      root.markReflowing()
      if (root.textSizePreviewIndex >= 0
          && root.nearestTextStop(Style.font.baseSize) === root.textSizePreviewIndex)
        root.textSizePreviewIndex = -1
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: Quickshell.screens.length > 1 ? "󰍺" : "󰍹"
    onPressed: function(b) { root.toggle() }
    onWheelMoved: function(delta) {
      if (!root.brightnessAvailable) return
      var wheel = Util.wheelSteps(root.wheelAccumulator, delta)
      root.wheelAccumulator = wheel.remainder
      if (wheel.steps === 0) return
      root.manualBrightness(root.brightnessPercent + wheel.steps * 5)
      root.showBrightnessOsd(root.brightnessPercent)
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight, Style.space(860))

    // Leave the bar strip out of the overlay so clicking another bar icon
    // switches straight to its panel (a user plugin is only told about its
    // own icons, so the stock forwarding swallows those clicks).
    mask: Region {
      width: panel.screenW
      height: panel.screenH
      Region {
        intersection: Intersection.Subtract
        x: panel.barPos === "right" ? panel.screenW - panel.barThickness : 0
        y: panel.barPos === "bottom" ? panel.screenH - panel.barThickness : 0
        width: panel.barPos === "left" || panel.barPos === "right" ? panel.barThickness : panel.screenW
        height: panel.barPos === "left" || panel.barPos === "right" ? panel.screenH : panel.barThickness
      }
    }

    content: PanelKeyCatcher {
      id: keyCatcher
      property alias scrollArea: scrollArea
      implicitHeight: panelColumn.implicitHeight
      anchors.fill: parent
      // Let the schedule's text/number fields receive keys while editing
      blocked: {
        var f = keyCatcher.Window.activeFocusItem
        return !!f && f.cursorPosition !== undefined
      }
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dy !== 0) root.moveCursor(dy)
        else if (dx !== 0) {
          if (root.focusSection === "brightness") root.adjustBrightness(dx * 5)
          else if (root.focusSection === "textsize") root.adjustTextSize(dx)
          else if (root.focusSection === "scale") root.moveCursorH(dx)
        }
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: panelColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
        Binding {
          target: scrollArea.contentItem
          property: "interactive"
          value: panelColumn.implicitHeight > scrollArea.height
        }

        Column {
          id: panelColumn
          width: scrollArea.availableWidth
          spacing: Style.space(14)

          // ---------- Hero: display icon · title/status ----------
          Item {
            width: parent.width
            implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, scheduleSwitch.implicitHeight)

            Text {
              id: heroIcon
              textFormat: Text.PlainText
              text: root.displays.length > 1 ? "󰍺" : "󰍹"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.display
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Column {
              id: heroLabels
              anchors.left: heroIcon.right
              anchors.leftMargin: Style.space(14)
              anchors.right: scheduleSwitch.visible ? scheduleSwitch.left : parent.right
              anchors.rightMargin: scheduleSwitch.visible ? Style.space(10) : 0
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                text: Commons.I18n.t("monitor.display")
                textFormat: Text.PlainText
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
                width: parent.width
              }

              Text {
                id: heroLabel
                textFormat: Text.PlainText
                text: {
                  if (root.brightnessAvailable) {
                    return root.brightnessName(brightnessSlider.dragging ? brightnessSlider.liveValue : root.brightnessPercent).toUpperCase()
                  }
                  return Commons.I18n.t("monitor.fixedBrightness")
                }
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
                elide: Text.ElideRight
                width: parent.width
              }
            }

            ToggleSwitch {
              id: scheduleSwitch
              visible: root.brightnessAvailable && root.scheduleReady
              checked: root.scheduleOn
              foreground: root.foreground
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              onToggled: {
                if (!root.schedule) return
                if (root.scheduleOn) root.brightnessPercent = 100   // switching off resets to full
                root.schedule.toggle()
              }

              PanelToolTip {
                visible: scheduleSwitch.containsMouse
                text: root.scheduleOn ? strings.t("switch.on") : strings.t("switch.off")
              }
            }
          }

          // ---------- Brightness ----------
          PanelSeparator {
            visible: root.brightnessAvailable
            foreground: root.bar.foreground
          }

          Column {
            visible: root.brightnessAvailable
            width: parent.width
            spacing: Style.space(6)

            Item {
              width: parent.width
              implicitHeight: Math.max(brightnessHeader.implicitHeight, brightnessPercent.implicitHeight)

              PanelSectionHeader {
                id: brightnessHeader
                text: Commons.I18n.t("monitor.brightness")
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: brightnessPercent
                textFormat: Text.PlainText
                text: Commons.I18n.formatNumber(Math.round(brightnessSlider.dragging ? brightnessSlider.liveValue : root.brightnessPercent)) + "%"
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            CursorSurface {
              id: brightnessRow
              width: parent.width
              height: brightnessSlider.implicitHeight + Style.spacing.controlGap
              hasCursor: root.cursorActive && root.focusSection === "brightness" && root.selectedIndex === -1
              onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(brightnessRow)
              foreground: root.bar.foreground
              outline: true

              PanelSlider {
                id: brightnessSlider
                bar: root.bar
                anchors.fill: parent
                anchors.leftMargin: Style.space(6)
                anchors.rightMargin: Style.space(6)
                minimum: 1
                maximum: 100
                step: 1
                value: root.brightnessPercent
                integer: true
                onMoved: function(v) {
                  if (root.scheduleOn) root.manualBrightness(v)
                  else root.previewBrightness(v)
                }
                onReleased: function(v) {
                  brightnessDebounce.stop()
                  root.manualBrightness(v)
                }
              }

              HoverHandler {
                onHoveredChanged: if (hovered && !root.reflowingText) {
                  root.cursorActive = true
                  root.focusSection = "brightness"
                  root.selectedIndex = -1
                }
              }
            }
          }

          // ---------- Brightness schedule (only while its switch is on) ----------
          Column {
            width: parent.width
            spacing: Style.space(14)
            visible: root.brightnessAvailable && root.scheduleOn

            Item {
              width: parent.width
              implicitHeight: Math.max(scheduleInfo.implicitHeight, resumeButton.visible ? resumeButton.implicitHeight : 0)

              Text {
                id: scheduleInfo
                textFormat: Text.PlainText
                anchors.left: parent.left
                anchors.right: resumeButton.visible ? resumeButton.left : parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: root.scheduleManual
                  ? strings.t("now.manual").arg(root.clockLabel(root.schedule.override.until))
                  : strings.t("now.schedule")
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
              }

              Button {
                id: resumeButton
                visible: root.scheduleManual
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                height: root.rowHeight
                text: strings.t("now.resume")
                iconText: "󰑐"
                fontSize: Style.font.bodySmall
                foreground: root.foreground
                fontFamily: root.fontFamily
                bordered: true
                onClicked: root.schedule.clearOverride()
              }
            }

            PanelSeparator { foreground: root.foreground }

            Column {
              width: parent.width
              spacing: Style.space(6)

              PanelSectionHeader {
                text: strings.t("section.timeline")
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Timeline {
                width: parent.width
                height: Style.space(64)
              }

              Item {
                width: parent.width
                implicitHeight: hourMetrics.height
                Text { id: hourMetrics; visible: false; text: "00"; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
                Repeater {
                  model: [0, 6, 12, 18, 24]
                  Text {
                    required property var modelData
                    textFormat: Text.PlainText
                    text: (modelData < 10 ? "0" : "") + modelData
                    x: Math.max(0, Math.min(parent.width - width,
                         root.plotInset + (parent.width - 2 * root.plotInset) * modelData / 24 - width / 2))
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
              }
            }

            // ---------- EDIT (unfolds from the Edit button) ----------
            PanelSeparator { foreground: root.foreground; visible: root.editing }

            Column {
              width: parent.width
              spacing: Style.space(8)
              visible: root.editing

              PanelSectionHeader {
                text: strings.t("section.edit")
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Row {
                visible: root.draft.length > 0
                width: parent.width
                spacing: root.colGap
                Heading { width: root.timeWidth; text: strings.t("schedule.time") }
                Heading { width: root.valueWidth; text: strings.t("schedule.value") }
                Heading { width: root.modeWidth; text: strings.t("schedule.arrive") }
                Heading { width: root.stepWidth; text: strings.t("schedule.every") }
              }

              Text {
                visible: root.draft.length === 0
                textFormat: Text.PlainText
                text: strings.t("schedule.empty")
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                width: parent.width
                wrapMode: Text.WordWrap
              }

              Column {
                width: parent.width
                spacing: Style.space(6)
                Repeater {
                  model: root.draft
                  delegate: PointRow {}
                }
              }

              Button {
                height: root.rowHeight
                text: strings.t("schedule.add")
                iconText: "󰐕"
                fontSize: Style.font.bodySmall
                foreground: root.foreground
                fontFamily: root.fontFamily
                bordered: true
                onClicked: root.addDraftPoint()
              }
            }

            // ---------- Edit / Save (same spot) ----------
            PanelSeparator { foreground: root.foreground }

            Item {
              width: parent.width
              implicitHeight: saveButton.implicitHeight

              Text {
                textFormat: Text.PlainText
                anchors.left: parent.left
                anchors.right: saveButton.left
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                text: root.editing && root.dirty ? strings.t("schedule.unsaved") : ""
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
              }

              Button {
                id: saveButton
                anchors.right: parent.right
                height: root.rowHeight
                text: root.editing ? strings.t("schedule.save") : strings.t("schedule.edit")
                iconText: root.editing ? "󰆓" : "󰏫"
                fontSize: Style.font.bodySmall
                foreground: root.foreground
                fontFamily: root.fontFamily
                bordered: true
                active: root.editing && root.dirty
                onClicked: {
                  if (root.editing) root.saveSchedule()
                  else { root.syncDraft(); root.editing = true }
                }
              }
            }
          }

          // ---------- Text size ----------
          PanelSeparator {
            foreground: root.bar.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(6)

            Item {
              width: parent.width
              implicitHeight: Math.max(textSizeHeader.implicitHeight, textSizePx.implicitHeight)

              PanelSectionHeader {
                id: textSizeHeader
                text: Commons.I18n.t("monitor.textSize")
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: textSizePx
                textFormat: Text.PlainText
                text: Commons.I18n.formatNumber(textSizeSlider.dragging
                       ? root.textSizeStops[Math.round(textSizeSlider.liveValue)]
                       : root.displayedTextPx()) + "px"
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            CursorSurface {
              id: textSizeRow
              width: parent.width
              height: textSizeSlider.implicitHeight + Style.spacing.controlGap
              hasCursor: root.cursorActive && root.focusSection === "textsize" && root.selectedIndex === -1
              onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(textSizeRow)
              foreground: root.bar.foreground
              outline: true

              PanelSlider {
                id: textSizeSlider
                bar: root.bar
                anchors.fill: parent
                anchors.leftMargin: Style.space(6)
                anchors.rightMargin: Style.space(6)
                minimum: 0
                maximum: root.textSizeStops.length - 1
                step: 1
                integer: true
                tickCount: root.textSizeStops.length
                value: root.currentTextIndex()
                onReleased: function(v) { root.setTextSize(root.textSizeStops[Math.round(v)]) }
              }

              HoverHandler {
                onHoveredChanged: if (hovered && !root.reflowingText) {
                  root.cursorActive = true
                  root.focusSection = "textsize"
                  root.selectedIndex = -1
                }
              }
            }
          }

          // ---------- Scale ----------
          PanelSeparator {
            foreground: root.bar.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(10)

            Item {
              width: parent.width
              implicitHeight: Math.max(scaleHeader.implicitHeight, scaleMonitor.implicitHeight)

              PanelSectionHeader {
                id: scaleHeader
                text: Commons.I18n.t("monitor.scale")
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              // Name the monitor SCALE targets, since it only applies to the
              // focused one.
              Text {
                id: scaleMonitor
                textFormat: Text.PlainText
                text: root.focusedMonitor
                // Only worth naming when more than one display is in play.
                visible: root.focusedMonitor !== "" && root.enabledDisplayCount > 1
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            Grid {
              id: scaleRow
              width: parent.width
              columns: root.scaleValues.length
              spacing: Style.spacing.xs

              readonly property real cellWidth: root.scaleValues.length > 0
                ? (width - spacing * (columns - 1)) / columns
                : 0

              Repeater {
                model: root.scaleValues

                ScalePill {
                  required property string modelData
                  required property int index

                  scaleValue: modelData
                  scaleIndex: index
                  width: scaleRow.cellWidth
                }
              }
            }
          }

          // ---------- Monitors ----------
          PanelSeparator {
            visible: root.displays.length > 1
            foreground: root.bar.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(10)
            visible: root.displays.length > 1

            PanelSectionHeader {
              text: Commons.I18n.t("monitor.displays")
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
            }

            Repeater {
              model: root.displays

              MonitorRow {
                required property var modelData
                required property int index

                width: panelColumn.width
                display: modelData
                rowIndex: index
              }
            }
          }

          Item {
            width: parent.width
            height: Style.space(4)
          }
        }
      }
    }
  }

  component ScalePill: Button {
    id: pill
    required property string scaleValue
    required property int scaleIndex

    text: Commons.I18n.formatNumber(root.effectiveScale(scaleValue)) + "x"
    fontSize: Style.font.caption
    foreground: root.bar.foreground
    fontFamily: root.bar.fontFamily
    horizontalPadding: Style.spacing.sm
    verticalPadding: Style.spacing.controlPaddingY
    bordered: true

    active: root.activeScaleIndex() === scaleIndex
    hasCursor: root.cursorActive && root.focusSection === "scale" && root.selectedIndex === scaleIndex

    onClicked: root.setScale(scaleValue)
    onHovered: function(isHovered) {
      if (!isHovered || root.reflowingText) return
      root.cursorActive = true
      root.focusSection = "scale"
      root.selectedIndex = pill.scaleIndex
    }
  }

  component MonitorRow: CursorSurface {
    id: monitorRow
    required property var display
    required property int rowIndex

    readonly property bool isFocused: display && display.focused
    readonly property bool canToggle: display && (!display.enabled || root.enabledDisplayCount > 1)

    hasCursor: root.cursorActive && root.focusSection === "monitors" && root.selectedIndex === rowIndex
    onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(monitorRow)
    current: isFocused
    foreground: root.bar.foreground
    fill: Style.hoverFillFor(root.bar.foreground, Commons.Color.accent)
    currentFill: Style.selectedFillFor(root.bar.foreground, Commons.Color.accent)
    implicitHeight: monitorInner.implicitHeight + Style.spacing.xl
    opacity: canToggle ? 1.0 : 0.45

    Row {
      id: monitorInner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(8)

      Text {
        text: "󰍹"
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.title
        width: Style.space(22)
        horizontalAlignment: Text.AlignHCenter
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        textFormat: Text.PlainText
        text: monitorRow.display.focused
          ? Commons.I18n.t("monitor.displayFocused").arg(monitorRow.display.name)
          : monitorRow.display.name
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
        width: parent.width - Style.space(22) - Style.space(14) - Style.space(16)
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        textFormat: Text.PlainText
        text: monitorRow.display.enabled ? "󰄬" : ""
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.subtitle
        width: Style.space(14)
        horizontalAlignment: Text.AlignRight
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: monitorRow.canToggle ? Qt.PointingHandCursor : Qt.ArrowCursor
      onContainsMouseChanged: if (containsMouse && !root.reflowingText) {
        root.cursorActive = true
        root.focusSection = "monitors"
        root.selectedIndex = monitorRow.rowIndex
      }
      onClicked: if (monitorRow.canToggle) root.toggleDisplay(monitorRow.display.name, monitorRow.display.enabled)
    }
  }

  // ---------------- components ----------------

  component Heading: Text {
    textFormat: Text.PlainText
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    elide: Text.ElideRight
  }

  // One schedule point: time · brightness % · how to arrive · step size · remove
  component PointRow: Row {
    id: row
    required property var modelData
    required property int index
    spacing: root.colGap
    height: root.rowHeight

    TextField {
      id: timeField
      width: root.timeWidth
      height: root.rowHeight
      anchors.verticalCenter: parent.verticalCenter
      verticalPadding: 0
      text: row.modelData.time
      foreground: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      horizontalAlignment: TextInput.AlignHCenter
      verticalAlignment: TextInput.AlignVCenter
      inputMethodHints: Qt.ImhTime
      maximumLength: 5
      placeholderText: "HH:MM"
      property bool invalid: false
      color: invalid ? Commons.Color.urgent : root.foreground
      onTextEdited: invalid = Schedule.parseTime(text) < 0
      onEditingFinished: {
        var m = Schedule.parseTime(text)
        if (m < 0) { text = row.modelData.time; invalid = false; return }
        var t = Schedule.formatTime(m)
        if (t !== row.modelData.time) root.editDraft(row.index, { time: t })
        else text = t
      }
      PanelToolTip { visible: timeField.invalid; text: strings.t("schedule.invalidTime") }
    }

    NumberField {
      anchors.verticalCenter: parent.verticalCenter
      fieldWidth: root.valueWidth
      field.height: root.rowHeight
      from: Schedule.MIN_VALUE
      to: Schedule.MAX_VALUE
      stepSize: 5
      value: row.modelData.value
      foreground: root.foreground
      fontFamily: root.fontFamily
      fontSize: Style.font.bodySmall
      onModified: function(v) { root.editDraft(row.index, { value: v }) }
    }

    Button {
      width: root.modeWidth
      height: root.rowHeight
      anchors.verticalCenter: parent.verticalCenter
      text: strings.t("transition." + row.modelData.transition)
      iconText: root.transitionIcon(row.modelData.transition)
      fontSize: Style.font.bodySmall
      foreground: root.foreground
      fontFamily: root.fontFamily
      bordered: true
      tooltipText: strings.t("transition." + row.modelData.transition + ".tip")
      onClicked: root.editDraft(row.index, { transition: root.transitionNext(row.modelData.transition) })
    }

    Item {
      width: root.stepWidth
      height: root.rowHeight

      NumberField {
        visible: row.modelData.transition === "steps"
        anchors.verticalCenter: parent.verticalCenter
        fieldWidth: root.stepWidth
        field.height: root.rowHeight
        from: 1
        to: 240
        stepSize: 5
        value: row.modelData.stepMinutes
        foreground: root.foreground
        fontFamily: root.fontFamily
        fontSize: Style.font.bodySmall
        onModified: function(v) { root.editDraft(row.index, { stepMinutes: v }) }
      }
    }

    PanelActionButton {
      anchors.verticalCenter: parent.verticalCenter
      iconText: "󰆴"
      foreground: root.foreground
      fontFamily: root.fontFamily
      tooltipText: strings.t("schedule.remove")
      onClicked: root.removeDraftPoint(row.index)
    }
  }

  // 24h curve in theme colours. Layers, bottom to top: track, area fill
  // (fades from strong at the bright top to faint at the bottom), curve,
  // "now" marker, schedule dots. The plot is inset by the dot radius on every
  // side so dots on the edges are never clipped. Shows the draft, so edits
  // preview before they are saved.
  component Timeline: Canvas {
    id: canvas
    renderStrategy: Canvas.Cooperative
    readonly property var pts: root.draft
    readonly property double nowMs: root.scheduleReady ? root.schedule.now : 0
    readonly property color fg: root.foreground
    readonly property real dotRadius: Style.space(3.5)
    onPtsChanged: requestPaint()
    onFgChanged: requestPaint()
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()
    property int minuteKey: Math.floor(nowMs / 60000)
    onMinuteKeyChanged: requestPaint()

    onPaint: {
      var ctx = getContext("2d")
      var w = width, h = height
      ctx.reset()

      var padX = root.plotInset
      var padY = dotRadius + 2
      var left = padX, right = w - padX
      var top = padY, bottom = h - padY
      var span = Schedule.MAX_VALUE - Schedule.MIN_VALUE
      function xFor(minutes) { return left + minutes / 1440 * (right - left) }
      function yFor(v) { return bottom - (v - Schedule.MIN_VALUE) / span * (bottom - top) }
      function rgba(a) { return Qt.rgba(fg.r, fg.g, fg.b, a) }

      // 1. track
      ctx.fillStyle = rgba(0.06)
      ctx.fillRect(0, 0, w, h)

      var samples = Math.max(96, Math.round(right - left))
      var values = Schedule.curve(pts, samples)
      function px(i) { return left + i / samples * (right - left) }

      // 2. area under the curve, one path (no seams)
      ctx.beginPath()
      ctx.moveTo(px(0), bottom)
      for (var i = 0; i <= samples; i++) ctx.lineTo(px(i), yFor(values[i]))
      ctx.lineTo(px(samples), bottom)
      ctx.closePath()
      var grad = ctx.createLinearGradient(0, top, 0, bottom)
      grad.addColorStop(0, rgba(0.45))
      grad.addColorStop(1, rgba(0.08))
      ctx.fillStyle = grad
      ctx.fill()

      // 3. curve
      ctx.strokeStyle = rgba(0.9)
      ctx.lineWidth = 1.5
      ctx.lineJoin = "round"
      ctx.beginPath()
      for (var j = 0; j <= samples; j++) {
        if (j === 0) ctx.moveTo(px(j), yFor(values[j])); else ctx.lineTo(px(j), yFor(values[j]))
      }
      ctx.stroke()

      // 4. now marker
      if (nowMs > 0) {
        var nx = Math.round(xFor(Schedule.minutesOfDay(new Date(nowMs)))) + 0.5
        ctx.strokeStyle = rgba(0.7)
        ctx.lineWidth = 1
        ctx.setLineDash([3, 3])
        ctx.beginPath()
        ctx.moveTo(nx, 0)
        ctx.lineTo(nx, h)
        ctx.stroke()
        ctx.setLineDash([])
      }

      // 5. schedule dots, ringed in the panel background so they sit cleanly
      //    on top of the curve and the now marker
      var bg = Commons.Color.popups.background
      for (var p = 0; p < pts.length; p++) {
        var dx = xFor(Schedule.parseTime(pts[p].time)), dy = yFor(pts[p].value)
        ctx.beginPath()
        ctx.arc(dx, dy, dotRadius + 1.5, 0, Math.PI * 2)
        ctx.fillStyle = bg
        ctx.fill()
        ctx.beginPath()
        ctx.arc(dx, dy, dotRadius, 0, Math.PI * 2)
        ctx.fillStyle = rgba(1)
        ctx.fill()
      }
    }
  }
}

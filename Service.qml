import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Schedule.js" as Schedule

// Brightness schedule service for the Display panel. Same model as the
// Night Light plugin's service, in brightness percent instead of Kelvin.
//
// While the schedule is on, every couple of seconds it works out the
// scheduled brightness and applies it to the built-in display (eDP/LVDS/DSI;
// the focused monitor when there is none). Settings live in
// ~/.config/omarchy/brightness-schedule.json, which is watched, so hand
// edits apply live.
//
// Switching it off sets brightness to 100%; after that it's hands off.
// A manual change while it is on (panel slider or brightness keys) holds
// until the next schedule point, then the schedule takes over again.
Item {
  id: root

  // Injected by omarchy-shell (the service loader).
  property var shell: null

  readonly property string configPath: Quickshell.env("HOME") + "/.config/omarchy/brightness-schedule.json"

  // ---- persisted settings ----
  property bool configLoaded: false
  property bool scheduleEnabled: false
  property var points: []
  property var override: null          // { value, until: ms } or null

  // ---- live state ----
  property double now: Date.now()
  readonly property bool stateLoaded: configLoaded
  readonly property bool enabled: configLoaded && scheduleEnabled
  readonly property bool overrideActive: enabled && override !== null
    && override.until !== null && override.until > now
  readonly property int scheduledValue: Schedule.valueAt(points, Schedule.minutesOfDay(new Date(now)))
  readonly property int targetValue: overrideActive ? override.value : scheduledValue
  property int appliedValue: -1        // last value this service wrote (-1 = unknown)

  // ---------------- settings API (used by Panel.qml) ----------------

  function toggle() { setEnabled(!enabled) }

  // Turning the schedule off hands brightness back at full: 100%.
  function setEnabled(value) {
    scheduleEnabled = !!value
    override = null
    appliedValue = -1
    saveSoon()
    if (!scheduleEnabled) apply(Schedule.NEUTRAL_VALUE)
    tick()
  }

  // Manual brightness while the schedule is on: holds until the next point.
  function setOverride(value) {
    if (!enabled) return
    override = { value: Schedule.clampValue(value), until: Schedule.nextPointMs(points, Date.now()) }
    saveSoon()
    tick()
  }

  function clearOverride() {
    override = null
    saveSoon()
    tick()
  }

  function setPoints(list) {
    points = Schedule.normalizePoints(list)
    override = null     // a changed schedule supersedes a manual brightness
    saveSoon()
    tick()
  }

  // ---------------- persistence ----------------

  function applyConfig(raw) {
    var c = Schedule.normalizeConfig(raw)
    scheduleEnabled = c.enabled
    points = c.points
    override = c.override
    configLoaded = true
    tick()
  }

  function serialise() {
    return JSON.stringify({
      version: 1,
      enabled: scheduleEnabled,
      points: points,
      override: override
    }, null, 2) + "\n"
  }

  property string lastWritten: ""
  function saveSoon() { saveTimer.restart() }
  function saveNow() {
    var text = serialise()
    if (text === lastWritten) return
    lastWritten = text
    configFile.setText(text)
  }

  Timer { id: saveTimer; interval: 400; onTriggered: root.saveNow() }

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: {
      var t = text()
      if (t === root.lastWritten && root.configLoaded) return
      var parsed = null
      try { parsed = JSON.parse(t) } catch (e) { parsed = null }
      if (parsed === null) {
        if (!root.configLoaded) root.applyConfig(null)
        return
      }
      root.lastWritten = t
      root.applyConfig(parsed)
    }
    onLoadFailed: function(error) {
      if (!root.configLoaded) root.applyConfig(null)
      root.saveNow()
    }
    onFileChanged: reload()
  }

  // ---------------- engine ----------------

  // Built-in panel first; the focused monitor otherwise.
  readonly property string pickMonitor:
    "m=$(hyprctl monitors -j | jq -r '[.[] | select(.name | test(\"^(eDP|LVDS|DSI)-\"))][0].name // empty'); "
    + "[ -n \"$m\" ] || m=$(omarchy-hyprland-monitor-focused 2>/dev/null); "

  property int probeCounter: 0
  property int pendingValue: -1

  function tick() {
    now = Date.now()
    if (!enabled) return
    if (override !== null && (override.until === null || override.until <= now)) {
      override = null
      saveSoon()
    }
    var target = targetValue
    if (target !== appliedValue) {
      apply(target)
    } else if (++probeCounter >= 5) {
      // Every ~10 s: notice brightness keys (or anything else) changing it
      probeCounter = 0
      if (!probe.running && !applyProcess.running) probe.running = true
    }
  }

  function apply(value) {
    appliedValue = value
    if (applyProcess.running) { pendingValue = value; return }
    runApply(value)
  }

  function runApply(value) {
    applyProcess.command = ["bash", "-c", pickMonitor
      + "omarchy-brightness-display --no-osd --monitor \"$m\" " + Number(value) + "%"]
    applyProcess.running = true
  }

  Process {
    id: applyProcess
    onExited: function() {
      if (root.pendingValue >= 0) {
        var v = root.pendingValue
        root.pendingValue = -1
        root.runApply(v)
      }
    }
  }

  Process {
    id: probe
    command: ["bash", "-c", root.pickMonitor + "omarchy-brightness-display --monitor \"$m\""]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var m = String(text).match(/[0-9]+/)
        if (!m || !root.enabled || root.appliedValue < 0) return
        var reported = Number(m[0])
        // Changed outside the schedule (brightness keys): treat it like a
        // slider drag and hold it until the next point.
        if (Math.abs(reported - root.appliedValue) > 1) {
          root.appliedValue = Schedule.clampValue(reported)
          root.override = { value: root.appliedValue, until: Schedule.nextPointMs(root.points, Date.now()) }
          root.saveSoon()
        }
      }
    }
  }

  Timer {
    interval: 2000
    running: true
    repeat: true
    onTriggered: root.tick()
  }

  ShellIpc {
    target: "brightness-schedule"

    function status(): string {
      return JSON.stringify({
        enabled: root.enabled,
        brightness: root.targetValue,
        scheduled: root.scheduledValue,
        override: root.overrideActive ? root.override : null
      })
    }
    function enable(): string { root.setEnabled(true); return "enabled" }
    function disable(): string { root.setEnabled(false); return "disabled" }
    function toggle(): string { root.toggle(); return root.scheduleEnabled ? "enabled" : "disabled" }
    function set(percent: string): string { root.setOverride(Number(percent)); return root.override ? String(root.override.value) : "schedule off" }
    function resume(): string { root.clearOverride(); return "schedule" }
  }
}

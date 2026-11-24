// Pure schedule logic for the brightness schedule (Display panel). No QML or
// I/O here, so it can be unit-tested with node (see tests/schedule.test.js).
// Same model as the Night Light plugin's schedule, in brightness percent.
//
// A schedule is a list of points around a 24h clock:
//   { time: "HH:MM", value: 1..100, transition: "fixed"|"fade"|"steps", stepMinutes: N }
//
// `transition` says how brightness travels from the previous point TO this one:
//   fixed  hold the previous brightness, jump to this one at `time`
//   fade   smooth line from the previous point's time/value to this one (1% resolution)
//   steps  same line, but moving in `stepMinutes` increments
// The list wraps around midnight.

var MIN_VALUE = 1
var MAX_VALUE = 100
var NEUTRAL_VALUE = 100
var MIN_STEP = 1
var MAX_STEP = 240
var TRANSITIONS = ["fixed", "fade", "steps"]

function defaultConfig() {
  return {
    version: 1,
    enabled: false,
    points: [
      { time: "06:00", value: 100, transition: "fixed", stepMinutes: 15 },
      { time: "19:00", value: 100, transition: "fixed", stepMinutes: 15 },
      { time: "23:00", value: 40, transition: "fade", stepMinutes: 15 }
    ],
    override: null
  }
}

function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }

function clampValue(t) {
  var n = Math.round(Number(t))
  if (!isFinite(n)) n = NEUTRAL_VALUE
  return clamp(n, MIN_VALUE, MAX_VALUE)
}

function pad2(n) { return (n < 10 ? "0" : "") + n }

// "7:5", "07:05", "0705", "7" -> minutes of day, or -1 when invalid
function parseTime(text) {
  var s = String(text === undefined || text === null ? "" : text).trim()
  var m = s.match(/^(\d{1,2})(?::?(\d{2}))?$/)
  if (!m) return -1
  var h = Number(m[1]), mi = m[2] === undefined ? 0 : Number(m[2])
  if (h > 23 || mi > 59) return -1
  return h * 60 + mi
}

function formatTime(minutes) {
  var m = ((Math.round(minutes) % 1440) + 1440) % 1440
  return pad2(Math.floor(m / 60)) + ":" + pad2(m % 60)
}

function normalizePoint(p) {
  p = p || {}
  var minutes = parseTime(p.time)
  if (minutes < 0) return null
  var transition = TRANSITIONS.indexOf(p.transition) >= 0 ? p.transition : "fixed"
  var step = Math.round(Number(p.stepMinutes))
  if (!isFinite(step)) step = 15
  return {
    time: formatTime(minutes),
    value: clampValue(p.value),
    transition: transition,
    stepMinutes: clamp(step, MIN_STEP, MAX_STEP)
  }
}

// Validated, de-duplicated (one point per minute, last wins) and time-sorted.
function normalizePoints(points) {
  var byTime = {}
  var list = Array.isArray(points) ? points : []
  for (var i = 0; i < list.length; i++) {
    var p = normalizePoint(list[i])
    if (p) byTime[p.time] = p
  }
  var out = Object.keys(byTime).map(function(k) { return byTime[k] })
  out.sort(function(a, b) { return parseTime(a.time) - parseTime(b.time) })
  return out
}

function normalizeConfig(raw) {
  var d = defaultConfig()
  if (!raw || typeof raw !== "object") return d
  var ov = raw.override
  var override = null
  // until: ms timestamp, or null = until changed (manual brightness while the schedule is off)
  if (ov && typeof ov === "object" && isFinite(Number(ov.value)) && (ov.until === null || isFinite(Number(ov.until))))
    override = { value: clampValue(ov.value), until: ov.until === null ? null : Number(ov.until) }
  return {
    version: 1,
    enabled: raw.enabled === true,
    points: Array.isArray(raw.points) ? normalizePoints(raw.points) : d.points,
    override: override
  }
}

function minutesOfDay(date) {
  return date.getHours() * 60 + date.getMinutes() + date.getSeconds() / 60 + date.getMilliseconds() / 60000
}

// Index of the segment that contains `t`: the point that is next to arrive.
// Returns { prev, next, elapsed, duration } in minutes.
function segmentAt(points, t) {
  var n = points.length
  var next = 0
  while (next < n && parseTime(points[next].time) <= t) next++
  if (next === n) next = 0
  var prev = (next - 1 + n) % n
  var pt = parseTime(points[prev].time)
  var nt = parseTime(points[next].time)
  var duration = ((nt - pt) + 1440) % 1440
  if (duration === 0) duration = 1440
  var elapsed = ((t - pt) + 1440) % 1440
  return { prev: prev, next: next, elapsed: elapsed, duration: duration }
}

// Scheduled brightness (integer percent) at minute-of-day `t`.
function valueAt(points, t) {
  if (!points || points.length === 0) return NEUTRAL_VALUE
  if (points.length === 1) return points[0].value
  var s = segmentAt(points, t)
  var from = points[s.prev].value
  var target = points[s.next]
  var to = target.value
  if (target.transition === "fade") {
    return Math.round(from + (to - from) * (s.elapsed / s.duration))
  }
  if (target.transition === "steps") {
    var step = target.stepMinutes
    var k = Math.floor(s.elapsed / step)
    return Math.round(from + (to - from) * Math.min(1, (k * step) / s.duration))
  }
  return from
}

// What the schedule does next, for status text:
// { time: "HH:MM", value, transition, changing } where `changing` is true
// while a fade/steps segment is in progress.
function upcoming(points, t) {
  if (!points || points.length < 2) return null
  var s = segmentAt(points, t)
  var target = points[s.next]
  var from = points[s.prev].value
  return {
    time: target.time,
    value: target.value,
    transition: target.transition,
    changing: target.transition !== "fixed" && from !== target.value
  }
}

// When brightness will next change while it is holding steady:
// { time: "HH:MM", value } of the first minute (looking ahead up to 24h) whose
// brightness differs from now, or null if it never changes.
function nextChange(points, t) {
  if (!points || points.length < 2) return null
  var current = valueAt(points, t)
  var start = Math.floor(t) + 1
  for (var i = 0; i < 1440; i++) {
    var m = (start + i) % 1440
    var k = valueAt(points, m)
    if (k !== current) {
      // A fade/steps segment starts at its point even though the first
      // visible degree arrives a moment later: report the point's time.
      var before = (m + 1439) % 1440
      for (var j = 0; j < points.length; j++)
        if (parseTime(points[j].time) === before) return { time: points[j].time, value: k }
      return { time: formatTime(m), value: k }
    }
  }
  return null
}

// Absolute ms timestamp of the next point after `nowMs` — when a manual
// override ends.
function nextPointMs(points, nowMs) {
  var now = new Date(nowMs)
  if (!points || points.length === 0) {
    var tomorrow = new Date(now.getFullYear(), now.getMonth(), now.getDate() + 1)
    return tomorrow.getTime()
  }
  var t = minutesOfDay(now)
  var s = segmentAt(points, t)
  var nt = parseTime(points[s.next].time)
  var target = new Date(now.getFullYear(), now.getMonth(), now.getDate(), Math.floor(nt / 60), nt % 60, 0, 0)
  if (target.getTime() <= nowMs) target = new Date(target.getFullYear(), target.getMonth(), target.getDate() + 1, Math.floor(nt / 60), nt % 60, 0, 0)
  return target.getTime()
}

// Sampled curve for drawing: `count` + 1 brightness values from 00:00 to 24:00.
function curve(points, count) {
  var out = []
  for (var i = 0; i <= count; i++) out.push(valueAt(points, (i * 1440) / count))
  return out
}

// A sensible new point: halfway (in time) into the longest gap, using the
// brightness the schedule currently has there.
function suggestPoint(points) {
  if (!points || points.length === 0) return { time: "21:00", value: 70, transition: "fade", stepMinutes: 15 }
  var bestStart = 0, bestLen = -1
  for (var i = 0; i < points.length; i++) {
    var a = parseTime(points[i].time)
    var b = parseTime(points[(i + 1) % points.length].time)
    var len = ((b - a) + 1440) % 1440 || 1440
    if (len > bestLen) { bestLen = len; bestStart = a }
  }
  var mid = Math.round((bestStart + bestLen / 2) / 15) * 15
  return { time: formatTime(mid), value: valueAt(points, mid % 1440), transition: "fade", stepMinutes: 15 }
}

if (typeof module !== "undefined") {
  module.exports = {
    MIN_VALUE: MIN_VALUE, MAX_VALUE: MAX_VALUE, NEUTRAL_VALUE: NEUTRAL_VALUE, TRANSITIONS: TRANSITIONS,
    defaultConfig: defaultConfig, clampValue: clampValue, parseTime: parseTime, formatTime: formatTime,
    normalizePoint: normalizePoint, normalizePoints: normalizePoints, normalizeConfig: normalizeConfig,
    minutesOfDay: minutesOfDay, valueAt: valueAt, upcoming: upcoming, nextChange: nextChange,
    nextPointMs: nextPointMs, curve: curve, suggestPoint: suggestPoint
  }
}

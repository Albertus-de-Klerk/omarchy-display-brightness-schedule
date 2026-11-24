// Run: node tests/schedule.test.js
const assert = require("assert")
const S = require("../Schedule.js")

const def = S.defaultConfig().points
const at = (pts, hhmm) => S.valueAt(pts, S.parseTime(hhmm))
let n = 0
const eq = (a, b, msg) => { assert.strictEqual(a, b, msg || `expected ${b}, got ${a}`); n++ }

// Default: full brightness 06-19, fade to 40% by 23:00, 40% overnight
eq(at(def, "05:59"), 40, "night before 06:00")
eq(at(def, "06:00"), 100, "06:00 jump to full")
eq(at(def, "19:00"), 100)
eq(at(def, "21:00"), 70, "halfway through the fade")
eq(at(def, "23:00"), 40)
eq(at(def, "02:00"), 40)
eq(S.valueAt(def, 19 * 60 + 4), 99, "1% resolution (~4 min per % on the default fade)")
eq(S.normalizeConfig(null).enabled, false, "off until switched on")
eq(S.normalizeConfig({ enabled: true }).enabled, true)

// Steps
const steps = S.normalizePoints([
  { time: "20:00", value: 100 },
  { time: "21:00", value: 60, transition: "steps", stepMinutes: 15 },
])
eq(at(steps, "20:14"), 100)
eq(at(steps, "20:15"), 90)
eq(at(steps, "20:59"), 70)
eq(at(steps, "21:00"), 60)

// Wrap-around fade across midnight
const wrap = S.normalizePoints([
  { time: "23:00", value: 50, transition: "fixed" },
  { time: "01:00", value: 10, transition: "fade" },
  { time: "08:00", value: 100, transition: "fixed" },
])
eq(at(wrap, "00:00"), 30, "midpoint of fade across midnight")
eq(at(wrap, "08:00"), 100)

// Clamping / normalising
eq(S.clampValue(0), 1, "never fully black")
eq(S.clampValue(150), 100)
eq(S.normalizePoint({ time: "9:00", value: 55 }).value, 55)
eq(S.valueAt([], 600), 100, "empty schedule = full brightness")
eq(S.normalizeConfig({ override: { value: 30, until: null } }).override.value, 30)
eq(S.normalizeConfig({ override: { value: 30, until: "x" } }).override, null)

// Override ends at the next point
const now = new Date(2026, 10, 24, 23, 30).getTime()
eq(new Date(S.nextPointMs(def, now)).getHours(), 6)
eq(new Date(S.nextPointMs(def, now)).getDate(), 25)

// Suggest: middle of the longest gap (06:00-19:00)
eq(S.suggestPoint(def).time, "12:30")

console.log(`ok - ${n} assertions passed`)

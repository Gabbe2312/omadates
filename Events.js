// Event math for the calendar popup: reading the sync cache, working out
// which days carry something, and turning a stored event into the one line
// the panel prints for it.
//
// Kept locale- and Qt-free for the same reason Model.js is. This is plain
// date arithmetic, and it should stay testable without a shell around it.

var MS_PER_DAY = 86400000

function pad2(value) {
  var n = Number(value)
  return (n < 10 ? "0" : "") + n
}

function dateKey(year, month, day) {
  return year + "-" + pad2(Number(month) + 1) + "-" + pad2(day)
}

function keyForDate(date) {
  return dateKey(date.getFullYear(), date.getMonth(), date.getDate())
}

// A stored ISO string carries its own offset, so this lands on the wall-clock
// time the event actually happens at here. An unparseable one drops the event
// rather than poisoning the sort with NaN.
function parseTime(value) {
  var ms = Date.parse(String(value || ""))
  return isFinite(ms) ? ms : NaN
}

// ---- Cache shape. Anything malformed reads as "no events, with a reason",
//      which is what the panel wants to print anyway.
function parseCache(text) {
  var empty = {
    status: "empty", error: "", syncedAt: "", events: [],
    // The helper states these on every write so the panel can tell "never
    // signed in" from "packages missing" from "the network is down", and each
    // has a different next step for whoever is looking at it.
    configured: false, signedIn: false, missing: [], writable: []
  }
  var raw = String(text || "").replace(/^\s+|\s+$/g, "")
  if (raw === "") return empty

  var parsed
  try {
    parsed = JSON.parse(raw)
  } catch (e) {
    return { status: "error", error: "calendar cache is unreadable", syncedAt: "", events: [] }
  }
  if (!parsed || typeof parsed !== "object") return empty

  var list = parsed.events instanceof Array ? parsed.events : []
  var events = []
  for (var i = 0; i < list.length; i++) {
    var normalized = normalize(list[i])
    if (normalized) events.push(normalized)
  }
  events.sort(compare)

  return {
    status: String(parsed.status || "ok"),
    error: String(parsed.error || ""),
    syncedAt: String(parsed.syncedAt || ""),
    configured: parsed.configured === true,
    writable: parsed.writableCalendars instanceof Array ? parsed.writableCalendars : [],
    signedIn: parsed.signedIn === true,
    missing: parsed.missing instanceof Array ? parsed.missing : [],
    events: events
  }
}

function normalize(entry) {
  if (!entry || typeof entry !== "object") return null

  var startMs = parseTime(entry.start)
  if (!isFinite(startMs)) return null

  var endMs = parseTime(entry.end)
  if (!isFinite(endMs) || endMs < startMs) endMs = startMs

  var start = new Date(startMs)
  return {
    uid: String(entry.uid || ""),
    summary: String(entry.summary || "").replace(/^\s+|\s+$/g, "") || "(no title)",
    description: String(entry.description || "").replace(/^\s+|\s+$/g, ""),
    recurring: entry.recurring === true,
    subscribed: entry.subscribed === true,
    location: String(entry.location || "").replace(/^\s+|\s+$/g, ""),
    calendar: String(entry.calendar || ""),
    color: String(entry.color || ""),
    allDay: entry.allDay === true,
    startMs: startMs,
    endMs: endMs,
    dayKey: keyForDate(start),
    startHour: start.getHours(),
    startMinute: start.getMinutes()
  }
}

// All-day events sort above timed ones, then by start, then alphabetically so
// two events at the same minute keep a stable order between redraws.
function compare(a, b) {
  if (a.allDay !== b.allDay) return a.allDay ? -1 : 1
  if (a.startMs !== b.startMs) return a.startMs - b.startMs
  return a.summary < b.summary ? -1 : (a.summary > b.summary ? 1 : 0)
}

// Every day an event touches. A multi-day event should mark all of them, but
// iCalendar writes all-day DTEND as the morning after the last day, so that
// one is trimmed back or a one-day event would light up two cells.
function dayKeys(event) {
  var start = new Date(event.startMs)
  var last = new Date(event.endMs)

  if (event.allDay) last = new Date(event.endMs - 1)
  else if (last.getHours() === 0 && last.getMinutes() === 0 && event.endMs > event.startMs)
    last = new Date(event.endMs - 1)

  var cursor = new Date(start.getFullYear(), start.getMonth(), start.getDate())
  var stop = new Date(last.getFullYear(), last.getMonth(), last.getDate())
  if (stop < cursor) stop = cursor

  var keys = []
  // Bounded so a bad end date can never spin the grid into a long loop.
  for (var guard = 0; cursor <= stop && guard < 400; guard++) {
    keys.push(keyForDate(cursor))
    cursor = new Date(cursor.getTime() + MS_PER_DAY)
  }
  return keys
}

// dateKey -> the calendar name behind every event on that day, in the order
// the list below the grid prints them. The array's length is the day's event
// count, so the grid counts and colours from the same thing.
//
// Names rather than colours: the colour is a lookup that the user can
// override, and two calendars sharing one must still read as two.
function marksByDay(events) {
  var marks = {}
  for (var i = 0; i < (events || []).length; i++) {
    var keys = dayKeys(events[i])
    for (var k = 0; k < keys.length; k++) {
      if (!marks[keys[k]]) marks[keys[k]] = []
      marks[keys[k]].push(String(events[i].calendar || ""))
    }
  }
  return marks
}

// calendar name -> the colour its source gave it, before any override.
function colorMap(events) {
  var colors = {}
  for (var i = 0; i < (events || []).length; i++) {
    var name = String(events[i].calendar || "")
    if (name !== "" && colors[name] === undefined) colors[name] = events[i].color || ""
  }
  return colors
}

// The dots to draw for one day: one per event, capped, because past three a
// row of dots stops being countable and turns into texture.
//
// The cap is not allowed to hide a calendar, though. A day with four work
// meetings and one dinner would otherwise read as purely work, so when the
// cap would repeat a calendar over a day that has something else on it, the
// trailing dots give way to the ones that would go unmentioned. The number of
// dots never changes, only which calendars fill them.
function dotColors(colors, limit) {
  var all = colors || []
  var cap = Math.max(0, Number(limit) || 0)
  var shown = all.slice(0, cap)
  if (all.length <= cap) return shown

  var distinct = []
  for (var i = 0; i < all.length; i++)
    if (distinct.indexOf(all[i]) === -1) distinct.push(all[i])

  var missing = []
  for (var d = 0; d < distinct.length; d++)
    if (shown.indexOf(distinct[d]) === -1) missing.push(distinct[d])

  for (var m = 0; m < missing.length && m < cap; m++)
    shown[cap - 1 - m] = missing[m]
  return shown
}

// A small fixed palette for recolouring a calendar by hand, mostly for
// subscribed feeds, which often ship no colour at all or one that clashes
// with everything else on the day. Mid-toned on purpose: each of these reads
// against a dark panel and a light one without the legibility guard below
// having to step in.
var PALETTE = [
  "#E05252", "#E0873C", "#D9B23C", "#5BAE5B",
  "#3CA8A8", "#4A90D9", "#8A6FD1", "#D96BA8"
]

function palette() {
  return PALETTE.slice()
}

// A URL worth handing to the subscribe helper. Deliberately loose: the
// helper and the server do the real validation, and this only exists to stop
// an empty field or an obvious paste accident from spawning a process.
function looksLikeCalendarUrl(value) {
  return /^(webcal|https?):\/\/\S+$/i.test(String(value || "").replace(/^\s+|\s+$/g, ""))
}

// ---- Keeping a calendar's own colour legible against the panel.
//
// The colours come from Apple, so they know nothing about the Omarchy theme
// they are being painted onto. Only the extremes actually break: a near-black
// calendar on a dark panel, a near-white one on a light panel. Everything in
// between is left exactly as the user set it.

function parseHex(hex) {
  var match = /^#([0-9a-f]{6})$/i.exec(String(hex || "").replace(/^\s+|\s+$/g, ""))
  if (!match) return null
  var value = parseInt(match[1], 16)
  return { r: (value >> 16) & 255, g: (value >> 8) & 255, b: value & 255 }
}

function toHex(rgb) {
  function part(n) {
    var clamped = Math.max(0, Math.min(255, Math.round(n)))
    return (clamped < 16 ? "0" : "") + clamped.toString(16)
  }
  return "#" + part(rgb.r) + part(rgb.g) + part(rgb.b)
}

// Perceptual weights rather than a flat average: green carries most of the
// apparent brightness, blue almost none.
function luminance(rgb) {
  return (0.2126 * rgb.r + 0.7152 * rgb.g + 0.0722 * rgb.b) / 255
}

function mixToward(rgb, target, amount) {
  return {
    r: rgb.r + (target - rgb.r) * amount,
    g: rgb.g + (target - rgb.g) * amount,
    b: rgb.b + (target - rgb.b) * amount
  }
}

// An empty colour means iCloud gave none, and the caller should fall back to
// the theme accent, signalled by returning "" rather than inventing one.
function legibleColor(hex, foregroundIsLight) {
  var rgb = parseHex(hex)
  if (!rgb) return ""
  var lum = luminance(rgb)
  // A light foreground means a dark panel behind it, and vice versa.
  if (foregroundIsLight && lum < 0.12) return toHex(mixToward(rgb, 255, 0.5))
  if (!foregroundIsLight && lum > 0.75) return toHex(mixToward(rgb, 0, 0.45))
  return String(hex)
}

// The calendars present in the cache, for the toggle row under the list.
// Built from every cached event rather than the visible ones, or switching a
// calendar off would take its own switch away with it.
function calendarsIn(events) {
  var seen = {}
  var out = []
  for (var i = 0; i < (events || []).length; i++) {
    var name = String(events[i].calendar || "")
    if (name === "" || seen[name]) continue
    seen[name] = true
    out.push({ name: name, color: events[i].color || "" })
  }
  out.sort(function(a, b) { return a.name < b.name ? -1 : (a.name > b.name ? 1 : 0) })
  return out
}

// Hiding a calendar is a display choice, not a sync one: everything stays in
// the cache, so switching it back on is instant and costs no round trip.
function visibleEvents(events, hidden) {
  var excluded = hidden || []
  if (excluded.length === 0) return events || []
  var out = []
  for (var i = 0; i < (events || []).length; i++)
    if (excluded.indexOf(String(events[i].calendar || "")) === -1) out.push(events[i])
  return out
}

function eventsForDay(events, key) {
  var wanted = String(key || "")
  var out = []
  for (var i = 0; i < (events || []).length; i++) {
    if (dayKeys(events[i]).indexOf(wanted) !== -1) out.push(events[i])
  }
  out.sort(compare)
  return out
}

// The time column beside each event. All-day events say so; a timed one shows
// the start it is filed under, which for the second day of a multi-day event
// is the start of that day rather than the original hour.
function timeLabel(event, dayKey) {
  if (!event) return ""
  if (event.allDay) return "All day"
  if (dayKey && event.dayKey !== String(dayKey)) return "All day"
  return pad2(event.startHour) + ":" + pad2(event.startMinute)
}

// ---- Composing a new event. Times are typed rather than picked: a clock
// widget is a lot of panel for something everyone can already write, and
// "14:30" is unambiguous in a way a spinner is not.

// Accepts 9, 9:5, 0900, 09.30 and 21:45. People type times a dozen ways and
// none of them are wrong.
function parseClock(text) {
  var raw = String(text || "").replace(/\s+/g, "")
  if (raw === "") return null
  var m = /^(\d{1,2})[:.,]?(\d{2})?$/.exec(raw)
  if (!m) return null
  var h = parseInt(m[1], 10)
  var min = m[2] === undefined ? 0 : parseInt(m[2], 10)
  if (!isFinite(h) || !isFinite(min) || h > 23 || min > 59) return null
  return { hour: h, minute: min }
}

function clockLabel(hour, minute) {
  return pad2(hour) + ":" + pad2(minute)
}

// Tidy on the way out, so what was typed becomes what is stored.
function normalizeClock(text) {
  var t = parseClock(text)
  return t === null ? "" : clockLabel(t.hour, t.minute)
}

function shiftClock(text, minutes) {
  var t = parseClock(text)
  if (t === null) return ""
  var total = ((t.hour * 60 + t.minute + minutes) % 1440 + 1440) % 1440
  return clockLabel(Math.floor(total / 60), total % 60)
}

// On today, the next full hour, because an event you are adding now is
// almost never in the past. On any other day, a plain working hour.
function defaultStartClock(dayKey, todayKey, now) {
  if (String(dayKey) !== String(todayKey)) return "09:00"
  var hour = now.getHours() + 1
  return hour > 23 ? "23:00" : clockLabel(hour, 0)
}

function endsAfterStart(startText, endText) {
  var a = parseClock(startText), b = parseClock(endText)
  if (a === null || b === null) return false
  return (b.hour * 60 + b.minute) > (a.hour * 60 + a.minute)
}

// An end at or before the start is not a mistake to reject: an event that
// begins at 23:00 and runs an hour ends at midnight, and refusing that would
// make the last hour of the day unusable. It runs into the next day instead,
// and the form says so rather than deciding quietly.
function crossesMidnight(startText, endText) {
  var a = parseClock(startText), b = parseClock(endText)
  if (a === null || b === null) return false
  return (b.hour * 60 + b.minute) <= (a.hour * 60 + a.minute)
}

// A stable identity for one event, so a row can be remembered as expanded
// across redraws. The UID alone is not enough: every occurrence of a repeating
// event shares it, so the start has to come along.
function eventKey(event) {
  if (!event) return ""
  return String(event.uid || "") + "|" + String(event.startMs)
}

// The full span, for the detail view. The list itself shows only the start,
// which is what you scan a day by, so this is the half that was left out.
function timeRange(event) {
  if (!event) return ""
  if (event.allDay) return "All day"
  var start = new Date(event.startMs)
  var end = new Date(event.endMs)
  var from = pad2(start.getHours()) + ":" + pad2(start.getMinutes())
  if (event.endMs <= event.startMs) return from
  return from + " – " + pad2(end.getHours()) + ":" + pad2(end.getMinutes())
}

// Whether the event touches more than one day, and so needs dates spelled
// out beside its times.
function spansDays(event) {
  return event ? dayKeys(event).length > 1 : false
}

function startDate(event) {
  return event ? new Date(event.startMs) : new Date()
}

// The last day the event is actually on. iCalendar writes an all-day DTEND as
// the morning after, and a timed event ending at midnight belongs to the day
// before it, so both are stepped back to the day a person would name.
function displayEndDate(event) {
  if (!event) return new Date()
  var end = new Date(event.endMs)
  if (event.endMs <= event.startMs) return new Date(event.startMs)
  if (event.allDay || (end.getHours() === 0 && end.getMinutes() === 0))
    return new Date(event.endMs - 1)
  return end
}

// Live-ness for the day being looked at, so the current event can be marked.
function isOngoing(event, nowMs) {
  if (!event || event.allDay) return false
  return nowMs >= event.startMs && nowMs < event.endMs
}

function isPast(event, nowMs) {
  if (!event || event.allDay) return false
  return event.endMs <= nowMs
}

// "3 events", "1 event", "": the count beside the day heading.
function summaryLabel(count) {
  var n = Number(count) || 0
  if (n <= 0) return ""
  return n === 1 ? "1 event" : n + " events"
}

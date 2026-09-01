import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Events.js" as Events
import "Model.js" as Model

// The clock's calendar popup: a month grid with ISO week numbers, built to
// sit beside the weather panel — same hero-over-detail composition, same
// spacing scale, same small-caps labels.
//
// The grid is a read-out rather than a picker: today is the only marked
// day, and the only thing that moves is which month is on screen —
// chevrons, the scroll wheel, and the arrow keys all step it.
//
// BarWidget.qml owns the bar label and hands this panel the button to
// anchor against.
Panel {
  id: root
  moduleName: "io.github.gabbe2312.calendar"
  ipcTarget: "io.github.gabbe2312.calendar"
  manageIpc: false

  property var anchorItem: null

  // The bar tracks the widget mounted in its slot — BarWidget.qml — not this
  // nested panel. Everything the bar identifies a panel by has to be that
  // widget: the popout coordinator (and with it the open-panel dot under the
  // pill) compares against `slot.activeItem`, and switchPanelFrom looks the
  // slot up the same way.
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // ---- Today. SystemClock keeps this honest across midnight so the
  //      highlight rolls over without the panel being reopened.
  property date today: new Date()
  readonly property string todayKey: Model.keyForDate(today)

  // The month on screen. Stepping moves this and nothing else: the grid is
  // a read-out, not a picker, so there is no per-day cursor to keep in sync.
  property int viewYear: today.getFullYear()
  property int viewMonth: today.getMonth()

  readonly property date viewDate: new Date(viewYear, viewMonth, 1)
  readonly property bool viewingCurrentMonth: viewYear === today.getFullYear() && viewMonth === today.getMonth()

  // Pinned to today, not to the month being browsed — stepping through the
  // calendar does not change how much of the year is gone.
  readonly property real yearDone: Model.yearProgress(today.getFullYear(), today.getMonth(), today.getDate())
  readonly property int yearDonePercent: Model.yearProgressPercent(today.getFullYear(), today.getMonth(), today.getDate())

  // Memento mori, for anyone who goes looking: double-tapping the year bar
  // asks for a birth year and a life expectancy, and a second bar tracks one
  // against the other. A birth year rather than an age, so it keeps counting
  // on its own. Without one the bar stays hidden.
  readonly property int birthYear: Model.parseBirthYear(setting("birthYear", 0), today.getFullYear())
  readonly property int age: Model.ageFromBirthYear(birthYear, today.getFullYear())
  readonly property int lifeExpectancy: Model.parseLifeExpectancy(setting("lifeExpectancy", 0))
  readonly property real lifeDone: Model.lifeProgress(age, lifeExpectancy)
  readonly property int lifeDonePercent: Model.lifeProgressPercent(age, lifeExpectancy)
  property bool editingLife: false

  // The year meter is the rule under the hero as well as a reading, so
  // hiding it cannot simply delete the row: the hero would sit straight on
  // the grid. Off, the space keeps a plain hairline, which is both the
  // divider the layout needs and the way back.
  readonly property bool showYearBar: setting("showYearProgress", true) !== false

  function toggleYearBar() {
    persistSettings({ showYearProgress: !root.showYearBar })
  }

  // Unset falls through to the locale's own first day, so a fresh install
  // starts out matching the rest of the desktop rather than a hardcoded
  // convention. Clicking the grid's "W" heading writes the choice back to
  // shell.json.
  readonly property int weekStart: Model.normalizedWeekStart(setting("weekStartDay", null), Qt.locale().firstDayOfWeek)
  // The interface is English throughout, so day names are not taken from the
  // system locale. Where the week starts still is: that is a regional
  // convention rather than a translation, and it stays overridable above.
  readonly property var labelLocale: Qt.locale("en_US")
  readonly property string nextWeekStartLabel: labelLocale.dayName(Model.toggledWeekStart(weekStart), Locale.LongFormat)
  readonly property var weekdays: Model.weekdayOrder(weekStart)
  readonly property var weeks: Model.monthGrid(viewYear, viewMonth, weekStart, todayKey)

  // ---- Calendar events, read from the cache omarchy-calendar-sync writes.
  //      The shell never touches the network itself: it watches one JSON file
  //      and redraws, so the panel opens instantly and still has yesterday's
  //      answer when the laptop is offline.
  property var cache: Events.parseCache("")
  // Which calendars are switched off, kept in shell.json so the choice
  // outlives a restart. Hiding is a display choice only; the events stay in
  // the cache, so switching one back on is instant.
  readonly property var hiddenCalendars: setting("hiddenCalendars", [])
  // From the server's own list, not inferred from the events in them, so a
  // calendar made a moment ago is here with its colour before anything has
  // been put in it.
  readonly property var calendars: Events.calendarList(cache.calendars, cache.events)
  readonly property var sourceColors: Events.colourIndex(cache.calendars)

  // Hand-picked colours, by calendar name. A display choice like hiding, so
  // it lives in shell.json next to it rather than in the sync config.
  readonly property var calendarColors: setting("calendarColors", ({}))

  // Names you have given a calendar yourself. Subscribed feeds often supply
  // none at all, in which case the sync falls back to a placeholder, and Apple's own
  // names are not always what you would call them either.
  readonly property var calendarNames: setting("calendarNames", ({}))

  // Which event row is showing its details. One at a time: the point is to
  // look something up, not to unfold the whole day.
  property string expandedEvent: ""

  // ---- Composing. Only calendars the account owns can take a new event: a
  //      subscribed feed is read-only, and a reminder list holds a different
  //      kind of thing entirely.
  readonly property var writableCalendars: Events.writableNames(cache.calendars)
  property bool composing: false
  property bool creating: false
  property string composeError: ""
  property string composeCalendar: ""

  readonly property string composeCalendarName: {
    var chosen = String(root.composeCalendar || "")
    if (chosen !== "" && root.writableCalendars.indexOf(chosen) !== -1) return chosen
    return root.writableCalendars.length > 0 ? String(root.writableCalendars[0]) : ""
  }

  // The helper lives beside this file, wherever the plugin was installed.
  // there is nothing on PATH to rely on for a plugin someone downloaded.
  readonly property string pluginDir: String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "")
  readonly property var syncCommand: [root.pluginDir + "bin/omadates-sync"]

  // Sign-in state. The password is held only between the click and the
  // helper reading it off stdin, and never touches disk on the way.
  property string pendingPassword: ""
  property bool signingIn: false
  property string signInError: ""

  readonly property bool configured: cache.configured === true
  readonly property bool signedIn: cache.signedIn === true

  // Someone who only ever subscribed to a feed is configured but not signed
  // in. Without this the form would be gone for good the moment the first
  // feed landed, and there would be no way back to it.
  property bool showSignIn: false
  readonly property bool signInVisible: (!root.configured || root.showSignIn)
    && root.missingPackages.length === 0

  // Focus follows the form rather than being asked for at each call site.
  // Signing out while the panel is open put the form on screen with nothing
  // focused, so typing went nowhere: the panel invites you to type by
  // focusing the field when it opens, then quietly stops honouring that.
  onSignInVisibleChanged: {
    if (!root.opened) return
    Qt.callLater(function() {
      if (!root.opened) return
      // And handed back when the form goes away, or the month keys would
      // stay dead on a field nobody can see any more.
      if (root.signInVisible) appleIdField.forceActiveFocus()
      else if (keyCatcher) keyCatcher.forceActiveFocus()
    })
  }
  readonly property var missingPackages: cache.missing instanceof Array ? cache.missing : []

  // Which calendar's swatches are open, and whether the URL field is up.
  // Only one of the two rows shows at a time. They occupy the same slot
  // under the calendar switches.
  property string calendarEditing: ""
  // "" closed, "choose" asking which, "feed" pasting a URL, "calendar"
  // naming a new one. The + used to mean only the middle of those.
  property string addMode: ""
  readonly property bool addingSubscription: root.addMode !== ""
  property bool subscribing: false
  property string subscribeError: ""

  property string newCalendarColour: "#4A90D9"
  property bool makingCalendar: false

  // Removing a calendar takes everything in it, so it is asked for twice and
  // told plainly in between. Armed per calendar, and disarmed by leaving.
  property bool calendarDeleteArmed: false
  property bool deletingCalendar: false

  readonly property var editedCalendar: {
    for (var i = 0; i < root.calendars.length; i++)
      if (String(root.calendars[i].name) === root.calendarEditing) return root.calendars[i]
    return null
  }

  readonly property string calendarDeleteWarning: {
    if (!root.editedCalendar) return ""
    return root.editedCalendar.subscribed === true
      ? "This stops following the feed. Whoever publishes it is unaffected, and pasting the address back brings it here again."
      : "This removes the calendar and everything in it from iCloud, on every device signed in to the account. It cannot be undone from here."
  }

  readonly property var events: Events.visibleEvents(cache.events, hiddenCalendars)
  readonly property var eventMarks: Events.marksByDay(events)
  readonly property bool cacheFailed: cache.status === "error"
  readonly property bool cacheMissing: cache.status === "empty"

  // The day the list below the grid is showing. Today until you click
  // another one. The question a calendar answers by default is "what is on
  // today", and everything else is a deliberate click away.
  property string selectedKey: todayKey
  onSelectedKeyChanged: {
    root.expandedEvent = ""
    root.deleteArmed = ""
  }
  readonly property var selectedEvents: Events.eventsForDay(root.events, selectedKey)
  readonly property date selectedDate: Model.dateFromKey(selectedKey, today)
  readonly property bool selectedIsToday: selectedKey === todayKey

  // Minute-resolution now, so the event you are in the middle of stays
  // marked as it moves rather than only at the moment the panel opened.
  property double nowMs: new Date().getTime()

  // Only the ordinary outcomes. Never signed in and missing packages each
  // get their own block below, because each has a different next step.
  // An empty day says so plainly. Whether the last sync worked is a separate
  // question with a separate line, because the two are independent: a failed
  // sync leaves the last good calendar on screen, and a day with nothing on
  // it is not a fault.
  readonly property string statusMessage: "Nothing scheduled"

  // A failed sync is not news until it has lasted. The first one usually has
  // not: the shell starts before the machine has a route, so the honest
  // report at that moment is that the calendar cannot reach iCloud, and it
  // is about to be wrong. Announcing it teaches you to distrust the line,
  // which is the one thing it cannot afford — the failures worth saying out
  // loud are the ones that stay, a password the server no longer accepts or
  // a feed that has moved.
  //
  // So the retry ladder below gets its first three tries in silence, and
  // only a failure still standing after those says so. What is on screen
  // meanwhile is the last calendar that arrived, which is the right thing to
  // be showing either way.
  readonly property int troubleGrace: 45 * 1000
  property bool troubleSettled: false
  readonly property string syncTrouble: root.cacheFailed && root.troubleSettled
    ? (root.cache.error !== "" ? root.cache.error : "Calendar sync failed")
    : ""


  // Guarded so the widget renders before the bar is injected (the bar-widget
  // contract instantiates it bare).
  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property bool foregroundIsLight: (0.2126 * contentForeground.r
    + 0.7152 * contentForeground.g + 0.0722 * contentForeground.b) > 0.5

  // The colour a calendar is drawn in, in priority order: the override you
  // set by hand, then whatever iCloud or the feed gave it, then the theme
  // accent. Nudged only when the theme would swallow it outright.
  function displayName(name) {
    var key = String(name || "")
    var custom = root.calendarNames[key]
    return (custom === undefined || custom === null || String(custom) === "")
      ? key : String(custom)
  }

  function calendarColor(name) {
    var key = String(name || "")
    var override = root.calendarColors[key]
    var chosen = (override === undefined || override === null || String(override) === "")
      ? String(root.sourceColors[key] || "")
      : String(override)
    var legible = Events.legibleColor(chosen, root.foregroundIsLight)
    return legible !== "" ? legible : Style.selectedStateColor(root.contentForeground, Color.accent)
  }
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family

  // Every day cell reserves room for the dot rail, so the number sits in the
  // same place whether the day has dots or not. Toggling a calendar must not
  // make the whole grid twitch.
  readonly property int dotRailOffset: Style.space(3)

  // Everything in the calendar row shares one height and centres inside it.
  // A Flow aligns its children by their top edge, so items whose glyphs differ in
  // size would otherwise each sit on a line of their own.
  readonly property int calendarRowHeight: Math.round(Style.font.body * 1.5)

  readonly property int cellWidth: Style.space(52)
  readonly property int cellHeight: Style.space(34)
  readonly property int cellSpacing: Style.space(2)
  readonly property int weekColumnWidth: Style.space(32)
  readonly property int gutterWidth: Style.space(14)

  function open() {
    refresh()
    root.controller.show()
    // Set after showing, not before: showing hands the popout coordinator
    // over, which closes whichever panel was open, and that close clears the
    // shared flag. Deferring means the panel taking over always wins, while
    // a handoff to a panel that does not manage the flag still leaves it
    // cleared rather than stuck on.
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
      // A panel that opens by asking for credentials should be ready to take
      // them, rather than making the first act a click into a field.
      if (root.opened && root.signInVisible) appleIdField.forceActiveFocus()
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    // Dismissing the panel mid-edit would otherwise leave the inputs up,
    // waiting behind a closed popup for the next time it opens.
    if (root.editingLife) root.cancelEditingLife()
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  // Summoning by hotkey moves no pointer, so a hover the bar was still
  // holding must not keep the center indicators revealed behind the panel.
  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  function refresh() {
    root.today = new Date()
    root.nowMs = new Date().getTime()
    root.goToToday()
    calendarCache.reload()
    root.requestPoll()
  }

  // A background sync, but only when the cache has actually gone stale.
  // Opening the panel repeatedly should not hammer iCloud, and the timer is
  // already covering the steady state.
  function requestSync() {
    if (syncProcess.running || pollProcess.running) return false
    syncProcess.running = true
    return true
  }

  // Asking whether anything changed costs a fraction of fetching it, so it
  // can be asked often. A change made on a phone lands here inside a minute
  // rather than waiting out the quarter hour.
  function requestPoll() {
    if (syncProcess.running || pollProcess.running) return
    pollProcess.running = true
  }

  function goToToday() {
    root.viewYear = today.getFullYear()
    root.viewMonth = today.getMonth()
    root.selectedKey = root.todayKey
  }

  function selectDay(day) {
    if (!day || !day.key) return
    root.selectedKey = String(day.key)
    // Clicking a trailing day from a neighbouring month follows it there,
    // rather than selecting a cell that is about to be greyed out.
    if (!day.inMonth) {
      root.viewYear = day.year
      root.viewMonth = day.month
    }
  }

  // Stepping months re-aims the list at the new month: today when it is the
  // current one, otherwise its first day. Leaving the old selection would
  // print a day the grid is no longer showing.
  function syncSelectionToView() {
    root.selectedKey = root.viewingCurrentMonth
      ? root.todayKey
      : Model.dateKey(root.viewYear, root.viewMonth, 1)
  }

  function moveMonth(delta) {
    var next = Model.stepMonth(viewYear, viewMonth, delta)
    root.viewYear = next.year
    root.viewMonth = next.month
    root.syncSelectionToView()
  }

  function moveYear(delta) {
    moveMonth(delta * 12)
  }

  // Applied locally first so the panel redraws on the click itself; the
  // shell.json write comes back through the bar as the same value. With no
  // writable entry (the widget is not in the layout) it stays a session-only
  // preference rather than doing nothing. The host widget builds its own
  // entry when the label format is cycled, so it has to be kept in step or
  // it would write this key straight back out from a stale copy.
  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    for (var key in values) entry[key] = values[key]

    root.settings = entry
    if (root.hostWidget && "settings" in root.hostWidget) root.hostWidget.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function toggleCalendar(name) {
    var target = String(name || "")
    if (target === "") return

    var next = []
    var wasHidden = false
    for (var i = 0; i < root.hiddenCalendars.length; i++) {
      var entry = String(root.hiddenCalendars[i])
      if (entry === target) wasHidden = true
      else next.push(entry)
    }
    if (!wasHidden) next.push(target)
    persistSettings({ hiddenCalendars: next })
  }

  function setCalendarColor(name, hex) {
    var key = String(name || "")
    if (key === "") return

    // A calendar the account owns keeps its colour on the server, where every
    // device reads it. Setting it here sets it on the phone, so a local
    // override would only be something to disagree with later.
    if (root.writableCalendars.indexOf(key) !== -1 && String(hex || "") !== "") {
      root.colourError = ""
      root.colouring = true
      root.pendingColour = JSON.stringify({ calendar: key, color: String(hex) })
      colourProcess.stdinEnabled = true
      colourProcess.command = root.syncCommand.concat(["colour"])
      colourProcess.running = true
      if (root.calendarColors[key] !== undefined) {
        var without = {}
        for (var drop in root.calendarColors) if (drop !== key) without[drop] = root.calendarColors[drop]
        persistSettings({ calendarColors: without })
      }
      return
    }

    var next = {}
    for (var existing in root.calendarColors) next[existing] = root.calendarColors[existing]
    // An empty colour clears the override rather than storing a blank, so
    // the calendar goes back to the colour its source gave it.
    if (String(hex || "") === "") delete next[key]
    else next[key] = String(hex)
    // The editor stays open: renaming and recolouring are usually the same
    // errand, and closing on the first click would undo half of it.
    persistSettings({ calendarColors: next })
  }

  function setCalendarName(name, label) {
    var key = String(name || "")
    if (key === "") return
    var trimmed = String(label || "").replace(/^\s+|\s+$/g, "")
    var next = {}
    for (var existing in root.calendarNames) next[existing] = root.calendarNames[existing]
    // Blank, or the original typed back, drops the override rather than
    // storing a copy of the name it already had.
    if (trimmed === "" || trimmed === key) delete next[key]
    else next[key] = trimmed
    persistSettings({ calendarNames: next })
  }

  function signIn() {
    var user = String(appleIdField.text || "").replace(/^\s+|\s+$/g, "")
    var secret = String(passwordField.text || "")
    if (user === "" || secret === "") {
      root.signInError = "Both fields are needed"
      return
    }
    root.signInError = ""
    root.pendingPassword = secret
    root.signingIn = true
    // Re-armed every time. Closing stdin in onStarted is what lets the
    // helper's read() return, but the assignment breaks the declarative
    // binding: the next run survives on what is left of it and every run
    // after that gets no stdin at all.
    loginProcess.stdinEnabled = true
    loginProcess.command = root.syncCommand.concat(["login", user])
    loginProcess.running = true
  }

  function signOut() {
    logoutProcess.command = root.syncCommand.concat(["logout"])
    logoutProcess.running = true
  }

  function deleteCalendar() {
    if (!root.editedCalendar) return
    root.calendarDeleteArmed = false
    root.deletingCalendar = true
    root.pendingColour = JSON.stringify({
      name: String(root.editedCalendar.name),
      url: String(root.editedCalendar.url || "")
    })
    deleteCalendarProcess.stdinEnabled = true
    deleteCalendarProcess.command = root.syncCommand.concat(["deletecalendar"])
    deleteCalendarProcess.running = true
  }

  function startEditingCalendar(name) {
    var key = String(name || "")
    root.calendarDeleteArmed = false
    if (root.calendarEditing === key) {
      root.closeCalendarEditor()
      return
    }
    root.addMode = ""
    root.calendarEditing = key
    Qt.callLater(function() {
      nameField.text = root.displayName(key)
      nameField.selectAll()
      nameField.forceActiveFocus()
    })
  }

  // Closing commits whatever is in the field, so a typed name is not lost by
  // clicking away from it.
  function closeCalendarEditor() {
    root.calendarDeleteArmed = false
    if (root.calendarEditing !== "") root.setCalendarName(root.calendarEditing, nameField.text)
    root.calendarEditing = ""
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  // The helper picks the map: a registered geo: handler is the system's own
  // choice, and only a machine with none falls back to the web.
  function openMap(location) {
    var place = String(location || "").replace(/^\s+|\s+$/g, "")
    if (place === "") return
    mapProcess.command = root.syncCommand.concat(["map", place])
    mapProcess.running = true
  }

  function startComposing() {
    root.composeError = ""
    root.composing = true
    Qt.callLater(function() {
      titleField.text = ""
      placeField.text = ""
      notesField.text = ""
      allDayBox = false
      startField.text = Events.defaultStartClock(root.selectedKey, root.todayKey, new Date())
      endField.text = Events.shiftClock(startField.text, 60)
      titleField.forceActiveFocus()
    })
  }

  function cancelComposing() {
    root.composing = false
    root.creating = false
    root.composeError = ""
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  property bool allDayBox: false

  // The payload goes over stdin as JSON: a title or a note can hold quotes
  // and newlines, and none of that belongs in a process list.
  function createEvent() {
    var title = String(titleField.text || "").replace(/^\s+|\s+$/g, "")
    if (title === "") {
      root.composeError = "A title is needed"
      return
    }
    if (root.composeCalendarName === "") {
      root.composeError = "No calendar can take an event"
      return
    }

    var payload = {
      calendar: root.composeCalendarName,
      summary: title,
      location: String(placeField.text || "").replace(/^\s+|\s+$/g, ""),
      description: String(notesField.text || ""),
      allDay: root.allDayBox
    }

    if (root.allDayBox) {
      payload.start = root.selectedKey
    } else {
      var from = Events.normalizeClock(startField.text)
      var to = Events.normalizeClock(endField.text)
      if (from === "" || to === "") {
        root.composeError = "Times read as HH:MM"
        return
      }
      payload.start = root.selectedKey + "T" + from
      // An end at or before the start runs into the next day. The form marks
      // it, so nothing is decided behind your back.
      payload.end = (Events.crossesMidnight(from, to)
        ? Model.keyForDate(new Date(root.selectedDate.getTime() + 86400000))
        : root.selectedKey) + "T" + to
    }

    root.composeError = ""
    root.creating = true
    root.pendingPayload = JSON.stringify(payload)
    createProcess.stdinEnabled = true
    createProcess.command = root.syncCommand.concat(["create"])
    createProcess.running = true
  }

  property string pendingPayload: ""

  // The helper has its own network timeout, but a process can die in ways
  // that never reach onExited. Without this the button would sit on
  // "Creating…" until the shell was restarted, which is what happened.
  Timer {
    id: writeWatchdog
    interval: 40000
    repeat: false
    running: root.creating || root.deleting || root.colouring
      || root.makingCalendar || root.deletingCalendar
    onTriggered: {
      if (root.creating) root.composeError = "That took too long. Nothing was saved as far as this knows"
      if (root.colouring) root.colourError = "That took too long"
      if (root.makingCalendar) root.subscribeError = "That took too long"
      root.makingCalendar = false
      root.deletingCalendar = false
      root.creating = false
      root.deleting = false
      root.colouring = false
      calendarCache.reload()
    }
  }

  // Which event is one click from being removed. Armed by the first press
  // and cleared by anything else, so nothing goes on a single stray click
  // and nothing stays armed behind your back.
  property string deleteArmed: ""
  property bool deleting: false

  // Writing a colour to the server, which is where the phone reads it.
  property string pendingColour: ""
  property bool colouring: false
  property string colourError: ""

  readonly property bool editingOwnCalendar:
    root.writableCalendars.indexOf(root.calendarEditing) !== -1

  function canDelete(event) {
    if (!event) return false
    if (event.subscribed === true) return false
    if (String(event.uid || "") === "") return false
    return root.writableCalendars.indexOf(String(event.calendar || "")) !== -1
  }

  function requestDelete(event) {
    var key = Events.eventKey(event)
    if (root.deleteArmed !== key) {
      root.deleteArmed = key
      return
    }
    root.deleteArmed = ""
    root.deleting = true
    // The start goes along so the helper can look in the right few days:
    // iCloud refuses the UID query that would otherwise find it directly.
    root.pendingPayload = JSON.stringify({
      uid: String(event.uid),
      calendar: String(event.calendar),
      start: Model.keyForDate(new Date(event.startMs)) + "T"
        + Events.timeLabel(event, "").replace("All day", "00:00")
    })
    deleteProcess.stdinEnabled = true
    deleteProcess.command = root.syncCommand.concat(["delete"])
    deleteProcess.running = true
  }

  function toggleEventDetail(event) {
    var key = Events.eventKey(event)
    root.deleteArmed = ""
    root.expandedEvent = root.expandedEvent === key ? "" : key
  }

  function startAddingSubscription() {
    root.calendarEditing = ""
    root.subscribeError = ""
    // Only offer the choice where both halves are possible: without an
    // account there is nowhere to make a calendar, and a feed is the only
    // thing on the table.
    root.addMode = root.signedIn ? "choose" : "feed"
    if (root.addMode === "feed") Qt.callLater(function() {
      urlField.text = ""
      urlField.forceActiveFocus()
    })
  }

  function chooseAddMode(mode) {
    root.subscribeError = ""
    root.addMode = String(mode)
    Qt.callLater(function() {
      if (root.addMode === "feed") { urlField.text = ""; urlField.forceActiveFocus() }
      else if (root.addMode === "calendar") { newCalendarField.text = ""; newCalendarField.forceActiveFocus() }
    })
  }

  function cancelAddingSubscription() {
    root.addMode = ""
    root.subscribeError = ""
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  function createCalendar() {
    var name = String(newCalendarField.text || "").replace(/^\s+|\s+$/g, "")
    if (name === "") {
      root.subscribeError = "A calendar needs a name"
      return
    }
    root.subscribeError = ""
    root.makingCalendar = true
    root.pendingColour = JSON.stringify({ name: name, color: root.newCalendarColour })
    newCalendarProcess.stdinEnabled = true
    newCalendarProcess.command = root.syncCommand.concat(["newcalendar"])
    newCalendarProcess.running = true
  }

  // The helper writes the subscription to calendar.json and re-runs the sync
  // itself, so the cache, and with it this panel, updates on its own.
  function commitSubscription() {
    var url = String(urlField.text || "").replace(/^\s+|\s+$/g, "")
    if (!Events.looksLikeCalendarUrl(url)) {
      root.subscribeError = "That does not look like a calendar URL"
      return
    }
    root.subscribeError = ""
    root.subscribing = true
    subscribeProcess.command = root.syncCommand.concat(["subscribe", url])
    subscribeProcess.running = true
  }

  // ---- The stock clock, still sitting on the bar beside this one.
  //
  // Two clocks is the one thing a fresh install can get visibly wrong, and
  // the fix would otherwise be a terminal command. So the panel offers it,
  // rather than either nagging about it or quietly deciding for you: someone
  // may well want both for a while to compare them.
  readonly property bool builtinClockOnBar: {
    if (!root.bar || !root.bar.shell) return false
    var config = root.bar.shell.shellConfig
    if (!config || !config.bar || !config.bar.layout) return false
    var sections = ["left", "center", "right"]
    for (var s = 0; s < sections.length; s++) {
      var list = config.bar.layout[sections[s]]
      if (!(list instanceof Array)) continue
      for (var i = 0; i < list.length; i++)
        if (list[i] && String(list[i].id) === "omarchy.clock") return true
    }
    return false
  }

  // Standing in for the stock clock rather than just deleting it.
  //
  // Deleting left a hole and closed it up, so whatever sat to the clock's
  // right slid over to this widget's left, the keyboard layout ending up on
  // the wrong side of the calendar. Taking the clock's exact slot instead
  // leaves the bar looking precisely as it did before, with this widget
  // where that one was.
  //
  // Off the bar, not uninstalled: the plugin stays enabled, so
  // `omarchy bar put omarchy.clock --section center` brings it straight back.
  function hideBuiltinClock() {
    if (!root.bar || !root.bar.shell) return
    var shell = root.bar.shell
    if (typeof shell.persistShellConfig !== "function") return
    var config = shell.shellConfig
    if (!config || !config.bar || !config.bar.layout) return

    var next = JSON.parse(JSON.stringify(config))
    var sections = ["left", "center", "right"]

    // This widget's own entry, settings and all. The move must not cost it
    // its colours, names or label format.
    var mine = null
    for (var a = 0; a < sections.length; a++) {
      var source = next.bar.layout[sections[a]]
      if (!(source instanceof Array)) continue
      for (var b = 0; b < source.length; b++)
        if (source[b] && String(source[b].id) === root.moduleName) mine = source[b]
    }
    if (!mine) return

    var placed = false
    for (var s = 0; s < sections.length; s++) {
      var list = next.bar.layout[sections[s]]
      if (!(list instanceof Array)) continue
      var kept = []
      for (var i = 0; i < list.length; i++) {
        var entry = list[i]
        var id = entry ? String(entry.id) : ""
        if (id === "omarchy.clock" && !placed) {
          kept.push(mine)
          placed = true
        } else if (id !== root.moduleName && id !== "omarchy.clock") {
          kept.push(entry)
        }
        // This widget's old position is dropped; it reappears in the slot above.
      }
      next.bar.layout[sections[s]] = kept
    }
    // Nothing to stand in for means nothing to rearrange.
    if (!placed) return
    shell.persistShellConfig(next)
  }

  function setWeekStart(day) {
    var next = Model.normalizedWeekStart(day, root.weekStart)
    if (next === root.weekStart) return
    persistSettings({ weekStartDay: Model.weekStartSettingName(next) })
  }

  function startEditingLife() {
    root.editingLife = true
    Qt.callLater(function() {
      bornField.text = root.birthYear > 0 ? String(root.birthYear) : ""
      expectancyField.text = String(root.lifeExpectancy)
      bornField.selectAll()
      bornField.forceActiveFocus()
    })
  }

  function cancelEditingLife() {
    root.editingLife = false
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  // Shared by both fields: Tab hops to the other one, Enter commits the pair,
  // Escape drops the lot.
  function handleLifeKey(event, other) {
    if (event.key === Qt.Key_Escape) {
      root.cancelEditingLife()
      event.accepted = true
    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      root.commitLife()
      event.accepted = true
    } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
      other.selectAll()
      other.forceActiveFocus()
      event.accepted = true
    }
  }

  // Double-tapping the life bar puts it away again. The expectancy stays in
  // the config so setting a birth year again brings your own number back
  // rather than the default.
  function clearLife() {
    if (root.birthYear <= 0) return
    persistSettings({ birthYear: 0 })
  }

  function commitLife() {
    var born = Model.parseBirthYear(bornField.text, today.getFullYear())
    var span = Model.parseLifeExpectancy(expectancyField.text)
    if (born !== root.birthYear || span !== root.lifeExpectancy)
      persistSettings({ birthYear: born, lifeExpectancy: span })
    cancelEditingLife()
  }

  function toggleWeekStart() {
    setWeekStart(Model.toggledWeekStart(root.weekStart))
  }

  // English short day names, matching the rest of the interface.
  function weekdayLabel(weekday) {
    return String(labelLocale.dayName(weekday, Locale.ShortFormat)).toUpperCase()
  }

  // The sync writes this atomically, so a watch fires only on a complete
  // file and the panel never parses half a cache.
  FileView {
    id: calendarCache
    path: Quickshell.env("HOME") + "/.cache/omarchy/omadates/events.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.cache = Events.parseCache(text())
    onLoadFailed: root.cache = Events.parseCache("")
  }

  Process {
    id: loginProcess
    stdinEnabled: true
    onStarted: {
      write(root.pendingPassword + "\n")
      // Closing stdin is what lets the helper's read() return.
      stdinEnabled = false
    }
    onExited: function(exitCode) {
      root.pendingPassword = ""
      root.signingIn = false
      if (exitCode === 0) {
        root.signInError = ""
        root.showSignIn = false
        appleIdField.text = ""
        passwordField.text = ""
        Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
      } else {
        // Short enough to sit beside the button without being elided; the
        // line underneath already says where an app-specific password
        // comes from, so it does not need repeating here.
        root.signInError = "Sign-in failed. Check both fields"
      }
      calendarCache.reload()
    }
  }

  Process {
    id: appleLinkProcess
  }

  Process {
    id: mapProcess
  }

  Process {
    id: deleteCalendarProcess
    stdinEnabled: true
    onStarted: {
      write(root.pendingColour)
      stdinEnabled = false
    }
    onExited: function(exitCode) {
      root.pendingColour = ""
      root.deletingCalendar = false
      if (exitCode === 0) {
        root.calendarEditing = ""
        Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
      } else {
        root.colourError = "Could not remove it"
      }
      calendarCache.reload()
    }
  }

  Process {
    id: newCalendarProcess
    stdinEnabled: true
    onStarted: {
      write(root.pendingColour)
      stdinEnabled = false
    }
    onExited: function(exitCode) {
      root.pendingColour = ""
      root.makingCalendar = false
      if (exitCode === 0) root.cancelAddingSubscription()
      else root.subscribeError = "Could not create it. See the sync line above"
      calendarCache.reload()
    }
  }

  Process {
    id: colourProcess
    stdinEnabled: true
    onStarted: {
      write(root.pendingColour)
      stdinEnabled = false
    }
    onExited: function(exitCode) {
      root.pendingColour = ""
      root.colouring = false
      root.colourError = exitCode === 0 ? "" : "Could not set it on the server"
      calendarCache.reload()
    }
  }

  Process {
    id: deleteProcess
    stdinEnabled: true
    onStarted: {
      write(root.pendingPayload)
      stdinEnabled = false
    }
    onExited: function(exitCode) {
      root.pendingPayload = ""
      root.deleting = false
      if (exitCode === 0) root.expandedEvent = ""
      calendarCache.reload()
    }
  }

  Process {
    id: createProcess
    stdinEnabled: true
    onStarted: {
      write(root.pendingPayload)
      stdinEnabled = false
    }
    onExited: function(exitCode) {
      root.pendingPayload = ""
      root.creating = false
      if (exitCode === 0) {
        root.composing = false
        root.composeError = ""
        Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
      } else {
        root.composeError = "Could not create it. See the sync line below"
      }
      calendarCache.reload()
    }
  }

  Process {
    id: logoutProcess
    onExited: calendarCache.reload()
  }

  Process {
    id: subscribeProcess
    onExited: function(exitCode) {
      root.subscribing = false
      if (exitCode === 0) {
        root.cancelAddingSubscription()
      } else {
        // The helper prints the real reason; this is only the nudge to go
        // look, since the panel has no room to quote a stack trace.
        root.subscribeError = "Could not add that calendar. Check the URL"
      }
      calendarCache.reload()
    }
  }

  Process {
    id: pollProcess
    command: root.syncCommand.concat(["poll"])
  }

  Process {
    id: syncProcess
    command: root.syncCommand
    // Nothing to do on exit: the sync rewrites the cache, and the FileView
    // above is already watching it.
  }

  // How often to ask in the background. Opening the panel always asks, and
  // that is the moment that matters: nothing outside the panel shows an
  // event, so a check nobody is waiting on buys very little. This interval
  // only decides how fresh the first paint is before the on-open check
  // corrects it a second or two later.
  //
  // Every minute would cost almost no CPU but would wake the radio 1440
  // times a day for a calendar looked at maybe ten times, which is the real
  // price on a laptop. Five minutes is the same experience for a fifth of
  // the wakeups. Set pollSeconds on the widget to taste; 0 leaves only the
  // quarter-hour sync.
  readonly property int pollSeconds: Math.max(0, Number(setting("pollSeconds", 300)) || 0)

  Timer {
    interval: Math.max(15, root.pollSeconds) * 1000
    running: root.pollSeconds > 0
    repeat: true
    onTriggered: root.requestPoll()
  }

  Timer {
    // The backstop. Subscribed feeds carry no sync token, so nothing cheap
    // can tell whether a timetable moved; and a full pass repairs anything
    // the tokens might have missed.
    interval: 15 * 60 * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.requestSync()
  }

  // ---- Getting back on after a sync that did not land.
  //      The pass above fires as the shell starts, which at boot is a second
  //      or two before NetworkManager has a route: the first thing the
  //      calendar says about a laptop that is about to be online is "no
  //      connection". Neither timer answers that. The poll keeps quiet when
  //      it cannot reach the server, by design, and the full pass is a
  //      quarter of an hour away, so the wrong answer stands for as long as
  //      it takes someone to notice it is wrong.
  //
  //      So a failure asks again itself: soon, since the usual cause is a
  //      radio that has not finished associating, then doubling, since the
  //      other causes are a rejected password and a server that is down and
  //      neither is helped by being asked every five seconds until morning.
  //
  //      Five to start with, because an attempt that fails for want of a
  //      route costs about forty milliseconds and sends nothing: the name
  //      lookup fails locally. That buys two tries inside the first fifteen
  //      seconds, which is the window the radio usually comes up in.
  readonly property int retryFloor: 5 * 1000
  readonly property int retryCeiling: 5 * 60 * 1000
  property int retryDelay: root.retryFloor

  // A sync that works resets the ladder, so the next bad patch starts
  // over at five seconds rather than wherever the last one gave up.
  onCacheFailedChanged: {
    if (!root.cacheFailed) root.retryDelay = root.retryFloor
    // Either way the grace starts over: a fresh failure has not earned the
    // line yet, and one that has just cleared should not leave it behind.
    root.troubleSettled = false
  }

  // Repeating, though it only needs to fire once, because a one-shot Timer
  // clears its own running property, and that assignment breaks the binding
  // that drives it. Settling stops it on the next evaluation instead.
  Timer {
    interval: root.troubleGrace
    running: root.cacheFailed && !root.troubleSettled
    repeat: true
    onTriggered: root.troubleSettled = true
  }

  Timer {
    interval: root.retryDelay
    running: root.cacheFailed
    repeat: true
    // Only a retry that actually ran counts towards the backoff: one skipped
    // because a sync was already in flight has learned nothing.
    onTriggered: if (root.requestSync())
      root.retryDelay = Math.min(root.retryDelay * 2, root.retryCeiling)
  }

  SystemClock {
    id: clock
    precision: SystemClock.Minutes
    onDateChanged: {
      root.nowMs = clock.date.getTime()
      if (Model.keyForDate(clock.date) === String(root.todayKey)) return
      var followToday = root.viewingCurrentMonth
      root.today = clock.date
      if (followToday) root.goToToday()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(560))
    contentHeight: panel.fittedContentHeight(calendarColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.editingLife || root.addingSubscription
        || root.calendarEditing !== "" || root.signInVisible || root.composing
      onMoveRequested: function(dx, dy) {
        if (dx !== 0) root.moveMonth(dx)
        if (dy !== 0) root.moveYear(dy)
      }
      onActivateRequested: root.goToToday()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "[") root.moveMonth(-1)
        else if (t === "]") root.moveMonth(1)
        else if (t === "{") root.moveYear(-1)
        else if (t === "}") root.moveYear(1)
        else if (t === "t" || t === "T") root.goToToday()
        else if (t === "w" || t === "W") root.toggleWeekStart()
      }

      Flickable {
        id: calendarScroll
        anchors.fill: parent
        contentWidth: calendarColumn.width
        contentHeight: calendarColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height || contentWidth > width

        Column {
          id: calendarColumn
          // Never narrower than the grid. The popup width is capped to what
          // the screen allows, and a fixed seven-column grid would otherwise
          // lose its last days off the edge instead of scrolling.
          width: Math.max(calendarScroll.width, gridColumn.width)
          spacing: Style.space(8)

          // ---- Hero: today, centered. Once the view has stepped back
          //      it is also the way home — clicking the date you are
          //      looking for beats hunting for a reset button.
          Item {
            width: parent.width
            height: heroRow.height

            Row {
              id: heroRow
              anchors.horizontalCenter: parent.horizontalCenter
              spacing: Style.space(22)

              Text {
                // Baseline-aligned, not center-aligned: "July 26" carries a
                // descender, so centering the two boxes leaves the icon
                // sitting visibly low against the digits.
                anchors.baseline: heroDate.baseline
                text: "󰃭"
                color: heroMouse.containsMouse
                  ? Style.hoverStateColor(root.contentForeground, Color.accent)
                  : root.contentForeground
                font.family: root.contentFontFamily
                // Decorative, and deliberately outside the Style.font.*
                // scale. Sized so the glyph reads at the cap height of the
                // date beside it rather than towering over it.
                font.pixelSize: 48
              }

              Text {
                id: heroDate
                anchors.verticalCenter: parent.verticalCenter
                text: Qt.formatDate(root.today, "MMMM d")
                color: heroMouse.containsMouse
                  ? Style.hoverStateColor(root.contentForeground, Color.accent)
                  : root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: 52
                font.bold: true
              }
            }

            MouseArea {
              id: heroMouse
              x: heroRow.x
              y: heroRow.y
              width: heroRow.width
              height: heroRow.height
              enabled: !root.viewingCurrentMonth
              hoverEnabled: enabled
              cursorShape: Qt.PointingHandCursor
              onClicked: root.goToToday()

              PanelToolTip {
                visible: heroMouse.containsMouse
                text: "Back to today"
                fontFamily: root.contentFontFamily
              }
            }
          }

          // ---- Year progress, doubling as the rule under the hero:
          //      a plain hairline said nothing, and whole days done
          //      over days in the year says the same thing louder.
          Item {
            width: parent.width
            height: root.showYearBar ? yearBlock.y + yearBlock.height : Style.space(24)

            // The hairline that stands in for the meter. Clicking either one
            // swaps them, so the control is in the same place both ways.
            Rectangle {
              visible: !root.showYearBar
              y: Style.space(12)
              anchors.horizontalCenter: parent.horizontalCenter
              width: gridColumn.width
              height: Style.spacing.hairline
              color: root.contentForeground
              opacity: yearRuleMouse.containsMouse ? 0.35 : 0.12

              MouseArea {
                id: yearRuleMouse
                anchors.fill: parent
                anchors.margins: -Style.space(7)
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.toggleYearBar()
              }

              PanelToolTip {
                visible: yearRuleMouse.containsMouse
                text: "Show year progress"
                fontFamily: root.contentFontFamily
              }
            }

            Item {
              id: yearBlock
              visible: root.showYearBar
              y: Style.space(6)
              anchors.horizontalCenter: parent.horizontalCenter
              width: gridColumn.width
              height: Math.max(yearLabel.implicitHeight, Style.space(10))

              TapHandler {
                enabled: !root.editingLife
                onDoubleTapped: root.startEditingLife()
              }

              // Right-click puts the meter away. Left-click is left alone:
              // the year rail already answers to a double tap for the life
              // bar, and a single click would fight it.
              TapHandler {
                acceptedButtons: Qt.RightButton
                onSingleTapped: root.toggleYearBar()
              }

              Row {
                visible: root.editingLife
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(10)

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: "BORN"
                  color: Qt.darker(root.contentForeground, 1.5)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.letterSpacing: 1
                }

                TextField {
                  id: bornField
                  width: Style.space(70)
                  anchors.verticalCenter: parent.verticalCenter
                  placeholderText: "year"
                  foreground: root.contentForeground
                  font.family: root.contentFontFamily
                  inputMethodHints: Qt.ImhDigitsOnly

                  Keys.onPressed: function(event) { root.handleLifeKey(event, expectancyField) }
                }

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.verticalCenterOffset: 0
                  leftPadding: Style.space(6)
                  text: "LIVE TO"
                  color: Qt.darker(root.contentForeground, 1.5)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.letterSpacing: 1
                }

                TextField {
                  id: expectancyField
                  width: Style.space(60)
                  anchors.verticalCenter: parent.verticalCenter
                  placeholderText: "90"
                  foreground: root.contentForeground
                  font.family: root.contentFontFamily
                  inputMethodHints: Qt.ImhDigitsOnly

                  Keys.onPressed: function(event) { root.handleLifeKey(event, bornField) }
                }
              }

              Text {
                id: yearLabel
                visible: !root.editingLife
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: root.today.getFullYear()
                color: Qt.darker(root.contentForeground, 1.5)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
                font.letterSpacing: 1
              }

              Text {
                id: yearPercent
                visible: !root.editingLife
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: root.yearDonePercent + "%"
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Rectangle {
                id: yearTrack
                visible: !root.editingLife
                anchors.left: yearLabel.right
                anchors.right: yearPercent.left
                anchors.leftMargin: Style.space(12)
                anchors.rightMargin: Style.space(12)
                anchors.verticalCenter: parent.verticalCenter
                height: Style.space(6)
                radius: Style.cornerRadius > 0 ? height / 2 : 0
                color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.12)

                Rectangle {
                  width: Math.round(parent.width * root.yearDone)
                  height: parent.height
                  radius: parent.radius
                  color: Style.selectedStateColor(root.contentForeground, Color.accent)

                  Behavior on width { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                }
              }
            }
          }

          // ---- Memento mori. Only here once someone has gone looking and
          //      given an age; the same rail as the year above it, measured
          //      against a nominal lifetime.
          Item {
            visible: root.birthYear > 0
            width: parent.width
            height: visible ? lifeBlock.height : 0

            Item {
              id: lifeBlock
              anchors.horizontalCenter: parent.horizontalCenter
              width: gridColumn.width
              height: Math.max(lifeLabel.implicitHeight, Style.space(10))

              Text {
                id: lifeLabel
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: "LIFE"
                color: Qt.darker(root.contentForeground, 1.5)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
                font.letterSpacing: 1
              }

              Text {
                id: lifePercent
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: root.lifeDonePercent + "%"
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Rectangle {
                anchors.left: lifeLabel.right
                anchors.right: lifePercent.left
                anchors.leftMargin: Style.space(12)
                anchors.rightMargin: Style.space(12)
                anchors.verticalCenter: parent.verticalCenter
                height: Style.space(6)
                radius: Style.cornerRadius > 0 ? height / 2 : 0
                color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.12)

                Rectangle {
                  width: Math.round(parent.width * root.lifeDone)
                  height: parent.height
                  radius: parent.radius
                  color: Style.selectedStateColor(root.contentForeground, Color.accent)

                  Behavior on width { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                }
              }

              TapHandler {
                onDoubleTapped: root.clearLife()
              }

              MouseArea {
                id: lifeMouse
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.NoButton

                PanelToolTip {
                  visible: lifeMouse.containsMouse
                  text: "Memento Mori"
                  fontFamily: root.contentFontFamily
                }
              }
            }
          }

          // ---- Month grid: week numbers down a gutter on the left, then
          //      the seven day columns. Always six rows, so the popup is
          //      exactly as tall in February as it is in August.
          Item {
            width: parent.width
            height: gridColumn.y + gridColumn.height

            WheelHandler {
              onWheel: function(event) {
                // Horizontal wheels and touchpad side-scrolls report y === 0;
                // without this they would every one read as "next month".
                if (event.angleDelta.y === 0) return
                root.moveMonth(event.angleDelta.y > 0 ? -1 : 1)
              }
            }

            Column {
              id: gridColumn
              // The meter above is a solid rule; the grid needs room to
              // read as its own block rather than hanging off it.
              y: Style.space(18)
              anchors.horizontalCenter: parent.horizontalCenter
              spacing: Style.space(3)

              Row {
                id: headerRow
                spacing: root.cellSpacing

                // The week-number heading doubles as the week-start toggle.
                // It is the one control in the panel whose meaning is not
                // self-evident, so it carries a tooltip naming the day the
                // click will switch to.
                Rectangle {
                  width: root.weekColumnWidth
                  height: Style.space(16)
                  radius: Style.cornerRadius
                  color: weekStartMouse.containsMouse
                    ? Style.hoverFillFor(root.contentForeground, Color.accent)
                    : "transparent"

                  Text {
                    anchors.centerIn: parent
                    text: "W"
                    color: weekStartMouse.containsMouse
                      ? Style.hoverStateColor(root.contentForeground, Color.accent)
                      : Qt.darker(root.contentForeground, 1.9)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                    font.letterSpacing: 1
                    font.bold: true
                  }

                  MouseArea {
                    id: weekStartMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.toggleWeekStart()
                  }

                  PanelToolTip {
                    visible: weekStartMouse.containsMouse
                    text: "Start weeks on " + root.nextWeekStartLabel
                    fontFamily: root.contentFontFamily
                  }
                }

                Item {
                  width: root.gutterWidth
                  height: Style.space(16)
                }

                Repeater {
                  model: root.weekdays

                  Text {
                    required property var modelData
                    width: root.cellWidth
                    height: Style.space(16)
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    text: root.weekdayLabel(modelData)
                    color: Qt.darker(root.contentForeground, 1.5)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                    font.letterSpacing: 1
                    font.bold: true
                  }
                }
              }

              Repeater {
                model: root.weeks

                Row {
                  required property var modelData
                  spacing: root.cellSpacing

                  Text {
                    width: root.weekColumnWidth
                    height: root.cellHeight
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    text: modelData.week
                    color: Qt.darker(root.contentForeground, 1.9)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                  }

                  Item {
                    width: root.gutterWidth
                    height: root.cellHeight
                  }

                  Repeater {
                    model: modelData.days

                    Rectangle {
                      id: dayCell
                      required property var modelData

                      readonly property bool selected: modelData.key === root.selectedKey
                      readonly property var marks: root.eventMarks[modelData.key] || []
                      readonly property int eventCount: dayCell.marks.length

                      width: root.cellWidth
                      height: root.cellHeight
                      radius: Style.cornerRadius
                      // Today is outlined, not filled: a lit-up block shouts
                      // over a grid this quiet. The day being read below the
                      // grid is the filled one, so the two marks never say
                      // the same thing twice. On most days today is both.
                      color: dayCell.selected
                        ? Style.selectedFillFor(root.contentForeground, Color.accent)
                        : (dayMouse.containsMouse
                          ? Style.hoverFillFor(root.contentForeground, Color.accent)
                          : "transparent")
                      border.width: modelData.today ? Style.spacing.hairline : 0
                      border.color: Style.normalBorderFor(root.contentForeground, Color.accent)

                      Text {
                        id: dayNumber
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.verticalCenterOffset: -root.dotRailOffset
                        text: dayCell.modelData.day
                        color: dayCell.modelData.inMonth
                          ? (dayCell.modelData.weekend ? Qt.darker(root.contentForeground, 1.45) : root.contentForeground)
                          : Qt.darker(root.contentForeground, 2.2)
                        font.family: root.contentFontFamily
                        font.pixelSize: Style.font.body
                        font.bold: dayCell.modelData.today
                      }

                      // ---- One dot per event, capped at three. Past that a
                      //      row of dots stops being countable and turns into
                      //      texture; the exact number is one click away in
                      //      the list below.
                      Row {
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.top: dayNumber.bottom
                        anchors.topMargin: Style.space(2)
                        spacing: Style.space(2)
                        visible: dayCell.eventCount > 0

                        Repeater {
                          model: Events.dotColors(dayCell.marks, 3)

                          Rectangle {
                            // The dot's own colour, shadowing the day the
                            // cell around it is built from.
                            required property var modelData

                            width: Style.space(3)
                            height: width
                            radius: width / 2
                            color: root.calendarColor(modelData)
                            // Days spilling in from the neighbouring months
                            // are dimmed in the grid; their dots follow.
                            opacity: dayCell.modelData.inMonth ? 0.9 : 0.35
                          }
                        }
                      }

                      MouseArea {
                        id: dayMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.selectDay(dayCell.modelData)
                      }
                    }
                  }
                }
              }
            }

            // Hairline down the week-number gutter, drawn only beside the
            // day rows so it does not cut through the header band.
            Rectangle {
              x: gridColumn.x + root.weekColumnWidth + root.cellSpacing + Math.round((root.gutterWidth - width) / 2)
              y: gridColumn.y + headerRow.height + gridColumn.spacing
              width: Style.spacing.hairline
              height: gridColumn.height - headerRow.height - gridColumn.spacing
              color: root.contentForeground
              opacity: 0.1
            }
          }

          // ---- Month stepping, spanning the grid it drives. The chevrons
          //      sit on the grid's outer bounds, the same edges the year
          //      rail above uses, so the row reads as the panel's other
          //      full-width rail instead of a cluster floating in space.
          //      The label is centered and fixed-width, so it holds still
          //      from "MAY" to "SEPTEMBER".
          Item {
            width: parent.width
            height: monthNav.height

            Item {
              id: monthNav
              anchors.horizontalCenter: parent.horizontalCenter
              width: gridColumn.width
              height: monthLabel.implicitHeight + Style.space(10)

              Text {
                id: monthLabel
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.verticalCenter: parent.verticalCenter
                // Fixed width so the chevrons hold still between a
                // "MAY 2026" and a "SEPTEMBER 2026".
                width: Style.space(130)
                horizontalAlignment: Text.AlignHCenter
                text: Qt.formatDate(root.viewDate, "MMMM yyyy").toUpperCase()
                color: Qt.darker(root.contentForeground, 1.4)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.body
                font.letterSpacing: 1
              }

              PanelActionButton {
                // Pulled out by the button's own padding so the glyph, not
                // its hit box, lines up with the "2026" on the year rail.
                anchors.left: parent.left
                anchors.leftMargin: -Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                iconText: "󰅁"
                tooltipText: "Previous month"
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                onClicked: root.moveMonth(-1)
              }

              PanelActionButton {
                anchors.right: parent.right
                anchors.rightMargin: -Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                iconText: "󰅂"
                tooltipText: "Next month"
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                onClicked: root.moveMonth(1)
              }
            }
          }

          // ---- What is on. The grid answers "what is the date"; this
          //      answers "what do I have", which is the other half of what a
          //      click on a clock is asking. The panel takes its height from
          //      this column, so it simply grows a line per event rather
          //      than scrolling a fixed-height box.
          Item {
            width: parent.width
            height: eventsBlock.y + eventsBlock.height

            Column {
              id: eventsBlock
              y: Style.space(10)
              anchors.horizontalCenter: parent.horizontalCenter
              width: gridColumn.width
              spacing: Style.space(7)

              // The same hairline the year rail draws, marking this off as
              // its own block rather than more of the grid.
              Rectangle {
                width: parent.width
                height: Style.spacing.hairline
                color: root.contentForeground
                opacity: 0.1
              }

              Item {
                width: parent.width
                height: Math.max(eventsHeading.implicitHeight, Style.space(12))

                Text {
                  id: eventsHeading
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  // "TODAY" rather than the date, because that is the one
                  // day you never have to look up.
                  text: root.selectedIsToday
                    ? "TODAY"
                    : Qt.formatDate(root.selectedDate, "dddd d MMMM").toUpperCase()
                  color: Qt.darker(root.contentForeground, 1.5)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.letterSpacing: 1
                }

                Text {
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  text: Events.summaryLabel(root.selectedEvents.length)
                  color: root.contentForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.bodySmall
                }
              }

              Repeater {
                model: root.selectedEvents

                Item {
                  id: eventRow
                  required property var modelData

                  readonly property bool ongoing: Events.isOngoing(eventRow.modelData, root.nowMs)
                  readonly property bool past: Events.isPast(eventRow.modelData, root.nowMs)
                  // iCloud's own calendar colour where it gave one, so work
                  // and home are told apart the same way they are on the
                  // phone; the accent stands in when it did not.
                  readonly property color tint: root.calendarColor(eventRow.modelData.calendar)
                  readonly property bool expanded: root.expandedEvent === Events.eventKey(eventRow.modelData)

                  width: eventsBlock.width
                  height: Math.max(eventTime.implicitHeight, eventTextColumn.implicitHeight)
                  // Finished events step back rather than vanish: the day
                  // still reads as a whole, but what is left of it leads.
                  // An expanded row is never dimmed: you opened it, so it is
                  // the thing you are reading regardless of whether it is over.
                  opacity: (eventRow.past && !eventRow.expanded) ? 0.45 : 1

                  // Drawn behind the content and bled past it, so the
                  // highlight has margins the text layout does not need.
                  Rectangle {
                    anchors.fill: parent
                    anchors.leftMargin: -Style.space(6)
                    anchors.rightMargin: -Style.space(6)
                    anchors.topMargin: -Style.space(3)
                    anchors.bottomMargin: -Style.space(3)
                    radius: Style.cornerRadius
                    color: eventRow.expanded
                      ? Style.selectedFillFor(root.contentForeground, Color.accent)
                      : (eventMouse.containsMouse
                        ? Style.hoverFillFor(root.contentForeground, Color.accent)
                        : "transparent")
                  }

                  // Behind the content rather than over it: plain text does
                  // not consume clicks, so the row still toggles wherever you
                  // press it, while the address above can claim its own.
                  MouseArea {
                    id: eventMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.toggleEventDetail(eventRow.modelData)
                  }

                  Text {
                    id: eventTime
                    anchors.left: parent.left
                    // Sitting on the title's baseline rather than its box:
                    // the two run at different sizes, and matching the boxes
                    // leaves the time visibly high against the words.
                    // Anchors cannot cross into the column, so this is the
                    // same alignment done as a binding.
                    y: eventTextColumn.y + eventTitle.y
                      + eventTitle.baselineOffset - eventTime.baselineOffset
                    // Fixed width so the titles line up whatever the time
                    // says, but left-aligned so the times start on the same
                    // edge as the "TODAY" heading above them.
                    width: Style.space(56)
                    horizontalAlignment: Text.AlignLeft
                    text: Events.timeLabel(eventRow.modelData, root.selectedKey)
                    color: eventRow.ongoing
                      ? Style.selectedStateColor(root.contentForeground, Color.accent)
                      : Qt.darker(root.contentForeground, 1.5)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.bold: eventRow.ongoing
                  }

                  Rectangle {
                    id: eventStripe
                    anchors.left: eventTime.right
                    anchors.leftMargin: Style.space(10)
                    anchors.top: parent.top
                    anchors.topMargin: Style.space(3)
                    width: Style.space(2)
                    height: Math.max(Style.space(6), eventTextColumn.implicitHeight - Style.space(5))
                    radius: Style.cornerRadius > 0 ? width / 2 : 0
                    color: eventRow.tint
                  }

                  Column {
                    id: eventTextColumn
                    anchors.left: eventStripe.right
                    anchors.leftMargin: Style.space(9)
                    anchors.right: parent.right
                    anchors.top: parent.top
                    spacing: Style.space(1)

                    Text {
                      id: eventTitle
                      width: parent.width
                      text: eventRow.modelData.summary
                      color: root.contentForeground
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.body
                      // Collapsed, a row must stay one line or the day stops
                      // being scannable. Expanded, the whole title is the
                      // reason you opened it.
                      elide: eventRow.expanded ? Text.ElideNone : Text.ElideRight
                      wrapMode: eventRow.expanded ? Text.WordWrap : Text.NoWrap
                    }

                    Text {
                      id: eventLocation
                      width: parent.width
                      visible: eventRow.modelData.location !== ""
                      text: eventRow.modelData.location
                      // Underlined only once the row is open, so a closed
                      // list stays quiet and the affordance appears exactly
                      // where it can be used.
                      color: (eventRow.expanded && locationMouse.containsMouse)
                        ? Style.hoverStateColor(root.contentForeground, Color.accent)
                        : Qt.darker(root.contentForeground, 1.8)
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.caption
                      font.underline: eventRow.expanded && locationMouse.containsMouse
                      elide: eventRow.expanded ? Text.ElideNone : Text.ElideRight
                      wrapMode: eventRow.expanded ? Text.WordWrap : Text.NoWrap

                      MouseArea {
                        id: locationMouse
                        anchors.fill: parent
                        enabled: eventRow.expanded
                        hoverEnabled: enabled
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.openMap(eventRow.modelData.location)
                      }

                      PanelToolTip {
                        visible: locationMouse.containsMouse
                        text: "Open in maps"
                        fontFamily: root.contentFontFamily
                      }
                    }

                    // ---- The half the list leaves out. The row shows when
                    //      something starts, because that is what you scan a
                    //      day by; this is when it ends, whose calendar it is
                    //      on, and whatever notes came with it.
                    Column {
                      width: parent.width
                      visible: eventRow.expanded
                      topPadding: visible ? Style.space(4) : 0
                      spacing: Style.space(2)

                      Text {
                        width: parent.width
                        text: Events.timeRange(eventRow.modelData)
                          + (Events.spansDays(eventRow.modelData)
                            ? "   " + Qt.formatDate(Events.startDate(eventRow.modelData), "d MMM")
                              + " – " + Qt.formatDate(Events.displayEndDate(eventRow.modelData), "d MMM")
                            : "")
                        color: Qt.darker(root.contentForeground, 1.3)
                        font.family: root.contentFontFamily
                        font.pixelSize: Style.font.bodySmall
                      }

                      Text {
                        width: parent.width
                        text: root.displayName(eventRow.modelData.calendar)
                        color: eventRow.tint
                        font.family: root.contentFontFamily
                        font.pixelSize: Style.font.caption
                        elide: Text.ElideRight
                      }

                      Text {
                        width: parent.width
                        visible: eventRow.modelData.description !== ""
                        topPadding: visible ? Style.space(3) : 0
                        text: eventRow.modelData.description
                        color: Qt.darker(root.contentForeground, 1.8)
                        font.family: root.contentFontFamily
                        font.pixelSize: Style.font.caption
                        wrapMode: Text.WordWrap
                      }

                      // Last in the block, whatever the block holds. Notes
                      // vary in length, so anchoring it to the calendar line
                      // put it in a different place on every event; the
                      // bottom right corner is always the bottom right.
                      Item {
                        width: parent.width
                        visible: root.canDelete(eventRow.modelData)
                        height: deleteAction.implicitHeight + Style.space(4)

                        // Two presses, not one. The first says what the
                        // second will do, and a repeating event says that it
                        // takes the whole series with it, because deleting by
                        // UID cannot take anything less.
                        Text {
                          id: deleteAction
                          anchors.right: parent.right
                          anchors.bottom: parent.bottom
                          text: root.deleting
                            ? "Deleting…"
                            : (root.deleteArmed === Events.eventKey(eventRow.modelData)
                              ? (eventRow.modelData.recurring ? "Delete every one?" : "Delete?")
                              : "Delete")
                          color: (deleteMouse.containsMouse
                            || root.deleteArmed === Events.eventKey(eventRow.modelData))
                            ? Style.hoverStateColor(root.contentForeground, Color.accent)
                            : Qt.darker(root.contentForeground, 2.1)
                          font.family: root.contentFontFamily
                          font.pixelSize: Style.font.caption

                          MouseArea {
                            id: deleteMouse
                            anchors.fill: parent
                            anchors.margins: -Style.space(5)
                            hoverEnabled: true
                            enabled: !root.deleting
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.requestDelete(eventRow.modelData)
                          }

                          PanelToolTip {
                            visible: deleteMouse.containsMouse
                              && root.deleteArmed !== Events.eventKey(eventRow.modelData)
                            text: eventRow.modelData.recurring
                              ? "Remove this event and every repeat of it"
                              : "Remove this event from the calendar"
                            fontFamily: root.contentFontFamily
                          }
                        }
                      }
                    }
                  }

                }
              }

              // ---- Nothing to list, and why. Three different reasons with
              //      three different things to do about them, so they are not
              //      collapsed into one apologetic sentence.

              // The packages are not something the plugin can install for
              // itself, so it prints the exact line to paste.
              Column {
                width: parent.width
                visible: root.missingPackages.length > 0
                spacing: Style.space(3)

                Text {
                  width: parent.width
                  text: "Missing packages"
                  color: Qt.darker(root.contentForeground, 1.3)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.bodySmall
                }

                Text {
                  width: parent.width
                  text: "omarchy pkg add " + root.missingPackages.join(" ")
                  color: Qt.darker(root.contentForeground, 1.8)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  // Break between package names, not inside them. A command
                  // meant to be read and retyped must not split a word.
                  wrapMode: Text.Wrap
                }
              }

              // ---- Signing in. The panel asks for it directly rather than
              //      sending anyone to a terminal, because "install it and
              //      log in" should be the whole of the setup.
              Column {
                width: parent.width
                visible: root.signInVisible
                spacing: Style.space(5)

                // Above the fields, not below them: you need the password in
                // hand before there is anything to type, so instructions
                // underneath arrive a step too late.
                Text {
                  width: parent.width
                  text: "CONNECT ICLOUD"
                  color: Qt.darker(root.contentForeground, 1.5)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  font.letterSpacing: 1
                }

                Text {
                  width: parent.width
                  // The reason, because "not your normal password" reads as
                  // an arbitrary rule without it.
                  text: "Apple has no browser sign-in for calendars, and CalDAV has "
                    + "nowhere to type a two-factor code. So it needs a password made "
                    + "for this one purpose. It is revocable on its own, and useless anywhere else."
                  color: Qt.darker(root.contentForeground, 1.75)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }

                Item {
                  width: parent.width
                  height: appleLinkRow.implicitHeight + Style.space(12)

                  Rectangle {
                    anchors.fill: parent
                    radius: Style.cornerRadius
                    color: appleLinkMouse.containsMouse
                      ? Style.hoverFillFor(root.contentForeground, Color.accent)
                      : Style.normalFillFor(root.contentForeground, Color.accent)
                  }

                  Column {
                    id: appleLinkRow
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: Style.space(11)
                    anchors.rightMargin: Style.space(11)
                    spacing: Style.space(2)

                    Text {
                      width: parent.width
                      text: "1.  Open account.apple.com and sign in"
                      color: root.contentForeground
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.caption
                      wrapMode: Text.WordWrap
                    }

                    Text {
                      width: parent.width
                      text: "2.  Go to App-Specific Passwords"
                      color: root.contentForeground
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.caption
                      wrapMode: Text.WordWrap
                    }

                    Text {
                      width: parent.width
                      text: "3.  Add one, name it Omarchy, copy the code below"
                      color: root.contentForeground
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.caption
                      wrapMode: Text.WordWrap
                    }
                  }

                  // The whole block opens the page: the first step is a trip
                  // to a browser either way, so it may as well be one click.
                  MouseArea {
                    id: appleLinkMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                      appleLinkProcess.command = ["xdg-open", "https://account.apple.com"]
                      appleLinkProcess.running = true
                    }
                  }

                  PanelToolTip {
                    visible: appleLinkMouse.containsMouse
                    text: "Open account.apple.com"
                    fontFamily: root.contentFontFamily
                  }
                }

                TextField {
                  id: appleIdField
                  width: parent.width
                  placeholderText: "Apple ID"
                  foreground: root.contentForeground
                  font.family: root.contentFontFamily
                  Keys.onPressed: function(event) {
                    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                        || event.key === Qt.Key_Tab) {
                      passwordField.forceActiveFocus()
                      event.accepted = true
                    }
                  }
                }

                TextField {
                  id: passwordField
                  width: parent.width
                  placeholderText: "App-specific password"
                  password: true
                  foreground: root.contentForeground
                  font.family: root.contentFontFamily
                  Keys.onPressed: function(event) {
                    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                      root.signIn()
                      event.accepted = true
                    }
                  }
                }

                Item {
                  width: parent.width
                  height: signInLabel.implicitHeight

                  Text {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - signInLabel.width - Style.space(10)
                    elide: Text.ElideRight
                    text: root.signingIn
                      ? "Signing in…"
                      : (root.signInError !== "" ? root.signInError : "Not your Apple password")
                    color: root.signInError !== ""
                      ? Qt.darker(root.contentForeground, 1.3)
                      : Qt.darker(root.contentForeground, 2.0)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                  }

                  Text {
                    id: signInLabel
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Sign in"
                    color: signInMouse.containsMouse
                      ? Style.hoverStateColor(root.contentForeground, Color.accent)
                      : root.contentForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.bodySmall

                    MouseArea {
                      id: signInMouse
                      anchors.fill: parent
                      anchors.margins: -Style.space(4)
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.signIn()
                    }
                  }
                }

                // An account is not actually required, since a subscribed
                // feed works on its own, but the form above says otherwise by
                // being the only thing on offer. So it says so.
                Text {
                  width: parent.width
                  text: "Or skip this: + below subscribes to a calendar feed, no account needed"
                  color: Qt.darker(root.contentForeground, 2.1)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }
              }

              Text {
                visible: !root.signInVisible && root.missingPackages.length === 0
                  && root.selectedEvents.length === 0
                width: parent.width
                text: root.statusMessage
                color: Qt.darker(root.contentForeground, 1.9)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
              }

              // Its own line, shown whether or not the day has anything on
              // it: what is on screen is the last calendar that arrived, and
              // saying nothing would let it quietly go stale.
              Text {
                visible: root.syncTrouble !== "" && !root.signInVisible
                  && root.missingPackages.length === 0
                width: parent.width
                text: "Last sync: " + root.syncTrouble
                color: Qt.darker(root.contentForeground, 1.5)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }

              // ---- Adding one. The grid is the date picker: the day you
              //      are looking at is the day it lands on, so the form asks
              //      only for what the calendar cannot already tell it.
              Item {
                width: parent.width
                height: composeAction.implicitHeight + Style.space(4)
                visible: !root.signInVisible && root.missingPackages.length === 0
                  && root.writableCalendars.length > 0

                Text {
                  id: composeAction
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.composing ? "× Cancel" : "+ New event"
                  color: composeMouse.containsMouse || root.composing
                    ? Style.hoverStateColor(root.contentForeground, Color.accent)
                    : Qt.darker(root.contentForeground, 1.9)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption

                  MouseArea {
                    id: composeMouse
                    anchors.fill: parent
                    anchors.margins: -Style.space(5)
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                      if (root.composing) root.cancelComposing()
                      else root.startComposing()
                    }
                  }
                }
              }

              Column {
                width: parent.width
                visible: root.composing
                spacing: Style.space(5)

                TextField {
                  id: titleField
                  width: parent.width
                  placeholderText: "Title"
                  foreground: root.contentForeground
                  font.family: root.contentFontFamily
                  Keys.onPressed: function(event) {
                    if (event.key === Qt.Key_Escape) { root.cancelComposing(); event.accepted = true }
                    else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                      root.createEvent(); event.accepted = true
                    }
                  }
                }

                TextField {
                  id: placeField
                  width: parent.width
                  placeholderText: "Place"
                  foreground: root.contentForeground
                  font.family: root.contentFontFamily
                  Keys.onPressed: function(event) {
                    if (event.key === Qt.Key_Escape) { root.cancelComposing(); event.accepted = true }
                  }
                }

                TextField {
                  id: notesField
                  width: parent.width
                  placeholderText: "Notes"
                  foreground: root.contentForeground
                  font.family: root.contentFontFamily
                  Keys.onPressed: function(event) {
                    if (event.key === Qt.Key_Escape) { root.cancelComposing(); event.accepted = true }
                  }
                }

                // ---- When. The date is the day the grid is showing, stated
                //      rather than asked for, so there is one less thing to
                //      type and no second place for it to disagree.
                Row {
                  width: parent.width
                  spacing: Style.space(8)

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(74)
                    text: Qt.formatDate(root.selectedDate, "d MMM").toUpperCase()
                    color: Qt.darker(root.contentForeground, 1.4)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                    font.letterSpacing: 1
                  }

                  TextField {
                    id: startField
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(62)
                    enabled: !root.allDayBox
                    opacity: enabled ? 1 : 0.4
                    placeholderText: "09:00"
                    foreground: root.contentForeground
                    font.family: root.contentFontFamily
                    // Retyping the end every time the start moves is busywork,
                    // so it follows along until it is set by hand.
                    onEditingFinished: {
                      var tidy = Events.normalizeClock(startField.text)
                      if (tidy !== "") startField.text = tidy
                      if (!Events.endsAfterStart(startField.text, endField.text))
                        endField.text = Events.shiftClock(startField.text, 60)
                    }
                  }

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "→"
                    color: Qt.darker(root.contentForeground, 1.9)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                    opacity: root.allDayBox ? 0.4 : 1
                  }

                  TextField {
                    id: endField
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(62)
                    enabled: !root.allDayBox
                    opacity: enabled ? 1 : 0.4
                    placeholderText: "10:00"
                    foreground: root.contentForeground
                    font.family: root.contentFontFamily
                    onEditingFinished: {
                      var tidy = Events.normalizeClock(endField.text)
                      if (tidy !== "") endField.text = tidy
                    }
                  }

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: !root.allDayBox
                      && Events.crossesMidnight(startField.text, endField.text)
                    text: "+1"
                    color: Qt.darker(root.contentForeground, 1.5)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption

                    MouseArea {
                      id: nextDayMouse
                      anchors.fill: parent
                      anchors.margins: -Style.space(3)
                      hoverEnabled: true
                    }

                    PanelToolTip {
                      visible: nextDayMouse.containsMouse
                      text: "Ends the next day"
                      fontFamily: root.contentFontFamily
                    }
                  }

                  // The click target is a sibling of the row rather than a
                  // child of it: a positioner refuses to lay out anything
                  // anchored, and silently stops laying out the rest too.
                  Item {
                    anchors.verticalCenter: parent.verticalCenter
                    width: allDayRow.width
                    height: allDayRow.height

                    Row {
                      id: allDayRow
                      spacing: Style.space(5)

                      Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: Style.space(11)
                        height: width
                        radius: Style.cornerRadius > 0 ? Style.space(3) : 0
                        color: root.allDayBox
                          ? Style.selectedStateColor(root.contentForeground, Color.accent)
                          : "transparent"
                        border.width: root.allDayBox ? 0 : Style.spacing.hairline
                        border.color: Qt.darker(root.contentForeground, 1.7)
                      }

                      Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "All day"
                        color: allDayMouse.containsMouse
                          ? Style.hoverStateColor(root.contentForeground, Color.accent)
                          : Qt.darker(root.contentForeground, 1.6)
                        font.family: root.contentFontFamily
                        font.pixelSize: Style.font.caption
                      }
                    }

                    MouseArea {
                      id: allDayMouse
                      anchors.fill: parent
                      anchors.margins: -Style.space(4)
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.allDayBox = !root.allDayBox
                    }
                  }
                }

                // ---- Which calendar, and the button. Only the writable ones
                //      are offered, so there is no way to pick a place the
                //      event cannot go.
                Item {
                  width: parent.width
                  height: Math.max(composeCalendars.implicitHeight, createButton.implicitHeight)

                  Flow {
                    id: composeCalendars
                    anchors.left: parent.left
                    anchors.right: createButton.left
                    anchors.rightMargin: Style.space(12)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(10)

                    Repeater {
                      model: root.writableCalendars

                      Item {
                        id: pick
                        required property var modelData
                        readonly property bool chosen: String(pick.modelData) === root.composeCalendarName
                        width: pickRow.width
                        height: pickRow.height

                        Row {
                          id: pickRow
                          spacing: Style.space(5)

                          Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            width: Style.space(6)
                            height: width
                            radius: width / 2
                            color: pick.chosen ? root.calendarColor(pick.modelData) : "transparent"
                            border.width: pick.chosen ? 0 : Style.spacing.hairline
                            border.color: root.calendarColor(pick.modelData)
                          }

                          Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: root.displayName(pick.modelData)
                            color: pick.chosen
                              ? root.contentForeground
                              : Qt.darker(root.contentForeground, 2.1)
                            font.family: root.contentFontFamily
                            font.pixelSize: Style.font.caption
                          }
                        }

                        MouseArea {
                          anchors.fill: parent
                          anchors.margins: -Style.space(4)
                          cursorShape: Qt.PointingHandCursor
                          onClicked: root.composeCalendar = String(pick.modelData)
                        }
                      }
                    }
                  }

                  Text {
                    id: createButton
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.creating ? "Creating…" : "Create"
                    color: createMouse.containsMouse
                      ? Style.hoverStateColor(root.contentForeground, Color.accent)
                      : root.contentForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.bold: true

                    MouseArea {
                      id: createMouse
                      anchors.fill: parent
                      anchors.margins: -Style.space(5)
                      hoverEnabled: true
                      enabled: !root.creating
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.createEvent()
                    }
                  }
                }

                Text {
                  width: parent.width
                  visible: root.composeError !== ""
                  text: root.composeError
                  color: Qt.darker(root.contentForeground, 1.3)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }
              }

              // ---- Calendars, doubling as the legend and the switches.
              //      A single calendar has nothing to toggle between, so the
              //      row only earns its space once there are two.
              Item {
                width: parent.width
                height: calendarFlow.implicitHeight

                Flow {
                  id: calendarFlow
                  anchors.left: parent.left
                  anchors.right: accountAction.left
                  anchors.rightMargin: Style.space(12)
                  width: parent.width
                  // Always present, even with a single calendar or none at
                  // all: subscribing does not depend on the iCloud account, so
                  // the "+" has to be reachable before there is anything to
                  // switch between.
                  height: implicitHeight
                  spacing: Style.space(12)
                  topPadding: Style.space(2)

                  Repeater {
                    model: root.calendars

                    Item {
                      id: chip
                      required property var modelData

                      readonly property bool hidden: root.hiddenCalendars.indexOf(chip.modelData.name) !== -1

                      width: chipRow.width
                      height: root.calendarRowHeight

                      Row {
                        id: chipRow
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Style.space(5)

                        // Filled when the calendar is on, hollow when off:
                        // the same shape as the dots in the grid, so the row
                        // reads as a key to them rather than a separate idea.
                        Rectangle {
                          anchors.verticalCenter: parent.verticalCenter
                          width: Style.space(6)
                          height: width
                          radius: width / 2
                          color: chip.hidden ? "transparent" : root.calendarColor(chip.modelData.name)
                          border.width: chip.hidden ? Style.spacing.hairline : 0
                          border.color: root.calendarColor(chip.modelData.name)
                          opacity: chip.hidden ? 0.6 : 1
                        }

                        Text {
                          anchors.verticalCenter: parent.verticalCenter
                          text: root.displayName(chip.modelData.name)
                          color: chip.hidden
                            ? Qt.darker(root.contentForeground, 2.4)
                            : (chipMouse.containsMouse
                              ? Style.hoverStateColor(root.contentForeground, Color.accent)
                              : Qt.darker(root.contentForeground, 1.4))
                          font.family: root.contentFontFamily
                          font.pixelSize: Style.font.caption
                        }
                      }

                      MouseArea {
                        id: chipMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        acceptedButtons: Qt.LeftButton | Qt.RightButton
                        onClicked: function(mouse) {
                          if (mouse.button === Qt.RightButton) {
                            root.addMode = ""
                            // Right-clicking the open one puts the swatches away.
                            root.startEditingCalendar(chip.modelData.name)
                          } else {
                            root.toggleCalendar(chip.modelData.name)
                          }
                        }
                      }

                      PanelToolTip {
                        visible: chipMouse.containsMouse
                        text: (chip.hidden ? "Show this calendar" : "Hide this calendar")
                          + " · right-click to rename or recolour"
                        fontFamily: root.contentFontFamily
                      }
                    }
                  }

                  // ---- Subscribing to a feed. It sits at the end of the row
                  //      it adds to, so the place you manage calendars and the
                  //      place you gain one are the same place.
                  Item {
                    width: addLabel.width
                    height: root.calendarRowHeight

                    Text {
                      id: addLabel
                      anchors.verticalCenter: parent.verticalCenter
                      // With calendars beside it the glyph is enough; with
                      // none it would be a lone mark on an empty row, so it
                      // says what it does instead.
                      text: root.addingSubscription
                        ? "×"
                        : (root.calendars.length === 0 ? "+  Add a calendar" : "+")
                      color: addMouse.containsMouse || root.addingSubscription
                        ? Style.hoverStateColor(root.contentForeground, Color.accent)
                        : Qt.darker(root.contentForeground, 1.9)
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.body
                      font.bold: true
                    }

                    MouseArea {
                      id: addMouse
                      anchors.fill: parent
                      anchors.margins: -Style.space(4)
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: {
                        if (root.addingSubscription) root.cancelAddingSubscription()
                        else root.startAddingSubscription()
                      }
                    }

                    PanelToolTip {
                      visible: addMouse.containsMouse
                      text: root.addingSubscription ? "Cancel" : "Subscribe to a calendar"
                      fontFamily: root.contentFontFamily
                    }
                  }

                }

                // ---- The account action, pinned right so it lines up under
                //      the event count rather than trailing the calendars. It
                //      concerns the whole account rather than any one calendar,
                //      and the switches read cleaner without it among them.
                Text {
                  id: accountAction
                  anchors.right: parent.right
                  anchors.top: parent.top
                  anchors.topMargin: Style.space(2)
                  height: root.calendarRowHeight
                  verticalAlignment: Text.AlignVCenter
                  visible: root.configured
                  text: root.signedIn ? "Sign out" : (root.showSignIn ? "Cancel" : "Sign in")
                  color: accountMouse.containsMouse
                    ? Style.hoverStateColor(root.contentForeground, Color.accent)
                    : Qt.darker(root.contentForeground, 2.2)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption

                  MouseArea {
                    id: accountMouse
                    anchors.fill: parent
                    anchors.margins: -Style.space(5)
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                      if (root.signedIn) root.signOut()
                      else {
                        root.showSignIn = !root.showSignIn
                        root.signInError = ""
                      }
                    }
                  }

                  PanelToolTip {
                    visible: accountMouse.containsMouse
                    text: root.signedIn ? "Sign out of the account"
                      : "Connect an iCloud or CalDAV account"
                    fontFamily: root.contentFontFamily
                  }
                }
              }

              // ---- Swatches for one calendar. Subscribed feeds often ship
              //      no colour at all, or one that fights with everything
              //      else on the day, so they need to be assignable by hand.
              Column {
                width: parent.width
                visible: root.calendarEditing !== ""
                spacing: Style.space(5)

                // A feed that supplied no name of its own arrives as a
                // placeholder, so this is often the only way it gets called
                // anything useful. The original name stays the identity
                // underneath. This only changes what is printed.
                TextField {
                  id: nameField
                  width: parent.width
                  placeholderText: root.calendarEditing
                  foreground: root.contentForeground
                  font.family: root.contentFontFamily

                  Keys.onPressed: function(event) {
                    if (event.key === Qt.Key_Escape) {
                      root.calendarEditing = ""
                      Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
                      event.accepted = true
                    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                      root.closeCalendarEditor()
                      event.accepted = true
                    }
                  }
                }

              Row {
                width: parent.width
                spacing: Style.space(6)

                Repeater {
                  model: Events.palette()

                  Rectangle {
                    required property var modelData

                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(11)
                    height: width
                    radius: width / 2
                    color: String(modelData)
                    border.width: swatchMouse.containsMouse ? Style.spacing.hairline : 0
                    border.color: root.contentForeground

                    MouseArea {
                      id: swatchMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.setCalendarColor(root.calendarEditing, parent.modelData)
                    }
                  }
                }

                // Only where a local override is the whole story. On a
                // calendar the account owns the colour lives on the server,
                // so there is no separate original to go back to.
                Rectangle {
                  visible: !root.editingOwnCalendar
                  anchors.verticalCenter: parent.verticalCenter
                  width: visible ? Style.space(11) : 0
                  height: width
                  radius: width / 2
                  color: "transparent"
                  border.width: Style.spacing.hairline
                  border.color: resetMouse.containsMouse
                    ? Style.hoverStateColor(root.contentForeground, Color.accent)
                    : Qt.darker(root.contentForeground, 1.7)

                  MouseArea {
                    id: resetMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.setCalendarColor(root.calendarEditing, "")
                  }

                  PanelToolTip {
                    visible: resetMouse.containsMouse
                    text: "Use the colour the feed publishes"
                    fontFamily: root.contentFontFamily
                  }
                }

                Item { width: Style.space(4); height: 1 }

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  visible: root.colouring || root.colourError !== "" || root.editingOwnCalendar
                  text: root.colouring
                    ? "Saving…"
                    : (root.colourError !== "" ? root.colourError : "Syncs to your other devices")
                  color: root.colourError !== ""
                    ? Qt.darker(root.contentForeground, 1.3)
                    : Qt.darker(root.contentForeground, 2.1)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }

                Item { width: Style.space(10); height: 1 }

                // Done, for anyone who does not think to press Enter.
                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: "Done"
                  color: doneMouse.containsMouse
                    ? Style.hoverStateColor(root.contentForeground, Color.accent)
                    : Qt.darker(root.contentForeground, 1.9)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption

                  MouseArea {
                    id: doneMouse
                    anchors.fill: parent
                    anchors.margins: -Style.space(4)
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.closeCalendarEditor()
                  }
                }

              }

              // ---- Removing it. Two presses with the consequence spelled
              //      out in between, because this takes more than a colour
              //      with it and the two kinds of calendar lose different
              //      things.
              Item {
                width: parent.width
                height: calendarDeleteRow.implicitHeight

                Text {
                  id: calendarDeleteRow
                  anchors.left: parent.left
                  anchors.right: parent.right
                  text: root.deletingCalendar
                    ? "Removing…"
                    : (root.calendarDeleteArmed
                      ? root.calendarDeleteWarning
                      : (root.editedCalendar && root.editedCalendar.subscribed === true
                        ? "Stop following this feed"
                        : "Delete this calendar"))
                  color: root.calendarDeleteArmed
                    ? Qt.darker(root.contentForeground, 1.25)
                    : (calendarDeleteMouse.containsMouse
                      ? Style.hoverStateColor(root.contentForeground, Color.accent)
                      : Qt.darker(root.contentForeground, 2.1))
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }

                MouseArea {
                  id: calendarDeleteMouse
                  anchors.fill: parent
                  anchors.margins: -Style.space(4)
                  hoverEnabled: true
                  enabled: !root.deletingCalendar && !root.calendarDeleteArmed
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.calendarDeleteArmed = true
                }
              }

              // The two answers, offered only once the warning has been
              // read, and with the safe one first.
              Row {
                width: parent.width
                visible: root.calendarDeleteArmed
                spacing: Style.space(16)

                Text {
                  text: "Keep it"
                  color: keepMouse.containsMouse
                    ? Style.hoverStateColor(root.contentForeground, Color.accent)
                    : root.contentForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.bodySmall

                  MouseArea {
                    id: keepMouse
                    anchors.fill: parent
                    anchors.margins: -Style.space(5)
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.calendarDeleteArmed = false
                  }
                }

                Text {
                  text: root.editedCalendar && root.editedCalendar.subscribed === true
                    ? "Stop following it" : "Delete it"
                  color: confirmDeleteMouse.containsMouse
                    ? Style.hoverStateColor(root.contentForeground, Color.accent)
                    : Qt.darker(root.contentForeground, 1.6)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.bodySmall

                  MouseArea {
                    id: confirmDeleteMouse
                    anchors.fill: parent
                    anchors.margins: -Style.space(5)
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.deleteCalendar()
                  }
                }
              }
              }

              // ---- Which kind. Both end up in the calendar row beside the
              //      others, but one is made on your account and the other is
              //      somebody else's file, read from a URL.
              Row {
                width: parent.width
                visible: root.addMode === "choose"
                spacing: Style.space(16)

                Text {
                  text: "New calendar"
                  color: newCalMouse.containsMouse
                    ? Style.hoverStateColor(root.contentForeground, Color.accent)
                    : Qt.darker(root.contentForeground, 1.4)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.bodySmall

                  MouseArea {
                    id: newCalMouse
                    anchors.fill: parent
                    anchors.margins: -Style.space(5)
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.chooseAddMode("calendar")
                  }

                  PanelToolTip {
                    visible: newCalMouse.containsMouse
                    text: "Make one on your account, visible on every device"
                    fontFamily: root.contentFontFamily
                  }
                }

                Text {
                  text: "Subscribe to a feed"
                  color: feedMouse.containsMouse
                    ? Style.hoverStateColor(root.contentForeground, Color.accent)
                    : Qt.darker(root.contentForeground, 1.4)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.bodySmall

                  MouseArea {
                    id: feedMouse
                    anchors.fill: parent
                    anchors.margins: -Style.space(5)
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.chooseAddMode("feed")
                  }

                  PanelToolTip {
                    visible: feedMouse.containsMouse
                    text: "Read a webcal or .ics published somewhere else"
                    fontFamily: root.contentFontFamily
                  }
                }
              }

              // ---- Naming a new one. The colour is asked for here because
              //      it is the only thing worth deciding up front; the rest
              //      of what a calendar is, is what you put in it.
              Column {
                width: parent.width
                visible: root.addMode === "calendar"
                spacing: Style.space(5)

                TextField {
                  id: newCalendarField
                  width: parent.width
                  placeholderText: "Calendar name"
                  foreground: root.contentForeground
                  font.family: root.contentFontFamily
                  Keys.onPressed: function(event) {
                    if (event.key === Qt.Key_Escape) {
                      root.cancelAddingSubscription(); event.accepted = true
                    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                      root.createCalendar(); event.accepted = true
                    }
                  }
                }

                Item {
                  width: parent.width
                  height: Math.max(newCalSwatches.implicitHeight, makeButton.implicitHeight)

                  Row {
                    id: newCalSwatches
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(6)

                    Repeater {
                      model: Events.palette()

                      Rectangle {
                        id: newSwatch
                        required property var modelData
                        anchors.verticalCenter: parent.verticalCenter
                        width: Style.space(11)
                        height: width
                        radius: width / 2
                        color: String(newSwatch.modelData)
                        border.width: String(newSwatch.modelData) === root.newCalendarColour
                          ? Style.spacing.hairline : 0
                        border.color: root.contentForeground

                        MouseArea {
                          anchors.fill: parent
                          cursorShape: Qt.PointingHandCursor
                          onClicked: root.newCalendarColour = String(newSwatch.modelData)
                        }
                      }
                    }
                  }

                  Text {
                    id: makeButton
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.makingCalendar ? "Creating…" : "Create"
                    color: makeMouse.containsMouse
                      ? Style.hoverStateColor(root.contentForeground, Color.accent)
                      : root.contentForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.bold: true

                    MouseArea {
                      id: makeMouse
                      anchors.fill: parent
                      anchors.margins: -Style.space(5)
                      hoverEnabled: true
                      enabled: !root.makingCalendar
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.createCalendar()
                    }
                  }
                }

                Text {
                  width: parent.width
                  visible: root.subscribeError !== ""
                  text: root.subscribeError
                  color: Qt.darker(root.contentForeground, 1.3)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }
              }

              // ---- Pasting a feed URL, with the directions to find one.
              //      iCloud cannot supply these, so the panel has to say
              //      where they actually live.
              Column {
                width: parent.width
                visible: root.addMode === "feed"
                spacing: Style.space(4)

                TextField {
                  id: urlField
                  width: parent.width
                  placeholderText: "webcal://… or https://….ics"
                  foreground: root.contentForeground
                  font.family: root.contentFontFamily

                  Keys.onPressed: function(event) {
                    if (event.key === Qt.Key_Escape) {
                      root.cancelAddingSubscription()
                      event.accepted = true
                    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                      root.commitSubscription()
                      event.accepted = true
                    }
                  }
                }

                Text {
                  width: parent.width
                  text: root.subscribing
                    ? "Fetching…"
                    : (root.subscribeError !== ""
                      ? root.subscribeError
                      : "iPhone: Settings → Apps → Calendar → Accounts → Subscribed Calendars")
                  color: root.subscribeError !== ""
                    ? Qt.darker(root.contentForeground, 1.3)
                    : Qt.darker(root.contentForeground, 2.0)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }
              }

              // Only while both clocks are on the bar; taking the offer is
              // what makes it go away. It sits at the very foot of the panel
              // with a surface of its own. A one-time piece of setup should
              // be findable at a glance, and then gone for good.
              Rectangle {
                width: parent.width
                visible: root.builtinClockOnBar
                height: hideClockRow.implicitHeight + Style.space(18)
                radius: Style.cornerRadius
                color: hideClockMouse.containsMouse
                  ? Style.hoverFillFor(root.contentForeground, Color.accent)
                  : Style.normalFillFor(root.contentForeground, Color.accent)

                Item {
                  id: hideClockRow
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.space(11)
                  anchors.rightMargin: Style.space(11)
                  implicitHeight: Math.max(hideClockLabel.implicitHeight, hideClockAction.implicitHeight)

                  Text {
                    id: hideClockLabel
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - hideClockAction.width - Style.space(12)
                    elide: Text.ElideRight
                    text: "Omarchy's own clock is on the bar too"
                    color: Qt.darker(root.contentForeground, 1.2)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.bodySmall
                  }

                  Text {
                    id: hideClockAction
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Hide it"
                    color: Style.selectedStateColor(root.contentForeground, Color.accent)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.bold: true
                  }
                }

                // The whole strip takes the click, not just the two words:
                // a one-time action deserves a target you cannot miss.
                MouseArea {
                  id: hideClockMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.hideBuiltinClock()
                }

                PanelToolTip {
                  visible: hideClockMouse.containsMouse
                  text: "Take it off the bar. It stays installed"
                  fontFamily: root.contentFontFamily
                }
              }
            }
          }
        }
      }
    }
  }
}

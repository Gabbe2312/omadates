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
  // outlives a restart. Hiding is a display choice only — the events stay in
  // the cache, so switching one back on is instant.
  readonly property var hiddenCalendars: setting("hiddenCalendars", [])
  readonly property var calendars: Events.calendarsIn(cache.events)
  readonly property var sourceColors: Events.colorMap(cache.events)

  // Hand-picked colours, by calendar name. A display choice like hiding, so
  // it lives in shell.json next to it rather than in the sync config.
  readonly property var calendarColors: setting("calendarColors", ({}))

  // Names you have given a calendar yourself. Subscribed feeds often supply
  // none at all — the sync falls back to a placeholder — and Apple's own
  // names are not always what you would call them either.
  readonly property var calendarNames: setting("calendarNames", ({}))

  // Which event row is showing its details. One at a time: the point is to
  // look something up, not to unfold the whole day.
  property string expandedEvent: ""

  // The helper lives beside this file, wherever the plugin was installed —
  // there is nothing on PATH to rely on for a plugin someone downloaded.
  readonly property string pluginDir: String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "")
  readonly property var syncCommand: [root.pluginDir + "bin/icalendar-sync"]

  // Sign-in state. The password is held only between the click and the
  // helper reading it off stdin, and never touches disk on the way.
  property string pendingPassword: ""
  property bool signingIn: false
  property string signInError: ""

  readonly property bool configured: cache.configured === true
  readonly property var missingPackages: cache.missing instanceof Array ? cache.missing : []

  // Which calendar's swatches are open, and whether the URL field is up.
  // Only one of the two rows shows at a time — they occupy the same slot
  // under the calendar switches.
  property string calendarEditing: ""
  property bool addingSubscription: false
  property bool subscribing: false
  property string subscribeError: ""

  readonly property var events: Events.visibleEvents(cache.events, hiddenCalendars)
  readonly property var eventMarks: Events.marksByDay(events)
  readonly property bool cacheFailed: cache.status === "error"
  readonly property bool cacheMissing: cache.status === "empty"

  // The day the list below the grid is showing. Today until you click
  // another one — the question a calendar answers by default is "what is on
  // today", and everything else is a deliberate click away.
  property string selectedKey: todayKey
  onSelectedKeyChanged: root.expandedEvent = ""
  readonly property var selectedEvents: Events.eventsForDay(root.events, selectedKey)
  readonly property date selectedDate: Model.dateFromKey(selectedKey, today)
  readonly property bool selectedIsToday: selectedKey === todayKey

  // Minute-resolution now, so the event you are in the middle of stays
  // marked as it moves rather than only at the moment the panel opened.
  property double nowMs: new Date().getTime()

  // Only the ordinary outcomes. Never signed in and missing packages each
  // get their own block below, because each has a different next step.
  readonly property string statusMessage: root.cacheFailed
    ? (root.cache.error !== "" ? root.cache.error : "Calendar sync failed")
    : "Nothing scheduled"


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
  // same place whether the day has dots or not — toggling a calendar must not
  // make the whole grid twitch.
  readonly property int dotRailOffset: Style.space(3)

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
      if (root.opened && !root.configured && root.missingPackages.length === 0)
        appleIdField.forceActiveFocus()
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
    root.requestSync()
  }

  // A background sync, but only when the cache has actually gone stale.
  // Opening the panel repeatedly should not hammer iCloud, and the timer is
  // already covering the steady state.
  function requestSync() {
    if (syncProcess.running) return
    var syncedAt = Date.parse(String(root.cache.syncedAt || ""))
    if (isFinite(syncedAt) && (new Date().getTime() - syncedAt) < 300000) return
    syncProcess.running = true
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
    loginProcess.command = root.syncCommand.concat(["login", user])
    loginProcess.running = true
  }

  function signOut() {
    logoutProcess.command = root.syncCommand.concat(["logout"])
    logoutProcess.running = true
  }

  function startEditingCalendar(name) {
    var key = String(name || "")
    if (root.calendarEditing === key) {
      root.closeCalendarEditor()
      return
    }
    root.addingSubscription = false
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
    if (root.calendarEditing !== "") root.setCalendarName(root.calendarEditing, nameField.text)
    root.calendarEditing = ""
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  function toggleEventDetail(event) {
    var key = Events.eventKey(event)
    root.expandedEvent = root.expandedEvent === key ? "" : key
  }

  function startAddingSubscription() {
    root.calendarEditing = ""
    root.subscribeError = ""
    root.addingSubscription = true
    Qt.callLater(function() {
      urlField.text = ""
      urlField.forceActiveFocus()
    })
  }

  function cancelAddingSubscription() {
    root.addingSubscription = false
    root.subscribeError = ""
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  // The helper writes the subscription to calendar.json and re-runs the sync
  // itself, so the cache — and with it this panel — updates on its own.
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
    for (var s = 0; s < sections.length; s++) {
      var list = next.bar.layout[sections[s]]
      if (!(list instanceof Array)) continue
      var kept = []
      for (var i = 0; i < list.length; i++)
        if (!list[i] || String(list[i].id) !== "omarchy.clock") kept.push(list[i])
      next.bar.layout[sections[s]] = kept
    }
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
    path: Quickshell.env("HOME") + "/.cache/omarchy/icalendar/events.json"
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
        appleIdField.text = ""
        passwordField.text = ""
        Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
      } else {
        // Short enough to sit beside the button without being elided; the
        // line underneath already says where an app-specific password
        // comes from, so it does not need repeating here.
        root.signInError = "Sign-in failed — check both fields"
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
        root.subscribeError = "Could not add that calendar — check the URL"
      }
      calendarCache.reload()
    }
  }

  Process {
    id: syncProcess
    command: root.syncCommand
    // Nothing to do on exit: the sync rewrites the cache, and the FileView
    // above is already watching it.
  }

  Timer {
    // Fifteen minutes is roughly what a phone does, and opening the panel
    // refreshes a stale cache anyway, so this only covers the case where
    // nobody has looked at it in a while.
    interval: 15 * 60 * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.requestSync()
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
        || root.calendarEditing !== "" || !root.configured
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
            height: yearBlock.y + yearBlock.height

            Item {
              id: yearBlock
              y: Style.space(6)
              anchors.horizontalCenter: parent.horizontalCenter
              width: gridColumn.width
              height: Math.max(yearLabel.implicitHeight, Style.space(10))

              TapHandler {
                enabled: !root.editingLife
                onDoubleTapped: root.startEditingLife()
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
                      // the same thing twice — on most days today is both.
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
                      width: parent.width
                      visible: eventRow.modelData.location !== ""
                      height: visible ? implicitHeight : 0
                      text: eventRow.modelData.location
                      color: Qt.darker(root.contentForeground, 1.8)
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.caption
                      elide: eventRow.expanded ? Text.ElideNone : Text.ElideRight
                      wrapMode: eventRow.expanded ? Text.WordWrap : Text.NoWrap
                    }

                    // ---- The half the list leaves out. The row shows when
                    //      something starts, because that is what you scan a
                    //      day by; this is when it ends, whose calendar it is
                    //      on, and whatever notes came with it.
                    Column {
                      width: parent.width
                      visible: eventRow.expanded
                      height: visible ? implicitHeight : 0
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
                        height: visible ? implicitHeight : 0
                        topPadding: visible ? Style.space(3) : 0
                        text: eventRow.modelData.description
                        color: Qt.darker(root.contentForeground, 1.8)
                        font.family: root.contentFontFamily
                        font.pixelSize: Style.font.caption
                        wrapMode: Text.WordWrap
                      }
                    }
                  }

                  MouseArea {
                    id: eventMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.toggleEventDetail(eventRow.modelData)
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
                height: visible ? implicitHeight : 0
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
                  // Break between package names, not inside them — a command
                  // meant to be read and retyped must not split a word.
                  wrapMode: Text.Wrap
                }
              }

              // ---- Signing in. The panel asks for it directly rather than
              //      sending anyone to a terminal, because "install it and
              //      log in" should be the whole of the setup.
              Column {
                width: parent.width
                visible: !root.configured && root.missingPackages.length === 0
                height: visible ? implicitHeight : 0
                spacing: Style.space(5)

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

                Text {
                  width: parent.width
                  text: "Create one at account.apple.com → Sign-In and Security → App-Specific Passwords"
                  color: Qt.darker(root.contentForeground, 2.1)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }
              }

              Text {
                visible: root.configured && root.missingPackages.length === 0
                  && root.selectedEvents.length === 0
                height: visible ? implicitHeight : 0
                width: parent.width
                text: root.statusMessage
                color: Qt.darker(root.contentForeground, root.cacheFailed ? 1.3 : 1.9)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
              }

              // ---- Calendars, doubling as the legend and the switches.
              //      A single calendar has nothing to toggle between, so the
              //      row only earns its space once there are two.
              Flow {
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
                    height: chipRow.height

                    Row {
                      id: chipRow
                      spacing: Style.space(5)

                      // Filled when the calendar is on, hollow when off —
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
                          root.addingSubscription = false
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
                  height: addLabel.height

                  Text {
                    id: addLabel
                    text: root.addingSubscription ? "×" : "+"
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

                Item {
                  visible: root.cache.signedIn === true
                  width: visible ? signOutLabel.width : 0
                  height: signOutLabel.height

                  Text {
                    id: signOutLabel
                    text: "Sign out"
                    color: signOutMouse.containsMouse
                      ? Style.hoverStateColor(root.contentForeground, Color.accent)
                      : Qt.darker(root.contentForeground, 2.2)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                  }

                  MouseArea {
                    id: signOutMouse
                    anchors.fill: parent
                    anchors.margins: -Style.space(4)
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.signOut()
                  }
                }
              }

              // ---- Swatches for one calendar. Subscribed feeds often ship
              //      no colour at all, or one that fights with everything
              //      else on the day, so they need to be assignable by hand.
              Column {
                width: parent.width
                visible: root.calendarEditing !== ""
                height: visible ? implicitHeight : 0
                spacing: Style.space(5)

                // A feed that supplied no name of its own arrives as a
                // placeholder, so this is often the only way it gets called
                // anything useful. The original name stays the identity
                // underneath — this only changes what is printed.
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

                // Back to whatever iCloud or the feed said, for undoing a
                // choice without having to remember the original.
                Rectangle {
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(11)
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
                    text: "Use the calendar's own colour"
                    fontFamily: root.contentFontFamily
                  }
                }

                Item { width: Style.space(4); height: 1 }

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
              }

              // ---- Pasting a feed URL, with the directions to find one.
              //      iCloud cannot supply these, so the panel has to say
              //      where they actually live.
              Column {
                width: parent.width
                visible: root.addingSubscription
                height: visible ? implicitHeight : 0
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
              // with a surface of its own — a one-time piece of setup should
              // be findable at a glance, and then gone for good.
              Rectangle {
                width: parent.width
                visible: root.builtinClockOnBar
                height: visible ? hideClockRow.implicitHeight + Style.space(18) : 0
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
                  text: "Take it off the bar — it stays installed"
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

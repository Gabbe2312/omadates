import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Date/time label for the bar, and the host for the calendar popup.
//
// Left click reveals the calendar — asking "what is the date?" is what a
// click on a clock means — right click walks the common label formats, and
// middle click opens the timezone picker.
BarWidget {
  id: root
  moduleName: "io.github.gabbe2312.calendar"

  property date displayDate: clock.date

  readonly property string configuredFormat: vertical
    ? setting("verticalFormat", "HH\n—\nmm")
    : setting("format", "dddd HH:mm")
  readonly property string configuredAltFormat: vertical
    ? setting("verticalFormatAlt", "dd\nMMM\n'W'ww\n''yy")
    : setting("formatAlt", "d MMMM 'W'ww yyyy")

  readonly property var formatRing: Model.clockFormatRing(configuredFormat, configuredAltFormat, Model.clockFormats(vertical))

  // What the bar shows is what shell.json stores, so a cycled format is the
  // format from then on rather than something that reverts on restart.
  readonly property string activeFormat: configuredFormat
  readonly property string displayText: formatted(displayDate)
  readonly property var verticalLines: displayText.split("\n")

  function refresh() {
    displayDate = new Date()
    if (panelLoader.item && panelLoader.item.refresh) panelLoader.item.refresh()
  }

  function cycleFormat() {
    var current = String(configuredFormat)
    var next = Model.nextClockFormat(formatRing, current)
    if (next === "" || next === current) return

    var entry = { id: root.moduleName }
    for (var key in root.settings) if (key !== "id") entry[key] = root.settings[key]
    entry[vertical ? "verticalFormat" : "format"] = next

    // Applied locally first so the label changes on the click itself; the
    // shell.json write comes back through the bar as the same value.
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function formatted(date) {
    return Qt.formatDateTime(date, activeFormat.replace(/ww/g, Model.isoWeekLiteral(date.getFullYear(), date.getMonth(), date.getDate())))
  }

  // ---- Calendar popup. Shape contract for shell.summon/hide/toggle
  //      routing: Bar.findPanelWidget requires open/close/opened on the
  //      bar-widget root.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  function togglePanel() {
    if (panelLoader.item) panelLoader.item.toggle()
  }

  // ---- Taking over the bar's centre anchor when it points at nothing.
  //
  // With a valid anchor the bar pins that one widget to the middle and hangs
  // everything else off its edges, so an indicator revealing on hover grows
  // leftward and the clock holds still. With no valid anchor it centres the
  // whole row as one block, and every reveal shoves the clock sideways,
  // right as you are reaching for it.
  //
  // Omarchy ships the anchor naming its own clock. Switch that clock off in
  // favour of this one and the anchor is left dangling, which is the broken
  // state this repairs. It never touches an anchor that resolves, and never
  // claims an empty one: blank is a deliberate "centre the row as a block".
  function adoptDanglingCenterAnchor() {
    if (!root.bar || !root.bar.shell) return
    var shell = root.bar.shell
    if (typeof shell.persistShellConfig !== "function") return

    var config = shell.shellConfig
    if (!config || !config.bar || !config.bar.layout) return
    var center = config.bar.layout.center
    if (!(center instanceof Array)) return

    var anchor = String(config.bar.centerAnchor || "")
    if (anchor === "" || anchor === root.moduleName) return

    var anchorPresent = false
    var selfPresent = false
    for (var i = 0; i < center.length; i++) {
      var id = center[i] ? String(center[i].id) : ""
      if (id === anchor) anchorPresent = true
      if (id === root.moduleName) selfPresent = true
    }
    if (anchorPresent || !selfPresent) return

    var next = JSON.parse(JSON.stringify(config))
    next.bar.centerAnchor = root.moduleName
    shell.persistShellConfig(next)
  }

  function toggleWeekStart() {
    if (panelLoader.item) panelLoader.item.toggleWeekStart()
  }

  function toggleCalendar(name) {
    if (panelLoader.item) panelLoader.item.toggleCalendar(name)
  }

  // The clock fills more slot than it paints a mark for, at both
  // orientations: horizontally it is a text label in a padded slot, so the
  // dot takes the label width; vertically it is a stack of icon-sized lines,
  // so the dot takes one line — the same mark every icon widget gets, rather
  // than a rule running the height of the whole stack.
  readonly property real openPanelIndicatorWidth: button.labelWidth
  readonly property real openPanelIndicatorHeight: Math.max(Style.space(10), Math.round(Style.bar.iconSlot * 0.55))

  // Forwarded so this widget can stand in for the panel as the bar's popout
  // identity: Bar.requestPopout prefers closeForPopoutSwitch over close, and
  // KeyboardPanel reads popoutSwitchClosing back off its owner.
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: {
    injectPanel()
    Qt.callLater(root.adoptDanglingCenterAnchor)
  }
  onSettingsChanged: injectPanel()

  SystemClock {
    id: clock
    precision: SystemClock.Minutes
    onDateChanged: root.displayDate = date
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    target: "io.github.gabbe2312.calendar"

    function refresh(): void { root.broadcast("refresh") }
    function cycleFormat(): void { root.cycleFormat() }
    function toggleWeekStart(): void { root.toggleWeekStart() }
    function toggleCalendar(name: string): void { root.toggleCalendar(name) }
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
  }

  // ---- A calendar file dropped on the bar label.
  //
  // The same act as dropping on the open panel, from the one part of this
  // plugin that is always on screen: you do not have to open the calendar to
  // put something in it. The file is staged, never written, and the panel
  // comes up to ask which calendar.
  readonly property string pluginDir: String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "")

  function looksLikeCalendarFile(url) {
    var text = String(url || "").toLowerCase().replace(/[?#].*$/, "")
    var kinds = [".ics", ".ical", ".icalendar", ".ifb", ".vcs"]
    for (var i = 0; i < kinds.length; i++)
      if (text.slice(-kinds[i].length) === kinds[i]) return true
    return false
  }

  function calendarFileIn(drop) {
    if (!drop || !drop.hasUrls) return ""
    for (var i = 0; i < drop.urls.length; i++)
      if (root.looksLikeCalendarFile(drop.urls[i])) return String(drop.urls[i])
    return ""
  }

  Process {
    id: barStageProcess
  }

  // Holding a file over the bar opens the calendar so there is somewhere to
  // drop it. Nothing closes it again while you are still holding something,
  // and that is the point: an open panel owns the whole screen's pointer
  // input (Ui/KeyboardPanel.qml masks the lot, bar strip included), so this
  // widget stops seeing the drag the instant the panel appears. Any clock
  // that tried to decide the drag was over would be deciding it blind, and
  // did: the calendar blinked open and shut the whole way down.
  //
  // The cost is honest. Change your mind and drop the file somewhere else and
  // the calendar stays up until you click, because it cannot be told that the
  // drag ended. Clicking anywhere dismisses it, as it always did.
  function tellPanel(what) {
    var target = panelLoader.item
    if (target && typeof target[what] === "function") target[what]()
  }

  function noteDrop() {
    if (panelLoader.item && "dragHovering" in panelLoader.item)
      panelLoader.item.dragHovering = false
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // While a calendar file is over the bar the clock says so, because with
    // no panel open this label is the whole of the target and the whole of
    // the feedback there is room for.
    // A file over the bar turns the clock into the target it has become. With
    // no panel open this label is all the room there is to say so, and it is
    // the same glyph the panel shows when the drag is over the month itself.
    text: root.vertical ? "" : (barDrop.containsDrag ? "󰈙  Drop here" : root.displayText)
    labelVisible: !root.vertical
    hasVisualContent: root.vertical ? root.verticalLines.length > 0 : text !== ""
    fixedHeight: root.vertical ? root.verticalLines.length * Style.bar.iconSlot : -1
    horizontalMargin: 8.75
    verticalPadding: 8.75

    onPressed: function(b) {
      if (b === Qt.RightButton) root.cycleFormat()
      else if (b === Qt.MiddleButton) { if (root.bar) root.bar.run("omarchy-menu-timezone") }
      else root.togglePanel()
    }

    // Takes drags only, so the press handling above is untouched. The label
    // lifts while a file is over it, which is the whole of the feedback a
    // bar this size has room for.
    DropArea {
      id: barDrop
      anchors.fill: parent
      anchors.margins: -Style.space(4)
      onEntered: function(drop) {
        if (root.calendarFileIn(drop) === "") { drop.accepted = false; return }
        if (!root.opened) root.open()
        root.tellPanel("dragEntered")
      }
      // Taking the file away again puts the calendar back. Not while the
      // pointer is still up here, and not the instant it leaves either: it
      // may be on its way down into the panel, which it can only do by
      // leaving the bar first.
      onExited: root.tellPanel("dragLeft")
      onDropped: function(drop) {
        root.noteDrop()
        var file = root.calendarFileIn(drop)
        if (file === "" || barStageProcess.running) return
        barStageProcess.command = [root.pluginDir + "bin/omadates-sync", "stage", file]
        barStageProcess.running = true
      }
    }

    Column {
      visible: root.vertical
      anchors.fill: parent

      Repeater {
        model: root.verticalLines

        OpticalGlyph {
          required property string modelData
          width: button.width
          height: Style.bar.iconSlot
          text: modelData
          fontFamily: button.fontFamily
          fontSize: modelData.length > 3
            ? button.fontSize * 0.9
            : button.fontSize
          color: button.foreground
        }
      }
    }
  }
}

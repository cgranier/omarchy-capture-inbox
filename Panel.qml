import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Capture Inbox: what is waiting to be sent, what was captured lately, and a
// box for a quick note. The capture CLI does all the sending.
Panel {
  id: root
  moduleName: "cgranier.capture"
  ipcTarget: "cgranier.capture"
  manageIpc: false

  property int cursorIndex: 0
  property bool cursorActive: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool vertical: bar ? bar.vertical : false

  function isDriver() {
    if (!bar || typeof bar.moduleWidgets !== "function") return true
    var items = bar.moduleWidgets(moduleName)
    return !items || items.length === 0 || items[0] === root
  }

  function clampCursor() {
    cursorIndex = Math.max(0, Math.min(cursorIndex, Math.max(0, inbox.cursorRows.length - 1)))
  }

  function moveCursor(dy) {
    cursorActive = true
    cursorIndex += dy
    clampCursor()
    scrollCursorIntoView()
  }

  function selectedRow() {
    if (inbox.cursorRows.length === 0) return null
    clampCursor()
    return inbox.cursorRows[cursorIndex]
  }

  // Enter on something waiting sends the queue; on a link in the history it
  // opens the page.
  function activate(row) {
    if (!row) return
    if (row.type === "queued") inbox.retryNow(row.item.dead)
    else if (row.row.url !== "") { inbox.openUrl(row.row.url); root.close() }
  }

  function dropSelected() {
    var row = selectedRow()
    if (row && row.type === "queued") inbox.drop(row.item)
  }

  function scrollCursorIntoView() {
    Qt.callLater(function() {
      for (var i = 0; i < rowColumn.children.length; i++) {
        var item = rowColumn.children[i]
        if (!item || item.cursorIndex !== root.cursorIndex) continue
        var margin = Style.space(6)
        var top = item.mapToItem(panelFlick.contentItem, 0, 0).y
        var bottom = top + item.height
        var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
        if (top < panelFlick.contentY + margin) panelFlick.contentY = Math.max(0, top - margin)
        else if (bottom > panelFlick.contentY + panelFlick.height - margin) panelFlick.contentY = Math.min(maxY, bottom + margin - panelFlick.height)
        return
      }
    })
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    cursorActive = false
    panelFlick.contentY = 0
    inbox.refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  Service {
    id: inbox
    settings: root.settings
    isDriver: root.isDriver
  }

  Connections {
    target: inbox
    function onCursorRowsChanged() { root.clampCursor() }
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { inbox.refresh(); return "ok" }
    function retry(): string { inbox.retryNow(false); return "ok" }
    function retryRefused(): string { inbox.retryNow(true); return "ok" }
    function status(): string { return inbox.summary }
    function state(): string {
      return JSON.stringify({ counts: inbox.counts, reachable: inbox.reachable === undefined ? null : inbox.reachable,
        queue: inbox.queue.length, journal: inbox.journal.length, busy: inbox.busy, opened: root.opened })
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: Model.barLabel(inbox.counts, root.vertical)
    active: inbox.counts.refused > 0
    dimmed: inbox.counts.waiting + inbox.counts.refused === 0
    tooltipText: root.opened ? "" : "Capture Inbox: " + inbox.summary

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton) inbox.retryNow(false)
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(column.implicitHeight + footer.implicitHeight + Style.space(12), Style.space(600))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (dy === 0) return
        if (!root.cursorActive) { root.cursorActive = true; root.clampCursor(); root.scrollCursorIntoView(); return }
        root.moveCursor(dy)
      }
      onActivateRequested: if (root.cursorActive) root.activate(root.selectedRow())
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r") inbox.retryNow(false)
        else if (t === "R") inbox.retryNow(true)
        else if (t === "j") root.moveCursor(1)
        else if (t === "k") root.moveCursor(-1)
        else if (t === "d" || t === "D") root.dropSelected()
        else if (t === "n" || t === "N") noteField.forceActiveFocus()
      }

      Flickable {
        id: panelFlick
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: footer.top
        anchors.bottomMargin: Style.space(8)
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: "Capture Inbox"
            meta: inbox.actionStatus !== "" ? inbox.actionStatus : inbox.summary
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: inbox.counts.waiting + inbox.counts.refused > 0 ? Model.GLYPHS.waiting : Model.GLYPHS.inbox
                color: inbox.counts.refused > 0 ? root.urgent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          TextField {
            id: noteField
            width: parent.width
            placeholderText: "Quick note: type and press enter"
            foreground: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            enabled: !inbox.busy
            // Enter belongs to the note while the field has focus. Left to
            // travel up, it would also activate the row under the cursor.
            function submit() { if (inbox.quickNote(text)) { text = ""; keyCatcher.forceActiveFocus() } }
            Keys.onReturnPressed: function(event) { submit(); event.accepted = true }
            Keys.onEnterPressed: function(event) { submit(); event.accepted = true }
            Keys.onEscapePressed: function(event) { text = ""; keyCatcher.forceActiveFocus(); event.accepted = true }
          }

          Column {
            id: rowColumn
            visible: inbox.rows.length > 0
            width: parent.width
            spacing: Style.space(2)

            Repeater {
              model: inbox.rows

              Loader {
                required property var modelData
                readonly property int cursorIndex: modelData.cursorIndex === undefined ? -1 : modelData.cursorIndex
                width: rowColumn.width
                sourceComponent: modelData.type === "header" ? headerRow : captureRow
                onLoaded: item.row = modelData
              }
            }
          }
        }
      }

      // Stays put while the list scrolls.
      Text {
        id: footer
        textFormat: Text.PlainText
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        horizontalAlignment: Text.AlignHCenter
        text: inbox.counts.waiting > 0 ? "enter or r save now · d drop · n note"
          : inbox.counts.refused > 0 ? "R try refused again · d drop · n note" : "enter open link · n note"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }
    }
  }

  Component {
    id: headerRow

    Item {
      property var row: null
      implicitHeight: headerText.implicitHeight + Style.space(6)

      PanelSectionHeader {
        id: headerText
        anchors.bottom: parent.bottom
        text: row ? row.text : ""
        foreground: root.foreground
        fontFamily: root.fontFamily
      }
    }
  }

  // One component for both kinds of row: something waiting in the queue, or a
  // line of history.
  Component {
    id: captureRow

    CursorSurface {
      id: surface
      property var row: null
      readonly property bool queued: row !== null && row.type === "queued"
      readonly property var entry: row === null ? null : (queued ? row.item : row.row)
      readonly property bool bad: entry !== null && (queued ? entry.dead : entry.status === "failed")

      hasCursor: root.cursorActive && row !== null && root.cursorIndex === row.cursorIndex
      foreground: root.foreground
      implicitHeight: content.implicitHeight + Style.space(12)

      MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: surface.queued || (surface.entry && surface.entry.url !== "") ? Qt.PointingHandCursor : Qt.ArrowCursor
        onEntered: if (surface.row) { root.cursorActive = true; root.cursorIndex = surface.row.cursorIndex }
        onClicked: root.activate(surface.row)
      }

      RowLayout {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Style.space(10)
        anchors.rightMargin: Style.space(10)
        spacing: Style.space(10)

        Text {
          textFormat: Text.PlainText
          text: surface.entry ? Model.kindGlyph(surface.entry.kind) : ""
          color: surface.bad ? root.urgent : root.foreground
          opacity: surface.queued ? 1.0 : 0.6
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          Layout.alignment: Qt.AlignVCenter
          Layout.preferredWidth: Style.space(18)
          horizontalAlignment: Text.AlignHCenter
        }

        ColumnLayout {
          id: content
          Layout.fillWidth: true
          spacing: Style.space(1)

          Text {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            text: surface.entry ? surface.entry.name : ""
            color: surface.bad ? root.urgent : root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
          }

          Text {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            text: !surface.entry ? "" : surface.queued ? Model.queueMeta(surface.entry, inbox.now) : Model.journalMeta(surface.entry, inbox.now)
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }
      }
    }
  }
}

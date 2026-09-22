import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Reads the capture CLI's queue and journal, and asks the CLI to retry when
// the webhook is reachable again. Everything that touches the network is the
// CLI's doing; this only ever runs `<command> queue|journal|reachable|retry|note`.
Item {
  id: root

  property var settings: ({})
  // One bar widget exists per monitor; only one of them should drive retries.
  property var isDriver: function() { return true }

  property var queue: []
  property var journal: []
  property var rows: []
  property var cursorRows: []
  property var counts: Model.counts([])
  property string summary: "Nothing captured yet"
  property var reachable: undefined   // undefined until first asked
  property double now: Date.now()
  property bool busy: retryProcess.running || noteProcess.running
  property string actionStatus: ""

  // The bundled CLI unless the settings name another one that speaks the same
  // subcommands (Carlos runs his private mnotes-capture this way).
  readonly property string bundledCommand: String(Qt.resolvedUrl("bin/capture")).replace(/^file:\/\//, "")
  readonly property string command: String(setting("command", "") || "") !== "" ? String(setting("command", "")) : bundledCommand
  readonly property bool autoRetry: setting("autoRetry", true) !== false
  readonly property int historyCount: Math.max(3, Math.min(40, parseInt(String(setting("historyCount", 12)), 10) || 12))
  // Watched for changes so a capture made from a keybind shows up at once.
  // The bundled CLI keeps it under capture-inbox; mnotes-capture under mnotes;
  // anything else says where with the `journal` setting.
  readonly property string stateHome: Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")
  readonly property string journalPath: String(setting("journal", "") || "") !== "" ? String(setting("journal", ""))
    : /mnotes-capture$/.test(command) ? stateHome + "/mnotes/journal.jsonl"
    : stateHome + "/capture-inbox/journal.jsonl"

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function rebuild() {
    now = Date.now()
    counts = Model.counts(queue)
    rows = Model.buildRows(queue, journal, historyCount)
    cursorRows = Model.cursorRows(rows)
    summary = Model.summaryText(counts, reachable, journal.length > 0)
  }

  // A refresh asked for while one is running is not dropped: the state on
  // disk may have changed after that read started, so read once more.
  property bool queueStale: false
  property bool journalStale: false

  function refresh() {
    if (queueProcess.running) queueStale = true
    else queueProcess.running = true
    if (journalProcess.running) journalStale = true
    else journalProcess.running = true
  }

  function say(text) {
    actionStatus = text
    actionStatusTimer.restart()
  }

  // withRefused: also try what the destination refused. Only ever on request, since a
  // refusal repeats until its cause (a bad token, say) is fixed.
  function retryNow(withRefused) {
    if (retryProcess.running) return
    if (counts.waiting === 0 && !(withRefused && counts.refused > 0)) return
    say("Sending…")
    // Titles are fetched on save, so a long queue can take a while; still finite.
    retryProcess.command = ["timeout", "300", command].concat(withRefused ? ["retry", "--refused"] : ["retry"])
    retryProcess.running = true
  }

  function drop(item) {
    if (!item || dropProcess.running) return
    dropProcess.command = ["timeout", "15", command, "queue", "drop", item.id]
    dropProcess.running = true
  }

  // Typed by the person at the keyboard, so it goes out as their own words:
  // no --author, which the contract reserves for text an agent wrote.
  function quickNote(text) {
    var note = String(text || "").trim()
    if (note === "" || noteProcess.running) return false
    say("Saving note…")
    noteProcess.command = ["timeout", "60", command, "note", note]
    noteProcess.running = true
    return true
  }

  function openUrl(url) {
    if (/^https?:\/\//.test(String(url || ""))) Quickshell.execDetached(["xdg-open", url])
  }

  onSettingsChanged: refresh()
  Component.onCompleted: refresh()

  // The CLI writes a journal line for every attempt, send, and drop, so the
  // journal changing is the signal that the queue may have changed too.
  FileView {
    path: root.journalPath
    watchChanges: true
    printErrors: false
    onFileChanged: { reload(); root.refresh() }
    onLoaded: root.refresh()
  }

  // While something waits: is the webhook back? `reachable` is a plain GET
  // with no token; it captures nothing.
  Timer {
    interval: 60000
    repeat: true
    running: root.autoRetry && root.counts.waiting > 0
    triggeredOnStart: true
    onTriggered: if (root.isDriver() && !reachProcess.running && !retryProcess.running) reachProcess.running = true
  }

  Timer {
    interval: 60000
    repeat: true
    running: true
    onTriggered: root.rebuild()
  }

  Timer {
    id: actionStatusTimer
    interval: 3000
    repeat: false
    onTriggered: root.actionStatus = ""
  }

  Process {
    id: queueProcess
    running: false
    command: ["timeout", "15", root.command, "queue", "--json"]
    stdout: StdioCollector { id: queueOut; waitForEnd: true }
    onExited: function(exitCode) {
      root.queue = Model.parseQueue(queueOut.text)
      root.rebuild()
      if (root.queueStale) { root.queueStale = false; running = true }
    }
  }

  Process {
    id: journalProcess
    running: false
    command: ["timeout", "15", root.command, "journal", "--json", "-n", "60"]
    stdout: StdioCollector { id: journalOut; waitForEnd: true }
    onExited: function(exitCode) {
      root.journal = Model.parseJournal(journalOut.text)
      root.rebuild()
      if (root.journalStale) { root.journalStale = false; running = true }
    }
  }

  Process {
    id: reachProcess
    running: false
    command: ["timeout", "15", root.command, "reachable"]
    onExited: function(exitCode) {
      root.reachable = exitCode === 0
      root.rebuild()
      if (root.reachable && root.counts.waiting > 0 && !retryProcess.running) {
        retryProcess.command = ["timeout", "300", root.command, "retry", "--quiet"]
        retryProcess.running = true
      }
    }
  }

  Process {
    id: retryProcess
    running: false
    command: []
    stdout: StdioCollector { id: retryOut; waitForEnd: true }
    onExited: function(exitCode) {
      var result = {}
      try { result = JSON.parse(String(retryOut.text || "{}").trim().split("\n").pop()) } catch (e) { result = {} }
      if (result.stopped === "unreachable") { root.reachable = false; root.say("Still not reachable") }
      else if (result.sent > 0) { root.reachable = true; root.say(result.sent + " sent") }
      else if (result.left > 0) root.say(result.left + " refused")
      else root.say("")
      root.refresh()
    }
  }

  Process {
    id: dropProcess
    running: false
    command: []
    onExited: function(exitCode) { root.say(exitCode === 0 ? "Dropped" : "Could not drop it"); root.refresh() }
  }

  Process {
    id: noteProcess
    running: false
    command: []
    stdout: StdioCollector { id: noteOut; waitForEnd: true }
    onExited: function(exitCode) {
      var status = ""
      try { status = JSON.parse(String(noteOut.text || "{}").trim().split("\n").pop()).status || "" } catch (e) { status = "" }
      root.say(exitCode !== 0 ? "The note was not saved" : status === "queued" ? "Note saved, will send later" : "Note saved")
      root.refresh()
    }
  }
}

// Pure logic for Capture Inbox: reading the capture CLI's queue and journal,
// and shaping them for the bar and the panel. No QML imports, so it runs under
// node for tests. The plugin never talks to a webhook itself; the CLI does.

function glyph(codePoint) {
  return String.fromCodePoint(codePoint)
}

var GLYPHS = {
  inbox: glyph(0xF01C),      // fa-inbox
  waiting: glyph(0xF017),    // fa-clock-o
  link: glyph(0xF0C1),       // fa-link
  screenshot: glyph(0xF030), // fa-camera
  note: glyph(0xF249),       // fa-sticky-note
  ok: glyph(0xF00C),         // fa-check
  duplicate: glyph(0xF0C5),  // fa-files-o
  failed: glyph(0xF071),     // fa-warning
  dropped: glyph(0xF1F8)     // fa-trash
}

var KIND_NAMES = { link: "Link", screenshot: "Screenshot", note: "Note" }

function parseArray(raw) {
  try {
    var value = JSON.parse(String(raw || "[]"))
    return Array.isArray(value) ? value : []
  } catch (e) {
    return []
  }
}

function kindGlyph(kind) {
  return GLYPHS[kind] || GLYPHS.inbox
}

function statusGlyph(status) {
  if (status === "ok") return GLYPHS.ok
  if (status === "duplicate") return GLYPHS.duplicate
  if (status === "queued") return GLYPHS.waiting
  if (status === "failed") return GLYPHS.failed
  if (status === "dropped") return GLYPHS.dropped
  return GLYPHS.ok   // the webhook's other outcomes ("stub saved", ...) are still saved
}

// What to call a capture. Only links ever carry a title or URL; a note or a
// screenshot is named by its kind, because the CLI deliberately records
// nothing of their content.
function displayName(item) {
  var label = String((item && item.label) || "").trim()
  if (label !== "") return label
  var url = String((item && item.url) || "").trim()
  if (url !== "") return url.replace(/^https?:\/\//, "")
  return KIND_NAMES[item && item.kind] || "Capture"
}

// Queue items from `mnotes-capture queue --json`, oldest first as the CLI lists them.
function parseQueue(raw) {
  var list = parseArray(raw)
  var items = []
  for (var i = 0; i < list.length; i++) {
    var q = list[i] || {}
    if (!q.id) continue
    items.push({
      id: String(q.id), kind: String(q.kind || ""), name: displayName(q), url: String(q.url || ""),
      dead: q.dead === true, attempts: Number(q.attempts) || 0,
      reason: q.dead === true ? "refused" : String(q.class || "unreachable"),
      error: String(q.error || ""), tsMs: Date.parse(q.ts) || 0
    })
  }
  return items
}

// Journal lines from `mnotes-capture journal --json`, newest first.
function parseJournal(raw) {
  var list = parseArray(raw)
  var rows = []
  for (var i = 0; i < list.length; i++) {
    var j = list[i] || {}
    if (!j.status) continue
    rows.push({
      id: String(j.id || ""), kind: String(j.kind || ""), status: String(j.status), name: displayName(j), url: String(j.url || ""),
      detail: String(j.detail || ""), late: String(j.detail || "") === "sent from the queue", tsMs: Date.parse(j.ts) || 0
    })
  }
  return rows
}

function counts(queue) {
  var c = { waiting: 0, refused: 0 }
  for (var i = 0; i < (queue || []).length; i++) {
    if (queue[i].dead) c.refused += 1
    else c.waiting += 1
  }
  return c
}

function barLabel(c, vertical) {
  var total = c.waiting + c.refused
  if (total === 0 || vertical) return GLYPHS.inbox
  return GLYPHS.waiting + " " + total
}

function summaryText(c, reachable, hasHistory) {
  var parts = []
  if (c.waiting > 0) parts.push(c.waiting + " waiting")
  if (c.refused > 0) parts.push(c.refused + " refused")
  if (parts.length === 0) return hasHistory ? "Everything sent" : "Nothing captured yet"
  if (c.waiting > 0 && reachable === false) parts.push("mNOTES unreachable")
  return parts.join(" · ")
}

function ago(tsMs, nowMs) {
  if (!tsMs) return ""
  var seconds = Math.max(0, Math.floor((nowMs - tsMs) / 1000))
  if (seconds < 60) return "just now"
  var minutes = Math.floor(seconds / 60)
  if (minutes < 60) return minutes + "m ago"
  var hours = Math.floor(minutes / 60)
  if (hours < 48) return hours + "h ago"
  return Math.floor(hours / 24) + "d ago"
}

var REASONS = {
  unreachable: "mNOTES could not be reached",
  server: "mNOTES answered with an error",
  ambiguous: "the connection broke part-way",
  refused: "mNOTES refused it"
}

function queueMeta(item, nowMs) {
  var text = REASONS[item.reason] || item.reason
  if (item.dead && item.error !== "") text += " (" + item.error + ")"
  var when = ago(item.tsMs, nowMs)
  if (when !== "") text += " · " + when
  // attempts counts retries; the capture itself was the first try.
  if (!item.dead && item.attempts > 0) text += " · tried " + (item.attempts + 1) + " times"
  return text
}

function journalMeta(row, nowMs) {
  var text = row.status === "ok" ? "saved" : row.status === "duplicate" ? "already there" : row.status
  if (row.late) text += " · sent late"
  var when = ago(row.tsMs, nowMs)
  return when !== "" ? text + " · " + when : text
}

// One flat list for the panel: the queue on top, then recent history. The
// cursor walks every row; what enter does depends on the row.
function buildRows(queue, journal, historyLimit) {
  var rows = []
  var cursorIndex = 0
  if ((queue || []).length > 0) {
    rows.push({ type: "header", text: "WAITING · " + queue.length, attention: true })
    for (var i = 0; i < queue.length; i++) {
      rows.push({ type: "queued", item: queue[i], cursorIndex: cursorIndex })
      cursorIndex += 1
    }
  }
  // One row per capture. A queued capture writes a journal line for every
  // attempt, so keep only its newest line, and none at all while it still
  // shows above as waiting.
  var seen = {}
  for (var q = 0; q < (queue || []).length; q++) seen[queue[q].id] = true
  var recent = []
  for (var j = 0; j < (journal || []).length && recent.length < historyLimit; j++) {
    var line = journal[j]
    if (line.status === "queued") continue
    if (line.id !== "") {
      if (seen[line.id]) continue
      seen[line.id] = true
    }
    recent.push(line)
  }
  if (recent.length > 0) {
    rows.push({ type: "header", text: "RECENT", attention: false })
    for (var k = 0; k < recent.length; k++) {
      rows.push({ type: "history", row: recent[k], cursorIndex: cursorIndex })
      cursorIndex += 1
    }
  }
  return rows
}

function cursorRows(rows) {
  var result = []
  for (var i = 0; i < (rows || []).length; i++) if (rows[i].type !== "header") result.push(rows[i])
  return result
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    GLYPHS: GLYPHS, parseQueue: parseQueue, parseJournal: parseJournal, displayName: displayName, counts: counts,
    barLabel: barLabel, summaryText: summaryText, ago: ago, queueMeta: queueMeta, journalMeta: journalMeta,
    buildRows: buildRows, cursorRows: cursorRows, kindGlyph: kindGlyph, statusGlyph: statusGlyph
  }
}

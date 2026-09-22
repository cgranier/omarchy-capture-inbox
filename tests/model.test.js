// Run with: node tests/model.test.js
const assert = require("assert")
const M = require("../Model.js")
let passed = 0
function test(name, fn) { fn(); passed += 1; console.log("ok - " + name) }

const NOW = Date.parse("2026-09-21T12:00:00-04:00")
const queueJson = JSON.stringify([
  { id: "20260921-113000-000000001", ts: "2026-09-21T11:30:00-04:00", kind: "link", what: "Link", label: "https://example.com/a", url: "https://example.com/a", class: "unreachable", attempts: 3, dead: false, error: "" },
  { id: "20260921-113100-000000002", ts: "2026-09-21T11:31:00-04:00", kind: "note", what: "Note", label: "", url: "", class: "ambiguous", attempts: 0, dead: false, error: "" },
  { id: "20260921-113200-000000003", ts: "2026-09-21T11:32:00-04:00", kind: "screenshot", what: "Screenshot", label: "", url: "https://example.com/page", class: "server", attempts: 2, dead: true, error: "HTTP 401: bad token" },
  { nonsense: true }
])
const journalJson = JSON.stringify([
  { ts: "2026-09-21T11:59:30-04:00", kind: "link", status: "ok", label: "A page title", url: "https://example.com/t", id: "x", detail: "sent from the queue" },
  { ts: "2026-09-21T11:32:00-04:00", kind: "screenshot", status: "queued", url: "https://example.com/page", id: "y", detail: "server" },
  { ts: "2026-09-21T10:00:00-04:00", kind: "note", status: "ok" },
  { ts: "2026-09-20T09:00:00-04:00", kind: "link", status: "duplicate", label: "Old page", url: "https://example.com/old" },
  { ts: "2026-09-18T09:00:00-04:00", kind: "link", status: "failed", url: "https://example.com/bad", detail: "HTTP 422" }
])
const queue = M.parseQueue(queueJson)
const journal = M.parseJournal(journalJson)

test("parseQueue keeps valid items and names them without inventing content", () => {
  assert.strictEqual(queue.length, 3)
  assert.deepStrictEqual(queue.map((q) => q.name), ["https://example.com/a", "Note", "example.com/page"])
  assert.deepStrictEqual(queue.map((q) => q.reason), ["unreachable", "ambiguous", "refused"])
  assert.strictEqual(queue[2].dead, true)
  assert.deepStrictEqual(M.parseQueue("not json"), [])
  assert.deepStrictEqual(M.parseQueue('{"a":1}'), [])
})

test("parseJournal reads rows newest first and flags late sends", () => {
  assert.strictEqual(journal.length, 5)
  assert.deepStrictEqual(journal.map((j) => j.name), ["A page title", "example.com/page", "Note", "Old page", "example.com/bad"])
  assert.strictEqual(journal[0].late, true)
  assert.strictEqual(journal[2].late, false)
})

test("counts, bar label, and summary", () => {
  const c = M.counts(queue)
  assert.deepStrictEqual(c, { waiting: 2, refused: 1 })
  assert.strictEqual(M.barLabel(c, false), M.GLYPHS.waiting + " 3")
  assert.strictEqual(M.barLabel(c, true), M.GLYPHS.inbox)
  assert.strictEqual(M.barLabel({ waiting: 0, refused: 0 }, false), M.GLYPHS.inbox)
  assert.strictEqual(M.summaryText(c, false, true), "2 waiting · 1 refused · not reachable")
  assert.strictEqual(M.summaryText(c, true, true), "2 waiting · 1 refused")
  assert.strictEqual(M.summaryText({ waiting: 0, refused: 1 }, false, true), "1 refused")
  assert.strictEqual(M.summaryText({ waiting: 0, refused: 0 }, true, true), "Everything sent")
  assert.strictEqual(M.summaryText({ waiting: 0, refused: 0 }, true, false), "Nothing captured yet")
})

test("row text", () => {
  assert.strictEqual(M.queueMeta(queue[0], NOW), "could not be reached · 30m ago · tried 4 times")
  assert.strictEqual(M.queueMeta(queue[1], NOW), "the connection broke part-way · 29m ago")
  assert.strictEqual(M.queueMeta(queue[2], NOW), "refused (HTTP 401: bad token) · 28m ago")
  assert.strictEqual(M.journalMeta(journal[0], NOW), "saved · sent late · just now")
  assert.strictEqual(M.journalMeta(journal[3], NOW), "already there · 27h ago")
  assert.strictEqual(M.journalMeta(journal[4], NOW), "failed · 3d ago")
  assert.strictEqual(M.ago(0, NOW), "")
})

test("buildRows: one history row per capture, newest outcome wins", () => {
  const lines = M.parseJournal(JSON.stringify([
    { ts: "2026-09-21T12:03:00-04:00", kind: "link", status: "ok", label: "A page", url: "https://example.com/a", id: "q1", detail: "sent from the queue" },
    { ts: "2026-09-21T12:02:00-04:00", kind: "link", status: "failed", label: "https://example.com/a", url: "https://example.com/a", id: "q1" },
    { ts: "2026-09-21T12:01:30-04:00", kind: "note", status: "failed", id: "q2" },
    { ts: "2026-09-21T12:01:00-04:00", kind: "link", status: "queued", label: "https://example.com/a", url: "https://example.com/a", id: "q1" },
    { ts: "2026-09-21T12:00:00-04:00", kind: "note", status: "ok" },
    { ts: "2026-09-21T11:59:00-04:00", kind: "note", status: "ok" },
  ]))
  const stillWaiting = [{ id: "q2", kind: "note", name: "Note", dead: true, attempts: 1 }]
  const history = M.buildRows(stillWaiting, lines, 10).filter((r) => r.type === "history").map((r) => r.row.status + ":" + r.row.name)
  // q1 collapses to its final "ok"; q2 is still in the queue so it is not repeated; notes without an id all stay.
  assert.deepStrictEqual(history, ["ok:A page", "ok:Note", "ok:Note"])
})

test("buildRows: queue on top, history below without repeating what still waits", () => {
  const rows = M.buildRows(queue, journal, 3)
  assert.deepStrictEqual(rows.map((r) => r.type), ["header", "queued", "queued", "queued", "header", "history", "history", "history"])
  assert.strictEqual(rows[0].text, "WAITING · 3")
  assert.ok(rows.filter((r) => r.type === "history").every((r) => r.row.status !== "queued"))
  assert.deepStrictEqual(M.cursorRows(rows).map((r) => r.cursorIndex), [0, 1, 2, 3, 4, 5])
  assert.deepStrictEqual(M.buildRows([], [], 5), [])
  assert.deepStrictEqual(M.buildRows([], journal, 10).map((r) => r.type), ["header", "history", "history", "history", "history"])
})

console.log("\n" + passed + " tests passed")

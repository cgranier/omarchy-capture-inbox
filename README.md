# Capture Inbox

A bar widget and panel for the `mnotes-capture` CLI on [Omarchy](https://omarchy.org).

![Capture Inbox panel](preview.jpg)

It shows three things:

- **What is waiting.** Captures the CLI saved locally because the webhook could not be reached.
- **What happened lately.** One row per recent capture: saved, already there, sent late, failed, or dropped.
- **A quick-note box.** Type, press enter, and the note goes out through the CLI as your own words.

While something is waiting, the plugin asks the CLI once a minute whether the webhook answers. When it does,
the queue is sent, oldest first, with no input from you.

## What it does not do

The plugin never talks to a webhook, never reads a token, and never stores anything. It only runs these
commands, and reads what they print:

```
mnotes-capture queue --json          mnotes-capture retry [--quiet|--refused]
mnotes-capture journal --json -n 60  mnotes-capture queue drop <id>
mnotes-capture reachable             mnotes-capture note <text>
```

The journal holds a title and address for links only. Note text and screenshots never appear in it, so they
never appear in the panel either: a note shows as "Note".

## Status: personal first

This version needs the `mnotes-capture` CLI (with the queue and journal commands, 2026-09-21 or later) on the
shell's `PATH`. That CLI is not public yet, so the plugin is not in the marketplace. The plan for a public
version is a second backend that writes Markdown to a local folder.

## Keys

| Key | Does |
|---|---|
| `j` / `k`, arrows | move |
| `enter` | on something waiting: send the queue now. On a link in the history: open it |
| `r` | send the queue now |
| `R` | also try what mNOTES refused (after fixing the cause, such as a bad token) |
| `d` | drop the selected waiting capture without sending it |
| `n` | jump to the quick-note box (`esc` leaves it) |
| middle click on the bar icon | send the queue now |

## The bar

A dimmed inbox glyph when there is nothing to do. A clock and a count when captures are waiting. The count
is highlighted when mNOTES refused something, because that needs a person: a refusal repeats until its cause
is fixed, so refused captures are never retried automatically.

## Settings

```
omarchy bar set cgranier.capture autoRetry false     # never send without being asked
omarchy bar set cgranier.capture historyCount 20     # rows of history (3 to 40)
omarchy bar set cgranier.capture command /path/to/cli
```

## From a keybind or script

```
omarchy-shell cgranier.capture toggle
omarchy-shell cgranier.capture status         # "2 waiting · mNOTES unreachable"
omarchy-shell cgranier.capture state          # JSON
omarchy-shell cgranier.capture retry
omarchy-shell cgranier.capture retryRefused
```

## Install

```
omarchy plugin add <this repo> --enable
```

## Uninstall

```
omarchy plugin disable cgranier.capture
omarchy plugin remove cgranier.capture
```

The queue and journal belong to the CLI (`~/.local/state/mnotes/`) and are left alone.

## Tests

```
node tests/model.test.js
```

The CLI has its own suite, run against a fake webhook on localhost. Never test against the real one.

## License

MIT

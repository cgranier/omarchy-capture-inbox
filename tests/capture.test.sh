#!/bin/bash
# Tests for bin/capture against a throwaway folder. Never touches ~/.config or ~/Documents.
# Run with: bash tests/capture.test.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
CLI="$HERE/../bin/capture"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export CAPTURE_CONFIG="$T/config" CAPTURE_STATE="$T/state" CAPTURE_QUIET=1 CAPTURE_OFFLINE=1
export HOME="$T/home"; mkdir -p "$HOME"
pass=0; fail=0
check() { if eval "$2"; then pass=$((pass + 1)); echo "ok - $1"; else fail=$((fail + 1)); echo "FAIL - $1"; fi; }
run() { bash "$CLI" "$@"; }
jlast() { tail -n 1 "$T/state/journal.jsonl"; }
inbox() { ls "$1/Inbox"/*.md 2>/dev/null; }

# --- default folder: created without being asked
out=$(run url "https://example.com/a" "a side note"); rc=$?
check "default folder is created and a link saved" '[[ $rc == 0 && $(jq -r .status <<<"$out") == ok && -d $HOME/Documents/Captures/Inbox ]]'
f=$(jq -r .file <<<"$out")
check "link file has front matter, title from the host when offline, the url and the note" \
  'grep -q "^type: link$" "$f" && grep -q "^title: \"example.com\"$" "$f" && grep -q "^<https://example.com/a>$" "$f" && grep -q "^a side note$" "$f"'
check "file name carries the date and a slug" '[[ $(basename "$f") =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4}-example-com\.md$ ]]'
check "files are private to the user" '[[ $(stat -c %a "$f") == 600 ]]'
check "journal: link has kind, status, url and label" '[[ $(jlast | jq -r "[.kind,.status,.url,.label]|join(\"|\")") == "link|ok|https://example.com/a|example.com" ]]'
out=$(run url "https://example.com/a")
check "the same link again is a duplicate, no second file" '[[ $(jq -r .status <<<"$out") == duplicate && $(inbox "$HOME/Documents/Captures" | wc -l) == 1 ]]'

# --- notes
out=$(run note $'Buy milk\n\nand eggs, my private thought')
check "note: first line is the title, body kept" 'f=$(jq -r .file <<<"$out"); grep -q "^title: \"Buy milk\"$" "$f" && grep -q "^and eggs, my private thought$" "$f"'
check "note: journal has NO label and NO url" '[[ $(jlast | jq -c "{kind,status,label,url}") == "{\"kind\":\"note\",\"status\":\"ok\",\"label\":null,\"url\":null}" ]]'
check "privacy: the note text is nowhere in the journal" '! grep -q "private thought" "$T/state/journal.jsonl"'
check "note: empty text is refused" '! run note "   " 2>/dev/null'

# --- screenshots
printf '\x89PNG\r\n\x1a\nfake' >"$T/s.png"
out=$(run --image-file "$T/s.png" --url "https://example.com/page" "what I saw")
f=$(jq -r .file <<<"$out")
check "screenshot: png copied to attachments and embedded with a relative path" \
  'img=$(grep -o "attachments/[^)]*\.png" "$f" | head -1); [[ -n $img && -s $HOME/Documents/Captures/Inbox/$img ]] && cmp -s "$T/s.png" "$HOME/Documents/Captures/Inbox/$img"'
check "screenshot: page url and note are in the file, title names the host" 'grep -q "^source: https://example.com/page$" "$f" && grep -q "^what I saw$" "$f" && grep -q "^title: \"Screenshot of example.com\"$" "$f"'
check "screenshot: journal keeps the page url but no label" '[[ $(jlast | jq -c "{kind,status,url,label}") == "{\"kind\":\"screenshot\",\"status\":\"ok\",\"url\":\"https://example.com/page\",\"label\":null}" ]]'

# --- a configured folder that is not there: queue
run setup "$T/vault" >/dev/null
check "setup writes the config and creates the folder" '[[ -f $T/config && -d $T/vault/Inbox/attachments ]]'
check "reachable: yes while the folder exists" 'run reachable'
mv "$T/vault" "$T/vault.gone"
check "reachable: no once it is gone (a configured folder is never recreated)" '! run reachable && [[ ! -d $T/vault ]]'
out=$(run url "https://example.com/offline-1" "kept note"); rc=$?
check "offline link: exit 0, status queued" '[[ $rc == 0 && $(jq -r .status <<<"$out") == queued && $(jq -r .reason <<<"$out") == unreachable ]]'
run note "written while offline" >/dev/null
run --image-file "$T/s.png" --url "https://example.com/p2" >/dev/null
check "three captures waiting, in order" '[[ $(run queue --json | jq -r "map(.kind)|join(\",\")") == "link,note,screenshot" ]]'
check "queue files are private" '[[ -z $(find "$T/state/queue" -type f ! -perm 600) ]]'
check "journal says queued" '[[ $(jlast | jq -r .status) == queued ]]'
out=$(run retry); check "retry while still gone: nothing sent, stopped unreachable" '[[ $(jq -c "{sent,left,stopped}" <<<"$out") == "{\"sent\":0,\"left\":3,\"stopped\":\"unreachable\"}" ]]'
check "attempts counted (each new capture retries the queue first)" '[[ $(run queue --json | jq -r ".[0].attempts") == 3 ]]'
mv "$T/vault.gone" "$T/vault"
out=$(run retry)
check "retry once back: all three saved, none left" '[[ $(jq -c "{sent,left}" <<<"$out") == "{\"sent\":3,\"left\":0}" ]]'
check "queued link kept its note and was journaled as sent from the queue" \
  'f=$(grep -l "example.com/offline-1" "$T/vault/Inbox"/*.md); grep -q "^kept note$" "$f" && [[ $(run journal --json -n 3 | jq -r "map(.detail)|unique|join(\",\")") == "sent from the queue" ]]'
check "queued screenshot bytes are intact" 'img=$(ls "$T/vault/Inbox/attachments"/*.png | head -1); cmp -s "$T/s.png" "$img"'

# --- drop, refused, help
mv "$T/vault" "$T/vault.gone"; run url "https://example.com/drop-me" >/dev/null
id=$(run queue --json | jq -r '.[0].id'); run queue drop "$id" >/dev/null
check "queue drop removes it and journals the drop with the url" '[[ $(run queue --json) == "[]" && $(jlast | jq -r ".status+\"|\"+.url") == "dropped|https://example.com/drop-me" ]]'
check "queue drop rejects a bad id" '! run queue drop "../../etc" 2>/dev/null'
mv "$T/vault.gone" "$T/vault"
check "journal --json is newest first" '[[ $(run journal --json -n 2 | jq -r ".[0].status") == dropped ]]'
check "help lists the commands" 'run --help | grep -q "capture retry"'
check "a bare URL works as the first argument" '[[ $(run "https://example.com/bare" | jq -r .status) == ok ]]'

# --- title fetch against a local page
python3 - "$T" <<'EOF' &
import http.server, sys, os
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"<html><head><title>Hello &amp; Welcome</title></head><body>x</body></html>"
        self.send_response(200); self.send_header("Content-Type", "text/html"); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
srv = http.server.HTTPServer(("127.0.0.1", 28766), H)
open(os.path.join(sys.argv[1], "srv.pid"), "w").write(str(os.getpid()))
srv.serve_forever()
EOF
sleep 1
out=$(CAPTURE_OFFLINE= run url "http://127.0.0.1:28766/x")
check "title fetched and entities decoded" '[[ $(jq -r .title <<<"$out") == "Hello & Welcome" ]]'
kill "$(cat "$T/srv.pid")" 2>/dev/null

echo; echo "$pass passed, $fail failed"; (( fail == 0 ))

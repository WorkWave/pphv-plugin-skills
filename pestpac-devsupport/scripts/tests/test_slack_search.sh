#!/usr/bin/env bash
set -uo pipefail

SCRIPT="$(dirname "$0")/../slack-search.sh"
pass=0; fail=0
ok()  { pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

# Read a field out of a state JSON file (node; jq unavailable).
json_field() { node -e 'const fs=require("fs");try{process.stdout.write(String(JSON.parse(fs.readFileSync(process.argv[1],"utf8"))[process.argv[2]]??""))}catch(e){process.stdout.write("")}' "$1" "$2"; }
json_access()  { json_field "$1" access_token; }
json_refresh() { json_field "$1" refresh_token; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A mock "curl": logs which Slack endpoint it was called for, and emits canned
# JSON driven by env vars. Lets us drive refresh/search behavior with no network.
# (Defaults are assigned to a var first — never inside ${:-...} — because braces
# in a parameter-expansion default get mis-parsed and corrupt the JSON.)
MOCK="$TMP/mockcurl.sh"
cat > "$MOCK" <<'EOF'
#!/usr/bin/env bash
args="$*"
if printf '%s' "$args" | grep -q "oauth.v2.access"; then
	echo "oauth" >> "$MOCK_LOG"
	resp="${MOCK_OAUTH_JSON:-}"
	[ -n "$resp" ] || resp='{"ok":true,"access_token":"xoxp-new","refresh_token":"refresh-new","expires_in":43200}'
	printf '%s' "$resp"
elif printf '%s' "$args" | grep -q "search.messages"; then
	n="$(grep -c search "$MOCK_LOG" 2>/dev/null || true)"; n="${n:-0}"
	echo "search" >> "$MOCK_LOG"
	if [ "${MOCK_SEARCH_FIRST_EXPIRED:-0}" = "1" ] && [ "$n" -eq 0 ]; then
		printf '%s' '{"ok":false,"error":"token_expired"}'
	else
		resp="${MOCK_SEARCH_JSON:-}"
		[ -n "$resp" ] || resp='{"ok":true,"messages":{"matches":[]}}'
		printf '%s' "$resp"
	fi
fi
EOF
chmod +x "$MOCK"

newlog()    { MOCK_LOG="$TMP/log.$1"; : > "$MOCK_LOG"; export MOCK_LOG; }
statefile() { echo "$TMP/state.$1.json"; }
countlog()  { c="$(grep -c "$1" "$2" 2>/dev/null || true)"; echo "${c:-0}"; }
NOW="$(date +%s)"

# --- A: nothing configured -> graceful skip, exit 0 ----------------------
out="$(env -u SLACK_USER_TOKEN -u SLACK_CLIENT_ID -u SLACK_CLIENT_SECRET -u SLACK_REFRESH_TOKEN \
	PPDS_SLACK_STATE="$TMP/none.json" bash "$SCRIPT" "q" 2>/dev/null)"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "SLACK_SKIPPED"; } && ok || bad "A: no-creds skip (rc=$rc out=$out)"

# --- B: --check prints search.messages, exit 0 (static token) ------------
out="$(SLACK_USER_TOKEN="xoxp-test" bash "$SCRIPT" --check "boom" 2>/dev/null)"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "search.messages"; } && ok || bad "B: check mode (rc=$rc out=$out)"

# --- C: --check must not leak the token value ----------------------------
out="$(SLACK_USER_TOKEN="xoxp-SECRET" bash "$SCRIPT" --check "boom" 2>/dev/null)"
printf '%s' "$out" | grep -q "SECRET" && bad "C: token leaked in --check" || ok

# --- D: proactive refresh from seed (no state), then search --------------
newlog D; st="$(statefile D)"
out="$(PPDS_CURL="$MOCK" PPDS_SLACK_STATE="$st" \
	SLACK_CLIENT_ID=cid SLACK_CLIENT_SECRET=sec SLACK_REFRESH_TOKEN=seed \
	bash "$SCRIPT" "boom" 2>/dev/null)"; rc=$?
{ [ "$rc" -eq 0 ] \
	&& grep -q oauth "$MOCK_LOG" \
	&& grep -q search "$MOCK_LOG" \
	&& printf '%s' "$out" | grep -q "matches" \
	&& [ -f "$st" ] \
	&& [ "$(json_access "$st")" = "xoxp-new" ] \
	&& [ "$(json_refresh "$st")" = "refresh-new" ]; } && ok || bad "D: proactive refresh (rc=$rc out=$out log=$(cat "$MOCK_LOG"))"

# --- E: valid (unexpired) token in state -> NO refresh -------------------
newlog E; st="$(statefile E)"
node -e 'const fs=require("fs");fs.writeFileSync(process.argv[1],JSON.stringify({access_token:"good",refresh_token:"r",expires_at:Number(process.argv[2])}))' "$st" "$((NOW+9999))"
out="$(PPDS_CURL="$MOCK" PPDS_SLACK_STATE="$st" \
	SLACK_CLIENT_ID=cid SLACK_CLIENT_SECRET=sec SLACK_REFRESH_TOKEN=r \
	bash "$SCRIPT" "boom" 2>/dev/null)"; rc=$?
{ [ "$rc" -eq 0 ] \
	&& ! grep -q oauth "$MOCK_LOG" \
	&& grep -q search "$MOCK_LOG"; } && ok || bad "E: valid token should not refresh (log=$(cat "$MOCK_LOG"))"

# --- F: expired token in state -> refresh --------------------------------
newlog F; st="$(statefile F)"
node -e 'const fs=require("fs");fs.writeFileSync(process.argv[1],JSON.stringify({access_token:"old",refresh_token:"r",expires_at:Number(process.argv[2])}))' "$st" "$((NOW-10))"
PPDS_CURL="$MOCK" PPDS_SLACK_STATE="$st" SLACK_CLIENT_ID=cid SLACK_CLIENT_SECRET=sec \
	bash "$SCRIPT" "boom" >/dev/null 2>&1
grep -q oauth "$MOCK_LOG" && ok || bad "F: expired token should refresh (log=$(cat "$MOCK_LOG"))"

# --- G: refresh failure -> graceful skip, exit 0, reason surfaced --------
newlog G; st="$(statefile G)"
out="$(PPDS_CURL="$MOCK" PPDS_SLACK_STATE="$st" \
	MOCK_OAUTH_JSON='{"ok":false,"error":"invalid_refresh_token"}' \
	SLACK_CLIENT_ID=cid SLACK_CLIENT_SECRET=sec SLACK_REFRESH_TOKEN=seed \
	bash "$SCRIPT" "boom" 2>/dev/null)"; rc=$?
{ [ "$rc" -eq 0 ] \
	&& printf '%s' "$out" | grep -q "SLACK_SKIPPED" \
	&& printf '%s' "$out" | grep -q "invalid_refresh_token"; } && ok || bad "G: refresh failure graceful (rc=$rc out=$out)"

# --- H: state file persisted (perms best-effort; NTFS may not honor chmod) -
[ -s "$(statefile D)" ] && ok || bad "H: state file missing/empty"

# --- I: reactive refresh+retry on token_expired during search ------------
newlog I; st="$(statefile I)"
node -e 'const fs=require("fs");fs.writeFileSync(process.argv[1],JSON.stringify({access_token:"good",refresh_token:"r",expires_at:Number(process.argv[2])}))' "$st" "$((NOW+9999))"
out="$(PPDS_CURL="$MOCK" PPDS_SLACK_STATE="$st" MOCK_SEARCH_FIRST_EXPIRED=1 \
	SLACK_CLIENT_ID=cid SLACK_CLIENT_SECRET=sec \
	bash "$SCRIPT" "boom" 2>/dev/null)"; rc=$?
oauths="$(countlog oauth "$MOCK_LOG")"
searches="$(countlog search "$MOCK_LOG")"
{ [ "$rc" -eq 0 ] \
	&& [ "$oauths" -eq 1 ] \
	&& [ "$searches" -eq 2 ] \
	&& printf '%s' "$out" | grep -q "matches"; } && ok || bad "I: reactive retry (rc=$rc oauths=$oauths searches=$searches out=$out)"

# --- J: search still failing after reactive refresh -> graceful skip -----
newlog J; st="$(statefile J)"
node -e 'const fs=require("fs");fs.writeFileSync(process.argv[1],JSON.stringify({access_token:"good",refresh_token:"r",expires_at:Number(process.argv[2])}))' "$st" "$((NOW+9999))"
out="$(PPDS_CURL="$MOCK" PPDS_SLACK_STATE="$st" \
	MOCK_SEARCH_JSON='{"ok":false,"error":"invalid_auth"}' \
	SLACK_CLIENT_ID=cid SLACK_CLIENT_SECRET=sec \
	bash "$SCRIPT" "boom" 2>/dev/null)"; rc=$?
{ [ "$rc" -eq 0 ] \
	&& printf '%s' "$out" | grep -q "SLACK_SKIPPED" \
	&& printf '%s' "$out" | grep -q "after token refresh" \
	&& [ "$(countlog oauth "$MOCK_LOG")" -eq 1 ] \
	&& [ "$(countlog search "$MOCK_LOG")" -eq 2 ]; } && ok || bad "J: skip after failed retry (rc=$rc out=$out oauth=$(countlog oauth "$MOCK_LOG") search=$(countlog search "$MOCK_LOG"))"

echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]

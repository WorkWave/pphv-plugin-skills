#!/usr/bin/env bash
set -euo pipefail

# Slack search wrapper with rotating-token (refresh) support.
# Reaches Slack's search.messages for the ticket-investigation plugin.
#
# Config (env vars; secrets never passed on the command line):
#   Auto-refresh mode (preferred): SLACK_CLIENT_ID, SLACK_CLIENT_SECRET, and an
#     initial SLACK_REFRESH_TOKEN. Rotating tokens are persisted to the state
#     file (default ~/.config/pestpac-devsupport/slack-token.json, perms 600;
#     override with PPDS_SLACK_STATE) because each refresh also rotates the
#     refresh token.
#   Static mode (backward compatible): SLACK_USER_TOKEN (a non-rotating xoxp-).
#
# Degrades gracefully: when nothing is configured, or a refresh fails, it
# prints a SLACK_SKIPPED note and exits 0 so a missing/broken Slack never
# aborts an investigation.
#
# Test seam: PPDS_CURL overrides the HTTP command (default "curl").

CURL="${PPDS_CURL:-curl}"
STATE="${PPDS_SLACK_STATE:-$HOME/.config/pestpac-devsupport/slack-token.json}"
REFRESH_BUFFER=120   # refresh this many seconds before expiry

CHECK=0
if [ "${1:-}" = "--check" ]; then CHECK=1; shift; fi
QUERY="${1:-}"

skip() { echo "SLACK_SKIPPED: $1"; exit 0; }

# --- JSON helpers (node; jq not available) -------------------------------
json_get() { # json_get FIELD  (reads JSON from stdin) -> value or empty
	node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const j=JSON.parse(s);const v=j[process.argv[1]];process.stdout.write(v==null?"":String(v));}catch(e){process.stdout.write("");}})' "$1"
}
json_make() { # json_make ACCESS REFRESH EXPIRES_AT -> JSON
	node -e 'const[a,r,e]=process.argv.slice(1);process.stdout.write(JSON.stringify({access_token:a,refresh_token:r,expires_at:Number(e)}))' "$1" "$2" "$3"
}
now() { date +%s; }

# --- Load current token state --------------------------------------------
ACCESS=""; REFRESH=""; EXPIRES_AT=0
if [ -f "$STATE" ]; then
	_s="$(cat "$STATE" 2>/dev/null || echo '{}')"
	ACCESS="$(printf '%s' "$_s" | json_get access_token)"
	REFRESH="$(printf '%s' "$_s" | json_get refresh_token)"
	EXPIRES_AT="$(printf '%s' "$_s" | json_get expires_at)"
fi
[ -n "$EXPIRES_AT" ] || EXPIRES_AT=0
[ -n "$REFRESH" ] || REFRESH="${SLACK_REFRESH_TOKEN:-}"

REFRESH_CONFIGURED=0
if [ -n "${SLACK_CLIENT_ID:-}" ] && [ -n "${SLACK_CLIENT_SECRET:-}" ] && [ -n "$REFRESH" ]; then
	REFRESH_CONFIGURED=1
fi

# Static-token fallback / nothing-configured skip
if [ "$REFRESH_CONFIGURED" -eq 0 ]; then
	if [ -n "${SLACK_USER_TOKEN:-}" ]; then
		ACCESS="${SLACK_USER_TOKEN}"
	else
		skip "no Slack credentials configured"
	fi
fi

# --- --check: show intended search call, no network, no secrets ----------
if [ "$CHECK" -eq 1 ]; then
	echo "curl -s -G https://slack.com/api/search.messages \\"
	echo "  -H 'Authorization: Bearer <access-token>' \\"
	echo "  --data-urlencode 'query=${QUERY}' --data 'count=10'"
	exit 0
fi

# --- token refresh (rotating) --------------------------------------------
save_state() {
	mkdir -p "$(dirname "$STATE")"
	local tmp="${STATE}.tmp.$$"
	json_make "$ACCESS" "$REFRESH" "$EXPIRES_AT" > "$tmp"
	chmod 600 "$tmp" 2>/dev/null || true
	mv "$tmp" "$STATE"
	chmod 600 "$STATE" 2>/dev/null || true
}

do_refresh() {
	local resp ok err newref expires_in
	resp="$("$CURL" -s -X POST https://slack.com/api/oauth.v2.access \
		-d "client_id=${SLACK_CLIENT_ID}" \
		-d "client_secret=${SLACK_CLIENT_SECRET}" \
		-d "grant_type=refresh_token" \
		-d "refresh_token=${REFRESH}" 2>/dev/null || echo '{}')"
	ok="$(printf '%s' "$resp" | json_get ok)"
	if [ "$ok" != "true" ]; then
		err="$(printf '%s' "$resp" | json_get error)"
		skip "token refresh failed (${err:-unknown})"
	fi
	ACCESS="$(printf '%s' "$resp" | json_get access_token)"
	newref="$(printf '%s' "$resp" | json_get refresh_token)"
	[ -n "$newref" ] && REFRESH="$newref"
	expires_in="$(printf '%s' "$resp" | json_get expires_in)"
	[ -n "$expires_in" ] || expires_in=43200
	EXPIRES_AT="$(( $(now) + expires_in ))"
	save_state
}

# Proactive refresh when the access token is missing or near expiry
if [ "$REFRESH_CONFIGURED" -eq 1 ]; then
	if [ -z "$ACCESS" ] || [ "$(now)" -ge "$(( EXPIRES_AT - REFRESH_BUFFER ))" ]; then
		do_refresh
	fi
fi

# --- search, with one reactive refresh+retry on auth failure -------------
do_search() {
	"$CURL" -s -G https://slack.com/api/search.messages \
		-H "Authorization: Bearer ${ACCESS}" \
		--data-urlencode "query=${QUERY}" \
		--data "count=10" 2>/dev/null || echo '{}'
}

resp="$(do_search)"
ok="$(printf '%s' "$resp" | json_get ok)"
if [ "$ok" != "true" ] && [ "$REFRESH_CONFIGURED" -eq 1 ]; then
	err="$(printf '%s' "$resp" | json_get error)"
	case "$err" in
		token_expired|invalid_auth|token_revoked)
			do_refresh
			resp="$(do_search)"
			ok="$(printf '%s' "$resp" | json_get ok)"
			if [ "$ok" != "true" ]; then
				err="$(printf '%s' "$resp" | json_get error)"
				skip "search failed after token refresh (${err:-unknown})"
			fi
			;;
	esac
fi
printf '%s\n' "$resp"

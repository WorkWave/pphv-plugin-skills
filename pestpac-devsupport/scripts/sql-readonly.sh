#!/usr/bin/env bash
set -euo pipefail

INSTANCE="${PPDS_SQL_INSTANCE:-.\\SQLEXPRESS}"
DB="${PPDS_SQL_DB:-PestPac333}"
CHECK=0

while [ $# -gt 0 ]; do
	case "$1" in
		--check) CHECK=1; shift ;;
		--db) DB="$2"; shift 2 ;;
		--) shift; break ;;
		-*) echo "REJECTED: unknown flag $1" >&2; exit 2 ;;
		*) break ;;
	esac
done

QUERY="${1:-}"

reject() { echo "REJECTED: $1" >&2; exit 2; }

# 1. Non-empty
[ -n "${QUERY// /}" ] || reject "empty query"

# 2. No comments (prevents comment-based smuggling)
case "$QUERY" in
	*"--"*) reject "line comments not allowed" ;;
	*"/*"*) reject "block comments not allowed" ;;
esac

# 3. No statement separators / batch terminators
case "$QUERY" in
	*";"*) reject "semicolons / multiple statements not allowed" ;;
esac

# Uppercase copy for keyword checks
UP="$(printf '%s' "$QUERY" | tr '[:lower:]' '[:upper:]' | tr '\n\r\t' '   ')"

# 4. Must begin with SELECT or WITH (after leading whitespace/parens)
case "$(printf '%s' "$UP" | sed -E 's/^[[:space:](]+//')" in
	SELECT" "*|SELECT|WITH" "*) : ;;
	*) reject "query must start with SELECT or WITH" ;;
esac

# 5. Forbidden keywords at word boundaries
for kw in INSERT UPDATE DELETE MERGE DROP ALTER CREATE TRUNCATE EXEC EXECUTE \
		  GRANT REVOKE DENY BACKUP RESTORE SHUTDOWN RECONFIGURE WAITFOR \
		  "INTO" " GO " OPENROWSET OPENQUERY OPENDATASOURCE BULK; do
	if printf ' %s ' "$UP" | grep -Eq "[^A-Z_]${kw// /}[^A-Z_]"; then
		reject "forbidden keyword: ${kw// /}"
	fi
done

# 6. Extended stored procedures (xp_) — trailing boundary check fails because
#    the char after XP_ is a letter; use a leading-boundary-only pattern.
if printf ' %s ' "$UP" | grep -Eq '[^A-Z_]XP_'; then
	reject "extended stored procedure (xp_) not allowed"
fi

if [ "$CHECK" -eq 1 ]; then
	exit 0
fi

exec sqlcmd -S "$INSTANCE" -E -d "$DB" -b -Q "SET NOCOUNT ON; $QUERY" -W

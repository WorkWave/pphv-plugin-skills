#!/usr/bin/env bash
set -uo pipefail

SCRIPT="$(dirname "$0")/../sql-readonly.sh"
pass=0; fail=0

assert_ok() { # query should be ACCEPTED
	if bash "$SCRIPT" --check "$1" >/dev/null 2>&1; then
		pass=$((pass+1))
	else
		echo "FAIL (expected accept): $1"; fail=$((fail+1))
	fi
}
assert_reject() { # query should be REJECTED (exit 2)
	bash "$SCRIPT" --check "$1" >/dev/null 2>&1
	if [ "$?" -eq 2 ]; then
		pass=$((pass+1))
	else
		echo "FAIL (expected reject): $1"; fail=$((fail+1))
	fi
}

# Allowed reads
assert_ok "SELECT TOP 10 * FROM Locations"
assert_ok "select name from sys.objects where type = 'P'"
assert_ok "WITH x AS (SELECT 1 AS n) SELECT n FROM x"
assert_ok "SELECT OBJECT_DEFINITION(OBJECT_ID('dbo.LocationSelect'))"

# Rejected writes / dangerous verbs
assert_reject "INSERT INTO Locations (Name) VALUES ('x')"
assert_reject "UPDATE Locations SET Name='x'"
assert_reject "DELETE FROM Locations"
assert_reject "DROP TABLE Locations"
assert_reject "ALTER TABLE Locations ADD c int"
assert_reject "CREATE TABLE t (id int)"
assert_reject "TRUNCATE TABLE Locations"
assert_reject "EXEC sp_who"
assert_reject "EXECUTE dbo.LocationDelete 1"
assert_reject "MERGE Locations USING src ON 1=1"
assert_reject "GRANT SELECT ON Locations TO public"

# Smuggling attempts
assert_reject "SELECT 1; DROP TABLE Locations"
assert_reject "SELECT * INTO Backup FROM Locations"
assert_reject "SELECT 1 GO DROP TABLE Locations"
assert_reject "SELECT 1 -- ; DROP TABLE Locations"

# Must start with a read
assert_reject "WAITFOR DELAY '00:00:05'"
assert_reject ""

# External data sources and extended stored procedures
assert_reject "SELECT * FROM OPENROWSET('SQLNCLI','Server=x;','SELECT 1')"
assert_reject "SELECT * FROM OPENQUERY(srv, 'select 1')"
assert_reject "SELECT * FROM OPENDATASOURCE('SQLNCLI','x') .a.b.c"
assert_reject "SELECT a FROM OPENROWSET(BULK 'c:\\f.txt', SINGLE_CLOB) x"
assert_reject "SELECT xp_fileexist('c:\\x')"
assert_ok "SELECT TOP 5 Name FROM Locations WHERE Active = 1"

# Newline-separated statement smuggling
assert_reject $'SELECT 1\nGO\nDROP TABLE Locations'
assert_reject $'SELECT 1\nDROP TABLE Locations'
assert_reject $'SELECT 1\nUPDATE Locations SET Name=1'
assert_ok     $'SELECT TOP 5 Name\nFROM Locations\nWHERE Active = 1'

echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]

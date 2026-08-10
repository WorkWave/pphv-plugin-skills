# aes.sonar OpenSearch — log field reference

Field map for scoping the WorkWave aes.sonar logs to a single tenant by company
key. Used by the `log-searcher` agent. Verified from sample docs on 2026-08-10;
field names re-confirmed via the OpenSearch MCP server on 2026-08-10.

Access: the `opensearch` MCP server (`https://aes.sonar.workwave.com`),
authenticated via a service account — query the indices directly with
`SearchIndexTool` / `CountTool` / `MsearchTool`. No browser, SSO, or manual login.

## Company key
6-digit tenant identifier, e.g. `123456`, `654321`. The same key can appear in
both `prod` and `staging` — disambiguate with the `env-type` field when known.

## Index → tenant field

| Index | Tenant field | Time | Host field(s) |
|-------|--------------|------|---------------|
| `iislogstash-*` | `company_key` | `@timestamp` | `host.name`, `agent.hostname`, `computername` |
| `pestpacapi-*`  | `cokey`        | `@timestamp` | `host.name`, `agent.hostname` |
| `winlogbeat-*`  | **none — not tenant-scoped** | `@timestamp` | `host.name` |

`winlogbeat-*` has no company key. To use it: first find the host name(s) serving
the tenant from `iislogstash-*` / `pestpacapi-*` hits in the window, then query
`winlogbeat-*` by `host.name` + the same `@timestamp` range.

## iislogstash-* (IIS access logs)
- Errors: `status` (>=400), `server_error:1`, `client_error:1`, `substatus`, `win32status`
- Request: `verb`, `request`, `querystring`, `responsetime`, `clientip`,
  `xforwardedfor`, `hostheader`
- Context: `env-type` (prod/staging), `env-name`, `host.name`, `message`
- Note: `message` is the raw W3SVC log line and the `cookie` field is large —
  exclude from `_source` unless needed.

## pestpacapi-* (.NET API logs)
- Errors: `level` (INFO/ERROR/…), `status` (>=400)
- Request: `route`/`sanitizedRoute`, `method`, `elapsed` (ms), `component`,
  `clientipaddress`
- Correlation: `activityid` (also ends the `message`) — matches a request across
  API and (when present) IIS `correlation-id`.
- Context: `env-type`, `host.name`, `message`
- WARNING: `responseBody` and `message` can be huge (full payloads). Always
  exclude `responseBody` from `_source`; never request large `size`.

## Query notes
- Read-only: `SearchIndexTool` / `CountTool` / `MsearchTool` only.
- Query the date-partitioned indices by their wildcard alias (`iislogstash-*`,
  etc.) with a `@timestamp` range — do not enumerate daily indices.
- Always: `term` on the tenant field + `@timestamp` range, `sort` by
  `@timestamp:desc`, `size <= 20` (via the tool's `size` arg), and a `_source`
  include list (never `responseBody`).
- Date ranges MUST include a `format`, e.g.
  `"format":"strict_date_optional_time||epoch_millis"`.
- `SearchIndexTool.query_dsl` takes the full search body (`query`/`sort`/`_source`);
  pass the hit count via the separate `size` argument.

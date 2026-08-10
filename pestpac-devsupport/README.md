# pestpac-devsupport

Claude Code plugin: given a Jira ticket ID, investigate it across Jira,
code/GitHub, the local SQL database, and Slack in parallel, and produce an
inline root-cause analysis with suggested changes — or a QE handoff (test cases
+ test-data plan + automation playbook) for QA.

The local filesystem and every data source stay **read-only**. The single
exception is `qe-steps`, which posts a QE spec comment and attaches a playbook to
the Jira ticket — and only after it shows you the draft and you confirm.

## Usage

Investigate a Jira ticket (root-cause analysis across all sources):
```
/pestpac-devsupport:analyze-ticket PES-1234
```

Turn a ticket into a QE handoff — impacted areas, manual test cases, and a
test-data plan — then post a **QE spec comment** plus an automation playbook to
the ticket (nothing is posted until you confirm the drafted comment):
```
/pestpac-devsupport:qe-steps PES-1234
```

Mentor-style code review of your changes (correctness + PestPac coding
standards + design, with the why explained; read-only):
```
/pestpac-devsupport:review-changes            # branch diff vs master (default)
/pestpac-devsupport:review-changes staged     # only staged changes
/pestpac-devsupport:review-changes 12471      # a PR on WorkWave/PestPac
/pestpac-devsupport:review-changes path/to/file.asp
```

## Setup

Each dependency is **optional and degrades gracefully** — if a source isn't
configured, that step is skipped with a note and the rest of the investigation
still runs. Configure the ones you want.

> **Credentials.** This plugin ships no secrets. Every credential below is read
> from your own environment or your user-scoped Claude Code config
> (`~/.claude.json`), never from the repo. Do not commit tokens, passwords, or
> connection strings.

### 1. GitHub CLI — code & PR search
`winget install GitHub.cli` (or `brew install gh`), then `gh auth login`.
If `gh` is absent the PR-search step is skipped with a note.

### 2. Atlassian MCP — Jira & Confluence
The `jira-similar` and `confluence-docs` agents use the official **Atlassian
Remote MCP server** (tools prefixed `mcp__atlassian__`). Add it once and
authenticate via OAuth (browser) — no API token is stored locally:

```
claude mcp add --transport sse atlassian https://mcp.atlassian.com/v1/sse
```

Then run `/mcp` in Claude Code and complete the `atlassian` OAuth flow. Access is
scoped to your own Atlassian account and its existing Jira/Confluence
permissions. If it isn't connected, the Jira and Confluence steps are skipped.

### 3. Slack plugin — conversation search (optional, read-only, public only)
The `slack-searcher` agent reaches Slack through the Slack plugin (MCP server
`plugin:slack:slack`, tools prefixed `mcp__plugin_slack_slack__`). Install and
connect it with `/plugin`, then authenticate via `/mcp`.

**Read-only + public-only is enforced by the agent's `tools:` allowlist.** The
agent is granted ONLY:
- `slack_search_public` — search **public channels only** (never
  `slack_search_public_and_private`, so private channels and DMs are never
  searched)
- `slack_read_channel`, `slack_read_thread` — read public channel/thread context
- `slack_search_channels`, `slack_search_users`, `slack_read_user_profile` —
  lookups

Every write tool (`slack_send_message`, `slack_send_message_draft`,
`slack_schedule_message`, `slack_add_reaction`, `slack_create_canvas`,
`slack_update_canvas`) and the private-inclusive search tool
(`slack_search_public_and_private`) are deliberately excluded. The investigation
posts NOTHING to Slack and reads NO private/DM conversations. For defense in
depth, still authorize the Slack app with read-only scopes.

If the Slack plugin is not installed or OAuth is not completed, the Slack step is
skipped with a note and the investigation continues.

### 4. Local SQL — read-only tenant DB inspection
Point the `sql-inspector` agent at your local PestPac instance (defaults shown;
override only if your setup differs):
- `PPDS_SQL_INSTANCE` (default `.\SQLEXPRESS`)
- `PPDS_SQL_DB` (default `PestPac333`)

SQL is read-only: all queries pass through `scripts/sql-readonly.sh`, which
rejects anything that is not a single SELECT/WITH read.

### 5. OpenSearch MCP — aes.sonar logs (optional, conditional)
The `log-searcher` agent reads the WorkWave aes.sonar logs
(`iislogstash-*`/`pestpacapi-*`/`winlogbeat-*`) directly through an `opensearch`
MCP server — no browser, SSO, or manual login. Set it up once:

**a. Install the MCP server into a Python venv** (Python 3.10+):
```bash
python -m venv <path>/opensearch-mcp-venv
<path>/opensearch-mcp-venv/Scripts/python -m pip install opensearch-mcp-server-py
# (macOS/Linux: <path>/opensearch-mcp-venv/bin/python)
```
It provides the `mcp_server_opensearch` module, run as
`python -m mcp_server_opensearch` (stdio).

**b. Get aes.sonar credentials.** Use a service account with **read-only**
access to the log indices — request one from the team that owns aes.sonar; do
not use a personal SSO login. You need a URL, username, and password.

**c. Register the `opensearch` MCP server** (user scope). Either via CLI:
```bash
claude mcp add opensearch --scope user \
  -e OPENSEARCH_URL=https://aes.sonar.workwave.com \
  -e OPENSEARCH_USERNAME='<service-account-user>' \
  -e OPENSEARCH_PASSWORD='<service-account-password>' \
  -- <path>/opensearch-mcp-venv/Scripts/python -m mcp_server_opensearch
```
…or by adding this block to `mcpServers` in your **user** `~/.claude.json`
(keep credentials out of the repo):
```json
"opensearch": {
  "type": "stdio",
  "command": "<path>/opensearch-mcp-venv/Scripts/python.exe",
  "args": ["-m", "mcp_server_opensearch"],
  "env": {
    "OPENSEARCH_URL": "https://aes.sonar.workwave.com",
    "OPENSEARCH_USERNAME": "<service-account-user>",
    "OPENSEARCH_PASSWORD": "<service-account-password>"
  }
}
```

**d. Reconnect** with `/mcp` and confirm `opensearch` is connected. If the
server is unavailable or rejects auth, the log step skips with a note and the
investigation proceeds.

### 6. Install the plugin
Run these inside Claude Code (uses your existing git credentials — the same
access you use to clone WorkWave repos):
```
/plugin marketplace add WorkWave/pphv-plugin-skills
/plugin install pestpac-devsupport@pestpac
```

Verify: run `/plugin` and confirm `pestpac-devsupport` is enabled.

To pick up new changes:
```
/plugin marketplace update pestpac
/plugin install pestpac-devsupport@pestpac
```

## Data sources & guarantees

| Source | Mechanism | Mode |
|--------|-----------|------|
| Jira   | Atlassian MCP | read-only |
| Code   | local git + ripgrep; `gh` for PRs | read-only |
| SQL    | `sqlcmd` via `sql-readonly.sh` | SELECT-only |
| Slack  | Slack plugin (`plugin:slack:slack`), public-channel search/read tools only | read-only, public channels only, optional |
| Regression | `git log`/`blame` + `gh` PRs over the ticket's time window | read-only |
| Confluence | CQL search via the Atlassian MCP | read-only |
| Logs | aes.sonar OpenSearch (`iislogstash-*`/`pestpacapi-*`/`winlogbeat-*`) via OpenSearch MCP | read-only, conditional |
| Automation suite | `WorkWave/TestAutomation-PestPac` via the `gh` API (no local clone) | read-only, `qe-steps` only |
| Unit / integration tests | `Grep`/`Read` over `C:\PestPac.NET` test projects (never executed) | read-only, `qe-steps` only |
| Xray test repository | Jira `issuetype in (Test, Test Set, Test Plan, Precondition)` via the Atlassian MCP | read-only, `qe-steps` only |
| Jira comment + attachment | Atlassian MCP `addCommentToJiraIssue` (+ attachment) | **write — `qe-steps` only, gated on explicit confirmation** |

The investigation fans out to six parallel agents — `jira-similar`,
`code-investigator`, `sql-inspector`, `slack-searcher`, `regression-hunter`
(ranks recent changes that could have caused the issue, or reports "no
regression signal" when the area hasn't changed), and `confluence-docs`
(design/runbook/known-issue pages for the intended flow — context only, never
overriding code/SQL) — then synthesizes one inline report.

A seventh agent, `log-searcher`, is dispatched **conditionally** — only when the
ticket has a 6-digit company key AND the issue would leave a runtime log trace
(HTTP/API errors, 500s, timeouts, intermittent failures). It searches the
aes.sonar OpenSearch indices for that tenant (`company_key` in `iislogstash-*`,
`cokey` in `pestpacapi-*`; `winlogbeat-*` is correlated by host since it has no
tenant field). It is skipped for code-style/design/feature/data-only tickets.

### QE handoff (`qe-steps`)

`/pestpac-devsupport:qe-steps` runs the `qe-analysis` skill. It reuses a
root-cause investigation already in the conversation for the same ticket, or runs
the full `ticket-investigation` fan-out if there isn't one, then adds two agents:

- **`automation-coverage`** — searches `WorkWave/TestAutomation-PestPac`
  (Reqnroll · NUnit · Playwright) over the `gh` API for `.feature` scenarios that
  already cover the impacted areas, the reusable business-intent step vocabulary,
  the scenario tags, the right target project (`PestPacTest` / `PestPacAPI` /
  `PestPacUI`), and the shared test accounts those tests use — **and** mines the
  unit/integration tests in the local `C:\PestPac.NET` clone
  (`API/tests/PestPacApi.UnitTests` xUnit+Moq, `PestPacApi.IntegrationTests`,
  `UnitTests/tests`, `src/test/server/handlers`) for the behaviors they assert.
  No local clone of the BDD suite is required; if `gh` is unavailable the BDD
  half is reported as **unknown** rather than empty and the local half still runs.
- **`xray-test-repo`** — searches the **PES Xray Test Repository** in Jira
  (`issuetype in (Test, "Test Set")`) for test cases that already cover the area.
  PES stores test content in the issue **`description`** — either structured
  (`### Scenario` / `### Preconditions` / `### Acceptance Criteria`) or as a
  one-line `Verify …` statement — rather than in Xray's manual-steps table, so
  the standard Jira API returns everything. The agent also reads `Automation
  Status`, `Test Category`, and the parent Test Set, and excludes tests labelled
  `DeleteMe` or closed-as-removed from a cycle.
- **`qe-test-designer`** — designs the manual test cases (new behavior **and**
  regression surface) plus the test-data plan, and assembles the playbook.
  Test data prefers API/UI seeding; SQL is a fallback emitted as **text only**,
  transaction-wrapped, and is never executed.

`confluence-docs` is also dispatched, scoped to **test procedures** (QA plans,
runbooks, "how to test X") rather than design intent.

**Steps are reused, not invented.** The designer draws from, in order: the Xray
test repository → the ticket and its linked issues → BDD `.feature` scenarios →
unit/integration assertions → Confluence test procedures. Every test case in the
comment carries a `source:`, and `authored` is only used once all five came up
empty for that behavior.

Two artifacts come out:

| Artifact | Audience | Delivery |
|---|---|---|
| QA Test Specification comment | the QE engineer executing the tests | posted to the ticket after you confirm |
| `<TICKET-ID>.yaml` playbook | the test-authoring plugin | assembled **in memory**, attached to the ticket (embedded as a fenced `yaml` block in the comment if attachment upload isn't available) |

The comment follows the PestPac house format (see PES-5717 for a worked
example): a `Scope` / `Reference environment` / `Related` header, then cases
grouped into **Happy Path & Core Scenarios**, an optional domain-specific
correctness section, **Regression & Blast-Radius**, **Cross-Browser & Visual**,
and **Edge Cases**, closing with a **Critical Edge Cases Summary** that triages
every case into Must / Should / Nice-to-Have. Each case is
`TC-<TICKET-ID>-<NNN>` with five fields — `Type`, `Preconditions`, `Steps`,
`Expected Results`, `Pass Criteria`.

Nothing is written to disk, and nothing is posted or attached until the drafted
comment has been shown in full and confirmed.

## Tests

```
bash scripts/tests/test_sql_readonly.sh
bash scripts/tests/test_slack_search.sh
```

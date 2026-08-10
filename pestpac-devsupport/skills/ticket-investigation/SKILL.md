---
name: ticket-investigation
description: Use when given a Jira ticket ID to investigate. Fetches the ticket, fans out to six parallel subagents (Jira-similar, code, SQL, Slack, regression, Confluence docs), and produces an inline root-cause analysis with suggested changes. Read-only; posts nothing.
---

# Ticket Investigation

You investigate a Jira ticket end to end and produce an inline report. You are
given a ticket ID (e.g. `PES-1234`).

## Step 1 — Fetch & triage (do this yourself, first)

Use the Atlassian MCP `getJiraIssue` to fetch summary, description, status,
type, components, labels, comments, and linked issues. Then extract an
**entities payload**:
- keywords / feature area
- error strings (verbatim)
- table and stored-procedure names
- file hints (ASP / C# / SQL paths or symbol names)
- report date + product version (the ticket created/reported date and any
  `PSUB`/version string, and a "last known good" date/version if the ticket
  states one) — for the regression check
- company key (the 6-digit tenant key) and env (prod/staging) if the ticket
  mentions them — for the log search

If the ID is malformed or the ticket is not found, say so and stop.

## Step 2 — Fan out (parallel)

Dispatch the core six subagents concurrently (a single message with six Agent
calls), passing the entities payload to each:
- `jira-similar`
- `code-investigator`
- `sql-inspector`
- `slack-searcher`
- `regression-hunter` (pass the report date / version so it can scope the window)
- `confluence-docs`

Each returns a `## Findings` + `## Confidence` block. Treat "not applicable",
"none found", "Slack skipped", "no regression signal", and "no relevant
Confluence pages found" as valid results, not failures.

### Conditionally: `log-searcher`
Dispatch `log-searcher` **only when it is needed** — do not run it by default.
Add it to the fan-out (pass the company key, env, report window, and error /
route keywords) **only if BOTH** hold:
1. the ticket contains a **company key**, and
2. the issue would leave a runtime log trace — HTTP/API errors, 500s,
   timeouts/slowness, intermittent failures, white-screen/runtime errors.

Skip it for pure code-style, design, feature-request, or data-only tickets, and
whenever no company key is present. It queries the aes.sonar logs directly through
the OpenSearch MCP server (no browser/SSO). A "logs skipped — opensearch MCP
unavailable" or "not applicable — no company key" result is valid, not a failure.

## Step 3 — Synthesize (inline only)

Produce ONE inline report. Write nothing to disk; post nothing anywhere.

### <TICKET-ID> — <summary>
**Ticket summary:** <2-3 sentences>

**Regression assessment:** <is this a recent regression or a long-standing
issue/data condition? cite the regression-hunter's verdict + window>

**Root-cause hypothesis (ranked):**
1. <hypothesis> — confidence <high|med|low> — based on <which evidence>
2. ...

**Evidence:**
- Code: `file:line` — <why>
- SQL: <object> — <observation>
- Similar tickets: `<KEY>` — <resolution>
- Slack: <channel/permalink> — <snippet>
- Regression suspects: `<sha>`/`#PR` <date> — <why> (or "no recent changes to the area")
- Docs (intent): "<Confluence page>" — <how it informs the flow> (note any doc-vs-code conflict; code/SQL win)
- Logs: <index> `<@timestamp>` <status/level> <request/route> — <observation> (only if `log-searcher` ran; else omit)

**Suggested changes:** <concrete, pointing at files/objects>

**Gaps:** <what could not be checked — e.g. Slack token missing, gh absent,
no DB objects referenced>

## Rules
- Read-only everywhere. No file writes. No Jira/Slack/Confluence posting. No SQL writes.
- Do not invent evidence. If a source returned nothing, say so under Gaps.
- Confluence docs are intent/context, not ground truth. When a doc conflicts
  with the code or SQL findings, trust code/SQL and flag the discrepancy.
- **Do not collapse multiple code paths into one.** If `code-investigator`
  reports more than one execution/delivery path (e.g. legacy in-process vs
  queue/SQS/Lambda), keep them distinct in the report. Before calling any
  table or log "the authoritative record" or "where to look first," tie the
  claim to the specific path **and** the environment/tenant active in this
  ticket — and note when another path would leave the evidence somewhere else
  (a different table, CloudWatch, an external service). An artifact being empty
  is only evidence for the path that writes it. If it's unclear which path is
  live for the tenant, rank it as a hypothesis and put "confirm active path"
  in Suggested changes — never assert one artifact settles the question.

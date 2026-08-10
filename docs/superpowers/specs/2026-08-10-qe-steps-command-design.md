# Design — `qe-steps`: QA-automation handoff command

**Date:** 2026-08-10
**Status:** Implemented 2026-08-10 — `commands/qe-steps.md`,
`skills/qe-analysis/SKILL.md`, `agents/automation-coverage.md`,
`agents/xray-test-repo.md`, `agents/qe-test-designer.md`. The QE spec comment
template lives in Step 6 of the skill and is the source of truth for the comment
shape.

**Amended 2026-08-10** — the design assumed a single coverage source (the BDD
suite). Widened to five step sources, in reuse order: Xray test repository →
ticket + linked issues → BDD `.feature` scenarios → local unit/integration test
assertions → Confluence test procedures. This added a third agent
(`xray-test-repo`), extended `automation-coverage` to read `C:\PestPac.NET` test
projects, and added `source:` provenance to every test case.
**Plugin:** `pestpac-devsupport` (in `WorkWave/pphv-plugin-skills`)

## Problem

Today the plugin's `analyze-ticket` command investigates a Jira ticket and
produces an inline root-cause report. Nothing bridges that analysis to QA
automation. A QE engineer still has to, by hand: work out what areas the fix
impacts, decide what to test, check whether the automation suite already covers
it, design test cases, figure out test-data setup, and write it all up on the
ticket.

We want a **separate command** that runs after (or instead of) investigation
and turns a ticket into a QE handoff:

1. Identify impacted areas (what a fix touches / what could regress).
2. Produce **manual QE test-case steps** and add them to the ticket.
3. Produce a **test-data setup plan** — via API/UI steps where the framework
   supports it, or a generated (never-executed) SQL seed script as a fallback.
4. Emit a **machine-readable playbook** carrying everything the *next* plugin (a
   Playwright/Reqnroll test-authoring plugin, built separately) needs to
   generate automated tests.
5. Post a comment to the ticket with the human-facing info — **only after
   explicit confirmation.**

## Context — the two repos involved

- **`WorkWave/pphv-plugin-skills`** (this repo) — the `pestpac-devsupport`
  plugin. Read-only investigation harness: `analyze-ticket` → `ticket-investigation`
  skill → parallel fan-out agents (`code-investigator`, `sql-inspector`,
  `regression-hunter`, `jira-similar`, `slack-searcher`, `confluence-docs`, and
  conditionally `log-searcher`) → inline report. Posts and writes nothing.
- **`WorkWave/TestAutomation-PestPac`** — the automation suite the next plugin
  authors into. **Reqnroll (SpecFlow) 3.2.0 · NUnit · Playwright** BDD.
  Gherkin `.feature` files with a reusable, business-vocabulary step library and
  C# step definitions. Three test projects:
  - `PestPacTest` — the main UI/e2e suite (`Features/`, `Steps/`).
  - `PestPacAPI` — API-level tests.
  - `PestPacUI` — newer UI feature area (e.g. `SOGenerate`); hosts
    `PestPacUI/.claude/codegen-local`, likely where the future authoring plugin
    operates.
  Conventions that matter for the handoff: feature-area tags (`@ServiceOrder`),
  regression tags (`@Regression_Full`, `@Regression_Short`, `@Sanity`),
  parallelism tags (`@Parallel_*`, `@NonParallelizable`); steps express business
  intent, not UI mechanics; tests reference shared test accounts / company keys
  (e.g. `AccountNumber 100204`, `Location ID 206`).

The automation repo is read over the **`gh` API** — this plugin does **not**
assume a local clone of it.

## Decisions (from brainstorming)

| # | Decision |
|---|----------|
| Input | **Hybrid**: reuse an investigation report already in the conversation for the same ticket; otherwise run the **full** `ticket-investigation` fan-out first. |
| Handoff | **Two artifacts**: a human-readable Jira comment (manual test cases) **and** a machine-readable playbook attached to the ticket. |
| QE step form | Jira comment carries **manual test-case steps** (preconditions / actions / expected results). Gherkin/automation specifics live in the playbook, not the comment. |
| Test data | **Prefer API/UI seeding** described as steps; emit SQL **only as a fallback**, and only as generated text — **never executed** (read-only guarantee preserved). |
| Automation-repo access | **`gh` API only** (no local-clone dependency). |
| New agents | **Three**: `automation-coverage`, `xray-test-repo`, `qe-test-designer`. (`xray-test-repo` added in the 2026-08-10 amendment.) |
| Step sources | **Reuse before authoring**, in order: Xray test repository → ticket + linked issues → BDD `.feature` scenarios → local unit/integration assertions → Confluence test procedures. Every case carries a `source:`; `authored` only when all five are empty for that behavior. |
| Playbook delivery | **Kept in memory — no local file is written.** Serialized as `<TICKET-ID>.yaml` and **attached to the Jira ticket** next to the comment. If attachment upload isn't available, fall back to embedding it as a fenced ` ```yaml ` block in the comment. |
| Posting | Draft, **show, confirm, then post** via `mcp__atlassian__addCommentToJiraIssue` (+ attach the playbook). Never post/attach without confirmation. Fallback to "paste/save this yourself" if the write tools are unavailable. |

## Architecture

New pieces (all in `pestpac-devsupport/`):

| Piece | Type | Responsibility |
|---|---|---|
| `commands/qe-steps.md` | command | Entry point. `argument-hint: <TICKET-ID>`. Invokes the `qe-analysis` skill; asks for a ticket ID if `$ARGUMENTS` is empty. |
| `skills/qe-analysis/SKILL.md` | skill | Orchestrator (see flow). Owns triage, investigation reuse/dispatch, agent fan-out, in-memory playbook assembly, and the confirm-then-post/attach gate. Writes nothing to the local filesystem. |
| `agents/automation-coverage.md` | **new agent** | Given impacted areas / feature names / keywords, searches `WorkWave/TestAutomation-PestPac` via `gh` for existing `.feature` scenarios that cover the area, their tags, the reusable step vocabulary available, the right target project (`PestPacTest` / `PestPacAPI` / `PestPacUI`), and the test accounts/company keys those tests use. Returns a coverage map + reusable steps + gaps. Tools: `Bash` (gh), `Grep`, `Read`. |
| `agents/qe-test-designer.md` | **new agent** | Given impacted areas + coverage map + gaps + data model, designs the manual test cases (new-behavior + regression) and the test-data plan, and assembles the playbook object. Read-only; proposes, never posts. Tools: `Read`, `Grep` (+ `Bash` only if it needs read-only `gh`/SQL grounding). |

Reused as-is: `ticket-investigation` skill and its agents (`code-investigator`,
`regression-hunter`, `sql-inspector`, etc.).

### Why two new agents

- `automation-coverage` is a clean, isolated unit: input = impacted-area
  entities; output = "what the suite already does here + what's reusable + where
  the gaps are." It only talks to the automation repo via `gh`.
- `qe-test-designer` is the reasoning unit: input = impacted areas + coverage +
  data model; output = test cases + data plan + playbook. Separating it keeps the
  orchestrating skill thin and makes the design step independently testable and
  swappable.

## Flow (the `qe-analysis` skill)

1. **Triage.** Fetch the ticket (read-only Atlassian MCP). Extract the entities
   payload (feature area, error strings, tables/procs, file hints, report
   date/version, company key/env) — same shape `ticket-investigation` uses.
   Malformed/not-found → say so and stop.

2. **Investigation (hybrid).**
   - If the conversation already contains a root-cause investigation for this
     ticket ID, reuse it.
   - Otherwise, run the **full `ticket-investigation`** procedure and use its
     synthesized findings.
   The output of this step is a set of **impacted areas** (code paths, data
   objects, recent-change risk).

3. **Coverage (parallel with data-model grounding).** Dispatch:
   - `automation-coverage` — impacted areas → existing coverage + reusable steps
     + gaps + target project + test accounts.
   - `sql-inspector` (only if the ticket implies test-data setup) — read-only
     confirmation that any tables/columns/keys a seed would touch actually exist.

4. **Design.** Dispatch `qe-test-designer` with impacted areas + coverage map +
   data-model facts. It returns:
   - **Manual QE test cases** — preconditions, steps, expected results; covering
     the new/changed behavior *and* the regression surface the fix could break.
   - **Test-data plan** — `method: api_ui` with steps where the framework
     supports it; otherwise `method: sql_fallback` with a generated,
     transaction-wrapped seed script as **text only**.
   - The assembled **playbook** object.

5. **Assemble playbook (in memory).** Serialize the playbook object to YAML as
   `<TICKET-ID>.yaml`. **No local file is written** — it is held in memory for
   the next step.

6. **Draft, confirm, then post + attach.** Render the Jira comment (manual test
   cases + impacted-areas summary + a note that the automation playbook is
   attached). **Show the comment in full, ask the user to confirm.** On yes:
   - post the comment via `mcp__atlassian__addCommentToJiraIssue`, and
   - attach `<TICKET-ID>.yaml` to the ticket (attachment-capable tool /
     Atlassian REST). If attachment upload is unavailable, embed the playbook as
     a fenced ` ```yaml ` block in the comment instead.
   On no → post/attach nothing. If Jira write is entirely unavailable, print both
   the comment and the playbook YAML for the user to paste/save manually.

## Playbook schema

Assembled in memory and serialized as the YAML attached to the ticket. Fields:

```yaml
ticket: PES-1234
summary: <one line>
generated: <ISO timestamp>            # stamped by the skill
impacted_areas:
  - area: <feature/module>
    why: <what the fix touches / regression risk>
target_project: PestPacTest           # PestPacTest | PestPacAPI | PestPacUI
existing_coverage:
  - feature: PestPacTest/Features/ServiceOrder.feature
    scenarios: ["Service Order - Add From Golden Button"]
    tags: ["@ServiceOrder", "@Regression_Short"]
reusable_steps:                        # business-intent steps already in the repo
  - "ServiceOrder Create"
  - "Service order was created"
new_steps_needed:                      # business-intent steps not yet in the repo
  - "<step the author will need to implement>"
test_data:
  method: api_ui                       # api_ui | sql_fallback
  accounts: ["100204"]                 # shared test accounts / company keys
  steps: [...]                         # when method: api_ui
  sql_fallback: |                      # when method: sql_fallback — TEXT ONLY, never executed
    BEGIN TRAN
    -- grounded seed INSERTs against a test company key
    ROLLBACK   -- author flips to COMMIT after review
manual_test_cases:
  - title: ...
    type: new | regression
    preconditions: [...]
    steps: [...]
    expected: [...]
suggested_tags: ["@Sanity", "@Regression_Short"]
gaps: [...]                            # what couldn't be determined and why
```

The Jira comment is a human-readable rendering of `manual_test_cases` +
`impacted_areas` + `test_data` + a one-line note that the playbook is attached; it
deliberately omits `reusable_steps` / `new_steps_needed` / `target_project` /
`suggested_tags` (automation-only).

### QA Test Specification comment shape

Derived from the real house format — see **PES-5717 comment 1248537** for the
worked example this was reverse-engineered from. The exact template is in
**Step 6 of `skills/qe-analysis/SKILL.md`**; treat that as authoritative and keep
this section as a summary.

Header:
1. `# QA TEST SPECIFICATION: <TICKET-ID> — <title>`
2. **Scope** — what changed + blast radius; states plainly when no functional
   logic changed
3. **Reference environment** — URL + creds
4. **Related** — Jira key · fix PR · root-cause PR

Sections, `---`-separated, cases numbered continuously from `001`:

| Section | Notes |
|---|---|
| Happy Path & Core Scenarios | Always present |
| `<Domain>` Correctness Tests | Optional; named for the actual concern (encoding, permissions, rounding) |
| Regression & Blast-Radius Tests | Every consumer of the changed code |
| Cross-Browser & Visual | Omit if rendering can't be affected |
| Edge Cases | Boundaries, adjacency, metadata, round-trip |
| Critical Edge Cases Summary | Must / Should / Nice-to-Have buckets referencing `TC-NNN` |

Each case is `### TC-<TICKET-ID>-<NNN>: <title>` with exactly five fields in
order — **Type**, **Preconditions**, **Steps**, **Expected Results**, **Pass
Criteria**. Steps are inline-numbered on one line (`1. … 2. … 3. …`), not a
bulleted list. `Type` ∈ {`E2E`, `Integration`, `Integration / File-level`,
`E2E / Regression`, `E2E / Smoke`, `UI / Cross-browser`, `UI / Visual`}.
Expected Results (observation) and Pass Criteria (binary verdict) are distinct.

### How PES actually stores Xray tests

Confirmed against the live instance, and it contradicts the obvious assumption:
`Test` issues (`issuetype` id `10414`) keep their content in the **`description`
field**, not in Xray manual-step custom fields — none are populated. Two shapes
are in use: structured (`### Scenario` / `### Preconditions` / `### Acceptance
Criteria`) and a one-line `Verify …`. The meaningful Xray fields are
`customfield_10594` Test Category, `customfield_10596` Automation Status, and
`customfield_10972` QA Story Points. Tests group into **Test Set** issues that
hang off a story. Tests labelled `DeleteMe`, or closed with a comment saying they
were dropped from a cycle, must be excluded — `Done` does not mean "executed".

## Guarantees & graceful degradation

- **Local filesystem stays fully read-only.** The playbook is held in memory and
  attached to the ticket — nothing is written to disk. The only writes anywhere
  are the Jira comment + attachment, and only after explicit confirmation. SQL
  remains SELECT-only — fallback seed SQL is emitted as text and never routed to
  execution.
- **Degrades like the rest of the plugin:**
  - no `gh` → `automation-coverage` reports it and the rest proceeds (no
    coverage map; `new_steps_needed` marked "unknown — repo not searched").
  - no attachment capability → playbook embedded as a fenced ` ```yaml ` block in
    the comment.
  - Atlassian write tools absent entirely → comment + playbook printed for manual
    paste/save.
  - no SQL access → data plan falls back to API/UI steps or notes the gap.

## Documentation & tests

- Update `pestpac-devsupport/README.md`: new `qe-steps` command usage, the two
  new agents, the in-memory playbook + Jira-attachment handoff, and the gated
  Jira writes (comment + attachment, with the confirm requirement) in the
  guarantees table.
- No local playbook directory and no `.gitignore` change — nothing is written to
  disk.
- No new shell scripts are expected (access is via `gh`/MCP), so no new
  `scripts/tests/*` are required. If a helper script is introduced during
  implementation, it gets a matching test in the existing style
  (`test_sql_readonly.sh` / `test_slack_search.sh`).

## Out of scope

- The Playwright/Reqnroll authoring plugin that consumes the playbook (separate
  effort).
- Executing seed SQL, running tests, or opening PRs against the automation repo.
- Modifying `analyze-ticket` / `ticket-investigation` beyond reusing them.

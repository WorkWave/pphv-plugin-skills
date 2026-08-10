---
name: qe-analysis
description: Use when a Jira ticket needs a QE handoff rather than a root-cause report — "what should QA test for this", "write the QE spec", "add test steps to the ticket", "what regresses if we ship this". Produces a QA Test Specification comment, a test-data plan, and an automation playbook, and posts to the ticket only after explicit confirmation.
---

# QE Analysis

You turn a Jira ticket into a QE handoff. You are given a ticket ID (e.g.
`PES-1234`).

Two artifacts come out of this:
1. a **QA Test Specification comment** posted to the ticket — human-facing, for
   the QE engineer who will execute the tests, and
2. an **automation playbook** (`<TICKET-ID>.yaml`) attached to the ticket —
   machine-readable, for the test-authoring plugin that consumes it.

**The local filesystem stays read-only.** The playbook is assembled in memory and
attached to the ticket; no file is written to disk. The only writes anywhere are
the Jira comment and attachment, and only after the user confirms.

## Step 1 — Fetch & triage (do this yourself, first)

Use the Atlassian MCP `getJiraIssue` to fetch summary, description, status, type,
components, labels, comments, and linked issues. Extract the same **entities
payload** `ticket-investigation` uses:
- keywords / feature area
- error strings (verbatim)
- table and stored-procedure names
- file hints (ASP / C# / SQL paths or symbol names)
- report date + product version
- company key (6-digit tenant key) and env, if present

Also pull, because the spec header needs them:
- the **reference/test environment URL and credentials** if any comment states
  them (QA comments often read `http://crossbrowser.pes-0-XXXX.pestpac.local/ —
  creds 00XXXX / admn`),
- the **fix PR** and the **root-cause PR** if referenced.

If the ID is malformed or the ticket is not found, say so and stop.

## Step 2 — Investigation (hybrid)

- **If the conversation already contains a root-cause investigation for this same
  ticket ID, reuse it.** Do not re-run the fan-out.
- Otherwise, run the **full `ticket-investigation`** procedure and use its
  synthesized findings.

The output of this step is a set of **impacted areas**: code paths, data objects,
and recent-change risk — what a fix touches, and what could regress around it.

For a shared include, common helper, or config file, the impacted area is
**every consumer of it**, not just the screen in the ticket. Say so explicitly —
the blast radius drives the Regression section of the spec.

## Step 3 — Coverage (parallel)

**Do not invent test steps that already exist somewhere.** Before designing
anything, find what PestPac already says about testing this area. Dispatch
concurrently (a single message with all applicable Agent calls):

- **`automation-coverage`** — impacted areas, feature names, keywords. Returns
  the BDD suite's existing scenarios / reusable steps / tags / target project /
  test accounts, **and** the behaviors asserted by the unit and integration tests
  in the local `C:\PestPac.NET` clone (`API/tests/PestPacApi.UnitTests`,
  `PestPacApi.IntegrationTests`, `UnitTests/tests`, `src/test/server/handlers`).
- **`xray-test-repo`** — impacted areas and keywords. Returns the `Test` issues
  that already exist in the **PES Xray Test Repository**, with their
  Scenario / Preconditions / Acceptance Criteria and automation status.
- **`confluence-docs`** — scope the search to **test procedures**: QA test plans,
  runbooks, "how to test X" and known-issue pages for this area, not just design
  intent.
- **`sql-inspector`** — **only if the ticket implies test-data setup.** Read-only
  confirmation that the tables/columns/keys a seed would touch actually exist.
  Skip it otherwise.

Also mine **the ticket itself and its linked issues** (you already have them from
Step 1): steps-to-reproduce, acceptance criteria, and any existing QA-steps
comment are first-class step sources.

"Not searched — `gh` unavailable" and "Xray not searched — Atlassian MCP
unavailable" are valid results, not failures. Carry them through as **unknown**,
never as "no coverage exists."

## Step 4 — Design

Dispatch `qe-test-designer` with impacted areas + coverage map + Xray tests +
Confluence test procedures + data-model facts. It returns the test cases, the
test-data plan (`api_ui` preferred, `sql_fallback` as text only), and the
assembled playbook.

**Reuse before you author.** Steps come from existing sources in this order, and
you author a new step only when none of them covers it:

| Order | Source | What it gives you |
|---|---|---|
| 1 | Xray test repository | Established scenarios and the team's wording — reuse verbatim |
| 2 | Ticket + linked issues | Steps-to-reproduce, acceptance criteria, existing QA-steps comment |
| 3 | BDD `.feature` scenarios | Business-intent flows already automated |
| 4 | Unit / integration assertions | Precise expected results and edge-case inputs |
| 5 | Confluence test procedures | Setup, environment, and known-issue caveats |

When a case comes from an existing source, record it (`PES-4803`,
`ServiceOrder.feature`, `<Test>.cs:LINE`) in the playbook so the reviewer can
check it.

## Step 5 — Assemble the playbook (in memory)

Serialize the playbook to YAML as `<TICKET-ID>.yaml`. **Write no local file** —
hold it in memory for Step 7.

```yaml
ticket: PES-1234
summary: <one line>
generated: <ISO timestamp>            # stamp this yourself
scope: <one line — what changed and the blast radius>
reference_env:
  url: http://crossbrowser.pes-0-XXXX.pestpac.local/
  creds: 00XXXX / admn
related:
  fix_pr: "#12914"
  root_cause_pr: "#12479"             # the PR that introduced the bug, if known
impacted_areas:
  - area: <feature/module>
    why: <what the fix touches / regression risk>
target_project: PestPacTest           # PestPacTest | PestPacAPI | PestPacUI
existing_coverage:
  - feature: PestPacTest/Features/ServiceOrder.feature
    scenarios: ["Service Order - Add From Golden Button"]
    tags: ["@ServiceOrder", "@Regression_Short"]
existing_xray_tests:                   # Test issues already in the PES repository
  - key: PES-4803
    summary: <one line>
    automation_status: Not Automated   # Xray "Automation Status"
    reused: true | false
unit_coverage:                         # asserted behavior from the local clone
  - test: API/tests/PestPacApi.UnitTests/<File>.cs:LINE
    asserts: <behavior in plain language>
reusable_steps:                        # business-intent steps already in the repo
  - "ServiceOrder Create"
new_steps_needed:                      # not yet in the repo
  - "<step the author will need to implement>"
test_data:
  method: api_ui                       # api_ui | sql_fallback
  accounts: ["100204"]
  steps: [...]                         # when method: api_ui
  sql_fallback: |                      # when method: sql_fallback — TEXT ONLY, never executed
    BEGIN TRAN
    -- grounded seed INSERTs against a test company key
    ROLLBACK   -- author flips to COMMIT after review
test_cases:
  - id: TC-PES-1234-001
    title: ...
    section: core                      # core | <domain> | regression | cross_browser | edge
    type: E2E                          # see the Type vocabulary in Step 6
    priority: must | should | nice
    source: PES-4803 | ServiceOrder.feature | <Test>.cs:LINE | ticket | authored
    preconditions: ...
    steps: [...]
    expected: ...
    pass_criteria: ...
suggested_tags: ["@Sanity", "@Regression_Short"]
gaps: [...]
```

## Step 6 — Render the QA Test Specification comment

This is the PestPac house format. Follow it exactly — QE reads these across
tickets and the shape is expected.

### Template

````markdown
# QA TEST SPECIFICATION: <TICKET-ID> — <Short descriptive title>

**Scope:** <What changed and why it matters, then the blast radius. Name the
shared file/module if one is involved and list every surface it reaches. State
plainly when no functional logic changed.>

**Reference environment:** `<url>` — creds `<companykey> / <user>`

**Related:** Jira <TICKET-ID> · PR [#<fix>](<url>) (<branch>) · Root-cause PR
#<origin> (<KEY>)

---

## Happy Path & Core Scenarios

### TC-<TICKET-ID>-001: <title>

**Type:** E2E

**Preconditions:** <state that must exist before step 1>

**Steps:** 1. <action> 2. <action> 3. <action>

**Expected Results:** <what the tester should observe>

**Pass Criteria:** <the binary condition that decides pass/fail>

---

## <Domain-Specific Correctness Tests>

<Optional. Name it for the actual concern — "Encoding Correctness Tests",
"Permission Enforcement Tests", "Rounding & Totals Tests". Omit the section
entirely if the fix has no such concern.>

---

## Regression & Blast-Radius Tests

<Every consumer of the changed code. Include a "no functional regression from
the change itself" case and an "unaffected common case still works" case.>

---

## Cross-Browser & Visual

<Chrome, Edge, Firefox; print preview where printing is involved; layout with
long or unusual content. Omit if the change cannot affect rendering.>

---

## Edge Cases

<Boundaries, adjacency, metadata fields, round-trip edit/re-save.>

---

## Critical Edge Cases Summary

**Must Test (Blocking):**

* <label> (TC-001) — <why it blocks>

**Should Test (Important):**

* <label> (TC-007)

**Nice-to-Have:**

* <label> (TC-014)

---
````

### Rules for filling it

- **IDs** are `TC-<TICKET-ID>-<NNN>`, zero-padded to three digits, numbered
  continuously across all sections starting at `001`. The summary at the end
  refers to them in short form (`TC-001`).
- **Every case has all five fields** — `Type`, `Preconditions`, `Steps`,
  `Expected Results`, `Pass Criteria` — in that order. Never drop one.
- **Steps are inline and numbered on one line**: `1. Login 2. Navigate to a
  location 3. Documents → Add Letter`. Not a bulleted list, not one per line.
- **`Type` vocabulary** — pick one, compounding with `/` where it applies:
  `E2E`, `Integration`, `Integration / File-level`, `E2E / Regression`,
  `E2E / Smoke`, `UI / Cross-browser`, `UI / Visual`.
- **`Expected Results` vs `Pass Criteria`** are different. Expected Results
  describes what the tester observes; Pass Criteria is the binary condition that
  decides the verdict. Do not repeat one in the other.
- **Expected results must be observable** — a value, message, glyph, row, or
  state. Never "works correctly" or "no errors".
- **Every case lands in exactly one section**, and every section that appears
  has at least one case. Omit a section rather than leaving it empty.
- **The summary buckets are a triage aid**, not a repeat of the cases: one short
  label per line, the TC number, and for Must-Test a reason. Every case appears
  in exactly one bucket.
- Use only real seeded accounts and confirmed schema. Anything unverified goes
  in the playbook's `gaps` and is called out in **Scope** — never silently
  guessed.
- Include the test-data plan under **Preconditions** of the cases that need it.
  When `method: sql_fallback`, say "seed script attached in the playbook — DBA
  review required before running"; never inline the SQL in the comment.

The comment omits `target_project`, `reusable_steps`, `new_steps_needed`,
`suggested_tags`, and `source` — those are automation-only and live in the
playbook.

## Step 7 — Confirm, then post + attach

**Show the rendered comment in full and ask the user to confirm before any write.**

On **yes**:
1. Post the comment with `mcp__atlassian__addCommentToJiraIssue`.
2. Attach `<TICKET-ID>.yaml` to the ticket. If attachment upload is unavailable,
   embed the playbook as a fenced ` ```yaml ` block at the end of the comment
   instead, and say that you did.

On **no** → post nothing, attach nothing.

If Jira write tools are unavailable entirely, print both the comment and the
playbook YAML for the user to paste and save manually.

## Rules
- **Never post or attach without explicit confirmation.** Not for "obvious"
  tickets, not because the user ran the command, not because you already showed
  a draft earlier in the conversation. The confirmation is per post.
- **No local file writes.** The playbook lives in memory until it is attached.
- **SQL stays SELECT-only.** Fallback seed SQL is emitted as text and never
  routed to execution — not by you, not by a subagent.
- **Do not invent evidence.** Unconfirmed schema, accounts, step names, or
  coverage go in `gaps` with the reason. "Repo not searched" means unknown, not
  empty.
- **Do not create Jira issues.** Turning spec cases into Xray `Test` issues is a
  separate, explicitly-requested action — this skill only comments and attaches.
- Degrade like the rest of the plugin: no `gh` → no BDD coverage map, note it; no
  SQL access → API/UI plan or a stated gap; no attachment capability → embed the
  YAML in the comment.

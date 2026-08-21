---
description: Turn a Jira ticket into a QE handoff — impacted areas, manual test cases, test-data plan — scoped to the impacted area of the fix or a full regression pass, then post a QE spec comment to the ticket after you confirm it.
argument-hint: <TICKET-ID> [focused|full]
---

The user wants a QE handoff for Jira ticket: **$ARGUMENTS**

Invoke the `qe-analysis` skill and run its full procedure for this ticket ID.

**Ask the spec-scope question first — before fetching the ticket, before any
search, before any subagent.** That is the skill's Step 1 and it is not optional:

- `focused` / "impacted scope only" → `scope_mode: focused` — **only what the fix
  touches**: the changed behavior and proof the change did not break its own flow,
  plus a Deferred Coverage section naming what a full spec would have added.
- `full` / "full regression" → `scope_mode: full` — the impacted scope plus every
  other consumer of the changed code, the full cross-browser matrix, and the full
  edge-case sweep.

Skip the question **only** when `$ARGUMENTS` already carries the scope; then echo
the mode you read in one line. Never default to one because the ticket looks small
or large.

If `$ARGUMENTS` has no ticket ID, ask for one — alongside the scope question, not
instead of it.

Nothing is posted to Jira until the user has seen the drafted comment in full and
confirmed it.

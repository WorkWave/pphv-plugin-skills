---
description: Turn a Jira ticket into a QE handoff — impacted areas, manual test cases, test-data plan — scoped to a full regression pass or the impacted flow only, then post a QE spec comment to the ticket after you confirm it.
argument-hint: <TICKET-ID> [full|focused]
---

The user wants a QE handoff for Jira ticket: **$ARGUMENTS**

Invoke the `qe-analysis` skill and run its full procedure for this ticket ID. If
`$ARGUMENTS` has no ticket ID, ask the user for one before proceeding.

`$ARGUMENTS` may also carry the **spec scope**:

- `full` (or "full regression") -> `scope_mode: full` — every consumer of the
  changed code, full cross-browser matrix, full edge-case sweep.
- `focused` (or "impacted flow only") -> `scope_mode: focused` — the changed flow
  only, plus proof the change did not regress it, plus a Deferred Coverage
  section listing what a full spec would have added.

When the scope is given, skip the skill's Step 3 question and echo the mode you
read in one line. When it is not, ask as Step 3 describes — do not assume `full`.

Nothing is posted to Jira until the user has seen the drafted comment in full and
confirmed it.

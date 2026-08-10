---
description: Turn a Jira ticket into a QE handoff — impacted areas, manual test cases, test-data plan — then post a QE spec comment to the ticket after you confirm it.
argument-hint: <TICKET-ID>
---

The user wants a QE handoff for Jira ticket: **$ARGUMENTS**

Invoke the `qe-analysis` skill and run its full procedure for this ticket ID. If
`$ARGUMENTS` is empty, ask the user for a ticket ID before proceeding.

Nothing is posted to Jira until the user has seen the drafted comment in full and
confirmed it.

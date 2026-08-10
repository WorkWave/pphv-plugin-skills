---
description: Analyze a Jira ticket across Jira, code/GitHub, local SQL, and Slack, and produce an inline root-cause analysis.
argument-hint: <TICKET-ID>
---

The user wants to investigate Jira ticket: **$ARGUMENTS**

Invoke the `ticket-investigation` skill and run its full procedure for this
ticket ID. If `$ARGUMENTS` is empty, ask the user for a ticket ID before
proceeding.

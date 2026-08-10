---
description: Mentor-style code review of your changes — correctness, PestPac coding standards, and design, with the why explained. Read-only.
argument-hint: [staged | <PR#> | <file paths>]
---

The user wants a mentor-style code review. Target: **$ARGUMENTS**

Dispatch the `mentor-reviewer` agent to perform the review. Interpret the target:
- empty → default: changes on this branch vs master
- `staged` → only staged changes (`git diff --cached`)
- a number (e.g. `12471`) → that PR via `gh pr diff` on WorkWave/PestPac
- anything else → treat as file path(s) to review

Pass the resolved target to the agent and present its review verbatim.

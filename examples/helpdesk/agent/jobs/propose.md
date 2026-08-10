---
description: Read open tickets and write a routing plan for review. Changes nothing outside.
tools: read, write
mcp: helpdesk
allow: helpdesk__list_open
produces: work/helpdesk/triage-plan.md
timeout_s: 300
---
List the open tickets. For each one, decide which team should own it using `context/routing.md`.

Write the result to `work/helpdesk/triage-plan.md`, one ticket per line, in this shape:

    - ticket <id>: <team> — <one line of reasoning>

Where the routing rules do not cover a ticket, write `needs a human` as the team rather than
guessing. A plan that admits a gap is worth more than one that invents a rule.

Finish with a one-line summary: how many tickets you routed, and how many need a human.

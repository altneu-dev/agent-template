---
description: Apply the reviewed routing plan by adding one note per ticket.
tools: read
mcp: helpdesk
allow: helpdesk__add_note
requires: work/helpdesk/triage-plan.md
verify: helpdesk-verify
timeout_s: 300
---
Read `work/helpdesk/triage-plan.md`. For every line that names a team, add a note to that
ticket saying which team should own it and why.

Skip any line whose team is `needs a human` — those are not yours to decide. Add nothing to
those tickets.

Do not re-derive the routing. The plan has been reviewed; your job is to apply it exactly as
written, including where you would have decided differently.

Finish with a one-line summary: how many notes you added, and how many you skipped.

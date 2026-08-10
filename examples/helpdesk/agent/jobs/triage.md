---
description: Read open tickets and add a triage note to each. Never closes anything.
tools:
mcp: helpdesk
allow: helpdesk__list_open, helpdesk__add_note
timeout_s: 300
---
List the open tickets. For each one, decide which team should own it using `context/routing.md`,
then add a short note saying so. Do not guess when the routing rules do not cover a ticket —
add a note asking for a human decision instead.

Finish with a one-line summary: how many tickets you noted, and how many you escalated.

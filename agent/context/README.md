# context/

What **this** agent is for. Replaced per deployment; the framework never reads these files,
the agent does.

Ship one file per concern. Suggested split — rename freely, nothing here is magic:

| File | Answers |
|---|---|
| `organisation.md` | who this is for, what they do, names and terms an outsider would not know |
| `scope.md` | what this agent handles, and what it must never touch |
| `policy.md` | escalation rules, thresholds, who decides what |
| `voice.md` | tone, language(s), formatting conventions for anything customer-facing |

Two rules learned the hard way:

- **Be specific about what is out of scope.** A list of what not to do is worth more than
  any amount of description of what to do — it is the only thing that stops an agent
  improvising at the edges.
- **Facts belong in `knowledge/notes/`, not here.** This directory is small and read every
  run; the knowledge base is large and searched on demand. Putting a price list here costs
  tokens on every single run forever.

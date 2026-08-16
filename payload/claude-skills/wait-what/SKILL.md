---
name: wait-what
description: Stop. That last message did not land — re-pitch it.
disable-model-invocation: true
---

Wait — I don't understand where you've got to here. Re-pitch that: give me a little bit of context, talk in ASD-STE100 Simplified Technical English, and use this repo's ubiquitous language.

Find the ubiquitous language in the first of these that exists:

1. `docs/GLOSSARY.md` — STModel. Scribe-owned, ~113 terms across 9 categories. Authoritative: use its terms verbatim, including the TV/TS taxonomy. Do not coin a synonym for a term it already defines.
2. `CONTEXT.md` — repos set up by `/setup-matt-pocock-skills`.
3. Any other `*GLOSSARY*.md` or `*TERMINOLOGY*.md` under `docs/`.
4. `docs/decisions/` and `docs/architecture/` — STModelAgent has no glossary. Take the vocabulary from the ADR titles and the lane codes (`b3`, `b7`, `l1d5`, …) instead of inventing new names for them.

Grep for the terms you already used. Do not read a glossary end-to-end — `docs/GLOSSARY.md` alone is ~169KB.

If none of these exist, say so in one line, then re-pitch in plain English and don't invent jargon.

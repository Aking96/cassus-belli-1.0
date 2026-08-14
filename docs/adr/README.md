# Architecture Decision Records

ADR-first: a record is written (and `accepted`) before the code it
governs is written, not after. Writing one to explain code that already
exists ("ADR Theater") defeats the purpose — the record should be the
place reasoning happens, not a summary of a decision already made.

## Tiers

Each tier has its own ID counter, starting at 001.

- **S-ADR** — Strategic. Foundational decisions (framework choice, core
  data model, engine-level constraints). Rare.
- **T-ADR** — Tactical. Implementation decisions within an existing
  architecture (a new state, a new module boundary, a new call path).
  Most decisions here.
- **Operational** — Config/tooling changes. Logged more like a
  changelog entry than a full record; no fixed template.
- **QE-ADR** — Quality Engineering. Bug investigations. Requires at
  least 2-3 hypotheses tested with evidence before a root cause is
  named — never jump straight from symptom to fix.

## File naming

```
docs/adr/<TIER>-<NNN>-<kebab-case-slug>.md
```

e.g. `docs/adr/T-ADR-001-recruit-second-commander-state.md`.

## Frontmatter

Every record (except Operational entries) opens with:

```yaml
id: T-ADR-001
status: proposed   # proposed -> accepted -> superseded | deprecated
depends_on: []      # IDs this record's decision relies on
related_to: []       # IDs worth cross-referencing, no hard dependency
supersedes: null      # ID this record replaces, if any
superseded_by: null    # ID that replaced this record, if any
```

A superseded record is never deleted — it's amended with
`superseded_by`, and the new record sets `supersedes`. Historical
reasoning stays intact even after the implementation changes.

## Body template

```
# <ID>. <Title>

## Problem statement
## Decision              (QE-ADR: "## Hypotheses tested" + "## Root cause" instead)
## Alternatives considered
## Consequences
```

## Registry

`ADR_REGISTRY.json` in this directory is the searchable index —
regenerate it (by hand for now) whenever a record is added or its
status changes.

## Linking code back to a record

Once a `T-ADR`/`S-ADR` is `accepted` and code is written under it, tag
the code with the record's ID so the connection survives refactors:

```lua
-- @adr {T-ADR-001} Recruiting a second commander is its own campaign state
function Campaign:recruitCommander(commander)
```

`rg "@adr\s*\{"` finds every call site governed by a record.

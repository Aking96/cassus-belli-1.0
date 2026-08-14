---
id: T-ADR-001
status: accepted
depends_on:
  - QE-ADR-001
related_to: []
supersedes: null
superseded_by: null
---

# T-ADR-001. Recruiting a second commander is its own campaign state

## Problem statement
Per QE-ADR-001, there is no path for the player to add to
`playerCommanders` after the initial `COMMANDER_SELECT` screen. We want
one: winning battles should let the player recruit additional
commanders, up to `MAX_PLAYER_COMMANDERS`.

## Decision
Add `Campaign.STATE.COMMANDER_RECRUIT`, entered from `leaveShop()` when
`#playerCommanders < MAX_PLAYER_COMMANDERS` and before `BATTLE_SELECT`.
Give it its own action method, `recruitCommander(name)`, rather than
overloading `selectOpponent` or `toggleCommander` — so "pick for myself"
and "pick who I fight" stay two unambiguous call sites instead of one
method inferring intent from state.

Recruiting removes the commander from `availableOpponents`.

## Alternatives considered
- **Overload `selectOpponent` to branch on state.** Rejected — collapses
  two different player intents into one method, makes the call site
  ambiguous to future readers.
- **Let recruited commanders remain fightable as opponents later.**
  Rejected for now — simpler mental model (recruited = no longer an
  enemy), but flagged as a pacing tradeoff worth playtesting; may get
  superseded if it feels bad in practice.

## Consequences
- `campaign.lua`: +1 state, +1 method, +1 branch in `leaveShop`.
- `campaign_ui.lua`: +1 `draw`/`mousepressed` branch, reusing existing
  `drawCommanderButtons`/`commanderButtonRects`.
- `availableOpponents` shrinks faster as the player recruits, reducing
  battles remaining in a campaign run.
- `battle.lua`/`commander.lua` untouched.

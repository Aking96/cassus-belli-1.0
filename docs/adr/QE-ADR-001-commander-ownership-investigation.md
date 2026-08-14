---
id: QE-ADR-001
status: accepted
depends_on: []
related_to:
  - T-ADR-001
supersedes: null
superseded_by: null
---

# QE-ADR-001. Investigation: newly-picked commander is owned by the opponent

## Problem statement
Reported as a bug: "after winning a round and choosing a new commander,
that card goes to the opponent of the second match instead of becoming
the player's second commander."

## Hypotheses tested
1. **Wrong variable/side assigned in `selectOpponent`.** Checked
   `campaign.lua:396-399` and `startBattleAgainst` — the clicked
   commander is deliberately passed as `enemyCommander` into
   `Battle.new`. This is the intended behavior of that call site, not a
   misassignment. **Rejected.**
2. **A player-roster write path exists but has a bug (wrong state guard,
   wrong list).** Grepped every write to `playerCommanders`
   (`table.insert(self.playerCommanders, ...)`) — the only call site is
   `toggleCommander`, gated to `STATE.COMMANDER_SELECT`
   (`campaign.lua:142-152`), which only runs once at campaign start.
   **Rejected — no such path exists at all, buggy or otherwise.**
3. **The feature doesn't exist yet; the post-victory screen only ever
   implemented opponent selection.** Confirmed: `BATTLE_SELECT` and
   `COMMANDER_SELECT` share the same button component
   (`drawCommanderButtons`), which is what made the two screens read as
   the same action. **Confirmed as root cause.**

## Root cause
Not a logic bug. The "recruit a second commander" feature has no
implementation — `BATTLE_SELECT` only ever meant "pick who to fight
next." The visual similarity between the two screens created the
impression that a working feature was misrouting ownership.

## Consequences
No fix to apply. Tracked as a feature gap in T-ADR-001 rather than a
patch to existing code.

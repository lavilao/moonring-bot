# Moonring Bot: Phased Implementation Plan

**Basis and caveats.** I couldn't open the repo or the game source from this chat. Everything below rests on the facts and line refs in your brief, and I haven't verified them against `2f013b5`. Anything I infer rather than know is marked *(inferred)*. Open questions are collected in §8, each with a file or function target.

**Conflicts to settle first:**

1. **The Jest entrance.** §7 says Harrowdus `leadsTo = dungeon2-01` (The Jest). §5.1 says relic dungeons are never attempted because they aren't any town's `leadsTo`. Either the bot already tries to delve The Jest and hits the `jest_key` lock, or the `leadsTo` field is not what the town tick reads. Check this before Phase 1.
2. **Theft confirm boxes.** `handleDialogs` sets `confirmBox → confirm=true` unconditionally. That would approve the theft prompt in towns. It is probably harmless today because the bot never bumps owned containers, but Phase 1 will bump many containers. The confirm handler must become text-aware, and the default for unknown confirms must be a conscious choice.
3. **Which ending.** The Archon accepts `killedGods` or `gotAllRelics`, and Lament is locked behind `gotAllRelics`. So the Tether is only reachable after all five relics, and the relics-only path ends the game early on the bad ending. The bot must never talk to the Archon before the Tether is dead. `archon1` must be an explicit, gated objective.
4. **Harlequin's taboo.** §6.3 says "non-pin/dagger/rapier", but the reporter is `reportUseOfHeavyWeapon`. Read the actual predicate before encoding it.

---

## 0. Architecture decisions that everything else depends on

### 0.1 Reflex, objective and maintenance layers

`init.lua` is already priority-ordered by branch. I would formalize this as a stack where each behavior returns `true` if it consumed the tick:

```
Reflex      handleDialogs → combat/heal/flee → hazard (amber, burden)
Objective   campaign.current():step()      ← the new part
Maintenance equip → sell → supply → inn → lamp fuel
```

The existing town and dungeon branches become "objective step providers". Combat and heal remain reflexes in every world type, including Zoom and the overworld.

### 0.2 Module extraction (no behavior change, done first)

`init.lua` stays the entry point and wrapper. Leaf modules move out under `mod/zzbot/`, sharing one context table `Z = {CFG, S, game, log, ev}`:

| Module | Contents |
|---|---|
| `metrics.lua` | structured event log, counters |
| `nav.lua` | cellAt, navSteps, weightedSteps, frontier, doors |
| `interact.lua` | container/pickup/stairs primitives (new) |
| `ledger.lua` | per-level completion bookkeeping (new) |
| `gear.lua` | slot scoring, equip, drop policy (new) |
| `dialogue.lua` | speech driver (new) |
| `gods.lua`, `powers.lua` | expert profiles, power catalog and policy (new) |
| `campaign.lua`, `campaign_data.lua` | objective graph and data (new) |
| `travel.lua` | overworld/ferry/ship/zoom/stairs legs (extracted and extended) |
| `model.lua` | extended |

Extraction rule: move a function only if the regression suite (§5) passes before and after. Upvalue-heavy code makes this the main source of silent regressions, so do it in small batches.

### 0.3 Structured event log

Keep the human log, and add machine-parseable lines `EV|t=<s>|kind=<k>|k=v…`. Event kinds:

- `level_enter`, `level_done`, `container_open`, `container_skip`
- `equip`, `power_use`, `power_result`
- `sin`, `curse`
- `dialogue`, `objective_start`, `objective_done`
- `death`, `stuck`, `alert_stuck`
- `trade`, `donate`, `devotion`

`tools/check_log.lua` asserts on these, so acceptance criteria become scripts rather than eyeballing. Without this, no acceptance criterion in this plan is checkable.

### 0.4 Game state is truth, bot state is cache

- **Container status** is derived from map cell type. Closed variants (`chestClosed`, `potClosed`, …) are the ones still to do, and `bookshelfSearched` is done. The ledger stores only annotations: unreachable, deferred, and why.
- **Objective completion** is derived from game state: properties or flags, inventory, and killed-actor markers. Resuming means re-evaluating every `done()` predicate.
- **Bot-side file** (`zzbot_state.lua` in the isolated save dir, never inside the game's `save/`): ledger annotations, dialogue-exhausted set, deed and ship notes, calibration data. It is written atomically (tmp then rename) on each objective transition and level completion, and carries a schema version plus a character-name check. If the game and the file disagree, the game wins.

---

## 1. Phase order and rationale

| Phase | Content | Depends on | Why here |
|---|---|---|---|
| **P0** | Metrics, watchdog, alert-freeze diagnosis, confirm-text guard, module extraction, regression harness, milestone saves | none | Every later acceptance check needs this |
| **P1** | Interaction primitives, level ledger, full loot sweep, multi-level descent, tears and "something special" | P0 | Violates your explicit rule today; the primitives feed everything |
| **P2** | Gear/inventory (6.2), burden policy, lamp/amberbane basics (6.12), healing policy | P1 (loot creates the gear problem) | Needed before experts or deeper dungeons |
| **P3** | Dialogue driver (6.6) | P0 | Campaign needs it; independent of P1/P2, can run in parallel |
| **P4** | Power catalog, god experts, bindings and power use (6.3), taboo guard | P2 | Experts need gear and healing rules |
| **P5** | Combat model v2: ranged, AOE, powers (6.5); Zoom survival (6.4) | P4 | The model needs the power catalog |
| **P6** | Campaign graph (6.7) with relics 2, 1, 3, 4 in that order; herbs (6.10); reputation/shops (6.8) | P1–P5 | First real end-to-end objectives |
| **P7** | Ships/sea (6.9), Tower of Veils chain, Lament, Archon, ending | P6 | Longest dependency chain, highest risk |

**Why Zoom comes late:** the deaths are a combat-capability problem (no pre-buff, powers, ranged), so diagnosing and fixing them needs P4/P5. In P0, add only the death-diagnosis instrumentation and a conservative "flee at first sight of a losing verdict" tweak.

**Why campaign is late:** each relic dungeon is only as good as the loot sweep, combat and gear underneath it. Starting with the campaign would produce deaths with no way to diagnose them.

---

## 2. Shared infrastructure

### 2.1 Interaction primitives (`interact.lua`)

All of these are generic and key-injection based, with pass/fail return codes and timeouts:

- `scan(level)` returns lists of container cells, stairs, doors and known pickups, from the cell type tables (`cell_data.lua:1293–1303`, stairs `212–214`).
- `openContainer(cell)` walks to an adjacent walkable tile and bumps. It then verifies success: the cell type changed, or the inventory or alert state changed. Per-cell retry cap of 3, then `container_skip reason=…`.
- `useStairs(dir)` walks onto the stairs cell. Whether stepping is enough or a key press is needed, and how the world name changes, are open questions (§8). The planner treats a world-name change as a "level transition" event and rebuilds `S.known` per world name (it must be keyed by name).
- `stepAllWalkableCoverage(region)` is the fallback if pickups can't be enumerated (§2.2).

### 2.2 Level ledger and completion test

```
LevelState[world] = {
  seenContainers = set(cell), annotations = {cell → {state, reason, tick}},
  stairsUp, stairsDown, frontierEmpty, visitedCount, openedCount
}
isLevelDone(world) :=
  frontier(world) is empty                          -- nothing reachable unexplored
  AND every container cell with a closed-type is either opened or annotated
      {unreachable | locked_no_tool | owned_in_town | hostile_guarded}
  AND (pickups enumerable ? none remaining : coverage fallback done)
  AND no door objective pending (locked doors with a known plan)
```

When done, emit `EV|kind=level_done containers=opened/total unreachable=[…] frontier=0 pickups=0 time=…`. That line is the proof of "no loot left".

**Deferred containers.** A `locked_no_tool` entry is revisited whenever the inventory gains a chest key, a lockpick, or the relevant skill. At dungeon exit, if any deferred entry could now be opened, the bot opens it first. Only a remaining entry whose requirement is unmet may be left, and it is logged as an exception.

### 2.3 Selector (loot-aware frontier)

At each decision the bot computes path costs with the existing `weightedSteps` (danger-aware) to each candidate. The candidate classes, in tie-break order, are:

1. Seen and unopened containers
2. Known pickups
3. Frontier cells
4. Door/secret-door objectives

The bot picks the minimum of `pathCost − classBonus`, where `classBonus` is small and just breaks ties toward containers. It holds the chosen target until it is reached, invalidated, or a reflex preempts, which avoids dithering. After a reflex (combat/flee) ends, it replans.

### 2.4 Stuck and freeze handling (P0)

- **Watchdog.** Track `(world, x, y, dialog_state, inventory_hash)`. After N ticks without change, or any `alert=open` for more than 200 ticks, escalate: return → space → escape → cycle the choice → a distinct dismissal. Log the full dialog state and the alert text each time.
- **Confirm/alert text classification.** Classify by text into theft, relic-dungeon entry, shatter, buy/sell, and unknown. Map each class to an explicit policy (decline theft, accept relic entry only when the campaign says so, and so on). Unknown confirms should default to the safe action (decline), because the current always-accept is the riskier default.

### 2.5 Regression harness

`tools/regress.sh` runs a scenario list. Each scenario is a save backup, an env set and an expected set of `check_log.lua` assertions. Plus pure-Lua unit tests (`tools/test_*.lua`) with fake-game stubs for the selector, ledger, gear scoring and AOE targeting, so most logic is testable in seconds rather than 20-minute headless runs. Start by adding milestone saves to `work/save-backup/`: after tutorial, at each town, at each relic dungeon entrance, with relic N in hand.

---

## 3. Per-feature design

### 3.1 Full loot sweep (6.1) — P1

- **Descent policy.** Clear the whole level, then take `stairsDown`. Reasons: your rule demands full clearing anyway, `stairsUp` stays known as a retreat route, and each level's monsters are cleared before going deeper. Down-first is rejected for the same reason. Level 07 is a prebuilt boss level and gets special handling (below).
- **Return.** After the last level and the objective (relic or key), ascend through each level using stored `stairsUp` cells and the known map, which is cheap because the levels are already explored. If a relic dungeon offers a warp or `leaveRelicDungeon` exit, prefer it. Confirm in source (§8).
- **Locked chests.** Existing `tryPickLock` plus keys. If neither works, annotate `locked_no_tool` and defer (§2.2).
- **Containers that spawn something** (tear guardians, mimics if any): the generic combat reflex handles them. After the fight, re-verify the container state.
- **Doors, secret doors, one-way drops.** Reuse `findRoutableDoor`, `trySecretDoorSweep` and the lock plans. A one-way drop is detected by the world change plus a missing `stairsUp` link, and logged as an `unreachable` reason on the level left behind.
- **Wasted consumables.** Opening costs no consumables. Lockpick consumption is an open question. Cap picks per container.
- **Replacing the early exit.** Remove the `HP>60% and healing remains` gate. Replace it with: sweep always; if HP is low and healing is gone, retreat to rest. In dungeons, resting means standing in explored safe space until HP recovers (verify there's passive regen, otherwise the nearest `lifestone`). If no recovery is possible, only then exit, log the reason, and flag the level as incomplete so a later visit resumes it.
- **Coverage fallback.** If pickups can't be enumerated (§8), cover every walkable known cell. That is costly, so restrict it to "cells adjacent to objects seen as non-terrain glyphs" if the renderer exposes them. Otherwise accept the full-coverage cost, with burden-aware tick budgeting.

**Tears.** A tear container is just a container: it is opened by the sweep, and the spawned guardian is handled by combat. Add handling for the announcement "There is something special around here!" (~`state_game.lua:1941`), which simply sets a flag on the level meaning "a tear container exists, level is not done until it is opened". Shattering stays in the `tearPending` path and gets `godIndex` from the active expert profile (§3.4).

### 3.2 Inventory and equipment (6.2) — P2

`gear.lua` has these parts:

- **Candidate filter** per slot, using `G_Globals.categoryToLocationIDs`. It must pass `isPlayerStatSufficientToUse`, `hasEnoughHandsToUseMessage`, the active god's taboo predicate, and a burden check (`getRawPlayerBurdenAndMaxBurden` after the swap does not push the tick multiplier above the threshold).
- **Score** per slot from ObjectData columns. Melee is expected damage per time unit (damage over `weaponTimeCost`, adjusted for cooldown and the stat bonuses the build uses). Armor is defense per burden, weighted by the build's mobility need. Shield is `shieldBlockFraction` and the hands cost. Ranged weapons need ammo availability.
- **Verification by the game's own numbers.** After equipping in a safe context (town, or a cleared dungeon level), read `getTotalPlayerMeleeAttackStatsAfterEquipmentDegradation` and defense totals, and revert if the build score dropped. Whether equipping is free and instant is an open question.
- **Unidentified items.** `isObjectDataIdentified` and `isItemInert` suggest identification and curse mechanics. Until verified, treat unidentified gear conservatively: equip only if the score gain is large, and log it.
- **Healing selection.** Extend `findHealPotion/useHealItem`: bandages, ointments, blood phials and lifestones as taboo-allowed. Dust must not use potions or ointments (except `potion_water`); Lady must not use non-blood food. Add a "don't waste" rule: heal only when predicted incoming burst, or HP, passes a threshold, rather than at a flat percentage.
- **Burden.** Keep burden under the multiplier threshold. When above, the drop ladder is: (1) equip upgrades, (2) drop the lowest value-per-weight item that isn't protected, in dungeons, (3) a sell trip only if the campaign allows. Inventory-full is not slot-based unless the source says otherwise (§8).
- **Sell protection.** `bestGearIDs` becomes "protected set" = equipped + best-per-slot for the active build + quest categories + all relic and key items.

### 3.3 Dialogue driver (6.6) — P3

A state machine over the `speechArea` states already seen in `handleDialogs`:

```
talkNPC(npc):
  walk adjacent → bump → loop:
    state = speechArea state
    choice/keyword list  → pick via dialogue_policy(npc, state)   (data-driven)
    typed input prompt   → type from a keyword list (see below) or fallback "bye"
    yes/no               → policy table by dialogue key
    plain text           → return
  mark exhausted when no unseen keywords remain
```

- **Keyword choice.** Parse `DialogueData - Sheet1.csv` at runtime (location, speaker, conditions, `removeWhenSeen`, keyword, `propertiesToSetAfterAllDialogue`). Then "exhaust all dialogue" equals selecting every keyword not yet seen, and the property gates tell the bot which NPC reveals new content after a flag change. This makes it data-driven with no per-NPC scripts.
- **Quest table** (in `campaign_data.lua`) lists the keywords the campaign needs, for example the Jest phrase clue, and `done()` predicates read the resulting properties.
- **Soft-lock prevention.** A cap on speech-area steps per NPC per visit (about 200), an Escape fallback, and a `dialogue_stuck` event.
- **Reward triggers** (`speech_area.lua:16–22`) are checked as inventory-count predicates, not driven by the dialogue layer.
- **Town re-sweep.** After flags change (new relic, new clue), re-run exhaust-all in towns whose NPCs have unseen keywords. This is where `conditions` parsing earns its keep. Whether `conditions` is parseable without the game's evaluator is an open question; if not, call the game's own condition checker.

### 3.4 God experts and powers (6.3) — P4

`gods.lua` holds one profile per god (data):

```
{ id, taboo = function(action|obj)→bool, sinPerEvent,
  stats = {priority…}, weaponClass, armorWeightMax,
  skillOrder = {7 cells}, bindOrder = {key→power}, doctrine = {…} }
```

- **Pure vs mixed** via `ZZBOT_BUILD=pure:<god>|mixed`. `ZZBOT_GOD` stays as the pure case. Mixed is out of scope until the pure experts are proven.
- **Taboo guard** is a single module `taboo.check(kind, payload)` called at every choke point: `drinkPotion/useHealItem`, flee start, equip, attack target selection, and technology use. It predicts the sin report from `state_game.lua:20354–20432`. After each action, compare `currentSin`, log `sin` events, and stop doing the offending action class when the projected sin would reach the curse threshold (1.0). If cursed, run the recovery path (`removeCurse`; find the in-game trigger, open question).
- **Wolf is the awkward case.** It forbids fleeing, but the bot's survival logic leans on flee. The Wolf doctrine front-loads buffs, uses healing earlier, and budgets cowardice (0.1 each, so at most about 9 flees per god, minus decay if any, open question). Dust cannot heal with potions, so it relies on lifestones, resting and escape powers.
- **Power catalog** (`powers.lua`) is built at runtime from `CActions.static.data`: `energyCost`, `cooldown`, `timeCost`, `targetingType`, `distance/radius`, `isViolent/fine`, `canUseInOverworld`, and the god via `worldMoon`. Add a hand-authored tag table: `damage|aoe|buff|heal|escape|summon|utility`, plus effect descriptors for the model (§3.5). Read the handlers under `actorManager:performActionWithActor` to author these, rather than guessing (§8).
- **Power policy.** Each tag has trigger conditions (for example a damage power fires when enemy `threatList` weight passes a threshold and energy and cooldown allow; an escape power fires when `verdict` says flee fails). Targeting solvers:
  - `target`: nearest or most dangerous in line of sight.
  - `direction`: the 8-way choice maximizing enemies hit, excluding allies.
  - `location`: the cell maximizing enemies in `radius`, excluding the player and allies, within `distance`.
- **Execution and binding.** Fire through the game's own binding keys, to stay faithful to key-injection. Assigning `skillBindings` directly (`skill_tree.lua:429`) is the simplest path and probably fine; confirm there is no UI side effect (§8).
- **Skill purchases.** Follow `skillOrder`, using `activateCellForGridFactionAtXY` and the existing `skillCostMap`. The existing gift flow already supplies devotion, so the expert only decides which cells to buy.
- **Friendly fire.** Angels' injustice taboo needs an ally/neutral flag on actors. Use the existing `isHostile`, and never target anything not hostile.

### 3.5 Combat model v2 (6.5) — P5

- **New actions in `model.lua`:** `shoot(target)`, `power(name, target|dir|loc)`, with energy and cooldown state in the sim.
- **Inputs:** range and line of sight from ObjectData `range` and the map, ammo counts, projectile hit chance, AOE shape from `radius`, and status effects on both sides.
- **Effects table.** Damage and status per power come from a hand-authored descriptor table, verified against the handler code. Add self-calibration: log `power_result` (predicted vs observed damage) and a script to compare across runs, so descriptor errors surface quickly.
- **Ranged kiting.** Extend the `kite` action to use `canOutrun` and the enemy `enemyStep` speed model, with ranged enemies treated as a different threat class (cannot be kited without cover).
- **Switching it on.** Keep `CFG.model` default off until the unit tests and the matrix (§5) show it beats the heuristic chooser, then flip the default. `S.modelErrors < 5` fallback stays.
- **Tests.** Deterministic seeds in `tools/test_model.lua`, with cases for each new action: ranged beats melee at range, AOE beats single target against packs, a power on cooldown is not chosen.

### 3.6 Zoom survival (6.4) — P0 diagnostics, P5 fix

- **P0.** Log on every Zoom entry: enemy list with `enemyWeight`, HP/energy, heals, and the power list. On death, log the HP timeline at one-second resolution.
- **P5.** (1) Readiness check at entry: rest to full HP and energy, carry heals. (2) A threat verdict at first sight: if `verdict` says the pack is a loss, retreat to `fleeZoneCell` while there is still distance and `canOutrun` holds, rather than when contact happens. (3) Fight only with powers and ranged kiting on. (4) Escape consumables before the lethal HP band. (5) Campaign marks Zoom as "visit only if an objective needs it".

**How Zoom is entered, and whether it can be avoided,** is an open question (§8).

### 3.7 Herbs and overworld pickups (6.10) — P6

Floor triggers are collected by stepping on them, so the layer is route integration. The overworld BFS already carries a danger map. Add "detour to pickup" candidates when the extra path length stays within a budget (for example 15% or 30 tiles) and no `overworld_enemy` marker is within a safety radius. The Necropolis chain needs 5× `witch_solvent_herb`: the four Endera positions and the one sold in Harrowdus. These live in `campaign_data.lua` as `Acquire{item, count}` objectives with a pointer to the known coordinates, and not as a general herb scanner.

### 3.8 Reputation and shops (6.8) — P6

Expected value per reputation point = (projected buy volume × discount + projected sell volume × premium) over the next N decisions, minus the gold cost from `getGoldNeededToRaiseFactionStanding`. Donate only when EV is positive, gold stays above the ferry/liquidity reserve, and the shop faction is one the bot will keep using. Log every decision as `EV|kind=donate ev=… cost=… reserve=…`. Build-specific purchasing reads the active god profile (weapon class, armor weight, ammo, lamp fuel, taboo-allowed healing). Upgrades outrank hoarding, and the existing arbitrage and demand logic stays.

### 3.9 Amberbane and lamp (6.12) — P2 basics

Maintain fuel when the world flag `allowAmber` is true. Keep a fuel-count threshold, buy fuel in town supply, and toggle the lamp via `toggleInventoryID`. Log `amber_state` per level. Verify the fuel object names in `ObjectData` and the `lampInventoryID` slot mechanics before coding (§8).

### 3.10 Ships and sea (6.9) — P7

Objectives: obtain the deed (forged deed container at `clickclack-01Triggers.csv` 45,51, or buy it if the dialogue data allows), claim a ship by walking over it on the overworld, sail to the Kenner island for the `key_clue_final` step, and handle Yeleba only if the campaign needs the Great Key. Sailing needs its own `travel.lua` mode (`isSailing`, jetties, `callShipToXY`, cannon/telescope) and a sea-combat reflex. This is the least understood subsystem, so P7 starts with a research spike, not code. Whether the Tower chain needs Yeleba at all is unclear from the brief.

---

## 4. Campaign and objective architecture (P6–P7)

### 4.1 Objective data

```lua
-- campaign_data.lua (data, no per-map code)
{ id="relic2_jest",
  requires = { "has:jest_key | prop:jest_unlocked", ... },
  steps = {
    Talk{ npc_hint="harrowdus_literature", keywords={...} },   -- clue
    Acquire{ item="…", ... },
    Yell{ phrase="Death_Has_Dominion_Over_All", at=trigger("HarrowdusTriggers", 79,82) },
    ClearDungeon{ entry="dungeon2-01", allLevels=true, boss=true, take="relic_2" },
  },
  done = "prop:relic_2" }
```

Step kinds (small, generic, reusable): `GoTo`, `Talk`, `Acquire`, `Kill`, `Yell`, `Use`, `ClearDungeon`, `Sail`, `Ritual` (shatter/donate/etc). Each has an idempotent `done()` read from game state.

### 4.2 Planner

1. Evaluate all `done()`; the unmet objectives whose `requires` are satisfied form the ready set.
2. Choose by: lowest estimated cost, subject to a **readiness gate**. Readiness compares build strength (HP, defense, DPS from §3.2, devotion level, powers bound) with the target's estimated difficulty (monster stats in `ActorData` for that dungeon's range *(inferred)*). If not ready, run "prepare" objectives: tears, optional dungeons, the shopping loop, the economy loop.
3. `TravelPlanner` resolves `GoTo` into legs: town exit → overworld BFS → ferry/ship → zoom crossing → dungeon entry. Existing `globalOverworldStep`, `ferryLegStep` and `overworldTravelStep` become leg executors.
4. Failure handling: a step that fails N times or times out is marked `blocked(reason)`. The planner moves to another ready objective, and emits `objective_blocked`. Never loop on one.

### 4.3 Suggested objective order

Jest (Harrowdus; phrase and key) → Garden (kill Sleathen, then the Lord of Trees) → Repository (locus device from ruin fragments) → Necropolis (Endera herbs and the Red Grove litany) → Tower of Veils (5-clue chain and ship) → Lament (all relics) → Tether → endgame world → Archon. Rationale: increasing prerequisite cost, with the ship-dependent Tower last. Which relic Jest drops (`relic_2`) is *(inferred)* and should be confirmed. Add priest6's tear and tears from visited levels as a "prepare" source, not an objective.

### 4.4 Endgame

Two objectives gate the end: `kill_tether` (clearing `dungeon6-06` through the boss, with leaving the dungeon setting `killedGods` and `setEndgameWorld`), then `talk archon1`. Add an explicit "never talk to the Archon with only relics" rule until `killedGods` is set. Confirm that `startFinalSequence` runs without bot input beyond dismissal, and let the `ZZBOT_QUIT` hook trigger on the ending.

### 4.5 Persistence and resume

Resume is "start, evaluate all `done()`, continue". The bot file (§0.4) holds only the ledger annotations, the dialogue-exhausted set, and calibration data. Test resume by killing a run mid-objective and restarting from the game's save.

---

## 5. Test plan

| Phase | Start save | Command variation | Log assertions | Pass criteria |
|---|---|---|---|---|
| P0 | `test43-loop` | standard headless | `EV` lines present; no `alert_stuck` | Regression suite green before and after the module split; economy numbers within 10% of the baseline |
| P1 | tutorial-end save | `ZZBOT_START_ON=1`, timeout 1800 | `level_done` per level with `containers opened=total` or listed exceptions; no `exit` before `level_done` | Zero reachable closed containers on exit across ≥3 dungeons/seeds; stairs descent works on a multi-level dungeon |
| P2 | post-P1 save with a loot haul | town visit | `equip` events; DPS/defense up; no `sin` for the active god | Upgrades in every slot where available; no relic/key sold; burden below threshold |
| P3 | each town save | town-only run | `dialogue` per NPC; flags set | All NPCs exhausted per town; tear obtained at MUT; no `dialogue_stuck` |
| P4 | per-god saves (one each) | `ZZBOT_BUILD=pure:<god>` | `power_use`, `sin` | Kit built, keys bound, powers fired with right targeting, no sin events, per god |
| P5 | Zoom-heavy save | repeat N=10 | `death` count, `power_result` calibration | 0 Zoom deaths in N runs; model beats heuristic on a fixed matrix |
| P6 | after Jest etc. | campaign mode | `objective_done` | Each relic dungeon milestone reached; economy and dialogue regressions green |
| P7 | all-relics save | full | `objective_done` through `archon`, ending flag | Good ending reached headless |

**Regression suite** (runs on every phase): economy (arbitrage/sell/discovery unchanged), dialogue (no soft-lock), combat (fixed fight scenarios with a win-rate floor). **Matrix** for combat and loot: cave, crypt, tower, ruins × melee, ranged, caster, summoner, pack, boss. Keep unit tests for pure logic so most iterations take seconds.

**Determinism.** Whether the game RNG can be seeded from the mod is an open question. If not, use fixed saves and N≥3 repetitions per scenario, and report medians.

---

## 6. Risk register

| # | Risk | Mitigation |
|---|---|---|
| 1 | Soft-lock in dialogue or alert/confirm boxes | Watchdog with escalating dismissal; text-classified confirms; per-NPC step caps |
| 2 | Curse/taboo from a missed choke point | Single `taboo.check`; sin event monitoring; per-god tests; pure builds first |
| 3 | Inventory/burden slows or blocks pickup | Drop ladder; burden threshold; sell trips only when allowed |
| 4 | Unreachable loot (doors, one-way drops, locked) | Ledger annotations with reasons; deferred revisit; logged exceptions |
| 5 | Boss and Zoom deaths | Readiness gate; pre-buff; escape consumables; instrumented death timelines |
| 6 | Wrong-ending trigger (Archon before Tether) | Explicit gate and predicate; endgame tested from its own save |
| 7 | Ship/sea subsystem unknown | Research spike first; objective can be marked blocked without stalling the campaign |
| 8 | Performance from full-coverage sweeps and Monte Carlo | Tick budget; model off by default; coverage fallback only if needed |
| 9 | Save corruption or bot-state mismatch | Bot file separate from game save; atomic writes; game state authoritative; backups before long runs |
| 10 | Silent regressions from the module split | Small batches; regression suite gate; no behavior change in P0 |

---

## 7. Effort and first increments

| Item | Effort | Item | Effort |
|---|---|---|---|
| P0 infra (metrics, watchdog, split, harness) | L | Dialogue driver | L |
| Loot sweep + ledger + descent | L | Powers and experts (all five) | L |
| Gear/inventory + healing | M | Model v2 | L |
| Lamp/amber basics | S | Zoom | M |
| Tears and "something special" | S | Campaign graph + data | L |
| Herbs/pickup detours | M | Reputation/shops | M |
| Ships and sea | L | Endgame | M |

**First three increments:**

1. **P0 slice.** Event log and `check_log.lua`, the watchdog with alert diagnostics, the text-aware confirm handler, and the milestone-save and regression scaffolding. No behavior change otherwise.
2. **Single-level full sweep.** Level ledger plus the selector replacing the HP>60% gate, with `level_done` proof, tested on the tutorial cave from a fresh save.
3. **Multi-level descent and exit.** Stairs detection, per-world-name memory, ascend-and-exit, and the deferred-container revisit, tested on a multi-level dungeon from a purpose-made save.

---

## 8. Open questions (read before coding; do not assume)

1. **Enumerating floor pickups/triggers on a map:** functions around `state_game.lua:15605` and `15869`, plus the trigger CSV loader. This decides full-coverage vs trigger-driven sweeping.
2. **Stairs mechanics:** how `stairsUp/Down` are used (step vs key), how world names change, whether levels persist when revisited, and what `leaveRelicDungeon` (`state_game.lua:13532`) does and when it applies.
3. **Harrowdus `leadsTo`:** how the town tick currently treats `dungeon2-01` and the `jest_key` lock (the §5 vs §7 conflict).
4. **Reading world properties/flags** from the mod (`getProperty`-style APIs), for `done()` predicates.
5. **Dialogue `conditions` syntax** and the game's evaluator function, for exhaust-all selection.
6. **Equip timing:** whether equipping costs game time, whether it is allowed in combat, and what `isItemInert` / unidentified items imply (`inventory_panel.lua:398–455`, `state_game.lua:17728, 17792`).
7. **Power effect handlers** in `actorManager:performActionWithActor`, to author model descriptors. Also the exact meaning of "technology" for Lady's taboo and the Harlequin weapon predicate (`state_game.lua:20354–20432`).
8. **Sin decay and curse recovery:** `alterSin`, `removeCurse` (`state_game.lua:20491`) and where the game invokes it.
9. **Binding powers:** whether writing `skillBindings` (`skill_tree.lua:429`) directly is safe or the UI path has side effects; whether any skill cells require NPC trainers.
10. **Inventory limits:** slot cap vs burden only; the burden value where `getPlayerTickCostMultiplier` starts penalizing; whether dropping items is possible and how.
11. **How Zoom is entered** from the overworld or towns, and whether it can be avoided on a route.
12. **Lockpick consumption and the chest-key flow** (`attemptToUnlockChestAtMapXY`, `actor.lua:5337`).
13. **RNG seeding** from the mod, for reproducible runs.
14. **When the game autosaves**, and what happens to unsaved progress on death or quit (impacts resume).
15. **Role of `archonDungeon-01` and the `magick` flag** (MUT triggers CSV), and the exact `archon1` branch conditions for good vs bad ending.
16. **Sea:** `isSailing`, `callShipToXY`, the Yeleba/Cannon2 requirement, and whether the Tower chain needs a ship at all.

---

## 9. Definition of done

**Whole bot.** From a fresh save, headless, with no manual input: all relevant levels of every visited dungeon have `level_done` with containers opened/total (or logged exceptions); all five relics are obtained (`prop:relic_1..5`); The Tether is killed; the endgame world is set; the Archon dialogue triggers the good ending; the run exits via `ZZBOT_QUIT`. Three consecutive runs pass with no `alert_stuck` or fatal soft-lock, and the economy regression stays within its baseline.

**Partial milestones, each with its own saved scenario:**

- Full loot sweep on a multi-level dungeon (P1)
- Gear upgrades without sin events (P2)
- All town NPCs exhausted and the MUT tear obtained (P3)
- Each pure-god expert wins its fixture fights (P4)
- Zero Zoom deaths over N runs (P5)
- Each relic dungeon cleared and relic in hand (P6)
- Ship acquired and Kenner reached (P7)
- Tether killed, then the Archon ending (P7)

I can also turn this into a Claude Doc you can edit and download as Word or PDF, or expand any single phase into a detailed task breakdown.

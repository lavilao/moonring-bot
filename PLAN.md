# Moonring Bot: Phased Implementation Plan

**Basis and caveats.** I couldn't open the repo or the game source from this chat. Everything below rests on the facts and line refs in your brief, and I haven't verified them against `2f013b5`. Anything I infer rather than know is marked *(inferred)*. Open questions are collected in §8, each with a file or function target.

**Conflicts to settle first:**

1. **The Jest entrance.** §7 says Harrowdus `leadsTo = dungeon2-01` (The Jest). §5.1 says relic dungeons are never attempted because they aren't any town's `leadsTo`. Either the bot already tries to delve The Jest and hits the `jest_key` lock, or the `leadsTo` field is not what the town tick reads. Check this before Phase 1.
2. **Theft confirm boxes.** `handleDialogs` sets `confirmBox → confirm=true` unconditionally. That would approve the theft prompt in towns. It is probably harmless today because the bot never bumps owned containers, but Phase 1 will bump many containers. The confirm handler must become text-aware, and the default for unknown confirms must be a conscious choice.
3. **Which ending.** The Archon accepts `killedGods` or `gotAllRelics`, and Lament is locked behind `gotAllRelics`. So the Tether is only reachable after all five relics, and the relics-only path ends the game early on the bad ending. The bot must never talk to the Archon before the Tether is dead. `archon1` must be an explicit, gated objective.
4. **Harlequin's taboo.** §6.3 says "non-pin/dagger/rapier", but the reporter is `reportUseOfHeavyWeapon`. Read the actual predicate before encoding it.

---

## 0.0 Estado verificado (2026-11-12, antes de leer el resto)

Este documento se escribió **sin acceso al repositorio** y por eso quedó por
detrás del código: describe como "a construir" cosas que ya existen, y no
menciona la línea de trabajo P8/P8b/P9 (aprendizaje de muertes, GA offline,
trazas y postmortem). La tabla siguiente es el estado real, comprobado con
`tools/unit.sh`, `tools/regress.sh` y lectura de los módulos.

| Fase | Qué hay en el repo | Estado real |
|---|---|---|
| P0 | métricas, watchdog, guardia de confirmaciones, arnés | **completo** (Test47/49) |
| P1 | ledger, barrido completo, escaleras, descenso multinivel | **completo** en mazmorra normal; salir de una mazmorra de reliquia necesita `key_master` (eso es P6) |
| P2 | `gear.lua` (scoring, `planEquip`, `dropLadder`, `protectedSet`, `curePlan`), adaptador, curas, burden medido | **completo** salvo consumir `protectedSet` en la venta |
| P3 | `dialogue.lua` + tests | módulo listo, cableado tras `ZZBOT_DIALOGUE`; **nunca verificado en A/B de pueblo** |
| P4 | `gods.lua`, `taboo.lua`, `powers.lua` | tabú aplicado en equipar y curar; **ningún poder se ha disparado en partida** |
| P5 | `model.lua` (816 líneas, Monte Carlo del reloj de combate) | simulador maduro; `shoot` ya está cableado (opción en el chooser + disparo real por `rangedWeapon`) y con `ZZBOT_MODEL=1` **empata con la heurística** en `dungeon` tras ampliar la ventana de decisión (A/B abajo); `power` sigue sin ofrecerse |
| P6 | `campaign.lua`, `campaign_data.lua` | planner + observación tras flag, sin ejecutar objetivos |
| P7 | `travel.lua`, spike del mar documentado | patas de viaje listas; mar sin tocar |
| P8 | `knowledge.lua` (ledger Beta por enemigo y banda) | módulo + tests, `ZZBOT_LEARN=0` por defecto y **ningún run ha producido ledger** |
| P8b | `tools/evolve.lua` (GA sobre knobs) | CLI + tests, nunca evaluado con partidas reales |
| P9 | `trace.lua`, `tools/postmortem.lua`, `ZZBOT_POLICY` | completo y siempre activo |

**El cuello de botella ya no es construir módulos, es verificarlos.** Casi todo
lo que este plan pedía existe; lo que falta es evidencia de que mejora al bot y
el interruptor por defecto. Cinco flags (`ZZBOT_MODEL`, `ZZBOT_LEARN`,
`ZZBOT_DIALOGUE`, `ZZBOT_POWERS`, `ZZBOT_CAMPAIGN`) siguen en 0, así que el bot
que corre los escenarios es esencialmente el de P1/P2 y todo lo demás es código
sin ejercitar.

### A/B ejecutado: primera versión del modelo perdía, la de hoy empata

Mismo guardado (`save-dungeon-start`, Yarrow Cave), mismo `TIMEOUT=300`,
`GEAR=1` en ambos:

| Run | Resultado | Evidencia |
|---|---|---|
| `tools/regress.sh dungeon` | **PASS** | `level_done` con 19/20 contenedores a t=276, sin muerte; sale por `dungeon_blocked reason=chest_key_missing` |
| `MODEL=1 LEARN=1 tools/regress.sh dungeon` (antes de cablear `shoot`) | **FAIL** | muerte a t=178 en 41,22 (`bones`), sin `level_done`; 24 decisiones del modelo en el log |
| `MODEL=1 tools/regress.sh dungeon` (con `shoot` y ventana a distancia) | **PASS** | `level_done` con 19/20 a t=274, sin muerte, mismo final `chest_key_missing`; **19 disparos reales** (`EV|kind=shoot`, dist 1–3, `dmg=8`) |
| `MODEL=1 LEARN=1` (con `shoot`) | **FAIL** | muerte a t=186 con `large_beetle`: todas las opciones a `pDeath=98–100%` y elige `hit`; es la falta de válvula (V1a), no el disparo |

Aviso sobre el margen: el baseline necesita ~276 s de los 300 del `TIMEOUT`,
así que repeticiones del mismo comando fallan por tiempo (17–19/20
contenedores, sin muerte) sin que haya regresión: el camino sin modelo no
ejecuta nada del código de `shoot` (verificado por grep: `DATA.rangedInfo` y
`DATA.rangedTargets` solo se llaman desde la rama del modelo).

La traza (`logs/zzbot-trace-*.txt`) dice **por qué**, y no es que el modelo
prediga mal: predijo bien. Con `hp=142/400`, poise 55 y un hornet adyacente,
evaluó `hit` con `pDeath=0.98` y `flee` con `pDeath=1.00`, eligió `hit`
("minimise risk"), y repitió hit/flee hasta morir. Tres defectos de integración,
no del simulador:

1. **No hay válvula de escape.** `chooseEval` siempre devuelve la mejor opción
aunque su `pDeathUpper` esté muy por encima de `alpha`; nunca cede el turno a
la rama `avoid`/kite que en el baseline es justo la que evita el combate.
2. **Decide demasiado tarde.** El modelo solo corre con `#adj > 0` (ya en
contacto), donde huir es matemáticamente peor que pelear. La conducta que gana
—alejarse a 6 casillas antes del contacto— vive en la capa de movimiento, que
el modelo no puede elegir.
3. **Desempate agresivo.** A igualdad de riesgo gana `meanHP` y luego
`resourceCost`; `hit` cuesta 0 y `retreat` 0.02, así que el empate resuelve a
favor de pelear.

Conclusión para el plan: **no se enciende `ZZBOT_MODEL` hasta arreglar esos
tres puntos y volver a medir.** El simulador no es el problema; el punto de
decisión y la política de repliegue sí.

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
| **P5** | Combat model: fix the decision point and the retreat policy, then ranged/AOE/powers (6.5); Zoom survival (6.4) | P4 | The simulator already exists; the wiring is what loses fights |
| **P5b** | Learning loop: make `knowledge` produce and use data, with a lethal-scenario library (P8/P8b/P9 already built) | P5 | A model that is wrong about a fight the same way twice is a data source; today it has no data |
| **P6** | Campaign graph (6.7) with relics 2, 1, 3, 4 in that order; herbs (6.10); reputation/shops (6.8) | P1–P5b | First real end-to-end objectives |
| **P7** | Ships/sea (6.9), Tower of Veils chain, Lament, Archon, ending | P6 | Longest dependency chain, highest risk |

**Re-sequenced work, in the order the evidence supports:**

- **V0 — make the flags measurable (done 2026-11-12).** `tools/regress.sh`
  accepts `MODEL=1`, `LEARN=1`, `GEAR=0` from the environment and keeps the
  learned ledger inside the scenario's own XDG dir, so the same save can be run
  twice without one run teaching the next. Every acceptance test below is an
  A/B against the current default.
- **V1 — fix the model before switching it on.** (a) When every contact option
  exceeds `alpha`, hand the tick to the `avoid`/kite layer instead of executing
  a 98%-death hit; (b) allow the model to be consulted in the approach window
  (`dist <= 6`) so retreat is priced while it still works; (c) tie-break that
  does not prefer the free action when the pack is unaffordable. Gate: `dungeon`
  and `newgame` with `MODEL=1` must be no worse than baseline on `!death` and
  `level_done`, N≥3.
- **V2 — the actual P5 v2: ranged and powers in the action set.** `shoot` is
  **done (2026-11-13)**: `buildCombatOptions` offers it from `getFinalPlayerRange()`
  and ammo, `executeChoice` fires `rangedWeapon` via `targetedOffset` +
  `performPendingActionAtTargetLocation`, and `tools/test_model.lua` has the
  ranged case. Remaining: `power` from `powers.lua` descriptors (single-target,
  AOE, self-heal, energy/cooldown gated by the caller) and its tests (AOE beats
  single target on a pack, a power on cooldown is not chosen).
- **V3 — learning with data.** Turn `ZZBOT_LEARN=1` on for a batch of runs so
  the Beta ledger gets observations (it stays at 1.0 until 5 per enemy band),
  add the "lethal scenario" library (`save-on-death` + `regress.sh`), and score
  genomas with it instead of 15-minute full runs. Only then judge `evolve.lua`.
- **V4 — flip the defaults.** `ZZBOT_MODEL`, `ZZBOT_LEARN`, `ZZBOT_GEAR`,
  `ZZBOT_DIALOGUE`, `ZZBOT_POWERS` move to 1 one at a time, each with the whole
  scenario suite green before and after.

**Why Zoom comes late:** the deaths are a combat-capability problem (no pre-buff, powers, ranged), so diagnosing and fixing them needs P4/P5. In P0, add only the death-diagnosis instrumentation and a conservative "flee at first sight of a losing verdict" tweak.

**Why campaign is late:** each relic dungeon is only as good as the loot sweep, combat and gear underneath it. Starting with the campaign would produce deaths with no way to diagnose them.

**Why the learning phase is new and sits before the campaign:** `knowledge.lua`,
`evolve.lua`, `trace.lua` and `postmortem.lua` are already written and tested,
but no run has ever written a ledger entry (`knowledge fresh: 0 deaths, 0
kills, 0 enemy kinds` is the only line any log contains), so the feature cannot
be judged, and the campaign would consume deaths without learning from them.

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
  - **Done (2026-11-12).** `Gear.planEquip` requires a 2.0x score gain (vs 1.15x for known gear) when `identified == false`, and the plan entry carries `unidentified`; `equipStep` logs it and emits `equip` with `unidentified=true`. Pinned by two tests in `tools/test_gear.lua`. Still open: what `isItemInert` means for a cursed item once worn — no in-game example seen yet.
- **Healing selection.** Extend `findHealPotion/useHealItem`: bandages, ointments, blood phials and lifestones as taboo-allowed. Dust must not use potions or ointments (except `potion_water`); Lady must not use non-blood food. Add a "don't waste" rule: heal only when predicted incoming burst, or HP, passes a threshold, rather than at a flat percentage.
  - **Done (2026-11-12).** Cures are data-driven from `useFX1` (`G_Globals.cureStates`): bleed=Bandage, flame=Water, poison=Antidote, rot=Sera-leaf Oil, stun=Acitra Nectar, torpor=Blackwater Draft, blind=Sightsalve, mad=Bitterleaf Brew, deafness=Silentsalve, all=Arnaut's Panacea. `Gear.curePlan` picks the specific cure first and only spends the panacea on 2+ ailments (or a single health-draining one). `DATA.cureStep` runs at the top of `tryHeal`, never uses a cure whose status is not active, emits `cure`/`nocure` events and calls the P4 `Taboo.check(profile, "heal", …)` hook.
- **Burden.** Keep burden under the multiplier threshold. When above, the drop ladder is: (1) equip upgrades, (2) drop the lowest value-per-weight item that isn't protected, in dungeons, (3) a sell trip only if the campaign allows. Inventory-full is not slot-based unless the source says otherwise (§8).
  - **Open question answered (2026-11-12): the game has no player-facing drop.** Items leave the inventory only through use (`destroyOnUse`), sale (`sell_panel.lua`), or crafting/repair consumption (`actions.lua`); the only `drop` is the console command `console_drop`, which spawns a *new* object on the floor and does not remove the original. So step (2) of the ladder cannot be executed and `Gear.dropLadder` has no consumer by design: burden is managed by *not buying* and by selling. Keep the ladder as pure policy, do not wire it to a fake drop.
  - Burden is now logged from the game's own numbers every beat (`burden weight=W/MAX mult=X`, `getRawPlayerBurdenAndMaxBurden` + `getPlayerTickCostMultiplier`). Multiplier is 0.8 empty, 1.0 at max burden, and grows past 1.0 above it; observed 0.87 at 14/40 in the smoke start.
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

### 3.5 Combat model (6.5) — P5

**Ya existe (`mod/zzbot/model.lua`, 816 líneas).** Simula el reloj de combate de
Moonring: poise que absorbe sin desbordar, mordiscos con distribución Bates(3)
por el CV real, veneno que resta la mitad de la vida actual y no mata, aguijones
que invocan 2-4 avispas con su propio `attackTime`, huida con `allOutrun`, y
rollouts de referencia de N=64 semillas. `M.evaluate` devuelve `pDeath`,
`pDeathUpper` (Wilson 95%), `meanHP`, `p10HP`, daño medio, duración y kills.
Soporta las acciones `attack`, `shoot`, `power` (single/AOE/self-heal), `heal`
(con `enemyHeals` del Lifestone), `choke`, `flee`, `move` y `wait`. También
tiene `readiness` (usada al cruzar el ferry) y `rank`.

**Lo que no está cableado, y por eso pierde** (ver §0.0 para el A/B completo):

- ~~`buildCombatOptions` nunca ofrece `shoot`~~: **hecho (2026-11-13)**. Se
  ofrece `shoot` contra todo enemigo de `near` dentro de `getFinalPlayerRange()`
  (3 con las piedras iniciales, 4 en `CActions.static.data`, manda el arma) y
  con línea de fuego (`getLOMToWorldXY`), con `damage` de
  `CActions.getRangedAverageDamage` (8 con `throwing_stones`) y `time` de
  `weaponTimeCost`. `executeChoice` fija `targetedOffset` y llama a
  `performPendingActionAtTargetLocation`; la munición se cuenta desde la pila
  equipada, así que un arma sin piedras no genera la opción.
- El modelo solo se consulta con `#adj > 0`, es decir, cuando el enemigo ya
  pega. **Parcialmente corregido**: sin adyacentes la rama se abre solo si hay
  un `shoot` posible, que es cuando el modelo aporta algo (disparar vs esperar
  vs replegarse); la aproximación a más de `range` sigue en la capa de
  movimiento. `power` sigue sin proponerse.
- `chooseEval` no tiene repliegue: si la mejor opción está al 98% de muerte,
  la ejecuta igual ("minimise risk" es solo una etiqueta en el log).
- Empate a riesgo → `meanHP` → `resourceCost`, y el ataque cuesta 0.

**Trabajo, en este orden:**

1. **Repliegue.** Si `pDeathUpper` de todas las opciones de contacto supera
   `alpha`, devolver `false` desde la rama del modelo para que manden las capas
   de kite/`avoid` (que en el baseline sobreviven), y loguear
   `model: all contact options > alpha (best=... )` una vez por ventana. Con
   `shoot` vivo el modelo ya no muere en `dungeon`, pero sigue sin válvula para
   el caso de que todas las opciones sean malas.
2. **Ventana de aproximación.** Llevar la ventana más allá de `range`
   (acción `move`/`retreat` ya modeladas) para que "alejarse y disparar"
   compita contra "esperar a que llegue". Mantener el veto de curar sin daño
   cercano que ya existe.
3. **Poderes.** `power` desde `powers.lua` con
   `energyCost`/`cooldown`/`targetingType` leídos de `CActions.static.data`.
   `shoot` ya está (ver arriba); falta medir consumo de munición y acierto.
4. **Auto-calibración.** `power_result` con daño predicho vs observado y
   `shoot` con acierto/fallo, comparados en `tools/postmortem.lua`.
5. **Encender.** `ZZBOT_MODEL=1` por defecto solo cuando el A/B (§5) empate o
   gane en `dungeon` y `newgame`, N≥3. `S.modelErrors < 5` sigue como fallback.

**Tests:** `shoot` ya tiene dos casos en `tools/test_model.lua` (a tres
casillas mata y `attack` no; fuera de su `range` no mata). Faltan: `power`
(AOE con `radius>1` mata más que un golpe simple contra un pack), una acción con
`time` absurdo que no domine, y `rank` prefiriendo `pDeathUpper` menor antes que
`meanHP` mayor.

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

### 3.11 Learning from deaths (P8, P8b, P9) — P5b

**Ya existe:**

- `knowledge.lua`: ledger Beta por (`actorType`, banda de nivel). Cada muerte
  sube la peligrosidad, cada kill la baja; el multiplicador está limitado a
  `[0.5, 4.0]` y **no se aplica hasta tener 5 observaciones**. Escala solo el
  daño entrante (`hit`, `maxHit`, `dps`, `cost`) en `threatList`, es decir, lo
  ven el modelo **y** la heurística, no el daño que hacemos.
- `trace.lua` + `tools/postmortem.lua`: anillo de 60 ticks, clasificación
  `SURPRISE`/`WARNED` de cada muerte, agregados de calibración.
- `tools/evolve.lua`: GA offline sobre `alpha`, `horizon`, reservas y márgenes,
  con élite y genoma #1 = default.
- `ZZBOT_POLICY=cautious|aggressive|bandit` ya etiqueta cada `EV` de muerte.

**Lo que falta para que signifique algo:**

1. **Datos.** Ningún run ha escrito ledger (`knowledge fresh: 0 deaths, 0
   kills, 0 enemy kinds`). Encender `ZZBOT_LEARN=1` en una tanda de runs, y
   mantener el fichero por escenario para no mezclar bandas.
2. **Evaluación barata.** La Capa 2 del plan-Claude ("biblioteca de escenarios
   letales") sigue sin hacer: guardar el save unos segundos antes de cada
   muerte (`save-on-death` en `tools/regress.sh`) y puntuar genomas por
   supervivencia en esos escenarios. Sin eso, cada evaluación son 15 minutos y
   el GA no converge.
3. **Atribución.** `death by=nil` en el evento: `parseKiller` no encontró el
   nombre en los últimos textos. Sin `by=`, el ledger aprende de la banda pero
   no del enemigo, que es justo la señal que se quiere. Arreglar la atribución
   antes de sacar conclusiones del aprendizaje.
4. **Un solo camino.** El ledger llega al modelo a través de `threatList`, así
   que funciona con `ZZBOT_MODEL=0`; conviene fijarlo con un test de integración
   (dos enemigos, una muerte, `threatMult > 1` en el log).

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
| **V0** | `save-dungeon-start`, `save-empty` | `MODEL=0/1`, `LEARN=0/1`, N≥3 | `death`, `level_done`, `choice`, `knowledge` | Hecho: baseline PASS (19/20 a t=276) vs modelo **FAIL** (muerte t=178). El arnés ya acepta `MODEL=`/`LEARN=` |
| **V1** | same | `MODEL=1` tras el repliegue | `!death`, `level_done`, `model: all contact options` | Modelo ≥ baseline en ambos escenarios, N≥3 |
| **V2** | pack fights, `thunder`/`power` fixtures | `MODEL=1` + munición | `shoot`/`power_result` | `shoot` ya dispara y empata en `dungeon` (19 tiros en el A/B); falta AOE > golpe simple en packs |
| **V3** | lethal-scenario library | `LEARN=1` | `knowledge` loaded/saved, `death by=` no nulo | Ledger con ≥5 observaciones por enemigo y atribución correcta |
| **V4** | full suite | defaults a 1 | all previous assertions | Suite completa verde con los flags encendidos |
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
6. **Equip timing:** whether equipping costs game time, whether it is allowed in combat, and what `isItemInert` / unidentified items imply (`inventory_panel.lua:398–455`, `state_game.lua:17728, 17792`). **Parcial (2026-11-12):** unidentified gear now needs a 2.0x gain; `isItemInert` still unobserved.
7. **Power effect handlers** in `actorManager:performActionWithActor`, to author model descriptors. Also the exact meaning of "technology" for Lady's taboo and the Harlequin weapon predicate (`state_game.lua:20354–20432`).
8. **Sin decay and curse recovery:** `alterSin`, `removeCurse` (`state_game.lua:20491`) and where the game invokes it.
9. **Binding powers:** whether writing `skillBindings` (`skill_tree.lua:429`) directly is safe or the UI path has side effects; whether any skill cells require NPC trainers.
10. **Inventory limits:** slot cap vs burden only; the burden value where `getPlayerTickCostMultiplier` starts penalizing; whether dropping items is possible and how. **Respondido (2026-11-12):** there is no player-facing drop. Items leave the inventory only by use (`destroyOnUse`), sale, or crafting; `console_drop` spawns a new floor object and does not remove the original. The multiplier is `lerp(0.8, 1, weight/max)` below max burden and `weight/max` above it, and is now logged every beat (`burden weight=14/40 mult=0.87` in the smoke start).
11. **How Zoom is entered** from the overworld or towns, and whether it can be avoided on a route.
12. **Lockpick consumption and the chest-key flow** (`attemptToUnlockChestAtMapXY`, `actor.lua:5337`).
13. **RNG seeding** from the mod, for reproducible runs.
14. **When the game autosaves**, and what happens to unsaved progress on death or quit (impacts resume).
15. **Role of `archonDungeon-01` and the `magick` flag** (MUT triggers CSV), and the exact `archon1` branch conditions for good vs bad ending.
16. **Sea:** `isSailing`, `callShipToXY`, the Yeleba/Cannon2 requirement, and whether the Tower chain needs a ship at all.
17. **Why does the model call adjacent flight fatal?** In the A/B it priced `flee` at `pDeath=100%` with one hornet adjacent and kept choosing `hit` instead. Verify with a fixture whether that is the model being right (a parting bite chain) or the flee rollout being short (`moveSteps` 1-8 over a `horizon` that outlasts it).
18. **Ranged aiming flow:** *respondida (2026-11-13).* No hace falta abrir el overlay de apuntado. `G_Globals.keyRanged = "r"` solo cambia `IM_INPUT.ranged`, que en `state_game.lua:4033` llama a `getFiringErrors()` y a `playerInitiatingAction("rangedWeapon", player:getFinalPlayerRange())`; la acción es `targetingType="location"`, `distance=4`, `radius=1`, `timeCost=12`, `isBlockedByWalls=true`. `getFiringErrors` exige `isSkillUsableByPlayer("rangedWeapon")`, `player.rangedInventoryID ~= 0` y `player:getAmmoForCurrentRangedWeapon() > 0`. El bot reproduce el disparo con `player.targetedOffset:set(dx,dy)` + `player:performPendingActionAtTargetLocation({id="rangedWeapon", distance=…, radius=1, noPrediction=true, playerDoesNotBlockTarget=false, isBlockedByWalls=true})`; queda por verificar en partida que consume una piedra y que la `rangedAngleVariance` (escalada por percepción) explica los fallos que registre el log.
19. **Kill/death attribution:** why `parseKiller` returns nil on real deaths (`EV|kind=death ... by=nil`). The learning ledger needs `by=` to move the right multiplier.

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

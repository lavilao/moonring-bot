# Worklog — moonring-bot

Última actualización: 2026-11-07 (handoff Claude para el bloqueo de descenso multi-nivel; estado: primer piso se barre, siguiente piso no entra).

Objetivo: bot autónomo estilo qw para **Moonring**. Debe iniciar una partida nueva,
llegar desde el pueblo Yarrow a **Yarrow Cave** (`firstDungeon-01`), explorarla,
obtener la **llave maestra** (`key_master`), salir de la mazmorra y volver a Yarrow.

Proyecto independiente de `qw2`, en `/home/lavilao570/Projects/moonring-bot`.

**Es un repositorio git** (`origin` remoto, rama `master`). El trabajo local sin
confirmar se guarda con `git stash` antes de cualquier `git pull`; al recuperarlo
revisar que los cambios del remoto no lo hayan dejado obsoleto.

---

## 1. Restricciones y aislamiento

- No tocar el save real del usuario (`~/.local/share/Moonring`).
- No modificar el AppImage original (solo se extrae una copia en `work/`).
- Todo el trabajo vive en `moonring-bot/`.
- Los saves del bot van a `work/xdg/love/moonring-bot` porque `tools/run.sh` exporta
  `XDG_DATA_HOME=$ROOT/work/xdg`.

## 2. Comandos habituales

```bash
cd /home/lavilao570/Projects/moonring-bot

# tras editar mod/zzbot/*: copia el mod y añade require("zzbot") a main.lua
tools/build.sh

# modo automático completo (headless), sin ventana
: > logs/zzbot.log
ZZBOT_HEADLESS=1 ZZBOT_SPEED=8 ZZBOT_TIMEOUT=300 ZZBOT_QUIT=1 \
ZZBOT_AUTOSTART=1 ZZBOT_START_ON=1 tools/run.sh
tail -f logs/zzbot.log

# modo interactivo: el bot arranca DESACTIVADO; juegas normal y pulsas F9
# para activarlo/desactivarlo cuando llegues a una parte tediosa
ZZBOT_SPEED=4 ZZBOT_AUTOSTART=0 ZZBOT_START_ON=0 tools/run.sh
```

Tecla de toggle: **F9** (configurable con `ZZBOT_TOGGLE`). F8 está ocupada
(consola del juego). Al desactivarlo, el juego corre a velocidad normal y el bot
deja de inyectar teclas; al reactivarlo continúa desde el estado actual.

Variables de entorno del bot:

| Variable | Default | Uso |
|---|---|---|
| `ZZBOT_NAME` | `QwBot` | nombre de la partida nueva |
| `ZZBOT_SPEED` | `4` | ticks de simulación por frame (1/40 s cada uno) solo con el bot activo |
| `ZZBOT_TIMEOUT` | `1800` | segundos de bot activo antes de abortar |
| `ZZBOT_LOG` | `$ROOT/logs/zzbot.log` (run.sh) | archivo de log |
| `ZZBOT_QUIT` | `0` | `1` = cerrar el juego al terminar (éxito/muerte/timeout) |
| `ZZBOT_AUTOSTART` | `0` | `1` = crear partida nueva automáticamente desde el título |
| `ZZBOT_START_ON` | `0` | `1` = bot activo desde el arranque |
| `ZZBOT_TOGGLE` | `f9` | tecla para activar/desactivar |
| `ZZBOT_HEADLESS` | `0` | `1` = SDL offscreen + audio dummy |

Códigos de salida en modo `ZZBOT_QUIT=1`: `0` éxito, `1` muerte, `3` timeout.
El timeout solo cuenta el tiempo con el bot activo.

## 3. Estructura del proyecto

```
moonring-bot/
├── mod/zzbot/init.lua        # TODO el bot (~593 líneas, con logs dbg temporales)
├── tools/build.sh            # extrae AppImage + descomprime juego + inyecta mod
├── tools/run.sh              # LÖVE 11.5 vendorizado, XDG aislado, headless opcional
├── tools/fetch-love.sh       # descarga LÖVE 11.5 a vendor/ (ya hecho)
├── vendor/squashfs-root/     # LÖVE 11.5 extraído (bin/love, lib/)
├── work/appimage/            # Moonring.AppImage extraído (solo lectura)
├── work/moonring-bot/        # juego descomprimido + mod inyectado (se regenera)
├── work/xdg/                 # saves aislados del bot
└── logs/zzbot.log
```

AppImage original: `/mnt/chromeos/MyFiles/Downloads/moon/Moonring.AppImage`
(también se puede pasar como argumento a `tools/build.sh`).

`tools/build.sh` hace:
1. extrae el AppImage a `work/appimage/squashfs-root` (una vez);
2. descomprime el zip Lua embebido en `bin/Moonring` a `work/moonring-bot`;
3. borra/copia `mod/zzbot` a `work/moonring-bot/zzbot`;
4. añade a `work/moonring-bot/main.lua`: `require("zzbot")`.

## 4. Arquitectura del mod (`mod/zzbot/init.lua`)

Puntos de entrada y flujo:

- `require("library.gamestate")` y CFG/estado en `S` (líneas 1-38).
- **Parche de cursor** al hacer `require` (líneas 60-77): el driver SDL `offscreen`
  no soporta cursores y el juego muere en `main.lua:1068`. Se envuelven
  `love.mouse.newCursor/setCursor/setVisible` con `pcall`.
- **Hook de `love.update`** (líneas 961-978): ejecuta `pollToggle`, `checkGlobal`,
  instala el hook de input y, **solo si el bot está activo**, llama `N` veces a
  `love.update` original con `dt=1/40` (velocidad). Si está desactivado, corre
  `originalUpdate(dt)` una vez: el juego se juega normal.
- **Toggle F9** (`pollToggle`): activa/desactiva el bot en caliente. Al activar
  reinicia el contador de tiempo y el estado de éxito/muerte para esa sesión;
  conserva el mapa conocido y continúa desde la posición actual.
- **Hook de `G_stateGame.getPlayerInput`** (líneas 916-935): antes del input real
  ejecuta `tick(self)` dentro de `pcall` solo si el bot está activo. Este es el
  punto donde el bot actúa, porque solo se llama cuando el jugador puede recibir
  input (`tileScreenManager.zoomFraction == 0`).
- **Inyección de teclas** (líneas 87-110): escribe en
  `G_Keyboard.currentKeyPressDictionary` **y** `justPressedDictionary`. Esto es
  imprescindible: `G_Keyboard.fixedUpdate` reconstruye ambos diccionarios cada
  tick desde `love.keyboard.isDown`, así que ambos deben marcarse en el mismo tick.
- **Diálogos** (`handleDialogs`, líneas 324-350):
  - `alertBox` abierto -> Return.
  - `confirmBox` abierto -> poner `confirmBox.confirm = true` y Return
    (por defecto `confirm=false`).
  - `tutorialBox` abierto -> Space cuando `fraction>=1` y `time>=0.5`.
  - `speechArea` / `multiChoiceBox` -> Return.
- **Mundo** (`tickWorld`, líneas 352-463):
  - detecta cambio de mundo y resetea el set de celdas conocidas;
  - marca `S.entered` al entrar a un mundo con `dungeonType`;
  - **solo actúa si `player:isFreeToMove()`**;
  - rama pueblo: va a las escaleras `playerStart` con data `firstDungeon-01` y
    pulsa Return encima;
  - rama mazmorra: curar -> si hay `key_master` ir a la salida -> combatir ->
    cofre `exitKey` -> explorar frontera.
- **Exploración** (líneas 213-277): set persistente `S.known` con las celdas
  `isVisible` (la niebla borra `isRemembered`, por eso no se usa). BFS desde el
  jugador sobre celdas conocidas y transitables; la primera celda conocida que
  toca una celda desconocida es la frontera. Se valida con el planificador.
- **Pathfinding propio** (`navSteps`, líneas 161-207): BFS sobre `map.cells` que
  trata puertas cerradas, puertas secretas y cajas/barriles como transitables.
  Al pisar una de esas celdas se empuja (se abre/rompe) y el siguiente tick se
  vuelve a planificar. Esto evita depender de `navMapWalkOnly`, que las considera
  muros.
- **Combate** (`combatStep`, líneas 345-389): enemigo visible **hostil y
  matable** más cercano (`player:isEnemy` + `isKillable`, no neutrales). Usa
  `actorManager:getNextStepTowardNearestReachableEnemy`, que devuelve pasos como
  **array `{dx,dy}`** (¡no `{x=,y=}`!). Valida que el paso no sea `{0,0}` ni un
  muro; si no sirve, ataca si está adyacente o usa el pathfinding propio.
- **Curación** (líneas 320-343): si HP < 40%, sin enemigo adyacente y cooldown de
  6 turnos. Busca item con `findInventoryObjectWithUseFX("heal")` y luego
  `"healing_stone"` (Lifestone); usa `game:useItemWithInventoryIndex(item.ID)`.
- **`checkGlobal`** (líneas 491-554), cada frame renderizado:
  - autostart en title screen con `G_stateTitleScreen:startFreshGame(CFG.name)`
    cuando `title.time > 1`;
  - muerte -> FAIL y quit 1;
  - éxito: `S.entered` + mundo con `isTown` + sin `key_master` -> SUCCESS y quit 0;
  - timeout -> FAIL y quit 3;
  - heartbeat cada 20 s.
- **Logs dbg temporales** a eliminar antes de la versión final:
  - líneas 389-410 (dump de navegación en el pueblo),
  - líneas 470-481 (dump de estado por tick).

## 5. Mecánicas del juego verificadas

### Input y tiempo

- El juego simula en ticks fijos de `1/40`; `G_stateGame:fixedUpdate` llama a
  `getPlayerInput` solo cuando `tileScreenManager.zoomFraction == 0`.
- Multiplicar `love.update` es determinista y acelera la simulación.
- `G_Input.isDown` lee `currentKeyPressDictionary`; `isPressed` exige
  `justPressedDictionary`.

### Paneles

- `alertBox`, `confirmBox`, `tutorialBox`, `speechArea`, `multiChoiceBox`.
- `game:isUIBlockingPlayerMovement()` los cubre.
- `confirmBox.confirm` debe ponerse a `true` antes de Return.

### Movimiento y navegación

- `player:isFreeToMove()`: `moveFraction == 1`, sin cooldowns.
- Movimiento bloqueado además por `isAnyNonPlayerActorStillSpendingTime`,
  `isAnimationBlocking`, paneles.
- Coordenadas de mundo == coordenadas de mapa en pueblos y mapas con zoom.
- `map:getNavStepsFromXYToXY(nav, sx, sy, tx, ty, actor)` devuelve pasos
  relativos `{x,y}` (primer elemento = siguiente paso).
- Navigator: `player.navigator` o `map:createNavigator(map.navMapWalkOnly)`.
- Transitabilidad: `CCellData.cellTypeArray[cell.typeIndex].isWalkable`;
  `map.cells[y+1][x+1]`.
- `navMapWalkOnly[y+1][x+1] == 0` significa transitable.

### Entrada y salida de mazmorra

- Entrada: estar en la celda de las escaleras + Return ->
  `performDefaultEnterAction` -> rama "deeper" (`playerStart` con data
  `firstDungeon-01`) -> `confirmBox` con `miniDungeonText` ->
  `changeDungeonLevelDeeper`.
- Salida: escaleras con trigger `fnUp` + `playerStart` con data `Yarrow`.
  Si `canReturn == false`, exige `key_master`: muestra alert, consume la llave y
  llama `leaveRelicDungeon` (el mundo cambia de inmediato; la animación de zoom
  es cosmética).
- Cofre de llave: trigger `exitKey` en la celda del cofre. Al abrir/recoger,
  `collectPickupTriggerAtWorldXY` añade `key_master`.

### Niebla

- `isVisible` = FOV actual; `isRemembered` se borra al perder de vista.
- El bot mantiene su propio set persistente a partir de `isVisible`.

### Cofre de la llave maestra en CaveYarrow (importante)

- `world_data.lua:87`: `firstDungeon-01` tiene `dungeonType = "CaveYarrow"`,
  `canReturn = false`, `hasStairs = false`.
- `dungeon_data.lua:664`: CaveYarrow tiene `needsExitKey = true`,
  `miniBossProbs = {silverwolf = 1}` y `waterMonsters`.
- `placeWeightedPrizeDictionaryInChest` (`state_game_dungeon_chunks.lua:3335`)
  crea el cofre del premio principal. Si recibe `lock_data_string`, **descarta**
  los datos de la cerradura y solo pone la celda en `chestLocked`; además añade
  los triggers `container` (premio) y `exitKey`.
- `attemptToUnlockChestAtMapXY` (`actor.lua:5337`): como `dungeonType` no es
  `"fixed"`, si no hay trigger `locked_chest`/`lock`, el cofre solo se abre con
  **`chest_key`** (se consume) o con `key_master` (que es justo el premio, así
  que no sirve). Sin llave imprime "Locked! Needs chest key!" y no se abre.
- La `chest_key` la lleva el **miniboss silverwolf** (`dungeon_gen_base.lua:3270`,
  `state_game_dungeon_chunks.lua:2567/3110`) o está en un contenedor/objeto.
  Al matar al portador, la llave cae como trigger `object`; hay que pisarla.
- Secuencia real: matar al silverwolf -> pisar la `chest_key` caída -> ir al
  cofre con trigger `exitKey` -> bump (consume `chest_key`, `chestLocked` pasa a
  `chestClosed`) -> segundo bump (recoge el `container` y el `exitKey` añade
  `key_master`).
- El bot implementa esto con las fases `key-carrier`, `key-container`, `to-key`
  (`tickWorld`, líneas ~720-762). Nunca debe empujar el cofre `chestLocked` si
  no tiene `chest_key` ni `key_master`.

### Código del juego (copias en `work/moonring-bot/`)

| Archivo | Línea | Contenido |
|---|---|---|
| `state_game.lua` | 3486 | `getPlayerInput` |
| `state_game.lua` | 7951 | `fixedUpdate` |
| `state_game.lua` | 11440 | `performDefaultEnterAction` |
| `state_game.lua` | 12001 | `checkLockedEntrances` |
| `state_game.lua` | 12038 | `useItemWithInventoryIndex` |
| `state_game.lua` | 13452 | `changeDungeonLevelDeeper` |
| `state_game.lua` | 13532 | `leaveRelicDungeon` |
| `state_game.lua` | 13751 | `fnHealingStone` |
| `actor.lua` | 4914 | `collectPickupTriggerAtWorldXY` |
| `actor.lua` | 4990 | `interactWithMapCellAtMapPositionXYZeroIndexed` |
| `actor.lua` | 5103 | `interactWithMapCell` (rutea a unlock door/chest) |
| `actor.lua` | 5237 | `attemptToUnlockDoorAtMapXY` |
| `actor.lua` | 5337 | `attemptToUnlockChestAtMapXY` |
| `actor.lua` | 3208 | `isFreeToMove` |
| `actor.lua` | 1096 | `getIsVisibleToPlayer` |
| `actor.lua` | 1323 | `isEnemyOrNeutral` |
| `actor.lua` | 6947 / 6990 | `findInventoryObjectWithName` / `WithUseFX` |
| `map.lua` | 2468 | `convertWorldXYToMapXYZeroIndexed` |
| `map.lua` | 2810 | `createNavigator` |
| `map.lua` | 2838 | `getNavStepsFromXYToXY` |
| `trigger_data.lua` | 108 | `addToLevel` |
| `trigger_data.lua` | 470-680 | lookups (`findTriggerXYOnLevelWithAction*`, etc.) |
| `cell_data.lua` | 36-39 | `unlockTileData` (secretDoor -> doorOpen) |
| `cell_data.lua` | 757-761 | `cellIsSecretDoor` |
| `cell_data.lua` | 1103-1107 | secret doors son `isWall` |
| `cell_data.lua` | 1291-1302 | flags de cofres (`isLocked`, etc.) |
| `main.lua` | 1068 | creación del cursor (causa del crash headless) |

## 6. Modelo de combate general (implementado en `mod/zzbot/init.lua`)

El bot no tiene reglas específicas de Yarrow: todo se deriva de mecánicas y de
los CSV de actores/objetos, así que aplica a cualquier mazmorra y enemigo.

### Pesos por enemigo (`enemyWeight`)

Por cada hostil visible se calcula: `hp`, `speed` (con `isFast` ya doblada),
`dodge`, `defFrac` (daño que atraviesa su armadura), `attackTime`, `hit`
(daño medio por golpe, con varianza, crítico y esquiva del jugador), `maxHit`
(peor golpe posible: varianza máxima + crítico), `dps`, `ourHit`/`ourDps`
(nuestro daño efectivo contra él), `ttk` y `n` (golpes que necesitamos).
Flags: `aware`, `carrier` (lleva `chest_key`), `summoner`
(`offensiveActions`/`supportActions` con un nombre que contenga "summon"),
`poison`, `fast`.

### Presupuesto de salud (`Hreq`, `lethalBound`, `verdict`)

- `Hreq(pack, W)`: salud necesaria para sobrevivir `W` ut con 99 % de
  confianza (media + `Z99·σ`; los lejanos llegan tarde).
- `lethalBound(pack, W)`: peor golpe crítico que puede llegar en `W` ut. Si la
  salud está por debajo, curarse deja de ser una decisión de valor y pasa a ser
  obligatoria.
- `verdict`: `open` si un único enemigo es asumible; `choke` solo si el coste
  de embudo es asumible **y** estamos en un callejón sin salida
  (`passableNeighbourCount <= 1`); `avoid` en cualquier otro caso. El modelo de
  embudo (solo uno puede morder) nunca se aplica en campo abierto.

### Prioridad de objetivo

- `pickTarget` (Smith): mayor daño por golpe primero (`dps/n`). El portador de
  la llave va primero si el resto se puede dejar atrás. Los invocadores suman
  +0.75 porque siguen alimentando el combate.
- `approachTarget` (nadie adyacente): portador +1000, invocador +50; el resto
  por `dps/n` y cercanía.
- Golpe de gracia: si un adyacente muere de un golpe (`hp <= ourHit·0.9`), se
  remata antes de curarse o de atacar a otro.

### Curación (`tryHeal`)

- Modelo de intercambio: `Gp` = salud que ganamos, `Ge` = salud que el Lifestone
  devuelve a los enemigos adyacentes (tope por su salud faltante),
  `dM_ls = Gp - λmax·Ge - D·C_LS`. Solo se usa si `dM_ls > 0`.
- **Poción primero** en emergencia: nunca ayuda al enemigo. Luego Lifestone si
  es rentable. Si el próximo golpe es letal y no hay poción, se usa el Lifestone
  aunque el intercambio sea negativo, siempre que `hp + Gp > lethalBound(adj)`:
  lo que el enemigo recupera le compra un turno, no la pelea.
- "Emergencia" = **solo enemigos adyacentes** pueden matar la próxima acción.
  Los que aún caminan pertenecen al veredicto del pack y al enrutado, no a un
  heal que regala el turno mientras se acercan.
- Tras la llave, recarga hasta 300 con ventana limpia antes de seguir.
- Kite solo si no hay cura que merezca la pena; curarse siempre gana a un kite
  que quizá no abra el hueco.

### Enrutado consciente de enemigos

- `travelDangerMap`: penalización suave por celda según radio de detección
  (`max(smellDistance, sight)`; el olfato ignora paredes) de cada hostil
  visible; `weightedSteps` = Dijkstra con coste base + penalización, evitando
  celdas de actores visibles y telarañas.
- `travelSteps` se usa en `moveToward`, `approachCell`, `moveToActor`, `doFlee`
  y `retreatPath`: tanto avanzar como huir rodean los grupos conocidos.
- Tras la llave la misión es salir vivo: recarga, rompe contacto si se puede
  correr más rápido (`allOut`) y no se engancha en otra pelea.

### Constantes actuales (`CC`)

`C_LS=12`, `C_POT=12`, `LS_CD=4`, `LS_FRAC=0.75`, `LS_RESERVE=1`,
`POT_MAJOR=450`, `POT_MINOR=225`, `DM_PEACE=150`, `MIN_GE_HEAL=100`,
`OUT_MARGIN=0.5`, `POSTKEY_HP=300`.

## 7. Mecánicas nuevas verificadas (esta sesión)

- **Poise**: `G_MAX_POISE=200`. Mientras `poise > 0` absorbe el golpe entero sin
  tocar salud (`alterHealthAndDieIfAppropriate`), sin desbordamiento. Se
  regenera `poiseFractionPerTick=0.0125 · food_frac · maxPoise` por tick tras
  `poiseRegainCooldown=36` ticks sin heridas, y **se detiene si hay un enemigo
  adyacente** (`G_EngagementStopsPoiseRecharge`). Fuente:
  `state_game.lua:2440-2480`, `data/Globals`.
- **No hay regeneración de salud**: `G_HealthBarHasLowestLimit = false`
  (`main.lua:101`), así que la salud es un recurso finito por incursión. La
  única recuperación gratuita es el poise.
- **Lifestone**: durabilidad 10, `rotPerUse=2` → **5 usos**, no 10. Cura
  `floor(0.75·maxHP)` al jugador (tope por salud faltante) y lo mismo a los
  enemigos en las 4 celdas cardinales (tope por su salud faltante).
- **Llave maestra**: al salir por la puerta, el juego la consume ("turns to
  dust", `removeInventoryItemWithID`) y `leaveRelicDungeon` cambia de mundo.
  Por eso el éxito se detecta como "de vuelta en el pueblo **sin**
  `key_master`" con `S.entered` como guarda.
- **Cajas de tutorial**: `tutorialBox` **no** está en
  `isUIBlockingPlayerMovement`; se cierra sola a los 6 movimientos y no bloquea
  la marcha. Las de alerta/confirmación/speech/multi sí bloquean.
- **Cuerpo a cuerpo solo cardinal**; no se ataca en diagonal.
- **Invocadores**: `wasp_nest` tiene `summonHornets` en sus acciones; hay ~20
  tipos con "summon" en `ActorData`. Matar al invocador corta refuerzos.
- **Velocidades**: paso del jugador `8/speed` (1.0–1.25 → 6.4–8.0 ut);
  hornets `1.8` (4.44 ut) son **más rápidos** que el jugador; silverwolf `1.0`;
  large_beetle `0.5`; queen_hornet `0.6` + `isFast`.

## 8. Estado de pruebas headless

Comando de referencia:

```bash
cd /home/lavilao570/Projects/moonring-bot
ZZBOT_HEADLESS=1 ZZBOT_START_ON=1 ZZBOT_AUTOSTART=1 ZZBOT_QUIT=1 ZZBOT_SPEED=8 ZZBOT_TIMEOUT=420 ZZBOT_LOG=/tmp/zzbot-testNN.log ZZBOT_MAPDUMP=/tmp/zzbot-mapNN.txt timeout 240 tools/run.sh
```

Resultados (misma build salvo donde se indica):

| Test | Resultado | Detalle |
|---|---|---|
| test13 | ÉXITO 54 s | `SUCCESS` en turno 5222 |
| test14 | muerte 56,31 | kite-heal adelantaba al Lifestone |
| test15 | muerte 59,29 | pinza queen_hornet + large_beetle |
| test16 | **ÉXITO 56 s, exit 0** | `MASTER KEY acquired at 67,32`; snapshot `success` |
| test17 | muerte 56,31 | mismo caso que test14 |
| test18 | muerte 60,31 | sin recursos; diagnósticos de heal |
| test19 | muerte 61,31 | dM_ls negativo (curar enemigos) |
| test20 | muerte 56,31 | rechazó Lifestone con golpe letal |
| test21 | **ÉXITO 43 s, exit 0** | `MASTER KEY at 67,32`, salida limpia |
| test22 | muerte 60,31 | huyó hacia hornets más rápidos |
| test23 | **ÉXITO 45 s, exit 0** | build final (retirada consciente de peligro) |

La misión (entrar, conseguir las dos llaves, abrir el cofre, salir) está
verificada (test13, test16, test21 y test23, este último con la build final).
La fiabilidad no es 100 %: las muertes se concentran en el pasillo
del nido (x≈59-62, y≈29-34), donde el mapa obliga a pasar junto a
`wasp_nest` + hornets (más rápidos) + `large_beetle`/`queen_hornet`, con
varianza de daño muy alta (`medium_bite 145 ±50 %`, crítico x2; se han visto
mordiscos de 188–266).

### Correcciones de esta sesión

- El cierre por éxito era código muerto: `if S.finished then return end` estaba
  antes del bloque que hacía `love.event.quit(0)`. Movido y verificado
  (`EXIT=0` en test16/test21).
- Curar antes que kite en emergencia: la cura cierta gana a un kite que quizá
  no abra hueco.
- "Emergencia" acotada a enemigos adyacentes (antes incluía el pack a 3–6
  celdas y gastaba cargas a 334 PV).
- `combatStep` antes que la cura fuera de contacto en `tickWorld`.
- Golpe de gracia coherente: `tryHeal` no cura si un adyacente muere de un
  golpe, salvo que el siguiente sea letal.
- Prioridad de invocadores (`summoner`) en `pickTarget`/`approachTarget`.
- Huida y retirada usan el mapa de peligro (antes podían huir hacia otro grupo).

### Limitaciones conocidas / siguiente trabajo

- Sin ataques a distancia ni "pull": hay `throwing_stones x10` sin usar.
- No se espera a recuperar poise antes de entrar a un pasillo (el poise es la
  única cura gratis; 200 PV de escudo en ~80 ticks).
- Cuando los enemigos son más rápidos (hornets) y no se puede huir, el modelo
  solo sabe pelear o morir; falta un modo "no puedo huir": foco al más rápido o
  al invocador y buscar embudo.
- El presupuesto de curas no se planifica a nivel de mazmorra (gastar 5 usos
  para salir es correcto aquí, pero en mazmorras más largas puede faltar).
- Quedan logs `dbg`/`combat`/`beat` permanentes (útiles; no bloquean).

## 9. Errores ya corregidos (para no repetirlos)

- Crash headless `Cannot create cursor`: parche de `love.mouse` en el mod.
- El bot no actuaba: `getPlayerInput` solo corre con zoom completo; se engancha
  ahí y se inyecta en ambos diccionarios de teclado.
- `confirmBox` no confirmaba: hay que forzar `confirmBox.confirm = true`.
- Lectura del PNG: es tipo paleta (color type 3, 8 bits). El índice de celda es
  `r + g*256` y es 1-based en `CCellData.cellTypeArray`; píxel `(x,y)` = celda
  `(x,y)`.
- Ruta a las escaleras imposible: no era un bug de navegación, es el puzzle de
  la puerta `(42,45)` (ya resuelto: llave del suelo, cofre, puerta y escaleras).
- Presupuesto del Lifestone: se contaban 10 usos (durabilidad) en vez de 5
  (`rotPerUse=2`).
- Cofre sin `chest_key`: el bot ya no empuja `chestLocked` sin llave; fases
  `key-carrier`/`key-container`/`to-key`.
- Lifestone curando al enemigo: ahora `dM_ls > 0`, poción primero, y la única
  excepción es el golpe letal con `hp + Gp > lethalBound`.
- `verdict` devolvía string como primer valor: se capturaba con `math.floor`
  (crash). Ahora `local _, openNeed = verdict(...)`.
- Enemigos conscientes a distancia 7–9 se ignoraban: `near` incluye
  `aware and dist <= THREAT_RADIUS`.
- Embudo aplicado en campo abierto: `choke` exige `deadEnd`.
- No se podía desenganchar estando adyacente: `avoid` huye si `allOut`, aunque
  haya enemigo pegado.
- Inventario: el diagnóstico ya vuelca `inv=[...]` correctamente.

## 10. Modelo probabilístico de combate (2026-10-27)

Sustituye al subagente anterior por un simulador propio, verificado contra el
código del juego. Módulo `mod/zzbot/model.lua`, tests en `tools/test_model.lua`
(11/11 PASS).

### Mecánicas verificadas en el código del juego

- **Poise**: máximo 200; mientras `poise > 0` un golpe se absorbe ENTERO, sin
  derrame; cualquier daño resetea `timeSinceLastInjured`; regenera
  `0.0125*maxPoise`/ut tras 36 ut sin daño y solo sin enemigo adyacente. No hay
  regeneración de vida.
- **Veneno**: no es DOT. `poisonMelee` acumula un medidor (hornet 0.15/golpe);
  al llegar a 1 se pierde `ceil(0.5*HP actual)` de golpe, ignora poise, NO puede
  matar (se queda a 1 PV) y el medidor vuelve a 0 (`actor.lua:4058-4066`,
  `8515`). Decae `0.00125`/ut tras 10 ut.
- **Daño**: `ceil((r1+r2)*0.5)` con r1,r2 ∈ [ceil(d*(1-var)), d] → triangular
  alrededor de `d*(1-var/2)`; crítico x2; `applyCurveToDamage` interpola
  `[d, 2d]` según stat/35.
- **Invocadores**: `summonHornets` cuesta 100 de energía, cd 200 ut, 24 ut de
  acción; el nido regenera 0.00025/tick → una invocación real cada ~4000 ut;
  invoca 2-4 hornets o 1 reina (1/6) con 6 ut de retraso.
- **Reloj**: cada acción del jugador da a todos los enemigos su tiempo; los
  enemigos actúan al acumular `availableTime > 0` (pagan después). El primer
  mordisco adyacente se modela en t=0.

### Arquitectura del modelo

- Monte Carlo N=96 por acción, horizonte 600 ut, números aleatorios comunes
  (misma semilla por trial para todas las acciones) → comparación pareada.
- RNG minstd con un único uniforme por golpe invertido contra la CDF exacta de
  Bates(3) (tabla de 512 puntos); sumar 3 salidas consecutivas del LCG
  subestimaba las colas (~4.5% vs 11% teórico).
- Política de referencia del rollout: atacar solo adyacentes (invocador
  primero), cerrar distancia si no hay nadie pegado, mantener embudo si
  `choke`.
- Decisión: menor cota superior de Wilson al 95% de `pDeath`, luego `pDeath`,
  luego vida media, luego coste de recursos, luego duración. Si todas las
  opciones mueren al 100%, gana la que más tarda en morir.
- La acción `flee` simula pasos reales; escapar exige que TODOS los enemigos
  queden a gap>1 y sean más lentos (`allOutrun`).

### Bugs de decisión encontrados en test24 (muerte en 63,42)

1. **Lifestone curando 0**: la opción se creaba con `healAmount=0` a vida llena
   y, al ser la única acción con un enemigo aún lejano, se eligió 5 veces
   (`charges 10→0`) sin curar nada. Arreglado: `Gp > 0` obligatorio y el modelo
   solo decide cuando hay enemigo adyacente (`#adj > 0`); a distancia decide la
   capa de movimiento.
2. **Sin huida al 100% de muerte**: `findFleeCell` exige una celda a distancia
   ≥2 de todo enemigo; en un callejón corto devolvía nil y el bot atacaba con
   `d=100%`. Arreglado: `desperateEscapeCell` ofrece el vecino transitable más
   lejano de todo hostil visible (opción `retreat` de 1 paso), y `doFlee` la usa
   como fallback.

### Resultados headless del modelo

| Test | Resultado | Lectura |
|---|---|---|
| test24 | muerte turno 2837 en 63,42 | Lifestone a 0 PV ×5 y ataque al 100% sin opción de huida |
| test25 | muerte turno 5109 en 54,23 | ya no desperdicia curas; huyó de un lobo hacia el nido de avispas |
| test26 | muerte turno 3231 en 68,44 | sin vecino transitable (callejón); 1v1 real contra silverwolf |

Test25 expuso que `findFleeCell` solo miraba la distancia a enemigos
visibles, no si la huida entraba en territorio sin explorar: el bot arrastró
un lobo durante ~15 turnos hasta el nido. Arreglado con penalización por
vecinos desconocidos (+4 por celda) en el destino de huida, y con una regla
de decisión: la huida solo se ofrece si el veredicto del pack es `avoid`, si
la vida está por debajo del 30 %, o si ya se tiene la llave (desenganche
post-llave). Un lobo adyacente que se puede matar se mata; huir de él a vida
llena es un treadmill que acumula perseguidores.

Test26 murió en un callejón sin salida: el modelo valoró el 1v1 contra un
silverwolf en 60-100 % de muerte (daga inicial, poise 0, sin pociones) y no
había ninguna celda transitable a la que retirarse. La predicción era
correcta; el error fue estratégico (entrar en territorio de lobos sin equipo).
La siguiente línea de trabajo es loot/equipo y progresión, no más parches al
combate básico.

## 2026-10-30 — Beneath the Keep: exploración tras cajas y puertas secretas

### Causa del bloqueo en test33 (archonDungeon-01)

La bóveda de entrada (filas 63-72) solo tiene una salida al norte: una celda
`secretDoor` en 47,62 detrás de una fila de `crateOpen` (48..54,64). Ni
`findFrontier` ni `findRoutableDoor` recorrían cajas/barriles (no son
`isWalkable`, solo rompibles al empujarlos) ni puertas secretas (parecen muro
hasta que se empujan), así que el bot se quedaba en `phase=stuck` con
"no frontier and no key" hasta el timeout. Verificado con el PNG del mapa
decodificado y `archonDungeon-01Triggers.csv`.

### Cambios en `mod/zzbot/init.lua`

- `findFrontier` y `findRoutableDoor` ahora recorren `isPassableForPath`
  (incluye cajas/barriles rompibles y puertas secretas).
- `lockedDoorPlan`: clasifica cada puerta `locked_door` por su trigger:
  - data string → `key:<item>` (bump si se lleva el ítem),
  - data numérico >0 → `plate:<code>` (hay que pisar la placa
    `fnUnlockWithPlate` con ese código),
  - data 0 → `sealed` (solo `key_master` o trigger `unlock`),
  - sin trigger → `pick` (ganzúa; `doorLocked2` nunca es forzable).
  `findRoutableDoor` ignora puertas que ahora mismo no se pueden abrir y
  `tryOpenDoor` usa `pickLock` cuando corresponde.
- `doorObjectiveStep`: si no queda frontera ni puerta abrible, va a la placa
  que corresponde al código o a por la llave (portador visible o contenedor).
- `trySecretDoorSweep`: cuando el juego marca `gotFeelingAboutSecretDoor`
  (hay una puerta secreta adyacente), empuja los muros vecinos (con lista
  negra de lava/fuego/etc. y enfriamiento de 3 s por celda).
- Capturas: `ZZBOT_SHOT_INTERVAL=n` guarda `zzshot-NNN.png` en el directorio
  de guardado; al quedarse atascado guarda `zzshot-stuck.png` una vez.
- Mecánica de placas confirmada en `state_game.lua:13960` (`fnUnlockWithPlate`):
  pisar `plateOff` la convierte en `plateOn` y transforma las puertas con el
  mismo código (`unlockTileData`), borrando sus triggers; después basta
  empujar la puerta ya `doorClosed`.

### Test35/test36 — salir de la cueva con vida

Test35 (sonda del save del usuario, 420 s): el bot tenía la llave maestra y
murió en 68,53 mientras "barría" fronteras restantes con 6 PV, sin pociones,
sin cargas de lifestone y con el poise roto. Arreglo: el barrido posterior a
la llave (`exit-explore`) solo se hace si hay vida > 60 % y alguna fuente de
curación (poción o lifestone); si no, va directo a las escaleras de salida.
Test36 arrancó desde el checkpoint del save del usuario (Overworld 267,223),
entró a Moon-upon-Thoss y siguió a la mazmorra sin errores.

## 2026-10-30 — Dioses: dedicación, lágrimas y compra de Gifts

Mecánica leída del código:

- Pantalla de dioses = `game.skillTree`; comprar un Gift es exactamente
  `game.skillTree:activateCellForGridFactionAtXY(x, y)` (la UI hace lo mismo).
  Los costes viven en la tabla local `skillTileData` de `skill_tree.lua`; el bot
  parsea el fichero instalado (`love.filesystem.read`) para conocerlos y no
  comprar sin devoción.
- `game:devoteToGod(god)` abre un confirmBox; al confirmarlo,
  `actuallyDedicateToGod` activa el boon del dios (p. ej. Death's Harlequin:
  Frolic), cura vida/poise/comida al máximo y maldice a los dioses rivales.
- Las Devotional Tears se ofrecen con `game:startShatteringTear(id)` (abre un
  multiChoiceBox con 5 dioses) y se rematan con `finishShattering(index,...)`;
  `handleDialogs` del bot elige `ZZBOT_GOD`.
- Devoción por dios: `game:getDevotion(god)`; compra un Gift por tick en
  pueblos seguros (`godStep`, solo si no hay enemigos ni otra UI abierta).

Decisión por defecto: `ZZBOT_GOD=deathsHarlequin` porque el bot usa daga y
huye (la restricción de Wolf es huir; la de Dust, pociones; la de Harlequin
solo prohíbe hachas/espadas/mazas y mejora ganzúa/dodge/evasión de trampas).
Pendiente: equipamiento debe respetar el tabú (no equipar espadas/mazas), y
buscar Devotional Tears en mazmorras para comprar más Gifts.

### Estrategia tras test37: la mazmorra 2 es inviable sin Gifts

El modelo de combate da ~100 % de muerte contra dos Nomans (need 3119, res
1050 con daga). El usuario lo confirmó: sin subir atributos/habilidades la
mazmorra 2 es matemáticamente imposible. Mecánica de progresión confirmada en
el código: cada punto de Devoción sube +5 el atributo del dios, y cada Gift
comprado también (+5). Fuentes de Devoción: Devotional Tears (objetos raros de
mazmorra/relic), y Devotional Tasks = logros de `achievements.lua` (2 de
devoción cada uno; p. ej. "visitar la ciudad natal de cada dios", "derrotar 50
enemigos", "sufrir 13 estados alterados"). El bot ya dedica (boon + cura full)
y compra Gifts cuando tiene devoción; falta farmear devoción.
Añadido: descanso en cama de posada en pueblo cuando hp < max antes de entrar
a la mazmorra, y log de money/stats/devoción por beat para medir la debilidad.

## 2026-10-30 — Gira de devoción: logros de ciudad natal y el archipiélago

### Por qué una gira

Cada ciudad natal de un dios concede +2 de devoción al entrar (logro
`visitAllTowns`; `saveCurrentWorldAndChangeWorld` en `state_game.lua` llama a
`processAchievement` y después `game:alterDevotion` al detectar `isHomeTown`).
La devoción se puede gastar en la misma visita porque el aviso solo abre un
alertBox que `handleDialogs` cierra. Con 5 ciudades natales + el logro cómico
"visitar todas las ciudades" la gira produce 12 de devoción antes de la
mazmorra 2, que es exactamente lo que el modelo de combate necesita para que
los Gifts/dedicación decidan la pelea contra los Nomans.

Diseño A (implementado): mientras queden ciudades de dios pendientes, todas
las ciudades son solo de tránsito (se saltan sus mazmorras, incluidas Yarrow y
Moon-upon-Thoss); tras la quinta, la ruta vuelve a `TOWN_ORDER[S.townIndex]`
(Yarrow, índice aún 1) y se hacen las mazmorras en orden de campaña con la
devoción ya gastada en Gifts.

- `TOUR_TOWNS = { Barrow-Linn, Harrowdus, Hearthaven, Wintersholl, The_Red_Grove }`
  (los pueblos natales de homeTown3/2/5/1/4).
- `tourPending(game)` lee `game:getAchievements().done` y devuelve las que
  faltan; `tourRemove()` las descuenta de `S.tourPending` al entrar.
- El `leadsTo` de cada ciudad sigue definiendo su mazmorra para la fase de
  campaña.

### El mundo exterior es un archipiélago

Decodificado `data/save/Overworld.png` (índice de tile = R + G*256, con
`cellTypeArray` 1-based → en Python `cells[i-1]`; 537 tipos, 12 110 celdas
andables) y calculadas componentes conexas 4-dir:

- Componente 23 (7 812 celdas): Yarrow (267,223), Moon-upon-Thoss (248,244),
  Harrowdus (310,311), Hearthaven (251,149), Wintersholl (339,242) y
  The_Red_Grove (176,190).
- Componente 106 (80 celdas): Barrow-Linn (189,287) y su embarcadero
  Barrow-Linn-Ferry (192,292), con 24 y 1 jetty respectivamente.
- Conclusión: existe ruta terrestre entre todas las ciudades menos
  Barrow-Linn, a la que solo se llega en transbordador.

### El transbordador

- `game:attemptToPayFerryman()` abre un multiChoiceBox de una opción ("Sail")
  con `price = economy:getNonObjectActualPrice(G_Globals.ferryCost)`
  (`ferryCost = 150` en Globals). `takeFerry()` cobra 150 salvo cuando el
  destino es Moon-upon-Thoss (viaje de vuelta gratis desde el embarcadero).
- La travesía la resuelve `updateFerryTime` (envolvente `gFerryEnvelope`,
  8.1 s): `zoomOut`, teletransporte al trigger `ferryDestination` del
  Overworld, fundido y checkpoint. Mientras `game.isOnFerry` el juego ignora
  la entrada del jugador, así que `tick` espera.
- Destinos: en Moon-upon-Thoss el transbordador va a Barrow-Linn-Ferry; en
  Barrow-Linn-Ferry vuelve a Moon-upon-Thoss.

Capa nueva en `mod/zzbot/init.lua`:

- `ferryLegStep`: si no hay ruta terrestre al destino, camina hasta el
  embarcadero (192,292) si es alcanzable, o hasta la puerta de
  Moon-upon-Thoss (248,244) cuando el destino es Barrow-Linn; al pisar la
  celda pulsa Return para entrar a la ciudad que tiene el ferry.
- `ferryStep` (rama de pueblo): en Moon-upon-Thoss solo intenta embarcar si
  `S.nextTown == "Barrow-Linn"`; en Barrow-Linn-Ferry siempre que el destino
  no sea Barrow-Linn. Comprueba el precio contra el dinero para no abrir un
  alertBox en bucle y espera a que la posada cure antes de zarpar.
- La rama de tránsito no avanza `S.townIndex` al pasar por Barrow-Linn-Ferry
  (no es ciudad de campaña).

### Test39 — ruta del ferry y muerte en una emboscada

Primer test con la capa del ferry: el bot salió del Zoom inicial, detectó
"no global route ... to 189,287" y "to 192,292", y encaminó al gate de
Moon-upon-Thoss (72 pasos). Pero la ruta se reconstruía en cada tick
("ferry leg ... 72 steps" repetido) porque el índice del path se consumía
aunque el juego descartara la tecla: `tick` corre dentro de `getPlayerInput`
y el juego sale antes de leer el movimiento cuando otro actor está gastando
tiempo (`actorManager:isAnyNonPlayerActorStillSpendingTime`). El bot avanzaba
a duras penas y además se paró a "hold-choke" contra un `overworld_enemy`,
que no es un enemigo sino un marcador que al contacto abre un Zoom con un
grupo entero (lobos + cazador); murió en ese Zoom (bites de 142-172).

Arreglos:

- `pathStepFrom(path, px, py)` deriva el siguiente paso de la posición real
  (no consume índice); la ruta solo se reconstruye si el jugador se sale de
  ella. Aplicado a la ruta global y a la del ferry.
- En el Overworld ya no se llama a `combatStep`: los perseguidores se dejan
  atrás caminando la ruta; pararse a pelear/chokear es lo que provocaba la
  emboscada.

### Test40 — la ruta ya no vibra, pero el bot se metía solo en las emboscadas

Con `pathStepFrom` la ruta del ferry se mantuvo estable (3 logs en vez de
cientos), pero el bot seguía atrapado en el bolsillo de 221,239 (pasillo de
una celda) y moría en Zooms sucesivos (lobos, belarks). Causa real: un
`overworld_enemy` es un actor de 100 PV; al pisarlo el jugador lo mata y
`actions.lua` (muerte del spawner) llama a
`setReadyForZoomInXYWithMonsterGroupSpawnTypeAndDirectionOfAttackAndStatuses`,
que abre el Zoom con todo el grupo. El bot caminaba hacia el marcador que
bloqueaba el pasillo y lo mataba él mismo. Arreglos:

- `actorAtWorldXY` + `walkAroundStep`: en el overworld nunca se pisa una celda
  ocupada; se rodea si hay hueco y, si no, se espera (`travel-blocked`).
- Si la ruta terrestre ya falló para este destino (`overRoute.failTarget`), no
  se usa el paso codicioso `outsideStep` (paseaba hacia la costa de una isla
  inalcanzable): se va directo a la pata del ferry.
- Los fallos de BFS se registran como máximo cada 5 s (`S.pathFailLogT`).

### Test41 — base limpia en Yarrow y el billete del ferry

Baseline nuevo: `work/save-backup/save-075659` (personaje en Yarrow 42,41,
primera mazmorra en curso o recién hecha). El bot salió de Yarrow, cruzó el
overworld, pisó la puerta de Moon-upon-Thoss (248,244), entró y pidió el
transbordador. **El pasaje real es 121 guineas (no 150) y el personaje tiene
100**, así que `takeFerry` no se abrió y el bot rebotó en bucle
Overworld(248,244) → Moon-upon-Thoss → salida → Overworld, porque la rama de
tránsito volvía a salir de la ciudad.

Arreglo: `ferryFare()` y guarda `ferry-poor` — con `S.nextTown ==
"Barrow-Linn"` y sin dinero para el billete, el bot se queda dentro de
Moon-upon-Thoss (los Gifts y la posada siguen corriendo) en vez de rebotar.

Pendiente inmediato: **economía para costear el billete**. Hay loot de la
primera mazmorra y tiendas (`CEconomy`), pero vender objetos aún no está
implementado (tarea #9/#10). Alternativa: cargar un baseline con más dinero
(el save del usuario en 221,239 lo tiene, pero está en un bolsillo con
perseguidores).

### Test42 — venta de loot y el "Close" que se comía el ferry

Primera pasada de la capa de economía (`sellStep`/`sellSessionStep`). El bot
eligió al tendero más rico con actor presente (Ozara, `items`, fondos 5499),
se le acercó, abrió el panel de venta y liquidó lo que no usa:
`1x potion_oil` (182), `2x kindling` (16), `2x apple` (6); **5 objetos, 204
guineas, dinero 100 → 304**. La política protege equipo puesto/mejor por
ranura, reservas de consumibles, llaves/encargos y no vende si la demanda
local es < 0.95 con la reserva cubierta (`ZZBOT_MONEY_RESERVE=150`,
`ZZBOT_SELL_HOLD=0.95`).

Dos bugs de la ruta del ferry salieron a la luz:

- `CMultiChoiceBox:setActive(..., include_default_close=true)` añade "Close" y
  deja el cursor en ella, así que el Return del bot solo cerraba la caja y el
  ferry nunca zarpaba ("boarding ..." en bucle). `handleDialogs` ahora mueve el
  cursor a la primera opción real antes de pulsar Return.
- `ferryLegStep` devuelve `true` (booleano) al pulsar Return en la puerta;
  `overworldTravelStep` lo trataba como `dx` y reventaba con
  "attempt to perform arithmetic on local 'dx' (a boolean value)".

Baseline: `work/save-backup/save-test42-econ-before` (Moon-upon-Thoss, 100
guineas, loot de la primera mazmorra en el inventario).

### Test43 — la venta paga el pasaje; primera devoción; muerte en Zoom

Con los dos arreglos, `logs/econ2.log`:

- Venta a Ozara 5 objetos → 304 guineas (dinero 100).
- `ferry: boarding at Moon-upon-Thoss for Barrow-Linn` → desembarco en la isla
  (192,292), entrada en Barrow-Linn y **+2 devoción** (`homeTown3`, lordsOfDust;
  quedan 4 ciudades-dios).
- Vuelta gratis desde `Barrow-Linn-Ferry` a Moon-upon-Thoss (248,244).
- Camino de Harrowdus: un marcador `Zoom` en 48,48 abre emboscada y el bot cae
  en 48,50 (400/400 → 0, turno 1790). No es un fallo de economía: es la
  fragilidad conocida ante Zooms (tarea #12).

Queda pendiente explotar la demanda al revés: comprar barato donde el offset
está en el suelo (0.7×) y vender caro donde está arriba (1.5×0.65 ≈ 0.975×).

### Test44 — arbitraje de demanda: datos reales y bug del peso 0

Con `ZZBOT_TRADE_DEBUG=1` el bot volcó en cada ciudad los mejores spreads de
su stock. Datos clave (seed del baseline):

- Moon-upon-Thoss: `potion_water` compra 78 → Barrow-Linn vende 94 (1.21×),
  stock 5; `rosetta` 788 → 969 (1.23×); `hull_patch` 161 → 189 (1.17×).
- Barrow-Linn: `minor_construct` 1400 → Hearthaven 1880 (1.34×);
  `broken_minor_construct` 157 → Harrowdus 195 (1.24×).
- Harrowdus: `throwing_daggers` 7 → Barrow-Linn 9 (1.29×, stock 20);
  `arrow` 7 → The_Red_Grove 9; `silverwolf_hide` 157 → 188 (1.20×).

La primera pasada no compró nada porque el filtro de peso exigía `w > 0` y
**la mitad del stock útil es ingrávido** (pociones, varas, bayas: weight 0).
Arreglos:

- Peso 0 = "cabe siempre"; la puntuación pasa a beneficio total esperado
  (`(venta-compra) × cantidad`), más el tope de carga al 85%.
- Presupuesto: 80% del dinero por encima de la reserva (antes 50%, mínimo 20).
  En Moon-upon-Thoss con 304 guineas el presupuesto es 107.
- La reserva incluye el billete del ferry mientras el destino sea Barrow-Linn
  (`tradeReserve`), para no quedarse varado tras comprar.
- `TRADE_SKIP`: nunca comprar para revender pociones de curación (el combate
  se las bebe) ni el camp kit / vara de curación (nunca se venden).
- Tope por sesión: el gasto no supera el presupuesto restante aunque se
  compren hasta 4 tipos distintos del mismo tendero.

### Test45 — ida y vuelta completa: 78 → 93

`logs/trade2.log`:

- Venta del loot a Ozara: 100 → 304 guineas.
- Compra de 1× `potion_water` a 78 en Moon-upon-Thoss (dinero 226; la reserva
  mantiene el billete de 150).
- Ferry a Barrow-Linn (dinero 76), venta de la poción a Illith por **93**
  (+19%, etiqueta cerrada: "trade: potion_water sold out").
- Vuelta gratis, camino a Harrowdus. En dos Zooms el bot sobrevivió y rescató
  a un mercader: **+573 guineas** (recompensa `money_medium` por ayudar en la
  batalla), dinero 742.
- En Harrowdus compró 10× `throwing_daggers` (7 → Barrow-Linn 9) y 10×
  `arrow` (7 → The_Red_Grove 9): 20 objetos por 140, ambos ingrávidos.
- Murió en otro Zoom camino de Hearthaven (58,51) antes de revender las dagas.

Conclusión: el bucle compra-barato/vende-caro funciona y los beneficios son
reales pero modestos con poco capital (el margen máximo teórico es
1.5×0.65/0.7 = 1.39×). La fuente grande de dinero a corto plazo son el loot
de mazmorra y las recompensas por rescatar mercaderes; el arbitraje escala
cuando haya más guineas. La asignatura pendiente sigue siendo sobrevivir a
los Zooms.

### Test46 — oro → devoción: comprar descubrimientos y Gifts baratos

No existe donar dinero por devoción: el logro `blindAngels.donate` está
comentado en `achievements.lua:56` y los cofres de donación solo suben
reputación (precios ±20%). El camino real oro → poder:

- `addObjectToInventory` (actor.lua:6811-6820) llama `processAchievement` con
  el nombre del objeto para pociones, ungüentos y varas, así que **comprar**
  un tipo desconocido cuenta para `discoverAllPotions` (15 tipos, +2 para la
  Lady) y `discoverAllWands` (12 tipos, +2 para los Lords of Dust).
- Las tiendas de las 5 ciudades venden exactamente **15 tipos** de
  poción/ungüento entre todas (agua, curación, energía, antídotos, venenos...),
  es decir, el primer logro se completa solo comprando. De varas solo hay 3
  tipos en stock (750–1100); los otros 9 salen del loot de mazmorra.
- Cada Gift da siempre +5 al atributo de su dios, así que comprar primero los
  de coste 1 (berserk/luck/puppet/revelation/gash/life_sight) maximiza la
  fuerza por punto de devoción. `buyGiftStep` ahora ordena por coste.

Implementación: `discoveryStep` compra una unidad de cada tipo desconocido
(reserva intacta para el ferry; prioriza pociones sobre varas) y `buyGiftStep`
elige el Gift alcanzable más barato. Diagnóstico de alerts añadido
(`alert:` con texto/fracción/delay).

Pruebas:

- `logs/discovery1.log`: venta 100→304; compra `potion_water` 78 (potions
  2/15); ferry 150; Barrow-Linn +2 → `revelation` (coste 1); Harrowdus +2 →
  `luck` + `puppet` (1+1). Un alert quedó abierto en la entrada de Harrowdus
  (no reproducido después; el diagnóstico lo vigila).
- `logs/discovery2.log`: Harrowdus/Hearthaven ya visitadas, +2 → `life_sight`
  (coste 1); muere en Zoom 47,49 contra moonbear + 2 moonmoths + moonmage
  (400→0 en ~2 s). Sigue siendo la debilidad #12, no la economía.

Pendiente para el plan de farmeo: barrido de loot (#9, también necesario para
las 9 varas que no se venden), equipo/inventario (#10), poderes divinos en
combate (#11) y supervivencia en Zooms (#12).

### Test47 — P0 del plan: eventos EV|, watchdog de diálogos, guardia de confirmaciones y arnés de regresión

Primer incremento del `PLAN.md` (fase P0), sin cambiar el objetivo de campaña:

- **Log de eventos** `EV|t=…|kind=…|k=v…` en el mismo `ZZBOT_LOG` (el log
  humano no cambia). Instrumentados `level_enter` (con `from`), `dungeon_done`,
  `campaign_done`, `death` (con últimos mensajes), `timeout`, `stuck`
  (dungeon/no-progress/force-close), `alert_stuck`, `bot` (continue/fresh,
  toggle), `confirm` (clase + decisión) y `confirm_unknown`.
- **Watchdog de diálogos** (`tick`, antes de `handleDialogs`): escalda
  Return → espacio → Escape → cierre por API a los 6/10/14/18 s de un mismo
  diálogo. Clave: el temporizador **sobrevive 2 s a que la caja se cierre y se
  reabra con la misma firma**, porque el bucle de grievance consistía en
  cerrar el alert y reabrirse en el mismo tick (la firma cambiaba y el
  watchdog anterior nunca disparaba).
- **Guardia de confirmaciones por texto**: antes se aceptaba todo
  (`confirmBox.confirm = true`), incluido `Do you want to steal?`. Ahora se
  clasifica el `bodyText`: robo/apostasía/título/salir del juego/borrar/salto
  al vacío/sacrificio/donación/desechar/reparar se declinan; `Leave this
  area?` (zoom) y dedicación se aceptan; las entradas a mazmorra (reliquia,
  mini, endless, tether, doom, arena) solo se aceptan si la campaña ha traído
  al bot aquí (`phase=to-dungeon` o `entered`) y lo desconocido se declina con
  `confirm_unknown`.
- **Grievances**: al recorrer la ciudad el bot embestía aldeanos y quedaba
  atrapado: dormir y `Leave this area?` fallan mientras haya una grievance
  (`state_game.lua:11620`) y la puerta solo produce el alert. `grievanceStep`
  paga la deuda con el diálogo propio del juego (`openPayGrievance`) antes de
  gastar en otra cosa; sin dinero emite `stuck source=grievance-poor`.
- **Arnés**: `tools/check_log.lua` (aserciones `kind[@campo=valor][>=N]`,
  `!kind` prohíbe), `tools/regress.sh` (escenarios `tools/scenarios/*.conf`
  con baseline, timeout y aserciones; cada uno usa su propio
  `work/xdg-regress/<nombre>`) y `tools/milestone.sh`.

Pruebas:

- `tools/regress.sh smoke` (save-test43-loop, Overworld 248,244): antes el bot
  se congelaba 60 s contra el alert de grievance de Barrow-Linn; ahora paga
  `grievance: paying 20G to villager`, acepta `Leave this area?`, avanza la
  ruta a Harrowdus y muere en la emboscada Zoom de Barrow-Linn-Ferry (35 s,
  debilidad P5, no regresión). Aserciones: `level_enter` (10), `!alert_stuck`,
  `bot@state=continue` → PASS.
- `tools/regress.sh yarrow` (save-075659): gira Yarrow → Barrow-Linn →
  Harrowdus → Hearthaven, sin `alert_stuck` ni `confirm_unknown`; muere en el
  tercer Zoom (bats, hp 400→0 con el modelo actual). Aserciones PASS.
- Los dos escenarios mueren por la debilidad conocida de Zoom: sirven para
  instrumentación, no como prueba de supervivencia.

Pendiente inmediato (P1): ledger por nivel y barrido completo de loot, evitando
de paso pisar actores no hostiles en ciudad (causa de las grievances).

### Test48 — P1: ledger por nivel, barrido completo de loot y ruta estricta por towns

Segundo incremento del `PLAN.md` (fase P1), sobre el arnés de Test47:

- **Ledger por mundo** (`Loot.rec(world)`): `known`, `knownCount`,
  `containers`, `visited`, `done`, `fp` (huella walkable/contenedores/fnUp/
  fnDown). Antes `S.known` se borraba en cada cambio de mundo, así que volver a
  un nivel lo re-exploraba; y la huella detecta niveles regenerados (muerte o
  reset) y emite `level_reset`, limpiando el registro viejo.
- **Barrido de contenedores** `Loot.sweepStep`: escanea el mapa cada ~1 s,
  registra `container_seen` y abre uno a uno los contenedores alcanzables
  (arcas, barriles, cajas, ollas, estanterías). Un contenedor bloqueado sin
  `chest_key`/`key_master`/ganzúa se anota `container_skip reason=locked_*`
  sin bloquear el nivel; `noPath` sostenido lo anota `unreachable`. Se eliminó
  el gate de HP>60 %, así que el barrido corre siempre, también herido.
- **Fin de nivel** `level_done` solo después de contenedores + frontera +
  puertas secretas + puertas + objetivos. El descenso ya no ocurre antes.
- **Escaleras por trigger** `Loot.stairsStep(action, phase)` con `fnDown`/
  `fnUp`; con la Master Key baja a cualquier nivel inferior cuyo registro no
  esté `done` y luego sube nivel a nivel hasta salir por `fnUp`.
- **Caza del key carrier** `Loot.huntStep` en el fondo sin llave: persigue al
  enemigo matable más cercano aunque no esté a la vista.
- **Ruta de campaña estricta** (bug observado en Test47): `tourActive` era
  verdadero en *cualquier* town mientras quedara algún god town pendiente, y
  bloqueaba `delve`, así que Yarrow nunca entraba a su mazmorra y la ruta
  saltaba directo a Barrow-Linn → Harrowdus. Ahora el orden es siempre
  `TOWN_ORDER`: la mazmorra del town actual (`leadsTo`) se limpia antes de
  salir; la lista de god towns solo registra visitas (+2 devotion) y no
  reordena la campaña ni retrasa mazmorras.
- **Escenario `dungeon`** (`save-dungeon-start`): derivado de `save-075659`
  reescribiendo `game.sav` (bitser) y `checkpoint.txt` al `playerStart` de
  `firstDungeon-01` (41,68). Resultado: abre 15 contenedores
  (`container_open`), 20 vistos, 1 anotado, sin muerte ni stuck, sin
  `confirm_unknown`; timeout a los 240 s aún en combate/barrido. PASS.
- **Escenarios de arranque limpio**: `newgame.conf` usa un directorio de save
  vacío (`save-empty`): el bot arranca partida nueva desde el título
  (`bot@state=fresh`) y debe entrar a la mazmorra de Yarrow antes de pisar el
  overworld.

Pendiente inmediato: verificar `newgame`/`yarrow` con la ruta estricta; si la
partida nueva muere en la cueva, la debilidad es de combate (P5), pero el
evento `dungeon_done` debe verse cuando la limpieza termine.

### Test49 — Fugas de la cadena del cofre de salida

La partida nueva (`newgame`) entró a `firstDungeon-01` desde Yarrow, mató al
silverwolf, tomó la `chest_key` y abrió el cofre de salida (Master Key). Pero
la cadena del cofre seguía apuntando a él después de abrirlo: `approachCell`
devuelve true aunque el bump no haga nada, así que el bot se quedó 400 s
embistiendo un cofre ya saqueado y **nunca ejecutó `Loot.sweepStep`** (cero
eventos `container_seen`). Arreglos:

- La cadena del cofre de salida solo corre si **no** se tiene `key_master`.
- Solo se apunta al cofre si su celda sigue siendo `chestLocked`/`chestClosed`
  (`chestWorkable`); un cofre abierto/saqueado deja paso al barrido normal.
- `dungeon_blocked reason=chest_key_missing`: cuando el cofre está bloqueado y
  no existe ni portador ni contenedor con `chest_key` (save ya gastado), se
  emite una vez en vez de girar hasta el timeout. El save sintético
  `save-dungeon-start` está exactamente en ese estado (silverwolf muerto,
  llave consumida), y ahora `dungeon.conf` lo verifica.

Pendiente: repetir `newgame` y comprobar que tras la Master Key el barrido
corre, el nivel se marca `done` y el bot sale por `fnUp` a Yarrow
(`dungeon_done`) para seguir la ruta a Moon-upon-Thoss.

### Test50 — Post-key contra el botín completo; enemigos inalcanzables

La repetición de `newgame` con la cadena del cofre arreglada confirmó el flujo
completo de la primera mazmorra: Yarrow (llaves del pueblo, puerta, compras),
entrada a `firstDungeon-01` (t=54 s), `chest_key` del silverwolf (t=74 s),
cofre de salida abierto y **Master Key en t=104 s**. Pero el bot murió en
t=283 s con el nivel a medio barrer (11/16 contenedores), y el registro
muestra dos causas concretas:

- **La política "post-key" se activaba con la `chest_key`**, no con la Master
  Key ni con el nivel terminado. Desde t=74 s el bot huía de todo combate
  (`fleeing ... (post-key)`) en vez de pelear; de espaldas recibió los
  mordiscos del silverwolf (n=8), gastó las 10 cargas del Lifestone y las 2
  pociones mayores *antes* de tener la Master Key, y llegó al barrido sin
  recursos. `tryHeal` además subía a 300 HP entre peleas, otro drenaje.
  Con la regla de botín completo la política era contradictoria: después de
  la llave aún quedaba medio nivel por saquear.
- **Ping-pong contra un enemigo inalcanzable**: un `archaea` (monstruo de
  agua) a distancia 3-6 absorbía el `combatStep` cada tick; el bot se acercaba
  hasta donde el pathing llegaba, fallaba, el barrido lo devolvía y repetía
  durante 50 s junto a contenedores sin abrir. El modelo además cargaba su dps
  al riesgo del paquete aunque nunca podría morder.

Arreglos:

- `S.exitReady` = Master Key **y** `lvl.done` (nivel barrido). Solo entonces
  aplican el tope a 300 HP, el gasto sin reserva de Lifestone, el descuento de
  recursos del modelo y la preferencia por desengancharse. Durante el barrido
  el bot pelea normalmente y conserva una carga de reserva.
- Se eliminó el `doFlee` forzado "post-key" con enemigos adyacentes: huir de
  algo que ya está en rango cuerpo a cuerpo regala golpes. El modelo sigue
  ofreciendo huida cuando es realmente más segura.
- `S.unreachable[actor.ID]`: tras un fallo de navegación hacia un enemigo se
  ignora 30 s (los adyacentes nunca se ignoran). Se limpia al cambiar de
  mundo y al completar la mazmorra. Esto corta el ping-pong con `archaea`,
  black slimes y cualquier criatura tras un foso/puerta sellada.
- `dungeon.conf` exige ahora `level_done@world=firstDungeon-01` (barrido
  completo del save bloqueado); `newgame.conf` exige `level_done`,
  `dungeon_done@dungeon=firstDungeon-01`, regreso a Yarrow
  (`level_enter@from=firstDungeon-01`) y `!death`.

En curso: `tools/regress.sh dungeon newgame` con TIMEOUT 300/900.

### Test49 — branch `glm`: módulos confirm/ending_gate/metrics y puerta de final (P0, lotes 1-2)

Tercer incremento del `PLAN.md` (completa los lotes 1-2 del module split §0.2
y resuelve el conflicto #3), sobre el arnés de Test47/48. Cada extracción se
hizo sin cambiar el comportamiento y con tests puros que corren sin el juego
(`tools/unit.sh`, luajit o lua):

- **`mod/zzbot/confirm.lua`**: el clasificador de confirmaciones y su política
  salen de `init.lua` como funciones puras (`classify(text)`,
  `decide(class, ctx)` con `ctx = {phase, entered}`). `init.lua` conserva una
  copia inline literal como fallback si el módulo no carga (mismo patrón de
  degradación que `zzbot.model`). `tools/test_confirm.lua`: robo→theft,
  prefijos `dungeon_*`, clases irreversibles siempre declinadas, entrada solo
  con `phase=to-dungeon`/`entered`, desconocido declina en cualquier contexto.
- **Normalización de espacios en el clasificador**: el `bodyText` del juego
  puede partir la frase en varias líneas; colapsando `%s+` a un espacio el
  matching por substring ya no pierde clases por reflow. Solo promueve
  `unknown → clasificado`; la política de aceptación no cambia y el
  desconocido sigue declinándose.
- **`mod/zzbot/ending_gate.lua`** (conflicto #3 del plan / riesgo #6): hablar
  con el Archonte con solo las reliquias dispara el final malo, así que la
  puerta bloquea cualquier avance de speech en mundos `archon*`/`endgame*`
  hasta que el Tether esté muerto. Señales aceptadas (OR): propiedad
  `killed_tether` del juego (leída con pcall), flag `killedGods`, o el
  registro propio `S.dungeonDone["dungeon6-06"]`; si la propiedad no es
  legible la puerta permanece cerrada. `handleDialogs` no pulsa Return, emite
  `EV|kind=archon_gate` una vez por texto y pulsa Escape. **El watchdog
  también cede ante la puerta**: su escalera Return→Espacio→Escape ya no
  pulsa Return/Espacio sobre speech bloqueado (si no, a los 6 s el propio
  watchdog habría anulado la puerta); el cierre forzoso por API del stage 4
  sigue disponible porque descarta sin avanzar el diálogo.
  `tools/test_ending_gate.lua`: pueblos/mazmorras normales nunca bloqueados,
  archon/endgame bloqueados antes del Tether, las tres señales lo levantan.
- **`mod/zzbot/metrics.lua`** (§0.3): `log`/`ev` salen de `init.lua` con reloj
  inyectable (`Metrics.init{logpath, t0, clock}`), así que el formato `EV|`
  sobre el que afirma `check_log.lua` queda cubierto por
  `tools/test_metrics.lua`: orden de claves estable, saneado de valores,
  prefijo `[zzbot] `, escritura y timestamp en fichero, reapertura al cambiar
  `logpath`. Fallback inline literal en `init.lua`.
- **`tools/unit.sh`**: corre todos los `tools/test_*.lua` con luajit (o lua
  de sistema) sin abrir el juego; los 4 ficheros (confirm, ending_gate,
  metrics, model) pasan. Los escenarios headless de `regress.sh` siguen sin
  ejecutarse aquí (necesitan el AppImage extraído en `work/`), así que la
  puerta y los módulos deben revalidarse con `tools/regress.sh smoke yarrow`
  y `dungeon` en cuanto haya entorno de juego.

Pendiente (próximos lotes del split §0.2): `nav.lua`, `interact.lua`,
`ledger.lua`, `gear.lua` (P2), `dialogue.lua` (P3).

### Test50 — P2: puntuación de equipo, plan de equipado y escalera de burden (`zzbot.gear`)

Cuarta fase del plan (§3.2 y §3.9). La lógica es pura y testada; el cableado
queda detrás de dos flags hasta verificar en headless (§8.6/§8.10 siguen
abiertos: columnas exactas de objectData y nombres de objetos de lámpara):

- **`mod/zzbot/gear.lua`** (18 tests): melé = daño por unidad de tiempo con la
  curva de might del modelo (`1 + min(1, might/35)`); ranged exige munición;
  armadura = defensa por burden; escudo = bloqueo por mano suelta.
  `planEquip` nunca baja de nivel, exige `minGain` (15 % por defecto para
  frenar churn y apuestas sin identificar), ignora candidatos sin score y el
  veto `allowed()` EXCLUYE del plan (gancho para la guardia de tabú de P4).
  `dropLadder` ordena por valor/peso ascendente entre los no protegidos con
  épsilon 1e-9 contra el residuo float de (0.9-0.7)*100. `lampPlan` solo
  quema ámbar donde `allowAmber`, mantiene reserva 2 y pide suministro antes
  de quedarse a oscuras.
- **Cableado** (`init.lua`): `equipStep` (una pieza por tick, solo con
  seguridad: sin hostiles en Chebyshev ≤ 4) se inserta en la cadena de
  ciudad antes de `sellStep`, así la protección de venta ve el build final;
  equipa vía el mismo `useItemWithInventoryIndex` de la curación y emite
  `EV|kind=equip`. `lampStep` enciende antes de descender y apaga en
  superficie vía `toggleInventoryID` con `EV|kind=amber_state`; la compra de
  combustible queda como aviso (`state=need_fuel`) hasta verificar nombres de
  objetos. Detrás de `ZZBOT_GEAR=1` / `ZZBOT_LAMP=1` (default off).
- Los tests pescaron dos bugs de diseño antes del commit: el veto no excluía
  al candidato del plan y el épsilon float soltaba un drop extra.

### Test51 — P3: driver de diálogo (`zzbot.dialogue`)

Quinta fase del plan (§3.3). Módulo puro con 12 tests + cableado tras
`ZZBOT_DIALOGUE=1` (default off; los nombres de campos de speechArea son la
pregunta abierta §8.5):

- **`mod/zzbot/dialogue.lua`**: máquina de estados sobre speechArea. Texto
  plano avanza; las choices se agotan de una en una (la primera sin usar, en
  el orden de la caja; "Close/Leave/Bye" nunca son keywords); los prompts de
  texto teclean una lista ordenada de keywords y caen en "bye"; los yes/no
  siguen una tabla de política cuyo default es DECLINAR. Cap de 200 pasos por
  npc/visita y agotamiento → `dialogue_stuck` / `dialogue_exhausted` +
  Escape. El driver es dueño del set de vistos: cada pick se marca dentro de
  `step`, así un caller despistado no puede entrar en bucle (un test pescó
  este contrato).
- **Cableado**: `dialogueStep` sondea `choiceArray/choices/keywordArray` y
  `inputMode/typedInput` con pcall — si la caja no encaja, cae al
  press-Return de siempre. La cola de tecleo (`S.typingQueue`) inyecta un
  carácter por tick por los mismos diccionarios que las flechas, y corre en
  el tick antes de `handleDialogs`. Keywords de campaña precargadas:
  `Death_Has_Dominion_Over_All` (frase del Jest, §4.1); `DIALOGUE_YESNO`
  vacío hasta verificar las claves de prompt.
- El gate del Archonte (Test49) se evalúa ANTES del driver, así que la
  exhaustión de diálogo nunca alcanza al final malo.

### Test52 — P4: perfiles de dioses, guardia de tabú y catálogo de poderes

Sexta fase del plan (§3.4). Tres módulos puros (32 tests) + cableado mínimo:

- **`mod/zzbot/gods.lua`**: un perfil por dios SOLO con lo que el plan afirma;
  lo no verificado (celdas de skill, prioridades de stats, valores de pecado)
  queda fuera (§8.7/§8.9). Tabúes: Harlequin `heavyWeapon` (armas fuera de
  pin/dagger/rapier), Dust `healPotions` (solo `potion_water`), Angels
  `injustice`, Wolf `flee`, Lady `nonBloodFood`. Dios desconocido = perfil
  vacío = nada prohibido.
- **`mod/zzbot/taboo.lua`**: `check(profile, kind, payload)` con cinco
  chokepoints (equip/heal/attack/flee/food). La regla heal distingue pociones
  de otras curaciones: el Lifestone y el descanso son lícitos para el Dust
  (un test pescó la sobreprohibición). Arma de clase desconocida no se puede
  juzgar y se permite — el pecado viene del USO, no del equipar; el veto de
  equip es la mitad preventiva.
- **`mod/zzbot/powers.lua`**: `shouldFire` con gates auditables por tag
  (damage≥1 enemigo, aoe≥3, heal si missingHP≥100, buff una vez y con
  combate, escape solo si el veredicto dice que huir falla) y tres solvers:
  `bestTarget` (nearest/danger, nunca muta los registros), `bestDirection`
  (8 direcciones, aliado = -100), `bestLocation` (radio/distancia, nunca
  cubre al aliado). `descriptor()` traduce entradas de CActions.
- **Cableado**: el gancho `allowed()` de `equipStep` ahora aplica el tabú del
  dios activo (`EV|kind=taboo_block`); `doFlee` emite `EV|kind=sin` de
  observabilidad para el Wolf (la doctrina que sustituye la huida no existe
  aún, así que NO se bloquea — bloquear sin doctrina es una espiral de
  muerte); y `ZZBOT_POWERS=1` lanza una sonda one-shot del catálogo
  `CActions.static.data` que registra energía/targeting/radio de cada poder
  para autorar los tags contra datos reales (§8.7). Nunca enlaza teclas ni
  dispara nada.

### Test53 — P5: modelo de combate v2 (ranged, poderes AOE, readiness de Zoom)

Séptima fase del plan (§3.5/§3.6). El simulador gana dos tipos de acción y
la comprobación de preparación; 16 tests nuevos y los 16 del model original
siguen en verde (sin regresión en el reloj de veneno/poise/summons):

- **`shoot`** (ranged): alcanza al enemigo vivo más cercano dentro de
  `action.range` (las flechas vuelan sobre el embudo de choke), falla fuera
  de rango pero cuesta su tiempo. El gating de munición es del caller.
- **`power`**: daño single-target o barrido AOE sobre todo enemigo vivo dentro
  de `radius`, o curación propia; energía/cooldown se gatean en el caller
  (zzbot.powers.shouldFire). Los tests cubren: aoe limpia un pack de 3,
  respeta el radio, heal power repone HP sin mordiscos, y `M.rank` prefiere
  el power que arrasa el pack sobre un golpe simple.
- **`M.readiness`** (§3.6): hp al completo, ≥1 curación a bordo y poise ≥50 %;
  devuelve reasons[] para el log. Cableado como observabilidad en la rama de
  ferry (`EV|kind=zoom_ready|zoom_not_ready`): los datos primero, la política
  (poderes + kiting con energía) cuando la ejecución de disparos esté
  verificada (§8: semántica de disparo y bindings de skill_tree).
- La ejecución de `shoot`/`power` en buildCombatOptions queda deliberadamente
  fuera hasta verificar cómo dispara el juego (bump vs tecla de fuego);
  ofrecer opciones no ejecutables rompería el chooser.

### Test54 — P6: grafo de campaña y planner (`zzbot.campaign` + `campaign_data`)

Octava fase del plan (§4). El planner es puro y testado (11 tests); el
cableado es observación, no cambio de ruta:

- **`mod/zzbot/campaign_data.lua`**: los 8 objetivos del orden §4.3 (Jest →
  Garden → Repository → Necropolis → Tower → Lament → Tether → Archon) con
  `requires`/`done` como descriptores de predicado. Solo los datos que el
  plan afirma: `dungeon2-01` (Jest, reliquia *inferida*), `dungeon6-06`
  (Tether), 5 reliquias para Lament/Tether; Garden..Tower van con props
  marcadas *unverified* para corregir contra el juego sin tocar código.
- **`mod/zzbot/campaign.lua`**: ready set (no done + requires + no blocked +
  puerta del final), pick por orden con **readiness gate** (fuerza del build
  vs difficulty del objetivo → pide preparar, no suicidarse), fallos
  consecutivos → `blocked` tras N=3 sin atascar el resto, y el Archon es
  implanable sin `killedGods` (defensa en profundidad sobre la ending gate de
  Test49). Sin evaluador el planner **falla cerrado**: no puede verificar sus
  done() → no planifica nada (un test pescó que antes dejaba pasar los
  objetivos sin requires).
- **Cableado** (`ZZBOT_CAMPAIGN=1`): en cada cambio de mundo el planner
  registra `EV|kind=objective` con el objetivo que elegiría, usando
  `isPropertyNonZero` (con pcall) como evaluador de props. La ruta estricta
  TOWN_ORDER sigue mandando hasta validar predicados en headless; entonces
  el switch de ruta es el siguiente paso.

### Test55 — P7: planificador de patas de viaje y spike del mar (`zzbot.travel`)

Novena y última fase planificada (§4.2.3 + §3.10). El plan manda spike antes
que código para el mar, así que P7 entrega el planificador puro de patas y
las preguntas del spike como datos:

- **`mod/zzbot/travel.lua`**: un GoTo se resuelve en patas ordenadas
  (`town_exit → ferry|overworld|sea → town_enter → dungeon_entry`). El único
  cruce verificado (Moon-upon-Thoss ↔ Barrow-Linn) es `FERRY_ROUTES`; un
  objetivo `needsShip` planea una pata `sea` con `blocked="no ship"` en vez
  de fingir, y `M.blocked` la devuelve sin atascar el resto. `M.SEA_SPIKE`
  lista las cinco preguntas que el spike debe responder (deed, claim,
  isSailing, cañones, si la Tower necesita barco).
- 8 tests. Los ejecutores reales siguen siendo `overRoute`/`ferryLegStep` en
  `init.lua` (verificados en Test48); el planificador decide, no camina.
- **Fin de partida**: ya cubierto por `campaign_data` (tether → archon con
  `requires={relics=5}` / `killedGods`), la refusal del planner (Test54) y la
  ending gate del watchdog/handleDialogs (Test49). Tres capas sobre el final
  malo.

### Test56 — P8: aprender de las muertes (`zzbot.knowledge`, banda ZZBOT_LEARN)

Nueva fase, fuera del PLAN original: el usuario pidió que el bot aprendiera de
sus muertes y ajustara pesos por enemigo, sin sustituir la estrategia actual
sino ofreciendo alternativas que se puedan probar. Se descartó RL profundo y
redes (datos escasos, LÖVE sin autodiff, PC modesto) y se aterrizó en un
**bandit de conteos Beta por (tipo de enemigo, banda de nivel)** que alimenta
al modelo Monte Carlo que ya teníamos:

- **`mod/zzbot/knowledge.lua`** (puro, sin LÖVE): ledger `enemigo@nivel →
  {a=muertes, b=encuentros sobrevividos}`; `threatMult` devuelve `1.0` sin
  opinión (menos de `MIN_AB=5` observaciones) y en caso contrario
  `1 + K·(p − p0)` con `p0=0.05` y clamp `[0.5, 4.0]` — una mala racha nunca
  puede lanzar al bot por un acantilado. Atribución del asesino por texto:
  `noteText` reconoce "The X hits you for N" (con lista negra de verbos de
  curación) y "You kill the X"/"The X dies"; `parseKiller` escanea lo más
  nuevo primero. Persistencia como fuente Lua junto al log de métricas,
  escritura atómica (tmp+rename), carga estricta: una entrada corrupta
  rechaza el fichero entero en vez de envenenar a medias.
- **Cableado en `init.lua`, todo tras `ZZBOT_LEARN=1`**: `enemyWeight`
  multiplica SOLO el daño entrante del hostil (`hit/maxHit/modelHit/
  modelMaxHit` y derivados `dps/cost`) por el multiplicador aprendido; el
  daño nuestro no se toca. El hook de `addText` atribuye golpes en vivo
  (`S.lastHitBy`, ventana de 120 s) y acredita kills como encuentros
  sobrevividos; en la muerte se registra `by=` en el evento `death`.
  Sin `ZZBOT_LEARN` el bot no lee ni escribe nada: multiplicador 1.0
  garantizado.
- **Corrección obligatoria descubierta en el camino**: el chunk principal de
  `init.lua` llevaba **más de 200 locals desde P6/P7** — el fichero no
  compilaba bajo los límites reales de Lua 5.1/LuaJIT (la sucesión de
  verificaciones anteriores no lo detectó). Fix mecánico: 26 tablas de datos
  estáticas (`DIRS`, `CC`, `TOWN_ORDER`, `WD`, `SELL_RESERVE`…) empaquetadas
  en una única tabla `DATA`; compila en Lua 5.1 y 5.5, 12/12 archivos de
  test en verde en ambos.
- 18 tests en `tools/test_knowledge.lua`: normalización, buckets de nivel
  (1-2/3-4/5-9/10-14/15+), parsing con lista negra de curación, guard de
  `MIN_AB`, clamps, independencia de buckets, matching por subcadena entre
  nombres de mensaje e ids de actor, round-trip de persistencia, fichero
  corrupto, operación sin path.
- Pendiente (siguiente lote): extracción de genome (alpha, horizonte, etc.)
  y `tools/evolve.lua` — búsqueda evolutiva offline sobre los knobs de CFG,
  con la muerte/éxito como recompensa verificable. Ese es el segundo nivel
  del sistema de aprendizaje acordado.

### Test57 — P8b: búsqueda evolutiva offline (`tools/evolve.lua`)

Segundo nivel del aprendizaje: el genoma son los knobs con ruta de env
(`alpha`, `horizon`, `moneyReserve`, `sellHold`, `tradeMargin`, `tradeTake`)
y la recompensa es verificable desde los logs `EV|` que ya existían
(`campaign_done` +200, `dungeon_done` +50, `level_done` +10, `objective` +3,
`death` −30, `timeout` −15). Nunca lanza el juego: es un driver que el
operador alimenta (`next` imprime la línea de env de un individuo; `record`
puntúa la corrida en el log; al completarse la población evoluciona solo).

- **GA**: élite de 2 copiada verbatim, resto por torneo(3) + cruce uniforme
  por gen + mutación gaussiana (σ=15% del rango, p=0.5), todo con clamp a
  los límites declarados en `M.SPEC`. El individuo #1 de cada generación es
  el default de fábrica — la búsqueda parte siempre de lo conocido y solo se
  aleja si el fitness lo justifica.
- **Reproducible**: estado en `work/evolve_state.lua` (fuente Lua, carga con
  validación estricta como el knowledge ledger) con la semilla del LCG
  guardada; `EVOLVE_STATE` redirige el fichero. `reset` limpia.
- 11 tests en `tools/test_evolve.lua`: parseo de `EV|`, pesos de fitness,
  clamps y defaults del genoma, línea de env, semilla de población (stock
  primero, resto en límites), evolución (élite intacta, límites respetados,
  reset de fitness), LCG determinista, round-trip de estado, ciclo
  next/record y disparo de generación nueva al completar la población.
- 13/13 ficheros de test en verde bajo Lua 5.1 y 5.5.
- Uso real (en el PC del usuario, donde vive el AppImage): bucle
  `next → run headless con la línea de env → record` repetido; una
  generación de 6 genomas × 2 corridas ≈ una noche. Ver WORKLOG Test56 para
  el nivel 1 (ledger de amenazas en juego).

### Test58 — P9: traza de decisión, postmortem y políticas (Capas 0 y 3 del plan-Claude)

Llegó un segundo plan de aprendizaje (revisión externa) con 5 capas. Cruce
con lo que ya había en `glm`: su Capa 1 es nuestro `zzbot.knowledge` (Test56),
su Capa 2 es `tools/evolve.lua` (Test57). Lo que faltaba y este lote entrega:
la **Capa 0** (datos de muerte con lo que el modelo predijo) y la **Capa 3
v1** (posturas de riesgo alternativas):

- **`mod/zzbot/trace.lua`** (puro): anillo de 60 ticks de combate. Dos
  entradas por tick cuando el modelo decide: la pre-decisión (hp, poise,
  nº de enemigos adyacentes/cercanos, fase, mundo) y la de decisión (acción
  elegida, `pDeath`, `pDeathUpper`, razón). Al morir, `init.lua` vuelca el
  anillo a `logs/zzbot-trace-<epoch>.txt` (con cabecera world/turn/killer/
  policy/alpha) y emite `EV|kind=death_trace` como puntero compacto; el
  anillo se resetea por vida. Solo daños entrantes: nada de esto toca la
  estrategia.
- **`tools/postmortem.lua`** (puro, CLI): parsea el log, enlaza cada `death`
  con su fichero de traza y produce un informe pegable-en-issue: asesino,
  últimos mensajes, curva de HP (peor caída en 3 ticks), última decisión y —
  lo importante para calibrar (Capa 1 fina) — dos banderas por muerte:
  **SURPRISE** (murió haciendo algo que el modelo valoró como seguro:
  `pDeathUpper <= alpha` sin huir) y **WARNED** (el modelo vio peligro N
  ticks y se ignoró M veces). Agregados por asesino/mundo/política + línea
  de calibración. El feature de predictor de la Capa 4 se entrena con estos
  datos cuando haya corpus.
- **`ZZBOT_POLICY=base|cautious|aggressive|bandit`** (Capa 3 v1): la misma
  política con otra tolerancia al riesgo — `cautious` alpha×0.5, `aggressive`
  alpha×1.75 — aplicada en boot y etiquetada en TODOS los `death`/`timeout`
  y en el nuevo evento `policy`. `bandit` hoy = base + etiqueta: la
  selección de brazo se decide offline comparando logs (postmortem agregada
  por política), no en juego. La base nunca se reemplaza: es el brazo de
  referencia.
- Tests: 6 de anillo (coerción, capacidad, serialize con placeholders, reset)
  y 7 de postmortem (parseo EV, lectura de traza, banderas surprise/warned,
  informe con y sin trazas). **15/15 ficheros de test en verde bajo Lua 5.1
  y 5.5.**
- Qué queda del plan externo: Capa 1 fina (posteriores por atributos en vez
  de por nombre + ajuste de ALPHA por calibración — necesita el corpus del
  postmortem), Capa 2 fina (biblioteca de escenarios letales con
  save-on-death; falta el hook de guardado en el juego), Capa 4 (regresión
  logística offline exportada a Lua), Capa 5 (RL sobre `model.lua` como
  entorno) — experimento, sin fecha.

### Estado de las fases tras la branch `glm`

| Fase | Alcance | Estado |
|---|---|---|
| P0 | métricas, watchdog, confirm guard, arnés, module split lotes 1-2 | completo (Test47+49) |
| P1 | ledger, barrido completo, escaleras, ruta estricta | completo (Test48, previo) |
| P2 | gear scoring/equip/burden/lámpara | módulos + tests; cableado tras flags |
| P3 | driver de diálogo | módulo + tests; cableado tras flag |
| P4 | dioses, tabú, poderes (política+solvers) | módulos + tests; tabú en equip; sonda de catálogo |
| P5 | modelo v2 (ranged/AOE/power), readiness | módulo + tests; readiness en ferry |
| P6 | planner de campaña + grafo | módulos + tests; observación tras flag |
| P7 | patas de viaje, spike del mar | módulo + tests; spike documentado |
| P8 | conocimiento aprendido de muertes (`zzbot.knowledge`) | módulo + tests; modulación tras `ZZBOT_LEARN` |
| P8b | GA offline sobre knobs del modelo (`tools/evolve.lua`) | módulo + tests + CLI; la evaluación corre en el PC del usuario |
| P9 | traza de decisión, postmortem, políticas (Capas 0+3) | módulos + tests; traces siempre activas, políticas tras `ZZBOT_POLICY` |

Bloqueado por verificación headless (necesita el AppImage en `work/`):
ejecución de `shoot`/`power` en el chooser, binding de skills (§8.9), nombres
de objetos de lámpara (§8.12), predicados de reliquia (§8.4/§8.15) y el
switch real de ruta TOWN_ORDER → planner.

### Test60 — Handoff a Claude: atasco tras completar el primer piso de The Jest

El reporte autocontenido para revisión externa es `CLAUDE_HANDOFF.md`. Incluye
los extractos de bot/juego necesarios, configuración de pruebas, secuencia de
eventos, límites de lo observado y preguntas precisas; no requiere acceso al
repositorio para leer el diagnóstico.

Estado verificado antes del último cambio en `Loot.stairsStep`:

- `tools/unit.sh`: todas las pruebas unitarias pasan.
- `tools/regress.sh dungeon`: barre 19/20, marca `level_done` a t=163.7 s y
  termina con `dungeon_blocked reason=no_way_out` a t=183.75. El save sintético
  no tiene `chest_key`/portador ni `fnDown`, así que no es una prueba de salida.
- `tools/regress.sh jest`: la contraseña `Death Has Dominion Over All` se grita,
  abre la puerta y se entra en `dungeon2-01`; luego vence el timeout de 120 s
  durante loot. Prueba la entrada, no la escalera multi-nivel.
- `tools/regress.sh jest-multilevel` con `PEACEFUL=1`: entra en `dungeon2-01`,
  aparta 29 hostiles, barre 8/8 contenedores y emite `level_done` a t=155.9 s.
  Después permanece en `dungeon2-01`, (42,43), `cell=dungeonBridge_ew`,
  `phase=descend`, hasta timeout t=601.85 s. No hay segundo `level_enter`.
- El único cambio posterior fue una hipótesis no verificada en `Loot.stairsStep`
  sobre no pulsar Return si el root ya es `stairsDown`/`stairsUp`. El log no
  contiene el target real de `fnDown`, así que no atribuir la falla a esa rama.
  Próximo paso indicado en `CLAUDE_HANDOFF.md`: instrumentar target/trigger,
  roots y resultado de `navigateOrOpenDoor` antes de cambiar más la interacción.

No se ha hecho commit. No afirmar aún que el flujo multi-nivel funciona.

### Test59 — Post-pull: ports del WIP local, atascos y armas arrojadizas

Estado del repositorio al empezar esta sesión: el árbol local tenía trabajo sin
confirmar (P1/P2: `peaceful`, deadline de reloj de pared, arreglo de lámpara,
watchdog de atasco, arnés con `START_TOWN`/`MAPDUMP`/`PEACEFUL`). Para poder
`git pull --ff-only` se guardó en `git stash` (`WIP local antes del pull
2026-11-03`) y el remoto avanzó de `ed5eeda` a `563d461` con P8/P8b/P9/P9b y los
módulos extraídos (`metrics`, `confirm`, `dialogue`, `gear`, `gods`, `taboo`,
`powers`, `campaign`, `travel`, `knowledge`, `trace`) más `tools/unit.sh`.

Lo que el remoto ya traía: ledger de contenedores, barrido completo, escaleras,
ruta estricta, `level_done`, capa de equipo, lámpara tras `ZZBOT_LAMP`. Lo que el
remoto **no** traía y se ha portado desde el stash (verificado con
`luajit -e loadfile` y `tools/unit.sh` en verde):

- **Deadline de reloj de pared** `ZZBOT_WALL` en `checkGlobal`: el timeout de
  juego solo corre mientras el bot tiene el tick, así que un run bloqueado en un
  diálogo o en el watchdog podía superar el `timeout` del arnés y quedarse vivo.
  Emite `timeout reason=wall` y sale con código 3.
- **`ZZBOT_PEACEFUL=1`** (solo pruebas): al entrar a un nivel manda a casa a
  todos los hostiles (`isAway`), y repite el barrido cada segundo para los
  guardianes que aparezcan después. Permite medir barrido/descenso sin que el
  resultado lo decida el combate. `tools/regress.sh` lo pasa junto con
  `ZZBOT_START_TOWN`, `ZZBOT_MAPDUMP` y `--kill-after=20s`.
- **Lámpara (P2)**: `game:toggleInventoryID` no existe; la API real es
  `player:toggleInventoryID("lampInventoryID", id)` y luego
  `game:updateLampStatus(...)` para recalcular vista/FOV. Además el estado se lee
  del juego (`player.lampInventoryID`), no de `S.lampOn`, porque el juego apaga
  la lámpara al agacharse y la vuelve a encender al levantarse. Si el toggle no
  cambia la ranura se emite `amber_state state=toggle_failed` con backoff de 30 s
  en vez de reintentar en silencio (causa de la ráfaga de `lamp: lit` del log).
- **Frontera sin progreso**: `findFrontier(game, player, blocked)` acepta celdas
  bloqueadas y el llamador aplica una gracia de 8 s sin celdas nuevas antes de
  anotarla (`frontier_skip reason=no_progress`). Es el caso de un bolsillo tras
  una ventana o una caída de un solo sentido.
- **Tope de atasco del barrido**: el contenedor elegido que no acorta su plan en
  20 s se anota `container_skip reason=stalled` y se replanifica, en lugar de
  embestirlo hasta el timeout.
- **Regla de botín completo aplicada de verdad**: `level_done` ya no se emite
  mientras quede algún contenedor pendiente **sin** anotar (bloqueante). Se
  cuentan `looted/containers/annotated` y, si quedan bloqueantes y todas las
  capas declinan, se emite `idle` cada 8 s con el objetivo más cercano y su
  longitud de camino. Antes la cima del tick podía declarar el nivel terminado
  con contenedores alcanzables sin abrir.

Armas arrojadizas (pregunta del usuario): **no es una decisión del modelo, es una
carencia**. `combatStep` solo golpea en cuerpo a cuerpo y `playerProfile` calcula
`dps` únicamente con `getTotalPlayerMeleeAttackStatsAfterEquipmentDegradation`,
así que nunca se comparan opciones a distancia. En el juego sí existen
(`throwing_stones`, `throwing_daggers`, `throwing_pins` son `category = "ranged"`
con `distance` y `showArc`), y el inventario inicial ya trae 10 piedras que el bot
nunca usa; la capa de venta solo conserva un arma a distancia y su munición
(`hasRangedWeapon`). Para usarlas hay que entrar en el flujo de apuntado
(`pendingActionData` + `targetedOffset` + `performPendingActionAtTargetLocation`)
o llamar la acción `rangedWeapon`; queda como trabajo de P5 (modelo v2) y no como
un bug de la lógica de daño actual.

En curso: `tools/regress.sh dungeon` y `tools/regress.sh jest-multilevel` (este
último con `PEACEFUL=1`) sobre el build nuevo.

### Test60 — P1 cerrado hasta donde se puede sin equipo; P2: el adaptador de equipo puntuaba cero

**The Jest (P1) queda aparcado a propósito.** El grito del Jest está verificado
(`yell@dungeon=dungeon2-01`, `entrance_unlocked`) y el descenso multinivel
funciona: piso 1 barrido 8/8 (`level_done` a t=240, known=3174) y bajada a
`dungeon2-02`. Lo que mata las runs no es la estrategia de barrido, es el
contenido: cada trampa o pincho que sube quita el **25% de la vida máxima**
(`actor.lua:8170 hitBySpikes`), así que cuatro golpes matan incluso al personaje
de prueba de 200 000 HP. Un piso 2 de la mazmorra de reliquias se juega con el
equipo de P2/P4 y el modelo de P5; insistir ahora es hacer el examen difícil
antes del fácil.

Lo que sí se dejó implementado y en verde (sintaxis, `tools/build.sh`,
`tools/unit.sh`):

- **Celdas peligrosas en el pathfinder**: agujeros (`trapdoorClosed`,
  `trapdoorOpen`, `void`) y trampas visibles (`fireTrap*`, `amberTrap*`) como
  muro (`DATA.HAZARD_CELLS` / `DATA.HAZARD_PREFIXES` / `DATA.isHazardCellName`).
  Los pinchos **no** se bloquean: el juego los cicla y hay salas enteras
  cubiertas; bloquearlos dejaba el barrido en 6/8 y `stuck`.
- **Trampas ocultas** (`fnTrap`): no son celdas, son triggers encima de suelo
  normal. Se penalizan en `weightedSteps` (`DATA.TRAP_PENALTY`,
  `DATA.TRAP_STEP_COST = 60`, `DATA.rebuildTrapPenalty(game)` al cambiar de
  mundo), así que la ruta las bordea cuando puede y las cruza cuando es el
  único pasillo.
- **Ciclo de pinchos** (`DATA.isSpikeCellName`, `DATA.spikesUp`,
  `DATA.spikeDownTurns`, `DATA.spikeGuard`): suben en los turnos 1-2 y 11-12 de
  cada 24 (`state_game.lua:8886`). El bot solo entra en una tirada de celdas de
  pinchos si la ventana de bajada cubre la tirada completa, y si le pilla encima
  se aparta a una celda sólida antes de que suban. Penalización suave (+8) para
  preferir suelo firme.
- **Escaleras tras puerta no abrible**: `Loot.stairsStep` responde
  `stairs_locked` (rc=4) en vez de embestir la puerta.
- **`PEACEFUL` no pierde llaves**: al mandar a casa a un hostil transfiere
  `carryingObject` al jugador antes de marcarlo `isAway`.
- **Subir fuera del Jest es P6**: exige `key_master`, premio del boss del piso 7.
  Por eso `jest-multilevel.conf` ya no pide salir; pide `level_done@world=dungeon2-01`,
  `level_done>=2`, `level_enter@from=dungeon2-01`, `!death`, `!alert_stuck`,
  `!confirm_unknown`, `!stairs_stall`, `!stairs_failed`. Hoy falla por muerte en
  `dungeon2-02` (`floorSpikesOn*`) y se deja como escenario de diagnóstico, no
  como puerta de P1.

**P2 — bug real encontrado en el adaptador de equipo.** `gearRecord` leía
`def.damage`, `def.defense`, `def.burden`, `def.might` y `def.block`, columnas
que **no existen** en `data/ObjectData - Sheet1.csv`; el juego usa
`physicalMeleeDam`/`magicalMeleeDam`, `physicalDef`/`magicalDef`,
`shieldBlockFraction`, `weight` y `weaponTimeCost`. Resultado: todos los
registros puntuaban 0 y `Gear.planEquip` nunca proponía un cambio — la capa de
equipo parecía instalada y era inerte.

- La conversión vive ahora en `gear.fromObjectData(o, def)` (pura y con tests) y
  `init.gearRecord` solo le añade `identified`. `zzbot.gear` prefiere
  `DPS_Calculation` cuando el juego lo expone y si no cae a
  `damage / timeCost`.
- La armadura se puntúa como defensa por **peso** (no hay columna de burden;
  el peso es lo que el juego cobra al cargar).
- Las armas a distancia se vetoadas en el plan hasta P5: `combatStep` solo
  embiste, así que un arco en la mano es pérdida neta de daño.
- Diagnóstico: una vez por nivel, `gear: no upgrade among N wearable records
  (M vetoed)`. En la run de `newgame` sale `5 wearable records (1 vetoed)`, que
  es la prueba de que el adaptador ya puntúa.
- `tools/regress.sh` pasa `ZZBOT_GEAR` (por defecto `1`, se puede apagar con
  `GEAR=""` en el `.conf`), así que el arnés por fin ejerce la capa de equipo.

**Bug propio encontrado en la verificación (ya corregido).** El primer intento de
`DATA.spikeGuard` se llamaba sin `px, py`, así que `cellAt(map, nil, nil)`
reventaba en cada tick de `moveToward`: el `pcall` del hook tragaba el error una
vez (`S.errLogged`) y el bot se quedaba clavado en la cama de Yarrow 900 s
(`newgame` en rojo). Ahora `moveToward` pasa las coordenadas y `spikeGuard`
ignora la llamada si no son números; `cellAt` devuelve `nil` en vez de petar,
para que una celda fuera de mapa sea "no transitable" y no un tick perdido.

**Segundo y tercer cuelgue: `pressDelta` con un delta que no es unitario.**
Con los dos bugs anteriores corregidos, `newgame` volvió a pasar una vez y
después se quedó otros 760 s parado en `Moon-upon-Thoss` en `phase=to-shop`
(32,63, hp 37/400). La causa de la familia: `doFlee` tomaba la celda que
devuelve `desperateEscapeCell` y la pasaba como si fuera un delta
(`pressDelta(50, 71)`), y `pressDelta` solo entiende ±1/0, así que **no pulsaba
nada** y devolvía `false` mientras `doFlee` devolvía `true`: bucle infinito.
Igual en `walkNextToActor`, que ignoraba el resultado de `pressDelta`. Ahora:

- el fallback de `doFlee` calcula el delta contra `player.position`;
- `doFlee` y `walkNextToActor` devuelven `false` si `pressDelta` falla, con un
  log único (`flee: no unit direction ...` / `shop: walkNextToActor cannot press ...`).
- **Watchdog de atasco para todos los mundos** (el detector `stuck` existente
  solo miraba mazmorras): si la posición no cambia en 25 s de juego, loguea
  `stall Ns ... (phase=..., tag=...)` + evento `stall` cada 15 s, y a los 45 s
  limpia los flags de sesión (`sellActive`/`buyActive`/`discActive` y sus
  cooldowns) para que el siguiente tick replanifique en vez de arrastrar un plan
  atascado. La línea `beat` ahora incluye `tag=`, que nombra el paso de pueblo
  que se está quedando con el turno.

**Lo que queda en `newgame` es combate, no cuelgue.** Con el watchdog puesto, las
siguientes runs ya no se congelan: mueren. Dos seguidas en `firstDungeon-01`
(t=37 y t=61, junto al cofre de 68,32), con `v=avoid` en el modelo, `need` >
`res` (necesita 811 y le quedan 21) y sin pociones: el pack de escarabajos +
avispas pega 380 de daño en un solo turno (109, 270 y 132 por mordisco con
armadura bloqueando 9-11), y la rama `avoid` no encuentra celda de retirada, así
que cae al `bump` y pelea. Eso es doctrina de P5 (no entrar en la sala, curar
antes del contacto, retirada con hueco real), no un bug de pathfinding. El
`newgame` es, por tanto, **flaky por potencia de combate**, no por atasco.

Pendiente de P2: escalera de burden sin consumidor (el peso solo limita las
compras de arbitraje) y el trato de objetos sin identificar.

### Test61 — P2 §3.2: curas de estados (data-driven)

El catálogo de curas no está en el código del juego como lista de objetos, sino
en `G_Globals.cureStates` (efecto → bandera de estado) y en la columna `useFX1`
de `ObjectData`; el inventario expone `findInventoryObjectWithUseFX`, que ya se
usaba para el Lifestone. Con eso la política queda data-driven, sin nombres de
objeto cableados:

| fx | objeto | estado |
|---|---|---|
| `cure_bleed` | Bandage | `isBleeding` |
| `cure_flame` | Water | `isAflame` |
| `cure_poison` | Antidote | `isPoisoned` |
| `cure_rot` | Sera-leaf Oil | `isRotting` |
| `cure_stun` | Acitra Nectar | `isStunned` |
| `cure_torpor` | Blackwater Draft | `isTorpid` |
| `cure_blind` | Sightsalve | `isBlind` |
| `cure_mad` | Bitterleaf Brew | `isMad` |
| `cure_deafness` | Silentsalve | `isDeaf` |
| `cure_all` | Arnaut's Panacea | cualquiera |

(De paso: los nombres que se suponían en el plan, `potion_water` y
`potion_cure_blindness`, no existen; son `Water` y `Sightsalve` con ese `useFX1`.)

- `Gear.curePlan(statuses, stock)` (puro, en `gear.lua`): elige el **cure
específico** antes que la panacea; `cure_all` solo cuando limpia 2+ males, o
cuando el único mal **drena vida por turno** (sangrado, fuego, veneno, podredumbre)
y no hay específico. Orden de gasto: drenantes primero, luego stun/torpor
(pierden el turno), ceguera, locura y sordera al final (la sordera solo silencia
líneas de NPC). Ni `isWet`/`isOily` ni las pociones-trampa (locura, aturdimiento,
veneno) entran en la lista: no se usan nunca.
- `DATA.cureStep(game, player)` en `init.lua`, llamado al principio de `tryHeal`
(antes de la comprobación de HP, porque sangrar bloquea la regeneración y se
come lo que curaría una poción). Escanea el inventario con `DATA.cureStock`, se
niega a usar nada si el estado no está activo (regla de no desperdiciar), emite
`EV|kind=cure|fx=...|ailment=...` por uso y `nocure` (máx. cada 15 s) cuando el
mal no tiene remedio en la mochila.
- **Gancho P4**: antes de usar, `Taboo.check(profile, "heal", {itemType, category})`;
si el dios lo prohíbe (Dust con pociones/ungüentos), deja el objeto y emite
`taboo_block kind=heal`.
- Tests nuevos en `tools/test_gear.lua`: nada se gasta sin mal activo, específico
antes que panacea, panacea con 2 males, panacea no se gasta en sordera ni en
locura solas, sí en un drenante sin específico, y drenante antes que cosmético.

Verificado: sintaxis, `tools/build.sh`, `tools/unit.sh` (todo verde) y
`tools/regress.sh smoke yarrow` PASS. En el log del smoke sale el camino nuevo
funcionando: el jugador empieza `torpid` y el bot emite
`cure: nothing in the pack for torpid` + `EV|nocure|ailment=torpid` una sola vez.

**Burden: el juego no permite tirar objetos.** Buscando consumidor para
`Gear.dropLadder` apareció que el inventario solo pierde objetos por uso
(`destroyOnUse`), venta (`sell_panel.lua`) o consumo en crafteo (`actions.lua`);
el único `drop` es el comando de consola `console_drop`, que **crea** un objeto
nuevo en el suelo y no quita el original. Así que el escalón 2 del plan (tirar
lo de peor valor/peso) no es ejecutable y la escalera se queda como política
pura, sin consumidor, a propósito: el peso se gestiona **no comprando** y
vendiendo. Anotado en `PLAN.md` §3.2.

Sí se añadió la observabilidad que faltaba: cada `beat` escribe
`burden weight=W/MAX mult=X` usando los números del propio juego
(`getRawPlayerBurdenAndMaxBurden` y `getPlayerTickCostMultiplier`; 0.8 vacío,
1.0 al máximo, >1.0 por encima). En el arranque del smoke: 14/40 → 0.87.

**Bonus: la línea `stats` estaba muerta desde siempre.** Estaba dentro de un
`pcall` que se comía el fallo, y el fallo era real:
`tostring(game:getCurrentGod())` revienta cuando el jugador aún no sigue a nadie
(un resultado vacío en posición de argumento no es `nil`, es error). Ahora se
lee con `game.getCurrentGod and game:getCurrentGod(game)` y el `pcall` loguea
`stats: cannot read player stats (...)` una sola vez si vuelve a romperse. Con
eso ya se ven dinero y devociones por dios (`money=520`, todos a 0 al empezar),
que es justo lo que P4 va a necesitar.

Verificado tras estos cambios: sintaxis, `tools/build.sh`, `tools/unit.sh` y
`tools/regress.sh smoke` PASS; `yarrow` re-lanzado por el cambio en `tryHeal`.

**Objetos sin identificar.** `planEquip` ya marcaba `identified = false` en la
entrada del plan, pero el umbral era el mismo que para el equipo conocido. Ahora
un candidato sin identificar necesita **2.0x** la puntuación actual (frente a
1.15x de uno conocido), y el `equipStep` que ya logueaba `, unidentified` emite
`eq|unidentified=true`. Dos tests nuevos: un 1.3x sin identificar se rechaza, un
salto grande se acepta y se marca. Sigue abierto qué hace `isItemInert` con un
objeto maldito puesto (no hay ejemplo en el juego todavía).

Con esto P2 §3.2 queda cerrado salvo ese detalle: candidatos, puntuación,
verificación por números del juego (equipar solo en contexto seguro, un cambio
por tick), identificación conservadora, curación data-driven y burden medido.

Verificación final: sintaxis, `tools/build.sh`, `tools/unit.sh` y
`tools/regress.sh smoke` + `yarrow` en verde.

## Test62 — Re-evaluación del plan y A/B del modelo Monte Carlo (2026-11-12)

**Petición:** re-evaluar `PLAN.md` contra el estado real del bot, y hacer algo con
el motor de combate nuevo y con la feature de aprendizaje, que hasta ahora no se
habían tocado.

### Lo que el plan suponía y lo que hay

`PLAN.md` se escribió sin acceso al repo y por eso pedía construir cosas que ya
existen: `model.lua` (816 líneas de Monte Carlo del reloj de combate, con
`shoot`/`power` simulados), `knowledge.lua` (ledger Beta por enemigo y banda),
`trace.lua` + `postmortem.lua`, `evolve.lua`, y los módulos de pueblo
(`dialogue`, `gods`, `taboo`, `powers`, `campaign`, `travel`). También ignora
que P8/P8b/P9 existen. La tabla de fases no distinguía "módulo escrito" de
"capacidad viva", y ahí está todo el hueco: cinco flags siguen en 0
(`ZZBOT_MODEL`, `ZZBOT_LEARN`, `ZZBOT_DIALOGUE`, `ZZBOT_POWERS`,
`ZZBOT_CAMPAIGN`), así que el bot que corren los escenarios es esencialmente el
de P1/P2.

`PLAN.md` ahora abre con §0.0 (estado verificado), reordena las fases
(P5 = arreglar el punto de decisión; nueva P5b = aprendizaje con datos; después
P6/P7) y añade V0–V4 como trabajo inmediato: medir, arreglar el modelo, cablear
ranged/poderes, generar datos de aprendizaje, apagar/encender flags.

### A/B: el modelo tal como está cableado es peor

Para poder medirlos añadí passthrough a `tools/regress.sh`: `MODEL=1` y
`LEARN=1` exportan `ZZBOT_MODEL`/`ZZBOT_LEARN` y guardan el ledger aprendido
dentro del XDG del escenario (`ZZBOT_KNOWLEDGE`), para que un run no enseñe al
siguiente. Mismo save (`save-dungeon-start`), mismo `TIMEOUT=300`:

| Run | Resultado |
|---|---|
| `tools/regress.sh dungeon` | **PASS**: `level_done` 19/20 a t=276, sin muerte, sale por `dungeon_blocked reason=chest_key_missing` |
| `MODEL=1 LEARN=1 tools/regress.sh dungeon` | **FAIL**: muerte a t=178 en 41,22 (`bones`), sin `level_done` |

**El modelo no predijo mal: predijo bien y aun así murió.** La traza muestra
`hp=142/400`, poise 55, un hornet adyacente: `hit` con `pDeath=0.98`,
`flee` con `pDeath=1.00`; eligió `hit` ("minimise risk") y alternó hit/flee
durante diez turnos hasta morir. Son tres defectos de integración, no del
simulador:

1. `chooseEval` no tiene repliegue: si la mejor opción está al 98% de muerte, la
   ejecuta igual, en vez de ceder el tick a la capa `avoid`/kite que en el
   baseline es la que sobrevive.
2. El modelo solo se consulta con `#adj > 0`, ya en contacto, donde huir es
   matemáticamente peor que pelear. La decisión que salva vidas (alejarse antes)
   vive en la capa de movimiento y el modelo no la puede elegir.
3. Desempate: a igual riesgo gana el que menos recursos gasta, y atacar cuesta 0.

Y el hueco que ya sabíamos: `buildCombatOptions` no ofrece `shoot` ni `power`,
así que el "modelo v2" que el WORKLOG daba por completo (Test53) está simulado
pero nunca propuesto. `tools/test_model.lua` tampoco tiene casos de `shoot` ni
de `power`.

### Aprendizaje

`knowledge fresh: 0 deaths, 0 kills, 0 enemy kinds` es literalmente lo único que
se ve en los logs: ningún run ha escrito ledger, y el multiplicador no se aplica
hasta 5 observaciones por banda, así que hoy la feature es inerte. Dos cosas
más que se ven en la evidencia: `death ... by=nil` (la atribución del asesino
falla, y el ledger necesita `by=` para mover el multiplicador correcto) y el
ledger entra por `threatList`, o sea que también modula la heurística, no solo
el modelo. Queda como V3 en el plan, con la biblioteca de escenarios letales
(save unos segundos antes de cada muerte) para que el GA pueda puntuar sin
esperar 15 minutos por genoma.

### Verificación

Sintaxis, `tools/build.sh`, `tools/unit.sh`, `tools/regress.sh dungeon` (PASS,
baseline) y el A/B documentado arriba. No toqué el save jugable: ambos runs van
en `work/xdg-regress/dungeon`.

## Test63 — Ataque a distancia cableado: `r` → `rangedWeapon` (2026-11-13)

### El mecanismo real (leído en el fuente del juego)

No existe una acción `shoot` aparte: la tecla `r` (`G_Globals.keyRanged`) solo
pone `IM_INPUT.ranged`, y `state_game.lua:4033` traduce eso en
`getFiringErrors()` + `playerInitiatingAction("rangedWeapon",
player:getFinalPlayerRange())`. La acción `rangedWeapon` de
`CActions.static.data` es `targetingType="location"`, `radius=1`,
`timeCost=12`, `isBlockedByWalls=true`; `getFiringErrors` exige la skill
usable, `player.rangedInventoryID ~= 0` y
`player:getAmmoForCurrentRangedWeapon() > 0`. O sea: overlay de apuntado aparte,
el disparo es una acción de ubicación que consume la munición de la pila
equipada. Al empezar la partida hay `throwing_stones` x10 en el slot ranged.

### Cambios

- `DATA.rangedInfo(game, player)`: rango efectivo con `getFinalPlayerRange()`
  (3 con las piedras, no el 4 de la tabla), munición, daño medio con
  `CActions.getRangedAverageDamage` (8 con `throwing_stones`), `time` de
  `weaponTimeCost`.
- `DATA.rangedTargets`: enemigos dentro de rango **con** `getLOMToWorldXY`
  despejado. Lo usan la lista de opciones y la ventana de decisión, para que la
  ventana no se abra con un muro de por medio (con solo la distancia se abría y
  no quedaba más que `wait-poise`: el run se quedó esperando 90 s).
- `buildCombatOptions`: nueva opción `shoot` (target del pack, `damage`, `time`,
  `range`), con coste de recurso 0.05 porque la munición es finita.
- `executeChoice`: fija `targetedOffset` y llama a
  `performPendingActionAtTargetLocation({id="rangedWeapon", ...})`; loguea
  `EV|kind=shoot|target=…|dist=…|dmg=…|range=…`.
- `equipStep`: el veto `ranged combat not implemented (P5)` pasa a ser
  `ranged unused without the model`. Melee y ranged son slots distintos, así que
  llevar arma a distancia no cuesta daño cuerpo a cuerpo, pero con
  `ZZBOT_MODEL=0` la heurística nunca dispara y equiparla solo alteraría el run
  por defecto.
- La rama del modelo se abre sin adyacentes **solo** si hay un `shoot` posible.
- `tools/test_model.lua`: dos casos nuevos (a 3 casillas `shoot` mata y `attack`
  no; fuera de `range` no mata).

### A/B (mismo save, `TIMEOUT=300`, Yarrow Cave)

| Run | Resultado | Disparos |
|---|---|---|
| baseline `tools/regress.sh dungeon` (Test62) | PASS (19/20, t=276, `chest_key_missing`) | 0 |
| `MODEL=1` | **PASS** (19/20, t=274) | **19** (dist 1–3, `dmg=8`) |
| `MODEL=1 LEARN=1` | FAIL: timeout con 19/20, luego muerte a t=186 | 18 / 13 |
| baseline, tres repeticiones de hoy | timeout con 19, 14 y 17 contenedores, sin muerte | 0 |

El baseline vive al filo del `TIMEOUT`: pasa a t=276 de 300. Las tres
repeticiones de hoy no son regresión del cambio — el camino sin modelo no
ejecuta nada nuevo (`DATA.rangedInfo`/`DATA.rangedTargets` solo se llaman
desde la rama del modelo y el veto de equipo vuelve a ser el mismo para
`ZZBOT_MODEL=0`); es el margen del escenario, y conviene subir `TIMEOUT` o
aceptar 19/20 en `dungeon`.

Los dos fallos con `LEARN=1` no son del disparo: uno fue el atasco de
`wait-poise` (corregido con la comprobación de LOS) y el otro la muerte de
siempre — todas las opciones de contacto a `pDeath=98–100%` y el chooser
ejecuta `hit` igual, porque **sigue sin existir la válvula de repliegue**
(V1a del plan). El modelo predice bien; el punto de decisión no sabe rendirse.

### Verificación

Sintaxis, `tools/build.sh`, `tools/unit.sh`, `luajit tools/test_model.lua` y los
runs de arriba en `work/xdg-regress/dungeon` (save jugable intacto).

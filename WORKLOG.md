# Worklog — moonring-bot

Última actualización: 2026-10-27 (combate generalizado, mazmorra completada y verificada en headless).

Objetivo: bot autónomo estilo qw para **Moonring**. Debe iniciar una partida nueva,
llegar desde el pueblo Yarrow a **Yarrow Cave** (`firstDungeon-01`), explorarla,
obtener la **llave maestra** (`key_master`), salir de la mazmorra y volver a Yarrow.

Proyecto independiente de `qw2`, en `/home/lavilao570/Projects/moonring-bot`.
No es un repositorio git.

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

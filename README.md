# moonring-bot

Bot autónomo para **Moonring** (roguelike de LÖVE 11.5). Se inyecta como mod
(`mod/zzbot`) en una copia extraída del juego y juega solo: explora mazmorras,
lootea, gestiona llaves/puertas, combate con un modelo probabilístico, viaja
por el overworld, usa el transbordador y compra Gifts de los dioses.

El juego original **no se incluye** en este repo: hay que aportar el AppImage
de Moonring. El bot corre con una copia y un guardado aislados; nunca toca el
guardado real del usuario (`~/.local/share/Moonring`).

## Requisitos

- Linux x86_64
- `python3`, `curl`, `luajit` (opcional, para comprobar sintaxis)
- Un AppImage de Moonring (por ejemplo `Moonring.AppImage`)
- LÖVE 11.5 (lo descarga `tools/fetch-love.sh`)

## Puesta en marcha

```bash
git clone https://github.com/lavilao/moonring-bot
cd moonring-bot

# 1) LÖVE 11.5 en vendor/
tools/fetch-love.sh

# 2) Extraer Moonring e inyectar el mod en work/moonring-bot
tools/build.sh /ruta/a/Moonring.AppImage
# o exportar MOONRING_APPIMAGE=/ruta/al/AppImage

# 3) Jugar (normal)
tools/run.sh

# 4) Automático sin ventana (pruebas)
ZZBOT_HEADLESS=1 ZZBOT_AUTOSTART=1 ZZBOT_START_ON=1 ZZBOT_QUIT=1 \
ZZBOT_SPEED=8 ZZBOT_TIMEOUT=1800 ZZBOT_LOG=/tmp/zzbot.log tools/run.sh
```

`tools/build.sh` descomprime el binario del juego (es un zip), copia
`mod/zzbot` a `work/moonring-bot/zzbot` y añade `require("zzbot")` al final de
`main.lua`. `tools/run.sh` ejecuta LÖVE con `XDG_DATA_HOME=work/xdg`, así que
los guardados de las pruebas viven en
`work/xdg/love/moonring-bot/data/save` y no en el home del usuario.

- **F9** activa/desactiva el bot en caliente.
- El guardado del usuario está a salvo: si quieres jugar tú, usa tu Moonring
  normal; este repo no lo abre.

### Guardados de prueba

Los baseline usados durante el desarrollo están en `work/save-backup/`
(ignorado por git). Para restaurar uno:

```bash
mv work/xdg/love/moonring-bot/data/save work/xdg/love/moonring-bot/data/save-prev
mkdir -p work/xdg/love/moonring-bot/data/save
cp -a work/save-backup/save-075659/. work/xdg/love/moonring-bot/data/save/
rm -rf work/xdg/love/moonring-bot/data/save_backup/* work/xdg/love/moonring-bot/data/save_failed/*
```

## Variables de entorno

| Variable | Default | Descripción |
|---|---|---|
| `ZZBOT_SPEED` | `4` | Actualizaciones del juego por frame (acelera las pruebas) |
| `ZZBOT_TIMEOUT` | `1800` | Segundos de juego antes de salir |
| `ZZBOT_LOG` | `logs/zzbot.log` | Fichero de log |
| `ZZBOT_QUIT` | `0` | `1` = salir al morir o terminar |
| `ZZBOT_AUTOSTART` | `0` | `1` = pulsar "continuar" en el título solo |
| `ZZBOT_START_ON` | `0` | `1` = bot activo desde el arranque (**necesario** para autostart) |
| `ZZBOT_HEADLESS` | `0` | `1` = SDL sin ventana (lo lee `tools/run.sh`) |
| `ZZBOT_NAME` | `QwBot` | Nombre para partida nueva |
| `ZZBOT_TOGGLE` | `f9` | Tecla de activación |
| `ZZBOT_GOD` | `deathsHarlequin` | Dios al que dedicar cuando la gira termine |
| `ZZBOT_TOUR` | `1` | `0` = desactivar la gira de devoción |
| `ZZBOT_START_TOWN` | `1` | Índice inicial en `TOWN_ORDER` |
| `ZZBOT_TRADE` | `1` | `0` = desactivar el arbitraje de mercancías |
| `ZZBOT_TRADE_MARGIN` | `1.20` | Margen mínimo esperado al comprar (venta ≥ 1.2× coste) |
| `ZZBOT_TRADE_TAKE` | `1.10` | Umbral para vender mercancía comprada (≥ 1.1× coste) |
| `ZZBOT_TRADE_DEBUG` | `0` | `1` = volcar en el log los mejores spreads de cada ciudad |
| `ZZBOT_MONEY_RESERVE` | `150` | Guineas intocables (ferry, posada, imprevistos) |
| `ZZBOT_SELL_HOLD` | `0.95` | Con reserva cubierta, no vender si la demanda local es menor |
| `ZZBOT_MODEL` | `0` | `1` = usar el modelo Monte Carlo en combate |
| `ZZBOT_MODEL_N` | `64` | Muestras del modelo |
| `ZZBOT_ALPHA` | `0.08` | Tolerancia de riesgo del modelo |
| `ZZBOT_HORIZON` | `480` | Horizonte temporal del modelo |
| `ZZBOT_SHOT_INTERVAL` | – | Segundos entre capturas (`zzshot-NNN.png`) |
| `ZZBOT_MAPDUMP` | – | Fichero donde volcar el mapa en cada cambio de mundo/muerte |

## Qué hace

1. **Mazmorras**: explora frentes, abre puertas (llaves, ganzúa, placas,
   puertas secretas empujando), busca la llave del cofre, saquea y sale.
2. **Combate**: modelo probabilístico (`mod/zzbot/model.lua`) que decide
   golpear, curarse, esperar poise, hacer kite o huir; usa pociones, Lifestone
   y varas de curación.
3. **Campaña**: `TOWN_ORDER` (Yarrow → Moon-upon-Thoss → Barrow-Linn →
   Harrowdus → Hearthaven → Wintersholl → The_Red_Grove). Cada ciudad lleva a
   su mazmorra vía `leadsTo`.
4. **Gira de devoción**: antes de las mazmorras de campaña visita las 5
   ciudades natales de los dioses (+2 de devoción por logro), compra Gifts con
   esa devoción (empieza por los de coste 1: cada Gift da +5 al atributo de su
   dios) y, al terminar la gira, se dedica al dios configurado. El oro no se
   puede donar, pero sí comprar **tipos desconocidos** de poción, ungüento y
   vara: cada tipo nuevo alimenta las Devotional Tasks de descubrimiento
   (`discoverAllPotions` 15 tipos, +2; `discoverAllWands` 12 tipos, +2).
5. **Economía**: vende el loot que no usa al tendero más rico allí donde la
   demanda local no sea baja (protege equipo, consumibles, llaves y encargos).
   Además hace **arbitraje**: cada ciudad tiene un offset de demanda
   (0.7×–1.5×) por objeto y descuenta un 25% sus productos locales; comprar
   cuesta `precio × demanda` y vender paga `precio × demanda × 0.65`, así que
   el bot compra existencias baratas (con reserva de dinero intacta) y las
   etiqueta con su coste; solo las vende donde el valor local supera el coste
   con margen (`ZZBOT_TRADE_MARGIN`/`ZZBOT_TRADE_TAKE`). Comprar sube la
   demanda local y vender la baja, así que los beneficios se agotan solos.
6. **Overworld**: ruta global sobre `data/save/Overworld.png` (BFS 512×512).
   El mundo es un archipiélago: Barrow-Linn solo se alcanza con el
   **transbordador** de Moon-upon-Thoss (121–150 guineas; vuelta gratis desde
   `Barrow-Linn-Ferry`). El bot va a la puerta de Moon-upon-Thoss, entra y
   pide el pasaje. Los `overworld_enemy` son marcadores: pisarlos abre un Zoom
   con todo el grupo, así que el bot los rodea o espera, nunca los pisa.

## Estructura

```
mod/zzbot/init.lua     mod (capa de juego, navegación, campaña, dioses, ferry)
mod/zzbot/model.lua    modelo de combate Monte Carlo
tools/build.sh         extrae Moonring e inyecta el mod
tools/fetch-love.sh    descarga LÖVE 11.5
tools/run.sh           arranca la copia moddeada con guardado aislado
tools/test_model.lua   simulación/pruebas del modelo
WORKLOG.md             bitácora de desarrollo (decisiones, tests, bugs)
analisis.md            notas de mecánicas del juego
```

## Estado actual y limitaciones

- La gira de devoción, el ferry y la ruta del overworld están implementados; el
  bot visita Barrow-Linn y Harrowdus (+2 de devoción en cada una) y sigue la
  gira.
- La economía funciona: vende el loot que no usa (protegiendo equipo,
  consumibles y encargos) al tendero más rico y hace arbitraje de demanda.
  Verificado: compra `potion_water` a 78 en Moon-upon-Thoss y la vende a 93 en
  Barrow-Linn (+19%), y compra dagas/flechas a 7 para venderlas a 9 (1.29×).
  La venta del loot de la primera mazmorra pagó el billete del ferry
  (100 → 304 guineas).
- **Oro → devoción**: compra una unidad de cada tipo desconocido de
  poción/ungüento/vara que ve en las tiendas (reservando el ferry) y compra
  los Gifts alcanzables más baratos. Verificado en pruebas: `potion_water`
  (pociones 2/15), `revelation`, `luck`, `puppet` y `life_sight`, todos de
  coste 1.
- **Punto débil actual**: las emboscadas Zoom aleatorias en el overworld
  (grupos de bandidos + animales) siguen matando al bot en algunos trayectos;
  cuando sobrevive, rescatar al mercader otorga ~500 guineas extra.
- Pendiente: barrido de loot más fino, inventario/equipo respetando el tabú
  del dios (Harlequin prohíbe hachas/espadas/mazas), poderes divinos en
  combate y diálogo con NPCs.

Ver `WORKLOG.md` para el detalle cronológico de pruebas y arreglos.

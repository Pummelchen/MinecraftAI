# Purple House

## Reference Frame Analysis

Source: `https://www.youtube.com/watch?v=gL_4xJ6TO7g`

The requested reference reads as a large L-shaped survival compound rather than
a small cabin:

- Wide, symmetrical front composition with two broad side staircases.
- Raised lower deck wrapping the front and stepping into an L-shaped plan.
- Central multi-floor house volume with steep intersecting gable roofs.
- Gray roof trim, wood roof planes, purple ridge/accent blocks, and a central
  front grid facade.
- Stone-and-wood support rhythm under the decks, including open front arcades.
- Courtyard focal point in front of the entrance, shown as a square pool.
- Side utility bays that read as garden/work/farm spaces from the front.
- Dense rails, lanterns, potted plants, hanging greenery, and flower accents.

The Pummelchen version keeps that massing and survival-house role, then turns it
into a lady-focused purple flower mansion: purple glass, purpur ridge/accent
blocks, purple terracotta details, amethyst floor inlays, purple carpets, a
large double purple bed, candle clusters, allium-heavy flower beds, and pet
spaces for cats, birds, ducks, and chickens.

## 3D Plan

Coordinate plan uses the structure's local origin at the northwest lower corner.
The finished NBT footprint is `57 x 32 x 57` blocks.

```text
Y 25-31  Intersecting gable roof peaks, polished deepslate trim, purpur ridge
Y 18-24  Wood roof planes over central house and front L-return
Y 13-18  Upper living floor: large double bedroom, balcony, bookshelves, vanity/work desk
Y 12-14  Left/right roof terraces: flower planters and wheat patches
Y  7-12  Main floor: big kitchen, lovely living room, central glass-grid facade
Y  6-7   Raised L-shaped deck wrapping house, side wings, and front bridge
Y  1-5   Basement: spa pool, storage, enchanting, smelting, quartz stair access
Y  0-1   Courtyard, paths, flower beds, pool, pet gardens, foundation
```

```text
Top view, X/Z:

  0        16        28        40        56
0 +------------------------------------------------+
  | cat patio        flowers / grass       bird pergola |
8 |                upper house volume              |
12|      left wing     central hall      right wing |
34|  open bay + grid entry + open bay/front bridge  |
40|  broad stairs    courtyard pool     broad stairs |
46|  chicken coop    flower paths       duck pond    |
56+------------------------------------------------+
```

## Generation Density

The datapack adds one random-spread placement cell every `108` chunks.

- `108 chunks * 16 blocks = 1,728 blocks`
- `1,728 * 1,728 = 2,985,984 square blocks`
- Minecraft blocks are treated as square meters, so the cell is about
  `2.986 km2`, effectively one Purple House per 3 square kilometers.

Biome targeting is `#minecraft:is_overworld`, so compatible overworld mod biomes
can receive the structure when they advertise that tag.

## Interior Direction

The generated structure uses mostly vanilla block IDs for boot and worldgen
safety, with one modded pet entity from `Untitled Duck Mod` because that mod is
active in the Pummelchen pack. The design is still based on what the Pummelchen
server already carries:

- ModernArch makes the vanilla shell, gray trim, wood roof planes, and
  purple/glass/quartz palette read more polished on clients.
- Macaw's Furniture and MrCrayfish's Furniture Mod: Refurbished are the intended
  optional upgrade path for sofas, kitchen counters, wardrobes, desks, and
  balcony seating.
- Cooking for Blockheads maps naturally to the generated kitchen zone.
- Display Case, PTS-Deco, and Luxury Building Pack can replace the vanilla
  bookshelves, barrels, slabs, and utility displays after generation.
- Cats, parrots, chickens, and `untitledduckmod:duck` entities are placed as
  persistent pets named around the property.
- The basement now centers on a quartz/amethyst spa pool with sea-lantern and
  candle lighting, while storage, enchanting, and smelting stay around the
  edges.

## Current Build Shape

The upgraded generated structure keeps the same `57 x 32 x 57` footprint and
placement spacing, but now uses `22,101` placed blocks, `103` palette states,
and `9` persistent pet entities. The exterior has the closer reference-match
features requested in the latest upgrade: twin wide staircases, raised
L-shaped decks, open utility bays, the central wood/glass grid facade, a square
courtyard pool, and intersecting gable roofs with gray trim and purple accents.

## Project Files

- `server-datapacks/pummelchen-purple-house.zip` is the deployable datapack.
- `server-datapacks-src/pummelchen-purple-house/` is generated source content.
- `server-datapacks-src/custom_datapacks.json` registers the pack as
  `Purple House` in the SQLite-backed mod collection.
- `scripts/build_purple_house_datapack.py` rebuilds and checks the zip.
- `scripts/sync_custom_datapacks.py` installs the zip into
  `server-datapacks`, mirrors it into the active `level-name` world datapacks
  folder, and upserts the tracker row.
- `scripts/reset_world_for_purple_house.py` is the backup-first live reset
  helper for making a new random-seed world and placing Purple House near spawn.

Quality gate:

```bash
python3 scripts/build_purple_house_datapack.py --check
python3 scripts/sync_custom_datapacks.py --project-dir . --check
bash scripts/validate_project.sh
```

Live reset command, run on the VPS after deployment:

```bash
python3 /var/minecraft_mods/scripts/reset_world_for_purple_house.py --yes
```

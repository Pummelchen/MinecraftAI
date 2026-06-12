# Pummelchen Rich Ores

Overrides vanilla configured ore features for overworld iron, gold, and diamonds.
Placement attempts are unchanged; only vein size is increased.
Minecraft caps ore feature size at 64, so larger requested values are clamped.

- ore_iron: 9 -> requested 90 -> final 64 clamped
- ore_iron_small: 4 -> requested 40 -> final 40
- ore_gold: 9 -> requested 90 -> final 64 clamped
- ore_gold_buried: 9 -> requested 90 -> final 64 clamped
- ore_diamond_small: 4 -> requested 40 -> final 40
- ore_diamond_medium: 8 -> requested 80 -> final 64 clamped
- ore_diamond_large: 12 -> requested 120 -> final 64 clamped
- ore_diamond_buried: 8 -> requested 80 -> final 64 clamped

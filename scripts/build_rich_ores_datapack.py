#!/usr/bin/env python3
"""Build the Pummelchen rich ores datapack.

This datapack keeps vanilla ore placement attempts intact and scales the
configured vein size for iron, gold, and diamond ore. Minecraft's ore feature
codec caps vein size at 64, so 10x requests above that limit are clamped.
"""

from __future__ import annotations

import argparse
import json
import shutil
import zipfile
from pathlib import Path
from typing import Any


ROOT_DIR = Path(__file__).resolve().parents[1]
DEFAULT_SRC_DIR = ROOT_DIR / "server-datapacks-src" / "pummelchen-rich-ores"
DEFAULT_ZIP = ROOT_DIR / "server-datapacks" / "pummelchen-rich-ores.zip"
MAX_ORE_SIZE = 64

ORE_FEATURES = {
    "ore_iron": {
        "base_size": 9,
        "discard_chance_on_air_exposure": 0.0,
        "blocks": ("minecraft:iron_ore", "minecraft:deepslate_iron_ore"),
    },
    "ore_iron_small": {
        "base_size": 4,
        "discard_chance_on_air_exposure": 0.0,
        "blocks": ("minecraft:iron_ore", "minecraft:deepslate_iron_ore"),
    },
    "ore_gold": {
        "base_size": 9,
        "discard_chance_on_air_exposure": 0.0,
        "blocks": ("minecraft:gold_ore", "minecraft:deepslate_gold_ore"),
    },
    "ore_gold_buried": {
        "base_size": 9,
        "discard_chance_on_air_exposure": 0.5,
        "blocks": ("minecraft:gold_ore", "minecraft:deepslate_gold_ore"),
    },
    "ore_diamond_small": {
        "base_size": 4,
        "discard_chance_on_air_exposure": 0.5,
        "blocks": ("minecraft:diamond_ore", "minecraft:deepslate_diamond_ore"),
    },
    "ore_diamond_medium": {
        "base_size": 8,
        "discard_chance_on_air_exposure": 0.5,
        "blocks": ("minecraft:diamond_ore", "minecraft:deepslate_diamond_ore"),
    },
    "ore_diamond_large": {
        "base_size": 12,
        "discard_chance_on_air_exposure": 0.7,
        "blocks": ("minecraft:diamond_ore", "minecraft:deepslate_diamond_ore"),
    },
    "ore_diamond_buried": {
        "base_size": 8,
        "discard_chance_on_air_exposure": 1.0,
        "blocks": ("minecraft:diamond_ore", "minecraft:deepslate_diamond_ore"),
    },
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--src-dir", type=Path, default=DEFAULT_SRC_DIR)
    parser.add_argument("--zip-output", type=Path, default=DEFAULT_ZIP)
    parser.add_argument("--multiplier", type=int, default=10)
    parser.add_argument("--check", action="store_true", help="report expected sizes without writing files")
    return parser.parse_args()


def ore_feature_payload(feature: dict[str, Any], multiplier: int) -> dict[str, Any]:
    size = min(int(feature["base_size"]) * multiplier, MAX_ORE_SIZE)
    blocks = feature["blocks"]
    return {
        "type": "minecraft:ore",
        "config": {
            "discard_chance_on_air_exposure": feature["discard_chance_on_air_exposure"],
            "size": size,
            "targets": [
                {
                    "state": {"Name": blocks[0]},
                    "target": {
                        "predicate_type": "minecraft:tag_match",
                        "tag": "minecraft:stone_ore_replaceables",
                    },
                },
                {
                    "state": {"Name": blocks[1]},
                    "target": {
                        "predicate_type": "minecraft:tag_match",
                        "tag": "minecraft:deepslate_ore_replaceables",
                    },
                },
            ],
        },
    }


def build_report(multiplier: int) -> dict[str, Any]:
    features = {}
    for name, feature in ORE_FEATURES.items():
        requested_size = int(feature["base_size"]) * multiplier
        features[name] = {
            "base_size": feature["base_size"],
            "requested_size": requested_size,
            "final_size": min(requested_size, MAX_ORE_SIZE),
            "clamped": requested_size > MAX_ORE_SIZE,
        }
    return {
        "multiplier": multiplier,
        "max_ore_size": MAX_ORE_SIZE,
        "features": features,
    }


def write_src_datapack(src_dir: Path, multiplier: int, report: dict[str, Any]) -> None:
    if src_dir.exists():
        shutil.rmtree(src_dir)
    feature_dir = src_dir / "data" / "minecraft" / "worldgen" / "configured_feature"
    feature_dir.mkdir(parents=True)
    (src_dir / "pack.mcmeta").write_text(
        json.dumps(
            {
                "pack": {
                    "description": {
                        "text": "Pummelchen Rich Ores - larger iron, gold, and diamond ore veins"
                    },
                    "min_format": [101, 1],
                    "max_format": 101,
                }
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    for name, feature in ORE_FEATURES.items():
        payload = ore_feature_payload(feature, multiplier)
        (feature_dir / f"{name}.json").write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    lines = [
        "# Pummelchen Rich Ores",
        "",
        "Overrides vanilla configured ore features for overworld iron, gold, and diamonds.",
        "Placement attempts are unchanged; only vein size is increased.",
        f"Minecraft caps ore feature size at {MAX_ORE_SIZE}, so larger requested values are clamped.",
        "",
    ]
    for name, item in report["features"].items():
        clamp = " clamped" if item["clamped"] else ""
        lines.append(
            f"- {name}: {item['base_size']} -> requested {item['requested_size']} -> final {item['final_size']}{clamp}"
        )
    (src_dir / "RICH_ORES.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


def write_zip(src_dir: Path, zip_output: Path) -> None:
    zip_output.parent.mkdir(parents=True, exist_ok=True)
    tmp = zip_output.with_suffix(zip_output.suffix + ".tmp")
    with zipfile.ZipFile(tmp, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(src_dir.rglob("*")):
            if path.is_file():
                archive.write(path, path.relative_to(src_dir).as_posix())
    tmp.replace(zip_output)


def main() -> int:
    args = parse_args()
    if args.multiplier < 1:
        raise ValueError("--multiplier must be positive")
    report = build_report(args.multiplier)
    print(json.dumps(report, indent=2, sort_keys=True))
    if not args.check:
        write_src_datapack(args.src_dir, args.multiplier, report)
        write_zip(args.src_dir, args.zip_output)
        print(f"wrote_src={args.src_dir}")
        print(f"wrote_zip={args.zip_output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

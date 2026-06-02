#!/usr/bin/env python3
"""
Assemble Localizable.xcstrings from a list of English source keys
plus per-locale TSV translation files.

Inputs:
  - keys_file:  one English key per line (the source-language values)
  - ar_tsv:     `english<TAB>arabic` per line (same order, same count)
  - zh_tsv:     `english<TAB>chinese` per line (same order, same count)

Output: a String Catalog JSON written to the target path.

Why a script and not handwritten JSON: 687 keys × 3 locales is too
many to hand-author, and the catalog format is sensitive to character
escaping (newlines, quotes, NBSP). Centralising the assembly here
also makes it easy to regenerate the file when keys or translations
change.

The Arabic / Chinese translations are MACHINE-GENERATED seed values.
Every locale entry is written with `state: needs_review` so a future
human-review pass can find them via Xcode's String Catalog editor
("Needs Review" filter).
"""

import json
import sys
from pathlib import Path


def load_keys(path: Path) -> list[str]:
    with path.open("r", encoding="utf-8") as f:
        return [line.rstrip("\n") for line in f if line.rstrip("\n")]


def load_tsv(path: Path) -> dict[str, str]:
    """Read english<TAB>translation lines into a dict keyed on the
    english side. Tolerates duplicate keys (later overrides earlier)."""
    result: dict[str, str] = {}
    if not path.exists():
        return result
    with path.open("r", encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line:
                continue
            parts = line.split("\t", 1)
            if len(parts) != 2:
                continue
            en, tr = parts[0], parts[1]
            if en and tr:
                result[en] = tr
    return result


def build_catalog(
    keys: list[str],
    ar: dict[str, str],
    zh: dict[str, str],
) -> dict:
    strings = {}
    for key in keys:
        loc: dict = {
            "en": {
                "stringUnit": {"state": "translated", "value": key}
            }
        }
        if key in ar:
            loc["ar"] = {
                "stringUnit": {"state": "needs_review", "value": ar[key]}
            }
        if key in zh:
            loc["zh-Hans"] = {
                "stringUnit": {"state": "needs_review", "value": zh[key]}
            }
        strings[key] = {
            "extractionState": "manual",
            "localizations": loc,
        }
    return {
        "sourceLanguage": "en",
        "strings": strings,
        "version": "1.0",
    }


def main() -> int:
    if len(sys.argv) != 5:
        print(
            "usage: build_xcstrings.py <keys.txt> <ar.tsv> <zh.tsv> <output.xcstrings>",
            file=sys.stderr,
        )
        return 2
    keys_path = Path(sys.argv[1])
    ar_path = Path(sys.argv[2])
    zh_path = Path(sys.argv[3])
    out_path = Path(sys.argv[4])

    keys = load_keys(keys_path)
    if not keys:
        print(f"no keys read from {keys_path}", file=sys.stderr)
        return 1

    ar = load_tsv(ar_path)
    zh = load_tsv(zh_path)

    catalog = build_catalog(keys, ar, zh)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("w", encoding="utf-8") as f:
        json.dump(catalog, f, ensure_ascii=False, indent=2, sort_keys=True)

    print(
        f"wrote {out_path}: {len(keys)} keys, "
        f"ar={len(ar)}/{len(keys)}, zh-Hans={len(zh)}/{len(keys)}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())

"""Fills the English column of App/Resources/Localizable.xcstrings from scripts/translations-en.json.

Workflow after adding or changing texts in the app:
  1. Build the app (xcodebuild … build), so Xcode writes the .stringsdata files.
  2. xcrun xcstringstool sync App/Resources/Localizable.xcstrings --stringsdata $(find .build/xcode -name '*.stringsdata')
  3. Add the new texts to scripts/translations-en.json and run: python3 scripts/apply-translations.py
It lists the texts that still lack an English translation and the translations no longer used.
"""
import json
import sys

CATALOG = "App/Resources/Localizable.xcstrings"
TRANSLATIONS = "scripts/translations-en.json"

catalog = json.load(open(CATALOG, encoding="utf-8"))
english = json.load(open(TRANSLATIONS, encoding="utf-8"))
# Texts the code no longer uses (xcstringstool marks them "stale") are dropped.
stale = [key for key, entry in catalog["strings"].items() if entry.get("extractionState") == "stale"]
for key in stale:
    del catalog["strings"][key]
    print("Quitado (el código ya no lo usa):", key)
missing = []
for key, entry in catalog["strings"].items():
    if key not in english:
        missing.append(key)
        continue
    entry.setdefault("localizations", {})["en"] = {
        "stringUnit": {"state": "translated", "value": english[key]}
    }
unused = sorted(set(english) - set(catalog["strings"]))
with open(CATALOG, "w", encoding="utf-8") as out:
    json.dump(catalog, out, ensure_ascii=False, indent=2, sort_keys=True, separators=(",", " : "))
    out.write("\n")
for key in missing:
    print("Sin traducir:", key)
for key in unused:
    print("Ya no se usa:", key)
sys.exit(1 if missing else 0)

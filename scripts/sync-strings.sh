#!/bin/bash
# Adds new UI strings to App/Sommelier/Localizable.xcstrings after a command-line build.
# Xcode does this by itself when building in the IDE; xcodebuild only writes .stringsdata files.
#   scripts/sync-strings.sh        (run after xcodebuild with -derivedDataPath build/DerivedData)
# Then translate the new entries for every language the catalog already has.
set -euo pipefail
cd "$(dirname "$0")/.."
args=()
while IFS= read -r f; do args+=(--stringsdata "$f"); done \
  < <(find build/DerivedData -path "*Sommelier.build*" -name "*.stringsdata" | sort -u)
[ ${#args[@]} -gt 0 ] || { echo "no .stringsdata found; build the app first" >&2; exit 1; }
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" xcrun xcstringstool sync App/Sommelier/Localizable.xcstrings "${args[@]}"
python3 -I - <<'PY'
import json
d = json.load(open("App/Sommelier/Localizable.xcstrings"))
languages = sorted({lang for v in d["strings"].values() for lang in v.get("localizations", {})} - {d["sourceLanguage"]})
print(f"{len(d['strings'])} strings; languages: {', '.join(languages)}")
for lang in languages:
    missing = [k for k, v in d["strings"].items() if k and lang not in v.get("localizations", {}) and v.get("shouldTranslate", True)]
    print(f"  {lang}: {len(missing)} untranslated" + ("".join(f"\n    {k}" for k in missing)))
PY

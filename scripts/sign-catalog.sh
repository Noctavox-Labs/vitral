#!/bin/zsh
# Signs catalog/failures.json with Sparkle's release key (keychain account "vitral", the same one
# that signs updates) and writes catalog/failures.signed.json, which Vitral downloads from GitHub.
# Publishing a catalog = committing and pushing that file (with Javier's go-ahead).
#
# Before: edit catalog/failures.json and raise its "revision" (YYYYMMDDnn). This script copies it
# into the code too (scripts/embed-catalog.py), so the next Vitral comes with it.
set -euo pipefail
root=${0:A:h:h}
cd "$root"
fail() { print -u2 -- "✗ $1"; exit 1; }

python3 scripts/embed-catalog.py >/dev/null
python3 - <<'PY' || exit 1
import base64, json, pathlib, sys
source = pathlib.Path("catalog/failures.json")
signed = pathlib.Path("catalog/failures.signed.json")
new = json.loads(source.read_text(encoding="utf-8"))
if signed.exists():
    old_bytes = base64.b64decode(json.loads(signed.read_text())["catalog"])
    old = json.loads(old_bytes)
    if old_bytes != source.read_bytes() and new["revision"] <= old["revision"]:
        sys.exit(f"✗ raise \"revision\" in catalog/failures.json (published: {old['revision']})")
PY
swift test -q --filter "Catalog|Diagnosis|Repair" >/dev/null 2>&1 || fail "the catalog's tests fail (swift test --filter Catalog)"

sparkle=$root/.build/xcode/SourcePackages/artifacts/sparkle/Sparkle/bin
[[ -x $sparkle/sign_update ]] || fail "Sparkle's tools are missing: build the app once with xcodebuild"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# A neutral name: sign_update changes files it takes for release notes.
cp catalog/failures.json "$tmp/catalog.data"
signature=$("$sparkle/sign_update" --account vitral -p "$tmp/catalog.data")
cmp -s catalog/failures.json "$tmp/catalog.data" || fail "sign_update changed the file"
python3 - "$signature" <<'PY'
import base64, json, pathlib, sys
data = pathlib.Path("catalog/failures.json").read_bytes()
out = {"catalog": base64.b64encode(data).decode(), "signature": sys.argv[1].strip()}
pathlib.Path("catalog/failures.signed.json").write_text(json.dumps(out, indent=2) + "\n")
PY
swift run -q vitral catalogo --verificar catalog/failures.signed.json
print "Listo. Para publicarlo: commit de catalog/ y Sources/VitralKit/Diagnosis/BuiltInCatalog.swift, y push."

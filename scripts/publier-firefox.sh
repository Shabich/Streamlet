#!/usr/bin/env bash
# Publie une version Firefox de Streamlet (pour les mainteneurs) / publish a Firefox release (maintainers).
#   1. signe l'extension chez Mozilla (clés dans .env : WEB_EXT_API_KEY, WEB_EXT_API_SECRET)
#   2. range le fichier signé dans web-ext-artifacts/streamlet-<version>.xpi
#   3. ajoute la version à updates.json (mises à jour automatiques de Firefox)
# Ensuite : commit + push de updates.json, puis Release GitHub v<version> avec le .xpi en pièce jointe.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

[[ -f .env ]] || { echo "✗ .env introuvable (WEB_EXT_API_KEY / WEB_EXT_API_SECRET)"; exit 1; }
set -a; source .env; set +a

VERSION="$(python3 -c 'import json; print(json.load(open("extension/manifest.json"))["version"])')"
ID="$(python3 -c 'import json; print(json.load(open("extension/manifest.json"))["browser_specific_settings"]["gecko"]["id"])')"
DEPOT="$(git remote get-url origin | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')"
XPI="web-ext-artifacts/streamlet-$VERSION.xpi"

if python3 -c "import json,sys; u=json.load(open('updates.json'))['addons']['$ID']['updates']; sys.exit(0 if any(x['version']=='$VERSION' for x in u) else 1)"; then
  echo "✗ la version $VERSION est déjà dans updates.json : augmente \"version\" dans extension/manifest.json"; exit 1
fi

echo "→ signature de la version $VERSION chez Mozilla (quelques minutes)…"
AVANT="$(ls web-ext-artifacts/*.xpi 2>/dev/null || true)"
npx --yes web-ext sign --source-dir extension --channel unlisted --artifacts-dir web-ext-artifacts --approval-timeout 900000
NOUVEAU="$(comm -13 <(echo "$AVANT" | sort) <(ls web-ext-artifacts/*.xpi | sort) | head -1)"
[[ -n "$NOUVEAU" ]] || { echo "✗ aucun fichier signé reçu"; exit 1; }
[[ "$NOUVEAU" == "$XPI" ]] || mv "$NOUVEAU" "$XPI"
echo "✓ signé : $XPI"

python3 - "$ID" "$VERSION" "https://github.com/$DEPOT/releases/download/v$VERSION/streamlet-$VERSION.xpi" <<'PY'
import json, sys
ident, version, lien = sys.argv[1:]
d = json.load(open("updates.json"))
d["addons"][ident]["updates"].append({"version": version, "update_link": lien})
json.dump(d, open("updates.json", "w"), indent=2); open("updates.json", "a").write("\n")
PY
echo "✓ updates.json : version $VERSION ajoutée"
echo
echo "Reste à faire :"
echo "  1. git add updates.json && git commit -m \"Firefox $VERSION\" && git push"
echo "  2. Release GitHub v$VERSION avec $XPI en pièce jointe (nom de fichier inchangé)"

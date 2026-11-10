#!/usr/bin/env bash
# Streamlet — installation pour macOS (Linux : install-linux.sh · Windows : install.ps1).
#   ./install-macos.sh               questionnaire : choisis ce qu'il faut installer, puis tout se lance
#   ./install-macos.sh --oui         sans questions, réglages recommandés (IA locale + Claude, durable)
# Options (sans questions) :
#   --ephemere                       serveur dans ce terminal (s'arrête quand on le ferme) au lieu de durable
#   --modele qwen3.5:2b              autre modèle Ollama
#   --sans-ollama                    sans IA locale (Claude uniquement)
#   --claude abonnement|api|aucun    accès à Claude (abonnement = via Claude Code)
set -euo pipefail

# ---------- Réglages par défaut (recommandés) ----------
AVEC_OLLAMA=1
MODELE="qwen3.5:4b"
CLAUDE_ACCES="abonnement"     # abonnement | api | aucun
INSTALLER_CLAUDE_CODE=0
CONNECTER_CLAUDE_CODE=0
EPHEMERE=0
QUESTIONNAIRE=1
ECRIRE_CONFIG=0

while [[ $# -gt 0 ]]; do
  QUESTIONNAIRE=0
  case "$1" in
    --oui|-y) ECRIRE_CONFIG=1; shift ;;
    --ephemere|--éphémère) EPHEMERE=1; shift ;;
    --modele) MODELE="${2:?--modele attend un nom de modèle}"; shift 2 ;;
    --sans-ollama) AVEC_OLLAMA=0; shift ;;
    --claude)
      CLAUDE_ACCES="${2:?--claude attend abonnement, api ou aucun}"; ECRIRE_CONFIG=1; shift 2
      [[ $CLAUDE_ACCES =~ ^(abonnement|api|aucun)$ ]] || { echo "--claude : abonnement, api ou aucun"; exit 1; } ;;
    -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Option inconnue : $1 (voir --help)"; exit 1 ;;
  esac
done
[[ -t 0 ]] || QUESTIONNAIRE=0   # pas de clavier (CI, pipe) : réglages par défaut

ICI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ICI"
ok()    { printf '\033[32m✓\033[0m %s\n' "$*"; }
info()  { printf '\033[34m→\033[0m %s\n' "$*"; }
avert() { printf '\033[33m!\033[0m %s\n' "$*"; }
ko()    { printf '\033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }
gras()  { printf '\033[1m%s\033[0m\n' "$*"; }

[[ "$(uname -s)" == Darwin ]] || ko "Ce script est pour macOS. Linux : ./install-linux.sh · Windows : install.ps1"

# ---------- Questionnaire ----------
# choix "Question" "option 1" "option 2" … → numéro choisi dans $REPONSE (1 = défaut, avec Entrée)
ETAPE=0
choix() {
  local question="$1"; shift
  local i=1 r
  ETAPE=$((ETAPE + 1))
  echo; gras "$ETAPE. $question"
  for opt in "$@"; do printf '  %d) %s\n' "$i" "$opt"; i=$((i + 1)); done
  while true; do
    read -r -p "Ton choix [1] : " r
    r="${r:-1}"
    if [[ "$r" =~ ^[0-9]+$ ]] && (( r >= 1 && r <= $# )); then REPONSE=$r; return; fi
    echo "  Réponds par un numéro entre 1 et $#."
  done
}
# oui_non "Question" → succès si oui (défaut : oui)
oui_non() {
  local r
  read -r -p "$1 [O/n] : " r
  [[ ! "$r" =~ ^[nN] ]]
}

claude_code_bin() {
  if command -v claude >/dev/null 2>&1; then command -v claude
  elif [[ -x "$HOME/.local/bin/claude" ]]; then echo "$HOME/.local/bin/claude"
  fi
}

if [[ $QUESTIONNAIRE == 1 ]]; then
  ECRIRE_CONFIG=1
  echo
  gras "Installation de Streamlet"
  echo "Quelques questions pour n'installer que ce dont tu as besoin (Entrée = choix recommandé)."

  choix "Quelle IA veux-tu utiliser ?" \
    "IA locale + Claude en secours (recommandé) : gratuit la plupart du temps, Claude prend le relais si besoin" \
    "IA locale uniquement : gratuit, rien ne sort de ta machine (quelques Go, machine correcte)" \
    "Claude uniquement : rien de lourd à installer, mais les questions sont envoyées à Anthropic"
  case $REPONSE in
    1) AVEC_OLLAMA=1; CLAUDE_ACCES="abonnement" ;;
    2) AVEC_OLLAMA=1; CLAUDE_ACCES="aucun" ;;
    3) AVEC_OLLAMA=0; CLAUDE_ACCES="abonnement" ;;
  esac

  if [[ $AVEC_OLLAMA == 1 ]]; then
    choix "Quel modèle local (via Ollama) ?" \
      "qwen3.5:4b (recommandé, ~4 Go)" \
      "qwen3.5:2b (plus léger, pour les machines modestes)" \
      "Un autre modèle Ollama (tu donnes son nom)"
    case $REPONSE in
      1) MODELE="qwen3.5:4b" ;;
      2) MODELE="qwen3.5:2b" ;;
      3) read -r -p "Nom du modèle (ex. qwen3.5:9b) : " MODELE; MODELE="${MODELE:-qwen3.5:4b}" ;;
    esac
  fi

  if [[ $CLAUDE_ACCES != "aucun" ]]; then
    choix "Comment accéder à Claude ?" \
      "Avec mon abonnement claude.ai (Pro / Max), via Claude Code : pas de frais en plus" \
      "Avec une clé API Anthropic : payée à l'usage, à coller ensuite dans la popup de l'extension"
    if [[ $REPONSE == 1 ]]; then CLAUDE_ACCES="abonnement"; else CLAUDE_ACCES="api"; fi

    if [[ $CLAUDE_ACCES == "abonnement" ]]; then
      CC="$(claude_code_bin)"
      if [[ -z "$CC" ]]; then
        echo; avert "Claude Code n'est pas installé : il est nécessaire pour utiliser ton abonnement."
        if oui_non "  L'installer maintenant ?"; then INSTALLER_CLAUDE_CODE=1; CONNECTER_CLAUDE_CODE=1; fi
      elif ! "$CC" auth status 2>/dev/null | grep -q '"authMethod": *"claude.ai"'; then
        echo; avert "Claude Code est installé mais pas connecté à ton abonnement."
        if oui_non "  Te connecter maintenant (ouvre le navigateur) ?"; then CONNECTER_CLAUDE_CODE=1; fi
      else
        ok "Claude Code est déjà connecté à ton abonnement."
      fi
    fi
  fi

  choix "Comment faire tourner le serveur local de Streamlet ?" \
    "Durable (recommandé) : en tâche de fond, démarre avec ta session, tu peux fermer le terminal" \
    "Éphémère : dans ce terminal, il s'arrête quand tu le fermes (à relancer à chaque fois)"
  if [[ $REPONSE == 2 ]]; then EPHEMERE=1; else EPHEMERE=0; fi
fi

# Moteur par défaut de l'extension, d'après les choix
if [[ $AVEC_OLLAMA == 1 && $CLAUDE_ACCES != "aucun" ]]; then MOTEUR="auto"
elif [[ $AVEC_OLLAMA == 1 ]]; then MOTEUR="local"
elif [[ $CLAUDE_ACCES != "aucun" ]]; then MOTEUR="claude"
else ko "Il faut au moins une IA : l'IA locale (Ollama) ou Claude."
fi

if [[ $QUESTIONNAIRE == 1 ]]; then
  echo; gras "Récapitulatif"
  if [[ $AVEC_OLLAMA == 1 ]]; then echo "  IA locale : Ollama + $MODELE"; else echo "  IA locale : non"; fi
  case $CLAUDE_ACCES in
    abonnement)
      A_FAIRE=""
      [[ $INSTALLER_CLAUDE_CODE == 1 ]] && A_FAIRE=", installé et connecté par ce script"
      [[ $INSTALLER_CLAUDE_CODE == 0 && $CONNECTER_CLAUDE_CODE == 1 ]] && A_FAIRE=", connecté par ce script"
      echo "  Claude    : via ton abonnement (Claude Code$A_FAIRE), modèle à choisir dans la popup" ;;
    api) echo "  Claude    : via clé API (à coller dans la popup), modèle à choisir dans la popup" ;;
    aucun) echo "  Claude    : non" ;;
  esac
  echo "  Moteur    : $MOTEUR"
  if [[ $EPHEMERE == 1 ]]; then echo "  Serveur   : éphémère (dans ce terminal)"; else echo "  Serveur   : durable (tâche de fond)"; fi
  echo
  oui_non "Lancer l'installation ?" || { echo "Installation annulée."; exit 0; }
fi
echo

# ---------- Python ----------
trouver_python() {
  PY=""
  for c in python3 python; do
    if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import sys; sys.exit(sys.version_info < (3, 10))' 2>/dev/null; then
      PY="$c"; return 0
    fi
  done
  return 1
}
if ! trouver_python; then
  # Le python3 fourni par Apple (outils de développement) est trop ancien : on passe par Homebrew.
  if command -v brew >/dev/null 2>&1; then
    info "Installation de Python avec Homebrew…"
    brew install python
    trouver_python || ko "Python installé mais introuvable : ouvre un nouveau terminal et relance ce script."
  else
    ko "Python 3.10+ introuvable. Installe-le depuis https://www.python.org/downloads/ (ou avec Homebrew : https://brew.sh), puis relance ce script."
  fi
fi
ok "Python : $($PY --version)"

# ---------- Ollama ----------
ollama_repond() { curl -fsS --max-time 2 http://127.0.0.1:11434/api/version >/dev/null 2>&1; }

if [[ $AVEC_OLLAMA == 1 ]]; then
  if ! command -v ollama >/dev/null 2>&1 && [[ ! -d /Applications/Ollama.app ]]; then
    info "Installation d'Ollama…"
    TMP="$(mktemp -d)"
    curl -fL --progress-bar -o "$TMP/Ollama.zip" https://ollama.com/download/Ollama-darwin.zip
    unzip -q "$TMP/Ollama.zip" -d "$TMP"
    # /Applications est en général modifiable sans mot de passe ; sinon, sudo le demande.
    mv "$TMP/Ollama.app" /Applications/ 2>/dev/null || sudo mv "$TMP/Ollama.app" /Applications/
    rm -rf "$TMP"
  fi
  ok "Ollama installé"
  OLLAMA_BIN="$(command -v ollama || echo /Applications/Ollama.app/Contents/Resources/ollama)"

  if ! ollama_repond; then
    info "Démarrage d'Ollama…"
    if [[ -d /Applications/Ollama.app ]]; then
      open -ga Ollama   # l'appli se lance aussi à chaque ouverture de session
    else
      nohup "$OLLAMA_BIN" serve >/dev/null 2>&1 &
    fi
    for _ in $(seq 1 30); do ollama_repond && break; sleep 1; done
    ollama_repond || ko "Ollama ne répond pas sur http://127.0.0.1:11434 : ouvre l'application Ollama, puis relance ce script."
  fi
  ok "Ollama actif"

  info "Téléchargement du modèle $MODELE (plusieurs Go la première fois)…"
  "$OLLAMA_BIN" pull "$MODELE"
  ok "Modèle $MODELE prêt"
else
  info "Ollama ignoré : seul le moteur « En ligne » (Claude) sera disponible."
fi

# ---------- Claude Code (abonnement) ----------
if [[ $INSTALLER_CLAUDE_CODE == 1 ]]; then
  info "Installation de Claude Code…"
  curl -fsSL https://claude.ai/install.sh | bash
  [[ -n "$(claude_code_bin)" ]] || ko "Claude Code installé mais introuvable : ouvre un nouveau terminal et relance ce script."
  ok "Claude Code installé"
fi
if [[ $CONNECTER_CLAUDE_CODE == 1 ]]; then
  info "Connexion de Claude Code à ton abonnement (une page va s'ouvrir dans le navigateur)…"
  if "$(claude_code_bin)" auth login --claudeai; then
    ok "Claude Code connecté"
  else
    avert "Connexion non terminée : tu pourras la faire plus tard avec « claude auth login »."
  fi
fi

# ---------- Environnement Python ----------
# Un .venv sans pip (création interrompue) est recréé.
if [[ -x .venv/bin/python ]] && ! .venv/bin/python -m pip --version >/dev/null 2>&1; then
  avert "Environnement .venv incomplet (pip absent) : il est recréé."
  rm -rf .venv
fi
if [[ ! -x .venv/bin/python ]]; then
  info "Création de l'environnement Python (.venv)…"
  if ! "$PY" -m venv .venv; then
    rm -rf .venv   # ne pas laisser un .venv à moitié créé
    ko "Échec de « python -m venv ». Réinstalle Python (brew reinstall python, ou python.org), puis relance ce script."
  fi
fi
.venv/bin/python -m pip install --quiet --upgrade pip
.venv/bin/python -m pip install --quiet -r requirements.txt
ok "Dépendances Python installées"

# ---------- Réglages de l'extension (moteur et accès Claude ; le modèle Claude se choisit dans la popup) ----------
if [[ $ECRIRE_CONFIG == 1 ]]; then
  ACCES_CONFIG="$CLAUDE_ACCES"; [[ $ACCES_CONFIG == "aucun" ]] && ACCES_CONFIG="abonnement"
  .venv/bin/python - "$MOTEUR" "$ACCES_CONFIG" <<'EOF'
import json, sys
from pathlib import Path
f = Path.home() / ".shabcode" / "qcm_config.json"
try:
    config = json.loads(f.read_text())
except (OSError, ValueError):
    config = {}
config.update(mode=sys.argv[1], acces_claude=sys.argv[2])
f.parent.mkdir(parents=True, exist_ok=True)
f.write_text(json.dumps(config))
EOF
  ok "Réglages enregistrés (moteur $MOTEUR), modifiables à tout moment dans la popup"
fi

# ---------- Serveur ----------
OPTIONS=""
if [[ "$MODELE" != "qwen3.5:4b" ]]; then OPTIONS="--modele $MODELE --modele-rapide $MODELE"; fi
ETAPES="  1. Charge l'extension (dossier extension/, voir le README) :
       Chrome / Edge / Brave : chrome://extensions › Mode développeur › « Charger l'extension non empaquetée »
       Firefox : about:debugging › Ce Firefox › « Charger un module complémentaire temporaire » › manifest.json"
if [[ $CLAUDE_ACCES == "api" ]]; then
  ETAPES="$ETAPES
  2. Colle ta clé API dans la popup de l'extension (section Claude › Clé API)"
fi

echo
if [[ $EPHEMERE == 1 ]]; then
  # Commande complète (avec le dossier) : elle marche depuis n'importe quel terminal.
  RELANCER="cd \"$ICI\" && .venv/bin/python serveur_qcm.py${OPTIONS:+ $OPTIONS}"
  relancer() {
    echo
    gras "Pour relancer Streamlet plus tard, copie cette commande dans un terminal :"
    echo
    echo "    $RELANCER"
    echo
  }
  ok "Installation terminée (éphémère)."
  echo "$ETAPES"
  relancer
  echo "Le serveur démarre ci-dessous : garde ce terminal ouvert. Ctrl+C ou fermer le terminal l'arrête."
  echo
  # shellcheck disable=SC2086
  .venv/bin/python serveur_qcm.py $OPTIONS || true
  relancer   # rappel à l'arrêt du serveur (Ctrl+C)
else
  # shellcheck disable=SC2086
  .venv/bin/python serveur_qcm.py --installer $OPTIONS
  ok "Installation terminée (durable) : tu peux fermer ce terminal."
  echo "$ETAPES"
  echo "  Arrêter et retirer la tâche de fond : .venv/bin/python serveur_qcm.py --desinstaller"
fi

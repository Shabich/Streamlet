#!/usr/bin/env bash
# Streamlet — installation pour Linux / installer for Linux  (macOS : install-macos.sh · Windows : install.ps1)
# Ce qui manque au système est installé avec sudo / missing system packages are installed with sudo.
#   ./install-linux.sh               questionnaire / interactive questions
#   ./install-linux.sh --yes         sans questions, réglages par défaut / no questions, default settings
# Options (sans questions / no questions) :
#   --lang en|fr                     langue des messages / message language (auto-detected)
#   --ephemeral (--ephemere)         serveur dans ce terminal / server in this terminal instead of background
#   --with-ollama (--avec-ollama)    ajoute l'IA locale / add the local AI (Ollama)
#   --model qwen3.5:2b (--modele)    modèle Ollama / Ollama model (implies --with-ollama)
#   --claude subscription|api|none   accès à Claude / Claude access (abonnement|api|aucun)
#   --firefox                        installe aussi l'extension dans Firefox / also install the extension in Firefox
set -euo pipefail

# ---------- Langue / language ----------
LANGUE=en
case "${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}" in fr*) LANGUE=fr ;; esac

for a in "$@"; do
  case "$a" in --lang=fr|--langue=fr) LANGUE=fr ;; --lang=en|--langue=en) LANGUE=en ;; esac
done
prev=""
for a in "$@"; do
  if [[ $prev == --lang || $prev == --langue ]]; then [[ $a == fr ]] && LANGUE=fr || LANGUE=en; fi
  prev="$a"
done
# L "texte français" "English text" → le texte dans la langue choisie
L() { if [[ $LANGUE == fr ]]; then printf '%s' "$1"; else printf '%s' "$2"; fi; }

# ---------- Réglages par défaut ----------
AVEC_OLLAMA=0
MODELE="qwen3.5:4b"
CLAUDE_ACCES="abonnement"     # abonnement | api | aucun
INSTALLER_CLAUDE_CODE=0
CONNECTER_CLAUDE_CODE=0
EPHEMERE=0
INSTALLER_FIREFOX=0
QUESTIONNAIRE=1
ECRIRE_CONFIG=0

while [[ $# -gt 0 ]]; do
  QUESTIONNAIRE=0
  case "$1" in
    --lang|--langue) shift 2 ;;
    --lang=*|--langue=*) shift ;;
    --yes|--oui|-y) ECRIRE_CONFIG=1; shift ;;
    --ephemeral|--ephemere|--éphémère) EPHEMERE=1; shift ;;
    --with-ollama|--avec-ollama) AVEC_OLLAMA=1; shift ;;
    --firefox) INSTALLER_FIREFOX=1; shift ;;
    --without-ollama|--sans-ollama) AVEC_OLLAMA=0; shift ;;
    --model|--modele) MODELE="${2:?$(L "--modele attend un nom de modèle" "--model needs a model name")}"; AVEC_OLLAMA=1; shift 2 ;;
    --claude)
      case "${2:-}" in
        subscription|abonnement) CLAUDE_ACCES="abonnement" ;;
        api) CLAUDE_ACCES="api" ;;
        none|aucun) CLAUDE_ACCES="aucun" ;;
        *) echo "--claude : subscription|api|none"; exit 1 ;;
      esac
      ECRIRE_CONFIG=1; shift 2 ;;
    -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    *) echo "$(L "Option inconnue" "Unknown option") : $1 (--help)"; exit 1 ;;
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

[[ "$(uname -s)" == Linux ]] || ko "$(L "Ce script est pour Linux. macOS : ./install-macos.sh · Windows : install.ps1" "This script is for Linux. macOS: ./install-macos.sh · Windows: install.ps1")"

# Installe des paquets système avec le gestionnaire de la distribution (demande le mot de passe sudo).
#   installer_paquets <apt> <dnf> <pacman> <zypper>   (noms des paquets, séparés par des espaces)
installer_paquets() {
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update -qq || true
    # shellcheck disable=SC2086
    sudo apt-get install -y $1
  elif command -v dnf >/dev/null 2>&1; then
    # shellcheck disable=SC2086
    sudo dnf install -y $2
  elif command -v pacman >/dev/null 2>&1; then
    # shellcheck disable=SC2086
    sudo pacman -S --needed --noconfirm $3
  elif command -v zypper >/dev/null 2>&1; then
    # shellcheck disable=SC2086
    sudo zypper install -y $4
  else
    return 1
  fi
}

firefox_present() { command -v firefox >/dev/null 2>&1; }
# Dossier Téléchargements de l'utilisateur : Firefox en snap (Ubuntu) ne voit pas /tmp.
dossier_telechargements() { local d; d="$(xdg-user-dir DOWNLOAD 2>/dev/null || true)"; [[ -n "$d" && "$d" != "$HOME" ]] || d="$HOME/Downloads"; mkdir -p "$d"; echo "$d"; }
ouvrir_dans_firefox() { nohup firefox "$1" >/dev/null 2>&1 & }

# curl sert à télécharger Ollama et Claude Code (absent de certaines installations minimales).
if ! command -v curl >/dev/null 2>&1; then
  info "$(L "Installation de curl (demande sudo)…" "Installing curl (asks for sudo)…")"
  installer_paquets curl curl curl curl || ko "$(L "curl est introuvable : installe-le, puis relance ce script." "curl not found: install it, then run this script again.")"
fi

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
    read -r -p "$(L "Ton choix" "Your choice") [1] : " r
    r="${r:-1}"
    if [[ "$r" =~ ^[0-9]+$ ]] && (( r >= 1 && r <= $# )); then REPONSE=$r; return; fi
    echo "  $(L "Réponds par un numéro entre 1 et" "Answer with a number between 1 and") $#."
  done
}
# oui_non "Question" → succès si oui (défaut : oui)
oui_non() {
  local r
  read -r -p "$1 $(L "[O/n]" "[Y/n]") : " r
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
  gras "$(L "Installation de Streamlet" "Streamlet setup")"
  L "Quelques questions pour n'installer que ce dont tu as besoin (Entrée = choix par défaut)." \
    "A few questions to install only what you need (Enter = default choice)."; echo

  choix "$(L "Quelle IA veux-tu utiliser ?" "Which AI do you want to use?")" \
    "$(L "Claude uniquement : rien de lourd à installer, rapide (les questions sont envoyées à Anthropic)" \
         "Claude only: nothing heavy to install, fast (questions are sent to Anthropic)")" \
    "$(L "IA locale + Claude en secours : gratuit la plupart du temps (Ollama, quelques Go, machine correcte)" \
         "Local AI + Claude as fallback: free most of the time (Ollama, a few GB, a decent computer)")" \
    "$(L "IA locale uniquement : gratuit, rien ne sort de ta machine (Ollama, quelques Go, machine correcte)" \
         "Local AI only: free, nothing leaves your computer (Ollama, a few GB, a decent computer)")"
  case $REPONSE in
    1) AVEC_OLLAMA=0; CLAUDE_ACCES="abonnement" ;;
    2) AVEC_OLLAMA=1; CLAUDE_ACCES="abonnement" ;;
    3) AVEC_OLLAMA=1; CLAUDE_ACCES="aucun" ;;
  esac

  if [[ $AVEC_OLLAMA == 1 ]]; then
    choix "$(L "Quel modèle local (via Ollama) ?" "Which local model (via Ollama)?")" \
      "$(L "qwen3.5:4b (par défaut, ~4 Go)" "qwen3.5:4b (default, ~4 GB)")" \
      "$(L "qwen3.5:2b (plus léger, pour les machines modestes)" "qwen3.5:2b (lighter, for modest computers)")" \
      "$(L "Un autre modèle Ollama (tu donnes son nom)" "Another Ollama model (you type its name)")"
    case $REPONSE in
      1) MODELE="qwen3.5:4b" ;;
      2) MODELE="qwen3.5:2b" ;;
      3) read -r -p "$(L "Nom du modèle (ex. qwen3.5:9b)" "Model name (e.g. qwen3.5:9b)") : " MODELE; MODELE="${MODELE:-qwen3.5:4b}" ;;
    esac
  fi

  if [[ $CLAUDE_ACCES != "aucun" ]]; then
    choix "$(L "Comment accéder à Claude ?" "How do you want to access Claude?")" \
      "$(L "Avec mon abonnement claude.ai (Pro / Max), via Claude Code : pas de frais en plus" \
           "With my claude.ai subscription (Pro / Max), via Claude Code: no extra cost")" \
      "$(L "Avec une clé API Anthropic : payée à l'usage, à coller ensuite dans la popup de l'extension" \
           "With an Anthropic API key: pay as you go, to paste later in the extension popup")"
    if [[ $REPONSE == 1 ]]; then CLAUDE_ACCES="abonnement"; else CLAUDE_ACCES="api"; fi

    if [[ $CLAUDE_ACCES == "abonnement" ]]; then
      CC="$(claude_code_bin)"
      if [[ -z "$CC" ]]; then
        echo; avert "$(L "Claude Code n'est pas installé : il est nécessaire pour utiliser ton abonnement." \
                         "Claude Code is not installed: it is needed to use your subscription.")"
        if oui_non "  $(L "L'installer maintenant ?" "Install it now?")"; then INSTALLER_CLAUDE_CODE=1; CONNECTER_CLAUDE_CODE=1; fi
      elif ! "$CC" auth status 2>/dev/null | grep -q '"authMethod": *"claude.ai"'; then
        echo; avert "$(L "Claude Code est installé mais pas connecté à ton abonnement." \
                         "Claude Code is installed but not signed in to your subscription.")"
        if oui_non "  $(L "Te connecter maintenant (ouvre le navigateur) ?" "Sign in now (opens the browser)?")"; then CONNECTER_CLAUDE_CODE=1; fi
      else
        ok "$(L "Claude Code est déjà connecté à ton abonnement." "Claude Code is already signed in to your subscription.")"
      fi
    fi
  fi

  choix "$(L "Comment faire tourner le serveur local de Streamlet ?" "How should Streamlet's local server run?")" \
    "$(L "Durable (par défaut) : en tâche de fond, démarre avec ta session, tu peux fermer le terminal" \
         "Persistent (default): in the background, starts with your session, you can close the terminal")" \
    "$(L "Éphémère : dans ce terminal, il s'arrête quand tu le fermes (à relancer à chaque fois)" \
         "Ephemeral: in this terminal, it stops when you close it (start it again each time)")"
  if [[ $REPONSE == 2 ]]; then EPHEMERE=1; else EPHEMERE=0; fi

  if firefox_present; then
    echo
    if oui_non "$(L "Firefox est installé : y ajouter l'extension Streamlet (version signée) ?" "Firefox is installed: add the Streamlet extension to it (signed version)?")"; then
      INSTALLER_FIREFOX=1
    fi
  fi
fi

# Moteur par défaut de l'extension, d'après les choix
if [[ $AVEC_OLLAMA == 1 && $CLAUDE_ACCES != "aucun" ]]; then MOTEUR="auto"
elif [[ $AVEC_OLLAMA == 1 ]]; then MOTEUR="local"
elif [[ $CLAUDE_ACCES != "aucun" ]]; then MOTEUR="claude"
else ko "$(L "Il faut au moins une IA : Claude ou l'IA locale (--with-ollama)." "At least one AI is needed: Claude or the local AI (--with-ollama).")"
fi

if [[ $QUESTIONNAIRE == 1 ]]; then
  echo; gras "$(L "Récapitulatif" "Summary")"
  if [[ $AVEC_OLLAMA == 1 ]]; then echo "  $(L "IA locale" "Local AI ") : Ollama + $MODELE"; else echo "  $(L "IA locale" "Local AI ") : $(L "non" "no")"; fi
  case $CLAUDE_ACCES in
    abonnement)
      A_FAIRE=""
      [[ $INSTALLER_CLAUDE_CODE == 1 ]] && A_FAIRE="$(L ", installé et connecté par ce script" ", installed and signed in by this script")"
      [[ $INSTALLER_CLAUDE_CODE == 0 && $CONNECTER_CLAUDE_CODE == 1 ]] && A_FAIRE="$(L ", connecté par ce script" ", signed in by this script")"
      echo "  Claude    : $(L "via ton abonnement" "via your subscription") (Claude Code$A_FAIRE), $(L "modèle à choisir dans la popup" "model to pick in the popup")" ;;
    api) echo "  Claude    : $(L "via clé API (à coller dans la popup), modèle à choisir dans la popup" "via API key (to paste in the popup), model to pick in the popup")" ;;
    aucun) echo "  Claude    : $(L "non" "no")" ;;
  esac
  echo "  $(L "Moteur" "Engine")    : $MOTEUR"
  if [[ $EPHEMERE == 1 ]]; then echo "  $(L "Serveur" "Server ")   : $(L "éphémère (dans ce terminal)" "ephemeral (in this terminal)")"
  else echo "  $(L "Serveur" "Server ")   : $(L "durable (tâche de fond)" "persistent (background)")"; fi
  if [[ $INSTALLER_FIREFOX == 1 ]]; then echo "  Firefox   : $(L "extension téléchargée et ouverte dans Firefox" "extension downloaded and opened in Firefox")"; fi
  echo
  oui_non "$(L "Lancer l'installation ?" "Start the installation?")" || { L "Installation annulée." "Installation cancelled."; echo; exit 0; }
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
  info "$(L "Installation de Python (demande sudo)…" "Installing Python (asks for sudo)…")"
  installer_paquets "python3 python3-venv" python3 python python3 \
    || ko "$(L "Impossible d'installer Python automatiquement : installe Python 3.10+ avec le gestionnaire de paquets de ta distribution, puis relance ce script." \
               "Could not install Python automatically: install Python 3.10+ with your distribution's package manager, then run this script again.")"
  trouver_python || ko "$(L "Python 3.10+ introuvable après installation : ta distribution fournit peut-être une version trop ancienne." \
                           "Python 3.10+ not found after installation: your distribution may ship an older version.")"
fi
ok "Python : $($PY --version)"

# Debian / Ubuntu : venv et pip ne sont pas livrés avec Python, ils sont dans le paquet python3-venv.
if ! "$PY" -c 'import venv, ensurepip' >/dev/null 2>&1; then
  VER="$("$PY" -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
  if command -v apt-get >/dev/null 2>&1; then
    info "$(L "Installation de python3-venv (venv et pip sont fournis à part sur Debian/Ubuntu ; demande sudo)…" \
              "Installing python3-venv (venv and pip are shipped separately on Debian/Ubuntu; asks for sudo)…")"
    sudo apt-get update -qq || true
    sudo apt-get install -y python3-venv "python${VER}-venv" || sudo apt-get install -y python3-venv \
      || ko "$(L "Échec de l'installation de python3-venv. Lance : sudo apt install python3-venv, puis relance ce script." \
                 "Could not install python3-venv. Run: sudo apt install python3-venv, then run this script again.")"
  else
    ko "$(L "Le module venv de Python est absent. Installe le paquet python3-venv (ou son équivalent sur ta distribution), puis relance ce script." \
            "Python's venv module is missing. Install the python3-venv package (or your distribution's equivalent), then run this script again.")"
  fi
  "$PY" -c 'import venv, ensurepip' >/dev/null 2>&1 \
    || ko "$(L "Le module venv est toujours absent. Lance : sudo apt install python${VER}-venv, puis relance ce script." \
               "The venv module is still missing. Run: sudo apt install python${VER}-venv, then run this script again.")"
  ok "$(L "python3-venv installé" "python3-venv installed")"
fi

# ---------- Ollama ----------
ollama_repond() { curl -fsS --max-time 2 http://127.0.0.1:11434/api/version >/dev/null 2>&1; }

if [[ $AVEC_OLLAMA == 1 ]]; then
  if ! command -v ollama >/dev/null 2>&1; then
    info "$(L "Installation d'Ollama (script officiel, demande sudo)…" "Installing Ollama (official script, asks for sudo)…")"
    curl -fsSL https://ollama.com/install.sh | sh   # installe le binaire et un service systemd
  fi
  ok "$(L "Ollama installé" "Ollama installed")"
  OLLAMA_BIN="ollama"

  if ! ollama_repond; then
    info "$(L "Démarrage d'Ollama…" "Starting Ollama…")"
    if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files ollama.service >/dev/null 2>&1; then
      sudo systemctl enable --now ollama || true   # service système : démarre aussi au boot
    fi
    if ! ollama_repond; then
      nohup ollama serve >/dev/null 2>&1 &
    fi
    for _ in $(seq 1 30); do ollama_repond && break; sleep 1; done
    ollama_repond || ko "$(L "Ollama ne répond pas sur http://127.0.0.1:11434 : lance « ollama serve », puis relance ce script." \
                             "Ollama is not responding on http://127.0.0.1:11434: run “ollama serve”, then run this script again.")"
  fi
  ok "$(L "Ollama actif" "Ollama running")"

  info "$(L "Téléchargement du modèle $MODELE (plusieurs Go la première fois)…" "Downloading the $MODELE model (several GB the first time)…")"
  "$OLLAMA_BIN" pull "$MODELE"
  ok "$(L "Modèle $MODELE prêt" "Model $MODELE ready")"
else
  info "$(L "Pas d'IA locale (Ollama non installé) : moteur « En ligne » (Claude)." "No local AI (Ollama not installed): “Online” engine (Claude).")"
fi

# ---------- Claude Code (abonnement) ----------
if [[ $INSTALLER_CLAUDE_CODE == 1 ]]; then
  info "$(L "Installation de Claude Code…" "Installing Claude Code…")"
  curl -fsSL https://claude.ai/install.sh | bash
  [[ -n "$(claude_code_bin)" ]] || ko "$(L "Claude Code installé mais introuvable : ouvre un nouveau terminal et relance ce script." "Claude Code installed but not found: open a new terminal and run this script again.")"
  ok "$(L "Claude Code installé" "Claude Code installed")"
fi
if [[ $CONNECTER_CLAUDE_CODE == 1 ]]; then
  info "$(L "Connexion de Claude Code à ton abonnement (une page va s'ouvrir dans le navigateur)…" "Signing Claude Code in to your subscription (a page will open in the browser)…")"
  if "$(claude_code_bin)" auth login --claudeai; then
    ok "$(L "Claude Code connecté" "Claude Code signed in")"
  else
    avert "$(L "Connexion non terminée : tu pourras la faire plus tard avec « claude auth login »." "Sign-in not finished: you can do it later with “claude auth login”.")"
  fi
fi

# ---------- Environnement Python ----------
# Un .venv sans pip (création interrompue, par ex. un ancien essai sans python3-venv) est recréé.
if [[ -x .venv/bin/python ]] && ! .venv/bin/python -m pip --version >/dev/null 2>&1; then
  avert "$(L "Environnement .venv incomplet (pip absent) : il est recréé." "Incomplete .venv environment (pip missing): recreating it.")"
  rm -rf .venv
fi
if [[ ! -x .venv/bin/python ]]; then
  info "$(L "Création de l'environnement Python (.venv)…" "Creating the Python environment (.venv)…")"
  if ! "$PY" -m venv .venv; then
    rm -rf .venv   # ne pas laisser un .venv à moitié créé
    ko "$(L "Échec de « python -m venv ». Sous Debian/Ubuntu : sudo apt install python3-venv, puis relance ce script." "“python -m venv” failed. On Debian/Ubuntu: sudo apt install python3-venv, then run this script again.")"
  fi
fi
.venv/bin/python -m pip install --quiet --upgrade pip
.venv/bin/python -m pip install --quiet -r requirements.txt
ok "$(L "Dépendances Python installées" "Python dependencies installed")"

# ---------- Réglages de l'extension (moteur et accès Claude ; le modèle Claude se choisit dans la popup) ----------
if [[ $ECRIRE_CONFIG == 1 ]]; then
  ACCES_CONFIG="$CLAUDE_ACCES"; [[ $ACCES_CONFIG == "aucun" ]] && ACCES_CONFIG="abonnement"
  .venv/bin/python - "$MOTEUR" "$ACCES_CONFIG" <<'EOF'
import json, sys
from pathlib import Path
f = Path.home() / ".streamlet" / "config.json"
ancien = Path.home() / ".shabcode" / "qcm_config.json"   # versions 1.0 et avant
try:
    config = json.loads((f if f.exists() else ancien).read_text())
except (OSError, ValueError):
    config = {}
config.update(mode=sys.argv[1], acces_claude=sys.argv[2])
f.parent.mkdir(parents=True, exist_ok=True)
f.write_text(json.dumps(config))
EOF
  ok "$(L "Réglages enregistrés (moteur $MOTEUR), modifiables à tout moment dans la popup" "Settings saved ($MOTEUR engine), you can change them anytime in the popup")"
fi

# ---------- Extension Firefox (version signée de la Release GitHub) ----------
if [[ $INSTALLER_FIREFOX == 1 ]]; then
  if ! firefox_present; then
    avert "$(L "Firefox introuvable : extension non installée." "Firefox not found: extension not installed.")"
  else
    VERSION_EXT="$("$PY" -c 'import json; print(json.load(open("extension/manifest.json"))["version"])')"
    DEPOT="$(git remote get-url origin 2>/dev/null | sed -nE 's#^(https://github.com/|git@github.com:)([^/]+/[^/.]+)(\.git)?/?$#\2#p')"
    DEPOT="${DEPOT:-Shabich/Streamlet}"
    DOSSIER_XPI="$(dossier_telechargements)"
    XPI="$DOSSIER_XPI/streamlet-$VERSION_EXT.xpi"
    info "$(L "Téléchargement de l'extension signée ${VERSION_EXT}…" "Downloading the signed extension ${VERSION_EXT}…")"
    if ! curl -fsSL -o "$XPI" "https://github.com/$DEPOT/releases/download/v$VERSION_EXT/streamlet-$VERSION_EXT.xpi"; then
      # Pas de Release pour cette version (code plus récent que la dernière publication) : on prend la dernière.
      LIEN="$(curl -fsSL "https://api.github.com/repos/$DEPOT/releases/latest" 2>/dev/null | "$PY" -c '
import json, sys
try:
    print(next(a["browser_download_url"] for a in json.load(sys.stdin)["assets"] if a["name"].endswith(".xpi")))
except Exception:
    pass')"
      XPI="$DOSSIER_XPI/streamlet.xpi"
      [[ -n "$LIEN" ]] && curl -fsSL -o "$XPI" "$LIEN" || XPI=""
    fi
    # Vérification : une archive valide, signée par Mozilla.
    if [[ -n "$XPI" ]] && "$PY" -c 'import sys, zipfile; z = zipfile.ZipFile(sys.argv[1]); sys.exit(0 if "META-INF/mozilla.rsa" in z.namelist() else 1)' "$XPI" 2>/dev/null; then
      ok "$(L "Extension téléchargée" "Extension downloaded") : $XPI"
      ouvrir_dans_firefox "$XPI"
      info "$(L "Dans Firefox, clique sur « Ajouter » pour installer Streamlet (elle se mettra ensuite à jour toute seule)." "In Firefox, click “Add” to install Streamlet (it then updates itself).")"
    else
      if [[ -n "$XPI" && -f "$XPI" ]]; then rm -f -- "$XPI"; fi  # fichier invalide : on ne le laisse pas traîner
      avert "$(L "Impossible de récupérer l'extension signée : installe-la depuis https://github.com/$DEPOT/releases" "Could not get the signed extension: install it from https://github.com/$DEPOT/releases")"
    fi
  fi
fi

# ---------- Serveur ----------
OPTIONS=""
if [[ $AVEC_OLLAMA == 1 && "$MODELE" != "qwen3.5:4b" ]]; then OPTIONS="--modele $MODELE --modele-rapide $MODELE"; fi
ETAPES="  1. $(L "Charge l'extension (dossier extension/, voir le README) :" "Load the extension (extension/ folder, see the README):")
       Chrome / Edge / Brave : chrome://extensions › $(L "Mode développeur › « Charger l'extension non empaquetée »" "Developer mode › “Load unpacked”")
       Firefox : $(L "installe le .xpi signé des Releases GitHub, ou about:debugging › Ce Firefox › « Charger un module complémentaire temporaire »" "install the signed .xpi from the GitHub Releases, or about:debugging › This Firefox › “Load Temporary Add-on”")"
if [[ $CLAUDE_ACCES == "api" ]]; then
  ETAPES="$ETAPES
  2. $(L "Colle ta clé API dans la popup de l'extension (section Claude › Clé API)" "Paste your API key in the extension popup (Claude section › API key)")"
fi

echo
if [[ $EPHEMERE == 1 ]]; then
  # Commande complète (avec le dossier) : elle marche depuis n'importe quel terminal.
  RELANCER="cd \"$ICI\" && .venv/bin/python serveur_qcm.py${OPTIONS:+ $OPTIONS}"
  relancer() {
    echo
    gras "$(L "Pour relancer Streamlet plus tard, copie cette commande dans un terminal :" "To start Streamlet again later, copy this command into a terminal:")"
    echo
    echo "    $RELANCER"
    echo
  }
  ok "$(L "Installation terminée (éphémère)." "Installation complete (ephemeral).")"
  echo "$ETAPES"
  relancer
  L "Le serveur démarre ci-dessous : garde ce terminal ouvert. Ctrl+C ou fermer le terminal l'arrête." \
    "The server starts below: keep this terminal open. Ctrl+C or closing the terminal stops it."; echo
  echo
  # shellcheck disable=SC2086
  .venv/bin/python serveur_qcm.py $OPTIONS || true
  relancer   # rappel à l'arrêt du serveur (Ctrl+C)
else
  # shellcheck disable=SC2086
  .venv/bin/python serveur_qcm.py --installer $OPTIONS
  ok "$(L "Installation terminée (durable) : tu peux fermer ce terminal." "Installation complete (persistent): you can close this terminal.")"
  echo "$ETAPES"
  echo "  $(L "Arrêter et retirer la tâche de fond" "Stop and remove the background service") : .venv/bin/python serveur_qcm.py --desinstaller"
fi

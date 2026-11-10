"""
Serveur local pour l'extension « Streamlet » (dossier extension/).

L'extension envoie la question de QCM de l'onglet coché (texte + position des choix).
Le serveur demande un indice qui aide SANS donner la réponse, puis enregistre :
  qcm.json              question, choix avec positions, indice (sans doublons)
  raisonnements.jsonl   le raisonnement du modèle, une ligne JSON par QCM
Les deux sont purgés des entrées de plus de 24 h (--conservation).

Moteurs (choisis dans la popup de l'extension) :
  local     Qwen via Ollama, sur ta machine
  auto      Qwen d'abord ; Claude si Qwen est trop lent (--delai-local), échoue ou est arrêté
  claude    Claude (en ligne) directement
Accès à Claude (choisi dans la popup) :
  abonnement  via Claude Code (`claude -p`), compris dans l'abonnement claude.ai — pas de clé API
  api         via une clé API payée au token, saisie dans la popup et rangée dans le trousseau du système (Trousseau macOS, Gestionnaire d'identification Windows, Secret Service Linux)

Positions : *_pct = % de la zone visible de la page ; ecran_x/ecran_y = point estimé sur l'écran
(macOS, en points), valable avec un zoom de page à 100 %.

Usage :
  python serveur_qcm.py
  python serveur_qcm.py --modele qwen3.5:4b --delai-local 90 --port 8765
  python serveur_qcm.py --installer      # en tâche de fond (macOS, Linux, Windows) : démarre avec la session
  python serveur_qcm.py --desinstaller   # arrête et retire la tâche de fond
Journal de la tâche de fond : ~/.shabcode/serveur_qcm.log
"""
import argparse, hashlib, json, os, queue, shutil, subprocess, sys, tempfile, threading, time
from datetime import datetime, timedelta
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import anthropic
import keyring
import ollama

ICI = Path(__file__).resolve().parent
FICHIER_CONFIG = Path.home() / ".shabcode" / "qcm_config.json"
TROUSSEAU = ("shabcode-qcm", "claude-api-key")  # (service, compte) dans le trousseau du système
MODES = ("local", "auto", "claude")

PROMPT_INDICE = """Voici une question de QCM.

Question : {question}
Choix :
{choix}

Trouve la bonne réponse, puis écris un indice court (1 à 2 phrases, dans la langue de la question)
qui aide à la trouver sans la nommer (ni sa lettre, ni son texte).
Ne cherche pas l'indice parfait : dès que tu as une bonne idée, écris-la.
Réponds uniquement avec ce JSON : {{"reponse": "texte exact du bon choix", "indice": "..."}}"""

ENTETE_PAGE = """Voici le texte visible d'une page web, puis la liste numérotée de ses éléments cliquables.
La page peut contenir du bruit (menus, publicités, navigation) : ignore-le.
Contient-elle une question de QCM (une question suivie de plusieurs choix de réponse) ?

TEXTE DE LA PAGE :
{texte}

ÉLÉMENTS CLIQUABLES :
{cliquables}
"""

# Local : repérage seul (rapide, sans réflexion) ; l'indice est demandé ensuite, si c'est bien un QCM.
PROMPT_PAGE = ENTETE_PAGE + """
Si NON, réponds : {{"est_qcm": false, "question": "", "choix_ids": []}}
Si OUI (s'il y en a plusieurs, prends celle qui n'est pas encore répondue), réponds UNIQUEMENT :
{{"est_qcm": true, "question": "texte exact de la question", "choix_ids": [numéros des éléments cliquables qui sont les choix, dans l'ordre]}}"""

# Règle ajoutée pour Claude seulement (Qwen, lui, se met à tourner en rond avec trop de contraintes).
REGLE_INDICE_CLAUDE = """L'indice ne doit pas non plus permettre de trouver la réponse en comparant les choix entre eux
(pas de « la plus ancienne », « la seule qui… », ni de position dans la liste), ni par un calcul ou une
valeur voisine (pas de « juste après le 32 ») : il doit faire réfléchir, pas donner la réponse déguisée."""

# En ligne : repérage ET indice dans un seul appel (moins d'attente, moins de quota).
PROMPT_PAGE_INDICE = ENTETE_PAGE + """
Si NON : est_qcm = false, et laisse les autres champs vides.
Si OUI (s'il y en a plusieurs, prends celle qui n'est pas encore répondue) :
- question : texte exact de la question
- choix_ids : numéros des éléments cliquables qui sont ses choix, dans l'ordre
- reponse : le texte exact du choix qui est la bonne réponse
- indice : trouve la bonne réponse, puis écris un indice court (1 à 2 phrases, dans la langue de la
  question) qui aide à la trouver sans la nommer (ni sa lettre, ni son texte).
""" + REGLE_INDICE_CLAUDE

# En ligne : toute la page (vue compacte construite par l'extension) ; Claude trouve la question,
# ses choix et écrit l'indice, en un seul appel. Fonctionne quelle que soit la mise en page du site.
PROMPT_COMPACTE = """Voici le contenu d'une page web, dans l'ordre de lecture. Les éléments cliquables sont
numérotés [n], suivis de leur type (radio, checkbox, bouton, lien, champ à remplir…) ; ○ = non coché, ● = coché.
La page peut contenir UNE OU PLUSIEURS questions, chacune de l'un de ces deux types :
- « choix » : une question suivie de plusieurs choix de réponse (QCM) ;
- « libre » : une question dont on écrit soi-même la réponse dans un champ à remplir.
Tout le reste est du bruit à ignorer : titre de la page, menus, barre de recherche, consignes,
publicités, chrono, boutons Valider / Suivant.
Les images de la page sont repérées [img k] et jointes à ce message (chacune précédée de son repère) :
une question peut porter sur une image (« Quel est ce poisson ? »), et des choix peuvent être des images.
Regarde-les pour répondre. Une image marquée [img k] mais absente du message n'a pas pu être lue.

PAGE :
{page}

Renvoie dans « questions » TOUTES les questions de la page, dans l'ordre (liste vide s'il n'y en a aucune).
N'invente jamais d'énoncé : une question dont l'énoncé ne figure pas sur la page est ignorée.
Pour chaque question :
- type : "choix" ou "libre"
- question : le texte exact de la question elle-même (pas le titre de la page ni la consigne)
- choix_ids : pour « choix », les numéros [n] de SES choix de réponse, dans l'ordre ; [] pour « libre »
- champ_id : pour « libre », le numéro [n] du champ où écrire SA réponse ; -1 pour « choix »
- image_ids : les numéros k des images [img k] qui font partie de la question ou de ses choix
  (pas les logos ni les décorations) ; [] s'il n'y en a pas
- reponse : pour « choix », le texte exact du bon choix ; pour « libre », la réponse attendue (courte)
- explication : en 1 ou 2 phrases, pourquoi c'est la bonne réponse (non montrée avec l'indice)
- indice : un indice court (1 à 2 phrases, dans la langue de la question) qui aide à trouver la réponse
  sans la nommer (ni sa lettre, ni son texte).
""" + REGLE_INDICE_CLAUDE

SCHEMA_INDICE = {"type": "object", "properties": {"reponse": {"type": "string"}, "indice": {"type": "string"}},
                 "required": ["reponse", "indice"], "additionalProperties": False}
SCHEMA_PAGE = {"type": "object",
               "properties": {"est_qcm": {"type": "boolean"}, "question": {"type": "string"},
                              "choix_ids": {"type": "array", "items": {"type": "integer"}}},
               "required": ["est_qcm", "question", "choix_ids"], "additionalProperties": False}
QUESTION_COMPACTE = {
    "type": "object",
    "properties": {"type": {"type": "string", "enum": ["choix", "libre"]}, "question": {"type": "string"},
                   "choix_ids": {"type": "array", "items": {"type": "integer"}}, "champ_id": {"type": "integer"},
                   "image_ids": {"type": "array", "items": {"type": "integer"}},
                   "reponse": {"type": "string"}, "explication": {"type": "string"}, "indice": {"type": "string"}},
    "required": ["type", "question", "choix_ids", "champ_id", "image_ids", "reponse", "explication", "indice"],
    "additionalProperties": False}
SCHEMA_COMPACTE = {"type": "object", "properties": {"questions": {"type": "array", "items": QUESTION_COMPACTE}},
                   "required": ["questions"], "additionalProperties": False}
SCHEMA_PAGE_INDICE = {**SCHEMA_PAGE,
                      "properties": {**SCHEMA_PAGE["properties"], "reponse": {"type": "string"},
                                     "indice": {"type": "string"}},
                      "required": [*SCHEMA_PAGE["required"], "reponse", "indice"]}

# Réglages recommandés par Qwen pour le mode raisonnement (pas de temperature 0 : risque de boucle).
# num_predict : budget de réflexion (~27 tokens/s avec qwen3.5:4b, soit ~2,5 min max).
OPTIONS_RAISONNEMENT = {"temperature": 0.6, "top_p": 0.95, "top_k": 20, "num_ctx": 8192, "num_predict": 4000}

# Prix Claude en $ par million de tokens (entrée, sortie) — pour afficher le coût dans la popup.
# Modèles proposés dans la popup : (alias pour Claude Code / abonnement, identifiant pour l'API).
MODELES_CLAUDE = {"opus": ("opus", "claude-opus-5-5"), "sonnet": ("sonnet", "claude-sonnet-5-5"),
                  "haiku": ("haiku", "claude-haiku-5-5")}
PRIX_CLAUDE = {"claude-opus-5-5": (4.0, 20.0), "claude-sonnet-5-5": (2.0, 10.0), "claude-haiku-5-5": (0.10, 0.50)}


# ---------------------------------------------------------------- stockage des QCM (qcm.json)
def cle(qcm):
    """Clé de déduplication : question + choix + images concernées.
    Beaucoup de quiz réutilisent le même énoncé (« Quel est ce poisson ? ») : seuls la photo et les choix
    changent. L'énoncé seul ne suffit donc pas à reconnaître une question déjà traitée."""
    normal = lambda t: " ".join((t or "").lower().split())
    question = normal(qcm.get("question", ""))
    if not question:
        return ""
    choix = sorted(normal(c.get("texte")) for c in qcm.get("choix", []))
    return "|".join([question, *choix, *qcm.get("images", [])])


class Stockage:
    """qcm.json sert aussi de cache : une question déjà vue est réaffichée sans rappeler l'IA (l'extension
    renvoie la page à chaque changement). Les entrées plus vieilles que `conservation` heures sont purgées
    (0 = tout garder), dans qcm.json comme dans raisonnements.jsonl."""

    def __init__(self, path, path_raisonnements, conservation=24):
        self.path = Path(path)
        self.path_raisonnements = Path(path_raisonnements)
        self.conservation = conservation
        self.items = json.loads(self.path.read_text(encoding="utf-8")) if self.path.exists() else []
        self.vus = {cle(q) for q in self.items}
        self.purger()

    def _recent(self, horodatage):
        try:
            return datetime.fromisoformat(horodatage) >= datetime.now() - timedelta(hours=self.conservation)
        except (TypeError, ValueError):
            return False  # entrée sans date lisible : purgée

    def _ecrire(self):
        tmp = self.path.with_suffix(".tmp")
        tmp.write_text(json.dumps(self.items, ensure_ascii=False, indent=2), encoding="utf-8")
        tmp.replace(self.path)  # écriture atomique

    def purger(self):
        """Retire les questions et raisonnements plus vieux que la durée de conservation."""
        if not self.conservation:
            return
        gardes = [q for q in self.items if self._recent(q.get("horodatage"))]
        if len(gardes) != len(self.items):
            self.items = gardes
            self.vus = {cle(q) for q in self.items}
            self._ecrire()
        if self.path_raisonnements.exists():
            lignes = self.path_raisonnements.read_text(encoding="utf-8").splitlines()
            recentes = [l for l in lignes if self._recent(lire_json(l).get("horodatage"))]
            if len(recentes) != len(lignes):
                self.path_raisonnements.write_text("".join(l + "\n" for l in recentes), encoding="utf-8")

    def retirer(self, qcm):
        """Supprime la question enregistrée (pour la remplacer, ex. réponse obtenue sans son image)."""
        k = cle(qcm)
        self.items = [q for q in self.items if cle(q) != k]
        self.vus.discard(k)

    def ajouter_possible(self, qcm):
        """True si la question n'est pas encore enregistrée."""
        k = cle(qcm)
        return bool(k) and k not in self.vus

    def ajouter(self, qcm):
        k = cle(qcm)
        if not k or k in self.vus:
            return False
        self.purger()
        self.vus.add(k)
        self.items.append(qcm)
        self._ecrire()
        return True

    def raisonnement(self, horodatage, question, pensee):
        ligne = {"horodatage": horodatage, "question": question, "raisonnement": pensee}
        with self.path_raisonnements.open("a", encoding="utf-8") as f:
            f.write(json.dumps(ligne, ensure_ascii=False) + "\n")


def telecharger_image(url, cote_max=1024, taille_max=8_000_000):
    """Télécharge une image de la page que l'extension n'a pas pu lire (autre site). Renvoie du JPEG en base64,
    ou None. Refuse les adresses locales/privées : une page ne doit pas pouvoir faire lire au serveur une
    ressource de ton réseau (box, services sur 127.0.0.1…)."""
    import base64, io, ipaddress, socket, urllib.parse, urllib.request
    from PIL import Image
    try:
        u = urllib.parse.urlparse(url)
        if u.scheme not in ("http", "https") or not u.hostname:
            return None
        for info in socket.getaddrinfo(u.hostname, u.port or (443 if u.scheme == "https" else 80)):
            ip = ipaddress.ip_address(info[4][0])
            if ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_reserved or ip.is_multicast:
                return None
        req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 (Macintosh) QCM-Stream",
                                                   "Accept": "image/*"})
        with urllib.request.urlopen(req, timeout=8) as r:
            if not r.headers.get("Content-Type", "").startswith("image/"):
                return None
            donnees = r.read(taille_max + 1)
        if len(donnees) > taille_max:
            return None
        img = Image.open(io.BytesIO(donnees))
        img.thumbnail((cote_max, cote_max))
        fond = Image.new("RGB", img.size, "white")  # PNG transparents : fond blanc
        fond.paste(img.convert("RGBA"), mask=img.convert("RGBA").split()[3])
        sortie = io.BytesIO()
        fond.save(sortie, "JPEG", quality=85)
        return base64.b64encode(sortie.getvalue()).decode()
    except Exception:
        return None


def contenu_message(prompt, images):
    """Contenu d'un message Claude : chaque image précédée de son repère [img k], puis le texte."""
    blocs = []
    for im in images or []:
        blocs.append({"type": "text", "text": f"[img {im['id']}]"})
        blocs.append({"type": "image", "source": {"type": "base64", "media_type": "image/jpeg", "data": im["data"]}})
    blocs.append({"type": "text", "text": prompt})
    return blocs


class TropLent(Exception):
    def __init__(self, pensee):
        self.pensee = pensee


def lire_json(contenu):
    try:
        data = json.loads(contenu or "{}")
    except json.JSONDecodeError:
        return {}
    return data if isinstance(data, dict) else {}


def associer_reponse(reponse, choix):
    """Rattache le texte de la réponse au choix correspondant : {"lettre", "texte"} (ou None)."""
    if not reponse:
        return None
    normal = lambda t: " ".join((t or "").lower().split()).strip(" .")
    r = normal(reponse)
    for c in choix:  # texte identique, puis l'un contenu dans l'autre (« B. Lyon » / « Lyon »)
        if normal(c["texte"]) == r:
            return {"lettre": c["lettre"], "texte": c["texte"]}
    for c in choix:
        t = normal(c["texte"])
        if t and (t in r or r in t):
            return {"lettre": c["lettre"], "texte": c["texte"]}
    return {"lettre": "", "texte": reponse}


def lettre(texte, k):
    """Lettre affichée devant le choix (« B. Lyon » -> B), sinon A, B, C… selon l'ordre."""
    import re
    m = re.match(r"\s*([A-Ha-h])\s*[.)\-:]\s+", texte or "")
    return m.group(1).upper() if m else ("ABCDEFGH"[k] if k < 8 else str(k + 1))


def position(b, vue):
    """Boîte (pixels CSS dans la zone visible) -> % de la zone visible + point estimé à l'écran."""
    if not b or not vue:
        return None
    W, H = vue["largeur"] or 1, vue["hauteur"] or 1
    x, y, l, h = b["x"], b["y"], b["l"], b["h"]
    cx, cy = x + l / 2, y + h / 2
    bord = max(vue["outerWidth"] - W, 0) / 2               # bordure latérale de la fenêtre
    barre = max(vue["outerHeight"] - H - bord, 0)          # onglets + barre d'adresse
    r = lambda v: round(v, 2)
    return {
        "centre_x_pct": r(cx / W * 100), "centre_y_pct": r(cy / H * 100),
        "gauche_pct": r(x / W * 100), "haut_pct": r(y / H * 100),
        "largeur_pct": r(l / W * 100), "hauteur_pct": r(h / H * 100),
        "ecran_x": round(vue["screenX"] + bord + cx), "ecran_y": round(vue["screenY"] + barre + cy),
    }


# ---------------------------------------------------------------- Claude (en ligne)
class ClaudeAPI:
    """Connexion à l'API Claude (payée au token). Clé lue dans le trousseau du système, sinon ANTHROPIC_API_KEY."""

    def __init__(self, modele):
        self.modele = modele
        self.client, self.source = None, None
        self.cout, self.appels = 0.0, 0
        self.charger()

    @property
    def connecte(self):
        return self.client is not None

    def charger(self):
        try:
            cle = keyring.get_password(*TROUSSEAU)
        except keyring.errors.KeyringError:
            cle = None
        if cle:
            self.client, self.source = anthropic.Anthropic(api_key=cle), "trousseau"
        elif os.environ.get("ANTHROPIC_API_KEY"):
            self.client, self.source = anthropic.Anthropic(), "environnement"
        else:
            self.client, self.source = None, None

    def connecter(self, cle):
        """Vérifie la clé (sans consommer de tokens) puis la range dans le trousseau. Renvoie une erreur ou None."""
        cle = (cle or "").strip()
        if not cle.startswith("sk-ant-"):
            return "Ce n'est pas une clé API Claude (elle commence par sk-ant-)."
        client = anthropic.Anthropic(api_key=cle)
        try:
            client.models.retrieve(self.modele)
        except anthropic.AuthenticationError:
            return "Clé refusée par Anthropic."
        except anthropic.PermissionDeniedError:
            return "Cette clé n'a pas les droits nécessaires."
        except anthropic.NotFoundError:
            return f"Le modèle {self.modele} n'est pas accessible avec cette clé."
        except anthropic.APIConnectionError:
            return "Impossible de joindre Anthropic (connexion Internet ?)."
        except anthropic.APIStatusError as e:
            return f"Erreur Anthropic ({e.status_code})."
        keyring.set_password(*TROUSSEAU, cle)
        self.client, self.source = client, "trousseau"
        return None

    def deconnecter(self):
        try:
            keyring.delete_password(*TROUSSEAU)
        except keyring.errors.PasswordDeleteError:
            pass
        self.charger()  # reste connecté si ANTHROPIC_API_KEY est défini

    def appeler(self, prompt, schema, effort, images=None):
        """Un appel Claude avec réflexion. Renvoie (données JSON, résumé du raisonnement)."""
        if not self.client:
            raise RuntimeError("Claude n'est pas connecté (ajoute ta clé dans la popup)")
        # Si un filtre de sécurité refuse, l'API relance automatiquement sur un autre modèle
        # (repli non disponible pour Haiku).
        repli = {} if "haiku" in self.modele else {"betas": ["server-side-fallback-2026-07-01"],
                                                    "fallbacks": "default"}
        r = self.client.beta.messages.create(
            model=self.modele,
            max_tokens=16000,
            **repli,
            thinking={"type": "adaptive", "display": "summarized"},
            output_config={"effort": effort, "format": {"type": "json_schema", "schema": schema}},
            messages=[{"role": "user", "content": contenu_message(prompt, images)}],
        )
        entree, sortie = PRIX_CLAUDE.get(self.modele, (0, 0))
        self.cout += (r.usage.input_tokens * entree + r.usage.output_tokens * sortie) / 1e6
        self.appels += 1
        pensee = "\n".join(b.thinking for b in r.content if b.type == "thinking" and b.thinking)
        if r.stop_reason == "refusal":
            return {}, pensee
        texte = next((b.text for b in r.content if b.type == "text"), "")
        return lire_json(texte), pensee

    def etat(self):
        return {"connecte": self.connecte, "source": self.source, "modele": self.modele,
                "cout_dollars": round(self.cout, 4), "appels": self.appels}


class ClaudeAbonnement:
    """Claude via Claude Code en mode non interactif (`claude -p`) : utilise l'abonnement claude.ai,
    sans clé API ni facturation au token (les appels comptent dans les limites de l'abonnement).

    Claude Code est bridé : aucun outil (ni fichiers ni commandes), réglages et serveurs MCP ignorés,
    dossier de travail vide. Le texte venu de la page web ne peut donc rien lui faire exécuter."""

    SYSTEME = "Tu aides à réviser des QCM. Tu réponds uniquement à la question posée, dans le format JSON demandé."

    def __init__(self, modele):
        self.modele = modele
        self.appels = 0
        self.exe = shutil.which("claude") or str(Path.home() / ".local" / "bin"
                                                  / ("claude.exe" if sys.platform == "win32" else "claude"))
        self._statut, self._vu = None, 0.0

    @staticmethod
    def env():
        e = dict(os.environ)
        e.pop("ANTHROPIC_API_KEY", None)  # sinon Claude Code utiliserait la clé (payante) au lieu de l'abonnement
        return e

    def statut(self):
        """Connexion de Claude Code à claude.ai (vérifiée au plus une fois par minute)."""
        if self._statut is None or time.monotonic() - self._vu > 60:
            try:
                r = subprocess.run([self.exe, "auth", "status"], capture_output=True, text=True,
                                   timeout=20, env=self.env())
                d = lire_json(r.stdout)
                self._statut = {"connecte": bool(d.get("loggedIn")) and d.get("authMethod") == "claude.ai",
                                "methode": d.get("authMethod"), "installe": True}
            except (OSError, subprocess.TimeoutExpired):
                self._statut = {"connecte": False, "methode": None, "installe": os.path.exists(self.exe)}
            self._vu = time.monotonic()
        return self._statut

    @property
    def connecte(self):
        return self.statut()["connecte"]

    def appeler(self, prompt, schema, effort, images=None):
        # Claude Code ne renvoie pas le raisonnement interne du modèle (et demander à le recopier est
        # refusé par ses filtres : catégorie « reasoning_extraction »). On demande donc une explication
        # de la bonne réponse, conservée dans raisonnements.jsonl à la place.
        explique = "indice" in schema["properties"]
        if explique:
            schema = {**schema, "properties": {"explication": {"type": "string"}, **schema["properties"]},
                      "required": ["explication", *schema["required"]]}
            prompt += ("\n\nDans « explication », dis en 2 ou 3 phrases quelle est la bonne réponse "
                       "et pourquoi (cette partie n'est pas montrée avec l'indice).")
        # Entrée au format stream-json : c'est ce format qui permet de joindre des images.
        message = {"type": "user", "message": {"role": "user", "content": contenu_message(prompt, images)}}
        with tempfile.TemporaryDirectory() as vide:
            r = subprocess.run(
                [self.exe, "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                 "--json-schema", json.dumps(schema),
                 "--tools", "", "--restricted", "--strict-mcp-config", "--disable-slash-commands",
                 "--no-session-persistence", "--system-prompt", self.SYSTEME,
                 "--model", self.modele, "--effort", effort],
                input=json.dumps(message) + "\n", capture_output=True, text=True, timeout=300, cwd=vide,
                env=self.env())
        self.appels += 1
        # La sortie est une suite de lignes JSON ; le résultat final est la ligne de type « result ».
        d = next((x for x in map(lire_json, reversed(r.stdout.splitlines())) if x.get("type") == "result"), {})
        if r.returncode != 0 or d.get("is_error"):
            self._statut = None  # on revérifiera la connexion
            msg = d.get("result") or r.stderr.strip()[-300:] or f"code {r.returncode}"
            if "safeguards flagged" in msg:
                msg = "refusé par un filtre de sécurité de Claude (" + msg.split("Details: `")[-1].split("`")[0] + ")"
            raise RuntimeError(f"Claude Code : {msg.strip()[:300]}")
        data = d.get("structured_output") or lire_json(d.get("result"))
        pensee = data.pop("explication", "") if explique else ""
        return data, pensee

    def etat(self):
        return {**self.statut(), "modele": self.modele, "appels": self.appels}


class Claude:
    """Claude par l'abonnement (Claude Code) ou par l'API (clé), selon le choix fait dans la popup."""
    ACCES = ("abonnement", "api")

    def __init__(self, acces, modele):
        self.api = ClaudeAPI(MODELES_CLAUDE["sonnet"][1])
        self.abonnement = ClaudeAbonnement(MODELES_CLAUDE["sonnet"][0])
        self.acces = acces if acces in self.ACCES else "abonnement"
        self.choisir_modele(modele)

    def choisir_modele(self, famille):
        """opus / sonnet / haiku, appliqué aux deux accès."""
        self.famille = famille if famille in MODELES_CLAUDE else "sonnet"
        self.abonnement.modele, self.api.modele = MODELES_CLAUDE[self.famille]

    @property
    def actif(self):
        return self.abonnement if self.acces == "abonnement" else self.api

    @property
    def connecte(self):
        return self.actif.connecte

    def appeler(self, prompt, schema, effort, images=None):
        return self.actif.appeler(prompt, schema, effort, images)

    def etat(self):
        return {"acces": self.acces, "connecte": self.connecte, "famille": self.famille,
                "api": self.api.etat(), "abonnement": self.abonnement.etat()}


# ---------------------------------------------------------------- serveur
class Serveur:
    def __init__(self, args):
        self.args = args
        self.stockage = Stockage(args.out, args.raisonnements, args.conservation)
        self.config = {"mode": "auto", "acces_claude": "abonnement", "modele_claude": "sonnet"}
        self.fichier_config = Path(args.config)
        if self.fichier_config.exists():
            self.config.update(lire_json(self.fichier_config.read_text()))
        self.claude = Claude(self.config["acces_claude"], self.config["modele_claude"])
        self.derniere_page = None  # (éléments de la page, question) du dernier appel Claude
        self.file = queue.Queue(maxsize=1)  # garde seulement l'envoi le plus récent
        self.pages_vues = set()             # mode secours : pages déjà analysées
        self.etat = {"en_cours": None, "en_cours_url": None, "en_cours_question": False, "dernier": None, "resultats": None,
                     "erreur": None}
        if self.stockage.items:
            d = self.stockage.items[-1]
            self.etat["dernier"] = {"question": d["question"], "indice": d.get("indice", ""),
                                    "reponse": d.get("reponse"),
                                    "source": d.get("indice_source", "")}
        threading.Thread(target=self.boucle, daemon=True).start()

    @property
    def mode(self):
        return self.config.get("mode") if self.config.get("mode") in MODES else "auto"

    def changer_config(self, p):
        """p peut contenir "mode" (local/auto/claude), "acces" (abonnement/api), "modele" (opus/sonnet/haiku)."""
        if ("mode" in p and p["mode"] not in MODES or "acces" in p and p["acces"] not in Claude.ACCES
                or "modele" in p and p["modele"] not in MODELES_CLAUDE):
            return False
        if "modele" in p:
            self.config["modele_claude"] = p["modele"]
            self.claude.choisir_modele(p["modele"])
            print(f"→ modèle Claude : {p['modele']}")
        if "mode" in p:
            self.config["mode"] = p["mode"]
            print(f"→ moteur : {p['mode']}")
        if "acces" in p:
            self.config["acces_claude"] = self.claude.acces = p["acces"]
            print(f"→ accès Claude : {p['acces']}")
        self.fichier_config.parent.mkdir(parents=True, exist_ok=True)
        self.fichier_config.write_text(json.dumps(self.config))
        return True

    @property
    def secours_claude(self):
        """True si on peut basculer sur Claude quand le local ne suffit pas."""
        return self.mode == "auto" and self.claude.connecte

    def recevoir(self, payload):
        try:
            self.file.get_nowait()
        except queue.Empty:
            pass
        self.file.put(payload)

    def boucle(self):
        while True:
            p = self.file.get()
            try:
                self.traiter(p)
                self.etat["erreur"] = None
            except Exception as e:  # le thread ne doit jamais mourir
                self.etat["erreur"] = f"{type(e).__name__}: {e}"
                print(f"[erreur] {self.etat['erreur']}")
            finally:
                self.etat["en_cours"] = self.etat["en_cours_url"] = None
                self.etat["en_cours_question"] = False

    # -- extraction --
    def depuis_page(self, p):
        """Mode secours : repérer la question parmi le texte de la page et ses éléments cliquables."""
        sig = hashlib.sha1(p["texte"].encode()).hexdigest()
        if sig in self.pages_vues:
            return None
        self.pages_vues.add(sig)
        cliquables = {c["id"]: c for c in p["cliquables"]}
        champs = dict(texte=p["texte"],
                      cliquables="\n".join(f"[{c['id']}] {c['texte']}" for c in p["cliquables"]))
        deja = None  # résultat complet (indice, réponse…) quand Claude a tout fait en un appel
        if self.mode == "claude":
            data, deja = self.page_claude(champs)
        else:
            try:
                r = ollama.chat(model=self.args.modele_rapide,
                                messages=[{"role": "user", "content": PROMPT_PAGE.format(**champs)}],
                                format=SCHEMA_PAGE, think=False, options={"temperature": 0, "num_ctx": 8192},
                                keep_alive="30m")
                data = lire_json(r["message"]["content"])
            except Exception as e:
                if not self.secours_claude:
                    raise
                print(f"    Qwen indisponible ({type(e).__name__}) → Claude")
                data, deja = self.page_claude(champs)
        if not data.get("est_qcm"):
            return None
        choix = [cliquables[i] for i in data.get("choix_ids") or [] if i in cliquables]
        return {
            "_indice": deja,
            "question": data.get("question", ""),
            "choix": [{"lettre": "ABCDEFGH"[k] if k < 8 else str(k + 1), "texte": c["texte"],
                       "position_texte": position(c["boite"], p["vue"]),
                       "position_bouton": position(c["boite"], p["vue"])} for k, c in enumerate(choix)],
        }

    def depuis_compacte(self, p):
        """En ligne : Claude lit toute la page et renvoie TOUTES ses questions (choix, champs, indices)
        en un seul appel. Renvoie une liste de questions, ou None si rien de nouveau."""
        c = p["compacte"]
        signature = c.get("signature") or c["page"]  # texte + adresses des images
        sig = hashlib.sha1("".join(ch for ch in signature if not ch.isdigit()).encode()).hexdigest()
        forcer = bool(p.get("forcer"))  # image capturée au clic droit : on refait l'analyse
        if sig in self.pages_vues and not forcer:  # page déjà analysée (seul un chiffre a changé : chrono…)
            return None
        self.pages_vues.add(sig)
        # Après « Valider », beaucoup de sites affichent la correction sur les MÊMES questions : la page
        # change, mais si les choix sont les mêmes et que les questions traitées y figurent toujours,
        # inutile de rappeler Claude : on republie les résultats déjà obtenus.
        # On compare les choix possibles (cases, boutons radio, options), pas les boutons de navigation
        # dont le texte change souvent après validation (« Valider » → « Suivant »).
        choix_possibles = [e for e in c["elements"] if e.get("nature") in ("radio", "checkbox", "option")]
        textes = frozenset([e["texte"] for e in (choix_possibles or c["elements"])]
                           + [i.get("src", "") for i in c.get("images", [])])
        normal = lambda t: " ".join((t or "").lower().split())
        if (not forcer and self.derniere_page and self.derniere_page[0] == textes
                and all(normal(q["question"]) in normal(c["page"]) for q in self.derniere_page[1])):
            print("    mêmes questions qu'avant (correction affichée ?) : pas de nouvel appel")
            return self.derniere_page[1]
        # Images que l'extension n'a pas pu lire (autre site) : le serveur les télécharge par leur adresse.
        manquantes = [i for i in c.get("images", []) if not i.get("data") and i.get("src")]
        for im in manquantes:
            im["data"] = telecharger_image(im["src"])
        recuperees = sum(1 for i in manquantes if i.get("data"))
        if manquantes:
            print(f"    {recuperees}/{len(manquantes)} image(s) d'un autre site téléchargée(s) par le serveur")
            if recuperees == len(manquantes):
                c["erreur_images"] = None
            else:
                c["erreur_images"] = (f"{len(manquantes) - recuperees} image(s) illisible(s) (protégée(s) "
                                      "par une connexion au site ?) : Claude a répondu sans")
        images = [i for i in c.get("images", []) if i.get("data")]
        print(f"    page envoyée à Claude ({len(c['page'])} caractères, {len(c['elements'])} éléments, "
              f"{len(images)} image(s))" + (f" — {c['erreur_images']}" if c.get("erreur_images") else ""))
        data, pensee = self.claude.appeler(PROMPT_COMPACTE.format(page=c["page"]), SCHEMA_COMPACTE, "medium",
                                           images)
        elements = {e["id"]: e for e in c["elements"]}
        images_page = {i["id"]: i for i in c.get("images", [])}
        qcms = []
        for q in data.get("questions") or []:
            if not (q.get("question") or "").strip():
                continue
            libre = q.get("type") == "libre"
            choix = [] if libre else [elements[i] for i in q.get("choix_ids") or [] if i in elements]
            champ = elements.get(q.get("champ_id")) if libre else None
            if not libre and len(choix) < 2:  # un QCM a au moins deux choix
                continue
            qcms.append({
                # Explication propre à la question si Claude l'a donnée, sinon son raisonnement global.
                "_indice": self.resultat(q, f"claude_{self.claude.acces}", q.get("explication") or pensee),
                # Éléments de la page liés à la question : l'extension s'en sert pour savoir laquelle
                # est à l'écran.
                "_elements": [e["id"] for e in choix] or ([champ["id"]] if champ else []),
                "_avertissement": c.get("erreur_images"),
                "type": "libre" if libre else "choix",
                "question": q["question"].strip(),
                # Adresse des images de la question : deux questions au même énoncé (« Quel est ce
                # poisson ? ») se distinguent par leur photo.
                "images": [images_page[k]["src"] for k in q.get("image_ids") or [] if k in images_page],
                **({"champ": {"position": position(champ["boite_bouton"], p["vue"])} if champ else None}
                   if libre else {}),
                "choix": [{"lettre": lettre(e["texte"], k), "texte": e["texte"],
                           "position_texte": position(e["boite_texte"], p["vue"]),
                           "position_bouton": position(e["boite_bouton"], p["vue"])} for k, e in enumerate(choix)],
            })
        self.derniere_page = (textes, qcms) if qcms else None
        print(f"    {len(qcms)} question(s) trouvée(s)")
        return qcms or None

    def page_claude(self, champs):
        """Un seul appel Claude : repère la question ET écrit l'indice."""
        data, pensee = self.claude.appeler(PROMPT_PAGE_INDICE.format(**champs), SCHEMA_PAGE_INDICE, "medium")
        return data, self.resultat(data, f"claude_{self.claude.acces}", pensee)

    def depuis_structure(self, p):
        return {
            "question": p["question"]["texte"],
            "position_question": position(p["question"].get("boite"), p["vue"]),
            "choix": [{"lettre": c["lettre"], "texte": c["texte"],
                       "position_texte": position(c["boite_texte"], p["vue"]),
                       "position_bouton": position(c["boite_bouton"], p["vue"])} for c in p["choix"]],
        }

    # -- indice et réponse --
    @staticmethod
    def resultat(data, source, pensee):
        """Résultat d'un moteur : {indice, reponse, source, pensee}, ou None si pas d'indice."""
        indice = (data.get("indice") or "").strip()
        if not indice:
            return None
        return {"indice": indice, "reponse": (data.get("reponse") or "").strip(), "source": source, "pensee": pensee}

    def indice_qwen(self, prompt, delai):
        """Qwen avec raisonnement, en flux pour pouvoir abandonner après `delai` secondes."""
        t0, pensee, contenu = time.monotonic(), [], []
        flux = ollama.chat(model=self.args.modele, messages=[{"role": "user", "content": prompt}],
                           format=SCHEMA_INDICE, think=True, options=OPTIONS_RAISONNEMENT,
                           keep_alive="30m", stream=True)
        try:
            for m in flux:
                pensee.append(m.message.thinking or "")
                contenu.append(m.message.content or "")
                if delai and time.monotonic() - t0 > delai:
                    raise TropLent("".join(pensee))
        finally:
            flux.close()  # coupe la connexion : Ollama arrête de générer
        return lire_json("".join(contenu)), "".join(pensee)

    def conclure_qwen(self, prompt, pensee):
        """Réflexion inachevée : sans réfléchir, Qwen donne souvent des indices FAUX (mesuré).
        On lui redonne donc sa propre réflexion, qui contient déjà la réponse."""
        suite = (prompt + "\n\nVoici ta réflexion jusqu'ici :\n" + pensee[-8000:] +
                 "\n\nNe réfléchis plus : donne maintenant la réponse et l'indice à partir de cette réflexion.")
        r = ollama.chat(model=self.args.modele, messages=[{"role": "user", "content": suite}],
                        format=SCHEMA_INDICE, think=False, options={"temperature": 0.3, "num_ctx": 8192},
                        keep_alive="30m")
        return self.resultat(lire_json(r["message"]["content"]), "qwen_reflexion_tronquee", pensee)

    def indice_claude(self, prompt):
        data, pensee = self.claude.appeler(prompt + "\n" + REGLE_INDICE_CLAUDE, SCHEMA_INDICE, "medium")
        return self.resultat(data, f"claude_{self.claude.acces}", pensee)

    def indice(self, qcm):
        """Renvoie {indice, reponse, source, pensee} (ou None) selon le moteur choisi."""
        choix = "\n".join(f"{c['lettre']}. {c['texte']}" for c in qcm["choix"])
        prompt = PROMPT_INDICE.format(question=qcm["question"], choix=choix)
        if self.mode == "claude":
            return self.indice_claude(prompt)

        delai = self.args.delai_local if self.secours_claude else None
        try:
            data, pensee = self.indice_qwen(prompt, delai)
            res = self.resultat(data, "qwen", pensee)
            if res:
                return res
            raison = "budget de réflexion épuisé"
        except TropLent as e:
            pensee, raison = e.pensee, f"plus de {delai:.0f} s"
        except Exception as e:
            if not self.secours_claude:
                raise
            print(f"    Qwen indisponible ({type(e).__name__}) → Claude")
            return self.indice_claude(prompt)

        if self.secours_claude:
            print(f"    Qwen trop lent ({raison}) → Claude")
            return self.indice_claude(prompt)
        print(f"    {raison}, on conclut à partir de la réflexion…")
        return self.conclure_qwen(prompt, pensee)

    def traiter(self, p):
        h = datetime.now().isoformat(timespec="seconds")
        t0 = time.perf_counter()
        url = p.get("url", "")
        if self.mode == "claude" and p.get("compacte"):
            # En ligne, repérage et indices se font en un seul appel : on signale l'analyse dès maintenant
            # (l'extension affiche « Réflexion en cours… » sur la page).
            self.etat["en_cours"], self.etat["en_cours_url"] = "Analyse de la page…", url
            self.etat["en_cours_question"] = False  # simple analyse : rien ne dit encore qu'il y a un quiz
            qcms = self.depuis_compacte(p) or []   # en ligne : Claude lit toute la page
        else:
            # Local : détection par règles dans l'extension, une question à la fois.
            qcm = self.depuis_structure(p) if p.get("mode") == "structure" else self.depuis_page(p)
            ok = qcm and qcm["question"] and (qcm.get("type") == "libre" or len(qcm["choix"]) >= 2)
            qcms = [qcm] if ok else []
        if not qcms:
            return
        resultats = [self.enregistrer(h, url, q, p.get("mode"), p.get("forcer")) for q in qcms]
        self.publier(url, p.get("envoi"), resultats)
        print(f"    {len(resultats)} résultat(s) publié(s) en {time.perf_counter() - t0:.0f}s")

    def enregistrer(self, h, url, qcm, mode_detection, remplacer=False):
        """Une question : indice (si pas déjà fourni), enregistrement sans doublon. Renvoie ce qu'il faut afficher."""
        qcm = dict(qcm)  # les questions republiées (même page) ne doivent pas être modifiées
        elements = qcm.pop("_elements", [])
        avertissement = qcm.pop("_avertissement", None)
        res = qcm.pop("_indice", None)
        if remplacer and res is not None:  # nouvelle analyse avec l'image : elle remplace l'ancienne
            self.stockage.retirer(qcm)
        if not self.stockage.ajouter_possible(qcm):
            ancien = next((q for q in reversed(self.stockage.items) if cle(q) == cle(qcm)), qcm)
            return self.affichable(ancien, elements, avertissement)
        if res is None:  # local : l'indice est demandé maintenant, si c'est bien une question
            self.etat["en_cours"], self.etat["en_cours_url"] = qcm["question"], url
            self.etat["en_cours_question"] = True
            print(f"{h}  QCM détecté ({mode_detection}, moteur {self.mode}) : {qcm['question'][:70]} — réflexion…")
            res = self.indice(qcm)
        res = res or {"indice": "", "reponse": "", "source": "", "pensee": ""}
        qcm = {"horodatage": h, "url": url, **qcm, "reponse": associer_reponse(res["reponse"], qcm["choix"]),
               "indice": res["indice"], "indice_source": res["source"]}
        if self.stockage.ajouter(qcm):
            self.stockage.raisonnement(h, qcm["question"], res["pensee"])
        print(f"    [{res['source']}] {qcm['question'][:60]} → indice : {res['indice'][:80] or '(vide)'}")
        return self.affichable(qcm, elements, avertissement)

    @staticmethod
    def affichable(qcm, elements, avertissement):
        return {"question": qcm["question"], "indice": qcm.get("indice", ""), "reponse": qcm.get("reponse"),
                "source": qcm.get("indice_source", ""), "elements": elements, "avertissement": avertissement}

    def publier(self, url, envoi, questions):
        """Résultats de la page, affichés par l'extension. L'id change à chaque publication."""
        self.compteur = getattr(self, "compteur", 0) + 1
        self.etat["resultats"] = {"id": self.compteur, "url": url, "envoi": envoi, "questions": questions}
        self.etat["dernier"] = questions[-1]  # pour la popup (mode sans notification)

    def etat_complet(self):
        return {**self.etat, "mode": self.mode, "modele": self.args.modele,
                "claude": self.claude.etat(), "nb_qcm": len(self.stockage.items)}


def handler(serveur, port):
    hotes = {f"127.0.0.1:{port}", f"localhost:{port}"}

    class H(BaseHTTPRequestHandler):
        def repondre(self, code, corps, type_="application/json; charset=utf-8"):
            data = corps if isinstance(corps, bytes) else json.dumps(corps, ensure_ascii=False).encode()
            self.send_response(code)
            self.send_header("Content-Type", type_)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def hote_ok(self):
            # Bloque le « DNS rebinding » : un site qui se ferait passer pour 127.0.0.1.
            return self.headers.get("Host") in hotes

        def do_POST(self):
            self.securise(self._post)

        def do_GET(self):
            self.securise(self._get)

        def securise(self, f):
            # Une erreur dans une requête ne doit jamais couper la connexion sans réponse
            # (la popup croirait alors le serveur arrêté).
            try:
                f()
            except Exception as e:
                print(f"[erreur requête {self.path}] {type(e).__name__}: {e}")
                try:
                    self.repondre(500, {"erreur": f"{type(e).__name__}: {e}"})
                except Exception:
                    pass

        def _post(self):
            if not self.hote_ok():
                return self.repondre(403, {"erreur": "hôte refusé"})
            # Exiger du JSON force un contrôle CORS : une page web quelconque ne peut donc pas
            # piloter le serveur (ni dépenser tes crédits Claude). L'extension, elle, y a droit.
            if not (self.headers.get("Content-Type") or "").startswith("application/json"):
                return self.repondre(415, {"erreur": "JSON attendu"})
            try:
                p = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
            except (ValueError, json.JSONDecodeError):
                return self.repondre(400, {"erreur": "JSON invalide"})
            if self.path == "/qcm":
                serveur.recevoir(p)
                return self.repondre(202, {"ok": True})
            if self.path == "/config":
                ok = isinstance(p, dict) and serveur.changer_config(p)
                return self.repondre(200 if ok else 400, {"ok": ok, "mode": serveur.mode,
                                                          "acces": serveur.claude.acces})
            if self.path == "/claude/connexion":
                erreur = serveur.claude.api.connecter(p.get("cle"))
                if not erreur:
                    print("→ Claude connecté (clé rangée dans le trousseau)")
                return self.repondre(200 if not erreur else 400, {"ok": not erreur, "erreur": erreur})
            if self.path == "/claude/deconnexion":
                serveur.claude.api.deconnecter()
                print("→ Claude déconnecté")
                return self.repondre(200, {"ok": True, "claude": serveur.claude.etat()})
            self.repondre(404, {"erreur": "inconnu"})

        def _get(self):
            if not self.hote_ok():
                return self.repondre(403, {"erreur": "hôte refusé"})
            if self.path == "/etat":
                return self.repondre(200, serveur.etat_complet())
            self.repondre(404, {"erreur": "inconnu"})

        def log_message(self, *a):
            pass
    return H


# ---------------------------------------------------------------- service en tâche de fond
# macOS : launchd · Linux : systemd (utilisateur) · Windows : lanceur caché dans le dossier Démarrage
LABEL = "com.shabcode.qcm"
PLIST = Path.home() / "Library" / "LaunchAgents" / f"{LABEL}.plist"
UNITE_SYSTEMD = Path.home() / ".config" / "systemd" / "user" / "streamlet.service"
# Windows : un script .vbs dans le dossier Démarrage lance pythonw (aucune fenêtre, aucun droit admin requis)
# et le relance s'il s'arrête.
LANCEUR_WINDOWS = (Path(os.environ.get("APPDATA", Path.home() / "AppData" / "Roaming"))
                   / "Microsoft" / "Windows" / "Start Menu" / "Programs" / "Startup" / "Streamlet.vbs")
JOURNAL = Path.home() / ".shabcode" / "serveur_qcm.log"


def lancer(*args):
    try:
        return subprocess.run(list(args), capture_output=True, text=True)
    except FileNotFoundError as e:
        return subprocess.CompletedProcess(args, 127, "", str(e))


def launchctl(*args):
    return lancer("launchctl", *args)


def python_venv():
    """Python du .venv du projet s'il existe, sinon celui qui exécute ce script."""
    if sys.platform == "win32":
        candidat = ICI / ".venv" / "Scripts" / "pythonw.exe"  # pythonw : pas de fenêtre de console
    else:
        candidat = ICI / ".venv" / "bin" / "python"
    return str(candidat if candidat.exists() else Path(sys.executable))


def service_installe():
    if sys.platform == "darwin":
        return launchctl("print", f"gui/{os.getuid()}/{LABEL}").returncode == 0
    if sys.platform == "win32":
        return LANCEUR_WINDOWS.exists()
    return UNITE_SYSTEMD.exists()


def installer_service(options):
    """Fait tourner le serveur en tâche de fond : démarre à l'ouverture de session et redémarre s'il s'arrête."""
    JOURNAL.parent.mkdir(parents=True, exist_ok=True)
    commande = [python_venv(), "-u", str(ICI / "serveur_qcm.py"), *options]

    if sys.platform == "darwin":
        import plistlib
        PLIST.parent.mkdir(parents=True, exist_ok=True)
        plist = {
            "Label": LABEL,
            "ProgramArguments": commande,
            "WorkingDirectory": str(ICI),           # qcm.json et raisonnements.jsonl restent dans le projet
            "RunAtLoad": True,
            "KeepAlive": True,                      # relancé automatiquement s'il s'arrête
            "ThrottleInterval": 5,
            "StandardOutPath": str(JOURNAL),
            "StandardErrorPath": str(JOURNAL),
        }
        domaine = f"gui/{os.getuid()}"
        launchctl("bootout", f"{domaine}/{LABEL}")  # remplace une ancienne version éventuelle
        PLIST.write_bytes(plistlib.dumps(plist))
        r = launchctl("bootstrap", domaine, str(PLIST))

    elif sys.platform == "win32":
        arreter_windows()  # remplace une ancienne version éventuelle
        commande = [*commande, "--journal", str(JOURNAL)]  # pythonw n'a pas de console : on écrit le journal
        vbs = lambda t: t.replace('"', '""')  # guillemets doublés dans une chaîne VBScript
        LANCEUR_WINDOWS.parent.mkdir(parents=True, exist_ok=True)
        LANCEUR_WINDOWS.write_text(
            "' Streamlet : serveur local de l'extension, lancé sans fenêtre et relancé s'il s'arrête.\r\n"
            "' Retirer : python serveur_qcm.py --desinstaller\r\n"
            'Set sh = CreateObject("WScript.Shell")\r\n'
            f'sh.CurrentDirectory = "{vbs(str(ICI))}"\r\n'
            "Do\r\n"
            f'  sh.Run "{vbs(subprocess.list2cmdline(commande))}", 0, True\r\n'
            "  WScript.Sleep 5000\r\n"
            "Loop\r\n", encoding="utf-16")  # UTF-16 avec BOM : seul encodage Unicode lu par WScript
        try:
            subprocess.Popen(["wscript.exe", str(LANCEUR_WINDOWS)],
                             creationflags=subprocess.DETACHED_PROCESS | subprocess.CREATE_NEW_PROCESS_GROUP)
            r = subprocess.CompletedProcess([], 0, "", "")
        except OSError as e:
            r = subprocess.CompletedProcess([], 1, "", str(e))

    else:
        UNITE_SYSTEMD.parent.mkdir(parents=True, exist_ok=True)
        UNITE_SYSTEMD.write_text(
            "[Unit]\nDescription=Streamlet - serveur local de l'extension\nAfter=network.target\n\n"
            f"[Service]\nWorkingDirectory={ICI}\nExecStart={subprocess.list2cmdline(commande)}\n"
            f"Restart=always\nRestartSec=5\nStandardOutput=append:{JOURNAL}\nStandardError=append:{JOURNAL}\n\n"
            "[Install]\nWantedBy=default.target\n")
        lancer("systemctl", "--user", "daemon-reload")
        r = lancer("systemctl", "--user", "enable", "--now", UNITE_SYSTEMD.name)

    if r.returncode != 0:
        sys.exit(f"✗ échec de l'installation : {(r.stderr or r.stdout).strip()}")
    print(f"✓ serveur installé en tâche de fond (démarre avec ta session, redémarre s'il s'arrête)")
    print(f"  journal : {JOURNAL}")
    print(f"  arrêter et désinstaller : python serveur_qcm.py --desinstaller")


def arreter_windows():
    """Arrête le lanceur .vbs (sinon il relancerait le serveur) puis le serveur lui-même."""
    for motif in ("*Streamlet.vbs*", "*serveur_qcm.py*"):
        lancer("powershell", "-NoProfile", "-Command",
               f"Get-CimInstance Win32_Process | Where-Object {{ $_.CommandLine -like '{motif}' -and "
               f"$_.ProcessId -ne {os.getpid()} -and $_.ProcessId -ne $PID }} | ForEach-Object {{ Stop-Process -Id $_.ProcessId -Force }}")


def desinstaller_service():
    if sys.platform == "darwin":
        launchctl("bootout", f"gui/{os.getuid()}/{LABEL}")
        PLIST.unlink(missing_ok=True)
    elif sys.platform == "win32":
        LANCEUR_WINDOWS.unlink(missing_ok=True)
        arreter_windows()
    else:
        lancer("systemctl", "--user", "disable", "--now", UNITE_SYSTEMD.name)
        UNITE_SYSTEMD.unlink(missing_ok=True)
        lancer("systemctl", "--user", "daemon-reload")
    print("✓ serveur en tâche de fond arrêté et désinstallé")


def main():
    if "--installer" in sys.argv:
        return installer_service([a for a in sys.argv[1:] if a != "--installer"])
    if "--desinstaller" in sys.argv:
        return desinstaller_service()

    p = argparse.ArgumentParser(description="Reçoit les QCM de l'extension et génère un indice (Qwen local ou Claude)")
    p.add_argument("--modele", default="qwen3.5:4b", help="modèle local avec raisonnement, pour l'indice")
    p.add_argument("--modele-rapide", default="qwen3.5:4b",
                   help="modèle local sans raisonnement, pour repérer la question sur les pages sans boutons radio")
    p.add_argument("--delai-local", type=float, default=90,
                   help="moteur auto : secondes accordées à Qwen avant de passer à Claude")
    p.add_argument("--out", default="qcm.json")
    p.add_argument("--raisonnements", default="raisonnements.jsonl")
    p.add_argument("--conservation", type=float, default=24,
                   help="heures pendant lesquelles les questions sont gardées (0 = toujours)")
    p.add_argument("--port", type=int, default=8765)
    p.add_argument("--config", default=str(FICHIER_CONFIG), help="fichier des réglages choisis dans la popup")
    p.add_argument("--journal", help="écrire la sortie dans ce fichier (utilisé par la tâche de fond Windows)")
    p.add_argument("--installer", action="store_true",
                   help="faire tourner le serveur en tâche de fond (launchd / systemd / dossier Démarrage Windows)")
    p.add_argument("--desinstaller", action="store_true", help="arrêter et retirer la tâche de fond")
    args = p.parse_args()
    if args.journal:
        Path(args.journal).parent.mkdir(parents=True, exist_ok=True)
        sys.stdout = sys.stderr = open(args.journal, "a", buffering=1, encoding="utf-8")

    try:
        httpd = ThreadingHTTPServer(("127.0.0.1", args.port), None)
    except OSError:
        tache = service_installe()
        sys.exit(f"✗ le port {args.port} est déjà utilisé : un serveur QCM tourne sans doute déjà"
                 + (" (en tâche de fond, voir --desinstaller)." if tache else "."))
    serveur = Serveur(args)
    httpd.RequestHandlerClass = handler(serveur, args.port)
    c = serveur.claude
    print(f"Serveur QCM sur http://127.0.0.1:{args.port}  (moteur {serveur.mode}, sortie {args.out})")
    print(f"Claude ({c.acces}) : {'connecté' if c.connecte else 'non connecté — voir la popup'}")
    print("Ctrl+C pour arrêter")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print(f"\nArrêt. {len(serveur.stockage.items)} QCM dans {args.out}")


if __name__ == "__main__":
    main()

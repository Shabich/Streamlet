"""Connaissances par thème (RAG local) pour Streamlet.

Un thème = un fichier de faits, un fait par ligne une fois lu :
  .csv          une ligne du tableau = un fait (« colonne : valeur · colonne : valeur »)
  .txt / .md    une ligne (ou un paragraphe) non vide = un fait ; un titre « # … » en tête donne le nom du thème
  .json/.jsonl  une liste (ou une ligne JSON) = un fait ; les objets deviennent « clé : valeur · … »

Deux dossiers sont lus :
  connaissances/                 (dans le projet)  thèmes fournis avec Streamlet
  ~/.streamlet/connaissances/    (sur ta machine)  thèmes déposés depuis l'extension

Pour chaque question, on cherche par mots-clés (question + choix) les faits les plus proches dans les thèmes
actifs ; ils sont donnés à l'IA locale comme informations de référence. Tout reste sur la machine.
"""
import csv, io, json, math, re, unicodedata
from pathlib import Path

EXTENSIONS = (".csv", ".txt", ".md", ".json", ".jsonl")
TAILLE_MAX = 5 * 1024 * 1024        # 5 Mo par fichier
NB_FAITS_MAX = 8                    # faits donnés à l'IA par question

# Mots trop courants pour aider à la recherche (français et anglais).
MOTS_VIDES = set("""
le la les l un une des du de d au aux a à et ou en dans sur pour par avec sans est sont ce cette ces cet
quel quelle quels quelles qui que quoi dont où ne pas plus il elle ils elles on se sa son ses leur leurs
y suivant suivante associe associee associes numero nom quelle laquelle lequel lesquels lesquelles comment
the a an of to in on for by with is are was were which what who whom whose this that these those it its
and or not as at from be been
""".split())


def normaliser(texte):
    """Minuscules, sans accents : « Ardèche » et « ardeche » se retrouvent."""
    t = unicodedata.normalize("NFKD", str(texte).lower())
    return "".join(c for c in t if not unicodedata.combining(c))


def mots(texte):
    """Mots utiles d'un texte. Les nombres perdent leurs zéros de tête (« 08 » = « 8 »)."""
    res = []
    for m in re.findall(r"\w+", normaliser(texte)):
        if m.isdigit():
            m = m.lstrip("0") or "0"
        elif m in MOTS_VIDES or len(m) < 2:
            continue
        res.append(m)
    return res


def _objet_en_fait(o):
    if isinstance(o, dict):
        return " · ".join(f"{k} : {v}" for k, v in o.items() if str(v).strip())
    return str(o).strip()


def lire(nom_fichier, contenu):
    """Lit un thème depuis son texte. Renvoie (nom du thème, liste de faits). Lève ValueError si illisible."""
    ext = Path(nom_fichier).suffix.lower()
    if ext not in EXTENSIONS:
        raise ValueError("format")
    nom = Path(nom_fichier).stem.replace("-", " ").replace("_", " ").strip()
    contenu = contenu.lstrip("﻿")  # BOM des exports Excel
    faits = []
    if ext == ".csv":
        try:
            dialecte = csv.Sniffer().sniff(contenu[:4096], delimiters=",;\t")
        except csv.Error:
            dialecte = csv.excel
        lignes = csv.DictReader(io.StringIO(contenu), dialect=dialecte)
        faits = [_objet_en_fait({k.strip(): (v or "").strip() for k, v in l.items() if k}) for l in lignes]
    elif ext in (".txt", ".md"):
        lignes = contenu.splitlines()
        if lignes and lignes[0].lstrip().startswith("#"):
            nom = lignes[0].lstrip("# ").strip() or nom
            lignes = lignes[1:]
        # Une liste (la plupart des lignes courtes) : une ligne = un fait.
        # Un texte rédigé : un paragraphe (lignes non vides qui se suivent) = un fait.
        utiles = [l.strip() for l in lignes if not l.strip().startswith("#")]  # sous-titres ignorés
        pleines = [l for l in utiles if l]
        if pleines and sum(len(l) < 200 for l in pleines) / len(pleines) > 0.8:
            faits = [re.sub(r"^[-*•]\s+", "", l) for l in pleines]
        else:
            bloc = []
            for l in utiles + [""]:
                if l:
                    bloc.append(l)
                elif bloc:
                    faits.append(" ".join(bloc)); bloc = []
    else:  # .json / .jsonl
        if ext == ".jsonl":
            donnees = [json.loads(l) for l in contenu.splitlines() if l.strip()]
        else:
            donnees = json.loads(contenu)
            if isinstance(donnees, dict):  # {"nom": …, "faits": […]} ou un seul objet
                nom = str(donnees.get("nom") or donnees.get("name") or nom)
                donnees = donnees.get("faits") or donnees.get("facts") or [donnees]
        faits = [_objet_en_fait(o) for o in donnees]
    faits = [f for f in faits if f]
    if not faits:
        raise ValueError("vide")
    return nom[:1].upper() + nom[1:], faits


class Theme:
    def __init__(self, ident, nom, faits, source, fichier):
        self.id, self.nom, self.faits, self.source, self.fichier = ident, nom, faits, source, fichier
        self.mots = [set(mots(f)) for f in self.faits]
        self.normalises = [" " + " ".join(re.findall(r"\w+", normaliser(f))) + " " for f in self.faits]


class Connaissances:
    def __init__(self, dossier_fourni, dossier_perso):
        self.dossiers = {"fourni": Path(dossier_fourni), "perso": Path(dossier_perso)}
        self.themes = {}
        self.charger()

    def charger(self):
        themes = {}
        for source, dossier in self.dossiers.items():
            if not dossier.is_dir():
                continue
            for f in sorted(dossier.iterdir()):
                if f.suffix.lower() not in EXTENSIONS or f.stat().st_size > TAILLE_MAX:
                    continue
                try:
                    nom, faits = lire(f.name, f.read_text(encoding="utf-8"))
                except (ValueError, UnicodeDecodeError, json.JSONDecodeError, csv.Error) as e:
                    print(f"[connaissances] {f.name} ignoré : {e}")
                    continue
                ident = f"{source}:{f.name}"
                themes[ident] = Theme(ident, nom, faits, source, f)
        self.themes = themes
        # Fréquence des mots sur l'ensemble des faits (pour pondérer : un mot rare compte plus).
        self.df, self.total = {}, 0
        for t in themes.values():
            for ms in t.mots:
                self.total += 1
                for m in ms:
                    self.df[m] = self.df.get(m, 0) + 1

    def liste(self, inactifs):
        return [{"id": t.id, "nom": t.nom, "source": t.source, "nb": len(t.faits), "actif": t.id not in inactifs,
                 "exemples": t.faits[:3]} for t in self.themes.values()]

    def ajouter(self, nom_fichier, contenu):
        """Enregistre un thème déposé depuis l'extension. Renvoie son identifiant."""
        if len(contenu.encode("utf-8")) > TAILLE_MAX:
            raise ValueError("taille")
        lire(nom_fichier, contenu)  # vérifie qu'il est lisible avant de l'enregistrer
        sur = re.sub(r"[^\w.-]+", "-", Path(nom_fichier).name).strip("-.") or "theme.txt"
        dossier = self.dossiers["perso"]
        dossier.mkdir(parents=True, exist_ok=True)
        (dossier / sur).write_text(contenu, encoding="utf-8")
        self.charger()
        return f"perso:{sur}"

    def supprimer(self, ident):
        t = self.themes.get(ident)
        if not t or t.source != "perso":  # les thèmes fournis se désactivent, ils ne se suppriment pas
            return False
        t.fichier.unlink(missing_ok=True)
        self.charger()
        return True

    def rechercher(self, question, choix, inactifs=()):
        """Faits des thèmes actifs les plus proches de la question et de ses choix : [(thème, fait), …]."""
        mots_question = set(mots(question))
        textes_choix = [" " + " ".join(re.findall(r"\w+", normaliser(c))) + " " for c in choix if c.strip()]
        mots_choix = set(m for c in choix for m in mots(c))
        requete = mots_question | mots_choix
        if not requete:
            return []
        idf = lambda m: math.log(1 + self.total / self.df.get(m, 1))
        resultats = []
        for t in self.themes.values():
            if t.id in inactifs:
                continue
            for i, ms in enumerate(t.mots):
                communs = ms & requete
                if not communs:
                    continue
                score = sum(idf(m) for m in communs)
                # Un choix cité en entier (« Lot-et-Garonne ») vaut plus que des mots épars.
                score += sum(2 * idf(m) for c in textes_choix if c.strip() and c in t.normalises[i] for m in mots(c)[:1])
                # Un nombre de la question présent dans le fait (« 47 ») : très discriminant.
                score += sum(3 for m in communs & mots_question if m.isdigit())
                resultats.append((score, t.nom, t.faits[i]))
        resultats.sort(key=lambda r: -r[0])
        if not resultats:
            return []
        # On ne garde que des faits nettement pertinents (au moins 35 % du meilleur score).
        seuil = resultats[0][0] * 0.35
        return [(nom, fait) for score, nom, fait in resultats[:NB_FAITS_MAX] if score >= seuil]

<p align="center">
  <img src="Streamlet.jpeg" alt="Streamlet" width="140">
</p>

<h1 align="center">Streamlet</h1>

<p align="center"><a href="README.en.md">English</a> · <b>Français</b></p>

<p align="center">
  Extension de navigateur qui lit la question de QCM affichée dans un onglet et demande à une IA
  (locale avec Ollama, ou en ligne avec Claude) un <b>indice</b> pour la trouver, et la réponse si tu le souhaites.
</p>

<p align="center">
  <img src="docs/page-indice.png" alt="Streamlet affiche un indice et la réponse en bas à droite d'une page de quiz" width="820">
</p>

> **À lire avant d'utiliser Streamlet.** Cette application est avant tout conçue pour faire du **benchmark de
> modèles d'IA en conditions réelles**. Voir l'[avertissement](#avertissement) : je me dégage de tout usage
> qui s'apparenterait à de la triche.

---

## Sommaire

- [Fonctionnement](#fonctionnement)
- [Prérequis](#prérequis)
- [Installation](#installation)
- [Charger l'extension dans le navigateur](#charger-lextension-dans-le-navigateur)
- [Gérer le serveur](#gérer-le-serveur)
- [Utilisation](#utilisation)
- [Moteurs d'IA](#moteurs-dia)
- [Fichiers générés](#fichiers-générés)
- [Options du serveur](#options-du-serveur)
- [Désinstallation](#désinstallation)
- [Dépannage](#dépannage)
- [Confidentialité](#confidentialité)
- [Publier une version](#publier-une-version)
- [Avertissement](#avertissement)

## Fonctionnement

```
 Navigateur                         Ta machine                          IA
┌─────────────────────┐   HTTP    ┌──────────────────────┐     ┌──────────────────────┐
│ Extension Streamlet │ ────────▶ │ serveur_qcm.py       │ ──▶ │ Ollama (Qwen, local) │
│ lit le HTML de      │ 127.0.0.1 │ port 8765            │     ├──────────────────────┤
│ l'onglet activé     │ ◀──────── │ indice + réponse     │ ──▶ │ Claude (en ligne)    │
└─────────────────────┘           └──────────────────────┘     └──────────────────────┘
```

1. Tu actives Streamlet sur un onglet. L'extension n'a accès qu'aux sites que tu actives.
2. À chaque changement de la page, elle repère la question et ses choix (boutons radio, cases à cocher,
   rôles ARIA, ou à défaut le texte de la page) et les envoie au serveur local.
3. Le serveur demande à l'IA un indice (et la réponse), puis l'extension l'affiche en bas à droite de la page
   ou dans la popup.

## Prérequis

| | Version |
|---|---|
| Navigateur | Chrome, Edge, Brave, Arc, Opera… (navigateurs Chromium) ou **Firefox 140+** |
| Système | macOS, Linux ou Windows 10/11 |
| Python | 3.10 ou plus : installé par le script d'installation s'il manque (Homebrew sur macOS, gestionnaire de paquets sous Linux, `winget` sous Windows) |
| Ollama | installé par le script, seulement si tu choisis l'IA locale |
| Espace disque | quelques Go pour le modèle local `qwen3.5:4b` (IA locale uniquement) |
| Claude (facultatif) | un abonnement claude.ai + [Claude Code](https://claude.com/claude-code), **ou** une clé API Anthropic |

> Safari n'est pas pris en charge.

## Installation

Clone le dépôt :

```bash
git clone <url-du-depot> Streamlet
cd Streamlet
```

Lance le script d'installation de ton système :

| Système | Commande |
|---|---|
| macOS | `./install-macos.sh` |
| Linux | `./install-linux.sh` |
| Windows (PowerShell) | `powershell -ExecutionPolicy Bypass -File install.ps1` |

> **Linux** : ce qui manque au système (Python, `python3-venv`, `curl`, Ollama) est installé avec `sudo`,
> donc ton mot de passe te sera demandé. Le script utilise le gestionnaire de paquets de ta distribution
> (apt, dnf, pacman ou zypper).

### Le questionnaire

Le script te pose quelques questions pour n'installer que ce dont tu as besoin, puis s'occupe de tout.
Appuie sur **Entrée** pour garder le choix par défaut (en gras).

| # | Question | Choix possibles |
|---|---|---|
| 1 | **Quelle IA veux-tu utiliser ?** | **Claude uniquement** (par défaut, rien de lourd à installer) · IA locale + Claude en secours · IA locale uniquement (Ollama, quelques Go) |
| 2 | **Quel modèle local ?** *(si IA locale)* | **`qwen3.5:4b`** (par défaut, ~4 Go) · `qwen3.5:2b` (plus léger) · un autre modèle Ollama de ton choix |
| 3 | **Comment accéder à Claude ?** *(si Claude)* | **ton abonnement claude.ai** via Claude Code (pas de frais en plus) · une clé API (payée à l'usage) |
| 4 | **Comment faire tourner le serveur ?** | **Durable** · Éphémère (voir ci-dessous) |
| 5 | **Ajouter l'extension à Firefox ?** *(si Firefox est installé)* | **Oui** : le script télécharge l'extension signée de la dernière Release et l'ouvre dans Firefox, il ne reste qu'à cliquer sur **Ajouter** · Non |

Avec l'abonnement, si Claude Code n'est pas installé ou pas connecté, le script propose de l'installer et
d'ouvrir la page de connexion. Un récapitulatif s'affiche ensuite, et l'installation ne démarre qu'après ta confirmation.

Le moteur de l'extension est réglé d'après tes réponses : **En ligne** (Claude seul), **Auto** (IA locale + Claude)
ou **Local**. Tu peux le changer à tout moment dans la popup, où se choisit aussi le modèle Claude
(Haiku, Sonnet ou Opus, voir [Connecter Claude](#connecter-claude)).

### Durable ou éphémère ?

Streamlet a besoin d'un petit **serveur local** (`serveur_qcm.py`, port `8765`) qui fait le lien entre
l'extension et l'IA. Il peut tourner de deux façons :

| | **Durable** (par défaut) | **Éphémère** |
|---|---|---|
| Où tourne le serveur | en tâche de fond, sans fenêtre | dans le terminal où tu as lancé le script |
| Fermer le terminal | ne l'arrête pas | **l'arrête** (comme Ctrl+C) |
| Redémarrage de l'ordinateur | il redémarre tout seul à l'ouverture de session | à relancer à la main |
| S'il plante | relancé automatiquement après 5 s | reste arrêté |
| Idéal pour | l'usage quotidien | essayer Streamlet, ou ne l'utiliser que de temps en temps |

### Ce que fait le script

1. vérifie Python 3.10+ et l'installe s'il manque (Homebrew sur macOS, `sudo apt`/`dnf`/`pacman`/`zypper` sous Linux,
   `winget` sous Windows). Sous Debian/Ubuntu, il ajoute aussi `python3-venv`, qui contient `venv` et `pip` ;
2. *si IA locale* : installe Ollama s'il est absent ([ollama.com](https://ollama.com)), le démarre et télécharge le modèle ;
3. *si abonnement Claude* : installe Claude Code et le connecte à ton compte, si tu l'as accepté ;
4. crée l'environnement Python `.venv` et installe les dépendances de `requirements.txt` ;
5. enregistre tes réglages (moteur et accès à Claude) ;
   *si tu l'as accepté* : télécharge l'extension Firefox signée (dans ton dossier Téléchargements) et l'ouvre dans Firefox ;
6. **durable** : installe le serveur en tâche de fond et le démarre ; tu peux fermer le terminal.
   **éphémère** : démarre le serveur dans le terminal ; il tourne tant que le terminal reste ouvert.
   La commande pour le relancer plus tard s'affiche avant le démarrage, puis de nouveau quand tu l'arrêtes
   avec Ctrl+C, par exemple :

   ```bash
   cd "/chemin/vers/Streamlet" && .venv/bin/python serveur_qcm.py              # macOS / Linux
   cd "C:\chemin\vers\Streamlet"; .venv\Scripts\python.exe serveur_qcm.py     # Windows
   ```

Le script peut être relancé sans risque (pour changer de mode, de modèle, ou après un `git pull`) :
ce qui est déjà installé n'est pas réinstallé.

### Sans questions

Si tu passes une option, le script ne pose aucune question. C'est pratique pour automatiser une installation :

| macOS / Linux | Windows | Effet |
|---|---|---|
| `--yes` (`--oui`) | `-Yes` (`-Oui`) | réglages par défaut (Claude par abonnement, sans IA locale, durable) |
| `--lang en` | `-Lang en` | langue des messages (`en` ou `fr`, détectée automatiquement sinon) |
| `--ephemeral` (`--ephemere`) | `-Ephemeral` (`-Ephemere`) | serveur éphémère au lieu de durable |
| `--with-ollama` (`--avec-ollama`) | `-WithOllama` (`-AvecOllama`) | ajoute l'IA locale (Ollama + `qwen3.5:4b`) |
| `--model qwen3.5:2b` (`--modele`) | `-Model qwen3.5:2b` (`-Modele`) | autre modèle Ollama (active l'IA locale) |
| `--claude api` | `-Claude api` | accès à Claude : `subscription` (défaut), `api` ou `none` (ou `abonnement`, `aucun`) |
| `--firefox` | `-Firefox` | télécharge l'extension Firefox signée et l'ouvre dans Firefox |

Exemple : `./install-linux.sh --claude api --ephemeral`.
Sans option, mais lancé sans clavier (par un autre programme, en CI…), le script prend aussi les réglages par défaut.

<details>
<summary>Installation manuelle (sans script)</summary>

```bash
# 1. Ollama : https://ollama.com/download, puis :
ollama pull qwen3.5:4b

# 2. Environnement Python
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt          # Windows : .venv\Scripts\pip install -r requirements.txt

# 3. Serveur : voir « Gérer le serveur » ci-dessous
```
</details>

## Charger l'extension dans le navigateur

Le même dossier `extension/` sert pour tous les navigateurs.

### Chrome, Edge, Brave, Arc, Opera…

1. Ouvre `chrome://extensions` (ou `edge://extensions`, `brave://extensions`…).
2. Active le **Mode développeur** (en haut à droite).
3. Clique sur **Charger l'extension non empaquetée** et choisis le dossier `extension/` du dépôt.
4. Épingle Streamlet dans la barre d'outils (icône puzzle › épingle).

Après une mise à jour du dépôt (`git pull`), clique sur ↻ dans la carte Streamlet de `chrome://extensions`.

### Firefox

1. Ouvre `about:debugging#/runtime/this-firefox`.
2. Clique sur **Charger un module complémentaire temporaire…** et choisis le fichier `extension/manifest.json`.
3. Épingle Streamlet dans la barre d'outils (icône puzzle › roue dentée › Épingler à la barre d'outils).

> **Firefox retire les extensions chargées ainsi à chaque redémarrage** : il faut refaire l'étape 2.
> Il n'installe durablement que les extensions signées par Mozilla. Pour garder Streamlet, installe le `.xpi`
> signé joint aux [Releases](../../releases) du dépôt (`about:addons` › roue dentée › **Installer un module
> depuis un fichier…**). **Firefox le met ensuite à jour tout seul** (à partir de la version 1.1) : il vérifie
> environ une fois par jour si une nouvelle version est publiée. Sur Ubuntu, Firefox (en snap) ne voit que ton
> dossier personnel : copie d'abord le `.xpi` dans `~/Téléchargements` si besoin.
>
> Sans `.xpi` signé, seules **Firefox Developer Edition** et **Nightly** gardent l'extension : dans `about:config`,
> passe `xpinstall.signatures.required` à `false`, crée le paquet (`cd extension && zip -r ../streamlet.xpi .`)
> et installe-le de la même façon.

Avec le `.xpi` signé, les mises à jour sont automatiques (`about:addons` › roue dentée › **Rechercher des mises à
jour** pour forcer la vérification). Pour la version temporaire, clique sur **Recharger** dans la carte Streamlet
de `about:debugging` après un `git pull`.

## Gérer le serveur

Le point en haut de la popup est **vert** quand le serveur tourne, **rouge** sinon.
Tu peux aussi ouvrir <http://127.0.0.1:8765/etat>.

Dans les commandes ci-dessous, remplace `.venv/bin/python` par `.venv\Scripts\python.exe` sous Windows.

### Mode durable

| Action | Commande |
|---|---|
| Installer et démarrer | `.venv/bin/python serveur_qcm.py --installer` (ce que fait le script d'installation) |
| Arrêter et retirer | `.venv/bin/python serveur_qcm.py --desinstaller` |
| Changer les réglages | relancer `--installer` avec les nouvelles options, par ex. `--installer --modele qwen3.5:2b` |
| Lire le journal | `~/.streamlet/serveur.log` (Windows : `%USERPROFILE%\.streamlet\serveur.log`) |

Comment c'est fait, selon le système :

| Système | Mécanisme | Fichier créé |
|---|---|---|
| macOS | agent **launchd** | `~/Library/LaunchAgents/app.streamlet.serveur.plist` |
| Linux | service **systemd utilisateur** | `~/.config/systemd/user/streamlet.service` |
| Windows | lanceur caché dans le dossier **Démarrage** (aucune fenêtre, aucun droit admin) | `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\Streamlet.vbs` |

> **Linux** : un service utilisateur s'arrête quand tu fermes ta session (pas quand tu fermes le terminal).
> Pour qu'il tourne même sans session ouverte : `sudo loginctl enable-linger $USER`.

### Mode éphémère

```bash
cd /chemin/vers/Streamlet
.venv/bin/python serveur_qcm.py              # macOS / Linux ; garde le terminal ouvert
.venv\Scripts\python.exe serveur_qcm.py     # Windows
```

C'est la commande que le script d'installation affiche en mode éphémère.

Ctrl+C ou fermer le terminal l'arrête. À relancer à chaque fois que tu veux utiliser Streamlet.

> Les deux modes utilisent le même port : si le mode durable est installé, le mode éphémère affiche
> « le port 8765 est déjà utilisé ». Retire d'abord le mode durable (`--desinstaller`) pour passer en éphémère.

## Utilisation

1. Va sur la page du QCM et clique sur l'icône Streamlet.
2. Active **Streamer cette page**. Le navigateur te demande l'accès à ce site, une seule fois par site.
   Le badge `ON` apparaît sur l'icône.
3. Choisis le **moteur** (voir ci-dessous).
4. Dès qu'une question est détectée, une fenêtre apparaît en bas à droite de la page : d'abord
   « Réflexion en cours… », puis l'indice (et la réponse si tu l'as activée).

<p align="center">
  <img src="docs/page-reflexion.png" alt="Pendant que l'IA réfléchit" width="49%">
  <img src="docs/page-indice.png" alt="L'indice et la réponse s'affichent" width="49%">
</p>

### Rappel et arrêt automatique

Quand Streamlet est actif sur un onglet, la popup rappelle de le désactiver après le quiz : chaque nouvelle page
de l'onglet est envoyée à l'IA, ce qui consomme des tokens avec Claude (quota d'abonnement ou crédits API).
Par sécurité, **Streamlet se coupe tout seul après 2 minutes sans question de quiz** sur la page, et l'indique
dans une petite fenêtre en bas à droite.

### Langue

L'extension s'affiche en anglais ou en français selon la langue du navigateur, et le serveur lui répond dans
la même langue (messages d'erreur, avertissements). Les scripts d'installation suivent la langue du système
(option `--lang en|fr` / `-Lang en|fr` pour la forcer). Les indices sont écrits dans la langue de la question.

### Connaissances par thème

L'IA locale (Qwen) connaît mal certains faits « par cœur », comme les numéros des départements ou les monnaies.
Les **connaissances** sont des fichiers de faits par thème, stockés sur ta machine : pour chaque question, Streamlet
y cherche les faits qui la concernent (par mots-clés : question et choix) et les donne à Qwen avec la question.
Rien ne sort de ta machine, et Claude ne s'en sert pas.

Mesuré sur le quiz des départements (moteur Local, réflexion Rapide) : **8/10 sans thème, 10/10 avec le thème
« Départements de France »**, pour le même temps (~5 s).

- **Gérer les thèmes** : dans la popup, fiche « IA locale » › **Gérer…**. La page s'ouvre dans un onglet :
  dépose un fichier (glisser-déposer ou « Choisir un fichier »), vérifie l'aperçu (nom du thème, nombre de faits,
  premiers faits), puis valide. Chaque thème s'active ou se désactive, ceux que tu as ajoutés se suppriment.
- **Formats acceptés** (5 Mo maximum, texte en UTF-8) :

  | Fichier | Comment il est lu |
  |---|---|
  | `.csv` | chaque ligne est un fait, avec les noms de colonnes (« numéro : 47 · département : Lot-et-Garonne »). Séparateur : virgule, point-virgule ou tabulation. Le plus simple : exporter depuis Excel, Numbers ou Google Sheets |
  | `.txt` / `.md` | chaque ligne est un fait (ou chaque paragraphe, pour un texte rédigé) ; une première ligne `# Titre` donne le nom du thème |
  | `.json` / `.jsonl` | une liste d'objets ou de phrases, un fait par élément (JSONL : un par ligne) |

  Le thème prend le nom du fichier, ou son `# Titre`. La page propose des modèles CSV et TXT à télécharger.
- **Où sont les fichiers** : les thèmes fournis avec Streamlet sont dans `connaissances/` (dans le dépôt) ; ceux que
  tu ajoutes sont dans `~/.streamlet/connaissances/`. Tu peux aussi y déposer un fichier à la main : il est pris en
  compte au prochain démarrage du serveur.
- **Thème fourni** : *Départements de France* (101 départements : numéro, nom, préfecture, région), construit à partir
  du [Code officiel géographique 2024 de l'INSEE](https://www.insee.fr/fr/information/7766585) (Licence Ouverte Etalab 2.0).

### La popup

<p align="center">
  <img src="docs/popup.png" alt="Popup de Streamlet, thème clair" width="300">
  &nbsp;&nbsp;
  <img src="docs/popup-sombre.png" alt="Popup de Streamlet, thème sombre" width="300">
</p>

De haut en bas : état du serveur (point vert), interrupteur de l'onglet, choix du moteur, puis selon le moteur :
- **Local** : la réflexion de l'IA locale et une fiche sur le modèle local (nom, mémoire utilisée par rapport à
  celle de la machine, part sur le GPU, taille sur le disque, délai avant que la mémoire soit libérée) ;
  la partie Claude est masquée, puisqu'il n'est jamais appelé ;
- **Auto** : les deux ;
- **En ligne** : la connexion à Claude et le choix du modèle Claude.

Ensuite viennent les réglages d'affichage. Quand « Notification sur la page » est coupée, le résultat s'affiche
dans la popup (comme ci-dessus) au lieu de la page. La popup suit le thème clair ou sombre du système.

Réglages de la popup :

| Réglage | Effet |
|---|---|
| Réflexion de l'IA locale *(moteurs Local et Auto)* | **Rapide** (~5 s, Qwen réfléchit 3 s puis donne la réponse seule, **sans indice** : avec si peu de réflexion, les indices sont peu fiables ; moins sûr sur les questions pièges ou en plusieurs étapes) ou **Normale** (~25 s, Qwen réfléchit jusqu'à 20 s puis donne un indice et la réponse). Appliqué tout de suite, sans redémarrer le serveur |
| Notification sur la page | affiche les résultats sur la page ; sinon ils restent dans la popup |
| Afficher l'indice | montre l'indice |
| Afficher la réponse | montre aussi la bonne réponse (désactivé par défaut) |
| Capturer les images illisibles | quand une question contient une image d'un autre site, l'extension en fait une capture d'écran. Demande l'accès à tous les sites. Sinon : **clic droit sur l'image › « Streamlet : lire cette image »** |

Badges de l'icône : `ON` = actif · `✗` = serveur injoignable · `!` = page impossible à lire (page interne du navigateur, Chrome Web Store…).

## Moteurs d'IA

| Moteur | Ce qui se passe | Coût | Confidentialité |
|---|---|---|---|
| **Local** | Qwen via Ollama, sur ta machine (environ 25 s par question, ou 5 s en réflexion « Rapide », qui donne la réponse sans indice) | gratuit | rien ne sort de ta machine |
| **Auto** | Qwen d'abord ; Claude prend le relais si Qwen est trop lent (90 s), échoue ou est arrêté | gratuit le plus souvent | Claude seulement en secours |
| **En ligne** | Claude directement : plus rapide, comprend les images et les pages complexes | voir ci-dessous | la question est envoyée à Anthropic |

### Connecter Claude

Dans la popup, section **Claude**, choisis l'accès :

- **Abonnement** (Claude Pro / Max) : passe par [Claude Code](https://claude.com/claude-code), sans clé API.
  1. Installe Claude Code (voir le lien), ou laisse le script d'installation le faire.
  2. Dans un terminal : `claude auth login`, avec ton compte claude.ai.
  3. La popup affiche « connecté ». Les appels comptent dans les limites de ton abonnement.
- **Clé API** : crée une clé sur [console.anthropic.com](https://console.anthropic.com/settings/keys), colle-la dans la popup.
  Elle est rangée dans le trousseau du système (Trousseau macOS, Gestionnaire d'identification Windows,
  Secret Service sous Linux), jamais dans l'extension. Facturée au token ; le coût estimé s'affiche dans la popup.
  La variable d'environnement `ANTHROPIC_API_KEY` est aussi reconnue.

Choisis ensuite le modèle : **Haiku** (le plus rapide), **Sonnet** (recommandé) ou **Opus** (le plus fin).

## Fichiers générés

Dans le dossier du projet (ignorés par git) :

| Fichier | Contenu |
|---|---|
| `qcm.json` | questions détectées, choix et leur position, indice, réponse (sans doublons) |
| `raisonnements.jsonl` | raisonnement / explication du modèle, une ligne JSON par question |

**Conservation : 24 h.** Les questions et raisonnements plus vieux sont supprimés automatiquement, au démarrage
du serveur et à chaque nouvelle question. Les fichiers restent donc légers.

Pourquoi ne pas les effacer dès l'affichage ? `qcm.json` sert aussi de **cache**. L'extension renvoie la page
à chaque changement (clic sur un choix, rafraîchissement, retour en arrière), et une question déjà présente est
réaffichée tout de suite, sans rappeler l'IA, donc sans attente ni quota consommé.

Pour changer la durée : `serveur_qcm.py --conservation 2` (heures), ou `--conservation 0` pour tout garder.

Réglages de la popup : `~/.streamlet/config.json`.

> **Versions 1.0 et avant** : les réglages étaient dans `~/.shabcode/` et la clé API sous le nom `shabcode-qcm`
> dans le trousseau. Le serveur les reprend automatiquement au premier lancement (les anciens ne sont pas
> supprimés).

## Options du serveur

```bash
.venv/bin/python serveur_qcm.py --help
```

| Option | Défaut | Rôle |
|---|---|---|
| `--modele` | `qwen3.5:4b` | modèle Ollama qui écrit l'indice (avec raisonnement) |
| `--modele-rapide` | `qwen3.5:4b` | modèle Ollama qui repère la question sur les pages sans boutons radio |
| `--reflexion-max` | `20` | durée de la réflexion « Normale » en secondes (le choix Rapide / Normale se fait dans la popup ; `0` = Rapide par défaut) |
| `--delai-local` | `90` | moteur Auto : secondes laissées à Qwen avant de passer à Claude |
| `--port` | `8765` | port du serveur. Si tu le changes, change aussi `SERVEUR` dans `extension/background.js` et `extension/popup.js` |
| `--out` | `qcm.json` | fichier des QCM |
| `--raisonnements` | `raisonnements.jsonl` | fichier des raisonnements |
| `--conservation` | `24` | heures pendant lesquelles les questions sont gardées (`0` = toujours) |
| `--installer` / `--desinstaller` | | installe / retire le serveur en mode durable |
| `--journal` | | écrit la sortie du serveur dans un fichier au lieu du terminal |

Les options passées avec `--installer` sont reprises par la tâche de fond, par ex.
`serveur_qcm.py --installer --modele qwen3.5:2b`.

## Désinstallation

```bash
.venv/bin/python serveur_qcm.py --desinstaller    # Windows : .venv\Scripts\python.exe serveur_qcm.py --desinstaller
ollama rm qwen3.5:4b                              # libère l'espace du modèle
```

Puis retire l'extension (`chrome://extensions`, ou `about:addons` sous Firefox), supprime le dossier du projet
et le dossier des réglages `~/.streamlet/`. Ollama se désinstalle comme une application classique.

## Dépannage

| Symptôme | Solution |
|---|---|
| « serveur arrêté » dans la popup, badge `✗` | lance le serveur (voir [Gérer le serveur](#gérer-le-serveur)) ou consulte le journal `~/.streamlet/serveur.log` |
| `le port 8765 est déjà utilisé` | un serveur tourne déjà (souvent la tâche de fond) : rien à faire, ou `--desinstaller` |
| Moteur Local trop lent ou sans réponse | vérifie qu'Ollama tourne (`ollama list`) ; passe la réflexion sur « Rapide » dans la popup, prends un modèle plus léger (`--modele qwen3.5:2b`) ou le moteur Auto |
| `model not found` | `ollama pull qwen3.5:4b` (ou le modèle passé avec `--modele`) |
| Claude « non connecté » (abonnement) | `claude auth login` dans un terminal ; vérifie avec `claude auth status` |
| Ubuntu / Debian : `No module named pip` | relance `./install-linux.sh` : il installe `python3-venv` et recrée le `.venv`. À la main : `sudo apt install python3-venv`, puis `rm -rf .venv` et relance le script |
| Linux : erreur `keyring` avec une clé API | installe un trousseau Secret Service (`sudo apt install gnome-keyring`, ou KWallet), ou utilise `ANTHROPIC_API_KEY` |
| Linux : le serveur durable s'arrête à la déconnexion | `sudo loginctl enable-linger $USER` |
| Le serveur s'arrête quand je ferme le terminal | c'est le mode éphémère : relance le script d'installation et choisis « Durable » |
| Windows : « l'exécution de scripts est désactivée » | lance le script avec `powershell -ExecutionPolicy Bypass -File install.ps1` |
| Aucune question détectée | recharge la page ; certaines pages très dynamiques nécessitent le moteur « En ligne » |

## Confidentialité

- L'extension n'a accès qu'aux sites que tu actives un par un, et ne parle qu'au serveur local `127.0.0.1:8765`.
- Le serveur n'accepte que les requêtes locales.
- En moteur **Local**, rien ne quitte ta machine. En **Auto** (secours) et **En ligne**, le contenu de la
  question (texte et éventuelles images) est envoyé à Anthropic.
- Les fichiers `qcm.json` et `raisonnements.jsonl` restent sur ta machine et ne sont pas versionnés.

## Publier une version

*Pour les mainteneurs du dépôt.* Firefox n'installe durablement que les extensions signées par Mozilla :
chaque version est donc signée, puis le fichier `.xpi` est joint à une Release GitHub.

### Une seule fois : les clés de signature

1. Crée un compte développeur sur [addons.mozilla.org](https://addons.mozilla.org/developers/) et accepte l'accord.
2. Génère tes clés sur la [page des clés d'API](https://addons.mozilla.org/developers/addon/api/key/).
3. Range-les dans un fichier `.env` à la racine du projet (ignoré par git, **ne jamais le commiter**) :

   ```
   WEB_EXT_API_KEY=user:12345:678
   WEB_EXT_API_SECRET=ton-secret
   ```

En cas de fuite, révoque-les sur la même page et génères-en de nouvelles.

### À chaque version

1. Augmente `"version"` dans `extension/manifest.json` (ex. `1.1` → `1.2`) : Mozilla refuse deux envois avec le
   même numéro.
2. Commit et push du code.
3. Lance le script de publication. Il signe l'extension chez Mozilla (sans la publier sur son catalogue,
   vérification automatique en quelques minutes), range le fichier dans `web-ext-artifacts/streamlet-<version>.xpi`
   et ajoute la version à `updates.json` :

   ```bash
   ./scripts/publier-firefox.sh
   ```

4. Commit et push de `updates.json`.
5. Crée la Release GitHub `v<version>` et joins-y le `.xpi` **sans le renommer** (par ex. avec `gh` :
   `gh release create v1.2 web-ext-artifacts/streamlet-1.2.xpi --title "Streamlet 1.2" --notes "…"`).

`updates.json` (à la racine du dépôt) est le fichier que Firefox consulte pour les mises à jour automatiques
(`update_url` dans `extension/manifest.json`). L'ordre compte : publie la Release avant ou en même temps que le
push de `updates.json`, sinon Firefox trouverait une version annoncée mais pas encore téléchargeable (il
réessaiera simplement plus tard).

> L'identifiant `streamlet@streamlet.app` (`extension/manifest.json`) est lié au compte qui signe la première
> version : il ne doit plus changer ensuite.

## Avertissement

Streamlet est avant tout conçu comme un outil de **benchmark dynamique de modèles d'IA** : comparer, sur de vraies
pages de questions et en conditions réelles, des modèles locaux et en ligne (justesse des réponses, temps de
réponse, effet de la réflexion et des connaissances par thème, mémoire utilisée).

L'auteur se dégage de toute responsabilité quant aux usages qui pourraient s'apparenter à de la triche (examens,
concours, évaluations notées, tests de recrutement…) ou qui contreviendraient au règlement d'un site, d'un
établissement ou d'une plateforme. Chaque utilisateur reste seul responsable de l'usage qu'il fait de Streamlet.

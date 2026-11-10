﻿# Streamlet — installation pour Windows / installer for Windows  (macOS : install-macos.sh · Linux : install-linux.sh)
#   powershell -ExecutionPolicy Bypass -File install.ps1         questionnaire / interactive questions
#   powershell -ExecutionPolicy Bypass -File install.ps1 -Yes    sans questions, réglages par défaut / no questions, default settings
# Options (sans questions / no questions) :
#   -Lang en|fr                         langue des messages / message language (auto-detected)
#   -Ephemeral (-Ephemere)              serveur dans ce terminal / server in this terminal instead of background
#   -WithOllama (-AvecOllama)           ajoute l'IA locale / add the local AI (Ollama)
#   -Model qwen3.5:2b (-Modele)         modèle Ollama / Ollama model (implies -WithOllama)
#   -Claude subscription|api|none       accès à Claude / Claude access (abonnement|api|aucun)
param(
    [ValidateSet("en", "fr")][Alias("Langue")][string]$Lang,
    [Alias("Oui")][switch]$Yes,
    [Alias("Ephemere")][switch]$Ephemeral,
    [Alias("AvecOllama")][switch]$WithOllama,
    [Alias("SansOllama")][switch]$WithoutOllama,
    [Alias("Modele")][string]$Model,
    [ValidateSet("subscription", "api", "none", "abonnement", "aucun")][string]$Claude
)
# "Continue" : sous Windows PowerShell 5.1, "Stop" fait planter le script dès qu'un programme externe écrit
# sur stderr redirigé. Les erreurs sont vérifiées une par une ($LASTEXITCODE, -ErrorAction Stop).
$ErrorActionPreference = "Continue"
Set-Location -Path $PSScriptRoot
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# ---------- Langue / language ----------
if (-not $Lang) { $Lang = if ((Get-UICulture).TwoLetterISOLanguageName -eq "fr") { "fr" } else { "en" } }
# L "texte français" "English text" → le texte dans la langue choisie
function L([string]$fr, [string]$en) { if ($script:Lang -eq "fr") { $fr } else { $en } }

function Ok($m)    { Write-Host "OK  $m" -ForegroundColor Green }
function Info($m)  { Write-Host "->  $m" -ForegroundColor Cyan }
function Avert($m) { Write-Host "!   $m" -ForegroundColor Yellow }
function Ko($m)    { Write-Host "X   $m" -ForegroundColor Red; exit 1 }
function Gras($m)  { Write-Host $m -ForegroundColor White }
function Rafraichir-Path {
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
                [Environment]::GetEnvironmentVariable("Path", "User")
}
$aWinget = [bool](Get-Command winget -ErrorAction SilentlyContinue)

# ---------- Réglages (par défaut : Claude uniquement, sans IA locale) ----------
$avecOllama = [bool]$WithOllama -or [bool]$Model
if ($WithoutOllama) { $avecOllama = $false }
$Modele = if ($Model) { $Model } else { "qwen3.5:4b" }
$claudeAcces = if (-not $Claude -or $Claude -eq "subscription") { "abonnement" } elseif ($Claude -eq "none") { "aucun" } else { $Claude }
$Ephemere = [bool]$Ephemeral
$installerClaudeCode = $false
$connecterClaudeCode = $false
$autres = @($PSBoundParameters.Keys | Where-Object { $_ -ne "Lang" })
$questionnaire = ($autres.Count -eq 0) -and -not [Console]::IsInputRedirected
$ecrireConfig = $questionnaire -or $Yes -or $PSBoundParameters.ContainsKey("Claude")

# ---------- Questionnaire ----------
$script:etape = 0
function Choix([string]$question, [string[]]$options) {
    $script:etape++
    Write-Host ""
    Gras "$($script:etape). $question"
    for ($i = 0; $i -lt $options.Count; $i++) { Write-Host "  $($i + 1)) $($options[$i])" }
    while ($true) {
        $r = Read-Host "$(L 'Ton choix' 'Your choice') [1]"
        if ([string]::IsNullOrWhiteSpace($r)) { return 1 }
        $n = 0
        if ([int]::TryParse($r, [ref]$n) -and $n -ge 1 -and $n -le $options.Count) { return $n }
        Write-Host "  $(L 'Réponds par un numéro entre 1 et' 'Answer with a number between 1 and') $($options.Count)."
    }
}
function OuiNon([string]$question) {
    $r = Read-Host "$question $(L '[O/n]' '[Y/n]')"
    return -not ($r -match '^[nN]')
}
function ClaudeCode {
    $c = Get-Command claude -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $local = Join-Path $env:USERPROFILE ".local\bin\claude.exe"
    if (Test-Path $local) { return $local }
    return $null
}

if ($questionnaire) {
    Write-Host ""
    Gras (L "Installation de Streamlet" "Streamlet setup")
    Write-Host (L "Quelques questions pour n'installer que ce dont tu as besoin (Entrée = choix par défaut)." `
                  "A few questions to install only what you need (Enter = default choice).")

    switch (Choix (L "Quelle IA veux-tu utiliser ?" "Which AI do you want to use?") @(
        (L "Claude uniquement : rien de lourd à installer, rapide (les questions sont envoyées à Anthropic)" `
           "Claude only: nothing heavy to install, fast (questions are sent to Anthropic)"),
        (L "IA locale + Claude en secours : gratuit la plupart du temps (Ollama, quelques Go, machine correcte)" `
           "Local AI + Claude as fallback: free most of the time (Ollama, a few GB, a decent computer)"),
        (L "IA locale uniquement : gratuit, rien ne sort de ta machine (Ollama, quelques Go, machine correcte)" `
           "Local AI only: free, nothing leaves your computer (Ollama, a few GB, a decent computer)"))) {
        1 { $avecOllama = $false; $claudeAcces = "abonnement" }
        2 { $avecOllama = $true;  $claudeAcces = "abonnement" }
        3 { $avecOllama = $true;  $claudeAcces = "aucun" }
    }

    if ($avecOllama) {
        switch (Choix (L "Quel modèle local (via Ollama) ?" "Which local model (via Ollama)?") @(
            (L "qwen3.5:4b (par défaut, ~4 Go)" "qwen3.5:4b (default, ~4 GB)"),
            (L "qwen3.5:2b (plus léger, pour les machines modestes)" "qwen3.5:2b (lighter, for modest computers)"),
            (L "Un autre modèle Ollama (tu donnes son nom)" "Another Ollama model (you type its name)"))) {
            1 { $Modele = "qwen3.5:4b" }
            2 { $Modele = "qwen3.5:2b" }
            3 { $Modele = Read-Host (L "Nom du modèle (ex. qwen3.5:9b)" "Model name (e.g. qwen3.5:9b)"); if (-not $Modele) { $Modele = "qwen3.5:4b" } }
        }
    }

    if ($claudeAcces -ne "aucun") {
        $r = Choix (L "Comment accéder à Claude ?" "How do you want to access Claude?") @(
            (L "Avec mon abonnement claude.ai (Pro / Max), via Claude Code : pas de frais en plus" `
               "With my claude.ai subscription (Pro / Max), via Claude Code: no extra cost"),
            (L "Avec une clé API Anthropic : payée à l'usage, à coller ensuite dans la popup de l'extension" `
               "With an Anthropic API key: pay as you go, to paste later in the extension popup"))
        $claudeAcces = if ($r -eq 1) { "abonnement" } else { "api" }

        if ($claudeAcces -eq "abonnement") {
            $cc = ClaudeCode
            if (-not $cc) {
                Write-Host ""; Avert (L "Claude Code n'est pas installé : il est nécessaire pour utiliser ton abonnement." `
                                        "Claude Code is not installed: it is needed to use your subscription.")
                if (OuiNon ("  " + (L "L'installer maintenant ?" "Install it now?"))) { $installerClaudeCode = $true; $connecterClaudeCode = $true }
            } elseif (-not (((& $cc auth status 2>$null) -join "") -match '"authMethod":\s*"claude\.ai"')) {
                Write-Host ""; Avert (L "Claude Code est installé mais pas connecté à ton abonnement." `
                                        "Claude Code is installed but not signed in to your subscription.")
                if (OuiNon ("  " + (L "Te connecter maintenant (ouvre le navigateur) ?" "Sign in now (opens the browser)?"))) { $connecterClaudeCode = $true }
            } else {
                Ok (L "Claude Code est déjà connecté à ton abonnement." "Claude Code is already signed in to your subscription.")
            }
        }
    }

    $r = Choix (L "Comment faire tourner le serveur local de Streamlet ?" "How should Streamlet's local server run?") @(
        (L "Durable (par défaut) : en tâche de fond, démarre avec ta session, tu peux fermer le terminal" `
           "Persistent (default): in the background, starts with your session, you can close the terminal"),
        (L "Éphémère : dans ce terminal, il s'arrête quand tu le fermes (à relancer à chaque fois)" `
           "Ephemeral: in this terminal, it stops when you close it (start it again each time)"))
    $Ephemere = ($r -eq 2)
}

# Moteur par défaut de l'extension, d'après les choix
if ($avecOllama -and $claudeAcces -ne "aucun") { $moteur = "auto" }
elseif ($avecOllama) { $moteur = "local" }
elseif ($claudeAcces -ne "aucun") { $moteur = "claude" }
else { Ko (L "Il faut au moins une IA : Claude ou l'IA locale (-WithOllama)." "At least one AI is needed: Claude or the local AI (-WithOllama).") }

if ($questionnaire) {
    Write-Host ""; Gras (L "Récapitulatif" "Summary")
    Write-Host ("  " + (L "IA locale" "Local AI ") + " : " + $(if ($avecOllama) { "Ollama + $Modele" } else { L "non" "no" }))
    switch ($claudeAcces) {
        "abonnement" {
            $aFaire = if ($installerClaudeCode) { L ", installé et connecté par ce script" ", installed and signed in by this script" }
                      elseif ($connecterClaudeCode) { L ", connecté par ce script" ", signed in by this script" } else { "" }
            Write-Host ("  Claude    : " + (L "via ton abonnement" "via your subscription") + " (Claude Code$aFaire), " + (L "modèle à choisir dans la popup" "model to pick in the popup"))
        }
        "api"   { Write-Host ("  Claude    : " + (L "via clé API (à coller dans la popup), modèle à choisir dans la popup" "via API key (to paste in the popup), model to pick in the popup")) }
        "aucun" { Write-Host ("  Claude    : " + (L "non" "no")) }
    }
    Write-Host ("  " + (L "Moteur" "Engine") + "    : $moteur")
    Write-Host ("  " + (L "Serveur" "Server ") + "   : " + $(if ($Ephemere) { L "éphémère (dans ce terminal)" "ephemeral (in this terminal)" } else { L "durable (tâche de fond)" "persistent (background)" }))
    Write-Host ""
    if (-not (OuiNon (L "Lancer l'installation ?" "Start the installation?"))) { Write-Host (L "Installation annulée." "Installation cancelled."); exit 0 }
}
Write-Host ""

# ---------- Python ----------
function Trouver-Python {
    foreach ($c in @(@("py", "-3"), @("python"))) {
        if (Get-Command $c[0] -ErrorAction SilentlyContinue) {
            $a = @($c | Select-Object -Skip 1) + @("-c", "import sys; sys.exit(sys.version_info < (3, 10))")
            & $c[0] @a 2>$null
            if ($LASTEXITCODE -eq 0) { return ,$c }
        }
    }
    return $null
}
$py = Trouver-Python
if (-not $py) {
    if (-not $aWinget) { Ko (L "Python 3.10+ introuvable. Installe-le depuis https://www.python.org/downloads/ puis relance." "Python 3.10+ not found. Install it from https://www.python.org/downloads/ then run again.") }
    Info (L "Installation de Python…" "Installing Python…")
    winget install -e --id Python.Python.3.12 --silent --accept-package-agreements --accept-source-agreements
    Rafraichir-Path
    $py = Trouver-Python
    if (-not $py) { Ko (L "Python installé mais introuvable : ouvre un nouveau terminal et relance ce script." "Python installed but not found: open a new terminal and run this script again.") }
}
$pyExe = $py[0]; $pyArgs = @($py | Select-Object -Skip 1)
Ok ("Python : " + (& $pyExe @pyArgs --version))

# ---------- Ollama ----------
function Ollama-Repond {
    try { Invoke-RestMethod -Uri "http://127.0.0.1:11434/api/version" -TimeoutSec 2 | Out-Null; return $true }
    catch { return $false }
}

if ($avecOllama) {
    if (-not (Get-Command ollama -ErrorAction SilentlyContinue)) {
        Info (L "Installation d'Ollama…" "Installing Ollama…")
        if ($aWinget) {
            winget install -e --id Ollama.Ollama --silent --accept-package-agreements --accept-source-agreements
        } else {
            $setup = Join-Path $env:TEMP "OllamaSetup.exe"
            Invoke-WebRequest -Uri "https://ollama.com/download/OllamaSetup.exe" -OutFile $setup -ErrorAction Stop
            Start-Process -FilePath $setup -ArgumentList "/SILENT" -Wait
        }
        Rafraichir-Path
        if (-not (Get-Command ollama -ErrorAction SilentlyContinue)) {
            $local = Join-Path $env:LOCALAPPDATA "Programs\Ollama"
            if (Test-Path (Join-Path $local "ollama.exe")) { $env:Path += ";$local" }
            else { Ko (L "Ollama installé mais introuvable : ouvre un nouveau terminal et relance ce script." "Ollama installed but not found: open a new terminal and run this script again.") }
        }
    }
    Ok (L "Ollama installé" "Ollama installed")

    if (-not (Ollama-Repond)) {
        Info (L "Démarrage d'Ollama…" "Starting Ollama…")
        $appli = Join-Path $env:LOCALAPPDATA "Programs\Ollama\ollama app.exe"
        if (Test-Path $appli) { Start-Process -FilePath $appli }   # l'appli se lance aussi à chaque session
        else { Start-Process -FilePath "ollama" -ArgumentList "serve" -WindowStyle Hidden }
        for ($i = 0; $i -lt 30 -and -not (Ollama-Repond); $i++) { Start-Sleep -Seconds 1 }
        if (-not (Ollama-Repond)) { Ko (L "Ollama ne répond pas sur http://127.0.0.1:11434 : lance « ollama serve » puis relance." "Ollama is not responding on http://127.0.0.1:11434: run “ollama serve” then run again.") }
    }
    Ok (L "Ollama actif" "Ollama running")

    Info (L "Téléchargement du modèle $Modele (plusieurs Go la première fois)…" "Downloading the $Modele model (several GB the first time)…")
    ollama pull $Modele
    if ($LASTEXITCODE -ne 0) { Ko ((L "Échec du téléchargement de" "Could not download") + " $Modele") }
    Ok (L "Modèle $Modele prêt" "Model $Modele ready")
} else {
    Info (L "Pas d'IA locale (Ollama non installé) : moteur « En ligne » (Claude)." "No local AI (Ollama not installed): “Online” engine (Claude).")
}

# ---------- Claude Code (abonnement) ----------
if ($installerClaudeCode) {
    Info (L "Installation de Claude Code…" "Installing Claude Code…")
    Invoke-RestMethod -Uri "https://claude.ai/install.ps1" -ErrorAction Stop | Invoke-Expression
    Rafraichir-Path
    if (-not (ClaudeCode)) { Ko (L "Claude Code installé mais introuvable : ouvre un nouveau terminal et relance ce script." "Claude Code installed but not found: open a new terminal and run this script again.") }
    Ok (L "Claude Code installé" "Claude Code installed")
}
if ($connecterClaudeCode) {
    Info (L "Connexion de Claude Code à ton abonnement (une page va s'ouvrir dans le navigateur)…" "Signing Claude Code in to your subscription (a page will open in the browser)…")
    & (ClaudeCode) auth login --claudeai
    if ($LASTEXITCODE -eq 0) { Ok (L "Claude Code connecté" "Claude Code signed in") }
    else { Avert (L "Connexion non terminée : tu pourras la faire plus tard avec « claude auth login »." "Sign-in not finished: you can do it later with “claude auth login”.") }
}

# ---------- Environnement Python ----------
$venvPy = Join-Path $PSScriptRoot ".venv\Scripts\python.exe"
if (-not (Test-Path $venvPy)) {
    Info (L "Création de l'environnement Python (.venv)…" "Creating the Python environment (.venv)…")
    & $pyExe @pyArgs -m venv .venv
    if ($LASTEXITCODE -ne 0) { Ko (L "Échec de « python -m venv »" "“python -m venv” failed") }
}
& $venvPy -m pip install --quiet --upgrade pip
& $venvPy -m pip install --quiet -r requirements.txt
if ($LASTEXITCODE -ne 0) { Ko (L "Échec de l'installation des dépendances Python" "Could not install the Python dependencies") }
Ok (L "Dépendances Python installées" "Python dependencies installed")

# ---------- Réglages de l'extension (moteur et accès Claude ; le modèle Claude se choisit dans la popup) ----------
if ($ecrireConfig) {
    $accesConfig = if ($claudeAcces -eq "aucun") { "abonnement" } else { $claudeAcces }
    $code = @'
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
'@
    # Passé par un fichier : PowerShell 5.1 abîme les guillemets des arguments de programmes externes.
    $fichierCode = Join-Path $env:TEMP "streamlet_config.py"
    Set-Content -Path $fichierCode -Value $code -Encoding ASCII
    & $venvPy $fichierCode $moteur $accesConfig
    Remove-Item $fichierCode -ErrorAction SilentlyContinue
    if ($LASTEXITCODE -ne 0) { Ko (L "Échec de l'enregistrement des réglages" "Could not save the settings") }
    Ok (L "Réglages enregistrés (moteur $moteur), modifiables à tout moment dans la popup" "Settings saved ($moteur engine), you can change them anytime in the popup")
}

# ---------- Serveur ----------
$options = @()
if ($avecOllama -and $Modele -ne "qwen3.5:4b") { $options = @("--modele", $Modele, "--modele-rapide", $Modele) }
$etapes = @(
    "  1. " + (L "Charge l'extension (dossier extension\, voir le README) :" "Load the extension (extension\ folder, see the README):"),
    "       Chrome / Edge / Brave : chrome://extensions > " + (L "Mode développeur > « Charger l'extension non empaquetée »" "Developer mode > “Load unpacked”"),
    "       Firefox : " + (L "installe le .xpi signé des Releases GitHub, ou about:debugging > Ce Firefox > « Charger un module complémentaire temporaire »" "install the signed .xpi from the GitHub Releases, or about:debugging > This Firefox > “Load Temporary Add-on”")
)
if ($claudeAcces -eq "api") { $etapes += "  2. " + (L "Colle ta clé API dans la popup de l'extension (section Claude > Clé API)" "Paste your API key in the extension popup (Claude section > API key)") }

Write-Host ""
if ($Ephemere) {
    # Commande complète (avec le dossier) : elle marche depuis n'importe quel terminal PowerShell.
    $relancer = "cd `"$PSScriptRoot`"; .venv\Scripts\python.exe serveur_qcm.py" + $(if ($options) { " " + ($options -join " ") } else { "" })
    function Afficher-Relance {
        Write-Host ""
        Gras (L "Pour relancer Streamlet plus tard, copie cette commande dans PowerShell :" "To start Streamlet again later, copy this command into PowerShell:")
        Write-Host ""
        Write-Host "    $relancer"
        Write-Host ""
    }
    Ok (L "Installation terminée (éphémère)." "Installation complete (ephemeral).")
    $etapes | ForEach-Object { Write-Host $_ }
    Afficher-Relance
    Write-Host (L "Le serveur démarre ci-dessous : garde ce terminal ouvert. Ctrl+C ou fermer le terminal l'arrête." "The server starts below: keep this terminal open. Ctrl+C or closing the terminal stops it.")
    Write-Host ""
    try { & $venvPy serveur_qcm.py @options }
    finally { Afficher-Relance }   # rappel à l'arrêt du serveur (Ctrl+C)
} else {
    & $venvPy serveur_qcm.py --installer @options
    if ($LASTEXITCODE -ne 0) { Ko (L "Échec de l'installation du serveur en tâche de fond" "Could not install the background server") }
    Ok (L "Installation terminée (durable) : tu peux fermer ce terminal." "Installation complete (persistent): you can close this terminal.")
    $etapes | ForEach-Object { Write-Host $_ }
    Write-Host ("  " + (L "Arrêter et retirer la tâche de fond" "Stop and remove the background service") + " : .venv\Scripts\python.exe serveur_qcm.py --desinstaller")
}

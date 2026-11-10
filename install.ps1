# Streamlet — installation pour Windows (macOS / Linux : utiliser install.sh).
#   powershell -ExecutionPolicy Bypass -File install.ps1          questionnaire : choisis ce qu'il faut installer
#   powershell -ExecutionPolicy Bypass -File install.ps1 -Oui     sans questions, réglages recommandés
# Options (sans questions) :
#   -Ephemere                       serveur dans ce terminal (s'arrête quand on le ferme) au lieu de durable
#   -Modele qwen3.5:2b              autre modèle Ollama
#   -SansOllama                     sans IA locale (Claude uniquement)
#   -Claude abonnement|api|aucun    accès à Claude (abonnement = via Claude Code)
param(
    [switch]$Oui,
    [switch]$Ephemere,
    [string]$Modele = "qwen3.5:4b",
    [switch]$SansOllama,
    [ValidateSet("abonnement", "api", "aucun")][string]$Claude = "abonnement"
)
# "Continue" : sous Windows PowerShell 5.1, "Stop" fait planter le script dès qu'un programme externe écrit
# sur stderr redirigé. Les erreurs sont vérifiées une par une ($LASTEXITCODE, -ErrorAction Stop).
$ErrorActionPreference = "Continue"
Set-Location -Path $PSScriptRoot
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

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

# ---------- Réglages ----------
$avecOllama = -not $SansOllama
$claudeAcces = $Claude
$installerClaudeCode = $false
$connecterClaudeCode = $false
$questionnaire = ($PSBoundParameters.Count -eq 0) -and -not [Console]::IsInputRedirected
$ecrireConfig = $questionnaire -or $Oui -or $PSBoundParameters.ContainsKey("Claude")

# ---------- Questionnaire ----------
$script:etape = 0
function Choix([string]$question, [string[]]$options) {
    $script:etape++
    Write-Host ""
    Gras "$($script:etape). $question"
    for ($i = 0; $i -lt $options.Count; $i++) { Write-Host "  $($i + 1)) $($options[$i])" }
    while ($true) {
        $r = Read-Host "Ton choix [1]"
        if ([string]::IsNullOrWhiteSpace($r)) { return 1 }
        $n = 0
        if ([int]::TryParse($r, [ref]$n) -and $n -ge 1 -and $n -le $options.Count) { return $n }
        Write-Host "  Réponds par un numéro entre 1 et $($options.Count)."
    }
}
function OuiNon([string]$question) {
    $r = Read-Host "$question [O/n]"
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
    Gras "Installation de Streamlet"
    Write-Host "Quelques questions pour n'installer que ce dont tu as besoin (Entrée = choix recommandé)."

    switch (Choix "Quelle IA veux-tu utiliser ?" @(
        "IA locale + Claude en secours (recommandé) : gratuit la plupart du temps, Claude prend le relais si besoin",
        "IA locale uniquement : gratuit, rien ne sort de ta machine (quelques Go, machine correcte)",
        "Claude uniquement : rien de lourd à installer, mais les questions sont envoyées à Anthropic")) {
        1 { $avecOllama = $true;  $claudeAcces = "abonnement" }
        2 { $avecOllama = $true;  $claudeAcces = "aucun" }
        3 { $avecOllama = $false; $claudeAcces = "abonnement" }
    }

    if ($avecOllama) {
        switch (Choix "Quel modèle local (via Ollama) ?" @(
            "qwen3.5:4b (recommandé, ~4 Go)",
            "qwen3.5:2b (plus léger, pour les machines modestes)",
            "Un autre modèle Ollama (tu donnes son nom)")) {
            1 { $Modele = "qwen3.5:4b" }
            2 { $Modele = "qwen3.5:2b" }
            3 { $Modele = Read-Host "Nom du modèle (ex. qwen3.5:9b)"; if (-not $Modele) { $Modele = "qwen3.5:4b" } }
        }
    }

    if ($claudeAcces -ne "aucun") {
        $r = Choix "Comment accéder à Claude ?" @(
            "Avec mon abonnement claude.ai (Pro / Max), via Claude Code : pas de frais en plus",
            "Avec une clé API Anthropic : payée à l'usage, à coller ensuite dans la popup de l'extension")
        $claudeAcces = if ($r -eq 1) { "abonnement" } else { "api" }

        if ($claudeAcces -eq "abonnement") {
            $cc = ClaudeCode
            if (-not $cc) {
                Write-Host ""; Avert "Claude Code n'est pas installé : il est nécessaire pour utiliser ton abonnement."
                if (OuiNon "  L'installer maintenant ?") { $installerClaudeCode = $true; $connecterClaudeCode = $true }
            } elseif (-not (((& $cc auth status 2>$null) -join "") -match '"authMethod":\s*"claude\.ai"')) {
                Write-Host ""; Avert "Claude Code est installé mais pas connecté à ton abonnement."
                if (OuiNon "  Te connecter maintenant (ouvre le navigateur) ?") { $connecterClaudeCode = $true }
            } else {
                Ok "Claude Code est déjà connecté à ton abonnement."
            }
        }
    }

    $r = Choix "Comment faire tourner le serveur local de Streamlet ?" @(
        "Durable (recommandé) : en tâche de fond, démarre avec ta session, tu peux fermer le terminal",
        "Éphémère : dans ce terminal, il s'arrête quand tu le fermes (à relancer à chaque fois)")
    $Ephemere = ($r -eq 2)
}

# Moteur par défaut de l'extension, d'après les choix
if ($avecOllama -and $claudeAcces -ne "aucun") { $moteur = "auto" }
elseif ($avecOllama) { $moteur = "local" }
elseif ($claudeAcces -ne "aucun") { $moteur = "claude" }
else { Ko "Il faut au moins une IA : l'IA locale (Ollama) ou Claude." }

if ($questionnaire) {
    Write-Host ""; Gras "Récapitulatif"
    Write-Host ("  IA locale : " + $(if ($avecOllama) { "Ollama + $Modele" } else { "non" }))
    switch ($claudeAcces) {
        "abonnement" {
            $aFaire = if ($installerClaudeCode) { ", installé et connecté par ce script" }
                      elseif ($connecterClaudeCode) { ", connecté par ce script" } else { "" }
            Write-Host "  Claude    : via ton abonnement (Claude Code$aFaire), modèle à choisir dans la popup"
        }
        "api"   { Write-Host "  Claude    : via clé API (à coller dans la popup), modèle à choisir dans la popup" }
        "aucun" { Write-Host "  Claude    : non" }
    }
    Write-Host "  Moteur    : $moteur"
    Write-Host ("  Serveur   : " + $(if ($Ephemere) { "éphémère (dans ce terminal)" } else { "durable (tâche de fond)" }))
    Write-Host ""
    if (-not (OuiNon "Lancer l'installation ?")) { Write-Host "Installation annulée."; exit 0 }
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
    if (-not $aWinget) { Ko "Python 3.10+ introuvable. Installe-le depuis https://www.python.org/downloads/ puis relance." }
    Info "Installation de Python…"
    winget install -e --id Python.Python.3.12 --silent --accept-package-agreements --accept-source-agreements
    Rafraichir-Path
    $py = Trouver-Python
    if (-not $py) { Ko "Python installé mais introuvable : ouvre un nouveau terminal et relance ce script." }
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
        Info "Installation d'Ollama…"
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
            else { Ko "Ollama installé mais introuvable : ouvre un nouveau terminal et relance ce script." }
        }
    }
    Ok "Ollama installé"

    if (-not (Ollama-Repond)) {
        Info "Démarrage d'Ollama…"
        $appli = Join-Path $env:LOCALAPPDATA "Programs\Ollama\ollama app.exe"
        if (Test-Path $appli) { Start-Process -FilePath $appli }   # l'appli se lance aussi à chaque session
        else { Start-Process -FilePath "ollama" -ArgumentList "serve" -WindowStyle Hidden }
        for ($i = 0; $i -lt 30 -and -not (Ollama-Repond); $i++) { Start-Sleep -Seconds 1 }
        if (-not (Ollama-Repond)) { Ko "Ollama ne répond pas sur http://127.0.0.1:11434 — lance « ollama serve » puis relance." }
    }
    Ok "Ollama actif"

    Info "Téléchargement du modèle $Modele (plusieurs Go la première fois)…"
    ollama pull $Modele
    if ($LASTEXITCODE -ne 0) { Ko "Échec du téléchargement de $Modele" }
    Ok "Modèle $Modele prêt"
} else {
    Info "Ollama ignoré : seul le moteur « En ligne » (Claude) sera disponible."
}

# ---------- Claude Code (abonnement) ----------
if ($installerClaudeCode) {
    Info "Installation de Claude Code…"
    Invoke-RestMethod -Uri "https://claude.ai/install.ps1" -ErrorAction Stop | Invoke-Expression
    Rafraichir-Path
    if (-not (ClaudeCode)) { Ko "Claude Code installé mais introuvable : ouvre un nouveau terminal et relance ce script." }
    Ok "Claude Code installé"
}
if ($connecterClaudeCode) {
    Info "Connexion de Claude Code à ton abonnement (une page va s'ouvrir dans le navigateur)…"
    & (ClaudeCode) auth login --claudeai
    if ($LASTEXITCODE -eq 0) { Ok "Claude Code connecté" }
    else { Avert "Connexion non terminée : tu pourras la faire plus tard avec « claude auth login »." }
}

# ---------- Environnement Python ----------
$venvPy = Join-Path $PSScriptRoot ".venv\Scripts\python.exe"
if (-not (Test-Path $venvPy)) {
    Info "Création de l'environnement Python (.venv)…"
    & $pyExe @pyArgs -m venv .venv
    if ($LASTEXITCODE -ne 0) { Ko "Échec de « python -m venv »" }
}
& $venvPy -m pip install --quiet --upgrade pip
& $venvPy -m pip install --quiet -r requirements.txt
if ($LASTEXITCODE -ne 0) { Ko "Échec de l'installation des dépendances Python" }
Ok "Dépendances Python installées"

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
    if ($LASTEXITCODE -ne 0) { Ko "Échec de l'enregistrement des réglages" }
    Ok "Réglages enregistrés (moteur $moteur), modifiables à tout moment dans la popup"
}

# ---------- Serveur ----------
$options = @()
if ($Modele -ne "qwen3.5:4b") { $options = @("--modele", $Modele, "--modele-rapide", $Modele) }
$etapes = @(
    "  1. Charge l'extension : chrome://extensions > Mode développeur > « Charger l'extension non empaquetée » > dossier extension\"
)
if ($claudeAcces -eq "api") { $etapes += "  2. Colle ta clé API dans la popup de l'extension (section Claude > Clé API)" }

Write-Host ""
if ($Ephemere) {
    # Commande complète (avec le dossier) : elle marche depuis n'importe quel terminal PowerShell.
    $relancer = "cd `"$PSScriptRoot`"; .venv\Scripts\python.exe serveur_qcm.py" + $(if ($options) { " " + ($options -join " ") } else { "" })
    function Afficher-Relance {
        Write-Host ""
        Gras "Pour relancer Streamlet plus tard, copie cette commande dans PowerShell :"
        Write-Host ""
        Write-Host "    $relancer"
        Write-Host ""
    }
    Ok "Installation terminée (éphémère)."
    $etapes | ForEach-Object { Write-Host $_ }
    Afficher-Relance
    Write-Host "Le serveur démarre ci-dessous : garde ce terminal ouvert. Ctrl+C ou fermer le terminal l'arrête."
    Write-Host ""
    try { & $venvPy serveur_qcm.py @options }
    finally { Afficher-Relance }   # rappel à l'arrêt du serveur (Ctrl+C)
} else {
    & $venvPy serveur_qcm.py --installer @options
    if ($LASTEXITCODE -ne 0) { Ko "Échec de l'installation du serveur en tâche de fond" }
    Ok "Installation terminée (durable) : tu peux fermer ce terminal."
    $etapes | ForEach-Object { Write-Host $_ }
    Write-Host "  Arrêter et retirer la tâche de fond : .venv\Scripts\python.exe serveur_qcm.py --desinstaller"
}

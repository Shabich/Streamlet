const SERVEUR = "http://127.0.0.1:8765";
const $ = (id) => document.getElementById(id);
const envoyer = (msg) => chrome.runtime.sendMessage(msg);

async function poster(chemin, corps) {
  const r = await fetch(SERVEUR + chemin, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(corps || {}),
  });
  return r.json();
}

const AIDE_MODES = {
  local: "Qwen, en local uniquement. Gratuit, rien ne sort de ta machine.",
  auto: "Qwen d'abord ; Claude prend le relais si Qwen est trop lent, échoue ou est arrêté.",
  claude: "Claude directement. Plus rapide, mais la question est envoyée à Anthropic.",
};
const AIDE_MODELES = {
  haiku: "Haiku : le plus rapide et le plus léger. Indices parfois moins fins.",
  sonnet: "Sonnet : rapide et largement suffisant pour des QCM.",
  opus: "Opus : le plus fin, plus lent et consomme plus de quota.",
};
const SOURCES = {
  qwen: "· Qwen", qwen_reflexion_tronquee: "· Qwen (réflexion écourtée)",
  claude_abonnement: "· Claude (abonnement)", claude_api: "· Claude (API)", claude: "· Claude",
};

// ---------- interrupteur de l'onglet ----------
async function initOnglet() {
  const [onglet] = await chrome.tabs.query({ active: true, currentWindow: true });
  const interrupteur = $("actif");
  let url;
  try { url = new URL(onglet.url); } catch {}
  if (!url || !/^https?:$/.test(url.protocol)) {
    $("site").textContent = "page non compatible";
    interrupteur.disabled = true;
    return;
  }
  $("site").textContent = url.host;
  await chrome.storage.session.remove("attente");
  interrupteur.checked = (await envoyer({ type: "etat", tabId: onglet.id })).actif;

  interrupteur.addEventListener("change", async () => {
    $("msg").textContent = "";
    if (!interrupteur.checked) { await envoyer({ type: "desactiver", tabId: onglet.id }); return; }
    // Accès limité au site de cet onglet (demandé une seule fois par site).
    // Firefox n'accepte permissions.request que directement dans le clic : aucun « await » avant.
    // « attente » permet au service de fond de finir l'activation si la popup se ferme pendant la demande
    // (Firefox la ferme pour afficher la question d'autorisation).
    chrome.storage.session.set({ attente: onglet.id });
    let permis = false;
    try {
      // Sans port : Firefox ignore les motifs d'adresse qui en contiennent un (ex. localhost:3000).
      permis = await chrome.permissions.request({ origins: [`${url.protocol}//${url.hostname}/*`] });
    } catch (e) {
      $("msg").textContent = "Demande d'accès impossible : " + (e.message || e);
    }
    await chrome.storage.session.remove("attente");
    if (!permis) {
      interrupteur.checked = false;
      if (!$("msg").textContent) $("msg").textContent = "Accès au site refusé.";
      return;
    }
    const r = await envoyer({ type: "activer", tabId: onglet.id });
    if (!r.ok) { interrupteur.checked = false; $("msg").textContent = "Injection impossible : " + r.erreur; }
  });
}

// ---------- moteur + Claude ----------
function initMoteur() {
  for (const b of document.querySelectorAll("#modes button")) {
    b.addEventListener("click", async () => {
      try { afficherMode((await poster("/config", { mode: b.dataset.mode })).mode); } catch {}
    });
  }
  for (const b of document.querySelectorAll("#modeles button")) {
    b.addEventListener("click", async () => {
      try { await poster("/config", { modele: b.dataset.modele }); } catch {}
      rafraichir();
    });
  }
  for (const b of document.querySelectorAll("#acces button")) {
    b.addEventListener("click", async () => {
      $("msg-claude").textContent = "";
      try { await poster("/config", { acces: b.dataset.acces }); } catch {}
      rafraichir();
    });
  }
  $("form-claude").addEventListener("submit", async (e) => {
    e.preventDefault();
    $("msg-claude").textContent = "";
    $("btn-connexion").disabled = true;
    $("btn-connexion").textContent = "Vérification…";
    try {
      const r = await poster("/claude/connexion", { cle: $("cle").value });
      if (r.ok) $("cle").value = "";
      else $("msg-claude").textContent = r.erreur;
    } catch {
      $("msg-claude").textContent = "Serveur injoignable.";
    }
    $("btn-connexion").disabled = false;
    $("btn-connexion").textContent = "Connecter";
    rafraichir();
  });
  $("btn-deconnexion").addEventListener("click", async () => {
    try { await poster("/claude/deconnexion"); } catch {}
    rafraichir();
  });
}

function afficherMode(mode) {
  for (const b of document.querySelectorAll("#modes button")) b.classList.toggle("choisi", b.dataset.mode === mode);
  $("aide-mode").textContent = AIDE_MODES[mode] || "";
}

function afficherClaude(claude, mode) {
  const parAbonnement = claude.acces === "abonnement";
  for (const b of document.querySelectorAll("#acces button")) b.classList.toggle("choisi", b.dataset.acces === claude.acces);
  const c = parAbonnement ? claude.abonnement : claude.api;
  for (const b of document.querySelectorAll("#modeles button")) b.classList.toggle("choisi", b.dataset.modele === claude.famille);
  $("aide-modele").textContent = AIDE_MODELES[claude.famille] || "";
  const etat = document.createElement("span");
  etat.className = c.connecte ? "ok" : mode === "local" ? "aide" : "ko";
  etat.textContent = c.connecte ? "connecté" : "non connecté";
  $("claude-etat").replaceChildren(etat);

  // Abonnement : passe par Claude Code, déjà connecté à ton compte claude.ai.
  $("claude-abonnement").hidden = !parAbonnement;
  if (parAbonnement) {
    $("claude-abonnement").textContent = c.connecte
      ? `Via Claude Code, compris dans ton abonnement (sans frais au token, mais compte dans tes limites). ${c.appels} appel(s).`
      : !c.installe
        ? "Claude Code n'est pas installé : il faut l'installer pour utiliser ton abonnement."
        : "Claude Code n'est pas connecté à ton abonnement : lance « claude » dans un terminal puis tape /login.";
  }
  // Clé API : formulaire de connexion, coût au token.
  $("claude-deconnecte").hidden = parAbonnement || c.connecte;
  $("claude-connecte").hidden = parAbonnement || !c.connecte;
  if (!parAbonnement && c.connecte) {
    $("claude-cout").textContent = `${c.appels} appel(s) · ~${c.cout_dollars.toFixed(3)} $ depuis le lancement` +
      (c.source === "environnement" ? " · clé via ANTHROPIC_API_KEY" : "");
    $("btn-deconnexion").hidden = c.source !== "trousseau";
  }
  if (!c.connecte && mode === "claude") $("msg-claude").textContent = "Connecte Claude pour utiliser le mode en ligne.";
  else if (!c.connecte && mode === "auto") $("msg-claude").textContent = "Sans Claude, le mode auto reste en local.";
  else if ($("msg-claude").textContent.startsWith("Connecte") || $("msg-claude").textContent.startsWith("Sans")) $("msg-claude").textContent = "";
}

// ---------- afficher l'indice / la réponse (préférence gardée dans l'extension) ----------
const affichage = { notif: true, indice: true, reponse: false };
let resultatRecu = false;

async function initAffichage() {
  try { Object.assign(affichage, (await chrome.storage.local.get("affichage")).affichage); } catch {}
  for (const [cle, id] of [["notif", "voir-notif"], ["indice", "voir-indice"], ["reponse", "voir-reponse"]]) {
    $(id).checked = affichage[cle];
    $(id).addEventListener("change", () => {
      affichage[cle] = $(id).checked;
      chrome.storage.local.set({ affichage }).catch(() => {});
      appliquerAffichage();
    });
  }
  appliquerAffichage();
}

function appliquerAffichage() {
  afficherResultats();
  // Notifications actives : le résultat est sur la page ; sinon il s'affiche ici.
  $("carte").hidden = affichage.notif || !resultatRecu;
  $("note-notif").hidden = !affichage.notif;
}

// ---------- résultats de la page (affichés ici quand la notification sur la page est coupée) ----------
let derniersResultats = null;

function bloc(etiquette, texte, classe) {
  const d = document.createElement("div");
  d.className = "bloc";
  const e = document.createElement("div");
  e.className = "etiquette";
  e.textContent = etiquette;
  const t = document.createElement("div");
  if (classe) t.className = classe;
  t.textContent = texte; // jamais de HTML : le texte vient de la page web
  d.append(e, t);
  return d;
}

function afficherResultats() {
  const qs = derniersResultats?.questions || [];
  $("carte").replaceChildren(...qs.map((q, i) => {
    const c = document.createElement("div");
    c.className = "carte";
    const titre = document.createElement("div");
    titre.className = "question";
    titre.textContent = (qs.length > 1 ? `${i + 1}. ` : "") + q.question;
    c.append(titre);
    if (affichage.indice) c.append(bloc("Indice " + (SOURCES[q.source] || ""), q.indice || "—", "indice"));
    if (affichage.reponse) {
      const r = q.reponse;
      c.append(bloc("Réponse", r ? (r.lettre && !new RegExp(`^\\s*${r.lettre}\\s*[.)\\-:]`, "i").test(r.texte) ? `${r.lettre}. ` : "") + r.texte : "—", "reponse"));
    }
    return c;
  }));
}

// ---------- état du serveur ----------
async function rafraichir() {
  try {
    const e = await (await fetch(SERVEUR + "/etat", { signal: AbortSignal.timeout(4000) })).json();
    $("point").className = "point ok";
    $("serveur").textContent = "serveur actif";
    afficherMode(e.mode);
    afficherClaude(e.claude, e.mode);
    if (e.resultats?.questions?.length && e.resultats.id !== derniersResultats?.id) {
      derniersResultats = e.resultats;
      resultatRecu = true;
      appliquerAffichage();
    }
    $("encours").hidden = !e.en_cours;
    $("encours").textContent = e.en_cours ? "Réflexion en cours : " + e.en_cours.slice(0, 80) + "…" : "";
    $("pied").textContent = `${e.nb_qcm} QCM enregistré(s)` + (e.erreur ? ` · erreur : ${e.erreur}` : "");
  } catch {
    $("point").className = "point ko";
    $("serveur").textContent = "serveur arrêté";
    $("pied").textContent = "Relance le script d'installation, ou voir « Gérer le serveur » dans le README.";
  }
}

// ---------- Capture automatique des images illisibles (accès à tous les sites, sur demande) ----------
const TOUS_LES_SITES = { origins: ["<all_urls>"] };
const AIDE_CAPTURE = {
  on: "Les images illisibles à l'écran sont capturées automatiquement.",
  off: "Sinon : clic droit sur l'image › « Streamlet : lire cette image ». L'activer demande l'accès à tous les sites.",
};

async function initCapture() {
  const inter = $("capture-auto");
  const afficher = () => { $("aide-capture").textContent = inter.checked ? AIDE_CAPTURE.on : AIDE_CAPTURE.off; };
  inter.checked = await chrome.permissions.contains(TOUS_LES_SITES);
  afficher();
  inter.addEventListener("change", async () => {
    if (inter.checked) inter.checked = await chrome.permissions.request(TOUS_LES_SITES);
    else await chrome.permissions.remove(TOUS_LES_SITES);
    afficher();
  });
}

initOnglet();
initMoteur();
initAffichage();
initCapture();
rafraichir();
setInterval(rafraichir, 1500);

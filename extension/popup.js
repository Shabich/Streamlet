const SERVEUR = "http://127.0.0.1:8765";
// Langue du navigateur, transmise au serveur pour qu'il réponde dans la même langue.
const LANGUE = chrome.i18n.getUILanguage().toLowerCase().startsWith("fr") ? "fr" : "en";
const $ = (id) => document.getElementById(id);
const envoyer = (msg) => chrome.runtime.sendMessage(msg);
// Textes traduits (_locales/en et _locales/fr) : langue du navigateur, anglais par défaut.
const t = (cle, ...valeurs) => chrome.i18n.getMessage(cle, valeurs.map(String));

function traduirePage() {
  document.documentElement.lang = chrome.i18n.getUILanguage();
  for (const el of document.querySelectorAll("[data-i18n]")) el.textContent = t(el.dataset.i18n);
  for (const el of document.querySelectorAll("[data-i18n-title]")) el.title = t(el.dataset.i18nTitle);
  for (const el of document.querySelectorAll("[data-i18n-placeholder]")) el.placeholder = t(el.dataset.i18nPlaceholder);
}

async function poster(chemin, corps) {
  const r = await fetch(SERVEUR + chemin, {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-Streamlet-Lang": LANGUE },
    body: JSON.stringify(corps || {}),
  });
  return r.json();
}

const AIDE_MODES = { local: "helpModeLocal", auto: "helpModeAuto", claude: "helpModeClaude" };
const AIDE_MODELES = { haiku: "helpModelHaiku", sonnet: "helpModelSonnet", opus: "helpModelOpus" };
const AIDE_REFLEXIONS = { rapide: "helpReasoningFast", normale: "helpReasoningNormal" };
const SOURCES = {
  qwen: "sourceQwen", qwen_reflexion_tronquee: "sourceQwenTruncated", qwen_rapide: "sourceQwenFast",
  claude_abonnement: "sourceClaudeSubscription", claude_api: "sourceClaudeApi", claude: "sourceClaude",
};

// ---------- interrupteur de l'onglet ----------
let ongletCourant = null, demandeEnCours = false;
const majRappel = () => { $("rappel").hidden = !$("actif").checked; };

// L'arrêt automatique (2 min sans question) peut couper l'onglet pendant que la popup est ouverte.
async function verifierOnglet() {
  if (!ongletCourant || demandeEnCours) return;
  try {
    const actif = (await envoyer({ type: "etat", tabId: ongletCourant })).actif;
    if ($("actif").checked !== actif) { $("actif").checked = actif; majRappel(); }
  } catch {}
}

async function initOnglet() {
  const [onglet] = await chrome.tabs.query({ active: true, currentWindow: true });
  const interrupteur = $("actif");
  let url;
  try { url = new URL(onglet.url); } catch {}
  if (!url || !/^https?:$/.test(url.protocol)) {
    $("site").textContent = t("pageUnsupported");
    interrupteur.disabled = true;
    return;
  }
  $("site").textContent = url.host;
  await chrome.storage.session.remove("attente");
  interrupteur.checked = (await envoyer({ type: "etat", tabId: onglet.id })).actif;
  ongletCourant = onglet.id;
  majRappel();

  interrupteur.addEventListener("change", async () => {
    $("msg").textContent = "";
    majRappel();
    if (!interrupteur.checked) { await envoyer({ type: "desactiver", tabId: onglet.id }); return; }
    demandeEnCours = true;
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
      $("msg").textContent = t("accessRequestFailed", e.message || e);
    }
    await chrome.storage.session.remove("attente");
    if (!permis) {
      demandeEnCours = false;
      interrupteur.checked = false;
      majRappel();
      if (!$("msg").textContent) $("msg").textContent = t("siteAccessDenied");
      return;
    }
    const r = await envoyer({ type: "activer", tabId: onglet.id });
    demandeEnCours = false;
    if (!r.ok) { interrupteur.checked = false; majRappel(); $("msg").textContent = t("injectionFailed", r.erreur); }
  });
}

// ---------- moteur + Claude ----------
function initMoteur() {
  for (const b of document.querySelectorAll("#modes button")) {
    b.addEventListener("click", async () => {
      try { afficherMode((await poster("/config", { mode: b.dataset.mode })).mode); } catch {}
    });
  }
  for (const b of document.querySelectorAll("#reflexions button")) {
    b.addEventListener("click", async () => {
      try { await poster("/config", { reflexion: b.dataset.reflexion }); } catch {}
      rafraichir(); // affiche ce que le serveur a réellement enregistré
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
    $("btn-connexion").textContent = t("checking");
    try {
      const r = await poster("/claude/connexion", { cle: $("cle").value });
      if (r.ok) $("cle").value = "";
      else $("msg-claude").textContent = r.erreur;
    } catch {
      $("msg-claude").textContent = t("serverUnreachable");
    }
    $("btn-connexion").disabled = false;
    $("btn-connexion").textContent = t("connect");
    rafraichir();
  });
  $("btn-deconnexion").addEventListener("click", async () => {
    try { await poster("/claude/deconnexion"); } catch {}
    rafraichir();
  });
}

function afficherMode(mode) {
  for (const b of document.querySelectorAll("#modes button")) b.classList.toggle("choisi", b.dataset.mode === mode);
  $("aide-mode").textContent = AIDE_MODES[mode] ? t(AIDE_MODES[mode]) : "";
  $("bloc-reflexion").hidden = !mode || mode === "claude"; // la réflexion ne concerne que l'IA locale
  // Local : seul le modèle local compte, Claude n'est jamais appelé. En ligne : seul Claude compte.
  $("bloc-claude").hidden = mode === "local";
  $("bloc-local").hidden = !mode || mode === "claude";
}

// Octets → « 9,2 Go » / « 9.2 GB » selon la langue (en multiples de 1 024, comme macOS et Windows : 16 Go = 16 Go).
const go = (octets) => t("gigabytes", (octets / 2 ** 30).toLocaleString(chrome.i18n.getUILanguage(), { maximumFractionDigits: 1 }));

function afficherConnaissances(c) {
  $("local-connaissances").textContent = !c ? "" : c.total ? t("knowledgeSummary", c.actifs, c.total) : t("knowledgeNone");
}

function afficherLocal(l) {
  if (!l) return; // serveur d'une version précédente
  $("local-modele").textContent = l.modele;
  const jauge = $("local-jauge");
  jauge.hidden = !(l.charge && l.memoire && l.memoire_totale);
  if (!l.ollama) $("local-etat").textContent = t("ollamaDown");
  else if (!l.installe) $("local-etat").textContent = t("localNotInstalled", l.modele);
  else if (!l.charge) $("local-etat").textContent = t("localNotLoaded", go(l.disque));
  else {
    $("local-etat").textContent = l.memoire_totale ? t("localMemory", go(l.memoire), go(l.memoire_totale)) : t("localMemoryNoTotal", go(l.memoire));
    if (!jauge.hidden) {
      const part = Math.min(100, (100 * l.memoire) / l.memoire_totale);
      $("local-jauge-plein").style.width = part + "%";
      jauge.classList.toggle("haute", part > 75);
    }
  }
  const details = [];
  if (l.charge) details.push(l.gpu >= 100 ? t("localGpuFull") : l.gpu <= 0 ? t("localCpuOnly") : t("localGpuPart", l.gpu));
  if (l.charge && l.disque) details.push(t("localOnDisk", go(l.disque)));
  if (l.charge && l.libere_dans != null) details.push(t("localFreesIn", l.libere_dans));
  $("local-details").textContent = details.join(" · ");
}

function afficherReflexion(reflexion) {
  // Un serveur d'une version précédente ne connaît pas ce réglage : il l'ignore sans rien dire.
  $("msg-reflexion").textContent = reflexion ? "" : t("serverOutdated");
  if (!reflexion) return;
  for (const b of document.querySelectorAll("#reflexions button")) b.classList.toggle("choisi", b.dataset.reflexion === reflexion);
  $("aide-reflexion").textContent = AIDE_REFLEXIONS[reflexion] ? t(AIDE_REFLEXIONS[reflexion]) : "";
}

function afficherClaude(claude, mode) {
  const parAbonnement = claude.acces === "abonnement";
  for (const b of document.querySelectorAll("#acces button")) b.classList.toggle("choisi", b.dataset.acces === claude.acces);
  const c = parAbonnement ? claude.abonnement : claude.api;
  for (const b of document.querySelectorAll("#modeles button")) b.classList.toggle("choisi", b.dataset.modele === claude.famille);
  $("aide-modele").textContent = AIDE_MODELES[claude.famille] ? t(AIDE_MODELES[claude.famille]) : "";
  const etat = document.createElement("span");
  etat.className = c.connecte ? "ok" : mode === "local" ? "aide" : "ko";
  etat.textContent = c.connecte ? t("connected") : t("notConnected");
  $("claude-etat").replaceChildren(etat);

  // Abonnement : passe par Claude Code, déjà connecté à ton compte claude.ai.
  $("claude-abonnement").hidden = !parAbonnement;
  if (parAbonnement) {
    $("claude-abonnement").textContent = c.connecte
      ? t("subscriptionConnected", c.appels)
      : !c.installe ? t("subscriptionNotInstalled") : t("subscriptionNotConnected");
  }
  // Clé API : formulaire de connexion, coût au token.
  $("claude-deconnecte").hidden = parAbonnement || c.connecte;
  $("claude-connecte").hidden = parAbonnement || !c.connecte;
  if (!parAbonnement && c.connecte) {
    $("claude-cout").textContent = t("apiCost", c.appels, c.cout_dollars.toFixed(3)) +
      (c.source === "environnement" ? t("apiKeyFromEnv") : "");
    $("btn-deconnexion").hidden = c.source !== "trousseau";
  }
  // Rappel affiché selon le moteur (marqué pour pouvoir l'effacer sans toucher aux messages d'erreur).
  const rappel = !c.connecte && mode === "claude" ? t("connectForOnline") : !c.connecte && mode === "auto" ? t("autoWithoutClaude") : "";
  if (rappel) { $("msg-claude").textContent = rappel; $("msg-claude").dataset.rappel = "1"; }
  else if ($("msg-claude").dataset.rappel) { $("msg-claude").textContent = ""; delete $("msg-claude").dataset.rappel; }
}

// ---------- afficher l'indice / la réponse (préférence gardée dans l'extension) ----------
const affichage = { indice: true, reponse: false };
let resultatRecu = false;

async function initAffichage() {
  try { Object.assign(affichage, (await chrome.storage.local.get("affichage")).affichage); } catch {}
  for (const [cle, id] of [["indice", "voir-indice"], ["reponse", "voir-reponse"]]) {
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
  $("carte").hidden = !resultatRecu;
}

// ---------- panneau latéral (résultats à côté de la page, rien n'est ajouté à la page) ----------
// Le navigateur n'accepte de l'ouvrir que sur un clic : l'appel doit partir directement du clic, sans attente.
let fenetreId = null;
chrome.windows.getCurrent().then((w) => { fenetreId = w.id; }).catch(() => {});
// Chaque navigateur a son API, on teste ce qui existe vraiment :
//   Firefox            : browser.sidebarAction.open()
//   Chrome, Edge, Brave : chrome.sidePanel.open()
//   Opera, Arc…        : pas d'ouverture possible par l'extension -> petite fenêtre Streamlet séparée.
async function ouvrirFenetre() {
  const { fenetrePanneau } = await chrome.storage.session.get("fenetrePanneau");
  if (fenetrePanneau != null) {
    try { await chrome.windows.update(fenetrePanneau, { focused: true }); return; } catch {} // fermée entre-temps
  }
  const w = await chrome.windows.create({ url: "panneau.html?fenetre=1", type: "popup", width: 360, height: 560 });
  await chrome.storage.session.set({ fenetrePanneau: w.id });
}

$("ouvrir-panneau").addEventListener("click", () => {
  const echec = (e) => { console.warn("Panneau :", e); $("msg").textContent = t("panelError", String(e?.message || e)); };
  const secours = (e) => { if (e) console.warn("Panneau latéral indisponible, fenêtre séparée :", e); return ouvrirFenetre(); };
  let ouverture;
  // Appels faits directement dans le clic : sinon le navigateur refuse (geste utilisateur requis).
  try {
    const firefox = globalThis.browser?.sidebarAction;
    if (typeof firefox?.open === "function") ouverture = firefox.open();
    else if (typeof chrome.sidePanel?.open === "function") {
      // windowId inconnu (clic très rapide) : l'onglet courant suffit aussi.
      ouverture = chrome.sidePanel.open(fenetreId != null ? { windowId: fenetreId } : { tabId: ongletCourant });
    } else ouverture = secours();
  } catch (e) { ouverture = secours(e); }
  Promise.resolve(ouverture).catch(secours).then(() => window.close(), echec);
});

// ---------- résultats de la page (aussi affichés ici) ----------
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
    const source = SOURCES[q.source] ? " " + t(SOURCES[q.source]) : "";
    if (affichage.indice && q.indice) c.append(bloc(t("hint") + source, q.indice, "indice"));
    if (!q.indice && !affichage.reponse) c.append(bloc(t("hint") + source, t("fastNoHint"), "indice"));
    if (affichage.reponse) {
      const r = q.reponse;
      c.append(bloc(t("answer"), r ? (r.lettre && !new RegExp(`^\\s*${r.lettre}\\s*[.)\\-:]`, "i").test(r.texte) ? `${r.lettre}. ` : "") + r.texte : "—", "reponse"));
    }
    return c;
  }));
}

// ---------- état du serveur ----------
async function rafraichir() {
  try {
    const e = await (await fetch(SERVEUR + "/etat", { signal: AbortSignal.timeout(4000), headers: { "X-Streamlet-Lang": LANGUE } })).json();
    $("point").className = "point ok";
    $("serveur").textContent = t("serverRunning");
    afficherMode(e.mode);
    afficherReflexion(e.reflexion);
    afficherLocal(e.local);
    afficherConnaissances(e.connaissances);
    afficherClaude(e.claude, e.mode);
    if (e.resultats?.questions?.length && e.resultats.id !== derniersResultats?.id) {
      derniersResultats = e.resultats;
      resultatRecu = true;
      appliquerAffichage();
    }
    $("encours").hidden = !e.en_cours;
    $("encours").textContent = !e.en_cours ? "" : e.en_cours_question ? t("thinkingAbout", e.en_cours.slice(0, 80)) : t("analyzingPage");
    $("pied").textContent = t("savedCount", e.nb_qcm) + (e.erreur ? t("errorSuffix", e.erreur) : "");
  } catch {
    $("point").className = "point ko";
    $("serveur").textContent = t("serverStopped");
    $("pied").textContent = t("serverHelp");
  }
}

// ---------- Capture automatique des images illisibles (accès à tous les sites, sur demande) ----------
const TOUS_LES_SITES = { origins: ["<all_urls>"] };
const AIDE_CAPTURE = { on: "captureOn", off: "captureOff" };

async function initCapture() {
  const inter = $("capture-auto");
  const afficher = () => { $("aide-capture").textContent = t(inter.checked ? AIDE_CAPTURE.on : AIDE_CAPTURE.off); };
  inter.checked = await chrome.permissions.contains(TOUS_LES_SITES);
  afficher();
  inter.addEventListener("change", async () => {
    if (inter.checked) inter.checked = await chrome.permissions.request(TOUS_LES_SITES);
    else await chrome.permissions.remove(TOUS_LES_SITES);
    afficher();
  });
}

traduirePage();
// Page « Connaissances » dans un onglet : un sélecteur de fichier dans la popup la fermerait (Firefox).
$("gerer-connaissances").addEventListener("click", (e) => { e.preventDefault(); chrome.runtime.openOptionsPage(); });
initOnglet();
initMoteur();
initAffichage();
initCapture();
rafraichir();
setInterval(() => { rafraichir(); verifierOnglet(); }, 1500);

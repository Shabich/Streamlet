// Service worker : garde la liste des onglets cochés, y injecte content.js,
// et relaie les QCM détectés vers le serveur local.
const SERVEUR = "http://127.0.0.1:8765";
// Langue du navigateur, transmise au serveur pour qu'il réponde dans la même langue.
const LANGUE = chrome.i18n.getUILanguage().toLowerCase().startsWith("fr") ? "fr" : "en";

// Arrêt automatique : un onglet sans question de quiz pendant 2 minutes est désactivé. Sécurité si on oublie
// de couper Streamlet : sinon chaque nouvelle page serait envoyée à l'IA (tokens consommés pour rien).
const DELAI_INACTIF = 2 * 60 * 1000;
const GRACE_PAGE = 30 * 1000; // après une navigation : le temps que la nouvelle page soit analysée

// onglets = { [tabId]: { vu: date de la dernière question vue (ou de l'activation) } }
async function ongletsActifs() {
  return (await chrome.storage.session.get("onglets")).onglets || {};
}
async function majOnglets(f) {
  const o = await ongletsActifs();
  f(o);
  await chrome.storage.session.set({ onglets: o });
}

const expire = (entree) => !!entree && Date.now() - (entree.vu || 0) > DELAI_INACTIF;
const noterQuestion = (tabId) => majOnglets((o) => { if (o[tabId]) o[tabId].vu = Date.now(); });

function badge(tabId, texte, couleur = "#16a34a") {
  chrome.action.setBadgeText({ tabId, text: texte }).catch(() => {});
  chrome.action.setBadgeBackgroundColor({ tabId, color: couleur }).catch(() => {});
}

async function injecter(tabId) {
  try {
    await chrome.scripting.executeScript({ target: { tabId }, files: ["content.js"] });
    badge(tabId, "ON");
    return { ok: true };
  } catch (e) {
    badge(tabId, "!", "#dc2626");
    return { ok: false, erreur: String(e.message || e) };
  }
}

// Images de la question : capture de la partie visible de l'onglet, puis découpage de chaque image.
// Marche quelle que soit leur origine (autre domaine, <canvas>…), là où les télécharger échouerait souvent.
async function joindreImages(tab, payload) {
  const images = payload.compacte.images.filter((i) => !i.data);
  try {
    if (!tab.active) throw new Error("onglet en arrière-plan : capture impossible");
    const bmp = await capturer(tab);
    const echelle = bmp.width / payload.vue.largeur; // pixels de la capture par pixel CSS
    for (const im of images) im.data = await decouper(bmp, echelle, im.boite, payload.vue);

  } catch (e) {
    // Sans <all_urls>, la capture n'est permise que juste après avoir cliqué sur l'extension (activeTab).
    // Pas grave : le serveur téléchargera ces images par leur adresse.
    payload.compacte.erreur_capture = String(e.message || e);
  }
}

async function capturer(tab) {
  const capture = await chrome.tabs.captureVisibleTab(tab.windowId, { format: "png" });
  return createImageBitmap(await (await fetch(capture)).blob());
}

// Découpe une image (boîte en pixels CSS de la zone visible) dans la capture. null si hors de l'écran.
async function decouper(bmp, echelle, { x, y, l, h }, vue) {
  if (y + h <= 0 || y >= vue.hauteur || x + l <= 0 || x >= vue.largeur) return null;
  const sx = Math.max(0, x * echelle), sy = Math.max(0, y * echelle);
  const sw = Math.min(bmp.width - sx, l * echelle), sh = Math.min(bmp.height - sy, h * echelle);
  if (sw < 8 || sh < 8) return null;
  const r = Math.min(1, 1024 / Math.max(sw, sh)); // 1024 px au plus : assez pour Claude, léger à envoyer
  const toile = new OffscreenCanvas(Math.round(sw * r), Math.round(sh * r));
  toile.getContext("2d").drawImage(bmp, sx, sy, sw, sh, 0, 0, toile.width, toile.height);
  const blob = await toile.convertToBlob({ type: "image/jpeg", quality: 0.85 });
  return enBase64(await blob.arrayBuffer());
}

// ---------- Clic droit sur une image : « lire cette image » ----------
// Le clic sur le menu vaut autorisation (activeTab) : la capture d'écran est alors permise,
// même sans l'accès à tous les sites.
chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.removeAll(() => {
    chrome.contextMenus.create({ id: "lire-image", title: chrome.i18n.getMessage("menuReadImage"), contexts: ["image"] });
  });
});

chrome.contextMenus.onClicked.addListener(async (info, tab) => {
  if (info.menuItemId !== "lire-image" || !tab?.id) return;
  try {
    if (!(await ongletsActifs())[tab.id]) await activer(tab.id); // la page n'était pas suivie : on l'active
    const zone = await chrome.tabs.sendMessage(tab.id, { type: "zone-image", src: info.srcUrl });
    if (!zone) throw new Error("image introuvable dans la page");
    const bmp = await capturer(tab);
    const data = await decouper(bmp, bmp.width / zone.vue.largeur, zone.boite, zone.vue);
    if (!data) throw new Error("image hors de l'écran");
    await chrome.tabs.sendMessage(tab.id, { type: "image-capturee", src: info.srcUrl, data });
    badge(tab.id, "ON");
  } catch (e) {
    badge(tab.id, "!", "#dc2626");
    console.warn("Lecture de l'image impossible :", e);
  }
});

function enBase64(buffer) {
  const octets = new Uint8Array(buffer);
  let s = "";
  for (let i = 0; i < octets.length; i += 0x8000) s += String.fromCharCode(...octets.subarray(i, i + 0x8000));
  return btoa(s);
}

async function activer(tabId) {
  await majOnglets((o) => { o[tabId] = { vu: Date.now() }; });
  return injecter(tabId);
}

// raison = "inactif" : arrêt automatique (la page affiche pourquoi Streamlet s'est coupé).
async function desactiver(tabId, raison) {
  await majOnglets((o) => { delete o[tabId]; });
  badge(tabId, "");
  try { await chrome.tabs.sendMessage(tabId, { type: "stop", raison }); } catch {}
  return { ok: true };
}

// Rechargement / navigation dans un onglet coché : on réinjecte (et on laisse le temps d'analyser la page).
chrome.tabs.onUpdated.addListener(async (tabId, info) => {
  if (info.status !== "complete") return;
  const entree = (await ongletsActifs())[tabId];
  if (!entree) return;
  if (expire(entree)) return desactiver(tabId, "inactif");
  await majOnglets((o) => { if (o[tabId]) o[tabId].vu = Math.max(o[tabId].vu || 0, Date.now() - DELAI_INACTIF + GRACE_PAGE); });
  injecter(tabId);
});
chrome.tabs.onRemoved.addListener((tabId) => majOnglets((o) => { delete o[tabId]; }));

// Si la popup s'est fermée pendant la demande de permission, on termine l'activation ici.
chrome.permissions.onAdded.addListener(async () => {
  const { attente } = await chrome.storage.session.get("attente");
  if (attente == null) return;
  await chrome.storage.session.remove("attente");
  activer(attente);
});

chrome.runtime.onMessage.addListener((msg, sender, repondre) => {
  if (msg.type === "qcm") {
    const tabId = sender.tab?.id;
    ongletsActifs().then(async (o) => {
      if (!o[tabId]) return; // onglet non coché : on n'envoie rien
      if (expire(o[tabId])) return desactiver(tabId, "inactif"); // pas de question depuis 2 min : rien n'est envoyé
      // Images que la page n'a pas pu lire elle-même (autre site) : capture d'écran en secours.
      if (msg.payload.compacte?.images?.some((i) => !i.data)) await joindreImages(sender.tab, msg.payload);
      fetch(SERVEUR + "/qcm", {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-Streamlet-Lang": LANGUE },
        body: JSON.stringify(msg.payload),
      })
        .then(() => badge(tabId, "ON"))
        .catch(() => badge(tabId, "✗", "#dc2626")); // serveur injoignable
    });
    return;
  }
  if (msg.type === "resultat") {
    // La page demande s'il y a un résultat à afficher (seulement depuis un onglet coché).
    // Appelé toutes les 1,5 s par chaque onglet actif : sert aussi à repérer l'inactivité.
    const tabId = sender.tab?.id;
    ongletsActifs().then(async (o) => {
      if (!o[tabId]) return repondre(null);
      let e = null;
      try { e = await (await fetch(SERVEUR + "/etat", { signal: AbortSignal.timeout(3000), headers: { "X-Streamlet-Lang": LANGUE } })).json(); } catch {}
      // Une question de quiz est sur cette page (résultat affiché) ou en cours de réflexion : on repousse l'arrêt.
      const url = sender.url;
      const question = e && ((e.en_cours_question && e.en_cours_url === url)
                             || (e.resultats?.url === url && e.resultats.questions?.length));
      if (question) await noterQuestion(tabId);
      else if (expire(o[tabId])) { await desactiver(tabId, "inactif"); return repondre(null); }
      repondre(e && { en_cours: e.en_cours, en_cours_url: e.en_cours_url, en_cours_question: e.en_cours_question,
                      resultats: e.resultats });
    });
    return true;
  }
  const actions = {
    activer: () => activer(msg.tabId),
    desactiver: () => desactiver(msg.tabId),
    etat: async () => ({ actif: !!(await ongletsActifs())[msg.tabId] }),
  };
  if (actions[msg.type]) {
    actions[msg.type]().then(repondre);
    return true; // réponse asynchrone
  }
});

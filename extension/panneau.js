// Panneau latéral : affiche l'indice / la réponse de l'onglet actif, sans rien ajouter à la page.
const SERVEUR = "http://127.0.0.1:8765";
const LANGUE = chrome.i18n.getUILanguage().toLowerCase().startsWith("fr") ? "fr" : "en";
const t = (cle, ...valeurs) => chrome.i18n.getMessage(cle, valeurs.map(String));
const $contenu = document.getElementById("contenu");
document.documentElement.lang = chrome.i18n.getUILanguage();

// Réglé par les interrupteurs de la popup.
const affichage = { indice: true, reponse: false };
chrome.storage.local.get("affichage").then((r) => Object.assign(affichage, r.affichage)).catch(() => {});
chrome.storage.onChanged.addListener((ch) => {
  if (!ch.affichage) return;
  Object.assign(affichage, ch.affichage.newValue);
  dernierRendu = ""; // force le réaffichage
  rafraichir();
});

// textContent uniquement : la question vient de la page, on n'injecte jamais de HTML.
function el(tag, classe, txt) {
  const e = document.createElement(tag);
  if (classe) e.className = classe;
  if (txt != null) e.textContent = txt;
  return e;
}

function message(texte, classe = "discret") {
  const c = el("div", "carte");
  c.append(el("div", classe, texte));
  return c;
}

function attente(texte) {
  const c = el("div", "carte");
  const a = el("div", "attente");
  a.append(el("span", "roue"), el("span", null, texte));
  c.append(a);
  return c;
}

function resultat(d, position) {
  const c = el("div", "carte");
  if (position) c.append(el("div", "etiquette", position));
  c.append(el("div", "question", d.question));
  // Mode Rapide : pas d'indice, seulement la réponse (si l'utilisateur l'affiche).
  if (affichage.indice && d.indice) c.append(el("div", "etiquette", t("hint")), el("div", null, d.indice));
  if (!d.indice && !affichage.reponse) c.append(el("div", null, t("fastNoHint")));
  if (affichage.reponse) {
    const r = d.reponse;
    c.append(el("div", "etiquette", t("answer")),
             el("div", "reponse", r ? (r.lettre && !new RegExp(`^\\s*${r.lettre}\\s*[.)\\-:]`, "i").test(r.texte) ? `${r.lettre}. ` : "") + r.texte : "—"));
  }
  // Ex. : image d'un autre site non lisible -> Claude a répondu sans la voir.
  if (d.avertissement) c.append(el("div", "avertissement", "⚠ " + d.avertissement));
  return c;
}

// On ne redessine que si quelque chose a changé (sinon l'animation repartirait toutes les 1,5 s).
let dernierRendu = "";
function rendre(cle, fabriquer) {
  if (cle === dernierRendu) return;
  dernierRendu = cle;
  $contenu.replaceChildren(fabriquer());
}

// Panneau latéral : il appartient à la fenêtre du navigateur. Fenêtre séparée (Opera, Arc…) : on suit
// la dernière fenêtre normale utilisée, pas la fenêtre Streamlet elle-même.
const FENETRE_SEPAREE = new URLSearchParams(location.search).has("fenetre");
async function ongletSuivi() {
  if (!FENETRE_SEPAREE) return (await chrome.tabs.query({ active: true, currentWindow: true }))[0];
  const w = await chrome.windows.getLastFocused({ windowTypes: ["normal"] });
  return (await chrome.tabs.query({ active: true, windowId: w.id }))[0];
}

async function rafraichir() {
  let tab;
  try { tab = await ongletSuivi(); } catch {}
  if (!tab) return rendre("aucun", () => message(t("panelInactive")));

  let etat = null;
  try { etat = await chrome.runtime.sendMessage({ type: "etat", tabId: tab.id }); } catch {}
  if (!etat?.actif) {
    return etat?.arret === "inactif"
      ? rendre("arret", () => message(t("autoStopped")))
      : rendre("inactif", () => message(t("panelInactive")));
  }

  let e;
  try {
    e = await (await fetch(SERVEUR + "/etat", { signal: AbortSignal.timeout(3000), headers: { "X-Streamlet-Lang": LANGUE } })).json();
  } catch {
    return rendre("serveur", () => message(t("serverStopped")));
  }

  // La page donne son adresse et la question à l'écran (aucun élément n'y est ajouté).
  let page = null;
  try { page = await chrome.tabs.sendMessage(tab.id, { type: "question-visible", resultats: e.resultats }); } catch {}
  if (!page) return rendre("chargement", () => message(t("panelWaiting")));

  if (e.en_cours && e.en_cours_url === page.url) {
    // Simple analyse de la page (moteur en ligne) : texte traduit ; vraie question : son énoncé.
    const texte = e.en_cours_question ? e.en_cours : t("analyzingPage");
    return rendre("attente:" + texte, () => attente(texte));
  }
  const res = e.resultats;
  if (res?.url === page.url && res.questions?.length) {
    const i = Math.min(page.index || 0, res.questions.length - 1);
    const position = res.questions.length > 1 ? t("questionOfPage", i + 1, res.questions.length) : null;
    return rendre(`res:${res.id}:${i}`, () => resultat(res.questions[i], position));
  }
  rendre("vide", () => message(t("panelWaiting")));
}

rafraichir();
setInterval(rafraichir, 1500);
chrome.tabs.onActivated.addListener(() => rafraichir());

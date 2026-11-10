// Page « Connaissances » : déposer, activer et supprimer les thèmes (RAG local) du serveur Streamlet.
const SERVEUR = "http://127.0.0.1:8765";
const LANGUE = chrome.i18n.getUILanguage().toLowerCase().startsWith("fr") ? "fr" : "en";
const $ = (id) => document.getElementById(id);
const t = (cle, ...valeurs) => chrome.i18n.getMessage(cle, valeurs.map(String));
const TAILLE_MAX = 5 * 1024 * 1024;

document.documentElement.lang = chrome.i18n.getUILanguage();
document.title = "Streamlet · " + t("knowledgeTitle");
for (const el of document.querySelectorAll("[data-i18n]")) el.textContent = t(el.dataset.i18n);

async function appeler(chemin, corps) {
  const options = corps === undefined
    ? { headers: { "X-Streamlet-Lang": LANGUE } }
    : { method: "POST", headers: { "Content-Type": "application/json", "X-Streamlet-Lang": LANGUE }, body: JSON.stringify(corps) };
  const r = await fetch(SERVEUR + chemin, options);
  return r.json();
}

function message(id, texte, ok = false) {
  $(id).textContent = texte || "";
  $(id).classList.toggle("ok", ok);
  $(id).hidden = !texte;
}

// ---------- liste des thèmes ----------
function afficherListe(themes) {
  const liste = $("liste");
  if (!themes.length) { liste.textContent = t("knowledgeEmpty"); liste.classList.add("aide"); return; }
  liste.classList.remove("aide");
  liste.replaceChildren(...themes.map((th) => {
    const ligne = document.createElement("div");
    ligne.className = "theme";
    const inter = document.createElement("input");
    inter.type = "checkbox";
    inter.checked = th.actif;
    inter.title = t(th.actif ? "knowledgeOn" : "knowledgeOff");
    inter.addEventListener("change", async () => {
      try { afficherListe((await appeler("/connaissances/activer", { id: th.id, actif: inter.checked })).themes); }
      catch { message("msg-serveur", t("serverUnreachable")); }
    });
    const infos = document.createElement("div");
    infos.className = "infos";
    const titre = document.createElement("div");
    titre.className = "titre";
    titre.textContent = th.nom; // jamais de HTML : le nom vient d'un fichier
    const etiquette = document.createElement("span");
    etiquette.className = "etiquette";
    etiquette.textContent = t(th.source === "fourni" ? "knowledgeBundled" : "knowledgeMine");
    titre.append(etiquette);
    const detail = document.createElement("div");
    detail.className = "aide";
    detail.textContent = t("knowledgeFacts", th.nb) + (th.exemples[0] ? " · " + th.exemples[0] : "");
    infos.append(titre, detail);
    ligne.append(inter, infos);
    if (th.source === "perso") {
      const suppr = document.createElement("button");
      suppr.className = "bouton danger";
      suppr.textContent = t("knowledgeDelete");
      suppr.addEventListener("click", async () => {
        if (!confirm(t("knowledgeDeleteConfirm", th.nom))) return;
        try { afficherListe((await appeler("/connaissances/supprimer", { id: th.id })).themes); }
        catch { message("msg-serveur", t("serverUnreachable")); }
      });
      ligne.append(suppr);
    }
    return ligne;
  }));
}

async function charger() {
  try {
    afficherListe((await appeler("/connaissances")).themes);
    message("msg-serveur", "");
  } catch {
    message("msg-serveur", t("knowledgeServerDown"));
    $("liste").textContent = "—";
  }
}

// ---------- dépôt d'un fichier : aperçu, puis validation ----------
let enAttente = null; // { nom_fichier, contenu }

async function lireFichier(fichier) {
  message("msg-depot", "");
  $("apercu").hidden = true;
  enAttente = null;
  if (!fichier) return;
  if (fichier.size > TAILLE_MAX) return message("msg-depot", t("knowledgeTooBig"));
  const contenu = await fichier.text();
  try {
    const r = await appeler("/connaissances/apercu", { nom_fichier: fichier.name, contenu });
    if (!r.ok) return message("msg-depot", r.erreur);
    enAttente = { nom_fichier: fichier.name, contenu };
    $("apercu-nom").textContent = r.nom;
    $("apercu-nb").textContent = t("knowledgeFacts", r.nb) + " · " + fichier.name;
    $("apercu-exemples").replaceChildren(...r.exemples.map((e) => {
      const d = document.createElement("div");
      d.className = "exemple";
      d.textContent = e;
      return d;
    }));
    $("apercu").hidden = false;
  } catch {
    message("msg-depot", t("knowledgeServerDown"));
  }
}

$("choisir").addEventListener("click", () => $("fichier").click());
$("fichier").addEventListener("change", () => { lireFichier($("fichier").files[0]); $("fichier").value = ""; });
const depot = $("depot");
for (const ev of ["dragenter", "dragover"]) depot.addEventListener(ev, (e) => { e.preventDefault(); depot.classList.add("survol"); });
for (const ev of ["dragleave", "drop"]) depot.addEventListener(ev, (e) => { e.preventDefault(); depot.classList.remove("survol"); });
depot.addEventListener("drop", (e) => lireFichier(e.dataTransfer.files[0]));

$("annuler").addEventListener("click", () => { enAttente = null; $("apercu").hidden = true; });
$("valider").addEventListener("click", async () => {
  if (!enAttente) return;
  $("valider").disabled = true;
  try {
    const r = await appeler("/connaissances/ajouter", enAttente);
    if (!r.ok) message("msg-depot", r.erreur);
    else {
      message("msg-depot", t("knowledgeAdded", r.nom, r.nb), true);
      $("apercu").hidden = true;
      enAttente = null;
      afficherListe(r.themes);
    }
  } catch {
    message("msg-depot", t("knowledgeServerDown"));
  }
  $("valider").disabled = false;
});

// ---------- modèles à télécharger ----------
function telecharger(nom, contenu) {
  const lien = document.createElement("a");
  lien.href = URL.createObjectURL(new Blob(["﻿" + contenu], { type: "text/plain;charset=utf-8" }));
  lien.download = nom;
  lien.click();
  setTimeout(() => URL.revokeObjectURL(lien.href), 1000);
}
$("modele-csv").addEventListener("click", () => telecharger(t("knowledgeTemplateCsvName"), t("knowledgeTemplateCsvContent")));
$("modele-txt").addEventListener("click", () => telecharger(t("knowledgeTemplateTxtName"), t("knowledgeTemplateTxtContent")));

charger();

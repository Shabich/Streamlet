// Injecté uniquement dans l'onglet coché. Observe la page et, à chaque changement,
// extrait la question de QCM active + ses choix (avec leur position), puis l'envoie.
(() => {
  if (window.__qcmStream) { window.__qcmStream.relancer(); return; }

  const DELAI = 700;          // ms d'attente après le dernier changement du DOM
  const MAX_TEXTE = 6000;     // texte de page envoyé en mode secours
  let minuteur = null, derniereSignature = "";
  let numeroEnvoi = 0;
  const envois = new Map(); // numéro d'envoi -> éléments de la page ([n] -> élément)

  const propre = (t) => (t || "").replace(/\s+/g, " ").trim();
  const texte = (el) => propre(el?.innerText ?? el?.textContent);

  function visible(el) {
    if (!el?.getBoundingClientRect) return false;
    const r = el.getBoundingClientRect();
    if (r.width < 1 || r.height < 1) return false;
    const s = getComputedStyle(el);
    return s.visibility !== "hidden" && s.display !== "none" && s.opacity !== "0";
  }
  // Visible ET placé dans la largeur de la page (pas repoussé hors écran, ex. left: -9999px).
  function surLaPage(el) {
    if (!visible(el)) return false;
    const r = el.getBoundingClientRect();
    return r.right > 0 && r.left < Math.max(document.documentElement.scrollWidth, innerWidth);
  }
  function dansLaVue(el) {
    const r = el.getBoundingClientRect();
    return r.bottom > 0 && r.right > 0 && r.top < innerHeight && r.left < innerWidth;
  }
  const boite = (el) => {
    if (!el) return null;
    const r = el.getBoundingClientRect();
    return { x: r.left, y: r.top, l: r.width, h: r.height };
  };

  // ---------- Mode 1 : QCM « propre » (boutons radio, cases, rôles ARIA) ----------
  function libelleDe(input) {
    if (input.labels?.length) return input.labels[0];
    const ids = input.getAttribute("aria-labelledby");
    if (ids) { const e = document.getElementById(ids.split(/\s+/)[0]); if (e) return e; }
    return input.closest("label") || input.parentElement;
  }

  function groupes() {
    const res = new Map();
    const ajouter = (cle, choix) => {
      if (!res.has(cle)) res.set(cle, []);
      res.get(cle).push(choix);
    };
    let n = 0;
    const idConteneur = new WeakMap();
    const cleConteneur = (el) => {
      const c = el.closest("fieldset,[role=radiogroup],[role=group],[role=listbox],form") || el.parentElement?.parentElement;
      if (!c) return "x";
      if (!idConteneur.has(c)) idConteneur.set(c, ++n);
      return "c" + idConteneur.get(c);
    };

    for (const input of document.querySelectorAll("input[type=radio],input[type=checkbox]")) {
      const lib = libelleDe(input);
      if (!lib || !texte(lib) || !(visible(input) || visible(lib))) continue;
      // Bouton masqué (case stylée en CSS) : on clique sur le libellé.
      const bouton = visible(input) ? input : lib;
      const cle = input.type === "radio" && input.name ? "r:" + input.name : cleConteneur(input);
      ajouter(cle, { bloc: lib, bouton, coche: input.checked });
    }
    for (const el of document.querySelectorAll("[role=radio],[role=checkbox],[role=option],[role=menuitemradio]")) {
      if (!visible(el) || !texte(el)) continue;
      ajouter("a:" + cleConteneur(el), {
        bloc: el, bouton: el,
        coche: el.getAttribute("aria-checked") === "true" || el.getAttribute("aria-selected") === "true",
      });
    }
    return [...res.values()].filter((g) => g.length >= 2);
  }

  // Texte situé juste avant le premier choix, en remontant les ancêtres.
  function questionDe(choix) {
    const premier = choix[0].bloc;
    const fs = premier.closest("fieldset");
    const lg = fs?.querySelector("legend");
    if (lg && texte(lg)) return { el: lg, texte: texte(lg) };
    const grp = premier.closest("[role=radiogroup],[role=group],[role=listbox]");
    if (grp) {
      const id = grp.getAttribute("aria-labelledby");
      const e = id && document.getElementById(id.split(/\s+/)[0]);
      if (e && texte(e)) return { el: e, texte: texte(e) };
      if (grp.getAttribute("aria-label")) return { el: grp, texte: propre(grp.getAttribute("aria-label")) };
    }
    let anc = premier.parentElement;
    for (let i = 0; anc && i < 8; i++, anc = anc.parentElement) {
      const q = texteAvant(anc, premier, choix);
      if (q && q.texte.length >= 5) return q;
    }
    return null;
  }

  // Zone de texte qui AFFICHE la question : certains sites l'écrivent en JavaScript dans un <textarea> ou un
  // <input> désactivé (ex. qcmquiz.com). Son contenu n'est pas un nœud texte : il faut lire sa valeur.
  // Au moins trois lettres d'affilée : écarte les compteurs (« 1 / 10 ») et les champs vides.
  const champAffichant = (n) =>
    (n.tagName === "TEXTAREA" || (n.tagName === "INPUT" && /^(text|search)?$/i.test(n.getAttribute("type") || "")))
    && /\p{L}{3}/u.test(n.value || "") && visible(n);

  function texteAvant(racine, cible, choix) {
    const w = document.createTreeWalker(racine, NodeFilter.SHOW_TEXT | NodeFilter.SHOW_ELEMENT);
    let dernier = null, valeur = null, n;
    while ((n = w.nextNode())) {
      if (cible.contains(n) || cible.compareDocumentPosition(n) & Node.DOCUMENT_POSITION_FOLLOWING) break;
      if (choix.some((c) => c.bloc.contains(n))) continue;
      if (n.nodeType === Node.ELEMENT_NODE) {
        if (champAffichant(n)) { dernier = n; valeur = propre(n.value); }
        continue;
      }
      if (!propre(n.textContent) || !visible(n.parentElement)) continue;
      dernier = n.parentElement.closest("p,h1,h2,h3,h4,h5,h6,legend,li,td,div,span,label") || n.parentElement;
      valeur = null;
    }
    if (!dernier || dernier.contains(cible)) return null;
    return { el: dernier, texte: (valeur ?? texte(dernier)).slice(0, 1000) };
  }

  function lettreDe(t, i) {
    const m = t.match(/^\s*([A-Ha-h1-9])\s*[.)\-:]\s+/);
    return m ? m[1].toUpperCase() : "ABCDEFGH"[i] || String(i + 1);
  }

  function extraireStructure() {
    const cx = innerWidth / 2, cy = innerHeight / 2;
    const candidats = groupes()
      .filter((g) => g.some((c) => dansLaVue(c.bloc)))
      .map((g) => {
        const r = g[0].bloc.getBoundingClientRect();
        return {
          g,
          repondu: g.some((c) => c.coche),
          distance: Math.hypot(r.left - cx, r.top - cy),
        };
      })
      // Priorité : question non répondue, puis la plus proche du centre de l'écran.
      .sort((a, b) => a.repondu - b.repondu || a.distance - b.distance);
    if (!candidats.length) return null;
    const choix = candidats[0].g;
    const q = questionDe(choix);
    return {
      mode: "structure",
      question: { texte: q?.texte || "", boite: boite(q?.el) },
      choix: choix.map((c, i) => {
        const t = texte(c.bloc);
        return { lettre: lettreDe(t, i), texte: t, coche: c.coche, boite_texte: boite(c.bloc), boite_bouton: boite(c.bouton) };
      }),
    };
  }

  // ---------- Mode 2 (secours) : texte de la page + éléments cliquables ----------
  function extrairePage() {
    const sel = "button,a,label,[role=button],[role=radio],[role=checkbox],[role=option],[onclick],li,div,span";
    const cliquables = [];
    for (const el of document.querySelectorAll(sel)) {
      if (!visible(el) || !dansLaVue(el)) continue;
      const t = texte(el);
      if (!t || t.length > 200) continue;
      const tag = el.tagName;
      const naturel = /^(BUTTON|A|LABEL)$/.test(tag) || el.hasAttribute("role") || el.hasAttribute("onclick");
      if (!naturel && getComputedStyle(el).cursor !== "pointer") continue;
      cliquables.push(el);
    }
    // On garde l'élément le plus externe quand plusieurs imbriqués ont le même texte.
    const gardes = cliquables.filter((el) => !cliquables.some((a) => a !== el && a.contains(el) && texte(a) === texte(el)));
    return {
      mode: "page",
      texte: (document.body?.innerText || "").slice(0, MAX_TEXTE),
      cliquables: gardes.slice(0, 120).map((el, i) => ({ id: i, texte: texte(el), boite: boite(el) })),
    };
  }

  // ---------- Vue compacte (pour Claude) : toute la page, dans l'ordre de lecture ----------
  // Texte visible + éléments cliquables numérotés [n] avec leur type et leur état (○/●).
  // Claude y trouve lui-même la question et ses choix, quelle que soit la mise en page du site.
  const MAX_COMPACTE = 30000;
  const IGNORES = /^(SCRIPT|STYLE|NOSCRIPT|TEMPLATE|IFRAME|HEAD|META|LINK|VIDEO|AUDIO)$/;
  const IMAGES = /^(IMG|CANVAS|SVG|svg)$/;
  const MAX_IMAGES = 12;     // images envoyées à Claude au plus (de toute la page, pas seulement l'écran)
  const TAILLE_MIN = 40;     // px : en dessous, c'est une icône, pas une image de question
  const ROLES = /^(button|radio|checkbox|option|link|tab|menuitem|menuitemradio|menuitemcheckbox|switch|treeitem)$/;

  function vueCompacte() {
    const lignes = [], elements = [], elsElements = [], images = [], elsImages = [], consommes = new WeakSet();
    let tampon = "";
    const vider = () => { const t = propre(tampon); if (t) lignes.push(t); tampon = ""; };

    // Image (photo de la question, ou image servant de choix) : repérée par [img k].
    // L'extension en fera une capture découpée, car beaucoup de sites servent leurs images
    // depuis un autre domaine (inaccessible directement).
    function image(el) {
      if (images.length >= MAX_IMAGES || !visible(el)) return null;
      const r = el.getBoundingClientRect();
      if (r.width < TAILLE_MIN || r.height < TAILLE_MIN) return null;
      const k = images.length;
      images.push({ id: k, boite: boite(el), src: String(el.currentSrc || el.src?.baseVal || el.src || "").slice(0, 300) });
      elsImages.push(el);
      return k;
    }
    const imagesDans = (el) => !el?.querySelectorAll ? "" :
      [...el.querySelectorAll("img,canvas,svg")].map(image).filter((k) => k != null).map((k) => ` [img ${k}]`).join("");

    const ajouter = (nature, txt, elTexte, elBouton) => {
      vider();
      const id = elements.length;
      txt = (propre(txt).slice(0, 200) + imagesDans(elTexte)).trim();
      elsElements.push(elBouton || elTexte);
      elements.push({ id, nature: nature.split(" ")[0], texte: txt,
                      boite_texte: boite(elTexte), boite_bouton: boite(elBouton) });
      lignes.push(`[${id}] ${nature} ${txt}`);
    };

    // Case/bouton radio : on l'associe à son libellé (qui ne sera pas répété ensuite).
    function caseACocher(input, lib) {
      lib = lib || libelleDe(input);
      if (lib) consommes.add(lib);
      const txt = texte(lib) || input.getAttribute("aria-label") || input.value || "";
      if (!(visible(input) || visible(lib))) return;
      const nom = input.name ? ` name=${input.name}` : "";
      // Beaucoup de sites cachent la vraie case hors de l'écran et dessinent la leur :
      // on clique alors sur le libellé.
      const bouton = surLaPage(input) ? input : (lib && visible(lib) ? lib : input);
      ajouter(`${input.type}${nom} ${input.checked ? "●" : "○"}`, txt, lib || input, bouton);
    }

    function nature(el, style) {
      const tag = el.tagName, role = el.getAttribute("role") || "";
      if (tag === "INPUT") return el.type;
      if (tag === "BUTTON" || role === "button") return "bouton";
      if (tag === "A" && el.hasAttribute("href")) return "lien";
      if (tag === "SELECT") return "liste";
      if (ROLES.test(role)) {
        const etat = el.getAttribute("aria-checked") === "true" || el.getAttribute("aria-selected") === "true";
        return `${role} ${etat ? "●" : "○"}`;
      }
      // div/span/li cliquables (onclick, curseur main) : seulement s'ils sont courts,
      // sinon c'est un conteneur entier (carte, bloc de question…) et on descend dedans.
      if ((el.hasAttribute("onclick") || style.cursor === "pointer") && texte(el).length <= 200
          && !el.querySelector("input,button,a[href],[role=radio],[role=checkbox],[role=option]")) return "cliquable";
      return null;
    }

    function visiter(n) {
      if (n.nodeType === Node.TEXT_NODE) { tampon += " " + n.textContent; return; }
      if (n.nodeType !== Node.ELEMENT_NODE || IGNORES.test(n.tagName) || consommes.has(n)) return;
      const style = getComputedStyle(n);
      if (style.display === "none" || style.visibility === "hidden") return;
      if (IMAGES.test(n.tagName)) {
        const k = image(n);
        if (k != null) {
          vider();
          const alt = propre(n.getAttribute("alt") || n.getAttribute("aria-label") || n.getAttribute("title") || "");
          lignes.push(`[img ${k}] image${alt ? ` (${alt})` : ""}`);
        }
        return;
      }

      if (n.tagName === "INPUT" && (n.type === "radio" || n.type === "checkbox")) return caseACocher(n);
      // Champ en lecture seule (certains sites y affichent l'énoncé, ex. <textarea readonly>) :
      // sa valeur n'est pas du texte de la page, on la lit donc comme du texte affiché.
      const champTexte = n.tagName === "TEXTAREA" || (n.tagName === "INPUT" && /^(text|search|)$/.test(n.type));
      if (champTexte && (n.readOnly || n.disabled)) {
        if (visible(n)) { vider(); const v = propre(n.value); if (v) lignes.push(v); }
        return;
      }
      // Champ à remplir (question à réponse libre). On n'envoie PAS ce qui y est tapé :
      // sinon chaque lettre changerait la page et relancerait une analyse.
      const saisie = (n.tagName === "INPUT" && /^(text|search|number|email|tel|url|)$/.test(n.type))
                     || n.tagName === "TEXTAREA" || (n.isContentEditable && n.hasAttribute("contenteditable"));
      if (saisie) {
        if (visible(n)) {
          const indication = propre(n.placeholder || n.getAttribute("aria-label") || "");
          ajouter(n.tagName === "INPUT" ? "champ à remplir" : "zone de texte à remplir",
                  indication ? `(${indication})` : "", n, n);
        }
        return;
      }
      if (n.tagName === "LABEL") {
        const input = n.querySelector("input[type=radio],input[type=checkbox]");
        if (input) { consommes.add(input); return caseACocher(input, n); }
      }
      const nat = nature(n, style);
      if (nat) {
        if (!visible(n)) return;
        const txt = n.tagName === "INPUT" ? (n.value || n.placeholder || "") : texte(n);
        if (txt) ajouter(nat, txt, n, n);
        return;
      }
      const bloc = !style.display.startsWith("inline");
      if (bloc) vider();
      if (n.shadowRoot) for (const c of n.shadowRoot.childNodes) visiter(c);
      for (const c of n.childNodes) visiter(c);
      if (bloc) vider();
    }

    if (document.body) visiter(document.body);
    vider();
    let page = lignes.join("\n");
    if (page.length > MAX_COMPACTE) page = page.slice(0, MAX_COMPACTE) + "\n[… page tronquée]";
    // Signature : le texte, plus l'adresse des images (même texte + nouvelle photo = nouvelle question).
    const signature = page + "\n" + images.map((i) => i.src).join("\n");
    return { page, elements, images, signature, elsImages, elsElements };
  }

  // ---------- Lecture des images dans la page ----------
  // Marche pour les images du même site ou autorisées (CORS) ; sinon l'extension en fait une capture d'écran.
  const COTE_MAX = 1024;
  function versJpeg(source, w, h) {
    const r = Math.min(1, COTE_MAX / Math.max(w, h));
    const toile = document.createElement("canvas");
    toile.width = Math.max(1, Math.round(w * r)); toile.height = Math.max(1, Math.round(h * r));
    const ctx = toile.getContext("2d");
    ctx.fillStyle = "#fff"; ctx.fillRect(0, 0, toile.width, toile.height); // fond blanc (PNG transparents)
    ctx.drawImage(source, 0, 0, toile.width, toile.height);
    return toile.toDataURL("image/jpeg", 0.85).split(",")[1]; // lève une erreur si l'image vient d'un autre site
  }
  const charger = (url) => new Promise((ok, ko) => { const i = new Image(); i.onload = () => ok(i); i.onerror = ko; i.src = url; });

  // Images capturées à l'écran après un clic droit « lire cette image » (adresse -> JPEG base64).
  const captures = new Map();
  let forcerEnvoi = false;

  async function lireImage(el) {
    const capturee = captures.get(el.currentSrc || el.src);
    if (capturee) return capturee;
    try {
      if (el.tagName === "CANVAS") return versJpeg(el, el.width, el.height);
      if (el.tagName.toLowerCase() === "svg") {
        const url = URL.createObjectURL(new Blob([new XMLSerializer().serializeToString(el)], { type: "image/svg+xml" }));
        try { const r = el.getBoundingClientRect(); return versJpeg(await charger(url), r.width, r.height); }
        finally { URL.revokeObjectURL(url); }
      }
      // Image encore en chargement (ex. question suivante qui vient de s'afficher) : on l'attend 4 s au plus.
      if (el.tagName === "IMG" && !(el.complete && el.naturalWidth)) {
        await Promise.race([el.decode().catch(() => {}), new Promise((ok) => setTimeout(ok, 4000))]);
      }
      if (el.tagName === "IMG" && el.complete && el.naturalWidth) {
        // Image d'un autre site : illisible ici (rien n'est retéléchargé), l'extension la capturera à l'écran.
        return versJpeg(el, el.naturalWidth, el.naturalHeight);
      }
    } catch {}
    return null;
  }

  async function analyser() {
    minuteur = null;
    const compacte = vueCompacte();
    if (!compacte.elements.length && !compacte.images.length) return; // rien à cliquer, remplir ou voir
    // On ne renvoie la page que si son contenu change. Les chiffres sont ignorés :
    // un chrono ou un compteur qui défile ne déclenche donc pas de nouvel envoi.
    // Cocher une case (○ → ●) ne compte pas non plus comme un changement de question.
    const signature = compacte.signature.replace(/\d+/g, "").replace(/[○●]/g, "");
    if (signature === derniereSignature && !forcerEnvoi) return;
    derniereSignature = signature;
    // Détection par règles, utilisée par le moteur local (Qwen) ; Claude, lui, lit la vue compacte.
    const res = extraireStructure() || extrairePage();
    const datas = await Promise.all(compacte.elsImages.map(lireImage));
    compacte.images.forEach((im, i) => { if (datas[i]) im.data = datas[i]; });
    // Éléments de la page : pas transmissibles. On les garde ici, liés au numéro de l'envoi, pour savoir
    // plus tard quelle question du résultat est à l'écran.
    const envoi = ++numeroEnvoi;
    envois.set(envoi, compacte.elsElements);
    if (envois.size > 5) envois.delete(envois.keys().next().value);
    delete compacte.elsImages; delete compacte.elsElements;
    chrome.runtime.sendMessage({
      type: "qcm",
      payload: {
        ...res,
        compacte,
        envoi,
        forcer: forcerEnvoi, // image capturée au clic droit : refaire l'analyse même si la page n'a pas changé
        url: location.href,
        titre: document.title,
        horodatage: new Date().toISOString(),
        vue: {
          largeur: innerWidth, hauteur: innerHeight,
          screenX, screenY, outerWidth, outerHeight,
          dpr: devicePixelRatio,
        },
      },
    }).catch(() => {});
    forcerEnvoi = false;
  }

  // Attend DELAI ms de calme, mais jamais plus de ATTENTE_MAX (page avec un chrono qui bouge en continu).
  const ATTENTE_MAX = 2500;
  let debutAttente = 0;
  const planifier = () => {
    const maintenant = Date.now();
    if (!minuteur) debutAttente = maintenant;
    clearTimeout(minuteur);
    minuteur = setTimeout(analyser, Math.max(0, Math.min(DELAI, debutAttente + ATTENTE_MAX - maintenant)));
  };
  const observateur = new MutationObserver(planifier);
  // Remplir un champ par JavaScript (el.value = …) ne modifie pas le DOM : l'observateur ne le voit pas.
  // On revérifie donc aussi la page toutes les 3 s (rien n'est envoyé si elle n'a pas changé).
  let verification = null;
  const demarrer = () => {
    observateur.observe(document.documentElement, { subtree: true, childList: true, characterData: true, attributes: true });
    verification = setInterval(planifier, 3000);
    planifier();
  };

  // ---------- Résultats : rien n'est ajouté à la page ----------
  // Ils s'affichent dans le panneau latéral de l'extension (panneau.html) ou dans la popup.
  // La page sert seulement à dire au panneau quelle question est à l'écran.

  // Parmi les questions de la page, celle dont les choix sont le plus près du centre de l'écran.
  function questionALEcran(res) {
    const els = envois.get(res.envoi) || [];
    let meilleure = 0, distance = Infinity;
    res.questions.forEach((q, i) => {
      for (const id of q.elements || []) {
        const e = els[id];
        if (!e?.isConnected) continue;
        const r = e.getBoundingClientRect();
        const d = Math.abs(r.top + r.height / 2 - innerHeight / 2);
        if (d < distance) { distance = d; meilleure = i; }
      }
    });
    return meilleure;
  }

  // Signale à l'extension que l'onglet est toujours utilisé (sert à l'arrêt automatique après 2 min sans question).
  const sonde = setInterval(() => { chrome.runtime.sendMessage({ type: "resultat" }).catch(() => {}); }, 1500);

  chrome.runtime.onMessage.addListener((msg, _expediteur, repondre) => {
    if (msg.type === "question-visible") {
      // Le panneau demande l'adresse de la page et la question à l'écran.
      repondre({ url: location.href, index: msg.resultats?.questions?.length ? questionALEcran(msg.resultats) : 0 });
      return;
    }
    if (msg.type === "zone-image") {
      // Où est l'image cliquée (clic droit) ? L'extension en découpera la capture d'écran.
      const img = [...document.images].find((i) => i.currentSrc === msg.src || i.src === msg.src);
      repondre(img ? { boite: boite(img), vue: { largeur: innerWidth, hauteur: innerHeight } } : null);
      return;
    }
    if (msg.type === "image-capturee") {
      captures.set(msg.src, msg.data);
      forcerEnvoi = true;
      planifier();
      return;
    }
    if (msg.type !== "stop") return;
    clearInterval(sonde);
    observateur.disconnect();
    clearInterval(verification);
    clearTimeout(minuteur);
    delete window.__qcmStream;
  });

  window.__qcmStream = { relancer: () => { derniereSignature = ""; planifier(); } };
  demarrer();
})();

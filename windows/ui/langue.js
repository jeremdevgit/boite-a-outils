/* SPDX-License-Identifier: GPL-3.0-or-later — Copyright (C) 2026 jeremdevgit — voir LICENSE */
// Langues : choisit la langue (lien ?lang=, choix enregistré, puis langue de Windows), traduit la page
// et fournit trad() aux scripts. Les textes sont dans textes/<langue>.js (le français sert de clé).
// L'interface étant construite au fil de l'eau (et une partie des textes venant du programme natif),
// tout ce qui s'affiche est traduit au moment où il apparaît : textes fixes, puis modèles
// (« {0} fichiers supprimés »), puis début de message (« Fichier introuvable : détail »).
(function () {
  const LANGUES = [["fr", "Français"], ["en", "English"], ["es", "Español"], ["de", "Deutsch"], ["it", "Italiano"], ["pt", "Português"], ["zh", "中文"], ["ja", "日本語"]];
  const LOCALES = { fr: "fr-FR", en: "en-US", es: "es-ES", de: "de-DE", it: "it-IT", pt: "pt-BR", zh: "zh-CN", ja: "ja-JP" };
  const connue = (c) => LANGUES.some((l) => l[0] === c);
  const nav = navigator.languages && navigator.languages.length ? navigator.languages : [navigator.language || ""];

  function choisir() {
    let c = null;
    try { c = new URLSearchParams(location.search).get("lang"); } catch (e) {}
    if (connue(c)) return c;
    try { c = localStorage.getItem("langue"); } catch (e) {}
    if (connue(c)) return c;
    for (const l of nav) { c = String(l).slice(0, 2).toLowerCase(); if (connue(c)) return c; }
    return "en";
  }
  const LANG = choisir();
  const LOCALE = nav.find((l) => String(l).slice(0, 2).toLowerCase() === LANG && String(l).length > 2) || LOCALES[LANG];
  const D = LANG === "fr" ? null : (window.TEXTES && window.TEXTES[LANG]) || {};
  let regles = null;
  try { regles = new Intl.PluralRules(LOCALE); } catch (e) {}
  const SEP = LANG === "fr" ? " : " : LANG === "zh" || LANG === "ja" ? "：" : ": ";

  // ---------- Modèles : clés contenant {0}, {n}… ----------
  // Rangés par premier mot (clés qui commencent par du texte) ou par dernier mot (clés qui
  // commencent par une valeur) : chaque texte affiché n'est comparé qu'à quelques modèles.
  const parDebut = new Map(), parFin = new Map(), sansAncre = [];
  const motDebut = (s) => (/^[^\s{]+/.exec(s) || [""])[0];
  const motFin = (s) => (/[^\s}]+$/.exec(s) || [""])[0];
  if (D) {
    for (const k in D) {
      if (k.indexOf("{") < 0 || !/\{\w+\}/.test(k)) continue;
      const fixe = k.replace(/\{\w+\}/g, "");
      if ((fixe.match(/\p{L}/gu) || []).length < 2) continue;
      const noms = [];
      const motif = k.split(/(\{\w+\})/).map((p) => {
        const m = /^\{(\w+)\}$/.exec(p);
        if (m) { noms.push(m[1]); return "([\\s\\S]+?)"; }
        return p.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
      }).join("");
      const modele = { re: new RegExp("^" + motif + "$"), noms, cle: k };
      const debut = motDebut(k);
      if (debut && k[0] !== "{") { if (!parDebut.has(debut)) parDebut.set(debut, []); parDebut.get(debut).push(modele); }
      else { const fin = motFin(k); if (!fin) sansAncre.push(modele); else { if (!parFin.has(fin)) parFin.set(fin, []); parFin.get(fin).push(modele); } }
    }
  }
  // unités dans les valeurs venues du programme natif (« 1,2 Go »)
  const UNITES = { o: "B", Ko: "KB", Mo: "MB", Go: "GB", To: "TB" };
  const unites = (v) => v.replace(/(\d) (o|Ko|Mo|Go|To)(?=\b|\/)/g, (m, d, u) => d + " " + UNITES[u]);
  function parModele(s) {
    const listes = [parDebut.get(motDebut(s)), parFin.get(motFin(s)), sansAncre];
    for (const l of listes) {
      if (!l) continue;
      for (const m of l) {
        const r = m.re.exec(s);
        if (!r) continue;
        const v = {};
        m.noms.forEach((n, i) => { const x = r[i + 1]; v[n] = (D[x] || unites(x)); });
        return D[m.cle].replace(/\{(\w+)\}/g, (t, n) => (n in v ? v[n] : t));
      }
    }
    return null;
  }
  // Texte affiché → traduction, ou null s'il n'y en a pas
  function tradTexte(s, html = false) {
    if (!D || !s) return null;
    if (D[s]) return D[s];
    // Les modèles dynamiques passent par les nœuds texte : leurs valeurs ne deviennent jamais du HTML.
    if (html) return null;
    const m = parModele(s);
    if (m) return m;
    const i = s.indexOf(" : ");
    if (i > 0) {
      const debut = s.slice(0, i), d = D[debut] || parModele(debut);
      if (d) { const reste = s.slice(i + 3); return d + SEP + (tradTexte(reste) || reste); }
    }
    return null;
  }

  // trad("Texte {n}", { n: 3 }) : traduction, puis remplacement des {valeurs}
  function trad(s, v) {
    let r = (D && D[s]) || s;
    if (v) r = r.replace(/\{(\w+)\}/g, (m, k) => (k in v ? v[k] : m));
    return r;
  }
  // tradn(n, "{n} fichier", "{n} fichiers") : singulier ou pluriel selon les règles de la langue
  function tradn(n, un, plusieurs, v) {
    const seul = regles ? regles.select(n) === "one" : Math.abs(n) < 2;
    return trad(seul ? un : plusieurs, Object.assign({ n: typeof n === "number" ? n.toLocaleString(LOCALE) : n }, v));
  }

  // ---------- Traduction de la page ----------
  const EN_LIGNE = new Set(["B", "I", "EM", "STRONG", "A", "CODE", "SPAN", "BR", "KBD", "SMALL", "SUP", "SUB", "ABBR", "MARK", "U", "S", "WBR"]);
  const IGNORES = /^(SCRIPT|STYLE|TEXTAREA|PRE|SVG|CANVAS|svg|path)$/;
  const ATTRIBUTS = ["placeholder", "title", "aria-label", "alt", "data-titre"];
  const net = (s) => s.replace(/\s+/g, " ").trim();
  const exclu = (el) => el.nodeType === 1 && (el.hasAttribute("data-brut") || (el.classList && (el.classList.contains("console") || el.classList.contains("mono"))));
  function enLigne(el) {
    for (const c of el.querySelectorAll("*")) if (!EN_LIGNE.has(c.tagName)) return false;
    return true;
  }
  // collecte : ensemble à remplir avec les textes trouvés (outil de traduction), sinon la page est traduite
  function traduire(racine, collecte) {
    if (!D && !collecte) return;
    const voir = (k, ecrire) => {
      if (!k) return;
      if (collecte) { collecte.add(k); return; }
      const t = tradTexte(k);
      if (t && t !== k) ecrire(t);
    };
    (function parcourir(el) {
      if (exclu(el)) return;
      for (const a of ATTRIBUTS) {
        const v = el.getAttribute && el.getAttribute(a);
        if (v && /\p{L}/u.test(v)) voir(net(v), (x) => el.setAttribute(a, x));
      }
      if (el.children && el.children.length && enLigne(el) && /\p{L}/u.test(el.textContent)) {
        const k = net(el.innerHTML);
        if (collecte) collecte.add(k);
        else { const t = tradTexte(k, true); if (t) { el.innerHTML = t; return; } }
      }
      for (const n of Array.from(el.childNodes)) {
        if (n.nodeType === 3) texte(n, voir);
        else if (n.nodeType === 1 && !IGNORES.test(n.tagName)) parcourir(n);
      }
    })(racine);
  }
  function texte(n, voir) {
    const m = /^(\s*)([\s\S]*?)(\s*)$/.exec(n.nodeValue);
    if (/\p{L}/u.test(m[2])) voir(net(m[2]), (x) => (n.nodeValue = m[1] + x + m[3]));
  }
  const voirSimple = (k, ecrire) => { const t = tradTexte(k); if (t && t !== k) ecrire(t); };

  // ---------- Suivi de ce qui apparaît ----------
  function suivre() {
    if (!D || !window.MutationObserver) return;
    const dansExclu = (n) => { for (let e = n.nodeType === 1 ? n : n.parentElement; e; e = e.parentElement) if (exclu(e) || IGNORES.test(e.tagName)) return true; return false; };
    const obs = new MutationObserver((liste) => {
      const vus = new Set();
      for (const m of liste) {
        if (m.type === "childList") {
          for (const n of m.addedNodes) {
            if (n.nodeType === 1) { if (!vus.has(n) && !dansExclu(n)) { vus.add(n); traduire(n.parentElement && enLigne(n.parentElement) && n.parentElement !== document.body ? n.parentElement : n); } }
            else if (n.nodeType === 3 && n.parentElement && !dansExclu(n)) {
              const p = n.parentElement;
              if (p.children.length && enLigne(p)) traduire(p); else texte(n, voirSimple);
            }
          }
        } else if (m.type === "characterData") {
          if (m.target.parentElement && !dansExclu(m.target)) texte(m.target, voirSimple);
        } else if (m.type === "attributes") {
          const v = m.target.getAttribute(m.attributeName);
          if (v && /\p{L}/u.test(v) && !dansExclu(m.target)) voirSimple(net(v), (x) => m.target.setAttribute(m.attributeName, x));
        }
      }
      obs.takeRecords(); // nos propres changements
    });
    obs.observe(document.body, { childList: true, subtree: true, characterData: true, attributes: true, attributeFilter: ATTRIBUTS });
  }

  function enregistrer(c) {
    try { localStorage.setItem("langue", c); return localStorage.getItem("langue") === c; } catch (e) { return false; }
  }
  function changer(c) {
    const garde = enregistrer(c);
    let avecLien = !garde;
    try { avecLien = avecLien || new URLSearchParams(location.search).has("lang"); } catch (e) {}
    if (avecLien) {
      const u = new URL(location.href);
      u.searchParams.set("lang", c);
      location.replace(u.href);
    } else location.reload();
  }

  // Menu des langues, placé dans chaque élément [data-langues]
  function menus(racine) {
    (racine || document).querySelectorAll("[data-langues]").forEach((place) => {
      const s = document.createElement("select");
      s.className = "langue field";
      s.setAttribute("aria-label", "Langue / Language");
      s.title = "Langue / Language";
      s.setAttribute("data-brut", "");
      for (const [c, nom] of LANGUES) {
        const o = document.createElement("option");
        o.value = c; o.textContent = nom; o.lang = c; o.selected = c === LANG;
        s.appendChild(o);
      }
      s.addEventListener("change", () => changer(s.value));
      place.replaceChildren(s);
    });
  }

  document.documentElement.lang = LANG;
  if (D && D[document.title]) document.title = D[document.title];

  window.LANG = LANG;
  window.LOCALE = LOCALE;
  window.LANGUES = LANGUES;
  window.trad = trad;
  window.tradn = tradn;
  window.tradTexte = (s) => tradTexte(s) || s;
  window.traduirePage = traduire;
  window.menusLangues = menus;
  // chargé avant les scripts de l'interface : la page fixe est traduite, puis tout ce qui s'ajoute
  traduire(document.body);
  menus();
  suivre();
})();

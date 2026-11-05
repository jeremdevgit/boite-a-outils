/* SPDX-License-Identifier: GPL-3.0-or-later — Copyright (C) 2026 jeremdevgit — voir LICENSE */
'use strict';
/* Fichiers lourds, façon WizTree : arborescence complète triée par place
   occupée, carte du disque (treemap) colorée par type, types de fichiers,
   recherche par nom, export CSV. L'analyse reste en mémoire côté natif :
   chaque clic n'interroge que l'arbre déjà construit. */

const DK = { scan: null, view: null, open: new Set(), kids: new Map(), items: new Map(), sel: new Set(), tab: 'tree', sort: { k: 'alloc', d: -1 }, q: '', ext: null, types: null, map: null, colors: new Map(), typeHi: null, files: null };
const DK_PALETTE = ['#4e8ff7', '#f2b134', '#3fc59a', '#e8615a', '#a879f0', '#3bc4d9', '#f08bc0', '#9ccc4f', '#f5874f', '#6d7ff5', '#d9c84a', '#4fb3a0', '#c9734f', '#b48ee0'];
const DK_LABEL = { mp4: 'Vidéo', mkv: 'Vidéo', avi: 'Vidéo', mov: 'Vidéo', webm: 'Vidéo', ts: 'Vidéo', mp3: 'Musique', flac: 'Musique', m4a: 'Musique', wav: 'Son', ogg: 'Son', jpg: 'Image', jpeg: 'Image', png: 'Image', gif: 'Image', webp: 'Image', heic: 'Photo', cr2: 'Photo RAW', nef: 'Photo RAW', arw: 'Photo RAW', dng: 'Photo RAW', psd: 'Photoshop', iso: 'Image disque', img: 'Image disque', vhdx: 'Disque virtuel', vhd: 'Disque virtuel', vmdk: 'Disque virtuel', vdi: 'Disque virtuel', zip: 'Archive', rar: 'Archive', '7z': 'Archive', gz: 'Archive', exe: 'Programme', msi: 'Installateur', msix: 'Installateur', dll: 'Bibliothèque', sys: 'Fichier système', pak: 'Données de jeu', vpk: 'Données de jeu', ucas: 'Données de jeu', utoc: 'Données de jeu', forge: 'Données de jeu', bundle: 'Données de jeu', bin: 'Données', dat: 'Données', blob: 'Données', db: 'Base de données', sqlite: 'Base de données', log: 'Journal', etl: 'Journal', tmp: 'Temporaire', pdf: 'PDF', docx: 'Word', xlsx: 'Excel', pptx: 'PowerPoint', txt: 'Texte', esd: 'Image Windows', wim: 'Image Windows', cab: 'Archive Windows', ttf: 'Police', js: 'Script', json: 'Données', pdb: 'Symboles', lib: 'Bibliothèque', obj: 'Objet compilé', rlib: 'Bibliothèque Rust', safetensors: 'Modèle d\'IA', gguf: 'Modèle d\'IA', ckpt: 'Modèle d\'IA', pt: 'Modèle d\'IA', onnx: 'Modèle d\'IA', edb: 'Index de recherche', evtx: 'Journal Windows', dmp: 'Vidage mémoire' };
const DK_FOLDER = '<svg class="dk-ico" viewBox="0 0 24 24"><path d="M3 6a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/></svg>';
const dkExt = n => { const i = n.lastIndexOf('.'); const e = i > 0 ? n.slice(i + 1) : ''; return e && e.length <= 12 && !e.includes(' ') ? e.toLowerCase() : ''; };
function dkColor(ext) {
  if (!ext) return '#7b8194';
  let c = DK.colors.get(ext);
  if (!c) { let h = 0; for (const ch of ext) h = (h * 31 + ch.charCodeAt(0)) >>> 0; c = `hsl(${h % 360} 28% 48%)`; DK.colors.set(ext, c); }
  return c;
}
const dkTypeName = e => e ? `.${e}` : '(sans extension)';

views.large = async (v, live) => {
  const info = state.info || (state.info = await bao.call('info'));
  if (!live()) return;
  let pick = DK.scan ? DK.scan.path : (info.drives[0]?.drive || 'C:\\');
  v.innerHTML = `<h1>Fichiers lourds</h1><p class="lead">Tout ce qui prend de la place, dossier par dossier, avec la carte du disque. Les éléments choisis vont dans la Corbeille : rien n'est perdu tant qu'elle n'est pas vidée.</p>
    <div class="card glass"><div class="toolbar" style="margin:0"><div class="chips" id="dk-roots">${info.drives.map(d => `<span class="chip" data-root="${esc(d.drive)}" title="${fmtSize(d.total - d.free)} utilisés sur ${fmtSize(d.total)}">Disque ${esc(d.drive.replace(/\\$/, ''))} <span class="muted small">${fmtSize(d.total - d.free)}</span></span>`).join('')}<span class="chip" data-root="${esc(info.home)}">Dossier personnel</span></div>
      <input class="field grow" id="dk-path" placeholder="ou un dossier : D:\\Jeux" style="min-width:180px">
      <button class="btn" id="dk-pick">Choisir…</button><button class="btn primary" id="dk-scan">Analyser</button></div>
      <div class="small muted" style="margin-top:10px">${info.elevated ? 'Disques NTFS : la table MFT est lue directement, un disque entier en quelques secondes.' : 'Mode limité : les dossiers sont parcourus un par un (plus lent). En administrateur, la table MFT est lue directement : un disque entier en quelques secondes. <button class="btn small" data-act="elevate">Relancer en administrateur</button>'}</div></div>
    <div id="out"></div>`;
  const out = $('#out', v);
  const markRoot = () => $$('[data-root]', v).forEach(c => c.classList.toggle('on', !$('#dk-path', v).value.trim() && c.dataset.root.toLowerCase() === pick.toLowerCase()));
  markRoot();
  $('#dk-roots', v).onclick = e => { const r = e.target.closest('[data-root]'); if (r) { pick = r.dataset.root; $('#dk-path', v).value = ''; markRoot(); } };
  $('#dk-path', v).oninput = markRoot;
  $('#dk-path', v).onkeydown = e => { if (e.key === 'Enter') scan(); };
  $('#dk-pick', v).onclick = async () => { const r = await bao.call('backup.pick').catch(() => null); if (r?.path) { $('#dk-path', v).value = r.path; markRoot(); } };
  $('#dk-scan', v).onclick = () => scan();

  // ── analyse ──
  const scan = async root => {
    root = root || $('#dk-path', v).value.trim() || pick;
    out.innerHTML = `<div class="progress glass"><div class="spinner"></div><div class="grow"><div id="pg-a">Analyse de ${esc(root)}…</div><div class="dk-prog"><i id="pg-bar"></i></div><div class="small muted ellipsis" id="pg-b"></div></div><button class="btn small" id="stop">Arrêter</button></div>`;
    const job = bao.call('tree.scan', { root }, d => {
      const a = $('#pg-a', out), b = $('#pg-b', out), bar = $('#pg-bar', out);
      if (!a) return;
      if (d.phase === 'mft') { const p = d.total ? d.done / d.total * 100 : 0; a.textContent = `Lecture de la table MFT… ${nf0.format(p)} %`; bar.style.width = p + '%'; b.textContent = `${nf0.format(d.done)} enregistrements sur ${nf0.format(d.total)}`; }
      else if (d.phase === 'walk') { a.textContent = `${nf0.format(d.files)} fichiers · ${fmtSize(d.bytes)}`; b.textContent = d.dir; bar.parentNode.hidden = true; }
      else if (d.phase === 'build') { a.textContent = 'Construction de l\'arborescence…'; bar.style.width = '100%'; b.textContent = ''; }
    });
    $('#stop', out).onclick = () => bao.cancel(job);
    router.cleanup.push(() => bao.cancel(job));
    try {
      const r = await job;
      Object.assign(DK, { scan: r, view: r.root, open: new Set(), kids: new Map(), items: new Map(), sel: new Set(), q: '', ext: null, typeHi: null, files: null });
      if (live()) { out.innerHTML = ''; await openView(r.root); }
    } catch (e) { if (live()) out.innerHTML = `<div class="note warn">${esc(e.message)}</div>`; }
  };

  // ── données ──
  const loadKids = async (id, force) => {
    if (!force && DK.kids.has(id)) return DK.kids.get(id);
    const r = await bao.call('tree.children', { id });
    DK.kids.set(id, r);
    for (const it of r.items) DK.items.set(it.id, it);
    DK.items.set(id, r.node);
    return r;
  };
  const setColors = ty => {
    DK.colors = new Map();
    ty.types.filter(t => t.name).slice(0, DK_PALETTE.length).forEach((t, i) => DK.colors.set(t.name, DK_PALETTE[i]));
  };
  const prepMap = m => {
    const byP = new Map(), byId = new Map();
    for (const [id, p, a, t, e, n] of m.items) {
      const it = { id, p, a, t, e: m.exts[e] || '', n };
      byId.set(id, it);
      (byP.get(p) || byP.set(p, []).get(p)).push(it);
    }
    return { root: m.root, alloc: m.alloc, byP, byId, rects: [], rectById: new Map(), base: null, hover: null };
  };
  const openView = async (id, keepOpen) => {
    if (!keepOpen) { DK.open = new Set(); DK.sel = new Set(); DK.files = null; DK.typeHi = null; }
    DK.view = id;
    const [, ty, m] = await Promise.all([loadKids(id, true), bao.call('tree.types', { id }), bao.call('tree.map', { id, max: 20000 })]);
    if (!live()) return;
    DK.types = ty; setColors(ty); DK.map = prepMap(m);
    if (!$('#dk-list', out)) shell();
    renderSummary(); renderCrumbs(); renderTab(); drawMap(); renderSel();
  };
  const refresh = async () => {
    const ids = [DK.view, ...DK.open];
    await Promise.all(ids.map(id => loadKids(id, true).catch(() => { DK.open.delete(id); DK.kids.delete(id); })));
    DK.files = null;
    await openView(DK.view, true);
  };
  const pathOf = async id => DK.items.get(id)?.path || (await bao.call('tree.info', { id })).item.path;

  // ── squelette de la page ──
  const shell = () => {
    out.innerHTML = `<div class="note info" id="dk-sum"></div>
      <div class="dk-nav"><div class="dk-crumbs" id="dk-crumbs"></div><div class="row" style="gap:6px"><button class="btn small" id="dk-up" title="Dossier parent (touche Retour arrière)">↑ Remonter</button><button class="btn small" id="dk-export" title="Dossiers et fichiers d'au moins 1 Mo, dans Téléchargements">Exporter (CSV)</button><button class="btn small" id="dk-rescan">Réanalyser</button></div></div>
      <div class="dk-tabs"><div class="chips" id="dk-tabs"><span class="chip" data-tab="tree">Arborescence</span><span class="chip" data-tab="files">Plus gros fichiers</span><span class="chip" data-tab="types">Types de fichiers</span></div><input class="field" id="dk-q" placeholder="Rechercher : *.iso, setup, *.mp4;*.mkv" value="${esc(DK.q)}"></div>
      <div class="card glass dk-list" id="dk-list"></div>
      <div class="card glass dk-selbar" id="dk-selbar"></div>
      <div class="card glass dk-map" id="dk-mapbox"><canvas id="dk-canvas"></canvas><div class="dk-tip" id="dk-tip" hidden></div><div class="dk-legend" id="dk-legend"></div></div>`;
    $('#dk-tabs', out).onclick = e => { const t = e.target.closest('[data-tab]'); if (t) { DK.tab = t.dataset.tab; renderTab(); } };
    $('#dk-up', out).onclick = goUp;
    $('#dk-rescan', out).onclick = () => scan(DK.scan.path);
    $('#dk-export', out).onclick = async () => {
      const n = DK.kids.get(DK.view).node;
      const stamp = new Date().toISOString().slice(0, 16).replace(/[T:]/g, '-');
      toast('Export en cours…');
      try { const r = await bao.call('tree.export', { id: DK.view, name: `Analyse ${n.path.replace(/[:\\]+/g, ' ').trim()} ${stamp}` }); toast(`${nf0.format(r.rows)} lignes exportées dans Téléchargements`); }
      catch (e) { toast('Export impossible : ' + e.message); }
    };
    $('#dk-crumbs', out).onclick = e => { const c = e.target.closest('[data-nav]'); if (c && +c.dataset.nav !== DK.view) openView(+c.dataset.nav); };
    let qt = 0;
    const q = $('#dk-q', out);
    const search = () => { DK.q = q.value.trim(); DK.ext = null; DK.files = null; DK.tab = DK.q ? 'files' : DK.tab; renderTab(); };
    q.oninput = () => { clearTimeout(qt); qt = setTimeout(search, 350); };
    q.onkeydown = e => { if (e.key === 'Enter') { clearTimeout(qt); search(); } if (e.key === 'Escape') { q.value = ''; search(); } };
    const list = $('#dk-list', out);
    list.addEventListener('click', onListClick);
    list.addEventListener('dblclick', onListDbl);
    $('#dk-selbar', out).onclick = onSelAction;
    const cv = $('#dk-canvas', out);
    cv.onmousemove = mapHover;
    cv.onmouseleave = () => { $('#dk-tip', out).hidden = true; if (DK.map) { DK.map.hover = null; compose(); } };
    cv.onclick = mapClick;
    cv.ondblclick = mapDbl;
    let rw = 0, rt = 0;
    const ro = new ResizeObserver(() => { const w = $('#dk-mapbox', out)?.clientWidth; if (w && w !== rw) { rw = w; clearTimeout(rt); rt = setTimeout(drawMap, 120); } });
    ro.observe($('#dk-mapbox', out));
    router.cleanup.push(() => ro.disconnect());
  };

  const renderSummary = () => {
    const n = DK.kids.get(DK.view).node, s = DK.scan;
    const drive = info.drives.find(d => d.drive.toLowerCase() === n.path.toLowerCase());
    const hidden = drive ? (drive.total - drive.free) - n.alloc : 0;
    $('#dk-sum', out).innerHTML = `<b>${fmtSize(n.alloc)}</b> sur le disque · ${nf0.format(n.files)} fichiers · ${nf0.format(n.dirs)} dossiers${Math.abs(n.size - n.alloc) > 1e8 ? ` · taille des fichiers ${fmtSize(n.size)}` : ''}${drive ? ` · ${fmtSize(drive.free)} libres sur ${fmtSize(drive.total)}` : ''}<br><span class="small">Analysé en ${nf1.format(s.ms / 1000)} s ${s.method === 'mft' ? 'par lecture directe de la table MFT' : 'en parcourant les dossiers'}${s.cancelled ? ' · analyse arrêtée avant la fin' : ''}. Les fichiers « dans le nuage » (OneDrive…) n'occupent rien.${hidden > 2e9 ? ` ${fmtSize(hidden)} utilisés ne sont dans aucun fichier visible : points de restauration, corbeilles d'autres comptes, métadonnées du disque${s.method === 'mft' ? '' : ', dossiers inaccessibles sans droits administrateur'}.` : ''}</span>`;
  };
  const renderCrumbs = () => {
    const c = DK.kids.get(DK.view).crumbs;
    $('#dk-crumbs', out).innerHTML = c.map((x, i) => `${i ? '<span class="sep">›</span>' : ''}<a data-nav="${x.id}">${esc(x.name)}</a>`).join('');
    $('#dk-up', out).disabled = c.length < 2;
  };
  const goUp = () => { const c = DK.kids.get(DK.view)?.crumbs; if (c && c.length > 1) openView(c[c.length - 2].id); };

  // ── onglets ──
  const sorters = { name: (a, b) => a.name.localeCompare(b.name, 'fr', { sensitivity: 'base', numeric: true }), alloc: (a, b) => a.alloc - b.alloc || a.size - b.size, size: (a, b) => a.size - b.size, files: (a, b) => (a.dir ? a.files + 1 : 0) - (b.dir ? b.files + 1 : 0), mtime: (a, b) => a.mtime - b.mtime };
  const sorted = list => { const f = sorters[DK.sort.k] || sorters.alloc; return [...list].sort((a, b) => DK.sort.d * f(a, b) || b.alloc - a.alloc); };
  const th = (k, label, cls = '') => `<th class="sort ${cls}" data-sort="${k}">${label}${DK.sort.k === k ? (DK.sort.d < 0 ? ' ▾' : ' ▴') : ''}</th>`;
  const pctCell = (a, total) => { const p = total > 0 ? Math.min(100, a / total * 100) : 0; return `<td class="dk-pct"><div class="dk-pbar"><i style="width:${p.toFixed(1)}%"></i></div><span>${nf1.format(p)} %</span></td>`; };
  const ico = it => it.dir ? DK_FOLDER : `<i class="dk-sw" style="background:${dkColor(dkExt(it.name))}"></i>`;
  const sysNote = it => !it.path ? '' : SYSTEM_FILES[it.name.toLowerCase()] || (isSystemPath(it.path) || isSystemPath(it.path + '\\') ? 'Fichier de Windows ou d\'un programme installé : désinstallez le programme plutôt que de supprimer ses fichiers.' : '');

  const renderTab = () => {
    $$('#dk-tabs [data-tab]', out).forEach(c => c.classList.toggle('on', c.dataset.tab === DK.tab));
    const list = $('#dk-list', out);
    // même onglet : position gardée (dépliage, tri) ; autre onglet : en haut
    const top = list.dataset.tab === DK.tab ? list.scrollTop : 0;
    list.dataset.tab = DK.tab;
    if (DK.tab === 'tree') renderTree(list);
    else if (DK.tab === 'files') renderFiles(list);
    else renderTypes(list);
    list.scrollTop = top;
  };

  const renderTree = list => {
    const root = DK.kids.get(DK.view);
    const rows = [];
    const row = (it, depth, total, open, label) => `<tr class="dk-row${DK.sel.has(it.id) ? ' on' : ''}" data-id="${it.id}"><td class="dk-name" style="padding-left:${6 + depth * 18}px">${it.dir && it.kids && depth ? `<a class="dk-tog" data-tog="${it.id}">${open ? '▾' : '▸'}</a>` : '<span class="dk-tog"></span>'}${ico(it)}<span class="ellipsis" title="${esc(label || it.name)}">${esc(label || it.name)}</span></td>${pctCell(it.alloc, total)}<td class="r size">${fmtSize(it.alloc)}</td><td class="r hide-s muted">${fmtSize(it.size)}</td><td class="r hide-s muted">${it.dir ? nf0.format(it.files) : ''}</td><td class="r hide-s muted">${it.dir ? nf0.format(it.dirs) : ''}</td><td class="r hide-s small muted">${it.mtime ? fmtDate(it.mtime) : ''}</td></tr>`;
    rows.push(row(root.node, 0, root.node.alloc, true, root.node.path));
    const walk = (id, depth) => {
      const c = DK.kids.get(id);
      if (!c) return;
      for (const it of sorted(c.items)) {
        const open = it.dir && DK.open.has(it.id) && DK.kids.has(it.id);
        rows.push(row(it, depth, c.node.alloc, open));
        if (open) walk(it.id, depth + 1);
      }
      if (c.more) rows.push(`<tr><td colspan="7" class="small muted" style="padding-left:${24 + depth * 18}px">… ${nf0.format(c.more)} éléments plus petits · ${fmtSize(c.moreAlloc)}</td></tr>`);
    };
    walk(DK.view, 1);
    list.innerHTML = `<table class="table dk-table"><thead><tr>${th('name', 'Nom')}${th('alloc', '% du parent')}${th('alloc', 'Sur le disque', 'r')}${th('size', 'Taille', 'r hide-s')}${th('files', 'Fichiers', 'r hide-s')}<th class="r hide-s">Dossiers</th>${th('mtime', 'Modifié', 'r hide-s')}</tr></thead><tbody>${rows.join('')}</tbody></table>`;
  };

  const renderFiles = async list => {
    if (!DK.files) {
      list.innerHTML = '<div class="row" style="padding:12px"><div class="spinner"></div><span class="muted">Recherche…</span></div>';
      const args = { id: DK.view, n: 1000 };
      if (DK.ext) args.ext = DK.ext.id; else if (DK.q) args.q = DK.q;
      try { DK.files = await bao.call('tree.top', args); } catch (e) { list.innerHTML = `<div class="note warn">${esc(e.message)}</div>`; return; }
      if (!live() || DK.tab !== 'files') return;
      for (const it of DK.files.items) DK.items.set(it.id, it);
    }
    const r = DK.files, base = DK.kids.get(DK.view).node.path;
    const filt = DK.ext ? `<span class="chip on" data-clear="1">Type ${esc(dkTypeName(DK.ext.name))} ✕</span>` : DK.q ? `<span class="chip on" data-clear="1">« ${esc(DK.q)} » ✕</span>` : '';
    const head = `<div class="row" style="padding:8px 8px 4px;gap:10px">${filt}<span class="small muted">${r.count > r.items.length ? `${nf0.format(r.items.length)} plus gros sur ${nf0.format(r.count)}` : plural(r.count, 'élément', 'éléments')} · ${fmtSize(r.alloc)}${!DK.q && !DK.ext ? ' · tapez un nom ou *.ext pour chercher' : ''}</span></div>`;
    if (!r.items.length) { list.innerHTML = head + '<div class="empty">Aucun élément trouvé</div>'; return; }
    const items = DK.sort.k === 'alloc' && DK.sort.d < 0 ? r.items : sorted(r.items);
    list.innerHTML = head + `<table class="table dk-table"><thead><tr>${th('name', 'Nom')}${th('alloc', 'Sur le disque', 'r')}${th('size', 'Taille', 'r hide-s')}${th('mtime', 'Modifié', 'r hide-s')}</tr></thead><tbody>${items.map(it => {
      const sys = sysNote(it);
      const rel = it.path.toLowerCase().startsWith(base.toLowerCase()) ? it.path.slice(base.length).replace(/^\\/, '') : it.path;
      const dir = rel.slice(0, Math.max(0, rel.lastIndexOf('\\')));
      return `<tr class="dk-row${DK.sel.has(it.id) ? ' on' : ''}" data-id="${it.id}"><td class="dk-name dk-file">${ico(it)}<span class="dk-fn"><b class="ellipsis" title="${esc(it.path)}">${esc(it.name)}</b><span class="small muted ellipsis">${esc(dir || base)}</span>${sys ? `<span class="small ellipsis" style="color:var(--warn)" title="${esc(sys)}">${esc(sys)}</span>` : ''}</span></td><td class="r size">${fmtSize(it.alloc)}</td><td class="r hide-s muted">${fmtSize(it.size)}</td><td class="r hide-s small muted">${it.mtime ? fmtDate(it.mtime) : ''}</td></tr>`;
    }).join('')}</tbody></table>`;
  };

  const renderTypes = list => {
    const t = DK.types, total = DK.kids.get(DK.view).node.alloc;
    list.innerHTML = `<div class="small muted" style="padding:8px 8px 4px">${plural(t.total, 'type de fichier', 'types de fichiers')}. Clic : repérer sur la carte · double-clic : lister ces fichiers.</div><table class="table dk-table dk-types"><thead><tr><th>Type</th><th>% du dossier</th><th class="r">Sur le disque</th><th class="r hide-s">Fichiers</th></tr></thead><tbody>${t.types.map(x => `<tr class="${DK.typeHi === x.name ? 'on' : ''}" data-ext="${x.ext}" data-name="${esc(x.name)}"><td class="dk-name"><i class="dk-sw" style="background:${dkColor(x.name)}"></i><b>${esc(dkTypeName(x.name))}</b> <span class="small muted">${esc(DK_LABEL[x.name] || '')}</span></td>${pctCell(x.alloc, total)}<td class="r size">${fmtSize(x.alloc)}</td><td class="r hide-s muted">${nf0.format(x.count)}</td></tr>`).join('')}</tbody></table>`;
  };

  // ── sélection ──
  const select = (id, add) => {
    if (add) DK.sel.has(id) ? DK.sel.delete(id) : DK.sel.add(id);
    else DK.sel = new Set([id]);
    $$('#dk-list tr[data-id]', out).forEach(r => r.classList.toggle('on', DK.sel.has(+r.dataset.id)));
    renderSel(); compose();
  };
  const renderSel = () => {
    const bar = $('#dk-selbar', out);
    const items = [...DK.sel].map(i => DK.items.get(i) || (DK.map?.byId.get(i) && { id: i, name: DK.map.byId.get(i).n, dir: DK.map.byId.get(i).t > 0, alloc: DK.map.byId.get(i).a })).filter(Boolean);
    if (!items.length) { bar.innerHTML = '<span class="small muted">Cliquez un élément dans la liste ou sur la carte (Ctrl pour en choisir plusieurs) · double-clic sur un dossier pour l\'ouvrir ici · Suppr pour mettre à la Corbeille</span>'; return; }
    const one = items.length === 1 ? items[0] : null;
    const tot = items.reduce((s, x) => s + x.alloc, 0);
    bar.innerHTML = `<div class="grow ellipsis">${one ? `${one.dir ? DK_FOLDER : `<i class="dk-sw" style="background:${dkColor(dkExt(one.name))}"></i>`}<b>${esc(one.name)}</b> · ${fmtSize(one.alloc)}${one.dir && one.files != null ? ` · ${nf0.format(one.files)} fichiers` : ''}` : `<b>${items.length} éléments</b> · ${fmtSize(tot)}`}</div>
      <button class="btn small" data-sa="reveal">Afficher dans l'explorateur</button><button class="btn small" data-sa="copy">Copier le chemin</button>${one?.dir && one.id !== DK.view ? '<button class="btn small" data-sa="zoom">Ouvrir ici</button>' : ''}${one?.id === DK.view ? '' : '<button class="btn small danger" data-sa="trash">Mettre à la Corbeille</button>'}`;
  };
  const onSelAction = async e => {
    const b = e.target.closest('[data-sa]'); if (!b) return;
    const ids = [...DK.sel];
    if (!ids.length) return;
    if (b.dataset.sa === 'reveal') bao.call('files.reveal', { path: await pathOf(ids[0]) });
    else if (b.dataset.sa === 'copy') {
      const t = (await Promise.all(ids.map(pathOf))).join('\r\n');
      try { await navigator.clipboard.writeText(t); } catch { const ta = document.createElement('textarea'); ta.value = t; document.body.append(ta); ta.select(); document.execCommand('copy'); ta.remove(); }
      toast(ids.length > 1 ? 'Chemins copiés' : 'Chemin copié');
    } else if (b.dataset.sa === 'zoom') openView(ids[0]);
    else if (b.dataset.sa === 'trash') recycle();
  };
  const recycle = async () => {
    const ids = [...DK.sel].filter(i => i !== DK.view);
    if (!ids.length) return;
    const infos = (await Promise.all(ids.map(id => bao.call('tree.info', { id }).catch(() => null)))).filter(Boolean).map(r => r.item);
    const ok = [], blocked = [];
    for (const it of infos) ((sysNote(it) || /^[a-z]:\\[^\\]*$/i.test(it.path) && it.dir) ? blocked : ok).push(it);
    if (!ok.length) return toast('À laisser en place : élément de Windows, d\'un programme installé ou dossier à la racine du disque.');
    const sz = ok.reduce((s, x) => s + x.alloc, 0);
    if (!await confirmAction(`Mettre ${plural(ok.length, 'élément', 'éléments')} à la Corbeille ?`, `<p>${fmtSize(sz)} sur le disque. Récupérables depuis la Corbeille ; l'espace n'est libéré qu'une fois la Corbeille vidée (Nettoyage → Corbeille).</p>${blocked.length ? `<p class="small" style="color:var(--warn)">${plural(blocked.length, 'élément laissé', 'éléments laissés')} de côté : Windows, programme installé ou dossier à la racine du disque.</p>` : ''}<div class="console">${ok.map(f => esc(f.path)).join('\n')}</div>`, 'Mettre à la Corbeille', true)) return;
    toast('Mise à la Corbeille…');
    const r = await bao.call('tree.recycle', { ids: ok.map(x => x.id) }).catch(err => ({ error: err.message }));
    if (r.error) return toast('Échec : ' + r.error);
    toast(`${plural(r.recycled, 'élément', 'éléments')} dans la Corbeille${r.failed ? `, ${r.failed} en échec (utilisé ?)` : ''}`);
    DK.sel = new Set();
    if (live()) await refresh();
  };

  // ── clics dans la liste ──
  const onListClick = async e => {
    const s = e.target.closest('[data-sort]');
    if (s) { const k = s.dataset.sort; DK.sort = DK.sort.k === k ? { k, d: -DK.sort.d } : { k, d: k === 'name' ? 1 : -1 }; renderTab(); return; }
    if (e.target.closest('[data-clear]')) { DK.q = ''; DK.ext = null; DK.files = null; $('#dk-q', out).value = ''; renderTab(); return; }
    const tg = e.target.closest('[data-tog]');
    if (tg) {
      const id = +tg.dataset.tog;
      if (DK.open.has(id)) DK.open.delete(id);
      else { DK.open.add(id); if (!DK.kids.has(id)) { tg.textContent = '…'; await loadKids(id).catch(() => DK.open.delete(id)); } }
      if (live()) renderTab();
      return;
    }
    const ty = e.target.closest('tr[data-ext]');
    if (ty) { DK.typeHi = DK.typeHi === ty.dataset.name ? null : ty.dataset.name; $$('tr[data-ext]', out).forEach(r => r.classList.toggle('on', r.dataset.name === DK.typeHi)); drawMap(); return; }
    const r = e.target.closest('tr[data-id]');
    if (r) select(+r.dataset.id, e.ctrlKey || e.metaKey);
  };
  const onListDbl = e => {
    const ty = e.target.closest('tr[data-ext]');
    if (ty) { DK.ext = { id: +ty.dataset.ext, name: ty.dataset.name }; DK.q = ''; $('#dk-q', out).value = ''; DK.files = null; DK.tab = 'files'; renderTab(); return; }
    const r = e.target.closest('tr[data-id]');
    if (!r || e.target.closest('[data-tog]')) return;
    const it = DK.items.get(+r.dataset.id);
    if (it?.dir && it.id !== DK.view) openView(it.id);
    else if (it && !it.dir) pathOf(it.id).then(path => bao.call('files.reveal', { path }));
  };
  // déplie l'arborescence jusqu'à un élément choisi sur la carte
  const expandTo = async id => {
    const r = await bao.call('tree.info', { id }).catch(() => null);
    if (!r || !live()) return;
    DK.items.set(id, { ...r.item });
    const i = r.chain.indexOf(DK.view);
    if (i < 0) return;
    for (const a of r.chain.slice(i + 1, -1)) { await loadKids(a).catch(() => {}); DK.open.add(a); }
    if (!live()) return;
    renderSel();
    if (DK.tab !== 'tree') return;
    renderTab();
    $(`#dk-list tr[data-id="${id}"]`, out)?.scrollIntoView({ block: 'nearest' });
  };

  // ── carte du disque ──
  const squarify = (items, x, y, w, h, total, put) => {
    if (total <= 0) return;
    const scale = w * h / total;
    let i = 0;
    while (i < items.length && w >= 1 && h >= 1) {
      const short = Math.min(w, h);
      const row = [];
      let sum = 0, worst = Infinity;
      while (i < items.length) {
        const ar = items[i].a * scale, s2 = sum + ar, big = row.length ? row[0].a * scale : ar;
        const w2 = Math.max(short * short * big / (s2 * s2), s2 * s2 / (short * short * ar));
        if (row.length && w2 > worst) break;
        row.push(items[i]); sum = s2; worst = w2; i++;
      }
      const thick = sum / short;
      if (w >= h) { let yy = y; for (const r of row) { const hh = r.a * scale / thick; put(r, x, yy, thick, hh); yy += hh; } x += thick; w -= thick; }
      else { let xx = x; for (const r of row) { const ww = r.a * scale / thick; put(r, xx, y, ww, thick); xx += ww; } y += thick; h -= thick; }
    }
  };
  const drawMap = () => {
    const M = DK.map, box = $('#dk-mapbox', out), cv = $('#dk-canvas', out);
    if (!M || !box) return;
    const W = Math.max(200, box.clientWidth - 16), H = Math.round(Math.min(560, Math.max(260, innerHeight * .42)));
    const dpr = devicePixelRatio || 1;
    cv.width = W * dpr; cv.height = H * dpr; cv.style.width = W + 'px'; cv.style.height = H + 'px';
    const base = document.createElement('canvas'); base.width = cv.width; base.height = cv.height;
    const g = base.getContext('2d'); g.scale(dpr, dpr);
    g.fillStyle = '#141722'; g.fillRect(0, 0, W, H);
    M.rects = []; M.rectById = new Map(); M.W = W; M.H = H;
    const hi = DK.typeHi;
    const leaf = (it, x, y, w, h) => {
      const dim = hi != null && (it.t || it.e !== hi);
      g.globalAlpha = dim ? .16 : 1;
      g.fillStyle = it.t ? '#5d6480' : dkColor(it.e);
      g.fillRect(x, y, w, h);
      if (w > 3 && h > 3) {
        const gr = g.createLinearGradient(x, y, x + w, y + h);
        gr.addColorStop(0, 'rgba(255,255,255,.30)'); gr.addColorStop(.55, 'rgba(255,255,255,0)'); gr.addColorStop(1, 'rgba(0,0,0,.35)');
        g.fillStyle = gr; g.fillRect(x, y, w, h);
        g.strokeStyle = 'rgba(0,0,0,.45)'; g.lineWidth = 1; g.strokeRect(x + .5, y + .5, w - 1, h - 1);
      }
      g.globalAlpha = 1;
    };
    const lay = (pid, x, y, w, h, total) => {
      const kids = M.byP.get(pid);
      if (!kids) return;
      squarify(kids, x, y, w, h, total, (it, rx, ry, rw, rh) => {
        const r = { it, x: rx, y: ry, w: rw, h: rh };
        M.rects.push(r); M.rectById.set(it.id, r);
        if (it.t === 2 && rw > 7 && rh > 7) {
          g.fillStyle = '#1d2133'; g.fillRect(rx, ry, rw, rh);
          g.strokeStyle = 'rgba(0,0,0,.7)'; g.lineWidth = 1; g.strokeRect(rx + .5, ry + .5, rw - 1, rh - 1);
          lay(it.id, rx + 2, ry + 2, rw - 4, rh - 4, it.a);
        } else leaf(it, rx, ry, rw, rh);
      });
    };
    lay(M.root, 0, 0, W, H, M.alloc);
    M.base = base;
    compose();
    // légende : types les plus présents
    const lg = $('#dk-legend', out);
    if (lg && DK.types) lg.innerHTML = DK.types.types.filter(t => t.name).slice(0, 12).map(t => `<span><i class="dk-sw" style="background:${dkColor(t.name)}"></i>${esc(dkTypeName(t.name))} ${fmtSize(t.alloc)}</span>`).join('') + '<span><i class="dk-sw" style="background:#5d6480"></i>dossiers trop petits pour être détaillés</span>';
  };
  const compose = () => {
    const M = DK.map, cv = $('#dk-canvas', out);
    if (!M?.base || !cv) return;
    const g = cv.getContext('2d'), dpr = devicePixelRatio || 1;
    g.setTransform(1, 0, 0, 1, 0, 0);
    g.drawImage(M.base, 0, 0);
    g.setTransform(dpr, 0, 0, dpr, 0, 0);
    if (M.hover) { const r = M.hover; g.strokeStyle = 'rgba(255,255,255,.75)'; g.lineWidth = 1; g.strokeRect(r.x + .5, r.y + .5, Math.max(1, r.w - 1), Math.max(1, r.h - 1)); }
    for (const id of DK.sel) {
      const r = M.rectById.get(id);
      if (!r) continue;
      g.strokeStyle = '#000'; g.lineWidth = 4; g.strokeRect(r.x + 1, r.y + 1, Math.max(1, r.w - 2), Math.max(1, r.h - 2));
      g.strokeStyle = '#fff'; g.lineWidth = 2; g.strokeRect(r.x + 1, r.y + 1, Math.max(1, r.w - 2), Math.max(1, r.h - 2));
    }
  };
  const hit = e => {
    const M = DK.map;
    if (!M) return null;
    const b = e.target.getBoundingClientRect(), x = e.clientX - b.left, y = e.clientY - b.top;
    for (let i = M.rects.length - 1; i >= 0; i--) { const r = M.rects[i]; if (x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h) return r; }
    return null;
  };
  const relPath = it => { const parts = []; for (let n = it; n; n = DK.map.byId.get(n.p)) parts.unshift(n.n); return parts.join('\\'); };
  const mapHover = e => {
    const r = hit(e), tip = $('#dk-tip', out), M = DK.map;
    if (r !== M.hover) { M.hover = r; compose(); }
    if (!r) { tip.hidden = true; return; }
    const it = r.it;
    tip.innerHTML = `<div class="ellipsis"><b>${esc(it.n)}</b></div><div>${fmtSize(it.a)} · ${it.t ? 'dossier' : esc(DK_LABEL[it.e] || dkTypeName(it.e))} · ${nf1.format(it.a / M.alloc * 100)} %</div><div class="muted ellipsis">${esc(relPath(it))}</div>`;
    tip.hidden = false;
    const box = $('#dk-mapbox', out).getBoundingClientRect();
    let x = e.clientX - box.left + 14, y = e.clientY - box.top + 14;
    if (x + tip.offsetWidth > box.width - 6) x = e.clientX - box.left - tip.offsetWidth - 14;
    if (y + tip.offsetHeight > box.height - 6) y = e.clientY - box.top - tip.offsetHeight - 14;
    tip.style.left = Math.max(4, x) + 'px'; tip.style.top = Math.max(4, y) + 'px';
  };
  const mapClick = e => {
    const r = hit(e);
    if (!r) return;
    select(r.it.id, e.ctrlKey || e.metaKey);
    expandTo(r.it.id);
  };
  const mapDbl = e => {
    const r = hit(e);
    if (!r) return;
    const target = r.it.t ? r.it.id : r.it.p;
    if (target !== DK.view) openView(target);
  };

  // ── clavier : Suppr, Retour arrière ──
  const key = e => {
    if (!live() || !$('#dk-list', out) || !$('#modal').hidden || e.target.closest?.('input, textarea, select')) return;
    if (e.key === 'Delete' && DK.sel.size) { e.preventDefault(); recycle(); }
    else if (e.key === 'Backspace') { e.preventDefault(); goUp(); }
  };
  addEventListener('keydown', key);
  router.cleanup.push(() => removeEventListener('keydown', key));

  // analyse précédente encore en mémoire : réaffichée telle quelle
  if (DK.scan && DK.view != null) {
    try { await openView(DK.view, true); } catch { DK.scan = null; out.innerHTML = ''; }
  }
};

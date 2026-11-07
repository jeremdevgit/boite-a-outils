/* SPDX-License-Identifier: GPL-3.0-or-later — Copyright (C) 2026 jeremdevgit — voir LICENSE */
'use strict';
/* Boîte à outils — écrans, ports USB et câbles, pilotes, diagnostic avancé,
   Sauvegarde propre, Essentiels. Utilise les outils d'app.js. */

// ── verre liquide : reflet au pointeur ; flou coupé sans accélération graphique ───────────────────
// une mise à jour par image au plus : une souris envoie jusqu'à 1000 positions par seconde
let glowEvent = null;
document.addEventListener('pointermove', e => {
  if (!glowEvent) requestAnimationFrame(() => {
    const ev = glowEvent; glowEvent = null;
    const g = ev.target.closest?.('.card.glass, .item.glass');
    if (!g) return;
    const r = g.getBoundingClientRect();
    g.style.setProperty('--mx', (ev.clientX - r.left) + 'px');
    g.style.setProperty('--my', (ev.clientY - r.top) + 'px');
  });
  glowEvent = e;
}, { passive: true });
// flou coupé si le PC affiche sans accélération graphique (machine virtuelle, pilote de base)
function softwareRendering() {
  try {
    const gl = document.createElement('canvas').getContext('webgl');
    if (!gl) return true;
    const i = gl.getExtension('WEBGL_debug_renderer_info');
    return /swiftshader|basic render|llvmpipe|software/i.test(i ? gl.getParameter(i.UNMASKED_RENDERER_WEBGL) : '');
  } catch { return false; }
}
document.body.classList.toggle('lite', softwareRendering());

const copyText = t => navigator.clipboard.writeText(t).then(() => toast('Copié'), () => toast('Copie impossible'));

// ── écrans ───────────────────────────────────────────────────────────────
views.displays = async (v, live) => {
  v.innerHTML = `<h1>Écrans</h1><p class="lead">Fréquence et résolution de chaque écran, réglées à la main. Tout essai s'annule seul après 15 secondes sans confirmation : un mode que l'écran ne supporte pas ne vous laisse jamais devant un écran noir.</p><div id="dsp"><div class="spinner big"></div></div>`;
  let data;
  const load = async () => {
    data = await bao.call('display.list');
    if (live()) render();
  };
  const uniq = a => [...new Set(a)];
  const map = () => {
    const ds = data.displays;
    const x0 = Math.min(...ds.map(d => d.x)), y0 = Math.min(...ds.map(d => d.y));
    const w = Math.max(...ds.map(d => d.x + d.width)) - x0, h = Math.max(...ds.map(d => d.y + d.height)) - y0;
    const s = Math.min(150 / h, 640 / w);
    return `<div class="mon-map">${ds.map(d => `<div style="left:${(d.x - x0) * s}px;top:${(d.y - y0) * s}px;width:${d.width * s - 3}px;height:${d.height * s - 3}px">${esc(d.name)}<br>${d.hz} Hz</div>`).join('')}</div>`;
  };
  const card = (d, i) => {
    const res = uniq(d.modes.map(m => `${m[0]}×${m[1]}`));
    const curRes = `${d.width}×${d.height}`;
    const hz = d.modes.filter(m => `${m[0]}×${m[1]}` === curRes).map(m => m[2]).sort((a, b) => b - a);
    const maxHz = Math.max(0, ...hz);
    return `<div class="card glass" data-i="${i}">
      <h3 class="row">${esc(d.name)} ${d.primary ? '<span class="badge info">Principal</span>' : ''}${d.connector ? `<span class="badge plain">${esc(d.connector)}</span>` : ''}${d.bits ? `<span class="badge plain">${d.bits} bits</span>` : ''}</h3>
      <div class="muted small">${esc(d.adapter)} · ${d.width} × ${d.height} à ${d.exactHz ? nf1.format(Math.round(d.exactHz * 100) / 100) : d.hz} Hz${d.exactHz ? ' (fréquence exacte)' : ''}</div>
      ${d.hz < maxHz ? `<div class="note warn" style="margin:10px 0 0">Cet écran tourne à ${d.hz} Hz alors que ${maxHz} Hz est disponible à cette résolution.</div>` : ''}
      <h3 style="margin-top:14px">Fréquence</h3>
      <div class="chips hz-chips">${hz.map(h => `<span class="chip${h === d.hz ? ' on' : ''}" data-hz="${h}">${h} Hz</span>`).join('')}</div>
      <div class="row" style="margin-top:12px"><span class="muted small">Résolution</span><select class="field" data-res>${res.map(r => `<option${r === curRes ? ' selected' : ''}>${r}</option>`).join('')}</select>
        <span class="muted small">Fréquence manuelle</span><input class="field" data-manual type="number" min="1" max="2000" placeholder="Hz" style="width:84px"><button class="btn small" data-try>Essayer</button></div>
      ${d.hdrSupported ? `<div class="row" style="margin-top:14px"><span class="grow">HDR</span><span class="switch${d.hdrOn ? ' on' : ''}" data-hdr></span></div>` : ''}
    </div>`;
  };
  const render = () => {
    $('#dsp', v).innerHTML = (data.displays.length > 1 ? map() : '') + data.displays.map(card).join('') +
      `<div class="note info">Un Hz absent de la liste peut être essayé en fréquence manuelle : le pilote est interrogé d'abord et refuse ce que l'écran n'annonce pas. Pour créer une fréquence que l'écran n'annonce pas (overclock d'écran), il faut un mode personnalisé : panneau NVIDIA ou AMD, ou <a data-link="https://www.monitortests.com/forum/Thread-Custom-Resolution-Utility-CRU" style="text-decoration:underline">Custom Resolution Utility</a>.</div>`;
  };
  const tryMode = async (d, w, h, hz) => {
    try { await bao.call('display.test', { device: d.device, width: w, height: h, hz }); }
    catch (e) { return modal('Mode refusé', `<p>${w} × ${h} à ${hz} Hz : ${esc(e.message)}.</p><p class="muted small">Aucun changement n'a été fait.</p>`); }
    if (!await confirmAction(`Essayer ${hz} Hz ?`, `<p>${esc(d.name)} passera en ${w} × ${h} à ${hz} Hz. L'écran peut clignoter. Sans confirmation de votre part dans les ${data.revertSecs} secondes, le réglage actuel revient tout seul.</p>`, 'Essayer')) return;
    let r;
    try { r = await bao.call('display.set', { device: d.device, width: w, height: h, hz }); }
    catch (e) { return toast('Échec : ' + e.message); }
    let left = r.seconds;
    const p = modal('Garder ce réglage ?', `<p>${w} × ${h} à ${hz} Hz. Retour au réglage précédent dans <b id="rv">${left}</b> s.</p>`, [['back', 'Revenir', ''], ['keep', 'Garder', 'primary']]);
    const id = setInterval(() => { left--; const e = $('#rv'); if (e) e.textContent = Math.max(0, left); if (left <= 0) { clearInterval(id); $('#modal [data-v="back"]')?.click(); } }, 1000);
    const c = await p;
    clearInterval(id);
    try {
      if (c === 'keep') { await bao.call('display.confirm', { id: r.pending, title: `${d.name} : ${w} × ${h} à ${hz} Hz` }); toast('Réglage conservé'); }
      else { await bao.call('display.revert', { id: r.pending }); toast('Réglage précédent rétabli'); }
    } catch (e) { toast(e.message); }
    setTimeout(() => live() && load(), 800);
  };
  v.addEventListener('click', async e => {
    const link = e.target.closest('[data-link]');
    if (link) return void bao.call('open', { target: link.dataset.link });
    const c = e.target.closest('[data-i]'); if (!c) return;
    const d = data.displays[+c.dataset.i];
    const [w, h] = $('[data-res]', c).value.split('×').map(Number);
    const chip = e.target.closest('[data-hz]');
    if (chip) { if (+chip.dataset.hz !== d.hz || w !== d.width) tryMode(d, w, h, +chip.dataset.hz); return; }
    if (e.target.closest('[data-try]')) {
      const hz = +$('[data-manual]', c).value;
      if (!hz) return toast('Entrez une fréquence en Hz');
      tryMode(d, w, h, hz); return;
    }
    const sw = e.target.closest('[data-hdr]');
    if (sw) {
      try { await bao.call('display.hdr', { device: d.device, on: !d.hdrOn }); await load(); toast('HDR ' + (d.hdrOn ? 'activé' : 'désactivé')); }
      catch (err) { toast('Échec : ' + err.message); }
    }
  });
  v.addEventListener('change', e => {
    const s = e.target.closest('[data-res]'); if (!s) return;
    const c = s.closest('[data-i]'), d = data.displays[+c.dataset.i];
    const hz = d.modes.filter(m => `${m[0]}×${m[1]}` === s.value).map(m => m[2]).sort((a, b) => b - a);
    $('.hz-chips', c).innerHTML = hz.map(h => `<span class="chip" data-hz="${h}">${h} Hz</span>`).join('');
  });
  await load();
};

// ── ports USB et câbles ──────────────────────────────────────────────────
const placeText = p => { if (!p || p.panel === 'Inconnu') return ''; return ['Panneau ' + p.panel.toLowerCase(), p.vertical, p.horizontal].filter(Boolean).join(', '); };
views.usb = async (v, live) => {
  v.innerHTML = `<h1>Ports USB et câbles</h1><p class="lead">Chaque port du PC : sa vitesse, ce qui y est branché, sa fonction et le courant demandé. Branchez ou débranchez un appareil : le port concerné s'illumine, et vous pouvez le nommer (« façade gauche »…).</p>
    <div class="note info"><b>Ce que Windows permet de savoir.</b> Un PC n'a pas de capteur de courant par port : le courant affiché est celui que l'appareil <b>déclare</b>, comparé à la limite du port. La puce e-marker des câbles USB-C n'étant pas lisible depuis Windows, le verdict sur le câble est <b>déduit</b> de la vitesse réellement négociée : watts du câble, longueur et câble de charge seul restent invisibles.</div>
    <div class="toolbar"><div class="chips"><span class="chip on" data-f="all">Tous les ports</span><span class="chip" data-f="used">Utilisés</span><span class="chip" data-f="problem">Problèmes</span></div><label class="row small muted"><input type="checkbox" id="internal"> Ports internes</label><span class="grow"></span><span class="muted small" id="usb-sum"></span></div>
    <div id="usb"><div class="spinner big"></div></div>`;
  let filter = 'all', showInt = false, prev = null, editing = false, tree = null;
  // un connecteur USB 3 = deux ports logiques compagnons : on n'en montre qu'un (celui qui est utilisé)
  const connectors = hub => {
    const ports = hub?.ports || [];
    const twin = p => p.companion ? ports.find(o => o.port === p.companion && o.companion === p.port) : null;
    return ports.filter(p => {
      const t = twin(p);
      if (!t) return true;
      if (p.device && !t.device) return true;
      if (t.device && !p.device) return false;
      return p.usb3 && !t.usb3 ? true : t.usb3 && !p.usb3 ? false : p.port < t.port;
    });
  };
  const flat = (hub, out = []) => { for (const p of connectors(hub)) { out.push(p); if (p.hub) flat(p.hub, out); } return out; };
  const sig = p => p.device ? p.device.vid + p.device.pid + p.device.speedCode : '';
  const plug = p => {
    const code = p.device?.speedCode;
    const cls = ['usb-plug', p.typeC ? 'c' : '', !p.device ? 'free' : '', code === 4 ? 'ssp' : code === 3 ? 'ss' : ''].filter(Boolean).join(' ');
    return `<div class="${cls}">${p.typeC ? 'USB-C' : p.usb3 ? 'USB 3' : 'USB 2'}</div>`;
  };
  const power = d => {
    if (d.selfPowered && !d.power) return '<div class="small muted">Alimentation propre</div>';
    const pct = d.budget ? d.power / d.budget * 100 : 0;
    return `<div class="small" style="text-align:right"><b>${d.power} mA</b> déclarés / ${d.budget} mA<br><span class="muted">${nf1.format(d.power * 5 / 1000)} W max à 5 V${d.selfPowered ? ' · alimentation propre' : ''}</span></div><div class="bar power-bar${pct > 90 ? ' hot' : ''}"><i style="width:${Math.min(100, pct)}%"></i></div>`;
  };
  const portRow = p => {
    const d = p.device;
    const lvl = { ok: 'ok', warn: 'warn', bad: 'bad', info: 'info' }[d?.cable?.level] || 'plain';
    const place = placeText(d?.place);
    return `<div class="usb-port glass" data-port="${esc(p.id)}">${plug(p)}<div>
      <div class="title row">${d ? esc(d.name) : '<span class="muted">Libre</span>'}${d?.isHub ? '<span class="badge plain">Concentrateur</span>' : ''}<input class="label-edit" data-label="${esc(p.id)}" value="${esc(p.label)}" placeholder="Port ${p.port} : nommer…"></div>
      <div class="sub">${[p.usb3 ? 'USB 3' : 'USB 2', p.typeC ? 'connecteur USB-C' : '', p.userConnectable ? '' : 'interne', `port ${p.port}${p.companion ? ' et ' + p.companion : ''}`, place].filter(Boolean).map(esc).join(' · ')}</div>
      ${p.problem ? `<div class="note ${p.status === 'bad' ? 'bad' : 'warn'}" style="margin:8px 0 0">${esc(p.problem)}</div>` : ''}
      ${d ? `<div class="what">${esc(d.speed)}${d.functions.length ? ' · ' + d.functions.map(esc).join(', ') : ''}</div>
        <div class="sub">USB ${esc(d.usb)} · ${esc(d.maker || '')} VID ${d.vid} PID ${d.pid}</div>
        <div style="margin-top:6px"><span class="badge ${lvl}">${esc(d.cable.title)}</span></div><div class="sub">${esc(d.cable.why)}</div>` : ''}
    </div><div class="side">${d ? power(d) : ''}</div></div>${p.hub ? `<div class="usb-sub">${portsOf(p.hub)}</div>` : ''}`;
  };
  const keep = p => {
    if (!showInt && !p.userConnectable && !p.device) return false;
    if (filter === 'used') return !!p.device;
    if (filter === 'problem') return !!p.problem || ['bad', 'warn'].includes(p.device?.cable?.level);
    return true;
  };
  const portsOf = hub => connectors(hub).filter(p => keep(p) || flat(p.hub).some(keep)).map(portRow).join('');
  const render = () => {
    const all = tree.controllers.flatMap(c => flat(c.hub));
    const used = all.filter(p => p.device);
    const mA = used.filter(p => !p.device.isHub).reduce((s, p) => s + p.device.power, 0);
    $('#usb-sum', v).textContent = `${used.length} appareils sur ${all.length} ports · ${nf1.format(mA * 5 / 1000)} W déclarés au total`;
    const html = tree.controllers.map(c => {
      if (c.error) return `<div class="note warn">${esc(c.name)} : ${esc(c.error)}</div>`;
      const ports = c.hub ? portsOf(c.hub) : '';
      return ports ? `<h2>${esc(c.name)}</h2><div class="list">${ports}</div>` : '';
    }).join('');
    $('#usb', v).innerHTML = html || '<div class="empty">Aucun port à afficher avec ce filtre</div>';
  };
  const refresh = async () => {
    if (!live() || editing || document.hidden) return;
    let t;
    try { t = await bao.call('usb.tree'); } catch (e) { if (!tree) $('#usb', v).innerHTML = `<div class="note warn">${esc(e.message)}</div>`; return; }
    if (!live() || editing) return;
    const now = new Map(t.controllers.flatMap(c => flat(c.hub)).map(p => [p.id, sig(p)]));
    const changed = prev ? [...now].filter(([k, s]) => prev.get(k) !== s).map(x => x[0]) : [];
    const same = prev && !changed.length && prev.size === now.size;
    prev = now; tree = t;
    if (same) return;
    render();
    for (const id of changed) {
      const el = $$('[data-port]', v).find(x => x.dataset.port === id);
      if (el) { el.classList.add('flash'); el.scrollIntoView({ block: 'center' }); toast(now.get(id) ? 'Appareil branché : ce port s\'illumine' : 'Appareil débranché : ce port s\'illumine'); }
    }
  };
  v.addEventListener('click', e => {
    const c = e.target.closest('[data-f]');
    if (c) { filter = c.dataset.f; $$('[data-f]', v).forEach(x => x.classList.toggle('on', x === c)); render(); }
  });
  $('#internal', v).onchange = e => { showInt = e.target.checked; render(); };
  v.addEventListener('focusin', e => { if (e.target.matches('.label-edit')) editing = true; });
  v.addEventListener('focusout', async e => {
    const i = e.target.closest('.label-edit'); if (!i) return;
    editing = false;
    await bao.call('usb.label', { id: i.dataset.label, label: i.value }).catch(err => toast(err.message));
    const p = tree?.controllers.flatMap(c => flat(c.hub)).find(x => x.id === i.dataset.label);
    if (p) p.label = i.value;
  });
  await refresh();
  const id = setInterval(refresh, 2000);
  router.cleanup.push(() => clearInterval(id));
};

// ── pilotes ──────────────────────────────────────────────────────────────
const VENDOR_PAGE = [
  [/nvidia/i, 'https://www.nvidia.com/fr-fr/drivers/'],
  [/amd|radeon|advanced micro/i, 'https://www.amd.com/fr/support/download/drivers.html'],
  [/intel/i, 'https://www.intel.fr/content/www/fr/fr/support/detect.html'],
  [/realtek/i, 'https://www.realtek.com/Download/Overview'],
];
// page de support du fabricant de la carte mère (le modèle sans la référence interne entre parenthèses)
const boardSupport = b => {
  const m = encodeURIComponent(String(b.model).replace(/\s*\(.*?\)\s*/g, ' ').trim());
  if (/micro-star|msi/i.test(b.maker)) return `https://www.msi.com/search/${m}`;
  if (/asus/i.test(b.maker)) return `https://www.asus.com/fr/searchresult?searchType=support&searchKey=${m}`;
  if (/gigabyte/i.test(b.maker)) return `https://www.gigabyte.com/fr/Search?kw=${m}`;
  if (/asrock/i.test(b.maker)) return `https://www.asrock.com/support/index.fr.asp?cat=Drivers`;
  return `https://www.google.com/search?q=${encodeURIComponent(`${b.maker} ${b.model} pilotes support`)}`;
};
// l'identifiant complet (SUBSYS, REV) ne donne aucun résultat dans le catalogue
const shortHwid = h => String(h).replace(/&REV_[0-9A-F]+$/i, '').replace(/^(PCI\\VEN_\w+&DEV_\w+).*$/i, '$1').replace(/^(USB\\VID_\w+&PID_\w+).*$/i, '$1');
const catalogUrl = hwid => `https://www.catalog.update.microsoft.com/Search.aspx?q=${encodeURIComponent(shortHwid(hwid))}`;
views.drivers = async (v, live) => {
  v.innerHTML = `<h1>Pilotes</h1><p class="lead">Les pilotes installés, leur âge, et ceux que Windows Update propose. Rien ne s'installe sans votre accord.</p>${adminNote()}
    <div class="card glass"><div class="row"><div class="grow"><h3>Pilotes disponibles</h3><div class="muted small" id="wu-state">Interroge Windows Update (une à deux minutes).</div></div><button class="btn primary" id="wu-search">Rechercher</button></div><div id="wu" style="margin-top:10px"></div></div>
    <div id="vendors"></div>
    <h2>Installés</h2><div class="toolbar"><input class="field grow" id="q" placeholder="Filtrer…" style="max-width:300px"><select class="field" id="cls"></select><label class="row small muted"><input type="checkbox" id="ms"> Inclure les pilotes Microsoft génériques</label><span class="muted small" id="cnt"></span></div>
    <div id="drv"><div class="spinner big"></div></div>`;
  const r = await ps('drivers');
  if (!live()) return;
  const items = r.items || [];
  const years = d => d ? (Date.now() - new Date(d)) / (365.25 * 864e5) : 0;
  const hasProblem = [...items.filter(d => d.error), ...(r.missing || [])];
  const gpu = items.find(d => d.class === 'DISPLAY' && !/microsoft|virtual|parsec/i.test(d.provider));
  const gpuPage = gpu && VENDOR_PAGE.find(([re]) => re.test(gpu.provider + gpu.name));
  const targets = [...items, ...(r.missing || [])];
  $('#vendors', v).innerHTML = `${hasProblem.length ? `<div class="note bad"><b>${plural(hasProblem.length, 'périphérique en erreur', 'périphériques en erreur')}</b> <button class="btn small" data-open="devmgmt.msc">Gestionnaire de périphériques</button><div class="list" style="margin-top:8px">${hasProblem.slice(0, 8).map(d => `<div class="row"><span class="grow">${esc(d.name || d.device)} <span class="muted small">(code ${d.error})</span></span>${d.hwid ? `<button class="btn small" data-cat="${targets.indexOf(d)}">Chercher un pilote</button>` : ''}</div>`).join('')}</div></div>` : ''}
    <div class="card glass"><h3>Sites des fabricants</h3><div class="muted small" style="margin-bottom:10px">Souvent plus récents que Windows Update, surtout pour la carte graphique.</div><div class="row">${gpuPage ? `<button class="btn small" data-url="${esc(gpuPage[1])}">Carte graphique : ${esc(gpu.name)}</button>` : ''}<button class="btn small" data-url="${esc(boardSupport(r.board))}">Carte mère : ${esc(r.board.maker)} ${esc(r.board.model)}</button></div></div>`;
  const classes = [...new Set(items.map(d => d.class).filter(Boolean))].sort();
  $('#cls', v).innerHTML = `<option value="">Toutes les catégories</option>` + classes.map(c => `<option>${esc(c)}</option>`).join('');
  let ms = false, q = '', cls = '';
  const render = () => {
    const low = q.toLowerCase();
    const list = items.filter(d => (ms || !/^microsoft/i.test(d.provider)) && (!cls || d.class === cls) && (!low || (d.name + d.provider + d.version + d.inf).toLowerCase().includes(low))).sort((a, b) => (b.error - a.error) || new Date(a.date) - new Date(b.date));
    $('#cnt', v).textContent = plural(list.length, 'pilote', 'pilotes');
    $('#drv', v).innerHTML = `<div class="scroll-x"><table class="table"><thead><tr><th>Périphérique</th><th>Fournisseur</th><th>Version</th><th>Date</th><th></th></tr></thead><tbody>${list.map(d => `<tr><td>${esc(d.name)}${d.error ? ` <span class="badge bad">Erreur ${d.error}</span>` : ''}<div class="muted small mono">${esc(d.inf)}</div></td><td>${esc(d.provider)}</td><td class="mono">${esc(d.version)}</td><td class="nowrap">${fmtDate(d.date)}${years(d.date) > 4 ? ' <span class="badge warn">Ancien</span>' : ''}</td><td class="r nowrap">${d.hwid ? `<button class="btn small" data-cat="${targets.indexOf(d)}" title="Chercher et installer une autre version depuis le catalogue Microsoft Update">Mettre à jour</button>` : ''}</td></tr>`).join('')}</tbody></table></div>`;
  };
  render();
  $('#q', v).oninput = e => { q = e.target.value; render(); };
  $('#cls', v).onchange = e => { cls = e.target.value; render(); };
  $('#ms', v).onchange = e => { ms = e.target.checked; render(); };
  let found = [];
  const showFound = () => {
    const byHw = new Map(items.map(d => [String(d.hwid).toLowerCase(), d]));
    $('#wu', v).innerHTML = found.length ? `<div class="list">${found.map(u => {
      const cur = byHw.get(u.hwid.toLowerCase());
      const older = cur && u.date && cur.date && new Date(u.date) < new Date(cur.date);
      return `<label class="pick"><input type="checkbox" data-wu="${esc(u.id)}"${older ? '' : ' checked'}><div><div>${esc(u.title)}</div><div class="muted small">${esc(u.class)} · ${esc(u.maker)} · ${fmtDate(u.date)}${cur ? ` · installé : ${esc(cur.version)} du ${fmtDate(cur.date)}` : ''}</div></div><div class="nowrap">${older ? '<span class="badge warn">Plus ancien que l\'installé</span> ' : ''}<span class="size">${fmtSize(u.size)}</span></div></label>`;
    }).join('')}</div><div class="row end" style="margin-top:10px">${checkAll('input[data-wu]', '#wu')}<button class="btn primary" id="wu-install">Installer la sélection</button></div>` : '<div class="note ok" style="margin:0">Windows Update ne propose aucun pilote pour ce PC. Les sites des fabricants peuvent en avoir de plus récents.</div>';
  };
  // catalogue Microsoft Update : recherche et installation sans quitter l'application
  const catalogFor = async (d, btn) => {
    const label = btn.textContent;
    btn.disabled = true; btn.textContent = 'Recherche…';
    let res;
    try { res = await ps('drvcat', { action: 'search', hwids: [].concat(d.hwids || d.hwid) }); }
    catch (err) { btn.disabled = false; btn.textContent = label; return toast(`Catalogue injoignable : ${err.message}`); }
    btn.disabled = false; btn.textContent = label;
    if (!live()) return;
    const found = [].concat(res.items || []);
    const list = found.length ? `<p class="muted small">Pilotes publiés par Microsoft pour <span class="mono">${esc(res.query)}</span>${d.version ? `. Installé : <b>${esc(d.version)}</b> du ${fmtDate(d.date)}` : ''}.</p><div class="list">${found.map(u => {
      const same = d.version && u.version === d.version;
      const older = !same && d.date && u.date && new Date(u.date) < new Date(d.date);
      return `<div class="row"><div class="grow"><div>${esc(u.title)}</div><div class="muted small">${esc(u.class)} · ${fmtDate(u.date)} · ${fmtSize(u.size)}${u.fits ? '' : ' · <span class="badge warn">Autre version de Windows</span>'}</div></div>${same ? '<span class="badge ok">Installé</span>' : `${older ? '<span class="badge warn">Plus ancien</span> ' : ''}<button class="btn small${older || !u.fits ? '' : ' primary'}" data-v="${esc(u.id)}">Installer</button>`}</div>`;
    }).join('')}</div>` : `<p>Le catalogue Microsoft ne contient aucun pilote pour ce périphérique.</p><p class="muted small">Le pilote vient alors du fabricant : site de la carte mère ou du périphérique.</p>`;
    const pick = await modal(d.name || 'Périphérique', list, [['', 'Fermer', '']]);
    const u = pick && found.find(x => x.id === pick);
    if (!u) return;
    if (!state.elevated) return toast('Droits administrateur nécessaires');
    if (!await safety()) return;
    if (!await confirmAction('Installer ce pilote ?', `<p>${esc(u.title)}</p><p class="muted small">Téléchargé depuis Microsoft, signature vérifiée, puis installé avec pnputil. L'écran peut clignoter.</p>`, 'Installer')) return;
    btn.disabled = true; btn.textContent = 'Installation…';
    try {
      const r2 = await ps('drvcat', { action: 'install', id: u.id }, 'Installation de pilote');
      const msg = r2.code === 259 ? 'Pilote ajouté à Windows, mais le périphérique garde son pilote actuel (jugé plus adapté par Windows).'
        : r2.ok ? `Pilote installé.${r2.reboot ? ' <b>Redémarrez le PC pour terminer.</b>' : ''}` : `Échec de l'installation (code ${r2.code}).`;
      await modal('Installation', `<p>${msg}</p><details><summary class="muted small">Détails</summary><pre class="mono small" style="white-space:pre-wrap">${esc(r2.log || '')}</pre></details>`);
    } catch (err) { toast(err.message); }
    btn.disabled = false; btn.textContent = label;
  };
  v.addEventListener('click', async e => {
    const url = e.target.closest('[data-url]');
    if (url) return void bao.call('open', { target: url.dataset.url });
    const op = e.target.closest('[data-open]');
    if (op) return void bao.call('open', { target: op.dataset.open });
    const cat = e.target.closest('[data-cat]');
    if (cat) return void catalogFor(targets[+cat.dataset.cat], cat);
    const s = e.target.closest('#wu-search');
    if (s) {
      s.disabled = true;
      $('#wu', v).innerHTML = '<div class="progress"><div class="spinner"></div><div>Recherche auprès de Windows Update…</div></div>';
      try { found = (await ps('drivers', { action: 'search' })).items || []; if (!live()) return; $('#wu-state', v).textContent = plural(found.length, 'pilote proposé', 'pilotes proposés'); showFound(); }
      catch (err) { $('#wu', v).innerHTML = `<div class="note warn" style="margin:0">${esc(err.message)}</div>`; }
      s.disabled = false; return;
    }
    if (e.target.closest('#wu-install')) {
      const ids = $$('[data-wu]:checked', v).map(c => c.dataset.wu);
      if (!ids.length) return toast('Rien de sélectionné');
      if (!state.elevated) return toast('Droits administrateur nécessaires');
      if (!await safety()) return;
      if (!await confirmAction('Installer ces pilotes ?', `<p>${plural(ids.length, 'pilote', 'pilotes')} : l'écran peut clignoter et un redémarrage peut être demandé.</p>`, 'Installer')) return;
      $('#wu', v).innerHTML = '<div class="progress"><div class="spinner"></div><div>Téléchargement et installation…</div></div>';
      try {
        const res = await ps('drivers', { action: 'install', ids }, 'Installation de pilotes');
        const failed = [].concat(res.items || []).filter(x => x.code !== 2);
        $('#wu', v).innerHTML = `<div class="note ${res.ok ? 'ok' : 'warn'}" style="margin:0">${res.ok ? 'Pilotes installés.' : `${failed.length} pilote(s) non installé(s) : ${failed.map(x => esc(x.title)).join(', ')}.`}${res.reboot ? ' <b>Redémarrez le PC pour terminer.</b>' : ''}</div>`;
      } catch (err) { $('#wu', v).innerHTML = `<div class="note warn" style="margin:0">${esc(err.message)}</div>`; }
    }
  });
};

// ── diagnostic avancé ────────────────────────────────────────────────────
views.hwplus = async (v, live) => {
  v.innerHTML = `<h1>Diagnostic avancé</h1><p class="lead">Ce qu'une fiche technique ne dit pas : la vitesse réelle des liens PCIe, l'usure des disques, le réseau, l'audio et la batterie.</p><div id="hp"><div class="progress glass"><div class="spinner"></div><div>Lecture du matériel…</div></div></div>`;
  const r = await ps('hwplus');
  if (!live()) return;
  const pcie = [].concat(r.pcie || []).sort((a, b) => (b.maxSpeed * b.maxWidth) - (a.maxSpeed * a.maxWidth));
  const rows = pcie.map(p => {
    const speedLow = p.speed < p.maxSpeed, widthLow = p.width < p.maxWidth;
    return `<tr><td>${esc(p.name)}</td><td class="nowrap">Gen ${p.gen} x${p.width}</td><td class="nowrap muted">Gen ${p.maxGen} x${p.maxWidth}</td><td>${widthLow ? '<span class="badge warn">Moins de lignes</span>' : speedLow ? '<span class="badge plain">Vitesse réduite</span>' : '<span class="badge ok">Maximum</span>'}</td></tr>`;
  }).join('');
  const smart = [].concat(r.smart || []).map(d => `<div class="card glass"><h3 class="row">${esc(d.name)} <span class="badge ${d.health === 'Healthy' ? 'ok' : 'bad'}">${d.health === 'Healthy' ? 'En bonne santé' : esc(d.health)}</span></h3><div class="muted small">${esc(d.media)} · ${esc(d.bus)} · ${fmtSize(d.size)}</div><div class="stress-grid">${[['Température', d.temp ? d.temp + ' °C' : '—', d.tempMax ? 'max ' + d.tempMax + ' °C' : ''], ['Usure', d.media === 'SSD' ? d.wear + ' %' : '—', ''], ['Heures de marche', d.hours ? nf0.format(d.hours) + ' h' : '—', ''], ['Erreurs lecture / écriture', `${d.readErr || 0} / ${d.writeErr || 0}`, '']].map(([a, b, c]) => `<div class="stat"><div class="muted small">${a}</div><div class="big">${b}</div><div class="muted small">${c}</div></div>`).join('')}</div></div>`).join('');
  const net = [].concat(r.net || []).map(n => `<tr><td>${esc(n.name)}<div class="muted small">${esc(n.desc)}</div></td><td>${n.status === 'Up' ? `<span class="badge ok">${esc(n.speed)}</span>` : '<span class="badge plain">Déconnecté</span>'}</td><td class="mono">${esc(n.ip)}</td><td class="mono">${esc(n.mac)}</td><td class="mono">${esc(n.driver)}</td></tr>`).join('');
  const b = r.battery;
  const bat = b ? `<h2>Batterie</h2><div class="card glass"><div class="stress-grid">${[['Charge', b.percent + ' %'], ['Santé', b.design ? nf0.format(b.full / b.design * 100) + ' %' : '—'], ['Puissance entrante', b.chargeMw ? nf1.format(b.chargeMw / 1000) + ' W' : '—'], ['Puissance consommée', b.dischargeMw ? nf1.format(b.dischargeMw / 1000) + ' W' : '—'], ['Tension', b.voltage ? nf1.format(b.voltage / 1000) + ' V' : '—']].map(([x, y]) => `<div class="stat"><div class="muted small">${x}</div><div class="big">${y}</div></div>`).join('')}</div><div class="muted small">La puissance entrante mesure vraiment ce que le chargeur et son câble apportent à la batterie.</div></div>` : '';
  $('#hp', v).innerHTML = `<h2>Liens PCIe</h2><div class="muted small" style="margin-bottom:8px">« Moins de lignes » sur une carte graphique ou un SSD : mauvais emplacement ou carte mal enfoncée. « Vitesse réduite » : soit le lien est au repos et accélère à la demande, soit la carte mère ou le processeur plafonne à cette génération (mesurez sous charge pour trancher).</div><div class="card glass scroll-x"><table class="table"><thead><tr><th>Périphérique</th><th>Actuel</th><th>Maximum</th><th></th></tr></thead><tbody>${rows || '<tr><td colspan="4" class="muted">Non disponible</td></tr>'}</tbody></table></div>
    <h2>Santé des disques</h2>${state.elevated ? '' : '<div class="note warn">Température, usure et heures de marche ne sont lisibles qu\'en administrateur : les valeurs ci-dessous sont incomplètes.</div>'}${smart || '<div class="empty">Aucune donnée</div>'}
    <h2>Réseau</h2><div class="card glass scroll-x"><table class="table"><thead><tr><th>Carte</th><th>Lien</th><th>IPv4</th><th>MAC</th><th>Pilote</th></tr></thead><tbody>${net}</tbody></table></div>
    <h2>Audio</h2><div class="card glass">${[].concat(r.audio || []).map(a => `<div class="row"><span class="grow">${esc(a.name)}</span><span class="muted small">${esc(a.maker)}</span></div>`).join('') || 'Aucun périphérique'}</div>${bat}`;
};

// ── Sauvegarde propre ────────────────────────────────────────────────────
const LAUNCHERS = /^(Steam|Epic Games Launcher|GOG Galaxy|Ubisoft Connect|EA app|Battle\.net|Riot Client|Rockstar Games Launcher|Amazon Games)$/i;
const SYSTEM_NAME = /^(Microsoft (Visual C\+\+|\.NET|Edge WebView|Update Health|Windows Desktop Runtime|ASP\.NET)|Windows (Software|SDK|Driver)|Extensions? |.*Extension$|Bonjour$|NVIDIA (PhysX|FrameView|USBC|HD Audio|Graphics Driver)|AMD (Chipset|Ryzen Master SDK)|Realtek |Intel\(R\))/i;
async function inventory(onStep) {
  onStep('Inventaire des logiciels (winget)…');
  const [wg, reg, games] = await Promise.all([
    bao.call('winget.list').catch(e => ({ error: e.message, items: [] })),
    ps('programs').catch(() => ({ items: [] })),
    ps('games').catch(() => ({ items: [] })),
  ]);
  const norm = s => String(s).toLowerCase().replace(/[^a-z0-9]/g, '');
  const urls = new Map([].concat(reg.items || []).map(p => [norm(p.name), p.url]));
  const gamesList = [].concat(games.items || []);
  const gameNames = new Set(gamesList.map(g => norm(g.name)));
  const steamIds = /Steam App (\d+)/i;
  const programs = [];
  const seen = new Set();
  const sourceItems = wg.items.length ? wg.items : [].concat(reg.items || []).map(p => ({ name: p.name, id: '', version: p.version, source: '' }));
  for (const p of sourceItems) {
    const k = norm(p.name);
    if (seen.has(k) || !k) continue;
    seen.add(k);
    if (steamIds.test(p.id)) { if (!gameNames.has(k)) { gamesList.push({ name: p.name, platform: 'Steam', path: '' }); gameNames.add(k); } continue; }
    if (gameNames.has(k)) continue;
    if (String(p.id).startsWith('MSIX\\')) continue; // applications et composants de Windows
    const kind = p.source === 'winget' ? 'winget' : p.source === 'msstore' ? 'store' : 'manual';
    programs.push({ name: p.name, id: p.id, version: p.version, available: p.available, source: p.source, kind, url: urls.get(k) || '', system: SYSTEM_NAME.test(p.name) });
  }
  programs.sort((a, b) => a.name.localeCompare(b.name, 'fr'));
  return { programs, games: gamesList.sort((a, b) => a.platform.localeCompare(b.platform) || a.name.localeCompare(b.name)), wingetError: wg.error };
}
views.backup = async (v, live) => {
  const st = { step: 0, inv: null, scan: null, sizes: {}, picked: new Set(), custom: [], dest: '', dl: new Set(), captures: true, minimize: true, skipCaches: true, drivers: true, wifi: false, showSys: false };
  const STEPS = ['1. Logiciels et jeux', '2. Données', '3. Destination', '4. Sauvegarde'];
  v.innerHTML = `<h1>Sauvegarde propre</h1><p class="lead">Tout préparer avant de réinstaller Windows : la liste de vos logiciels avec leurs derniers installateurs, vos jeux par plateforme, des captures de votre bureau et vos données. Rien n'est modifié ni supprimé sur le PC.</p><div class="steps" id="st"></div><div id="bk"></div>`;
  const body = () => $('#bk', v);
  const steps = () => { $('#st', v).innerHTML = STEPS.map((s, i) => `<span class="step${i === st.step ? ' on' : i < st.step ? ' done' : ''}">${s}</span>`).join(''); };
  const go = n => { st.step = n; steps(); [renderSoft, renderData, renderDest][n]?.(); $('#main').scrollTop = 0; };

  function renderSoft() {
    const { programs, games, wingetError } = st.inv;
    const vis = programs.filter(p => st.showSys || !p.system);
    const auto = vis.filter(p => p.kind !== 'manual'), manual = vis.filter(p => p.kind === 'manual');
    const plats = [...new Set(games.map(g => g.platform))];
    body().innerHTML = `${wingetError ? `<div class="note warn">${esc(wingetError)}. Sans winget, tous les logiciels passent par un lien vers leur site.</div>` : ''}
      <div class="stress-grid"><div class="stat"><div class="big">${auto.length}</div><div class="muted small">réinstallables en un clic</div></div><div class="stat"><div class="big">${manual.length}</div><div class="muted small">à réinstaller depuis leur site</div></div><div class="stat"><div class="big">${games.length}</div><div class="muted small">jeux répertoriés</div></div></div>
      <div class="note info"><b>Un seul installateur pour tout :</b> la sauvegarde contiendra <b>Tout-reinstaller.cmd</b>, qui réinstalle d'un double-clic la dernière version de chaque logiciel reconnu, et <b>Ouvrir-les-sites.cmd</b>, qui ouvre la page des autres.</div>
      <div class="row" style="margin:6px 0 12px"><label class="row small muted"><input type="checkbox" id="sys"${st.showSys ? ' checked' : ''}> Afficher les composants système</label><span class="grow"></span><button class="btn" id="next">Continuer</button></div>
      <h2>Réinstallables automatiquement</h2><p class="muted small">Cochez ceux dont vous voulez aussi le fichier d'installation dans la sauvegarde (utile sans connexion). Les applications du Microsoft Store ne se téléchargent pas ainsi.</p>
      <div class="row" style="margin-bottom:8px"><button class="btn small" id="all">Tout sélectionner</button><button class="btn small" id="none">Tout désélectionner</button></div>
      <div class="card glass scroll-x"><table class="table"><tbody>${auto.map(p => `<tr><td style="width:28px">${p.kind === 'winget' ? `<input type="checkbox" data-dl="${esc(p.id)}"${st.dl.has(p.id) ? ' checked' : ''}>` : ''}</td><td>${esc(p.name)}</td><td class="muted mono">${esc(p.version)}</td><td>${p.available ? `<span class="badge info">Version ${esc(p.available)} disponible</span>` : ''}</td><td class="muted small">${p.kind === 'store' ? 'Microsoft Store' : esc(p.id)}</td></tr>`).join('')}</tbody></table></div>
      <h2>À réinstaller depuis leur site</h2><div class="card glass scroll-x"><table class="table"><tbody>${manual.map(p => `<tr><td>${esc(p.name)}</td><td class="muted mono">${esc(p.version)}</td><td class="r"><button class="btn small" data-site="${esc(p.url && /^https?:/.test(p.url) ? p.url : `https://duckduckgo.com/?q=${encodeURIComponent(p.name + ' télécharger site officiel')}`)}">${p.url && /^https?:/.test(p.url) ? 'Site de l\'éditeur' : 'Rechercher'}</button></td></tr>`).join('')}</tbody></table></div>
      <h2>Jeux</h2><p class="muted small">Ils ne sont pas copiés : à retélécharger depuis leur plateforme. Leurs sauvegardes et réglages sont proposés à l'étape suivante.</p>
      ${plats.map(pl => `<div class="card glass platform-group"><h3>${esc(pl)} <span class="muted">(${games.filter(g => g.platform === pl).length})</span></h3><div class="small muted">${games.filter(g => g.platform === pl).map(g => esc(g.name)).join(' · ')}</div></div>`).join('') || '<div class="empty">Aucun jeu détecté</div>'}`;
  }

  async function renderData() {
    body().innerHTML = '<div class="progress glass"><div class="spinner"></div><div>Recherche de vos données…</div></div>';
    if (!st.scan) {
      st.scan = await ps('backup_scan');
      if (!live()) return;
      for (const i of [].concat(st.scan.items)) if (i.def) st.picked.add(i.path);
      bao.call('files.sizes', { paths: [].concat(st.scan.items).map(i => i.path) }).then(sz => {
        [].concat(st.scan.items).forEach((i, k) => (st.sizes[i.path] = sz[k]));
        if (live() && st.step === 1) drawData();
      }).catch(() => { });
    }
    if (live()) drawData();
  }
  function drawData() {
    const items = [...[].concat(st.scan.items), ...st.custom];
    const groups = [...new Set(items.map(i => i.group))];
    const total = items.filter(i => st.picked.has(i.path)).reduce((s, i) => s + (st.sizes[i.path] || 0), 0);
    body().innerHTML = `<div class="note warn"><b>Que voulez-vous garder ?</b> Vérifiez cette liste avant de continuer : ce qui n'est pas coché ne sera pas sauvegardé. Fermez aussi vos jeux, navigateurs et Discord : un fichier ouvert ne peut pas être copié.</div>
      <div class="row" style="margin:10px 0 0"><button class="btn small" id="pick-all">Tout sélectionner</button><button class="btn small" id="pick-none">Tout désélectionner</button></div>
      ${groups.map(g => `<h2>${esc(g)}</h2><div class="card glass" style="padding:6px">${items.filter(i => i.group === g).map(i => `<label class="pick"><input type="checkbox" data-p="${esc(i.path)}"${st.picked.has(i.path) ? ' checked' : ''}><div class="grow"><div><b>${esc(i.label)}</b></div><div class="muted small">${esc(i.why)}${i.note ? ` · <span style="color:var(--warn)">${esc(i.note)}</span>` : ''}</div><div class="muted small mono ellipsis">${esc(i.path)}</div></div><span class="size">${st.sizes[i.path] == null ? '…' : fmtSize(st.sizes[i.path])}</span></label>`).join('')}</div>`).join('')}
      <div class="card glass"><h3>Options</h3>
        <label class="pick"><input type="checkbox" id="o-caches"${st.skipCaches ? ' checked' : ''}><div>Ignorer les caches (navigateurs, shaders, node_modules, temporaires)<div class="muted small">Recréés par les logiciels. Fortement conseillé : la taille affichée au-dessus les inclut encore.</div></div><span></span></label>
        <label class="pick"><input type="checkbox" id="o-cap"${st.captures ? ' checked' : ''}><div>Captures d'écran du bureau, fond d'écran, liste des icônes<div class="muted small">Les fenêtres sont réduites une seconde puis restaurées.</div></div><span></span></label>
        <label class="pick"><input type="checkbox" id="o-drv"${st.drivers ? ' checked' : ''}><div>Exporter les pilotes installés<div class="muted small">Pratique si le réseau ne fonctionne pas après la réinstallation.</div></div><span></span></label>
        ${st.scan.hasWifi ? `<label class="pick"><input type="checkbox" id="o-wifi"${st.wifi ? ' checked' : ''}><div>Réseaux Wi-Fi enregistrés<div class="muted small" style="color:var(--warn)">Les mots de passe sont écrits en clair dans la sauvegarde.</div></div><span></span></label>` : ''}
      </div>
      <div class="card glass sticky row"><button class="btn" id="add">Ajouter un dossier…</button><span class="grow"><b>${fmtSize(total)}</b> <span class="muted small">au plus, caches compris</span></span><button class="btn" data-go="0">Retour</button><button class="btn primary" data-go="2">Continuer</button></div>`;
  }

  async function renderDest() {
    const items = [...[].concat(st.scan.items), ...st.custom].filter(i => st.picked.has(i.path));
    const total = items.reduce((s, i) => s + (st.sizes[i.path] || 0), 0);
    let free = null;
    if (st.dest) { free = (await bao.call('backup.free', { path: st.dest })).free; if (!live()) return; }
    const sameDrive = st.dest && st.dest[0].toUpperCase() === (state.info?.home || 'C')[0].toUpperCase();
    body().innerHTML = `<div class="card glass"><h3>Où enregistrer la sauvegarde ?</h3><div class="row" style="margin-top:8px"><input class="field grow" id="dest" value="${esc(st.dest)}" placeholder="Disque externe conseillé, ex. E:\\"><button class="btn" id="browse">Parcourir…</button></div>
      ${free != null ? `<div class="small" style="margin-top:8px">${fmtSize(free)} libres, ${fmtSize(total)} au plus à copier${st.dl.size ? `, plus ${st.dl.size} installateur(s)` : ''}.</div>` : ''}
      ${free != null && free < total ? `<div class="note warn" style="margin:8px 0 0">Il peut manquer de la place, même si les caches ignorés réduiront le volume.</div>` : ''}
      ${sameDrive ? `<div class="note warn" style="margin:8px 0 0">Cette destination est sur le disque de Windows : une réinstallation peut l'effacer. Préférez un disque externe.</div>` : ''}</div>
      <div class="card glass"><h3>Résumé</h3><ul class="small" style="margin:0;padding-left:18px"><li>${plural(items.length, 'dossier de données', 'dossiers de données')}</li><li>${st.dl.size} installateur(s) à télécharger</li><li>Inventaire, Tout-reinstaller.cmd et Ouvrir-les-sites.cmd</li>${st.captures ? '<li>Captures du bureau</li>' : ''}${st.drivers ? '<li>Export des pilotes</li>' : ''}${st.wifi ? '<li>Réseaux Wi-Fi (mots de passe en clair)</li>' : ''}</ul></div>
      <div class="row end"><button class="btn" data-go="1">Retour</button><button class="btn primary" id="start"${st.dest ? '' : ' disabled'}>Lancer la sauvegarde</button></div>`;
  }

  async function start() {
    st.step = 3; steps();
    const items = [...[].concat(st.scan.items), ...st.custom].filter(i => st.picked.has(i.path));
    const d = new Date(), stamp = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
    body().innerHTML = `<div class="card glass"><div class="progress" style="padding:0"><div class="spinner"></div><div class="grow"><b id="p-t">Préparation…</b><div class="muted small ellipsis" id="p-d"></div></div><button class="btn danger" id="stop">Arrêter</button></div></div>`;
    const job = bao.call('backup.run', { dest: st.dest, stamp, items: items.map(i => ({ label: i.label, path: i.path })), download: [...st.dl], captures: st.captures, minimize: st.minimize, skipCaches: st.skipCaches, drivers: st.drivers, wifi: st.wifi, programs: st.inv.programs, games: st.inv.games }, p => {
      const t = $('#p-t', v), s = $('#p-d', v); if (!t) return;
      t.textContent = p.step === 'data' ? `Copie : ${p.label}` : p.step === 'installers' ? `Installateur ${p.index}/${p.total} : ${p.label}` : p.label;
      s.textContent = p.step === 'data' ? `${nf0.format(p.files)} fichiers · ${fmtSize(p.bytes)}${p.errors ? ` · ${p.errors} erreur(s)` : ''}${p.current ? ' · ' + p.current : ''}` : (p.line || '');
    });
    $('#stop', v).onclick = () => { bao.cancel(job); $('#p-t', v).textContent = 'Arrêt en cours…'; };
    try {
      const r = await job;
      if (!live()) return;
      const dlFail = (r.downloads || []).filter(x => !x.ok);
      body().innerHTML = `<div class="note ${r.cancelled ? 'warn' : r.errors || dlFail.length ? 'warn' : 'ok'}"><b>${r.cancelled ? 'Sauvegarde interrompue' : 'Sauvegarde terminée'}</b><br>${r.report.map(esc).join('<br>')}</div>
        ${r.errors ? `<div class="card glass"><h3>${plural(r.errors, 'fichier non copié', 'fichiers non copiés')}</h3><div class="muted small">Le plus souvent des fichiers ouverts : fermez le logiciel concerné et relancez, seuls les manquants seront copiés. La liste complète est dans « Erreurs de copie.txt ».</div><div class="console">${r.firstErrors.map(esc).join('\n')}</div></div>` : ''}
        ${dlFail.length ? `<div class="card glass"><h3>Installateurs non téléchargés</h3><div class="console">${dlFail.map(x => esc(x.id + ' : ' + x.message)).join('\n')}</div><div class="muted small">Ils restent réinstallables par Tout-reinstaller.cmd.</div></div>` : ''}
        <div class="row"><button class="btn primary" id="open-folder" data-f="${esc(r.folder)}">Ouvrir le dossier</button><button class="btn" data-go="2">Relancer</button></div>`;
    } catch (e) { if (live()) body().innerHTML = `<div class="note bad">${esc(e.message)}</div><button class="btn" data-go="2">Retour</button>`; }
  }

  v.addEventListener('click', async e => {
    const nav = e.target.closest('[data-go]');
    if (nav) return go(+nav.dataset.go);
    if (e.target.closest('#next')) return go(1);
    if (e.target.closest('#all')) { st.inv.programs.filter(p => p.kind === 'winget' && (st.showSys || !p.system)).forEach(p => st.dl.add(p.id)); return renderSoft(); }
    if (e.target.closest('#none')) { st.dl.clear(); return renderSoft(); }
    const site = e.target.closest('[data-site]');
    if (site) return void bao.call('open', { target: site.dataset.site });
    if (e.target.closest('#add')) {
      const r = await bao.call('backup.pick');
      if (r.path) { st.custom.push({ group: 'Ajoutés par vous', label: baseName(r.path), path: r.path, why: 'Dossier choisi', note: '' }); st.picked.add(r.path); bao.call('files.sizes', { paths: [r.path] }).then(s => { st.sizes[r.path] = s[0]; if (st.step === 1) drawData(); }); drawData(); }
      return;
    }
    if (e.target.closest('#browse')) { const r = await bao.call('backup.pick'); if (r.path) { st.dest = r.path; renderDest(); } return; }
    if (e.target.closest('#start')) { const ok = await bao.call('backup.free', { path: st.dest }); if (!ok.free) return toast('Dossier de destination introuvable'); return start(); }
    const of = e.target.closest('#open-folder');
    if (of) bao.call('files.reveal', { path: of.dataset.f });
    const pk = e.target.closest('#pick-all, #pick-none');
    if (pk) { for (const i of [...[].concat(st.scan.items), ...st.custom]) pk.id === 'pick-all' ? st.picked.add(i.path) : st.picked.delete(i.path); drawData(); }
  });
  v.addEventListener('change', e => {
    const t = e.target;
    if (t.id === 'sys') { st.showSys = t.checked; return renderSoft(); }
    if (t.dataset.dl) { t.checked ? st.dl.add(t.dataset.dl) : st.dl.delete(t.dataset.dl); return; }
    if (t.dataset.p) { t.checked ? st.picked.add(t.dataset.p) : st.picked.delete(t.dataset.p); return drawData(); }
    if (t.id === 'o-caches') st.skipCaches = t.checked;
    if (t.id === 'o-cap') st.captures = t.checked;
    if (t.id === 'o-drv') st.drivers = t.checked;
    if (t.id === 'o-wifi') st.wifi = t.checked;
    if (t.id === 'dest') { st.dest = t.value.trim(); renderDest(); }
  });
  steps();
  state.info ??= await bao.call('info');
  body().innerHTML = '<div class="progress glass"><div class="spinner"></div><div id="inv-s">Inventaire…</div></div>';
  st.inv = await inventory(s => { const e = $('#inv-s', v); if (e) e.textContent = s; });
  if (live()) renderSoft();
};

// ── Essentiels ───────────────────────────────────────────────────────────
const ESSENTIALS = [
  ['Redistribuables Microsoft', 'Nécessaires à la plupart des jeux et logiciels. Sans risque : à installer tous si un jeu réclame une DLL manquante.', [
    ['Microsoft.VCRedist.2015+.x64', 'Visual C++ 2015-2022 (64 bits)', 1], ['Microsoft.VCRedist.2015+.x86', 'Visual C++ 2015-2022 (32 bits)', 1], ['Microsoft.VCRedist.2013.x64', 'Visual C++ 2013 (64 bits)'], ['Microsoft.VCRedist.2013.x86', 'Visual C++ 2013 (32 bits)'], ['Microsoft.VCRedist.2012.x64', 'Visual C++ 2012 (64 bits)'], ['Microsoft.VCRedist.2012.x86', 'Visual C++ 2012 (32 bits)'], ['Microsoft.VCRedist.2010.x64', 'Visual C++ 2010 (64 bits)'], ['Microsoft.VCRedist.2010.x86', 'Visual C++ 2010 (32 bits)'], ['Microsoft.VCRedist.2008.x64', 'Visual C++ 2008 (64 bits)'], ['Microsoft.VCRedist.2008.x86', 'Visual C++ 2008 (32 bits)'], ['Microsoft.VCRedist.2005.x64', 'Visual C++ 2005 (64 bits)'], ['Microsoft.VCRedist.2005.x86', 'Visual C++ 2005 (32 bits)'], ['Microsoft.DirectX', 'DirectX (anciens jeux)', 1], ['Microsoft.DotNet.DesktopRuntime.8', '.NET Desktop 8', 1], ['Microsoft.DotNet.DesktopRuntime.9', '.NET Desktop 9'], ['Microsoft.DotNet.DesktopRuntime.6', '.NET Desktop 6'], ['Microsoft.EdgeWebView2Runtime', 'WebView2'],
  ]],
  ['Java', 'Minecraft et de nombreux outils. Temurin est la distribution libre d\'Eclipse.', [
    ['EclipseAdoptium.Temurin.21.JRE', 'Java 21 (Temurin)', 1], ['EclipseAdoptium.Temurin.17.JRE', 'Java 17 (Temurin)'], ['EclipseAdoptium.Temurin.8.JRE', 'Java 8 (Temurin)'], ['Oracle.JavaRuntimeEnvironment', 'Java 8 (Oracle)'], ['EclipseAdoptium.Temurin.21.JDK', 'JDK 21 pour développeurs'],
  ]],
  ['Navigateurs et communication', '', [['Mozilla.Firefox', 'Firefox'], ['Google.Chrome', 'Chrome'], ['Brave.Brave', 'Brave'], ['Discord.Discord', 'Discord'], ['Telegram.TelegramDesktop', 'Telegram'], ['Mozilla.Thunderbird', 'Thunderbird']]],
  ['Jeu', '', [['Valve.Steam', 'Steam'], ['EpicGames.EpicGamesLauncher', 'Epic Games'], ['GOG.Galaxy', 'GOG Galaxy'], ['Ubisoft.Connect', 'Ubisoft Connect'], ['ElectronicArts.EADesktop', 'EA app'], ['Blizzard.BattleNet', 'Battle.net'], ['Guru3D.Afterburner', 'MSI Afterburner'], ['OBSProject.OBSStudio', 'OBS Studio']]],
  ['Utilitaires', '', [['7zip.7zip', '7-Zip', 1], ['Notepad++.Notepad++', 'Notepad++'], ['VideoLAN.VLC', 'VLC', 1], ['voidtools.Everything', 'Everything'], ['Microsoft.PowerToys', 'PowerToys'], ['ShareX.ShareX', 'ShareX'], ['Rufus.Rufus', 'Rufus'], ['qBittorrent.qBittorrent', 'qBittorrent'], ['SumatraPDF.SumatraPDF', 'SumatraPDF'], ['AntibodySoftware.WizTree', 'WizTree'], ['Bitwarden.Bitwarden', 'Bitwarden'], ['KeePassXCTeam.KeePassXC', 'KeePassXC'], ['Malwarebytes.Malwarebytes', 'Malwarebytes']]],
  ['Bureautique et création', '', [['TheDocumentFoundation.LibreOffice', 'LibreOffice'], ['dotPDN.PaintDotNet', 'Paint.NET'], ['GIMP.GIMP.3', 'GIMP'], ['Audacity.Audacity', 'Audacity'], ['HandBrake.HandBrake', 'HandBrake']]],
  ['Diagnostic matériel', '', [['CPUID.CPU-Z', 'CPU-Z'], ['TechPowerUp.GPU-Z', 'GPU-Z'], ['REALiX.HWiNFO', 'HWiNFO'], ['CrystalDewWorld.CrystalDiskInfo', 'CrystalDiskInfo'], ['CrystalDewWorld.CrystalDiskMark', 'CrystalDiskMark'], ['Wagnardsoft.DisplayDriverUninstaller', 'Display Driver Uninstaller']]],
  ['Développement', '', [['Git.Git', 'Git'], ['Microsoft.VisualStudioCode', 'VS Code'], ['Python.Python.3.13', 'Python 3.13'], ['OpenJS.NodeJS.LTS', 'Node.js LTS'], ['Microsoft.WindowsTerminal', 'Terminal Windows']]],
];
views.essentials = async (v, live) => {
  v.innerHTML = `<h1>Essentiels</h1><p class="lead">Redistribuables, Java et logiciels utiles, en version officielle et sans barre d'outils cachée : ils viennent du dépôt winget de Microsoft. Cochez, installez, c'est tout.</p>
    <div class="row" style="margin-bottom:12px"><button class="btn" id="reco">Sélection conseillée</button><button class="btn" id="clear">Tout décocher</button><span class="grow"></span><button class="btn" id="upall">Mettre à jour tous mes logiciels</button><button class="btn primary" id="go" disabled>Installer</button></div>
    <div id="ess-run"></div><div id="ess">${ESSENTIALS.map(([t, d, list]) => `<h2>${esc(t)}</h2>${d ? `<p class="muted small">${esc(d)}</p>` : ''}<div class="ess-grid">${list.map(([id, n]) => `<label class="ess-item glass" data-item="${esc(id)}"><input type="checkbox" data-id="${esc(id)}" data-n="${esc(n)}"><span class="ellipsis">${esc(n)}</span><span class="small muted" data-state></span></label>`).join('')}</div>`).join('')}</div>`;
  const update = () => {
    const n = $$('[data-id]:checked', v).length;
    const go = $('#go', v); go.disabled = !n; go.textContent = n ? `Installer (${n})` : 'Installer';
  };
  v.addEventListener('change', update);
  bao.call('winget.list').then(r => {
    if (!live()) return;
    const ids = new Set(r.items.map(p => p.id.toLowerCase()));
    const upd = new Map(r.items.filter(p => p.available).map(p => [p.id.toLowerCase(), p.available]));
    for (const el of $$('[data-item]', v)) {
      const id = el.dataset.item.toLowerCase();
      if (ids.has(id)) { el.classList.add('installed'); $('[data-state]', el).innerHTML = upd.has(id) ? `<span class="badge info">Mise à jour</span>` : `<span class="badge ok">Installé</span>`; }
    }
  }).catch(e => { if (live()) $('#ess-run', v).innerHTML = `<div class="note warn">${esc(e.message)}</div>`; });
  const runBox = title => { $('#ess-run', v).innerHTML = `<div class="card glass"><div class="progress" style="padding:0"><div class="spinner"></div><div class="grow"><b data-t>${esc(title)}</b><div class="muted small ellipsis" data-l></div></div><button class="btn danger" data-stop>Arrêter</button></div><div class="console" data-c hidden></div></div>`; };
  v.addEventListener('click', async e => {
    if (e.target.closest('#reco')) {
      const rec = new Set(ESSENTIALS.flatMap(([, , l]) => l.filter(x => x[2]).map(x => x[0])));
      $$('[data-id]', v).forEach(c => { c.checked = rec.has(c.dataset.id) && !c.closest('.installed'); });
      return update();
    }
    if (e.target.closest('#clear')) { $$('[data-id]', v).forEach(c => (c.checked = false)); return update(); }
    if (e.target.closest('#upall')) {
      if (!await confirmAction('Tout mettre à jour ?', '<p>Tous les logiciels connus de winget passent à leur dernière version. Fermez-les d\'abord : un logiciel ouvert peut refuser la mise à jour.</p>', 'Mettre à jour')) return;
      runBox('Mise à jour de tous les logiciels');
      const box = $('#ess-run', v);
      const job = bao.call('winget.upgradeAll', {}, p => { const l = $('[data-l]', box); if (l) l.textContent = p.line; });
      $('[data-stop]', box).onclick = () => bao.cancel(job);
      try { const r = await job; if (live()) box.innerHTML = `<div class="note ${r.ok ? 'ok' : 'warn'}">${r.ok ? 'Mises à jour terminées.' : 'Certaines mises à jour ont échoué : ' + esc(r.message)}</div>`; }
      catch (err) { if (live()) box.innerHTML = `<div class="note warn">${esc(err.message)}</div>`; }
      return;
    }
    if (e.target.closest('#go')) {
      const list = $$('[data-id]:checked', v).map(c => ({ id: c.dataset.id, name: c.dataset.n }));
      runBox('Installation');
      const box = $('#ess-run', v);
      let cur = null, stop = false;
      $('[data-stop]', box).onclick = () => { stop = true; bao.cancel(cur); };
      const results = [];
      for (const [i, p] of list.entries()) {
        if (stop || !live()) break;
        const el = $(`[data-item="${CSS.escape(p.id)}"]`, v);
        $('[data-t]', box).textContent = `${i + 1}/${list.length} : ${p.name}`;
        $('[data-state]', el).innerHTML = '<span class="badge info">En cours</span>';
        cur = bao.call('winget.install', { id: p.id, name: p.name }, x => { const l = $('[data-l]', box); if (l) l.textContent = x.line; });
        try {
          const r = await cur;
          results.push({ ...p, ok: r.ok, message: r.message });
          $('[data-state]', el).innerHTML = r.ok ? '<span class="badge ok">Installé</span>' : '<span class="badge bad">Échec</span>';
          if (r.ok) { el.classList.add('installed'); $('[data-id]', el).checked = false; }
        } catch (err) { results.push({ ...p, ok: false, message: err.message }); $('[data-state]', el).innerHTML = ''; }
      }
      if (!live()) return;
      const failed = results.filter(r => !r.ok);
      box.innerHTML = `<div class="note ${failed.length ? 'warn' : 'ok'}">${results.length - failed.length} sur ${list.length} installés.${failed.length ? '<br>' + failed.map(f => esc(`${f.name} : ${f.message}`)).join('<br>') : ''}</div>`;
      update();
    }
  });
};

/* SPDX-License-Identifier: GPL-3.0-or-later — Copyright (C) 2026 jeremdevgit — voir LICENSE */
'use strict';
/* Boîte à outils — interface. JavaScript sans framework. Chaque action qui
   modifie Windows : confirmation si elle a un effet visible, point de
   restauration proposé une fois par session, inscription dans l'historique. */

// ── outils ───────────────────────────────────────────────────────────────
const $ = (s, r = document) => r.querySelector(s);
const $$ = (s, r = document) => [...r.querySelectorAll(s)];
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const native = m => window.ipc && window.ipc.postMessage(JSON.stringify(m));
const log = msg => native({ cmd: 'log', msg: String(msg) });
addEventListener('error', e => log('ERREUR JS : ' + e.message + ' @' + e.lineno));
addEventListener('unhandledrejection', e => log('PROMESSE : ' + (e.reason?.message || e.reason)));

const nf1 = new Intl.NumberFormat(LOCALE, { maximumFractionDigits: 1 });
const nf0 = new Intl.NumberFormat(LOCALE, { maximumFractionDigits: 0 });
// unités de taille : octets en français, bytes ailleurs
const UNITS = LANG === 'fr' ? { b: 'o', k: 'Ko', m: 'Mo', g: 'Go', t: 'To' } : { b: 'B', k: 'KB', m: 'MB', g: 'GB', t: 'TB' };
function fmtSize(b) {
  b = +b || 0;
  if (b >= 1e12) return nf1.format(b / 1e12) + ' ' + UNITS.t;
  if (b >= 1e9) return nf1.format(b / 1e9) + ' ' + UNITS.g;
  if (b >= 1e6) return nf0.format(b / 1e6) + ' ' + UNITS.m;
  if (b >= 1e3) return nf0.format(b / 1e3) + ' ' + UNITS.k;
  return b + ' ' + UNITS.b;
}
const fmtDate = d => { const t = typeof d === 'number' ? new Date(d * 1000) : new Date(d); return isNaN(t) ? '' : t.toLocaleDateString(LOCALE, { day: 'numeric', month: 'short', year: 'numeric' }); };
const fmtDateTime = d => { const t = typeof d === 'number' ? new Date(d * 1000) : new Date(d); return isNaN(t) ? '' : t.toLocaleString(LOCALE, { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' }); };
const fmtDuration = s => { const d = Math.floor(s / 86400), h = Math.floor(s / 3600) % 24, m = Math.floor(s / 60) % 60; return d ? trad('{d} j {h} h', { d, h }) : h ? trad('{h} h {m} min', { h, m }) : trad('{m} min', { m }); };
const baseName = p => String(p).split('\\').filter(Boolean).pop() || p;
const plural = (n, one, many) => tradn(n, '{n} ' + one, '{n} ' + many);

let toastTimer = 0;
function toast(msg) {
  const t = $('#toast'); t.textContent = msg; t.hidden = false;
  clearTimeout(toastTimer); toastTimer = setTimeout(() => (t.hidden = true), 3600);
}

/** Fenêtre de confirmation. buttons : [[valeur, libellé, classe]] → Promise(valeur | null). */
function modal(title, html, buttons = [['ok', 'OK', 'primary']]) {
  return new Promise(done => {
    const m = $('#modal'), box = $('#modal-box');
    box.innerHTML = `<h2>${esc(title)}</h2><div>${html}</div><div class="row end">${buttons.map(([v, l, c]) => `<button class="btn ${c || ''}" data-v="${esc(v)}">${esc(l)}</button>`).join('')}</div>`;
    m.hidden = false;
    const close = v => { m.hidden = true; m.onclick = null; removeEventListener('keydown', key); done(v); };
    const key = e => { if (e.key === 'Escape') close(null); };
    addEventListener('keydown', key);
    m.onclick = e => { const b = e.target.closest('[data-v]'); if (b) close(b.dataset.v); else if (e.target === m) close(null); };
    box.querySelector('.btn.primary, .btn.danger')?.focus();
  });
}
/** Boutons « Tout sélectionner / Tout désélectionner » pour les cases `sel` du bloc `scope` qui les contient. */
const checkAll = (sel, scope) => `<span class="check-all"><button class="btn small" data-check-all="1" data-sel="${esc(sel)}" data-scope="${esc(scope)}">Tout sélectionner</button><button class="btn small" data-check-all="0" data-sel="${esc(sel)}" data-scope="${esc(scope)}">Tout désélectionner</button></span>`;
document.addEventListener('click', e => {
  const b = e.target.closest('[data-check-all]');
  if (!b) return;
  e.preventDefault();
  const on = b.dataset.checkAll === '1', root = b.closest(b.dataset.scope) || document;
  for (const i of root.querySelectorAll(b.dataset.sel)) if (!i.disabled && i.checked !== on && !i.closest('[hidden]')) { i.checked = on; i.dispatchEvent(new Event('change', { bubbles: true })); }
});
const confirmAction = async (title, html, ok = 'Continuer', danger = false) => (await modal(title, html, [['no', 'Annuler', ''], ['yes', ok, danger ? 'danger' : 'primary']])) === 'yes';

const filterNorm = s => String(s ?? '').normalize('NFKD').replace(/\p{M}/gu, '').toLocaleLowerCase(LOCALE);
const filterMatch = (q, ...parts) => !q || filterNorm(parts.map(x => `${x ?? ''} ${tradTexte(String(x ?? '')) || ''}`).join(' ')).includes(filterNorm(q));
const filterSelect = (id, label, options) => `<select class="field" id="${id}" aria-label="${esc(label)}">${options.map(([value, text]) => `<option value="${value}">${esc(text)}</option>`).join('')}</select>`;
const sizeFilter = id => filterSelect(id, 'Taille minimale', [[0, 'Toutes les tailles'], [10e6, 'Plus de 10 Mo'], [100e6, 'Plus de 100 Mo'], [1e9, 'Plus de 1 Go']]);

// ── communication avec le code natif ────────────────────────────────────
const bao = {
  seq: 0, pending: new Map(),
  /** Promesse de la réponse ; .id sert à annuler une analyse longue. */
  call(cmd, args = {}, onProgress) {
    const id = ++this.seq;
    const p = new Promise((ok, ko) => this.pending.set(id, { ok, ko, onProgress }));
    p.id = id;
    native({ id, cmd, args });
    return p;
  },
  cancel(p) { if (p?.id) native({ id: 0, cmd: 'cancel', args: { job: p.id } }); },
  recv(m) {
    const p = this.pending.get(m.id);
    if (!p) return;
    if (m.type === 'progress') { p.onProgress?.(m.data); return; }
    this.pending.delete(m.id);
    m.ok ? p.ok(m.data) : p.ko(new Error(m.error));
  },
};
window.bao = bao;
const ps = (script, args = {}, title) => bao.call('ps', { script, args, title });

const state = { info: null, elevated: false, safetyAsked: false, busyTool: false };

/** Avant la première modification de la session : point de restauration proposé. */
async function safety() {
  if (state.safetyAsked || !state.elevated) return true;
  const v = await modal('Créer un point de restauration ?',
    `<p>C'est la première modification de cette session. Un point de restauration permet de revenir à l'état actuel de Windows si quelque chose tourne mal, même sans la Boîte à outils.</p><p class="muted small">Chaque modification reste aussi annulable depuis l'Historique.</p>`,
    [['cancel', 'Annuler', ''], ['skip', 'Continuer sans', ''], ['create', 'Créer puis continuer', 'primary']]);
  if (!v || v === 'cancel') return false;
  state.safetyAsked = true;
  if (v === 'create') {
    toast('Création du point de restauration…');
    try { await ps('restore', { action: 'create', description: 'Boîte à outils', enable: true }); toast('Point de restauration créé'); }
    catch (e) { return (await confirmAction('Point de restauration impossible', `<p>${esc(e.message)}</p><p>Continuer quand même ? La modification restera annulable depuis l'Historique.</p>`)); }
  }
  return true;
}

const riskBadge = r => r && RISK[r] ? `<span class="badge ${RISK[r][1]}">${RISK[r][0]}</span>` : '';
const needAdmin = () => !state.elevated;
const adminNote = () => state.elevated ? '' : `<div class="note warn">Mode limité : relancez la Boîte à outils en administrateur pour modifier les éléments de tout le PC (services, tâches, Windows). <button class="btn small" data-act="elevate">Relancer en administrateur</button></div>`;
document.addEventListener('click', e => { if (e.target.closest('[data-act="elevate"]')) native({ cmd: 'elevate' }); });

// ── navigation ───────────────────────────────────────────────────────────
const TITLES = { home: 'Accueil', startup: 'Démarrage', services: 'Services', processes: 'Processus', clean: 'Nettoyage', large: 'Fichiers lourds', ghosts: 'Fichiers fantômes', hardware: 'Matériel', displays: 'Écrans', usb: 'Ports USB et câbles', drivers: 'Pilotes', hwplus: 'Diagnostic avancé', backup: 'Sauvegarde propre', essentials: 'Essentiels', sensors: 'Capteurs', stress: 'Tests de stabilité', perf: 'Performances', perso: 'Personnalisation', tweaks: 'Réglages', godmode: 'Mode Dieu', downloads: 'Mes logiciels', tools: 'Santé et réparation', programs: 'Applications', sysinternals: 'Sysinternals', history: 'Historique' };
const router = {
  view: 'home', token: 0, cleanup: [],
  go(view) {
    this.cleanup.forEach(f => f()); this.cleanup = [];
    this.view = view;
    $$('#nav a').forEach(a => a.classList.toggle('on', a.dataset.view === view));
    document.body.classList.remove('drawer');
    $('#top-title').textContent = TITLES[view] || 'Boîte à outils';
    $('#main').scrollTop = 0;
    // conteneur neuf à chaque page : ses écouteurs disparaissent avec elle
    const v = document.createElement('div');
    $('#view').replaceChildren(v);
    v.innerHTML = '<div class="spinner big"></div>';
    const token = ++this.token;
    Promise.resolve(views[view](v, () => token === this.token)).catch(e => {
      log('vue ' + view + ' : ' + e.message);
      if (token === this.token) v.innerHTML = `<div class="empty"><h2>Impossible d'afficher cette page</h2><div>${esc(e.message)}</div></div>`;
    });
  },
};

const views = {};

// ── accueil ──────────────────────────────────────────────────────────────
views.home = async (v, live) => {
  const info = state.info = await bao.call('info');
  if (!live()) return;
  const greeting = trad('Bonjour{0}', { 0: info.user ? ' ' + esc(info.user) : '' });
  v.innerHTML =`<h1 data-brut>${greeting}</h1><p class="lead">Un état rapide du PC et ce qui mérite votre attention. Rien n'est modifié sans votre accord, et tout est annulable depuis l'Historique.</p>
    ${adminNote()}
    <div class="cards">
      <div class="card glass" id="sys"><h3>Système</h3><div class="muted small" id="sys-os">…</div><div class="small" id="sys-hw"></div>
        <div class="muted small" style="margin-top:10px">Allumé depuis ${fmtDuration(info.uptime)} · <span id="sys-act"></span></div></div>
      <div class="card glass" id="live"><h3>En direct</h3>${['cpu', 'gpu', 'mem', 'net'].map(k => `<div class="row"><span class="grow">${{ cpu: 'Processeur', gpu: 'Carte graphique', mem: 'Mémoire', net: 'Réseau' }[k]}</span><span class="size" data-live="${k}">…</span></div>${k === 'net' ? '' : `<div class="bar"><i data-bar="${k}" style="width:0"></i></div>`}`).join('')}</div>
      <div class="card glass"><h3>Disques</h3>${info.drives.map(d => { const u = d.total - d.free, pct = u / d.total; const label = trad('<span class="grow">{0}</span><span class="size">{1} libres sur {2}</span>', { 0: esc(d.drive), 1: esc(fmtSize(d.free)), 2: esc(fmtSize(d.total)) }); return `<div class="row" data-brut>${label}</div><div class="bar${pct > .9 ? ' hot' : ''}"><i style="width:${(pct * 100).toFixed(1)}%"></i></div>`; }).join('')}</div>
    </div>
    <h2>À regarder</h2><div class="list" id="recos"><div class="progress glass"><div class="spinner"></div><div>Analyse rapide du PC…</div></div></div>`;
  ps('system').then(o => {
    if (!live()) return;
    $('#sys-os').textContent = `${o.os} · build ${o.build}`;
    $('#sys-hw').innerHTML = `${esc(o.cpu)}<br>${esc((o.gpus || []).join(', '))}`;
    state.overview = o;
  }).catch(() => { });
  ps('repair', { action: 'status' }).then(s => {
    if (!live() || s.activated == null) return;
    $('#sys-act', v).innerHTML = s.activated ? 'Windows activé' : '<span style="color:var(--warn)">Windows non activé</span>';
  }).catch(() => { });
  quickCheck(v, live, info);
  liveMonitor(v, live);
};

/** Activité en direct : une mesure par seconde tant que l'accueil est affiché. */
function liveMonitor(v, live) {
  const rate = b => b >= 1e6 ? nf1.format(b / 1e6) + ' ' + UNITS.m + '/s' : nf0.format(b / 1e3) + ' ' + UNITS.k + '/s';
  const set = (k, text, pct) => {
    const t = $(`[data-live="${k}"]`, v); if (t) t.textContent = text;
    const b = $(`[data-bar="${k}"]`, v); if (b && pct != null) { b.style.width = Math.min(100, pct).toFixed(1) + '%'; b.parentElement.classList.toggle('hot', pct > 90); }
  };
  let busy = false;
  const tick = async () => {
    if (busy || !live() || document.hidden) return;
    busy = true;
    try {
      const s = await bao.call('live');
      const used = s.memTotal - s.memAvail;
      set('cpu', nf0.format(s.cpu) + ' %', s.cpu);
      set('gpu', s.gpu == null ? '—' : nf0.format(s.gpu) + ' %', s.gpu ?? 0);
      set('mem', `${fmtSize(used)} / ${fmtSize(s.memTotal)}`, used / s.memTotal * 100);
      set('net', `↓ ${rate(s.rx)} · ↑ ${rate(s.tx)}`);
    } catch { }
    busy = false;
  };
  tick();
  const id = setInterval(tick, 1000);
  router.cleanup.push(() => clearInterval(id));
}

async function quickCheck(v, live, info) {
  const recos = [];
  const add = (level, title, text, view, btn) => recos.push({ level, title, text, view, btn });
  for (const d of info.drives) {
    if (d.free / d.total < .12) add('bad', `Espace faible sur ${d.drive}`, `Il reste ${fmtSize(d.free)}. Windows et les jeux ralentissent quand un disque est presque plein.`, 'large', 'Trouver les fichiers lourds');
  }
  const [clean, startup, restore, disks, shortcuts, sys] = await Promise.all([
    bao.call('clean.analyze').catch(() => null),
    ps('startup').catch(() => null),
    state.elevated ? ps('restore').catch(() => null) : null,
    ps('disks').catch(() => null),
    ps('shortcuts').catch(() => null),
    ps('system').catch(() => null),
  ]);
  if (!live()) return;
  if (clean) {
    const sz = clean.cats.filter(c => c.default && !c.locked).reduce((s, c) => s + c.size, 0);
    if (sz > 500e6) add('info', `${fmtSize(sz)} de caches et fichiers temporaires`, 'Récupérables sans conséquence (caches de navigateurs, temporaires, rapports d\'erreurs…).', 'clean', 'Nettoyer');
  }
  if (startup) {
    const on = startup.items.filter(i => i.kind !== 'task' && i.enabled);
    if (on.length >= 6) add('info', `${on.length} programmes se lancent au démarrage`, 'Chacun allonge le démarrage et occupe de la mémoire. Ceux dont vous n\'avez pas besoin tout de suite peuvent être coupés.', 'startup', 'Voir le démarrage');
    const broken = startup.items.filter(i => !i.exists);
    if (broken.length) add('info', plural(broken.length, 'entrée de démarrage cassée', 'entrées de démarrage cassées'), 'Elles lancent un programme qui n\'existe plus.', 'startup', 'Voir');
  }
  if (restore) {
    const last = [].concat(restore.points || []).map(p => new Date(p.date)).sort((a, b) => b - a)[0];
    if (!restore.enabled) add('warn', 'Protection du système désactivée', 'Aucun point de restauration ne peut être créé : en cas de problème après une mise à jour ou un pilote, pas de retour arrière possible.', 'tools', 'Activer');
    else if (!last || Date.now() - last > 30 * 864e5) add('info', 'Pas de point de restauration récent', last ? `Le dernier date du ${fmtDate(last)}.` : 'Aucun point trouvé.', 'tools', 'Créer un point');
  }
  if (disks) {
    for (const d of disks.disks || []) {
      if (d.health && d.health !== 'Healthy') add('bad', `Disque « ${d.name} » : état ${d.health}`, 'Windows signale un problème de santé. Sauvegardez vos données importantes sans attendre.', 'tools', 'Voir les disques');
      else if (d.wear >= 80) add('warn', `SSD « ${d.name} » usé à ${d.wear} %`, 'Il approche de sa fin de vie théorique : gardez des sauvegardes à jour.', 'tools', 'Voir les disques');
    }
  }
  if (shortcuts?.items?.length) add('ok', plural(shortcuts.items.length, 'raccourci cassé', 'raccourcis cassés'), 'Des raccourcis pointent vers des programmes qui n\'existent plus.', 'ghosts', 'Voir les fichiers fantômes');
  if (sys?.defender && !sys.defender.realtime) add('warn', 'Protection en temps réel de Defender désactivée', 'Normal si un autre antivirus est installé. Sinon, le PC n\'est pas protégé.', null, null);
  if (info.uptime > 10 * 86400) add('info', `PC allumé depuis ${fmtDuration(info.uptime)}`, 'Redémarrer de temps en temps applique les mises à jour et libère la mémoire. (« Arrêter » ne suffit pas si le démarrage rapide est actif.)', null, null);
  const box = $('#recos', v);
  const order = { bad: 0, warn: 1, info: 2, ok: 3 };
  recos.sort((a, b) => order[a.level] - order[b.level]);
  box.innerHTML = recos.length ? recos.map(r => `<div class="item glass"><div class="ico" style="color:var(--${r.level === 'ok' ? 'ok' : r.level})">${r.level === 'bad' ? '!' : r.level === 'warn' ? '!' : 'i'}</div><div><div class="title">${esc(r.title)}</div><div class="what">${esc(r.text)}</div></div><div class="side">${r.view ? `<button class="btn small" data-go="${r.view}">${esc(r.btn)}</button>` : ''}</div></div>`).join('')
    : '<div class="note ok">Rien à signaler : le PC est en bon état.</div>';
  box.onclick = e => { const b = e.target.closest('[data-go]'); if (b) router.go(b.dataset.go); };
}

// ── démarrage ────────────────────────────────────────────────────────────
const TRIGGERS = { Logon: 'à l\'ouverture de session', Boot: 'au démarrage', Daily: 'chaque jour', Weekly: 'chaque semaine', Monthly: 'chaque mois', Time: 'à heure fixe', Idle: 'quand le PC est inactif', Event: 'sur un événement', Registration: 'à l\'installation', SessionStateChange: 'au changement de session' };
const genericOff = {
  run: 'Le programme ne se lancera plus tout seul. Vous pouvez toujours l\'ouvrir vous-même ; c\'est réversible.',
  folder: 'Le programme ne se lancera plus tout seul. Vous pouvez toujours l\'ouvrir vous-même ; c\'est réversible.',
  task: 'La tâche ne s\'exécutera plus. Souvent une vérification de mises à jour ; vérifiez l\'éditeur avant de couper.',
};

views.startup = async (v, live) => {
  const st = { tab: 'apps', windows: false, q: '', items: [] };
  v.innerHTML = `<h1>Démarrage</h1><p class="lead">Programmes et tâches qui se lancent tout seuls. Les couper ici fait exactement comme le Gestionnaire des tâches : rien n'est supprimé, et un clic les réactive.</p>${adminNote()}
    <div class="toolbar"><div class="chips"><span class="chip on" data-tab="apps">Applications</span><span class="chip" data-tab="tasks">Tâches planifiées</span></div>
    <input class="field grow" id="q" placeholder="Filtrer…" style="max-width:280px">${filterSelect("sf-state", "État", [["", "Tous les états"], ["on", "Activés"], ["off", "Désactivés"], ["broken", "Entrées cassées"]])}<label class="row small muted" id="winbox" hidden><input type="checkbox" id="win"> Afficher les tâches de Windows</label></div>
    <div class="list" id="list"><div class="spinner big"></div></div>`;
  const load = async () => {
    $('#list', v).innerHTML = '<div class="spinner big"></div>';
    const r = await ps('startup', { windows: st.windows });
    if (!live()) return;
    st.items = r.items || [];
    render();
  };
  const render = () => {
    const q = st.q.toLowerCase();
    let items = st.items.filter(i => (st.tab === 'apps' ? i.kind !== 'task' : i.kind === 'task') && filterMatch(q, i.name, i.command, i.company) && (!$('#sf-state', v).value || ($('#sf-state', v).value === 'on' ? i.enabled : $('#sf-state', v).value === 'off' ? !i.enabled : !i.exists)));
    items.sort((a, b) => (b.enabled - a.enabled) || a.name.localeCompare(b.name));
    $('#winbox', v).hidden = st.tab !== 'tasks';
    $('#list', v).innerHTML = items.length ? items.map(startupItem).join('') : '<div class="empty">Rien à afficher</div>';
  };
  v.addEventListener('click', async e => {
    const tab = e.target.closest('[data-tab]');
    if (tab) { st.tab = tab.dataset.tab; $$('[data-tab]', v).forEach(c => c.classList.toggle('on', c === tab)); render(); return; }
    const sw = e.target.closest('.switch[data-id]');
    const del = e.target.closest('[data-del]');
    const it = st.items.find(i => i.id === (sw || del)?.dataset[sw ? 'id' : 'del']);
    if (!it) return;
    const kb = kbOf(it);
    if (sw) {
      if (sw.classList.contains('locked')) return toast(lockReason(it, kb));
      const enable = !it.enabled;
      if (!enable && (kb?.r === 'bad' || kb?.r === 'warn' || it.microsoft) && !await confirmAction(`Couper « ${it.name} » ?`, `<p>${esc(kb?.off || 'Tâche de Windows : ne la coupez que si vous savez ce qu\'elle fait.')}</p>`, 'Couper quand même', kb?.r === 'bad')) return;
      if (!await safety()) return;
      sw.classList.add('busy');
      try {
        await ps('startup_set', { ...it, enable }, `Démarrage : « ${it.name} » ${enable ? 'réactivé' : 'coupé'}`);
        it.enabled = enable; render(); toast(enable ? 'Réactivé' : 'Coupé au démarrage (annulable dans l\'Historique)');
      } catch (err) { sw.classList.remove('busy'); toast('Échec : ' + err.message); }
    } else if (del) {
      if (!await confirmAction(`Retirer « ${it.name} » ?`, `<p>Cette entrée lance <span class="mono break">${esc(it.exe)}</span>, qui n'existe plus. Elle sera sauvegardée puis retirée (annulable dans l'Historique).</p>`, 'Retirer')) return;
      if (!await safety()) return;
      try { await ps('startup_set', { ...it, action: 'delete' }, `Démarrage : entrée cassée « ${it.name} » retirée`); st.items = st.items.filter(x => x !== it); render(); toast('Entrée retirée'); }
      catch (err) { toast('Échec : ' + err.message); }
    }
  });
  $('#q', v).oninput = e => { st.q = e.target.value; render(); };
  $('#sf-state', v).onchange = render;
  $('#win', v).onchange = e => { st.windows = e.target.checked; load(); };
  await load();
};
const kbOf = i => kbFind(i.kind === 'folder' ? 'folder' : i.kind, i.name, i.exe, `${i.product || ''} ${i.description || ''} ${i.command || ''}`);
function lockReason(it, kb) {
  if (kb?.r === 'lock') return 'Élément protégé : ' + (kb.off || 'nécessaire à Windows');
  return 'Droits administrateur nécessaires : relancez la Boîte à outils en administrateur';
}
function startupItem(i) {
  const kb = kbOf(i);
  const risk = kb?.r || (i.microsoft ? 'warn' : 'info');
  const locked = kb?.r === 'lock' || (needAdmin() && (i.hive === 'HKLM' || i.kind === 'task'));
  const sub = [i.company, i.kind === 'task' ? (i.triggers || []).map(t => TRIGGERS[t] || t).filter(Boolean).join(', ') : i.scope].filter(Boolean).join(' · ');
  const what = kb?.w || i.description || (i.kind === 'task' ? 'Tâche planifiée.' : 'Programme lancé à l\'ouverture de session.');
  return `<div class="item glass${i.enabled ? '' : ' off'}">
    <div class="ico">${esc((kb?.n || i.name || '?')[0].toUpperCase())}</div>
    <div><div class="title">${esc(i.name)}${kb && kb.n.toLowerCase() !== i.name.toLowerCase() ? `<span class="muted small">${esc(kb.n)}</span>` : ''} ${riskBadge(risk)}${i.exists ? '' : '<span class="badge bad">Programme introuvable</span>'}</div>
      <div class="sub">${esc(sub)}</div><div class="what">${esc(what)}</div>
      <div class="cons"><b>Si coupé :</b> ${esc(kb?.off || genericOff[i.kind])}</div>
      <details><summary>Détails</summary><div class="mono break small muted">${esc(i.command)}</div><div class="small muted">${esc(i.location || '')}</div></details></div>
    <div class="side"><div class="switch${i.enabled ? ' on' : ''}${locked ? ' locked' : ''}" data-id="${esc(i.id)}" title="${i.enabled ? 'Se lance au démarrage' : 'Coupé'}"></div>${i.exists ? '' : `<button class="btn small" data-del="${esc(i.id)}">Retirer</button>`}</div></div>`;
}

// ── services ─────────────────────────────────────────────────────────────
const START = { auto: 'Automatique', 'delayed-auto': 'Automatique (différé)', demand: 'Manuel', disabled: 'Désactivé' };
const startOf = s => s.start === 'Auto' ? (s.delayed ? 'delayed-auto' : 'auto') : s.start === 'Manual' ? 'demand' : s.start === 'Disabled' ? 'disabled' : s.start.toLowerCase();

views.services = async (v, live) => {
  const st = { tab: 'apps', q: '', running: false, items: [] };
  v.innerHTML = `<h1>Services</h1><p class="lead">Programmes qui tournent en arrière-plan sans fenêtre. Le plus sûr pour alléger le PC est de passer un service en <b>Manuel</b> : il ne démarre que quand un programme en a besoin. Les services vitaux de Windows sont verrouillés.</p>${adminNote()}
    <div class="toolbar"><div class="chips"><span class="chip on" data-tab="apps">Programmes installés</span><span class="chip" data-tab="win">Windows</span></div>
    <input class="field grow" id="q" placeholder="Filtrer…" style="max-width:280px">${filterSelect("svc-start", "Mode de démarrage", [["", "Tous les modes"], ["auto", "Automatique"], ["demand", "Manuel"], ["disabled", "Désactivé"]])}<label class="row small muted"><input type="checkbox" id="run"> En cours seulement</label></div>
    <div class="list" id="list"><div class="spinner big"></div></div>`;
  const render = () => {
    const q = st.q.toLowerCase();
    const items = st.items.filter(s => (st.tab === 'apps' ? !s.microsoft : s.microsoft) && (!st.running || s.state === 'Running') && filterMatch(q, s.name, s.display, s.company, s.description) && (!$('#svc-start', v).value || ($('#svc-start', v).value === 'auto' ? ['auto', 'delayed-auto'].includes(startOf(s)) : startOf(s) === $('#svc-start', v).value)))
      .sort((a, b) => ((b.state === 'Running') - (a.state === 'Running')) || a.display.localeCompare(b.display));
    $('#list', v).innerHTML = items.length ? items.slice(0, 400).map(serviceItem).join('') : '<div class="empty">Rien à afficher</div>';
  };
  const load = async () => { const r = await ps('services'); if (!live()) return; st.items = r.items || []; render(); };
  v.addEventListener('click', async e => {
    const tab = e.target.closest('[data-tab]');
    if (tab) { st.tab = tab.dataset.tab; $$('[data-tab]', v).forEach(c => c.classList.toggle('on', c === tab)); render(); return; }
    const b = e.target.closest('[data-svc-act]');
    if (!b) return;
    const s = st.items.find(x => x.name === b.dataset.name);
    const kb = kbFind('svc', s.name, s.exe, s.display);
    const act = b.dataset.svcAct;
    if (act === 'loc') { bao.call('files.reveal', { path: s.exe }); return; }
    if (act === 'web') { bao.call('open', { target: 'https://www.bing.com/search?q=' + encodeURIComponent(`service Windows "${s.name}" ${s.display}`) }); return; }
    if (act === 'restart') {
      try { await ps('service_set', { name: s.name, restart: true }); toast('Service redémarré'); } catch (err) { toast('Échec : ' + err.message); }
      return;
    }
    const stop = act === 'stop';
    if (stop && !await confirmAction(`Arrêter « ${s.display} » ?`, `<p>${esc(kb?.off || 'Le programme qui utilise ce service peut cesser de fonctionner jusqu\'au prochain démarrage du service.')}</p>`, 'Arrêter')) return;
    if (!await safety()) return;
    try { await ps('service_set', { name: s.name, [stop ? 'stop' : 'run']: true }, `Service « ${s.display} » ${stop ? 'arrêté' : 'démarré'}`); s.state = stop ? 'Stopped' : 'Running'; render(); toast(stop ? 'Service arrêté' : 'Service démarré'); }
    catch (err) { toast('Échec : ' + err.message); }
  });
  v.addEventListener('change', async e => {
    const sel = e.target.closest('select[data-name]');
    if (!sel) return;
    const s = st.items.find(x => x.name === sel.dataset.name);
    const kb = kbFind('svc', s.name, s.exe, s.display);
    const to = sel.value, from = startOf(s);
    const risky = to === 'disabled' || ((to === 'demand' || to === 'disabled') && (kb?.r === 'bad' || kb?.r === 'warn'));
    if (risky && !await confirmAction(`« ${s.display} » : ${START[to]} ?`, `<p>${esc(kb?.off || (to === 'disabled' ? 'Désactivé, ce service ne pourra plus démarrer, même si un programme en a besoin. Manuel est plus sûr.' : ''))}</p>`, START[to], kb?.r === 'bad' || to === 'disabled')) { sel.value = from; return; }
    if (!await safety()) { sel.value = from; return; }
    sel.disabled = true;
    try {
      await ps('service_set', { name: s.name, start: to }, `Service « ${s.display} » : ${START[from] || from} → ${START[to]}`);
      s.start = to === 'demand' ? 'Manual' : to === 'disabled' ? 'Disabled' : 'Auto'; s.delayed = to === 'delayed-auto';
      toast(`${s.display} : ${START[to]}`); render();
    } catch (err) { toast('Échec : ' + err.message); sel.value = from; sel.disabled = false; }
  });
  $('#q', v).oninput = e => { st.q = e.target.value; render(); };
  $('#svc-start', v).onchange = render;
  $('#run', v).onchange = e => { st.running = e.target.checked; render(); };
  await load();
};
function serviceItem(s) {
  const kb = kbFind('svc', s.name, s.exe, s.display);
  const risk = kb?.r || (s.microsoft ? 'warn' : 'info');
  const locked = risk === 'lock' || needAdmin();
  const cur = startOf(s);
  const advice = kb?.svc && kb.svc !== cur ? `<div class="small" style="color:var(--info);margin-top:4px">Conseillé : ${START[kb.svc]}</div>` : '';
  const opts = Object.entries(START).map(([k, l]) => `<option value="${k}"${k === cur ? ' selected' : ''}>${l}</option>`).join('');
  return `<div class="item glass${s.state === 'Running' ? '' : ' off'}">
    <div class="ico">${esc((s.display || s.name)[0].toUpperCase())}</div>
    <div><div class="title">${esc(s.display)} ${riskBadge(risk)} <span class="badge plain">${s.state === 'Running' ? 'En cours' : 'Arrêté'}</span>${s.restart ? '<span class="badge info" title="Windows le relance automatiquement s\'il s\'arrête">Se relance tout seul</span>' : ''}</div>
      <div class="sub">${esc([s.name, s.company].filter(Boolean).join(' · '))}</div>
      <div class="what">${esc(kb?.w || s.description || 'Service d\'un programme installé.')}</div>
      <div class="cons"><b>Si arrêté ou en manuel :</b> ${esc(kb?.off || (s.microsoft ? 'Fonction de Windows : laissez le réglage d\'origine si vous ne savez pas à quoi il sert.' : 'Il ne démarrera que si son programme le demande. Si le programme cesse de fonctionner, remettez-le en Automatique.'))}</div>${advice}
      <details><summary>Détails</summary><div class="mono break small muted">${esc(s.exe)}</div><div class="small muted">Compte : ${esc(s.account)}</div><div class="row" style="margin-top:6px"><button class="btn small" data-svc-act="loc" data-name="${esc(s.name)}">Emplacement du fichier</button><button class="btn small" data-svc-act="web" data-name="${esc(s.name)}">Rechercher sur le web</button>${!locked && s.state === 'Running' ? `<button class="btn small" data-svc-act="restart" data-name="${esc(s.name)}">Redémarrer le service</button>` : ''}</div></details></div>
    <div class="side"><select class="field" data-name="${esc(s.name)}"${locked || cur === 'boot' || cur === 'system' ? ' disabled' : ''}>${opts}</select>
      ${locked ? '' : s.state === 'Running' ? `<button class="btn small" data-svc-act="stop" data-name="${esc(s.name)}">Arrêter</button>` : cur !== 'disabled' ? `<button class="btn small" data-svc-act="start" data-name="${esc(s.name)}">Démarrer</button>` : ''}</div></div>`;
}

// ── processus ────────────────────────────────────────────────────────────
views.processes = async (v, live) => {
  const st = { sort: 'ram', items: [], q: '' };
  v.innerHTML = `<h1>Processus</h1><p class="lead">Ce qui tourne en ce moment, regroupé par programme. Terminer un processus est immédiat mais temporaire : pour qu'un programme ne revienne plus, coupez-le dans Démarrage ou Services.</p>
    <div class="toolbar"><input class="field grow" id="q" placeholder="Filtrer…" style="max-width:280px">${sizeFilter("proc-size")}<label class="row small muted"><input type="checkbox" id="proc-active"> Processeur actif</label><button class="btn" id="refresh">Actualiser</button><span class="muted small" id="total"></span></div>
    <div class="scroll-x"><table class="table"><thead><tr><th class="sort" data-s="name">Programme</th><th class="r sort" data-s="count">Nb</th><th class="r sort" data-s="ram">Mémoire</th><th class="r sort" data-s="cpu">Processeur</th><th class="hide-s">Éditeur</th><th></th></tr></thead><tbody id="rows"><tr><td colspan="6"><div class="spinner big"></div></td></tr></tbody></table></div>`;
  const render = () => {
    const q = st.q.toLowerCase();
    const items = st.items.filter(p => filterMatch(q, p.name, p.description, p.company) && p.ram >= +$('#proc-size', v).value && (!$('#proc-active', v).checked || p.cpu > 0));
    const k = st.sort;
    items.sort((a, b) => k === 'name' ? a.name.localeCompare(b.name) : b[k] - a[k]);
    $('#rows', v).innerHTML = items.slice(0, 300).map(p => {
      const kb = kbFind('proc', p.name, p.path, p.description);
      const own = kb && /^\^proc/.test(kb.m.source);
      const lock = kb?.r === 'lock';
      return `<tr><td><div class="title">${esc(kb?.n && own ? kb.n : (p.description || p.name))} <span class="muted small">${esc(p.name)}</span> ${own ? riskBadge(kb.r) : ''}</div>${kb ? `<div class="small muted">${esc(kb.w)}</div>` : ''}</td>
        <td class="r">${p.count}</td><td class="r size">${fmtSize(p.ram)}</td><td class="r">${nf1.format(p.cpu)} %</td><td class="hide-s small muted ellipsis" style="max-width:180px">${esc(p.company)}</td>
        <td class="r">${lock ? '<span class="badge lock">Protégé</span>' : `<button class="btn small" data-kill="${esc(p.name)}">Terminer</button>`}</td></tr>`;
    }).join('');
    const ram = st.items.reduce((s, p) => s + p.ram, 0);
    $('#total', v).textContent = `${st.items.length} programmes · ${fmtSize(ram)} de mémoire privée`;
  };
  const load = async () => { const r = await bao.call('procs.list'); if (!live()) return; st.items = r.items || []; render(); };
  v.addEventListener('click', async e => {
    const th = e.target.closest('th[data-s]');
    if (th) { st.sort = th.dataset.s; render(); return; }
    if (e.target.closest('#refresh')) { load(); return; }
    const b = e.target.closest('[data-kill]');
    if (!b) return;
    const p = st.items.find(x => x.name === b.dataset.kill);
    const kb = kbFind('proc', p.name, p.path, p.description);
    const own = kb && /^\^proc/.test(kb.m.source);
    const text = own ? kb.off : `Ferme ${esc(p.description || p.name)}${p.count > 1 ? ` (${p.count} processus)` : ''}. Le travail non enregistré dans ce programme est perdu.`;
    if (!await confirmAction(`Terminer « ${p.description || p.name} » ?`, `<p>${own ? esc(text) : text}</p>`, 'Terminer', kb?.r === 'bad' || kb?.r === 'warn')) return;
    try { const r = await ps('processes', { action: 'kill', name: p.name }); toast(`${r.stopped} sur ${r.total} processus terminés`); load(); }
    catch (err) { toast('Échec : ' + err.message); }
  });
  $('#q', v).oninput = e => { st.q = e.target.value; render(); };
  $('#proc-size', v).onchange = render;
  $('#proc-active', v).onchange = render;
  await load();
};

// ── nettoyage ────────────────────────────────────────────────────────────
views.clean = async (v, live, done = '') => {
  v.innerHTML = `<h1>Nettoyage</h1><p class="lead">Caches et fichiers temporaires que Windows et vos applications recréent au besoin. Les éléments cochés par défaut n'ont aucune conséquence ; les autres sont expliqués.</p>${adminNote()}${done}<div id="cats"><div class="spinner big"></div></div>`;
  const r = await bao.call('clean.analyze');
  if (!live()) return;
  const cats = r.cats;
  const groups = [...new Set(cats.map(c => c.group))];
  const box = $('#cats', v);
  box.innerHTML = groups.map(g => `<h2>${esc(g)}</h2><div class="list">${cats.filter(c => c.group === g).map(c => `
    <label class="item glass${c.locked ? ' off' : ''}"><input type="checkbox" data-id="${c.id}"${c.default && !c.locked && c.size > 0 ? ' checked' : ''}${c.locked ? ' disabled' : ''}>
      <div><div class="title">${esc(c.label)} ${c.risk === 'prudence' ? '<span class="badge warn">À lire</span>' : '<span class="badge ok">Sans risque</span>'}${c.locked ? '<span class="badge lock">Administrateur requis</span>' : ''}</div><div class="what">${esc(c.desc)}</div></div>
      <div class="side"><span class="size">${fmtSize(c.size)}</span><span class="muted small">${c.id === 'recycle' ? plural(c.count, 'élément', 'éléments') : plural(c.count, 'fichier', 'fichiers')}</span></div></label>`).join('')}</div>`).join('')
    + `<div class="card glass row sticky" style="margin-top:18px"><div class="grow"><b id="sel-size"></b> <span class="muted" id="sel-count"></span></div>${checkAll('input[data-id]', '#cats')}<button class="btn primary" id="go">Nettoyer</button></div><div id="result"></div>`;
  const update = () => {
    const ids = $$('input[data-id]:checked', box).map(i => i.dataset.id);
    const sz = cats.filter(c => ids.includes(c.id)).reduce((s, c) => s + c.size, 0);
    $('#sel-size', box).textContent = fmtSize(sz) + ' sélectionnés';
    $('#sel-count', box).textContent = `(${plural(ids.length, 'catégorie', 'catégories')})`;
    $('#go', box).disabled = !ids.length;
  };
  box.addEventListener('change', update);
  update();
  $('#go', box).onclick = async () => {
    const ids = $$('input[data-id]:checked', box).map(i => i.dataset.id);
    const risky = cats.filter(c => ids.includes(c.id) && c.risk === 'prudence');
    if (risky.length && !await confirmAction('Nettoyer ces éléments ?', `<p>À savoir avant de continuer :</p><ul>${risky.map(c => `<li><b>${esc(c.label)}</b> : ${esc(c.desc)}</li>`).join('')}</ul>`, 'Nettoyer')) return;
    const btn = $('#go', box); btn.disabled = true;
    const res = $('#result', box);
    res.innerHTML = '<div class="progress glass"><div class="spinner"></div><div id="cl-label">Nettoyage…</div></div>';
    try {
      const out = await bao.call('clean.run', { ids }, d => { const l = $('#cl-label', res); if (l) l.textContent = 'Nettoyage : ' + d.label; });
      const skipped = out.results.reduce((s, x) => s + x.skipped, 0);
      res.innerHTML = `<div class="note ok"><b>${fmtSize(out.freed)} libérés.</b> ${out.results.map(x => `${esc(x.label)} : ${fmtSize(x.freed)}`).join(' · ')}${skipped ? `<br>${plural(skipped, 'fichier gardé', 'fichiers gardés')} car utilisé${skipped > 1 ? 's' : ''} en ce moment ou trop récent${skipped > 1 ? 's' : ''} : c'est normal.` : ''}</div>`;
      toast(fmtSize(out.freed) + ' libérés');
      // tailles mises à jour, compte rendu gardé en haut de la page
      if (live()) views.clean(v, live, res.innerHTML);
    } catch (e) { res.innerHTML = `<div class="note warn">${esc(e.message)}</div>`; btn.disabled = false; }
  };
};

// ── fichiers lourds ──────────────────────────────────────────────────────
const SYSTEM_FILES = { 'pagefile.sys': 'Fichier d\'échange de Windows (mémoire virtuelle). Géré par Windows, ne pas supprimer.', 'hiberfil.sys': 'Fichier de mise en veille prolongée. Pour le retirer : Performances → Veille prolongée.', 'swapfile.sys': 'Fichier d\'échange des applications modernes. Géré par Windows.', 'memory.dmp': 'Vidage mémoire d\'un écran bleu : supprimable depuis Nettoyage → Rapports d\'erreurs.' };
function isSystemPath(p) {
  const s = p.toLowerCase();
  return /^[a-z]:\\(windows|program files|program files \(x86\)|programdata|\$recycle\.bin|system volume information|recovery)\\/.test(s) || /^[a-z]:\\[^\\]+\.sys$/.test(s) || s.includes('\\appdata\\local\\packages\\') || s.includes('\\windowsapps\\');
}

// views.large : voir disk.js (analyse façon WizTree)

// ── fichiers fantômes ────────────────────────────────────────────────────
views.ghosts = async (v, live) => {
  v.innerHTML = `<h1>Fichiers fantômes</h1><p class="lead">Ce qui reste derrière les programmes : raccourcis morts, dossiers vides, anciennes versions, installateurs oubliés, restes de désinstallation et doublons. Tout part dans la Corbeille, récupérable.</p>
    <div id="sections"></div><h2>Doublons</h2><div class="card glass"><div class="row"><div class="grow">Fichiers identiques (contenu comparé, pas seulement le nom) de plus de 1 Mo dans Bureau, Documents, Téléchargements, Images, Vidéos et Musique.</div><button class="btn" id="dupes">Chercher les doublons</button></div><div id="dupes-out"></div></div>`;
  const sections = [
    { id: 'shortcuts', t: 'Raccourcis cassés', d: 'Raccourcis du Bureau, du menu Démarrer et de la barre des tâches vers des programmes qui n\'existent plus.', load: async () => (await ps('shortcuts')).items.map(i => ({ path: i.path, label: baseName(i.path).replace(/\.lnk$/i, ''), sub: `${i.location} → ${i.target}`, checked: true })) },
    { id: 'empty', t: 'Dossiers vides', d: 'Dossiers vides posés directement dans Bureau, Documents, Téléchargements, Images, Vidéos ou Musique. Ceux qui sont plus profonds ne sont pas proposés : ils appartiennent souvent à un jeu ou un logiciel qui les attend.', action: 'dirs', load: async () => (await bao.call('scan.empty', {})).dirs.map(i => ({ path: i.path, label: baseName(i.path), sub: i.path, checked: false })) },
    { id: 'versions', t: 'Anciennes versions d\'applications', d: 'Discord, Teams, Slack, GitHub Desktop… gardent leurs anciennes versions après une mise à jour. Seule la plus récente sert.', load: async () => (await bao.call('ghosts.versions')).items.map(i => ({ path: i.path, label: `${i.app} — ${baseName(i.path)}`, sub: i.path, size: i.size, checked: true })) },
    { id: 'downloads', t: 'Installateurs et archives oubliés', d: 'Fichiers .exe, .msi, .iso, .zip… de plus de 30 jours dans Téléchargements. Vérifiez avant : certains peuvent servir à réinstaller un logiciel.', load: async () => (await bao.call('ghosts.downloads')).items.map(i => ({ path: i.path, label: baseName(i.path), sub: `il y a ${i.age} jours`, size: i.size, checked: false })), sizes: [[0, 'Toutes les tailles'], [10e6, 'Plus de 10 Mo'], [100e6, 'Plus de 100 Mo'], [1e9, 'Plus de 1 Go']] },
    { id: 'leftovers', t: 'Restes de programmes désinstallés', d: 'Dossiers dans Program Files, ProgramData et AppData qui ne correspondent à aucun programme installé et n\'ont pas servi depuis 60 jours. Détection par le nom : vérifiez chaque dossier avant (bouton Ouvrir).', warn: true, load: async () => {
      const items = (await ps('system', { action: 'leftovers' })).items;
      const sizes = items.length ? await bao.call('files.sizes', { paths: items.map(i => i.path) }) : [];
      return items.map((i, k) => ({ path: i.path, label: baseName(i.path), sub: `${i.path} · modifié le ${fmtDate(i.modified)}`, size: sizes[k] || 0, checked: false }));
    } },
  ];
  const box = $('#sections', v);
  box.innerHTML = sections.map(s => `<h2>${esc(s.t)}</h2><div class="card glass" id="g-${s.id}"><div class="muted small" style="margin-bottom:8px">${esc(s.d)}</div><div class="body"><div class="row"><div class="spinner"></div><span class="muted">Recherche…</span></div></div></div>`).join('');
  const show = (s, items) => {
    const card = $(`#g-${s.id} .body`, box);
    if (!items.length) { card.innerHTML = '<div class="muted">Rien trouvé.</div>'; return; }
    s.items = items;
    // installateurs et archives : filtre par taille, les éléments masqués sont décochés
    const min = s.sizes ? s.min || 0 : 0;
    const shown = items.map((it, i) => [it, i]).filter(([it]) => (it.size || 0) >= min);
    if (min) for (const it of items) if ((it.size || 0) < min) it.checked = false;
    const filters = s.sizes ? `<div class="toolbar" style="margin-bottom:8px"><div class="chips">${s.sizes.map(([b, l]) => `<span class="chip${min === b ? ' on' : ''}" data-min="${b}" data-sec="${s.id}">${l}</span>`).join('')}</div><span class="muted small">${plural(shown.length, 'fichier', 'fichiers')} · ${fmtSize(shown.reduce((t, [it]) => t + (it.size || 0), 0))}</span></div>` : '';
    card.innerHTML = `${s.warn ? '<div class="note warn">À vérifier : ne cochez que les dossiers que vous reconnaissez comme inutiles.</div>' : ''}${filters}${shown.length ? '' : '<div class="muted">Aucun fichier de cette taille.</div>'}<div class="scroll-x"><table class="table"><tbody>${shown.map(([it, i]) => `<tr><td style="width:28px"><input type="checkbox" data-s="${s.id}" data-i="${i}"${it.checked ? ' checked' : ''}></td><td class="path"><div class="ellipsis"><b>${esc(it.label)}</b></div><div class="small muted ellipsis" title="${esc(it.sub)}">${esc(it.sub)}</div></td><td class="r size">${it.size != null ? fmtSize(it.size) : ''}</td><td class="r"><button class="btn small" data-reveal="${esc(it.path)}">Ouvrir</button></td></tr>`).join('')}</tbody></table></div>
      <div class="row end" style="margin-top:10px">${checkAll(`input[data-s="${s.id}"]`, `#g-${s.id}`)}<button class="btn danger small" data-go="${s.id}">${s.action === 'dirs' ? 'Supprimer les dossiers vides cochés' : 'Mettre les éléments cochés à la Corbeille'}</button></div>`;
  };
  for (const s of sections) s.load().then(items => live() && show(s, items)).catch(e => { if (live()) $(`#g-${s.id} .body`, box).innerHTML = `<div class="note warn">${esc(e.message)}</div>`; });
  v.addEventListener('click', async e => {
    const rv = e.target.closest('[data-reveal]'); if (rv) { bao.call('files.reveal', { path: rv.dataset.reveal }); return; }
    const mn = e.target.closest('[data-min]');
    if (mn) {
      const s = sections.find(x => x.id === mn.dataset.sec);
      for (const i of $$(`input[data-s="${s.id}"]`, box)) s.items[+i.dataset.i].checked = i.checked;
      s.min = +mn.dataset.min; show(s, s.items); return;
    }
    const go = e.target.closest('[data-go]');
    if (go) {
      const s = sections.find(x => x.id === go.dataset.go);
      const picked = $$(`input[data-s="${s.id}"]:checked`, box).map(i => s.items[+i.dataset.i]);
      if (!picked.length) return toast('Rien de coché');
      if (!await confirmAction(`${s.t} : ${plural(picked.length, 'élément', 'éléments')}`, `<p>${s.action === 'dirs' ? 'Ces dossiers vides seront supprimés (uniquement s\'ils sont toujours vides).' : 'Ils vont dans la Corbeille et restent récupérables.'}</p><div class="console">${picked.map(p => esc(p.path)).join('\n')}</div>`, 'Continuer', true)) return;
      const r = s.action === 'dirs' ? await bao.call('files.delete_dirs', { paths: picked.map(p => p.path) }) : await bao.call('files.recycle', { paths: picked.map(p => p.path), what: s.t.toLowerCase() });
      const ok = r.recycled ?? r.removed;
      toast(`${ok} élément(s) traités${r.failed ? `, ${r.failed} en échec` : ''}`);
      const done = new Set(picked.map(p => p.path));
      show(s, s.items.filter(i => !done.has(i.path) || r.failed));
    }
    if (e.target.closest('#dupes')) dupes(v);
  });
};
async function dupes(v) {
  const out = $('#dupes-out', v);
  out.innerHTML = '<div class="progress"><div class="spinner"></div><div id="dp">Recherche des fichiers…</div><button class="btn small" id="dstop">Arrêter</button></div>';
  const job = bao.call('scan.dupes', {}, d => { const l = $('#dp', out); if (l && d.phase === 'hash') l.textContent = `Comparaison du contenu… ${d.done} / ${d.total} groupes`; });
  $('#dstop', out).onclick = () => bao.cancel(job);
  router.cleanup.push(() => bao.cancel(job));
  const r = await job;
  if (!r.groups.length) { out.innerHTML = `<div class="muted" style="margin-top:10px">Aucun doublon parmi ${nf0.format(r.scanned)} fichiers.</div>`; return; }
  const waste = r.groups.reduce((s, g) => s + g.size * (g.files.length - 1), 0);
  // la copie la plus ancienne (l'originale, en général) est gardée
  r.groups.forEach(g => g.files.sort((a, b) => a.mtime - b.mtime));
  out.innerHTML = `<div class="note info" style="margin-top:10px">${plural(r.groups.length, 'groupe', 'groupes')} de fichiers identiques · ${fmtSize(waste)} occupés en double. La plus ancienne copie de chaque groupe est gardée ; les autres sont cochées.</div>
    ${r.groups.slice(0, 200).map((g, gi) => `<div style="margin:10px 0"><div class="small muted">${fmtSize(g.size)} × ${g.files.length}</div>${g.files.map((f, fi) => `<label class="row small" style="padding:3px 0"><input type="checkbox" data-g="${gi}" data-f="${fi}"${fi ? ' checked' : ''}><span class="grow ellipsis" title="${esc(f.path)}">${esc(f.path)}</span><span class="muted">${fmtDate(f.mtime)}</span></label>`).join('')}</div>`).join('')}
    <div class="row end">${checkAll('input[data-g]', '#dupes-out')}<button class="btn danger small" id="dgo">Mettre les copies cochées à la Corbeille</button></div>`;
  $('#dgo', out).onclick = async () => {
    const picked = $$('input[data-g]:checked', out).map(i => r.groups[+i.dataset.g].files[+i.dataset.f].path);
    // jamais toutes les copies d'un même groupe
    const whole = r.groups.findIndex((g, gi) => g.files.every((_, fi) => $(`input[data-g="${gi}"][data-f="${fi}"]`, out)?.checked));
    if (whole >= 0) return toast('Gardez au moins une copie de chaque fichier');
    if (!picked.length) return toast('Rien de coché');
    if (!await confirmAction(`Mettre ${plural(picked.length, 'copie', 'copies')} à la Corbeille ?`, '<p>Une copie de chaque fichier est gardée. Les autres restent récupérables dans la Corbeille.</p>', 'Continuer', true)) return;
    const res = await bao.call('files.recycle', { paths: picked, what: 'doublons' });
    toast(`${res.recycled} copie(s) dans la Corbeille`);
    dupes(v);
  };
}

// ── performances et réglages ─────────────────────────────────────────────
const sameVal = (a, b) => a === b || (a != null && b != null && String(a) === String(b));
const WU_UX = 'HKLM:\\SOFTWARE\\Microsoft\\WindowsUpdate\\UX\\Settings';
// valeurs écrites par Paramètres → Windows Update → Suspendre les mises à jour
const PAUSE_KEYS = ['PauseUpdatesStartTime', 'PauseUpdatesExpiryTime', 'PauseFeatureUpdatesStartTime', 'PauseFeatureUpdatesEndTime', 'PauseQualityUpdatesStartTime', 'PauseQualityUpdatesEndTime'];

views.perf = (v, live) => tweakPage(v, live, 'perf');
views.tweaks = (v, live) => tweakPage(v, live, 'tweaks');
views.perso = (v, live) => tweakPage(v, live, 'perso');
const PAGE_TEXT = {
  perf: ['Performances', 'Jeux, vitesse, mémoire, mises à jour et alimentation.'],
  perso: ['Personnalisation', 'Barre des tâches (transparente, floutée ou colorée), menu Démarrer, bureau, couleurs, souris et fenêtres.'],
  tweaks: ['Réglages', 'Explorateur (fichiers cachés, extensions, volet de navigation…), confidentialité, publicités, clavier et système.'],
};

async function tweakPage(v, live, page) {
  const perf = page === 'perf';
  const groups = TWEAK_PAGES[page];
  const list = TWEAKS.filter(t => groups.includes(t.group));
  const perso = page === 'perso';
  v.innerHTML = `<h1>${PAGE_TEXT[page][0]}</h1><p class="lead">${PAGE_TEXT[page][1]} Uniquement des réglages documentés, à l'effet réel, et réversibles en un clic.${perf ? ' Les « astuces » sans effet mesurable sont listées en bas, avec la raison de leur absence.' : ''}</p>${adminNote()}<div id="explorer-note"></div><div id="tw"><div class="spinner big"></div></div>`;
  const items = list.flatMap(t => (t.reg || []).map(r => ({ path: r.path, name: r.name })));
  if (perf) items.push(...PAUSE_KEYS.map(name => ({ path: WU_UX, name })));
  const svcNames = list.filter(t => t.svc).map(t => t.svc.name);
  let [cur, svcs, sys, power, status] = await Promise.all([
    ps('reg', { action: 'get', items }),
    svcNames.length ? ps('repair', { action: 'svc', names: svcNames }).catch(() => ({ services: {} })) : { services: {} },
    perf ? ps('system').catch(() => null) : null,
    perf ? ps('power').catch(() => null) : null,
    perso ? ps('repair', { action: 'status' }).catch(() => null) : null,
  ]);
  let bar = perso ? await bao.call('taskbar.get').catch(() => null) : null;
  if (!live()) return;
  const val = new Map(cur.values.map(x => [x.path + '|' + x.name, x.exists ? x.value : null]));
  const svc = svcs.services || {};
  // valeur absente : Windows applique son réglage par défaut (def)
  const isOn = t => t.svc ? svc[t.svc.name]?.start === t.svc.on : t.reg.every(r => sameVal(val.get(r.path + '|' + r.name) ?? r.def ?? null, r.on));
  const box = $('#tw', v);
  const row = t => {
    const on = isOn(t), locked = t.admin && needAdmin();
    return `<div class="item glass"><div class="ico">${on ? '✓' : ''}</div><div><div class="title">${esc(t.t)} ${riskBadge(t.r)}${t.restart ? '<span class="badge plain">Après redémarrage</span>' : ''}${t.explorer ? '<span class="badge plain">Après redémarrage de l\'Explorateur</span>' : ''}${locked ? '<span class="badge lock">Administrateur requis</span>' : ''}</div><div class="what">${esc(t.d)}</div><div class="cons"><b>Effet :</b> ${esc(t.effect)}</div></div>
      <div class="side"><div class="switch${on ? ' on' : ''}${locked ? ' locked' : ''}" data-tw="${t.id}"></div></div></div>`;
  };
  const pauseItem = () => {
    const end = new Date(val.get(WU_UX + '|PauseUpdatesExpiryTime') || 0);
    const paused = end > new Date();
    const lock = needAdmin();
    return `<div class="item glass"><div class="ico">${paused ? '⏸' : ''}</div><div><div class="title">Suspendre les mises à jour ${riskBadge('info')}${lock ? '<span class="badge lock">Administrateur requis</span>' : ''}</div><div class="what">${paused ? `Windows Update est en pause jusqu'au <b>${fmtDate(end)}</b>.` : 'Repousse toutes les mises à jour de une à cinq semaines (par exemple avant un tournoi ou un déplacement), comme dans les Paramètres.'}</div><div class="cons"><b>Effet :</b> aucune mise à jour, y compris de sécurité, pendant la pause. Windows les installe toutes à la fin de la pause.</div></div>
      <div class="side">${paused ? `<button class="btn small" id="resume"${lock ? ' disabled' : ''}>Reprendre</button>` : `<select class="field" id="pause-weeks"${lock ? ' disabled' : ''}>${[1, 2, 3, 4, 5].map(n => `<option value="${n}">${plural(n, 'semaine', 'semaines')}</option>`).join('')}</select><button class="btn small" id="pause"${lock ? ' disabled' : ''}>Suspendre</button>`}</div></div>`;
  };
  const desktopItems = () => `<div class="item glass"><div class="ico">${status.godmode ? '✓' : ''}</div><div><div class="title">« Mode Dieu » sur le bureau ${riskBadge('ok')}</div><div class="what">Dossier spécial de Windows qui rassemble plus de 200 réglages du Panneau de configuration sur une seule page.</div><div class="cons"><b>Effet :</b> un dossier « Mode Dieu » apparaît sur le bureau ; le supprimer suffit à l'enlever.</div></div><div class="side"><div class="switch${status.godmode ? ' on' : ''}" data-god></div></div></div>
    <div class="item glass"><div class="ico">🖼</div><div><div class="title">Récupérer les images « Windows à la une »</div><div class="what">Copie les photos affichées sur l'écran de verrouillage et le bureau par Windows à la une dans Images\\Windows à la une, en .jpg.</div></div><div class="side"><button class="btn small" id="spotlight">Récupérer</button></div></div>
    <div class="item glass"><div class="ico">🔒</div><div><div class="title">Image de l'écran de verrouillage</div><div class="what">Choisir une photo, un diaporama d'un dossier ou Windows à la une.</div></div><div class="side"><button class="btn small" data-open-target="ms-settings:lockscreen">Paramètres</button></div></div>`;
  const powerSection = () => {
    if (!power?.plans) return '';
    const hasUltimate = power.plans.some(p => /ultime|ultimate/i.test(p.name));
    return `<h2>Alimentation</h2><div class="list">${power.plans.map(p => `<div class="item glass${p.active ? '' : ' off'}"><div class="ico">${p.active ? '⚡' : ''}</div><div><div class="title">${esc(p.name)} ${p.active ? '<span class="badge ok">Actif</span>' : ''}</div><div class="sub mono">${esc(p.guid)}</div></div><div class="side">${p.active ? '' : `<button class="btn small" data-plan="${esc(p.guid)}" data-name="${esc(p.name)}"${needAdmin() ? ' disabled' : ''}>Activer</button>`}</div></div>`).join('')}
      ${hasUltimate ? '' : `<div class="item glass"><div class="ico">+</div><div><div class="title">Mode « Performances ultimes » ${riskBadge('info')}</div><div class="what">Mode masqué de Windows qui supprime les micro-économies d'énergie du processeur et des disques.</div><div class="cons"><b>Effet :</b> sur un PC de bureau récent, aucun gain mesurable en jeu et une consommation plus élevée au repos. Déconseillé sur portable (autonomie). « Utilisation normale » convient à presque tous les usages.</div></div><div class="side"><button class="btn small" id="ultimate"${needAdmin() ? ' disabled' : ''}>Ajouter et activer</button></div></div>`}</div>`;
  };
  const BAR_MODES = [['normal', 'Normale (Windows)'], ['clear', 'Transparente'], ['blur', 'Floutée'], ['acrylic', 'Verre dépoli'], ['color', 'Couleur']];
  const taskbarSection = () => {
    if (!bar) return '';
    const c = bar.config, hex = (c.color || '#00000040').slice(0, 7), alpha = parseInt((c.color || '#00000040').slice(7, 9) || 'ff', 16);
    return `<h2>Barre des tâches transparente</h2><div class="card glass"><div class="muted small" style="margin-bottom:10px">Comme TranslucentTB : la Boîte à outils applique l'effet à la barre des tâches de chaque écran, depuis un petit processus léger (moins de 2 Mo de mémoire) lancé avec Windows. Rien n'est modifié dans Windows lui-même : « Normale » remet tout comme avant.</div>
      <div class="chips" id="bar-modes">${BAR_MODES.map(([k, l]) => `<span class="chip${c.mode === k ? ' on' : ''}" data-bar="${k}">${l}</span>`).join('')}</div>
      <div class="row" style="margin-top:12px;flex-wrap:wrap">${c.mode === 'color' || c.mode === 'acrylic' ? `<label class="row small">Teinte <input type="color" id="bar-color" value="${esc(hex)}"></label><label class="row small">Opacité <input type="range" id="bar-alpha" min="0" max="255" value="${alpha}"></label>` : ''}
        ${c.mode !== 'normal' ? `<label class="row small">Quand une fenêtre est agrandie <select class="field" id="bar-max"><option value="">même aspect</option>${BAR_MODES.filter(m => m[0] !== c.mode).map(([k, l]) => `<option value="${k}"${c.maximized === k ? ' selected' : ''}>${l}</option>`).join('')}</select></label>` : ''}</div>
      <div class="small" style="margin-top:10px;color:var(${bar.running ? '--ok' : '--dim'})">${bar.running ? '● Effet actif' : c.mode === 'normal' ? 'Aspect d\'origine de Windows' : '○ En cours de démarrage…'}</div>
      <div class="muted small" style="margin-top:6px">Menu Démarrer transparent : Windows ne le permet qu'avec ses propres « effets de transparence » (réglage ci-dessous dans Couleurs, ou Paramètres → Personnalisation → Couleurs). Les outils qui vont plus loin, comme Windhawk, modifient le code de l'Explorateur en mémoire : volontairement non repris ici.</div></div>`;
  };
  const saveBar = async patch => {
    const config = { ...bar.config, ...patch };
    try { await bao.call('taskbar.set', { config }); bar.config = config; await new Promise(r => setTimeout(r, 600)); bar = await bao.call('taskbar.get'); render(); }
    catch (err) { toast('Échec : ' + err.message); }
  };
  const render = () => {
    box.innerHTML = (perso ? taskbarSection() : '') + groups.map(g => {
      const ts = list.filter(t => t.group === g && !(t.svc && !svc[t.svc.name]));
      const extra = g === 'Démarrage et stockage' && sys ? hiberItem(sys) : g === 'Mises à jour' ? pauseItem() : g === 'Bureau et apparence' && status ? desktopItems() : '';
      return `<h2>${esc(g)}</h2><div class="list">${ts.map(row).join('')}${extra}</div>`;
    }).join('')
      + (perf ? powerSection() + `<h2>Volontairement absents</h2><div class="card glass">${PLACEBO.map(([a, b]) => `<div style="margin-bottom:8px"><b>${esc(a)}</b><div class="muted small">${esc(b)}</div></div>`).join('')}</div>` : '');
  };
  const explorerNote = () => { $('#explorer-note', v).innerHTML = '<div class="note info">Redémarrez l\'Explorateur pour voir le changement (la barre des tâches disparaît une seconde ; les fenêtres de l\'Explorateur ouvertes se ferment). <button class="btn small" id="restart-explorer">Redémarrer l\'Explorateur</button></div>'; };
  render();
  v.addEventListener('change', e => {
    if (e.target.id === 'bar-color' || e.target.id === 'bar-alpha') {
      const a = (+$('#bar-alpha', v).value).toString(16).padStart(2, '0');
      saveBar({ color: $('#bar-color', v).value + a });
    }
    if (e.target.id === 'bar-max') saveBar({ maximized: e.target.value });
  });
  v.addEventListener('click', async e => {
    const open = e.target.closest('[data-open-target]'); if (open) { bao.call('open', { target: open.dataset.openTarget }); return; }
    const bm =e.target.closest('[data-bar]'); if (bm) { saveBar({ mode: bm.dataset.bar }); return; }
    if (e.target.closest('#restart-explorer')) {
      try { await ps('repair', { action: 'explorer' }); $('#explorer-note', v).innerHTML = ''; toast('Explorateur redémarré'); } catch (err) { toast('Échec : ' + err.message); }
      return;
    }
    const plan = e.target.closest('[data-plan]');
    if (plan) {
      if (!await safety()) return;
      try { await ps('power', { action: 'set', guid: plan.dataset.plan }, `Mode d'alimentation : ${plan.dataset.name}`); power = await ps('power'); render(); toast('Mode d\'alimentation changé'); } catch (err) { toast('Échec : ' + err.message); }
      return;
    }
    if (e.target.closest('#ultimate')) {
      if (!await confirmAction('Ajouter « Performances ultimes » ?', '<p>Le mode est ajouté et activé. Il augmente la consommation au repos sans gain mesurable en jeu sur un PC de bureau récent. Vous pouvez revenir à « Utilisation normale » ici à tout moment, ou l\'annuler depuis l\'Historique.</p>', 'Ajouter')) return;
      if (!await safety()) return;
      try { await ps('power', { action: 'ultimate' }, 'Mode Performances ultimes ajouté'); power = await ps('power'); render(); toast('Mode ajouté et activé'); } catch (err) { toast('Échec : ' + err.message); }
      return;
    }
    if (e.target.closest('#pause') || e.target.closest('#resume')) {
      const resume = !!e.target.closest('#resume');
      const weeks = resume ? 0 : +$('#pause-weeks', v).value;
      const iso = d => d.toISOString().replace(/\.\d+Z$/, 'Z');
      const now = new Date(), end = new Date(Date.now() + weeks * 7 * 864e5);
      const items = PAUSE_KEYS.map(name => ({ path: WU_UX, name, type: 'String', value: resume ? null : /Start/.test(name) ? iso(now) : iso(end) }));
      if (!resume && !await safety()) return;
      try {
        await ps('reg', { action: 'set', items }, resume ? 'Windows Update repris' : `Windows Update en pause jusqu'au ${fmtDate(end)}`);
        for (const i of items) val.set(WU_UX + '|' + i.name, i.value);
        render(); toast(resume ? 'Mises à jour reprises' : 'Mises à jour suspendues');
      } catch (err) { toast('Échec : ' + err.message); }
      return;
    }
    if (e.target.closest('#spotlight')) {
      try { const r = await ps('repair', { action: 'spotlight' }); toast(r.copied ? `${plural(r.copied, 'image copiée', 'images copiées')}` : 'Aucune nouvelle image'); bao.call('files.reveal', { path: r.folder }); } catch (err) { toast('Échec : ' + err.message); }
      return;
    }
    const sw = e.target.closest('.switch');
    if (!sw || sw.classList.contains('busy')) return;
    if (sw.classList.contains('locked')) return toast('Droits administrateur nécessaires');
    if (sw.dataset.god !== undefined) {
      const on = !status.godmode;
      try { await ps('repair', on ? { action: 'godmode' } : { action: 'godmode', remove: true }, on ? 'Mode Dieu ajouté au bureau' : undefined); status.godmode = on; render(); toast(on ? 'Dossier « Mode Dieu » créé sur le bureau' : 'Dossier retiré'); } catch (err) { toast('Échec : ' + err.message); }
      return;
    }
    if (sw.dataset.hiber !== undefined) {
      const on = !sw.classList.contains('on');
      if (!on && !await confirmAction('Supprimer le fichier de veille prolongée ?', '<p>La veille prolongée et le démarrage rapide seront désactivés. À éviter sur un portable que vous laissez souvent en veille prolongée.</p>', 'Désactiver')) return;
      if (!await safety()) return;
      sw.classList.add('busy');
      try { await ps('system', { action: 'hibernate', on }, `Veille prolongée ${on ? 'activée' : 'désactivée'}`); sys.hiberfil = on ? 1 : 0; toast('Fait'); render(); } catch (err) { toast('Échec : ' + err.message); sw.classList.remove('busy'); }
      return;
    }
    const t = TWEAKS.find(x => x.id === sw.dataset.tw);
    const on = !isOn(t);
    if (on && t.r !== 'ok' && !await confirmAction(t.t, `<p>${esc(t.effect)}</p>`, 'Appliquer', t.r === 'bad')) return;
    if (!await safety()) return;
    sw.classList.add('busy');
    const title = `${on ? 'Appliqué' : 'Retiré'} : ${t.t}`;
    try {
      if (t.svc) {
        const to = on ? t.svc.on : t.svc.off;
        await ps('service_set', { name: t.svc.name, start: to, stop: to === 'disabled', run: to !== 'disabled' }, title);
        svc[t.svc.name].start = to;
      } else {
        await ps('reg', { action: 'set', items: t.reg.map(r => ({ path: r.path, name: r.name, type: r.type, value: on ? r.on : r.off, dropKey: r.dropKey })) }, title);
        for (const r of t.reg) val.set(r.path + '|' + r.name, on ? r.on : r.off);
      }
      toast(on ? 'Appliqué' + (t.restart ? ' (effet après redémarrage)' : '') : 'Réglage d\'origine remis');
      if (t.explorer) explorerNote();
      if (t.broadcast) ps('personal', { action: 'broadcast' }).catch(() => { });
      render();
    } catch (err) { toast('Échec : ' + err.message); sw.classList.remove('busy'); }
  });
}
function hiberItem(sys) {
  const on = sys.hiberfil > 0;
  return `<div class="item glass"><div class="ico">${on ? '✓' : ''}</div><div><div class="title">Veille prolongée ${riskBadge('info')}${needAdmin() ? '<span class="badge lock">Administrateur requis</span>' : ''}</div><div class="what">Le fichier hiberfil.sys ${on ? `occupe ${fmtSize(sys.hiberfil)}` : 'est absent'} sur le disque système. Il sert à la veille prolongée et au démarrage rapide.</div><div class="cons"><b>Désactivée :</b> espace disque récupéré ; plus de veille prolongée ni de démarrage rapide. Utile sur un PC de bureau qui ne s'en sert pas.</div></div><div class="side"><div class="switch${on ? ' on' : ''}${needAdmin() ? ' locked' : ''}" data-hiber></div></div></div>`;
}

// ── outils ───────────────────────────────────────────────────────────────
views.tools = async (v, live) => {
  v.innerHTML = `<h1>Santé et réparation</h1><p class="lead">Réparation de Windows, santé et optimisation des disques, Windows Update, caches, registre, réseau. Les outils longs affichent leur progression ; vous pouvez continuer à utiliser le PC.</p>${adminNote()}
    <h2>Points de restauration</h2><div class="card glass" id="restore"><div class="spinner"></div></div>
    <h2>Disques</h2><div id="disks"><div class="spinner"></div></div>
    <h2>Réparer Windows</h2><div class="cards">
      ${toolCard('sfc', 'Vérifier les fichiers système (SFC)', 'Compare les fichiers de Windows à leur version d\'origine et répare ceux qui sont abîmés. Environ 10 à 20 minutes.', 'Lancer')}
      ${toolCard('dism_restore', 'Réparer l\'image de Windows (DISM)', 'Répare la réserve de fichiers dont SFC se sert, en téléchargeant les originaux chez Microsoft. À faire si SFC n\'arrive pas à tout réparer. 10 à 30 minutes.', 'Lancer')}
      ${toolCard('dism_analyze', 'Composants Windows (WinSxS)', 'Analyse les anciennes versions de composants gardées après les mises à jour, puis les retire (aucune mise à jour installée n\'est désinstallée).', 'Analyser', 'dism_cleanup', 'Nettoyer')}
      ${repCard('wureset', 'Réparer Windows Update', 'Quand les mises à jour échouent en boucle ou restent bloquées : arrête Windows Update, met de côté son cache (dossiers renommés en .bak) et le relance. L\'historique des mises à jour affiché dans les Paramètres repart de zéro.', 'Réparer', true)}
    </div>
    <h2>Entretien</h2><div class="cards">
      ${repCard('gpu', 'Redémarrer le pilote graphique', 'Écran figé, noir ou artefacts après un jeu : relance le pilote sans redémarrer le PC (comme Win+Ctrl+Maj+B). L\'écran clignote une seconde.', 'Redémarrer')}
      ${repCard('iconcache', 'Reconstruire le cache des icônes', 'Icônes blanches, fausses ou d\'anciens programmes : le cache est vidé et l\'Explorateur redémarré (ses fenêtres ouvertes se ferment).', 'Reconstruire')}
      ${repCard('explorer', 'Redémarrer l\'Explorateur', 'Barre des tâches ou menu Démarrer bloqués, ou après un réglage d\'affichage. Les fenêtres de l\'Explorateur ouvertes se ferment.', 'Redémarrer')}
      ${repCard('storecache', 'Vider le cache du Microsoft Store', 'Quand le Store n\'affiche plus rien ou ne télécharge plus. Le Store s\'ouvre une fois terminé.', 'Vider')}
      ${repCard('history', 'Effacer l\'historique de l\'Explorateur', 'Fichiers récents, listes de raccourcis, chemins tapés, historique de recherche et de la boîte Exécuter. Vos fichiers ne sont pas touchés.', 'Effacer')}
      ${repCard('battery', 'Rapport de batterie', 'Usure de la batterie d\'un portable (capacité actuelle comparée à l\'origine) et historique d\'autonomie, dans le navigateur.', 'Générer', true)}
    </div>
    <h2>Registre</h2><div class="card glass" id="reg"><div class="note info">Le registre n'a pas besoin d'être « nettoyé » pour que le PC aille plus vite : c'est un mythe des logiciels d'optimisation. Seules les entrées orphelines <b>certaines</b> sont proposées ici (programme ou fichier visé introuvable), sauvegardées avant suppression et annulables.</div><button class="btn" id="reg-scan"${needAdmin() ? ' disabled' : ''}>Chercher les entrées orphelines</button><div id="reg-out"></div></div>
    <h2>Réseau</h2><div class="cards">
      ${toolCard('flushdns', 'Vider le cache DNS', 'Utile si un site ne s\'affiche plus après un changement d\'adresse ou de box. Sans conséquence.', 'Vider')}
      <div class="card glass" id="dns"><h3>Serveurs DNS</h3><div class="muted small">Chargement…</div></div>
      ${toolCard('iprenew', 'Renouveler l\'adresse IP', 'Redemande une adresse à la box. Utile après un changement de box ou un « réseau non identifié ». Coupure d\'une à deux secondes.', 'Renouveler')}
      ${toolCard('winsock', 'Réinitialiser la pile réseau (Winsock)', 'En dernier recours si Internet ne marche plus alors que la box fonctionne. Redémarrage nécessaire ; les VPN et certains logiciels réseau peuvent devoir être réinstallés.', 'Réinitialiser')}
      ${toolCard('ipreset', 'Réinitialiser TCP/IP', 'Complète Winsock : remet les réglages IP d\'origine. Une adresse IP ou des DNS fixes réglés à la main sont perdus. Redémarrage nécessaire.', 'Réinitialiser')}
    </div>
    <h2>Diagnostics de Windows</h2><div class="card glass"><div class="chips">
      <span class="chip" data-open-target="reliability">Moniteur de fiabilité (historique des plantages)</span>
      <span class="chip" data-open-target="mdsched.exe">Diagnostic de la mémoire (redémarre le PC)</span>
      <span class="chip" data-open-target="devmgmt.msc">Gestionnaire de périphériques</span>
      <span class="chip" data-open-target="ms-settings:storagesense">Stockage</span>
      <span class="chip" data-open-target="cleanmgr.exe">Nettoyage de disque (Windows.old)</span>
      <span class="chip" data-open-target="ms-settings:windowsupdate">Windows Update</span>
      <span class="chip" data-open-target="ms-settings:windowsdefender">Sécurité Windows</span>
      <span class="chip" data-open-target="rstrui.exe">Restauration du système</span></div></div>`;
  v.addEventListener('click', async e => {
    const open = e.target.closest('[data-open-target]'); if (open) { bao.call('open', { target: open.dataset.openTarget }); return; }
    const rep = e.target.closest('[data-rep]'); if (rep) { runRepair(rep.dataset.rep, rep.closest('.card').querySelector('.tool-out')); return; }
    const t = e.target.closest('[data-tool]'); if (t) runTool(t.dataset.tool, t.dataset.drive, t.closest('.card, .item').querySelector('.tool-out') || t.closest('.card'));
    if (e.target.closest('#reg-scan')) regScan(v);
    if (e.target.closest('#rp-create')) createRestore(v, false);
    if (e.target.closest('#rp-enable')) createRestore(v, true);
  });
  loadRestore(v, live);
  loadDisks(v, live);
  loadDns(v, live);
};
const DNS = [
  ['auto', 'Automatique (ceux de la box)', [], 'Réglage d\'origine.'],
  ['cloudflare', 'Cloudflare', ['1.1.1.1', '1.0.0.1'], 'Le plus rapide en moyenne, respect de la vie privée.'],
  ['google', 'Google', ['8.8.8.8', '8.8.4.4'], 'Très fiable.'],
  ['quad9', 'Quad9', ['9.9.9.9', '149.112.112.112'], 'Bloque les sites malveillants connus.'],
  ['adguard', 'AdGuard', ['94.140.14.14', '94.140.15.15'], 'Bloque aussi les publicités et pisteurs sur tout le PC.'],
  ['cloudflare-family', 'Cloudflare Famille', ['1.1.1.3', '1.0.0.3'], 'Bloque les sites malveillants et pour adultes.'],
];
async function loadDns(v, live) {
  const box = $('#dns', v);
  const r = await ps('personal', { action: 'dns' }).catch(e => ({ error: e.message }));
  if (!live()) return;
  if (r.error) { box.innerHTML = `<h3>Serveurs DNS</h3><div class="note warn">${esc(r.error)}</div>`; return; }
  const ad = [].concat(r.adapters || []);
  const cur = ad[0];
  const now = !cur ? '' : cur.auto ? 'automatiques (box)' : (DNS.find(d => d[2].join() === [].concat(cur.servers).slice(0, 2).join())?.[1] || [].concat(cur.servers).join(', '));
  box.innerHTML = `<h3>Serveurs DNS</h3><div class="muted small" style="margin-bottom:10px">Le DNS traduit les noms de sites en adresses. Un DNS rapide accélère l'ouverture des sites ; certains bloquent aussi les sites dangereux ou les publicités. Actuellement : <b>${esc(now || 'aucune connexion active')}</b>.</div>
    <div class="row"><select class="field" id="dns-pick">${DNS.map(d => `<option value="${d[0]}">${esc(d[1])}${d[2].length ? ' — ' + d[2][0] : ''}</option>`).join('')}</select><button class="btn" id="dns-go"${needAdmin() || !ad.length ? ' disabled' : ''}>Appliquer</button></div><div class="muted small" id="dns-what" style="margin-top:6px"></div>`;
  const what = () => { $('#dns-what', v).textContent = DNS.find(d => d[0] === $('#dns-pick', v).value)[3]; };
  $('#dns-pick', v).onchange = what; what();
  $('#dns-go', v).onclick = async () => {
    const d = DNS.find(x => x[0] === $('#dns-pick', v).value);
    if (!await safety()) return;
    try { await ps('personal', { action: 'setdns', adapters: ad.map(a => a.index), servers: d[2] }, `DNS : ${d[1]}`); toast(`DNS : ${d[1]}`); loadDns(v, live); }
    catch (e) { toast('Échec : ' + e.message); }
  };
}
const toolCard = (id, t, d, btn, id2, btn2) => `<div class="card glass"><h3>${esc(t)}</h3><div class="muted small" style="margin-bottom:10px">${esc(d)}</div><div class="row"><button class="btn" data-tool="${id}"${needAdmin() ? ' disabled' : ''}>${esc(btn)}</button>${id2 ? `<button class="btn" data-tool="${id2}"${needAdmin() ? ' disabled' : ''}>${esc(btn2)}</button>` : ''}</div><div class="tool-out"></div></div>`;

const repCard = (id, t, d, btn, admin) => `<div class="card glass"><h3>${esc(t)}</h3><div class="muted small" style="margin-bottom:10px">${esc(d)}</div><div class="row"><button class="btn" data-rep="${id}"${admin && needAdmin() ? ' disabled' : ''}>${esc(btn)}</button></div><div class="tool-out"></div></div>`;
const REPAIRS = {
  wureset: { ask: ['Réparer Windows Update ?', 'Windows Update est arrêté, son cache (SoftwareDistribution et catroot2) renommé en .bak, puis relancé. Les mises à jour en attente seront téléchargées à nouveau.'], title: 'Windows Update réparé', done: r => r.renamed?.length ? 'Cache mis de côté. Relancez une recherche de mises à jour dans les Paramètres.' : 'Les dossiers n\'ont pas pu être renommés (une mise à jour est peut-être en cours) : redémarrez le PC puis réessayez.' },
  iconcache: { ask: ['Reconstruire le cache des icônes ?', 'L\'Explorateur va redémarrer : la barre des tâches disparaît une seconde et les fenêtres de l\'Explorateur ouvertes se ferment.'], done: r => `${plural(r.removed, 'fichier de cache supprimé', 'fichiers de cache supprimés')}. Les icônes se reconstruisent au fur et à mesure.` },
  explorer: { ask: ['Redémarrer l\'Explorateur ?', 'La barre des tâches disparaît une seconde et les fenêtres de l\'Explorateur ouvertes se ferment.'], done: () => 'Explorateur redémarré.' },
  storecache: { done: () => 'Nettoyage lancé : le Store s\'ouvrira une fois terminé.' },
  history: { ask: ['Effacer l\'historique de l\'Explorateur ?', 'Les listes de fichiers récents et de raccourcis épinglés dans les listes de la barre des tâches sont vidées. Vos fichiers ne sont pas touchés.'], title: 'Historique de l\'Explorateur effacé', done: r => `${plural(r.removed, 'élément effacé', 'éléments effacés')}.` },
  battery: { done: () => 'Rapport ouvert dans le navigateur.' },
};
async function runRepair(name, out) {
  if (name === 'gpu') {
    if (!await confirmAction('Redémarrer le pilote graphique ?', '<p>L\'écran devient noir une à deux secondes. Les jeux ouverts peuvent planter : fermez-les d\'abord.</p>', 'Redémarrer')) return;
    await bao.call('gpu.restart'); out.innerHTML = '<div class="note ok" style="margin-top:10px">Pilote graphique redémarré.</div>'; return;
  }
  const r = REPAIRS[name];
  if (r.ask && !await confirmAction(r.ask[0], `<p>${esc(r.ask[1])}</p>`, 'Continuer')) return;
  out.innerHTML = '<div class="progress"><div class="spinner"></div><div>En cours…</div></div>';
  try {
    const res = await ps('repair', { action: name });
    if (name === 'battery') await bao.call('open.report');
    if (r.title) await bao.call('journal.add', { title: r.title, detail: res.detail || '' }).catch(() => { });
    out.innerHTML = `<div class="note ok" style="margin-top:10px">${esc(r.done(res))}</div>`;
  } catch (e) { out.innerHTML = `<div class="note warn" style="margin-top:10px">${esc(e.message)}</div>`; }
}

async function runTool(name, drive, out) {
  if (state.busyTool) return toast('Un outil est déjà en cours');
  if (name === 'ipreset' && !await confirmAction('Réinitialiser TCP/IP ?', '<p>Les réglages IP reviennent à leur état d\'origine : une adresse IP ou des serveurs DNS réglés à la main sont perdus. Redémarrage nécessaire.</p>', 'Réinitialiser', true)) return;
  if (name === 'winsock' &&!await confirmAction('Réinitialiser Winsock ?', '<p>La configuration réseau de Windows revient à son état d\'origine. Un redémarrage est nécessaire ; certains VPN ou logiciels réseau peuvent devoir être réinstallés.</p>', 'Réinitialiser', true)) return;
  if (name === 'dism_cleanup' && !await confirmAction('Nettoyer les composants ?', '<p>Les anciennes versions de composants remplacées par des mises à jour sont retirées. Les mises à jour déjà installées ne pourront plus être désinstallées. Plusieurs minutes.</p>', 'Nettoyer')) return;
  state.busyTool = true;
  out.innerHTML = `<div class="progress"><div class="spinner"></div><div class="grow small mono ellipsis" data-line>Démarrage…</div></div>`;
  try {
    const r = await bao.call('tool', { name, drive }, d => { const l = $('[data-line]', out); if (l) l.textContent = d.line; });
    const ok = r.code === 0;
    out.innerHTML = `<div class="note ${ok ? 'ok' : 'warn'}" style="margin-top:10px">${ok ? 'Terminé.' : `Terminé avec le code ${r.code}.`} ${summary(name, r)}</div><details><summary class="small muted">Compte rendu complet</summary><div class="console">${esc(r.output)}</div></details>`;
  } catch (e) { out.innerHTML = `<div class="note warn">${esc(e.message)}</div>`; }
  state.busyTool = false;
}
function summary(name, r) {
  const o = r.output;
  if (name === 'sfc') return /n'a trouvé aucune violation|did not find any integrity/i.test(o) ? 'Aucun fichier abîmé.' : /a trouvé des fichiers endommagés et les a réparés|successfully repaired/i.test(o) ? 'Des fichiers abîmés ont été réparés. Redémarrez le PC.' : /n'a pas pu réparer|unable to fix/i.test(o) ? 'Certains fichiers n\'ont pas pu être réparés : lancez « Réparer l\'image de Windows (DISM) », puis SFC à nouveau.' : '';
  if (name === 'dism_analyze') { const m = o.match(/(?:Nettoyage du magasin d[eu]s? composants recommandé|Component Store Cleanup Recommended)\s*:\s*(\S+)/i); return m ? `Nettoyage recommandé : ${esc(m[1])}.` : ''; }
  if (name === 'optimize') return /TRIM|retrim|r[ée]optimisation/i.test(o) ? 'TRIM effectué : le SSD sait quels blocs sont libres.' : /d[ée]fragment/i.test(o) ? 'Défragmentation terminée.' : '';
  if (name === 'chkdsk') return /aucun problème|sans trouver de probl|found no problems/i.test(o) ? 'Aucune erreur sur le disque.' : '';
  if (name === 'winsock') return 'Redémarrez le PC pour terminer.';
  return '';
}

async function loadRestore(v, live) {
  const box = $('#restore', v);
  if (needAdmin()) { box.innerHTML = '<div class="muted">Administrateur requis.</div>'; return; }
  const r = await ps('restore').catch(e => ({ error: e.message }));
  if (!live()) return;
  if (r.error) { box.innerHTML = `<div class="note warn">${esc(r.error)}</div>`; return; }
  const pts = [].concat(r.points || []).sort((a, b) => new Date(b.date) - new Date(a.date));
  box.innerHTML = `${r.enabled ? '' : '<div class="note warn">La protection du système semble désactivée sur le lecteur système : aucun point de restauration ne peut être créé.</div>'}
    ${pts.length ? `<table class="table"><tbody>${pts.slice(0, 8).map(p => `<tr><td>${esc(p.description)}</td><td class="r muted">${fmtDateTime(p.date)}</td></tr>`).join('')}</tbody></table>` : '<div class="muted">Aucun point de restauration.</div>'}
    <div class="row" style="margin-top:10px">${r.enabled ? '<button class="btn primary" id="rp-create">Créer un point maintenant</button>' : '<button class="btn primary" id="rp-enable">Activer la protection et créer un point</button>'}<button class="btn" data-open-target="rstrui.exe">Restaurer le système…</button></div><div id="rp-out"></div>`;
}
async function createRestore(v, enable) {
  const out = $('#rp-out', v);
  out.innerHTML = '<div class="progress"><div class="spinner"></div><div>Création du point (environ une minute)…</div></div>';
  try { await ps('restore', { action: 'create', description: 'Boîte à outils (manuel)', enable }); toast('Point de restauration créé'); state.safetyAsked = true; loadRestore(v, () => true); }
  catch (e) { out.innerHTML = `<div class="note warn">${esc(e.message)}</div>`; }
}

async function loadDisks(v, live) {
  const box = $('#disks', v);
  const r = await ps('disks').catch(e => ({ error: e.message }));
  if (!live()) return;
  if (r.error) { box.innerHTML = `<div class="note warn">${esc(r.error)}</div>`; return; }
  box.innerHTML = `<div class="list">${r.volumes.map(vol => {
    const d = vol.disk || {};
    const ssd = d.media === 'SSD';
    const used = vol.size - vol.free;
    const facts = [d.name, d.bus, ssd ? 'SSD' : d.media === 'HDD' ? 'Disque dur' : '', d.temperature ? `${d.temperature} °C` : '', d.wear != null && ssd ? `usure ${d.wear} %` : '', d.hours ? `${nf0.format(d.hours)} h d'utilisation` : ''].filter(Boolean).join(' · ');
    const health = d.health === 'Healthy' ? '<span class="badge ok">En bonne santé</span>' : d.health ? `<span class="badge bad">${esc(d.health)}</span>` : '';
    return `<div class="item glass"><div class="ico">${esc(vol.letter)}</div><div><div class="title">${esc(vol.letter)}: ${esc(vol.label || '')} ${health}</div><div class="sub">${esc(facts)}</div>
      <div class="row small" style="margin-top:6px"><span class="grow">${fmtSize(vol.free)} libres sur ${fmtSize(vol.size)}</span></div><div class="bar${used / vol.size > .9 ? ' hot' : ''}"><i style="width:${(used / vol.size * 100).toFixed(1)}%"></i></div>
      <div class="what">${ssd ? 'SSD : « Optimiser » envoie un TRIM (jamais de défragmentation, inutile et néfaste sur un SSD).' : d.media === 'HDD' ? 'Disque dur : « Optimiser » le défragmente si nécessaire.' : '« Optimiser » choisit automatiquement TRIM ou défragmentation selon le type de disque.'}</div><div class="tool-out"></div></div>
      <div class="side"><button class="btn small" data-tool="optimize" data-drive="${esc(vol.letter)}"${needAdmin() ? ' disabled' : ''}>Optimiser</button><button class="btn small" data-tool="chkdsk" data-drive="${esc(vol.letter)}"${needAdmin() ? ' disabled' : ''}>Vérifier les erreurs</button></div></div>`;
  }).join('')}</div>${r.optimizeTask ? `<div class="muted small" style="margin-top:6px">Optimisation automatique de Windows : ${r.optimizeTask.state === 'Disabled' ? 'désactivée' : 'active'}${r.optimizeTask.last ? `, dernière le ${fmtDate(r.optimizeTask.last)}` : ''}.</div>` : ''}`;
}

const REG_CATS = { run: 'Démarrage vers un programme disparu', uninstall: 'Programmes fantômes dans « Programmes et fonctionnalités »', apppaths: 'Chemins d\'applications morts', shareddlls: 'Compteurs de DLL partagées orphelins', muicache: 'Noms mémorisés de programmes disparus', approved: 'États de démarrage orphelins' };
async function regScan(v) {
  const out = $('#reg-out', v);
  out.innerHTML = '<div class="progress"><div class="spinner"></div><div>Analyse du registre…</div></div>';
  const r = await ps('registry', { action: 'scan' }).catch(e => ({ error: e.message }));
  if (r.error) { out.innerHTML = `<div class="note warn">${esc(r.error)}</div>`; return; }
  if (!r.items.length) { out.innerHTML = '<div class="note ok" style="margin-top:10px">Aucune entrée orpheline.</div>'; return; }
  const cats = [...new Set(r.items.map(i => i.cat))];
  out.innerHTML = cats.map(c => `<h3 style="margin-top:14px">${esc(REG_CATS[c] || c)}</h3>${r.items.map((it, i) => it.cat === c ? `<label class="row small" style="padding:3px 0"><input type="checkbox" data-r="${i}" checked><span class="grow">${esc(it.detail)}<div class="muted mono break">${esc(it.key)}${it.value ? ' → ' + esc(it.value) : ''}</div></span></label>` : '').join('')}`).join('')
    + `<div class="row end" style="margin-top:10px">${checkAll('input[data-r]', '#reg-out')}<button class="btn primary" id="reg-fix">Retirer les entrées cochées</button></div>`;
  $('#reg-fix', out).onclick = async () => {
    const items = $$('input[data-r]:checked', out).map(i => r.items[+i.dataset.r]);
    if (!items.length) return;
    if (!await safety()) return;
    try { const res = await ps('registry', { action: 'fix', items }, `Registre : ${items.length} entrées orphelines retirées`); out.innerHTML = `<div class="note ok" style="margin-top:10px">${res.fixed} entrées retirées. Sauvegarde gardée ; annulable dans l'Historique.</div>`; }
    catch (e) { toast('Échec : ' + e.message); }
  };
}

// ── applications ─────────────────────────────────────────────────────────
views.programs = async (v, live) => {
  const st = { tab: 'win32', q: '', sort: 'name', win32: null, store: null, features: null, allFeatures: false, showSys: false };
  v.innerHTML = `<h1>Applications</h1><p class="lead">Programmes installés, applications du Microsoft Store, applications préinstallées superflues et fonctionnalités facultatives de Windows.</p>${adminNote()}
    <div class="toolbar"><div class="chips"><span class="chip on" data-tab="win32">Programmes</span><span class="chip" data-tab="store">Microsoft Store</span><span class="chip" data-tab="bloat">Préinstallées</span><span class="chip" data-tab="features">Fonctionnalités de Windows</span></div>
    <input class="field grow" id="q" placeholder="Filtrer…" style="max-width:240px">${sizeFilter("app-size")}<span class="muted small" id="cnt"></span></div><div id="apps"></div>`;
  const box = $('#apps', v);
  const match = (...s) => filterMatch(st.q, ...s);
  const dateOf = d => /^\d{8}$/.test(d) ? `${d.slice(6, 8)}/${d.slice(4, 6)}/${d.slice(0, 4)}` : '';
  const spinner = () => { box.innerHTML = '<div class="spinner big"></div>'; };
  const loadStore = async () => { st.store = (await ps('apps', { elevated: state.elevated })).items || []; };

  const renderWin32 = () => {
    const items = st.win32.filter(p => match(p.name, p.publisher) && (p.size || 0) >= +$('#app-size', v).value);
    const k = st.sort;
    items.sort((a, b) => k === 'size' ? b.size - a.size : k === 'date' ? String(b.date).localeCompare(String(a.date)) : String(a[k]).localeCompare(String(b[k])));
    box.innerHTML = `<div class="scroll-x"><table class="table"><thead><tr><th class="sort" data-s="name">Nom</th><th class="hide-s sort" data-s="publisher">Éditeur</th><th class="r sort" data-s="size">Taille</th><th class="r hide-s sort" data-s="date">Installé le</th><th></th></tr></thead><tbody>${items.map(p => `<tr><td><b>${esc(p.name)}</b><div class="small muted">${esc(p.version)}</div></td><td class="hide-s small muted">${esc(p.publisher)}</td><td class="r size">${p.size ? fmtSize(p.size) : ''}</td><td class="r hide-s small muted">${dateOf(p.date)}</td>
      <td class="r nowrap">${p.location ? `<button class="btn small ghost" data-loc="${esc(p.location)}" title="Ouvrir l'emplacement">📂</button><button class="btn small ghost" data-stop="${esc(p.key)}" title="Fermer le programme">✕</button>` : ''}${p.uninstall ? `<button class="btn small" data-un="${esc(p.key)}">Désinstaller</button>` : ''}</td></tr>`).join('')}</tbody></table></div>`;
    $('#cnt', v).textContent = plural(items.length, 'programme', 'programmes');
  };

  const appKb = a => appxFind(a.name);
  const appLocked = a => a.nonRemovable || a.system || appKb(a)?.r === 'lock';
  const renderStore = () => {
    const items = st.store.filter(a => (st.showSys || !a.system) && match(a.title, a.name, a.publisher)).sort((a, b) => a.title.localeCompare(b.title));
    box.innerHTML = `<div class="note info">« Réinitialiser » efface les données et réglages de l'application, comme au premier lancement. Une application désinstallée se réinstalle depuis le Microsoft Store ; celles fournies avec Windows reviennent aussi par « Annuler » dans l'Historique.</div><div class="toolbar"><label class="row small muted"><input type="checkbox" id="showsys"${st.showSys ? ' checked' : ''}> Afficher les composants système (${st.store.filter(a => a.system).length})</label></div><div class="list">${items.map(a => {
      const kb = appKb(a), lock = appLocked(a);
      return `<div class="item glass"><div class="ico">${esc(a.title[0] || '?')}</div><div><div class="title">${esc(a.title)} ${kb && !lock ? riskBadge(kb.r) : ''}${a.running ? '<span class="badge plain">Ouverte</span>' : ''}</div><div class="sub">${esc([a.publisher, a.version].filter(Boolean).join(' · '))}</div>${kb ? `<div class="what">${esc(kb.w)}</div><div class="cons"><b>Si désinstallée :</b> ${esc(kb.off)}</div>` : ''}<details><summary>Détails</summary><div class="mono break small muted">${esc(a.full)}</div></details></div>
        <div class="side">${a.app ? `<button class="btn small" data-launch="${esc(a.full)}">Ouvrir</button>` : ''}${a.running ? `<button class="btn small" data-astop="${esc(a.full)}">Fermer</button>` : ''}${lock ? '<span class="badge lock">Protégée</span>' : `<button class="btn small" data-reset="${esc(a.full)}">Réinitialiser</button><button class="btn small" data-aun="${esc(a.full)}">Désinstaller</button>`}</div></div>`;
    }).join('')}</div>`;
    $('#cnt', v).textContent = plural(items.length, 'application', 'applications');
  };

  const renderBloat = () => {
    const items = st.store.filter(a => appKb(a)?.bloat && !appLocked(a) && match(a.title, a.name)).sort((a, b) => a.title.localeCompare(b.title));
    box.innerHTML = `<div class="note info">Applications installées d'office par Windows ou le fabricant, que la plupart des gens n'utilisent pas. Celles qui n'ont aucune conséquence sont cochées. Elles sont retirées pour votre compte ; une grande mise à jour de Windows peut en réinstaller certaines.</div>
      ${items.length ? `<div class="list">${items.map(a => { const kb = appKb(a); return `<label class="item glass"><div class="ico"><input type="checkbox" data-b="${esc(a.full)}"${kb.r === 'ok' ? ' checked' : ''}></div><div><div class="title">${esc(a.title)} ${riskBadge(kb.r)}${a.running ? '<span class="badge plain">Ouverte</span>' : ''}</div><div class="what">${esc(kb.w)}</div><div class="cons"><b>Si désinstallée :</b> ${esc(kb.off)}</div></div></label>`; }).join('')}</div>
      <div class="row end sticky" style="margin-top:10px">${checkAll('input[data-b]', '#apps')}<button class="btn primary" id="bloat-go">Désinstaller la sélection</button></div>` : '<div class="note ok">Aucune application superflue connue n\'est installée.</div>'}`;
    $('#cnt', v).textContent = plural(items.length, 'application', 'applications');
  };

  const renderFeatures = () => {
    const known = new Map(FEATURES.map(f => [f.n, f]));
    let items = st.features.filter(f => st.allFeatures || known.has(f.name)).filter(f => match(f.name, known.get(f.name)?.t || ''));
    items.sort((a, b) => st.allFeatures ? a.name.localeCompare(b.name) : FEATURES.findIndex(f => f.n === a.name) - FEATURES.findIndex(f => f.n === b.name));
    const lock = needAdmin();
    box.innerHTML = `<div class="note info">Composants de Windows à activer selon vos besoins. L'activation télécharge parfois des fichiers depuis Windows Update et prend quelques minutes ; un redémarrage est souvent demandé.</div>
      <div class="toolbar"><label class="row small muted"><input type="checkbox" id="allf"${st.allFeatures ? ' checked' : ''}> Afficher toutes les fonctionnalités (${st.features.length})</label></div>
      <div class="list">${items.map(f => { const k = known.get(f.name), on = f.state === 'Enabled'; return `<div class="item glass"><div class="ico">${on ? '✓' : ''}</div><div><div class="title">${esc(k?.t || f.name)} ${k?.warnOn && on ? riskBadge('warn') : ''}${lock ? '<span class="badge lock">Administrateur requis</span>' : ''}</div>${k ? `<div class="what">${esc(k.w)}</div>` : ''}<div class="sub mono">${esc(f.name)}${/Pending/.test(f.state) ? ' · redémarrage en attente' : ''}</div><div class="tool-out"></div></div><div class="side"><div class="switch${on ? ' on' : ''}${lock ? ' locked' : ''}" data-feat="${esc(f.name)}"></div></div></div>`; }).join('')}</div>`;
    $('#cnt', v).textContent = plural(items.length, 'fonctionnalité', 'fonctionnalités');
  };

  const render = async () => {
    $('#app-size', v).hidden = st.tab !== 'win32';
    const tab = st.tab;
    try {
      if (tab === 'win32') { if (!st.win32) { spinner(); st.win32 = (await ps('programs')).items || []; } }
      else if (tab === 'features') { if (!st.features) { box.innerHTML = '<div class="progress glass"><div class="spinner"></div><div>Lecture des fonctionnalités de Windows (quelques secondes)…</div></div>'; st.features = (await ps('features')).items || []; } }
      else if (!st.store) { box.innerHTML = '<div class="progress glass"><div class="spinner"></div><div>Lecture des applications…</div></div>'; await loadStore(); }
    } catch (e) { if (live() && st.tab === tab) box.innerHTML = `<div class="note warn">${esc(e.message)}</div>`; return; }
    if (!live() || st.tab !== tab) return;
    ({ win32: renderWin32, store: renderStore, bloat: renderBloat, features: renderFeatures })[tab]();
  };

  const storeApp = full => st.store.find(a => a.full === full);
  v.addEventListener('click', async e => {
    const open = e.target.closest('[data-open-target]'); if (open) { bao.call('open', { target: open.dataset.openTarget }); return; }
    const tab = e.target.closest('[data-tab]');
    if (tab) { st.tab = tab.dataset.tab; $$('[data-tab]', v).forEach(c => c.classList.toggle('on', c === tab)); render(); return; }
    const th = e.target.closest('th[data-s]'); if (th) { st.sort = th.dataset.s; renderWin32(); return; }
    const loc = e.target.closest('[data-loc]'); if (loc) { bao.call('files.reveal', { path: loc.dataset.loc }); return; }
    const stop = e.target.closest('[data-stop]');
    if (stop) {
      const p = st.win32.find(x => x.key === stop.dataset.stop);
      if (!await confirmAction(`Fermer « ${p.name} » ?`, '<p>Tous ses processus sont terminés. Le travail non enregistré est perdu.</p>', 'Fermer', true)) return;
      try { const r = await ps('programs', { action: 'stop', key: p.key }); toast(r.stopped ? plural(r.stopped, 'processus terminé', 'processus terminés') : 'Ce programme n\'était pas ouvert'); } catch (err) { toast('Échec : ' + err.message); }
      return;
    }
    const un = e.target.closest('[data-un]');
    if (un) {
      const p = st.win32.find(x => x.key === un.dataset.un);
      if (!await confirmAction(`Désinstaller « ${p.name} » ?`, '<p>Le désinstallateur officiel du programme va s\'ouvrir : suivez ses instructions. Ensuite, la page Fichiers fantômes peut retrouver ses restes éventuels.</p>', 'Ouvrir le désinstallateur')) return;
      try { await ps('programs', { action: 'uninstall', key: p.key }); toast('Désinstallateur lancé'); st.win32 = null; } catch (err) { toast('Échec : ' + err.message); }
      return;
    }
    const la = e.target.closest('[data-launch]');
    if (la) { const a = storeApp(la.dataset.launch); try { await ps('apps', { action: 'launch', full: a.full, app: a.app }); toast('Application ouverte'); } catch (err) { toast('Échec : ' + err.message); } return; }
    const as = e.target.closest('[data-astop]');
    if (as) { const a = storeApp(as.dataset.astop); try { await ps('apps', { action: 'stop', full: a.full }); a.running = false; renderStore(); toast('Application fermée'); } catch (err) { toast('Échec : ' + err.message); } return; }
    const rs = e.target.closest('[data-reset]');
    if (rs) {
      const a = storeApp(rs.dataset.reset);
      if (!await confirmAction(`Réinitialiser « ${a.title} » ?`, '<p>Ses données (réglages, connexion au compte, fichiers enregistrés dans l\'application) sont effacées, comme après une réinstallation. Cela ne peut pas être annulé.</p>', 'Réinitialiser', true)) return;
      try { await ps('apps', { action: 'reset', full: a.full, title: a.title }); await bao.call('journal.add', { title: `Application réinitialisée : ${a.title}`, detail: a.full }); toast('Application réinitialisée'); } catch (err) { toast('Échec : ' + err.message); }
      return;
    }
    const au = e.target.closest('[data-aun]');
    if (au) { const a = storeApp(au.dataset.aun); await removeApps([a]); return; }
    if (e.target.closest('#bloat-go')) {
      const list = $$('input[data-b]:checked', v).map(i => storeApp(i.dataset.b));
      if (list.length) await removeApps(list);
    }
  });
  const removeApps = async list => {
    const kbs = list.map(a => appxFind(a.name));
    const warn = kbs.some(k => k && k.r !== 'ok');
    if (!await confirmAction(list.length > 1 ? `Désinstaller ${list.length} applications ?` : `Désinstaller « ${list[0].title} » ?`, `<ul>${list.map((a, i) => `<li><b>${esc(a.title)}</b>${kbs[i] ? ` : ${esc(kbs[i].off)}` : ''}</li>`).join('')}</ul><p class="muted small">Réinstallables depuis le Microsoft Store ; celles fournies avec Windows reviennent aussi par « Annuler » dans l'Historique.</p>`, 'Désinstaller', warn)) return;
    if (!await safety()) return;
    box.innerHTML = '<div class="progress glass"><div class="spinner"></div><div>Désinstallation…</div></div>';
    try {
      const r = await ps('apps', { action: 'remove', items: list.map(a => a.full) }, list.length > 1 ? `${list.length} applications désinstallées` : `Application désinstallée : ${list[0].title}`);
      toast(`${plural(r.removed, 'application désinstallée', 'applications désinstallées')}${r.failed?.length ? `, ${r.failed.length} en échec` : ''}`);
      if (r.failed?.length) log('apps remove : ' + r.failed.join(' | '));
    } catch (err) { toast('Échec : ' + err.message); }
    st.store = null; render();
  };
  v.addEventListener('click', async e => {
    const sw = e.target.closest('[data-feat]');
    if (!sw || sw.classList.contains('busy')) return;
    if (sw.classList.contains('locked')) return toast('Droits administrateur nécessaires');
    const f = st.features.find(x => x.name === sw.dataset.feat);
    const on = f.state !== 'Enabled';
    const k = FEATURES.find(x => x.n === f.name);
    if (!await confirmAction(`${on ? 'Activer' : 'Désactiver'} « ${k?.t || f.name} » ?`, `<p>${k ? esc(k.w) : ''}</p><p class="muted small">Peut prendre plusieurs minutes. Un redémarrage est souvent nécessaire.</p>`, on ? 'Activer' : 'Désactiver', k?.warnOn && on)) return;
    if (!await safety()) return;
    sw.classList.add('busy');
    const out = sw.closest('.item').querySelector('.tool-out');
    out.innerHTML = '<div class="progress"><div class="spinner"></div><div>En cours (plusieurs minutes possibles)…</div></div>';
    try {
      const r = await ps('features', { action: 'set', name: f.name, on }, `Fonctionnalité ${on ? 'activée' : 'désactivée'} : ${k?.t || f.name}`);
      f.state = on ? 'Enabled' : 'Disabled';
      renderFeatures();
      toast(r.restart ? 'Fait : redémarrez le PC pour terminer' : 'Fait');
    } catch (err) { out.innerHTML = `<div class="note warn">${esc(err.message)}</div>`; sw.classList.remove('busy'); }
  });
  v.addEventListener('change', e => {
    if (e.target.id === 'allf') { st.allFeatures = e.target.checked; renderFeatures(); }
    if (e.target.id === 'showsys') { st.showSys = e.target.checked; renderStore(); }
  });
  $('#q', v).oninput = e => { st.q = e.target.value; render(); };
  $('#app-size', v).onchange = render;
  await render();
};

// ── sysinternals ─────────────────────────────────────────────────────────
views.sysinternals = async (v, live) => {
  const st = { q: '', have: {} };
  const all = SYSINT.flatMap(c => c.items);
  v.innerHTML = `<h1>Sysinternals</h1><p class="lead">Les ${all.length} outils de diagnostic avancé de Microsoft (Mark Russinovich). Chaque outil est téléchargé au premier lancement depuis le site officiel <span class="mono">live.sysinternals.com</span>, et n'est gardé et lancé que si sa signature Microsoft est valide.</p>${adminNote()}
    <div class="toolbar"><input class="field grow" id="q" placeholder="Filtrer…" style="max-width:280px">${filterSelect("si-kind", "Type d’outil", [["", "Tous les outils"], ["gui", "Fenêtre"], ["cli", "Ligne de commande"], ["downloaded", "Téléchargé"]])}<span class="muted small" id="cnt"></span><button class="btn small" id="si-folder">Dossier des outils</button><button class="btn small" id="si-update">Mettre à jour les outils téléchargés</button></div>
    <div id="si"></div>`;
  const box = $('#si', v);
  const here = { processes: 'Processus', startup: 'Démarrage', services: 'Services', large: 'Fichiers lourds' };
  const render = () => {
    const q = st.q.toLowerCase();
    let n = 0;
    box.innerHTML = SYSINT.map(c => {
      const items = c.items.filter(t => filterMatch(q, t.n, t.w, t.f) && (!$('#si-kind', v).value || ($('#si-kind', v).value === 'gui' ? t.gui : $('#si-kind', v).value === 'cli' ? !t.gui : !!st.have[t.f])));
      n += items.length;
      return items.length ? `<h2>${esc(c.cat)}</h2><div class="list">${items.map(t => {
        const has = st.have[t.f];
        return `<div class="item glass" data-si="${t.id}"><div class="ico">${t.gui ? '▣' : '›_'}</div><div><div class="title">${esc(t.n)} ${t.r ? riskBadge(t.r) : ''}<span class="badge plain">${t.gui ? 'Fenêtre' : 'Ligne de commande'}</span>${has ? '<span class="badge ok">Téléchargé</span>' : ''}</div>
          <div class="what">${esc(t.w)}</div>${t.note ? `<div class="cons">${esc(t.note)}</div>` : ''}${t.here ? `<div class="small" style="margin-top:4px">Équivalent simplifié dans la Boîte à outils : <a data-go="${t.here}" style="text-decoration:underline;cursor:pointer">${here[t.here]}</a></div>` : ''}
          ${t.gui ? '' : `<div class="row" style="margin-top:8px"><input class="field grow mono small" data-args value="${esc(t.args || '')}" placeholder="Arguments (facultatif)" spellcheck="false"></div>`}<div class="tool-out"></div></div>
          <div class="side"><button class="btn small primary" data-run>${has ? 'Lancer' : 'Télécharger et lancer'}</button><button class="btn small ghost" data-help title="Documentation officielle">?</button></div></div>`;
      }).join('')}</div>` : '';
    }).join('') + (q || $('#si-kind', v).value ? '' : `<h2>Non repris</h2><div class="card glass">${SYSINT_ABSENT.map(([a, b]) => `<div style="margin-bottom:8px"><b>${esc(a)}</b><div class="muted small">${esc(b)}</div></div>`).join('')}</div>`);
    $('#cnt', v).textContent = plural(n, 'outil', 'outils');
  };
  const run = async (t, item) => {
    const out = $('.tool-out', item), btn = $('[data-run]', item);
    if (t.r === 'bad' && !await confirmAction(`Lancer ${t.n} ?`, `<p>${esc(t.w)}</p>`, 'Lancer', true)) return;
    const args = t.gui ? '' : $('[data-args]', item).value;
    if (/<[^>]+>/.test(args)) { toast('Remplacez d\'abord la partie entre < > par votre valeur'); $('[data-args]', item).focus(); return; }
    if (t.r === 'warn' && !t.gui && !await confirmAction(`Lancer ${t.n} ?`, `<p>${esc(t.w)}</p><p class="mono small">${esc(t.f)} ${esc(args)}</p>`, 'Lancer', true)) return;
    btn.disabled = true;
    try {
      if (!st.have[t.f]) {
        out.innerHTML = '<div class="progress"><div class="spinner"></div><div>Téléchargement depuis live.sysinternals.com et vérification de la signature…</div></div>';
        st.have = await bao.call('sysint.get', { files: [t.f] });
        $('.badge.ok', item) || $('.title', item).insertAdjacentHTML('beforeend', '<span class="badge ok">Téléchargé</span>');
        btn.textContent = 'Lancer';
      }
      if (t.gui) {
        await bao.call('sysint.run', { file: t.f, gui: true, eula: t.eula !== false });
        out.innerHTML = '<div class="note ok" style="margin-top:8px">Ouvert dans sa propre fenêtre.</div>';
      } else {
        out.innerHTML = '<div class="progress"><div class="spinner"></div><div class="grow small" data-line>Lancement…</div><button class="btn small" data-stop>Arrêter</button></div>';
        const p = bao.call('sysint.run', { file: t.f, args, eula: t.eula !== false }, d => { const l = $('[data-line]', out); if (l) l.textContent = d.line; });
        $('[data-stop]', out).onclick = () => bao.cancel(p);
        const r = await p;
        out.innerHTML = `<div class="note ${r.code === 0 ? 'ok' : 'warn'}" style="margin-top:8px">${r.code === -2 ? 'Arrêté.' : r.code === 0 ? 'Terminé.' : `Terminé avec le code ${r.code}.`}</div><div class="console">${esc(r.output.trim() || '(aucune sortie)')}</div>`;
      }
    } catch (e) { out.innerHTML = `<div class="note warn" style="margin-top:8px">${esc(e.message)}</div>`; }
    btn.disabled = false;
  };
  v.addEventListener('click', async e => {
    const go = e.target.closest('[data-go]'); if (go) { router.go(go.dataset.go); return; }
    if (e.target.closest('#si-folder')) { bao.call('files.reveal', { path: state.dataDir + '\\sysinternals' }); return; }
    if (e.target.closest('#si-update')) {
      const files = Object.keys(st.have);
      if (!files.length) return toast('Aucun outil téléchargé');
      toast('Mise à jour…');
      try { st.have = await bao.call('sysint.get', { files }); render(); toast(plural(files.length, 'outil mis à jour', 'outils mis à jour')); } catch (err) { toast('Échec : ' + err.message); }
      return;
    }
    const item = e.target.closest('[data-si]'); if (!item) return;
    const t = all.find(x => x.id === item.dataset.si);
    if (e.target.closest('[data-help]')) { bao.call('open', { target: `https://learn.microsoft.com/sysinternals/downloads/${t.id === 'autorunsc' ? 'autoruns' : t.id === 'tcpvcon' ? 'tcpview' : t.id === 'loadordc' ? 'loadorder' : t.id === 'loadord' ? 'loadorder' : t.id === 'cpustres' ? 'cpustres' : t.id === 'movefile' ? 'pendmoves' : t.id}` }); return; }
    if (e.target.closest('[data-run]')) run(t, item);
  });
  v.addEventListener('keydown', e => { if (e.key === 'Enter' && e.target.matches('[data-args]')) { const item = e.target.closest('[data-si]'); run(all.find(x => x.id === item.dataset.si), item); } });
  $('#q', v).oninput = e => { st.q = e.target.value; render(); };
  $('#si-kind', v).onchange = render;
  st.have = await bao.call('sysint.state').catch(() => ({}));
  if (!live()) return;
  render();
};

// ── historique ───────────────────────────────────────────────────────────
views.history = async (v, live) => {
  const list = (await bao.call('journal.list')) || [];
  if (!live()) return;
  list.reverse();
  v.innerHTML = `<h1>Historique</h1><p class="lead">Toutes les modifications faites avec la Boîte à outils. Celles qui ont un bouton « Annuler » reviennent exactement à l'état d'avant. Les fichiers mis à la Corbeille se récupèrent depuis la Corbeille.</p>
    <div class="toolbar"><input class="field grow" id="history-q" placeholder="Filtrer…">${filterSelect("history-state", "État", [["", "Tous les états"], ["undo", "Annulables"], ["undone", "Annulées"]])}<button class="btn" id="backups">Ouvrir le dossier des sauvegardes</button></div>
    <div class="list" id="history-list"></div>`;
  const render = () => {
    const shown = list.filter(e => filterMatch($('#history-q', v).value, e.title, e.detail) && (!$('#history-state', v).value || ($('#history-state', v).value === 'undo' ? e.undo_script && !e.undone : e.undone)));
    $('#history-list', v).innerHTML = `${shown.length ? shown.map(e => `<div class="item glass${e.undone ? ' off' : ''}"><div class="ico">${e.undone ? '↺' : '✓'}</div><div><div class="title">${esc(e.title)} ${e.undone ? '<span class="badge plain">Annulée</span>' : ''}</div><div class="sub">${fmtDateTime(e.time)}</div>${e.detail ? `<div class="small muted break">${esc(e.detail)}</div>` : ''}</div>
      <div class="side">${e.undo_script && !e.undone ? `<button class="btn small" data-undo="${e.id}">Annuler</button>` : ''}</div></div>`).join('') : '<div class="empty">Aucune modification pour l\'instant.</div>'}`;
  };
  $('#history-q', v).oninput = render;
  $('#history-state', v).onchange = render;
  render();
  v.addEventListener('click', async e => {
    if (e.target.closest('#backups')) { bao.call('files.reveal', { path: state.dataDir + '\\sauvegardes' }); return; }
    const b = e.target.closest('[data-undo]'); if (!b) return;
    b.disabled = true;
    try { await bao.call('journal.undo', { id: +b.dataset.undo }); toast('Modification annulée'); router.go('history'); }
    catch (err) { toast('Échec : ' + err.message); b.disabled = false; }
  });
};

// Index local en mémoire, reconstruit à la demande. Aucun contenu de fichier n'est lu.
const fileSearch = { root: '', q: '', kind: '', min: 0, since: 0, sort: 'name', fullPath: false, hidden: false };
views.search = async (v, live) => {
  const info = state.info || await bao.call('info');
  if (!live()) return;
  const status = await bao.call('search.status');
  if (!live()) return;
  fileSearch.root = status.root || fileSearch.root || info.home || info.drives?.[0]?.drive || 'C:\\';
  v.innerHTML = `<h1>Recherche de fichiers</h1><p class="lead">Retrouvez fichiers et dossiers par leur nom, comme avec Everything.</p>
    <div class="card glass"><div class="toolbar"><input class="field grow" id="fs-root" aria-label="Dossier à indexer" value="${esc(fileSearch.root)}"><select class="field" id="fs-volume" aria-label="Emplacement"><option value="">Choisir un emplacement</option><option value="*">Tout l'ordinateur</option><option value="${esc(info.home || '')}">Dossier personnel</option>${(info.drives || []).map(d => `<option value="${esc(d.drive + (d.drive.endsWith('\\') ? '' : '\\'))}">${esc(d.drive)}</option>`).join('')}</select><button class="btn primary" id="fs-build">Reconstruire l'index</button><button class="btn" id="fs-stop">Arrêter</button></div>
    <label class="row small"><input type="checkbox" id="fs-hidden"${fileSearch.hidden ? ' checked' : ''}> Inclure les éléments masqués</label><div class="muted small" id="fs-status" role="status"></div>
    <p class="muted small">L'index reste en mémoire sur cet appareil. Reconstruisez-le après des modifications.</p><p class="muted small">La première indexation peut prendre plusieurs minutes. Les dossiers inaccessibles sont ignorés ; les liens ne sont pas parcourus. Les tailles des dossiers ne sont pas calculées.</p></div>
    <div class="toolbar"><input class="field grow" id="fs-query" placeholder="Nom, plusieurs mots ou *.pdf" value="${esc(fileSearch.q)}">${filterSelect('fs-kind', 'Type', [['', 'Fichiers et dossiers'], ['files', 'Fichiers'], ['folders', 'Dossiers']])}${sizeFilter('fs-min')}${filterSelect('fs-date', 'Date de modification', [[0, 'Toutes les dates'], [1, 'Dernières 24 heures'], [7, '7 derniers jours'], [30, '30 derniers jours']])}${filterSelect('fs-sort', 'Trier', [['name', 'Nom'], ['size', 'Taille'], ['date', 'Date de modification']])}</div>
    <label class="row small muted"><input type="checkbox" id="fs-path"${fileSearch.fullPath ? ' checked' : ''}> Chercher dans le chemin complet</label><div id="fs-count" class="muted small" role="status"></div><div id="fs-results"></div>`;
  for (const [id, key] of [['fs-kind','kind'],['fs-min','min'],['fs-date','since'],['fs-sort','sort']]) $('#'+id,v).value = fileSearch[key];
  let serial = 0, pending = false, timer;
  const render = async () => {
    const seq = ++serial;
    const r = await bao.call('search.query', { ...fileSearch, since: fileSearch.since ? Math.floor(Date.now()/1000) - fileSearch.since*86400 : 0, limit: 500 });
    if (!live() || seq !== serial) return;
    $('#fs-build',v).disabled = r.running; $('#fs-stop',v).disabled = !r.running;
    $('#fs-status',v).textContent = trad('{0} éléments indexés · {1} dossiers inaccessibles', { 0:r.indexed, 1:r.skipped }) + ' · ' + trad(r.running ? 'Indexation en cours…' : r.cancelled ? 'Indexation arrêtée (résultats partiels)' : 'Index prêt');
    $('#fs-count',v).textContent = trad('{0} résultats · {1} affichés', { 0:r.total, 1:r.items.length });
    $('#fs-results',v).innerHTML = r.items.length ? `<div class="scroll-x"><table class="table"><thead><tr><th>Nom</th><th>Chemin</th><th class="r">Taille</th><th>Date de modification</th><th></th></tr></thead><tbody>${r.items.map(it => `<tr><td style="min-width:160px">${it.dir ? '📁' : '📄'} ${esc(it.name)}</td><td class="path small"><span title="${esc(it.path)}">${esc(it.path)}</span></td><td class="r size">${it.dir ? '—' : fmtSize(it.size)}</td><td class="small">${it.modified ? fmtDateTime(it.modified) : '—'}</td><td><button class="btn small" data-fs-reveal="${esc(it.path)}">Afficher</button><button class="btn small" data-fs-copy="${esc(it.path)}">Copier le chemin</button></td></tr>`).join('')}</tbody></table></div>` : '<div class="empty">Aucun résultat. Lancez une indexation ou ajustez les filtres.</div>';
  };
  const refresh = () => { if (pending || !live()) return; pending = true; render().catch(e => live() && toast(e.message)).finally(() => pending = false); };
  $('#fs-query',v).oninput = e => { fileSearch.q=e.target.value;clearTimeout(timer);timer=setTimeout(refresh,180); };
  for (const [id,key,numeric] of [['fs-kind','kind',false],['fs-min','min',true],['fs-date','since',true],['fs-sort','sort',false]]) $('#'+id,v).onchange=e=>{fileSearch[key]=numeric?+e.target.value:e.target.value;refresh();};
  $('#fs-path',v).onchange=e=>{fileSearch.fullPath=e.target.checked;refresh();};
  $('#fs-volume',v).onchange=e=>{if(e.target.value)$('#fs-root',v).value=e.target.value;};
  $('#fs-build',v).onclick=async()=>{
    fileSearch.root=$('#fs-root',v).value.trim();fileSearch.hidden=$('#fs-hidden',v).checked;
    try { await bao.call('search.start',{root:fileSearch.root,hidden:fileSearch.hidden});refresh(); } catch(e) { if(live())toast(e.message); }
  };
  $('#fs-stop',v).onclick=async()=>{await bao.call('search.stop');refresh();};
  v.addEventListener('click',e=>{
    const reveal=e.target.closest('[data-fs-reveal]');if(reveal)bao.call('files.reveal',{path:reveal.dataset.fsReveal});
    const copy=e.target.closest('[data-fs-copy]');if(copy)copyText(copy.dataset.fsCopy);
  });
  const interval=setInterval(refresh,1500);
  router.cleanup.push(()=>{clearInterval(interval);clearTimeout(timer);serial++;});
  await render();
};

// ── démarrage ────────────────────────────────────────────────────────────
async function boot() {
  $('#nav').addEventListener('click', e => { const a = e.target.closest('a[data-view]'); if (a) router.go(a.dataset.view); });
  $('#menu-btn').onclick = () => document.body.classList.toggle('drawer');
  $('#scrim').onclick = () => document.body.classList.remove('drawer');
  native({ cmd: 'ready', lang: LANG });
  try { state.info = await bao.call('info'); } catch { state.info = null; }
  state.elevated = !!state.info?.elevated;
  state.dataDir = state.info?.dataDir || '';
  $('#admin-state').innerHTML = state.elevated ? '<span style="color:var(--ok)">●</span> Administrateur' : '<span style="color:var(--warn)">●</span> Mode limité<button class="btn small" data-act="elevate">Relancer en administrateur</button>';
  router.go('home');
}
boot();

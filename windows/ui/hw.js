/* SPDX-License-Identifier: GPL-3.0-or-later — Copyright (C) 2026 jeremdevgit — voir LICENSE */
'use strict';
/* Boîte à outils — matériel (façon CPU-Z), capteurs (façon HWMonitor), tests de
   stabilité (façon OCCT), Mode Dieu et autres logiciels. Utilise les outils
   d'app.js (bao, ps, esc, router, views…). */

const UNIT = { temp: '°C', freq: 'MHz', load: '%', power: 'W', fan: trad('tr/min'), volt: 'V', data: UNITS.g, pct: '%' };
const KIND_NAME = { temp: 'Températures', volt: 'Tensions', power: 'Puissance', freq: 'Fréquences', load: 'Charge', fan: 'Ventilateurs', pct: 'Ventilateurs et puissance', data: 'Mémoire' };
const fmtVal = (k, v) => {
  if (v == null || !isFinite(v)) return '—';
  const d = k === 'volt' ? 3 : k === 'temp' || k === 'power' || k === 'data' ? 1 : 0;
  return v.toLocaleString(LOCALE, { minimumFractionDigits: d, maximumFractionDigits: d }) + ' ' + UNIT[k];
};
const tempClass = (k, v) => k !== 'temp' ? '' : v >= 90 ? ' bad' : v >= 80 ? ' warn' : '';
const PAWNIO_NOTE = `<div class="note info">Pour la température et la puissance du processeur et les sondes de la carte mère (ventilateurs, tensions), la Boîte à outils utilise <b>PawnIO</b> : un pilote libre et signé, utilisé aussi par LibreHardwareMonitor et FanControl, en lecture seule ici. <button class="btn small" data-act="pawnio">Installer PawnIO</button></div>`;
document.addEventListener('click', e => { if (e.target.closest('[data-act="pawnio"]')) { bao.call('pawnio.install').then(() => toast('Installation de PawnIO lancée : relancez la Boîte à outils ensuite')).catch(e => toast(e.message)); } });

// ── matériel ─────────────────────────────────────────────────────────────
// fiche lue une fois par session (7 s de requêtes WMI), dès le survol du menu
let hwInfoP = null;
const hwInfo = () => (hwInfoP ??= ps('hwinfo').catch(e => { hwInfoP = null; throw e; }));
document.addEventListener('mouseover', e => { if (e.target.closest('#nav a[data-view="hardware"]')) hwInfo().catch(() => { }); });
views.hardware = async (v, live) => {
  v.innerHTML = `<h1>Matériel</h1><p class="lead">Fiche complète du PC : processeur, carte mère, mémoire, carte graphique, stockage et système.</p>
    <div class="toolbar"><div class="chips" id="hw-tabs">${['Processeur', 'Carte mère', 'Mémoire', 'Graphisme', 'Stockage', 'Système'].map((t, i) => `<span class="chip${i ? '' : ' on'}" data-t="${i}">${t}</span>`).join('')}</div><button class="btn small" id="hw-copy">Copier le rapport</button></div>
    <div id="hw"><div class="spinner big"></div></div>`;
  const [cpu, info, sens] = await Promise.all([bao.call('hw.cpu'), hwInfo(), bao.call('sensors').catch(() => null)]);
  if (!live()) return;
  let tab = 0;
  const row = (k, val) => val === '' || val == null ? '' : `<tr><td class="muted" style="width:38%">${esc(k)}</td><td>${val}</td></tr>`;
  const table = rows => `<div class="card glass"><table class="table"><tbody>${rows.join('')}</tbody></table></div>`;
  const sizeK = b => b >= 1 << 20 ? (b / (1 << 20)) + ' ' + UNITS.m : (b / 1024) + ' ' + UNITS.k;
  const freq = () => sens?.groups?.find(g => g.id === 'cpu')?.items.find(i => i.l === 'Fréquence maximale des cœurs')?.v;
  const sections = [
    () => table([
      row('Nom', `<b>${esc(cpu.brand)}</b>`),
      row('Fabricant', esc(cpu.vendor)),
      row('Microarchitecture', esc(cpu.codename)),
      row('Socket', esc(info.cpu?.socket)),
      row('Cœurs / threads', `${cpu.cores} cœurs, ${cpu.threads} threads`),
      row('Fréquence de base', cpu.baseMhz ? `${nf0.format(cpu.baseMhz)} MHz` : ''),
      row('Fréquence actuelle (cœur le plus rapide)', freq() ? `${nf0.format(freq())} MHz` : ''),
      row('Famille / modèle / révision', `${cpu.family}h / ${cpu.model}h / ${cpu.stepping} <span class="muted mono small">(CPUID ${cpu.signature})</span>`),
      ...cpu.caches.map(c => row(`Cache ${c.name}`, `${c.count > 1 ? c.count + ' × ' : ''}${sizeK(c.size)}`)),
      row('Instructions', `<div class="chips">${cpu.features.map(f => `<span class="chip" style="cursor:default">${esc(f)}</span>`).join('')}</div>`),
      row('Virtualisation dans le BIOS', info.cpu?.virtualization ? 'Activée' : 'Désactivée (nécessaire à WSL 2, aux émulateurs Android et aux machines virtuelles)'),
    ]),
    () => table([
      row('Fabricant', esc(info.board?.maker)), row('Modèle', `<b>${esc(info.board?.model)}</b>`), row('Révision', esc(info.board?.version)),
      row('BIOS', `${esc(info.bios?.maker)} ${esc(info.bios?.version)}`), row('Date du BIOS', fmtDate(info.bios?.date)),
      row('Mode de démarrage', info.bios?.uefi ? 'UEFI' : 'Hérité (BIOS)'),
      row('Démarrage sécurisé', info.secureboot == null ? 'Inconnu' : info.secureboot ? 'Activé' : 'Désactivé'),
      row('TPM', info.tpm ? (info.tpm.present ? (info.tpm.ready ? 'Présent et prêt' : 'Présent, non initialisé') : 'Absent ou désactivé') : 'Inconnu'),
      row('Ordinateur', `${esc(info.system?.maker)} ${esc(info.system?.model)}`),
    ]),
    () => {
      const m = info.memory || {}, mods = m.modules || [];
      const first = mods[0] || {};
      return table([
        row('Quantité totale', `<b>${fmtSize(mods.reduce((s, x) => s + x.size, 0))}</b>`),
        row('Type', esc(first.type)),
        row('Barrettes', `${mods.length} sur ${m.slots || '?'} emplacements`),
        row('Fréquence configurée', first.configured ? `${first.configured} MT/s (${Math.round(first.configured / 2)} MHz)` : ''),
        row('Fréquence nominale (JEDEC/XMP)', first.speed ? `${first.speed} MT/s` : ''),
        first.speed && first.configured && first.configured < first.speed ? row('Remarque', '<span style="color:var(--warn)">La mémoire tourne moins vite que sa fréquence nominale : activez le profil XMP / EXPO / DOCP dans le BIOS.</span>') : '',
      ]) + `<h2>Barrettes</h2><div class="scroll-x"><table class="table"><thead><tr><th>Emplacement</th><th>Taille</th><th>Fabricant</th><th>Référence</th><th class="hide-s">Tension</th></tr></thead><tbody>${mods.map(x => `<tr><td>${esc(x.slot)}</td><td class="size">${fmtSize(x.size)}</td><td>${esc(x.maker === 'Unknown' ? '—' : x.maker)}</td><td class="mono small">${esc(x.part)}</td><td class="hide-s">${x.voltage ? (x.voltage / 1000).toFixed(2) + ' V' : ''}</td></tr>`).join('')}</tbody></table></div>`;
    },
    () => (info.gpus || []).map(g => table([
      row('Nom', `<b>${esc(g.name)}</b>`), row('Fabricant', esc(g.maker)), row('Mémoire vidéo', g.vram ? fmtSize(g.vram) : ''),
      row('Pilote', `${esc(g.driver)}${g.date ? ' du ' + fmtDate(g.date) : ''}`), row('Affichage', esc(g.mode)),
    ])).join('') + (info.monitors?.length ? `<h2>Écrans</h2>` + table(info.monitors.map(mo => row(mo.maker || 'Écran', `${esc(mo.name)}${mo.year ? ` (${mo.year})` : ''}`))) : ''),
    () => `<div class="list">${(info.disks || []).map(d => `<div class="item glass"><div class="ico">💾</div><div><div class="title">${esc(d.name)} <span class="badge ${d.health === 'Healthy' ? 'ok' : 'bad'}">${d.health === 'Healthy' ? 'En bonne santé' : esc(d.health)}</span></div><div class="sub">${esc([d.media === 'SSD' ? 'SSD' : d.media === 'HDD' ? 'Disque dur' : d.media, d.bus, fmtSize(d.size), d.firmware ? 'micrologiciel ' + d.firmware : ''].filter(Boolean).join(' · '))}</div></div></div>`).join('')}</div>`,
    () => table([
      row('Système', `<b>${esc(info.os?.name)}</b>`), row('Version', `${esc(info.os?.version)} (build ${esc(info.os?.build)})`), row('Architecture', esc(info.os?.arch)),
      row('Installé le', fmtDate(info.os?.installed)), row('Nom du PC', esc(info.system?.name)),
    ]),
  ];
  const render = () => { $('#hw', v).innerHTML = sections[tab](); };
  render();
  v.addEventListener('click', e => {
    const t = e.target.closest('[data-t]');
    if (t) { tab = +t.dataset.t; $$('[data-t]', v).forEach(c => c.classList.toggle('on', c === t)); render(); }
    if (e.target.closest('#hw-copy')) {
      const text = sections.map(f => { const d = document.createElement('div'); d.innerHTML = f(); traduirePage(d); return d.innerText; }).join('\n\n');
      navigator.clipboard.writeText(`${trad('Rapport matériel — Boîte à outils')}\n\n${text}`).then(() => toast('Rapport copié'), () => toast('Copie impossible'));
    }
  });
};

// ── capteurs ─────────────────────────────────────────────────────────────
views.sensors = async (v, live) => {
  v.innerHTML = `<h1>Capteurs</h1><p class="lead">Températures, fréquences, charge, puissance, ventilateurs et tensions, avec le minimum et le maximum relevés depuis l'ouverture de la page.</p>
    <div id="sn-note"></div><div class="toolbar"><button class="btn small" id="sn-reset">Remettre min/max à zéro</button><label class="row small muted"><input type="checkbox" id="sn-threads"> Détail par thread</label><span class="muted small" id="sn-since"></span></div>
    <div id="sn"><div class="spinner big"></div></div>`;
  let threads = false, busy = false, first = true;
  const icon = { cpu: '⚙', board: '▦', gpu: '▣', mem: '▤', disk: '💾', battery: '🔋' };
  const tick = async () => {
    if (busy || !live() || document.hidden) return;
    busy = true;
    try {
      const s = await bao.call('sensors');
      if (!live()) return;
      if (first) {
        first = false;
        $('#sn-note', v).innerHTML = (!s.pawnio ? PAWNIO_NOTE : !s.elevated ? adminNote() : '') + (s.notes || []).map(n => `<div class="note warn">${esc(n)}</div>`).join('');
      }
      $('#sn', v).innerHTML = s.groups.map(g => {
        const items = g.items.filter(i => threads || !/^(Thread|Cœur) #/.test(i.l) || g.id !== 'cpu' || i.k === 'temp');
        const kinds = [...new Set(items.map(i => i.k))];
        return `<div class="card glass sensor"><h3><span class="sicon">${icon[g.icon] || '•'}</span>${esc(g.name)}</h3><table class="table"><thead><tr><th>Capteur</th><th class="r">Valeur</th><th class="r">Min</th><th class="r">Max</th></tr></thead><tbody>${kinds.map(k => `<tr class="kind"><td colspan="4">${KIND_NAME[k]}</td></tr>${items.filter(i => i.k === k).map(i => `<tr><td>${esc(i.l)}</td><td class="r val${tempClass(i.k, i.v)}">${fmtVal(i.k, i.v)}</td><td class="r muted">${fmtVal(i.k, i.min)}</td><td class="r muted${tempClass(i.k, i.max)}">${fmtVal(i.k, i.max)}</td></tr>`).join('')}`).join('')}</tbody></table></div>`;
      }).join('');
      $('#sn-since', v).textContent = `Relevés depuis ${fmtDuration(s.since)}`;
    } catch (e) { $('#sn', v).innerHTML = `<div class="note warn">${esc(e.message)}</div>`; }
    busy = false;
  };
  v.addEventListener('click', e => { if (e.target.closest('#sn-reset')) bao.call('sensors.reset').then(tick); });
  $('#sn-threads', v).onchange = e => { threads = e.target.checked; tick(); };
  await tick();
  const id = setInterval(tick, 1000);
  router.cleanup.push(() => clearInterval(id));
};

// ── tests de stabilité ───────────────────────────────────────────────────
const STRESS_LIMITS = { cpu: 95, gpu: 90 };
views.stress = async (v, live) => {
  const threads = navigator.hardwareConcurrency || 8;
  const info = await bao.call('info');
  if (!live()) return;
  v.innerHTML = `<h1>Tests de stabilité</h1><p class="lead">Mettez le processeur, la mémoire ou la carte graphique à 100 % pour vérifier qu'ils tiennent la charge (après un surcadençage, une sous-tension, un changement de pâte thermique ou des plantages en jeu), et mesurez la vitesse de vos disques.</p>
    <div class="note info">Les tests s'arrêtent seuls si le processeur dépasse ${STRESS_LIMITS.cpu} °C ou la carte graphique ${STRESS_LIMITS.gpu} °C. Le PC chauffe et ventile fort pendant un test : c'est normal.</div>
    <div class="card glass" id="st-live" hidden><h3>En cours : <span id="st-title"></span></h3><div class="stress-grid" id="st-grid"></div><div id="st-msg"></div><div class="row" style="margin-top:10px"><button class="btn danger" id="st-stop">Arrêter</button></div></div>
    <div class="cards" id="st-cards">
      <div class="card glass"><h3>Processeur</h3><div class="muted small" style="margin-bottom:10px">Calcul flottant intensif (AVX2/FMA si disponible) sur chaque thread. Chaque résultat est comparé à une référence : une seule différence révèle un processeur instable.</div>
        <div class="row"><select class="field" id="cpu-threads"><option value="0">Tous les threads (${threads})</option><option value="${Math.max(1, threads / 2)}">La moitié (${Math.max(1, threads / 2)})</option><option value="1">Un seul thread</option></select><select class="field" id="cpu-min">${dur()}</select></div>
        <div class="row" style="margin-top:10px"><button class="btn primary" data-start="cpu">Lancer</button></div></div>
      <div class="card glass"><h3>Mémoire vive</h3><div class="muted small" style="margin-bottom:10px">Écrit puis relit des motifs dans une grande partie de la mémoire libre. Une erreur signale une barrette ou un profil XMP/EXPO instable.</div>
        <div class="row"><select class="field" id="mem-pct"><option value="50">50 % de la mémoire libre</option><option value="70" selected>70 %</option><option value="85">85 %</option></select><select class="field" id="mem-min">${dur()}</select></div>
        <div class="row" style="margin-top:10px"><button class="btn primary" data-start="mem">Lancer</button></div></div>
      <div class="card glass"><h3>Carte graphique</h3><div class="muted small" style="margin-bottom:10px">Rendu 3D très lourd en continu (WebGL). Surveillez la température et les artefacts à l'écran ; un plantage du pilote signale une carte ou un surcadençage instable.</div>
        <div class="row"><select class="field" id="gpu-min">${dur()}</select></div>
        <div class="row" style="margin-top:10px"><button class="btn primary" data-start="gpu">Lancer</button></div></div>
      <div class="card glass"><h3>Vitesse du disque</h3><div class="muted small" style="margin-bottom:10px">Lecture et écriture séquentielles (gros fichiers) et aléatoires de 4 Ko (petits fichiers, ce qui compte pour la réactivité). Un fichier de test temporaire est créé puis supprimé.</div>
        <div class="row"><select class="field" id="disk-drive">${info.drives.map(d => `<option value="${esc(d.drive[0])}">${esc(d.drive)} (${fmtSize(d.free)} libres)</option>`).join('')}</select><select class="field" id="disk-size"><option value="512">512 Mo</option><option value="1024" selected>1 Go</option><option value="4096">4 Go</option></select></div>
        <div class="row" style="margin-top:10px"><button class="btn primary" data-start="disk">Mesurer</button></div><div class="tool-out" id="disk-out"></div></div>
    </div>
    <div id="gpu-stage" hidden><canvas id="gpu-canvas"></canvas><div class="gpu-hud" id="gpu-hud"></div><button class="btn danger" id="gpu-stop">Arrêter</button></div>`;
  function dur() { return `<option value="10">10 minutes</option><option value="30">30 minutes</option><option value="60">1 heure</option><option value="0">Sans limite</option><option value="1">1 minute</option>`; }
  let poll = 0, gpu = null;
  const grid = $('#st-grid', v);
  const showLive = (title, on) => { $('#st-live', v).hidden = !on; $('#st-title', v).textContent = title; $('#st-cards', v).style.opacity = on ? .5 : 1; };
  const sensorPanel = s => {
    const cpu = s.groups.find(g => g.id === 'cpu'), gp = s.groups.find(g => g.icon === 'gpu');
    const pick = (g, re) => g?.items.find(i => re.test(i.l));
    const cells = [
      ['Processeur', pick(cpu, /Tctl|boîtier/)], ['Puissance processeur', pick(cpu, /^Puissance/)], ['Fréquence max.', pick(cpu, /maximale/)], ['Charge processeur', pick(cpu, /Charge totale/)],
      ['Carte graphique', pick(gp, /^Processeur graphique/)], ['Charge graphique', pick(gp, /^Charge/)], ['Puissance graphique', pick(gp, /^Puissance$/)],
    ].filter(c => c[1]);
    return cells.map(([n, i]) => `<div class="stat"><div class="muted small">${n}</div><div class="big${tempClass(i.k, i.v)}">${fmtVal(i.k, i.v)}</div><div class="muted small">max ${fmtVal(i.k, i.max)}</div></div>`).join('');
  };
  const watch = kind => {
    clearInterval(poll);
    poll = setInterval(async () => {
      if (!live()) return clearInterval(poll);
      const [s, st] = await Promise.all([bao.call('sensors'), kind === 'gpu' ? null : bao.call('stress.status')]);
      const cpuT = s.groups.find(g => g.id === 'cpu')?.items.find(i => i.k === 'temp')?.v;
      const gpuT = s.groups.find(g => g.icon === 'gpu')?.items.find(i => i.k === 'temp')?.v;
      let head = '';
      if (st) {
        head = `<div class="stat"><div class="muted small">Durée</div><div class="big">${fmtDuration(st.elapsed)}${st.limit ? ` / ${fmtDuration(st.limit)}` : ''}</div></div><div class="stat"><div class="muted small">${kind === 'cpu' ? 'Calculs vérifiés' : 'Passes complètes'}</div><div class="big">${nf0.format(st.iterations)}</div>${st.bytes ? `<div class="muted small">${fmtSize(st.bytes)} testés</div>` : ''}</div><div class="stat"><div class="muted small">Erreurs</div><div class="big${st.errors ? ' bad' : ''}">${st.errors}</div></div>`;
        if (!st.running) { clearInterval(poll); finish(kind, st); }
      } else if (gpu) {
        head = `<div class="stat"><div class="muted small">Durée</div><div class="big">${fmtDuration((Date.now() - gpu.start) / 1000)}</div></div><div class="stat"><div class="muted small">Images/s</div><div class="big">${gpu.fps}</div></div>`;
      }
      grid.innerHTML = head + sensorPanel(s);
      if ((cpuT >= STRESS_LIMITS.cpu && kind !== 'gpu') || (gpuT >= STRESS_LIMITS.gpu && kind === 'gpu')) {
        $('#st-msg', v).innerHTML = `<div class="note bad">Température trop élevée (${fmtVal('temp', kind === 'gpu' ? gpuT : cpuT)}) : test arrêté. Vérifiez le refroidissement (ventilateurs, pâte thermique, poussière).</div>`;
        stopAll();
      }
    }, 1000);
    router.cleanup.push(() => clearInterval(poll));
  };
  const finish = (kind, st) => {
    showLive('', false);
    const ok = !st.errors;
    const msg = ok ? `<div class="note ok">Test ${kind === 'cpu' ? 'du processeur' : 'de la mémoire'} terminé après ${fmtDuration(st.elapsed)} : <b>aucune erreur</b>.</div>`
      : `<div class="note bad">Test terminé avec <b>${st.errors} erreur(s)</b> : ${kind === 'cpu' ? 'le processeur est instable (surcadençage, sous-tension ou surchauffe). Revenez aux réglages d\'origine dans le BIOS.' : 'la mémoire est instable. Essayez sans profil XMP/EXPO, ou testez les barrettes une par une.'}<div class="mono small">${esc(st.firstError || '')}</div></div>`;
    $('#st-cards', v).insertAdjacentHTML('beforebegin', `<div class="st-result">${msg}</div>`);
    journalNote(`Test de stabilité ${kind === 'cpu' ? 'processeur' : 'mémoire'} : ${ok ? 'aucune erreur' : st.errors + ' erreur(s)'} en ${fmtDuration(st.elapsed)}`);
  };
  const journalNote = title => bao.call('journal.add', { title, detail: '' }).catch(() => { });
  const stopAll = () => { bao.call('stress.stop'); stopGpu(); };
  const stopGpu = () => {
    if (!gpu) return;
    cancelAnimationFrame(gpu.raf); gpu.gl.getExtension('WEBGL_lose_context')?.loseContext();
    const secs = (Date.now() - gpu.start) / 1000;
    $('#gpu-stage', v).hidden = true; showLive('', false); clearInterval(poll);
    $('#st-cards', v).insertAdjacentHTML('beforebegin', `<div class="st-result"><div class="note ${gpu.lost ? 'bad' : 'ok'}">Test de la carte graphique ${gpu.lost ? '<b>interrompu par une perte du pilote graphique</b> : carte ou surcadençage instable, ou pilote défaillant.' : `terminé après ${fmtDuration(secs)} sans plantage du pilote`}.</div></div>`);
    journalNote(`Test de stabilité carte graphique : ${gpu.lost ? 'pilote perdu' : 'sans plantage'} en ${fmtDuration(secs)}`);
    gpu = null;
  };
  // quitter la page arrête le test : la surveillance de température vit ici
  router.cleanup.push(() => { bao.call('stress.stop'); if (gpu) { cancelAnimationFrame(gpu.raf); gpu = null; } });
  v.addEventListener('click', async e => {
    if (e.target.closest('#st-stop')) { stopAll(); return; }
    if (e.target.closest('#gpu-stop')) { stopGpu(); return; }
    const b = e.target.closest('[data-start]'); if (!b) return;
    $$('.st-result', v).forEach(x => x.remove());
    const kind = b.dataset.start;
    if (kind === 'disk') {
      const out = $('#disk-out', v), drive = $('#disk-drive', v).value, size = +$('#disk-size', v).value;
      b.disabled = true;
      out.innerHTML = '<div class="progress"><div class="spinner"></div><div data-line>Préparation…</div></div>';
      try {
        const r = await bao.call('bench.disk', { drive, sizeMb: size }, d => { const l = $('[data-line]', out); if (l) l.textContent = d.line; });
        const mb = x => nf0.format(x) + ' ' + UNITS.m + '/s';
        out.innerHTML = `<table class="table" style="margin-top:10px"><thead><tr><th></th><th class="r">Lecture</th><th class="r">Écriture</th></tr></thead><tbody><tr><td>Séquentiel (1 Mo)</td><td class="r val">${mb(r.seqRead)}</td><td class="r val">${mb(r.seqWrite)}</td></tr><tr><td>Aléatoire 4 Ko</td><td class="r val">${nf1.format(r.rndRead)} Mo/s<div class="muted small">${nf0.format(r.rndReadIops)} IOPS</div></td><td class="r val">${nf1.format(r.rndWrite)} Mo/s<div class="muted small">${nf0.format(r.rndWriteIops)} IOPS</div></td></tr></tbody></table><div class="muted small">Ordres de grandeur en lecture séquentielle : disque dur 100 à 250 Mo/s, SSD SATA 500 Mo/s, SSD NVMe 2 000 à 14 000 Mo/s.</div>`;
        journalNote(`Vitesse du disque ${drive}: : ${mb(r.seqRead)} en lecture, ${mb(r.seqWrite)} en écriture`);
      } catch (err) { out.innerHTML = `<div class="note warn">${esc(err.message)}</div>`; }
      b.disabled = false;
      return;
    }
    if (kind === 'gpu') { startGpu(+$('#gpu-min', v).value); return; }
    const minutes = +$(`#${kind}-min`, v).value;
    try {
      await bao.call('stress.start', kind === 'cpu' ? { kind, threads: +$('#cpu-threads', v).value, minutes } : { kind, minutes, memPct: +$('#mem-pct', v).value });
      showLive(kind === 'cpu' ? 'test du processeur' : 'test de la mémoire', true);
      $('#st-msg', v).innerHTML = '';
      watch(kind);
    } catch (err) { toast('Échec : ' + err.message); }
  });
  function startGpu(minutes) {
    const stage = $('#gpu-stage', v), canvas = $('#gpu-canvas', v);
    stage.hidden = false;
    const gl = canvas.getContext('webgl2', { antialias: false, powerPreference: 'high-performance' });
    if (!gl) { stage.hidden = true; toast('WebGL indisponible : test impossible'); return; }
    const sh = (type, src) => { const s = gl.createShader(type); gl.shaderSource(s, src); gl.compileShader(s); return s; };
    const prog = gl.createProgram();
    gl.attachShader(prog, sh(gl.VERTEX_SHADER, '#version 300 es\nin vec2 p;void main(){gl_Position=vec4(p,0,1);}'));
    // fractale 3D (Mandelbulb) calculée par lancer de rayons : charge maximale du GPU
    gl.attachShader(prog, sh(gl.FRAGMENT_SHADER, `#version 300 es
precision highp float;uniform vec2 r;uniform float t;out vec4 o;
float de(vec3 p){vec3 z=p;float dr=1.,rr=0.;for(int i=0;i<12;i++){rr=length(z);if(rr>2.)break;float th=acos(z.z/rr)*8.+t*.3,ph=atan(z.y,z.x)*8.;dr=pow(rr,7.)*8.*dr+1.;z=pow(rr,8.)*vec3(sin(th)*cos(ph),sin(ph)*sin(th),cos(th))+p;}return .5*log(rr)*rr/dr;}
void main(){vec2 uv=(gl_FragCoord.xy*2.-r)/r.y;vec3 ro=vec3(0,0,-2.4),rd=normalize(vec3(uv,1.6));float c=cos(t*.2),s=sin(t*.2);ro.xz*=mat2(c,-s,s,c);rd.xz*=mat2(c,-s,s,c);
float d=0.;int k;for(k=0;k<256;k++){float h=de(ro+rd*d);if(h<.0004||d>6.)break;d+=h;}float g=float(k)/256.;o=vec4(vec3(.15+g*1.2,.5+g*.6,.9)*(1.-g*.5)*(d<6.?1.:.12),1);}`));
    gl.linkProgram(prog); gl.useProgram(prog);
    const buf = gl.createBuffer(); gl.bindBuffer(gl.ARRAY_BUFFER, buf);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
    const loc = gl.getAttribLocation(prog, 'p'); gl.enableVertexAttribArray(loc); gl.vertexAttribPointer(loc, 2, gl.FLOAT, false, 0, 0);
    const ur = gl.getUniformLocation(prog, 'r'), ut = gl.getUniformLocation(prog, 't');
    gpu = { gl, start: Date.now(), frames: 0, fps: 0, last: Date.now(), raf: 0, lost: false };
    canvas.addEventListener('webglcontextlost', e => { e.preventDefault(); if (gpu) { gpu.lost = true; stopGpu(); } }, { once: true });
    const frame = () => {
      if (!gpu) return;
      const w = canvas.clientWidth * devicePixelRatio | 0, h = canvas.clientHeight * devicePixelRatio | 0;
      if (canvas.width !== w || canvas.height !== h) { canvas.width = w; canvas.height = h; gl.viewport(0, 0, w, h); }
      gl.uniform2f(ur, w, h); gl.uniform1f(ut, (Date.now() - gpu.start) / 1000);
      gl.drawArrays(gl.TRIANGLES, 0, 3);
      gpu.frames++;
      if (Date.now() - gpu.last >= 1000) { gpu.fps = gpu.frames; gpu.frames = 0; gpu.last = Date.now(); $('#gpu-hud', v).textContent = `${gpu.fps} images/s`; }
      if (minutes && Date.now() - gpu.start > minutes * 60000) { stopGpu(); return; }
      gpu.raf = requestAnimationFrame(frame);
    };
    showLive('test de la carte graphique', true);
    watch('gpu');
    gpu.raf = requestAnimationFrame(frame);
  }
};

// ── Mode Dieu ────────────────────────────────────────────────────────────
views.godmode = async (v, live) => {
  v.innerHTML = `<h1>Mode Dieu</h1><p class="lead">Les quelque 200 réglages du Panneau de configuration que Windows rassemble dans son « Mode Dieu », classés et cherchables. Un clic ouvre le réglage.</p>
    <div class="toolbar"><input class="field grow" id="q" placeholder="Rechercher un réglage (ex. : souris, pare-feu, polices, son…)" style="max-width:420px"><span class="muted small" id="cnt"></span></div><div id="gm"><div class="spinner big"></div></div>`;
  const r = await ps('godmode');
  if (!live()) return;
  const items = r.items || [];
  const norm = s => String(s).toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '');
  const render = q => {
    q = norm(q);
    const list = items.filter(i => !q || norm(i.name + ' ' + i.cat + ' ' + i.keys).includes(q));
    const cats = [...new Set(list.map(i => i.cat))].sort((a, b) => a.localeCompare(b));
    $('#gm', v).innerHTML = cats.map(c => `<h2>${esc(c || 'Autres')}</h2><div class="gm-grid">${list.filter(i => i.cat === c).map(i => `<button class="gm-item glass" data-p="${esc(i.path)}">${esc(i.name)}</button>`).join('')}</div>`).join('') || '<div class="empty">Aucun réglage trouvé</div>';
    $('#cnt', v).textContent = plural(list.length, 'réglage', 'réglages');
  };
  render('');
  $('#q', v).oninput = e => render(e.target.value);
  v.addEventListener('click', e => { const b = e.target.closest('[data-p]'); if (b) bao.call('godmode.open', { path: b.dataset.p }).catch(err => toast('Échec : ' + err.message)); });
};

// ── mes logiciels (jeremdevgit) ─────────────────────────────────────────
const MY_APPS = [
  { id: 'pomme', icon: '🍎', t: 'Pomme', os: 'Windows', d: 'Lecteur de musique léger pour Apple Music et vos fichiers audio locaux : bibliothèque, listes de lecture, paroles, égaliseur.' },
  { id: 'rjb', icon: '🌈', t: 'rJb', os: 'Windows', d: 'L\'éclairage RGB de tous vos périphériques et composants dans une seule application légère : claviers, souris, casques, mémoire, carte mère et carte graphique.' },
  { id: 'boite-a-outils', icon: '🧰', t: 'Boîte à outils pour Mac', os: 'macOS', d: 'La même idée pour le Mac : nettoyage, espace disque, doublons, désinstallation complète, démarrage, confidentialité, batterie, capteurs.' },
  { id: 'ludotheque', icon: '🎮', t: 'Ludothèque', os: 'macOS', d: 'Tous vos jeux au même endroit : Steam, Epic, GOG, Xbox, PlayStation, émulateurs… avec statistiques, succès et mode TV.' },
  { id: 'suite-libre', icon: '🔐', t: 'Suite Libre', os: 'Navigateur', d: 'Six outils dans le navigateur, sans compte : QR codes, flou d\'images, compression de photos, conversions, moyennes, mots de passe.' },
  { id: 'batailles-de-france', icon: '⚔️', t: 'Batailles de France', os: 'Navigateur', d: 'Jeu de stratégie en temps réel sur les cartes de Lyon, Paris, Marseille, Bordeaux et Strasbourg, en solo ou en ligne.' },
];
views.downloads = async (v) => {
  v.innerHTML = `<h1>Mes logiciels</h1><p class="lead">La Boîte à outils est créée par <b>jeremdevgit</b>. Voici ses autres logiciels, libres, gratuits et sans publicité : chaque bouton ouvre la page de téléchargement officielle sur GitHub.</p>
    <div class="row" style="margin-bottom:16px"><button class="btn" data-open="profil">Tous mes logiciels sur GitHub</button></div>
    <div class="cards">${MY_APPS.map(m => `<div class="card glass app-card"><div class="app-ico">${m.icon}</div><h3>${esc(m.t)}</h3><div class="muted small">${esc(m.os)}</div><div class="muted small" style="margin:6px 0 12px">${esc(m.d)}</div><div class="row"><button class="btn primary" data-open="${esc(m.id)}">Télécharger</button></div></div>`).join('')}</div>`;
  v.addEventListener('click', async e => {
    const b = e.target.closest('[data-open]'); if (!b) return;
    try { await bao.call('apps.open', { id: b.dataset.open }); toast('Page ouverte dans votre navigateur'); } catch (err) { toast('Échec : ' + err.message); }
  });
};

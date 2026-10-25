/* Safari Spotter: Live-Tiererkennung mit Tracking, Sichtungen, Fahrtaufzeichnung und Korrektur-Loop. Alles läuft auf dem Gerät. */
(() => {
'use strict';
const VERSION = '1.3.0';
const HEAD_DIR = 'models/head/1.2.1/';
const $ = (s) => document.querySelector(s);
const $$ = (s) => Array.from(document.querySelectorAll(s));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/* ---------- Artenwissen ---------- */
const ANIMAL_COCO = new Set(['bird', 'cat', 'dog', 'horse', 'sheep', 'cow', 'elephant', 'bear', 'zebra', 'giraffe']);
const BLOCKED_COCO = new Set(['person', 'bicycle', 'car', 'motorcycle', 'bus', 'train', 'truck', 'boat', 'airplane']);
const COCO_DIRECT = { elephant: 'Elefant', zebra: 'Zebra', giraffe: 'Giraffe' };
const COCO_FALLBACK = { bird: 'Vogel', cat: 'Raubkatze?', dog: 'Hundeartiges?', horse: 'Antilope / Zebra?', sheep: 'Antilope?', cow: 'Antilope / Büffel?', elephant: 'Elefant', bear: 'Grosses Tier?', zebra: 'Zebra', giraffe: 'Giraffe' };
// ImageNet-Rückfall, falls der Artenkopf nicht geladen werden kann
const SPECIES = {
  'african elephant': 'Elefant', 'indian elephant': 'Elefant', 'tusker': 'Elefant', 'zebra': 'Zebra', 'lion': 'Löwe', 'leopard': 'Leopard', 'cheetah': 'Gepard',
  'hippopotamus': 'Flusspferd', 'water buffalo': 'Kaffernbüffel', 'impala': 'Impala', 'gazelle': 'Springbock', 'hartebeest': 'Kuhantilope', 'warthog': 'Warzenschwein',
  'ostrich': 'Strauss', 'baboon': 'Pavian', 'guenon': 'Meerkatze', 'hyena': 'Hyäne', 'african hunting dog': 'Wildhund', 'meerkat': 'Erdmännchen', 'mongoose': 'Manguste',
  'badger': 'Honigdachs', 'porcupine': 'Stachelschwein', 'african crocodile': 'Nilkrokodil', 'komodo dragon': 'Waran', 'vulture': 'Geier', 'hornbill': 'Nashornvogel',
  'bustard': 'Riesentrappe', 'flamingo': 'Flamingo', 'goose': 'Nilgans', 'box turtle': 'Schildkröte', 'terrapin': 'Schildkröte', 'triceratops': 'Nashorn?'
};
const COLORS = ['#f0a93a', '#5ec8f2', '#9be36a', '#f27ab0', '#c9a3ff', '#55e0c8', '#ffd166', '#ff9f6e'];
const BIG5 = [
  { label: 'Elefant', test: (n) => n === 'Elefant' },
  { label: 'Nashorn', test: (n) => /nashorn/i.test(n) },
  { label: 'Büffel', test: (n) => n === 'Kaffernbüffel' },
  { label: 'Löwe', test: (n) => /^löw/i.test(n) },
  { label: 'Leopard', test: (n) => n === 'Leopard' }
];
const FONT = '-apple-system, BlinkMacSystemFont, "Helvetica Neue", Arial, sans-serif';
const speciesFor = (c) => SPECIES[String(c).split(',')[0].trim().toLowerCase()] || null;

/* ---------- Speicher ---------- */
const store = {
  get(k, d) { try { const v = localStorage.getItem(k); return v == null ? d : JSON.parse(v); } catch (e) { return d; } },
  set(k, v) { try { localStorage.setItem(k, JSON.stringify(v)); } catch (e) { toast('Speicher voll, Eintrag nicht gesichert'); } }
};
// IndexedDB für Korrekturen (Bildausschnitte)
const idb = {
  db: null,
  open() {
    if (this.db) return Promise.resolve(this.db);
    return new Promise((res, rej) => {
      if (!('indexedDB' in window)) { rej(new Error('kein IndexedDB')); return; }
      const r = indexedDB.open('spotter', 1);
      r.onupgradeneeded = () => { const d = r.result; if (!d.objectStoreNames.contains('corrections')) d.createObjectStore('corrections', { keyPath: 'id', autoIncrement: true }); };
      r.onsuccess = () => { this.db = r.result; res(this.db); };
      r.onerror = () => rej(r.error);
    });
  },
  tx(mode, fn) {
    return this.open().then((d) => new Promise((res, rej) => {
      const t = d.transaction('corrections', mode); const s = t.objectStore('corrections');
      let out; try { out = fn(s); } catch (e) { rej(e); return; }
      t.oncomplete = () => res(out && 'result' in out ? out.result : out);
      t.onerror = () => rej(t.error);
    }));
  },
  add(item) { return this.tx('readwrite', (s) => s.add(item)); },
  put(item) { return this.tx('readwrite', (s) => s.put(item)); },
  del(id) { return this.tx('readwrite', (s) => s.delete(id)); },
  all() { return this.open().then((d) => new Promise((res, rej) => { const r = d.transaction('corrections').objectStore('corrections').getAll(); r.onsuccess = () => res(r.result || []); r.onerror = () => rej(r.error); })).catch(() => []); }
};

/* ---------- Zustand ---------- */
const settings = Object.assign({ threshold: 0.4, labels: true, burnIn: true, far: 'on', res: '720', region: 'auto', gps: true, collect: true }, store.get('ss.settings', {}));
let sightings = store.get('ss.sightings', []);
if (!Array.isArray(sightings)) sightings = [];
sightings.forEach((e, i) => { if (!e.id) e.id = 'm' + i + '-' + e.t; if (!e.n) e.n = 1; });
let trip = store.get('ss.trip', null);
if (!trip || !Array.isArray(trip.points)) trip = { active: false, startedAt: 0, points: [], dist: 0 };
let trips = store.get('ss.trips', []);
if (!Array.isArray(trips)) trips = [];

const video = $('#cam'), overlay = $('#overlay'), stage = $('#stage'), viewportEl = $('#viewport');
const octx = overlay.getContext('2d');
const detCanvas = document.createElement('canvas'); const dctx = detCanvas.getContext('2d');
const clsCanvas = document.createElement('canvas'); clsCanvas.width = clsCanvas.height = 224; const cctx = clsCanvas.getContext('2d');
const thumbCanvas = document.createElement('canvas'); const tctx = thumbCanvas.getContext('2d');
const recCanvas = $('#recCanvas'); const rctx = recCanvas.getContext('2d');

let detector = null, classifier = null, head = null, headMeta = null, info = {}, regionsCfg = { factor: 0.25, regions: [] };
let stream = null, running = false, currentDeviceId = null;
let hint = null, hintRuns = [], lastHintAt = 0, hintFlip = false;
let zoom = 1, hwZoom = null;
let tracks = [], nextId = 1, detFps = 0, sightSeq = 0;
let recorder = null, chunks = [], recStart = 0, recTimerId = 0, micStream = null, recMime = '', isRecording = false, recMap = null, lastClip = null, recStamp = '';
let wakeLock = null;
let gpsWatch = null, lastFix = null, autoRegion = null;
let reviewCount = 0, corrCtx = null, photoQueue = [], photoCur = null, map = null, mapLayers = null, activeTab = 'list';

/* ---------- UI-Helfer ---------- */
function setStatus(text, live) { $('#statusText').textContent = text; $('#status').classList.toggle('live', !!live); }
let toastId = 0;
function toast(msg, ms = 2200) { const t = $('#toast'); t.textContent = msg; t.hidden = false; clearTimeout(toastId); toastId = setTimeout(() => { t.hidden = true; }, ms); }
function openSheet(id) { $('#scrim').hidden = false; $(id).hidden = false; }
function closeSheets() { $('#scrim').hidden = true; $$('.sheet').forEach((s) => { s.hidden = true; }); }
function closeTop(id) { $(id).hidden = true; if (!$$('.sheet').some((s) => !s.hidden)) $('#scrim').hidden = true; }
$('#scrim').addEventListener('click', closeSheets);
$$('[data-close]').forEach((b) => b.addEventListener('click', () => { const sh = b.closest('.sheet'); if (sh.classList.contains('top')) closeTop('#' + sh.id); else closeSheets(); }));
const fmtTime = (ts) => new Date(ts).toLocaleTimeString('de-CH', { hour: '2-digit', minute: '2-digit' });
const fmtDate = (ts) => new Date(ts).toLocaleDateString('de-CH');
const fmtZoom = (z) => z.toFixed(1).replace('.', ',') + '×';
const fmtKm = (m) => (m / 1000).toFixed(1).replace('.', ',');
const pad2 = (n) => String(n).padStart(2, '0');
const fmtDur = (ms) => { const s = Math.max(0, Math.floor(ms / 1000)); return Math.floor(s / 3600) + ':' + pad2(Math.floor(s / 60) % 60); };
const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
function shareOrDownload(blob, filename, title) {
  const file = new File([blob], filename, { type: blob.type });
  if (navigator.canShare && navigator.canShare({ files: [file] })) {
    return navigator.share({ files: [file], title }).catch((e) => { if (e && e.name !== 'AbortError') downloadBlob(blob, filename); });
  }
  downloadBlob(blob, filename); return Promise.resolve();
}
function downloadBlob(blob, filename) {
  const a = document.createElement('a'); a.href = URL.createObjectURL(blob); a.download = filename; document.body.appendChild(a); a.click();
  setTimeout(() => { URL.revokeObjectURL(a.href); a.remove(); }, 4000);
}
// Tabs im Sichtungs-Sheet
$$('#sheetSightings [role=tab]').forEach((b) => b.addEventListener('click', () => showTab(b.dataset.tab)));
function showTab(tab) {
  activeTab = tab;
  $$('#sheetSightings [role=tab]').forEach((b) => b.setAttribute('aria-selected', String(b.dataset.tab === tab)));
  $('#tabList').hidden = tab !== 'list'; $('#tabStats').hidden = tab !== 'stats'; $('#tabTrip').hidden = tab !== 'trip'; $('#tabReview').hidden = tab !== 'review';
  if (tab === 'stats') renderStats();
  if (tab === 'trip') { renderTrip(); setTimeout(renderMap, 50); }
  if (tab === 'review') renderReview();
}

/* ---------- Modelle und Daten ---------- */
const MODEL_FILES = [
  'models/cocossd/model.json', 'models/cocossd/group1-shard1of5', 'models/cocossd/group1-shard2of5', 'models/cocossd/group1-shard3of5', 'models/cocossd/group1-shard4of5', 'models/cocossd/group1-shard5of5',
  'models/mobilenet/model.json', 'models/mobilenet/group1-shard1of4.bin', 'models/mobilenet/group1-shard2of4.bin', 'models/mobilenet/group1-shard3of4.bin', 'models/mobilenet/group1-shard4of4.bin',
  HEAD_DIR + 'model.json', HEAD_DIR + 'weights.bin', HEAD_DIR + 'classes.json'
];
async function prefetchModels(onProgress) {
  let done = 0;
  await Promise.all(MODEL_FILES.map(async (u) => { const r = await fetch(u); if (!r.ok) throw new Error('Modelldatei fehlt: ' + u); await r.arrayBuffer(); done++; onProgress(done / MODEL_FILES.length); }));
}
async function loadModels() {
  const bar = $('#loadBar'), txt = $('#loadText');
  await tf.ready();
  try { await tf.setBackend('webgl'); await tf.ready(); } catch (e) { try { await tf.setBackend('cpu'); } catch (e2) { /* bleibt */ } }
  $('#backend').textContent = tf.getBackend();
  try { await prefetchModels((p) => { bar.style.width = Math.round(p * 70) + '%'; txt.textContent = 'Lade Modelle … ' + Math.round(p * 100) + ' %'; }); }
  catch (e) { console.warn(e); }
  txt.textContent = 'Modelle werden vorbereitet …'; bar.style.width = '80%';
  const [d, c, h, meta, inf, reg] = await Promise.all([
    cocoSsd.load({ base: 'lite_mobilenet_v2', modelUrl: 'models/cocossd/model.json' }),
    mobilenet.load({ version: 2, alpha: 1.0, modelUrl: 'models/mobilenet/model.json', inputRange: [0, 1] }),
    tf.loadLayersModel(HEAD_DIR + 'model.json').catch((e) => { console.warn('Artenkopf fehlt', e); return null; }),
    fetch(HEAD_DIR + 'classes.json').then((r) => (r.ok ? r.json() : null)).catch(() => null),
    fetch('data/species-info.json').then((r) => (r.ok ? r.json() : {})).catch(() => ({})),
    fetch('data/regions.json').then((r) => (r.ok ? r.json() : null)).catch(() => null)
  ]);
  detector = d; classifier = c; info = inf || {};
  if (reg && Array.isArray(reg.regions)) regionsCfg = reg;
  if (h && meta && meta.classes && meta.classes.length === h.outputs[0].shape[1]) {
    head = h; headMeta = meta;
    headMeta.classes.forEach((cl) => { cl.sensitive = !!(info[cl.key] && info[cl.key].sensitive); });
    tf.tidy(() => head.predict(tf.zeros([1, meta.dim || 1280])));
  }
  renderSpeciesList(); fillRegionSelect(); fillCorrSelect();
  bar.style.width = '100%';
  txt.textContent = 'Bereit. Erkennung läuft auf ' + (tf.getBackend() === 'webgl' ? 'der GPU' : 'der CPU (langsamer)') + ', nichts verlässt das Gerät.';
}
function classByName(name) { return headMeta ? headMeta.classes.find((c) => c.name === name) : null; }
function isSensitive(name) {
  if (!name) return false;
  const c = classByName(name); if (c && c.sensitive) return true;
  return headMeta ? headMeta.classes.some((x) => x.sensitive && x.group === name) : /nashorn/i.test(name);
}
function renderSpeciesList() {
  const ul = $('#speciesList'), h2 = $('#speciesTitle'), note = $('#speciesNote');
  if (!headMeta) return;
  const shown = headMeta.classes.filter((c) => !c.negative);
  ul.innerHTML = '';
  shown.forEach((c) => { const li = document.createElement('li'); const b = document.createElement('button'); b.type = 'button'; b.textContent = c.name; b.addEventListener('click', () => openProfile(c.key)); li.appendChild(b); ul.appendChild(li); });
  h2.textContent = 'Erkennt ' + shown.length + ' Arten';
  note.innerHTML = 'Eigenes Modell, trainiert mit Fotos aus iNaturalist (Stand ' + (headMeta.trained || '') + '). Im Test ' + headMeta.valTop1 + ' % richtige Art auf ' + headMeta.valPhotos + ' ungesehenen Fotos. Tipp auf eine Art zeigt den Steckbrief.';
}

/* ---------- Steckbriefe ---------- */
function openProfile(keyOrName) {
  let c = headMeta ? headMeta.classes.find((x) => x.key === keyOrName) || classByName(keyOrName) : null;
  if (!c && headMeta) c = headMeta.classes.find((x) => x.group === keyOrName && !x.negative);
  const i = c ? info[c.key] : null;
  $('#profName').textContent = c ? c.name : keyOrName;
  $('#profLatin').textContent = i ? i.latin + (i.en ? ' · ' + i.en : '') : '';
  const dl = $('#profBody'); dl.innerHTML = '';
  if (!i) { dl.innerHTML = '<dd class="small">Kein Steckbrief vorhanden.</dd>'; }
  else {
    const rows = [['Erkennen', i.id], ['Verwechslung', i.confuse], ['Grösse', i.size + (i.weight ? ', ' + i.weight : '')], ['Lebensweise', i.habits], ['Rote Liste', i.status]];
    if (i.big5) rows.unshift(['Big Five', 'Ja']);
    if (i.sensitive) rows.push(['Artenschutz', 'Standorte dieser Art speichert die App nur auf 10 km genau und gibt sie nie exakt weiter.']);
    rows.forEach(([k, v]) => { if (!v) return; const dt = document.createElement('dt'); dt.textContent = k; const dd = document.createElement('dd'); dd.textContent = v; dl.append(dt, dd); });
  }
  openSheet('#sheetProfile');
}

/* ---------- Kamera ---------- */
function stopStream() { if (stream) { stream.getTracks().forEach((t) => t.stop()); stream = null; } }
async function startCamera(deviceId) {
  stopStream();
  const w = settings.res === '1080' ? 1920 : 1280, h = settings.res === '1080' ? 1080 : 720;
  const vc = deviceId ? { deviceId: { exact: deviceId } } : { facingMode: { ideal: 'environment' } };
  Object.assign(vc, { width: { ideal: w }, height: { ideal: h }, frameRate: { ideal: 30 } });
  stream = await navigator.mediaDevices.getUserMedia({ video: vc, audio: false });
  video.srcObject = stream;
  try { await video.play(); } catch (e) { /* Nutzer hat schon geklickt */ }
  const track = stream.getVideoTracks()[0];
  const s = track.getSettings ? track.getSettings() : {};
  currentDeviceId = s.deviceId || deviceId || null;
  setupZoom(track);
  await listLenses();
}
function lensName(label, i) {
  const l = (label || '').toLowerCase();
  if (!label) return 'Kamera ' + (i + 1);
  if (l.includes('ultra')) return 'Ultraweitwinkel 0,5×';
  if (l.includes('tele')) return 'Teleobjektiv';
  if (l.includes('front')) return 'Frontkamera';
  if (l.includes('dual') || l.includes('triple')) return 'Rückkamera (Auto)';
  if (l.includes('back') || l.includes('rear') || l.includes('rück')) return 'Rückkamera 1×';
  return label;
}
async function listLenses() {
  const sel = $('#lens');
  try {
    const devs = (await navigator.mediaDevices.enumerateDevices()).filter((d) => d.kind === 'videoinput');
    if (devs.length < 2) { sel.hidden = true; return; }
    sel.innerHTML = '';
    devs.forEach((d, i) => { const o = document.createElement('option'); o.value = d.deviceId; o.textContent = lensName(d.label, i); if (d.deviceId === currentDeviceId) o.selected = true; sel.appendChild(o); });
    sel.hidden = false;
  } catch (e) { sel.hidden = true; }
}
$('#lens').addEventListener('change', async (e) => {
  try { await startCamera(e.target.value); toast(e.target.selectedOptions[0].textContent); } catch (err) { toast('Objektivwechsel fehlgeschlagen'); console.error(err); }
});
function setupZoom(track) {
  hwZoom = null; zoom = 1;
  const slider = $('#zoom');
  try { const caps = track.getCapabilities ? track.getCapabilities() : {}; if (caps && caps.zoom && caps.zoom.max > caps.zoom.min) hwZoom = { track, min: caps.zoom.min, max: Math.min(caps.zoom.max, 15), step: caps.zoom.step || 0.1 }; } catch (e) { hwZoom = null; }
  if (hwZoom) { slider.min = hwZoom.min; slider.max = hwZoom.max; slider.step = hwZoom.step; const s = track.getSettings ? track.getSettings() : {}; slider.value = s.zoom || hwZoom.min; }
  else { slider.min = 1; slider.max = 4; slider.step = 0.1; slider.value = 1; }
  stage.style.transform = '';
  $('#zoomVal').textContent = fmtZoom(parseFloat(slider.value));
  $('#zoomWrap').hidden = false;
}
let zoomTimer = 0;
$('#zoom').addEventListener('input', (e) => {
  const v = parseFloat(e.target.value);
  $('#zoomVal').textContent = fmtZoom(v);
  if (hwZoom) { clearTimeout(zoomTimer); zoomTimer = setTimeout(() => { hwZoom.track.applyConstraints({ advanced: [{ zoom: v }] }).catch(() => {}); }, 40); }
  else { zoom = v; stage.style.transform = v > 1 ? 'scale(' + v + ')' : ''; }
});
function visibleRegion() {
  const vw = video.videoWidth, vh = video.videoHeight;
  const W = viewportEl.clientWidth || 1, H = viewportEl.clientHeight || 1;
  const s = Math.max(W / vw, H / vh);
  const z = hwZoom ? 1 : zoom;
  const w = Math.min(vw, W / (s * z)), h = Math.min(vh, H / (s * z));
  return { x: (vw - w) / 2, y: (vh - h) / 2, w, h, cssScale: s * z };
}
function syncCanvases() {
  const vw = video.videoWidth, vh = video.videoHeight;
  if (!vw || !vh) return false;
  if (overlay.width !== vw || overlay.height !== vh) { overlay.width = vw; overlay.height = vh; }
  return true;
}

/* ---------- GPS, Region, Fahrt ---------- */
const R_EARTH = 6371000;
function haversine(a, b) {
  const toR = Math.PI / 180, dLat = (b.lat - a.lat) * toR, dLon = (b.lon - a.lon) * toR;
  const s = Math.sin(dLat / 2) ** 2 + Math.cos(a.lat * toR) * Math.cos(b.lat * toR) * Math.sin(dLon / 2) ** 2;
  return 2 * R_EARTH * Math.asin(Math.sqrt(s));
}
// Artenschutz: Standort auf ein 10-km-Raster runden (Zellenmitte), so hält auch das Gerät nie den exakten Punkt
function coarsen(lat, lon) {
  const cell = 10000 / 111320; // Grad Breite pro 10 km
  const cellLon = cell / Math.max(0.2, Math.cos(lat * Math.PI / 180));
  return { lat: (Math.floor(lat / cell) + 0.5) * cell, lon: (Math.floor(lon / cellLon) + 0.5) * cellLon };
}
function startGps() {
  if (!settings.gps || !navigator.geolocation || gpsWatch != null) return;
  try {
    gpsWatch = navigator.geolocation.watchPosition(onFix, (err) => { $('#gpsState').textContent = 'GPS: ' + (err.code === 1 ? 'nicht erlaubt' : 'kein Signal'); }, { enableHighAccuracy: true, maximumAge: 4000, timeout: 20000 });
    $('#gpsState').textContent = 'GPS wartet';
  } catch (e) { gpsWatch = null; }
}
function stopGps() { if (gpsWatch != null && navigator.geolocation) navigator.geolocation.clearWatch(gpsWatch); gpsWatch = null; $('#gpsState').textContent = 'GPS aus'; }
function onFix(pos) {
  const c = pos.coords;
  lastFix = { lat: c.latitude, lon: c.longitude, acc: c.accuracy || 999, t: Date.now() };
  $('#gpsState').textContent = 'GPS ±' + Math.round(lastFix.acc) + ' m';
  updateAutoRegion();
  if (trip.active) addTrackPoint(lastFix);
}
function updateAutoRegion() {
  if (!lastFix) return;
  const r = regionsCfg.regions.find((x) => lastFix.lat >= x.bbox[0] && lastFix.lon >= x.bbox[1] && lastFix.lat <= x.bbox[2] && lastFix.lon <= x.bbox[3]) || null;
  if ((r && r.key) !== (autoRegion && autoRegion.key)) { autoRegion = r; updateRegionNote(); if (r && settings.region === 'auto') toast('Region: ' + r.name, 2600); }
}
function currentRegion() {
  if (settings.region === 'none') return null;
  if (settings.region === 'auto') return autoRegion;
  return regionsCfg.regions.find((x) => x.key === settings.region) || null;
}
function updateRegionNote() {
  const r = currentRegion();
  $('#regionNote').textContent = r ? 'Aktiv: ' + r.name : (settings.region === 'auto' ? (lastFix ? 'Kein bekanntes Gebiet, kein Vorwissen aktiv' : 'Wartet auf GPS') : 'Kein Vorwissen aktiv');
}
function fillRegionSelect() {
  const sel = $('#region'); sel.innerHTML = '';
  [['auto', 'Automatisch (GPS)'], ['none', 'Keine Region']].concat(regionsCfg.regions.map((r) => [r.key, r.name])).forEach(([v, n]) => { const o = document.createElement('option'); o.value = v; o.textContent = n; sel.appendChild(o); });
  sel.value = settings.region;
  updateRegionNote();
}
function applyPrior(probs) {
  const r = currentRegion();
  if (!r || !headMeta) return probs;
  const bad = new Set(r.unlikely || []);
  const out = probs.map((p, i) => (bad.has(headMeta.classes[i].key) ? p * (regionsCfg.factor || 0.25) : p));
  const sum = out.reduce((a, b) => a + b, 0) || 1;
  return out.map((p) => p / sum);
}
// Fahrtaufzeichnung
function addTrackPoint(fix) {
  const pts = trip.points, last = pts[pts.length - 1];
  const here = { lat: fix.lat, lon: fix.lon };
  if (last) {
    const d = haversine({ lat: last[1], lon: last[2] }, here);
    if (d < 8 && fix.t - last[0] < 20000) return;
    if (fix.acc <= 60 && d >= 8 && d < 2000) trip.dist += d;
  }
  pts.push([fix.t, Math.round(fix.lat * 1e5) / 1e5, Math.round(fix.lon * 1e5) / 1e5]);
  if (pts.length > 6000) pts.splice(0, pts.length - 6000);
  if (pts.length % 5 === 0) store.set('ss.trip', trip);
  updateKmPill();
}
function updateKmPill() { const p = $('#kmPill'); p.hidden = !trip.active; if (trip.active) p.textContent = fmtKm(trip.dist) + ' km'; }
function startTrip() {
  trip = { active: true, startedAt: Date.now(), points: [], dist: 0 }; store.set('ss.trip', trip);
  if (!settings.gps) { settings.gps = true; store.set('ss.settings', settings); $('#swGps').setAttribute('aria-checked', 'true'); }
  startGps(); updateKmPill(); renderTrip(); toast('Fahrt gestartet');
}
function stopTrip() {
  if (!trip.active) return;
  const done = { startedAt: trip.startedAt, endedAt: Date.now(), dist: trip.dist, points: trip.points, sightings: sightings.filter((s) => s.t >= trip.startedAt).reduce((a, s) => a + (s.n || 1), 0) };
  trips.unshift(done); trips = trips.slice(0, 7); store.set('ss.trips', trips);
  trip = { active: false, startedAt: 0, points: [], dist: 0 }; store.set('ss.trip', trip);
  updateKmPill(); renderTrip(); toast('Fahrt beendet: ' + fmtKm(done.dist) + ' km');
}
$('#btnTrip').addEventListener('click', () => { if (trip.active) stopTrip(); else startTrip(); });
function renderTrip() {
  const active = trip.active;
  const src = active ? trip : trips[0];
  const dist = src ? src.dist : 0;
  const dur = src ? ((active ? Date.now() : src.endedAt) - src.startedAt) : 0;
  $('#trKm').textContent = fmtKm(dist); $('#trTime').textContent = fmtDur(dur);
  $('#trSpeed').textContent = dur > 60000 ? String(Math.round(dist / 1000 / (dur / 3600000))) : '0';
  $('#btnTrip').textContent = active ? 'Fahrt beenden' : 'Fahrt starten';
  $('#btnTrip').classList.toggle('main', !active);
  const ul = $('#tripList'); ul.innerHTML = '';
  if (!trips.length) ul.innerHTML = '<li><span class="small">Noch keine abgeschlossene Fahrt.</span></li>';
  trips.forEach((t) => { const li = document.createElement('li'); li.innerHTML = '<span>' + esc(fmtDate(t.startedAt)) + ' ' + esc(fmtTime(t.startedAt)) + ' bis ' + esc(fmtTime(t.endedAt)) + ' · ' + t.sightings + ' Tiere</span><span class="n">' + fmtKm(t.dist) + ' km</span>'; ul.appendChild(li); });
}

/* ---------- Karte ---------- */
function renderMap() {
  if (typeof L === 'undefined') return;
  if (!map) {
    map = L.map('map', { zoomControl: true, attributionControl: true });
    L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png', { maxZoom: 17, attribution: '© OpenStreetMap' }).addTo(map);
    mapLayers = L.layerGroup().addTo(map);
    map.setView([-30.5, 24.5], 5);
  }
  map.invalidateSize();
  mapLayers.clearLayers();
  const bounds = [];
  const pts = (trip.active ? trip.points : (trips[0] ? trips[0].points : [])).map((p) => [p[1], p[2]]);
  if (pts.length > 1) { L.polyline(pts, { color: '#f0a93a', weight: 4, opacity: 0.9 }).addTo(mapLayers); pts.forEach((p) => bounds.push(p)); }
  sightings.forEach((s) => {
    if (s.lat == null) return;
    if (s.coarse) {
      L.circle([s.lat, s.lon], { radius: 10000, color: '#e5484d', weight: 1.5, fillOpacity: 0.08 }).addTo(mapLayers).bindPopup(esc(s.s) + '<br>Standort ±10 km (Artenschutz)');
    } else {
      L.circleMarker([s.lat, s.lon], { radius: 7, color: '#15190f', weight: 1.5, fillColor: '#9be36a', fillOpacity: 0.95 }).addTo(mapLayers).bindPopup(esc(s.s) + ' ' + (s.n > 1 ? s.n + '×' : '') + '<br>' + esc(fmtTime(s.t)));
    }
    bounds.push([s.lat, s.lon]);
  });
  if (lastFix) { L.circleMarker([lastFix.lat, lastFix.lon], { radius: 6, color: '#5ec8f2', fillColor: '#5ec8f2', fillOpacity: 0.9 }).addTo(mapLayers); bounds.push([lastFix.lat, lastFix.lon]); }
  if (bounds.length) { try { map.fitBounds(bounds, { padding: [24, 24], maxZoom: 14 }); } catch (e) { /* egal */ } }
}

/* ---------- Tracking ---------- */
function iou(a, b) {
  const ax2 = a[0] + a[2], ay2 = a[1] + a[3], bx2 = b[0] + b[2], by2 = b[1] + b[3];
  const iw = Math.max(0, Math.min(ax2, bx2) - Math.max(a[0], b[0])), ih = Math.max(0, Math.min(ay2, by2) - Math.max(a[1], b[1]));
  const inter = iw * ih, u = a[2] * a[3] + b[2] * b[3] - inter;
  return u > 0 ? inter / u : 0;
}
function containment(a, b) {
  const ax2 = a[0] + a[2], ay2 = a[1] + a[3], bx2 = b[0] + b[2], by2 = b[1] + b[3];
  const iw = Math.max(0, Math.min(ax2, bx2) - Math.max(a[0], b[0])), ih = Math.max(0, Math.min(ay2, by2) - Math.max(a[1], b[1]));
  const m = Math.min(a[2] * a[3], b[2] * b[3]);
  return m > 0 ? (iw * ih) / m : 0;
}
const centerInside = (a, b) => { const cx = a[0] + a[2] / 2, cy = a[1] + a[3] / 2; return cx >= b[0] && cx <= b[0] + b[2] && cy >= b[1] && cy <= b[1] + b[3]; };
const sameAnimal = (a, b) => iou(a, b) > 0.45 || containment(a, b) > 0.7 || ((centerInside(a, b) || centerInside(b, a)) && iou(a, b) > 0.12);
function mergeDetections(dets) {
  // Grosse, sichere Rahmen zuerst: Teilrahmen aus Kacheln gehen in ihnen auf
  dets.sort((a, b) => (b.firm - a.firm) || (b.box[2] * b.box[3] - a.box[2] * a.box[3]));
  const kept = [];
  for (const d of dets) {
    let dup = false;
    for (const k of kept) { if (sameAnimal(k.box, d.box)) { dup = true; if (d.firm && !k.firm) { k.firm = true; k.cls = d.cls; k.score = Math.max(k.score, d.score); } break; } }
    if (!dup) kept.push(d);
  }
  return kept;
}
function updateTracks(dets, now) {
  const used = new Set();
  tracks.sort((a, b) => b.hits - a.hits);
  for (const t of tracks) {
    let best = -1, bestIou = 0.25;
    dets.forEach((d, i) => { if (used.has(i)) return; const v = iou(t.box, d.box); if (v > bestIou) { bestIou = v; best = i; } });
    if (best >= 0) {
      used.add(best); const d = dets[best]; const a = 0.55;
      for (let k = 0; k < 4; k++) t.box[k] = t.box[k] * (1 - a) + d.box[k] * a;
      if (d.firm || !t.firm) { t.cls = d.cls; t.score = d.score; }
      if (d.firm) t.firm = true;
      t.hits++; t.missed = 0; t.lastSeen = now;
    } else t.missed++;
  }
  dets.forEach((d, i) => {
    if (used.has(i)) return;
    tracks.push({ id: nextId, box: d.box.slice(), cls: d.cls, score: d.score, firm: !!d.firm, verified: false, locked: false, collected: false, clsRuns: 0, hits: 1, missed: 0, born: now, lastSeen: now, lastCls: 0, votes: new Map(), species: null, conf: 0, logged: false, sightId: null, color: COLORS[(nextId - 1) % COLORS.length] });
    nextId++;
  });
  tracks = tracks.filter((t) => {
    if (t.missed > 10 || (t.hits < 2 && t.missed > 2)) return false;
    if (!t.firm && !t.verified && (t.clsRuns >= 2 || (t.clsRuns >= 1 && now - t.born > 2500))) return false;
    return true;
  });
}
const isShown = (t) => t.hits >= 2 && (t.firm || t.verified);

/* Ausschnitt eines Rahmens als Quadrat mit Rand (Quelle: Video oder Canvas) */
function cropSquare(src, sw, sh, box, pad = 0.12) {
  const [x, y, w, h] = box;
  const side = Math.min(Math.max(w, h) * (1 + 2 * pad), sw, sh);
  const qx = Math.max(0, Math.min(x + w / 2 - side / 2, sw - side)), qy = Math.max(0, Math.min(y + h / 2 - side / 2, sh - side));
  return { qx, qy, side };
}
function thumbFrom(src, sw, sh, box, size = 96, q = 0.6) {
  const { qx, qy, side } = cropSquare(src, sw, sh, box, 0.08);
  thumbCanvas.width = thumbCanvas.height = size;
  tctx.drawImage(src, qx, qy, side, side, 0, 0, size, size);
  try { return thumbCanvas.toDataURL('image/jpeg', q); } catch (e) { return null; }
}

async function classifyPending() {
  const now = performance.now();
  const cand = tracks
    .filter((t) => !t.locked && t.missed === 0 && (t.hits >= 2 || !t.firm) && now - t.lastCls > (t.species && t.sure ? 900 : 300))
    .sort((a, b) => (a.firm - b.firm) || (a.lastCls - b.lastCls))[0];
  if (!cand) return;
  cand.lastCls = now; cand.clsRuns++;
  const vw = video.videoWidth, vh = video.videoHeight;
  if (cand.box[2] < 12 || cand.box[3] < 12) return;
  const { qx, qy, side } = cropSquare(video, vw, vh, cand.box);
  cctx.drawImage(video, qx, qy, side, side, 0, 0, 224, 224);
  if (head) {
    const r = await runHead(clsCanvas);
    if (!r) return;
    const p = r.probs;
    cand.probs = cand.probs ? cand.probs.map((v, i) => v * 0.6 + p[i] * 0.4) : p;
    const d = decideSpecies(cand.probs);
    cand.species = d.name; cand.conf = d.conf; cand.other = d.other; cand.sure = d.sure; cand.key = d.key;
    if (!cand.firm && d.name && !d.other && d.conf >= 0.6) cand.verified = true;
    if (d.sure) maybeLog(cand);
    // Unsichere, aber stabile Treffer zum Prüfen sammeln
    if (settings.collect && !cand.collected && cand.hits >= 4 && d.name && !d.other && d.conf >= 0.3 && d.conf < 0.7 && reviewCount < 80) {
      cand.collected = true;
      let crop = null; try { crop = clsCanvas.toDataURL('image/jpeg', 0.8); } catch (e) { crop = null; }
      if (crop) addCorrection({ img: crop, predicted: d.name, predKey: d.key || null, conf: d.conf, status: 'review', t: Date.now(), region: (currentRegion() || {}).key || null });
    }
    return;
  }
  // Rückfall: ImageNet-Zuordnung
  let res; try { res = await classifier.classify(clsCanvas, 5); } catch (e) { console.error(e); return; }
  for (const [k, v] of cand.votes) cand.votes.set(k, v * 0.7);
  for (const r of res) { const sp = speciesFor(r.className); if (sp) cand.votes.set(sp, (cand.votes.get(sp) || 0) + r.probability * (sp.endsWith('?') ? 0.8 : 1)); }
  const direct = COCO_DIRECT[cand.cls]; if (direct) cand.votes.set(direct, (cand.votes.get(direct) || 0) + cand.score * 0.9);
  let bestName = null, bestV = 0, total = 0;
  for (const [k, v] of cand.votes) { total += v; if (v > bestV) { bestV = v; bestName = k; } }
  if (bestName && bestV >= 0.12) { cand.species = bestName; cand.conf = total > 0 ? bestV / total : 0; } else { cand.species = null; cand.conf = 0; }
  cand.sure = !!cand.species && !cand.species.endsWith('?');
  if (cand.sure) maybeLog(cand);
}
async function runHead(canvas) {
  let out;
  try { out = tf.tidy(() => head.predict(classifier.infer(canvas, true))); return { probs: applyPrior(Array.from(await out.data())) }; }
  catch (e) { console.error(e); return null; }
  finally { if (out) out.dispose(); }
}
function decideSpecies(probs) {
  const cls = headMeta.classes;
  const order = probs.map((v, i) => [v, i]).sort((a, b) => b[0] - a[0]);
  const [p1, i1] = order[0], [p2, i2] = order[1];
  const c1 = cls[i1], c2 = cls[i2];
  if (c1.negative) return { name: 'Anderes Tier', key: c1.key, conf: p1, sure: false, other: true };
  if (c1.group && c2.group === c1.group && p1 - p2 < 0.3) return { name: c1.group, key: 'group:' + c1.group, conf: p1 + p2, sure: p1 + p2 >= 0.5, other: false };
  if (p1 < 0.35) return { name: null, key: null, conf: p1, sure: false, other: false };
  return { name: c1.name, key: c1.key, conf: p1, sure: p1 >= 0.5, other: false };
}
async function idleHint(now) {
  if (!head) return;
  const active = tracks.some((t) => isShown(t) && t.missed === 0);
  if (active) { hintRuns = []; if (hint && now > hint.until) hint = null; return; }
  if (now - lastHintAt < 700) return;
  lastHintAt = now;
  const reg = visibleRegion();
  hintFlip = !hintFlip;
  const side = Math.min(reg.w, reg.h) * (hintFlip ? 0.7 : 0.4);
  cctx.drawImage(video, reg.x + (reg.w - side) / 2, reg.y + (reg.h - side) / 2, side, side, 0, 0, 224, 224);
  const r = await runHead(clsCanvas);
  if (!r) return;
  const d = decideSpecies(r.probs);
  hintRuns.push(d); if (hintRuns.length > 4) hintRuns.shift();
  const same = d.name ? hintRuns.filter((x) => x.name === d.name && !x.other && x.conf >= 0.6).length : 0;
  if (same >= 2 && !d.other) {
    hint = { name: d.name, conf: d.conf, until: now + 1800 };
    if (same >= 4 && d.conf >= 0.7) logSighting(d.name, { fromHint: true, thumb: safeThumb() });
  } else if (hint && now > hint.until) hint = null;
}
function safeThumb() { try { thumbCanvas.width = thumbCanvas.height = 96; tctx.drawImage(clsCanvas, 0, 0, 224, 224, 0, 0, 96, 96); return thumbCanvas.toDataURL('image/jpeg', 0.6); } catch (e) { return null; } }

/* ---------- Sichtungen ---------- */
function maybeLog(t) {
  if (t.logged || !t.species || !t.sure || t.other) return;
  if (t.hits < 4 || performance.now() - t.born < 1200) return;
  t.logged = true;
  const thumb = thumbFrom(video, video.videoWidth, video.videoHeight, t.box);
  t.sightId = logSighting(t.species, { thumb, key: t.key });
}
let lastHintLog = { name: '', t: 0 };
function positionFor(name) {
  if (!lastFix || Date.now() - lastFix.t > 180000) return {};
  if (isSensitive(name)) { const c = coarsen(lastFix.lat, lastFix.lon); return { lat: c.lat, lon: c.lon, acc: 10000, coarse: true }; }
  return { lat: Math.round(lastFix.lat * 1e5) / 1e5, lon: Math.round(lastFix.lon * 1e5) / 1e5, acc: Math.round(lastFix.acc), coarse: false };
}
// Gibt die ID des Eintrags zurück (neu oder zusammengefasst)
function logSighting(name, opt = {}) {
  const now = Date.now();
  if (opt.fromHint) { if (lastHintLog.name === name && now - lastHintLog.t < 60000) return null; lastHintLog = { name, t: now }; }
  const last = sightings[sightings.length - 1];
  const n = opt.n || 1;
  if (!opt.noMerge && last && last.s === name && now - last.t < 30000) { last.n = (last.n || 1) + n; last.t = now; if (!last.thumb && opt.thumb) last.thumb = opt.thumb; store.set('ss.sightings', sightings); renderSightings(); return last.id; }
  const e = Object.assign({ id: 's' + now + '-' + (++sightSeq), s: name, key: opt.key || null, t: opt.t || now, n, thumb: opt.thumb || null, src: opt.fromHint ? 'hint' : (opt.src || 'cam') }, opt.pos || positionFor(name));
  sightings.push(e);
  store.set('ss.sightings', sightings);
  renderSightings();
  return e.id;
}
function renderSightings() {
  const list = $('#sightList'), empty = $('#sightEmpty');
  const total = sightings.reduce((a, e) => a + (e.n || 1), 0);
  $('#sightCount').textContent = String(total);
  list.innerHTML = '';
  empty.hidden = sightings.length > 0;
  [...sightings].reverse().forEach((e) => {
    const li = document.createElement('li');
    const th = e.thumb ? Object.assign(document.createElement('img'), { className: 'thumb', src: e.thumb, alt: '' }) : Object.assign(document.createElement('div'), { className: 'thumb empty', textContent: e.src === 'manual' ? 'manuell' : 'ohne Bild' });
    th.addEventListener('click', () => openCorrection({ mode: 'sighting', id: e.id, img: e.thumb, predicted: e.s }));
    const name = document.createElement('div'); name.className = 'name';
    const b = document.createElement('button'); b.type = 'button'; b.textContent = e.s; b.addEventListener('click', () => openProfile(e.key && !e.key.startsWith('group:') ? e.key : e.s));
    const sm = document.createElement('small');
    sm.textContent = e.lat == null ? 'ohne Standort' : e.coarse ? 'Standort ±10 km (Artenschutz)' : 'GPS ±' + e.acc + ' m';
    name.append(b, sm);
    const st = document.createElement('div'); st.className = 'stepper';
    const minus = document.createElement('button'); minus.type = 'button'; minus.textContent = '−'; minus.setAttribute('aria-label', 'Anzahl verringern');
    const num = document.createElement('span'); num.textContent = e.n || 1;
    const plus = document.createElement('button'); plus.type = 'button'; plus.textContent = '+'; plus.setAttribute('aria-label', 'Anzahl erhöhen');
    minus.addEventListener('click', () => { e.n = Math.max(0, (e.n || 1) - 1); if (e.n === 0) sightings = sightings.filter((x) => x !== e); store.set('ss.sightings', sightings); renderSightings(); });
    plus.addEventListener('click', () => { e.n = (e.n || 1) + 1; store.set('ss.sightings', sightings); renderSightings(); });
    st.append(minus, num, plus);
    const tm = document.createElement('span'); tm.className = 't'; tm.textContent = fmtTime(e.t);
    li.append(th, name, st, tm); list.appendChild(li);
  });
  $('#sightTitle').textContent = 'Sichtungen ' + (sightings.length ? fmtDate(sightings[sightings.length - 1].t) : 'heute');
}
function countsBySpecies() {
  const m = new Map();
  sightings.forEach((e) => m.set(e.s, (m.get(e.s) || 0) + (e.n || 1)));
  return [...m.entries()].sort((a, b) => b[1] - a[1]);
}
function renderStats() {
  const counts = countsBySpecies();
  $('#stTotal').textContent = String(counts.reduce((a, c) => a + c[1], 0));
  $('#stSpecies').textContent = String(counts.length);
  $('#stKm').textContent = fmtKm(trip.active ? trip.dist : (trips[0] && fmtDate(trips[0].startedAt) === fmtDate(Date.now()) ? trips[0].dist : 0));
  const b5 = $('#big5'); b5.innerHTML = '';
  BIG5.forEach((b) => { const d = document.createElement('div'); d.textContent = b.label; if (counts.some(([n]) => b.test(n))) d.classList.add('done'); b5.appendChild(d); });
  const ul = $('#countList'); ul.innerHTML = '';
  if (!counts.length) ul.innerHTML = '<li><span class="small">Noch keine Sichtungen.</span></li>';
  counts.forEach(([n, c]) => { const li = document.createElement('li'); li.innerHTML = '<span>' + esc(n) + '</span><span class="n">' + c + '</span>'; ul.appendChild(li); });
}
function sightingsText() {
  const counts = countsBySpecies();
  const total = counts.reduce((a, c) => a + c[1], 0);
  const km = trip.active ? trip.dist : (trips[0] ? trips[0].dist : 0);
  return 'Safari ' + fmtDate(Date.now()) + ': ' + total + ' Tiere, ' + counts.length + ' Arten' + (km ? ', ' + fmtKm(km) + ' km' : '') + '\n' +
    counts.map(([n, c]) => n + ' ' + c + '×').join('\n') + '\n\n' +
    [...sightings].reverse().map((e) => fmtTime(e.t) + '  ' + e.s + (e.n > 1 ? ' (' + e.n + '×)' : '') + (e.coarse ? ' [Standort ±10 km]' : '')).join('\n');
}
$('#btnSightings').addEventListener('click', () => { renderSightings(); openSheet('#sheetSightings'); showTab(activeTab); });
$('#btnShareSight').addEventListener('click', async () => {
  if (!sightings.length) { toast('Noch keine Sichtungen'); return; }
  const text = sightingsText();
  try { if (navigator.share) { await navigator.share({ title: 'Safari Sichtungen', text }); return; } await navigator.clipboard.writeText(text); toast('Liste kopiert'); }
  catch (e) { if (e && e.name !== 'AbortError') toast('Teilen nicht möglich'); }
});
$('#btnClearSight').addEventListener('click', () => { sightings = []; store.set('ss.sightings', sightings); tracks.forEach((t) => { t.logged = true; }); renderSightings(); toast('Liste geleert'); });
$('#btnAddManual').addEventListener('click', () => openCorrection({ mode: 'manual' }));

// Zählung als Bild teilen
$('#btnShareStats').addEventListener('click', async () => {
  const counts = countsBySpecies();
  if (!counts.length) { toast('Noch keine Sichtungen'); return; }
  const W = 1080, rowH = 56, top = 330, H = top + counts.length * rowH + 140;
  const c = document.createElement('canvas'); c.width = W; c.height = H; const g = c.getContext('2d');
  g.fillStyle = '#0d0f0b'; g.fillRect(0, 0, W, H);
  g.fillStyle = '#f0a93a'; g.fillRect(0, 0, W, 14);
  g.fillStyle = '#f4f0e6'; g.font = '700 64px ' + FONT; g.fillText('Safari Spotter', 64, 120);
  g.fillStyle = '#b5b0a2'; g.font = '400 36px ' + FONT; g.fillText(fmtDate(Date.now()) + (currentRegion() ? ' · ' + currentRegion().name : ''), 64, 176);
  const total = counts.reduce((a, x) => a + x[1], 0), km = trip.active ? trip.dist : (trips[0] ? trips[0].dist : 0);
  g.fillStyle = '#f4f0e6'; g.font = '600 44px ' + FONT; g.fillText(total + ' Tiere · ' + counts.length + ' Arten' + (km ? ' · ' + fmtKm(km) + ' km' : ''), 64, 260);
  g.font = '400 36px ' + FONT;
  counts.forEach(([n, k], i) => { const y = top + i * rowH; g.fillStyle = 'rgba(244,240,230,0.12)'; g.fillRect(64, y - 38, W - 128, 1); g.fillStyle = '#f4f0e6'; g.fillText(n, 64, y); g.textAlign = 'right'; g.fillStyle = '#f0a93a'; g.font = '600 36px ' + FONT; g.fillText(k + '×', W - 64, y); g.textAlign = 'left'; g.font = '400 36px ' + FONT; });
  g.fillStyle = '#b5b0a2'; g.font = '400 28px ' + FONT; g.fillText('Erkannt auf dem iPhone, Nashorn-Standorte bewusst ungenau.', 64, H - 60);
  c.toBlob((blob) => { if (blob) shareOrDownload(blob, 'safari-' + fmtDate(Date.now()).replace(/\./g, '-') + '.png', 'Safari Zählung'); }, 'image/png');
});

/* ---------- Export: CSV und GPX (mit Artenschutz) ---------- */
const hourFloor = (t) => Math.floor(t / 3600000) * 3600000;
function exportRows() {
  return sightings.map((e) => {
    const sens = e.coarse || isSensitive(e.s);
    return { t: sens ? hourFloor(e.t) : e.t, s: e.s, n: e.n || 1, lat: e.lat, lon: e.lon, prec: e.lat == null ? '' : sens ? '±10 km (Artenschutz)' : '±' + e.acc + ' m', sens };
  });
}
$('#btnExportCsv').addEventListener('click', () => {
  if (!sightings.length) { toast('Noch keine Sichtungen'); return; }
  const rows = exportRows();
  const csv = ['Datum;Zeit;Art;Anzahl;Breite;Laenge;Genauigkeit'].concat(rows.map((r) => [fmtDate(r.t), r.sens ? fmtTime(r.t).slice(0, 2) + ':00 (gerundet)' : fmtTime(r.t), r.s, r.n, r.lat == null ? '' : r.lat.toFixed(r.sens ? 2 : 5), r.lon == null ? '' : r.lon.toFixed(r.sens ? 2 : 5), r.prec].join(';'))).join('\n');
  shareOrDownload(new Blob(['﻿' + csv], { type: 'text/csv' }), 'sichtungen-' + fmtDate(Date.now()).replace(/\./g, '-') + '.csv', 'Sichtungen CSV');
});
$('#btnExportGpx').addEventListener('click', () => {
  const pts = trip.active ? trip.points : (trips[0] ? trips[0].points : []);
  if (!pts.length && !sightings.some((s) => s.lat != null)) { toast('Noch keine Positionen'); return; }
  // Um Nashorn-Sichtungen herum wird die Spur ausgeblendet (±15 Minuten), sonst verrät sie den Standort
  const sensTimes = sightings.filter((s) => s.coarse || isSensitive(s.s)).map((s) => s.t);
  const hidden = (t) => sensTimes.some((st) => Math.abs(t - st) < 15 * 60000);
  const iso = (t) => new Date(t).toISOString();
  let gpx = '<?xml version="1.0" encoding="UTF-8"?>\n<gpx version="1.1" creator="Safari Spotter ' + VERSION + '" xmlns="http://www.topografix.com/GPX/1/1">\n';
  exportRows().forEach((r) => { if (r.lat == null) return; gpx += '  <wpt lat="' + r.lat.toFixed(r.sens ? 3 : 5) + '" lon="' + r.lon.toFixed(r.sens ? 3 : 5) + '"><time>' + iso(r.t) + '</time><name>' + esc(r.s) + (r.n > 1 ? ' (' + r.n + ')' : '') + '</name><desc>' + esc(r.prec) + '</desc></wpt>\n'; });
  if (pts.length) {
    gpx += '  <trk><name>Safari ' + esc(fmtDate(pts[0][0])) + '</name><trkseg>\n';
    let open = true;
    pts.forEach((p) => {
      if (hidden(p[0])) { if (open) { gpx += '  </trkseg><trkseg>\n'; open = false; } return; }
      open = true; gpx += '    <trkpt lat="' + p[1] + '" lon="' + p[2] + '"><time>' + iso(p[0]) + '</time></trkpt>\n';
    });
    gpx += '  </trkseg></trk>\n';
  }
  gpx += '</gpx>\n';
  shareOrDownload(new Blob([gpx], { type: 'application/gpx+xml' }), 'safari-' + fmtDate(Date.now()).replace(/\./g, '-') + '.gpx', 'Safari GPX');
});

/* ---------- Korrekturen ---------- */
async function addCorrection(item) {
  try { await idb.add(item); if (item.status === 'review') { reviewCount++; updateReviewBadge(); } } catch (e) { console.warn('Korrektur nicht gespeichert', e); }
}
function updateReviewBadge() { const b = $('#reviewCount'); b.textContent = String(reviewCount); b.hidden = reviewCount === 0; }
async function countReview() { const all = await idb.all(); reviewCount = all.filter((x) => x.status === 'review').length; updateReviewBadge(); }
function pickerOptions() {
  const opts = [];
  if (headMeta) {
    const groups = new Set();
    headMeta.classes.filter((c) => !c.negative).forEach((c) => { opts.push({ v: c.key, n: c.name }); if (c.group) groups.add(c.group); });
    groups.forEach((g) => opts.push({ v: 'group:' + g, n: g + ' (Art unklar)' }));
  }
  opts.sort((a, b) => a.n.localeCompare(b.n, 'de'));
  opts.push({ v: '__other', n: 'Anderes Tier (kein Safari-Tier)' }, { v: '__none', n: 'Kein Tier (Fehlalarm)' });
  return opts;
}
function fillCorrSelect(filter = '') {
  const sel = $('#corrSelect'); sel.innerHTML = '';
  const f = filter.trim().toLowerCase();
  pickerOptions().filter((o) => !f || o.n.toLowerCase().includes(f)).forEach((o) => { const el = document.createElement('option'); el.value = o.v; el.textContent = o.n; sel.appendChild(el); });
}
$('#corrSearch').addEventListener('input', (e) => fillCorrSelect(e.target.value));
function labelName(v) {
  if (v === '__other') return 'Anderes Tier';
  if (v === '__none') return 'Kein Tier';
  if (v.startsWith('group:')) return v.slice(6);
  const c = headMeta && headMeta.classes.find((x) => x.key === v); return c ? c.name : v;
}
// ctx: {mode:'track'|'sighting'|'manual'|'photo'|'review', ...}
function openCorrection(ctx) {
  corrCtx = ctx;
  $('#corrImg').src = ctx.img || 'data:image/svg+xml;utf8,<svg xmlns="http://www.w3.org/2000/svg" width="112" height="112"></svg>';
  $('#corrImg').hidden = !ctx.img;
  $('#corrPred').textContent = ctx.predicted || (ctx.mode === 'manual' ? 'manueller Eintrag' : 'unbestimmt');
  $('#btnCorrOk').hidden = ctx.mode === 'manual' || !ctx.predicted;
  $('#btnCorrSave').textContent = ctx.mode === 'manual' ? 'Sichtung eintragen' : 'Korrektur speichern';
  $('#corrSearch').value = ''; fillCorrSelect();
  const sel = $('#corrSelect');
  const pre = ctx.predKey || (ctx.predicted && classByName(ctx.predicted) ? classByName(ctx.predicted).key : null);
  if (pre) sel.value = pre;
  openSheet('#sheetCorrect');
}
$('#btnCorrInfo').addEventListener('click', () => { const v = $('#corrSelect').value; if (v && !v.startsWith('__')) openProfile(v.startsWith('group:') ? v.slice(6) : v); });
$('#btnCorrOk').addEventListener('click', async () => {
  const c = corrCtx; if (!c) return;
  if (c.mode === 'review' && c.item) { c.item.status = 'confirmed'; c.item.label = c.item.predicted; c.item.labelKey = c.item.predKey; await idb.put(c.item); await countReview(); renderReview(); }
  else if (c.img && c.predicted) await addCorrection({ img: c.img, predicted: c.predicted, predKey: c.predKey || null, conf: c.conf || null, label: c.predicted, labelKey: c.predKey || null, status: 'confirmed', t: Date.now(), region: (currentRegion() || {}).key || null });
  if (c.mode === 'track' && c.track) { c.track.locked = true; c.track.sure = true; }
  closeTop('#sheetCorrect'); toast('Danke, bestätigt');
});
$('#btnCorrSave').addEventListener('click', async () => {
  const c = corrCtx, v = $('#corrSelect').value; if (!c || !v) { toast('Bitte eine Art wählen'); return; }
  const name = labelName(v), isNone = v === '__none', isOther = v === '__other';
  if (c.mode === 'manual') { logSighting(name, { key: v, src: 'manual', noMerge: true }); closeTop('#sheetCorrect'); toast(name + ' eingetragen'); return; }
  if (c.mode === 'review' && c.item) { c.item.status = 'corrected'; c.item.label = name; c.item.labelKey = v; await idb.put(c.item); await countReview(); renderReview(); }
  else if (c.img) await addCorrection({ img: c.img, predicted: c.predicted || null, predKey: c.predKey || null, conf: c.conf || null, label: name, labelKey: v, status: 'corrected', t: Date.now(), region: (currentRegion() || {}).key || null });
  // Live-Track und Sichtung anpassen
  if (c.mode === 'track' && c.track) {
    const t = c.track; t.locked = true;
    if (isNone) { tracks = tracks.filter((x) => x !== t); if (t.sightId) removeSighting(t.sightId); }
    else { t.species = name; t.key = v; t.sure = !isOther; t.other = isOther; t.conf = 1; if (t.sightId) renameSighting(t.sightId, name, v); else if (!isOther) { t.logged = true; t.sightId = logSighting(name, { key: v, thumb: c.img, noMerge: true }); } }
  }
  if (c.mode === 'sighting' && c.id) { if (isNone) removeSighting(c.id); else renameSighting(c.id, name, v); }
  if (c.mode === 'photo' && c.det) { c.det.name = isNone ? null : name; c.det.key = v; c.det.sure = !isNone && !isOther; c.det.conf = 1; renderPhoto(); }
  closeTop('#sheetCorrect'); toast(isNone ? 'Als Fehlalarm gespeichert' : 'Gespeichert: ' + name);
});
function renameSighting(id, name, key) {
  const e = sightings.find((x) => x.id === id); if (!e) return;
  e.s = name; e.key = key;
  if (isSensitive(name) && e.lat != null && !e.coarse) { const c = coarsen(e.lat, e.lon); e.lat = c.lat; e.lon = c.lon; e.acc = 10000; e.coarse = true; }
  store.set('ss.sightings', sightings); renderSightings();
}
function removeSighting(id) { sightings = sightings.filter((x) => x.id !== id); store.set('ss.sightings', sightings); renderSightings(); }
async function renderReview() {
  const all = (await idb.all()).sort((a, b) => b.t - a.t);
  const open = all.filter((x) => x.status === 'review');
  const ul = $('#reviewList'); ul.innerHTML = '';
  $('#reviewEmpty').hidden = open.length > 0;
  open.forEach((item) => {
    const li = document.createElement('li');
    const img = document.createElement('img'); img.src = item.img; img.alt = '';
    const box = document.createElement('div');
    box.innerHTML = '<div><b>' + esc(item.predicted || 'unbestimmt') + '</b> <span class="small">' + Math.round((item.conf || 0) * 100) + ' % · ' + esc(fmtTime(item.t)) + '</span></div>';
    const btns = document.createElement('div'); btns.className = 'btns';
    const ok = document.createElement('button'); ok.type = 'button'; ok.className = 'ok'; ok.textContent = 'Richtig';
    ok.addEventListener('click', async () => { item.status = 'confirmed'; item.label = item.predicted; item.labelKey = item.predKey; await idb.put(item); await countReview(); renderReview(); });
    const wrong = document.createElement('button'); wrong.type = 'button'; wrong.textContent = 'Falsch …';
    wrong.addEventListener('click', () => openCorrection({ mode: 'review', item, img: item.img, predicted: item.predicted, predKey: item.predKey }));
    const del = document.createElement('button'); del.type = 'button'; del.textContent = 'Löschen';
    del.addEventListener('click', async () => { await idb.del(item.id); await countReview(); renderReview(); });
    btns.append(ok, wrong, del); box.appendChild(btns);
    li.append(img, box); ul.appendChild(li);
  });
  const done = all.length - open.length;
  $('#corrStats').textContent = all.length ? done + ' geprüft, ' + open.length + ' offen. Export enthält nur geprüfte Ausschnitte (224 px), keine ganzen Bilder.' : '';
}
$('#btnExportCorr').addEventListener('click', async () => {
  const all = (await idb.all()).filter((x) => x.status !== 'review');
  if (!all.length) { toast('Noch nichts geprüft'); return; }
  const payload = { app: 'Safari Spotter', version: VERSION, head: HEAD_DIR, exported: new Date().toISOString(), items: all.map((x) => ({ img: x.img, predicted: x.predicted, predKey: x.predKey, conf: x.conf, label: x.label, labelKey: x.labelKey, status: x.status, t: x.t, region: x.region })) };
  shareOrDownload(new Blob([JSON.stringify(payload)], { type: 'application/json' }), 'korrekturen-' + fmtDate(Date.now()).replace(/\./g, '-') + '.json', 'Korrekturen');
});
$('#btnClearCorr').addEventListener('click', async () => {
  const all = await idb.all(); for (const x of all) if (x.status !== 'review') await idb.del(x.id);
  renderReview(); toast('Geprüfte Korrekturen gelöscht');
});
// Tipp auf einen Rahmen im Kamerabild
viewportEl.addEventListener('click', (ev) => {
  if (!running || !syncCanvases()) return;
  const r = viewportEl.getBoundingClientRect(), reg = visibleRegion();
  const vx = reg.x + ((ev.clientX - r.left) / r.width) * reg.w, vy = reg.y + ((ev.clientY - r.top) / r.height) * reg.h;
  const slack = 24 / reg.cssScale;
  const hit = tracks.filter(isShown).map((t) => ({ t, d: Math.max(0, t.box[0] - vx, vx - (t.box[0] + t.box[2])) + Math.max(0, t.box[1] - vy, vy - (t.box[1] + t.box[3])) })).filter((h) => h.d <= slack).sort((a, b) => a.d - b.d)[0];
  if (!hit) return;
  const t = hit.t;
  const { qx, qy, side } = cropSquare(video, video.videoWidth, video.videoHeight, t.box);
  cctx.drawImage(video, qx, qy, side, side, 0, 0, 224, 224);
  let img = null; try { img = clsCanvas.toDataURL('image/jpeg', 0.8); } catch (e) { img = null; }
  openCorrection({ mode: 'track', track: t, img, predicted: t.species || null, predKey: t.key || null, conf: t.conf });
});

/* ---------- Bildanalyse (Mediathek und Foto-Modus) ---------- */
async function detectRegionFrom(src, sw, sh, x, y, w, h, size, isTile) {
  const dw = size, dh = Math.max(32, Math.round(size * h / w));
  if (detCanvas.width !== dw || detCanvas.height !== dh) { detCanvas.width = dw; detCanvas.height = dh; }
  dctx.drawImage(src, x, y, w, h, 0, 0, dw, dh);
  const minScore = Math.max(0.12, settings.threshold * 0.4);
  const preds = await detector.detect(detCanvas, 10, minScore);
  const sx = w / dw, sy = h / dh, out = [];
  for (const p of preds) {
    if (BLOCKED_COCO.has(p.class)) continue;
    const box = [x + p.bbox[0] * sx, y + p.bbox[1] * sy, p.bbox[2] * sx, p.bbox[3] * sy];
    const edge = isTile && (p.bbox[0] < 2 || p.bbox[1] < 2 || p.bbox[0] + p.bbox[2] > dw - 2 || p.bbox[1] + p.bbox[3] > dh - 2);
    // Kacheln sind für kleine Tiere da: ein grosser Rahmen am Kachelrand ist ein angeschnittenes grosses Tier, das der Vollbild-Durchlauf abdeckt
    if (edge && (p.bbox[2] > dw * 0.5 || p.bbox[3] > dh * 0.5)) continue;
    out.push({ box, cls: p.class, score: p.score, firm: ANIMAL_COCO.has(p.class) && p.score >= settings.threshold && !edge });
  }
  return out;
}
function tileGrid(reg, n) {
  const tiles = [], fw = Math.min(1, 1 / n + 0.15), fh = Math.min(1, 1 / n + 0.15);
  for (let i = 0; i < n; i++) for (let j = 0; j < n; j++) {
    const fx = n === 1 ? 0 : (i / (n - 1)) * (1 - fw), fy = n === 1 ? 0 : (j / (n - 1)) * (1 - fh);
    tiles.push({ x: reg.x + fx * reg.w, y: reg.y + fy * reg.h, w: fw * reg.w, h: fh * reg.h });
  }
  return tiles;
}
async function analyzeStill(canvas) {
  const W = canvas.width, H = canvas.height, reg = { x: 0, y: 0, w: W, h: H };
  let dets = await detectRegionFrom(canvas, W, H, 0, 0, W, H, 416, false);
  for (const t of tileGrid(reg, 3)) dets = dets.concat(await detectRegionFrom(canvas, W, H, t.x, t.y, t.w, t.h, 320, true));
  dets = mergeDetections(dets);
  const minSide = Math.min(W, H) * 0.03;
  dets = dets.filter((d) => d.box[2] >= minSide && d.box[3] >= minSide).slice(0, 10);
  const out = [];
  for (const d of dets) {
    const { qx, qy, side } = cropSquare(canvas, W, H, d.box);
    cctx.drawImage(canvas, qx, qy, side, side, 0, 0, 224, 224);
    let img = null; try { img = clsCanvas.toDataURL('image/jpeg', 0.8); } catch (e) { img = null; }
    let dec = { name: null, key: null, conf: 0, sure: false, other: false };
    if (head) { const r = await runHead(clsCanvas); if (r) dec = decideSpecies(r.probs); }
    const keep = d.firm || (dec.name && !dec.other && dec.conf >= 0.5);
    if (!keep) continue;
    // Gleiche Art, überlappender Rahmen: ein Tier
    if (dec.name && out.some((o) => o.box && o.name === dec.name && (iou(o.box, d.box) > 0.12 || centerInside(d.box, o.box) || centerInside(o.box, d.box)))) continue;
    out.push({ box: d.box, cls: d.cls, score: d.score, name: dec.name, key: dec.key, conf: dec.conf, sure: dec.sure, other: dec.other, img, color: COLORS[out.length % COLORS.length] });
  }
  if (!out.length && head) {
    // Hinweis aus der Bildmitte
    for (const f of [0.7, 0.4]) {
      const side = Math.min(W, H) * f;
      cctx.drawImage(canvas, (W - side) / 2, (H - side) / 2, side, side, 0, 0, 224, 224);
      const r = await runHead(clsCanvas); if (!r) continue;
      const dec = decideSpecies(r.probs);
      if (dec.name && !dec.other && dec.conf >= 0.6) { let img = null; try { img = clsCanvas.toDataURL('image/jpeg', 0.8); } catch (e) { img = null; } out.push({ box: null, name: dec.name, key: dec.key, conf: dec.conf, sure: dec.sure, other: false, img, color: COLORS[0], hint: true }); break; }
    }
  }
  return out;
}
function drawStillBoxes(ctx, dets, px) {
  dets.forEach((d) => {
    if (!d.box) return;
    const [X, Y, W, H] = d.box;
    ctx.lineWidth = 2.2 * px; ctx.strokeStyle = d.color; ctx.setLineDash(d.sure ? [] : [7 * px, 5 * px]);
    roundRect(ctx, X, Y, W, H, 10 * px); ctx.stroke(); ctx.setLineDash([]);
    const name = d.name ? (d.sure ? d.name : d.name + '?') : (COCO_FALLBACK[d.cls] || 'Tier');
    const sub = d.name ? Math.round(Math.min(d.conf, 0.99) * 100) + ' %' : 'unbestimmt';
    chip(ctx, X, Y, name, sub, d.sure ? d.color : null, px);
  });
}
function chip(ctx, X, Y, name, sub, fill, px) {
  const fs = 14 * px;
  ctx.font = '600 ' + fs + 'px ' + FONT; const tw = ctx.measureText(name).width;
  ctx.font = '500 ' + (fs * 0.8) + 'px ' + FONT; const sw = ctx.measureText(sub).width;
  const padX = 8 * px, gap = 7 * px, chipH = fs * 1.9, chipW = tw + sw + padX * 2 + gap;
  let cx = X, cy = Y - chipH - 4 * px; if (cy < 0) cy = Y + 4 * px; if (cx + chipW > ctx.canvas.width) cx = Math.max(0, ctx.canvas.width - chipW);
  ctx.fillStyle = fill || 'rgba(13,15,11,0.82)'; roundRect(ctx, cx, cy, chipW, chipH, 7 * px); ctx.fill();
  ctx.textBaseline = 'middle'; ctx.fillStyle = fill ? '#1a1206' : '#f4f0e6'; ctx.font = '600 ' + fs + 'px ' + FONT; ctx.fillText(name, cx + padX, cy + chipH / 2);
  ctx.fillStyle = fill ? 'rgba(26,18,6,0.72)' : '#b5b0a2'; ctx.font = '500 ' + (fs * 0.8) + 'px ' + FONT; ctx.fillText(sub, cx + padX + tw + gap, cy + chipH / 2);
}
// Minimaler EXIF-Leser: GPS und Aufnahmezeit aus JPEG
function parseExif(buf) {
  try {
    const dv = new DataView(buf);
    if (dv.getUint16(0) !== 0xFFD8) return null;
    let off = 2;
    while (off + 4 < dv.byteLength) {
      const marker = dv.getUint16(off); const len = dv.getUint16(off + 2);
      if (marker === 0xFFE1 && dv.getUint32(off + 4) === 0x45786966) {
        const tiff = off + 10, le = dv.getUint16(tiff) === 0x4949;
        const u16 = (p) => dv.getUint16(p, le), u32 = (p) => dv.getUint32(p, le);
        const rat = (p) => u32(p) / (u32(p + 4) || 1);
        const readIfd = (p) => { const n = u16(p), tags = {}; for (let i = 0; i < n; i++) { const e = p + 2 + i * 12; tags[u16(e)] = { type: u16(e + 2), count: u32(e + 4), val: e + 8 }; } return tags; };
        const ifd0 = readIfd(tiff + u32(tiff + 4));
        const out = {};
        if (ifd0[0x8769]) { const ex = readIfd(tiff + u32(ifd0[0x8769].val)); const dt = ex[0x9003]; if (dt) { const p = tiff + u32(dt.val); let s = ''; for (let i = 0; i < 19; i++) s += String.fromCharCode(dv.getUint8(p + i)); const m = s.match(/^(\d{4}):(\d{2}):(\d{2}) (\d{2}):(\d{2}):(\d{2})$/); if (m) out.time = new Date(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +m[6]).getTime(); } }
        if (ifd0[0x8825]) {
          const g = readIfd(tiff + u32(ifd0[0x8825].val));
          const dms = (tag) => { if (!g[tag]) return null; const p = tiff + u32(g[tag].val); return rat(p) + rat(p + 8) / 60 + rat(p + 16) / 3600; };
          const ref = (tag) => (g[tag] ? String.fromCharCode(dv.getUint8(g[tag].val)) : '');
          const lat = dms(2), lon = dms(4);
          if (lat != null && lon != null && isFinite(lat) && isFinite(lon)) { out.lat = ref(1) === 'S' ? -lat : lat; out.lon = ref(3) === 'W' ? -lon : lon; }
        }
        return out;
      }
      if ((marker & 0xFF00) !== 0xFF00 || marker === 0xFFDA) break;
      off += 2 + len;
    }
  } catch (e) { /* kein EXIF */ }
  return null;
}
function loadImageFile(file) {
  return new Promise((res, rej) => {
    const url = URL.createObjectURL(file); const img = new Image();
    img.onload = () => { URL.revokeObjectURL(url); res(img); }; img.onerror = () => { URL.revokeObjectURL(url); rej(new Error('Bild nicht lesbar')); };
    img.src = url;
  });
}
async function analyzeFiles(files) {
  if (!detector) { toast('Modelle laden noch'); return; }
  photoQueue = Array.from(files);
  await nextPhoto();
}
async function nextPhoto() {
  const file = photoQueue.shift();
  if (!file) { closeTop('#sheetPhoto'); return; }
  toast('Analysiere ' + (file.name || 'Bild') + ' …', 4000);
  let exif = null; try { exif = parseExif(await file.slice(0, 256 * 1024).arrayBuffer()); } catch (e) { exif = null; }
  let img; try { img = await loadImageFile(file); } catch (e) { toast('Bild nicht lesbar'); return nextPhoto(); }
  const maxSide = 1600, k = Math.min(1, maxSide / Math.max(img.naturalWidth, img.naturalHeight));
  const c = $('#photoCanvas'); c.width = Math.round(img.naturalWidth * k); c.height = Math.round(img.naturalHeight * k);
  c.getContext('2d').drawImage(img, 0, 0, c.width, c.height);
  await showPhotoAnalysis(c, { title: file.name || 'Bild', exif, src: 'photo' });
  $('#btnPhotoNext').hidden = photoQueue.length === 0;
}
async function showPhotoAnalysis(c, meta) {
  const base = document.createElement('canvas'); base.width = c.width; base.height = c.height; base.getContext('2d').drawImage(c, 0, 0);
  const dets = await analyzeStill(base);
  photoCur = { base, dets, meta };
  renderPhoto();
  openSheet('#sheetPhoto');
}
function renderPhoto() {
  if (!photoCur) return;
  const { base, dets, meta } = photoCur;
  const c = $('#photoCanvas'), g = c.getContext('2d');
  c.width = base.width; c.height = base.height; g.drawImage(base, 0, 0);
  const px = Math.max(1, base.width / 600);
  drawStillBoxes(g, dets, px);
  $('#photoTitle').textContent = meta.title || 'Bildanalyse';
  const pos = meta.exif && meta.exif.lat != null ? 'Standort aus Foto' : (lastFix ? 'aktueller Standort' : 'ohne Standort');
  $('#photoInfo').textContent = (dets.length ? dets.length + ' Treffer' : 'Kein Tier gefunden') + ' · ' + pos + (meta.exif && meta.exif.time ? ' · ' + fmtDate(meta.exif.time) + ' ' + fmtTime(meta.exif.time) : '') + '. Tipp auf einen Treffer korrigiert die Art.';
  const ul = $('#photoList'); ul.innerHTML = '';
  dets.forEach((d) => {
    const li = document.createElement('li');
    const im = document.createElement('img'); im.className = 'thumb'; im.src = d.img || ''; im.alt = '';
    const name = document.createElement('div'); name.className = 'name';
    const b = document.createElement('button'); b.type = 'button'; b.textContent = d.name ? (d.sure ? d.name : d.name + '?') : (COCO_FALLBACK[d.cls] || 'Tier'); b.addEventListener('click', () => openCorrection({ mode: 'photo', det: d, img: d.img, predicted: d.name, predKey: d.key, conf: d.conf }));
    const sm = document.createElement('small'); sm.textContent = (d.hint ? 'Vermutung ohne Rahmen · ' : '') + Math.round(Math.min(d.conf, 0.99) * 100) + ' %';
    name.append(b, sm);
    const sp = document.createElement('span'); sp.style.gridColumn = 'span 2';
    li.append(im, name, sp); ul.appendChild(li);
  });
  $('#btnPhotoSave').disabled = !dets.some((d) => d.name && !d.other);
}
$('#btnPhotoSave').addEventListener('click', () => {
  if (!photoCur) return;
  const { dets, meta } = photoCur;
  const counts = new Map();
  dets.filter((d) => d.name && !d.other).forEach((d) => { const e = counts.get(d.name) || { n: 0, key: d.key, img: d.img }; e.n++; counts.set(d.name, e); });
  if (!counts.size) { toast('Keine bestimmbare Art'); return; }
  const t = meta.exif && meta.exif.time ? meta.exif.time : Date.now();
  counts.forEach((e, name) => {
    let pos = {};
    if (meta.exif && meta.exif.lat != null) { if (isSensitive(name)) { const c = coarsen(meta.exif.lat, meta.exif.lon); pos = { lat: c.lat, lon: c.lon, acc: 10000, coarse: true }; } else pos = { lat: Math.round(meta.exif.lat * 1e5) / 1e5, lon: Math.round(meta.exif.lon * 1e5) / 1e5, acc: 15, coarse: false }; }
    else pos = positionFor(name);
    logSighting(name, { key: e.key, n: e.n, thumb: e.img, t, pos, src: meta.src || 'photo', noMerge: true });
  });
  toast('Als Sichtung gespeichert');
  if (photoQueue.length) nextPhoto(); else closeTop('#sheetPhoto');
});
$('#btnPhotoShare').addEventListener('click', () => { const c = $('#photoCanvas'); c.toBlob((b) => { if (b) shareOrDownload(b, 'spotter-' + Date.now() + '.jpg', 'Safari Spotter Foto'); }, 'image/jpeg', 0.9); });
$('#btnPhotoNext').addEventListener('click', () => nextPhoto());
$('#fileGate').addEventListener('change', (e) => { if (e.target.files.length) analyzeFiles(e.target.files); e.target.value = ''; });
$('#fileSettings').addEventListener('change', (e) => { if (e.target.files.length) { closeSheets(); analyzeFiles(e.target.files); } e.target.value = ''; });
// Foto-Modus aus der Kamera: aktuelles Bild in voller Streamauflösung
$('#btnPhoto').addEventListener('click', async () => {
  if (!running || !syncCanvases()) return;
  const reg = visibleRegion();
  const c = document.createElement('canvas'); c.width = Math.round(reg.w); c.height = Math.round(reg.h);
  c.getContext('2d').drawImage(video, reg.x, reg.y, reg.w, reg.h, 0, 0, c.width, c.height);
  toast('Analysiere Foto …', 3000);
  await showPhotoAnalysis(c, { title: 'Foto ' + fmtTime(Date.now()), exif: null, src: 'cam' });
  $('#btnPhotoNext').hidden = true;
});

/* ---------- Erkennungsschleife ---------- */
async function detectLoop() {
  while (running) {
    if (!syncCanvases() || video.paused) { await sleep(60); continue; }
    const t0 = performance.now();
    const reg = visibleRegion();
    const vw = video.videoWidth, vh = video.videoHeight;
    let dets = [];
    try {
      dets = await detectRegionFrom(video, vw, vh, reg.x, reg.y, reg.w, reg.h, 416, false);
      const n = settings.far === 'max' ? 3 : settings.far === 'off' ? 0 : 2;
      if (n) for (const t of tileGrid(reg, n)) { if (!running) break; dets = dets.concat(await detectRegionFrom(video, vw, vh, t.x, t.y, t.w, t.h, 320, true)); }
    } catch (e) { console.error(e); await sleep(250); continue; }
    dets = mergeDetections(dets);
    const minSide = Math.min(reg.w, reg.h) * 0.03, maxSide = Math.max(reg.w, reg.h) * 0.9;
    let weak = 0;
    dets = dets.filter((d) => { if (d.firm) return true; if (d.box[2] < minSide || d.box[3] < minSide || d.box[2] > maxSide || d.box[3] > maxSide) return false; return ++weak <= 3; });
    updateTracks(dets, performance.now());
    await classifyPending();
    await idleHint(performance.now());
    const dt = performance.now() - t0;
    detFps = detFps * 0.8 + (1000 / Math.max(dt, 1)) * 0.2;
    if (dt < 50) await sleep(50 - dt);
  }
}

/* ---------- Zeichnen ---------- */
function roundRect(ctx, x, y, w, h, r) {
  r = Math.min(r, w / 2, h / 2);
  ctx.beginPath(); ctx.moveTo(x + r, y); ctx.arcTo(x + w, y, x + w, y + h, r); ctx.arcTo(x + w, y + h, x, y + h, r); ctx.arcTo(x, y + h, x, y, r); ctx.arcTo(x, y, x + w, y, r); ctx.closePath();
}
function drawOverlay(ctx, map, px) {
  for (const t of tracks) {
    if (!isShown(t)) continue;
    const [x, y, w, h] = t.box;
    const X = (x - map.ox) * map.k, Y = (y - map.oy) * map.k, W = w * map.k, H = h * map.k;
    const sure = !!t.sure;
    ctx.lineWidth = 2.2 * px; ctx.strokeStyle = t.color; ctx.setLineDash(sure ? [] : [7 * px, 5 * px]);
    roundRect(ctx, X, Y, W, H, 10 * px); ctx.stroke(); ctx.setLineDash([]);
    const c = Math.min(16 * px, W / 3, H / 3);
    ctx.lineWidth = 4 * px; ctx.beginPath();
    ctx.moveTo(X, Y + c); ctx.lineTo(X, Y); ctx.lineTo(X + c, Y);
    ctx.moveTo(X + W - c, Y); ctx.lineTo(X + W, Y); ctx.lineTo(X + W, Y + c);
    ctx.moveTo(X + W, Y + H - c); ctx.lineTo(X + W, Y + H); ctx.lineTo(X + W - c, Y + H);
    ctx.moveTo(X + c, Y + H); ctx.lineTo(X, Y + H); ctx.lineTo(X, Y + H - c);
    ctx.stroke();
    if (!settings.labels) continue;
    const name = t.species ? (t.sure || t.other || t.species.endsWith('?') ? t.species : t.species + '?') : (COCO_FALLBACK[t.cls] || 'Tier');
    const sub = t.other ? 'kein Safari-Tier' : t.locked ? 'bestätigt' : t.species ? Math.round(Math.min(t.conf, 0.99) * 100) + ' %' : 'unbestimmt';
    chip(ctx, X, Y, name, sub, sure ? t.color : null, px);
  }
  if (hint && settings.labels && performance.now() < hint.until) {
    const fs = 15 * px, label = hint.name + '  ' + Math.round(Math.min(hint.conf, 0.99) * 100) + ' %';
    ctx.font = '600 ' + fs + 'px ' + FONT;
    const tw = ctx.measureText(label).width, padX = 12 * px, chipH = fs * 2.1, chipW = tw + padX * 2;
    const cw = map.w || ctx.canvas.width, ch = map.h || ctx.canvas.height;
    const cx = (map.x0 || 0) + (cw - chipW) / 2, cy = (map.y0 || 0) + ch * 0.62;
    ctx.fillStyle = 'rgba(13,15,11,0.82)'; roundRect(ctx, cx, cy, chipW, chipH, 9 * px); ctx.fill();
    ctx.strokeStyle = '#f0a93a'; ctx.lineWidth = 1.5 * px; ctx.stroke();
    ctx.fillStyle = '#f4f0e6'; ctx.textBaseline = 'middle'; ctx.fillText(label, cx + padX, cy + chipH / 2);
  }
}
let fpsTick = 0;
function render() {
  if (!running) return;
  requestAnimationFrame(render);
  if (!syncCanvases()) return;
  const reg = visibleRegion(), px = 1 / reg.cssScale;
  octx.clearRect(0, 0, overlay.width, overlay.height);
  drawOverlay(octx, { ox: 0, oy: 0, k: 1, x0: reg.x, y0: reg.y, w: reg.w, h: reg.h }, px);
  if (isRecording && settings.burnIn && recMap) {
    const RW = recCanvas.width, RH = recCanvas.height;
    let cw = reg.w, ch = cw * RH / RW; if (ch > reg.h) { ch = reg.h; cw = ch * RW / RH; }
    const cx0 = reg.x + (reg.w - cw) / 2, cy0 = reg.y + (reg.h - ch) / 2;
    rctx.drawImage(video, cx0, cy0, cw, ch, 0, 0, RW, RH);
    const k = RW / cw;
    drawOverlay(rctx, { ox: cx0, oy: cy0, k, x0: 0, y0: 0, w: RW, h: RH }, k / reg.cssScale);
    const fsw = Math.round(RH * 0.028);
    rctx.font = '500 ' + fsw + 'px ' + FONT; rctx.textBaseline = 'alphabetic'; rctx.textAlign = 'right';
    rctx.fillStyle = 'rgba(0,0,0,0.45)'; rctx.fillText(recStamp, RW - fsw + 1, RH - fsw + 1);
    rctx.fillStyle = 'rgba(244,240,230,0.9)'; rctx.fillText(recStamp, RW - fsw, RH - fsw);
    rctx.textAlign = 'left';
  }
  if (++fpsTick % 15 === 0) {
    const n = tracks.filter(isShown).length;
    $('#fps').textContent = Math.round(detFps) + ' fps';
    const hinting = n === 0 && hint && performance.now() < hint.until;
    setStatus(hinting ? hint.name + ' vermutet' : n === 0 ? 'Suche Tiere …' : n === 1 ? '1 Tier im Bild' : n + ' Tiere im Bild', true);
  }
}

/* ---------- Aufnahme ---------- */
function pickMime() {
  if (typeof MediaRecorder === 'undefined') return null;
  return ['video/mp4;codecs=avc1', 'video/mp4;codecs=h264', 'video/mp4', 'video/webm;codecs=vp9', 'video/webm;codecs=vp8', 'video/webm'].find((m) => { try { return MediaRecorder.isTypeSupported(m); } catch (e) { return false; } }) || '';
}
async function startRecording() {
  if (!stream || isRecording) return;
  if (typeof MediaRecorder === 'undefined') { toast('Dieser Browser kann nicht aufnehmen'); return; }
  chunks = [];
  const reg = visibleRegion();
  let ms;
  if (settings.burnIn) {
    const RW = Math.min(1280, Math.round(reg.w)) & ~1, RH = Math.round(RW * reg.h / reg.w) & ~1;
    recCanvas.width = RW; recCanvas.height = RH; recMap = { RW, RH };
    rctx.drawImage(video, reg.x, reg.y, reg.w, reg.h, 0, 0, RW, RH);
    ms = recCanvas.captureStream(30);
  } else { recMap = null; ms = new MediaStream([stream.getVideoTracks()[0]]); }
  try { micStream = await navigator.mediaDevices.getUserMedia({ audio: true }); micStream.getAudioTracks().forEach((t) => ms.addTrack(t)); } catch (e) { micStream = null; }
  recMime = pickMime();
  try { recorder = new MediaRecorder(ms, recMime ? { mimeType: recMime, videoBitsPerSecond: 8e6 } : { videoBitsPerSecond: 8e6 }); }
  catch (e) { console.error(e); toast('Aufnahme konnte nicht gestartet werden'); return; }
  recorder.ondataavailable = (e) => { if (e.data && e.data.size) chunks.push(e.data); };
  recorder.onstop = finishRecording;
  recorder.onerror = (e) => { console.error(e); toast('Aufnahmefehler'); };
  recStamp = 'Safari Spotter · ' + fmtDate(Date.now()) + ' ' + fmtTime(Date.now());
  recorder.start(1000);
  isRecording = true; recStart = Date.now();
  $('#btnRecord').classList.add('on'); $('#btnRecord').setAttribute('aria-label', 'Aufnahme stoppen');
  $('#recTimer').hidden = false; $('#recTimer').textContent = '00:00';
  recTimerId = setInterval(() => { const s = Math.floor((Date.now() - recStart) / 1000); $('#recTimer').textContent = pad2(Math.floor(s / 60)) + ':' + pad2(s % 60); }, 500);
}
function stopRecording() {
  if (!isRecording) return;
  isRecording = false; clearInterval(recTimerId);
  $('#btnRecord').classList.remove('on'); $('#btnRecord').setAttribute('aria-label', 'Aufnahme starten');
  $('#recTimer').hidden = true;
  try { recorder.stop(); } catch (e) { finishRecording(); }
}
function finishRecording() {
  if (micStream) { micStream.getTracks().forEach((t) => t.stop()); micStream = null; }
  if (!chunks.length) { toast('Keine Aufnahme entstanden'); return; }
  const type = (recMime && recMime.split(';')[0]) || chunks[0].type || 'video/mp4';
  const blob = new Blob(chunks, { type }), ext = type.includes('mp4') ? 'mp4' : 'webm', d = new Date();
  const name = 'safari-' + d.getFullYear() + pad2(d.getMonth() + 1) + pad2(d.getDate()) + '-' + pad2(d.getHours()) + pad2(d.getMinutes()) + pad2(d.getSeconds()) + '.' + ext;
  if (lastClip && lastClip.url) URL.revokeObjectURL(lastClip.url);
  lastClip = { blob, name, type, url: URL.createObjectURL(blob) };
  $('#clipVideo').src = lastClip.url;
  $('#clipInfo').textContent = Math.round((Date.now() - recStart) / 1000) + ' s · ' + (blob.size / 1048576).toFixed(1).replace('.', ',') + ' MB · ' + ext.toUpperCase();
  const a = $('#btnSaveClip'); a.href = lastClip.url; a.download = name;
  openSheet('#sheetClip');
}
$('#btnRecord').addEventListener('click', () => { if (isRecording) stopRecording(); else startRecording(); });
$('#btnShareClip').addEventListener('click', async () => {
  if (!lastClip) return;
  const file = new File([lastClip.blob], lastClip.name, { type: lastClip.type });
  try { if (navigator.canShare && navigator.canShare({ files: [file] })) { await navigator.share({ files: [file], title: 'Safari Aufnahme' }); return; } toast('Teilen nicht möglich, bitte „In Dateien speichern“'); }
  catch (e) { if (e && e.name !== 'AbortError') toast('Teilen abgebrochen'); }
});
$('#btnDiscardClip').addEventListener('click', () => { if (lastClip && lastClip.url) URL.revokeObjectURL(lastClip.url); lastClip = null; $('#clipVideo').removeAttribute('src'); closeSheets(); });

/* ---------- Einstellungen ---------- */
function bindSettings() {
  const thr = $('#thr'); thr.value = settings.threshold;
  $('#thrVal').textContent = 'Schwelle ' + Math.round(settings.threshold * 100) + ' %';
  thr.addEventListener('input', () => { settings.threshold = parseFloat(thr.value); $('#thrVal').textContent = 'Schwelle ' + Math.round(settings.threshold * 100) + ' %'; store.set('ss.settings', settings); });
  const sw = (id, key, onChange) => {
    const el = $(id); el.setAttribute('aria-checked', String(!!settings[key]));
    el.addEventListener('click', () => { settings[key] = !settings[key]; el.setAttribute('aria-checked', String(settings[key])); store.set('ss.settings', settings); if (onChange) onChange(settings[key]); });
  };
  sw('#swLabels', 'labels'); sw('#swBurn', 'burnIn'); sw('#swCollect', 'collect');
  sw('#swGps', 'gps', (on) => { if (on) startGps(); else { stopGps(); if (trip.active) stopTrip(); } });
  const far = $('#far'); far.value = ['off', 'on', 'max'].includes(settings.far) ? settings.far : 'on';
  far.addEventListener('change', () => { settings.far = far.value; store.set('ss.settings', settings); });
  $('#region').addEventListener('change', (e) => { settings.region = e.target.value; store.set('ss.settings', settings); updateRegionNote(); });
  const res = $('#res'); res.value = settings.res;
  res.addEventListener('change', () => { settings.res = res.value; store.set('ss.settings', settings); toast('Gilt ab dem nächsten Kamerastart'); });
  $('#ver').textContent = 'v' + VERSION;
  $('#btnSettings').addEventListener('click', () => { updateRegionNote(); openSheet('#sheetSettings'); });
  $('#btnReload').addEventListener('click', async () => {
    try {
      if ('caches' in window) { const keys = await caches.keys(); await Promise.all(keys.map((k) => caches.delete(k))); }
      if ('serviceWorker' in navigator) { const regs = await navigator.serviceWorker.getRegistrations(); await Promise.all(regs.map((r) => r.unregister())); }
    } catch (e) { /* egal */ }
    location.reload();
  });
  $('#btnStopCam').addEventListener('click', () => { stopAll(); closeSheets(); });
}

/* ---------- Start / Stopp ---------- */
async function keepAwake() { try { if ('wakeLock' in navigator && document.visibilityState === 'visible') wakeLock = await navigator.wakeLock.request('screen'); } catch (e) { wakeLock = null; } }
document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible' && running) { keepAwake(); video.play().catch(() => {}); } });
function showGateError(msg) { const e = $('#gateErr'); e.textContent = msg; e.hidden = false; }
async function startAll() {
  $('#gateErr').hidden = true;
  if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) { showGateError('Dieser Browser gibt die Kamera nicht frei. Bitte die Seite direkt in Safari öffnen (nicht in einer App-Vorschau).'); return; }
  $('#btnStart').disabled = true; $('#btnStartText').textContent = 'Kamera wird gestartet …';
  try { await startCamera(null); }
  catch (e) {
    console.error(e);
    $('#btnStart').disabled = false; $('#btnStartText').textContent = 'Kamera starten';
    const denied = e && (e.name === 'NotAllowedError' || e.name === 'SecurityError');
    showGateError(denied ? 'Kamerazugriff abgelehnt. In Safari: „aA“ links in der Adresszeile tippen, Website-Einstellungen, Kamera erlauben. Dann erneut starten.' : 'Kamera nicht verfügbar (' + (e && e.name ? e.name : 'Fehler') + '). Läuft sie gerade in einer anderen App?');
    return;
  }
  running = true;
  $('#gate').hidden = true;
  $('#btnRecord').disabled = false; $('#btnPhoto').disabled = false;
  setStatus('Suche Tiere …', true);
  keepAwake(); startGps();
  requestAnimationFrame(render);
  detectLoop();
}
function stopAll() {
  if (isRecording) stopRecording();
  running = false; stopStream(); tracks = [];
  octx.clearRect(0, 0, overlay.width, overlay.height);
  $('#btnRecord').disabled = true; $('#btnPhoto').disabled = true;
  $('#zoomWrap').hidden = true; $('#lens').hidden = true;
  setStatus('Bereit', false); $('#fps').textContent = '';
  $('#gate').hidden = false;
  $('#btnStart').disabled = false; $('#btnStartText').textContent = 'Kamera starten';
  if (wakeLock) { try { wakeLock.release(); } catch (e) { /* egal */ } wakeLock = null; }
}
$('#btnStart').addEventListener('click', startAll);
window.addEventListener('pagehide', () => { if (isRecording) stopRecording(); store.set('ss.trip', trip); });

/* ---------- Hochfahren ---------- */
window.__spotter = {
  state: () => ({ version: VERSION, head: !!head, tracks: tracks.map((t) => ({ id: t.id, cls: t.cls, species: t.species, conf: t.conf, sure: t.sure, hits: t.hits, locked: t.locked })), hint, hintRuns: hintRuns.slice(), detFps, sightings, trip: { active: trip.active, dist: trip.dist, points: trip.points.length }, region: (currentRegion() || {}).key || null, lastFix, reviewCount }),
  fakeFix: (lat, lon, acc = 8) => onFix({ coords: { latitude: lat, longitude: lon, accuracy: acc } }),
  analyzeFiles, logSighting, startTrip, stopTrip, exportRows: () => exportRows(), coarsen,
  dbg: { renameSighting, renderSightings, addCorrection, labelName, closeTop, toast, isSensitive, store, tracks: () => tracks, lockTrack: (i, name, key) => { const t = tracks[i]; t.locked = true; t.species = name; t.key = key; t.sure = true; t.other = false; t.conf = 1; return t.sightId; } }
};
bindSettings();
renderSightings(); updateKmPill();
if (trip.active) startGps();
countReview();
if ('serviceWorker' in navigator) window.addEventListener('load', () => { navigator.serviceWorker.register('sw.js').catch(() => {}); });
(async () => {
  try { await loadModels(); $('#btnStart').disabled = false; $('#btnStartText').textContent = 'Kamera starten'; }
  catch (e) {
    console.error(e);
    $('#loadText').textContent = 'Modelle konnten nicht geladen werden. Internetverbindung prüfen und die Seite neu laden.';
    showGateError('Fehler beim Laden der KI-Modelle: ' + (e && e.message ? e.message : e));
    $('#btnStartText').textContent = 'Modelle fehlen';
  }
})();
})();

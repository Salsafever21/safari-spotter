// Deterministische Testeingaben: Fahrt mit Stopps, Prob-Vektoren, Detektionsfolgen
const fs = require('fs');
let seed = 7; const rnd = () => { seed = (seed * 1103515245 + 12345) % 2147483648; return seed / 2147483648; };
const t0 = 1761480000; // Fahrtbeginn
const pts = []; let lat = -24.9, lon = 31.55, alt = 300, t = t0;
const phases = [[600, 8], [120, 0], [900, 12], [200, 0.2], [500, 6], [60, 0], [300, 15]]; // [Sekunden, m/s]
for (const [sec, v] of phases) {
  for (let s = 0; s < sec; s += 5) {
    t += 5; const d = v * 5 + (rnd() - 0.5) * 2;
    if (v > 0) { lat += (d / 111320) * Math.cos(t / 400); lon += (d / (111320 * Math.cos(lat * Math.PI / 180))) * Math.sin(t / 400); alt += (rnd() - 0.45) * 3; }
    else { lat += (rnd() - 0.5) * 2e-6; lon += (rnd() - 0.5) * 2e-6; }
    // GPS-Tempo manchmal unbekannt, manchmal falsch hoch im Stand (wird durch Ortsregel korrigiert)
    const spd = rnd() < 0.1 ? -1 : (v === 0 && rnd() < 0.3 ? 1.5 : v + (rnd() - 0.5) * 0.4);
    pts.push({ t, lat, lon, spd, alt: rnd() < 0.05 ? null : Math.round(alt) });
  }
}
let dist = 0; const hv = (a, b) => { const toR = Math.PI / 180, dLat = (b.lat - a.lat) * toR, dLon = (b.lon - a.lon) * toR; const s = Math.sin(dLat / 2) ** 2 + Math.cos(a.lat * toR) * Math.cos(b.lat * toR) * Math.sin(dLon / 2) ** 2; return 2 * 6371000 * Math.asin(Math.sqrt(s)); };
for (let i = 1; i < pts.length; i++) dist += hv(pts[i - 1], pts[i]);
const sightings = [{ t: t0 + 650, name: 'Impala' }, { t: t0 + 700, name: 'Löwin' }, { t: t0 + 1900, name: 'Elefant' }, { t: t0 - 100, name: 'Vorher' }];
const labels = JSON.parse(fs.readFileSync(require('path').resolve(__dirname, '..', '..', 'SafariSpotter', 'Resources', 'species-labels.json'), 'utf8')).classes;
const n = labels.length, idx = (k) => labels.findIndex((c) => c.key === k);
const vec = (pairs) => { for (const [k] of pairs) if (idx(k) < 0) throw new Error('Klasse fehlt: ' + k); const v = new Array(n).fill(0); let s = 0; for (const [k, p] of pairs) { v[idx(k)] = p; s += p; } const rest = (1 - s) / (n - pairs.length); return v.map((x) => x || rest); };
console.error('Klassen:', labels.map((c) => c.key).join(' '));
const probs = [
  vec([['impala', 0.8]]), vec([['loewe_m', 0.4], ['loewin', 0.35]]), vec([['loewe_m', 0.7], ['loewin', 0.1]]), vec([['breitmaulnashorn', 0.45], ['spitzmaulnashorn', 0.2]]),
  vec([['anderes_hund', 0.5]]), vec([['impala', 0.3]]), vec([['impala', 0.36]]), vec([['steppenzebra', 0.52], ['impala', 0.3]]), vec([['elefant', 0.55]]),
];
const dets = [];
for (let f = 0; f < 30; f++) {
  const fr = [];
  // Tier A: sicher, bewegt sich; Kachel-Teilboxen dazu
  if (f < 25) { const x = 300 + f * 12; fr.push({ x, y: 400, w: 420, h: 300, cls: 'zebra', score: 0.8, firm: true }); fr.push({ x: x + 40, y: 420, w: 200, h: 250, cls: 'horse', score: 0.3, firm: false }); fr.push({ x: x + 300, y: 500, w: 150, h: 180, cls: 'cow', score: 0.4, firm: false }); }
  // Tier B: schwach, klein, taucht ab Frame 5 auf und bleibt
  if (f >= 5) fr.push({ x: 1500, y: 200 + f, w: 90, h: 70, cls: 'bird', score: 0.2, firm: false });
  // Rauschen: zu klein / zu gross
  fr.push({ x: 10, y: 10, w: 20, h: 20, cls: 'dog', score: 0.3, firm: false });
  fr.push({ x: 0, y: 0, w: 1900, h: 1070, cls: 'bear', score: 0.3, firm: false });
  // Tier C: sicher ab Frame 12, verschwindet ab 20
  if (f >= 12 && f < 20) fr.push({ x: 1000, y: 700, w: 250, h: 200, cls: 'elephant', score: 0.9, firm: true });
  dets.push(fr);
}
const inp = { startedAt: t0, endedAt: t, dist, points: pts, sightings, probs, regionKey: 'westkap', dets, visible: [0, 0, 1920, 1080], coarsen: [[-24.9, 31.55], [-33.9, 18.4], [-22.1, 29.9], [0.3, 36.8]] };
fs.writeFileSync(process.argv[2] || 'input.json', JSON.stringify(inp));
console.log('Punkte', pts.length, 'Distanz', dist.toFixed(0));

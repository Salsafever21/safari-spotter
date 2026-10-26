// Führt die Original-JS-Funktionen aus app.js mit input.json aus und schreibt js-out.json
const fs = require('fs'), path = require('path');
const ROOT = path.resolve(__dirname, '..', '..', '..');
const src = fs.readFileSync(path.join(ROOT, 'app.js'), 'utf8');
function grab(name) { // Funktion oder const-Lambda per Name aus app.js schneiden
  let m = src.match(new RegExp('^(?:async )?function ' + name + '\\([^)]*\\) \\{[\\s\\S]*?^\\}', 'm'));
  if (!m) m = src.match(new RegExp('^const ' + name + ' = .*$', 'm'));
  if (!m) throw new Error('nicht gefunden: ' + name);
  return m[0];
}
const code = ['R_EARTH', 'haversine', 'coarsen', 'applyPrior', 'currentRegion', 'STILL_SPEED', 'STOP_MIN', 'tripStats', 'decideSpecies', 'iou', 'containment', 'centerInside', 'sameAnimal', 'mergeDetections', 'updateTracks', 'isShown', 'cropSquare', 'tileGrid']
  .map((n) => (n === 'R_EARTH' || n === 'STILL_SPEED' || n === 'STOP_MIN') ? src.match(new RegExp('^const ' + n + ' = .*$', 'm'))[0] : grab(n)).join('\n');
const inp = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const RES = path.join(ROOT, 'ios', 'SafariSpotter', 'Resources');
const headMeta = JSON.parse(fs.readFileSync(path.join(RES, 'species-labels.json'), 'utf8'));
const regionsCfg = JSON.parse(fs.readFileSync(path.join(RES, 'regions.json'), 'utf8'));
const settings = { region: inp.regionKey || 'none' };
const COLORS = ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h'];
let tracks = [], nextId = 1, autoRegion = null;
const sightings = inp.sightings.map((s) => ({ t: s.t * 1000, name: s.name }));
eval(code.replace(/^const /gm, 'var '));
const out = {};
out.decisions = inp.probs.map((p) => { const pr = applyPrior(p); const d = decideSpecies(pr); return { name: d.name, key: d.key, conf: Math.round(d.conf * 1e6) / 1e6, sure: d.sure, other: d.other, sum: Math.round(pr.reduce((a, b) => a + b, 0) * 1e6) / 1e6 }; });
const vis = { x: inp.visible[0], y: inp.visible[1], w: inp.visible[2], h: inp.visible[3] };
const r4 = (v) => Math.round(v * 1e4) / 1e4;
out.frames = inp.dets.map((f, fi) => {
  const dets = f.map((d) => ({ box: [d.x, d.y, d.w, d.h], cls: d.cls, score: d.score, firm: d.firm }));
  let merged = mergeDetections(dets);
  const minSide = Math.min(vis.w, vis.h) * 0.03, maxSide = Math.max(vis.w, vis.h) * 0.9; let weak = 0;
  const filtered = merged.filter((d) => { if (d.firm) return true; if (d.box[2] < minSide || d.box[3] < minSide || d.box[2] > maxSide || d.box[3] > maxSide) return false; return ++weak <= 3; });
  updateTracks(filtered, fi * 100);
  return { merged: merged.map((d) => [r4(d.box[0]), r4(d.box[1]), r4(d.box[2]), r4(d.box[3]), d.cls, d.firm]), tracks: tracks.map((t) => ({ id: t.id, hits: t.hits, missed: t.missed, firm: t.firm, box: t.box.map(r4), shown: isShown(t) })) };
});
out.tiles = tileGrid(vis, 3).map((t) => [t.x, t.y, t.w, t.h]);
const sq = cropSquare(null, 1920, 1080, [1500, 900, 300, 120]); out.square = [sq.qx, sq.qy, sq.side];
const tr = { active: false, startedAt: inp.startedAt * 1000, endedAt: inp.endedAt * 1000, dist: inp.dist, points: inp.points.map((p) => [p.t * 1000, p.lat, p.lon, p.spd, p.alt == null ? null : p.alt]) };
const st = tripStats(tr);
out.stats = { dist: st.dist, dur: st.dur / 1000, moving: st.moving / 1000, standing: st.standing / 1000, maxSpeed: r4(st.maxSpeed), avgMoving: r4(st.avgMoving), elev: st.elev,
  stops: st.stops.map((s) => ({ t0: s.t0 / 1000, t1: s.t1 / 1000, dur: s.dur / 1000, lat: s.lat, lon: s.lon, n: s.sightings.length })), splits: st.splits.map((s) => ({ km: s.km, time: s.time / 1000, at: s.at / 1000 })) };
out.coarsen = inp.coarsen.map(([a, b]) => { const c = coarsen(a, b); return [Math.round(c.lat * 1e9) / 1e9, Math.round(c.lon * 1e9) / 1e9]; });
fs.writeFileSync(process.argv[3], JSON.stringify(out));
console.log('ok');

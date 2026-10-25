// Trainiert den Artenkopf auf den MobileNet-Embeddings und exportiert ihn als TF.js-Layers-Modell in ../models/head/.
// Aufruf: node train.js [embeddings.json]
const fs = require('fs');
const path = require('path');
const tf = require('@tensorflow/tfjs-node');

const SITE = path.resolve(__dirname, '..');
const EMB = path.resolve(process.argv[2] || path.join(__dirname, 'embeddings.json'));
const spec = JSON.parse(fs.readFileSync(path.join(__dirname, 'species.json'), 'utf8'));
const classes = spec.classes.map((c) => c.key);
const idx = Object.fromEntries(classes.map((k, i) => [k, i]));

const raw = JSON.parse(fs.readFileSync(EMB, 'utf8'));
const dim = raw.dim;
const buf = fs.readFileSync(path.join(path.dirname(EMB), raw.bin));
const all = new Float32Array(buf.buffer, buf.byteOffset, buf.byteLength / 4);
const items = raw.items;
if (all.length !== items.length * dim) throw new Error('Embedding-Datei passt nicht zum Index: ' + all.length + ' vs ' + items.length * dim);

// Split nach Beobachtung (alle Varianten eines Fotos landen auf derselben Seite), 15 % Validierung
function hash(s) { let h = 2166136261; for (const ch of String(s)) { h ^= ch.charCodeAt(0); h = Math.imul(h, 16777619); } return (h >>> 0) / 4294967295; }
const trainIdx = [], valIdx = [];
items.forEach((it, i) => { if (idx[it.cls] === undefined) return; (hash(it.file) < 0.15 ? valIdx : trainIdx).push(i); });
// Validierung nur mit der ungespiegelten Vollbild-Variante (Variante 0), damit die Zahl realistisch bleibt
const valIdx0 = valIdx.filter((i) => items[i].variant === 0);

function tensors(ids) {
  const x = new Float32Array(ids.length * dim); const y = new Int32Array(ids.length);
  ids.forEach((i, r) => { x.set(all.subarray(i * dim, (i + 1) * dim), r * dim); y[r] = idx[items[i].cls]; });
  return { x: tf.tensor2d(x, [ids.length, dim]), y: tf.tensor1d(y, 'int32') };
}
const tr = tensors(trainIdx), va = tensors(valIdx0);
const yTr = tf.oneHot(tr.y, classes.length), yVa = tf.oneHot(va.y, classes.length);

// Klassengewichte gegen Ungleichgewicht
const counts = new Array(classes.length).fill(0);
trainIdx.forEach((i) => counts[idx[items[i].cls]]++);
const mean = counts.reduce((a, b) => a + b, 0) / classes.length;
const classWeight = Object.fromEntries(counts.map((c, i) => [i, Math.min(3, mean / Math.max(c, 1))]));

const CFG = { hidden: +(process.env.HIDDEN || 256), dropIn: +(process.env.DROP_IN || 0.2), dropH: +(process.env.DROP_H || 0.35), l2: +(process.env.L2 || 1e-4), lr: +(process.env.LR || 1e-3) };
console.log('Konfiguration:', JSON.stringify(CFG));
const model = tf.sequential();
model.add(tf.layers.dropout({ rate: CFG.dropIn, inputShape: [dim] }));
model.add(tf.layers.dense({ units: CFG.hidden, activation: 'relu', kernelRegularizer: tf.regularizers.l2({ l2: CFG.l2 }) }));
model.add(tf.layers.dropout({ rate: CFG.dropH }));
model.add(tf.layers.dense({ units: classes.length, activation: 'softmax' }));
model.compile({ optimizer: tf.train.adam(CFG.lr), loss: 'categoricalCrossentropy', metrics: ['accuracy'] });

(async () => {
  console.log('Klassen:', classes.length, '| Training:', trainIdx.length, 'Vektoren | Validierung:', valIdx0.length, 'Fotos');
  let best = 0, bestWeights = null, patience = 0;
  for (let epoch = 0; epoch < 60; epoch++) {
    const h = await model.fit(tr.x, yTr, { epochs: 1, batchSize: 128, shuffle: true, classWeight, verbose: 0 });
    const ev = model.evaluate(va.x, yVa, { batchSize: 512 });
    const vacc = (await ev[1].data())[0]; ev.forEach((t) => t.dispose());
    if (epoch % 5 === 0 || vacc > best) console.log(`Epoche ${epoch + 1}: loss ${h.history.loss[0].toFixed(3)} acc ${h.history.acc[0].toFixed(3)} | val acc ${vacc.toFixed(3)}`);
    if (vacc > best + 1e-4) { best = vacc; bestWeights = model.getWeights().map((w) => w.clone()); patience = 0; }
    else if (++patience >= 10) break;
    if (epoch === 30) model.optimizer.learningRate = 3e-4;
  }
  model.setWeights(bestWeights);
  console.log('beste Validierungsgenauigkeit:', best.toFixed(3));

  // Verwechslungen und Top-3
  const probs = model.predict(va.x, { batchSize: 512 });
  const p = await probs.array(); probs.dispose();
  const yv = await va.y.array();
  const conf = {}; let top1 = 0, top3 = 0; const perClass = {};
  classes.forEach((c) => { perClass[c] = { n: 0, ok: 0 }; });
  p.forEach((row, r) => {
    const order = row.map((v, i) => [v, i]).sort((a, b) => b[0] - a[0]).map((x) => x[1]);
    const t = yv[r]; perClass[classes[t]].n++;
    if (order[0] === t) { top1++; perClass[classes[t]].ok++; } else { const k = classes[t] + ' -> ' + classes[order[0]]; conf[k] = (conf[k] || 0) + 1; }
    if (order.slice(0, 3).includes(t)) top3++;
  });
  const groupOf = (i) => { const c = spec.classes[i]; return c.negative ? 'Anderes' : (c.group || c.key); };
  let gOk = 0;
  p.forEach((row, r) => { let bi = 0; row.forEach((v, i) => { if (v > row[bi]) bi = i; }); if (groupOf(bi) === groupOf(yv[r])) gOk++; });
  console.log(`Top-1 ${(top1 / p.length * 100).toFixed(1)} %  Top-3 ${(top3 / p.length * 100).toFixed(1)} %  Gruppenebene ${(gOk / p.length * 100).toFixed(1)} %`);
  console.log('Schwächste Klassen:');
  Object.entries(perClass).map(([c, v]) => [c, v.n ? v.ok / v.n : 0, v.n]).sort((a, b) => a[1] - b[1]).slice(0, 12).forEach(([c, a, n]) => console.log('  ', c.padEnd(22), (a * 100).toFixed(0) + ' %', '(' + n + ')'));
  console.log('Häufigste Verwechslungen:');
  Object.entries(conf).sort((a, b) => b[1] - a[1]).slice(0, 15).forEach(([k, n]) => console.log('  ', k, n));

  // Export
  const outDir = path.join(SITE, 'models', 'head', '1.1.0');
  fs.mkdirSync(outDir, { recursive: true });
  await model.save('file://' + outDir);
  const meta = {
    version: '1.1.0', dim, trained: new Date().toISOString().slice(0, 10),
    valTop1: Math.round(top1 / p.length * 1000) / 10, valGroup: Math.round(gOk / p.length * 1000) / 10, valPhotos: p.length,
    classes: spec.classes.map((c) => ({ key: c.key, name: c.name, group: c.group || null, negative: !!c.negative, taxon: c.taxon }))
  };
  fs.writeFileSync(path.join(outDir, 'classes.json'), JSON.stringify(meta));
  const acc = {}; Object.entries(perClass).forEach(([c, v]) => { acc[c] = v.n ? Math.round(v.ok / v.n * 100) : null; });
  fs.writeFileSync(path.join(__dirname, 'report.json'), JSON.stringify({ top1: meta.valTop1, top3: Math.round(top3 / p.length * 1000) / 10, perClass: acc, confusions: conf }, null, 1));
  console.log('exportiert nach', outDir);
})().catch((e) => { console.error(e); process.exit(1); });

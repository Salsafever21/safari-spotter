// Erzeugt reference.json mit TF.js-Ausgaben (Artenmodell und Detektor) für den numerischen Vergleich der Core-ML-Konvertierung.
// Aufruf aus training/: node coreml/check_reference.js <bild.jpg>
const fs = require('fs'), path = require('path');
const tf = require('@tensorflow/tfjs-node');
const mobilenet = require('@tensorflow-models/mobilenet');
const ROOT = path.resolve(__dirname, '..', '..');
const HEAD = path.join(ROOT, 'models', 'head', '1.2.1');
function localHandler(p) { const dir = path.dirname(p); return { load: async () => tf.io.getModelArtifactsForJSON(JSON.parse(fs.readFileSync(p, 'utf8')), async (groups) => { const specs = [], bufs = []; for (const g of groups) { specs.push(...g.weights); for (const q of g.paths) bufs.push(fs.readFileSync(path.join(dir, q))); } const total = bufs.reduce((a, b) => a + b.length, 0); const out = new Uint8Array(total); let off = 0; for (const b of bufs) { out.set(b, off); off += b.length; } return [specs, out.buffer]; }) }; }
(async () => {
  const img = tf.node.decodeImage(fs.readFileSync(process.argv[2]), 3);
  const [H, W] = img.shape;
  // Artenmodell: zentraler Ausschnitt 224×224
  const side = Math.min(H, W);
  const crop = tf.tidy(() => tf.image.resizeBilinear(tf.slice(img, [Math.floor((H - side) / 2), Math.floor((W - side) / 2), 0], [side, side, 3]).toFloat(), [224, 224]).toInt());
  const mn = await mobilenet.load({ version: 2, alpha: 1.0, modelUrl: localHandler(path.join(ROOT, 'models', 'mobilenet', 'model.json')), inputRange: [0, 1] });
  const head = await tf.loadLayersModel('file://' + path.join(HEAD, 'model.json'));
  const probs = tf.tidy(() => head.predict(mn.infer(crop, true)));
  const speciesInput = Array.from(await crop.toFloat().div(255).data());
  const speciesProbs = Array.from(await probs.data());
  // Detektor: Rohausgaben des Graphen bei 300×300-Eingang
  const det = await tf.loadGraphModel(localHandler(path.join(ROOT, 'models', 'cocossd', 'model.json')));
  const small = tf.tidy(() => tf.image.resizeBilinear(img.toFloat(), [300, 300]).toInt().expandDims(0));
  const res = await det.executeAsync(small);
  const scores = Array.from(await res[0].data()), boxes = Array.from(await res[1].data());
  fs.writeFileSync(path.join(__dirname, 'reference.json'), JSON.stringify({ image: path.basename(process.argv[2]), species_input: speciesInput, species_probs: speciesProbs, det_input: Array.from(await small.data()), det_scores: scores, det_boxes: boxes, det_shapes: [res[0].shape, res[1].shape] }));
  const best = speciesProbs.indexOf(Math.max(...speciesProbs));
  console.log('reference.json geschrieben; Arten-Top-1 Index', best, 'p=', speciesProbs[best].toFixed(3), '| Detektor-Shapes', JSON.stringify([res[0].shape, res[1].shape]));
})().catch((e) => { console.error(e); process.exit(1); });

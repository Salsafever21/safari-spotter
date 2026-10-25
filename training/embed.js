// Berechnet MobileNet-v2-Embeddings (1280-d) für alle Trainingsbilder mit exakt dem Graph, den die App im Browser lädt.
// Aufruf: node embed.js [dataDir] [outFile]
// Schreibt outFile (JSON): { classes:[...], keys:[...], dim, items:[{cls, file, obs}], emb: base64(Float32Array) }
const fs = require('fs');
const path = require('path');
const tf = require('@tensorflow/tfjs-node');
const mobilenet = require('@tensorflow-models/mobilenet');

const SITE = path.resolve(__dirname, '..');
const DATA = path.resolve(process.argv[2] || path.join(__dirname, 'data'));
const OUT = path.resolve(process.argv[3] || path.join(__dirname, 'embeddings.json'));
const spec = JSON.parse(fs.readFileSync(path.join(__dirname, 'species.json'), 'utf8'));
const manifest = JSON.parse(fs.readFileSync(path.join(DATA, 'manifest.json'), 'utf8'));

function localHandler(modelJsonPath) {
  const dir = path.dirname(modelJsonPath);
  return { load: async () => {
    const json = JSON.parse(fs.readFileSync(modelJsonPath, 'utf8'));
    return tf.io.getModelArtifactsForJSON(json, async (groups) => {
      const specs = [], bufs = [];
      for (const g of groups) { specs.push(...g.weights); for (const p of g.paths) bufs.push(fs.readFileSync(path.join(dir, p))); }
      const total = bufs.reduce((a, b) => a + b.length, 0);
      const out = new Uint8Array(total); let off = 0;
      for (const b of bufs) { out.set(b, off); off += b.length; }
      return [specs, out.buffer];
    });
  } };
}

// Varianten pro Bild: Vollbild, gespiegelt, zentrierter Ausschnitt (wie ein enger Detektorrahmen), gespiegelter Ausschnitt
function variants(img) {
  const [h, w] = img.shape;
  const s = Math.min(h, w);
  const center = tf.image.cropAndResize(img.expandDims(0).toFloat(), [[(h - s) / 2 / h, (w - s) / 2 / w, (h + s) / 2 / h, (w + s) / 2 / w]], [0], [224, 224]).squeeze();
  const tight = tf.image.cropAndResize(img.expandDims(0).toFloat(), [[0.12, 0.12, 0.88, 0.88]], [0], [224, 224]).squeeze();
  const flip = (t) => tf.reverse(t, 1);
  return [center, flip(center), tight, flip(tight)];
}

(async () => {
  const model = await mobilenet.load({ version: 2, alpha: 1.0, modelUrl: localHandler(path.join(SITE, 'models/mobilenet/model.json')), inputRange: [0, 1] });
  const items = [], chunks = [];
  let dim = 0, n = 0;
  const t0 = Date.now();
  for (const c of spec.classes) {
    const dir = path.join(DATA, c.key);
    if (!fs.existsSync(dir)) { console.log('fehlt:', c.key); continue; }
    const files = fs.readdirSync(dir).filter((f) => f.endsWith('.jpg')).sort();
    let okFiles = 0;
    for (const f of files) {
      let img;
      try { img = tf.node.decodeImage(fs.readFileSync(path.join(dir, f)), 3); } catch (e) { continue; }
      if (img.shape.length !== 3 || img.shape[0] < 64 || img.shape[1] < 64) { img.dispose(); continue; }
      const vs = variants(img);
      const embs = tf.tidy(() => model.infer(tf.stack(vs).toInt(), true));
      const data = await embs.data();
      dim = embs.shape[1];
      for (let v = 0; v < vs.length; v++) {
        chunks.push(Float32Array.from(data.subarray(v * dim, (v + 1) * dim)));
        items.push({ cls: c.key, file: c.key + '/' + f, variant: v, obs: (manifest[c.key + '/' + f] || {}).observation || 0 });
      }
      embs.dispose(); vs.forEach((t) => t.dispose()); img.dispose();
      okFiles++; n++;
      if (n % 500 === 0) console.log(n, 'Bilder,', ((Date.now() - t0) / 1000).toFixed(0), 's');
    }
    console.log(c.key.padEnd(22), okFiles, 'Bilder');
  }
  const all = new Float32Array(chunks.length * dim);
  chunks.forEach((c, i) => all.set(c, i * dim));
  fs.writeFileSync(OUT, JSON.stringify({ dim, items, emb: Buffer.from(all.buffer).toString('base64') }));
  console.log('fertig:', items.length, 'Vektoren ×', dim, 'in', ((Date.now() - t0) / 1000).toFixed(0), 's ->', OUT);
})().catch((e) => { console.error(e); process.exit(1); });

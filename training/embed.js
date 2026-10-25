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
  return tf.tidy(() => {
    const [h, w] = img.shape;
    const s = Math.min(h, w);
    const batch = img.expandDims(0).toFloat();
    const center = tf.image.cropAndResize(batch, [[(h - s) / 2 / h, (w - s) / 2 / w, (h + s) / 2 / h, (w + s) / 2 / w]], [0], [224, 224]);
    const tight = tf.image.cropAndResize(batch, [[0.12, 0.12, 0.88, 0.88]], [0], [224, 224]);
    const flip = (t) => tf.reverse(t, 2);
    // Fern-Variante: enger Ausschnitt auf 72 px herunter- und wieder hochgerechnet, wie ein kleines Tier in der Distanz
    const far = tf.image.resizeBilinear(tf.image.resizeBilinear(tight, [72, 72]), [224, 224]);
    return tf.concat([center, flip(center), tight, flip(tight), far], 0).toInt(); // [5,224,224,3]
  });
}

(async () => {
  const model = await mobilenet.load({ version: 2, alpha: 1.0, modelUrl: localHandler(path.join(SITE, 'models/mobilenet/model.json')), inputRange: [0, 1] });
  const BIN = OUT.replace(/\.json$/, '.bin');
  const fd = fs.openSync(BIN, 'w');
  const items = [];
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
      const vs = variants(img); img.dispose();
      const embs = tf.tidy(() => model.infer(vs, true));
      vs.dispose();
      const data = await embs.data();
      dim = embs.shape[1];
      const nv = embs.shape[0];
      embs.dispose();
      fs.writeSync(fd, Buffer.from(data.buffer, data.byteOffset, data.byteLength));
      for (let v = 0; v < nv; v++) items.push({ cls: c.key, file: c.key + '/' + f, variant: v, obs: (manifest[c.key + '/' + f] || {}).observation || 0 });
      okFiles++; n++;
      if (n % 1000 === 0) console.log(n, 'Bilder,', ((Date.now() - t0) / 1000).toFixed(0), 's, Tensoren im Speicher:', tf.memory().numTensors);
    }
    console.log(c.key.padEnd(22), okFiles, 'Bilder');
  }
  fs.closeSync(fd);
  fs.writeFileSync(OUT, JSON.stringify({ dim, count: items.length, bin: path.basename(BIN), items }));
  console.log('fertig:', items.length, 'Vektoren ×', dim, 'in', ((Date.now() - t0) / 1000).toFixed(0), 's ->', OUT, '+', BIN);
})().catch((e) => { console.error(e); process.exit(1); });

// Auto-Labeling: erzeugt YOLO-Boxen für die Trainingsbilder (training/data/<klasse>/*.jpg) mit dem COCO-SSD-Detektor.
// Die Artklasse ist durch den Ordner bekannt, der Detektor liefert nur die Box. Bilder ohne brauchbare Box bekommen
// eine zentrierte Box über 80 % des Bildes (iNaturalist-Fotos zeigen das Tier meist bildfüllend).
// Aufruf aus training/: node yolo/autolabel.js [--limit N]
// Ergebnis: training/yolo/dataset/{images,labels}/{train,val}/... (Bilder als Symlinks) und dataset.yaml
const fs = require('fs'), path = require('path');
const tf = require('@tensorflow/tfjs-node');
const cocoSsd = require('@tensorflow-models/coco-ssd');
const ROOT = path.resolve(__dirname, '..', '..');
const DATA = path.join(ROOT, 'training', 'data');
const OUT = path.join(__dirname, 'dataset');
const spec = JSON.parse(fs.readFileSync(path.join(ROOT, 'training', 'species.json'), 'utf8'));
const ANIMAL = new Set(['bird', 'cat', 'dog', 'horse', 'sheep', 'cow', 'elephant', 'bear', 'zebra', 'giraffe']);
const limit = (() => { const i = process.argv.indexOf('--limit'); return i > 0 ? parseInt(process.argv[i + 1], 10) : 0; })();
function localHandler(p) { const dir = path.dirname(p); return { load: async () => tf.io.getModelArtifactsForJSON(JSON.parse(fs.readFileSync(p, 'utf8')), async (groups) => { const specs = [], bufs = []; for (const g of groups) { specs.push(...g.weights); for (const q of g.paths) bufs.push(fs.readFileSync(path.join(dir, q))); } const total = bufs.reduce((a, b) => a + b.length, 0); const out = new Uint8Array(total); let off = 0; for (const b of bufs) { out.set(b, off); off += b.length; } return [specs, out.buffer]; }) }; }
function hash(s) { let h = 2166136261; for (const ch of s) { h ^= ch.charCodeAt(0); h = Math.imul(h, 16777619); } return (h >>> 0) / 4294967295; }

(async () => {
  const det = await cocoSsd.load({ base: 'lite_mobilenet_v2', modelUrl: localHandler(path.join(ROOT, 'models', 'cocossd', 'model.json')) });
  const classes = spec.classes.filter((c) => !c.negative);
  const names = classes.map((c) => c.key);
  for (const split of ['train', 'val']) { fs.mkdirSync(path.join(OUT, 'images', split), { recursive: true }); fs.mkdirSync(path.join(OUT, 'labels', split), { recursive: true }); }
  let n = 0, boxed = 0, fallback = 0; const t0 = Date.now();
  for (const [ci, c] of classes.entries()) {
    const dir = path.join(DATA, c.key); if (!fs.existsSync(dir)) continue;
    let files = fs.readdirSync(dir).filter((f) => f.endsWith('.jpg')).sort();
    if (limit) files = files.slice(0, limit);
    for (const f of files) {
      let img; try { img = tf.node.decodeImage(fs.readFileSync(path.join(dir, f)), 3); } catch (e) { continue; }
      if (img.shape.length !== 3) { img.dispose(); continue; }
      const [H, W] = img.shape;
      const preds = await det.detect(img, 10, 0.2);
      img.dispose();
      // beste Tier-Box (grösste mit Score ≥ 0.3), sonst Rückfall
      const animals = preds.filter((p) => ANIMAL.has(p.class) && p.score >= 0.3).sort((a, b) => b.bbox[2] * b.bbox[3] - a.bbox[2] * a.bbox[3]);
      let boxes;
      if (animals.length) {
        // alle Tier-Boxen derselben Art (Herden): nur Boxen, die mindestens 25 % der grössten haben
        const big = animals[0].bbox[2] * animals[0].bbox[3];
        boxes = animals.filter((p) => p.bbox[2] * p.bbox[3] >= big * 0.25).map((p) => p.bbox); boxed++;
      } else { boxes = [[W * 0.1, H * 0.1, W * 0.8, H * 0.8]]; fallback++; }
      const split = hash(c.key + '/' + f) < 0.15 ? 'val' : 'train';
      const stem = c.key + '_' + path.basename(f, '.jpg');
      const lines = boxes.map(([x, y, w, h]) => { const cx = Math.min(1, Math.max(0, (x + w / 2) / W)), cy = Math.min(1, Math.max(0, (y + h / 2) / H)); return `${ci} ${cx.toFixed(5)} ${cy.toFixed(5)} ${Math.min(1, w / W).toFixed(5)} ${Math.min(1, h / H).toFixed(5)}`; });
      fs.writeFileSync(path.join(OUT, 'labels', split, stem + '.txt'), lines.join('\n') + '\n');
      const link = path.join(OUT, 'images', split, stem + '.jpg');
      try { fs.symlinkSync(path.join(dir, f), link); } catch (e) { /* existiert */ }
      n++;
      if (n % 1000 === 0) console.log(n, 'Bilder,', ((Date.now() - t0) / 1000).toFixed(0), 's');
    }
    console.log(c.key.padEnd(22), files.length, 'Bilder');
  }
  const yaml = `# YOLO-Datensatz Safari Spotter (Auto-Labels aus COCO-SSD, Art aus dem Ordnernamen)\npath: ${OUT}\ntrain: images/train\nval: images/val\nnames:\n` + names.map((k, i) => `  ${i}: ${k}`).join('\n') + '\n';
  fs.writeFileSync(path.join(__dirname, 'dataset.yaml'), yaml);
  fs.writeFileSync(path.join(__dirname, 'classes.json'), JSON.stringify(classes.map((c) => ({ key: c.key, name: c.name, group: c.group || null })), null, 1));
  console.log(`fertig: ${n} Bilder, ${boxed} mit Detektor-Box, ${fallback} mit Rückfall-Box, ${((Date.now() - t0) / 1000).toFixed(0)} s -> ${OUT}`);
})().catch((e) => { console.error(e); process.exit(1); });

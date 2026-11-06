// Auto-Labeling: erzeugt YOLO-Boxen für die Trainingsbilder (training/data/<klasse>/*.jpg) mit dem COCO-SSD-Detektor.
// Die Artklasse ist durch den Ordner bekannt, der Detektor liefert nur die Box. Bilder ohne brauchbare Box bekommen
// eine zentrierte Box über 80 % des Bildes (iNaturalist-Fotos zeigen das Tier meist bildfüllend).
// Aufruf aus training/: node yolo/autolabel.js [--limit N] [--overwrite]
// Ergebnis: training/yolo/dataset/{images,labels}/{train,val}/... (Bilder als Symlinks) und dataset.yaml
const fs = require('fs'), path = require('path');
const tf = require('@tensorflow/tfjs-node');
const cocoSsd = require('@tensorflow-models/coco-ssd');
const { isValidation, eligibleFiles, retireStaleLinks } = require('../dataset');
const { acceptsPrediction } = require('./detection_filter');
const { normaliseBox } = require('./box_geometry');
const ROOT = path.resolve(__dirname, '..', '..');
const DATA = path.join(ROOT, 'training', 'data');
const OUT = path.join(__dirname, 'dataset');
const GENERATOR_VERSION = 2;
const spec = JSON.parse(fs.readFileSync(path.join(ROOT, 'training', 'species.json'), 'utf8'));
const manifest = JSON.parse(fs.readFileSync(path.join(DATA, 'manifest.json'), 'utf8'));
const limit = (() => { const i = process.argv.indexOf('--limit'); return i > 0 ? parseInt(process.argv[i + 1], 10) : 0; })();
const overwrite = process.argv.includes('--overwrite');
function localHandler(p) { const dir = path.dirname(p); return { load: async () => tf.io.getModelArtifactsForJSON(JSON.parse(fs.readFileSync(p, 'utf8')), async (groups) => { const specs = [], bufs = []; for (const g of groups) { specs.push(...g.weights); for (const q of g.paths) bufs.push(fs.readFileSync(path.join(dir, q))); } const total = bufs.reduce((a, b) => a + b.length, 0); const out = new Uint8Array(total); let off = 0; for (const b of bufs) { out.set(b, off); off += b.length; } return [specs, out.buffer]; }) }; }

function ensureLink(source, link) {
  try { fs.symlinkSync(source, link); }
  catch (error) {
    if (error.code !== 'EEXIST' || path.resolve(path.dirname(link), fs.readlinkSync(link)) !== source) throw error;
  }
}
function writeLabel(file, lines) {
  const part = file + '.' + process.pid + '.part';
  try { fs.writeFileSync(part, lines); fs.renameSync(part, file); }
  catch (error) { try { fs.unlinkSync(part); } catch (_) {} throw error; }
}
(async () => {
  const classes = spec.classes.filter((c) => !c.negative);
  const names = classes.map((c) => c.key);
  const classesFile = path.join(__dirname, 'classes.json');
  if (fs.existsSync(classesFile)) {
    const previous = JSON.parse(fs.readFileSync(classesFile, 'utf8')).map((c) => c.key);
    if (JSON.stringify(previous) !== JSON.stringify(names)) {
      throw new Error('Klassenreihenfolge geändert: vorhandenen Datensatz separat archivieren und neu erzeugen.');
    }
  }
  const reviewPath = path.join(OUT, 'label-review.json');
  const priorReview = fs.existsSync(reviewPath) ? JSON.parse(fs.readFileSync(reviewPath, 'utf8')) : {};
  const hasLabels = ['train', 'val'].some((split) => {
    const dir = path.join(OUT, 'labels', split);
    return fs.existsSync(dir) && fs.readdirSync(dir).some((name) => name.endsWith('.txt'));
  });
  if (hasLabels && priorReview.generatorVersion !== GENERATOR_VERSION && !overwrite) {
    throw new Error('Alte Labels ohne geprüfte Detektor-Klassen: bestehende Bearbeitungen sichern und --overwrite verwenden.');
  }
  if (overwrite && Object.keys(priorReview.approvedFiles || {}).length) {
    throw new Error('--overwrite würde bereits gesichtete Labels ersetzen; neuen Datensatz separat anlegen.');
  }
  const det = await cocoSsd.load({ base: 'lite_mobilenet_v2', modelUrl: localHandler(path.join(ROOT, 'models', 'cocossd', 'model.json')) });
  for (const split of ['train', 'val']) { fs.mkdirSync(path.join(OUT, 'images', split), { recursive: true }); fs.mkdirSync(path.join(OUT, 'labels', split), { recursive: true }); }
  const { retired, allowedSources } = retireStaleLinks(OUT, DATA, spec.classes, manifest);
  writeLabel(classesFile, JSON.stringify(classes.map((c) => ({ key: c.key, name: c.name, group: c.group || null })), null, 1));
  const fallbackFiles = new Set(!overwrite && Array.isArray(priorReview.fallbackFiles) ? priorReview.fallbackFiles.filter((x) => allowedSources.has(x)) : []);
  const multipleBoxFiles = new Set(!overwrite && Array.isArray(priorReview.multipleBoxFiles) ? priorReview.multipleBoxFiles.filter((x) => allowedSources.has(x)) : []);
  const approvedFiles = Object.fromEntries(Object.entries(priorReview.approvedFiles || {})
    .filter(([relative]) => allowedSources.has(relative)));
  let n = 0, boxed = 0, fallback = 0, negatives = 0, reused = 0; const t0 = Date.now();
  for (const [ci, c] of classes.entries()) {
    const dir = path.join(DATA, c.key); if (!fs.existsSync(dir)) continue;
    let files = eligibleFiles(dir, c.key, manifest);
    if (limit) files = files.slice(0, limit);
    for (const f of files) {
      const relative = c.key + '/' + f;
      const split = isValidation(manifest[relative].observation, relative) ? 'val' : 'train';
      const stem = c.key + '_' + path.basename(f, '.jpg');
      const label = path.join(OUT, 'labels', split, stem + '.txt');
      const link = path.join(OUT, 'images', split, stem + '.jpg');
      if (!overwrite && fs.existsSync(label)) {
        const saved = fs.readFileSync(label, 'utf8').trim();
        if (saved) {
          ensureLink(path.join(dir, f), link);
          const rows = saved.split('\n');
          if (rows.length === 1 && rows[0] === `${ci} 0.50000 0.50000 0.80000 0.80000`) {
            fallbackFiles.add(relative);
          }
          // A manual edit does not clear the review requirement. Only an explicit
          // approval tied to the current JPEG and label hashes can clear it.
          if (rows.length > 1) multipleBoxFiles.add(relative);
          reused++;
          continue;
        }
      }
      let img; try { img = tf.node.decodeImage(fs.readFileSync(path.join(dir, f)), 3); } catch (e) { continue; }
      if (img.shape.length !== 3) { img.dispose(); continue; }
      const [H, W] = img.shape;
      const preds = await det.detect(img, 10, 0.2);
      img.dispose();
      // beste Tier-Box (grösste mit Score ≥ 0.3), sonst Rückfall
      const animals = preds.filter((p) => acceptsPrediction(c.key, p))
        .sort((a, b) => b.bbox[2] * b.bbox[3] - a.bbox[2] * a.bbox[3]);
      let boxes;
      if (animals.length) {
        // alle Tier-Boxen derselben Art (Herden): nur Boxen, die mindestens 25 % der grössten haben
        const big = animals[0].bbox[2] * animals[0].bbox[3];
        boxes = animals.filter((p) => p.bbox[2] * p.bbox[3] >= big * 0.25).map((p) => p.bbox); boxed++;
        if (boxes.length > 1) multipleBoxFiles.add(relative);
      } else {
        boxes = [[W * 0.1, H * 0.1, W * 0.8, H * 0.8]]; fallback++;
        fallbackFiles.add(relative);
      }
      let normalized = boxes.map((box) => normaliseBox(box, W, H)).filter(Boolean);
      if (!normalized.length) {
        normalized = [normaliseBox([W * 0.1, H * 0.1, W * 0.8, H * 0.8], W, H)];
        fallbackFiles.add(relative);
        if (animals.length) { boxed--; fallback++; }
      }
      const lines = normalized.map(([cx, cy, w, h]) =>
        `${ci} ${cx.toFixed(5)} ${cy.toFixed(5)} ${w.toFixed(5)} ${h.toFixed(5)}`);
      ensureLink(path.join(dir, f), link);
      writeLabel(label, lines.join('\n') + '\n');
      n++;
      if (n % 1000 === 0) console.log(n, 'Bilder,', ((Date.now() - t0) / 1000).toFixed(0), 's');
    }
    console.log(c.key.padEnd(22), files.length, 'Bilder');
  }
  // Die vier "Anderes"-Klassen sind harte Gegenbeispiele: Hund, Hausrind, Ziege und Esel
  // sollen keine Safari-Tier-Box auslösen. YOLO nutzt dafür ein leeres Label pro Bild.
  for (const c of spec.classes.filter((item) => item.negative)) {
    const dir = path.join(DATA, c.key); if (!fs.existsSync(dir)) continue;
    let files = eligibleFiles(dir, c.key, manifest);
    if (limit) files = files.slice(0, limit);
    for (const f of files) {
      const relative = c.key + '/' + f;
      const split = isValidation(manifest[relative].observation, relative) ? 'val' : 'train';
      const stem = c.key + '_' + path.basename(f, '.jpg');
      const label = path.join(OUT, 'labels', split, stem + '.txt');
      const link = path.join(OUT, 'images', split, stem + '.jpg');
      ensureLink(path.join(dir, f), link);
      if (!overwrite && fs.existsSync(label)) { reused++; continue; }
      writeLabel(label, '');
      negatives++;
    }
    console.log(c.key.padEnd(22), files.length, 'Gegenbeispiele');
  }
  const yaml = `# YOLO-Datensatz Safari Spotter (Auto-Labels aus COCO-SSD, Art aus dem Ordnernamen)\npath: ${OUT}\ntrain: images/train\nval: images/val\nnames:\n` + names.map((k, i) => `  ${i}: ${k}`).join('\n') + '\n';
  fs.writeFileSync(path.join(__dirname, 'dataset.yaml'), yaml);
  writeLabel(reviewPath, JSON.stringify({ generatedAt: new Date().toISOString(), generatorVersion: GENERATOR_VERSION,
    fallbackFiles: [...fallbackFiles].sort(), multipleBoxFiles: [...multipleBoxFiles].sort(), approvedFiles }, null, 2) + '\n');
  console.log(`fertig: ${n} neue Tierbilder, ${boxed} mit Detektor-Box, ${fallback} mit Rückfall-Box, ${negatives} neue Gegenbeispiele, ${reused} bestehende Labels beibehalten, ${retired} veraltete Verknüpfungen archiviert, ${((Date.now() - t0) / 1000).toFixed(0)} s -> ${OUT}`);
})().catch((e) => { console.error(e); process.exit(1); });

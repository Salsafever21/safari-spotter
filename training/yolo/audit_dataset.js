// Refuse training when labels, sources, split groups or class coverage are inconsistent.
const fs = require('fs');
const path = require('path');
const { eligibleFiles, isValidation, ambiguousSources } = require('../dataset');
const { approvalMatches } = require('./review_label');

const HERE = __dirname;
const DATA = path.resolve(HERE, '..', 'data');
const OUT = path.join(HERE, 'dataset');
const partial = process.argv.includes('--partial');
const spec = JSON.parse(fs.readFileSync(path.resolve(HERE, '..', 'species.json'), 'utf8'));
const manifest = JSON.parse(fs.readFileSync(path.join(DATA, 'manifest.json'), 'utf8'));
const classes = JSON.parse(fs.readFileSync(path.join(HERE, 'classes.json'), 'utf8')).map((c) => c.key);
const positive = spec.classes.filter((c) => !c.negative).map((c) => c.key);
const negative = new Set(spec.classes.filter((c) => c.negative).map((c) => c.key));
const errors = [];
if (JSON.stringify(classes) !== JSON.stringify(positive)) errors.push('Klassenreihenfolge stimmt nicht mit species.json überein');

const wanted = new Map();
for (const c of spec.classes) {
  for (const file of eligibleFiles(path.join(DATA, c.key), c.key, manifest)) {
    const relative = c.key + '/' + file;
    const split = isValidation(manifest[relative].observation, relative) ? 'val' : 'train';
    wanted.set(path.join(OUT, 'images', split, c.key + '_' + path.basename(file, '.jpg') + '.jpg'), relative);
  }
}

const counts = Object.fromEntries(spec.classes.map((c) => [c.key, { train: 0, val: 0 }]));
const observations = new Map();
const observedFallback = new Set(), observedMultiple = new Set();
const labelFor = new Map();
let labels = 0;
for (const split of ['train', 'val']) {
  const imagesDir = path.join(OUT, 'images', split);
  const labelsDir = path.join(OUT, 'labels', split);
  for (const file of fs.readdirSync(imagesDir).filter((x) => x.endsWith('.jpg'))) {
    const link = path.join(imagesDir, file);
    const expected = wanted.get(link);
    if (!expected) { errors.push('Bild nicht im aktiven Manifest: ' + link); continue; }
    let actual;
    try { actual = fs.realpathSync(link); }
    catch { errors.push('Bildverknüpfung ist kaputt: ' + link); continue; }
    if (path.resolve(DATA, expected) !== actual) errors.push('Bildverknüpfung zeigt auf falsche Quelle: ' + link);
    const [key] = expected.split('/');
    const observation = String(manifest[expected].observation || expected);
    const oldSplit = observations.get(observation);
    if (oldSplit && oldSplit !== split) errors.push('Eine Beobachtung liegt in Train und Val: ' + observation);
    observations.set(observation, split);
    const label = path.join(labelsDir, file.replace(/\.jpg$/, '.txt'));
    if (!fs.existsSync(label)) { errors.push('Label fehlt: ' + label); continue; }
    const rows = fs.readFileSync(label, 'utf8').trim().split('\n').filter(Boolean);
    labelFor.set(expected, label);
    if (rows.length === 1 && rows[0] === `${classes.indexOf(key)} 0.50000 0.50000 0.80000 0.80000`) {
      observedFallback.add(expected);
    }
    if (rows.length > 1) observedMultiple.add(expected);
    if (negative.has(key) && rows.length) errors.push('Negatives Beispiel hat Tier-Boxen: ' + label);
    if (!negative.has(key) && !rows.length) errors.push('Tierbild hat keine Box: ' + label);
    for (const row of rows) {
      const values = row.trim().split(/\s+/).map(Number);
      if (values.length !== 5 || values[0] !== classes.indexOf(key) ||
          values.slice(1).some((v) => !Number.isFinite(v) || v < 0 || v > 1) ||
          values[3] <= 0 || values[4] <= 0) errors.push('Ungültige YOLO-Box: ' + label);
    }
    counts[key][split]++;
    labels++;
  }
  for (const file of fs.readdirSync(labelsDir).filter((x) => x.endsWith('.txt'))) {
    if (!fs.existsSync(path.join(imagesDir, file.replace(/\.txt$/, '.jpg')))) {
      errors.push('Label ohne Bild: ' + path.join(labelsDir, file));
    }
  }
}

if (!partial) {
  for (const link of wanted.keys()) if (!fs.existsSync(link)) errors.push('Noch nicht gelabelt: ' + link);
  for (const c of spec.classes) {
    const count = counts[c.key];
    if (count.train < 20 || count.val < 3) {
      errors.push(`Zu wenig Bilder für ${c.key}: ${count.train} Train, ${count.val} Val`);
    }
  }
}
const reviewPath = path.join(OUT, 'label-review.json');
const review = fs.existsSync(reviewPath) ? JSON.parse(fs.readFileSync(reviewPath, 'utf8')) : {};
const fallback = new Set(review.fallbackFiles || []);
const multiple = new Set(review.multipleBoxFiles || []);
for (const relative of observedFallback) if (!fallback.has(relative)) errors.push('Rückfall-Box fehlt in Prüfliste: ' + relative);
for (const relative of observedMultiple) if (!multiple.has(relative)) errors.push('Mehrfach-Box fehlt in Prüfliste: ' + relative);
const queued = new Set([...fallback, ...multiple]);
const unreviewed = [...queued].filter((relative) => {
  const label = labelFor.get(relative);
  return !label || !approvalMatches(review.approvedFiles?.[relative], path.join(DATA, relative), label);
});
if (!partial && unreviewed.length) {
  errors.push(`${unreviewed.length} Rückfall-/Mehrfach-Labels noch nicht am Bild geprüft oder nach Prüfung verändert; Beispiele: ${unreviewed.slice(0, 5).join(', ')}`);
}
console.log(`Geprüft: ${labels} Bilder, ${observations.size} Beobachtungen, ${fallback.size} Rückfall-Boxen, ${multiple.size} Mehrfach-Boxen, ${unreviewed.length} zur Sichtprüfung offen`);
const ambiguous = [...ambiguousSources(manifest)].sort();
if (ambiguous.length) console.log(`${ambiguous.length} widersprüchliche Fotoquellen ausgeschlossen: ${ambiguous.slice(0, 10).join(', ')}`);
console.log('Klassen mit Bildern:', Object.values(counts).filter((c) => c.train + c.val > 0).length, '/', spec.classes.length);
if (errors.length) {
  for (const error of errors.slice(0, 25)) console.error('FEHLER:', error);
  if (errors.length > 25) console.error(`... und ${errors.length - 25} weitere Fehler`);
  process.exitCode = 1;
} else console.log(partial ? 'Teil-Datensatz strukturell korrekt' : 'Datensatz bereit für einen Trainingsversuch');

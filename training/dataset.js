// Shared, deterministic source selection and validation grouping for both training paths.
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const ambiguousCache = new WeakMap();
const excludedPhotos = new Set(Object.keys(JSON.parse(fs.readFileSync(path.join(__dirname, 'excluded_photos.json'), 'utf8'))));

function sourceIdentity(relative, record) {
  if (record.source === 'safari-spotter-correction') {
    return (record.sourceJPEGHash || record.sourceHash) ?
      'correction:' + (record.sourceJPEGHash || record.sourceHash) : null;
  }
  const file = relative.split('/').at(-1);
  return /^\d+\.jpg$/.test(file) ? 'inat:' + file : null;
}

function ambiguousSources(manifest) {
  if (ambiguousCache.has(manifest)) return ambiguousCache.get(manifest);
  const owners = new Map(), ambiguous = new Set();
  for (const [relative, record] of Object.entries(manifest)) {
    if (!record || typeof record !== 'object' || record.superseded ||
        (record.source !== 'safari-spotter-correction' && !['cc0', 'cc-by'].includes(record.license))) continue;
    const identity = sourceIdentity(relative, record);
    if (!identity) continue;
    const owner = relative.split('/')[0];
    if (owners.has(identity) && owners.get(identity) !== owner) ambiguous.add(identity);
    else owners.set(identity, owner);
  }
  ambiguousCache.set(manifest, ambiguous);
  return ambiguous;
}

function hash(value) {
  let h = 2166136261;
  for (const ch of String(value)) { h ^= ch.charCodeAt(0); h = Math.imul(h, 16777619); }
  return (h >>> 0) / 4294967295;
}

function isValidation(observation, file) {
  return hash(observation || file) < 0.15;
}

function sourceFingerprint(bytes, record) {
  return { sha256: crypto.createHash('sha256').update(bytes).digest('hex'),
    observation: String(record.observation || 0), license: record.license || null,
    source: record.source || null };
}

function eligibleFiles(dir, classKey, manifest) {
  if (!fs.existsSync(dir)) return [];
  return fs.readdirSync(dir).filter((file) => {
    if (!file.endsWith('.jpg')) return false;
    const relative = classKey + '/' + file;
    const record = manifest[relative];
    return !excludedPhotos.has(relative) && record && !record.superseded &&
      (record.source === 'safari-spotter-correction' || ['cc0', 'cc-by'].includes(record.license)) &&
      !ambiguousSources(manifest).has(sourceIdentity(relative, record));
  }).sort();
}

function retireStaleLinks(out, data, classes, manifest) {
  const wanted = new Set();
  const allowedSources = new Set();
  for (const c of classes) {
    for (const file of eligibleFiles(path.join(data, c.key), c.key, manifest)) {
      const relative = c.key + '/' + file;
      const split = isValidation(manifest[relative].observation, relative) ? 'val' : 'train';
      wanted.add(path.join(out, 'images', split, c.key + '_' + path.basename(file, '.jpg') + '.jpg'));
      allowedSources.add(relative);
    }
  }
  let retired = 0;
  for (const split of ['train', 'val']) {
    const images = path.join(out, 'images', split);
    for (const file of fs.readdirSync(images).filter((name) => name.endsWith('.jpg'))) {
      const link = path.join(images, file);
      if (wanted.has(link)) continue;
      if (!fs.lstatSync(link).isSymbolicLink()) throw new Error('Fremde Bilddatei im generierten Datensatz: ' + link);
      const label = path.join(out, 'labels', split, file.replace(/\.jpg$/, '.txt'));
      if (fs.existsSync(label)) {
        const archive = path.join(out, 'excluded');
        fs.mkdirSync(archive, { recursive: true });
        fs.renameSync(label, path.join(archive, split + '-' + file + '-' + crypto.randomUUID() + '.txt'));
      }
      fs.unlinkSync(link);  // Only the generated symlink; the source JPEG remains in training/data.
      retired++;
    }
  }
  return { retired, allowedSources };
}

module.exports = { isValidation, eligibleFiles, retireStaleLinks, ambiguousSources, sourceFingerprint };

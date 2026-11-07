// Explicit visual-review marker. Approval is bound to the exact JPEG and YOLO label bytes.
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { eligibleFiles, isValidation } = require('../dataset');

function sha256(file) {
  return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
}

function fingerprint(image, label) {
  return { imageSHA256: sha256(image), labelSHA256: sha256(label) };
}

function approvalMatches(approval, image, label) {
  if (!approval || !fs.existsSync(image) || !fs.existsSync(label)) return false;
  const current = fingerprint(image, label);
  return current.imageSHA256 === approval.imageSHA256 && current.labelSHA256 === approval.labelSHA256;
}

function approve(relative) {
  const data = path.resolve(__dirname, '..', 'data');
  const out = path.join(__dirname, 'dataset');
  const manifest = JSON.parse(fs.readFileSync(path.join(data, 'manifest.json'), 'utf8'));
  const [key, file, extra] = relative.split('/');
  if (extra || !key || !file || !eligibleFiles(path.join(data, key), key, manifest).includes(file)) {
    throw new Error('Bild ist kein aktiver, zulässiger Manifest-Eintrag: ' + relative);
  }
  const reviewPath = path.join(out, 'label-review.json');
  const review = JSON.parse(fs.readFileSync(reviewPath, 'utf8'));
  if (![...(review.fallbackFiles || []), ...(review.multipleBoxFiles || [])].includes(relative)) {
    throw new Error('Bild steht nicht in der Prüfliste: ' + relative);
  }
  const split = isValidation(manifest[relative].observation, relative) ? 'val' : 'train';
  const stem = key + '_' + path.basename(file, '.jpg');
  const image = path.join(data, relative);
  const link = path.join(out, 'images', split, stem + '.jpg');
  const label = path.join(out, 'labels', split, stem + '.txt');
  if (fs.realpathSync(link) !== image) throw new Error('Bildverknüpfung zeigt nicht auf die Quelle');
  if (!fs.readFileSync(label, 'utf8').trim()) throw new Error('Tierlabel fehlt');
  review.approvedFiles ||= {};
  review.approvedFiles[relative] = { ...fingerprint(image, label), reviewedAt: new Date().toISOString() };
  const temp = reviewPath + '.' + process.pid + '.part';
  try { fs.writeFileSync(temp, JSON.stringify(review, null, 2) + '\n'); fs.renameSync(temp, reviewPath); }
  catch (error) { try { fs.unlinkSync(temp); } catch (_) {} throw error; }
  console.log('Sichtprüfung gespeichert:', relative);
}

if (require.main === module) {
  if (process.argv.length !== 4 || process.argv[3] !== '--reviewed') {
    console.error('Nach Sichtprüfung: node yolo/review_label.js <klasse/foto.jpg> --reviewed');
    process.exit(2);
  }
  try { approve(process.argv[2]); } catch (error) { console.error(error.message); process.exit(1); }
}

module.exports = { fingerprint, approvalMatches };

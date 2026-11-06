// Export reviewed YOLO boxes to Apple's normalized Create ML annotation format.
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');
const { boxFitsImage } = require('./box_geometry');

function annotationFromYolo(contents, classes) {
  return contents.trim().split('\n').filter(Boolean).map((row) => {
    const values = row.trim().split(/\s+/).map(Number);
    const [index, x, y, width, height] = values;
    if (values.length !== 5 || !Number.isInteger(index) || !classes[index] ||
        [x, y, width, height].some((v) => !Number.isFinite(v) || v < 0 || v > 1) ||
        width <= 0 || height <= 0 || !boxFitsImage(x, y, width, height)) {
      throw new Error('Ungültiges YOLO-Label: ' + row);
    }
    return { label: classes[index], coordinates: { x, y, width, height } };
  });
}

function exportDataset() {
  const here = __dirname;
  const dataset = path.join(here, 'dataset');
  const output = path.resolve(process.argv[2] || path.join(dataset, 'create_ml'));
  if (fs.existsSync(output)) throw new Error('Create-ML-Export existiert bereits: ' + output);
  // The audit refuses unreviewed fallback/multiple boxes, missing labels, and poor class coverage.
  execFileSync(process.execPath, [path.join(here, 'audit_dataset.js')], { stdio: 'inherit' });
  const classes = JSON.parse(fs.readFileSync(path.join(here, 'classes.json'), 'utf8')).map((c) => c.key);
  const scratch = fs.mkdtempSync(path.join(dataset, 'create_ml.partial-'));
  for (const split of ['train', 'val']) {
    const dest = path.join(scratch, split);
    fs.mkdirSync(dest);
    const annotations = [];
    const images = path.join(dataset, 'images', split);
    for (const file of fs.readdirSync(images).filter((name) => name.endsWith('.jpg')).sort()) {
      const source = fs.realpathSync(path.join(images, file));
      const label = path.join(dataset, 'labels', split, file.replace(/\.jpg$/, '.txt'));
      fs.symlinkSync(source, path.join(dest, file));
      annotations.push({ imagefilename: file, annotation: annotationFromYolo(fs.readFileSync(label, 'utf8'), classes) });
    }
    fs.writeFileSync(path.join(dest, 'annotations.json'), JSON.stringify(annotations));
    console.log(split + ':', annotations.length, 'Bilder');
  }
  fs.renameSync(scratch, output);
  console.log('Create-ML-Datensatz:', output);
}

if (require.main === module) {
  try { exportDataset(); } catch (error) { console.error(error.message); process.exit(1); }
}

module.exports = { annotationFromYolo };

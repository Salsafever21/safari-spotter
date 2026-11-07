const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { isValidation, eligibleFiles, retireStaleLinks, sourceFingerprint } = require('../dataset');

test('all photos from one observation stay in the same split', () => {
  assert.equal(isValidation(123456, 'elefant/one.jpg'), isValidation(123456, 'leopard/two.jpg'));
  assert.equal(isValidation('correction:abc', 'elefant/one.jpg'),
    isValidation('correction:abc', 'elefant/two.jpg'));
});

test('only active, traceable training images are selected', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'spotter-dataset-'));
  try {
    const dir = path.join(root, 'elefant');
    fs.mkdirSync(dir);
    for (const name of ['licensed.jpg', 'reviewed.jpg', 'superseded.jpg', 'orphan.jpg', 'unlicensed.jpg']) {
      fs.writeFileSync(path.join(dir, name), 'fixture');
    }
    const manifest = {
      'elefant/licensed.jpg': { license: 'cc-by', observation: 123 },
      'elefant/reviewed.jpg': { source: 'safari-spotter-correction', observation: 'correction:abc' },
      'elefant/superseded.jpg': { source: 'safari-spotter-correction', superseded: true },
      'elefant/unlicensed.jpg': { license: 'all-rights-reserved' },
    };
    assert.deepEqual(eligibleFiles(dir, 'elefant', manifest), ['licensed.jpg', 'reviewed.jpg']);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('a superseded correction leaves training while its source and old label survive', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'spotter-retire-'));
  try {
    const data = path.join(root, 'data');
    const out = path.join(root, 'dataset');
    const sourceDir = path.join(data, 'elefant');
    fs.mkdirSync(sourceDir, { recursive: true });
    for (const split of ['train', 'val']) {
      fs.mkdirSync(path.join(out, 'images', split), { recursive: true });
      fs.mkdirSync(path.join(out, 'labels', split), { recursive: true });
    }
    const active = path.join(sourceDir, 'active.jpg');
    const old = path.join(sourceDir, 'old.jpg');
    fs.writeFileSync(active, 'original active image');
    fs.writeFileSync(old, 'original superseded image');
    const activeSplit = isValidation(123, 'elefant/active.jpg') ? 'val' : 'train';
    const activeLink = path.join(out, 'images', activeSplit, 'elefant_active.jpg');
    fs.symlinkSync(active, activeLink);
    fs.writeFileSync(path.join(out, 'labels', activeSplit, 'elefant_active.txt'), '0 0.5 0.5 0.8 0.8\n');
    const oldLink = path.join(out, 'images', 'train', 'elefant_old.jpg');
    fs.symlinkSync(old, oldLink);
    fs.writeFileSync(path.join(out, 'labels', 'train', 'elefant_old.txt'), '0 0.5 0.5 0.8 0.8\n');
    const manifest = {
      'elefant/active.jpg': { license: 'cc-by', observation: 123 },
      'elefant/old.jpg': { source: 'safari-spotter-correction', superseded: true },
    };
    const result = retireStaleLinks(out, data, [{ key: 'elefant' }], manifest);
    assert.equal(result.retired, 1);
    assert.ok(fs.existsSync(activeLink));
    assert.ok(fs.existsSync(old));
    assert.ok(!fs.existsSync(oldLink));
    const archived = fs.readdirSync(path.join(out, 'excluded'));
    assert.equal(archived.length, 1);
    assert.match(fs.readFileSync(path.join(out, 'excluded', archived[0]), 'utf8'), /^0 0\.5/);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('a photo assigned to two species is excluded from both datasets', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'spotter-ambiguous-'));
  try {
    for (const key of ['steppenzebra', 'tuepfelhyaene']) {
      const dir = path.join(root, key);
      fs.mkdirSync(dir);
      fs.writeFileSync(path.join(dir, '486724930.jpg'), 'same photo');
    }
    const manifest = {
      'steppenzebra/486724930.jpg': { license: 'cc-by', observation: 1 },
      'tuepfelhyaene/486724930.jpg': { license: 'cc-by', observation: 2 },
    };
    assert.deepEqual(eligibleFiles(path.join(root, 'steppenzebra'), 'steppenzebra', manifest), []);
    assert.deepEqual(eligibleFiles(path.join(root, 'tuepfelhyaene'), 'tuepfelhyaene', manifest), []);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('conflicting active corrections from one original JPEG are excluded', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'spotter-correction-conflict-'));
  try {
    for (const key of ['elefant', 'leopard']) {
      const dir = path.join(root, key);
      fs.mkdirSync(dir);
      fs.writeFileSync(path.join(dir, 'correction-x.jpg'), 'fixture');
    }
    const record = { source: 'safari-spotter-correction', sourceJPEGHash: 'same-original' };
    const manifest = { 'elefant/correction-x.jpg': record, 'leopard/correction-x.jpg': record };
    assert.deepEqual(eligibleFiles(path.join(root, 'elefant'), 'elefant', manifest), []);
    assert.deepEqual(eligibleFiles(path.join(root, 'leopard'), 'leopard', manifest), []);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('a visually rejected photo stays on disk but leaves both training paths', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'spotter-rejected-'));
  try {
    const dir = path.join(root, 'karakal');
    fs.mkdirSync(dir);
    const file = path.join(dir, '30955166.jpg');
    fs.writeFileSync(file, 'original image remains');
    const manifest = { 'karakal/30955166.jpg': { license: 'cc-by', observation: 123 } };
    assert.deepEqual(eligibleFiles(dir, 'karakal', manifest), []);
    assert.ok(fs.existsSync(file));
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('embedding provenance changes with the source image or observation', () => {
  const original = sourceFingerprint(Buffer.from('photo A'), { license: 'cc-by', observation: 12 });
  assert.notDeepEqual(original, sourceFingerprint(Buffer.from('photo B'), { license: 'cc-by', observation: 12 }));
  assert.notDeepEqual(original, sourceFingerprint(Buffer.from('photo A'), { license: 'cc-by', observation: 13 }));
});

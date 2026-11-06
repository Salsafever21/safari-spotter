const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { fingerprint, approvalMatches } = require('../yolo/review_label');
const { acceptsPrediction } = require('../yolo/detection_filter');

test('visual approval expires when an image or its box changes', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'spotter-label-review-'));
  try {
    const image = path.join(dir, 'image.jpg');
    const label = path.join(dir, 'label.txt');
    fs.writeFileSync(image, 'original photo');
    fs.writeFileSync(label, '0 0.5 0.5 0.8 0.8\n');
    const approval = fingerprint(image, label);
    assert.ok(approvalMatches(approval, image, label));
    fs.writeFileSync(label, '0 0.4 0.5 0.3 0.4\n');
    assert.ok(!approvalMatches(approval, image, label));
    fs.writeFileSync(label, '0 0.5 0.5 0.8 0.8\n');
    fs.writeFileSync(image, 'replaced photo');
    assert.ok(!approvalMatches(approval, image, label));
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('a distinctive COCO animal cannot label a different species', () => {
  assert.ok(acceptsPrediction('elefant', { class: 'elephant', score: 0.8 }));
  assert.ok(!acceptsPrediction('impala', { class: 'elephant', score: 0.8 }));
  assert.ok(!acceptsPrediction('elefant', { class: 'zebra', score: 0.8 }));
  assert.ok(acceptsPrediction('impala', { class: 'horse', score: 0.8 }));
  assert.ok(!acceptsPrediction('impala', { class: 'bird', score: 0.8 }));
  assert.ok(acceptsPrediction('strauss', { class: 'bird', score: 0.8 }));
  assert.ok(!acceptsPrediction('strauss', { class: 'horse', score: 0.8 }));
});

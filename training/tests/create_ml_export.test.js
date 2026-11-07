const { test } = require('node:test');
const assert = require('node:assert/strict');
const { annotationFromYolo } = require('../yolo/export_create_ml');
const { normaliseBox, boxFitsImage } = require('../yolo/box_geometry');

test('YOLO center and normalized box size retain both species in Create ML', () => {
  const annotation = annotationFromYolo('0 0.25 0.5 0.2 0.4\n1 0.75 0.4 0.1 0.2\n', ['elefant', 'giraffe']);
  assert.deepEqual(annotation, [
    { label: 'elefant', coordinates: { x: 0.25, y: 0.5, width: 0.2, height: 0.4 } },
    { label: 'giraffe', coordinates: { x: 0.75, y: 0.4, width: 0.1, height: 0.2 } },
  ]);
  assert.deepEqual(annotationFromYolo('', ['elefant']), []);
  assert.throws(() => annotationFromYolo('3 0.5 0.5 0.2 0.2', ['elefant']));
});

test('a detector box crossing the photo edge is clipped before training', () => {
  const [x, y, width, height] = normaliseBox([-10, 20, 100, 100], 200, 100);
  assert.deepEqual([x, y, width, height], [0.225, 0.6, 0.45, 0.8]);
  assert.ok(boxFitsImage(x, y, width, height));
  assert.ok(!boxFitsImage(0.40438, 0.49713, 0.81539, 1));
  assert.throws(() => annotationFromYolo('0 0.40438 0.49713 0.81539 1', ['elefant']));
});

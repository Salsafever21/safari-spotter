const { test } = require('node:test');
const assert = require('node:assert/strict');
const { annotationFromYolo } = require('../yolo/export_create_ml');

test('YOLO center and normalized box size retain both species in Create ML', () => {
  const annotation = annotationFromYolo('0 0.25 0.5 0.2 0.4\n1 0.75 0.4 0.1 0.2\n', ['elefant', 'giraffe']);
  assert.deepEqual(annotation, [
    { label: 'elefant', coordinates: { x: 0.25, y: 0.5, width: 0.2, height: 0.4 } },
    { label: 'giraffe', coordinates: { x: 0.75, y: 0.4, width: 0.1, height: 0.2 } },
  ]);
  assert.deepEqual(annotationFromYolo('', ['elefant']), []);
  assert.throws(() => annotationFromYolo('3 0.5 0.5 0.2 0.2', ['elefant']));
});

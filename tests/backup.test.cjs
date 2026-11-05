const test = require('node:test');
const assert = require('node:assert/strict');
const archive = require('../backup.js');

test('backup preserves every record and verifies photo bytes', async () => {
  const image = new Blob([Uint8Array.from([0xff, 0xd8, 1, 2, 3, 0xff, 0xd9])], { type: 'image/jpeg' });
  const snapshot = {
    settings: { gps: true },
    sightings: [{ id: 'one', s: 'Elefant', t: 1000, n: 2, lat: -24.1, lon: 31.2 }],
    trip: { active: true, startedAt: 500, points: [[500, -24.1, 31.2]], dist: 10 },
    trips: [{ startedAt: 100, endedAt: 200, points: [[100, -24, 31]], dist: 25 }]
  };
  const photo = { id: 4, t: 1000, kind: 'auto', species: ['Elefant'], sightIds: ['one'],
    lat: -24.1, lon: 31.2, coarse: false, thumb: 'data:image/jpeg;base64,AA==', blob: image };
  const correction = { id: 8, img: 'data:image/jpeg;base64,AA==', status: 'review' };
  const { file } = await archive.create({ snapshot, stored: { 'ss.settings': '{"gps":true}' },
    photos: [photo], corrections: [correction], sourceVersion: '1.5.1', origin: 'https://example.org' });
  const restored = await archive.inspect(file);
  assert.deepEqual(restored.snapshot, snapshot);
  assert.deepEqual(restored.corrections, [correction]);
  const { blob: ignored, ...metadata } = photo;
  assert.deepEqual(restored.photos[0].metadata, metadata);
  assert.equal(restored.counts.photos, 1);
  const bytes = new Uint8Array(await file.arrayBuffer());
  bytes[bytes.length - 1] ^= 1;
  await assert.rejects(archive.inspect(new Blob([bytes])), /Prüfsumme/);
});

const test = require('node:test');
const assert = require('node:assert/strict');
const { protectLinkedPhoto } = require('../privacy.js');

test('rhino correction protects the linked photo without changing unrelated photos', () => {
  const photo = { id: 7, sightIds: ['s1'], species: ['Löwe'], lat: -24.98765, lon: 31.54321, coarse: false, acc: 5 };
  const other = { ...photo, id: 8, sightIds: ['s2'] };
  const coarse = (lat, lon) => ({ lat: Math.round(lat * 10) / 10, lon: Math.round(lon * 10) / 10 });
  const protectedPhoto = protectLinkedPhoto(photo, 's1', 'Breitmaulnashorn', coarse);
  assert.deepEqual(protectedPhoto.species, ['Löwe', 'Breitmaulnashorn']);
  assert.equal(protectedPhoto.coarse, true);
  assert.equal(protectedPhoto.acc, 10000);
  assert.notEqual(protectedPhoto.lat, photo.lat);
  assert.equal(photo.coarse, false);
  assert.equal(protectLinkedPhoto(other, 's1', 'Breitmaulnashorn', coarse), null);
  assert.equal(protectLinkedPhoto(protectedPhoto, 's1', 'Breitmaulnashorn', () => { throw Error('doubled'); }).lat, protectedPhoto.lat);
});

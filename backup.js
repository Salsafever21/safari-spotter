/* Lossless Safari Spotter archive. Keep this format stable for native imports. */
(() => {
  'use strict';
  const magic = new TextEncoder().encode('SSBK1\n');
  const encoder = new TextEncoder();

  function hex(bytes) { return Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join(''); }
  async function digest(blob) {
    return hex(new Uint8Array(await crypto.subtle.digest('SHA-256', await blob.arrayBuffer())));
  }
  function readStore(db, name) {
    return new Promise((resolve, reject) => {
      const tx = db.transaction(name, 'readonly');
      const req = tx.objectStore(name).getAll();
      req.onsuccess = () => resolve(req.result);
      req.onerror = () => reject(req.error || new Error(name + ' konnte nicht gelesen werden'));
      tx.onabort = () => reject(tx.error || new Error(name + ' wurde abgebrochen'));
    });
  }
  function openDatabase() {
    return new Promise((resolve, reject) => {
      const req = indexedDB.open('spotter', 2);
      req.onsuccess = () => resolve(req.result);
      req.onerror = () => reject(req.error || new Error('IndexedDB konnte nicht geöffnet werden'));
      req.onupgradeneeded = () => {
        const db = req.result;
        if (!db.objectStoreNames.contains('photos')) db.createObjectStore('photos', { keyPath: 'id', autoIncrement: true });
        if (!db.objectStoreNames.contains('corrections')) db.createObjectStore('corrections', { keyPath: 'id', autoIncrement: true });
      };
    });
  }
  async function capture(snapshot, sourceVersion) {
    const db = await openDatabase();
    let photos, corrections;
    try {
      photos = await readStore(db, 'photos');
      corrections = await readStore(db, 'corrections');
    } finally { db.close(); }
    const stored = {};
    for (let i = 0; i < localStorage.length; i++) {
      const key = localStorage.key(i);
      if (key.startsWith('ss.')) stored[key] = localStorage.getItem(key);
    }
    return create({ snapshot, stored, photos, corrections, sourceVersion, origin: location.origin });
  }
  async function create({ snapshot, stored, photos, corrections, sourceVersion, origin }) {
    const binaries = [];
    const photoRecords = [];
    let offset = 0;
    for (const photo of photos) {
      if (!(photo.blob instanceof Blob)) throw new Error('Foto ' + photo.id + ' hat keine Bilddatei');
      const { blob, ...metadata } = photo;
      photoRecords.push({ metadata, offset, length: blob.size, type: blob.type, sha256: await digest(blob) });
      binaries.push(blob);
      offset += blob.size;
    }
    const manifest = {
      format: 'safari-spotter-backup', version: 1, createdAt: new Date().toISOString(),
      sourceVersion, origin, snapshot, stored, corrections, photos: photoRecords,
      counts: { sightings: snapshot.sightings.length, photos: photos.length, corrections: corrections.length,
        completedDrives: snapshot.trips.length, activeDrive: !!snapshot.trip.active },
      binaryLength: offset
    };
    const json = encoder.encode(JSON.stringify(manifest));
    const length = new Uint8Array(8);
    new DataView(length.buffer).setBigUint64(0, BigInt(json.length), true);
    const file = new File([magic, length, json, ...binaries],
      'safari-spotter-' + new Date().toISOString().slice(0, 10) + '.ssbackup',
      { type: 'application/octet-stream' });
    return { file, manifest };
  }
  async function inspect(file) {
    const header = new Uint8Array(await file.slice(0, 14).arrayBuffer());
    if (header.length !== 14 || magic.some((b, i) => b !== header[i])) throw new Error('Keine Safari-Spotter-Sicherung');
    const size = Number(new DataView(header.buffer).getBigUint64(6, true));
    if (!Number.isSafeInteger(size) || size < 2 || size > 100_000_000) throw new Error('Ungültige Sicherungslänge');
    const start = 14 + size;
    if (start > file.size) throw new Error('Sicherung unvollständig');
    const manifest = JSON.parse(new TextDecoder().decode(await file.slice(14, start).arrayBuffer()));
    if (manifest.format !== 'safari-spotter-backup' || manifest.version !== 1 ||
        !Array.isArray(manifest.photos) || !Array.isArray(manifest.corrections) ||
        !Array.isArray(manifest.snapshot?.sightings) || !Array.isArray(manifest.snapshot?.trips) ||
        !manifest.snapshot?.trip) throw new Error('Sicherungsformat ungültig');
    if (start + manifest.binaryLength !== file.size || manifest.photos.length !== manifest.counts.photos ||
        manifest.snapshot.sightings.length !== manifest.counts.sightings ||
        manifest.corrections.length !== manifest.counts.corrections ||
        manifest.snapshot.trips.length !== manifest.counts.completedDrives) throw new Error('Sicherung unvollständig');
    for (const photo of manifest.photos) {
      if (photo.offset < 0 || photo.length < 0 || photo.offset + photo.length > manifest.binaryLength) throw new Error('Foto ausserhalb der Sicherung');
      const actual = await digest(file.slice(start + photo.offset, start + photo.offset + photo.length));
      if (actual !== photo.sha256) throw new Error('Foto-Prüfsumme stimmt nicht');
    }
    return manifest;
  }
  const api = { capture, create, inspect };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  if (typeof window !== 'undefined') window.SafariSpotterArchive = api;
})();

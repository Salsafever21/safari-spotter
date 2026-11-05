/* Keep linked animal photos safe when a sighting is corrected to a sensitive species. */
(() => {
  'use strict';
  function protectLinkedPhoto(photo, sightingId, species, coarsen) {
    if (!(photo.sightIds || []).includes(sightingId)) return null;
    const updated = { ...photo, species: [...new Set([...(photo.species || []), species])] };
    if (updated.lat != null && updated.lon != null && !updated.coarse) {
      const point = coarsen(updated.lat, updated.lon);
      updated.lat = point.lat;
      updated.lon = point.lon;
      updated.acc = 10000;
      updated.coarse = true;
    }
    return updated;
  }
  const api = { protectLinkedPhoto };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  if (typeof window !== 'undefined') window.SafariSpotterPrivacy = api;
})();

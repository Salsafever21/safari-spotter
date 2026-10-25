/* Safari Spotter Service Worker: App-Hülle vorab cachen, Modelle beim ersten Laden dauerhaft ablegen. */
const APP_CACHE = 'spotter-app-v1.2.0';
const MODEL_CACHE = 'spotter-models-v1';
const SHELL = [
  './', './index.html', './manifest.webmanifest',
  './vendor/tf.min.js', './vendor/coco-ssd.min.js', './vendor/mobilenet.min.js',
  './icon-180.png', './icon-192.png', './icon-512.png'
];

self.addEventListener('install', (e) => {
  e.waitUntil(caches.open(APP_CACHE).then((c) => c.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', (e) => {
  e.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== APP_CACHE && k !== MODEL_CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

async function cacheFirst(cacheName, req) {
  const cache = await caches.open(cacheName);
  const hit = await cache.match(req, { ignoreSearch: true });
  if (hit) return hit;
  const res = await fetch(req);
  if (res && res.ok) cache.put(req, res.clone());
  return res;
}

async function networkFirst(cacheName, req, fallbackUrl) {
  const cache = await caches.open(cacheName);
  try {
    const res = await fetch(req);
    if (res && res.ok) cache.put(req, res.clone());
    return res;
  } catch (err) {
    const hit = await cache.match(req, { ignoreSearch: true });
    if (hit) return hit;
    if (fallbackUrl) { const fb = await cache.match(fallbackUrl); if (fb) return fb; }
    throw err;
  }
}

async function staleWhileRevalidate(cacheName, req) {
  const cache = await caches.open(cacheName);
  const hit = await cache.match(req, { ignoreSearch: true });
  const fetching = fetch(req).then((res) => { if (res && res.ok) cache.put(req, res.clone()); return res; }).catch(() => null);
  return hit || (await fetching) || Response.error();
}

self.addEventListener('fetch', (e) => {
  const req = e.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return;
  if (url.pathname.includes('/models/')) { e.respondWith(cacheFirst(MODEL_CACHE, req)); return; }
  if (req.mode === 'navigate') { e.respondWith(networkFirst(APP_CACHE, req, './index.html')); return; }
  e.respondWith(staleWhileRevalidate(APP_CACHE, req));
});

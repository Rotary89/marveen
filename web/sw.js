// Service worker for PWA installability.
// Strategy: network-first for app-shell assets (always fresh when online),
// cache fallback for offline use. /api/* always bypassed (Bearer-auth safety).

const CACHE_NAME = 'marveen-shell-v2';

self.addEventListener('install', (event) => {
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(keys.filter((k) => k !== CACHE_NAME).map((k) => caches.delete(k)))
    )
  );
  self.clients.claim();
});

self.addEventListener('fetch', (event) => {
  const url = new URL(event.request.url);

  // Never intercept API calls — they carry Bearer auth and must not be cached.
  if (url.pathname.startsWith('/api/')) return;

  // Network-first: try live fetch, update cache on success, fall back to cache offline.
  // Only cache same-origin responses — cross-origin CDN scripts return opaque responses
  // that would throw TypeError on cache.put.
  event.respondWith(
    fetch(event.request)
      .then((response) => {
        // Only cache successful same-origin responses. Caching an error/opaque
        // response then serving it later would poison the shell.
        if (url.origin === self.location.origin && response.ok) {
          const clone = response.clone();
          caches.open(CACHE_NAME).then((cache) => cache.put(event.request, clone));
        }
        return response;
      })
      .catch(async () => {
        // Network failed (offline, cold proxy, transient). Fall back to cache,
        // but a cache MISS must NOT resolve to null -- respondWith(null) throws
        // "Returned response is null" and breaks the page. Return a proper
        // network-error Response so the browser handles it as a normal failure.
        const cached = await caches.match(event.request);
        return cached || Response.error();
      })
  );
});

// Service Worker - DTS
// Permite que o app funcione offline após a primeira abertura com internet.
const CACHE = "dts-axial-v14";

// Arquivos do próprio app (mesma origem) para pré-cachear na instalação
const APP_SHELL = [
  "./",
  "./index.html",
  "./modelo_dts.pdf",
  "./modelo_pt_quente.pdf",
  "./modelo_pt_eletricidade.pdf",
  "./modelo_pt_altura.pdf",
  "./modelo_pt_escavacao.pdf",
  "./modelo_pt_confinado.pdf",
  "./modelo_pt_mergulho.pdf",
  "./modelo_pt_icamento.pdf",
  "./manifest.json",
  "./icon-192.png",
  "./icon-512.png",
];

// CDNs das bibliotecas - cacheadas em runtime na primeira visita online
const CDN_HOSTS = [
  "unpkg.com",
  "cdn.jsdelivr.net",
  "cdnjs.cloudflare.com",
];

self.addEventListener("install", (e) => {
  e.waitUntil(
    caches.open(CACHE).then((c) => c.addAll(APP_SHELL)).catch(()=>{}).then(()=>self.skipWaiting())
  );
});

self.addEventListener("activate", (e) => {
  e.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k)))
    ).then(() => self.clients.claim())
  );
});

// Permite que a página peça ativação imediata da nova versão
self.addEventListener("message", (e) => {
  if (e.data === "SKIP_WAITING") self.skipWaiting();
});

self.addEventListener("fetch", (e) => {
  const url = new URL(e.request.url);

  // Nunca cachear chamadas ao Supabase (API e Storage)
  if (url.hostname.endsWith("supabase.co")) {
    return; // deixa passar direto pela rede
  }

  const isApp = url.origin === self.location.origin;
  const isCDN = CDN_HOSTS.some((h) => url.hostname.endsWith(h));
  if (!isApp && !isCDN) return;

  // Para o app (HTML e arquivos próprios): REDE PRIMEIRO.
  // Assim, correções chegam na hora; o cache só entra se estiver offline.
  if (isApp) {
    e.respondWith(
      fetch(e.request).then((resp) => {
        if (resp && resp.status === 200) {
          const copy = resp.clone();
          caches.open(CACHE).then((c) => c.put(e.request, copy));
        }
        return resp;
      }).catch(() => caches.match(e.request)) // offline: usa o cache
    );
    return;
  }

  // Para as CDNs (bibliotecas que não mudam): cache primeiro (mais rápido).
  e.respondWith(
    caches.open(CACHE).then(async (cache) => {
      const cached = await cache.match(e.request);
      const fetchPromise = fetch(e.request).then((resp) => {
        if (resp && resp.status === 200) cache.put(e.request, resp.clone());
        return resp;
      }).catch(() => cached);
      return cached || fetchPromise;
    })
  );
});

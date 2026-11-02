/* System notifications from the open ORBITA page. No caching or Web Push yet. */
'use strict';
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('notificationclick', event => {
  event.notification.close();
  event.waitUntil((async () => {
    const target = new URL('./orbita-live-0.3.html', self.location.href);
    const windows = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    for (const client of windows) {
      const url = new URL(client.url);
      if (url.origin === target.origin && url.pathname === target.pathname) {
        await client.focus(); client.postMessage({ type: 'orbita-open-offer' }); return;
      }
    }
    await self.clients.openWindow(target.href);
  })());
});

// Requires Playwright and its Chromium runtime. Uses an isolated browser profile.
const { chromium } = require('playwright');
const assert = require('node:assert/strict');
const base = process.env.EXCALIDRAW_URL || 'http://127.0.0.1:3100';
(async () => {
  const browser = await chromium.launch({ headless: true });
  try {
    const page = await browser.newPage({ viewport: { width: 1600, height: 1300 } });
    const errors = [];
    const externalRequests = [];
    await page.route('**/*', route => {
      const url = new URL(route.request().url());
      if (['http:', 'https:'].includes(url.protocol) && url.origin !== new URL(base).origin) {
        externalRequests.push(url.href);
        return route.abort();
      }
      return route.continue();
    });
    page.on('pageerror', error => errors.push(error.message));
    const id = `browser-smoke-${Date.now()}`;
    const response = await page.request.put(`${base}/api/scenes/${id}`, { data: {
      elements: [{ type: 'rectangle', id: 'handoff-box', x: 100, y: 100,
        width: 400, height: 160, backgroundColor: '#dcebdc',
        label: { text: 'MCP to upstream Excalidraw' } }],
      appState: { viewBackgroundColor: '#fffdf7' }, files: {},
    } });
    assert.equal(response.status(), 200);
    await page.goto(`${base}/bridge/?scene=${id}`);
    await page.waitForFunction(() => window.diagram?.api?.getSceneElements().length > 0);
    await page.getByRole('button', { name: 'Open in Excalidraw', exact: true }).click();
    await page.waitForFunction(() => document.title === 'Excalidraw Whiteboard');
    await page.waitForFunction(() => {
      const saved = JSON.parse(localStorage.getItem('excalidraw') || '[]');
      return saved.some(e => e.text === 'MCP to upstream Excalidraw');
    });
    assert.equal(await page.getByRole('button', { name: 'Open in Excalidraw', exact: true }).count(), 0);
    assert.ok(await page.locator('canvas').count() > 0);
    await page.reload();
    await page.waitForFunction(() => JSON.parse(localStorage.getItem('excalidraw') || '[]').some(e => e.text === 'MCP to upstream Excalidraw'));
    await page.locator('canvas').first().waitFor();
    assert.equal(await page.evaluate(async () => (await navigator.serviceWorker.getRegistrations()).length), 0);
    await page.goto(`${base}/bridge/?scene=${id}`);
    await page.waitForFunction(() => document.title === 'Excalidraw MCP bridge');
    await page.waitForFunction(() => window.diagram?.api?.getSceneElements().length > 0);
    await page.evaluate(() => document.fonts.ready);
    for (const format of ['PNG', 'SVG', 'EXCALIDRAW']) {
      const nextDownload = page.waitForEvent('download');
      await page.getByRole('button', { name: format, exact: true }).click();
      const download = await nextDownload;
      assert.equal(await download.failure(), null);
      const file = await download.path();
      assert.ok(require('node:fs').statSync(file).size > 100);
    }
    const blocked = await page.evaluate(async () => {
      try { await fetch('https://excalidraw.com/local-only-test', {method:'POST',body:'{}'}); return false; }
      catch { return true; }
    });
    assert.equal(blocked,true);
    assert.deepEqual(externalRequests, [], 'No external request may reach the browser network layer');
    assert.deepEqual(errors, []);
    if (process.env.EXCALIDRAW_SCREENSHOT) await page.screenshot({path: process.env.EXCALIDRAW_SCREENSHOT});
    console.log('PASS: bridge handoff opens full upstream app; scene imported and persists after reload; native PNG/SVG/scene exports; no external browser requests; external POST blocked by CSP; no page errors');
  } finally {
    await browser.close();
  }
})().catch(error => { console.error(error); process.exitCode = 1; });

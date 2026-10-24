import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';

test('UI calls the configured API, renders real data safely, and supports retry after failure', async () => {
  const root = { textContent: '', children: [], replaceChildren() { this.children = []; }, append(node) { this.children.push(node); } };
  let click;
  const button = { disabled: false, addEventListener(event, callback) { assert.equal(event, 'click'); click = callback; } };
  const calls = [];
  let fail = false;
  const source = readFileSync(new URL('./app.js', import.meta.url), 'utf8');
  runInNewContext(`const API_BASE_URL = 'https://api.example.com/api';\n${source}`, {
    document: {
      querySelector: selector => selector === 'main' ? root : button,
      createElement: () => ({ textContent: '' }),
    },
    AbortSignal,
    fetch: async (url, options) => {
      assert.equal(options.cache, 'no-store');
      assert.ok(options.signal instanceof AbortSignal);
      calls.push(url);
      if (fail) throw new Error('network offline');
      return { ok: true, json: async () => url.endsWith('health')
        ? { status: 'ok', release: '<script>untrusted</script>', postgres: { ok: true }, redis: { ok: true } }
        : { ok: true, time: { now: '2026-10-24T12:00:00Z' } } };
    },
  });
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(calls, ['https://api.example.com/api/health', 'https://api.example.com/api/users']);
  assert.equal(root.children.length, 3);
  assert.match(root.children[0].textContent, /<script>untrusted<\/script>/);
  assert.match(root.children[2].textContent, /2026-10-24/);
  fail = true;
  await click();
  assert.match(root.textContent, /API unavailable: network offline/);
  assert.equal(button.disabled, false);
  fail = false;
  await click();
  assert.equal(root.children.length, 3);
});

test('stalled requests time out after 10 seconds and allow refresh', async () => {
  const root = { textContent: '' };
  let click;
  const button = { disabled: false, addEventListener(event, callback) { click = callback; } };
  const controllers = [];
  const source = readFileSync(new URL('./app.js', import.meta.url), 'utf8');
  runInNewContext(`const API_BASE_URL = '/api';\n${source}`, {
    document: { querySelector: selector => selector === 'main' ? root : button },
    AbortSignal: { timeout(ms) {
      assert.equal(ms, 10000);
      const controller = new AbortController();
      controllers.push(controller);
      return controller.signal;
    } },
    fetch: (url, { signal }) => new Promise((resolve, reject) => {
      signal.addEventListener('abort', () => reject(signal.reason), { once: true });
    }),
  });
  assert.equal(button.disabled, true);
  assert.equal(controllers.length, 2);
  controllers.forEach(controller => controller.abort(new Error('request timed out')));
  await new Promise(resolve => setImmediate(resolve));
  assert.match(root.textContent, /API unavailable: request timed out/);
  assert.equal(button.disabled, false);
  const retry = click();
  assert.equal(button.disabled, true);
  assert.equal(controllers.length, 4);
  controllers.slice(2).forEach(controller => controller.abort(new Error('request timed out')));
  await retry;
  assert.equal(button.disabled, false);
});

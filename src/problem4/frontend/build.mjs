import { createHash } from 'node:crypto';
import { readFileSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

export function build(destination, release, apiBase = '/api') {
  if (!/^[a-f0-9]{40}$/.test(release)) throw new Error('Expected full lowercase commit SHA');
  if (apiBase !== '/api') {
    const url = new URL(apiBase);
    if (url.protocol !== 'https:' || url.username || url.password || url.search || url.hash ||
        !['', '/', '/api'].includes(url.pathname)) throw new Error('Expected HTTPS API origin or /api URL');
    apiBase = `${url.origin}/api`;
  }
  const source = `const API_BASE_URL = ${JSON.stringify(apiBase)};\n` +
    readFileSync(new URL('./app.js', import.meta.url), 'utf8');
  const name = `app-${createHash('sha256').update(source).digest('hex')}.js`;
  rmSync(destination, { recursive: true, force: true });
  mkdirSync(`${destination}/assets`, { recursive: true });
  writeFileSync(`${destination}/assets/${name}`, source);
  writeFileSync(`${destination}/index.html`, `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<meta name="release" content="${release}"><title>Problem 3 service</title></head>
<body><h1>Problem 3 service</h1><p>Live PostgreSQL and Redis API</p>
<button id="refresh">Refresh</button><main aria-live="polite"></main>
<script type="module" src="/assets/${name}"></script></body></html>\n`);
}
if (process.argv[1] === fileURLToPath(import.meta.url)) build('dist', process.env.RELEASE_SHA, process.env.API_BASE_URL || '/api');

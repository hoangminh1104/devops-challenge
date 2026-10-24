import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, readdirSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { createHash } from 'node:crypto';
import { build } from './build.mjs';

test('build is deterministic and HTML references content-addressed, existing assets', () => {
  const dir = mkdtempSync(`${tmpdir()}/spa-`);
  try {
    build(dir, 'b'.repeat(40));
    const html = readFileSync(`${dir}/index.html`, 'utf8');
    const [, name, digest] = html.match(/src="\/(assets\/app-([a-f0-9]{64})\.js)"/);
    assert.equal(createHash('sha256').update(readFileSync(`${dir}/${name}`)).digest('hex'), digest);
    assert.ok(html.includes('b'.repeat(40)));
    build(dir, 'b'.repeat(40));
    assert.equal(readFileSync(`${dir}/index.html`, 'utf8'), html);
    assert.throws(() => build(dir, '../bad'));
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('API build configuration changes the content hash and keeps the two-file archive shape', () => {
  const dir = mkdtempSync(`${tmpdir()}/spa-api-`);
  try {
    build(dir, 'b'.repeat(40));
    const local = readdirSync(`${dir}/assets`)[0];
    assert.match(readFileSync(`${dir}/assets/${local}`, 'utf8'), /const API_BASE_URL = "\/api"/);
    build(dir, 'b'.repeat(40), 'https://api.example.com');
    const production = readdirSync(`${dir}/assets`)[0];
    assert.notEqual(production, local);
    assert.match(readFileSync(`${dir}/assets/${production}`, 'utf8'), /https:\/\/api.example.com\/api/);
    assert.deepEqual(readdirSync(dir).sort(), ['assets', 'index.html']);
    for (const bad of ['http://api.example.com', 'https://api.example.com/?token=x', 'https://user:secret@api.example.com', 'https://api.example.com/other']) {
      assert.throws(() => build(dir, 'b'.repeat(40), bad));
    }
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

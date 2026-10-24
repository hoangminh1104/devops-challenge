import assert from 'node:assert/strict';

const [base, sha, mode = 'healthy'] = process.argv.slice(2);
const response = await fetch(`${base}/api/health`);
const health = await response.json();
assert.equal(health.release, sha);
if (mode === 'redis-down') {
  assert.equal(health.status, 'degraded');
  assert.equal(health.redis.ok, false);
} else if (mode === 'postgres-down') {
  assert.equal(response.status, 503);
  assert.equal(health.postgres.ok, false);
} else {
  assert.equal(response.status, 200);
  assert.equal(health.status, 'ok');
  assert.equal(health.postgres.ok, true);
  assert.equal(health.redis.ok, true);
  const users = await (await fetch(`${base}/api/users`)).json();
  assert.equal(users.ok, true);
  assert.ok(Date.parse(users.time.now));
  // nginx proxies only /api; direct API retains Problem 3's /status route.
  if (!process.env.PROXY_ONLY) {
    const statusResponse = await fetch(`${base}/status`);
    assert.equal(statusResponse.status, 200);
    assert.deepEqual(await statusResponse.json(), { status: 'ok', release: sha });
  }
  const allowed = await fetch(`${base}/api/health`, { headers: { Origin: 'https://app.example.test' } });
  assert.equal(allowed.headers.get('access-control-allow-origin'), 'https://app.example.test');
  const denied = await fetch(`${base}/api/health`, { headers: { Origin: 'https://other.example.test' } });
  assert.equal(denied.headers.get('access-control-allow-origin'), null);
}
console.log(`PASS: HTTP ${mode} at ${base}`);

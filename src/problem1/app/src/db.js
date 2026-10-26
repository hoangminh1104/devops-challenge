import pg from 'pg';
import { readFileSync } from 'node:fs';

export const pool = new pg.Pool({
  host: process.env.DB_HOST || '127.0.0.1',
  port: Number(process.env.DB_PORT || 5432),
  user: process.env.DB_USER || 'postgres',
  password: process.env.DB_PASSWORD || 'local-test-only',
  database: process.env.DB_NAME || 'trading',
  max: Number(process.env.DB_POOL_MAX || 12),
  connectionTimeoutMillis: 2000,
  statement_timeout: 2000,
  query_timeout: 3000,
  idleTimeoutMillis: 30000,
  application_name: `dom7hc-practice-${process.env.ROLE || 'app'}`,
  ssl: process.env.DB_SSL === 'true'
    ? { rejectUnauthorized: true, ca: readFileSync(new URL('../rds-ca.pem', import.meta.url)) }
    : false,
});

pool.on('error', err => console.error(JSON.stringify({ event: 'db_idle_error', code: err.code })));

export class HttpError extends Error {
  constructor(status, message) { super(message); this.status = status; }
}

export async function transaction(fn, timing) {
  const acquireStart = performance.now();
  const client = await pool.connect();
  if (timing) timing.acquire_ms = performance.now()-acquireStart;
  let broken = false;
  try {
    await client.query('BEGIN');
    await client.query("SET LOCAL lock_timeout = '1500ms'");
    const workStart = performance.now();
    const result = await fn(client);
    if (timing) timing.work_ms = performance.now()-workStart;
    const commitStart = performance.now();
    await client.query('COMMIT');
    if (timing) timing.commit_ms = performance.now()-commitStart;
    return result;
  } catch (err) {
    try { await client.query('ROLLBACK'); } catch { broken = true; }
    throw err;
  } finally { client.release(broken); }
}

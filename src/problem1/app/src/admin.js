import { readFileSync } from 'node:fs';
import { pool } from './db.js';
import { seedAccount, audit } from './trading.js';

try {
  const command = process.argv[2];
  if (command==='migrate') {
    const client=await pool.connect();
    try {
      await client.query('BEGIN');
      await client.query("SELECT pg_advisory_xact_lock(hashtext('dom7hc-practice:migration'))");
      await client.query(readFileSync(new URL('../sql/schema.sql',import.meta.url),'utf8'));
      await client.query('COMMIT');
    } catch(err) { await client.query('ROLLBACK'); throw err; } finally { client.release(); }
    console.log(JSON.stringify({ event:'migrated' }));
  } else if (command==='seed') {
    const ids=JSON.parse(process.env.SEED_ACCOUNTS || '[]');
    for (const id of ids) await seedAccount(id);
    console.log(JSON.stringify({ event:'seeded',accounts:ids.length }));
  } else if (command==='audit') console.log(JSON.stringify({ event:'audit',...await audit() }));
  else throw new Error('Expected migrate, seed, or audit');
} catch (err) {
  console.error(JSON.stringify({ event:'admin_failed',code:err.code,message:err.message }));
  process.exitCode=1;
} finally { await pool.end(); }

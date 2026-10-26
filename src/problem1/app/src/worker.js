import { writeFileSync } from 'node:fs';
import { setTimeout as sleep } from 'node:timers/promises';
import { pool } from './db.js';
import { processBatch, queueHealth } from './trading.js';

let stopping = false;
const heartbeat = () => writeFileSync('/tmp/worker-heartbeat', String(Date.now()));
heartbeat();
const timer = setInterval(heartbeat,5000);
timer.unref();
process.on('SIGTERM',()=>{ stopping=true; });
process.on('SIGINT',()=>{ stopping=true; });
let lastReport = 0;
const batchSize = Number(process.env.WORKER_BATCH_SIZE || 1);
if (!Number.isInteger(batchSize) || batchSize < 1 || batchSize > 32) throw new Error('Invalid WORKER_BATCH_SIZE');
let maxBatchMs = 0;
let completed = 0;
while (!stopping) {
  try {
    const started = performance.now();
    const count = await processBatch(batchSize);
    maxBatchMs = Math.max(maxBatchMs,performance.now()-started);
    completed += count;
    if (Date.now()-lastReport>30000) {
      lastReport=Date.now();
      try {
        console.log(JSON.stringify({event:'worker_progress',...await queueHealth(),batch_size:batchSize,max_batch_ms:Math.round(maxBatchMs),completed_since_report:completed}));
      } catch (err) {
        console.error(JSON.stringify({event:'worker_metrics_error',code:err.code || err.name}));
      }
      maxBatchMs=0;
      completed=0;
    }
    if (!count) await sleep(30);
  } catch (err) {
    console.error(JSON.stringify({ event:'worker_retry',code:err.code || err.name }));
    await sleep(500);
  }
}
clearInterval(timer);
await pool.end();

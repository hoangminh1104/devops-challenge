import {setTimeout as sleep} from 'node:timers/promises';
import {pool} from './db.js';
let stopping=false;
process.on('SIGTERM',()=>{stopping=true;});
while(!stopping) {
  try {
    const result=(await pool.query('SELECT p5.worker_process_one() AS result')).rows[0].result;
    if(result.processed) console.log(JSON.stringify({event:'cancellation_processed',id:result.id}));
    await sleep(result.processed?10:100);
  } catch(err) {console.error(JSON.stringify({event:'worker_retry',code:err.code}));await sleep(200);}
}
await pool.end();

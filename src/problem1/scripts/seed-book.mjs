// Reproducible, idempotent non-crossing liquidity for the final benchmark.
// Runs inside the private application image through an operator ECS task.
import {writeFileSync} from 'node:fs';
import {setTimeout as sleep} from 'node:timers/promises';
import {pool} from './src/db.js';
import {submit,queueHealth,book} from './src/trading.js';

const heartbeat=setInterval(()=>writeFileSync('/tmp/worker-heartbeat',String(Date.now())),5000);
let created=0,replayed=0;
try {
  const ids=JSON.parse(process.env.SEED_ACCOUNTS || '[]');
  if(ids.length<2) throw new Error('Two existing funded accounts are required');
  for(const side of ['BUY','SELL']) {
    const account=side==='BUY'?ids[0]:ids[1];
    for(let level=0;level<20;level++) {
      const price=String(60000+(side==='BUY'?-1:1)*(10+level));
      for(let index=0;index<10;index++) {
        const order=await submit(account,{market:'BTC-USDT',side,price,quantity:'0.01'},`liquidity-v1:${side}:${level}:${index}`);
        if(order.replayed) replayed++; else created++;
      }
    }
  }
  const deadline=Date.now()+120000;
  while((await queueHealth()).pending_commands>0) {
    if(Date.now()>deadline) throw new Error('Liquidity admission did not drain in 120 seconds');
    await sleep(500);
  }
  const snapshot=await book(100);
  console.log(JSON.stringify({event:'book_seeded',fixture_orders:400,created,replayed,fixture_levels_per_side:20,fixture_orders_per_level:10,bid_levels:snapshot.bids.length,ask_levels:snapshot.asks.length}));
} finally {
  clearInterval(heartbeat);
  await pool.end();
}

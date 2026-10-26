import { test, before, beforeEach, after } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import { pool } from '../src/db.js';
import { submit, cancel, getOrder, processBatch, seedAccount, audit, validateOrder, book } from '../src/trading.js';
import { app } from '../src/server.js';

let server, base;
const input = (side='BUY',price='60000',quantity='1') => ({market:'BTC-USDT',side,price,quantity});
const place = (account,side,price,quantity,key=randomUUID()) => submit(account,input(side,price,quantity),key);
const balance = async (id,asset) => (await pool.query('SELECT available,reserved FROM balances WHERE account_id=$1 AND asset=$2',[id,asset])).rows[0];
async function drain() {
  for (let n=0;n<100;n++) {
    if (!(await audit()).pending_commands) return;
    await processBatch(16);
  }
  throw new Error('Queue did not drain');
}
async function reconciles() {
  const a=await audit();
  assert.equal(a.negative_balances,0); assert.equal(a.unbalanced_events,0); assert.equal(a.unreconciled_balances,0);
}

before(async () => {
  assert.ok(['localhost','127.0.0.1',undefined].includes(process.env.DB_HOST),'Tests must use local PostgreSQL');
  assert.equal(process.env.DB_PORT,'55432','Tests require the dedicated local port');
  await pool.query(readFileSync(new URL('../sql/schema.sql',import.meta.url),'utf8'));
  server=app.listen(0,'127.0.0.1');
  await new Promise(resolve=>server.once('listening',resolve));
  base=`http://127.0.0.1:${server.address().port}`;
});
beforeEach(async () => {
  await pool.query('TRUNCATE ledger,trades,commands,orders,balances,accounts RESTART IDENTITY CASCADE');
  for (const id of ['alice','bob','carol']) await seedAccount(id);
});
after(async () => { await new Promise(resolve=>server.close(resolve)); await pool.end(); });

test('acceptance atomically reserves funds and concurrent retries create only one order',async()=>{
  const key=randomUUID();
  const orders=await Promise.all(Array.from({length:12},()=>submit('alice',input(),key)));
  assert.equal(new Set(orders.map(o=>o.id)).size,1);
  assert.equal((await audit()).pending_commands,1);
  assert.equal((await balance('alice','USDT')).reserved,'60000.0000000000000000');
  assert.equal(orders.filter(o=>!o.replayed).length,1);
  await assert.rejects(submit('alice',input('BUY','61000'),key),e=>e.status===409);
  await reconciles();
});

test('concurrent requests cannot overspend and rejected acceptance leaves no order or command',async()=>{
  const results=await Promise.allSettled([place('alice','BUY','100000','100'),place('alice','BUY','100000','100')]);
  assert.equal(results.filter(r=>r.status==='fulfilled').length,1);
  assert.equal(results.find(r=>r.status==='rejected').reason.status,422);
  assert.equal((await pool.query('SELECT count(*)::int n FROM orders')).rows[0].n,1);
  assert.equal((await balance('alice','USDT')).available,'0.0000000000000000');
  await reconciles();
});

test('matching settles at maker price and releases buyer price improvement',async()=>{
  const sell=await place('bob','SELL','60000','1'); await drain();
  const buy=await place('alice','BUY','61000','1'); await drain();
  assert.equal((await getOrder('alice',buy.id)).status,'FILLED');
  assert.equal((await getOrder('bob',sell.id)).status,'FILLED');
  assert.deepEqual(await balance('alice','USDT'),{available:'9940000.0000000000000000',reserved:'0.0000000000000000'});
  assert.equal((await balance('alice','BTC')).available,'101.0000000000000000');
  assert.equal((await balance('bob','BTC')).available,'99.0000000000000000');
  assert.equal((await audit()).trade_count,1);
  await reconciles();
});

test('best price wins, then engine admission sequence; partial residual stays reserved',async()=>{
  const older=await place('bob','SELL','60000','1'); await drain();
  const same=await place('carol','SELL','60000','1'); await drain();
  const best=await place('carol','SELL','59000','0.5'); await drain();
  await place('alice','BUY','61000','1.75'); await drain();
  const trades=(await pool.query('SELECT maker_order,quantity FROM trades ORDER BY id')).rows;
  assert.deepEqual(trades.map(t=>t.maker_order),[best.id,older.id,same.id]);
  assert.equal((await getOrder('carol',same.id)).remaining,'0.75000000');
  assert.equal((await balance('carol','BTC')).reserved,'0.7500000000000000');
  await reconciles();
});

test('pending cancellation and its retries release reservation once',async()=>{
  const order=await place('alice','BUY','100','1');
  await Promise.all([cancel('alice',order.id),cancel('alice',order.id)]);
  await drain();
  assert.equal((await getOrder('alice',order.id)).status,'CANCELLED');
  assert.equal((await cancel('alice',order.id)).cancellation_requested,false);
  assert.deepEqual(await balance('alice','USDT'),{available:'10000000.0000000000000000',reserved:'0.0000000000000000'});
  await reconciles();
});

test('self-trade prevention cancels the incoming remainder without changing resting maker',async()=>{
  const sell=await place('alice','SELL','60000','1'); await drain();
  const buy=await place('alice','BUY','60000','1'); await drain();
  assert.equal((await getOrder('alice',buy.id)).reason,'SELF_TRADE_PREVENTION');
  assert.equal((await getOrder('alice',sell.id)).status,'OPEN');
  assert.equal((await audit()).trade_count,0);
  await reconciles();
});

test('settlement failure rolls back fully and another worker can retry the durable command',async()=>{
  await place('bob','SELL','60000','1'); await drain();
  const buy=await place('alice','BUY','60000','1');
  await pool.query(`CREATE OR REPLACE FUNCTION test_fail_trade() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'injected crash'; END $$;
    CREATE TRIGGER test_fail_trade AFTER INSERT ON trades FOR EACH ROW EXECUTE FUNCTION test_fail_trade()`);
  try { await assert.rejects(processBatch(),/injected crash/); }
  finally { await pool.query('DROP TRIGGER test_fail_trade ON trades; DROP FUNCTION test_fail_trade()'); }
  assert.equal((await audit()).trade_count,0);
  assert.equal((await getOrder('alice',buy.id)).status,'PENDING');
  await reconciles();
  await Promise.all([processBatch(),processBatch()]); await drain();
  assert.equal((await audit()).trade_count,1);
  await reconciles();
});

test('two workers cannot duplicate fills, including a command spanning the fill batch limit',async()=>{
  for(let i=0;i<34;i++) await place('bob','SELL','60000','0.01');
  await drain();
  const order=await place('alice','BUY','60000','0.34');
  await Promise.all([processBatch(),processBatch()]); await drain();
  assert.equal((await getOrder('alice',order.id)).status,'FILLED');
  assert.equal((await audit()).trade_count,34);
  await reconciles();
});

test('fractional amounts settle exactly without floating-point loss',async()=>{
  await place('bob','SELL','60000','0.00000017'); await drain();
  await place('alice','BUY','61000','0.00000017'); await drain();
  assert.equal((await balance('alice','USDT')).available,'9999999.9898000000000000');
  await reconciles();
});

test('API denies cross-account order access, missing identity, invalid amounts and excessive depth',async()=>{
  const order=await place('alice','BUY','60000','1');
  let r=await fetch(`${base}/v1/orders/${order.id}`,{headers:{'x-user-sub':'bob'}}); assert.equal(r.status,404);
  r=await fetch(`${base}/v1/balances`); assert.equal(r.status,401);
  r=await fetch(`${base}/v1/markets/BTC-USDT/orderbook?depth=10000`); assert.equal(r.status,400);
  for(const bad of [input('BUY','1e5'),input('BUY','60000.001'),input('BUY','60000','0'),{...input(),price:60000}]) {
    assert.throws(()=>validateOrder(bad,randomUUID()),e=>e.status===400);
  }
  await assert.rejects(cancel('bob',order.id),e=>e.status===404);
  await drain(); assert.equal((await book()).bids.length,1);
});

test('history cursor preserves every order when timestamps tie',async()=>{
  for(let i=0;i<53;i++) await place('alice','BUY','1','1');
  await pool.query("UPDATE orders SET accepted_at='2026-10-22 12:00:00.123456+00'");
  const headers={'x-user-sub':'alice'};
  const first=await (await fetch(`${base}/v1/orders`,{headers})).json();
  const second=await (await fetch(`${base}/v1/orders?cursor=${first.next_cursor}`,{headers})).json();
  assert.equal(first.orders.length,50); assert.equal(second.orders.length,3);
  assert.equal(new Set([...first.orders,...second.orders].map(o=>o.id)).size,53);
  assert.equal((await fetch(`${base}/v1/orders?cursor=invalid`,{headers})).status,400);
  assert.equal((await fetch(`${base}/v1/orders/------------------------------------`,{headers})).status,404);
});

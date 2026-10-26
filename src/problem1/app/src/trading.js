import { randomUUID, createHash } from 'node:crypto';
import Decimal from 'decimal.js';
import { pool, transaction, HttpError } from './db.js';

Decimal.set({ precision: 50 });
const D = value => new Decimal(value);
const amount = value => D(value).toFixed(16);
const active = status => ['PENDING', 'OPEN', 'PARTIALLY_FILLED'].includes(status);
const orderColumns = 'id,market,side,price,quantity,remaining,status,reason,admission_seq,accepted_at,updated_at';
export const validId = id => typeof id === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id);

export function validateOrder(body, key) {
  if (!body || Object.keys(body).some(k => !['market','side','price','quantity'].includes(k)) ||
      body.market !== 'BTC-USDT' || !['BUY','SELL'].includes(body.side)) {
    throw new HttpError(400, 'Expected market BTC-USDT and side BUY or SELL');
  }
  for (const field of ['price','quantity']) {
    if (typeof body[field] !== 'string' || !/^\d{1,10}(\.\d{1,8})?$/.test(body[field]) || D(body[field]).lte(0)) {
      throw new HttpError(400, `${field} must be a positive decimal string with at most 8 decimal places`);
    }
  }
  if (D(body.price).gt('1000000000') || !D(body.price).mod('0.01').isZero() ||
      D(body.quantity).gt('100') || D(body.price).times(body.quantity).lt('0.01')) {
    throw new HttpError(400, 'Price tick 0.01, maximum price 1e9, maximum quantity 100, minimum notional 0.01');
  }
  if (typeof key !== 'string' || !/^[A-Za-z0-9._:-]{8,128}$/.test(key)) {
    throw new HttpError(400, 'Idempotency-Key must contain 8–128 letters, digits, or ._:-');
  }
  return { market: body.market, side: body.side, price: D(body.price).toFixed(8), quantity: D(body.quantity).toFixed(8) };
}

async function posting(c, event, account, asset, available, reserved, reason) {
  await c.query('INSERT INTO ledger(event_id,account_id,asset,available_delta,reserved_delta,reason) VALUES($1,$2,$3,$4,$5,$6)',
    [event, account, asset, amount(available), amount(reserved), reason]);
}

export async function submit(account, body, key) {
  const input = validateOrder(body, key);
  const hash = createHash('sha256').update(JSON.stringify(input)).digest('hex');
  const reserve = input.side === 'BUY' ? D(input.price).times(input.quantity) : D(input.quantity);
  const asset = input.side === 'BUY' ? 'USDT' : 'BTC';
  const timing = {};
  const started = performance.now();
  try {
    return await transaction(async c => {
    const exists = await c.query('SELECT 1 FROM accounts WHERE id=$1', [account]);
    if (!exists.rowCount) throw new HttpError(403, 'Account is not provisioned');
    const inserted = await c.query(`INSERT INTO orders(id,account_id,market,side,price,quantity,remaining,reserved_amount,status,idempotency_key,request_hash)
      VALUES($1,$2,$3,$4,$5,$6,$6,$7,'PENDING',$8,$9) ON CONFLICT(account_id,idempotency_key) DO NOTHING RETURNING ${orderColumns}`,
    [randomUUID(),account,input.market,input.side,input.price,input.quantity,amount(reserve),key,hash]);
    if (!inserted.rowCount) {
      const prior = (await c.query(`SELECT ${orderColumns},request_hash FROM orders WHERE account_id=$1 AND idempotency_key=$2`, [account,key])).rows[0];
      if (prior.request_hash !== hash) throw new HttpError(409, 'Idempotency key reused for different input');
      delete prior.request_hash;
      return { ...prior, replayed: true };
    }
    const reserveStart = performance.now();
    const reserved = await c.query('UPDATE balances SET available=available-$3,reserved=reserved+$3 WHERE account_id=$1 AND asset=$2 AND available >= $3 RETURNING asset', [account,asset,amount(reserve)]);
    timing.reserve_ms = performance.now()-reserveStart;
    if (!reserved.rowCount) throw new HttpError(422, 'Insufficient available funds');
    const order = inserted.rows[0];
    await posting(c, randomUUID(), account, asset, reserve.negated(), reserve, 'RESERVE');
    await c.query("INSERT INTO commands(order_id,kind) VALUES($1,'PLACE')", [order.id]);
    return { ...order, replayed: false };
    },timing);
  } finally {
    const elapsed = performance.now()-started;
    if (elapsed > 50) console.log(JSON.stringify({event:'slow_submit',elapsed_ms:Math.round(elapsed),...Object.fromEntries(Object.entries(timing).map(([key,value])=>[key,Math.round(value*100)/100]))}));
  }
}

export async function getOrder(account, id) {
  if (!validId(id)) throw new HttpError(404, 'Order not found');
  const order = (await pool.query(`SELECT ${orderColumns} FROM orders WHERE id=$1 AND account_id=$2`, [id,account])).rows[0];
  if (!order) throw new HttpError(404, 'Order not found');
  const fills = (await pool.query('SELECT id,price,quantity,executed_at FROM trades WHERE maker_order=$1 OR taker_order=$1 ORDER BY id DESC LIMIT 50',[id])).rows;
  return {...order,recent_fills:fills,fills_limit:50};
}

export async function cancel(account, id) {
  if (!validId(id)) throw new HttpError(404, 'Order not found');
  return transaction(async c => {
    const order = (await c.query('SELECT id,status FROM orders WHERE id=$1 AND account_id=$2 FOR UPDATE', [id,account])).rows[0];
    if (!order) throw new HttpError(404, 'Order not found');
    if (!active(order.status)) return { id, status: order.status, cancellation_requested: false };
    await c.query("INSERT INTO commands(order_id,kind) VALUES($1,'CANCEL') ON CONFLICT(order_id,kind) DO NOTHING", [id]);
    return { id, status: order.status, cancellation_requested: true };
  });
}

async function release(c, order, reason = 'USER_REQUEST') {
  if (!active(order.status)) return;
  const asset = order.side === 'BUY' ? 'USDT' : 'BTC';
  await c.query('UPDATE balances SET available=available+$3,reserved=reserved-$3 WHERE account_id=$1 AND asset=$2', [order.account_id,asset,order.reserved_amount]);
  await posting(c, randomUUID(), order.account_id, asset, order.reserved_amount, D(order.reserved_amount).negated(), 'RELEASE');
  await c.query("UPDATE orders SET reserved_amount=0,status='CANCELLED',reason=$2,updated_at=clock_timestamp() WHERE id=$1", [order.id,reason]);
}

async function settle(c, taker, maker) {
  const qty = Decimal.min(taker.remaining, maker.remaining);
  const price = D(maker.price);
  const buyer = taker.side === 'BUY' ? taker : maker;
  const seller = taker.side === 'SELL' ? taker : maker;
  const quote = qty.times(price);
  const buyReserved = qty.times(buyer.price);
  const event = randomUUID();
  const deltas = [
    [buyer.account_id, 'BTC', qty, D(0)],
    [buyer.account_id, 'USDT', buyReserved.minus(quote), buyReserved.negated()],
    [seller.account_id, 'BTC', D(0), qty.negated()],
    [seller.account_id, 'USDT', quote, D(0)],
  ].sort((a,b) => a[0].localeCompare(b[0]) || a[1].localeCompare(b[1]));
  // Stable lock ordering also covers future additional markets sharing balances.
  await c.query('SELECT account_id,asset FROM balances WHERE account_id=ANY($1::text[]) ORDER BY account_id,asset FOR UPDATE', [[buyer.account_id,seller.account_id]]);
  const values = [];
  const placeholders = deltas.map(([account,asset,av,res], i) => {
    values.push(account,asset,amount(av),amount(res));
    return `($${i*4+1}::text,$${i*4+2}::text,$${i*4+3}::numeric,$${i*4+4}::numeric)`;
  }).join(',');
  await c.query(`UPDATE balances b SET available=b.available+d.av,reserved=b.reserved+d.res
    FROM (VALUES ${placeholders}) AS d(account,asset,av,res) WHERE b.account_id=d.account AND b.asset=d.asset`, values);
  for (const [account,asset,av,res] of deltas) await posting(c,event,account,asset,av,res,'TRADE');
  await c.query('INSERT INTO trades(event_id,market,maker_order,taker_order,buyer_id,seller_id,price,quantity) VALUES($1,$2,$3,$4,$5,$6,$7,$8)',
    [event,'BTC-USDT',maker.id,taker.id,buyer.account_id,seller.account_id,price.toFixed(8),qty.toFixed(8)]);
  for (const order of [taker,maker]) {
    order.remaining = D(order.remaining).minus(qty).toFixed(8);
    order.reserved_amount = D(order.reserved_amount).minus(order.side === 'BUY' ? qty.times(order.price) : qty).toFixed(16);
    order.status = D(order.remaining).isZero() ? 'FILLED' : 'PARTIALLY_FILLED';
    await c.query('UPDATE orders SET remaining=$2,reserved_amount=$3,status=$4,updated_at=clock_timestamp() WHERE id=$1',
      [order.id,order.remaining,order.reserved_amount,order.status]);
  }
}

export async function processBatch(limit = 8) {
  return transaction(async c => {
    const locked = (await c.query("SELECT pg_try_advisory_xact_lock(hashtext('dom7hc-practice:BTC-USDT')) AS locked")).rows[0].locked;
    if (!locked) return 0;
    const commands = (await c.query('SELECT * FROM commands WHERE processed_at IS NULL ORDER BY id LIMIT $1 FOR UPDATE', [limit])).rows;
    let processed = 0;
    for (const command of commands) {
      const order = (await c.query('SELECT * FROM orders WHERE id=$1 FOR UPDATE', [command.order_id])).rows[0];
      let complete = true;
      if (command.kind === 'CANCEL') await release(c,order);
      else if (active(order.status)) {
        if (order.status === 'PENDING') {
          const admitted = (await c.query("UPDATE orders SET status='OPEN',admission_seq=nextval('book_sequence'),updated_at=clock_timestamp() WHERE id=$1 RETURNING admission_seq", [order.id])).rows[0];
          order.status = 'OPEN'; order.admission_seq = admitted.admission_seq;
        }
        for (let fill = 0; fill < 32 && active(order.status); fill++) {
          const buy = order.side === 'BUY';
          const maker = (await c.query(`SELECT * FROM orders WHERE market=$1 AND side=$2 AND status IN ('OPEN','PARTIALLY_FILLED')
            AND price ${buy ? '<=' : '>='} $3 AND id<>$4 ORDER BY price ${buy ? 'ASC' : 'DESC'},admission_seq LIMIT 1 FOR UPDATE`,
          [order.market,buy ? 'SELL' : 'BUY',order.price,order.id])).rows[0];
          if (!maker) break;
          if (maker.account_id === order.account_id) { await release(c,order,'SELF_TRADE_PREVENTION'); break; }
          await settle(c,order,maker);
          // Continue the same durable command before admitting later commands.
          if (fill === 31 && active(order.status)) complete = false;
        }
      }
      if (!complete) break;
      await c.query('UPDATE commands SET processed_at=clock_timestamp() WHERE id=$1', [command.id]);
      processed++;
    }
    return processed;
  });
}

export async function book(depth = 20) {
  const rows = (await pool.query(`(SELECT side,price,sum(remaining)::text AS quantity FROM orders
    WHERE market='BTC-USDT' AND side='BUY' AND status IN ('OPEN','PARTIALLY_FILLED') GROUP BY side,price ORDER BY price DESC LIMIT $1)
    UNION ALL (SELECT side,price,sum(remaining)::text AS quantity FROM orders
    WHERE market='BTC-USDT' AND side='SELL' AND status IN ('OPEN','PARTIALLY_FILLED') GROUP BY side,price ORDER BY price ASC LIMIT $1)`, [depth])).rows;
  return { market: 'BTC-USDT', bids: rows.filter(r=>r.side==='BUY').map(r=>[r.price,r.quantity]), asks: rows.filter(r=>r.side==='SELL').map(r=>[r.price,r.quantity]) };
}

export async function seedAccount(id) {
  return transaction(async c => {
    const added = await c.query('INSERT INTO accounts(id) VALUES($1) ON CONFLICT DO NOTHING RETURNING id', [id]);
    if (!added.rowCount) return false;
    for (const [asset,value] of [['BTC','100'],['USDT','10000000']]) {
      const event = randomUUID();
      await c.query('INSERT INTO balances(account_id,asset,available,reserved) VALUES($1,$2,$3,0)', [id,asset,value]);
      await posting(c,event,id,asset,value,0,'DEMO_FUNDING');
      await posting(c,event,'@demo-treasury',asset,D(value).negated(),0,'DEMO_FUNDING');
    }
    return true;
  });
}

export async function audit() {
  const start = performance.now();
  const result = await pool.query(`SELECT
    (SELECT count(*)::int FROM balances WHERE available<0 OR reserved<0) AS negative_balances,
    (SELECT count(*)::int FROM (SELECT event_id,asset FROM ledger GROUP BY event_id,asset HAVING sum(available_delta+reserved_delta)<>0) x) AS unbalanced_events,
    (SELECT count(*)::int FROM balances b LEFT JOIN (SELECT account_id,asset,sum(available_delta) a,sum(reserved_delta) r FROM ledger GROUP BY account_id,asset) l USING(account_id,asset)
      WHERE b.available IS DISTINCT FROM l.a OR b.reserved IS DISTINCT FROM l.r) AS unreconciled_balances,
    (SELECT count(*)::int FROM commands WHERE processed_at IS NULL) AS pending_commands,
    (SELECT coalesce(extract(epoch FROM clock_timestamp()-min(created_at)),0)::float FROM commands WHERE processed_at IS NULL) AS oldest_command_seconds,
    (SELECT count(*)::int FROM trades) AS trade_count`);
  return {...result.rows[0],duration_ms:Math.round(performance.now()-start)};
}

export async function queueHealth() {
  return (await pool.query(`SELECT count(*)::int AS pending_commands,
    coalesce(extract(epoch FROM clock_timestamp()-min(created_at)),0)::float AS oldest_command_seconds
    FROM commands WHERE processed_at IS NULL`)).rows[0];
}

import express from 'express';
import { pathToFileURL } from 'node:url';
import { pool, HttpError } from './db.js';
import { submit, cancel, getOrder, book, validId } from './trading.js';

export const app = express();
app.disable('x-powered-by');
app.use(express.json({ limit: '8kb', strict: true }));
app.use((req,res,next) => { res.set('Cache-Control','no-store'); next(); });
app.get('/health/live', (req,res) => res.json({ status:'ok' }));
app.get('/health/ready', async (req,res) => { await pool.query('SELECT 1'); res.json({ status:'ready' }); });
app.get('/v1/markets', (req,res) => res.json({ markets:[{ symbol:'BTC-USDT',price_tick:'0.01',quantity_step:'0.00000001',max_quantity:'100',min_notional:'0.01',fees:'0',funding:'simulated' }] }));
app.get('/v1/markets/:symbol/orderbook', async (req,res) => {
  if (req.params.symbol !== 'BTC-USDT') throw new HttpError(404,'Market not found');
  const depth = Number(req.query.depth ?? 20);
  if (!Number.isInteger(depth) || depth < 1 || depth > 100) throw new HttpError(400,'depth must be 1–100');
  res.json(await book(depth));
});
app.get('/v1/markets/:symbol/trades', async (req,res) => {
  if (req.params.symbol !== 'BTC-USDT') throw new HttpError(404,'Market not found');
  const rows = (await pool.query('SELECT id,price,quantity,executed_at FROM trades WHERE market=$1 ORDER BY id DESC LIMIT 50', [req.params.symbol])).rows;
  res.json({ market:req.params.symbol,trades:rows });
});
app.use('/v1', (req,res,next) => {
  // Only API Gateway's JWT-authorized integration can reach the service and
  // it overwrites this header. Direct local calls are for isolated tests only.
  const subject = req.get('x-user-sub');
  if (!subject || !/^[a-zA-Z0-9_-]{1,128}$/.test(subject) || subject === 'anonymous') throw new HttpError(401,'Authentication required');
  req.account = subject;
  next();
});
app.get('/v1/balances', async (req,res) => res.json({ balances:(await pool.query('SELECT asset,available,reserved FROM balances WHERE account_id=$1 ORDER BY asset', [req.account])).rows }));
app.post('/v1/orders', async (req,res) => res.status(202).json(await submit(req.account,req.body,req.get('Idempotency-Key'))));
app.get('/v1/orders', async (req,res) => {
  let cursor=null;
  if(req.query.cursor) {
    try {
      if(typeof req.query.cursor!=='string' || req.query.cursor.length>512) throw new Error();
      cursor=JSON.parse(Buffer.from(req.query.cursor,'base64url').toString('utf8'));
      if(typeof cursor.time!=='string' || Number.isNaN(Date.parse(cursor.time)) || !validId(cursor.id)) throw new Error();
    } catch { throw new HttpError(400,'Invalid pagination cursor'); }
  }
  const orders = (await pool.query(`SELECT id,market,side,price,quantity,remaining,status,accepted_at::text AS accepted_at FROM orders
    WHERE account_id=$1 AND ($2::timestamptz IS NULL OR (accepted_at,id)<($2::timestamptz,$3::uuid))
    ORDER BY orders.accepted_at DESC,orders.id DESC LIMIT 50`, [req.account,cursor?.time || null,cursor?.id || null])).rows;
  const last=orders.at(-1);
  res.json({ orders,next_cursor:orders.length===50 ? Buffer.from(JSON.stringify({time:last.accepted_at,id:last.id})).toString('base64url') : null });
});
app.get('/v1/orders/:id', async (req,res) => res.json(await getOrder(req.account,req.params.id)));
app.delete('/v1/orders/:id', async (req,res) => res.status(202).json(await cancel(req.account,req.params.id)));
app.use((req,res) => res.status(404).json({ error:'Not found' }));
app.use((err,req,res,next) => {
  const status = err.status || (err.type==='entity.parse.failed' ? 400 : 503);
  if (status>=500) console.error(JSON.stringify({ event:'request_failed',code:err.code || err.name,path:req.path }));
  res.status(status).json({ error:status>=500 ? 'Service temporarily unavailable; retry using the same idempotency key' : err.message });
});

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const server = app.listen(Number(process.env.PORT || 3000), '0.0.0.0', () => console.log(JSON.stringify({ event:'listening',port:3000 })));
  server.requestTimeout = 5000;
  server.headersTimeout = 66000;
  server.keepAliveTimeout = 65000;
  let stopping = false;
  const stop = () => {
    if (stopping) return; stopping = true;
    server.close(async () => { await pool.end(); process.exit(0); });
    setTimeout(()=>process.exit(1),25000).unref();
  };
  process.on('SIGTERM',stop); process.on('SIGINT',stop);
}

import express from 'express';
import {readFileSync} from 'node:fs';
import {importSPKI,jwtVerify} from 'jose';
import {pool} from './db.js';

const key=await importSPKI(readFileSync('/run/secrets/jwt_public','utf8'),'RS256');
const issuer='urn:dom7hc-practice-p5:issuer',audience='dom7hc-practice-p5';
const app=express();
app.disable('x-powered-by');
app.use(express.json({limit:'4kb',strict:true}));
app.use((req,res,next)=>{res.set('Cache-Control','no-store');next();});
app.get('/health',async(req,res)=>{await pool.query('SELECT 1');res.json({status:'ok',replica:process.env.REPLICA});});
app.use(async(req,res,next)=>{
  try {
    const authorization=req.get('authorization') || '';
    if(!authorization.startsWith('Bearer ')) throw new Error('Missing bearer token');
    const {payload}=await jwtVerify(authorization.slice(7),key,{algorithms:['RS256'],issuer,audience,requiredClaims:['sub','exp','iss','aud']});
    if(typeof payload.sub!=='string' || !/^[a-z][a-z0-9_-]{0,63}$/.test(payload.sub)) throw new Error('Invalid subject');
    req.subject=payload.sub;
    req.scopes=new Set(typeof payload.scope==='string'?payload.scope.split(' '):[]);
    next();
  } catch { res.status(401).json({error:'Valid access token required'}); }
});
const scope=name=>(req,res,next)=>req.scopes.has(name)?next():res.status(403).json({error:'Required operation scope is missing'});
const idCheck=(req,res,next)=>/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(req.params.id)?next():res.status(404).json({error:'Order not found'});
app.get('/v1/balances',scope('balances:read'),async(req,res)=>{
  res.json((await pool.query('SELECT p5.api_balance($1) AS result',[req.subject])).rows[0].result);
});
app.post('/v1/orders',scope('orders:write'),async(req,res)=>{
  const body=req.body;
  if(!body || Object.keys(body).length!==1 || typeof body.amount!=='string' || !/^(?:0|[1-9]\d{0,3})(?:\.\d{1,2})?$/.test(body.amount)) {
    return res.status(400).json({error:'Expected only amount, as a positive USDT decimal string with at most two decimals'});
  }
  const requestKey=req.get('Idempotency-Key');
  if(!requestKey || !/^[A-Za-z0-9._:-]{8,100}$/.test(requestKey)) return res.status(400).json({error:'Invalid Idempotency-Key'});
  const result=(await pool.query('SELECT p5.api_submit($1,$2,$3::numeric) AS result',[req.subject,requestKey,body.amount])).rows[0].result;
  res.status(202).json(result);
});
app.get('/v1/orders/:id',scope('orders:read'),idCheck,async(req,res)=>res.json((await pool.query('SELECT p5.api_order($1,$2::uuid) AS result',[req.subject,req.params.id])).rows[0].result));
app.delete('/v1/orders/:id',scope('orders:write'),idCheck,async(req,res)=>res.status(202).json((await pool.query('SELECT p5.api_cancel($1,$2::uuid) AS result',[req.subject,req.params.id])).rows[0].result));
app.use((req,res)=>res.status(404).json({error:'Not found'}));
app.use((err,req,res,next)=>{
  const codes={P4000:400,P4030:403,P4040:404,P4090:409,P4220:422,P4290:429,P5030:503};
  const status=codes[err.code] || err.status || 503;
  if(status===429 || status===503) res.set('Retry-After',status===429?'60':'1');
  console.error(JSON.stringify({event:'request_rejected',status,code:err.code || err.type || 'internal',replica:process.env.REPLICA}));
  res.status(status).json({error:status===503?'Admission closed or dependency unavailable; retry with the same key':(codes[err.code]?err.message:'Invalid request')});
});
const server=app.listen(3000,'0.0.0.0',()=>console.log(JSON.stringify({event:'ready',replica:process.env.REPLICA})));
server.keepAliveTimeout=65000;
server.headersTimeout=66000;
process.on('SIGTERM',()=>{server.close(async()=>{await pool.end();process.exit(0);});setTimeout(()=>process.exit(1),5000).unref();});

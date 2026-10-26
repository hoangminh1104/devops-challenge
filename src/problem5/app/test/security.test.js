import {test,before,beforeEach,after} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync,writeFileSync} from 'node:fs';
import {randomUUID,generateKeyPairSync,randomBytes} from 'node:crypto';
import {setTimeout as sleep} from 'node:timers/promises';
import {importPKCS8,SignJWT} from 'jose';
import pg from 'pg';

const fixture='dom7hc-practice-p5';
const issuer='urn:dom7hc-practice-p5:issuer',audience=fixture;
const endpoints=['http://api-a:3000','http://api-b:3000'];
const db=(user,secret)=>new pg.Pool({host:'db',database:'p5_security',user,
  password:readFileSync(`/run/secrets/${secret}`,'utf8').trim(),max:2,connectionTimeoutMillis:2000,query_timeout:4000});
const admin=db('postgres','admin_password'),api=db('p5_api','api_password'),worker=db('p5_worker','worker_password'),migrator=db('p5_migrator','migrator_password');
let signingKey;
const cases=[];
const scope='orders:write orders:read balances:read';
async function token(subject='alice',options={}) {
  const {key=signingKey,algorithm='RS256',...claims}=options;
  return new SignJWT({scope,...claims}).setProtectedHeader({alg:algorithm,typ:'JWT'})
    .setSubject(subject).setIssuer(claims.iss || issuer).setAudience(claims.aud || audience)
    .setExpirationTime(claims.exp ?? '5m').setIssuedAt().sign(key);
}
async function call(path,{jwt,method='GET',body,key,replica=0,headers={}}={}) {
  const response=await fetch(endpoints[replica]+path,{method,
    headers:{'Content-Type':'application/json',...(jwt?{Authorization:`Bearer ${jwt}`} : {}),...(key?{'Idempotency-Key':key}:{}),...headers},
    body:body===undefined?undefined:JSON.stringify(body),signal:AbortSignal.timeout(5000)});
  return {status:response.status,body:await response.json(),retryAfter:response.headers.get('retry-after')};
}
async function place(jwt,amount='25.00',replica=0,key=randomUUID()) {
  return call('/v1/orders',{jwt,method:'POST',body:{amount},replica,key});
}
async function reset() {
  // Only this new Compose database is reachable. Never use a P1 host/port.
  assert.equal(process.env.DB_HOST,'db');assert.equal(process.env.P5_TEST_DATABASE,'p5_security');
  const client=await admin.connect();
  try {
    await client.query('BEGIN');
    await client.query('SELECT pg_advisory_xact_lock(584005,1)');
    await client.query('TRUNCATE p5.ledger,p5.orders,p5.balances,p5.rate_buckets,p5.accounts RESTART IDENTITY CASCADE');
    await client.query('UPDATE p5.limits SET account_limit=4,window_seconds=60,capacity=20');
    await client.query("INSERT INTO p5.accounts VALUES('alice'),('bob'); INSERT INTO p5.balances VALUES('alice',10000,0),('bob',10000,0)");
    for(const subject of ['alice','bob']) {
      const event=randomUUID();
      await client.query(`INSERT INTO p5.ledger(event_id,account_id,available_delta,reserved_delta,reason)
        VALUES($1,$2,10000,0,'DEMO_FUNDING'),($1,'@treasury',-10000,0,'DEMO_FUNDING')`,[event,subject]);
    }
    await client.query('COMMIT');
  } catch(err) {await client.query('ROLLBACK');throw err;} finally {client.release();}
}
async function audit() {
  const result=(await admin.query(`SELECT
    (SELECT count(*)::int FROM p5.balances WHERE available<0 OR reserved<0) AS negative,
    (SELECT count(*)::int FROM (SELECT event_id FROM p5.ledger GROUP BY event_id HAVING sum(available_delta+reserved_delta)<>0) x) AS unbalanced,
    (SELECT count(*)::int FROM p5.balances b LEFT JOIN
      (SELECT account_id,sum(available_delta) a,sum(reserved_delta) r FROM p5.ledger GROUP BY account_id) l USING(account_id)
      WHERE b.available IS DISTINCT FROM l.a OR b.reserved IS DISTINCT FROM l.r) AS unreconciled`)).rows[0];
  assert.deepEqual(result,{negative:0,unbalanced:0,unreconciled:0});
  return result;
}
function securityCase(name,fn) {
  test(name,async()=>{
    const start=Date.now();
    try {await fn();await audit();cases.push({name,status:'passed',duration_ms:Date.now()-start});}
    catch(err) {cases.push({name,status:'failed',duration_ms:Date.now()-start,error:err.code || err.name});throw err;}
  });
}

before(async()=>{
  signingKey=await importPKCS8(readFileSync('/run/secrets/jwt_private','utf8'),'RS256');
  assert.equal((await admin.query('SELECT current_database() name')).rows[0].name,'p5_security');
});
beforeEach(reset);
after(async()=>{
  let finalAudit=null;
  try {finalAudit=await audit();} catch {process.exitCode=1;}
  const summary={exercise:5,project:fixture,executed_at:new Date().toISOString(),environment:'isolated Docker Compose; PostgreSQL 18; two API replicas',
    cases,total:cases.length,passed:cases.filter(c=>c.status==='passed').length,failed:cases.filter(c=>c.status==='failed').length,
    expected_cases:12,all_checks_passed:cases.length===12 && cases.every(c=>c.status==='passed') && finalAudit!==null,financial_reconciliation:finalAudit,
    scope:'Security lab only. No AWS changes and no Problem 1 runtime dependencies. This is not a penetration test or performance benchmark.'};
  try {writeFileSync('/evidence/security-results.json',JSON.stringify(summary,null,2)+'\n');}
  finally {await Promise.all([admin.end(),api.end(),worker.end(),migrator.end()]);}
});

securityCase('missing, malformed, expired, wrong-audience, wrong-issuer and forged tokens are rejected',async()=>{
  const other=generateKeyPairSync('rsa',{modulusLength:2048,privateKeyEncoding:{type:'pkcs8',format:'pem'},publicKeyEncoding:{type:'spki',format:'pem'}});
  const wrongKey=await importPKCS8(other.privateKey,'RS256');
  const unsigned=Buffer.from(JSON.stringify({alg:'none'})).toString('base64url')+'.'+Buffer.from(JSON.stringify({sub:'alice',iss:issuer,aud:audience,exp:9999999999})).toString('base64url')+'.';
  const missingExpiry=await new SignJWT({scope}).setProtectedHeader({alg:'RS256'}).setSubject('alice').setIssuer(issuer).setAudience(audience).sign(signingKey);
  const values=[undefined,'invalid',unsigned,missingExpiry,await token('alice',{algorithm:'HS256',key:randomBytes(32)}),await token('alice',{exp:1}),await token('alice',{aud:'another-api'}),await token('alice',{iss:'untrusted-issuer'}),await token('alice',{key:wrongKey})];
  for(const jwt of values) assert.equal((await call('/v1/balances',{jwt})).status,401);
});

securityCase('read-only scope can read balances but cannot create or cancel orders',async()=>{
  const jwt=await token('alice',{scope:'balances:read'});
  assert.equal((await call('/v1/balances',{jwt})).status,200);
  assert.equal((await place(jwt)).status,403);
  assert.equal((await call(`/v1/orders/${randomUUID()}`,{jwt,method:'DELETE'})).status,403);
});

securityCase('ownership and identity-header substitution cannot expose or cancel another account order',async()=>{
  const alice=await token(),bob=await token('bob');
  const order=await place(bob);assert.equal(order.status,202);
  assert.equal((await call(`/v1/orders/${order.body.id}`,{jwt:alice,headers:{'x-user-sub':'bob'}})).status,404);
  assert.equal((await call(`/v1/orders/${order.body.id}`,{jwt:alice,method:'DELETE'})).status,404);
  assert.equal((await call('/v1/orders',{jwt:alice,method:'POST',key:randomUUID(),body:{amount:'10',account_id:'bob'}})).status,400);
  assert.equal((await call(`/v1/orders/${order.body.id}`,{jwt:bob})).body.status,'PENDING');
});

securityCase('API identity cannot read base tables, perform DDL, rewrite ledger or assume an owner role',async()=>{
  assert.equal((await api.query('SELECT current_user AS role')).rows[0].role,'p5_api');
  for(const sql of ['SELECT * FROM p5.balances',"UPDATE p5.ledger SET available_delta=999",'DELETE FROM p5.ledger','DROP TABLE p5.orders',
    'CREATE TABLE p5.intrusion(id integer)','CREATE TABLE public.intrusion(id integer)','SET ROLE p5_owner','SET ROLE postgres']) {
    await assert.rejects(api.query(sql),err=>err.code==='42501');
  }
  const attrs=(await admin.query("SELECT rolsuper,rolcreatedb,rolcreaterole,rolbypassrls FROM pg_roles WHERE rolname='p5_api'")).rows[0];
  assert.deepEqual(attrs,{rolsuper:false,rolcreatedb:false,rolcreaterole:false,rolbypassrls:false});
});

securityCase('API and worker cannot invoke each other operations; migration has separate authority',async()=>{
  await assert.rejects(api.query('SELECT p5.worker_process_one()'),err=>err.code==='42501');
  await assert.rejects(worker.query("SELECT p5.api_submit('alice','worker-abuse',10)"),err=>err.code==='42501');
  await assert.rejects(worker.query('DELETE FROM p5.ledger'),err=>err.code==='42501');
  await migrator.query('CREATE TABLE p5.migration_probe(id integer)');
  await migrator.query('DROP TABLE p5.migration_probe');
  assert.equal((await worker.query('SELECT p5.worker_process_one() result')).rows[0].result.processed,false);
});

securityCase('concurrent idempotent submissions across replicas reserve and charge quota only once',async()=>{
  const jwt=await token(),key=randomUUID();
  const replies=await Promise.all(Array.from({length:12},(_,i)=>place(jwt,'25.00',i%2,key)));
  assert.ok(replies.every(r=>r.status===202));
  assert.equal(new Set(replies.map(r=>r.body.id)).size,1);
  const balance=(await call('/v1/balances',{jwt})).body;
  assert.equal(balance.available,'9975.00');assert.equal(balance.reserved,'25.00');
  assert.equal((await admin.query("SELECT accepted FROM p5.rate_buckets WHERE account_id='alice'")).rows[0].accepted,1);
  assert.equal((await place(jwt,'26.00',1,key)).status,409);
});

securityCase('simultaneous submissions cannot overspend and a rejected request creates no reservation',async()=>{
  const jwt=await token();
  await admin.query("UPDATE p5.balances SET available=100 WHERE account_id='alice'; UPDATE p5.ledger SET available_delta=100 WHERE account_id='alice' AND reason='DEMO_FUNDING'; UPDATE p5.ledger SET available_delta=-100 WHERE account_id='@treasury' AND event_id IN (SELECT event_id FROM p5.ledger WHERE account_id='alice')");
  const replies=await Promise.all([place(jwt,'75.00',0),place(jwt,'75.00',1)]);
  assert.deepEqual(replies.map(r=>r.status).sort(),[202,422]);
  const balance=(await call('/v1/balances',{jwt})).body;
  assert.equal(balance.available,'25.00');assert.equal(balance.reserved,'75.00');
  assert.equal((await admin.query('SELECT count(*)::int n FROM p5.orders')).rows[0].n,1);
});

securityCase('shared per-account quota survives replica switching and preserves other users and retries',async()=>{
  const alice=await token(),bob=await token('bob'),keys=[];
  for(let i=0;i<4;i++) {const key=randomUUID();keys.push(key);assert.equal((await place(alice,'10',i%2,key)).status,202);}
  const denied=await place(alice,'10',1);assert.equal(denied.status,429);assert.ok(Number(denied.retryAfter)>0);
  assert.equal((await place(bob,'10',1)).status,202);
  assert.equal((await place(alice,'10',1,keys[0])).status,202);
  assert.equal((await call('/v1/balances',{jwt:alice})).body.reserved,'40.00');
});

securityCase('concurrent admission stops at the configured shared capacity without reserving rejected funds',async()=>{
  await admin.query('UPDATE p5.limits SET capacity=3,account_limit=100');
  const auth=[await token(),await token('bob')];
  const replies=await Promise.all(Array.from({length:12},(_,i)=>place(auth[i%2],'10',i%2)));
  assert.equal(replies.filter(r=>r.status===202).length,3);
  assert.equal(replies.filter(r=>r.status===503).length,9);
  assert.ok(replies.filter(r=>r.status===503).every(r=>r.retryAfter==='1'));
  assert.equal((await admin.query('SELECT sum(reserved)::text n FROM p5.balances')).rows[0].n,'30.00');
});

securityCase('cancellation works during admission closure and the worker releases funds exactly once',async()=>{
  await admin.query('UPDATE p5.limits SET capacity=1');
  const jwt=await token(),key=randomUUID();
  const order=await place(jwt,'20',0,key);assert.equal(order.status,202);
  assert.equal((await place(jwt,'20',1)).status,503);
  assert.equal((await place(jwt,'20',1,key)).body.id,order.body.id);
  const replies=await Promise.all([0,1].map(replica=>call(`/v1/orders/${order.body.id}`,{jwt,method:'DELETE',replica})));
  assert.ok(replies.every(r=>r.status===202));
  let state;
  for(let i=0;i<30;i++) {state=await call(`/v1/orders/${order.body.id}`,{jwt});if(state.body.status==='CANCELLED') break;await sleep(100);}
  assert.equal(state.body.status,'CANCELLED');
  assert.equal((await call(`/v1/orders/${order.body.id}`,{jwt,method:'DELETE'})).status,202);
  assert.equal((await call('/v1/balances',{jwt})).body.available,'10000.00');
  assert.equal((await admin.query("SELECT count(*)::int n FROM p5.ledger WHERE reason='RELEASE'")).rows[0].n,1);
  assert.equal((await place(jwt,'20',1)).status,202);
});

securityCase('invalid amounts, SQL-shaped input and direct database validation bypass attempts fail closed',async()=>{
  const jwt=await token();
  for(const amount of ['0','-1','NaN','1e3','25.001',"1'; DROP TABLE p5.ledger; --",'1001',25]) {
    assert.equal((await place(jwt,amount)).status,400);
  }
  await assert.rejects(api.query("SELECT p5.api_submit('alice','direct-invalid',-10)"),err=>err.code==='P4000');
  await assert.rejects(api.query("SELECT p5.api_submit('alice','direct-invalid','NaN'::numeric)"),err=>err.code==='P4000');
  assert.equal((await admin.query('SELECT count(*)::int n FROM p5.orders')).rows[0].n,0);
});

securityCase('security-definer functions have a non-login owner, pinned path and no PUBLIC execution grant',async()=>{
  const rows=(await admin.query(`SELECT p.proname,p.prosecdef,p.proconfig,r.rolname,r.rolcanlogin
    FROM pg_proc p JOIN pg_namespace n ON p.pronamespace=n.oid JOIN pg_roles r ON p.proowner=r.oid WHERE n.nspname='p5'`)).rows;
  assert.equal(rows.length,5);
  for(const row of rows) {assert.equal(row.prosecdef,true);assert.equal(row.rolname,'p5_owner');assert.equal(row.rolcanlogin,false);assert.ok(row.proconfig.includes('search_path=pg_catalog, p5, pg_temp'));}
  const publicGrants=(await admin.query(`SELECT count(*)::int n FROM pg_proc p JOIN pg_namespace n ON p.pronamespace=n.oid,
    LATERAL aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a
    WHERE n.nspname='p5' AND a.grantee=0 AND a.privilege_type='EXECUTE'`)).rows[0].n;
  assert.equal(publicGrants,0);
});

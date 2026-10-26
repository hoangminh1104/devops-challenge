import pg from 'pg';
import {readFileSync} from 'node:fs';

export const pool=new pg.Pool({
  host:process.env.DB_HOST || 'db',database:'p5_security',user:process.env.DB_USER,
  password:readFileSync(process.env.DB_PASSWORD_FILE,'utf8').trim(),
  max:4,connectionTimeoutMillis:1000,statement_timeout:1500,query_timeout:2000,
  application_name:`dom7hc-practice-p5-${process.env.REPLICA || 'worker'}`,
});
pool.on('error',err=>console.error(JSON.stringify({event:'db_idle_error',code:err.code})));

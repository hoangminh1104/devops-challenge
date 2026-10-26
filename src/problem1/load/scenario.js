import http from 'k6/http';
import exec from 'k6/execution';
import { Trend, Rate, Counter } from 'k6/metrics';

const endToEnd = new Trend('end_to_end_ms', true);
const unexpected = new Rate('unexpected_status');
const accepted = new Counter('accepted_orders');
const mainRequests = new Counter('main_requests');
const auth = JSON.parse(__ENV.TOKENS);
const profile = __ENV.PROFILE || 'mixed';
const durationMatch = /^(\d+)(s|m|h)$/.exec(__ENV.DURATION || '180s');
if (!durationMatch) throw new Error('Invalid DURATION');
const measuredSeconds = Number(durationMatch[1])*({s:1,m:60,h:3600}[durationMatch[2]]);
export const options = {
  scenarios: {
    main: { executor:'constant-arrival-rate',rate:Number(__ENV.RATE || 500),timeUnit:'1s',duration:`${measuredSeconds+20}s`,preAllocatedVUs:Number(__ENV.PREALLOCATED_VUS || 500),maxVUs:Number(__ENV.PREALLOCATED_VUS || 500),exec:'exercise' },
  },
  thresholds: {
    'end_to_end_ms{phase:main}': ['p(99)<100'],
    'end_to_end_ms{phase:main,route:place}': ['p(99)<100'],
    'end_to_end_ms{phase:main,route:trades}': ['p(99)<100'],
    ...(profile==='write-heavy' ? {} : {
      'end_to_end_ms{phase:main,route:book}': ['p(99)<100'],
      'end_to_end_ms{phase:main,route:balances}': ['p(99)<100'],
      'end_to_end_ms{phase:main,route:history}': ['p(99)<100'],
    }),
    'unexpected_status{phase:main}': ['rate<0.001'],
    'dropped_iterations{scenario:main}': ['count==0'],
  },
  summaryTrendStats: ['avg','min','med','max','p(90)','p(95)','p(99)'],
};

export function exercise() {
  const phase = exec.instance.currentTestRunDuration < 20000 ? 'warmup' : 'main';
  const i = exec.scenario.iterationInTest;
  const user = auth[i % auth.length];
  const n = i % 100;
  let route, path, method='GET', data=null, expected=200;
  if ((profile==='write-heavy' && n<80) || (profile!=='write-heavy' && n>=80 && n<90)) {
    route='place'; path='/v1/orders'; method='POST'; expected=202;
    data=JSON.stringify({market:'BTC-USDT',side:i%2===0?'BUY':'SELL',price:'60000',quantity:'0.0001'});
  } else if(n<50) { route='book'; path='/v1/markets/BTC-USDT/orderbook'; }
  else if(n<70) { route='balances'; path='/v1/balances'; }
  else if(n<80) { route='history'; path='/v1/orders'; }
  else { route='trades'; path='/v1/markets/BTC-USDT/trades'; }
  const tags={phase,route};
  const headers={'Content-Type':'application/json','Authorization':`Bearer ${user.token}`};
  if(method==='POST') headers['Idempotency-Key']=`${__ENV.RUN_ID}:${phase}:${i}`;
  const started=Date.now();
  const response=http.request(method,__ENV.TARGET+path,data,{headers,tags,timeout:'5s'});
  endToEnd.add(Date.now()-started,tags);
  unexpected.add(response.status!==expected,tags);
  if(phase==='main') mainRequests.add(1);
  if(method==='POST' && response.status===202) accepted.add(1,tags);
}

export function handleSummary(data) {
  return { stdout:JSON.stringify({event:'load_summary',run_id:__ENV.RUN_ID,profile,offered_rps:Number(__ENV.RATE || 500),duration:__ENV.DURATION || '180s',warmup_seconds:20,warmup_rps:Number(__ENV.RATE || 500),region:'ap-southeast-1',api_url:__ENV.TARGET,metrics:data.metrics,state:data.state})+'\n' };
}

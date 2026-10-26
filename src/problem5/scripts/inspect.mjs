import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {writeFileSync,readFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {fileURLToPath} from 'node:url';
const root=fileURLToPath(new URL('../',import.meta.url));
const project='dom7hc-practice-p5';
const docker=args=>execFileSync('docker',args,{cwd:root,encoding:'utf8'});
const ids=docker(['compose','-p',project,'-f',`${root}/compose.yml`,'ps','-q','db','api-a','api-b','worker']).trim().split(/\s+/);
assert.equal(ids.length,4,'Expected only the four P5 services');
const containers=JSON.parse(docker(['inspect',...ids]));
const files=['src/api.js','src/db.js','src/worker.js','package.json','package-lock.json'];
const sourceHashes=Object.fromEntries(files.map(name=>[name,createHash('sha256').update(readFileSync(`${root}/app/${name}`)).digest('hex')]));
const results=[];
for(const item of containers) {
  assert.equal(item.Config.Labels['com.docker.compose.project'],project);
  const service=item.Config.Labels['com.docker.compose.service'];
  const mounts=item.Mounts.map(m=>m.Destination).filter(p=>p.startsWith('/run/secrets/')).sort();
  if(service==='db') {
    assert.equal(Object.keys(item.HostConfig.PortBindings || {}).length,0,'Database must have no host-published port');
    results.push({service,database_port_published:false});
  } else {
    const command="const fs=require('fs'),c=require('crypto');console.log(JSON.stringify(Object.fromEntries(['src/api.js','src/db.js','src/worker.js','package.json','package-lock.json'].map(n=>[n,c.createHash('sha256').update(fs.readFileSync('/app/'+n)).digest('hex')]))))";
    const inside=JSON.parse(docker(['compose','-p',project,'-f',`${root}/compose.yml`,'exec','-T',service,'node','-e',command]));
    assert.deepEqual(inside,sourceHashes,'Runtime source differs from current checkout; rebuild instead of using SkipBuild');
    assert.equal(item.Config.User,'node');
    assert.equal(item.HostConfig.ReadonlyRootfs,true);
    assert.ok(item.HostConfig.CapDrop.includes('ALL'));
    assert.ok(item.HostConfig.SecurityOpt.includes('no-new-privileges:true'));
    assert.ok(!item.Config.Env.some(value=>value.startsWith('DB_PASSWORD=')),'No plaintext DB password in container environment');
    assert.ok(item.Mounts.filter(m=>m.Destination.startsWith('/run/secrets/')).every(m=>m.RW===false));
    const api=service.startsWith('api-');
    assert.deepEqual(mounts,api?['/run/secrets/api_password','/run/secrets/jwt_public']:['/run/secrets/worker_password']);
    if(api) assert.ok(item.HostConfig.PortBindings['3000/tcp'].every(binding=>binding.HostIp==='127.0.0.1'));
    else assert.equal(Object.keys(item.HostConfig.PortBindings || {}).length,0);
    results.push({service,user:'node',read_only_root:true,capabilities_dropped:true,no_new_privileges:true,secret_mounts:mounts,secret_mounts_read_only:true,
      ...(api?{loopback_only:true}:{published_ports:[],network_scope:'backend-only'})});
  }
}
const network=JSON.parse(docker(['network','inspect',`${project}_backend`]))[0];
assert.equal(network.Internal,true);
const report={project,executed_at:new Date().toISOString(),backend_network_internal:true,runtime_source_matches:true,source_hashes:sourceHashes,services:results,passed:true};
writeFileSync(`${root}/evidence/runtime-controls.json`,JSON.stringify(report,null,2)+'\n');
console.log(JSON.stringify(report,null,2));

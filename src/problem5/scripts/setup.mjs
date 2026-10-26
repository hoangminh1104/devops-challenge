import {randomBytes,generateKeyPairSync} from 'node:crypto';
import {mkdirSync,existsSync,writeFileSync} from 'node:fs';
import {fileURLToPath} from 'node:url';

const root=fileURLToPath(new URL('../.local/',import.meta.url));
mkdirSync(root,{recursive:true,mode:0o700});
for(const name of ['admin','migrator','api','worker']) {
  const path=`${root}/${name}-password.txt`;
  // Individual files are mounted read-only into only the intended containers.
  // Directory permissions protect the host copy; Compose secrets are file mounts.
  if(!existsSync(path)) writeFileSync(path,randomBytes(32).toString('hex'),{mode:0o644,flag:'wx'});
}
if(!existsSync(`${root}/jwt-private.pem`)) {
  const keys=generateKeyPairSync('rsa',{modulusLength:2048,
    publicKeyEncoding:{type:'spki',format:'pem'},privateKeyEncoding:{type:'pkcs8',format:'pem'}});
  writeFileSync(`${root}/jwt-private.pem`,keys.privateKey,{mode:0o644,flag:'wx'});
  writeFileSync(`${root}/jwt-public.pem`,keys.publicKey,{mode:0o644,flag:'wx'});
}
console.log('Generated/preserved P5-only credentials and test signing keys in ignored .local/. No secrets printed.');

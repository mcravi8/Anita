import test from 'node:test';
import assert from 'node:assert/strict';
import {publicAddress,publicURL,PrivateBrowser} from '../browser.mjs';
import {mkdtemp,rm,symlink,writeFile,readFile,chmod} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {spawn} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {createServer} from 'node:http';
test('private, mapped IPv6 and ambiguous network destinations are rejected',async()=>{
  for(const ip of ['127.0.0.1','10.2.3.4','172.16.2.1','192.168.0.1','169.254.169.254','100.64.0.1','0.0.0.0','224.0.0.1','::1','fc00::1','::ffff:127.0.0.1','2001:db8::1'])assert.equal(publicAddress(ip),false,ip);
  assert.equal(publicAddress('192.0.43.8'),true);assert.equal(publicAddress('192.0.0.1'),false);assert.equal(publicAddress('8.8.8.8'),true);assert.equal(publicAddress('2606:4700:4700::1111'),true);
  for(const url of ['file:///etc/passwd','javascript:alert(1)','http://localhost','http://127.0.0.1','http://user:pass@example.com','http://2130706433'])await assert.rejects(publicURL(url));
  await assert.rejects(publicURL('https://example.com',async()=>[{address:'8.8.8.8'},{address:'127.0.0.1'}]));
});
test('private browser forms require fresh, single-use exact operations; passwords are blocked',async()=>{
  let submissions=0;
  const server=createServer((req,res)=>{if(req.url.startsWith('/submit'))submissions++;res.setHeader('Content-Type','text/html');res.end(req.url.startsWith('/submit')?'<h1>Fixture submitted</h1>':'<h1>Inert application</h1><form action="/submit"><label>Name<input name="name"></label><button>Submit fixture</button></form>');});
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  const origin=`http://127.0.0.1:${server.address().port}`,root=await mkdtemp(join(tmpdir(),'buddy-browser-test-')),b=new PrivateBrowser(join(root,'profile'),{testOrigin:origin});
  try{
    const page=await b.navigate(origin);const name=page.controls.find(c=>c.name==='Name');
    assert.equal(submissions,0);
    const prepared=await b.prepare({snapshotId:page.snapshotId,action:'fill',fields:[{ref:name.ref,value:'Fixture Person'}]});
    assert.equal(await b.page.locator('[name=name]').inputValue(),'');assert.equal(prepared.preview.arguments.targets[0].value,'Fixture Person');
    const result=await b.commit(prepared.token);assert.equal(await b.page.locator('[name=name]').inputValue(),'Fixture Person');
    await assert.rejects(b.commit(prepared.token));assert.equal(submissions,0);
    const submit=result.page.controls.find(c=>c.name==='Submit fixture');
    const stale=await b.prepare({snapshotId:result.page.snapshotId,action:'click',ref:submit.ref});
    await b.page.locator('[name=name]').fill('Changed outside approval');await assert.rejects(b.commit(stale.token));assert.equal(submissions,0);
    const fresh=await b.read(),p=await b.prepare({snapshotId:fresh.snapshotId,action:'click',ref:fresh.controls.find(c=>c.name==='Submit fixture').ref});
    await b.commit(p.token);assert.equal(submissions,1);await assert.rejects(b.navigate('http://127.0.0.2'));
  }finally{await b.close();await rm(root,{recursive:true,force:true});await new Promise(resolve=>server.close(resolve));}
});

test('authentication pages reveal no fields, values or text; only the approved saved-login broker can submit',async()=>{
 let submits=0;
 const server=createServer((req,res)=>{res.setHeader('Content-Type','text/html');if(req.method==='POST'){submits++;res.end('<h1>Signed in fixture</h1>');return;}res.end('<title>Private login</title><form method="post" action="/done"><label>Email<input type="email" value="fixture@example.com"></label><label>Password<input type="password" name="password" autocomplete="current-password" value="synthetic-secret-42"></label><button>Sign in</button></form>');});
 await new Promise(r=>server.listen(0,'127.0.0.1',r));const origin=`http://127.0.0.1:${server.address().port}`,root=await mkdtemp(join(tmpdir(),'buddy-auth-test-')),b=new PrivateBrowser(join(root,'profile'),{testOrigin:origin});
 try{let page=await b.navigate(origin+'/login');assert.equal(page.authentication.private,true);assert.deepEqual(page.controls,[]);assert.ok(!JSON.stringify(page).includes('synthetic-secret-42'));await assert.rejects(b.prepare({snapshotId:'x',action:'fill',fields:[{ref:'0',value:'secret'}]}));
  await b.page.locator('[name=password]').evaluate(e=>e.type='text');page=await b.read();assert.equal(page.authentication.private,true);assert.ok(!JSON.stringify(page).includes('synthetic-secret-42'));
  await b.page.locator('[name=password]').evaluate(e=>e.type='password');const plan=await b.prepareSignIn('signin');assert.equal(plan.accountEmail,'fixture@example.com');assert.equal(submits,0);const result=await b.useSaved(plan.token);assert.equal(result.performed,true);assert.equal(submits,1);await assert.rejects(b.useSaved(plan.token));assert.ok(!JSON.stringify(result).includes('synthetic-secret-42'));
 }finally{await b.close();await rm(root,{recursive:true,force:true});await new Promise(r=>server.close(r));}
});

test('email verification is origin-bound, fresh and single-use, with the code absent from the result',async()=>{
 let codes=[];
 const server=createServer(async(req,res)=>{res.setHeader('Content-Type','text/html');if(req.method==='POST'){let data='';for await(const chunk of req)data+=chunk;codes.push(new URLSearchParams(data).get('otp'));res.end('<h1>Verified 410239</h1>');return;}res.end('<h1>Verify your email</h1><p>Code sent to fixture@example.com</p><form method="post" action="/verified"><label>Verification code<input name="otp" autocomplete="one-time-code" maxlength="6"></label><button>Verify</button></form>');});
 await new Promise(r=>server.listen(0,'127.0.0.1',r));const origin=`http://127.0.0.1:${server.address().port}`,root=await mkdtemp(join(tmpdir(),'buddy-code-test-')),b=new PrivateBrowser(join(root,'profile'),{testOrigin:origin});
 try{const page=await b.navigate(origin);assert.equal(page.authentication.kind,'verification');const plan=await b.verificationPlan();assert.equal(plan.email,'fixture@example.com');await assert.rejects(b.verifyEmail('forged','410239'));assert.deepEqual(codes,[]);const fresh=await b.verificationPlan();const result=await b.verifyEmail(fresh.token,'410239');assert.equal(result.performed,true);assert.deepEqual(codes,['410239']);assert.ok(!JSON.stringify(result).includes('410239'));await assert.rejects(b.verifyEmail(fresh.token,'410239'));
 }finally{await b.close();await rm(root,{recursive:true,force:true});await new Promise(r=>server.close(r));}
});

test('JSONL browser bridge starts through a symlinked application path',async()=>{
 const root=await mkdtemp(join(tmpdir(),'buddy-browser-entry-'));const alias=join(root,'browser.mjs');
 try{
  await symlink(fileURLToPath(new URL('../browser.mjs',import.meta.url)),alias);
  const p=spawn(process.execPath,[alias,join(root,'profile')],{stdio:['pipe','pipe','pipe']});let output='',errors='';p.stdout.on('data',x=>output+=x);p.stderr.on('data',x=>errors+=x);p.stdin.end(JSON.stringify({id:1,command:'close'})+'\n');
  const code=await new Promise((resolve,reject)=>{p.on('error',reject);p.on('exit',resolve);});assert.equal(code,0,errors);assert.equal(JSON.parse(output).result.closed,true);
 }finally{await rm(root,{recursive:true,force:true});}
});

test('private handoff launches an ordinary separate profile with no agent/debugging connection',async()=>{
 const root=await mkdtemp(join(tmpdir(),'buddy-private-window-test-')),program=join(root,'fake-chrome');
 await writeFile(program,`#!${process.execPath}\nrequire('node:fs').writeFileSync(${JSON.stringify(join(root,'args.json'))},JSON.stringify(process.argv.slice(2)));setInterval(()=>{},1000);`);await chmod(program,0o700);
 const b=new PrivateBrowser(join(root,'profile'),{manualExecutable:program});
 try{assert.equal((await b.manual('google')).private,true);assert.equal(b.context,null);await assert.rejects(b.read(),/Private sign-in is open/);
  let args;for(let i=0;i<50;i++){try{args=JSON.parse(await readFile(join(root,'args.json'),'utf8'));break;}catch{await new Promise(r=>setTimeout(r,20));}}
  assert.ok(args.includes('chrome://settings/people'));assert.ok(args.some(x=>x===`--user-data-dir=${join(root,'profile')}`));assert.ok(!args.some(x=>/remote-debug|enable-automation|mock-keychain|password-store=basic/.test(x)));
  assert.equal((await b.finishManual()).closed,true);
 }finally{await b.close();await rm(root,{recursive:true,force:true});}
});

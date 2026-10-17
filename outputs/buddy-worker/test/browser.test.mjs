import test from 'node:test';
import assert from 'node:assert/strict';
import {publicAddress,publicURL,PrivateBrowser} from '../browser.mjs';
import {mkdtemp,rm,symlink} from 'node:fs/promises';
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
  const server=createServer((req,res)=>{if(req.url.startsWith('/submit'))submissions++;res.setHeader('Content-Type','text/html');res.end(req.url.startsWith('/submit')?'<h1>Fixture submitted</h1>':'<h1>Inert application</h1><form action="/submit"><label>Name<input name="name"></label><label>Password<input name="password" type="password"></label><button>Submit fixture</button></form>');});
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  const origin=`http://127.0.0.1:${server.address().port}`,root=await mkdtemp(join(tmpdir(),'buddy-browser-test-')),b=new PrivateBrowser(join(root,'profile'),{testOrigin:origin});
  try{
    const page=await b.navigate(origin);const name=page.controls.find(c=>c.name==='Name'),password=page.controls.find(c=>c.type==='password');
    assert.equal(submissions,0);await assert.rejects(b.prepare({snapshotId:page.snapshotId,action:'fill',fields:[{ref:password.ref,value:'never'}]}));
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

test('JSONL browser bridge starts through a symlinked application path',async()=>{
 const root=await mkdtemp(join(tmpdir(),'buddy-browser-entry-'));const alias=join(root,'browser.mjs');
 try{
  await symlink(fileURLToPath(new URL('../browser.mjs',import.meta.url)),alias);
  const p=spawn(process.execPath,[alias,join(root,'profile')],{stdio:['pipe','pipe','pipe']});let output='',errors='';p.stdout.on('data',x=>output+=x);p.stderr.on('data',x=>errors+=x);p.stdin.end(JSON.stringify({id:1,command:'close'})+'\n');
  const code=await new Promise((resolve,reject)=>{p.on('error',reject);p.on('exit',resolve);});assert.equal(code,0,errors);assert.equal(JSON.parse(output).result.closed,true);
 }finally{await rm(root,{recursive:true,force:true});}
});

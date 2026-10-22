import test from 'node:test';
import assert from 'node:assert/strict';
import {SharedBrowser} from '../browser.mjs';
import {mkdtemp,rm,readFile,readdir,writeFile,mkdir} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {createServer} from 'node:http';
import {createHash} from 'node:crypto';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';

// "Can't use the logins in Buddy's Chrome — that's the whole point." A file an agent needs from the web (a coding session's published PDF
// behind a CAPTCHA, a members-only dataset) is fetched by Buddy's own Chrome, in the task's own page, with the person's sign-ins: the file
// lands only where Buddy says, under the name the agent gave (never over another file), and the agent hears only what was saved. A CAPTCHA,
// a sign-in or an access check comes back as a challenge for the person, and once they have finished it the same fetch saves the file.
const run=promisify(execFile);
const PDF=Buffer.from('%PDF-1.7\n% fixture: the published article\n%%EOF\n');
const COOKIE='member-SECRET-cookie-4417',HEADER='header-SECRET-value-9921';
async function site(handler){
 const posts=[];
 const server=createServer(async(req,res)=>{let body='';for await(const chunk of req)body+=chunk;if(req.method!=='GET')posts.push(req.url);await handler(req,res,body);});
 await new Promise(r=>server.listen(0,'127.0.0.1',r));
 return {server,posts,origin:`http://127.0.0.1:${server.address().port}`,close:()=>new Promise(r=>server.close(r))};
}
const html=(res,text,status=200)=>{res.statusCode=status;res.setHeader('Content-Type','text/html');res.end(text);};
const signedIn=req=>(req.headers.cookie||'').includes('member='+COOKIE);
async function quarantine(path){
 if(process.platform!=='darwin')return 'not macOS';
 try{return (await run('/usr/bin/xattr',['-p','com.apple.quarantine',path])).stdout.trim();}catch{return '';}
}
async function files(dir){const out=[];async function walk(d,p){for(const e of await readdir(d,{withFileTypes:true}).catch(()=>[])){if(e.isDirectory())await walk(join(d,e.name),p+e.name+'/');else out.push(p+e.name);}}await walk(dir,'');return out.sort();}
async function fixture(name){const root=await mkdtemp(join(tmpdir(),name));const dir=join(root,'project');await mkdir(dir);return {root,dir,profile:join(root,'profile.noindex')};}

test('a fetch saves the file a site serves directly, only into the given folder, never over another file, with quarantine and a receipt that carries no cookie or header',{timeout:90000},async()=>{
 const s=await site((req,res)=>{
  if(req.url==='/login'){res.setHeader('Set-Cookie','member='+COOKIE+'; Path=/; Max-Age=3600');return html(res,'<h1>Signed in</h1>');}
  if(req.url==='/paper.pdf'){
   if(!signedIn(req))return html(res,'<title>Sign in</title><form method="post" action="/session"><input type="email" name="email"><input type="password" name="password"><button>Sign in</button></form>');
   res.setHeader('Set-Cookie','tracking='+COOKIE+'; Path=/');res.setHeader('X-Private-Token',HEADER);res.setHeader('Content-Type','application/pdf');return res.end(PDF);
  }
  res.statusCode=404;res.end('missing');
 });
 const {root,dir,profile}=await fixture('buddy-fetch-direct-');
 const browser=new SharedBrowser(profile,{testOrigin:s.origin});
 try{
  // The person signed in to the site in Buddy's Chrome (a page on the shared profile sets its cookie, as their window does).
  await browser.session('person').navigate(s.origin+'/login');
  const task=browser.session('task-a:fetch');
  const got=await task.fetch(s.origin+'/paper.pdf',{dir,saveAs:'sources/paper.pdf'});
  assert.equal(got.saved,true);assert.equal(got.path,'sources/paper.pdf');
  assert.deepEqual(await readFile(join(dir,'sources/paper.pdf')),PDF,'the file itself, with the person’s sign-in');
  assert.equal(got.bytes,PDF.length);assert.equal(got.sha256,createHash('sha256').update(PDF).digest('hex'));assert.equal(got.contentType,'application/pdf');
  assert.equal(got.url,s.origin+'/paper.pdf');assert.equal(new URL(got.finalURL).pathname,'/paper.pdf');
  const said=JSON.stringify(got);
  for(const secret of [COOKIE,HEADER,'set-cookie','Set-Cookie','x-private-token','cookie'])assert.ok(!said.includes(secret),`the receipt never carries ${secret}: ${said}`);
  assert.match(await quarantine(join(dir,'sources/paper.pdf')),/Buddy|not macOS/,'the file keeps macOS quarantine');
  // The same name again: a new file with a number, the first one untouched.
  await writeFile(join(dir,'sources/paper.pdf'),'the person’s own edit');
  const again=await task.fetch(s.origin+'/paper.pdf',{dir,saveAs:'sources/paper.pdf'});
  assert.equal(again.path,'sources/paper (2).pdf');
  assert.equal(await readFile(join(dir,'sources/paper.pdf'),'utf8'),'the person’s own edit','never over another file');
  assert.deepEqual(await readFile(join(dir,'sources/paper (2).pdf')),PDF);
  // Only a relative, visible path inside the folder; only an absolute folder Buddy chose.
  for(const saveAs of ['../escape.pdf','/tmp/absolute.pdf','.hidden.pdf','sources/.git/config','a\\b.pdf','sources//x.pdf','','x'.repeat(300)+'.pdf'])
   await assert.rejects(task.fetch(s.origin+'/paper.pdf',{dir,saveAs}),/saveAs|path|name/i,`refused: ${saveAs}`);
  await assert.rejects(task.fetch(s.origin+'/paper.pdf',{dir:'relative/dir',saveAs:'x.pdf'}),/folder/i);
  // Over the size limit: nothing is written.
  await assert.rejects(task.fetch(s.origin+'/paper.pdf',{dir,saveAs:'big.pdf',maxBytes:10}),/larger than/);
  // Only public web pages: no other scheme, no private address.
  await assert.rejects(task.fetch('file:///etc/passwd',{dir,saveAs:'passwd.txt'}),/public/i);
  await assert.rejects(task.fetch('http://127.0.0.2:9/secret.pdf',{dir,saveAs:'secret.pdf'}),/Local and private/);
  assert.deepEqual(await files(dir),['sources/paper (2).pdf','sources/paper.pdf'],'nothing else was written in the folder');
  assert.deepEqual((await files(root)).filter(f=>!f.startsWith('profile.noindex/')),['project/sources/paper (2).pdf','project/sources/paper.pdf'],'and nothing outside it');
 }finally{await browser.close();await rm(root,{recursive:true,force:true});await s.close();}
});

test('a download the page itself starts is saved; a download no fetch asked for is dropped, and a download over the limit is stopped',{timeout:90000},async()=>{
 const csv='date,close\n2026-10-20,5800\n';
 const s=await site((req,res)=>{
  if(req.url==='/report.csv'){res.setHeader('Content-Type','text/csv');res.setHeader('Content-Disposition','attachment; filename="report.csv"');return res.end(csv);}
  if(req.url==='/report')return html(res,'<title>Preparing your download</title><p>Your download starts in a moment.</p><script>setTimeout(()=>location.href="/report.csv",200)</script>');
  if(req.url==='/auto')return html(res,'<title>Auto</title><a id="d" href="/report.csv" download>get</a><script>setTimeout(()=>document.getElementById("d").click(),100)</script>');
  if(req.url==='/big.bin'){
   res.setHeader('Content-Type','application/octet-stream');res.setHeader('Content-Disposition','attachment; filename="big.bin"');
   let sent=0;const chunk=Buffer.alloc(256*1024,7);const pump=()=>{if(sent>=8*1024*1024||res.destroyed)return res.end();sent+=chunk.length;res.write(chunk);setTimeout(pump,5);};return pump();
  }
  res.statusCode=404;res.end('missing');
 });
 const {root,dir,profile}=await fixture('buddy-fetch-download-');
 const browser=new SharedBrowser(profile,{testOrigin:s.origin});
 try{
  const task=browser.session('task-b:fetch');
  const viaPage=await task.fetch(s.origin+'/report',{dir,saveAs:'report.csv'});
  assert.equal(viaPage.saved,true);assert.equal(viaPage.via,'download');assert.equal(await readFile(join(dir,'report.csv'),'utf8'),csv);
  const direct=await task.fetch(s.origin+'/report.csv',{dir,saveAs:'data/report.csv'});
  assert.equal(direct.saved,true);assert.equal(await readFile(join(dir,'data/report.csv'),'utf8'),csv);
  assert.match(await quarantine(join(dir,'data/report.csv')),/Buddy|not macOS/);
  // Another task's page starts a download nobody asked Buddy to fetch: it is dropped, and nothing of it is kept anywhere.
  const dropped=browser.droppedDownloads;
  await browser.session('reader').navigate(s.origin+'/auto');
  for(let i=0;i<60&&browser.droppedDownloads===dropped;i++)await new Promise(r=>setTimeout(r,50));
  assert.equal(browser.droppedDownloads,dropped+1,'the unrequested download was dropped');
  await new Promise(r=>setTimeout(r,300));
  assert.deepEqual(await files(browser.downloadsDir),[],'nothing of it is left in Chrome’s download folder');
  // A download over the limit is stopped and nothing is written.
  await assert.rejects(task.fetch(s.origin+'/big.bin',{dir,saveAs:'big.bin',maxBytes:1024*1024}),/larger than/);
  assert.deepEqual(await files(dir),['data/report.csv','report.csv']);
 }finally{await browser.close();await rm(root,{recursive:true,force:true});await s.close();}
});

test('a CAPTCHA, a sign-in form or an access check comes back as a challenge for the person; once they finish it, the same fetch saves the file',{timeout:90000},async()=>{
 const s=await site((req,res)=>{
  const solved=(req.headers.cookie||'').includes('human=yes');
  if(req.url==='/solve'){res.setHeader('Set-Cookie','human=yes; Path=/; Max-Age=3600');return html(res,'<h1>Thanks</h1>');}
  if(req.url==='/article/ac498c/pdf'){
   if(!solved)return html(res,`<title>Radware Captcha Page</title><h1>We want to make sure it is actually you</h1><iframe src="/recaptcha/api2/anchor?k=fixture"></iframe><p>Please complete the security check to access iopscience.</p>`,403);
   res.setHeader('Content-Type','application/pdf');return res.end(PDF);
  }
  if(req.url.startsWith('/recaptcha/'))return html(res,'<div>I’m not a robot</div>');
  if(req.url==='/members/data.csv')return html(res,'<title>Log in</title><form method="post" action="/members/session"><label>Email<input type="email" name="email"></label><label>Password<input type="password" name="password"></label><button>Log in</button></form>');
  if(req.url==='/denied.pdf')return html(res,'<title>Access Denied</title><h1>Access denied</h1><p>Your institution does not subscribe to this content.</p>',403);
  if(req.url==='/turnstile.pdf')return html(res,'<title>Just a moment...</title><div class="cf-turnstile" data-sitekey="fixture"></div><p>Verify you are human by completing the action below.</p>',503);
  if(req.url==='/about')return html(res,'<title>About the journal</title><h1>About</h1><p>Plain page.</p>');
  res.statusCode=404;res.end('missing');
 });
 const {root,dir,profile}=await fixture('buddy-fetch-challenge-');
 const browser=new SharedBrowser(profile,{testOrigin:s.origin});
 try{
  const task=browser.session('task-c:fetch');
  const blocked=await task.fetch(s.origin+'/article/ac498c/pdf',{dir,saveAs:'ac498c.pdf'});
  assert.equal(blocked.saved,false);assert.equal(blocked.challenge.kind,'captcha');assert.equal(blocked.challenge.url,s.origin+'/article/ac498c/pdf');
  assert.equal(blocked.challenge.origin,s.origin);assert.match(blocked.challenge.title,/Captcha/);
  assert.deepEqual(await files(dir),[],'nothing is saved from a challenge page');
  // The person finishes the check in Buddy's Chrome (here a page on the shared profile sets the site's cookie, as their window does).
  await browser.session('person').navigate(s.origin+'/solve');
  const saved=await task.fetch(s.origin+'/article/ac498c/pdf',{dir,saveAs:'ac498c.pdf'});
  assert.equal(saved.saved,true);assert.deepEqual(await readFile(join(dir,'ac498c.pdf')),PDF);
  // A sign-in form, an access-denied page and a "just a moment" check are challenges too, each of its own kind.
  assert.equal((await task.fetch(s.origin+'/members/data.csv',{dir,saveAs:'data.csv'})).challenge?.kind,'signin');
  assert.equal((await task.fetch(s.origin+'/denied.pdf',{dir,saveAs:'denied.pdf'})).challenge?.kind,'blocked');
  assert.equal((await task.fetch(s.origin+'/turnstile.pdf',{dir,saveAs:'t.pdf'})).challenge?.kind,'captcha');
  // An ordinary web page is not a file: refused, unless the agent asked to save the page itself (.html).
  await assert.rejects(task.fetch(s.origin+'/about',{dir,saveAs:'about.pdf'}),/web page/);
  const page=await task.fetch(s.origin+'/about',{dir,saveAs:'about.html'});
  assert.equal(page.saved,true);assert.match(await readFile(join(dir,'about.html'),'utf8'),/About the journal/);
  assert.deepEqual(await files(dir),['about.html','ac498c.pdf']);
 }finally{await browser.close();await rm(root,{recursive:true,force:true});await s.close();}
});

test('a fetch only opens the address: a page that submits a form is stopped before it posts anything, and a pinned task’s Google file opens as its account',{timeout:90000},async()=>{
 const USC='craviott@usc.edu';
 const s=await site((req,res)=>{
  if(req.url==='/autopost')return html(res,'<title>Continue</title><form id="f" method="post" action="/collect"><input name="x" value="1"></form><script>document.getElementById("f").submit()</script>');
  if(req.url.startsWith('/collect'))return html(res,'<h1>Posted</h1>');
  res.statusCode=404;res.end('missing');
 });
 const seen=[];
 const g=await site((req,res)=>{seen.push(req.url);const u=new URL(req.url,'http://x');if(u.pathname==='/drive/file.pdf'){res.setHeader('Content-Type','application/pdf');return res.end(PDF);}res.statusCode=404;res.end();});
 const {root,dir,profile}=await fixture('buddy-fetch-get-');
 const browser=new SharedBrowser(profile,{testOrigins:[s.origin,g.origin],testGoogle:[g.origin],testGooglePath:'/accounts/'});
 try{
  await assert.rejects(browser.session('task-d:fetch').fetch(s.origin+'/autopost',{dir,saveAs:'x.pdf'}),/submit|form/i);
  await new Promise(r=>setTimeout(r,300));
  assert.deepEqual(s.posts,[],'nothing was posted');
  const pinned=browser.session('task-usc:fetch','',USC);
  const got=await pinned.fetch(g.origin+'/drive/file.pdf',{dir,saveAs:'file.pdf'});
  assert.equal(got.saved,true);
  assert.ok(seen.some(u=>u.includes('authuser=craviott%40usc.edu')),'the address named the task’s account: '+seen);
  // An unpinned fetch may name an account for the file: it opens as that one.
  seen.length=0;
  await browser.session('task-e:fetch','','').fetch(g.origin+'/drive/file.pdf',{dir,saveAs:'file.pdf',account:USC});
  assert.ok(seen.some(u=>u.includes('authuser=craviott%40usc.edu')),'the named account: '+seen);
  // A pinned task never fetches as another account.
  await assert.rejects(pinned.fetch(g.origin+'/drive/file.pdf',{dir,saveAs:'file.pdf',account:'me.personal@gmail.com'}),/craviott@usc\.edu/);
 }finally{await browser.close();await rm(root,{recursive:true,force:true});await s.close();await g.close();}
});

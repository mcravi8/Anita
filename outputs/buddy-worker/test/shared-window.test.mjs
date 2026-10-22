import test from 'node:test';
import assert from 'node:assert/strict';
import {SharedBrowser} from '../browser.mjs';
import {mkdtemp,rm,writeFile,readFile,chmod} from 'node:fs/promises';
import {existsSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import {createServer} from 'node:http';

// "While my Chrome window is open, every agent's browsing waits." One Chrome profile is one Chrome process, and the person's window is plain
// Chrome with no agent connection (Google refuses sign-in in a browser an agent drives), so the agents can't share that process. While the
// window is open, the other tasks browse in a copy of the profile made the moment it opened: the sign-ins they had, in a separate Chrome
// that never sees the person's window. Only the task the window is for waits. Done closes the copy and everyone is back on the one profile.
async function site(handler){
 const server=createServer((req,res)=>{res.setHeader('Content-Type','text/html');handler(req,res);});
 await new Promise(r=>server.listen(0,'127.0.0.1',r));
 return {server,origin:`http://127.0.0.1:${server.address().port}`,close:()=>new Promise(r=>server.close(r))};
}
// Like Chrome, a start while one is already running on the profile hands its pages to that one and exits.
async function fakeChrome(root){
 const program=join(root,'fake-chrome'),log=join(root,'launches.jsonl'),running=join(root,'running');
 await writeFile(program,`#!${process.execPath}\nconst fs=require('node:fs');fs.appendFileSync(${JSON.stringify(log)},JSON.stringify(process.argv.slice(2))+'\\n');\nif(fs.existsSync(${JSON.stringify(running)}))process.exit(0);\nfs.writeFileSync(${JSON.stringify(running)},'');process.on('SIGTERM',()=>{fs.rmSync(${JSON.stringify(running)},{force:true});process.exit(0);});setInterval(()=>{},1000);`);await chmod(program,0o700);
 const launches=async(n=1)=>{for(let i=0;i<100;i++){try{const all=(await readFile(log,'utf8')).trim().split('\n').filter(Boolean).map(l=>JSON.parse(l));if(all.length>=n)return all;}catch{}await new Promise(r=>setTimeout(r,20));}return [];};
 return {program,launches};
}

test('while the person’s Chrome window is open for one task, the other tasks keep browsing with the sign-ins they had; that task waits; Done brings everyone back to the one profile',{timeout:90000},async()=>{
 const a=await site((req,res)=>{
  if(req.url==='/sign')return res.writeHead(200,{'Set-Cookie':'account=fixture; Path=/; Max-Age=3600','Content-Type':'text/html'}),res.end('<h1>Signed in once</h1>');
  if(req.url==='/meanwhile')return res.writeHead(200,{'Set-Cookie':'meanwhile=yes; Path=/; Max-Age=3600','Content-Type':'text/html'}),res.end('<h1>Set meanwhile</h1>');
  if(req.url==='/whoami')return res.end(`<h1>${/account=fixture/.test(req.headers.cookie||'')?'Signed in as fixture':'Signed out'}${/meanwhile=yes/.test(req.headers.cookie||'')?' (meanwhile)':''}</h1>`);
  res.end('<h1>Article</h1>');
 });
 const root=await mkdtemp(join(tmpdir(),'buddy-shared-window-')),chrome=await fakeChrome(root),profile=join(root,'profile.noindex');
 const browser=new SharedBrowser(profile,{testOrigins:[a.origin],manualExecutable:chrome.program});
 try{
  await browser.session('task-one').navigate(a.origin+'/sign');
  await browser.closeSession('task-one');
  assert.equal(browser.context,null);
  // The person's window opens for task-one's step, on the one profile.
  await browser.manual(undefined,{session:'task-one',page:a.origin+'/article'});
  const [first]=await chrome.launches(1);
  assert.ok(first.includes(`--user-data-dir=${resolve(profile)}`),'the person’s window is on the shared profile: '+first);
  // Another task keeps browsing, with the sign-in it had, in a Chrome that is not on the person's profile.
  const two=browser.session('task-two');
  assert.match((await two.navigate(a.origin+'/whoami')).text,/Signed in as fixture/);
  assert.ok(browser.contextProfile&&browser.contextProfile!==resolve(profile),'the agents’ Chrome runs on a copy: '+browser.contextProfile);
  assert.ok(existsSync(browser.contextProfile));
  // The window's own task waits for the person, its fetches too.
  await assert.rejects(browser.session('task-one').navigate(a.origin+'/whoami'),/Private sign-in is open/);
  await assert.rejects(browser.session('task-one:fetch').navigate(a.origin+'/whoami'),/Private sign-in is open/);
  // What an agent's page sets in the copy meanwhile stays in the copy.
  await two.navigate(a.origin+'/meanwhile');
  const copy=browser.contextProfile;
  // Done: the person's window closes, the copy is closed and removed, and the agents are back on the one profile.
  await browser.finishManual();
  assert.equal(existsSync(copy),false,'the copy is removed');
  const back=await two.navigate(a.origin+'/whoami');
  assert.match(back.text,/Signed in as fixture/);assert.doesNotMatch(back.text,/meanwhile/);
  assert.equal(browser.contextProfile,resolve(profile));
  // The setup window (no task): every task keeps browsing.
  await browser.closeSession('task-two');
  await browser.manual('google');
  assert.match((await browser.session('task-three').navigate(a.origin+'/whoami')).text,/Signed in as fixture/);
  await browser.finishManual();
 }finally{await browser.close();await rm(root,{recursive:true,force:true});await a.close();}
});

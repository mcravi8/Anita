import test from 'node:test';
import assert from 'node:assert/strict';
import {SharedBrowser} from '../browser.mjs';
import {mkdtemp,rm,writeFile,readFile,chmod} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {createServer} from 'node:http';

// A step an agent asks the person to do on a web page opens exactly that page in the person's Chrome window, in front, in the task's
// account; never a blank page or whatever Chrome had open before. Chrome is a stand-in program that records each time it is started.
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
// What Chrome is asked to open: the arguments that are not switches.
const pages=args=>args.filter(a=>!a.startsWith('--'));

test('a step opens exactly its page as the only page of a new Chrome window, and a Google page in the task’s account',{timeout:45000},async()=>{
 const a=await site((req,res)=>res.end('<h1>Article</h1>')),g=await site((req,res)=>res.end('<h1>Mail</h1>'));
 const root=await mkdtemp(join(tmpdir(),'buddy-web-step-')),chrome=await fakeChrome(root);
 const browser=new SharedBrowser(join(root,'profile.noindex'),{testOrigins:[a.origin,g.origin],testGoogle:[g.origin],manualExecutable:chrome.program});
 try{
  // A coding task's step: no page of its own in the shared browser, only the page it named.
  assert.equal((await browser.manual(undefined,{session:'coding-task',page:a.origin+'/article/10.1088/ac498c'})).private,true);
  const [first]=await chrome.launches(1);
  assert.deepEqual(pages(first),[a.origin+'/article/10.1088/ac498c'],'the step’s page is the one page Chrome is asked to open');
  assert.ok(first.includes('--new-window'),'in a new window, in front');
  assert.ok(first.includes(`--user-data-dir=${join(root,'profile.noindex')}`),'on the shared profile');
  assert.ok(!first.some(x=>/about:blank|remote-debug|enable-automation/.test(x)),'never a blank page, never an agent connection');
  // Pressed again while the window is open: the same page is shown again in that Chrome (a second start hands it to the running one).
  await browser.manual(undefined,{session:'coding-task',page:a.origin+'/article/10.1088/ac498c'});
  const twice=await chrome.launches(2);
  assert.equal(twice.length,2);assert.deepEqual(pages(twice[1]),[a.origin+'/article/10.1088/ac498c']);assert.ok(twice[1].includes('--new-window'));
  assert.equal(browser.manualOpen(),true,'the person’s window is still the one Buddy opened');
  await browser.finishManual();
  // A Google page for a task that must use an account: the address names it, so Google doesn't open the default account instead.
  await browser.manual(undefined,{session:'mail-task',page:g.origin+'/mail/u/0/#inbox',account:'Craviott@USC.edu'});
  const third=(await chrome.launches(3))[2];
  const opened=new URL(pages(third)[0]);
  assert.equal(opened.searchParams.get('authuser'),'craviott@usc.edu',`the account is in the address: ${opened.href}`);
  assert.equal(opened.pathname,'/mail/','an account given by number is replaced by the task’s');
  await browser.finishManual();
  // Another site with an account: opened as it is (the account is the person's to choose there).
  await browser.manual(undefined,{session:'site-task',page:a.origin+'/login',account:'craviott@usc.edu'});
  assert.deepEqual(pages((await chrome.launches(4))[3]),[a.origin+'/login']);
  await browser.finishManual();
 }finally{await browser.close();await rm(root,{recursive:true,force:true});await a.close();await g.close();}
});

test('a step without a page, or with a page that is not public, opens nothing; the Browser sign-in setup still opens Chrome’s account settings',{timeout:45000},async()=>{
 const root=await mkdtemp(join(tmpdir(),'buddy-web-step-none-')),chrome=await fakeChrome(root);
 const browser=new SharedBrowser(join(root,'profile.noindex'),{manualExecutable:chrome.program});
 try{
  await assert.rejects(browser.manual(undefined,{session:'coding-task'}),/doesn’t know which page/,'no page: nothing is opened, not even a blank one');
  await assert.rejects(browser.manual(undefined,{session:'coding-task',page:'http://127.0.0.2/admin'}),/private network|public/);
  await assert.rejects(browser.manual(undefined,{session:'coding-task',page:'file:///etc/passwd'}),/public/);
  assert.equal((await chrome.launches(1)).length,0,'Chrome was never started');
  assert.equal(browser.manualOpen(),false);
  await browser.manual('google');
  assert.deepEqual(pages((await chrome.launches(1))[0]),['chrome://settings/people'],'Open Chrome on the setup page is as before');
  await browser.finishManual();
 }finally{await browser.close();await rm(root,{recursive:true,force:true});}
});

test('Done looks at the step’s own page again in the task’s session',{timeout:60000},async()=>{
 let solved=false;
 const a=await site((req,res)=>res.end(solved?'<h1>Article text</h1>':'<title>Check</title><form method="post" action="/check"><label>Password<input type="password" name="password"></label><button>Continue</button></form>'));
 const root=await mkdtemp(join(tmpdir(),'buddy-web-step-done-'));
 const browser=new SharedBrowser(join(root,'profile.noindex'),{testOrigins:[a.origin]});
 try{
  const s=browser.session('task-one');
  // The agent named the page but never opened it in its own session.
  assert.equal((await s.recheck({reload:true,url:a.origin+'/article/1'})).signedIn,false,'still asks for something: Done says so');
  solved=true;
  const done=await s.recheck({reload:true,url:a.origin+'/article/1'});
  assert.equal(done.signedIn,true);assert.match(done.page.text,/Article text/,'the step’s page, opened in the task’s own session');
  assert.equal(new URL(s.page.url()).pathname,'/article/1');
 }finally{await browser.close();await rm(root,{recursive:true,force:true});await a.close();}
});

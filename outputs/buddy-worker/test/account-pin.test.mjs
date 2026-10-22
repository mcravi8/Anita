import test from 'node:test';
import assert from 'node:assert/strict';
import {SharedBrowser} from '../browser.mjs';
import {mkdtemp,rm,mkdir} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {createServer} from 'node:http';

// A task that the person told to use one Google account uses that account, and only that one, in the one shared Chrome where several
// Google accounts are signed in. Buddy enforces it in the browser: the model's words never decide which account a page acts as.
const PERSONAL='me.personal@gmail.com',USC='craviott@usc.edu';
async function site(handler){
 const server=createServer(async(req,res)=>{let body='';for await(const chunk of req)body+=chunk;res.setHeader('Content-Type','text/html');await handler(req,res,body);});
 await new Promise(r=>server.listen(0,'127.0.0.1',r));
 return {server,origin:`http://127.0.0.1:${server.address().port}`,close:()=>new Promise(r=>server.close(r))};
}
// A stand-in for Google on a local origin. `accounts` are the Google accounts signed in to the shared Chrome, the first being the default
// (/u/0): a page opens as the account its address names (authuser, by email or number, or a /u/N/ path) and otherwise as the default, and it
// shows that account the way Google's own account button does, in its accessible label. /fallback ignores the address (as Google does for an
// account that is not signed in), /plain shows no account, and /accounts/chooser is the account chooser. `sent` records what a page's Send
// button did, as which account.
async function google(){
 const fixture={accounts:[PERSONAL,USC],seen:[],sent:[]};
 const s=await site((req,res)=>{
  const url=new URL(req.url,'http://fixture');fixture.seen.push(req.url);
  if(url.pathname==='/sent'){fixture.sent.push(url.searchParams.get('as'));return res.end('ok');}
  if(url.pathname.startsWith('/accounts/chooser')){
   const next=url.searchParams.get('continue')||'/mail/',join=next.includes('?')?'&':'?';
   return res.end(`<title>Choose an account</title><h1>Choose an account</h1>${fixture.accounts.map(a=>`<div role="link" tabindex="0" data-identifier="${a}" onclick="location.href='${next}${join}authuser=${encodeURIComponent(a)}'">${a}</div>`).join('')}`);
  }
  if(url.pathname.startsWith('/plain'))return res.end('<title>Help</title><h1>Help centre</h1><button type="button" onclick="fetch(\'/sent?as=unknown\')">Send</button>');
  const asked=url.searchParams.get('authuser'),path=url.pathname.match(/\/u\/(\d+)(?:\/|$)/);
  let who=fixture.accounts[0];
  if(!url.pathname.startsWith('/fallback')){
   if(path)who=fixture.accounts[Number(path[1])]||who;
   else if(asked&&asked.includes('@'))who=fixture.accounts.find(a=>a===asked.toLowerCase())||who;
   else if(asked&&/^\d+$/.test(asked))who=fixture.accounts[Number(asked)]||who;
  }
  res.end(`<title>Inbox</title><a href="/accounts/SignOutOptions" aria-label="Google Account: Fixture Person&#10;(${who})">Account</a><h1>Mail for ${who}</h1><a href="/mail/next">Next page</a><button type="button" onclick="fetch('/sent?as=${encodeURIComponent(who)}')">Send</button>`);
 });
 return Object.assign(fixture,s);
}
async function fixtureRoot(name){const root=await mkdtemp(join(tmpdir(),name));const profile=join(root,'fixture.noindex','profile');await mkdir(profile,{recursive:true});return {root,profile};}
const click=async(session,name)=>{const read=await session.read();const control=read.controls.find(c=>c.name===name);assert.ok(control,`a ${name} control on ${read.url}`);const prepared=await session.prepare({snapshotId:read.snapshotId,action:'click',ref:control.ref});return session.commit(prepared.token);};
const settle=()=>new Promise(r=>setTimeout(r,300));

test('a pinned task opens every Google page as its account: the address carries authuser, also for a page named by number and a link the agent follows',{timeout:60000},async()=>{
 const g=await google(),{root,profile}=await fixtureRoot('buddy-account-pin-');
 const browser=new SharedBrowser(profile,{testOrigins:[g.origin],testGoogle:[g.origin],testGooglePath:'/accounts/'});
 try{
  const usc=browser.session('task-usc','',USC);
  assert.equal(usc.account,USC);
  const opened=await usc.navigate(g.origin+'/mail/');
  assert.match(opened.text,/Mail for craviott@usc\.edu/);assert.ok(g.seen.includes('/mail/?authuser=craviott%40usc.edu'),'the address named the account: '+g.seen);
  // An address that names another account by its number is opened as the task's account instead.
  const numbered=await usc.navigate(g.origin+'/mail/u/0/');
  assert.match(numbered.text,/Mail for craviott@usc\.edu/,'not the default account the address pointed at');
  // A link the agent follows on the page (an ordinary Google link, with no account in it) carries the account too.
  const followed=await click(usc,'Next page');
  assert.match(followed.page.text,/Mail for craviott@usc\.edu/);
  assert.ok(g.seen.includes('/mail/next?authuser=craviott%40usc.edu'),'the followed link named the account: '+g.seen);
  assert.deepEqual(g.seen.filter(u=>u.startsWith('/mail')&&!u.includes('authuser=craviott%40usc.edu')),[],'no Google page was ever asked for without the task’s account');
  // The account it was opened with stays: a request naming another account for the same task is refused.
  assert.throws(()=>browser.session('task-usc','',PERSONAL),/keeps the account/);
  assert.throws(()=>browser.session('task-other','','not an address'),/email/);
 }finally{await browser.close();await rm(root,{recursive:true,force:true});await g.close();}
});

test('the account chooser picks the pinned account, and says so plainly when that account is not signed in to Buddy’s Chrome',{timeout:60000},async()=>{
 const g=await google(),{root,profile}=await fixtureRoot('buddy-account-chooser-');
 const browser=new SharedBrowser(profile,{testOrigins:[g.origin],testGoogle:[g.origin],testGooglePath:'/accounts/'});
 try{
  const usc=browser.session('task-usc','',USC);
  const chosen=await usc.navigate(g.origin+'/accounts/chooser?continue=/mail/inbox');
  assert.match(chosen.text,/Mail for craviott@usc\.edu/,'the chooser chose the task’s account: '+chosen.text);
  assert.ok(g.seen.includes('/mail/inbox?authuser=craviott%40usc.edu'));
  assert.ok(!g.seen.some(u=>u.includes(encodeURIComponent(PERSONAL))),'the other account was never chosen');
  // The pinned account is not among the signed-in accounts: nothing is chosen, and the task is told what the person must do.
  g.accounts=[PERSONAL];const before=g.seen.length;
  await assert.rejects(usc.navigate(g.origin+'/accounts/chooser?continue=/mail/'),/Sign in to craviott@usc\.edu in Buddy’s Chrome, then press Done\./);
  await settle();
  assert.deepEqual(g.seen.slice(before).filter(u=>u.startsWith('/mail')),[],'no account was chosen in its place');
 }finally{await browser.close();await rm(root,{recursive:true,force:true});await g.close();}
});

test('“Continue with Google” on another site chooses the pinned account, and never another one when it is missing',{timeout:60000},async()=>{
 const chosen=[];let accounts=[PERSONAL,USC];
 const s=await site((req,res)=>{
  const url=new URL(req.url,'http://fixture');
  if(url.pathname==='/sign-in')return res.end('<title>Sign in</title><input type="password"><button onclick="location.href=\'/google/choose\'">Continue with Google</button>');
  if(url.pathname==='/google/choose')return res.end(`<title>Choose an account</title>${accounts.map(a=>`<div role="link" tabindex="0" data-identifier="${a}" onclick="location.href='/oauth_callback?as=${encodeURIComponent(a)}'">${a}</div>`).join('')}`);
  if(url.pathname==='/oauth_callback'){chosen.push(url.searchParams.get('as'));res.writeHead(302,{Location:'/dashboard'});return res.end();}
  res.end('<h1>Dashboard</h1>');
 });
 const {root,profile}=await fixtureRoot('buddy-account-oauth-');
 const browser=new SharedBrowser(profile,{testOrigins:[s.origin],testGooglePath:'/google/'});
 try{
  const usc=browser.session('task-usc','',USC);
  await usc.navigate(s.origin+'/sign-in');
  let plan=await usc.prepareSignIn('signin');
  const done=await usc.useSaved(plan.token);
  assert.equal(done.performed,true);assert.equal(done.method,'google');assert.match(done.page.text,/Dashboard/);
  assert.deepEqual(chosen,[USC],'of the two accounts offered, the task’s own was chosen');
  // An unpinned task offered two accounts still asks the person, as before.
  const any=browser.session('task-any');await any.navigate(s.origin+'/sign-in');
  plan=await any.prepareSignIn('signin');assert.equal((await any.useSaved(plan.token)).needsUser,true);
  // The task's account is not offered: nothing is chosen, and the person is asked to sign in to it.
  accounts=[PERSONAL];await usc.navigate(s.origin+'/sign-in');
  plan=await usc.prepareSignIn('signin');
  const missing=await usc.useSaved(plan.token);
  assert.equal(missing.needsUser,true);assert.match(missing.reason,/Sign in to craviott@usc\.edu in Buddy’s Chrome, then press Done\./);
  assert.deepEqual(chosen,[USC],'the other account was never chosen in its place');
 }finally{await browser.close();await rm(root,{recursive:true,force:true});await s.close();}
});

test('a Google page that shows another account is refused before any action and the action never runs; one that shows no account at all goes ahead',{timeout:60000},async()=>{
 const g=await google(),{root,profile}=await fixtureRoot('buddy-account-mismatch-');
 const browser=new SharedBrowser(profile,{testOrigins:[g.origin],testGoogle:[g.origin],testGooglePath:'/accounts/'});
 try{
  const usc=browser.session('task-usc','',USC);
  const refusal=/This page is signed in as me\.personal@gmail\.com, but this task must use craviott@usc\.edu\. Buddy stopped instead of continuing as me\.personal@gmail\.com\./;
  // Google shows the default account instead (the pinned one is not signed in there): the agent is told, and sees nothing of that account.
  await assert.rejects(usc.navigate(g.origin+'/fallback/mail'),refusal);
  await assert.rejects(usc.read(),refusal,'reading it again is refused too');
  // A Google page that shows no account (YouTube, a help page, another language): Buddy can't see another account there, so the step goes
  // ahead (the address still names the task's account).
  const plain=await usc.navigate(g.origin+'/plain');
  assert.ok(g.seen.includes('/plain?authuser=craviott%40usc.edu'),'the address still names the account: '+g.seen);
  await click(usc,'Send');await settle();
  assert.deepEqual(g.sent,['unknown'],'a page with no account signal is not refused');
  assert.ok(plain.controls.some(c=>c.name==='Send'));
  // The page's account changes after a step was approved: the approved step is not done.
  const mail=await usc.navigate(g.origin+'/mail/');
  const prepared=await usc.prepare({snapshotId:mail.snapshotId,action:'click',ref:mail.controls.find(c=>c.name==='Send').ref});
  await usc.page.evaluate(who=>{const a=document.querySelector('[aria-label^="Google Account"]');a.setAttribute('aria-label',`Google Account: Fixture Person (${who})`);},PERSONAL);
  await assert.rejects(usc.commit(prepared.token),/Nothing was sent/);
  await settle();
  assert.deepEqual(g.sent,['unknown'],'no action ran as the wrong account');
  // The same step on the right account goes through, once.
  await usc.navigate(g.origin+'/mail/');await click(usc,'Send');await settle();
  assert.deepEqual(g.sent,['unknown',USC]);
 }finally{await browser.close();await rm(root,{recursive:true,force:true});await g.close();}
});

test('an unpinned task is unchanged, and two tasks pinned to different accounts in the one Chrome each keep their own',{timeout:60000},async()=>{
 const g=await google(),{root,profile}=await fixtureRoot('buddy-account-two-');
 const browser=new SharedBrowser(profile,{testOrigins:[g.origin],testGoogle:[g.origin],testGooglePath:'/accounts/'});
 try{
  const any=browser.session('task-any');
  assert.equal(any.account,'');
  const page=await any.navigate(g.origin+'/mail/');
  assert.match(page.text,/Mail for me\.personal@gmail\.com/);assert.ok(g.seen.includes('/mail/'),'the address is left as it was');
  await click(any,'Send');await settle();
  assert.deepEqual(g.sent,[PERSONAL],'an unpinned task acts as the page’s account, as before');
  await browser.closeSession('task-any');g.sent.length=0;g.seen.length=0;
  const usc=browser.session('task-usc','',USC),mine=browser.session('task-mine','',PERSONAL);
  const [a,b]=await Promise.all([usc.navigate(g.origin+'/mail/'),mine.navigate(g.origin+'/mail/')]);
  assert.match(a.text,/Mail for craviott@usc\.edu/);assert.match(b.text,/Mail for me\.personal@gmail\.com/);
  await Promise.all([click(usc,'Next page'),click(mine,'Next page')]);
  assert.ok(g.seen.includes('/mail/next?authuser=craviott%40usc.edu')&&g.seen.includes('/mail/next?authuser=me.personal%40gmail.com'),'each followed link named its own task’s account: '+g.seen);
  assert.match((await usc.read()).text,/Mail for craviott@usc\.edu/);assert.match((await mine.read()).text,/Mail for me\.personal@gmail\.com/);
  await Promise.all([click(usc,'Send'),click(mine,'Send')]);await settle();
  assert.deepEqual([...g.sent].sort(),[USC,PERSONAL].sort(),'each acted as its own account, once');
 }finally{await browser.close();await rm(root,{recursive:true,force:true});await g.close();}
});

test('on other sites a pinned task signs in only as its account: a saved login or a typed sign-in for another email is handed to the person',{timeout:60000},async()=>{
 const posts=[];let email='someone.else@example.com';
 const a=await site((req,res,body)=>{
  if(req.method==='POST'){posts.push(new URLSearchParams(body).get('email'));return res.end('<h1>Signed in</h1>');}
  res.end(`<title>Sign in</title><form method="post" action="/session"><label>Email<input type="email" name="email" value="${email}"></label><label>Password<input type="password" name="password" autocomplete="current-password"></label><button>Sign in</button></form>`);
 });
 const {root,profile}=await fixtureRoot('buddy-account-sites-');
 const browser=new SharedBrowser(profile,{testOrigins:[a.origin]});
 try{
  const usc=browser.session('task-usc','',USC);
  await usc.navigate(a.origin+'/login');
  await usc.page.locator('[name=password]').evaluate(e=>{e.value='chrome-filled-fixture';});
  let plan=await usc.prepareSignIn('signin');
  const saved=await usc.useSaved(plan.token);
  assert.equal(saved.needsUser,true);assert.match(saved.reason,/someone\.else@example\.com/);assert.match(saved.reason,/craviott@usc\.edu/);
  assert.ok(!JSON.stringify(saved).includes('chrome-filled-fixture'),'never the password');
  await assert.rejects(usc.secretPlan(),/someone\.else@example\.com.*craviott@usc\.edu|craviott@usc\.edu.*someone\.else@example\.com/);
  assert.deepEqual(posts,[],'nothing was submitted as another account');
  // The site's username is the task's account: both go ahead as before.
  email=USC;await usc.navigate(a.origin+'/login');
  assert.equal((await usc.secretPlan()).account,USC);
  await usc.page.locator('[name=password]').evaluate(e=>{e.value='chrome-filled-fixture';});
  plan=await usc.prepareSignIn('signin');
  assert.equal((await usc.useSaved(plan.token)).performed,true);
  assert.deepEqual(posts,[USC]);
  // A site whose username is not an email is not second-guessed.
  email='jdoe';await usc.navigate(a.origin+'/login');
  assert.equal((await usc.secretPlan()).field,'password');
 }finally{await browser.close();await rm(root,{recursive:true,force:true});await a.close();}
});

import test from 'node:test';
import assert from 'node:assert/strict';
import {chromium} from 'playwright-core';
import {mkdtemp,rm} from 'node:fs/promises';
import {existsSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';

// In the chat: "JobApply wants to create an account on jobs.ubs.com with … — is that fine?" with ✓ Create account and ✗ Don't, then the
// receipt in place with Saved sign-ins; the card for a sign-up Buddy stopped because it asks for money (Open the page, Skip); and a sign-in
// that asks for the email and the password together: both fields, the email filled in, an eye on the password, and "Never shown to JobApply.
// Filled directly to jobs.ubs.com." The Mac app's bridge is a stand-in that records every call.
const skip=process.platform!=='darwin'||!existsSync('/Applications/Google Chrome.app');
const relay=new URL('../../relay/index.html',import.meta.url).href;
const EMAIL='matteo.craviotto@gmail.com',SECRET='Typed!pw-61Hz-not-real';

function bridge(){
 window.calls=[];window.ops=[];window.saved=[];window.replies={};
 window.fixtureWorker={online:true,paused:false,tasks:[],routines:[],decisions:[],notifications:{},plans:[],pulse:{agents:{}},supervisorLane:{online:true,busy:false},signinRequests:[]};
 window.BuddyDesktop={saveState:async json=>{saved.push(json);return {saved:true};},
  worker:async p=>{ops.push(JSON.parse(JSON.stringify(p)));
   if(['status','start'].includes(p.operation))return structuredClone({...fixtureWorker,workspace:state.conversationWorkspace});
   if(p.operation==='detail')return {task:fixtureWorker.tasks.find(t=>t.id===p.taskId)||null};
   if(p.operation==='notify')return {notifications:{}};
   if(p.operation==='browser')return {opened:true,private:true};
   return {};},
  signin:async p=>{calls.push(JSON.parse(JSON.stringify(p)));if(p.action==='sites')return {sites:[]};if(p.action==='status')return {profiles:[]};const next=(replies[p.action]||[]).shift();return next||{};}};
}
function people(){
 document.getElementById('onboarding-root').innerHTML='';closeModal();
 state.agents=[['jobapply','JobApply']].map(([id,name])=>({id,name,role:'Applications',description:'x',setupStatus:'ready',avatarShape:'star',avatarColor:'lilac',tools:{web:true,desktop:true}}));
 state.groups=[];state.messages={jobapply:[]};state.runs={};state.drafts={};state.attachments={};state.proposals=[];state.teamPlans=[];state.activitySeen={};state.activityDismissed={};state.hiddenAgents=[];state.onboarding={status:'completed',agentId:'jobapply'};
 navigate('chat','jobapply');
}
const ask=(extra={})=>({key:'account:t1:a1',kind:'account',taskId:'t1',agentId:'jobapply',reviewId:'a1',purpose:'signup',origin:'https://jobs.ubs.com',account:EMAIL,
 reason:'To apply for the analyst role you asked about.',what:'Buddy makes a strong password and keeps it in your Keychain; it agrees to the site’s standard terms; it confirms the email in your Gmail.',title:'Apply at UBS',...extra});
async function open(directory){
 const context=await chromium.launchPersistentContext(path.join(directory,'browser.noindex'),{channel:'chrome',headless:true,viewport:{width:1280,height:900},reducedMotion:'reduce'});
 await context.route('**/*',r=>/^https?:/.test(r.request().url())?r.abort():r.continue());
 await context.addInitScript(bridge);
 const page=context.pages()[0];const errors=[];page.on('pageerror',e=>errors.push(e.message));
 await page.goto(relay);await page.waitForFunction(()=>!!window.BuddySignIn&&!!window.BuddyWorkerUI);
 await page.evaluate(people);
 return {context,page,errors};
}
async function snapshot(page,value){await page.evaluate(v=>{Object.assign(fixtureWorker,v);},value);await page.evaluate(()=>BuddyWorkerUI.refresh(false));}
async function nowhere(page,needle){
 return page.evaluate(n=>{
  const places={dom:document.documentElement.outerHTML,fields:[...document.querySelectorAll('input,textarea')].map(i=>i.value).join('\n'),state:JSON.stringify(state),saved:saved.join('\n'),
   local:Object.keys(localStorage).map(k=>k+'='+localStorage.getItem(k)).join('\n'),worker:JSON.stringify(ops)};
  return Object.entries(places).filter(([,text])=>text.includes(n)).map(([where])=>where);
 },needle);
}
const task={id:'t1',agentId:'jobapply',title:'Apply at UBS',status:'waiting_review',updatedAt:'2026-10-21T09:00:00Z'};

test('the create card asks “is that fine?” with why and what happens; Create account answers through the sign-in bridge, and the receipt shows in place with Saved sign-ins',{skip,timeout:90000},async()=>{
 const directory=await mkdtemp(path.join(tmpdir(),'buddy-accounts-ui-'));let context;
 try{
  const opened=await open(directory);context=opened.context;const {page,errors}=opened;
  await snapshot(page,{tasks:[task],signinRequests:[ask()]});
  const card=page.locator('[data-signin-key="account:t1:a1"]');await card.waitFor({timeout:8000});
  await card.getByText('JobApply wants to create an account on jobs.ubs.com with matteo.craviotto@gmail.com — is that fine?',{exact:true}).waitFor();
  const text=await card.innerText();
  assert.match(text,/To apply for the analyst role you asked about\./,'one line of why');
  assert.match(text,/Buddy makes a strong password and keeps it in your Keychain; it agrees to the site’s standard terms; it confirms the email in your Gmail\./,'what will happen');
  const yes=card.getByRole('button',{name:'Create account'}),no=card.getByRole('button',{name:'Don’t'});
  assert.equal(await yes.count(),1);assert.equal(await no.count(),1);
  assert.match(await yes.innerText(),/✓/);assert.match(await no.innerText(),/✗/);
  await page.evaluate(()=>{replies.account=[{answered:true,allow:true,reviewId:'a1'}];});
  await yes.click();
  await card.getByText('Creating your account on jobs.ubs.com…').waitFor();
  assert.deepEqual(await page.evaluate(()=>calls.at(-1)),{action:'account',taskId:'t1',reviewId:'a1',allow:true},'only the sign-in bridge carries the answer');
  assert.ok(!(await page.evaluate(()=>ops.some(o=>o.operation==='review'))),'never the general review path');
  assert.equal(await card.getByRole('button',{name:'Create account'}).count(),0,'no second answer');
  const receipt='Created an account on jobs.ubs.com as matteo.craviotto@gmail.com — password saved in your Keychain.';
  await snapshot(page,{tasks:[{...task,status:'running'}],signinRequests:[ask({done:true,created:true,receipt,details:'Chrome’s Password Manager can’t be filled in by automation, so Buddy keeps this password in your Mac’s Keychain and fills it in whenever an agent signs in to the site. You’ll find it in Saved sign-ins.'})]});
  await card.getByText(receipt).waitFor();
  assert.match(await card.innerText(),/Chrome’s Password Manager can’t be filled in by automation/);
  await card.getByRole('button',{name:'Saved sign-ins'}).click();
  await page.locator('.worker-saved-signins').waitFor({timeout:8000});
  assert.deepEqual(errors,[]);
 }finally{await context?.close();await rm(directory,{recursive:true,force:true});}
});

test('Don’t closes the card and says so; a reset asks in its own words',{skip,timeout:90000},async()=>{
 const directory=await mkdtemp(path.join(tmpdir(),'buddy-accounts-no-'));let context;
 try{
  const opened=await open(directory);context=opened.context;const {page,errors}=opened;
  await snapshot(page,{tasks:[task],signinRequests:[ask({key:'account:t1:a2',reviewId:'a2',origin:'https://second.example'}),ask({key:'account:t1:a3',reviewId:'a3',purpose:'reset',origin:'https://reset.example',reason:'Your remembered password for reset.example didn’t work.',what:'Buddy asks reset.example for a reset email, opens the link from your Gmail, sets a new strong password and keeps it in your Keychain, then signs in.'})]});
  const second=page.locator('[data-signin-key="account:t1:a2"]');await second.waitFor({timeout:8000});
  await page.evaluate(()=>{replies.account=[{answered:true,allow:false,reviewId:'a2'}];});
  await second.getByRole('button',{name:'Don’t'}).click();
  await second.waitFor({state:'detached'});await page.locator('#toast').filter({hasText:'Not now. JobApply won’t create an account on second.example.'}).waitFor();
  assert.deepEqual(await page.evaluate(()=>calls.at(-1)),{action:'account',taskId:'t1',reviewId:'a2',allow:false});
  const reset=page.locator('[data-signin-key="account:t1:a3"]');
  await reset.getByText('JobApply wants to reset your password on reset.example through your email — is that fine?',{exact:true}).waitFor();
  assert.equal(await reset.getByRole('button',{name:'Reset password'}).count(),1);
  assert.deepEqual(errors,[]);
 }finally{await context?.close();await rm(directory,{recursive:true,force:true});}
});

test('a sign-up Buddy stopped for money: what it asks for, Open the page and Skip, never a field for a card',{skip,timeout:90000},async()=>{
 const directory=await mkdtemp(path.join(tmpdir(),'buddy-accounts-money-'));let context;
 try{
  const opened=await open(directory);context=opened.context;const {page,errors}=opened;
  const step={key:'step:t2:p1',kind:'step',taskId:'t2',agentId:'jobapply',need:'payment',money:'trial',url:'https://trial.example/join',origin:'https://trial.example',
   instruction:'This sign-up on trial.example starts a free trial that becomes paid. Buddy stopped. It never enters payment details or starts a paid trial. Open the page to do it yourself in Buddy’s Chrome and press Done, or Skip.',chromeOpen:false};
  await snapshot(page,{tasks:[{id:'t2',agentId:'jobapply',title:'Use the tool',status:'waiting_user',updatedAt:'2026-10-21T09:00:00Z'}],signinRequests:[step]});
  const card=page.locator('[data-signin-key="step:t2:p1"]');await card.waitFor({timeout:8000});
  await card.getByText('This sign-up on trial.example starts a free trial that becomes paid',{exact:true}).waitFor();
  assert.match(await card.innerText(),/Buddy stopped\. It never enters payment details or starts a paid trial\./);
  assert.equal(await card.getByRole('button',{name:'Open the page'}).count(),1);assert.equal(await card.getByRole('button',{name:'Skip'}).count(),1);
  assert.equal(await card.locator('input').count(),0,'no field to type a card into');
  await card.getByRole('button',{name:'Open the page'}).click();
  await card.getByText('Chrome is open at trial.example. Finish there, then press Done.').waitFor();
  // The app now says Chrome is open for this step: Done appears beside Skip.
  await snapshot(page,{signinRequests:[{...step,chromeOpen:true}]});
  await card.getByRole('button',{name:'Done'}).waitFor();
  assert.deepEqual(await page.evaluate(()=>ops.filter(o=>o.operation==='browser')),[{operation:'browser',taskId:'t2',url:'https://trial.example/join'}]);
  await page.evaluate(()=>{replies.skip=[{skipped:true}];});
  await card.getByRole('button',{name:'Skip'}).click();
  await card.waitFor({state:'detached'});await page.locator('#toast').filter({hasText:'Skipped — JobApply goes on without it.'}).waitFor();
  assert.deepEqual(await page.evaluate(()=>calls.at(-1)),{action:'skip',taskId:'t2'});
  assert.deepEqual(errors,[]);
 }finally{await context?.close();await rm(directory,{recursive:true,force:true});}
});

test('a sign-in that asks for both: the email filled in, the password with an eye, “Never shown to JobApply. Filled directly to jobs.ubs.com.”',{skip,timeout:90000},async()=>{
 const directory=await mkdtemp(path.join(tmpdir(),'buddy-accounts-login-'));let context;
 try{
  const opened=await open(directory);context=opened.context;const {page,errors}=opened;
  const login={key:'signin:t1:s1',kind:'signin',taskId:'t1',agentId:'jobapply',reviewId:'r1',mode:'signin',origin:'https://jobs.ubs.com',account:EMAIL,field:'login',step:'login',note:'',attempts:0,choices:['private'],title:'Apply at UBS'};
  await snapshot(page,{tasks:[task],signinRequests:[login]});
  const card=page.locator('[data-signin-key="signin:t1:s1"]');await card.waitFor({timeout:8000});
  await card.getByText('Sign in to jobs.ubs.com',{exact:true}).waitFor();
  const email=card.getByLabel('Email address',{exact:true}),password=card.getByLabel('Password',{exact:true});
  assert.equal(await email.inputValue(),EMAIL,'the task’s account is filled in');
  assert.equal(await email.getAttribute('type'),'email');assert.equal(await password.getAttribute('type'),'password');
  await card.getByText('Never shown to JobApply. Filled directly to jobs.ubs.com.',{exact:true}).waitFor();
  await password.fill(SECRET);
  const eye=card.getByRole('button',{name:'Show password'});
  await eye.click();
  assert.equal(await password.getAttribute('type'),'text','the eye shows what was typed');
  assert.equal(await card.getByRole('button',{name:'Hide password'}).getAttribute('aria-pressed'),'true');
  // The chat redraws while typing: the field keeps what was typed and how it is shown.
  await page.evaluate(()=>refreshLiveChat('jobapply'));
  assert.equal(await card.getByLabel('Password',{exact:true}).inputValue(),SECRET);
  await card.getByRole('button',{name:'Hide password'}).click();
  assert.equal(await card.getByLabel('Password',{exact:true}).getAttribute('type'),'password');
  await page.evaluate(()=>{replies.secret=[{sent:true,signedIn:true,remembered:true}];});
  await card.getByRole('button',{name:'Send'}).click();
  await card.waitFor({state:'detached'});await page.locator('#toast').filter({hasText:'Sent — signed in. Remembered for jobs.ubs.com.'}).waitFor();
  assert.deepEqual(await page.evaluate(()=>calls.at(-1)),{action:'secret',taskId:'t1',reviewId:'r1',value:SECRET,username:EMAIL,remember:true});
  assert.deepEqual(await nowhere(page,SECRET),[],'what was typed is nowhere on the page');
  // A password field alone has the eye and the same line.
  await snapshot(page,{signinRequests:[{...login,key:'signin:t1:s2',reviewId:'r2',field:'password',step:'password'}]});
  const single=page.locator('[data-signin-key="signin:t1:s2"]');await single.waitFor();
  assert.equal(await single.getByRole('button',{name:'Show password'}).count(),1);
  await single.getByText('Never shown to JobApply. Filled directly to jobs.ubs.com.',{exact:true}).waitFor();
  assert.deepEqual(errors,[]);
 }finally{await context?.close();await rm(directory,{recursive:true,force:true});}
});

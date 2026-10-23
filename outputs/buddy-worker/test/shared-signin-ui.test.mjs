import test from 'node:test';
import assert from 'node:assert/strict';
import {chromium} from 'playwright-core';
import {mkdtemp,rm} from 'node:fs/promises';
import {existsSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';

// Sign-ins asked in the chats: a private field for a website's password, Done for a step done elsewhere, and the one "Set up once"
// Browser sign-in page. The Mac app's bridge is a stand-in that records every call.
const skip=process.platform!=='darwin'||!existsSync('/Applications/Google Chrome.app');
const relay=new URL('../../relay/index.html',import.meta.url).href;
const SECRET='Shop!pw-41Kx-typed-in-chat';

function bridge(){
 window.calls=[];window.ops=[];window.saved=[];window.replies={};window.fixtureWorker={online:true,paused:false,tasks:[],routines:[],decisions:[],notifications:{},plans:[],pulse:{agents:{}},supervisorLane:{online:true,busy:false},signinRequests:[]};
 window.BuddyDesktop={saveState:async json=>{saved.push(json);return {saved:true};},
  worker:async p=>{ops.push(JSON.parse(JSON.stringify(p)));
   if(['status','start'].includes(p.operation))return structuredClone({...fixtureWorker,workspace:state.conversationWorkspace});
   if(p.operation==='detail')return {task:fixtureWorker.tasks.find(t=>t.id===p.taskId)||null};
   if(p.operation==='notify')return {notifications:{}};
   if(p.operation==='openGoogle'){fixtureWorker.privateBrowser={shared:true,taskId:null,agentId:null};return {opened:true,private:true};}
   if(p.operation==='review'||p.operation==='browser')return {accepted:true};
   return {};},
  signin:async p=>{calls.push(JSON.parse(JSON.stringify(p)));const next=(replies[p.action]||[]).shift();return next||{};}};
}
function people(){
 document.getElementById('onboarding-root').innerHTML='';closeModal();
 state.agents=[['ada','Ada'],['bo','Bo'],['cy','Cy']].map(([id,name])=>({id,name,role:'Shopper',description:'x',setupStatus:'ready',avatarShape:'star',avatarColor:'lilac',tools:id==='cy'?{web:false,desktop:true}:{web:true,desktop:true}}));
 state.groups=[{id:'team',name:'Shop team',members:['ada','bo'],objective:'Orders',managedBy:'ada',createdAt:'2026-10-19T09:00:00Z'}];
 state.messages={ada:[],bo:[],cy:[],team:[{id:'u1',who:'you',body:'How are the orders going?',time:'10:00'}]};
 state.runs={};state.drafts={};state.attachments={};state.proposals=[];state.teamPlans=[];state.activitySeen={};state.activityDismissed={};state.hiddenAgents=[];state.onboarding={status:'completed',agentId:'ada'};
 navigate('chat','ada');
}
const plan={id:'p1',groupId:'team',objective:'Check the orders',supervisorId:'ada',status:'active',revision:1,scope:null,notices:[],run:{state:'working',working:['ada'],needsYou:1,idleSince:null},
 stages:[{id:'s1',n:1,title:'Orders',goal:'Read the orders',acceptance:['A list'],status:'active',tasks:[{id:'pt1',title:'Read my last order',assignee:'ada',kind:'research',status:'running',workerTaskId:'t1',workerStatus:'waiting_review',blockedOn:'none',resultSummary:'',updatedAt:'2026-10-20T09:00:00Z'}]}]};
const signinRequest={key:'signin:t1:s1',kind:'signin',taskId:'t1',agentId:'ada',planId:'p1',reviewId:'r1',mode:'signin',origin:'https://shop.example',account:'ada@example.com',field:'password',step:'password',note:'',attempts:0,choices:['private'],title:'Read my last order'};
async function open(directory){
 const context=await chromium.launchPersistentContext(path.join(directory,'browser.noindex'),{channel:'chrome',headless:true,viewport:{width:1280,height:900},reducedMotion:'reduce'});
 await context.route('**/*',r=>/^https?:/.test(r.request().url())?r.abort():r.continue());
 await context.addInitScript(bridge);
 const page=context.pages()[0];const errors=[];page.on('pageerror',e=>errors.push(e.message));
 await page.goto(relay);await page.waitForFunction(()=>!!window.BuddySignIn&&!!window.BuddyWorkerUI&&!!window.BuddyActivity);
 await page.evaluate(people);
 return {context,page,errors};
}
async function snapshot(page,value){await page.evaluate(v=>{Object.assign(fixtureWorker,v);},value);await page.evaluate(()=>BuddyWorkerUI.refresh(false));}
// Everywhere a typed value could end up on the page: the document, every field, the saved workspace (now and every save the page made),
// browser storage, and every request the page sent other than the one sign-in call.
async function nowhere(page,needle){
 return page.evaluate(n=>{
  const places={dom:document.documentElement.outerHTML,fields:[...document.querySelectorAll('input,textarea')].map(i=>i.value).join('\n'),state:JSON.stringify(state),saved:saved.join('\n'),
   local:Object.keys(localStorage).map(k=>k+'='+localStorage.getItem(k)).join('\n'),session:Object.keys(sessionStorage).map(k=>k+'='+sessionStorage.getItem(k)).join('\n'),worker:JSON.stringify(ops)};
  return Object.entries(places).filter(([,text])=>text.includes(n)).map(([where])=>where);
 },needle);
}

test('a website password is typed in the agent’s chat; the group chat shows the same request; what is typed goes only to the sign-in bridge and is gone after Send',{skip,timeout:90000},async()=>{
 const directory=await mkdtemp(path.join(tmpdir(),'buddy-signin-chat-'));let context;
 try{
  const opened=await open(directory);context=opened.context;const {page,errors}=opened;
  const task={id:'t1',workspace:'',agentId:'ada',title:'Read my last order',status:'waiting_review',planId:'p1',provider:'chatgpt',kind:'general',updatedAt:'2026-10-20T09:00:00Z',progress:'Needs your sign-in'};
  await snapshot(page,{tasks:[task],plans:[plan],signinRequests:[signinRequest],decisions:[{id:'review:r1',kind:'signin',audience:'user',agentId:'ada',taskId:'t1',title:'Sign in to shop.example',question:'Choose how to sign in.',actionLabel:'Open chat',payload:{taskId:'t1',reviewId:'r1'},createdAt:'2026-10-20T09:00:00Z'}]});
  const holder=page.locator('[data-signin-holder="signin:t1:s1"]');await holder.waitFor({timeout:8000});
  const input=holder.locator('input');
  assert.deepEqual(await input.evaluate(e=>({type:e.type,autocomplete:e.getAttribute('autocomplete'),spellcheck:e.getAttribute('spellcheck'),label:e.getAttribute('aria-label'),value:e.getAttribute('value')})),{type:'password',autocomplete:'off',spellcheck:'false',label:'Password for shop.example',value:null},'a masked field, labelled with the site');
  await page.getByText('Account: ada@example.com · For “Read my last order”').waitFor();
  assert.equal(await page.locator('#messages [data-signin-key]').count(),1,'one request message in the agent’s chat');
  // The same request in the team's group chat, said by the agent.
  await page.evaluate(()=>navigate('chat','team'));
  const shared=page.locator('#messages [data-signin-key="signin:t1:s1"]');await shared.waitFor();
  assert.equal(await shared.count(),1,'and one in the group chat');assert.match(await shared.innerText(),/Ada/);
  await page.evaluate(()=>navigate('chat','ada'));await holder.waitFor();
  // Typing survives the chat being redrawn (a reply streaming in, a status arriving).
  await input.click();await page.keyboard.type(SECRET.slice(0,8));
  await page.evaluate(()=>refreshLiveChat('ada'));
  await page.keyboard.type(SECRET.slice(8));
  assert.equal(await holder.locator('input').inputValue(),SECRET,'nothing typed is lost to a redraw');
  assert.deepEqual(await nowhere(page,SECRET),['fields'],'while it is typed it is only in its field (not in state, drafts, storage or any request)');
  await page.evaluate(()=>{replies.secret=[{sent:true,signedIn:true}];});
  await holder.getByRole('button',{name:'Send'}).click();
  await page.getByText('Sent — signed in').waitFor();
  assert.deepEqual(await page.evaluate(()=>calls),[{action:'secret',taskId:'t1',reviewId:'r1',value:SECRET,remember:true}],'one call, to the sign-in bridge, for exactly this request (Remember is on unless turned off)');
  assert.equal(await page.locator('[data-signin-holder]').count(),0,'the field is gone');
  assert.deepEqual(await nowhere(page,SECRET),[],'after Send it is nowhere on the page');
  assert.equal(await page.evaluate(()=>state.messages.team.find(m=>m.kind==='signin-request').result),'Sent — signed in','the group chat’s message says so too');
  // The request ends: the messages stay, saying how it went, and the Needs item is gone.
  await snapshot(page,{tasks:[{...task,status:'running'}],signinRequests:[],decisions:[]});
  assert.ok(await page.evaluate(()=>Object.values(state.messages).flat().filter(m=>m.kind==='signin-request').every(m=>m.status==='closed'&&m.result==='Sent — signed in')));
  assert.equal(await page.evaluate(()=>BuddyActivity.collect(state,BuddyWorkerUI.snapshot()).filter(i=>i.kind==='needs').length),0);
  assert.deepEqual(errors,[]);
 }finally{await context?.close();await rm(directory,{recursive:true,force:true});}
});

test('a wrong password says “that didn’t work” and keeps the field for the next try; Not now ends it in both chats',{skip,timeout:90000},async()=>{
 const directory=await mkdtemp(path.join(tmpdir(),'buddy-signin-retry-'));let context;
 try{
  const opened=await open(directory);context=opened.context;const {page,errors}=opened;
  await snapshot(page,{tasks:[{id:'t1',agentId:'ada',title:'Read my last order',status:'waiting_review',planId:'p1',updatedAt:'2026-10-20T09:00:00Z'}],plans:[plan],signinRequests:[signinRequest]});
  const holder=page.locator('[data-signin-holder="signin:t1:s1"]');await holder.waitFor({timeout:8000});
  // The app's answer names the next try; a status read made just before it still shows the first one, and must not win.
  await page.evaluate(r=>{replies.secret=[{sent:true,signedIn:false,retry:true,field:'password',reviewId:'r2',note:'That didn’t work. Check it and type it again.'}];},signinRequest);
  await holder.locator('input').fill('not-the-password');await holder.locator('input').press('Enter');
  await page.getByText('Sent — that didn’t work, try again').waitFor();
  assert.equal(await holder.locator('input').inputValue(),'','the field is empty again');
  assert.equal(await page.evaluate(()=>state.messages.ada.find(m=>m.kind==='signin-request').request.reviewId),'r2','the next try is the one Send goes to');
  await snapshot(page,{signinRequests:[{...signinRequest,reviewId:'r2',note:'That didn’t work. Check it and type it again.'}]});
  await page.getByText('That didn’t work. Check it and type it again.').waitFor();
  await page.evaluate(()=>{replies.secret=[{sent:true,signedIn:true}];});
  await holder.locator('input').fill(SECRET);await holder.getByRole('button',{name:'Send'}).click();
  await page.getByText('Sent — signed in').waitFor();
  assert.deepEqual(await page.evaluate(()=>calls.map(c=>[c.reviewId,c.value===undefined])),[['r1',false],['r2',false]]);
  assert.deepEqual(await nowhere(page,SECRET),[]);assert.deepEqual(await nowhere(page,'not-the-password'),[]);
  // Another request: Not now answers the review as declined, and both chats say so.
  await snapshot(page,{signinRequests:[{...signinRequest,key:'signin:t1:s2',reviewId:'r9'}]});
  await page.locator('[data-signin-key="signin:t1:s2"]').getByRole('button',{name:'Not now'}).click();
  await page.waitForFunction(()=>ops.some(o=>o.operation==='review'));
  assert.deepEqual(await page.evaluate(()=>ops.filter(o=>o.operation==='review')),[{operation:'review',taskId:'t1',id:'r9',accept:false}]);
  assert.ok(await page.evaluate(()=>Object.values(state.messages).flat().filter(m=>m.request?.key==='signin:t1:s2').every(m=>m.status==='closed'&&/Not now/.test(m.result))));
  assert.deepEqual(errors,[]);
 }finally{await context?.close();await rm(directory,{recursive:true,force:true});}
});

test('a step done in Buddy’s Chrome window ends with Done: still unfinished says so and keeps the button; finished, it leaves the chat; a Duo push is acknowledged and leaves by itself',{skip,timeout:90000},async()=>{
 const directory=await mkdtemp(path.join(tmpdir(),'buddy-signin-done-'));let context;
 try{
  const opened=await open(directory);context=opened.context;const {page,errors}=opened;
  const step={key:'step:t2:c1',kind:'step',taskId:'t2',agentId:'ada',need:'signin',origin:'https://mail.example',instruction:'Sign in to mail.example: choose your saved account, or unlock Chrome’s Password Manager in the Chrome window Buddy opened. When you’re finished, press Done.',chromeOpen:true,title:'Check my mail'};
  await snapshot(page,{tasks:[{id:'t2',agentId:'ada',title:'Check my mail',status:'waiting_user',updatedAt:'2026-10-20T09:00:00Z',checkpoint:{id:'c1',need:'signin'}}],signinRequests:[step],decisions:[{id:'step:t2:1:c1',kind:'step',audience:'user',agentId:'ada',taskId:'t2',title:'Finish signing in to mail.example',question:step.instruction,actionLabel:'Done',payload:{taskId:'t2',need:'signin'},createdAt:'2026-10-20T09:00:00Z'}]});
  const message=page.locator('[data-signin-key="step:t2:c1"]');await message.waitFor({timeout:8000});
  await message.getByText('Sign in to mail.example',{exact:true}).waitFor();
  assert.equal(await message.getByRole('button',{name:'Open Chrome'}).count(),0,'Chrome is already open');
  await page.evaluate(()=>{replies.done=[{done:false,reopened:true,note:'It still isn’t finished: mail.example still asks you to sign in. Chrome is open again. Finish there, then press Done.'},{done:true,checked:true}];});
  await message.getByRole('button',{name:'Done'}).click();
  await message.getByText(/It still isn’t finished/).waitFor();
  assert.equal(await message.getByRole('button',{name:'Done'}).isEnabled(),true,'the Done button stays');
  await message.getByRole('button',{name:'Done'}).click();
  await message.waitFor({state:'detached'});await page.locator('#toast').filter({hasText:'Done — Ada is continuing.'}).waitFor();
  assert.deepEqual(await page.evaluate(()=>calls),[{action:'done',taskId:'t2'},{action:'done',taskId:'t2'}]);
  assert.equal(await message.count(),0,'done, the request has left the chat');
  // The Needs item opens this chat at the request.
  await page.evaluate(()=>navigate('chat','bo'));
  await page.getByRole('button',{name:/^Notifications:/}).click();
  await page.getByRole('button',{name:/Finish signing in to mail\.example/}).click();
  await page.waitForFunction(()=>ui.view.target==='ada'&&!document.querySelector('.modal'));
  // A Duo push: Done acknowledges it and puts its Needs item away; the message changes by itself when the command ends.
  const duo={key:'mfa:t3:cmd1',kind:'mfa',taskId:'t3',agentId:'ada',service:'WRDS',instruction:'A command is signing in to WRDS with your saved sign-in. Approve the Duo push on your phone, then press Done.'};
  await snapshot(page,{tasks:[{id:'t3',agentId:'ada',title:'Extract',status:'running',updatedAt:'2026-10-20T09:00:00Z'}],signinRequests:[duo],decisions:[{id:'mfa:t3:cmd1',kind:'mfa',audience:'user',agentId:'ada',taskId:'t3',title:'Approve the WRDS Duo push on your phone',question:'Approve it.',actionLabel:'Open task',payload:{taskId:'t3'},createdAt:'2026-10-20T09:00:00Z'}]});
  const push=page.locator('[data-signin-key="mfa:t3:cmd1"]');await push.waitFor({timeout:8000});
  await push.getByRole('button',{name:'Done'}).click();
  await push.getByText('Thanks. This updates by itself when the command finishes.').waitFor();
  assert.deepEqual(await page.evaluate(()=>ops.filter(o=>o.operation==='notify').at(-1)),{operation:'notify',ids:['decision:mfa:t3:cmd1'],read:true,dismissed:true},'its Needs item is put away');
  await snapshot(page,{tasks:[{id:'t3',agentId:'ada',title:'Extract',status:'completed',updatedAt:'2026-10-20T09:01:00Z'}],signinRequests:[],decisions:[]});
  await push.waitFor({state:'detached'});   // the command ended: the request leaves the chat
  assert.deepEqual(errors,[]);
 }finally{await context?.close();await rm(directory,{recursive:true,force:true});}
});

test('Browser sign-in is one “Set up once” section with one Open Chrome button for every agent with internet access',{skip,timeout:60000},async()=>{
 const directory=await mkdtemp(path.join(tmpdir(),'buddy-setup-once-'));let context;
 try{
  const opened=await open(directory);context=opened.context;const {page,errors}=opened;
  await page.evaluate(()=>{fixtureWorker.browserAgents=['ada','bo'];});
  await page.evaluate(()=>BuddyWorkerUI.profiles());
  const section=page.locator('.worker-setup-once');await section.waitFor({timeout:8000});
  await section.getByText('Every agent with internet access will use the accounts you sign in to here.').waitFor();
  await section.getByText(/as many websites and accounts as you like, including more than one Google account/).waitFor();
  await section.getByText('Used by Ada, Bo. No browser for Cy (internet access is off).').waitFor();
  assert.equal(await page.locator('[data-worker-op="open-google"]').count(),1,'one Open Chrome button, not one per agent');
  assert.equal(await page.locator('.worker-profile').count(),0,'no per-agent rows');
  assert.equal(await page.getByText('Each agent has a separate private Chrome profile.').count(),0);
  await section.getByRole('button',{name:'Open Chrome'}).click();
  await page.waitForFunction(()=>ops.some(o=>o.operation==='openGoogle'));
  assert.deepEqual(await page.evaluate(()=>ops.find(o=>o.operation==='openGoogle')),{operation:'openGoogle'},'no agent is named: it is for everyone');
  await page.locator('.worker-setup-once [data-worker-op="finish-signin"]').waitFor();
  await page.locator('.worker-setup-once').getByText(/Chrome is open\./).waitFor();
  assert.deepEqual(errors,[]);
 }finally{await context?.close();await rm(directory,{recursive:true,force:true});}
});

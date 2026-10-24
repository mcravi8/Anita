import test from 'node:test';
import assert from 'node:assert/strict';
import {chromium} from 'playwright-core';
import {mkdtemp,rm} from 'node:fs/promises';
import {existsSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';

// Connected services, as the person sees them: the chat's card when Forge asks for RunPod and it isn't connected (the address it suggested,
// how the key is sent, whether it can charge money, the key), the one approval card for a request that can cost money (the exact request,
// the agent's cost estimate, what Buddy deletes and when, what will be uploaded, why), and Settings' list of connected services. The Mac
// app's bridges are stand-ins that record every call; a typed key must reach only the sign-in bridge, and nowhere else on the page.
const skip=process.platform!=='darwin'||!existsSync('/Applications/Google Chrome.app');
const relay=new URL('../../relay/index.html',import.meta.url).href;
const KEY='rpa_TYPED-7Q2Z-not-a-real-key',NOTES='notes-TYPED-88Lm';
const connect={key:'credential:t1:c1',kind:'credential',taskId:'t1',agentId:'forge',profile:'service:runpod',service:'RunPod',secret:'service',baseUrl:'https://rest.runpod.io/v2',
 instruction:'Connect RunPod so Forge can use its API: run the 800 C1 replications on 32 vCPUs.',title:'C1 replications'};
const review={id:'svc-1',kind:'service',status:'pending',route:'user',questions:[{id:'operation',question:'Allow this request to RunPod?',options:[{label:'Accept'},{label:'Decline'}]}],
 request:{agent:'Forge',service:'RunPod',baseUrl:'https://rest.runpod.io/v2',charges:true,method:'POST',path:'/pods',query:{},body:'{\n  "cpu" : {\n    "id" : "cpu3c-2-4",\n    "vcpuCount" : 32\n  },\n  "name" : "c1-replications"\n}',
  reason:'Run the 800 C1 replications on 32 vCPUs instead of this Mac.',cost:{perHour:1.28,maxHours:6,maxCostUSD:7.68},lease:{resource:'/id',teardown:'DELETE /pods/{id}',maxHours:6},uploads:[{path:'stages/S02c_review',files:214,bytes:3400000}]},
 tool:{name:'POST /pods on RunPod',service:'RunPod',arguments:{request:'POST https://rest.runpod.io/v2/pods',reason:'Run the 800 C1 replications on 32 vCPUs instead of this Mac.'}}};

function bridge(){
 window.calls=[];window.ops=[];window.saved=[];window.services=[];
 window.fixtureWorker={online:true,paused:false,tasks:[],routines:[],decisions:[],notifications:{},plans:[],pulse:{agents:{}},supervisorLane:{online:true,busy:false},signinRequests:[]};
 window.fixtureTask=null;
 window.BuddyDesktop={saveState:async json=>{saved.push(json);return {saved:true};},
  worker:async p=>{ops.push(JSON.parse(JSON.stringify(p)));
   if(['status','start'].includes(p.operation))return structuredClone({...fixtureWorker,workspace:state.conversationWorkspace});
   if(p.operation==='detail')return {task:fixtureTask};
   if(p.operation==='notify')return {notifications:{}};
   if(p.operation==='review'){fixtureTask={...fixtureTask,status:'running',progress:'Sending the request approved',reviews:fixtureTask.reviews.map(r=>({...r,status:p.cancel?'cancelled':'answered',answeredBy:'user'}))};fixtureWorker.tasks=[fixtureTask];return {accepted:true};}
   return {};},
  signin:async p=>{calls.push(JSON.parse(JSON.stringify(p)));await new Promise(r=>setTimeout(r,20));
   if(p.action==='status')return {profiles:[{id:'wrds',name:'WRDS',saved:false}]};
   if(p.action==='sites')return {sites:[]};
   if(p.action==='services')return {services};
   if(p.action==='provideService'){if(typeof p.charges!=='boolean')throw Error('Say whether it can charge money.');services=services.filter(s=>s.name!==p.name).concat([{id:p.name.toLowerCase(),name:p.name,baseUrl:p.baseUrl,header:p.header,scheme:p.scheme,charges:p.charges,sends:p.header+': '+(p.scheme?p.scheme+' ':'')+'…',saved:true}]);return {saved:true,resumed:!!p.taskId,services};}
   if(p.action==='removeService'){services=services.filter(s=>s.id!==p.id);return {removed:true,services};}
   return {};}};
}
function people(){
 document.getElementById('onboarding-root').innerHTML='';closeModal();
 state.agents=[['forge','Forge']].map(([id,name])=>({id,name,role:'Engineer',description:'x',setupStatus:'ready',avatarShape:'star',avatarColor:'lilac',tools:{web:true,projectFiles:true}}));
 state.groups=[];state.messages={forge:[]};state.runs={};state.drafts={};state.attachments={};state.proposals=[];state.teamPlans=[];state.activitySeen={};state.activityDismissed={};state.hiddenAgents=[];state.onboarding={status:'completed',agentId:'forge'};
 navigate('chat','forge');
}
async function open(directory){
 const context=await chromium.launchPersistentContext(path.join(directory,'browser.noindex'),{channel:'chrome',headless:true,viewport:{width:1280,height:900},reducedMotion:'reduce'});
 await context.route('**/*',r=>/^https?:/.test(r.request().url())?r.abort():r.continue());
 await context.addInitScript(bridge);
 const page=context.pages()[0];const errors=[];page.on('pageerror',e=>errors.push(e.message));
 await page.goto(relay);await page.waitForFunction(()=>!!window.BuddySignIn&&!!window.BuddyWorkerUI&&!!window.BuddyServices);
 await page.evaluate(people);
 return {context,page,errors};
}
async function snapshot(page,value){await page.evaluate(v=>{Object.assign(fixtureWorker,v);},value);await page.evaluate(()=>BuddyWorkerUI.refresh(false));}
// Everywhere a typed value could end up on the page.
async function nowhere(page,needle){
 return page.evaluate(n=>{
  const places={dom:document.documentElement.outerHTML,fields:[...document.querySelectorAll('input,textarea')].map(i=>i.value).join('\n'),state:JSON.stringify(state),saved:saved.join('\n'),
   local:Object.keys(localStorage).map(k=>k+'='+localStorage.getItem(k)).join('\n'),session:Object.keys(sessionStorage).map(k=>k+'='+sessionStorage.getItem(k)).join('\n'),worker:JSON.stringify(ops)};
  return Object.entries(places).filter(([,text])=>text.includes(n)).map(([where])=>where);
 },needle);
}

test('the chat asks to connect RunPod: the address Forge suggested, Authorization: Bearer, whether it can charge money (the person must say), and the key, which goes only to the sign-in bridge',{skip,timeout:90000},async()=>{
 const directory=await mkdtemp(path.join(tmpdir(),'buddy-services-ui-'));let context;
 try{
  const opened=await open(directory);context=opened.context;const {page,errors}=opened;
  await snapshot(page,{tasks:[{id:'t1',agentId:'forge',title:'C1 replications',kind:'coding',status:'waiting_user',checkpoint:{need:'credential',profile:'service:runpod',secret:'service'},updatedAt:'2026-10-23T20:00:00Z'}],signinRequests:[connect]});
  const card=page.locator('.signin-message').last();await card.waitFor({timeout:8000});
  assert.match(await card.locator('.signin-title').innerText(),/^Connect RunPod$/);
  assert.match(await card.innerText(),/run the 800 C1 replications/);
  assert.equal(await card.getByLabel('API address').inputValue(),'https://rest.runpod.io/v2','the address the agent suggested, for the person to check');
  assert.equal(await card.getByLabel('How the key is sent').inputValue(),'Authorization');
  assert.equal(await card.locator('[data-service-charges]:checked').count(),0,'nothing is chosen for the person');
  // One tidy column (the user, 23 Oct: the fields were scattered down the right edge with tall gaps): the address and how the key is sent
  // side by side, the key under them across the form, then the money question, then the note and Connect; no header name with Bearer.
  const at=sel=>card.locator(sel).first().evaluate(e=>{const b=e.getBoundingClientRect();return {l:Math.round(b.left),t:Math.round(b.top),r:Math.round(b.right),h:Math.round(b.height)};});
  const address=await at('label:has([data-service-input="baseUrl"])'),how=await at('label:has([data-service-header])'),keyRow=await at('label:has([data-service-input="key"])'),money=await at('.service-charges'),send=await at('[data-signin-send]');
  assert.equal(await card.getByLabel('Header name').isVisible(),false,'no header name while Bearer is chosen');
  assert.ok(Math.abs(address.t-how.t)<2&&how.l>address.r,'the address and how the key is sent share a row');
  assert.ok(keyRow.t>address.t+address.h&&keyRow.l===address.l&&keyRow.r>=how.r-1,'the key has its own row, across the form');
  assert.ok(money.t>keyRow.t&&send.t>money.t,'then the money question, then Connect');
  assert.ok(address.h<80&&keyRow.h<80,`fields are as tall as their label and box (${address.h}, ${keyRow.h})`);
  assert.ok((await card.boundingBox()).height<560,'the whole card fits on screen');
  const key=card.getByLabel('API key');
  assert.equal(await key.evaluate(e=>e.type),'password','the key field is masked');
  await key.click();await page.keyboard.type(KEY);
  // The chat redraws while the person types: nothing typed is lost, and nothing reaches the page's state.
  await page.evaluate(()=>BuddyWorkerUI.refresh(false));
  assert.equal(await card.getByLabel('API key').inputValue(),KEY,'nothing typed is lost to a redraw');
  assert.deepEqual(await nowhere(page,KEY),['fields'],'while it is typed it is only in its field');
  await card.getByRole('button',{name:'Connect'}).click();
  await card.getByText('Say whether RunPod can charge you money.').waitFor();
  assert.equal(await page.evaluate(()=>calls.filter(c=>c.action==='provideService').length),0,'nothing is sent until the person says whether it can charge money');
  await card.getByLabel('Yes').check();
  await page.evaluate(()=>BuddyWorkerUI.refresh(false));
  assert.equal(await page.locator('.signin-message').last().locator('[data-service-charges]:checked').inputValue(),'yes','the choice survives a redraw');
  const connecting=page.locator('.signin-message').last();await connecting.getByRole('button',{name:'Connect'}).click();
  // Connected, the card leaves the chat and a toast says so once.
  await connecting.waitFor({state:'detached'});await page.locator('#toast').filter({hasText:'Connected — Forge is continuing.'}).waitFor();
  assert.deepEqual(await page.evaluate(()=>calls.filter(c=>c.action==='provideService')),[{action:'provideService',taskId:'t1',name:'RunPod',baseUrl:'https://rest.runpod.io/v2',header:'Authorization',scheme:'Bearer',key:KEY,charges:true}],'one call to the sign-in bridge, with the choices and the key');
  assert.deepEqual(await nowhere(page,KEY),[],'afterwards the key is nowhere on the page');
  assert.deepEqual(errors,[]);
 }finally{await context?.close();await rm(directory,{recursive:true,force:true});}
});

test('the request card: Forge wants to send a POST request to RunPod, with the exact request, the cost estimate, what Buddy deletes and when, what will be uploaded and why; Approve answers it once',{skip,timeout:90000},async()=>{
 const directory=await mkdtemp(path.join(tmpdir(),'buddy-services-ui-'));let context;
 try{
  const opened=await open(directory);context=opened.context;const {page,errors}=opened;
  await page.evaluate(r=>{fixtureTask={id:'t2',agentId:'forge',workspace:state.conversationWorkspace,kind:'coding',provider:'claude',title:'C1 replications',status:'waiting_review',attempt:1,progress:'Waiting for your OK for a request to RunPod: at most $7.68',attentionKey:r.id,updatedAt:'2026-10-23T20:00:00Z',result:'',reviews:[r]};fixtureWorker.tasks=[fixtureTask];},review);
  await page.evaluate(()=>BuddyWorkerUI.refresh(false));
  await page.locator('.reply-content').filter({hasText:'I need your OK for a request to RunPod: at most $7.68.'}).waitFor({timeout:8000});
  await page.getByRole('button',{name:'Review task'}).click();
  const card=page.locator('[data-worker-review="svc-1"]');await card.waitFor();
  const text=await card.innerText();
  assert.match(text,/Forge wants to send a POST request to RunPod\./);
  assert.match(text,/Why: Run the 800 C1 replications on 32 vCPUs instead of this Mac\./);
  for(const line of ['Request: POST https://rest.runpod.io/v2/pods','Cost (Forge’s estimate): $1.28 an hour, for at most 6 hours: at most $7.68','Cleanup: Buddy calls DELETE /pods/{id} when Forge is done, when the task ends, and after 6 hours at the latest','Uploads to it: stages/S02c_review (214 files, 3.4 MB)','RunPod can charge you money.'])
   assert.ok(text.includes(line),`the card says: ${line}`);
  assert.match(await card.locator('.worker-review-body').innerText(),/"vcpuCount" : 32/,'the exact body');
  assert.deepEqual(await card.locator('.worker-toolbar button').allInnerTexts(),['Disapprove','Approve']);
  await card.getByRole('button',{name:'Approve',exact:true}).dblclick();
  await page.waitForFunction(()=>ops.some(c=>c.operation==='review'));await page.waitForTimeout(400);
  assert.deepEqual(await page.evaluate(()=>ops.filter(c=>c.operation==='review')),[{operation:'review',taskId:'t2',id:'svc-1',answers:{operation:['Accept']},cancel:false,accept:true}],'one answer');
  assert.deepEqual(errors,[]);
 }finally{await context?.close();await rm(directory,{recursive:true,force:true});}
});

test('Settings › Browser sign-in lists connected services next to Saved sign-ins; Connect a service takes a custom key header and a No, and the key goes only to the bridge',{skip,timeout:90000},async()=>{
 const directory=await mkdtemp(path.join(tmpdir(),'buddy-services-ui-'));let context;
 try{
  const opened=await open(directory);context=opened.context;const {page,errors}=opened;
  await page.evaluate(()=>{services=[{id:'runpod',name:'RunPod',baseUrl:'https://rest.runpod.io/v2',header:'Authorization',scheme:'Bearer',charges:true,sends:'Authorization: Bearer …',saved:true}];});
  await page.evaluate(()=>BuddyWorkerUI.profiles());
  const section=page.locator('[data-connected-services]');await section.getByText('RunPod',{exact:true}).waitFor({timeout:8000});
  assert.match(await section.innerText(),/https:\/\/rest\.runpod\.io\/v2 · Can charge money: you approve each change · Authorization: Bearer …/);
  await section.getByRole('button',{name:'Connect a service'}).click();
  const form=section.locator('[data-service-form="new"]');await form.waitFor();
  await form.getByLabel('Service name').fill('Notes');await form.getByLabel('API address').fill('https://notes.example.com/v1');
  await form.getByLabel('How the key is sent').selectOption('custom');
  await form.getByLabel('Header name').fill('X-API-Key');await form.getByLabel('No').check();
  await form.getByLabel('API key').click();await page.keyboard.type(NOTES);
  await form.getByRole('button',{name:'Connect'}).click();
  await section.getByText('Connected Notes.').waitFor();
  assert.deepEqual(await page.evaluate(()=>calls.filter(c=>c.action==='provideService')),[{action:'provideService',name:'Notes',baseUrl:'https://notes.example.com/v1',header:'X-API-Key',scheme:'',key:NOTES,charges:false}]);
  assert.match(await section.innerText(),/Notes[\s\S]*Can’t charge money · X-API-Key: …/);
  assert.deepEqual(await nowhere(page,NOTES),[],'the key is nowhere on the page');
  await section.locator('[data-service-row="runpod"]').getByRole('button',{name:'Remove'}).click();
  await section.getByText(/Removed RunPod/).waitFor();
  assert.deepEqual(await page.evaluate(()=>calls.filter(c=>c.action==='removeService')),[{action:'removeService',id:'runpod'}]);
  assert.deepEqual(errors,[]);
 }finally{await context?.close();await rm(directory,{recursive:true,force:true});}
});

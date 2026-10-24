import test from 'node:test';
import assert from 'node:assert/strict';
import {chromium} from 'playwright-core';
import {mkdtemp,rm} from 'node:fs/promises';
import {existsSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';

const skip=process.platform!=='darwin'||!existsSync('/Applications/Google Chrome.app');
const relay=new URL('../../relay/index.html',import.meta.url).href;

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
// Continuing a background task from its page sends exactly what the instructions box holds, however it got there: a paste tool, dictation
// or the Edit menu can fill the box without the page seeing an input event, and Continue used to send its fallback line instead (23 Oct:
// Forge's two-pod switch was lost twice that way).
test('Continue coding sends what the box holds, even when it was filled without an input event',{skip,timeout:90000},async()=>{
 const directory=await mkdtemp(path.join(tmpdir(),'buddy-continue-ui-'));let context;
 try{
  const opened=await open(directory);context=opened.context;const {page,errors}=opened;
  const t={id:'t1',agentId:'forge',title:'Execute approved S02c review additions',kind:'coding',provider:'chatgpt',status:'paused',blockedBy:'remote',stopCause:'remote.running',attempt:9,
   progress:'Running on 203.0.113.7 for 1 h 14 min · 183 result files there · Buddy continues when it ends',updatedAt:new Date().toISOString(),reviews:[]};
  await page.evaluate(t=>{fixtureTask=t;fixtureWorker.tasks=[t];},t);
  await page.evaluate(()=>BuddyWorkerUI.open());
  await page.locator('[data-worker-task="t1"]').first().click({timeout:10000});
  const box=page.locator('[data-worker-update]');await box.waitFor({timeout:8000});
  // Filled as a paste tool would: the value changes, no input event fires.
  await box.evaluate(e=>{e.value='Switch C1 to two cpu5c pods with --shard 1/2 and 2/2.';});
  await page.getByRole('button',{name:'Continue coding'}).click();
  await page.waitForFunction(()=>ops.some(o=>o.operation==='coding'),null,{timeout:8000});
  const sent=await page.evaluate(()=>ops.filter(o=>o.operation==='coding'));
  assert.deepEqual(sent,[{operation:'coding',agentId:'forge',arguments:{action:'continue',taskId:'t1',goal:'Switch C1 to two cpu5c pods with --shard 1/2 and 2/2.'}}],'the instructions in the box are what Forge gets');
  assert.deepEqual(errors,[]);
 }finally{await context?.close();await rm(directory,{recursive:true,force:true});}
});

import test from 'node:test';import assert from 'node:assert/strict';import {chromium} from 'playwright-core';import {mkdtemp,rm} from 'node:fs/promises';import {tmpdir} from 'node:os';import {join} from 'node:path';
test('a reply that finishes while an agent is being created is kept, and every save goes through one ordered queue',{timeout:60000},async()=>{
 const dir=await mkdtemp(join(tmpdir(),'buddy-adopt-ui-'));let context;
 try{
  context=await chromium.launchPersistentContext(dir,{channel:'chrome',headless:true,viewport:{width:1200,height:800}});const page=context.pages()[0];
  await page.goto(new URL('../../relay/index.html',import.meta.url).href);await page.waitForFunction(()=>!!window.BuddyChat&&!!window.BuddyFigures);
  await page.evaluate(()=>{
   document.getElementById('onboarding-root').innerHTML='';closeModal();
   state.agents=[{id:'a',name:'Atlas',role:'Researcher',description:'Find things.',avatarShape:'sphere',avatarColor:'blue',setupStatus:'ready',tools:{}}];state.groups=[];state.tasks=[];state.files=[];
   state.messages={a:[]};state.drafts={a:'find three sources'};state.attachments={};state.runs={};state.onboarding={status:'completed',agentId:'a'};ui.view={kind:'chat',target:'a'};
   window.saved=[];window.inFlight=0;window.maxInFlight=0;
   // A slow native save: the window in which events used to be lost.
   BuddyDesktop={saveState:async json=>{inFlight++;maxInFlight=Math.max(maxInFlight,inFlight);await new Promise(r=>setTimeout(r,300));saved.push(JSON.parse(json));inFlight--;return {saved:true};},sendMessage:async()=>{},agentSetup:async()=>({})};
   render();
   const {run}=BuddyChat.begin(state,'a');window.runId=run.runId;window.runKey=run.key;
   BuddyChat.apply(state,{runId:run.runId,key:run.key,status:'answering',text:'partial'});
  });
  await page.evaluate(()=>{newAgent();document.getElementById('agent-name').value='Sage';});
  // Submit, then let the reply finish while the save is still in flight.
  await page.evaluate(()=>{document.getElementById('agent-form').requestSubmit();});
  await page.waitForTimeout(80);
  await page.evaluate(()=>{state.agents.find(a=>a.id==='a').learnedRules=['Prefers short answers.'];});   // a live edit to an existing agent during the save
  await page.evaluate(()=>window.dispatchEvent(new CustomEvent('buddy-conversation',{detail:{type:'run',runId,key:runKey,status:'completed',text:'final answer'}})));
  await page.waitForTimeout(1800);
  const out=await page.evaluate(()=>({status:state.runs[runId].status,body:state.messages.a.at(-1).body,agents:state.agents.map(a=>a.name),rules:state.agents.find(a=>a.id==='a').learnedRules,busy:!!BuddyChat.active(state,'a'),last:saved.at(-1)&&{status:saved.at(-1).runs[runId].status,agents:saved.at(-1).agents.map(a=>a.name),body:saved.at(-1).messages.a.at(-1).body},maxInFlight}));
  assert.equal(out.status,'completed','the finished run is not undone');assert.equal(out.body,'final answer');assert.equal(out.busy,false,'the chat is not stuck busy');
  assert.deepEqual(out.agents,['Atlas','Sage'],'the new agent is added');assert.deepEqual(out.rules,['Prefers short answers.'],'an edit made to another agent during the save is kept');
  assert.deepEqual(out.last,{status:'completed',agents:['Atlas','Sage'],body:'final answer'},'the last thing saved has both the finished reply and the new agent');
  assert.equal(out.maxInFlight,1,'saves never overlap, so an older snapshot cannot land after a newer one');
 }finally{await context?.close();await rm(dir,{recursive:true,force:true});}
});

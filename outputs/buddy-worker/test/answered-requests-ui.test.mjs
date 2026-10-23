import test from 'node:test';import assert from 'node:assert/strict';import {chromium} from 'playwright-core';import {mkdtemp,rm} from 'node:fs/promises';import {existsSync} from 'node:fs';import {tmpdir} from 'node:os';import {join} from 'node:path';
// The user, 23 Oct: "whenever it needs my approval or small input, it should then disappear not stay". A request in the chat stays only while
// it waits on the person: answered (by them or by Chief), or once its task has moved on, it leaves; a toast says what came of their own tap.
const skip=process.platform!=='darwin'||!existsSync('/Applications/Google Chrome.app');
async function open(dir){
 const context=await chromium.launchPersistentContext(join(dir,'browser.noindex'),{channel:'chrome',headless:true,viewport:{width:1280,height:860},reducedMotion:'reduce'});
 await context.route('**/*',r=>/^https?:/.test(r.request().url())?r.abort():r.continue());
 const page=context.pages()[0];const errors=[];page.on('pageerror',e=>errors.push(e.message));
 await page.goto(new URL('../../relay/index.html',import.meta.url).href);await page.waitForFunction(()=>!!window.BuddyWorkerUI&&!!window.BuddyActions);
 await page.evaluate(()=>{
  document.getElementById('onboarding-root').innerHTML='';closeModal();
  state.agents=[{id:'forge',name:'Forge',role:'Builder',avatarShape:'cube',avatarColor:'blue',setupStatus:'ready',tools:{}},{id:'chief',name:'Chief',role:'Chief of staff',avatarShape:'star',avatarColor:'lilac',setupStatus:'ready',tools:{}}];
  state.groups=[];state.onboarding={status:'completed',agentId:'forge'};state.runs={};state.drafts={};state.attachments={};state.proposals=[];state.teamPlans=[];state.toolInputs={};
  state.messages={forge:[],chief:[]};
  const base={workspace:state.conversationWorkspace,agentId:'forge',title:'Execute S02c',kind:'coding',attempt:1,updatedAt:'2026-10-23T21:30:00Z'};
  const review={id:'net',kind:'coding',status:'pending',tool:{name:'Run command',arguments:{command:'curl -sSf https://api.runpod.io/graphql'}},questions:[{id:'command',question:'Allow this command?',options:[{label:'Accept'},{label:'Decline'}]}]};
  window.tasks={
   approval:{...base,id:'approval',status:'waiting_review',attentionKey:'net',reviews:[review]},
   asks:{...base,id:'asks',status:'waiting_user',progress:'Which RunPod account should I use?',attentionKey:'Which RunPod account should I use?'},
   cancelled:{...base,id:'cancelled',status:'waiting_user',progress:'Working on your request',attentionKey:'Working on your request'},
  };
  for(const t of Object.values(tasks))BuddyWorkerUI.deliverResult(state,t);
  // A question saved before Buddy knew it was for Chief: "I need a detail from you to continue." while the task waits on Chief.
  state.messages.forge.push({id:'worker-chief-q-1-waiting_user-x',who:'forge',body:'Waiting for Chief: What RunPod provisioning path can this task use? The exposed tools are not enough for a long question like this one, which runs past the length a card shows.',time:'14:30',live:true,status:'completed',workerTaskID:'chief-q',workerStatus:'waiting_user',workerAttempt:1});
  window.live=[{...tasks.approval},{...tasks.asks},{...tasks.cancelled,status:'cancelled'},{...base,id:'chief-q',status:'waiting_user',stopCause:'checkpoint.supervisor',progress:'Waiting for Chief: What RunPod provisioning path can this task use?'}].map(t=>{const {reviews,...rest}=t;return rest;});
  window.answers=[];
  window.BuddyDesktop={saveState:async()=>({saved:true}),
   worker:async p=>p.operation==='status'||p.operation==='start'?{workspace:state.conversationWorkspace,online:true,paused:false,tasks:structuredClone(live),routines:[],decisions:[],notifications:{},plans:[],pulse:{agents:{}}}:p.operation==='notify'?{notifications:{}}:p.operation==='detail'?{task:structuredClone(tasks[p.taskId]||live.find(t=>t.id===p.taskId)||null)}:{},
   answerToolInput:async p=>{answers.push(p);const r=state.toolInputs[p.id];return {accepted:true,request:{...r,status:p.cancel?'declined':'answered'}};}};
  navigate('chat','forge');
 });
 await page.evaluate(()=>BuddyWorkerUI.refresh(false));
 return {context,page,errors};
}
const shown=page=>page.evaluate(()=>[...document.querySelectorAll('#messages > [data-chat-item]')].map(e=>e.dataset.chatItem.replace(/^worker-([^-]+)-.*/,'$1')));

test('a task’s request is in the chat only while it waits on the person: answered, moved on, or Chief’s to answer, it leaves',{skip,timeout:60000},async()=>{
 const dir=await mkdtemp(join(tmpdir(),'buddy-answered-'));let context;
 try{
  const opened=await open(dir);context=opened.context;const {page,errors}=opened;
  await page.waitForFunction(()=>document.querySelectorAll('#messages > [data-chat-item]').length>0);
  assert.deepEqual(await shown(page),['approval','asks'],'the approval and the question that wait on the person; not the cancelled run’s, nor the one for Chief');
  assert.doesNotMatch(await page.locator('#messages').innerText(),/I need a detail from you to continue|Working on your request/);
  // The approval is answered (on the task's page, or by Chief): it leaves the chat; the message keeps what was decided.
  await page.evaluate(()=>{BuddyWorkerUI.recordDecision(state,'approval',{reviewId:'net',title:'Run a command that uses the internet',verdict:'approved',by:'user'});refreshLiveChat('forge');});
  assert.deepEqual(await shown(page),['asks']);
  assert.equal(await page.evaluate(()=>state.messages.forge.find(m=>m.workerTaskID==='approval').body),'Run a command that uses the internet — approved');
  // The question is answered and the task runs again: the next poll takes it away, without anything else redrawing the chat.
  await page.evaluate(()=>{live.find(t=>t.id==='asks').status='running';});
  await page.evaluate(()=>BuddyWorkerUI.refresh(false));
  await page.waitForFunction(()=>!document.querySelector('#messages > [data-chat-item]'));
  assert.deepEqual(await shown(page),[]);
  // The chat list does not quote what has left the chat.
  await page.evaluate(()=>repaintChatList());
  const line=await page.locator('.chat-row[data-id="forge"] .chat-snippet').innerText();
  assert.doesNotMatch(line,/RunPod|need a detail|Working on your request|approved/,`the Forge row reads ${line}`);
  assert.deepEqual(errors,[]);
 }finally{await context?.close();await rm(dir,{recursive:true,force:true});}
});

test('an approval in a reply leaves once answered, a toast says so; one that failed stays',{skip,timeout:60000},async()=>{
 const dir=await mkdtemp(join(tmpdir(),'buddy-answered-'));let context;
 try{
  const opened=await open(dir);context=opened.context;const {page,errors}=opened;
  await page.evaluate(()=>{
   state.messages.forge=[];state.runs.r1={runId:'r1',key:'forge',target:'forge',status:'answering',agentId:'forge'};
   state.messages.forge.push({id:'reply-1',who:'forge',body:'I’ll send the summary.',time:'14:31',live:true,runId:'r1',status:'answering'});
   const ask=(id,status)=>({id,native:true,workspace:state.conversationWorkspace,runId:'r1',agentId:'forge',agentName:'Forge',status,tool:{name:'send_email',service:'Gmail'},questions:[{id:'q',question:'Send this email?',options:[{label:'Accept'}]}]});
   state.toolInputs={send:ask('send','pending')};refreshLiveChat('forge');
  });
  const card=page.locator('[data-tool-input="send"]');await card.waitFor();
  await card.getByRole('button',{name:'Send email'}).click();
  await card.waitFor({state:'detached'});await page.locator('#toast').filter({hasText:'Sent — Forge is continuing.'}).waitFor();
  assert.deepEqual(await page.evaluate(()=>answers.map(a=>a.id)),['send'],'answered once');
  assert.equal(await page.locator('#messages').innerText().then(t=>/Review submitted|Action completed/.test(t)),false,'no receipt left in the reply');
  // An action that could not finish still needs a look: it stays.
  await page.evaluate(()=>{state.toolInputs.send.status='failed';refreshLiveChat('forge');});
  await page.locator('[data-tool-input="send"]').getByText('Action could not finish').waitFor();
  assert.deepEqual(errors,[]);
 }finally{await context?.close();await rm(dir,{recursive:true,force:true});}
});

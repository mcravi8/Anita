import test from 'node:test';import assert from 'node:assert/strict';import {chromium} from 'playwright-core';import {mkdtemp,rm} from 'node:fs/promises';import {existsSync} from 'node:fs';import {tmpdir} from 'node:os';import {join} from 'node:path';
// Moving between Chat · Plan · Files slides the views in that order, and the selector under the tabs glides to the one chosen; nothing is drawn
// again: each view keeps what was typed, and the plan and files keep their place. Back in the chat, it shows its latest messages (the user,
// 23 Oct: land at the latest messages from anywhere, the plan included), already there as it slides in.
const skip=process.platform!=='darwin'||!existsSync('/Applications/Google Chrome.app');
async function open(dir,reducedMotion){
 const context=await chromium.launchPersistentContext(join(dir,'browser.noindex'),{channel:'chrome',headless:true,viewport:{width:1280,height:860},reducedMotion});
 await context.route('**/*',r=>/^https?:/.test(r.request().url())?r.abort():r.continue());
 const page=context.pages()[0];const errors=[];page.on('pageerror',e=>errors.push(e.message));
 await page.goto(new URL('../../relay/index.html',import.meta.url).href);await page.waitForFunction(()=>!!window.BuddyWorkerUI&&!!window.BuddyProjectDock&&!!window.BuddyFiles);
 await page.evaluate(()=>{
  document.getElementById('onboarding-root').innerHTML='';closeModal();
  state.agents=[{id:'chief',name:'Chief',role:'Chief of staff',avatarShape:'star',avatarColor:'lilac',setupStatus:'ready',tools:{projectFiles:true}},{id:'forge',name:'Forge',role:'Builder',avatarShape:'cube',avatarColor:'blue',setupStatus:'ready',tools:{projectFiles:true}}];
  state.groups=[{id:'team',name:'Omori team',members:['chief','forge'],objective:'EE590 report',managedBy:'chief',createdAt:'2026-10-19T09:00:00Z'}];
  state.onboarding={status:'completed',agentId:'chief'};state.runs={};state.drafts={};state.attachments={};state.proposals=[];state.teamPlans=[];
  state.messages={team:Array.from({length:30},(_,i)=>({id:'u'+i,who:'you',body:'Message number '+i+'. '.repeat(4),time:'10:'+String(i).padStart(2,'0')})),chief:[],forge:[]};
  const plan={id:'p1',groupId:'team',objective:'EE590 report',supervisorId:'chief',status:'draft',revision:1,scope:null,notices:[],run:{state:'draft',working:[],needsYou:0,idleSince:null},
   stages:[{id:'s1',n:1,title:'S01 Protocol freeze',goal:'Freeze the protocol',acceptance:['spec_v1.sha256 saved'],status:'proposed',tasks:[]},{id:'s2',n:2,title:'S02a Pooled relaxation',goal:'Pooled analysis',acceptance:['Timing 3 of 3'],status:'proposed',tasks:[]}]};
  const folder={folderId:'research',name:'Directed Research',location:'/Users/example/Research',primary:true,available:true,folders:[],files:[{path:'stages/S01_protocol/spec_v1.sha256',bytes:80}],directories:[]};
  window.BuddyDesktop={saveState:async()=>({saved:true}),worker:async p=>p.operation==='status'||p.operation==='start'?{workspace:state.conversationWorkspace,online:true,paused:false,tasks:[],routines:[],decisions:[],notifications:{},plans:[plan],pulse:{agents:{}}}:p.operation==='notify'?{notifications:{}}:{task:null},
   projectFiles:async()=>structuredClone(folder),previewProjectFile:async p=>({path:p.path,folderId:p.folderId,format:'text',content:'x',version:'v1',editable:false}),projectFileVersion:async()=>({version:'v1'})};
  navigate('chat','team');
 });
 await page.evaluate(()=>BuddyWorkerUI.refresh(false));
 await page.locator('[data-chat-views] [data-chat-view="files"]').waitFor({timeout:8000});
 return {context,page,errors};
}
// Where an element is drawn across, from its transform (0 when it is not moving).
const shiftOf=(page,selector)=>page.locator(selector).first().evaluate(e=>{const t=getComputedStyle(e).transform;return t==='none'?0:new DOMMatrixReadOnly(t).m41;});
const fromEnd=page=>page.evaluate(()=>{const b=document.getElementById('chat-body');return b.scrollHeight-b.scrollTop-b.clientHeight;});
const state=page=>page.evaluate(()=>{const c=document.querySelector('.content-layout > .conversation'),thumb=document.querySelector('.chat-views-thumb'),tab=v=>document.querySelector(`[data-chat-view="${v}"][role="tab"]`);
 return {shown:c.dataset.viewShown,sliding:'viewSliding' in c.dataset,chat:getComputedStyle(document.getElementById('chat-body')).visibility,thumb:new DOMMatrixReadOnly(getComputedStyle(thumb).transform).m41,tabs:Object.fromEntries(['chat','plan','files'].map(v=>[v,tab(v).offsetLeft]))};});

test('Chat → Plan slides the chat out to the left and the plan in from the right; Files → Chat slides the other way; the selector glides',{skip,timeout:90000},async()=>{
 const dir=await mkdtemp(join(tmpdir(),'buddy-views-motion-'));let context;
 try{
  const opened=await open(dir,'no-preference');context=opened.context;const {page,errors}=opened;
  await page.locator('#message-input').fill('Half a sentence');
  // The chat goes to its latest message as it opens; scroll up once it has, to see it come back to them.
  await page.waitForTimeout(600);await page.evaluate(()=>{document.getElementById('chat-body').scrollTop=200;});
  await page.waitForTimeout(300);assert.equal(await page.evaluate(()=>document.getElementById('chat-body').scrollTop),200);
  // Chat → Plan
  await page.locator('[data-chat-view="plan"][role="tab"]').click();
  await page.waitForTimeout(120);
  const mid=await state(page),chatShift=await shiftOf(page,'#chat-body'),planShift=await shiftOf(page,'[data-chat-pane="plan"]');
  assert.equal(mid.sliding,true,'both views show while they move');assert.equal(mid.chat,'visible');
  assert.ok(chatShift<0,`the chat leaves to the left (${chatShift})`);assert.ok(planShift>0,`the plan comes in from the right (${planShift})`);
  assert.ok(mid.thumb>mid.tabs.chat&&mid.thumb<mid.tabs.plan,`the selector is on its way from Chat to Plan (${mid.thumb})`);
  await page.waitForTimeout(600);
  const end=await state(page);
  assert.equal(end.shown,'plan');assert.equal(end.sliding,false);assert.equal(end.chat,'hidden','the chat is out of sight, not gone');
  assert.equal(await shiftOf(page,'[data-chat-pane="plan"]'),0);assert.ok(Math.abs(end.thumb-end.tabs.plan)<1,'the selector rests under Plan');
  await page.evaluate(()=>{document.querySelector('[data-chat-pane="plan"]').__kept=true;});
  // Plan → Files: still to the right.
  await page.locator('[data-chat-view="files"][role="tab"]').click();await page.waitForTimeout(120);
  assert.ok(await shiftOf(page,'[data-chat-pane="plan"]')<0&&await shiftOf(page,'[data-chat-pane="files"]')>0,'further right: the plan leaves to the left, the files come from the right');
  await page.waitForTimeout(600);
  // Files → Chat: straight there, the other way.
  await page.locator('[data-chat-view="chat"][role="tab"]').click();await page.waitForTimeout(120);
  const back=await state(page),filesShift=await shiftOf(page,'[data-chat-pane="files"]'),chatBack=await shiftOf(page,'#chat-body');
  assert.ok(filesShift>0,`the files leave to the right (${filesShift})`);assert.ok(chatBack<0,`the chat comes in from the left (${chatBack})`);
  assert.ok(await fromEnd(page)<4,'the chat comes in at its latest messages');
  assert.equal(await page.locator('[data-chat-pane="plan"]').isVisible(),false,'straight to the chat, not past the plan');
  assert.ok(back.thumb<back.tabs.files&&back.thumb>back.tabs.chat,'the selector glides back');
  await page.waitForTimeout(600);
  // Nothing was drawn again.
  assert.equal(await page.locator('#message-input').inputValue(),'Half a sentence','what was typed is still there');
  assert.ok(await fromEnd(page)<4,'the chat rests at its latest messages');
  assert.equal(await page.evaluate(()=>document.querySelector('[data-chat-pane="plan"]').__kept),true,'the plan view is the same one');
  assert.equal(await page.locator('.composer-wrap > .stage-strip').count(),1,'the plan’s line above the composer is there');
  // Quick taps: each ends where it was asked to.
  for(const v of ['plan','files','chat','files'])await page.locator(`[data-chat-view="${v}"][role="tab"]`).click();
  await page.waitForTimeout(700);
  const last=await state(page);assert.equal(last.shown,'files');assert.equal(last.sliding,false);assert.equal(await page.locator('[data-chat-pane]:not([hidden])').count(),1,'one view at rest');
  assert.deepEqual(errors,[]);
 }finally{await context?.close();await rm(dir,{recursive:true,force:true});}
});

test('anyone who asks for less motion moves between the views at once',{skip,timeout:60000},async()=>{
 const dir=await mkdtemp(join(tmpdir(),'buddy-views-motion-'));let context;
 try{
  const opened=await open(dir,'reduce');context=opened.context;const {page,errors}=opened;
  await page.locator('[data-chat-view="plan"][role="tab"]').click();
  const now=await state(page);
  assert.equal(now.shown,'plan');assert.equal(now.sliding,false);assert.equal(now.chat,'hidden');
  assert.equal(await page.evaluate(()=>document.getAnimations().filter(a=>a.playState==='running').length),0,'nothing moves');
  assert.deepEqual(errors,[]);
 }finally{await context?.close();await rm(dir,{recursive:true,force:true});}
});

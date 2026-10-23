import test from 'node:test';import assert from 'node:assert/strict';import {chromium} from 'playwright-core';import {mkdtemp,rm} from 'node:fs/promises';import {existsSync} from 'node:fs';import {tmpdir} from 'node:os';import {join} from 'node:path';

// The user's S04a question from Chief: its notification said Answer but opened the background task, which has nowhere to answer, and the plan
// view's "See what needs you" opened the notifications again. Both now open the team chat at the question's card, ready to answer.
test('a question Chief forwarded is reached in one step from its notification and from the plan view: the team chat opens at its card',{skip:process.platform!=='darwin'||!existsSync('/Applications/Google Chrome.app'),timeout:60000},async()=>{
 const dir=await mkdtemp(join(tmpdir(),'buddy-answer-link-'));let context;
 try{
  context=await chromium.launchPersistentContext(join(dir,'browser.noindex'),{channel:'chrome',headless:true,viewport:{width:1280,height:900},reducedMotion:'reduce'});
  await context.route('**/*',r=>/^https?:/.test(r.request().url())?r.abort():r.continue());
  const page=context.pages()[0];const errors=[];page.on('pageerror',e=>errors.push(e.message));
  await page.goto(new URL('../../relay/index.html',import.meta.url).href);await page.waitForFunction(()=>!!window.BuddyWorkerUI&&!!window.BuddyPlan);
  await page.evaluate(()=>{
   document.getElementById('onboarding-root').innerHTML='';closeModal();
   state.agents=[{id:'chief',name:'Chief',role:'Chief of staff',avatarShape:'star',avatarColor:'lilac',setupStatus:'ready',tools:{}},{id:'vera',name:'Vera',role:'Reviewer',avatarShape:'cube',avatarColor:'green',setupStatus:'ready',tools:{}}];
   state.groups=[{id:'team',name:'Omori team',members:['chief','vera'],objective:'EE590 report',managedBy:'chief',createdAt:'2026-10-19T09:00:00Z'}];
   state.onboarding={status:'completed',agentId:'chief'};state.proposals=[];state.teamPlans=[];state.runs={};state.drafts={team:''};state.attachments={};
   // A long chat, so the card is not on screen when the chat opens.
   state.messages={team:Array.from({length:40},(_,n)=>({id:'m'+n,role:n%2?'assistant':'user',agentId:n%2?'chief':undefined,text:'Earlier message '+n+'. '.repeat(20),createdAt:'2026-10-23T0'+(n%9)+':00:00Z'})),chief:[],vera:[]};
   ui.view={kind:'chat',target:'chief'};ui.lastChat='chief';
   const question='May we change the November 12 restriction to finish S04a now using the verified partial S02b results?';
   window.plan={id:'p1',groupId:'team',objective:'EE590 report',supervisorId:'chief',status:'active',revision:3,scope:{through:4,quote:'Get stage 4 done',at:'2026-10-23T09:00:00Z',status:'active'},
    stages:[{id:'s1',n:1,title:'S01 Protocol freeze',goal:'Freeze the protocol',acceptance:['spec_v1.sha256 saved'],status:'done',tasks:[]},{id:'s4',n:2,title:'S04a Report',goal:'Write the report',acceptance:['Report saved'],status:'working',tasks:[]}],
    notices:[{id:'e1',kind:'escalation',text:question+' My recommendation: Approve using the verified partial S02b findings.',chat:true,status:'open',at:'2026-10-23T16:55:18Z',refs:{question,recommendation:'Approve using the verified partial S02b findings',category:'objective'}}],
    run:{state:'needs_you',working:[],needsYou:1,idleSince:null}};
   const decision={id:'escalation:run:waiting:task:1',kind:'escalation',status:'open',audience:'user',agentId:'chief',title:'Chief needs your decision',question,label:'Answer',actionLabel:'Answer',taskId:'task',createdAt:'2026-10-23T16:55:18Z',payload:{noticeId:'e1',planId:'p1',category:'objective',taskId:'task'}};
   const status=()=>({workspace:state.conversationWorkspace,online:true,paused:false,tasks:[],routines:[],decisions:[decision],notifications:{},plans:[structuredClone(plan)],pulse:{agents:{}},supervisorLane:{online:true,busy:false}});
   window.BuddyDesktop={saveState:async()=>({saved:true}),worker:async p=>{
    if(['status','start'].includes(p.operation))return status();
    if(p.operation==='notify')return {notifications:{}};if(p.operation==='detail')return {task:null};
    throw Error('Unexpected fixture operation '+p.operation);}};
   render();
  });
  await page.evaluate(()=>BuddyWorkerUI.refresh(false));
  const atCard=async how=>{
   await page.waitForFunction(()=>document.activeElement?.closest?.('[data-chat-item="plan-notice-e1"]')&&document.activeElement.textContent==='Approve',null,{timeout:8000});
   const where=await page.evaluate(()=>{const card=document.querySelector('[data-chat-item="plan-notice-e1"] .plan-card-decision').getBoundingClientRect();
    return {target:ui.view?.target,chatShown:!!document.querySelector('[data-chat-views] [data-chat-view="chat"][aria-selected="true"]')||!document.querySelector('[data-chat-views]'),onScreen:card.top>=0&&card.bottom<=innerHeight,drawer:!!document.querySelector('.modal-overlay')};});
   assert.deepEqual(where,{target:'team',chatShown:true,onScreen:true,drawer:false},how+' opens the team chat at the card, with Approve ready');
  };
  // From the notification.
  await page.locator('[data-activity-open]').first().click();
  const item=page.locator('.activity-item',{hasText:'Chief needs your decision'});await item.waitFor({timeout:8000});
  assert.match(await item.innerText(),/Answer in chat/);
  await item.click();await atCard('the notification');
  // From the plan view of the team chat.
  await page.evaluate(()=>{document.querySelector('#messages')?.scrollTo(0,0);BuddyProjectDock.show('plan');});
  const button=page.getByRole('button',{name:'Answer in chat',exact:true});await button.waitFor({timeout:8000});
  await button.click();await atCard('the plan view');
  assert.deepEqual(errors,[]);
 }finally{await context?.close();await rm(dir,{recursive:true,force:true});}
});

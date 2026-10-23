import test from 'node:test';import assert from 'node:assert/strict';import {chromium} from 'playwright-core';import {mkdtemp,rm} from 'node:fs/promises';import {existsSync} from 'node:fs';import {tmpdir} from 'node:os';import {join} from 'node:path';

// The user, 23 Oct: "when I get to a chat from anywhere (home, plan, etc.) always land at the bottom of the chat, at the latest messages".
// A chat was drawn from its top, and coming back from its Plan view showed it from the top too (a hidden chat loses its place).
test('arriving at a chat from anywhere shows its latest messages; a chat drawn again while open keeps the person’s place',{skip:process.platform!=='darwin'||!existsSync('/Applications/Google Chrome.app'),timeout:60000},async()=>{
 const dir=await mkdtemp(join(tmpdir(),'buddy-chat-landing-'));let context;
 try{
  context=await chromium.launchPersistentContext(join(dir,'browser.noindex'),{channel:'chrome',headless:true,viewport:{width:1280,height:900},reducedMotion:'reduce'});
  await context.route('**/*',r=>/^https?:/.test(r.request().url())?r.abort():r.continue());
  const page=context.pages()[0];const errors=[];page.on('pageerror',e=>errors.push(e.message));
  await page.goto(new URL('../../relay/index.html',import.meta.url).href);await page.waitForFunction(()=>!!window.BuddyWorkerUI&&!!window.BuddyPlan&&!!window.BuddyProjectDock);
  await page.evaluate(()=>{
   document.getElementById('onboarding-root').innerHTML='';closeModal();
   state.agents=[{id:'chief',name:'Chief',role:'Chief of staff',avatarShape:'star',avatarColor:'lilac',setupStatus:'ready',tools:{}},{id:'vera',name:'Vera',role:'Reviewer',avatarShape:'cube',avatarColor:'green',setupStatus:'ready',tools:{}}];
   state.groups=[{id:'team',name:'Omori team',members:['chief','vera'],objective:'EE590 report',managedBy:'chief',createdAt:'2026-10-19T09:00:00Z'}];
   state.onboarding={status:'completed',agentId:'chief'};state.proposals=[];state.teamPlans=[];state.runs={};state.drafts={};state.attachments={};
   const long=(who,n)=>Array.from({length:n},(_,i)=>({id:who+i,who:i%2?who:'you',text:`Message ${i} in ${who}. `+'Some longer words to fill the line. '.repeat(6),time:'09:00',createdAt:new Date(Date.UTC(2026,9,23,8,i)).toISOString()}));
   state.messages={team:long('chief',60),vera:long('vera',60),chief:[]};
   ui.view={kind:'chat',target:'team'};ui.lastChat='team';
   window.plan={id:'p1',groupId:'team',objective:'EE590 report',supervisorId:'chief',status:'active',revision:1,scope:{through:1,quote:'Get stage 1 done',at:'2026-10-23T09:00:00Z',status:'active'},
    stages:[{id:'s1',n:1,title:'S01 Protocol freeze',goal:'Freeze the protocol',acceptance:['spec saved'],status:'working',tasks:[]}],notices:[],run:{state:'working',working:[],needsYou:0,idleSince:null}};
   const status=()=>({workspace:state.conversationWorkspace,online:true,paused:false,tasks:[],routines:[],decisions:[],notifications:{},plans:[structuredClone(plan)],pulse:{agents:{}},supervisorLane:{online:true,busy:false}});
   window.BuddyDesktop={saveState:async()=>({saved:true}),worker:async p=>{if(['status','start'].includes(p.operation))return status();if(p.operation==='notify')return {notifications:{}};if(p.operation==='detail')return {task:null};throw Error('Unexpected fixture operation '+p.operation);}};
   render();
  });
  await page.evaluate(()=>BuddyWorkerUI.refresh(false));
  const where=()=>page.evaluate(()=>{const b=document.getElementById('chat-body');const shown=document.querySelector('.content-layout > .conversation')?.dataset.viewShown||'chat';
   return {target:ui.view.target,shown,top:Math.round(b?.scrollTop||0),fromEnd:b?Math.round(b.scrollHeight-b.scrollTop-b.clientHeight):-1,visible:!!b&&b.offsetParent!==null};});
  const atEnd=async(how,target)=>{await page.waitForFunction(t=>{const b=document.getElementById('chat-body');return ui.view.target===t&&b&&b.offsetParent!==null&&b.scrollHeight-b.scrollTop-b.clientHeight<4;},target,{timeout:5000}).catch(()=>{});
   const w=await where();assert.ok(w.target===target&&w.shown==='chat'&&w.visible&&w.fromEnd<4,`${how}: the latest messages of ${target} show (${JSON.stringify(w)})`);
   await page.waitForTimeout(250);};   // the second look at the end (150 ms) has passed before the person scrolls
  await atEnd('opening Buddy on a chat','team');
  // From another chat.
  await page.evaluate(()=>{document.getElementById('chat-body').scrollTop=0;});
  await page.locator('.chat-row[data-id="vera"]').click();await atEnd('another chat','vera');
  // The same chat drawn again keeps the person's place.
  await page.evaluate(()=>{const b=document.getElementById('chat-body');b.scrollTop=Math.round(b.scrollHeight/3);});await page.waitForTimeout(100);
  const before=(await where()).top;await page.evaluate(()=>render());await page.waitForTimeout(100);
  const after=await where();assert.ok(Math.abs(after.top-before)<=2&&after.fromEnd>100,`a redraw keeps the place (${before} → ${JSON.stringify(after)})`);
  // Back to the team chat, then its Plan view and back to the chat.
  await page.locator('.chat-row[data-id="team"]').click();await atEnd('back to a chat','team');
  await page.evaluate(()=>{document.getElementById('chat-body').scrollTop=0;});
  await page.locator('[data-chat-views] [data-chat-view="plan"]').click();await page.waitForFunction(()=>document.querySelector('.content-layout > .conversation')?.dataset.viewShown==='plan');
  await page.locator('[data-chat-views] [data-chat-view="chat"]').click();await atEnd('back from the Plan view','team');
  // From another page, with the Plan view shown last: the chat's messages show, at the end.
  await page.locator('[data-chat-views] [data-chat-view="plan"]').click();await page.waitForFunction(()=>document.querySelector('.content-layout > .conversation')?.dataset.viewShown==='plan');
  await page.evaluate(()=>navigate('tasks','tasks'));await page.locator('.chat-row[data-id="team"]').click();await atEnd('back from another page','team');
  assert.deepEqual(errors,[]);
 }finally{await context?.close();await rm(dir,{recursive:true,force:true});}
});

import test from 'node:test';import assert from 'node:assert/strict';import {chromium} from 'playwright-core';import {mkdtemp,rm} from 'node:fs/promises';import {existsSync} from 'node:fs';import {tmpdir} from 'node:os';import {join} from 'node:path';
// The plan strip above the group composer: a drafted plan asks which stage to get done, a tap authorizes it, and the strip then says what the team is doing.
test('the plan strip offers the stages, authorizes the tapped one, then shows the work, at desktop and phone width, light and dark',{skip:process.platform!=='darwin'||!existsSync('/Applications/Google Chrome.app'),timeout:60000},async()=>{
 const dir=await mkdtemp(join(tmpdir(),'buddy-plan-ui-'));let context;
 try{
  context=await chromium.launchPersistentContext(join(dir,'browser.noindex'),{channel:'chrome',headless:true,viewport:{width:1120,height:850},reducedMotion:'reduce'});
  await context.route('**/*',r=>/^https?:/.test(r.request().url())?r.abort():r.continue());
  const page=context.pages()[0];const errors=[];page.on('pageerror',e=>errors.push(e.message));page.on('dialog',d=>d.accept());
  await page.goto(new URL('../../relay/index.html',import.meta.url).href);await page.waitForFunction(()=>!!window.BuddyWorkerUI&&!!window.BuddyActivity);
  await page.evaluate(()=>{
   document.getElementById('onboarding-root').innerHTML='';closeModal();
   state.agents=[{id:'chief',name:'Chief',role:'Chief of staff',avatarShape:'star',avatarColor:'lilac',setupStatus:'ready',tools:{}},{id:'lyra',name:'Lyra',role:'Researcher',avatarShape:'cube',avatarColor:'orange',setupStatus:'ready',tools:{}},{id:'forge',name:'Forge',role:'Builder',avatarShape:'pebble',avatarColor:'blue',setupStatus:'ready',tools:{}}];
   state.groups=[{id:'team',name:'Omori team',members:['chief','lyra','forge'],objective:'Ship the portfolio',managedBy:'chief',createdAt:'2026-10-19T09:00:00Z'}];
   state.onboarding={status:'completed',agentId:'chief'};state.proposals=[];state.teamPlans=[];state.runs={};state.messages={team:[{id:'ask',who:'you',body:'Plan the portfolio.',time:'10:00',createdAt:'2026-10-19T10:00:00Z'}],chief:[],lyra:[],forge:[]};state.drafts={team:''};state.attachments={};ui.view={kind:'chat',target:'team'};ui.lastChat='team';
   const task=(id,title,assignee,status,extra={})=>({id,title,assignee,kind:'research',status,workerTaskId:'',workerStatus:'',blockedOn:'none',resultSummary:'',updatedAt:new Date(Date.now()-4*60000).toISOString(),...extra});
   const stages=s1=>[{id:'s1',n:1,title:'Research',goal:'Know what the best portfolios do',acceptance:['Five references saved','A one-page direction'],status:s1,tasks:[task('t1','Collect five references','lyra',s1==='working'?'dispatched':'pending',s1==='working'?{workerTaskId:'w1',workerStatus:'running'}:{}),task('t2','Write the direction','forge','pending')]},{id:'s2',n:2,title:'Build',goal:'A first homepage',acceptance:['The homepage opens on a phone'],status:'proposed',tasks:[]},{id:'s3',n:3,title:'Launch',goal:'Share it',acceptance:['Published'],status:'proposed',tasks:[]}];
   window.draftPlan={id:'p1',groupId:'team',objective:'Ship a portfolio that feels like me',supervisorId:'chief',status:'draft',revision:1,scope:null,stages:stages('proposed'),notices:[],run:{state:'draft',working:[],needsYou:0,idleSince:null}};
   window.activePlan={...draftPlan,status:'active',scope:{through:1,quote:'Get stage 1 done',at:new Date().toISOString(),status:'active'},stages:stages('working'),notices:[{id:'n1',kind:'authorized',text:'Stage 1 authorized. The team is working on Stage 1 — Research. I’ll report when it’s done.',chat:true,status:'open',at:new Date().toISOString()}],run:{state:'working',working:[{agentId:'lyra',title:'Collect five references',since:new Date(Date.now()-4*60000).toISOString()}],needsYou:0,idleSince:null}};
   window.currentPlan=draftPlan;window.operations=[];
   const status=()=>({workspace:state.conversationWorkspace,online:true,paused:false,tasks:[],routines:[],decisions:[],notifications:{},plans:[currentPlan],pulse:{agents:currentPlan===activePlan?{lyra:{state:'working',taskId:'w1',title:'Collect five references',since:new Date().toISOString(),lastActivitySeconds:3}}:{},queuePaused:false,privateSignIn:null,idleSince:null},supervisorLane:{online:true,busy:false,lastRunAt:'',lastError:''}});
   window.BuddyDesktop={saveState:async()=>({saved:true}),worker:async p=>{operations.push(JSON.parse(JSON.stringify(p)));
    if(p.operation==='status'||p.operation==='start')return status();
    if(p.operation==='plan'&&p.arguments?.action==='authorize'&&!window.refusedOnce){window.refusedOnce=true;return {error:'Authorizing a stage needs the user’s own words (at least 8 characters).'};}
    if(p.operation==='plan'&&p.arguments?.action==='authorize'){currentPlan=activePlan;return {plan:activePlan,receipt:{}};}
    if(p.operation==='plan'&&p.arguments?.action==='stop'){currentPlan={...activePlan,status:'holding',scope:null,notices:activePlan.notices,run:{state:'stopped',working:[],needsYou:0,idleSince:null}};return {plan:currentPlan,receipt:{}};}
    if(p.operation==='notify')return {notifications:{}};
    throw Error('Unexpected fixture operation '+p.operation);}};
   render();
  });
  await page.evaluate(()=>BuddyWorkerUI.refresh(false));
  const strip=page.locator('.composer-wrap > .plan-strip');
  await strip.filter({hasText:'Plan ready — which stage should the team get done?'}).waitFor({timeout:8000});
  assert.equal(await strip.count(),1,'one strip, above the composer');
  assert.equal(await page.locator('.composer-wrap > .plan-strip + *').count(),1);
  await strip.getByText('Ship a portfolio that feels like me').waitFor();
  await strip.getByText('Five references saved').waitFor();
  assert.equal(await strip.locator('.plan-task canvas[data-fig]').count(),2,'each task shows its agent’s figure');
  await strip.getByRole('button',{name:'Get stages 1–2 done',exact:true}).waitFor();
  await strip.getByRole('button',{name:'Change stage 2',exact:true}).click();
  assert.equal(await page.locator('#message-input').inputValue(),'Stage 2: ');assert.equal(await page.evaluate(()=>document.activeElement?.id),'message-input');assert.equal(await page.evaluate(()=>state.drafts.team),'Stage 2: ');
  await page.locator('#message-input').fill('');
  await strip.getByRole('button',{name:'Get stage 1 done',exact:true}).click();
  await strip.getByRole('alert').filter({hasText:'Authorizing a stage needs the user’s own words (at least 8 characters).'}).waitFor({timeout:8000});
  assert.match(await strip.locator('.plan-strip-head').innerText(),/^Plan ready/,'a refused tap never shows the stage as started');
  assert.equal(await page.evaluate(()=>BuddyFigures.getMode('lyra')),'ready');
  await strip.getByRole('button',{name:'Get stage 1 done',exact:true}).click();
  await strip.filter({hasText:/^Working on Stage 1 of 3/}).first().waitFor({timeout:8000});
  assert.equal(await strip.getByRole('alert').count(),0,'the refusal goes once the stage really starts');
  const plan=await page.evaluate(()=>operations.filter(o=>o.operation==='plan'));
  assert.equal(plan.length,2);
  for(const op of plan){assert.equal(op.arguments.action,'authorize');assert.equal(op.arguments.through,1);assert.equal(op.arguments.planId,'p1');assert.equal(op.arguments.quote,'Get stage 1 done','the person’s words: the button they tapped');assert.equal(op.actorId,undefined,'the tap is the person’s, not an agent’s');}
  assert.match(await strip.locator('.plan-strip-head').innerText(),/Working on Stage 1 of 3 — 0 of 2 tasks done — Lyra is working on “Collect five references” \(4 min\)/);
  assert.equal(await strip.locator('[data-plan-toggle]').getAttribute('aria-expanded'),'false','once the team is working the strip folds to its one line');
  assert.equal(await strip.getByRole('button',{name:/Get stage/}).count(),0);
  await page.locator('#messages .plan-notice').filter({hasText:'Stage 1 authorized.'}).waitFor();
  assert.equal(await page.locator('#messages .plan-notice .message-author').innerText(),'Chief','the notice is Chief’s, under Chief’s name');
  await page.evaluate(()=>BuddyWorkerUI.refresh(false));await page.evaluate(()=>BuddyWorkerUI.refresh(false));
  assert.equal(await page.evaluate(()=>state.messages.team.filter(m=>m.id==='plan-notice-n1').length),1,'delivered once, however often the status is read');
  assert.equal(await page.evaluate(()=>BuddyFigures.getMode('lyra')),'working','Lyra’s figure works while her background task runs');
  await strip.locator('[data-plan-toggle]').click();
  assert.equal(await strip.locator('[data-plan-toggle]').getAttribute('aria-expanded'),'true');
  await strip.locator('.plan-task-title').filter({hasText:'Collect five references'}).waitFor();
  // Crossing the phone breakpoint re-renders the page (app.js); the strip comes back, still open, in the new composer.
  await page.setViewportSize({width:390,height:844});
  await page.waitForFunction(()=>innerWidth===390&&document.querySelector('.composer-wrap > .plan-strip [data-plan-toggle]')?.getAttribute('aria-expanded')==='true'&&document.querySelector('.composer-wrap > .plan-strip').getBoundingClientRect().width>300);
  await page.evaluate(()=>BuddyTheme.choose('dark'));
  const fits=await page.evaluate(()=>{const el=document.querySelector('.composer-wrap > .plan-strip');return {fits:el.scrollWidth<=el.clientWidth+1,width:el.getBoundingClientRect().width,body:document.documentElement.scrollWidth<=window.innerWidth+1,theme:document.documentElement.dataset.theme};});
  assert.equal(fits.fits,true,'nothing in the strip is wider than a phone');assert.equal(fits.body,true,'and the page does not scroll sideways');assert.ok(fits.width>300,JSON.stringify(fits));assert.equal(fits.theme,'dark');
  const colours=await page.evaluate(()=>{const el=document.querySelector('.composer-wrap > .plan-strip'),s=getComputedStyle(el);return {bg:s.backgroundColor,fg:getComputedStyle(el.querySelector('.plan-banner')).color};});
  assert.notEqual(colours.bg,'rgb(255, 255, 255)','dark mode has a dark strip');assert.notEqual(colours.fg,'rgb(20, 20, 20)','with light text');
  const stop=strip.getByRole('button',{name:'Stop',exact:true});await stop.waitFor();const box=await stop.boundingBox();assert.ok(box.height>=32,'buttons stay easy to tap on a phone');
  await stop.click();
  await strip.filter({hasText:/^Stopped — nothing new will start/}).first().waitFor({timeout:8000});
  assert.equal(await page.evaluate(()=>operations.filter(o=>o.operation==='plan').at(-1).arguments.action),'stop');
  await strip.getByRole('button',{name:'Get stage 1 done',exact:true}).waitFor();
  await page.evaluate(()=>navigate('chat','lyra'));assert.equal(await page.locator('.plan-strip').count(),0,'a teammate who supervises nothing has no strip in their chat');
  await page.evaluate(()=>navigate('chat','chief'));await page.locator('.composer-wrap > .plan-strip').waitFor();
  await page.evaluate(()=>{newTask();document.getElementById('task-name').value='A note';document.getElementById('task-brief').value='Just a note.';document.getElementById('task-form').requestSubmit();});
  assert.match(await page.locator('#toast').innerText(),/The board doesn’t start work: ask an agent in chat, or use Background work → New task\./);
  assert.deepEqual(errors,[]);
 }finally{await context?.close();await rm(dir,{recursive:true,force:true});}
});

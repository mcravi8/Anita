import test from 'node:test';import assert from 'node:assert/strict';import {chromium} from 'playwright-core';import {mkdtemp,rm} from 'node:fs/promises';import {existsSync} from 'node:fs';import {tmpdir} from 'node:os';import {join} from 'node:path';
// The plan of the group chat: one line above the composer that opens the plan view, where a drafted plan asks which stage to get done, a tap
// authorizes it, and the plan then says what the team is doing.
test('the plan view offers the stages, authorizes the tapped one, then shows the work; the chat shows it in one line, at desktop and phone width, light and dark',{skip:process.platform!=='darwin'||!existsSync('/Applications/Google Chrome.app'),timeout:60000},async()=>{
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
  // In the chat: one line above the composer, a segment per stage, that opens the plan view.
  const line=page.locator('.composer-wrap > .stage-strip');
  await line.filter({hasText:'Plan ready — which stage should the team get done?'}).waitFor({timeout:8000});
  assert.equal(await page.locator('.composer-wrap > .plan-strip').count(),0,'the whole plan is not above the composer any more');
  assert.equal(await line.locator('.stage-seg').count(),3,'a segment for each stage');
  assert.deepEqual(await page.locator('[data-chat-views] [role="tab"]').allInnerTexts(),['Chat','Plan'],'the plan is a view of the chat');
  await line.click();
  // The plan view: the whole plan, with its buttons, where the messages were.
  const view=page.locator('[data-chat-pane="plan"]'),strip=view.locator('.plan-strip');await strip.waitFor();
  assert.equal(await page.locator('[data-chat-view="plan"][role="tab"]').getAttribute('aria-selected'),'true');
  assert.equal(await page.locator('#chat-body').isVisible(),false,'the messages make way');
  assert.equal(await page.evaluate(()=>!!document.activeElement?.closest('[data-chat-pane]')),true,'focus moves to the plan');
  await strip.getByText('Ship a portfolio that feels like me').waitFor();
  await strip.getByText('Five references saved').waitFor();
  assert.equal(await strip.locator('.plan-task canvas[data-fig]').count(),2,'each task shows its agent’s figure');
  await strip.getByRole('button',{name:'Get stages 1–2 done',exact:true}).waitFor();
  await strip.getByRole('button',{name:'Change stage 2',exact:true}).click();
  assert.equal(await page.locator('#message-input').inputValue(),'Stage 2: ');assert.equal(await page.evaluate(()=>document.activeElement?.id),'message-input','a change is said in the chat, which comes back for it');assert.equal(await page.evaluate(()=>state.drafts.team),'Stage 2: ');
  assert.equal(await page.locator('[data-chat-view="chat"][role="tab"]').getAttribute('aria-selected'),'true');
  await page.locator('#message-input').fill('');
  await page.locator('[data-chat-views] [data-chat-view="plan"]').click();await strip.waitFor();
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
  assert.equal(await strip.getByRole('button',{name:/Get stage/}).count(),0);
  // Escape goes back to the chat, where the authorization is one line, not a message.
  await page.keyboard.press('Escape');
  assert.equal(await page.evaluate(()=>document.activeElement?.id),'message-input');
  const notice=page.locator('#messages .plan-status-line').filter({hasText:'Stage 1 authorized'});await notice.waitFor();
  assert.match(await notice.innerText(),/Stage 1 authorized · working on Stage 1 — Research/);
  await line.filter({hasText:/^Working on Stage 1 of 3/}).waitFor();
  await page.evaluate(()=>BuddyWorkerUI.refresh(false));await page.evaluate(()=>BuddyWorkerUI.refresh(false));
  assert.equal(await page.evaluate(()=>state.messages.team.filter(m=>m.id==='plan-notice-n1').length),1,'delivered once, however often the status is read');
  assert.equal(await page.evaluate(()=>BuddyFigures.getMode('lyra')),'working','Lyra’s figure works while her background task runs');
  // At phone width, in dark mode: the line fits, and the plan view too.
  await page.setViewportSize({width:390,height:844});
  await page.waitForFunction(()=>innerWidth===390&&document.querySelector('.composer-wrap > .stage-strip')?.getBoundingClientRect().width>300);
  await page.evaluate(()=>BuddyTheme.choose('dark'));
  const fits=await page.evaluate(()=>{const el=document.querySelector('.composer-wrap > .stage-strip');return {fits:el.scrollWidth<=el.clientWidth+1,width:el.getBoundingClientRect().width,body:document.documentElement.scrollWidth<=window.innerWidth+1,theme:document.documentElement.dataset.theme};});
  assert.equal(fits.fits,true,'nothing in the line is wider than a phone');assert.equal(fits.body,true,'and the page does not scroll sideways');assert.ok(fits.width>300,JSON.stringify(fits));assert.equal(fits.theme,'dark');
  const colours=await page.evaluate(()=>{const el=document.querySelector('.composer-wrap > .stage-strip'),s=getComputedStyle(el);return {bg:s.backgroundColor,fg:getComputedStyle(el.querySelector('.plan-banner')).color};});
  assert.notEqual(colours.bg,'rgb(255, 255, 255)','dark mode has a dark line');assert.notEqual(colours.fg,'rgb(20, 20, 20)','with light text');
  await page.locator('.composer-wrap > .stage-strip').click();await strip.waitFor();
  assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=window.innerWidth+1),true,'the plan view fits a phone');
  const stop=strip.getByRole('button',{name:'Stop',exact:true});await stop.waitFor();const box=await stop.boundingBox();assert.ok(box.height>=32,'buttons stay easy to tap on a phone');
  await stop.click();
  await strip.filter({hasText:/^Stopped — nothing new will start/}).first().waitFor({timeout:8000});
  assert.equal(await page.evaluate(()=>operations.filter(o=>o.operation==='plan').at(-1).arguments.action),'stop');
  await strip.getByRole('button',{name:'Get stage 1 done',exact:true}).waitFor();
  await page.evaluate(()=>navigate('chat','lyra'));assert.equal(await page.locator('.plan-strip,.stage-strip,[data-chat-views]').count(),0,'a teammate who supervises nothing has no plan in their chat');
  await page.evaluate(()=>navigate('chat','chief'));await page.locator('.composer-wrap > .stage-strip').waitFor();
  assert.equal(await page.locator('[data-chat-view="chat"][role="tab"]').getAttribute('aria-selected'),'true','another chat opens on its messages');
  await page.evaluate(()=>{newTask();document.getElementById('task-name').value='A note';document.getElementById('task-brief').value='Just a note.';document.getElementById('task-form').requestSubmit();});
  assert.match(await page.locator('#toast').innerText(),/The board doesn’t start work: ask an agent in chat, or use Background work → New task\./);
  assert.deepEqual(errors,[]);
 }finally{await context?.close();await rm(dir,{recursive:true,force:true});}
});

// Plan notices as cards in the group chat: the stage report's next stage is chosen from the card, and Chief's question is answered from its card
// with Approve, Disapprove or a written reply, each sent once as the person's own answer.
test('a stage report and a decision are cards in the chat; the next stage and the answer are the person’s taps, sent once',{skip:process.platform!=='darwin'||!existsSync('/Applications/Google Chrome.app'),timeout:60000},async()=>{
 const dir=await mkdtemp(join(tmpdir(),'buddy-plan-cards-'));let context;
 try{
  context=await chromium.launchPersistentContext(join(dir,'browser.noindex'),{channel:'chrome',headless:true,viewport:{width:1280,height:900},reducedMotion:'reduce'});
  await context.route('**/*',r=>/^https?:/.test(r.request().url())?r.abort():r.continue());
  const page=context.pages()[0];const errors=[];page.on('pageerror',e=>errors.push(e.message));
  await page.goto(new URL('../../relay/index.html',import.meta.url).href);await page.waitForFunction(()=>!!window.BuddyWorkerUI&&!!window.BuddyPlan);
  await page.evaluate(()=>{
   document.getElementById('onboarding-root').innerHTML='';closeModal();
   state.agents=[{id:'chief',name:'Chief',role:'Chief of staff',avatarShape:'star',avatarColor:'lilac',setupStatus:'ready',tools:{}},{id:'vera',name:'Vera',role:'Reviewer',avatarShape:'cube',avatarColor:'green',setupStatus:'ready',tools:{}}];
   state.groups=[{id:'team',name:'Omori team',members:['chief','vera'],objective:'EE590 report',managedBy:'chief',createdAt:'2026-10-19T09:00:00Z'}];
   state.onboarding={status:'completed',agentId:'chief'};state.proposals=[];state.teamPlans=[];state.runs={};state.messages={team:[],chief:[],vera:[]};state.drafts={team:''};state.attachments={};ui.view={kind:'chat',target:'team'};ui.lastChat='team';
   const report='Acceptance: S01 PASS, independently signed off by Vera.\nOutputs: spec_v1.sha256 and acceptance.md saved.\nIssues: No remaining S01 blockers.';
   window.plan={id:'p1',groupId:'team',objective:'EE590 report',supervisorId:'chief',status:'holding',revision:2,scope:{through:1,quote:'Get stage 1 done',at:'2026-10-21T02:00:00Z',status:'achieved'},
    stages:[{id:'s1',n:1,title:'S01 Protocol freeze',goal:'Freeze the protocol',acceptance:['spec_v1.sha256 saved'],status:'done',tasks:[]},{id:'s2',n:2,title:'S02a Pooled relaxation',goal:'Pooled analysis',acceptance:['Timing 3 of 3'],status:'proposed',tasks:[]}],
    notices:[{id:'r1',kind:'stage_report',text:report+'\n\nNext is Stage 2 — S02a Pooled relaxation: Pooled analysis. Say “get stage 2 done”, or tell me what to change.',chat:true,status:'open',at:'2026-10-21T03:05:00Z',refs:{stageId:'s1'}},
     {id:'e1',kind:'escalation',text:'Approve the recommended suspension? My recommendation: Suspend S02a recovery until runtime access is back. The team keeps working on the rest meanwhile.',chat:true,status:'open',at:'2026-10-21T03:51:00Z',refs:{question:'Approve the recommended suspension?',recommendation:'Suspend S02a recovery until runtime access is back',category:'objective'}},
     {id:'e2',kind:'escalation',text:'Which year should the report use?',chat:true,status:'open',at:'2026-10-21T03:52:00Z',refs:{question:'Which year should the report use?',category:'personal_fact'}}],
    run:{state:'needs_you',working:[],needsYou:2,idleSince:null}};
   window.operations=[];
   const status=()=>({workspace:state.conversationWorkspace,online:true,paused:false,tasks:[],routines:[],decisions:[],notifications:{},plans:[structuredClone(plan)],pulse:{agents:{}},supervisorLane:{online:true,busy:false}});
   window.BuddyDesktop={saveState:async()=>({saved:true}),worker:async p=>{operations.push(JSON.parse(JSON.stringify(p)));
    if(['status','start'].includes(p.operation))return status();
    if(p.operation==='plan'&&p.arguments?.action==='answer'){plan.notices=plan.notices.map(n=>n.id===p.arguments.escalationId?{...n,status:'answered',refs:{...n.refs,answer:p.arguments.answer}}:n);return {plan:structuredClone(plan)};}
    if(p.operation==='plan'&&p.arguments?.action==='authorize'){plan.status='active';plan.scope={through:2,quote:p.arguments.quote,at:new Date().toISOString(),status:'active'};plan.stages[1].status='approved';return {plan:structuredClone(plan)};}
    if(p.operation==='notify')return {notifications:{}};if(p.operation==='detail')return {task:null};
    throw Error('Unexpected fixture operation '+p.operation);}};
   render();
  });
  await page.evaluate(()=>BuddyWorkerUI.refresh(false));
  const report=page.locator('#messages [data-chat-item="plan-notice-r1"] .plan-card-report');await report.waitFor({timeout:8000});
  assert.match(await report.locator('h3').innerText(),/Stage 1 · S01 Protocol freeze/);
  assert.deepEqual(await report.locator(':scope > .plan-card-rows dt').allInnerTexts(),['Acceptance','Issues'],'the report’s labelled lines read as rows: what the stage achieved and what is open');
  assert.deepEqual(await report.locator('.plan-card-more .plan-card-rows dt').allTextContents(),['Outputs'],'where the files went folds under Details');
  assert.equal(await report.locator('.plan-card-more > summary').innerText(),'Details');
  assert.equal(await page.locator('#messages [data-chat-item="plan-notice-r1"] .team-chat-author .message-author').innerText(),'Chief','under Chief’s name');
  await report.getByRole('button',{name:'Get stage 2 done',exact:true}).click();
  await report.getByText('Stage 2 started').waitFor({timeout:8000});
  assert.equal(await report.getByRole('button',{name:'Get stage 2 done'}).count(),0,'once chosen, the card says so');
  // Approve: the person's answer, in plain words, sent once.
  const decision=page.locator('#messages [data-chat-item="plan-notice-e1"] .plan-card-decision');await decision.waitFor();
  assert.match(await decision.innerText(),/Needs your decision · a change to the plan/);
  assert.match(await decision.innerText(),/Chief recommends\s+Suspend S02a recovery until runtime access is back/);
  await decision.getByRole('button',{name:'Approve',exact:true}).dblclick();
  // Answered, the question leaves the chat, and a toast says the answer went.
  await decision.waitFor({state:'detached',timeout:8000});await page.locator('#toast').filter({hasText:'Sent to Chief.'}).waitFor({timeout:8000});
  const answers=await page.evaluate(()=>operations.filter(o=>o.operation==='plan'&&o.arguments.action==='answer').map(o=>o.arguments));
  assert.deepEqual(answers,[{action:'answer',planId:'p1',escalationId:'e1',answer:'Approved. Go ahead with your recommendation: Suspend S02a recovery until runtime access is back',quote:'Approved. Go ahead with your recommendation: Suspend S02a recovery until runtime access is back'}],'one answer, the person’s own');
  assert.equal(await page.locator('#messages [data-chat-item="plan-notice-e1"]').count(),0,'the answered question is not in the chat');
  // A question with no recommendation is answered in words.
  const question=page.locator('#messages [data-chat-item="plan-notice-e2"] .plan-card-decision');
  await question.getByRole('button',{name:'Reply',exact:true}).click();
  const box=question.locator('textarea');await box.waitFor();assert.equal(await page.evaluate(()=>document.activeElement?.tagName),'TEXTAREA');
  await box.fill('Use 2015, the year the paper uses.');
  await page.evaluate(()=>refreshLiveChat('team'));assert.equal(await question.locator('textarea').inputValue(),'Use 2015, the year the paper uses.','what is written survives a redraw');
  await question.getByRole('button',{name:'Send answer',exact:true}).click();
  await question.waitFor({state:'detached',timeout:8000});
  assert.equal(await page.evaluate(()=>operations.filter(o=>o.operation==='plan'&&o.arguments.action==='answer').at(-1).arguments.answer),'Use 2015, the year the paper uses.');
  assert.deepEqual(errors,[]);
 }finally{await context?.close();await rm(dir,{recursive:true,force:true});}
});

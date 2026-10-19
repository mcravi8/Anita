import test from 'node:test';
import assert from 'node:assert/strict';
import {chromium} from 'playwright-core';
import {mkdtemp,rm} from 'node:fs/promises';
import {existsSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';

const skip=process.platform!=='darwin'||!existsSync('/Applications/Google Chrome.app');
async function open(directory,setup){
 const context=await chromium.launchPersistentContext(path.join(directory,'browser.noindex'),{channel:'chrome',headless:true,viewport:{width:1200,height:900}});
 await context.route('**/*',r=>/^https?:/.test(r.request().url())?r.abort():r.continue());
 const page=context.pages()[0];page.on('pageerror',e=>console.error('Fixture page error:',e.message));await page.goto(new URL('../../relay/index.html',import.meta.url).href);
 await page.evaluate(()=>{
  document.getElementById('onboarding-root').innerHTML='';closeModal();
  state.agents=[{id:'chief',name:'Chief',role:'Chief of staff',description:'Preserve my role',setupStatus:'ready',avatarShape:'diamond',avatarColor:'lilac',tools:{desktop:false,web:true}},{id:'sage',name:'Sage',role:'Applications',description:'Apply for jobs',setupStatus:'ready',avatarShape:'sphere',avatarColor:'blue',tools:{desktop:true,web:true}}];
  state.messages={chief:[],sage:[]};state.groups=[];state.runs={};state.onboarding={status:'completed',agentId:'chief'};ui.lastChat='chief';ui.view={kind:'chat',target:'chief'};
 });
 await page.evaluate(setup);
 return {context,page};
}

test('a change made in chat is carried into the page, saved, and only then acknowledged',{skip,timeout:45000},async()=>{
 const directory=await mkdtemp(path.join(tmpdir(),'buddy-rules-ui-'));let context,page;
 try{
  ({context,page}=await (async()=>{const r=await open(directory,()=>{
   window.log=[];window.pendingChanges=[
    {id:'c1',agentId:'chief',field:'name',status:'applied',old:'Chief',new:'Captain',seq:1},
    {id:'c2',agentId:'sage',field:'tools.desktop',status:'applied',old:true,new:false,seq:2},
    {id:'c3',agentId:'gone',field:'name',status:'applied',old:'A',new:'B',seq:3}];
   window.BuddyDesktop={saveState:async v=>{log.push('save:'+JSON.parse(v).agents.map(a=>a.name).join(','));return {saved:true};},worker:async p=>{
    if(p.operation==='status')return {online:true,paused:false,tasks:[],routines:[]};
    if(p.operation==='settings'&&p.arguments.action==='pending'){log.push('pending:'+p.arguments.adopter);return {changes:pendingChanges};}
    if(p.operation==='settings'&&p.arguments.action==='adopt'){log.push('adopt:'+p.arguments.adopter+':'+p.arguments.ids.join(','));pendingChanges=[];return {adopted:true};}
    throw Error('Unexpected fixture operation '+p.operation);
   }};
   window.dispatchEvent(new CustomEvent('buddy-conversation',{detail:{type:'agent-settings-changed'}}));
  });return {context:r.context,page:r.page};})());
  await page.waitForFunction(()=>log.some(x=>x.startsWith('adopt:')),null,{timeout:8000});
  const log=await page.evaluate(()=>log);
  assert.deepEqual(log.filter(x=>!x.startsWith('pending')),['save:Captain,Sage','adopt:page:c1,c2,c3'],'saved first, then acknowledged, every change including one for a vanished agent');
  assert.ok(log.includes('pending:page'));
  assert.equal(await page.evaluate(()=>state.agents[0].name),'Captain');
  assert.equal(await page.evaluate(()=>state.agents[1].tools.desktop),false);
  assert.equal(await page.evaluate(()=>state.agents[1].tools.web),true);
 }finally{await context?.close();await rm(directory,{recursive:true,force:true});}
});

test('an agent’s settings list its rules and chat changes, with pause, remove, undo and allow',{skip,timeout:60000},async()=>{
 const directory=await mkdtemp(path.join(tmpdir(),'buddy-rules-ui-'));let context,page;
 try{
  ({context,page}=await open(directory,()=>{
   window.calls=[];
   window.listing={rules:[{id:'r1',agentId:'sage',text:'Send the CV before applying',status:'active',approved:2,needed:3,earned:false,relaxes:true},{id:'r2',agentId:'sage',text:'Always show the cover letter',status:'active',approved:0,needed:0,earned:false,relaxes:false}],
    changes:[{id:'x1',agentId:'sage',scope:'agent',field:'name',label:'name',status:'applied',summary:'Sage’s name: “Sage” → “Scout”',by:'chat',at:'2026-10-18T12:00:00Z',canUndo:true},{id:'x2',agentId:'sage',scope:'agent',field:'tools.desktop',label:'browser access',status:'pending',summary:'Sage’s browser access: off → on',by:'chat',at:'2026-10-18T12:05:00Z',canUndo:false}]};
   window.BuddyDesktop={saveState:async()=>({saved:true}),worker:async p=>{
    calls.push(p);
    if(p.operation==='status')return {online:true,paused:false,tasks:[],routines:[],workspace:state.conversationWorkspace,decisions:[{id:'change:x2',kind:'confirm',agentId:'sage',taskId:'',title:'Allow this change?',question:'You asked for this in chat: Sage’s browser access: off → on. It gives more access or room to spend, so it waits for your OK.',actionLabel:'Allow',payload:{changeId:'x2'},createdAt:'2026-10-18T12:05:00Z'}],notifications:{}};
    if(p.operation==='settings'&&p.arguments.action==='pending')return {changes:[]};
    if(p.operation==='settings'&&p.arguments.action==='list')return listing;
    if(p.operation==='settings'||p.operation==='rules')return {saved:true};
    throw Error('Unexpected fixture operation '+p.operation);
   }};
  }));
  await page.evaluate(()=>agentInfo('sage'));
  await page.locator('.agent-rules .rule-row').first().waitFor({timeout:8000});
  const text=await page.locator('.agent-rules').innerText();
  assert.match(text,/Send the CV before applying/);assert.match(text,/2 of 3 checks approved/);assert.match(text,/Shows its work every time/);assert.match(text,/Sage’s name: “Sage” → “Scout”/);assert.match(text,/Waiting for your OK/);
  assert.equal(await page.locator('#bot-settings [data-change-undo]').count(),1,'only the finished change can be undone');
  assert.equal(await page.evaluate(()=>(document.querySelector('#bot-settings .agent-rules').compareDocumentPosition(document.getElementById('bot-error'))&Node.DOCUMENT_POSITION_FOLLOWING)!==0),true,'it sits above the form’s buttons');
  await page.locator('[data-rule-act="pause"][data-rule-id="r1"]').click();
  await page.locator('[data-change-undo="x1"]').click();
  await page.locator('[data-change-answer="deny"][data-change-id="x2"]').click();
  await page.waitForFunction(()=>calls.filter(c=>c.operation==='settings'&&c.arguments.action==='answer').length===1);
  const calls=await page.evaluate(()=>calls.filter(c=>['rules','settings'].includes(c.operation)&&c.arguments.action!=='list'&&c.arguments.action!=='pending').map(c=>[c.operation,c.arguments.action,c.arguments.ruleId||c.arguments.changeId,c.arguments.allow]));
  assert.deepEqual(calls,[['rules','pause','r1',undefined],['settings','undo','x1',undefined],['settings','answer','x2',false]]);
  assert.equal(await page.evaluate(()=>state.agents.every(a=>a.name!=='Scout')),true,'undo and answers go to the app; the page never edits itself');
  // The same question as a card in Notifications.
  await page.evaluate(()=>{closeModal();});
  await page.evaluate(()=>BuddyWorkerUI.refresh());
  await page.waitForFunction(()=>BuddyActivity.collect(state,{workspace:state.conversationWorkspace,tasks:[],decisions:[{id:'change:x2',kind:'confirm',agentId:'sage',payload:{changeId:'x2'}}]}).some(i=>i.changeId==='x2'));
  await page.evaluate(()=>{BuddyActivity.acceptWorker({workspace:state.conversationWorkspace,tasks:[],routines:[],notifications:{},decisions:[{id:'change:x2',kind:'confirm',agentId:'sage',taskId:'',title:'Allow this change?',question:'You asked for this in chat: Sage’s browser access: off → on.',actionLabel:'Allow',payload:{changeId:'x2'},createdAt:'2026-10-18T12:05:00Z'}]});BuddyActivity.open();});
  await page.locator('[data-change-confirm="x2"]').click();
  await page.getByRole('button',{name:'Allow',exact:true}).waitFor();
  assert.match(await page.locator('.modal').innerText(),/browser access: off → on/);
  await page.evaluate(()=>{calls.length=0;});
  await page.getByRole('button',{name:'Allow',exact:true}).click();
  await page.waitForFunction(()=>calls.some(c=>c.operation==='settings'&&c.arguments.action==='answer'));
  assert.deepEqual(await page.evaluate(()=>calls.filter(c=>c.arguments?.action==='answer').map(c=>[c.arguments.changeId,c.arguments.allow])),[['x2',true]]);
 }finally{await context?.close();await rm(directory,{recursive:true,force:true});}
});

test('a check of the work shows what to look at, needs a reason to refuse, and answers the agent',{skip,timeout:60000},async()=>{
 const directory=await mkdtemp(path.join(tmpdir(),'buddy-rules-ui-'));let context,page;
 try{
  ({context,page}=await open(directory,()=>{
   window.calls=[];window.fixtureTask={id:'apply',agentId:'sage',workspace:state.conversationWorkspace,kind:'applications',provider:'claude',title:'Apply to Acme',status:'waiting_review',attempt:1,progress:'Needs your check',attentionKey:'cp1',updatedAt:'2026-10-18T04:45:00Z',result:'',reviews:[{id:'cp1',kind:'checkpoint',rule:'r1',status:'pending',tool:{name:'Check the work',service:'Buddy',arguments:{rule:'Send the CV before applying',summary:'Here is the CV I will send to Acme.',files:['cv-acme.md'],check:2,of:3,effect:'This is check 2 of 3. After 3 approved checks, this agent continues at this step without asking.'}},questions:[{id:'operation',question:'Here is the CV I will send to Acme.',options:[{label:'Looks good, continue'},{label:'Needs changes'}]}]}]};
   window.BuddyDesktop={saveState:async()=>({saved:true}),worker:async p=>{
    calls.push(p);
    if(p.operation==='status'||p.operation==='start')return {online:true,paused:false,tasks:[fixtureTask],routines:[]};
    if(p.operation==='detail')return {task:fixtureTask};
    if(p.operation==='review'){fixtureTask={...fixtureTask,status:'running',reviews:fixtureTask.reviews.map(r=>({...r,status:p.accept?'answered':'cancelled'}))};return {accepted:true};}
    throw Error('Unexpected fixture operation '+p.operation);
   }};render();
  }));
  await page.evaluate(()=>BuddyWorkerUI.open());
  await page.locator('[data-worker-task="apply"]').first().click({timeout:10000});
  await page.locator('[data-worker-review="cp1"]').waitFor({timeout:8000});
  const card=await page.locator('[data-worker-review="cp1"]').innerText();
  assert.match(card,/Check the work/);assert.match(card,/Check 2 of 3/);assert.match(card,/Send the CV before applying/);assert.match(card,/Here is the CV I will send to Acme\./);assert.match(card,/cv-acme\.md/);assert.match(card,/After 3 approved checks/);
  await page.getByRole('button',{name:'Needs changes',exact:true}).click();
  await page.getByText('Say what needs changing so the agent can fix it.',{exact:true}).waitFor();
  assert.equal(await page.evaluate(()=>calls.some(c=>c.operation==='review')),false,'a refusal needs a reason');
  await page.locator('[data-worker-question="feedback"]').fill('Use the shorter CV.');
  await page.getByRole('button',{name:'Needs changes',exact:true}).click();
  await page.waitForFunction(()=>calls.some(c=>c.operation==='review'));
  assert.deepEqual(await page.evaluate(()=>calls.filter(c=>c.operation==='review').map(c=>[c.id,c.accept,c.feedback])),[['cp1',false,'Use the shorter CV.']]);
 }finally{await context?.close();await rm(directory,{recursive:true,force:true});}
});

test('a model changed from chat shows on screen without a reload',{skip,timeout:60000},async()=>{
 const directory=await mkdtemp(path.join(tmpdir(),'buddy-rules-ui-'));let context,page;
 try{
  ({context,page}=await open(directory,()=>{
   window.chosen='claude-sonnet-4-6';window.listCalls=0;
   const models=[{provider:'claude',id:'claude-sonnet-4-6',name:'Sonnet 4.6',current:true},{provider:'claude',id:'claude-sonnet-5-5',name:'Sonnet 5.5',current:true}];
   window.BuddyDesktop={saveState:async()=>({saved:true}),worker:async p=>({online:true,paused:false,tasks:[],routines:[],decisions:[],notifications:{}}),
    agentModels:async p=>{listCalls++;return {models,agents:{chief:{provider:'claude',model:'claude-sonnet-4-6'},sage:{provider:'claude',model:chosen}},errors:{}};}};
   ui.view={kind:'chat',target:'sage'};render();BuddyModels.mount();
  }));
  await page.waitForFunction(()=>BuddyModels.current('sage')?.model==='claude-sonnet-4-6',null,{timeout:8000});
  assert.match(await page.locator('.agent-model-slot, [data-agent-model]').first().innerText().catch(()=>''),/Sonnet 4\.6|Claude/);
  // The app changes the model (as it does for Chief's request), then tells the page.
  await page.evaluate(()=>{window.chosen='claude-sonnet-5-5';window.dispatchEvent(new CustomEvent('buddy-conversation',{detail:{type:'agent-settings-changed'}}));});
  await page.waitForFunction(()=>BuddyModels.current('sage')?.model==='claude-sonnet-5-5',null,{timeout:8000});
  assert.ok(await page.evaluate(()=>BuddyModels.label(BuddyModels.__snapshot||{models:[{provider:'claude',id:'claude-sonnet-5-5',name:'Sonnet 5.5'}],agents:{sage:{provider:'claude',model:'claude-sonnet-5-5'}}},'sage'))==='Sonnet 5.5');
  assert.ok(await page.evaluate(()=>listCalls)>=2,'the page asked the app again');
  await page.waitForFunction(()=>/Sonnet 5\.5/.test(document.body.innerText),null,{timeout:8000});
 }finally{await context?.close();await rm(directory,{recursive:true,force:true});}
});

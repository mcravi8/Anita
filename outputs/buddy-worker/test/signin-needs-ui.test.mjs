import test from 'node:test';import assert from 'node:assert/strict';import {chromium} from 'playwright-core';import {mkdtemp,rm} from 'node:fs/promises';import {tmpdir} from 'node:os';import {join} from 'node:path';
test('a task waiting for a WRDS sign-in shows a Needs card whose Sign in button opens the app’s own sign-in box with only the profile and task',{timeout:45000},async()=>{
 const dir=await mkdtemp(join(tmpdir(),'buddy-signin-needs-'));let context;
 try{
  context=await chromium.launchPersistentContext(dir,{channel:'chrome',headless:true,viewport:{width:1120,height:850}});const page=context.pages()[0];const errors=[];page.on('pageerror',e=>errors.push(e.message));await page.goto(new URL('../../relay/index.html',import.meta.url).href);await page.waitForFunction(()=>!!window.BuddyActivity);
  await page.evaluate(()=>{
   document.getElementById('onboarding-root').innerHTML='';closeModal();state.agents=[{id:'forge',name:'Forge',role:'Engineer',avatarShape:'cube',avatarColor:'orange',setupStatus:'ready',tools:{}}];state.groups=[];state.onboarding={status:'completed',agentId:'forge'};state.proposals=[];state.teamPlans=[];state.activitySeen={};state.hiddenAgents=[];state.messages={forge:[]};state.runs={};ui.view={kind:'chat',target:'forge'};window.calls=[];window.opened=[];
   const task={id:'extract',workspace:state.conversationWorkspace,agentId:'forge',title:'OptionMetrics extract',status:'waiting_user',provider:'chatgpt',kind:'coding',updatedAt:'2026-10-20T18:00:00Z',progress:'WRDS needs your sign-in. Choose Sign in to save it privately in Buddy.'};
   window.fixtureWorker={workspace:state.conversationWorkspace,online:true,tasks:[task],routines:[],decisions:[{id:'credential:extract:1:wrds',kind:'credential',audience:'user',agentId:'forge',taskId:'extract',title:'WRDS needs your sign-in',question:'Sign in to WRDS so the agent can run the OptionMetrics SPX skew extract.',actionLabel:'Sign in',payload:{taskId:'extract',profile:'wrds'},createdAt:'2026-10-20T18:00:00Z'}]};
   BuddyDesktop={saveState:async()=>({saved:true}),worker:async p=>{window.opened.push(p);return p.operation==='detail'?{task}:fixtureWorker;},signin:async p=>{window.calls.push(p);return {profile:'wrds',name:'WRDS',saved:true,resumed:true};}};
   render();BuddyActivity.acceptWorker(fixtureWorker);
  });
  await page.getByRole('button',{name:/^Notifications:/}).click();await page.getByRole('tab',{name:/Needs you/}).waitFor();
  const card=page.getByRole('button',{name:/WRDS needs your sign-in/});await card.waitFor();
  assert.match(await card.innerText(),/Sign in/);
  await card.click();
  await page.waitForFunction(()=>window.calls.length===1);
  assert.deepEqual(await page.evaluate(()=>window.calls),[{action:'provide',profile:'wrds',taskId:'extract'}],'the box is asked for with the profile and the task, nothing else');
  await page.getByText('Saved. The task continues.',{exact:true}).waitFor();
  assert.equal(await page.getByRole('heading',{name:'OptionMetrics extract',exact:true}).count(),0,'the button opens the sign-in box, not the task');
  assert.equal(await page.locator('input[type=password]').count(),0,'the page itself never asks for a password');
  assert.deepEqual(errors,[]);
 }finally{await context?.close();await rm(dir,{recursive:true,force:true});}
});

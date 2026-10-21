import test from 'node:test';import assert from 'node:assert/strict';import {chromium} from 'playwright-core';import {mkdtemp,rm} from 'node:fs/promises';import {tmpdir} from 'node:os';import {join} from 'node:path';
test('a task waiting for a WRDS sign-in shows a Needs card that opens the agent’s chat, where the sign-in is typed into private fields and goes only to the app’s sign-in bridge',{timeout:45000},async()=>{
 const dir=await mkdtemp(join(tmpdir(),'buddy-signin-needs-'));let context;const USER='fixture-user-7Q2Z',PASS='Fx!pw-93ZK-not-a-real-secret';
 try{
  context=await chromium.launchPersistentContext(dir,{channel:'chrome',headless:true,viewport:{width:1120,height:850}});const page=context.pages()[0];const errors=[];page.on('pageerror',e=>errors.push(e.message));await page.goto(new URL('../../relay/index.html',import.meta.url).href);await page.waitForFunction(()=>!!window.BuddyActivity&&!!window.BuddySignIn);
  await page.evaluate(()=>{
   document.getElementById('onboarding-root').innerHTML='';closeModal();state.agents=[{id:'forge',name:'Forge',role:'Engineer',avatarShape:'cube',avatarColor:'orange',setupStatus:'ready',tools:{}},{id:'lyra',name:'Lyra',role:'Writer',avatarShape:'star',avatarColor:'lilac',setupStatus:'ready',tools:{}}];state.groups=[];state.onboarding={status:'completed',agentId:'forge'};state.proposals=[];state.teamPlans=[];state.activitySeen={};state.hiddenAgents=[];state.messages={forge:[],lyra:[]};state.runs={};ui.view={kind:'chat',target:'lyra'};window.calls=[];window.opened=[];window.saved=[];
   const task={id:'extract',workspace:state.conversationWorkspace,agentId:'forge',title:'OptionMetrics extract',status:'waiting_user',provider:'chatgpt',kind:'coding',updatedAt:'2026-10-20T18:00:00Z',progress:'WRDS needs your sign-in. Choose Sign in to save it privately in Buddy.',checkpoint:{id:'c1',need:'credential',profile:'wrds'}};
   window.fixtureWorker={workspace:state.conversationWorkspace,online:true,tasks:[task],routines:[],decisions:[{id:'credential:extract:1:wrds',kind:'credential',audience:'user',agentId:'forge',taskId:'extract',title:'WRDS needs your sign-in',question:'Sign in to WRDS so the agent can run the OptionMetrics SPX skew extract.',actionLabel:'Sign in',payload:{taskId:'extract',profile:'wrds'},createdAt:'2026-10-20T18:00:00Z'}],
    signinRequests:[{key:'credential:extract:c1',kind:'credential',taskId:'extract',agentId:'forge',profile:'wrds',service:'WRDS',instruction:'Sign in to WRDS so the agent can run the OptionMetrics SPX skew extract.',title:'OptionMetrics extract'}]};
   BuddyDesktop={saveState:async json=>{saved.push(json);return {saved:true};},worker:async p=>{window.opened.push(p);return p.operation==='detail'?{task}:fixtureWorker;},signin:async p=>{window.calls.push(JSON.parse(JSON.stringify(p)));return {profile:'wrds',name:'WRDS',saved:true,resumed:true};}};
   render();BuddyActivity.acceptWorker(fixtureWorker);
  });
  await page.evaluate(()=>BuddyWorkerUI.refresh(false));
  await page.getByRole('button',{name:/^Notifications:/}).click();await page.getByRole('tab',{name:/Needs you/}).waitFor();
  const card=page.getByRole('button',{name:/WRDS needs your sign-in/});await card.waitFor();
  assert.match(await card.innerText(),/Sign in in chat/);
  await card.click();
  await page.waitForFunction(()=>ui.view.target==='forge'&&!document.querySelector('.modal'));
  const holder=page.locator('[data-signin-holder="credential:extract:c1"]');await holder.waitFor();
  // The chat takes focus once the drawer has finished closing.
  await page.waitForFunction(()=>document.activeElement?.dataset?.signinName==='username',null,{timeout:5000}).catch(()=>{});
  assert.equal(await page.evaluate(()=>document.activeElement?.dataset?.signinName),'username','the card opens the chat at the sign-in, ready to type');
  assert.deepEqual(await holder.locator('input').evaluateAll(list=>list.map(e=>[e.type,e.getAttribute('autocomplete'),e.getAttribute('spellcheck')])),[['text','off','false'],['password','off','false']],'a username field and a masked password field');
  await page.keyboard.type(USER);await page.keyboard.press('Enter');
  assert.equal(await page.evaluate(()=>document.activeElement?.dataset?.signinName),'password','Enter moves on to the password');
  await page.keyboard.type(PASS);await page.keyboard.press('Enter');
  await page.getByText('Saved — Forge is continuing.').waitFor();
  assert.deepEqual(await page.evaluate(()=>window.calls),[{action:'provide',profile:'wrds',taskId:'extract',username:USER,password:PASS}],'the sign-in goes to the app’s sign-in bridge with the profile and the task, nothing else');
  assert.equal(await page.getByRole('heading',{name:'OptionMetrics extract',exact:true}).count(),0,'the card opens the chat, not the task');
  const left=await page.evaluate(([u,p])=>[document.documentElement.outerHTML,JSON.stringify(state),saved.join(''),JSON.stringify(window.opened),Object.keys(localStorage).map(k=>localStorage.getItem(k)).join('')].map(t=>t.includes(u)||t.includes(p)),[USER,PASS]);
  assert.deepEqual(left,[false,false,false,false,false],'after Save it is in no page, state, saved workspace, worker request or browser storage');
  assert.deepEqual(errors,[]);
 }finally{await context?.close();await rm(dir,{recursive:true,force:true});}
});

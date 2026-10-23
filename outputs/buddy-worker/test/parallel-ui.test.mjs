import test from 'node:test';
import assert from 'node:assert/strict';
import {chromium} from 'playwright-core';
import {mkdtemp,rm} from 'node:fs/promises';
import {existsSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';

// Several background tasks run at once: Background work lists each task running now with its agent, and Run at once (Worker settings)
// sends the person's choice to the worker. The worker here is a fixture in the page.
test('Background work shows every task running now, and Run at once sends the person’s choice',{skip:process.platform!=='darwin'||!existsSync('/Applications/Google Chrome.app'),timeout:45000},async()=>{
 const directory=await mkdtemp(path.join(tmpdir(),'buddy-parallel-ui-'));let context;
 try{
  context=await chromium.launchPersistentContext(path.join(directory,'browser.noindex'),{channel:'chrome',headless:true,viewport:{width:1200,height:900},reducedMotion:'reduce'});
  await context.route('**/*',r=>/^https?:/.test(r.request().url())?r.abort():r.continue());
  const page=context.pages()[0];const errors=[];page.on('pageerror',e=>errors.push(e.message));await page.goto(new URL('../../relay/index.html',import.meta.url).href);
  await page.evaluate(()=>{
   document.getElementById('onboarding-root').innerHTML='';closeModal();
   state.agents=[{id:'forge',name:'Forge',role:'Engineer',setupStatus:'ready',avatarShape:'star',avatarColor:'lilac',tools:{}},{id:'vera',name:'Vera',role:'Researcher',setupStatus:'ready',avatarShape:'pill',avatarColor:'sage',tools:{}},{id:'ada',name:'Ada',role:'Engineer',setupStatus:'ready',avatarShape:'hex',avatarColor:'sky',tools:{}}];
   state.messages={forge:[],vera:[],ada:[]};state.groups=[];state.runs={};state.drafts={forge:'',vera:'',ada:''};state.onboarding={status:'completed',agentId:'forge'};
   const base={workspace:state.conversationWorkspace,kind:'coding',provider:'claude',attempt:1,updatedAt:'2026-10-22T10:00:00Z',result:'',reviews:[]};
   window.workerCalls=[];window.limit=3;
   window.fixtureTasks=[{...base,id:'left',agentId:'forge',title:'Build the left half',status:'running',progress:'Running project command'},{...base,id:'right',agentId:'vera',title:'Build the right half',status:'running',progress:'Working on your request'},{...base,id:'notes',agentId:'ada',title:'Write the notes',status:'queued',progress:'Queued'}];
   const pulse=()=>({agents:{forge:{state:'working',taskId:'left'},vera:{state:'working',taskId:'right'},ada:{state:'queued',taskId:'notes'}},queuePaused:false,privateSignIn:null,idleSince:null,running:2,maxRunning:limit});
   window.BuddyDesktop={saveState:async()=>({saved:true}),worker:async p=>{
    workerCalls.push(p);
    if(p.operation==='status'||p.operation==='start')return {online:true,paused:false,tasks:fixtureTasks,routines:[],running:['left','right'],maxRunning:limit,pulse:pulse(),plans:[]};
    if(p.operation==='maxRunning'){if(![1,2,3,4,5,6].includes(p.value))throw Error('Choose how many tasks may run at once, from 1 to 6.');limit=p.value;return {maxRunning:limit};}
    if(p.operation==='detail')return {task:fixtureTasks.find(t=>t.id===p.taskId)};
    throw Error('Unexpected fixture operation '+p.operation);
   }};render();
  });
  await page.evaluate(()=>BuddyWorkerUI.open());
  const running=page.locator('[data-worker-running]');
  await running.waitFor();
  assert.match(await running.innerText(),/Working now · 2 of 3 at once/);
  const rows=await running.locator('[data-worker-task]').allInnerTexts();
  assert.equal(rows.length,2,'one row for each task running now');
  assert.match(rows[0],/Build the left half[\s\S]*Forge/);assert.match(rows[1],/Build the right half[\s\S]*Vera/);
  assert.equal(await page.locator('[data-work-page] .work-row').count(),3,'the full list still has every task, on the Background work page');
  assert.equal(await page.locator('#modal-root .modal-overlay').count(),0,'a page, not a drawer');
  await page.locator('summary',{hasText:'Worker settings'}).click();
  const select=page.locator('[data-worker-max-running]');
  assert.equal(await select.inputValue(),'3');
  await select.selectOption('2');
  await page.waitForFunction(()=>workerCalls.some(c=>c.operation==='maxRunning'));
  assert.deepEqual(await page.evaluate(()=>workerCalls.filter(c=>c.operation==='maxRunning')),[{operation:'maxRunning',value:2}],'exactly the person’s choice, as a number');
  await page.locator('[data-worker-running]').filter({hasText:'2 of 2 at once'}).waitFor();
  assert.equal(await page.locator('[data-worker-max-running]').inputValue(),'2','the setting shows the new choice');
  assert.deepEqual(errors,[]);
 }finally{await context?.close();await rm(directory,{recursive:true,force:true});}
});

import test from 'node:test';
import assert from 'node:assert/strict';
import {chromium} from 'playwright-core';
import {mkdtemp,rm} from 'node:fs/promises';
import {existsSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';

// The person told the agent which account to use: the reply that started the task says “Uses craviott@usc.edu” under it, and so does the
// task itself in Background work.
test('a task pinned to an account says “Uses …” on the chat reply that started it and in the task’s details',{skip:process.platform!=='darwin'||!existsSync('/Applications/Google Chrome.app'),timeout:45000},async()=>{
 const directory=await mkdtemp(path.join(tmpdir(),'buddy-account-ui-'));let context;
 try{
  context=await chromium.launchPersistentContext(path.join(directory,'browser.noindex'),{channel:'chrome',headless:true,viewport:{width:1200,height:900},reducedMotion:'reduce'});
  await context.route('**/*',r=>/^https?:/.test(r.request().url())?r.abort():r.continue());
  const page=context.pages()[0];const errors=[];page.on('pageerror',e=>errors.push(e.message));await page.goto(new URL('../../relay/index.html',import.meta.url).href);
  await page.evaluate(()=>{
   document.getElementById('onboarding-root').innerHTML='';closeModal();
   state.agents=[{id:'chief',name:'Chief',role:'Chief of staff',setupStatus:'ready',avatarShape:'star',avatarColor:'lilac',tools:{desktop:true,web:true}}];state.messages={chief:[]};state.groups=[];state.runs={};
   state.drafts={chief:'Use my USC account to check my calendar for tomorrow'};state.onboarding={status:'completed',agentId:'chief'};ui.lastChat='chief';ui.view={kind:'chat',target:'chief'};
   window.fixtureTask={id:'cal-task',agentId:'chief',workspace:state.conversationWorkspace,kind:'general',provider:'claude',title:'Check my calendar',status:'running',attempt:1,progress:'Working on the website',account:'craviott@usc.edu',updatedAt:'2026-10-20T18:00:00Z',result:'',reviews:[]};
   window.BuddyDesktop={saveState:async()=>({saved:true}),worker:async p=>{
    if(p.operation==='status'||p.operation==='start')return {online:true,paused:false,tasks:[fixtureTask],routines:[]};
    if(p.operation==='detail')return {task:fixtureTask};
    throw Error('Unexpected fixture operation '+p.operation);
   }};
   window.fixtureRun=BuddyChat.begin(state,'chief').run.runId;render();
  });
  // The app tells the page about the task the reply started, then the reply finishes.
  await page.evaluate(()=>{
   window.dispatchEvent(new CustomEvent('buddy-conversation',{detail:{type:'task',runId:fixtureRun,task:{id:'cal-task',title:'Check my calendar',account:'craviott@usc.edu',agentId:'chief'}}}));
   window.dispatchEvent(new CustomEvent('buddy-conversation',{detail:{type:'run',runId:fixtureRun,status:'completed',text:'I’m on it. I’ll let you know when it’s done or if I need you.'}}));
  });
  const receipt=page.locator('.bot-message .task-receipt').filter({hasText:'Uses craviott@usc.edu'});
  await receipt.waitFor({timeout:8000});
  assert.match(await page.locator('.bot-message').filter({has:page.locator('.task-receipt')}).innerText(),/I’m on it/,'under the reply that started the task');
  // It stays after a redraw (it is saved with the reply), and it opens the task.
  await page.evaluate(()=>render());await receipt.waitFor();
  await receipt.getByRole('button').click();
  await page.locator('.worker-task-heading').filter({hasText:'Uses craviott@usc.edu'}).waitFor({timeout:8000});
  // An unpinned task says nothing about accounts.
  await page.evaluate(()=>{delete fixtureTask.account;closeModal();});
  await page.evaluate(()=>document.querySelector('.task-receipt [data-worker-task]')?.click());
  await page.locator('.worker-task-heading').waitFor();
  assert.doesNotMatch(await page.locator('.worker-task-heading').innerText(),/Uses /);
  assert.deepEqual(errors,[]);
 }finally{await context?.close();await rm(directory,{recursive:true,force:true});}
});

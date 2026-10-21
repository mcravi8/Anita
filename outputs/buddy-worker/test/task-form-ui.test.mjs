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
  state.agents=[{id:'chief',name:'Chief',role:'Chief of staff',description:'Coordinate',setupStatus:'ready',avatarShape:'diamond',avatarColor:'lilac',tools:{desktop:true,web:true}}];
  state.messages={chief:[]};state.groups=[];state.runs={};state.onboarding={status:'completed',agentId:'chief'};ui.lastChat='chief';ui.view={kind:'chat',target:'chief'};
 });
 await page.evaluate(setup);
 return {context,page};
}

test('a new task for a Claude agent starts without the person touching Options, and a stopped coding task simply continues',{skip,timeout:60000},async()=>{
 const directory=await mkdtemp(path.join(tmpdir(),'buddy-task-form-.'));let context,page;
 try{
  ({context,page}=await open(directory,()=>{
   window.calls=[];window.coding={id:'code1',agentId:'chief',workspace:state.conversationWorkspace,kind:'coding',provider:'claude',title:'Rerun',status:'interrupted',attempt:1,progress:'Stopped',remainingBudgetUSD:0,budgetUSD:0.5,updatedAt:'2026-10-19T01:00:00Z',result:'',reviews:[]};
   window.BuddyDesktop={saveState:async()=>({saved:true}),worker:async p=>{
    calls.push(p);
    if(p.operation==='status')return {online:true,paused:false,tasks:[coding],routines:[],claudeConnected:true,claudeBudgetUSD:0.5};
    if(p.operation==='create')return {task:{...coding,id:'new1',kind:p.kind||'general',status:'queued',title:p.title}};
    if(p.operation==='detail')return {task:p.taskId==='code1'?coding:{...coding,id:'new1',status:'queued',kind:'general'}};
    if(p.operation==='resume'){window.coding={...coding,status:'queued',remainingBudgetUSD:p.additionalBudgetUSD};return {task:coding};}
    throw Error('Unexpected fixture operation '+p.operation);
   }};render();
  }));
  await page.evaluate(()=>BuddyWorkerUI.open());
  await page.getByRole('button',{name:/New task/}).first().click({timeout:10000});
  await page.locator('input[name="title"]').fill('Look something up');await page.locator('textarea[name="goal"]').fill('Find the latest figures.');
  await page.getByRole('button',{name:/Start task/}).click();
  await page.waitForFunction(()=>calls.some(c=>c.operation==='create'),null,{timeout:8000});
  const created=await page.evaluate(()=>calls.find(c=>c.operation==='create'));
  assert.equal('budgetUSD' in created,false,'the agent’s own model is used with the settings limit; the form sends no zero that would be refused: '+JSON.stringify(created));
  // A stopped coding task is never held up for an allowance: it just continues.
  await page.locator('[data-worker-op="back"]').first().click({timeout:10000});
  await page.locator('[data-worker-task="code1"]').first().waitFor({state:'attached',timeout:10000});
  await page.evaluate(()=>document.querySelector('[data-worker-task="code1"]').click());
  await page.locator('[data-worker-allowance]').first().waitFor({state:'detached',timeout:3000}).catch(()=>{});
  assert.equal(await page.locator('[data-worker-allowance]').count(),0,'no allowance field is shown');
  await page.getByRole('button',{name:/Resume|Continue/}).first().click();
  await page.waitForFunction(()=>calls.some(c=>c.operation==='resume'||c.operation==='coding'),null,{timeout:8000});
  const resumed=await page.evaluate(()=>calls.filter(c=>c.operation==='resume'||c.operation==='coding').at(-1));
  assert.ok(!resumed.additionalBudgetUSD&&!resumed.arguments?.additionalBudgetUSD,'nothing about an allowance is sent: '+JSON.stringify(resumed));
 }finally{await context?.close();await rm(directory,{recursive:true,force:true});}
});

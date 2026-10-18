import test from 'node:test';
import assert from 'node:assert/strict';
import {chromium} from 'playwright-core';
import {mkdtemp,rm} from 'node:fs/promises';
import {existsSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';

test('ordinary website task requests review and returns its verified result in the same DM',{skip:process.platform!=='darwin'||!existsSync('/Applications/Google Chrome.app'),timeout:45000},async()=>{
 const directory=await mkdtemp(path.join(tmpdir(),'buddy-task-ui-'));let context;
 try{
  context=await chromium.launchPersistentContext(path.join(directory,'browser.noindex'),{channel:'chrome',headless:true,viewport:{width:1200,height:900}});
  await context.route('**/*',r=>/^https?:/.test(r.request().url())?r.abort():r.continue());
  const page=context.pages()[0];page.on('pageerror',e=>console.error('Fixture page error:',e.message));await page.goto(new URL('../../relay/index.html',import.meta.url).href);
  await page.evaluate(()=>{
   document.getElementById('onboarding-root').innerHTML='';closeModal();
   state.agents=[{id:'chief',name:'Chief',role:'Chief of staff',description:'Preserve my role',setupStatus:'ready',avatarShape:'star',avatarColor:'lilac',tools:{desktop:true,web:true}}];state.messages={chief:[]};state.groups=[];state.runs={};state.drafts={chief:'My existing draft'};state.onboarding={status:'completed',agentId:'chief'};ui.lastChat='chief';ui.view={kind:'chat',target:'chief'};
   window.taskCalls=[];window.fixtureTask={id:'browser-task',agentId:'chief',workspace:state.conversationWorkspace,kind:'general',provider:'claude',title:'Create AgentMail inbox',status:'waiting_review',attempt:1,progress:'Review the requested inbox creation.',attentionKey:'create-inbox-review',updatedAt:'2026-10-18T04:45:00Z',result:'',reviews:[{id:'create-inbox-review',kind:'browser',status:'pending',tool:{name:'Create inbox',service:'AgentMail',arguments:{address:'chief@example.invalid'}},questions:[{id:'operation',question:'Allow this exact browser operation?',options:[{label:'Accept'},{label:'Decline'}]}]}]};
   window.BuddyDesktop={saveState:async()=>({saved:true}),worker:async p=>{
    taskCalls.push(p);
    if(p.operation==='status'||p.operation==='start')return {online:true,paused:false,tasks:[fixtureTask],routines:[]};
    if(p.operation==='detail')return {task:fixtureTask};
    if(p.operation==='review'){
     if(!p.accept)throw Error('Fixture expects a deliberate exact review');
     fixtureTask={...fixtureTask,status:'completed',result:'The requested inbox was created and verified on the website.',updatedAt:'2026-10-18T04:46:00Z',reviews:fixtureTask.reviews.map(r=>({...r,status:'completed'}))};return {accepted:true};
    }
    throw Error('Unexpected fixture operation '+p.operation);
   }};render();
  });
  try { await page.locator('.reply-content').filter({hasText:'need your approval'}).waitFor({timeout:8000}); } catch(e) { console.error(await page.evaluate(()=>JSON.stringify({calls:taskCalls,messages:state.messages,body:document.querySelector('#messages')?.textContent})));throw e; }
  assert.equal(await page.evaluate(()=>state.messages.chief.length),1);
  assert.equal(await page.locator('#message-input').inputValue(),'My existing draft');
  await page.getByRole('button',{name:'Review task'}).click();
  await page.locator('[data-worker-review="create-inbox-review"]').waitFor();
  await page.getByRole('button',{name:'Continue',exact:true}).click();
  await page.getByText('Answer each question to continue.',{exact:true}).waitFor();
  assert.equal(await page.evaluate(()=>taskCalls.some(c=>c.operation==='review')),false);
  await page.locator('[data-worker-question="operation"]').selectOption('Accept');
  await page.getByRole('button',{name:'Continue',exact:true}).click();
  await page.evaluate(()=>closeModal());
  await page.locator('.reply-content').filter({hasText:'The requested inbox was created and verified on the website.'}).waitFor();
  assert.equal(await page.evaluate(()=>state.messages.chief.length),2);
  assert.equal(await page.evaluate(()=>taskCalls.filter(c=>c.operation==='review').length),1);
  assert.equal(await page.evaluate(()=>taskCalls.some(c=>c.operation==='create')),false);
  assert.equal(await page.evaluate(()=>state.agents[0].description),'Preserve my role');
  assert.equal(await page.locator('#message-input').inputValue(),'My existing draft');
 }finally{await context?.close();await rm(directory,{recursive:true,force:true});}
});

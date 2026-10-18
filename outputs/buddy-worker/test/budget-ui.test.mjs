import test from 'node:test';
import assert from 'node:assert/strict';
import {chromium} from 'playwright-core';
import {mkdir,rm} from 'node:fs/promises';
import {existsSync} from 'node:fs';
import {randomUUID} from 'node:crypto';
import {tmpdir} from 'node:os';
import path from 'node:path';

test('workspace daily limit saves explicitly, survives failures and refreshes, and never writes to a different workspace',{skip:process.platform!=='darwin'||!existsSync('/Applications/Google Chrome.app')},async()=>{
 const directory=path.join(tmpdir(),'buddy-budget-ui-'+randomUUID()+'.noindex');await mkdir(directory,{mode:0o700});let context;
 try{
  context=await chromium.launchPersistentContext(directory,{channel:'chrome',headless:true,viewport:{width:1100,height:850}});
  await context.route('**/*',route=>/^https?:/.test(route.request().url())?route.abort():route.continue());
  const page=context.pages()[0];await page.goto(new URL('../../relay/index.html',import.meta.url).href);await page.waitForFunction(()=>!!window.BuddyTeamMonitorUI);
  await page.evaluate(async()=>{
   document.getElementById('onboarding-root').innerHTML='';closeModal();state.agents=[];state.messages={};state.runs={};state.onboarding={status:'completed'};
   window.fixture={amount:2,revision:1,writes:[],readError:false,writeError:true,holdSave:false};
   const response=()=>({workspace:state.conversationWorkspace,dailyLimitUSD:fixture.amount,journalRevision:fixture.revision,agents:{},checks:[],updates:[],profiles:[],observed:[]});
   window.BuddyDesktop={saveState:async()=>({saved:true}),worker:async request=>{
    if(request.operation!=='team')return {};
    if(request.arguments.action==='configure'){
     fixture.writes.push(request.arguments);
     if(fixture.holdSave)await new Promise(resolve=>fixture.releaseSave=resolve);
     if(fixture.writeError)throw Error('Fixture save unavailable');
     fixture.amount=request.arguments.dailyLimitUSD;fixture.revision++;
    }else if(fixture.readError)throw Error('Fixture settings unavailable');
    return response();
   }};
   await BuddyTeamMonitorUI.refresh();settings();
  });
  const row=page.locator('.team-budget-option');assert.equal(await row.isVisible(),true);assert.match(await row.textContent(),/\$2\.00 per day/);
  await row.getByRole('button',{name:'Change limit'}).click();
  const input=page.getByRole('spinbutton',{name:'Daily automatic Claude limit in USD'}),save=page.getByRole('button',{name:'Save limit',exact:true});
  await input.waitFor();await page.waitForFunction(()=>!document.querySelector('[data-team-budget-input]').disabled);assert.equal(await input.inputValue(),'2');assert.equal(await input.getAttribute('max'),null);
  await input.fill('0');await save.click();await page.getByRole('alert').filter({hasText:'at least $0.10'}).waitFor();assert.equal(await page.evaluate(()=>fixture.writes.length),0);
  await input.fill('35');await page.evaluate(()=>fixture.holdSave=true);await save.click();
  await page.getByRole('button',{name:'Saving…'}).waitFor();assert.equal(await input.isDisabled(),true);
  await page.evaluate(()=>document.querySelector('#team-budget-form').dispatchEvent(new Event('submit',{bubbles:true,cancelable:true})));assert.equal(await page.evaluate(()=>fixture.writes.length),1);
  await page.evaluate(()=>{fixture.releaseSave();fixture.holdSave=false;});await page.getByRole('alert').filter({hasText:'Fixture save unavailable'}).waitFor();
  assert.equal(await input.inputValue(),'35');assert.equal(await save.isEnabled(),true);
  await page.evaluate(()=>{fixture.writeError=false;});await input.press('Enter');await page.getByRole('heading',{name:'Workspace settings',exact:true}).waitFor();
  assert.match(await row.textContent(),/\$35\.00 per day/);assert.equal(await page.evaluate(()=>fixture.writes.length),2);
  await row.getByRole('button',{name:'Change limit'}).click();await page.waitForFunction(()=>!document.querySelector('[data-team-budget-input]').disabled);assert.equal(await input.inputValue(),'35');
  await input.fill('4');await BuddyRefresh(page);assert.equal(await input.inputValue(),'4');
  await page.getByRole('button',{name:'Cancel',exact:true}).click();assert.match(await row.textContent(),/\$35\.00 per day/);assert.equal(await page.evaluate(()=>fixture.writes.length),2);
  await page.evaluate(()=>fixture.readError=true);await row.getByRole('button',{name:'Change limit'}).click();await page.getByRole('alert').filter({hasText:'Fixture settings unavailable'}).waitFor();
  assert.equal(await input.isDisabled(),true);assert.equal(await save.isDisabled(),true);assert.equal(await input.inputValue(),'');
  await page.evaluate(()=>fixture.readError=false);await page.getByRole('button',{name:'Try again',exact:true}).click();await page.waitForFunction(()=>!document.querySelector('[data-team-budget-input]').disabled);assert.equal(await input.inputValue(),'35');
  await page.setViewportSize({width:390,height:844});assert.equal(await page.locator('.modal').evaluate(el=>el.scrollWidth<=el.clientWidth),true);
  await input.fill('5');await page.evaluate(()=>state.conversationWorkspace='different-workspace');await save.click();await page.getByRole('alert').filter({hasText:'workspace changed'}).waitFor();assert.equal(await page.evaluate(()=>fixture.writes.length),2);
 }finally{await context?.close();await rm(directory,{recursive:true,force:true});}
});
async function BuddyRefresh(page){await page.evaluate(()=>BuddyTeamMonitorUI.refresh());}

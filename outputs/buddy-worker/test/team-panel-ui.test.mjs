import test from 'node:test';
import assert from 'node:assert/strict';
import {chromium} from 'playwright-core';
import {mkdtemp,rm} from 'node:fs/promises';
import {existsSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';

test('the Teamwork panel refreshes on its own without closing the section the person is reading',{skip:process.platform!=='darwin'||!existsSync('/Applications/Google Chrome.app'),timeout:60000},async()=>{
 const directory=await mkdtemp(path.join(tmpdir(),'buddy-team-panel-.'));let context;
 try{
  context=await chromium.launchPersistentContext(path.join(directory,'browser.noindex'),{channel:'chrome',headless:true,viewport:{width:1100,height:850}});
  await context.route('**/*',r=>/^https?:/.test(r.request().url())?r.abort():r.continue());
  const page=context.pages()[0];await page.goto(new URL('../../relay/index.html',import.meta.url).href);await page.waitForFunction(()=>!!window.BuddyTeamMonitorUI);
  await page.evaluate(async()=>{
   document.getElementById('onboarding-root').innerHTML='';closeModal();
   state.agents=[{id:'chief',name:'Chief',role:'Chief of staff',description:'x',setupStatus:'ready',avatarShape:'star',avatarColor:'lilac',tools:{}}];state.messages={chief:[]};state.runs={};state.onboarding={status:'completed',agentId:'chief'};
   window.fixture={revision:1,calls:0,interval:15};
   window.BuddyDesktop={saveState:async()=>({saved:true}),worker:async r=>{fixture.calls++;return {workspace:state.conversationWorkspace,supervisorId:'chief',enabled:true,intervalMinutes:fixture.interval,dailyLimitUSD:2,journalRevision:fixture.revision,agents:{},checks:[],updates:[],profiles:[],observed:[]};}};
   render();await BuddyTeamMonitorUI.open();
  });
  const section=page.locator('.team-monitor-details');await section.waitFor({timeout:8000});
  await section.locator('summary').click();assert.equal(await section.evaluate(e=>e.open),true);
  await page.evaluate(()=>BuddyTeamMonitorUI.refresh());await page.waitForTimeout(200);
  assert.equal(await page.locator('.team-monitor-details').evaluate(e=>e.open),true,'a refresh with nothing new leaves the open section open');
  await page.evaluate(()=>{fixture.revision++;fixture.interval=30;return BuddyTeamMonitorUI.refresh();});await page.waitForTimeout(200);
  assert.equal(await page.locator('.team-monitor-details').evaluate(e=>e.open),true,'and so does a redraw because something changed');
 }finally{await context?.close();await rm(directory,{recursive:true,force:true});}
});

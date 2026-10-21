import test from 'node:test';
import assert from 'node:assert/strict';
import {chromium} from 'playwright-core';
import {mkdtemp,rm} from 'node:fs/promises';
import {existsSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';

test('while a reply streams, a section the person opened stays open, the workspace is not saved on every word, and unread badges survive searching',{skip:process.platform!=='darwin'||!existsSync('/Applications/Google Chrome.app'),timeout:60000},async()=>{
 const directory=await mkdtemp(path.join(tmpdir(),'buddy-streaming-.'));let context;
 try{
  context=await chromium.launchPersistentContext(path.join(directory,'browser.noindex'),{channel:'chrome',headless:true,viewport:{width:1100,height:850}});
  await context.route('**/*',r=>/^https?:/.test(r.request().url())?r.abort():r.continue());
  const page=context.pages()[0];await page.goto(new URL('../../relay/index.html',import.meta.url).href);await page.waitForFunction(()=>!!window.BuddyChat);
  await page.evaluate(()=>{
   document.getElementById('onboarding-root').innerHTML='';closeModal();
   state.agents=[{id:'chief',name:'Chief',role:'Chief of staff',description:'x',setupStatus:'ready',avatarShape:'star',avatarColor:'lilac',tools:{}},{id:'lyra',name:'Lyra',role:'Research',description:'x',setupStatus:'ready',avatarShape:'cube',avatarColor:'blue',tools:{}}];
   state.messages={chief:[{id:'u0',who:'you',body:'Where are we?',time:'10:00',live:true},{id:'t1',who:'chief',live:true,status:'completed',teamUpdate:true,body:'Forge is blocked.',teamDetail:'The longer explanation.',teamSources:[{agentId:'chief',title:'Chat'}],teamCheckedAt:'2026-10-19T08:00:00Z',teamCheckStatus:'completed',time:'10:01'}],lyra:[]};
   state.drafts={chief:'Tell me more',lyra:''};state.runs={};state.groups=[];state.onboarding={status:'completed',agentId:'chief'};ui.view={kind:'chat',target:'chief'};
   window.saved=0;window.BuddyDesktop={saveState:async()=>{saved++;return {saved:true};},sendMessage:async()=>({}),worker:async()=>({})};
   render();
  });
  const details=page.locator('#messages details').first();await details.waitFor({timeout:8000});await details.locator('summary').click();assert.equal(await details.evaluate(e=>e.open),true);
  const runId=await page.evaluate(()=>{const r=BuddyChat.begin(state,'chief');return r.run.runId;});
  await page.evaluate(()=>{window.saved=0;});
  for(let i=1;i<=25;i++)await page.evaluate(([id,i])=>window.dispatchEvent(new CustomEvent('buddy-conversation',{detail:{type:'run',runId:id,status:'answering',text:'word '.repeat(i)}})),[runId,i]);
  assert.equal(await page.locator('#messages details').first().evaluate(e=>e.open),true,'the opened section was not closed by the words that kept arriving');
  assert.ok(await page.evaluate(()=>saved)<=2,'25 streamed updates did not cause 25 saves of the whole workspace: '+await page.evaluate(()=>saved));
  await page.evaluate(id=>window.dispatchEvent(new CustomEvent('buddy-conversation',{detail:{type:'run',runId:id,status:'completed',text:'The finished reply.'}})),runId);
  assert.ok(await page.evaluate(()=>saved)>=1,'the finished reply is saved at once');
  // Unread badges are filled in by the activity module after the list is drawn; typing in the search redraws the list.
  await page.evaluate(()=>{window.__painted=0;const original=BuddyActivity.paint;BuddyActivity.paint=(...a)=>{__painted++;return original.apply(BuddyActivity,a);};});
  const search=page.locator('[data-chat-search], input[type="search"], .sidebar input').first();await search.fill('Ly');
  assert.ok(await page.evaluate(()=>__painted)>=1,'searching repaints the unread badges it just replaced');
 }finally{await context?.close();await rm(directory,{recursive:true,force:true});}
});

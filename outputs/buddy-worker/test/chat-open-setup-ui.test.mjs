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
 await page.evaluate(()=>{document.getElementById('onboarding-root').innerHTML='';closeModal();state.onboarding={status:'completed',agentId:'chief'};});
 await page.evaluate(setup);
 return {context,page};
}

test('a chat opens at its newest message and its unread signal goes away; other chats keep theirs',{skip,timeout:60000},async()=>{
 const directory=await mkdtemp(path.join(tmpdir(),'buddy-chat-ui-'));let context,page;
 try{
  ({context,page}=await open(directory,()=>{
   const many=who=>Array.from({length:70},(_,i)=>({id:`${who}-${i}`,who:i%2?who:'you',body:`Message number ${i} `+'with some words to take up room. '.repeat(6),time:'10:00'}));
   state.agents=[{id:'chief',name:'Chief',role:'Chief of staff',description:'Preserve',setupStatus:'ready',avatarShape:'diamond',avatarColor:'lilac',tools:{}},{id:'sage',name:'Sage',role:'Applications',description:'Apply',setupStatus:'ready',avatarShape:'sphere',avatarColor:'blue',tools:{}}];
   state.messages={chief:many('chief'),sage:many('sage')};state.groups=[];state.runs={};ui.lastChat='chief';ui.view={kind:'chat',target:'chief'};
   window.calls=[];
   window.BuddyDesktop={saveState:async()=>({saved:true}),worker:async p=>{calls.push(p);if(p.operation==='notify')return {notifications:Object.fromEntries(p.ids.map(id=>[id,{read:p.read===true,dismissed:false}]))};return {online:true,paused:false,tasks:[],routines:[]};}};
   render();
   BuddyActivity.acceptWorker({workspace:state.conversationWorkspace,tasks:[],routines:[],notifications:{},decisions:[
    {id:'change:1',kind:'confirm',agentId:'sage',taskId:'',title:'Allow this change?',question:'Allow it?',actionLabel:'Allow',payload:{changeId:'1'},createdAt:'2026-10-18T12:00:00Z'},
    {id:'graduated:2',kind:'notice',agentId:'chief',taskId:'',title:'Chief now works without asking',question:'Earned.',actionLabel:'Review rule',payload:{ruleId:'2'},createdAt:'2026-10-18T12:01:00Z'}]});
  }));
  const atBottom=()=>page.evaluate(()=>{const b=document.getElementById('chat-body');return b.scrollHeight>b.clientHeight+200&&b.scrollHeight-b.scrollTop-b.clientHeight<6;});
  await page.waitForFunction(()=>{const b=document.getElementById('chat-body');return b&&b.scrollHeight-b.scrollTop-b.clientHeight<6;},null,{timeout:8000});
  assert.equal(await atBottom(),true,'the first chat opens at the bottom');
  // Opening Chief read Chief's notice; Sage's request to be allowed is still unread, so Sage's row still shows it.
  assert.equal(await page.locator('.chat-row[data-id="chief"] .activity-dot').count(),0,'the opened chat’s signal is gone');
  assert.ok(await page.locator('.chat-row[data-id="sage"] .activity-dot').count()>0,'another chat keeps its signal');
  await page.locator('.chat-row[data-id="sage"]').click();
  await page.waitForFunction(()=>ui.view.target==='sage');
  await page.waitForTimeout(500);
  assert.equal(await atBottom(),true,'the next chat opens at the bottom too');
  assert.equal(await page.locator('.chat-row[data-id="sage"] .activity-dot').count(),0,'opening it cleared its signal');
  assert.ok(await page.evaluate(()=>calls.some(c=>c.operation==='notify'&&c.read===true&&c.ids.includes('decision:change:1'))),'the app is told it was read');
  assert.ok(await page.evaluate(()=>BuddyActivity.collect(state,{workspace:state.conversationWorkspace,tasks:[],decisions:[{id:'change:1',kind:'confirm',agentId:'sage',payload:{changeId:'1'}}],notifications:{'decision:change:1':{read:true,dismissed:false}}}).length===1),'reading keeps the alert listed; nothing is dismissed or approved');
  // Redraws happen all the time (a message arrives, a setting changes). They must not throw the reader back to the top.
  await page.evaluate(()=>{render();render();});await page.waitForTimeout(300);
  assert.equal(await atBottom(),true,'a redraw while at the bottom stays at the bottom');
  await page.evaluate(()=>{document.getElementById('chat-body').scrollTop=600;});
  await page.evaluate(()=>{render();});await page.waitForTimeout(300);
  assert.equal(await page.evaluate(()=>Math.round(document.getElementById('chat-body').scrollTop)),600,'a redraw while reading older messages keeps the place');
  // Reading back to an earlier chat starts at the bottom again, even after scrolling up.
  await page.evaluate(()=>{document.getElementById('chat-body').scrollTop=0;});
  await page.locator('.chat-row[data-id="chief"]').click();
  await page.waitForFunction(()=>ui.view.target==='chief');await page.waitForTimeout(400);
  assert.equal(await atBottom(),true,'coming back to a chat starts at the bottom');
 }finally{await context?.close();await rm(directory,{recursive:true,force:true});}
});

test('an agent with saved instructions can skip its setup questions in one click, in its chat, its settings and its team chat',{skip,timeout:60000},async()=>{
 const directory=await mkdtemp(path.join(tmpdir(),'buddy-setup-ui-'));let context,page;
 try{
  ({context,page}=await open(directory,()=>{
   const pending=(id,name,extra={})=>({id,name,role:name+' lead',description:'You are '+name+'. Own the work and report plainly.',setupStatus:'pending',setupSeed:'seed',avatarShape:'sphere',avatarColor:'blue',tools:{},...extra});
   state.agents=[{id:'chief',name:'Chief',role:'Chief of staff',description:'Preserve',setupStatus:'ready',avatarShape:'diamond',avatarColor:'lilac',tools:{}},pending('lyra','Lyra'),pending('forge','Forge'),pending('vera','Vera',{description:''}),pending('long','Longwinded',{description:'x'.repeat(1600)})];
   state.hiddenAgents=['lyra','forge','vera'];state.messages={chief:[],lyra:[],forge:[],vera:[],long:[],g1:[]};state.groups=[{id:'g1',name:'Omori Volatility Research',objective:'Research',description:'Research',members:['chief','lyra','forge'],managedBy:'chief'},{id:'g2',name:'Mixed',objective:'Research',description:'Research',members:['chief','vera'],managedBy:'chief'}];state.runs={};ui.lastChat='chief';ui.view={kind:'chat',target:'g1'};
   window.calls=[];
   window.BuddyDesktop={saveState:async()=>({saved:true}),worker:async()=>({online:true,paused:false,tasks:[],routines:[]}),agentSetup:async p=>{
    calls.push(p);const base={workspace:state.conversationWorkspace,agentId:p.agentId,messages:[]};
    if(p.action==='begin')return {interview:{...base,status:'interview',revision:1,profileRevision:0,phase:'questions'}};
    if(p.action==='edit')return {interview:{...base,status:'ready',revision:2,profileRevision:1,role:p.role,instructions:p.instructions}};
    return {interview:{...base,status:'interview',revision:1,profileRevision:0}};
   }};
   render();
  }));
  // The team chat says who is not ready and offers the way out.
  await page.locator('.setup-offer').waitFor({timeout:8000});
  const offer=await page.locator('.setup-offer').innerText();
  assert.match(offer,/Lyra and Forge haven’t finished setup/);assert.match(offer,/Use their instructions/);
  await page.getByRole('button',{name:'Use their instructions'}).click();
  await page.waitForFunction(()=>state.agents.find(a=>a.id==='lyra').setupStatus==='ready'&&state.agents.find(a=>a.id==='forge').setupStatus==='ready',null,{timeout:8000});
  const edits=await page.evaluate(()=>calls.filter(c=>c.action==='edit').map(c=>[c.agentId,c.role,c.instructions]));
  assert.deepEqual(edits,[['lyra','Lyra lead','You are Lyra. Own the work and report plainly.'],['forge','Forge lead','You are Forge. Own the work and report plainly.']],'each agent is saved exactly as it was written');
  assert.equal(await page.locator('.setup-offer').count(),0,'the offer goes away once everyone is ready');
  assert.deepEqual(await page.evaluate(()=>state.hiddenAgents),['lyra','forge','vera'],'agents stay hidden from the chat list while the team chat works');
  assert.equal(await page.locator('.chat-list > .chat-row[data-id="lyra"]').count(),0);
  assert.equal(await page.evaluate(()=>state.agents.find(a=>a.id==='lyra').description),'You are Lyra. Own the work and report plainly.');
  // A team whose member has no instructions cannot use them, and says so rather than offering a button that does nothing.
  await page.evaluate(()=>{ui.view={kind:'chat',target:'g2'};render();});
  await page.locator('.setup-offer').waitFor();
  assert.equal(await page.getByRole('button',{name:'Use their instructions'}).isDisabled(),true);
  // The agent's own chat offers it when the instructions are usable, and not when they are too long.
  await page.evaluate(()=>{state.agents.find(a=>a.id==='forge').setupStatus='pending';state.agents.find(a=>a.id==='forge').setupSeed='seed';ui.view={kind:'chat',target:'forge'};render();});
  await page.locator('.setup-offer').waitFor();assert.match(await page.locator('.setup-offer').innerText(),/Forge can start with the instructions already saved/);
  await page.evaluate(()=>{ui.view={kind:'chat',target:'long'};render();});
  assert.equal(await page.locator('.setup-offer').count(),0,'instructions over the limit are not offered');
  await page.evaluate(()=>{state.agents.push({id:'fresh',name:'Fresh',role:'Getting started',description:BuddyAgentSetup.bootstrap,setupStatus:'pending',setupSeed:'seed',tools:{},avatarShape:'cube',avatarColor:'blue'});state.messages.fresh=[];ui.view={kind:'chat',target:'fresh'};render();});
  assert.equal(await page.locator('.setup-offer').count(),0,'a brand-new agent has no job yet, so it is not offered a way to skip learning one');
  // And in the agent's settings, next to "Continue setup in chat".
  await page.evaluate(()=>{state.agents.find(a=>a.id==='forge').setupStatus='pending';agentInfo('forge');});
  await page.locator('#bot-settings [data-setup-use="forge"]').waitFor({timeout:8000});
  await page.locator('#bot-settings [data-setup-use="forge"]').click();
  await page.waitForFunction(()=>state.agents.find(a=>a.id==='forge').setupStatus==='ready'&&!document.getElementById('bot-settings'),null,{timeout:8000});
 }finally{await context?.close();await rm(directory,{recursive:true,force:true});}
});

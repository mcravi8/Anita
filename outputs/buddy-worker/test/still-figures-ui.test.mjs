import test from 'node:test';import assert from 'node:assert/strict';import {chromium} from 'playwright-core';import {mkdtemp,rm} from 'node:fs/promises';import {existsSync} from 'node:fs';import {tmpdir} from 'node:os';import {join} from 'node:path';
// Buddy's logo (the sidebar's header and its workspace button) and the figure in a chat's floating header are still pictures: they do not
// blink, glance, breathe or show a working ring, while the agent's own figure in the sidebar keeps working.
test('the logo and the chat header’s figure stay still while the agent works',{skip:process.platform!=='darwin'||!existsSync('/Applications/Google Chrome.app'),timeout:60000},async()=>{
 const dir=await mkdtemp(join(tmpdir(),'buddy-still-figures-'));let context;
 try{
  context=await chromium.launchPersistentContext(join(dir,'browser.noindex'),{channel:'chrome',headless:true,viewport:{width:1280,height:860},reducedMotion:'no-preference'});
  await context.route('**/*',r=>/^https?:/.test(r.request().url())?r.abort():r.continue());
  const page=context.pages()[0];const errors=[];page.on('pageerror',e=>errors.push(e.message));
  await page.goto(new URL('../../relay/index.html',import.meta.url).href);await page.waitForFunction(()=>!!window.BuddyFigures);
  await page.evaluate(()=>{
   document.getElementById('onboarding-root').innerHTML='';closeModal();
   state.agents=[{id:'chief',name:'Chief',role:'Chief of staff',avatarShape:'star',avatarColor:'lilac',setupStatus:'ready',tools:{}},{id:'forge',name:'Forge',role:'Builder',avatarShape:'cube',avatarColor:'blue',setupStatus:'ready',tools:{}}];
   state.groups=[{id:'team',name:'Team',members:['chief','forge'],objective:'x',managedBy:'chief',createdAt:'2026-10-19T09:00:00Z'}];
   state.onboarding={status:'completed',agentId:'chief'};state.messages={chief:[],forge:[],team:[]};state.runs={};state.drafts={};state.attachments={};
   navigate('chat','forge');BuddyFigures.setMode('forge','working');
  });
  const island=page.locator('.island .conversation-title canvas[data-fig]');await island.waitFor();
  await page.waitForTimeout(600);
  const look=()=>page.evaluate(()=>{const c=document.querySelector('.island .conversation-title canvas[data-fig]'),logo=BuddyFigures.sim('logo'),forge=BuddyFigures.sim('forge');
   return {island:c.toDataURL(),logo:JSON.stringify([Object.values(logo.S).map(s=>[s.x,s.v]),logo.blinkT,logo.spinT]),forge:forge.prog};});
  const a=await look();await page.waitForTimeout(1500);const b=await look();
  assert.notEqual(a.forge,b.forge,'Forge is working: the live figure moves');
  assert.equal(b.island,a.island,'the chat header’s figure does not move');
  assert.equal(b.logo,a.logo,'the logo keeps its resting pose');
  // The group's header too.
  await page.evaluate(()=>navigate('chat','team'));await page.locator('.island .conversation-title canvas[data-fig="group"]').waitFor();await page.waitForTimeout(600);
  const g=()=>page.evaluate(()=>document.querySelector('.island .conversation-title canvas[data-fig="group"]').toDataURL());
  const g1=await g();await page.waitForTimeout(1500);assert.equal(await g(),g1,'the group’s header picture does not move, even with a member working');
  assert.deepEqual(errors,[]);
 }finally{await context?.close();await rm(dir,{recursive:true,force:true});}
});

import test from 'node:test';
import assert from 'node:assert/strict';
import {chromium} from 'playwright-core';
import {mkdtemp,rm} from 'node:fs/promises';
import {existsSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';

const skip=process.platform!=='darwin'||!existsSync('/Applications/Google Chrome.app');
async function open(directory,{reducedMotion}={}){
 const context=await chromium.launchPersistentContext(path.join(directory,'browser.noindex'),{channel:'chrome',headless:true,viewport:{width:1200,height:800},reducedMotion:reducedMotion||'no-preference'});
 await context.route('**/*',r=>/^https?:/.test(r.request().url())?r.abort():r.continue());
 const page=context.pages()[0],errors=[];page.on('pageerror',e=>errors.push(String(e)));
 await page.goto(new URL('../../relay/index.html',import.meta.url).href);
 await page.waitForFunction(()=>!!window.BuddyFigures);
 await page.evaluate(()=>{
  document.getElementById('onboarding-root').innerHTML='';closeModal();
  const agent=(id,name,role,shape,color)=>({id,name,role,description:'x',setupStatus:'ready',avatarShape:shape,avatarColor:color,tools:{}});
  state.onboarding={status:'completed',agentId:'morgan'};
  state.agents=[agent('morgan','Morgan','Chief of staff','diamond','lilac'),agent('atlas','Atlas','Researcher','sphere','blue')];
  state.groups=[];state.messages={morgan:[],atlas:[]};state.runs={};state.tasks=[];state.drafts={};state.attachments={};
  window.BuddyDesktop={saveState:async()=>({saved:true}),worker:async()=>({online:true,paused:false,tasks:[],routines:[]})};
  ui.view={kind:'chat',target:'morgan'};render();
 });
 await page.waitForTimeout(400);
 return {context,page,errors};
}
// How far the panel is from its resting place, in pixels, sampled once per painted frame for a while.
const trackPanel=(page,selector,action,ms=800)=>page.evaluate(({selector,action,ms})=>new Promise(resolve=>{
 const out=[],t0=performance.now();
 const offset=()=>{const el=document.querySelector(selector);if(!el)return null;const m=new DOMMatrixReadOnly(getComputedStyle(el).transform);return Math.round(m.m41);};
 new Function(action)();
 const step=()=>{out.push(offset());if(performance.now()-t0<ms)requestAnimationFrame(step);else resolve(out);};
 requestAnimationFrame(step);
}),{selector,action,ms});

test('a side panel slides in when it opens and slides back out when it closes, and the page is usable while it leaves',{skip,timeout:90000},async()=>{
 const directory=await mkdtemp(path.join(tmpdir(),'buddy-drawer-ui-'));let context,page,errors;
 try{
  ({context,page,errors}=await open(directory));
  const opening=await trackPanel(page,'#modal-root .modal.drawer',"document.querySelector('.conversation-title').click()");
  const slid=opening.filter(v=>v!==null);
  assert.ok(slid[0]>=100,`it starts off to the right (${slid.slice(0,6)})`);
  assert.equal(slid.at(-1),0,'and ends at rest');
  assert.ok(new Set(slid).size>=4,`in several steps, not one jump: ${slid}`);
  assert.deepEqual([...slid].sort((a,b)=>b-a),slid,'in one direction');
  assert.ok(await page.evaluate(()=>getComputedStyle(document.querySelector('#modal-root .drawer-overlay')).opacity)==='1','its dimming has arrived');

  // Changing what an open panel shows does not make it slide again.
  await page.evaluate(()=>chatDetails());await page.waitForTimeout(50);
  assert.equal(await page.evaluate(()=>document.querySelector('#modal-root .modal.drawer').getAnimations().length),0,'no second slide');

  // Closing: the dialog is gone and the page is live at once; a copy of the panel carries on sliding out.
  const closing=await page.evaluate(()=>new Promise(resolve=>{
   const out=[],t0=performance.now();document.querySelector('#modal-root [data-action="close-modal"]').click();
   const state0={dialogs:document.querySelectorAll('#modal-root .modal').length,inert:document.getElementById('app').inert,leaving:document.querySelectorAll('.drawer-leaving').length,ghostIsDialog:document.querySelector('.drawer-leaving')?.getAttribute('role'),ghostInert:document.querySelector('.drawer-leaving')?.inert,ids:document.querySelectorAll('.drawer-leaving [id]').length};
   const step=()=>{const el=document.querySelector('.drawer-leaving > .modal');out.push(el?Math.round(new DOMMatrixReadOnly(getComputedStyle(el).transform).m41):null);if(performance.now()-t0<900)requestAnimationFrame(step);else resolve({state0,out});};
   requestAnimationFrame(step);
  }));
  assert.equal(closing.state0.dialogs,0,'the dialog itself is gone at once');
  assert.equal(closing.state0.inert,false,'the page is usable at once');
  assert.equal(closing.state0.leaving,1,'a copy slides out');
  assert.equal(closing.state0.ghostInert,true,'and cannot be clicked');
  assert.equal(closing.state0.ids,0,'it holds no ids that could clash with the page');
  const out=closing.out.filter(v=>v!==null);
  assert.ok(out.length>=3&&out[0]<60&&out.at(-1)>=250,`it leaves to the right (${out})`);
  assert.deepEqual([...out].sort((a,b)=>a-b),out,'in one direction');
  assert.ok(new Set(out).size>=4,`in several steps: ${out}`);
  assert.equal(closing.out.at(-1),null,'and is gone after');
  assert.equal(await page.locator('.drawer-leaving').count(),0);
  assert.equal(await page.evaluate(()=>document.getElementById('app').inert),false);
  assert.deepEqual(errors,[]);
 }finally{await context?.close();await rm(directory,{recursive:true,force:true});}
});

test('a page drawn again or a panel opened while one is leaving never leaves the page locked',{skip,timeout:90000},async()=>{
 const directory=await mkdtemp(path.join(tmpdir(),'buddy-drawer-lock-'));let context,page;
 try{
  ({context,page}=await open(directory));
  await page.evaluate(()=>chatDetails());await page.waitForTimeout(600);
  // Closed, then the page is redrawn at once (a copy is still on screen): nothing stays inert afterwards.
  await page.evaluate(()=>{closeModal();render();});
  assert.equal(await page.locator('.drawer-leaving').count(),1);
  await page.waitForFunction(()=>!document.querySelector('.drawer-leaving'),null,{timeout:3000});
  assert.equal(await page.evaluate(()=>document.getElementById('app').inert),false,'the page can be used again');
  await page.click('.chat-row[data-id="atlas"]');
  assert.equal(await page.evaluate(()=>ui.view.target),'atlas','and it responds');
  // Opened again while the old one slides out: the new one is the dialog, the old one only a picture.
  await page.evaluate(()=>{chatDetails();});await page.waitForTimeout(600);
  await page.evaluate(()=>{closeModal();chatDetails();});
  assert.equal(await page.locator('#modal-root .modal.drawer').count(),1);
  assert.equal(await page.locator('[role=dialog]').count(),1,'only one dialog for the page to deal with');
  await page.waitForTimeout(900);
  assert.equal(await page.locator('.drawer-leaving').count(),0);
  assert.equal(await page.evaluate(()=>document.getElementById('app').inert),true,'a dialog is open, so the page behind it is held');
  await page.evaluate(()=>closeModal());await page.waitForTimeout(900);
  assert.equal(await page.evaluate(()=>document.getElementById('app').inert),false);
  // A dialog that is not a side panel just closes.
  await page.evaluate(()=>searchModal());await page.evaluate(()=>closeModal());
  assert.equal(await page.locator('.drawer-leaving').count(),0,'only side panels slide');
 }finally{await context?.close();await rm(directory,{recursive:true,force:true});}
});

test('with reduced motion a side panel simply appears and disappears',{skip,timeout:60000},async()=>{
 const directory=await mkdtemp(path.join(tmpdir(),'buddy-drawer-calm-'));let context,page;
 try{
  ({context,page}=await open(directory,{reducedMotion:'reduce'}));
  await page.evaluate(()=>chatDetails());
  assert.equal(await page.locator('.drawer-enter').count(),0);
  assert.equal(await page.evaluate(()=>document.querySelector('#modal-root .modal.drawer').getAnimations().length),0);
  await page.evaluate(()=>closeModal());
  assert.equal(await page.locator('.drawer-leaving').count(),0);
 }finally{await context?.close();await rm(directory,{recursive:true,force:true});}
});

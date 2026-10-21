import test from 'node:test';
import assert from 'node:assert/strict';
import {chromium} from 'playwright-core';
import {mkdtemp,rm} from 'node:fs/promises';
import {existsSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';

const skip=process.platform!=='darwin'||!existsSync('/Applications/Google Chrome.app');
async function open(directory,viewport){
 const context=await chromium.launchPersistentContext(path.join(directory,'browser.noindex'),{channel:'chrome',headless:true,viewport});
 await context.route('**/*',r=>/^https?:/.test(r.request().url())?r.abort():r.continue());
 const page=context.pages()[0];page.on('pageerror',e=>console.error('Fixture page error:',e.message));await page.goto(new URL('../../relay/index.html',import.meta.url).href);
 await page.evaluate(()=>{
  document.getElementById('onboarding-root').innerHTML='';closeModal();state.onboarding={status:'completed',agentId:'chief'};
  state.agents=[{id:'chief',name:'Chief',role:'Chief of staff',description:'Preserve',setupStatus:'ready',avatarShape:'diamond',avatarColor:'lilac',tools:{}}];state.messages={chief:[]};state.groups=[];state.runs={};ui.lastChat='chief';ui.view={kind:'chat',target:'chief'};
  window.BuddyDesktop={saveState:async()=>({saved:true}),worker:async()=>({online:true,paused:false,tasks:[],routines:[]})};render();
 });
 return {context,page};
}
const width=page=>page.evaluate(()=>Math.round(document.querySelector('.sidebar').getBoundingClientRect().width));

test('the sidebar slides between its full and icon-only widths instead of jumping',{skip,timeout:60000},async()=>{
 const directory=await mkdtemp(path.join(tmpdir(),'buddy-motion-ui-'));let context,page;
 try{
  ({context,page}=await open(directory,{width:1200,height:800}));
  const full=await width(page);
  // The icon-only layout is part of the sidebar toggle; without it there is nothing to slide to.
  const narrowed=await page.evaluate(()=>{document.querySelector('.shell').classList.add('sidebar-compact');return new Promise(r=>setTimeout(()=>r(Math.round(document.querySelector('.sidebar').getBoundingClientRect().width)),1000));});
  if(narrowed>=full)return;
  await page.evaluate(()=>document.querySelector('.shell').classList.remove('sidebar-compact'));
  const samples=[];
  for(let i=0;i<8;i++){samples.push(await width(page));await page.waitForTimeout(60);}
  assert.ok(samples[0]<full&&samples.at(-1)>narrowed,`it moves while the time passes: ${samples}`);
  assert.ok(new Set(samples).size>=4,`in several steps, not one jump: ${samples}`);
  assert.deepEqual([...samples].sort((a,b)=>a-b),samples,'and only in one direction');
  await page.waitForTimeout(1000);assert.equal(await width(page),full,'it ends at its full width');
  const closing=[];await page.evaluate(()=>document.querySelector('.shell').classList.add('sidebar-compact'));
  for(let i=0;i<8;i++){closing.push(await width(page));await page.waitForTimeout(60);}
  assert.ok(new Set(closing).size>=4,`closing is gradual too: ${closing}`);
  await page.waitForTimeout(1000);assert.equal(await width(page),narrowed);
  // A person who asked their system for less motion gets none.
  await page.emulateMedia({reducedMotion:'reduce'});
  const straight=await page.evaluate(()=>{document.querySelector('.shell').classList.remove('sidebar-compact');return Math.round(document.querySelector('.sidebar').getBoundingClientRect().width);});
  assert.equal(straight,full,'reduced motion: straight to the new width, in the same moment');
 }finally{await context?.close();await rm(directory,{recursive:true,force:true});}
});

test('on a narrow window the sidebar drawer slides in and out, staying visible until it has left',{skip,timeout:60000},async()=>{
 const directory=await mkdtemp(path.join(tmpdir(),'buddy-motion-ui-'));let context,page;
 try{
  ({context,page}=await open(directory,{width:520,height:800}));
  const state_=()=>page.evaluate(()=>{const s=document.querySelector('.sidebar'),c=getComputedStyle(s);return {left:Math.round(s.getBoundingClientRect().left),visibility:c.visibility};});
  assert.equal((await state_()).visibility,'hidden');
  await page.evaluate(()=>document.querySelector('.sidebar').classList.add('mobile-open'));
  const opening=[];for(let i=0;i<10;i++){opening.push(await state_());await page.waitForTimeout(50);}
  assert.ok(opening.every(s=>s.visibility==='visible'),'visible as soon as it starts to come in');
  assert.ok(new Set(opening.map(s=>s.left)).size>=3,`it slides in: ${opening.map(s=>s.left)}`);
  await page.waitForTimeout(900);assert.equal((await state_()).left,0);
  await page.evaluate(()=>document.querySelector('.sidebar').classList.remove('mobile-open'));
  const closing=[];for(let i=0;i<8;i++){closing.push(await state_());await page.waitForTimeout(50);}
  assert.ok(closing.every(s=>s.visibility==='visible'),'and stays visible while it slides out');
  assert.ok(new Set(closing.map(s=>s.left)).size>=2,`it slides out: ${closing.map(s=>s.left)}`);
  await page.waitForTimeout(900);assert.equal((await state_()).visibility,'hidden');
 }finally{await context?.close();await rm(directory,{recursive:true,force:true});}
});

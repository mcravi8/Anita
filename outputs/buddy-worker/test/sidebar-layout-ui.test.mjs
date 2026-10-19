import test from 'node:test';
import assert from 'node:assert/strict';
import {chromium} from 'playwright-core';
import {mkdtemp,rm} from 'node:fs/promises';
import {existsSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';

const skip=process.platform!=='darwin'||!existsSync('/Applications/Google Chrome.app');
async function open(directory,viewport={width:1100,height:700}){
 const context=await chromium.launchPersistentContext(path.join(directory,'browser.noindex'),{channel:'chrome',headless:true,viewport});
 await context.route('**/*',r=>/^https?:/.test(r.request().url())?r.abort():r.continue());
 const page=context.pages()[0];page.on('pageerror',e=>console.error('Fixture page error:',e.message));await page.goto(new URL('../../relay/index.html',import.meta.url).href);
 await page.evaluate(()=>{
  document.getElementById('onboarding-root').innerHTML='';closeModal();state.onboarding={status:'completed',agentId:'chief'};
  state.agents=['Chief','Lyra','Forge'].map((n,i)=>({id:'a'+i,name:n,role:'Role '+n,description:'d',setupStatus:'ready',avatarShape:'sphere',avatarColor:['lilac','blue','mint'][i],tools:{}}));
  state.messages={a0:[{id:'1',who:'you',body:'Hello',time:'10:00'}],a1:[],a2:[]};state.groups=[{id:'g1',name:'Team',objective:'x',description:'x',members:['a0','a1'],managedBy:'a0'}];state.hiddenAgents=['a2'];state.runs={};ui.lastChat='a0';ui.view={kind:'chat',target:'a0'};
  window.BuddyDesktop={saveState:async()=>({saved:true}),worker:async()=>({online:true,paused:false,tasks:[],routines:[]})};render();
 });
 await page.waitForTimeout(400);
 return {context,page};
}
const probe=page=>page.evaluate(()=>{
 const r=(sel,i=0)=>{const e=document.querySelectorAll(sel)[i];if(!e)return null;const b=e.getBoundingClientRect();return {x:Math.round(b.left),y:Math.round(b.top),w:Math.round(b.width),h:Math.round(b.height)};};
 return {sidebar:r('.sidebar'),bell:r('.activity-nav'),plus:r('[data-action=new-chat]'),toggle:r('.sidebar-layout-toggle'),search:r('.compact-chat-search'),row0:r('.chat-row',0),row1:r('.chat-row',1),row2:r('.chat-row',2),av0:r('.chat-row .fig-slot',0),av1:r('.chat-row .fig-slot',1),hidden:r('.hidden-agents > summary'),desk:r('.worker-nav',0),deskIcon:r('.worker-nav:nth-child(1) svg'),bg:r('.worker-nav',1),ws:r('.workspace-button'),wsLogo:r('.workspace-button .fig-slot'),status:r('.preview-status')};
});
const settle=page=>page.waitForTimeout(1000);

test('the wide sidebar and the rail keep every agent and footer item in the same place',{skip,timeout:90000},async()=>{
 const directory=await mkdtemp(path.join(tmpdir(),'buddy-layout-ui-'));let context,page;
 try{
  ({context,page}=await open(directory));
  const wide=await probe(page);
  assert.deepEqual([wide.row0.y,wide.av0.y,wide.hidden.y],[130,137,349],'the wide layout is as it was');
  await page.evaluate(()=>setSidebarCompact(true));await settle(page);
  const rail=await probe(page);
  assert.equal(rail.sidebar.w,78);
  for(const key of ['row0','row1','row2','av0','av1','hidden','desk','bg','ws','wsLogo','status','deskIcon'])assert.equal(rail[key].y,wide[key].y,`${key} keeps its height`);
  for(const key of ['av0','av1','deskIcon','wsLogo'])assert.equal(rail[key].x,wide[key].x,`${key} keeps its place across`);
  for(const key of ['row0','row1','desk','ws'])assert.equal(rail[key].h,wide[key].h,`${key} keeps its height`);
  // Pictures and footer icons share one vertical axis.
  const axis=r=>r.x+r.w/2;
  assert.deepEqual([axis(wide.av0),axis(wide.deskIcon),axis(wide.wsLogo)].map(Math.round),[39,39,39]);
  // The commands sit in a grid inside the header band, above the first agent, and none overlaps another.
  const cmds=['bell','plus','search','toggle'].map(k=>rail[k]);
  for(const c of cmds){assert.ok(c.y>=52&&c.y+c.h<=rail.row0.y,`a command lies in the header band: ${JSON.stringify(c)}`);assert.ok(c.x>=0&&c.x+c.w<=rail.sidebar.w,'and inside the rail');}
  // Some web engines (the one in the Mac app) clip a positioned child to ANY ancestor that clips, so nothing between a command and the sidebar may.
  const clippers=await page.evaluate(()=>[...document.querySelectorAll('.sidebar-header .icon-button:not(.mobile-sidebar-close),.compact-chat-search')].flatMap(b=>{const out=[];for(let e=b.parentElement;e&&!e.classList.contains('sidebar');e=e.parentElement){const o=getComputedStyle(e);if(o.display!=='contents'&&(o.overflowX!=='visible'||o.overflowY!=='visible'||o.clipPath!=='none'||o.contain.includes('paint')))out.push((b.className||'button').toString().split(' ')[0]+' inside '+e.className);}return out;}));
  assert.deepEqual(clippers,[],'no ancestor between a command and the sidebar clips it');
  assert.equal(rail.sidebar.w,78);
  assert.ok(await page.evaluate(()=>{const s=document.querySelector('.sidebar');return s.scrollWidth<=s.clientWidth;}),'and the wide logo line does not widen the rail');
  const overlap=(a,b)=>a.x<b.x+b.w&&b.x<a.x+a.w&&a.y<b.y+b.h&&b.y<a.y+a.h;
  for(let i=0;i<cmds.length;i++)for(let j=i+1;j<cmds.length;j++)assert.equal(overlap(cmds[i],cmds[j]),false,'no two commands overlap');
  await page.evaluate(()=>setSidebarCompact(false));await settle(page);
  assert.deepEqual(await probe(page),wide,'and back again, everything returns exactly');
 }finally{await context?.close();await rm(directory,{recursive:true,force:true});}
});

test('narrowing and widening glide: the sidebar is not rebuilt, pictures stay still, commands travel with the edge, words fade',{skip,timeout:90000},async()=>{
 const directory=await mkdtemp(path.join(tmpdir(),'buddy-layout-ui-'));let context,page;
 try{
  ({context,page}=await open(directory));
  await page.evaluate(()=>{window.keep=document.querySelector('.sidebar');window.keepRow=document.querySelector('.chat-row');});
  await page.evaluate(()=>setSidebarCompact(true));
  const frames=[];
  for(let i=0;i<14;i++){frames.push(await page.evaluate(()=>{const b=e=>e.getBoundingClientRect();return {w:Math.round(b(document.querySelector('.sidebar')).width),bell:Math.round(b(document.querySelector('.activity-nav')).left),bellY:Math.round(b(document.querySelector('.activity-nav')).top),av:Math.round(b(document.querySelector('.chat-row .fig-slot')).left)+','+Math.round(b(document.querySelector('.chat-row .fig-slot')).top),copy:+getComputedStyle(document.querySelector('.chat-row-copy')).opacity,t:Math.round(performance.now())};}));await page.waitForTimeout(55);}
  assert.equal(await page.evaluate(()=>window.keep===document.querySelector('.sidebar')&&window.keepRow===document.querySelector('.chat-row')),true,'the same sidebar and rows are kept, so they can move');
  const widths=frames.map(f=>f.w);
  assert.ok(widths[0]>200,`it does not jump on the first frame: ${widths}`);
  assert.ok(new Set(widths).size>=8,`it takes many steps: ${widths}`);
  assert.deepEqual([...widths].sort((a,b)=>b-a),widths,'always narrowing');
  const t0=frames[0].t,atThird=frames.find(f=>f.t-t0>=300);
  assert.ok(atThird.w>110,`slow enough to follow: a third of a second in, it is still ${atThird.w}px wide`);
  assert.equal(new Set(frames.map(f=>f.av)).size,1,'the pictures never move');
  const bellXs=frames.map(f=>f.bell),bellYs=frames.map(f=>f.bellY);
  assert.deepEqual([...bellXs].sort((a,b)=>b-a),bellXs,'the notifications button travels in one direction');
  assert.deepEqual([...bellYs].sort((a,b)=>a-b),bellYs,'and settles down into the grid, never back up');
  assert.ok(new Set(bellXs).size>=8&&new Set(bellYs).size>=4,'smoothly, in steps');
  assert.ok(frames.find(f=>f.t-t0>=100).copy<1,'the words are already fading as the edge starts to move');
  assert.ok(frames.some(f=>f.copy>0.05&&f.copy<0.95),'they fade rather than vanish');
  await settle(page);
  const opacity=await page.evaluate(()=>+getComputedStyle(document.querySelector('.chat-row-copy')).opacity);assert.equal(opacity,0);
  // Widening: the words come back late, after most of the width.
  await page.evaluate(()=>setSidebarCompact(false));
  const back=[];for(let i=0;i<14;i++){back.push(await page.evaluate(()=>({w:Math.round(document.querySelector('.sidebar').getBoundingClientRect().width),copy:+getComputedStyle(document.querySelector('.chat-row-copy')).opacity})));await page.waitForTimeout(55);}
  const firstText=back.findIndex(f=>f.copy>0.05);assert.ok(firstText>=3,`words wait for the edge: first visible at frame ${firstText}`);
  assert.ok(back[firstText].w>150,`they appear once there is room: ${back[firstText].w}px`);
  assert.equal(await page.evaluate(()=>window.keep===document.querySelector('.sidebar')),true);
  await settle(page);
  assert.equal(await page.evaluate(()=>document.querySelector('.sidebar-layout-toggle').getAttribute('aria-label')),'Compact sidebar');
 }finally{await context?.close();await rm(directory,{recursive:true,force:true});}
});

test('the rail can always be opened again: the logo opens it, and the page records what it can see of the toggle',{skip,timeout:90000},async()=>{
 const directory=await mkdtemp(path.join(tmpdir(),'buddy-layout-ui-'));let context,page;
 try{
  ({context,page}=await open(directory));
  await page.evaluate(()=>setSidebarCompact(true));await settle(page);
  const seen=await page.evaluate(()=>state.sidebarDiagnostics);
  assert.ok(seen&&seen.compact===true&&seen.toggle&&seen.toggle.hitIsSelf===true&&seen.toggle.visibility==='visible'&&seen.sidebar.w===78,`the toggle is on screen and reachable in the rail, and the page says so: ${JSON.stringify(seen?.toggle)}`);
  // The toggle must be what a person would click: nothing paints or sits over it.
  const topmost=await page.evaluate(()=>{const t=document.querySelector('.sidebar-layout-toggle').getBoundingClientRect();return document.elementFromPoint(t.left+t.width/2,t.top+t.height/2).closest('.sidebar-layout-toggle')!==null;});
  assert.equal(topmost,true);
  await page.locator('.sidebar .buddy-brand').click();await settle(page);
  assert.equal(await page.evaluate(()=>state.sidebarCompact),false,'clicking the logo in the rail opens the sidebar');
  assert.equal((await probe(page)).sidebar.w,290);
  await page.locator('.sidebar .buddy-brand').click();await page.waitForTimeout(300);
  assert.equal(await page.evaluate(()=>state.sidebarCompact),false,'in the wide sidebar the logo does nothing');
 }finally{await context?.close();await rm(directory,{recursive:true,force:true});}
});

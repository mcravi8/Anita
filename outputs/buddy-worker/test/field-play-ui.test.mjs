import test from 'node:test';
import assert from 'node:assert/strict';
import {chromium} from 'playwright-core';
import {mkdtemp,rm} from 'node:fs/promises';
import {existsSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';

const skip=process.platform!=='darwin'||!existsSync('/Applications/Google Chrome.app');
async function open(directory,viewport={width:1200,height:800}){
 const context=await chromium.launchPersistentContext(path.join(directory,'browser.noindex'),{channel:'chrome',headless:true,viewport});
 await context.route('**/*',r=>/^https?:/.test(r.request().url())?r.abort():r.continue());
 const page=context.pages()[0],errors=[];page.on('pageerror',e=>errors.push(String(e)));
 await page.goto(new URL('../../relay/index.html',import.meta.url).href);
 await page.waitForFunction(()=>!!window.BuddyFigures&&!!window.BuddyFieldPlay);
 await page.evaluate(()=>{
  document.getElementById('onboarding-root').innerHTML='';closeModal();
  const agent=(id,name,role,shape,color)=>({id,name,role,description:'x',setupStatus:'ready',avatarShape:shape,avatarColor:color,tools:{}});
  state.onboarding={status:'completed',agentId:'morgan'};
  state.agents=[agent('morgan','Morgan','Chief of staff','diamond','lilac'),agent('atlas','Atlas','Researcher','sphere','blue'),agent('nova','Nova','Builder','hex','peach'),agent('scout','Scout','Reviewer','pill','mint')];
  state.groups=[{id:'launch',name:'Website launch',members:['morgan','atlas','nova','scout'],objective:'Ship it.'}];
  state.messages={morgan:[{id:'a1',who:'you',body:'Can you help me get my portfolio ready?',time:'10:14'},{id:'a2',who:'morgan',body:'Of course.',time:'10:15'}],atlas:[],nova:[],scout:[],launch:[]};
  state.runs={};state.tasks=[];state.drafts={};state.attachments={};
  window.BuddyDesktop={saveState:async()=>({saved:true}),worker:async()=>({online:true,paused:false,tasks:[],routines:[]})};
  ui.view={kind:'chat',target:'morgan'};render();
 });
 await page.waitForTimeout(500);
 return {context,page,errors};
}
// Lit cells of the sidebar's dot field inside a box given in sidebar coordinates.
const lit=(page,box)=>page.evaluate(({x,y,w,h})=>{
 const f=document.querySelector('canvas.sidebar-field'),fr=f.getBoundingClientRect(),dpr=f.width/fr.width;
 const d=f.getContext('2d').getImageData(Math.max(0,Math.round(x*dpr)),Math.max(0,Math.round(y*dpr)),Math.round(w*dpr),Math.round(h*dpr)).data;
 let n=0;for(let i=3;i<d.length;i+=4)if(d[i]>140)n++;return n;
},box);
const geometry=(page,id)=>page.evaluate(id=>{
 const side=document.querySelector('.sidebar').getBoundingClientRect(),row=document.querySelector(`.chat-row[data-id="${id}"]`).getBoundingClientRect(),slot=document.querySelector(`.chat-row[data-id="${id}"] .fig-slot`).getBoundingClientRect();
 return {rowRight:row.right-side.left,rowTop:row.top-side.top,cx:slot.left-side.left+slot.width/2,cy:slot.top-side.top+slot.height/2,half:slot.width/2};
},id);

test('the chat header is a floating pill: name and figure always, subtitle and actions slide out of it, and it is never rebuilt to do so',{skip,timeout:90000},async()=>{
 const directory=await mkdtemp(path.join(tmpdir(),'buddy-island-ui-'));let context,page,errors;
 try{
  ({context,page,errors}=await open(directory));
  const header=await page.evaluate(()=>{const h=document.querySelector('.conversation-header'),i=document.querySelector('.island').getBoundingClientRect(),m=document.querySelector('.main-shell,.center').getBoundingClientRect();return {position:getComputedStyle(h).position,radius:parseFloat(getComputedStyle(document.querySelector('.island')).borderTopLeftRadius),pillW:Math.round(i.width),centered:Math.abs((i.left+i.width/2)-(m.left+m.width/2))<40,top:Math.round(i.top)};});
  assert.equal(header.position,'absolute','the header floats over the conversation');
  assert.ok(header.radius>=20,'it is a pill');assert.ok(header.centered,'centred over the conversation');assert.ok(header.top<30,'near the top');
  assert.equal(await page.locator('.conversation-title h1').textContent(),'Morgan');
  assert.equal(await page.locator('.conversation-subtitle').textContent(),'Chief of staff','the subtitle is in the page even while it is tucked away');
  assert.equal(await page.locator('.island-toggle').getAttribute('aria-expanded'),'false');
  assert.equal(await page.locator('.island-more').getAttribute('inert'),'','the tucked-away actions cannot be tabbed to or clicked');
  assert.equal(await page.locator('.island-more').getAttribute('aria-hidden'),'true');
  const closedW=await page.evaluate(()=>Math.round(document.querySelector('.island').getBoundingClientRect().width));
  // The messages scroll under the pill, and the first one starts below it.
  assert.ok(await page.evaluate(()=>document.querySelector('.date-divider').getBoundingClientRect().top>=document.querySelector('.island').getBoundingClientRect().bottom),'the conversation starts below the pill');

  await page.evaluate(()=>{window.__header=document.querySelector('.conversation-header');});
  // Sampled once per painted frame inside the page, so a busy machine cannot make a smooth slide look like a jump.
  const widths=await page.evaluate(()=>new Promise(resolve=>{
   const out=[],t0=performance.now();document.querySelector('.island-toggle').click();
   const step=()=>{out.push(Math.round(document.querySelector('.island').getBoundingClientRect().width));if(performance.now()-t0<700)requestAnimationFrame(step);else resolve(out);};
   requestAnimationFrame(step);
  }));
  assert.ok(widths[0]<widths.at(-1)&&widths.some(w=>w>closedW+10&&w<widths.at(-1)-10),`it slides out through the widths in between, not in one jump: ${widths}`);
  assert.deepEqual([...widths].sort((a,b)=>a-b),widths,'in one direction');
  await page.waitForTimeout(500);
  const openW=await page.evaluate(()=>Math.round(document.querySelector('.island').getBoundingClientRect().width));
  assert.ok(openW>closedW+150,`the actions and subtitle made room (${closedW} to ${openW})`);
  assert.equal(await page.locator('.island-toggle').getAttribute('aria-expanded'),'true');
  assert.equal(await page.locator('.island-more').getAttribute('inert'),null);
  assert.equal(await page.evaluate(()=>document.querySelector('.conversation-header')===window.__header),true,'the header element is the same one: it moved, it was not rebuilt');
  assert.ok(await page.evaluate(()=>{const r=document.querySelector('.conversation-subtitle').getBoundingClientRect();return r.width>40&&r.height>8;}),'the subtitle is visible');
  await page.click('.island [data-action="workspace-details"]');
  assert.ok(await page.locator('.modal').count()>=1,'the folder opens shared files');
  await page.evaluate(()=>closeModal());

  // The choice holds when the conversation is drawn again, and when another chat is opened.
  await page.evaluate(()=>{ui.view={kind:'chat',target:'atlas'};render();});await page.waitForTimeout(300);
  assert.equal(await page.locator('.island-toggle').getAttribute('aria-expanded'),'true');
  assert.equal(await page.locator('.conversation-subtitle').textContent(),'Researcher');
  await page.click('.island-toggle');await page.waitForTimeout(600);
  assert.equal(await page.locator('.island-toggle').getAttribute('aria-expanded'),'false');
  assert.equal(await page.locator('.island-more').getAttribute('inert'),'');
  assert.equal(await page.evaluate(()=>Math.round(document.querySelector('.island-more').getBoundingClientRect().width)),0,'it closes back to the name alone');
  // The name still opens the details.
  await page.click('.conversation-title');assert.ok(await page.locator('.modal').count()>=1);
  assert.deepEqual(errors,[]);
 }finally{await context?.close();await rm(directory,{recursive:true,force:true});}
});

test('on a phone-width window the menu button and the pill share the header without overlapping',{skip,timeout:60000},async()=>{
 const directory=await mkdtemp(path.join(tmpdir(),'buddy-island-phone-'));let context,page;
 try{
  ({context,page}=await open(directory,{width:520,height:800}));
  const rects=await page.evaluate(()=>{const r=e=>{const b=document.querySelector(e).getBoundingClientRect();return {l:b.left,r:b.right,t:b.top,b:b.bottom};};return {menu:r('.mobile-menu-button'),island:r('.island'),view:innerWidth};});
  assert.ok(rects.menu.r<=rects.island.l+1,`the menu button is left of the pill (${rects.menu.r} vs ${rects.island.l})`);
  assert.ok(rects.island.r<=rects.view,'the pill fits the window');
  await page.click('.island-toggle');await page.waitForTimeout(600);
  const after=await page.evaluate(()=>{const b=document.querySelector('.island').getBoundingClientRect();return {r:b.right,view:innerWidth};});
  assert.ok(after.r<=after.view+1,'opened, the pill still fits the window');
 }finally{await context?.close();await rm(directory,{recursive:true,force:true});}
});

test('field play: unread counts, roots on opening a chat, a cloud while working, and the flow from the composer',{skip,timeout:90000},async()=>{
 const directory=await mkdtemp(path.join(tmpdir(),'buddy-field-ui-'));let context,page,errors;
 try{
  ({context,page,errors}=await open(directory));
  // Unread: replies that land in other chats are counted and drawn at the right of the row; the chat you are in is not.
  const before=await geometry(page,'nova');
  const digits=g=>lit(page,{x:g.rowRight-22,y:g.cy-6,w:16,h:16});
  const quiet=await digits(before);
  await page.evaluate(()=>{state.messages.nova.push({id:'n1',who:'nova',body:'Draft.',time:'10:30'},{id:'n2',who:'nova',body:'Two.',time:'10:31'});state.messages.morgan.push({id:'a3',who:'morgan',body:'Hi again.',time:'10:32'});});
  await page.waitForFunction(()=>BuddyFieldPlay.state.unread.nova===2);
  assert.deepEqual(await page.evaluate(()=>BuddyFieldPlay.state.unread),{nova:2},'the chat you are looking at is never unread');
  await page.waitForTimeout(1600);
  assert.ok(await page.locator('.chat-row[data-id="nova"].field-unread').count()===1&&await page.locator('.chat-row[data-id="scout"].field-unread').count()===0,'the row with the count leaves room for it');
  const withCount=await digits(before);
  assert.ok(withCount>=quiet+6,`digits are drawn at the right of the row (${quiet} to ${withCount})`);
  assert.ok(await digits(await geometry(page,'scout'))<4,'a row with nothing unread has nothing there (control)');
  // A group counts as one chat.
  await page.evaluate(()=>{state.messages.launch.push({id:'l1',who:'launch',body:'Update',time:'10:33'});});
  await page.waitForFunction(()=>BuddyFieldPlay.state.unread.launch===1);
  // A message that has not finished is not a reply yet.
  await page.evaluate(()=>{state.messages.scout.push({id:'s1',who:'scout',body:'',live:true,status:'answering'});});await page.waitForTimeout(300);
  assert.equal(await page.evaluate(()=>BuddyFieldPlay.state.unread.scout||0),0,'a reply that is still being written is not unread');
  await page.evaluate(()=>{state.messages.scout[0].status='completed';});
  await page.waitForFunction(()=>BuddyFieldPlay.state.unread.scout===1);

  // Opening the chat: it is read, roots grow, and the count goes.
  await page.click('.chat-row[data-id="nova"]');
  await page.waitForFunction(()=>BuddyFieldPlay.state.bursts.some(b=>b.id==='nova'));
  assert.equal(await page.evaluate(()=>BuddyFieldPlay.state.unread.nova),undefined,'opening it reads it');
  assert.equal(await page.locator('.chat-row[data-id="nova"].field-unread').count(),0);
  const roots=await page.evaluate(()=>BuddyFieldPlay.state.bursts.find(b=>b.id==='nova').pts.length);assert.ok(roots>100,`roots have grown: ${roots}`);
  await page.waitForTimeout(1300);
  const row=await geometry(page,'nova');
  const grown=await lit(page,{x:row.cx+row.half+10,y:row.rowTop+4,w:row.rowRight-row.cx-row.half-16,h:56});
  const calmRow=await lit(page,{x:row.cx+row.half+10,y:(await geometry(page,'scout')).rowTop+4,w:row.rowRight-row.cx-row.half-16,h:56});
  assert.ok(grown>calmRow+40,`the row fills with the roots' ink (${grown} against ${calmRow} in another row)`);
  await page.waitForFunction(()=>!BuddyFieldPlay.state.bursts.length,null,{timeout:6000});

  // Working: a cloud appears over the head and goes when the work does.
  const atlas=await geometry(page,'atlas'),cloudBox={x:atlas.cx+2,y:atlas.cy-44,w:30,h:16};
  const noCloud=await lit(page,cloudBox);
  await page.evaluate(()=>BuddyFigures.setMode('atlas','working'));await page.waitForTimeout(900);
  const cloud=await lit(page,cloudBox);
  assert.ok(cloud>=noCloud+25,`a thought cloud over a working agent (${noCloud} to ${cloud})`);
  await page.evaluate(()=>BuddyFigures.setMode('atlas','ready'));await page.waitForTimeout(900);
  assert.ok(await lit(page,cloudBox)<=noCloud+4,'and it is gone when the work stops');

  // Typing: dots flow from the composer, and the agent looks toward you.
  await page.click('.chat-row[data-id="morgan"]');await page.waitForTimeout(300);
  await page.locator('#message-input').fill('');await page.locator('#message-input').pressSequentially('hello there',{delay:30});
  assert.ok(await page.evaluate(()=>BuddyFieldPlay.state.keys.length>0),'typing starts the flow');
  assert.equal(await page.evaluate(()=>BuddyFieldPlay.extension.listening('morgan')),true);
  assert.equal(await page.evaluate(()=>BuddyFieldPlay.extension.listening('atlas')),false);
  await page.waitForTimeout(1700);
  assert.equal(await page.evaluate(()=>BuddyFieldPlay.extension.listening('morgan')),false,'it looks back after you stop');
  assert.deepEqual(errors,[]);
 }finally{await context?.close();await rm(directory,{recursive:true,force:true});}
});

test('field play: agents sleep when idle, wake one by one when chosen, and a failing effect never stops the rest',{skip,timeout:90000},async()=>{
 const directory=await mkdtemp(path.join(tmpdir(),'buddy-sleep-ui-'));let context,page,errors;
 try{
  ({context,page,errors}=await open(directory));
  const eyes=id=>page.evaluate(id=>BuddyFigures.sim(id).S.open.x,id);
  assert.ok(await eyes('atlas')>.8,'awake eyes are open');
  await page.evaluate(()=>{BuddyFieldPlay.state.sleepAfter=.6;});
  await page.waitForFunction(()=>BuddyFieldPlay.state.asleep,null,{timeout:8000});
  await page.waitForTimeout(900);
  assert.ok(await eyes('atlas')<.2&&await eyes('scout')<.2,'idle agents have shut their eyes');
  assert.ok(await eyes('morgan')<.2,'including the one whose chat is open');
  assert.ok(await page.evaluate(()=>BuddyFigures.sim('logo').S.open.x)>.8,'the logo never sleeps');
  await page.waitForTimeout(1500);
  assert.ok(await page.evaluate(()=>BuddyFieldPlay.state.zzz.length>0),'sleepers breathe out z’s');
  // Choosing an agent wakes that one only.
  await page.evaluate(()=>{BuddyFieldPlay.state.sleepAfter=600;});
  await page.click('.chat-row[data-id="atlas"]');await page.waitForTimeout(900);
  assert.ok(await eyes('atlas')>.8,'the chosen agent woke up');
  assert.ok(await eyes('scout')<.2&&await eyes('nova')<.2,'the others sleep on');
  // A working agent is awake whatever the rest do.
  await page.evaluate(()=>BuddyFigures.setMode('scout','working'));await page.waitForTimeout(900);
  assert.ok(await eyes('scout')>.7,'work wakes an agent');
  await page.evaluate(()=>BuddyFigures.setMode('scout','ready'));
  // Waking everyone ends the sleep.
  for(const id of ['nova','scout','morgan']){await page.click(`.chat-row[data-id="${id}"]`);await page.waitForTimeout(150);}
  assert.equal(await page.evaluate(()=>BuddyFieldPlay.state.asleep),false,'everyone has been chosen: nobody sleeps');
  await page.waitForTimeout(900);assert.ok(await eyes('nova')>.8);

  // An effect that throws is reported and skipped; the figures, the field and the other effects carry on.
  await page.evaluate(()=>{window.__broken=0;BuddyFigures.extend({frame(){window.__broken++;throw new Error('frame failed');},field(){throw new Error('field failed');},listening(){throw new Error('listening failed');},sleeping(){throw new Error('sleeping failed');}});});
  await page.evaluate(()=>{state.messages.nova.push({id:'late',who:'nova',body:'Still counted.',time:'11:00'});});
  await page.waitForFunction(()=>BuddyFieldPlay.state.unread.nova===1,null,{timeout:5000});
  await page.waitForTimeout(400);
  assert.ok(await page.evaluate(()=>window.__broken)>3,'the broken extension keeps being called');
  const g=await geometry(page,'atlas');assert.ok(await lit(page,{x:g.cx-22,y:g.cy-22,w:44,h:44})>60,'the figures are still painted');
  // Still alive, not just still showing the last picture: new work shows a new cloud, and a finished reply new happy eyes.
  const cloudBox={x:g.cx+2,y:g.cy-44,w:30,h:16},before=await lit(page,cloudBox);
  await page.evaluate(()=>{BuddyFigures.setMode('atlas','working');BuddyFigures.setMode('nova','done');});await page.waitForTimeout(900);
  assert.ok(await lit(page,cloudBox)>=before+25,'the field keeps painting new things');
  assert.ok(await page.evaluate(()=>BuddyFigures.sim('nova').S.happy.x)>.8,'and the figures keep moving');
  assert.deepEqual(errors,[],'and the page itself never errors');
 }finally{await context?.close();await rm(directory,{recursive:true,force:true});}
});

test('with reduced motion the field keeps its signals (unread counts, sleeping eyes, the cloud) and drops the moving effects',{skip,timeout:90000},async()=>{
 const directory=await mkdtemp(path.join(tmpdir(),'buddy-calm-field-ui-'));let context,page;
 try{
  ({context,page}=await open(directory));
  await page.emulateMedia({reducedMotion:'reduce'});await page.evaluate(()=>{BuddyFieldPlay.state.sv=null;});await page.waitForTimeout(300);
  await page.evaluate(()=>{state.messages.nova.push({id:'n1',who:'nova',body:'Draft.',time:'10:30'});});
  await page.waitForFunction(()=>BuddyFieldPlay.state.unread.nova===1);
  await page.waitForTimeout(400);
  assert.equal(await page.evaluate(()=>BuddyFieldPlay.state.arrivals.length),0,'no converging dots');
  const g=await geometry(page,'nova');
  assert.ok(await lit(page,{x:g.rowRight-22,y:g.cy-6,w:16,h:16})>=6,'but the count is there');
  await page.click('.chat-row[data-id="atlas"]');await page.waitForTimeout(400);
  assert.equal(await page.evaluate(()=>BuddyFieldPlay.state.bursts.length),0,'no roots');
  await page.locator('#message-input').pressSequentially('abc',{delay:20});await page.waitForTimeout(150);
  // No patterns forming in the background: the field outside rows and heads stays at its resting dots.
  assert.equal(await page.evaluate(()=>BuddyFieldPlay.state.sv),null,'no background patterns');
  await page.evaluate(()=>BuddyFigures.setMode('scout','working'));await page.waitForTimeout(700);
  const s=await geometry(page,'scout');
  assert.ok(await lit(page,{x:s.cx+2,y:s.cy-44,w:30,h:16})>=20,'a working agent still shows its cloud, held still');
 }finally{await context?.close();await rm(directory,{recursive:true,force:true});}
});

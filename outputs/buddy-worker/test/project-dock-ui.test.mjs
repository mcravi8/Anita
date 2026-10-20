import test from 'node:test';
import assert from 'node:assert/strict';
import {chromium} from 'playwright-core';
import {mkdtemp,rm} from 'node:fs/promises';
import {existsSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';

const skip=process.platform!=='darwin'||!existsSync('/Applications/Google Chrome.app');
const relay=new URL('../../relay/index.html',import.meta.url).href;

// The Mac app's bridge, as far as files go: one connected project folder (or none), its files, and a file viewer.
function fixture({folder,bridge=true}){
 document.getElementById('onboarding-root').innerHTML='';closeModal();
 state.agents=[['chief','Chief'],['atlas','Atlas']].map(([id,name])=>({id,name,role:'Researcher',description:'x',setupStatus:'ready',avatarShape:'star',avatarColor:'lilac',tools:{projectFiles:true}}));
 state.messages={chief:[{id:'u1',who:'you',body:'Summarise the price history in the project, please. '.repeat(6),time:'10:00'}],atlas:[]};state.groups=[];state.runs={};state.drafts={};state.onboarding={status:'completed',agentId:'chief'};ui.lastChat='chief';ui.view={kind:'chat',target:'chief'};
 window.folderValue=folder;window.calls=[];
 window.BuddyDesktop={saveState:async()=>({saved:true}),worker:async p=>p.operation==='status'?{online:true,paused:false,tasks:[],routines:[],decisions:[]}:p.operation==='notify'?{notifications:{}}:{task:null},
  ...(bridge?{
   projectFiles:async id=>{calls.push(['projectFiles',id||null]);await new Promise(r=>setTimeout(r,40));if(!folderValue)throw Error('The shared folder is missing. Choose a folder to reconnect it.');return structuredClone(folderValue);},
   previewProjectFile:async p=>{calls.push(['previewProjectFile',p.path]);return {path:p.path,folderId:p.folderId,format:'text',content:'date,close\n2026-10-19,6001.2',version:'v1',editable:true};},
   projectFileVersion:async()=>({version:'v1'})
  }:{})};
 render();
}
const project={folderId:'prices',name:'Prices',location:'/Users/example/Prices',primary:true,available:true,folders:[{folderId:'prices',name:'Prices',location:'/Users/example/Prices',primary:true,available:true}],files:[{path:'notes.md',bytes:20},{path:'data/SPX_History.csv',bytes:2048}],directories:[{path:'data'}]};
async function open(directory,{width,folder=project,bridge=true,reducedMotion='no-preference'}){
 const context=await chromium.launchPersistentContext(path.join(directory,'browser.noindex'),{channel:'chrome',headless:true,viewport:{width,height:860},reducedMotion});
 await context.route('**/*',r=>/^https?:/.test(r.request().url())?r.abort():r.continue());
 const page=context.pages()[0];const errors=[];page.on('pageerror',e=>errors.push(e.message));
 await page.goto(relay);await page.waitForFunction(()=>!!window.BuddyFiles&&!!window.BuddyWorkerUI);
 await page.evaluate(fixture,{folder,bridge});
 return {context,page,errors};
}
const rect=(page,selector)=>page.locator(selector).first().evaluate(e=>{const b=e.getBoundingClientRect();return {left:b.left,right:b.right,top:b.top,bottom:b.bottom,width:b.width};});
// Wait until the page has asked for the folder and had its answer, so "no dock" means it decided, not that it had not looked yet.
const settled=page=>page.waitForFunction(()=>calls.some(c=>c[0]==='projectFiles')).then(()=>page.waitForTimeout(400));

test('a project folder is docked on the right at a wide window: no overlay, the chat column makes room, and it stays across chats',{skip,timeout:90000},async()=>{
 const directory=await mkdtemp(path.join(tmpdir(),'buddy-project-dock-'));let context;
 try{
  const opened=await open(directory,{width:1440});context=opened.context;const {page,errors}=opened;
  const dock=page.locator('[data-project-dock]');await dock.waitFor({timeout:8000});
  assert.match(await dock.innerText(),/Prices/);assert.match(await dock.innerText(),/notes\.md/);assert.match(await dock.innerText(),/Folder & access/,'the same panel as the Files drawer');
  assert.equal(await page.locator('.modal-overlay').count(),0,'not a modal');
  assert.equal(await page.evaluate(()=>document.getElementById('app').inert),false,'the chat stays usable');
  assert.equal(await dock.evaluate(e=>getComputedStyle(e).animationName),'project-dock-open','it slides in when it first appears');
  await page.waitForTimeout(600);
  const d=await rect(page,'[data-project-dock]'),composer=await rect(page,'.composer'),body=await rect(page,'#chat-body'),center=await rect(page,'.conversation');
  assert.ok(Math.abs(d.right-1440)<=1,'docked to the right edge');
  assert.ok(composer.right<=d.left&&body.right<=d.left&&center.right<=d.left+0.5,'it covers neither the messages nor the composer');
  assert.ok(center.width>=680,'the chat column keeps a comfortable width: '+center.width);
  const hit=await page.evaluate(()=>{const bubble=document.querySelector('#messages .user-bubble');bubble.scrollIntoView({block:'center'});const c=document.querySelector('.composer').getBoundingClientRect(),m=bubble.getBoundingClientRect();const a=document.elementFromPoint(c.right-4,c.top+c.height/2),b=document.elementFromPoint(m.right-4,m.top+m.height/2);return [!!a?.closest('.composer'),!!b?.closest('.user-bubble')];});
  assert.deepEqual(hit,[true,true],'what is at the composer and the messages is the composer and the messages');
  await page.locator('#message-input').fill('Typing while the files are open');assert.equal(await page.evaluate(()=>state.drafts.chief),'Typing while the files are open');
  // Another chat: still docked, and not sliding in again.
  await page.evaluate(()=>navigate('chat','atlas'));await dock.waitFor();
  assert.equal(await dock.evaluate(e=>getComputedStyle(e).animationName),'none','switching chats does not slide it in again');
  assert.match(await dock.innerText(),/notes\.md/);
  // A file opens in the existing viewer.
  await dock.locator('[data-action="project-file"][data-path="notes.md"]').click();
  await page.locator('[data-project-view="notes.md"]').waitFor();assert.deepEqual(await page.evaluate(()=>calls.filter(c=>c[0]==='previewProjectFile')),[['previewProjectFile','notes.md']]);
  // The viewer's "Files" goes back to the docked panel, not a drawer.
  await page.locator('[data-project-view] [data-action="project-files"]').click();
  await page.waitForFunction(()=>!document.querySelector('#modal-root .modal-overlay'));
  assert.equal(await page.locator('#modal-root .drawer').count(),0);
  // The folder button shows the dock (focus moves to it) instead of opening the drawer.
  await page.evaluate(()=>setIsland(true));
  await page.locator('.header-tools [data-action="workspace-details"][data-section="files"]').click();
  await page.waitForTimeout(300);
  assert.equal(await page.locator('#modal-root .modal-overlay').count(),0,'no drawer while docked');
  assert.equal(await page.evaluate(()=>!!document.activeElement?.closest('[data-project-dock]')),true,'focus is on the docked files');
  // New files appear the way they do in the drawer: when the app says the folder changed.
  await page.evaluate(()=>{folderValue.files.push({path:'summary.md',bytes:90});window.dispatchEvent(new CustomEvent('buddy-conversation',{detail:{type:'project-files-changed'}}));});
  await dock.getByText('summary.md').waitFor({timeout:5000});
  assert.deepEqual(errors,[]);
 }finally{await context?.close();await rm(directory,{recursive:true,force:true});}
});

test('the dock follows the room the chat has: off when the window narrows, back when the sidebar gives up space, never overlapping',{skip,timeout:90000},async()=>{
 const directory=await mkdtemp(path.join(tmpdir(),'buddy-project-dock-'));let context;
 try{
  const opened=await open(directory,{width:1440,reducedMotion:'reduce'});context=opened.context;const {page,errors}=opened;
  const dock=page.locator('[data-project-dock]');await dock.waitFor({timeout:8000});
  assert.equal(await dock.evaluate(e=>getComputedStyle(e).animationName),'none','no motion for anyone who asked for less');
  await page.setViewportSize({width:1200,height:860});
  await page.waitForFunction(()=>!document.querySelector('[data-project-dock]'));
  // The sidebar narrowing to a rail gives the chat room again, without the window changing.
  await page.evaluate(()=>{document.querySelector('.shell').style.gridTemplateColumns='78px minmax(0,1fr)';});
  await dock.waitFor({timeout:5000});
  const d=await rect(page,'[data-project-dock]'),composer=await rect(page,'.composer'),center=await rect(page,'.conversation');
  assert.ok(composer.right<=d.left&&center.right<=d.left+0.5&&center.width>=680,JSON.stringify({d,composer,center}));
  await page.evaluate(()=>{document.querySelector('.shell').style.gridTemplateColumns='';});
  await page.waitForFunction(()=>!document.querySelector('[data-project-dock]'));
  // Dark mode reads the same tokens as the rest of the page.
  await page.setViewportSize({width:1440,height:860});await dock.waitFor();
  await page.evaluate(()=>{document.documentElement.dataset.theme='dark';});
  const [panel,card]=await page.evaluate(()=>{const probe=document.createElement('div');probe.style.background='var(--card)';document.body.append(probe);const value=getComputedStyle(probe).backgroundColor;probe.remove();return [getComputedStyle(document.querySelector('[data-project-dock]')).backgroundColor,value];});
  assert.equal(panel,card,'the panel colour is the theme’s card colour');assert.equal(card,'rgb(31, 31, 29)','and that is the dark one');
  assert.deepEqual(errors,[]);
 }finally{await context?.close();await rm(directory,{recursive:true,force:true});}
});

test('at a narrow window nothing is docked and the folder button opens the Files drawer as before',{skip,timeout:90000},async()=>{
 const directory=await mkdtemp(path.join(tmpdir(),'buddy-project-dock-'));let context;
 try{
  const opened=await open(directory,{width:1200,reducedMotion:'reduce'});context=opened.context;const {page,errors}=opened;
  await settled(page);
  assert.equal(await page.locator('[data-project-dock]').count(),0);
  await page.evaluate(()=>setIsland(true));
  await page.locator('.header-tools [data-action="workspace-details"][data-section="files"]').click();
  await page.locator('.modal.drawer [data-project-list] [data-action="project-file"][data-path="notes.md"]').waitFor({timeout:5000});
  assert.deepEqual(errors,[]);
 }finally{await context?.close();await rm(directory,{recursive:true,force:true});}
});

test('no folder, no dock: a missing folder, Buddy’s own empty folder, and the plain browser page',{skip,timeout:90000},async()=>{
 const directory=await mkdtemp(path.join(tmpdir(),'buddy-project-dock-'));let context;
 try{
  const opened=await open(directory,{width:1440,folder:null,reducedMotion:'reduce'});context=opened.context;const {page,errors}=opened;
  await settled(page);
  assert.equal(await page.locator('[data-project-dock]').count(),0,'the folder is missing');
  await page.evaluate(()=>{folderValue={folderId:state.conversationWorkspace,name:'Buddy files',location:'/Users/example/Library/Buddy files',managed:true,primary:true,folders:[],files:[],directories:[]};calls=[];navigate('chat','atlas');});
  await settled(page);
  assert.equal(await page.locator('[data-project-dock]').count(),0,'Buddy’s own folder with nothing in it is not a project');
  await page.evaluate(fixture,{folder:null,bridge:false});
  await page.waitForTimeout(500);
  assert.equal(await page.locator('[data-project-dock]').count(),0,'the plain browser page has no folders');
  assert.deepEqual(errors,[]);
 }finally{await context?.close();await rm(directory,{recursive:true,force:true});}
});

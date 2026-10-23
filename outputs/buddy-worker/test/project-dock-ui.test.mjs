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
// Wait until the page has asked for the folder and had its answer, so "no Files view" means it decided, not that it had not looked yet.
const settled=page=>page.waitForFunction(()=>calls.some(c=>c[0]==='projectFiles')).then(()=>page.waitForTimeout(400));

test('a project folder is the Files view of the chat at any window width: the chat keeps its column, the files take it when chosen',{skip,timeout:90000},async()=>{
 const directory=await mkdtemp(path.join(tmpdir(),'buddy-project-dock-'));let context;
 try{
  const opened=await open(directory,{width:1440,reducedMotion:'reduce'});context=opened.context;const {page,errors}=opened;
  const tabs=page.locator('.conversation-header .island [data-chat-views]');await tabs.getByRole('tab',{name:'Files'}).waitFor({timeout:8000});
  assert.deepEqual(await tabs.getByRole('tab').allInnerTexts(),['Chat','Files'],'the chat, and its files');
  assert.equal(await tabs.getByRole('tab',{name:'Chat'}).getAttribute('aria-selected'),'true','a chat opens on its messages');
  assert.equal(await page.locator('[data-chat-pane]:not([hidden])').count(),0,'nothing beside or over the chat');
  const before=await rect(page,'.conversation');
  await page.locator('#message-input').fill('Typing before looking at the files');
  await tabs.getByRole('tab',{name:'Files'}).click();
  const files=page.locator('[data-chat-pane="files"]');await files.waitFor();
  assert.match(await files.innerText(),/Prices/);assert.match(await files.innerText(),/notes\.md/);assert.match(await files.innerText(),/Folder & access/,'the same folder view as the Files drawer');
  assert.equal(await page.locator('.modal-overlay').count(),0,'not a modal');
  assert.equal(await page.locator('#chat-body').isVisible(),false,'the files take the chat’s place');
  const after=await rect(page,'.conversation');assert.equal(after.width,before.width,'the chat column is the same width either way');
  assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1),true);
  // Back to the chat: what was typed is still there.
  await tabs.getByRole('tab',{name:'Chat'}).click();
  assert.equal(await page.locator('#message-input').inputValue(),'Typing before looking at the files');
  // The tabs move with the arrow keys.
  await tabs.getByRole('tab',{name:'Chat'}).focus();await page.keyboard.press('ArrowRight');
  await files.waitFor();assert.equal(await page.evaluate(()=>document.activeElement?.dataset.chatView),'files');
  // Another chat opens on its messages, with its Files view one tab away.
  await page.evaluate(()=>navigate('chat','atlas'));
  await page.locator('[data-chat-views] [data-chat-view="files"]').waitFor();assert.equal(await page.locator('[data-chat-pane]:not([hidden])').count(),0);
  await page.locator('[data-chat-views] [data-chat-view="files"]').click();
  // A file opens in the existing viewer, and the viewer's Files goes back to the Files view, not a drawer.
  await files.locator('[data-action="project-file"][data-path="notes.md"]').click();
  await page.locator('[data-project-view="notes.md"]').waitFor();assert.deepEqual(await page.evaluate(()=>calls.filter(c=>c[0]==='previewProjectFile')),[['previewProjectFile','notes.md']]);
  await page.locator('[data-project-view] [data-action="project-files"]').click();
  await page.waitForFunction(()=>!document.querySelector('#modal-root .modal-overlay'));
  assert.equal(await page.locator('#modal-root .drawer').count(),0);
  // From the chat, the folder button shows the Files view (focus moves to it) instead of opening a drawer.
  await page.locator('[data-chat-views] [data-chat-view="chat"]').click();
  await page.evaluate(()=>setIsland(true));
  await page.locator('.header-tools [data-action="workspace-details"][data-section="files"]').click();
  await files.waitFor();await page.waitForTimeout(300);
  assert.equal(await page.locator('#modal-root .modal-overlay').count(),0,'no drawer');
  assert.equal(await page.evaluate(()=>!!document.activeElement?.closest('[data-chat-pane="files"]')),true,'focus is on the files');
  // New files appear the way they do in the drawer: when the app says the folder changed.
  await page.evaluate(()=>{folderValue.files.push({path:'summary.md',bytes:90});window.dispatchEvent(new CustomEvent('buddy-conversation',{detail:{type:'project-files-changed'}}));});
  await files.getByText('summary.md').waitFor({timeout:5000});
  // Escape goes back to the chat.
  await page.keyboard.press('Escape');assert.equal(await page.evaluate(()=>document.activeElement?.id),'message-input');
  assert.deepEqual(errors,[]);
 }finally{await context?.close();await rm(directory,{recursive:true,force:true});}
});

test('the Files view works at a narrow window and on a phone, in dark mode, without scrolling sideways',{skip,timeout:90000},async()=>{
 const directory=await mkdtemp(path.join(tmpdir(),'buddy-project-dock-'));let context;
 try{
  const opened=await open(directory,{width:1000,reducedMotion:'reduce'});context=opened.context;const {page,errors}=opened;
  await page.locator('[data-chat-views] [data-chat-view="files"]').click({timeout:8000});
  const files=page.locator('[data-chat-pane="files"]');await files.locator('[data-path="notes.md"]').waitFor();
  await page.setViewportSize({width:390,height:844});
  await page.waitForFunction(()=>innerWidth===390&&!!document.querySelector('[data-chat-pane="files"] [data-path="notes.md"]'));
  await page.evaluate(()=>{document.documentElement.dataset.theme='dark';});
  const look=await page.evaluate(()=>{const island=document.querySelector('.island').getBoundingClientRect(),tabs=document.querySelector('[data-chat-views]').getBoundingClientRect();return {wide:document.documentElement.scrollWidth<=innerWidth+1,inside:tabs.right<=island.right+0.5&&tabs.left>=island.left-0.5,text:getComputedStyle(document.querySelector('.chat-pane-title')).color};});
  assert.equal(look.wide,true,'the page does not scroll sideways');assert.equal(look.inside,true,'the tabs stay inside the chat’s header');assert.notEqual(look.text,'rgb(20, 20, 20)','light text in dark mode');
  assert.deepEqual(errors,[]);
 }finally{await context?.close();await rm(directory,{recursive:true,force:true});}
});

test('no folder, no Files view: a missing folder, Buddy’s own empty folder, and the plain browser page',{skip,timeout:90000},async()=>{
 const directory=await mkdtemp(path.join(tmpdir(),'buddy-project-dock-'));let context;
 try{
  const opened=await open(directory,{width:1440,folder:null,reducedMotion:'reduce'});context=opened.context;const {page,errors}=opened;
  await settled(page);
  assert.equal(await page.locator('[data-chat-views],[data-chat-pane]').count(),0,'the folder is missing');
  await page.evaluate(()=>{folderValue={folderId:state.conversationWorkspace,name:'Buddy files',location:'/Users/example/Library/Buddy files',managed:true,primary:true,folders:[],files:[],directories:[]};calls=[];navigate('chat','atlas');});
  await settled(page);
  assert.equal(await page.locator('[data-chat-views],[data-chat-pane]').count(),0,'Buddy’s own folder with nothing in it is not a project');
  await page.evaluate(fixture,{folder:null,bridge:false});
  await page.waitForTimeout(500);
  assert.equal(await page.locator('[data-chat-views],[data-chat-pane]').count(),0,'the plain browser page has no folders');
  assert.deepEqual(errors,[]);
 }finally{await context?.close();await rm(directory,{recursive:true,force:true});}
});

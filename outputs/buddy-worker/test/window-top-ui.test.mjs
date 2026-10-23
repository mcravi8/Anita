import test from 'node:test';import assert from 'node:assert/strict';import {chromium} from 'playwright-core';import {mkdtemp,rm} from 'node:fs/promises';import {existsSync} from 'node:fs';import {tmpdir} from 'node:os';import {join} from 'node:path';
// In the Mac app the window buttons sit in a 28px strip over the top of the page. The first row comes right under it, on one line across the
// window: the sidebar's logo and commands, the chat's floating header, the bar at the top of the other pages. The user, 23 Oct: the top felt
// very far from the window buttons.
const skip=process.platform!=='darwin'||!existsSync('/Applications/Google Chrome.app');
async function open(dir,reducedMotion){
 const context=await chromium.launchPersistentContext(join(dir,'browser.noindex'),{channel:'chrome',headless:true,viewport:{width:1280,height:860},reducedMotion});
 await context.route('**/*',r=>/^https?:/.test(r.request().url())?r.abort():r.continue());
 const page=context.pages()[0];const errors=[];page.on('pageerror',e=>errors.push(e.message));
 await page.goto(new URL('../../relay/index.html',import.meta.url).href);await page.waitForFunction(()=>!!window.BuddyWorkerUI&&!!window.BuddyProjectDock&&!!window.BuddyFiles);
 await page.evaluate(()=>{
  document.getElementById('onboarding-root').innerHTML='';closeModal();
  state.agents=[{id:'chief',name:'Chief',role:'Chief of staff',avatarShape:'star',avatarColor:'lilac',setupStatus:'ready',tools:{projectFiles:true}},{id:'forge',name:'Forge',role:'Builder',avatarShape:'cube',avatarColor:'blue',setupStatus:'ready',tools:{projectFiles:true}}];
  state.groups=[{id:'team',name:'Omori team',members:['chief','forge'],objective:'EE590 report',managedBy:'chief',createdAt:'2026-10-19T09:00:00Z'}];
  state.onboarding={status:'completed',agentId:'chief'};state.runs={};state.drafts={};state.attachments={};state.proposals=[];state.teamPlans=[];
  state.messages={team:Array.from({length:30},(_,i)=>({id:'u'+i,who:'you',body:'Message number '+i+'. '.repeat(4),time:'10:'+String(i).padStart(2,'0')})),chief:[],forge:[]};
  const plan={id:'p1',groupId:'team',objective:'EE590 report',supervisorId:'chief',status:'draft',revision:1,scope:null,notices:[],run:{state:'draft',working:[],needsYou:0,idleSince:null},
   stages:[{id:'s1',n:1,title:'S01 Protocol freeze',goal:'Freeze the protocol',acceptance:['spec_v1.sha256 saved'],status:'proposed',tasks:[]},{id:'s2',n:2,title:'S02a Pooled relaxation',goal:'Pooled analysis',acceptance:['Timing 3 of 3'],status:'proposed',tasks:[]}]};
  const folder={folderId:'research',name:'Directed Research',location:'/Users/example/Research',primary:true,available:true,folders:[],files:[{path:'stages/S01_protocol/spec_v1.sha256',bytes:80}],directories:[]};
  window.BuddyDesktop={saveState:async()=>({saved:true}),worker:async p=>p.operation==='status'||p.operation==='start'?{workspace:state.conversationWorkspace,online:true,paused:false,tasks:[],routines:[],decisions:[],notifications:{},plans:[plan],pulse:{agents:{}}}:p.operation==='notify'?{notifications:{}}:{task:null},
   projectFiles:async()=>structuredClone(folder),previewProjectFile:async p=>({path:p.path,folderId:p.folderId,format:'text',content:'x',version:'v1',editable:false}),projectFileVersion:async()=>({version:'v1'})};
  navigate('chat','team');
 });
 await page.evaluate(()=>BuddyWorkerUI.refresh(false));
 await page.locator('[data-chat-views] [data-chat-view="files"]').waitFor({timeout:8000});
 return {context,page,errors};
}
const box=(page,selector)=>page.locator(selector).first().evaluate(e=>{const b=e.getBoundingClientRect();return {top:b.top,bottom:b.bottom,mid:b.top+b.height/2};});

test('the first row sits just under the window buttons, on one line across the window, wide and as a rail',{skip,timeout:60000},async()=>{
 const dir=await mkdtemp(join(tmpdir(),'buddy-window-top-'));let context;
 try{
  const opened=await open(dir,'reduce');context=opened.context;const {page,errors}=opened;
  await page.evaluate(()=>{document.documentElement.classList.add('buddy-native-window');document.documentElement.style.setProperty('--titlebar-inset','28px');});
  const logo=await box(page,'.sidebar-header .buddy-brand'),bell=await box(page,'.sidebar-header .activity-nav'),island=await box(page,'.island');
  assert.ok(logo.top>=28&&logo.top<=34,`the logo line starts just under the strip (${logo.top})`);
  assert.ok(Math.abs(bell.mid-logo.mid)<1&&Math.abs(island.mid-logo.mid)<1,`the commands and the chat's header are on the logo's line (${logo.mid}, ${bell.mid}, ${island.mid})`);
  assert.ok(island.top>=28,'the chat’s header is below the strip, where it can be clicked');
  // The messages start under the header, and so does the plan.
  const body=await page.locator('#chat-body').evaluate(e=>e.getBoundingClientRect().top+parseFloat(getComputedStyle(e).paddingTop));
  assert.ok(body>island.bottom+16&&body<island.bottom+32,`the messages start just under the header (${body}, ${island.bottom})`);
  await page.locator('[data-chat-view="plan"][role="tab"]').click();
  const plan=await page.locator('[data-chat-pane="plan"]').evaluate(e=>e.getBoundingClientRect().top+parseFloat(getComputedStyle(e).paddingTop));
  assert.ok(plan>island.bottom+16&&plan<island.bottom+32,`the plan starts just under the header (${plan})`);
  await page.locator('[data-chat-view="chat"][role="tab"]').click();
  // As a rail: the agents stay where they were, and the logo and the commands stay under the strip.
  const agent=await box(page,'.chat-row');
  await page.evaluate(()=>document.querySelector('.shell').classList.add('sidebar-compact'));
  const railLogo=await box(page,'.sidebar-header .buddy-logo, .sidebar-header .buddy-brand'),railBell=await box(page,'.sidebar-header .activity-nav'),railAgent=await box(page,'.chat-row');
  assert.ok(Math.abs(railAgent.top-agent.top)<1,`the agents keep their place (${agent.top} → ${railAgent.top})`);
  assert.ok(railLogo.top>=24&&railBell.top>=railLogo.bottom,`the rail’s logo and commands sit under the strip (${railLogo.top}, ${railBell.top})`);
  assert.ok(railBell.bottom<=railAgent.top,'and above the agents');
  await page.evaluate(()=>document.querySelector('.shell').classList.remove('sidebar-compact'));
  // Another page's bar is on the same line.
  await page.locator('.worker-nav').first().click();await page.locator('.secondary-header').waitFor();
  const back=await box(page,'.secondary-header .border-button');
  assert.ok(Math.abs(back.mid-logo.mid)<1.5,`the page bar is on the logo's line (${back.mid})`);
  // A plain browser page has no strip, and keeps its own room at the top.
  await page.evaluate(()=>{document.documentElement.classList.remove('buddy-native-window');document.documentElement.style.removeProperty('--titlebar-inset');});
  assert.ok((await box(page,'.sidebar-header .buddy-brand')).top>=16,'without the strip the logo keeps its own margin');
  assert.deepEqual(errors,[]);
 }finally{await context?.close();await rm(dir,{recursive:true,force:true});}
});

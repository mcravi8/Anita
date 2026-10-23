import test from 'node:test';
import assert from 'node:assert/strict';
import {chromium} from 'playwright-core';
import {mkdtemp,rm} from 'node:fs/promises';
import {existsSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';

const skip=process.platform!=='darwin'||!existsSync('/Applications/Google Chrome.app');
const relay=new URL('../../relay/index.html',import.meta.url).href;
const LOCATION='/Users/matteo/Desktop/USC/Semester 4/Directed Research';
// Chief’s real reply, word for word, and a teammate’s relative link to a file it saved.
const CHIEF='Stage 4 is complete. [**Open the completed Stage 4 paper draft**](</Users/matteo/Desktop/USC/Semester 4/Directed Research/paper_draft.md>)';
const LEDGER='Corrections are in the [ledger](verification/paper_audit_corrections_2026-10-20.md).';
// The person's shared folder (primary), and a second connected folder whose name starts like the outside path below.
const research={folderId:'research',name:'Directed Research',location:LOCATION,primary:true,available:true};
const other={folderId:'other',name:'Other',location:'/Users/matteo/Documents/Other',primary:false,available:true};
const project={...research,folders:[research,other],files:[{path:'paper_draft.md',bytes:4000},{path:'verification/paper_audit_corrections_2026-10-20.md',bytes:900}],directories:[{path:'verification'}]};

const task=(id,title,assignee,status,extra={})=>({id,title,assignee,kind:'research',status,workerTaskId:'',workerStatus:'',blockedOn:'none',resultSummary:'',updatedAt:'2026-10-20T09:00:00Z',...extra});
function draftPlan(){
 return {id:'p1',groupId:'team',objective:'Finish the directed-research paper',supervisorId:'chief',status:'draft',revision:1,scope:null,notices:[],run:{state:'draft',working:[],needsYou:0,idleSince:null},
  stages:[{id:'s1',n:1,title:'Audit',goal:'Every claim checked',acceptance:['A corrections ledger'],status:'proposed',tasks:[task('t1','Check every citation','lyra','pending'),task('t2','Write the ledger','forge','pending')]},
   {id:'s2',n:2,title:'Draft',goal:'A complete paper',acceptance:['paper_draft.md'],status:'proposed',tasks:[]}]};
}

// The Mac app's bridge, in place before the page loads (a reload gets it again, with what was saved). The worker refuses every go-ahead, so the
// same button can be tapped from the panel and from the card.
function bridge({initial,folder,plans}){
 window.ops=[];window.fileCalls=[];window.saved=[];window.folderValue=folder;window.plansValue=plans;
 window.BuddyDesktop={...(initial?{initialState:initial}:{}),saveState:async json=>{saved.push(json);return {saved:true};},
  worker:async p=>{ops.push(JSON.parse(JSON.stringify(p)));
   if(p.operation==='status'||p.operation==='start')return {online:true,paused:false,tasks:[],routines:[],decisions:[],notifications:{},plans:structuredClone(plansValue),pulse:{agents:{}},supervisorLane:{online:true,busy:false}};
   if(p.operation==='plan')return {error:'Authorizing a stage needs the user’s own words.'};
   if(p.operation==='notify')return {notifications:{}};
   if(p.operation==='detail')return {task:null};
   throw Error('Unexpected fixture operation '+p.operation);},
  projectFiles:async id=>{fileCalls.push(['projectFiles',id||null]);await new Promise(r=>setTimeout(r,30));if(!folderValue)throw Error('The shared folder is missing. Choose a folder to reconnect it.');return structuredClone(folderValue);},
  projectFolders:async()=>({folders:folderValue?structuredClone(folderValue.folders):[]}),
  previewProjectFile:async p=>{fileCalls.push(['previewProjectFile',p.path,p.folderId]);return {path:p.path,folderId:p.folderId,format:'text',content:'# Paper draft',version:'v1',editable:true};},
  projectFileVersion:async()=>({version:'v1'})};
}
function people({messages={}}={}){
 document.getElementById('onboarding-root').innerHTML='';closeModal();
 state.agents=[['chief','Chief'],['lyra','Lyra'],['forge','Forge']].map(([id,name])=>({id,name,role:'Researcher',description:'x',setupStatus:'ready',avatarShape:'star',avatarColor:'lilac',tools:{projectFiles:true}}));
 state.groups=[{id:'team',name:'Paper team',members:['chief','lyra','forge'],objective:'Finish the paper',managedBy:'chief',createdAt:'2026-10-19T09:00:00Z'}];
 state.messages={team:[{id:'u1',who:'you',body:'Where are we with the paper?',time:'10:00'},...(messages.team||[])],chief:[],lyra:messages.lyra||[],forge:messages.forge||[]};
 state.runs={};state.drafts={};state.attachments={};state.proposals=[];state.teamPlans=[];state.onboarding={status:'completed',agentId:'chief'};delete state.projectSidebar;
 navigate('chat','team');
}
async function open(directory,{width=1440,folder=project,plans=[draftPlan()],messages,reducedMotion='reduce'}={}){
 const context=await chromium.launchPersistentContext(path.join(directory,'browser.noindex'),{channel:'chrome',headless:true,viewport:{width,height:900},reducedMotion});
 await context.route('**/*',r=>/^https?:/.test(r.request().url())?r.abort():r.continue());
 await context.addInitScript(bridge,{folder,plans});
 const page=context.pages()[0];const errors=[];page.on('pageerror',e=>errors.push(e.message));page.on('dialog',d=>d.accept());
 await page.goto(relay);await page.waitForFunction(()=>!!window.BuddyFiles&&!!window.BuddyWorkerUI&&!!window.BuddyPlan);
 await page.evaluate(people,{messages});await page.evaluate(()=>BuddyWorkerUI.refresh(false));
 return {context,page,errors};
}
const planArgs=page=>page.evaluate(()=>ops.filter(o=>o.operation==='plan').map(({requestId,...rest})=>rest));

test('the chat offers its plan and its files as views; the plan view holds the whole plan and its buttons, the chat one line that opens it',{skip,timeout:120000},async()=>{
 const directory=await mkdtemp(path.join(tmpdir(),'buddy-project-sidebar-'));let context;
 try{
  const opened=await open(directory);context=opened.context;let {page,errors}=opened;
  const tabs=page.locator('.island [data-chat-views]');await tabs.getByRole('tab',{name:'Files'}).waitFor({timeout:8000});
  assert.deepEqual(await tabs.getByRole('tab').allInnerTexts(),['Chat','Plan','Files'],'the chat, its plan and its files');
  const line=page.locator('.composer-wrap > .stage-strip');await line.waitFor();
  assert.match(await line.innerText(),/Plan ready — which stage should the team get done\?/);
  assert.equal(await page.locator('.composer-wrap .plan-strip').count(),0,'the whole plan is in its view, not above the composer');
  // The plan view, from its tab: always open, with the buttons the person taps.
  await tabs.getByRole('tab',{name:'Plan'}).click();
  const view=page.locator('[data-chat-pane="plan"]');await view.locator('.plan-strip').waitFor();
  await view.getByText('Finish the directed-research paper').waitFor();await view.getByText('Check every citation').waitFor();
  assert.equal(await view.locator('[data-plan-toggle]').count(),0,'in its view the plan is always open');
  assert.equal(await page.locator('.composer').isVisible(),false,'the plan takes the chat’s place');
  await view.getByRole('button',{name:'Get stage 1 done',exact:true}).click();
  await view.getByRole('alert').filter({hasText:'Authorizing a stage needs the user’s own words.'}).waitFor({timeout:8000});
  assert.deepEqual(await planArgs(page),[{operation:'plan',arguments:{action:'authorize',planId:'p1',through:1,quote:'Get stage 1 done'}}]);
  // Files, then the chat again: the line above the composer opens the plan view too.
  await tabs.getByRole('tab',{name:'Files'}).click();
  await page.locator('[data-chat-pane="files"] [data-action="project-file"][data-path="paper_draft.md"]').waitFor();
  assert.equal(await view.isVisible(),false,'one view at a time');
  await tabs.getByRole('tab',{name:'Chat'}).click();await line.click();await view.locator('.plan-strip').waitFor();
  // Another chat opens on its messages; Chief supervises the plan, so Chief's chat offers it as well.
  await page.evaluate(()=>navigate('chat','chief'));
  await page.locator('.composer-wrap > .stage-strip').waitFor();
  assert.equal(await page.locator('[data-chat-view="chat"][role="tab"]').getAttribute('aria-selected'),'true');
  await page.evaluate(()=>navigate('chat','team'));
  // A relaunch: the chat opens on its messages, with the views offered again.
  const last=await page.evaluate(()=>saved.at(-1));
  await context.addInitScript(bridge,{initial:last,folder:project,plans:[draftPlan()]});
  await page.reload();await page.waitForFunction(()=>!!window.BuddyPlan&&!!window.BuddyWorkerUI);
  await page.evaluate(()=>BuddyWorkerUI.refresh(false));
  await page.locator('.composer-wrap > .stage-strip').waitFor({timeout:8000});
  await page.locator('.island [data-chat-views] [data-chat-view="files"]').waitFor({timeout:8000});
  assert.equal(await page.locator('[data-chat-pane]:not([hidden])').count(),0);
  // Dark mode reads the theme’s tokens.
  await page.evaluate(()=>BuddyTheme.choose('dark'));
  const colours=await page.evaluate(()=>{const probe=document.createElement('div');probe.style.background='var(--card)';document.body.append(probe);const card=getComputedStyle(probe).backgroundColor;probe.remove();const line=document.querySelector('.composer-wrap > .stage-strip');return {line:getComputedStyle(line).backgroundColor,card,text:getComputedStyle(line.querySelector('.plan-banner')).color};});
  assert.equal(colours.line,colours.card);assert.equal(colours.card,'rgb(31, 31, 29)');assert.notEqual(colours.text,'rgb(20, 20, 20)','light text in dark mode');
  assert.deepEqual(errors,[]);
 }finally{await context?.close();await rm(directory,{recursive:true,force:true});}
});

test('the views follow what the chat has: a plan alone, files alone, neither; a view that goes away gives back the chat',{skip,timeout:90000},async()=>{
 const directory=await mkdtemp(path.join(tmpdir(),'buddy-project-sidebar-'));let context;
 try{
  const opened=await open(directory,{folder:null});context=opened.context;const {page,errors}=opened;
  const tabs=page.locator('.island [data-chat-views]');await tabs.getByRole('tab',{name:'Plan'}).waitFor({timeout:8000});
  await page.waitForFunction(()=>fileCalls.some(c=>c[0]==='projectFiles'));await page.waitForTimeout(400);
  assert.deepEqual(await tabs.getByRole('tab').allInnerTexts(),['Chat','Plan'],'a plan with no folder: no Files view');
  await tabs.getByRole('tab',{name:'Plan'}).click();await page.locator('[data-chat-pane="plan"] .plan-strip').waitFor();
  // A folder, and the plan is gone: the plan view gives back the chat, and the files are offered.
  await page.evaluate(v=>{window.folderValue=v;window.plansValue=[];},project);
  await page.evaluate(()=>BuddyWorkerUI.refresh(false));await page.evaluate(()=>BuddyFiles.load({persist:false}));
  await tabs.getByRole('tab',{name:'Files'}).waitFor({timeout:5000});
  assert.deepEqual(await tabs.getByRole('tab').allInnerTexts(),['Chat','Files']);
  assert.equal(await page.locator('[data-chat-pane]:not([hidden])').count(),0,'the chat is back');
  assert.equal(await page.locator('#chat-body').isVisible(),true);
  assert.equal(await page.locator('.plan-strip,.stage-strip').count(),0,'no plan anywhere');
  // Neither: no choice to show.
  await page.evaluate(()=>{window.folderValue=null;});await page.evaluate(()=>BuddyFiles.load({persist:false}).catch(()=>{}));
  await page.evaluate(()=>BuddyProjectDock.lost());
  assert.equal(await page.locator('[data-chat-views]').count(),0);
  assert.deepEqual(errors,[]);
 }finally{await context?.close();await rm(directory,{recursive:true,force:true});}
});

test('a link to a file in a connected folder opens it in the viewer; a path outside the folders is not a link',{skip,timeout:90000},async()=>{
 const directory=await mkdtemp(path.join(tmpdir(),'buddy-project-sidebar-'));let context;
 try{
  const messages={team:[
   {id:'c1',who:'chief',body:CHIEF,live:true,status:'completed',time:'10:01'},
   {id:'c2',who:'lyra',body:LEDGER,live:true,status:'completed',time:'10:02'},
   {id:'c3',who:'forge',body:'My old notes are at [notes](</Users/matteo/Documents/Other folder/notes.md>) and [this](javascript:alert(1)).',live:true,status:'completed',time:'10:03'}]};
  const opened=await open(directory,{width:1200,plans:[],messages});context=opened.context;const {page,errors}=opened;
  const link=page.locator('#messages a[data-action="project-file"][data-path="paper_draft.md"]');await link.waitFor({timeout:8000});
  assert.equal(await link.innerText(),'Open the completed Stage 4 paper draft');
  assert.equal(await link.getAttribute('data-folder-id'),'research');
  await link.click();
  await page.locator('[data-project-view="paper_draft.md"]').waitFor({timeout:5000});
  assert.deepEqual(await page.evaluate(()=>fileCalls.filter(c=>c[0]==='previewProjectFile')),[['previewProjectFile','paper_draft.md','research']]);
  assert.equal(await page.evaluate(()=>location.hash),'','the page does not navigate');
  await page.evaluate(()=>closeModal());
  const ledger=page.locator('#messages a[data-action="project-file"][data-path="verification/paper_audit_corrections_2026-10-20.md"]');
  assert.equal(await ledger.getAttribute('data-folder-id'),'research','a relative link is read in the folder the person has open');
  const outside=page.locator('#messages [data-chat-item="c3"]');
  assert.equal(await outside.locator('a').count(),0,'neither the outside path nor javascript: is a link');
  assert.equal(await outside.locator('span[title="/Users/matteo/Documents/Other folder/notes.md"]').innerText(),'notes','the words stay, with the path on hover');
  assert.equal(await page.locator('#messages [href^="javascript"],#messages [href^="file"]').count(),0);
  assert.deepEqual(errors,[]);
 }finally{await context?.close();await rm(directory,{recursive:true,force:true});}
});

test('a stage report in the group chat shows the files that stage’s tasks saved, without anyone asking',{skip,timeout:90000},async()=>{
 const directory=await mkdtemp(path.join(tmpdir(),'buddy-project-sidebar-'));let context;
 try{
  const receipt=(p,date,actorName,kind='created')=>({id:'r-'+p+date,folderId:'research',path:p,revision:'v-'+date,kind,actor:actorName.toLowerCase(),actorName,date});
  const result=(agent,id,files)=>({id:`worker-${id}-1-completed`,who:agent,body:'Done.',live:true,status:'completed',workerTaskID:id,workerStatus:'completed',workerAttempt:1,files,time:'11:00'});
  const messages={lyra:[result('lyra','w1',[receipt('paper_draft.md','2026-10-20T10:00:00Z','Lyra')])],
   forge:[result('forge','w2',[receipt('verification/paper_audit_corrections_2026-10-20.md','2026-10-20T10:30:00Z','Forge'),receipt('paper_draft.md','2026-10-20T11:00:00Z','Forge','edited')])],
   // A report delivered before deliverables were attached: drawn with them, saved as it was.
   team:[{id:'plan-notice-old',who:'chief',body:'Stage 1 — Audit is done (earlier report).',time:'11:20',live:true,status:'completed',planNotice:true,planId:'p1',noticeKind:'stage_report'}]};
  const plan={...draftPlan(),status:'holding',scope:{through:1,quote:'Get stage 1 done',at:'2026-10-20T09:00:00Z',status:'achieved'},run:{state:'stage_done',working:[],needsYou:0,idleSince:null}};
  plan.stages[0]={...plan.stages[0],status:'done',tasks:[task('t1','Check every citation','lyra','done',{workerTaskId:'w1'}),task('t2','Write the ledger','forge','done',{workerTaskId:'w2'})]};
  plan.notices=[{id:'old',kind:'stage_report',text:'Stage 1 — Audit is done (earlier report).',chat:true,status:'open',at:'2026-10-20T11:20:00Z',refs:{stageId:'s1'}},
   {id:'n2',kind:'stage_report',text:'Stage 1 — Audit is done.\n\nNext is Stage 2 — Draft.',chat:true,status:'open',at:'2026-10-20T11:30:00Z',refs:{stageId:'s1'}}];
  const opened=await open(directory,{width:1200,plans:[plan],messages});context=opened.context;const {page,errors}=opened;
  const notice=page.locator('#messages [data-chat-item="plan-notice-n2"]');await notice.waitFor({timeout:8000});
  const cards=notice.locator('.saved-file-cards .artifact-card');
  assert.deepEqual(await cards.locator('strong').allInnerTexts(),['paper_draft.md','paper_audit_corrections_2026-10-20.md'],'one card per file, newest first');
  assert.match(await cards.first().innerText(),/Saved by Forge/,'the latest save of the draft');
  assert.equal(await page.evaluate(()=>state.messages.team.find(m=>m.id==='plan-notice-n2').files.length),2,'kept with the message');
  const earlier=page.locator('#messages [data-chat-item="plan-notice-old"] .saved-file-cards .artifact-card');
  assert.equal(await earlier.count(),2,'an earlier report shows them too');
  assert.equal(await page.evaluate(()=>state.messages.team.find(m=>m.id==='plan-notice-old').files),undefined,'without rewriting what was saved');
  await cards.first().click();
  await page.locator('[data-project-view="paper_draft.md"]').waitFor({timeout:5000});
  assert.deepEqual(errors,[]);
 }finally{await context?.close();await rm(directory,{recursive:true,force:true});}
});

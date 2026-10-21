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

test('the panel holds the plan and the files at a wide window; closed, the plan card is back above the composer; the choice survives a reload',{skip,timeout:120000},async()=>{
 const directory=await mkdtemp(path.join(tmpdir(),'buddy-project-sidebar-'));let context;
 try{
  const opened=await open(directory,{reducedMotion:'no-preference'});context=opened.context;let {page,errors}=opened;
  const dock=page.locator('[data-project-dock]');await dock.locator('.plan-strip').waitFor({timeout:8000});await dock.getByRole('tab',{name:'Files'}).waitFor({timeout:8000});
  assert.deepEqual(await dock.getByRole('tab').allInnerTexts(),['Plan','Files'],'two tabs: the plan and the files');
  assert.equal(await dock.getByRole('tab',{name:'Plan'}).getAttribute('aria-selected'),'true','the plan first');
  await dock.getByText('Finish the directed-research paper').waitFor();await dock.getByText('Check every citation').waitFor();
  assert.equal(await page.locator('.composer-wrap > .plan-strip').count(),0,'the plan is not shown twice');
  assert.equal(await dock.locator('[data-plan-toggle]').count(),0,'in the panel the plan is always open');
  const d=await dock.boundingBox(),composer=await page.locator('.composer').boundingBox();assert.ok(composer.x+composer.width<=d.x,'beside the chat, not over it');
  // Files, then back.
  await dock.getByRole('tab',{name:'Files'}).click();
  await dock.locator('[data-action="project-file"][data-path="paper_draft.md"]').waitFor();
  assert.equal(await dock.locator('.plan-strip').isVisible(),false);
  assert.equal(await page.evaluate(()=>state.projectSidebar.tab),'files','the tab chosen is remembered');
  await dock.getByRole('tab',{name:'Plan'}).click();await dock.locator('.plan-strip').waitFor();
  // The stage button in the panel sends what the card sends: same handler, same words.
  await dock.getByRole('button',{name:'Get stage 1 done',exact:true}).click();
  await dock.getByRole('alert').filter({hasText:'Authorizing a stage needs the user’s own words.'}).waitFor({timeout:8000});
  await dock.getByRole('button',{name:'Change stage 2',exact:true}).click();
  assert.equal(await page.locator('#message-input').inputValue(),'Stage 2: ');await page.locator('#message-input').fill('');
  // Close: it slides away, the plan card is back above the composer, and the open button takes its place in the header.
  await dock.locator('[data-project-dock-close]').click();
  assert.equal(await page.locator('.project-dock.dock-leave').evaluate(e=>getComputedStyle(e).animationName),'project-dock-close','it slides out');
  await page.waitForFunction(()=>!document.querySelector('.project-dock'));
  const card=page.locator('.composer-wrap > .plan-strip');await card.waitFor();
  const opener=page.locator('.conversation-header [data-project-dock-open]');await opener.waitFor();
  assert.equal(await page.evaluate(()=>document.activeElement?.matches('[data-project-dock-open]')),true,'focus moves to the open button');
  assert.equal(await page.evaluate(()=>state.projectSidebar.closed),true);
  assert.equal(await card.locator('[data-plan-toggle]').getAttribute('aria-expanded'),'true','a draft opens by itself, as before');
  await card.getByRole('button',{name:'Get stage 1 done',exact:true}).click();
  await page.waitForFunction(()=>ops.filter(o=>o.operation==='plan').length===2);
  const [fromPanel,fromCard]=await planArgs(page);
  assert.deepEqual(fromPanel,{operation:'plan',arguments:{action:'authorize',planId:'p1',through:1,quote:'Get stage 1 done'}});
  assert.deepEqual(fromCard,fromPanel,'the panel and the card send the same request');
  // Files stay one button away: the folder button opens the Files drawer while the panel is closed.
  await page.evaluate(()=>setIsland(true));
  await page.locator('.header-tools [data-action="workspace-details"][data-section="files"]').click();
  await page.locator('.modal.drawer [data-project-list] [data-path="paper_draft.md"]').waitFor({timeout:5000});
  await page.evaluate(()=>closeModal());
  // Another chat: still closed.
  await page.evaluate(()=>navigate('chat','chief'));await page.locator('.composer-wrap > .plan-strip').waitFor();
  assert.equal(await page.locator('.project-dock').count(),0,'closed in every chat');
  await page.locator('.conversation-header [data-project-dock-open]').waitFor();
  await page.evaluate(()=>navigate('chat','team'));
  // A relaunch: the Mac app hands the page what was saved, and the panel stays closed.
  const last=await page.evaluate(()=>saved.at(-1));assert.equal(JSON.parse(last).projectSidebar.closed,true);
  await context.addInitScript(bridge,{initial:last,folder:project,plans:[draftPlan()]});
  await page.reload();await page.waitForFunction(()=>!!window.BuddyPlan&&!!window.BuddyWorkerUI);
  await page.evaluate(()=>BuddyWorkerUI.refresh(false));
  await page.locator('.composer-wrap > .plan-strip').waitFor({timeout:8000});
  await page.locator('.conversation-header [data-project-dock-open]').waitFor();
  await page.waitForFunction(()=>fileCalls.some(c=>c[0]==='projectFiles'));await page.waitForTimeout(400);
  assert.equal(await page.locator('.project-dock').count(),0,'still closed after the reload');
  // Open again: it slides in, with the plan, and the card above the composer goes.
  await page.locator('.conversation-header [data-project-dock-open]').click();
  await dock.locator('.plan-strip').waitFor();
  assert.equal(await dock.evaluate(e=>getComputedStyle(e).animationName),'project-dock-open','it slides in');
  assert.equal(await page.locator('.composer-wrap > .plan-strip').count(),0);
  assert.equal(await page.locator('[data-project-dock-open]').count(),0,'the open button goes while it is open');
  assert.equal(await page.evaluate(()=>state.projectSidebar.closed),false);
  assert.equal(await page.evaluate(()=>!!document.activeElement?.closest('[data-project-dock]')),true,'focus moves into the panel');
  assert.equal(await dock.getByRole('tab',{name:'Files'}).getAttribute('aria-selected'),'false');
  // Dark mode reads the theme’s tokens.
  await page.evaluate(()=>BuddyTheme.choose('dark'));
  const colours=await page.evaluate(()=>{const probe=document.createElement('div');probe.style.background='var(--card)';document.body.append(probe);const card=getComputedStyle(probe).backgroundColor;probe.remove();return {panel:getComputedStyle(document.querySelector('[data-project-dock]')).backgroundColor,card,text:getComputedStyle(document.querySelector('[data-project-dock] .plan-banner')).color};});
  assert.equal(colours.panel,colours.card);assert.equal(colours.card,'rgb(31, 31, 29)');assert.notEqual(colours.text,'rgb(20, 20, 20)','light text on the dark panel');
  assert.deepEqual(errors,[]);
 }finally{await context?.close();await rm(directory,{recursive:true,force:true});}
});

test('a plan with no folder gets the panel with the plan alone; a folder with no plan, the files alone; too narrow, neither',{skip,timeout:90000},async()=>{
 const directory=await mkdtemp(path.join(tmpdir(),'buddy-project-sidebar-'));let context;
 try{
  const opened=await open(directory,{folder:null});context=opened.context;const {page,errors}=opened;
  const dock=page.locator('[data-project-dock]');await dock.locator('.plan-strip').waitFor({timeout:8000});
  await page.waitForFunction(()=>fileCalls.some(c=>c[0]==='projectFiles'));await page.waitForTimeout(400);
  assert.equal(await dock.getByRole('tab').count(),0,'one section, no tabs');
  assert.equal(await dock.locator('.project-dock-header h2').innerText(),'Plan');
  assert.equal(await dock.locator('[data-project-dock-body]').count(),0,'no files without a folder');
  assert.equal(await page.locator('.composer-wrap > .plan-strip').count(),0);
  // A folder, and the plan is gone: the files alone.
  await page.evaluate(v=>{window.folderValue=v;window.plansValue=[];},project);
  await page.evaluate(()=>BuddyWorkerUI.refresh(false));await page.evaluate(()=>BuddyFiles.load({persist:false}));
  await dock.locator('[data-path="paper_draft.md"]').waitFor({timeout:5000});
  assert.equal(await dock.locator('.plan-strip').count(),0);assert.equal(await dock.getByRole('tab').count(),0);
  assert.equal(await dock.locator('.project-dock-header h2').innerText(),'Files');
  assert.equal(await page.locator('.plan-strip').count(),0,'no plan anywhere');
  // Too narrow: no panel and no open button; the plan card is above the composer.
  await page.evaluate(p=>{window.plansValue=[p];},draftPlan());await page.evaluate(()=>BuddyWorkerUI.refresh(false));
  await dock.locator('.plan-strip').waitFor();
  await page.setViewportSize({width:1200,height:900});
  await page.waitForFunction(()=>!document.querySelector('[data-project-dock]'));
  await page.locator('.composer-wrap > .plan-strip').waitFor();
  assert.equal(await page.locator('[data-project-dock-open]').count(),0,'nothing to open when it would not fit');
  await page.setViewportSize({width:1440,height:900});await dock.locator('.plan-strip').waitFor();
  assert.equal(await page.locator('.composer-wrap > .plan-strip').count(),0);
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

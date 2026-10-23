import test from 'node:test';
import assert from 'node:assert/strict';
import {chromium} from 'playwright-core';
import {mkdtemp,rm} from 'node:fs/promises';
import {existsSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';

const skip=process.platform!=='darwin'||!existsSync('/Applications/Google Chrome.app');
const relay=new URL('../../relay/index.html',import.meta.url).href;
const command='curl -sSfL "https://example.invalid/history?range=max&format=csv" -o data/SPX_History.csv';
const review={id:'cmd',kind:'coding',status:'pending',tool:{name:'Run command outside the sandbox',service:'Buddy coding project',arguments:{command,reason:'Download the price history',project:'/Users/example/Prices'}},questions:[{id:'command',question:'Allow this command to run outside the project sandbox, with network access?',options:[{label:'Accept'},{label:'Decline'}]}]};

// The page as the Mac app shows it: a coding task waiting on one approval, a worker that answers like the native one, and every save kept.
function fixture({review,agents}){
 document.getElementById('onboarding-root').innerHTML='';closeModal();
 state.agents=agents.map(([id,name])=>({id,name,role:'Builder',description:'x',setupStatus:'ready',avatarShape:'star',avatarColor:'lilac',tools:{projectFiles:true,web:true}}));
 state.messages=Object.fromEntries(agents.map(([id])=>[id,[]]));state.groups=[];state.runs={};state.drafts={};state.onboarding={status:'completed',agentId:agents[0][0]};ui.lastChat='coder';ui.view={kind:'chat',target:'coder'};
 window.calls=[];window.saved=[];
 window.fixtureTask={id:'code-task',agentId:'coder',workspace:state.conversationWorkspace,kind:'coding',provider:'chatgpt',title:'Fetch the S&P history',status:'waiting_review',attempt:1,progress:'A coding command needs network access',attentionKey:review.id,updatedAt:'2026-10-20T10:00:00Z',result:'',reviews:[review]};
 window.BuddyDesktop={saveState:async json=>{saved.push(json);return {saved:true};},worker:async p=>{
  calls.push(JSON.parse(JSON.stringify(p)));
  if(p.operation==='status'||p.operation==='start'){const {reviews,...summary}=fixtureTask;return {workspace:state.conversationWorkspace,online:true,paused:false,tasks:[summary],routines:[],decisions:[]};}
  if(p.operation==='detail')return {task:fixtureTask};
  if(p.operation==='notify')return {notifications:{}};
  if(p.operation==='review'){
   await new Promise(r=>setTimeout(r,150));
   const progress=p.cancel?'Operation declined':'Running the approved operation';
   fixtureTask={...fixtureTask,status:'running',progress,attentionKey:progress,updatedAt:'2026-10-20T10:00:10Z',reviews:fixtureTask.reviews.map(r=>({...r,status:p.cancel?'cancelled':'answered'}))};return {accepted:true};
  }
  throw Error('Unexpected fixture operation '+p.operation);
 }};
 render();
}
async function open(directory,options={}){
 const context=await chromium.launchPersistentContext(path.join(directory,'browser.noindex'),{channel:'chrome',headless:true,viewport:{width:1200,height:900},reducedMotion:'reduce'});
 await context.route('**/*',r=>/^https?:/.test(r.request().url())?r.abort():r.continue());
 const page=context.pages()[0];const errors=[];page.on('pageerror',e=>errors.push(e.message));
 await page.goto(relay);await page.waitForFunction(()=>!!window.BuddyWorkerUI);
 await page.evaluate(fixture,{review:options.review||review,agents:options.agents||[['coder','Coder']]});
 await page.locator('.reply-content').filter({hasText:'need your approval'}).waitFor({timeout:8000});
 return {context,page,errors};
}
// Answered, the request leaves the chat; the saved message keeps what was decided (the task's page says it too).
const asked=page=>page.locator('#messages [data-chat-item^="worker-code-task-"]');
const recorded=page=>page.evaluate(()=>state.messages.coder[0].body);
const reviewCalls=page=>page.evaluate(()=>calls.filter(c=>c.operation==='review'));

test('an approval is two buttons; Approve sends what Approve once + Continue sent, once, and the request then leaves the chat, after a reload too',{skip,timeout:60000},async()=>{
 const directory=await mkdtemp(path.join(tmpdir(),'buddy-review-ui-'));let context;
 try{
  const opened=await open(directory);context=opened.context;const {page,errors}=opened;
  await page.getByRole('button',{name:'Review task'}).click();
  const card=page.locator('[data-worker-review="cmd"]');await card.waitFor();
  assert.equal(await card.locator('select').count(),0,'no Choose… list');
  assert.deepEqual(await card.locator('button').allInnerTexts(),['Disapprove','Approve'],'exactly two buttons');
  assert.deepEqual(await card.locator('button').evaluateAll(b=>b.map(x=>x.className)),['border-button','primary-button'],'the same look as the check-the-work buttons');
  assert.match(await card.innerText(),/Allow this command to run outside the project sandbox, with network access\?/,'the question is still there to read');
  await card.getByRole('button',{name:'Approve',exact:true}).dblclick();
  await page.waitForFunction(()=>calls.some(c=>c.operation==='review'));await page.waitForTimeout(500);
  assert.deepEqual(await reviewCalls(page),[{operation:'review',taskId:'code-task',id:'cmd',answers:{command:['Accept']},cancel:false,accept:true}],'one answer, the same body the old Accept + Continue sent');
  await page.evaluate(()=>closeModal());
  await page.waitForFunction(()=>/— approved$/.test(state.messages.coder[0]?.body||''));await asked(page).waitFor({state:'detached'});
  assert.equal(await recorded(page),'Request to run `curl … data/SPX_History.csv` — approved','the message keeps what was decided');
  assert.equal(await page.getByRole('button',{name:'Review task'}).count(),0,'Review task is gone once answered');
  assert.equal(await page.evaluate(()=>state.messages.coder.length),1,'the same message, changed in place');
  await page.evaluate(()=>render());
  assert.equal(await asked(page).count(),0,'a re-render does not bring it back');
  // A reload: the Mac app hands the page what was last saved.
  const last=await page.evaluate(()=>saved.at(-1));assert.match(last,/— approved/);
  await page.addInitScript(raw=>{window.BuddyDesktop={initialState:raw,saveState:async()=>({saved:true}),worker:async p=>p.operation==='status'?{online:true,paused:false,tasks:[],routines:[],decisions:[]}:p.operation==='notify'?{notifications:{}}:{task:null}};},last);
  await page.reload();await page.waitForFunction(()=>!!window.BuddyWorkerUI&&!!document.querySelector('#messages'));
  assert.equal(await asked(page).count(),0,'nor a reload');
  assert.equal(await page.getByRole('button',{name:'Review task'}).count(),0);
  assert.deepEqual(errors,[]);
 }finally{await context?.close();await rm(directory,{recursive:true,force:true});}
});

test('Disapprove sends what Cancel action sent and the request leaves the chat',{skip,timeout:60000},async()=>{
 const directory=await mkdtemp(path.join(tmpdir(),'buddy-review-ui-'));let context;
 try{
  const opened=await open(directory);context=opened.context;const {page,errors}=opened;
  await page.getByRole('button',{name:'Review task'}).click();
  const card=page.locator('[data-worker-review="cmd"]');await card.waitFor();
  await card.getByRole('button',{name:'Disapprove',exact:true}).click();
  await page.waitForFunction(()=>calls.some(c=>c.operation==='review'));
  assert.deepEqual(await reviewCalls(page),[{operation:'review',taskId:'code-task',id:'cmd',answers:{},cancel:true,accept:false}],'the same body the old Cancel action sent');
  await page.evaluate(()=>closeModal());
  await page.waitForFunction(()=>/— disapproved$/.test(state.messages.coder[0]?.body||''));await asked(page).waitFor({state:'detached'});
  assert.equal(await recorded(page),'Request to run `curl … data/SPX_History.csv` — disapproved');
  assert.equal(await page.getByRole('button',{name:'Review task'}).count(),0);
  assert.deepEqual(errors,[]);
 }finally{await context?.close();await rm(directory,{recursive:true,force:true});}
});

test('an approval the supervisor gave leaves the chat, and the message keeps that Chief answered and why',{skip,timeout:60000},async()=>{
 const directory=await mkdtemp(path.join(tmpdir(),'buddy-review-ui-'));let context;
 try{
  const opened=await open(directory,{agents:[['coder','Coder'],['chief','Chief']]});context=opened.context;const {page,errors}=opened;
  await page.evaluate(()=>{fixtureTask={...fixtureTask,status:'running',progress:'Running the approved operation',attentionKey:'Running the approved operation',updatedAt:'2026-10-20T10:00:20Z',reviews:fixtureTask.reviews.map(r=>({...r,status:'answered',answeredBy:'supervisor',answeredByName:'Chief',answerReason:'A read-only download of public prices into the project.',answeredAt:'2026-10-20T10:00:19Z'}))};});
  await page.evaluate(()=>BuddyWorkerUI.refresh(false));
  await page.waitForFunction(()=>/approved by Chief$/.test(state.messages.coder[0]?.body||''),null,{timeout:8000});await asked(page).waitFor({state:'detached'});
  assert.equal(await recorded(page),'Request to run `curl … data/SPX_History.csv` — approved by Chief','answered by Chief, it leaves the chat; the message keeps who answered');
  assert.equal(await page.evaluate(()=>state.messages.coder[0].workerDecision.reason),'A read-only download of public prices into the project.','and why');
  assert.equal(await page.getByRole('button',{name:'Review task'}).count(),0);
  assert.equal(await page.evaluate(()=>calls.some(c=>c.operation==='review')),false,'the page answered nothing itself');
  assert.match(await page.evaluate(()=>saved.at(-1)),/approved by Chief/,'saved with the chat');
  assert.deepEqual(errors,[]);
 }finally{await context?.close();await rm(directory,{recursive:true,force:true});}
});

test('a review that asks a real question keeps its input and its Continue button',{skip,timeout:60000},async()=>{
 const directory=await mkdtemp(path.join(tmpdir(),'buddy-review-ui-'));let context;
 try{
  const question={id:'ask',kind:'browser',status:'pending',tool:{name:'Name the inbox',service:'AgentMail',arguments:{}},questions:[{id:'name',question:'Which name should the inbox use?'}]};
  const opened=await open(directory,{review:question});context=opened.context;const {page}=opened;
  await page.getByRole('button',{name:'Review task'}).click();
  const card=page.locator('[data-worker-review="ask"]');await card.waitFor();
  assert.equal(await card.locator('textarea[data-worker-question="name"]').count(),1);
  assert.deepEqual(await card.locator('button').allInnerTexts(),['Cancel action','Continue']);
 }finally{await context?.close();await rm(directory,{recursive:true,force:true});}
});

test('a command Buddy assessed reads as one plain line of what and why, with the command under Details, and the chat says the same (Chief’s S01 request)',{skip,timeout:60000},async()=>{
 const directory=await mkdtemp(path.join(tmpdir(),'buddy-review-ui-'));let context;
 const assessed={...review,tool:{...review.tool,arguments:{command:"/bin/zsh -lc 'curl -fL --max-time 90 https://download.documentfoundation.org/libreoffice/stable/26.8.1/mac/aarch64/ -o a.html\ncurl -fL --max-time 90 https://arxiv.org/html/2106.07040 -o b.html'",reason:'Allow checking the LibreOffice package URL and an alternate full-text record for the paper?',project:'/Users/example/Files',access:'Runs outside the project sandbox: it can use the network and change files outside the project copy.'}},
  assessment:{routine:true,reason:'2 downloads from download.documentfoundation.org and arxiv.org into the project.',hosts:['download.documentfoundation.org','arxiv.org'],writes:['a.html','b.html']}};
 try{
  const opened=await open(directory,{review:assessed});context=opened.context;const {page,errors}=opened;
  await page.getByRole('button',{name:'Review task'}).click();
  const card=page.locator('[data-worker-review="cmd"]');await card.waitFor();
  assert.equal(await card.locator('strong').first().innerText(),'Coder wants to download 2 files from download.documentfoundation.org and arxiv.org.');
  assert.match(await card.locator(':scope > p').first().innerText(),/^Why: Checking the LibreOffice package URL and an alternate full-text record for the paper\.$/);
  assert.equal(await card.locator('details').evaluate(d=>d.open),false,'the command is folded away under Details');
  assert.equal(await card.locator('details dd').first().isVisible(),false);
  assert.doesNotMatch(await card.evaluate(c=>[...c.children].filter(e=>e.tagName!=='DETAILS').map(e=>e.innerText).join('\n')),/curl|zsh|sandbox|Users\/example/,'no command, path or sandbox wording outside Details');
  assert.deepEqual(await card.locator('.worker-toolbar button').allInnerTexts(),['Disapprove','Approve']);
  await card.locator('details > summary').click();assert.match(await card.locator('details').innerText(),/arxiv\.org\/html\/2106\.07040/,'the exact command is one click away');
  await card.getByRole('button',{name:'Approve',exact:true}).click();
  await page.waitForFunction(()=>calls.some(c=>c.operation==='review'));
  assert.deepEqual(await reviewCalls(page),[{operation:'review',taskId:'code-task',id:'cmd',answers:{command:['Accept']},cancel:false,accept:true}],'the same answer as before');
  await page.evaluate(()=>closeModal());
  await page.waitForFunction(()=>/— approved$/.test(state.messages.coder[0]?.body||''));await asked(page).waitFor({state:'detached'});
  assert.equal(await recorded(page),'Download 2 files from download.documentfoundation.org and arxiv.org — approved');
  assert.deepEqual(errors,[]);
 }finally{await context?.close();await rm(directory,{recursive:true,force:true});}
});

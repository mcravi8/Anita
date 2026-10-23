import test from 'node:test';
import assert from 'node:assert/strict';
import {chromium} from 'playwright-core';
import {mkdtemp,rm} from 'node:fs/promises';
import {existsSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';

// A step on a web page, asked in the agent's chat: it says the site and the account, what to do there, Open the page opens that very page,
// and Done carries on. A coding task's blocked download asks for the file in a connected folder; a step saved without its page says Buddy
// doesn't know which page. The Mac app's bridges are stand-ins that record every call.
const skip=process.platform!=='darwin'||!existsSync('/Applications/Google Chrome.app');
const relay=new URL('../../relay/index.html',import.meta.url).href;
const ARTICLE='https://iopscience.iop.org/article/10.1088/1742-5468/ac498c';

function bridge(){
 window.calls=[];window.ops=[];window.saved=[];window.replies={};window.fixtureWorker={online:true,paused:false,tasks:[],routines:[],decisions:[],notifications:{},plans:[],pulse:{agents:{}},supervisorLane:{online:true,busy:false},signinRequests:[]};
 window.BuddyDesktop={saveState:async json=>{saved.push(json);return {saved:true};},
  worker:async p=>{ops.push(JSON.parse(JSON.stringify(p)));
   if(['status','start'].includes(p.operation))return structuredClone({...fixtureWorker,workspace:state.conversationWorkspace});
   if(p.operation==='detail')return {task:fixtureWorker.tasks.find(t=>t.id===p.taskId)||null};
   if(p.operation==='notify')return {notifications:{}};
   if(p.operation==='browser')return {opened:true,private:true};
   return {};},
  signin:async p=>{calls.push(JSON.parse(JSON.stringify(p)));const next=(replies[p.action]||[]).shift();return next||{};}};
}
function people(){
 document.getElementById('onboarding-root').innerHTML='';closeModal();
 state.agents=[['chief','Chief'],['ada','Ada']].map(([id,name])=>({id,name,role:'Assistant',description:'x',setupStatus:'ready',avatarShape:'star',avatarColor:'lilac',tools:{web:true,desktop:true}}));
 state.groups=[];state.messages={chief:[],ada:[]};
 state.runs={};state.drafts={};state.attachments={};state.proposals=[];state.teamPlans=[];state.activitySeen={};state.activityDismissed={};state.hiddenAgents=[];state.onboarding={status:'completed',agentId:'chief'};
 navigate('chat','chief');
}
async function open(directory){
 const context=await chromium.launchPersistentContext(path.join(directory,'browser.noindex'),{channel:'chrome',headless:true,viewport:{width:1280,height:900},reducedMotion:'reduce'});
 await context.route('**/*',r=>/^https?:/.test(r.request().url())?r.abort():r.continue());
 await context.addInitScript(bridge);
 const page=context.pages()[0];const errors=[];page.on('pageerror',e=>errors.push(e.message));
 await page.goto(relay);await page.waitForFunction(()=>!!window.BuddySignIn&&!!window.BuddyWorkerUI&&!!window.BuddyActivity);
 await page.evaluate(people);
 return {context,page,errors};
}
async function snapshot(page,value){await page.evaluate(v=>{Object.assign(fixtureWorker,v);},value);await page.evaluate(()=>BuddyWorkerUI.refresh(false));}
const task=(id,extra={})=>({id,agentId:'chief',title:'Get the Sethna article',status:'waiting_user',updatedAt:'2026-10-21T00:04:00Z',...extra});

test('a CAPTCHA or a sign-in on a web page names the site and the account, Open the page opens that page, and Done carries on',{skip,timeout:90000},async()=>{
 const directory=await mkdtemp(path.join(tmpdir(),'buddy-web-step-ui-'));let context;
 try{
  const opened=await open(directory);context=opened.context;const {page,errors}=opened;
  const step={key:'step:t1:c1',kind:'step',taskId:'t1',agentId:'chief',need:'captcha',url:ARTICLE,origin:'https://iopscience.iop.org',account:'craviott@usc.edu',instruction:'Tick “I’m not a robot”, then wait for the article to load.',chromeOpen:false,title:'Get the Sethna article'};
  await snapshot(page,{tasks:[task('t1',{checkpoint:{id:'c1',need:'captcha'}})],signinRequests:[step]});
  const message=page.locator('[data-signin-key="step:t1:c1"]');await message.waitFor({timeout:8000});
  await message.getByText('Finish the CAPTCHA on iopscience.iop.org',{exact:true}).waitFor();
  await message.getByText('Account: craviott@usc.edu · For “Get the Sethna article”').waitFor();
  await message.getByText('Tick “I’m not a robot”, then wait for the article to load.').waitFor();
  assert.doesNotMatch(await message.innerText(),/the website/,'never “the website”');
  assert.equal(await message.getByRole('button',{name:'Open Chrome'}).count(),0,'no bare Open Chrome');
  await message.getByRole('button',{name:'Open the page'}).click();
  await message.getByText('Chrome is open at iopscience.iop.org. Finish there, then press Done.').waitFor();
  assert.deepEqual(await page.evaluate(()=>ops.filter(o=>o.operation==='browser')),[{operation:'browser',taskId:'t1',url:ARTICLE}],'Open the page sends the step’s page');
  assert.equal(await message.getByRole('button',{name:'Open the page'}).count(),1,'and stays, to show the page again');
  await page.evaluate(()=>{replies.done=[{done:true,checked:false}];});
  await message.getByRole('button',{name:'Done'}).click();
  await message.waitFor({state:'detached'});await page.locator('#toast').filter({hasText:'Done — Chief is continuing.'}).waitFor();
  assert.deepEqual(await page.evaluate(()=>calls),[{action:'done',taskId:'t1'}]);
  // A sign-in for the task's account says the account in its title.
  const signin={key:'step:t2:c1',kind:'step',taskId:'t2',agentId:'chief',need:'signin',url:'https://mail.google.com/mail/',origin:'https://mail.google.com',account:'craviott@usc.edu',instruction:'Sign in to craviott@usc.edu in Buddy’s Chrome, then press Done.',chromeOpen:false};
  await snapshot(page,{tasks:[task('t2',{checkpoint:{id:'c1',need:'signin'}})],signinRequests:[signin]});
  const second=page.locator('[data-signin-key="step:t2:c1"]');await second.waitFor({timeout:8000});
  await second.getByText('Sign in to mail.google.com as craviott@usc.edu',{exact:true}).waitFor();
  assert.deepEqual(errors,[]);
 }finally{await context?.close();await rm(directory,{recursive:true,force:true});}
});

test('a coding task’s blocked download asks to save the file from that page into the connected folder; Done tells it the file is there',{skip,timeout:90000},async()=>{
 const directory=await mkdtemp(path.join(tmpdir(),'buddy-web-step-file-'));let context;
 try{
  const opened=await open(directory);context=opened.context;const {page,errors}=opened;
  const step={key:'step:t3:c1',kind:'step',taskId:'t3',agentId:'chief',need:'file',url:ARTICLE,origin:'https://iopscience.iop.org',target:'Directed Research/stages/S01_protocol/sources/sethna-2022.pdf',coding:true,instruction:'Use the Download PDF button on the article page.',chromeOpen:false,title:'Get the Sethna article'};
  await snapshot(page,{tasks:[task('t3',{kind:'coding',checkpoint:{id:'c1',need:'file'}})],signinRequests:[step]});
  const message=page.locator('[data-signin-key="step:t3:c1"]');await message.waitFor({timeout:8000});
  await message.getByText('Save the PDF from iopscience.iop.org into Directed Research/stages/S01_protocol/sources',{exact:true}).waitFor();
  await message.getByText(/Name it sethna-2022\.pdf/).waitFor();
  await message.getByText('Use the Download PDF button on the article page.').waitFor();
  assert.doesNotMatch(await message.innerText(),/the website|[Ss]ign in/,'no sign-in is asked of the person');
  await message.getByRole('button',{name:'Open the page'}).click();
  await page.waitForFunction(()=>ops.some(o=>o.operation==='browser'));
  assert.deepEqual(await page.evaluate(()=>ops.filter(o=>o.operation==='browser')),[{operation:'browser',taskId:'t3',url:ARTICLE}]);
  await page.evaluate(()=>{replies.done=[{done:true,checked:false}];});
  await message.getByRole('button',{name:'Done'}).click();
  await message.waitFor({state:'detached'});await page.locator('#toast').filter({hasText:'Done — Chief is continuing.'}).waitFor();
  assert.deepEqual(await page.evaluate(()=>calls),[{action:'done',taskId:'t3'}]);
  assert.deepEqual(errors,[]);
 }finally{await context?.close();await rm(directory,{recursive:true,force:true});}
});

test('a step saved without its page says Buddy doesn’t know which page and to ask the agent, with no Open button',{skip,timeout:90000},async()=>{
 const directory=await mkdtemp(path.join(tmpdir(),'buddy-web-step-unknown-'));let context;
 try{
  const opened=await open(directory);context=opened.context;const {page,errors}=opened;
  const step={key:'step:t4:c1',kind:'step',taskId:'t4',agentId:'chief',need:'signin',origin:null,unknownPage:true,coding:true,instruction:'Sign in in the Chrome window Buddy opened. When you’re finished, press Done.',chromeOpen:false,title:'Get the Sethna article'};
  await snapshot(page,{tasks:[task('t4',{kind:'coding',checkpoint:{id:'c1',need:'signin'}})],signinRequests:[step]});
  const message=page.locator('[data-signin-key="step:t4:c1"]');await message.waitFor({timeout:8000});
  await message.getByText('Buddy doesn’t know which page — ask Chief',{exact:true}).waitFor();
  await message.getByText(/Reply in this chat to ask Chief which page/).waitFor();
  assert.equal(await message.getByRole('button',{name:/Open/}).count(),0,'nothing to open: no blank Chrome window');
  assert.doesNotMatch(await message.innerText(),/the website/);
  await message.getByRole('button',{name:'Reply in chat'}).click();
  assert.equal(await page.evaluate(()=>document.activeElement?.id),'message-input','the reply box takes the focus');
  assert.equal(await message.getByRole('button',{name:'Done'}).count(),1,'Done is still there');
  // The same step with its page found in the task's result opens it.
  await snapshot(page,{signinRequests:[{...step,unknownPage:undefined,url:ARTICLE,origin:'https://iopscience.iop.org',instruction:'Sign in to iopscience.iop.org in the Chrome window Buddy opened. When you’re finished, press Done.'}]});
  await message.getByText('Sign in to iopscience.iop.org',{exact:true}).waitFor();
  await message.getByText(/Chief’s commands can’t use what you sign in to in Chrome/).waitFor();
  await message.getByRole('button',{name:'Open the page'}).click();
  await page.waitForFunction(()=>ops.some(o=>o.operation==='browser'));
  assert.deepEqual(await page.evaluate(()=>ops.filter(o=>o.operation==='browser')),[{operation:'browser',taskId:'t4',url:ARTICLE}]);
  assert.deepEqual(errors,[]);
 }finally{await context?.close();await rm(directory,{recursive:true,force:true});}
});

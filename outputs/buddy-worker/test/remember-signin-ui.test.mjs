import test from 'node:test';
import assert from 'node:assert/strict';
import {chromium} from 'playwright-core';
import {mkdtemp,rm} from 'node:fs/promises';
import {existsSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';

// "Remember for shop.example (ada@example.com)" under a website's password field, on by default; the step a fetch needs, which ends with
// Buddy saving the file; and the remembered sign-ins with Replace and Remove for Background work › Browser sign-in. The Mac app's bridge is
// a stand-in that records every call.
const skip=process.platform!=='darwin'||!existsSync('/Applications/Google Chrome.app');
const relay=new URL('../../relay/index.html',import.meta.url).href;
const SECRET='Shop!pw-41Kx-remember-me',REPLACED='New!pw-77Qa-replaced';

function bridge(){
 window.calls=[];window.ops=[];window.saved=[];window.replies={};window.sitesList=[];
 window.fixtureWorker={online:true,paused:false,tasks:[],routines:[],decisions:[],notifications:{},plans:[],pulse:{agents:{}},supervisorLane:{online:true,busy:false},signinRequests:[]};
 window.BuddyDesktop={saveState:async json=>{saved.push(json);return {saved:true};},
  worker:async p=>{ops.push(JSON.parse(JSON.stringify(p)));
   if(['status','start'].includes(p.operation))return structuredClone({...fixtureWorker,workspace:state.conversationWorkspace});
   if(p.operation==='detail')return {task:fixtureWorker.tasks.find(t=>t.id===p.taskId)||null};
   if(p.operation==='notify')return {notifications:{}};
   return {};},
  signin:async p=>{calls.push(JSON.parse(JSON.stringify(p)));
   if(p.action==='sites')return {sites:structuredClone(sitesList)};
   if(p.action==='removeSite'){sitesList=sitesList.filter(s=>!(s.origin===p.origin&&s.username===p.username));return {removed:true};}
   const next=(replies[p.action]||[]).shift();return next||{};}};
}
function people(){
 document.getElementById('onboarding-root').innerHTML='';closeModal();
 state.agents=[['ada','Ada'],['chief','Chief']].map(([id,name])=>({id,name,role:'Shopper',description:'x',setupStatus:'ready',avatarShape:'star',avatarColor:'lilac',tools:{web:true,desktop:true}}));
 state.groups=[];state.messages={ada:[],chief:[]};state.runs={};state.drafts={};state.attachments={};state.proposals=[];state.teamPlans=[];state.activitySeen={};state.activityDismissed={};state.hiddenAgents=[];state.onboarding={status:'completed',agentId:'ada'};
 navigate('chat','ada');
}
const ask=(extra={})=>({key:'signin:t1:s1',kind:'signin',taskId:'t1',agentId:'ada',reviewId:'r1',mode:'signin',origin:'https://shop.example',account:'ada@example.com',field:'password',step:'password',note:'',attempts:0,choices:['private'],title:'Read my last order',...extra});
async function open(directory){
 const context=await chromium.launchPersistentContext(path.join(directory,'browser.noindex'),{channel:'chrome',headless:true,viewport:{width:1280,height:900},reducedMotion:'reduce'});
 await context.route('**/*',r=>/^https?:/.test(r.request().url())?r.abort():r.continue());
 await context.addInitScript(bridge);
 const page=context.pages()[0];const errors=[];page.on('pageerror',e=>errors.push(e.message));
 await page.goto(relay);await page.waitForFunction(()=>!!window.BuddySignIn&&!!window.BuddyWorkerUI&&!!window.BuddyWebsiteSignIns);
 await page.evaluate(people);
 return {context,page,errors};
}
async function snapshot(page,value){await page.evaluate(v=>{Object.assign(fixtureWorker,v);},value);await page.evaluate(()=>BuddyWorkerUI.refresh(false));}
async function nowhere(page,needle){
 return page.evaluate(n=>{
  const places={dom:document.documentElement.outerHTML,fields:[...document.querySelectorAll('input,textarea')].map(i=>i.value).join('\n'),state:JSON.stringify(state),saved:saved.join('\n'),
   local:Object.keys(localStorage).map(k=>k+'='+localStorage.getItem(k)).join('\n'),worker:JSON.stringify(ops)};
  return Object.entries(places).filter(([,text])=>text.includes(n)).map(([where])=>where);
 },needle);
}

test('a website password field offers “Remember for <site> (<account>)”, on by default; the choice goes with Send, and a code field has none',{skip,timeout:90000},async()=>{
 const directory=await mkdtemp(path.join(tmpdir(),'buddy-remember-'));let context;
 try{
  const opened=await open(directory);context=opened.context;const {page,errors}=opened;
  const task={id:'t1',agentId:'ada',title:'Read my last order',status:'waiting_review',updatedAt:'2026-10-21T09:00:00Z'};
  await snapshot(page,{tasks:[task],signinRequests:[ask()]});
  const message=page.locator('[data-signin-key="signin:t1:s1"]');await message.waitFor({timeout:8000});
  const box=message.getByRole('checkbox',{name:'Remember for shop.example (ada@example.com)'});
  assert.equal(await box.isChecked(),true,'on by default');
  // Turned off, and the chat redrawn: it stays off, and Send says so.
  await box.uncheck();await page.evaluate(()=>refreshLiveChat('ada'));
  assert.equal(await message.getByRole('checkbox',{name:/Remember for shop\.example/}).isChecked(),false,'the choice survives a redraw');
  await page.evaluate(()=>{replies.secret=[{sent:true,signedIn:true}];});
  await message.locator('[data-signin-holder] input').fill(SECRET);await message.getByRole('button',{name:'Send'}).click();
  await message.waitFor({state:'detached'});await page.locator('#toast').filter({hasText:'Sent — signed in'}).waitFor();
  assert.deepEqual(await page.evaluate(()=>calls.at(-1)),{action:'secret',taskId:'t1',reviewId:'r1',value:SECRET,remember:false});
  // Another request: on again by default, and the app says it remembered it.
  await snapshot(page,{signinRequests:[ask({key:'signin:t1:s2',reviewId:'r2'})]});
  const second=page.locator('[data-signin-key="signin:t1:s2"]');await second.waitFor();
  await page.evaluate(()=>{replies.secret=[{sent:true,signedIn:true,remembered:true}];});
  await second.locator('[data-signin-holder] input').fill(SECRET);await second.getByRole('button',{name:'Send'}).click();
  await second.waitFor({state:'detached'});await page.locator('#toast').filter({hasText:'Sent — signed in. Remembered for shop.example.'}).waitFor();
  assert.equal((await page.evaluate(()=>calls.at(-1))).remember,true);
  assert.deepEqual(await nowhere(page,SECRET),[],'what was typed is nowhere on the page');
  // A code field: nothing to remember.
  await snapshot(page,{signinRequests:[ask({key:'signin:t1:s3',reviewId:'r3',field:'code',step:'code'})]});
  const code=page.locator('[data-signin-key="signin:t1:s3"]');await code.waitFor();
  assert.equal(await code.getByRole('checkbox').count(),0);
  await page.evaluate(()=>{replies.secret=[{sent:true,signedIn:true}];});
  await code.locator('[data-signin-holder] input').fill('492011');await code.getByRole('button',{name:'Send'}).click();
  await code.waitFor({state:'detached'});
  assert.ok(!('remember' in await page.evaluate(()=>calls.at(-1))),'a code goes without a Remember choice');
  // An email-first sign-in (Google's own) asks which account, in a plain field, with nothing to remember.
  await snapshot(page,{signinRequests:[ask({key:'signin:t1:s4',reviewId:'r4',field:'username',step:'username',origin:'https://accounts.google.com',account:null})]});
  const user=page.locator('[data-signin-key="signin:t1:s4"]');await user.waitFor();
  const email=user.getByLabel('Email or username for accounts.google.com');
  assert.equal(await email.getAttribute('type'),'email');assert.equal(await user.getByRole('checkbox').count(),0);
  await page.evaluate(()=>{replies.secret=[{sent:true,signedIn:false,retry:true,field:'password',reviewId:'r5',note:'accounts.google.com now asks for your password.'}];});
  await email.fill('craviott@usc.edu');await user.getByRole('button',{name:'Send'}).click();
  await user.getByText('Sent — that didn’t work, try again').or(user.getByText('Sent — the website wants another step.')).first().waitFor();
  assert.deepEqual(await page.evaluate(()=>calls.at(-1)),{action:'secret',taskId:'t1',reviewId:'r4',value:'craviott@usc.edu'});
  assert.deepEqual(errors,[]);
 }finally{await context?.close();await rm(directory,{recursive:true,force:true});}
});

test('a step a fetch needs says Buddy saves the file on Done, not to save it by hand',{skip,timeout:90000},async()=>{
 const directory=await mkdtemp(path.join(tmpdir(),'buddy-fetch-step-'));let context;
 try{
  const opened=await open(directory);context=opened.context;const {page,errors}=opened;
  const url='https://iopscience.iop.org/article/10.1088/1742-5468/ac498c/pdf';
  await snapshot(page,{tasks:[{id:'t9',agentId:'chief',title:'S01 protocol',status:'waiting_user',kind:'coding',updatedAt:'2026-10-21T09:00:00Z'}],
   signinRequests:[{key:'step:t9:c1',kind:'step',taskId:'t9',agentId:'chief',need:'captcha',url,origin:'https://iopscience.iop.org',instruction:'Complete the CAPTCHA on iopscience.iop.org; Buddy will save ac498c.pdf when you press Done.',target:'your project/sources/ac498c.pdf',coding:true,fetch:true,chromeOpen:false}]});
  await page.evaluate(()=>navigate('chat','chief'));
  const message=page.locator('[data-signin-key="step:t9:c1"]');await message.waitFor({timeout:8000});
  await message.getByText('Finish the CAPTCHA on iopscience.iop.org',{exact:true}).waitFor();
  const text=await message.innerText();
  assert.match(text,/Buddy will save ac498c\.pdf when you press Done/);
  assert.match(text,/Buddy’s Chrome fetches it again and saves ac498c\.pdf into your project\/sources/);
  assert.doesNotMatch(text,/ask you for the file instead/,'not the old “a coding session can’t use Chrome” line');
  assert.equal(await message.getByRole('button',{name:'Open the page'}).count(),1);assert.equal(await message.getByRole('button',{name:'Done'}).count(),1);
  assert.deepEqual(errors,[]);
 }finally{await context?.close();await rm(directory,{recursive:true,force:true});}
});

test('remembered website sign-ins show site and account with Replace and Remove; a new password goes only to the bridge',{skip,timeout:90000},async()=>{
 const directory=await mkdtemp(path.join(tmpdir(),'buddy-website-signins-'));let context;
 try{
  const opened=await open(directory);context=opened.context;const {page,errors}=opened;
  await page.evaluate(()=>{sitesList=[{origin:'https://shop.example',username:'ada@example.com',site:'shop.example'},{origin:'https://journal.example',username:'reader@example.org',site:'journal.example'}];
   const holder=document.createElement('section');holder.id='fixture-sites';holder.innerHTML=BuddyWebsiteSignIns.section();document.body.append(holder);});
  const section=page.locator('#fixture-sites [data-website-signins]');
  await section.getByText('journal.example',{exact:true}).waitFor({timeout:8000});
  assert.match(await section.innerText(),/ada@example\.com/);
  const shop=section.locator('[data-website-signin="https://shop.example|ada@example.com"]');
  await shop.getByRole('button',{name:'Replace'}).click();
  const field=shop.getByLabel('New password for shop.example');
  assert.equal(await field.getAttribute('type'),'password');
  await field.fill(REPLACED);await shop.getByRole('button',{name:'Save'}).click();
  await section.getByText('Replaced the password for shop.example.').waitFor();
  assert.deepEqual(await page.evaluate(()=>calls.filter(c=>c.action==='replaceSite')),[{action:'replaceSite',password:REPLACED,origin:'https://shop.example',username:'ada@example.com'}]);
  assert.deepEqual(await nowhere(page,REPLACED),[],'the new password is nowhere on the page after Save');
  await section.locator('[data-website-signin="https://journal.example|reader@example.org"]').getByRole('button',{name:'Remove'}).click();
  await section.getByText('Removed the password for journal.example.').waitFor();
  assert.equal(await section.locator('[data-website-signin]').count(),1,'the list is read again from the app');
  assert.deepEqual(await page.evaluate(()=>calls.filter(c=>c.action==='removeSite')),[{action:'removeSite',origin:'https://journal.example',username:'reader@example.org'}]);
  assert.deepEqual(errors,[]);
 }finally{await context?.close();await rm(directory,{recursive:true,force:true});}
});

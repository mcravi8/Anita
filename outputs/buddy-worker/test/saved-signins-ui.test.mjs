import test from 'node:test';
import assert from 'node:assert/strict';
import {chromium} from 'playwright-core';
import {mkdtemp,rm} from 'node:fs/promises';
import {existsSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';

// Background work › Browser sign-in › Saved sign-ins: the service sign-ins agents' commands use (WRDS), Saved or Not saved, with Replace and
// Remove. What is typed into Replace goes from the field to the app's sign-in bridge and nowhere else. The Mac app's bridge is a stand-in
// that records every call; its status follows what was saved or removed.
const skip=process.platform!=='darwin'||!existsSync('/Applications/Google Chrome.app');
const relay=new URL('../../relay/index.html',import.meta.url).href;
const SECRET='Wrds!pw-77Qa-typed-in-settings',USER='wrds-user-fixture';

function bridge(){
 window.calls=[];window.ops=[];window.saved=[];window.keychain={wrds:true};
 window.fixtureWorker={online:true,paused:false,tasks:[],routines:[],decisions:[],notifications:{},plans:[],pulse:{agents:{}},supervisorLane:{online:true,busy:false},signinRequests:[]};
 window.BuddyDesktop={saveState:async json=>{saved.push(json);return {saved:true};},
  worker:async p=>{ops.push(JSON.parse(JSON.stringify(p)));
   if(['status','start'].includes(p.operation))return structuredClone({...fixtureWorker,workspace:state.conversationWorkspace});
   if(p.operation==='notify')return {notifications:{}};
   return {};},
  signin:async p=>{calls.push(JSON.parse(JSON.stringify(p)));await new Promise(r=>setTimeout(r,20));
   if(p.action==='status')return {profiles:[{id:'wrds',name:'WRDS',saved:!!keychain.wrds}]};
   if(p.action==='provide'){if(!p.username||!p.password)throw Error('Type your WRDS username and password.');keychain.wrds=true;return {profile:'wrds',name:'WRDS',saved:true};}
   if(p.action==='remove'){keychain.wrds=false;return {profile:'wrds',saved:false};}
   return {};}};
}
function people(){
 document.getElementById('onboarding-root').innerHTML='';closeModal();
 // Lyra has Mac apps off and Web research on; Cy has Web research off.
 state.agents=[['ada','Ada',{web:true,desktop:true}],['lyra','Lyra',{web:true,desktop:false}],['cy','Cy',{web:false,desktop:true}]].map(([id,name,tools])=>({id,name,role:'Researcher',description:'x',setupStatus:'ready',avatarShape:'star',avatarColor:'lilac',tools}));
 state.groups=[];state.messages={ada:[],lyra:[],cy:[]};state.runs={};state.drafts={};state.attachments={};state.proposals=[];state.teamPlans=[];state.activitySeen={};state.activityDismissed={};state.hiddenAgents=[];state.onboarding={status:'completed',agentId:'ada'};
 navigate('chat','ada');
}
async function open(directory){
 const context=await chromium.launchPersistentContext(path.join(directory,'browser.noindex'),{channel:'chrome',headless:true,viewport:{width:1280,height:900},reducedMotion:'reduce'});
 await context.route('**/*',r=>/^https?:/.test(r.request().url())?r.abort():r.continue());
 await context.addInitScript(bridge);
 const page=context.pages()[0];const errors=[];page.on('pageerror',e=>errors.push(e.message));
 await page.goto(relay);await page.waitForFunction(()=>!!window.BuddyWorkerUI&&!!window.BuddySignIn);
 await page.evaluate(people);
 return {context,page,errors};
}
// Everywhere a typed value could end up on the page: the document, every field, the saved workspace (now and every save the page made),
// browser storage, and every request the page sent through the worker bridge.
async function nowhere(page,needle){
 return page.evaluate(n=>{
  const places={dom:document.documentElement.outerHTML,fields:[...document.querySelectorAll('input,textarea')].map(i=>i.value).join('\n'),state:JSON.stringify(state),saved:saved.join('\n'),
   local:Object.keys(localStorage).map(k=>k+'='+localStorage.getItem(k)).join('\n'),session:Object.keys(sessionStorage).map(k=>k+'='+sessionStorage.getItem(k)).join('\n'),worker:JSON.stringify(ops)};
  return Object.entries(places).filter(([,text])=>text.includes(n)).map(([where])=>where);
 },needle);
}

test('Saved sign-ins: WRDS shows Saved; Replace opens a private field whose value goes only to the sign-in bridge and is gone after Save',{skip,timeout:90000},async()=>{
 const directory=await mkdtemp(path.join(tmpdir(),'buddy-saved-signins-'));let context;
 try{
  const opened=await open(directory);context=opened.context;const {page,errors}=opened;
  await page.evaluate(()=>BuddyWorkerUI.profiles());
  const section=page.locator('.worker-saved-signins');await section.waitFor({timeout:8000});
  const row=section.locator('[data-saved-profile="wrds"]');
  await row.getByText('Saved',{exact:true}).waitFor();
  assert.equal(await row.getByRole('button',{name:'Replace'}).count(),1);assert.equal(await row.getByRole('button',{name:'Remove'}).count(),1);
  assert.equal(await section.locator('input').count(),0,'no field until Replace');
  await row.getByRole('button',{name:'Replace'}).click();
  const holder=section.locator('[data-saved-holder="wrds"]');await holder.waitFor();
  const user=holder.getByLabel('WRDS username'),pass=holder.getByLabel('WRDS password');
  assert.deepEqual(await pass.evaluate(e=>({type:e.type,autocomplete:e.getAttribute('autocomplete'),spellcheck:e.getAttribute('spellcheck')})),{type:'password',autocomplete:'off',spellcheck:'false'},'a masked field');
  await user.fill(USER);await pass.click();await page.keyboard.type(SECRET);
  // The worker panel polls while it is open; the field must not be redrawn away (or into anything) while the person types.
  await page.evaluate(()=>BuddyWorkerUI.refresh());
  assert.equal(await pass.inputValue(),SECRET,'nothing typed is lost to a refresh');
  assert.deepEqual(await nowhere(page,SECRET),['fields'],'while it is typed it is only in its field (not in state, drafts, storage or any worker request)');
  await holder.getByRole('button',{name:'Save'}).click();
  await section.getByText(/Saved\. .*new sign-in/).waitFor();
  // Reading what is saved (the sign-ins, remembered websites and connected services listed beside them) changes nothing.
  const sent=await page.evaluate(()=>calls.filter(c=>!['status','sites','services'].includes(c.action)));
  assert.deepEqual(sent,[{action:'provide',profile:'wrds',username:USER,password:SECRET}],'one call, to the sign-in bridge, with no task: it replaces the saved sign-in');
  assert.equal(await section.locator('input').count(),0,'the field is gone');
  assert.deepEqual(await nowhere(page,SECRET),[],'after Save it is nowhere on the page');assert.deepEqual(await nowhere(page,USER),[]);
  assert.deepEqual(errors,[]);
 }finally{await context?.close();await rm(directory,{recursive:true,force:true});}
});

test('Saved sign-ins: Remove asks once, then removes through the sign-in bridge; Not saved offers Add; Cancel sends nothing',{skip,timeout:90000},async()=>{
 const directory=await mkdtemp(path.join(tmpdir(),'buddy-saved-signins-remove-'));let context;
 try{
  const opened=await open(directory);context=opened.context;const {page,errors}=opened;
  await page.evaluate(()=>BuddyWorkerUI.profiles());
  const section=page.locator('.worker-saved-signins'),row=section.locator('[data-saved-profile="wrds"]');await row.getByText('Saved',{exact:true}).waitFor({timeout:8000});
  // Replace, then Cancel: nothing is sent and the typed value goes with the field.
  await row.getByRole('button',{name:'Replace'}).click();
  await section.getByLabel('WRDS password').fill(SECRET);
  await section.getByRole('button',{name:'Cancel'}).click();
  assert.equal(await section.locator('input').count(),0);assert.deepEqual(await nowhere(page,SECRET),[]);
  assert.deepEqual(await page.evaluate(()=>calls.filter(c=>!['status','sites','services'].includes(c.action))),[],'Cancel sends nothing');
  await row.getByRole('button',{name:'Remove'}).click();
  await section.getByText('Remove the saved WRDS sign-in?').waitFor();
  assert.deepEqual(await page.evaluate(()=>calls.filter(c=>!['status','sites','services'].includes(c.action))),[],'the first click only asks');
  await section.locator('[data-saved-confirm-remove="wrds"]').click();
  await row.getByText('Not saved',{exact:true}).waitFor();
  assert.deepEqual(await page.evaluate(()=>calls.filter(c=>!['status','sites','services'].includes(c.action))),[{action:'remove',profile:'wrds'}]);
  assert.equal(await row.getByRole('button',{name:'Remove'}).count(),0,'nothing left to remove');
  await row.getByRole('button',{name:'Add'}).click();
  await section.getByLabel('WRDS username').fill(USER);await section.getByLabel('WRDS password').fill(SECRET);await section.getByLabel('WRDS password').press('Enter');
  await row.getByText('Saved',{exact:true}).waitFor();
  assert.deepEqual(await page.evaluate(()=>calls.filter(c=>!['status','sites','services'].includes(c.action)).at(-1)),{action:'provide',profile:'wrds',username:USER,password:SECRET});
  assert.deepEqual(await nowhere(page,SECRET),[]);
  assert.deepEqual(errors,[]);
 }finally{await context?.close();await rm(directory,{recursive:true,force:true});}
});

test('Set up once: internet access is Web research alone, so an agent with Mac apps off still uses Buddy’s Chrome',{skip,timeout:60000},async()=>{
 const directory=await mkdtemp(path.join(tmpdir(),'buddy-setup-web-only-'));let context;
 try{
  const opened=await open(directory);context=opened.context;const {page,errors}=opened;
  // An app that does not say which agents use the browser: the page works it out from Web research alone.
  await page.evaluate(()=>BuddyWorkerUI.profiles());
  const section=page.locator('.worker-setup-once');await section.waitFor({timeout:8000});
  await section.getByText('Internet access is Web research in an agent’s settings; Mac apps doesn’t need to be on.').waitFor();
  await section.getByText('Used by Ada, Lyra. No browser for Cy (internet access is off).').waitFor();
  assert.deepEqual(errors,[]);
 }finally{await context?.close();await rm(directory,{recursive:true,force:true});}
});

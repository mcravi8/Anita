import test from 'node:test';
import assert from 'node:assert/strict';
import {chromium} from 'playwright-core';
import {mkdtemp,rm} from 'node:fs/promises';
import {existsSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';

// "It should be able to edit on my computer… ask first time for access to Desktop and from that point forward never ask again. Option to
// choose access ✓ vs ✗ in chat would be nice. Settings get updated accordingly." An agent that names a place on the Mac not open to agents
// yet gets a card in the chat (its own, and the group's): ✓ Allow, ✗ Don't allow, or the whole home folder, answered only through the app's
// bridge. Allowed, the agent is told to continue in a follow-up turn. Files › Folder & access lists what is allowed and what isn't. A move
// shows in the chat like a saved file. The Mac app's bridge is a stand-in that records every call.
const skip=process.platform!=='darwin'||!existsSync('/Applications/Google Chrome.app');

test('the access card asks once with ✓ / ✗, answers through the bridge, continues the agent, and Settings shows allowed and declined places',{skip,timeout:60000},async()=>{
 const directory=await mkdtemp(path.join(tmpdir(),'buddy-folder-access-ui-'));let context;
 try{
  context=await chromium.launchPersistentContext(path.join(directory,'browser.noindex'),{channel:'chrome',headless:true,viewport:{width:1180,height:900},reducedMotion:'reduce'});
  await context.route('**/*',r=>/^https?:/.test(r.request().url())?r.abort():r.continue());
  const page=context.pages()[0],errors=[];page.on('pageerror',e=>errors.push(e.message));
  await page.goto(new URL('../../relay/index.html',import.meta.url).href);await page.waitForFunction(()=>!!window.BuddyFolderAccess&&!!window.BuddyFiles);
  await page.evaluate(()=>{
   document.getElementById('onboarding-root').innerHTML='';closeModal();
   state.agents=[['chief','Chief'],['lyra','Lyra']].map(([id,name])=>({id,name,role:'Research',description:'x',setupStatus:'ready',avatarShape:'star',avatarColor:'lilac',tools:{projectFiles:true}}));
   state.groups=[{id:'team',name:'Research team',members:['chief','lyra'],objective:'Papers',managedBy:'chief',createdAt:'2026-10-21T09:00:00Z'}];
   state.messages={chief:[{id:'u1',who:'you',body:'/Users/matteo/Desktop/paper.pdf — Here the paper you were looking for',time:'10:00',live:true}],lyra:[],team:[]};
   state.runs={};state.drafts={chief:'a draft the person is still writing'};state.attachments={};state.proposals=[];state.teamPlans=[];state.activitySeen={};state.hiddenAgents=[];state.onboarding={status:'completed',agentId:'chief'};
   const w=state.conversationWorkspace,home='/Users/matteo';
   const desktop={id:'r1',status:'pending',name:'Desktop',label:'your Desktop',reason:'to read paper.pdf',path:'~/Desktop/paper.pdf',location:home+'/Desktop',agentId:'chief',agentName:'Chief',
    waiting:[{agentId:'chief',agentName:'Chief',chat:'chief',taskId:'',runId:'run-1',planId:''},{agentId:'lyra',agentName:'Lyra',chat:'team',taskId:'',runId:'run-2',planId:''}]};
   const pictures={id:'r2',status:'pending',name:'Pictures',label:'your Pictures',reason:'to look in Pictures',path:'~/Pictures',location:home+'/Pictures',agentId:'chief',agentName:'Chief',waiting:[{agentId:'chief',agentName:'Chief',chat:'chief',taskId:'',runId:'run-3',planId:''}]};
   const documents={id:'r3',status:'pending',name:'Documents',label:'your Documents',reason:'to save notes.md',path:'~/Documents/notes.md',location:home+'/Documents',agentId:'chief',agentName:'Chief',waiting:[{agentId:'chief',agentName:'Chief',chat:'chief',taskId:'',runId:'run-4',planId:''}]};
   window.overview={workspace:w,wholeHome:false,homeFolderId:'home-id',home,granted:[{folderId:'desk',name:'Desktop',location:home+'/Desktop'}],declined:[{path:home+'/Downloads',name:'Downloads',label:'your Downloads',at:'2026-10-21T09:00:00Z'}],requests:[desktop,pictures,documents]};
   window.calls=[];window.sent=[];window.disconnected=[];
   const folder={folderId:'research',name:'Directed Research',location:home+'/Directed Research',available:true,primary:true};
   window.BuddyDesktop={saveState:async()=>({saved:true}),sendMessage:async p=>{sent.push(JSON.parse(JSON.stringify(p)));return {accepted:true};},
    projectFiles:async()=>({...folder,folders:[folder],files:[{path:'notes.md',bytes:20}],directories:[]}),
    disconnectProjectFolder:async id=>{disconnected.push(id);return {disconnected:true};},
    folderAccess:async p=>{calls.push(JSON.parse(JSON.stringify(p)));
     if(p.action==='list')return structuredClone(overview);
     if(p.action==='answer'){
      const r=overview.requests.find(x=>x.id===p.id);r.status=p.choice==='deny'?'declined':'allowed';
      if(p.choice==='deny')overview.declined.push({path:r.location,name:r.name,label:r.label,at:'now'});
      return {request:structuredClone(r),answered:[structuredClone(r)],waiting:r.waiting.map(x=>({...x,requestId:r.id,status:r.status,name:r.name,label:r.label})),wholeHome:false};
     }
     return {...structuredClone(overview),waiting:[]};}};
   navigate('chat','chief');
  });
  await page.evaluate(()=>BuddyFolderAccess.refresh(true));

  // The card: who, which place, why; ✓ / ✗ and the smaller whole-home choice.
  const card=page.locator('[data-access-request="r1"]');await card.waitFor();
  const text=await card.innerText();
  assert.match(text,/Chief wants access to your Desktop/);assert.match(text,/to read paper\.pdf/);assert.match(text,/~\/Desktop\/paper\.pdf/);
  assert.equal(await card.getByRole('button',{name:'✓ Allow'}).count(),1);assert.equal(await card.getByRole('button',{name:'✗ Don’t allow'}).count(),1);assert.equal(await card.getByRole('button',{name:'Allow my whole home folder'}).count(),1);
  assert.equal(await page.locator('[data-access-request]').count(),3,'one card per request in this chat');

  // ✓: the app's bridge records the person's click; the card says the agent is continuing, and the chats that waited get the note.
  await card.getByRole('button',{name:'✓ Allow'}).click();
  // Answered, the card leaves the chat; a toast says what came of it.
  await card.waitFor({state:'detached'});await page.locator('#toast').filter({hasText:'Allowed — Chief and Lyra are continuing.'}).waitFor();
  assert.deepEqual(await page.evaluate(()=>calls.filter(c=>c.action==='answer')),[{action:'answer',id:'r1',choice:'allow'}]);
  await page.waitForFunction(()=>sent.length===2,null,{timeout:5000});
  const sent=await page.evaluate(()=>sent);
  assert.deepEqual(sent.map(p=>[p.agentId||p.groupId,p.text]).sort(),[['chief','Access to Desktop granted; continue.'],['team','Access to Desktop granted; continue.']],'a follow-up turn in each chat that waited');
  assert.equal(await page.evaluate(()=>state.drafts.chief),'a draft the person is still writing','the person’s draft is left alone');

  // The group's copy of the same request has left too.
  await page.evaluate(()=>navigate('chat','team'));await page.locator('#messages').waitFor();
  assert.equal(await page.locator('[data-access-request="r1"]').count(),0);

  // ✗ on the other request: recorded as not allowed, and nobody is sent a turn.
  await page.evaluate(()=>navigate('chat','chief'));
  const second=page.locator('[data-access-request="r2"]');await second.waitFor();
  await second.getByRole('button',{name:'✗ Don’t allow'}).click();
  await second.waitFor({state:'detached'});await page.locator('#toast').filter({hasText:'Not allowed.'}).waitFor();
  assert.deepEqual(await page.evaluate(()=>calls.filter(c=>c.action==='answer').at(-1)),{action:'answer',id:'r2',choice:'deny'});
  assert.equal(await page.evaluate(()=>sent.length),2,'no turn after a no');

  // The smaller choice: the whole home folder, in one click. (The follow-up waits for the chat's earlier reply to finish.)
  await page.evaluate(()=>{for(const run of Object.values(state.runs))BuddyChat.apply(state,{runId:run.runId,key:run.key,status:'completed',text:'Read it.'});});
  const third=page.locator('[data-access-request="r3"]');
  await third.getByRole('button',{name:'Allow my whole home folder'}).click();
  await third.waitFor({state:'detached'});await page.locator('#toast').filter({hasText:'Allowed — Chief is continuing.'}).waitFor();
  assert.deepEqual(await page.evaluate(()=>calls.filter(c=>c.action==='answer').at(-1)),{action:'answer',id:'r3',choice:'home'});
  await page.waitForFunction(()=>sent.length===3,null,{timeout:5000});
  assert.equal(await page.evaluate(()=>sent.at(-1).text),'Access to Documents granted; continue.');

  // A move shows in the reply like a saved file.
  await page.evaluate(()=>{state.messages.chief.push({id:'a2',who:'chief',body:'Renamed and filed it.',time:'10:05',live:true,runId:'run-9',status:'completed',files:[{id:'m1',kind:'moved',movedFrom:'paper.pdf',movedFromFolder:'desk',path:'stages/S01_protocol/source_retry/paper.pdf',folderId:'research',revision:'abc',actorName:'Chief'}]});refreshLiveChat('chief');});
  await page.getByText('Moved paper.pdf → stages/S01_protocol/source_retry/paper.pdf').waitFor();

  // Settings: Files › Folder & access lists the whole home folder, what is allowed (Remove) and what isn't (Allow).
  await page.evaluate(()=>BuddyFiles.show());
  await page.locator('.project-folder-details summary').click();
  const settings=page.locator('[data-folder-access-settings]');await settings.getByText('Whole home folder').waitFor();
  const shown=await settings.innerText();
  assert.match(shown,/Whole home folder[\s\S]*Not allowed/);assert.match(shown,/Desktop[\s\S]*Allowed · ~\/Desktop/);assert.match(shown,/Downloads[\s\S]*Not allowed · ~\/Downloads/);assert.match(shown,/Pictures[\s\S]*Not allowed · ~\/Pictures/);
  await settings.getByRole('button',{name:'Allow Downloads'}).click();
  await page.waitForFunction(()=>calls.some(c=>c.action==='allow'));
  assert.deepEqual(await page.evaluate(()=>calls.find(c=>c.action==='allow')),{action:'allow',path:'/Users/matteo/Downloads'});
  await settings.getByRole('button',{name:'Remove Desktop'}).click();
  await page.waitForFunction(()=>disconnected.length===1);
  assert.deepEqual(await page.evaluate(()=>disconnected),['desk']);
  await page.locator('[data-folder-access-settings] [data-access-setting="allowHome"]').click();
  await page.waitForFunction(()=>calls.some(c=>c.action==='allowHome'));
  assert.deepEqual(errors,[]);
 }finally{await context?.close();await rm(directory,{recursive:true,force:true});}
});

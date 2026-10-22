import test from 'node:test';import assert from 'node:assert/strict';import {chromium} from 'playwright-core';import {mkdtemp,rm} from 'node:fs/promises';import {existsSync} from 'node:fs';import {tmpdir} from 'node:os';import {join} from 'node:path';
// The desktop drop's page (relay/buddy-drop.html), as the Mac app's transparent panel shows it at the top-left of the screen. The Mac app's
// messages are stubbed: `window.webkit.messageHandlers.buddyDrop` records what the page tells the app.
const skip=process.platform!=='darwin'||!existsSync('/Applications/Google Chrome.app');
const item=(id,extra={})=>({id,name:id[0].toUpperCase()+id.slice(1),kind:'done',text:'Stage 1 is done',chat:id+'-chat',shape:'diamond',color:'lilac',...extra});
async function open(options={}){
 const dir=await mkdtemp(join(tmpdir(),'buddy-drop-ui-'));let context;
 try{
  context=await chromium.launchPersistentContext(join(dir,'browser.noindex'),{channel:'chrome',headless:true,viewport:{width:400,height:440},...options});
  await context.route('**/*',r=>/^https?:/.test(r.request().url())?r.abort():r.continue());
  const page=context.pages()[0],errors=[];page.on('pageerror',e=>errors.push(e.message));
  await page.addInitScript(()=>{window.posts=[];window.webkit={messageHandlers:{buddyDrop:{postMessage:m=>window.posts.push(JSON.parse(JSON.stringify(m)))}}};});
  await page.goto(new URL('../../relay/buddy-drop.html',import.meta.url).href);
  await page.waitForFunction(()=>!!window.BuddyDropPage&&posts.some(p=>p.type==='ready'),null,{timeout:10000});
  return {dir,context,page,errors};
 }catch(error){await context?.close();await rm(dir,{recursive:true,force:true});throw error;}
}
const centre=async(page,id)=>{const b=await page.locator(`[data-drop-id="${id}"] .drop-holder`).boundingBox();return {x:b.x+b.width/2,y:b.y+b.height/2};};
const near=(a,b,tolerance=2)=>Math.abs(a-b)<=tolerance;
// The holder's own ink, read off the canvas inside the disc but outside the figure.
const pixel=(page,x,y)=>page.evaluate(([x,y])=>{const c=document.querySelector('canvas.drop-canvas'),k=c.width/c.clientWidth;return [...c.getContext('2d').getImageData(Math.round(x*k),Math.round(y*k),1,1).data];},[x,y]);
const labelShown=(page,id)=>page.evaluate(id=>getComputedStyle(document.querySelector(`[data-drop-id="${id}"] .drop-label`)).opacity==='1',id);
const settled=(page,ys)=>page.waitForFunction(ys=>{const n=BuddyDropPage.snapshot().notes.filter(n=>!n.popping);return n.length===ys.length&&n.every((n,i)=>n.built&&Math.abs(n.cy-ys[i])<1.5&&Math.abs(n.vcy)<5);},ys,{timeout:6000});

test('a drop builds its holder top-left, stacks the next 92px lower, keeps four, opens the chat on a click and shows its label on hover',{skip,timeout:90000},async()=>{
 const {dir,context,page,errors}=await open();
 try{
  await page.evaluate(i=>BuddyDropPage.show(i),item('atlas',{text:'Visual direction is ready'}));
  await page.waitForTimeout(450);
  let s=await page.evaluate(()=>BuddyDropPage.snapshot());
  assert.equal(s.calm,false);assert.equal(s.notes.length,1);assert.equal(s.notes[0].built,false,'the holder is still being built from its dots');
  assert.equal(await page.locator('[data-drop-id="atlas"]').evaluate(el=>getComputedStyle(el).visibility),'hidden','nothing to click while it builds');
  await settled(page,[76]);
  const a=await centre(page,'atlas');assert.ok(near(a.x,50)&&near(a.y,76),`holder centre ${JSON.stringify(a)}`);
  const ink=await pixel(page,70,96);assert.ok(ink[3]>200&&ink[0]<60&&ink[1]<60&&ink[2]<60,`the solid black disc has landed: ${ink}`);
  await page.waitForFunction(()=>getComputedStyle(document.querySelector('[data-drop-id="atlas"] .drop-label')).opacity==='1',null,{timeout:3000});
  assert.equal(await page.locator('[data-drop-id="atlas"] .drop-name').innerText(),'Atlas');
  assert.equal(await page.locator('[data-drop-id="atlas"] .drop-text').innerText(),'Finished · Visual direction is ready');
  const regions=await page.evaluate(()=>posts.filter(p=>p.type==='regions').at(-1).rects);
  const holder=regions.find(r=>r.id==='atlas'&&r.part==='holder'),label=regions.find(r=>r.id==='atlas'&&r.part==='label');
  assert.ok(holder&&near(holder.x,12)&&near(holder.y,38)&&near(holder.w,76)&&near(holder.h,76)&&holder.round===true,JSON.stringify(regions));
  assert.ok(label&&label.x>=88&&label.w>40,'the visible label is clickable too');

  await page.evaluate(i=>BuddyDropPage.show(i),item('nova',{kind:'needs',text:'Approve a command',shape:'hex',color:'peach'}));
  await settled(page,[76,168]);
  const n=await centre(page,'nova');assert.ok(near(n.x,50)&&near(n.y,168),`second holder ${JSON.stringify(n)}`);
  for(const id of ['scout','morgan','iris'])await page.evaluate(i=>BuddyDropPage.show(i),item(id,{shape:'pill',color:'mint'}));
  await settled(page,[76,168,260,352]);
  s=await page.evaluate(()=>BuddyDropPage.snapshot());
  assert.deepEqual(s.notes.filter(n=>!n.popping).map(n=>n.id),['nova','scout','morgan','iris'],'at most four: the oldest made room');
  assert.equal(await page.locator('[data-drop-id="atlas"]').count(),0);

  // The same agent again: its holder wobbles and its label says the latest, without a second holder.
  await page.evaluate(i=>BuddyDropPage.show(i),item('nova',{kind:'done',text:'Stage 2 is done',shape:'hex',color:'peach'}));
  s=await page.evaluate(()=>BuddyDropPage.snapshot());
  assert.equal(s.notes.filter(n=>n.id==='nova').length,1);assert.equal(s.notes.find(n=>n.id==='nova').kicks,1);
  assert.equal(await page.locator('[data-drop-id="nova"] .drop-text').innerText(),'Finished · Stage 2 is done');
  assert.ok(await labelShown(page,'nova'),'an update peeks its label out again');

  // A click pops the holder and asks the app to open that agent's chat; the ones below spring up.
  await page.locator('[data-drop-id="scout"] .drop-holder').click();
  assert.deepEqual(await page.evaluate(()=>posts.filter(p=>p.type==='open')),[{type:'open',id:'scout',chat:'scout-chat'}]);
  // The pointer moves off, or the holder that springs up under it would count as hovered.
  await page.mouse.move(390,430);
  await settled(page,[76,168,260]);
  assert.deepEqual((await page.evaluate(()=>BuddyDropPage.snapshot())).notes.map(n=>n.id),['nova','morgan','iris']);
  // The app's own click (the panel takes the click, not the page) does the same.
  await page.evaluate(()=>BuddyDropPage.click('iris'));
  assert.deepEqual(await page.evaluate(()=>posts.filter(p=>p.type==='open').map(p=>p.chat)),['scout-chat','iris-chat']);
  await settled(page,[76,168]);

  // Hover brings the label back once its peek is over, from the page's own pointer or from the app's tracking.
  await page.waitForFunction(()=>getComputedStyle(document.querySelector('[data-drop-id="morgan"] .drop-label')).opacity==='0',null,{timeout:8000});
  await page.mouse.move(50,168);
  await page.waitForFunction(()=>getComputedStyle(document.querySelector('[data-drop-id="morgan"] .drop-label')).opacity==='1',null,{timeout:2000});
  await page.mouse.move(300,420);
  await page.waitForFunction(()=>getComputedStyle(document.querySelector('[data-drop-id="morgan"] .drop-label')).opacity==='0',null,{timeout:2000});
  await page.evaluate(()=>BuddyDropPage.hover('morgan'));
  await page.waitForFunction(()=>getComputedStyle(document.querySelector('[data-drop-id="morgan"] .drop-label')).opacity==='1',null,{timeout:2000});
  await page.evaluate(()=>BuddyDropPage.hover(null));

  // Dark: the holder stays the design's black disc; the label takes the dark card colours.
  await page.emulateMedia({colorScheme:'dark'});
  assert.equal(await page.locator('[data-drop-id="morgan"] .drop-label').evaluate(el=>getComputedStyle(el).backgroundColor),'rgb(31, 31, 29)');
  await page.waitForTimeout(100);const dark=await pixel(page,70,184);assert.ok(dark[3]>200&&dark[0]<60,`still a black disc in dark mode: ${dark}`);

  // Buddy came to the front: everything pops and the app hears the stack is empty, so it can put the panel away.
  await page.evaluate(()=>BuddyDropPage.clear());
  await page.waitForFunction(()=>posts.at(-1)?.type==='empty'&&BuddyDropPage.snapshot().notes.length===0,null,{timeout:3000});
  assert.equal(await page.evaluate(()=>posts.filter(p=>p.type==='open').length),2,'clearing opens nothing');
  // Bad input from the app is ignored rather than drawn.
  await page.evaluate(()=>{BuddyDropPage.show({id:'',name:'x',kind:'done'});BuddyDropPage.show({id:'q',name:'Q',kind:'weird',text:'x'});});
  assert.equal((await page.evaluate(()=>BuddyDropPage.snapshot())).notes.length,0);
  assert.deepEqual(errors,[]);
 }finally{await context.close();await rm(dir,{recursive:true,force:true});}
});

test('with Reduce Motion the holder and figure are there at once, without the build, spin or hop, and still open the chat',{skip,timeout:60000},async()=>{
 const {dir,context,page,errors}=await open({reducedMotion:'reduce'});
 try{
  await page.evaluate(i=>BuddyDropPage.show(i),item('lyra',{kind:'needs',text:'Sign in to iopscience.iop.org',shape:'sphere',color:'blue'}));
  await page.waitForTimeout(150);
  const s=await page.evaluate(()=>BuddyDropPage.snapshot());
  assert.equal(s.calm,true);assert.equal(s.notes[0].built,true,'no dot-by-dot build');assert.ok(near(s.notes[0].cy,76,0.01),'no spring into place');
  assert.equal(s.notes[0].spun,false,'no spin');assert.equal(s.notes[0].hopped,false,'no hop');
  const ink=await pixel(page,70,96);assert.ok(ink[3]>200&&ink[0]<60,`the disc is drawn at once: ${ink}`);
  assert.equal(await page.locator('[data-drop-id="lyra"]').evaluate(el=>getComputedStyle(el).visibility),'visible');
  await page.waitForFunction(()=>getComputedStyle(document.querySelector('[data-drop-id="lyra"] .drop-label')).opacity==='1',null,{timeout:3000});
  assert.equal(await page.locator('[data-drop-id="lyra"] .drop-text').innerText(),'Needs you · Sign in to iopscience.iop.org');
  // A figure that finishes in calm mode is happy, without spinning.
  await page.evaluate(i=>BuddyDropPage.show(i),item('lyra',{kind:'done',text:'Stage 1 is done',shape:'sphere',color:'blue'}));
  await page.waitForTimeout(600);
  const after=(await page.evaluate(()=>BuddyDropPage.snapshot())).notes[0];assert.equal(after.spun,false);assert.equal(after.mode,'done');
  await page.locator('[data-drop-id="lyra"] .drop-holder').click();
  assert.deepEqual(await page.evaluate(()=>posts.filter(p=>p.type==='open')),[{type:'open',id:'lyra',chat:'lyra-chat'}]);
  assert.deepEqual(errors,[]);
 }finally{await context.close();await rm(dir,{recursive:true,force:true});}
});

test('in Buddy, delivered events reach the Mac app’s drop bridge, the setting turns it off, and the app can open the chat',{skip,timeout:60000},async()=>{
 const dir=await mkdtemp(join(tmpdir(),'buddy-drop-main-'));let context;
 try{
  context=await chromium.launchPersistentContext(join(dir,'browser.noindex'),{channel:'chrome',headless:true,viewport:{width:1120,height:850},reducedMotion:'reduce'});
  await context.route('**/*',r=>/^https?:/.test(r.request().url())?r.abort():r.continue());
  const page=context.pages()[0],errors=[];page.on('pageerror',e=>errors.push(e.message));
  await page.goto(new URL('../../relay/index.html',import.meta.url).href);await page.waitForFunction(()=>!!window.BuddyWorkerUI&&!!window.BuddyDrop);
  await page.evaluate(()=>{
   document.getElementById('onboarding-root').innerHTML='';closeModal();
   state.agents=[{id:'chief',name:'Chief',role:'Chief of staff',avatarShape:'star',avatarColor:'lilac',setupStatus:'ready',tools:{}},{id:'lyra',name:'Lyra',role:'Researcher',avatarShape:'pebble',avatarColor:'blue',setupStatus:'ready',tools:{}}];
   state.groups=[{id:'team',name:'Team',members:['chief','lyra'],managedBy:'chief'}];state.onboarding={status:'completed',agentId:'chief'};state.proposals=[];state.teamPlans=[];state.runs={};
   state.messages={chief:[],lyra:[],team:[]};state.drafts={};state.attachments={};ui.view={kind:'chat',target:'chief'};ui.lastChat='chief';
   const now=new Date().toISOString();
   window.drops=[];window.fixtureTask={id:'t1',workspace:state.conversationWorkspace,agentId:'lyra',title:'Find five references',status:'completed',attempt:1,result:'Five references saved.',updatedAt:now};
   window.fixturePlan={id:'p1',groupId:'team',supervisorId:'chief',status:'holding',stages:[{id:'s1',n:1,title:'Research',status:'done',tasks:[]}],notices:[{id:'n1',kind:'stage_report',text:'Stage 1 — Research is done.',chat:true,status:'open',at:now,refs:{stageId:'s1'}}],run:{state:'stage_done'}};
   const status=()=>({workspace:state.conversationWorkspace,online:true,paused:false,tasks:[fixtureTask],routines:[],decisions:[],notifications:{},plans:[fixturePlan],signinRequests:[{key:'step:t9:1',kind:'step',need:'signin',taskId:'t9',agentId:'lyra',url:'https://iopscience.iop.org/x',origin:'https://iopscience.iop.org'}],pulse:{agents:{}},supervisorLane:{online:true}});
   window.BuddyDesktop={saveState:async()=>({saved:true}),drop:async p=>{drops.push(JSON.parse(JSON.stringify(p)));return {shown:true};},worker:async p=>p.operation==='detail'?{task:fixtureTask}:status()};
   render();
  });
  await page.evaluate(()=>BuddyWorkerUI.refresh(false));
  await page.waitForFunction(()=>drops.length>=3,null,{timeout:5000});
  const drops=await page.evaluate(()=>drops);
  assert.deepEqual(drops.map(d=>[d.kind,d.agentId,d.chat,d.text]).sort(),[['done','chief','team','Stage 1 is done'],['done','lyra','lyra','Find five references'],['needs','lyra','lyra','Sign in to iopscience.iop.org']]);
  assert.ok(drops.every(d=>d.eventId&&d.name&&['diamond','sphere','hex','pill'].includes(d.shape)&&d.color),JSON.stringify(drops));
  await page.evaluate(()=>BuddyWorkerUI.refresh(false));await page.waitForTimeout(200);
  assert.equal(await page.evaluate(()=>drops.length),3,'a second status read drops nothing new');

  // Settings › Desktop drop: on by default; off stops drops and clears what is on screen.
  await page.evaluate(()=>settings());
  const toggle=page.locator('[data-desktop-drop-setting]');
  assert.equal(await toggle.isChecked(),true);
  await toggle.uncheck();
  assert.equal(await page.evaluate(()=>state.desktopDrop),false);
  assert.deepEqual(await page.evaluate(()=>drops.at(-1)),{clear:true});
  await page.evaluate(()=>{closeModal();fixtureTask.attempt=2;fixtureTask.updatedAt=new Date().toISOString();});
  await page.evaluate(()=>BuddyWorkerUI.refresh(false));await page.waitForTimeout(200);
  assert.equal(await page.evaluate(()=>drops.filter(d=>d.eventId).length),3,'nothing while it is off');
  assert.equal(await page.evaluate(()=>state.messages.lyra.length),3,'the chat still gets every message');
  await page.evaluate(()=>settings());assert.equal(await page.locator('[data-desktop-drop-setting]').isChecked(),false);
  await page.locator('[data-desktop-drop-setting]').check();assert.equal(await page.evaluate(()=>state.desktopDrop),true);
  await page.evaluate(()=>closeModal());

  // The Mac app opens the chat a holder was for; anything that is not a chat here is ignored.
  assert.equal(await page.evaluate(()=>BuddyDrop.open('team')),true);
  assert.deepEqual(await page.evaluate(()=>ui.view),{kind:'chat',target:'team'});
  assert.equal(await page.evaluate(()=>BuddyDrop.open('nobody')),false);
  assert.deepEqual(await page.evaluate(()=>ui.view),{kind:'chat',target:'team'});
  assert.deepEqual(errors,[]);
 }finally{await context?.close();await rm(dir,{recursive:true,force:true});}
});

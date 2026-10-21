import test from 'node:test';import assert from 'node:assert/strict';import {chromium} from 'playwright-core';import {mkdtemp,rm} from 'node:fs/promises';import {tmpdir} from 'node:os';import {join} from 'node:path';
test('figures are painted in rows, messages, previews and inline names; search, files and settings show them; appearance saves and reaches the app',{timeout:60000},async()=>{
 const dir=await mkdtemp(join(tmpdir(),'buddy-figures-ui-'));let context;
 try{
  context=await chromium.launchPersistentContext(dir,{channel:'chrome',headless:true,viewport:{width:1280,height:860}});const page=context.pages()[0];
  const errors=[];page.on('pageerror',e=>errors.push(String(e)));page.on('console',m=>{if(m.type()==='error')errors.push(m.text());});
  await page.goto(new URL('../../relay/index.html',import.meta.url).href);await page.waitForFunction(()=>!!window.BuddyFigures&&!!window.BuddyTheme&&!!window.BuddyFigureModes);
  await page.evaluate(()=>{
   document.getElementById('onboarding-root').innerHTML='';closeModal();
   // The original 3D shape names, as an older saved workspace would hold them.
   state.agents=[{id:'chief',name:'Chief',role:'Chief of staff',avatarShape:'star',avatarColor:'lilac',setupStatus:'ready',tools:{}},{id:'scout',name:'Scout',role:'Reviewer',avatarShape:'clover',avatarColor:'mint',setupStatus:'ready',tools:{}}];
   state.groups=[{id:'team',name:'Launch team',members:['chief','scout'],objective:'Ship it.'}];state.onboarding={status:'completed',agentId:'chief'};state.runs={};state.tasks=[];
   state.files=[{id:'f1',name:'plan.md',type:'Markdown',owner:'scout',revision:2,content:'# Plan'}];
   state.messages={chief:[{id:'m1',who:'you',body:'Hello',time:'10:00'},{id:'m2',who:'chief',body:'Hi there.',time:'10:01'}],scout:[],team:[{id:'t1',who:'chief',body:'Group reply.',time:'10:02'}]};state.drafts={};state.attachments={};
   window.appearance=[];BuddyDesktop={saveState:async()=>({saved:true}),setAppearance:c=>{appearance.push(c);}};ui.view={kind:'chat',target:'chief'};render();
  });
  await page.waitForTimeout(600);
  // Rows hold slots, not canvases; the one dot field behind them is painted.
  assert.equal(await page.locator('.sidebar canvas.sidebar-field').count(),1);
  assert.equal(await page.locator('.chat-row .fig-slot').count(),3);
  assert.equal(await page.locator('.chat-row canvas').count(),0);
  assert.equal(await page.locator('img.avatar,.avatar img').count(),0,'no image avatars remain');
  const litPixels=sel=>page.evaluate(selector=>{const c=document.querySelector(selector);if(!c)return -1;const d=c.getContext('2d').getImageData(0,0,c.width,c.height).data;let n=0;for(let i=3;i<d.length;i+=4)if(d[i]>140)n++;return n;},sel);
  // Pixel check on the field: a head is drawn at each row's slot, and the control spot (empty space) is not.
  const field=await page.evaluate(()=>{const f=document.querySelector('canvas.sidebar-field'),fr=f.getBoundingClientRect(),dpr=f.width/fr.width,ctx=f.getContext('2d');
   const heavy=(cx,cy,r)=>{const d=ctx.getImageData(Math.max(0,(cx-r)*dpr),Math.max(0,(cy-r)*dpr),2*r*dpr,2*r*dpr).data;let n=0;for(let i=3;i<d.length;i+=4)if(d[i]>140)n++;return n;};
   const slots=[...document.querySelectorAll('.chat-row .fig-slot')].map(s=>{const r=s.getBoundingClientRect();return heavy(r.left-fr.left+r.width/2,r.top-fr.top+r.height/2,22);});
   return {slots,empty:heavy(fr.width-30,fr.height-200,22)};});
  for(const n of field.slots)assert.ok(n>60,`a figure is painted at each row (${field.slots})`);
  assert.ok(field.empty<5,'empty sidebar space carries no figure (control)');
  assert.ok(await litPixels('.conversation-title canvas.fig')>60,'the header figure is painted');
  // The old names draw as the new figures before any migration runs, and loading a saved workspace rewrites them.
  assert.deepEqual(await page.evaluate(()=>RelayTeam.migrate(state).agents.map(a=>a.avatarShape)),['diamond','pill']);
  // Control: a canvas for an agent that does not exist stays blank.
  await page.evaluate(()=>{const c=document.createElement('canvas');c.className='fig';c.dataset.fig='agent';c.dataset.figId='nobody';c.dataset.size='40';c.width=40;c.height=40;c.id='ghost';document.getElementById('app').appendChild(c);});
  await page.waitForTimeout(400);assert.equal(await litPixels('#ghost'),0,'an unknown agent is not drawn');
  // Group messages show the author's figure; previews recolour live.
  await page.evaluate(()=>{ui.view={kind:'chat',target:'team'};render();});await page.waitForTimeout(500);
  assert.ok(await page.locator('.bot-message > .avatar canvas[data-fig]').count()>=1,'a group message has its author’s figure');
  // Search shows a figure for agents and groups, an icon for files.
  await page.evaluate(()=>searchModal());await page.locator('#workspace-search').fill('');await page.waitForTimeout(300);
  const results=await page.locator('#search-results .group-card').evaluateAll(cards=>cards.map(c=>({name:c.querySelector('strong').textContent,figure:!!c.querySelector('canvas[data-fig]'),icon:!!c.querySelector(':scope > svg')})));
  assert.deepEqual(results.map(r=>[r.name,r.figure]),[['Chief',true],['Scout',true],['Launch team',true],['plan.md',false]]);
  assert.ok(results[3].icon,'a file keeps its file icon');
  await page.evaluate(()=>closeModal());
  // Files: the owner is shown with a figure on the page and in the drawer.
  await page.evaluate(()=>{ui.view={kind:'files'};render();});await page.waitForTimeout(300);
  assert.ok(await page.locator('.files-table td .who canvas[data-fig]').count()===1&&/Scout/.test(await page.locator('.files-table td .who').innerText()));
  // Settings: the appearance block, and the first Buddy with its figure.
  await page.evaluate(()=>settings());await page.waitForTimeout(300);
  assert.ok(await page.locator('.settings-option .who canvas[data-fig]').count()===1);
  assert.deepEqual(await page.locator('.theme-card').evaluateAll(b=>b.map(x=>[x.dataset.themeChoice,x.getAttribute('aria-pressed')])),[['light','true'],['dark','false'],['system','false']]);
  await page.locator('.theme-card[data-theme-choice=dark]').click();
  assert.equal(await page.evaluate(()=>document.documentElement.dataset.theme),'dark');assert.equal(await page.evaluate(()=>state.theme),'dark');
  assert.equal(await page.evaluate(()=>getComputedStyle(document.body).backgroundColor),'rgb(18, 18, 17)');
  assert.equal((await page.evaluate(()=>appearance)).at(-1),'dark','the app is told, so the window follows');
  await page.locator('.theme-card[data-theme-choice=system]').click();
  assert.equal(await page.evaluate(()=>state.theme),'system');assert.equal((await page.evaluate(()=>appearance)).at(-1),'system');
  await page.locator('.theme-card[data-theme-choice=light]').click();
  assert.equal(await page.evaluate(()=>document.documentElement.dataset.theme),'light');
  assert.deepEqual(errors,[]);
 }finally{await context?.close();await rm(dir,{recursive:true,force:true});}
});

import test from 'node:test';
import assert from 'node:assert/strict';
import {chromium} from 'playwright-core';
import {mkdir,rm} from 'node:fs/promises';
import {existsSync} from 'node:fs';
import {randomUUID} from 'node:crypto';
import {tmpdir} from 'node:os';
import path from 'node:path';

test('switch all agents: a preview first, the switch only on confirm, a plain refusal, and it fits a phone in dark mode',{skip:process.platform!=='darwin'||!existsSync('/Applications/Google Chrome.app')},async()=>{
 const directory=path.join(tmpdir(),'buddy-provider-switch-ui-'+randomUUID()+'.noindex');await mkdir(directory,{mode:0o700});let context;
 try{
  context=await chromium.launchPersistentContext(directory,{channel:'chrome',headless:true,viewport:{width:1100,height:850},reducedMotion:'reduce'});
  await context.route('**/*',route=>/^https?:/.test(route.request().url())?route.abort():route.continue());
  const page=context.pages()[0],errors=[];page.on('pageerror',e=>errors.push(e.message));
  await page.goto(new URL('../../relay/index.html',import.meta.url).href);await page.waitForFunction(()=>!!window.BuddyProviders&&!!window.BuddyTheme);
  await page.evaluate(async()=>{
   document.getElementById('onboarding-root').innerHTML='';closeModal();
   const agent=(id,name)=>({id,name,role:'Teammate',description:'Fixture',setupStatus:'ready',avatarShape:'sphere',avatarColor:'blue',tools:{}});
   state.agents=[agent('chief','Chief'),agent('forge','Forge'),agent('inbox','Inbox')];state.messages={};state.runs={};state.onboarding={status:'completed'};
   window.fixture={provider:'chatgpt',requests:[],refuse:''};
   const status=()=>({provider:fixture.provider,connected:true,chatgpt:{connected:true,enabled:true},claude:{connected:true,enabled:true},plan:null,error:''});
   const note="Coding sessions and Chief's background supervision run on Claude. They keep using Claude while it stays connected.";
   const plans={
    claude:[{agentId:'chief',from:{provider:'chatgpt',model:'gpt-5.5-pro',name:'GPT-5.5 Pro'},to:{provider:'claude',model:'claude-opus-5',name:'Claude Opus 5'},how:'equivalent'},
            {agentId:'forge',from:{provider:'chatgpt',model:'gpt-5.5',name:'GPT-5.5'},to:{provider:'claude',model:'claude-sonnet-5',name:'Claude Sonnet 5'},how:'remembered'},
            {agentId:'inbox',from:{provider:'claude',model:'claude-haiku-5',name:'Claude Haiku 5'},to:{provider:'claude',model:'claude-haiku-5',name:'Claude Haiku 5'},how:'unchanged'}],
    chatgpt:[{agentId:'chief',from:{provider:'claude',model:'claude-opus-5',name:'Claude Opus 5 with a very long release name for small screens'},to:{provider:'chatgpt',model:'gpt-5.5-pro',name:'GPT-5.5 Pro extended reasoning preview build'},how:'remembered'},
             {agentId:'inbox',from:{provider:'claude',model:'claude-haiku-5',name:'Claude Haiku 5'},to:{provider:'chatgpt',model:'gpt-5.5-mini',name:'GPT-5.5 mini'},how:'equivalent'}]};
   window.BuddyDesktop={saveState:async()=>({saved:true}),providerSettings:async payload=>{
    fixture.requests.push(payload);
    if(payload.operation!=='switch')return status();
    if(fixture.refuse)throw Error(fixture.refuse);
    const plan={provider:payload.provider,dryRun:payload.dryRun,applied:!payload.dryRun,note,agents:plans[payload.provider]};
    if(payload.dryRun)return plan;
    fixture.provider=payload.provider;return {...plan,status:status()};
   }};
   await BuddyProviders.refresh();settings();
  });
  const switches=()=>page.evaluate(()=>fixture.requests.filter(r=>r.operation==='switch'));
  const offer=page.getByRole('button',{name:'Switch all agents to Claude',exact:true});
  await offer.waitFor();assert.match(await page.locator('.provider-switch').textContent(),/Move the whole team/);

  // A preview first: every agent with its current and new model, what stays on Claude, and nothing applied yet.
  await offer.click();
  const preview=page.getByRole('group',{name:'Switch all agents to Claude'});await preview.waitFor();
  assert.deepEqual(await switches(),[{operation:'switch',provider:'claude',dryRun:true}]);
  const text=await preview.textContent();
  assert.match(text,/Switch all agents to Claude\?/);assert.match(text,/Chief\s*GPT-5\.5 Pro\s*→\s*to\s*Claude Opus 5/);assert.match(text,/Forge\s*GPT-5\.5\s*→\s*to\s*Claude Sonnet 5\s*The model it had before/);
  assert.match(text,/Inbox\s*Claude Haiku 5\s*Already on Claude/);
  assert.match(text,/Coding sessions and Chief's background supervision run on Claude\. They keep using Claude while it stays connected\./);
  assert.match(text,/Replies and tasks already running finish on the model they started with\./);
  assert.equal(await page.evaluate(()=>document.activeElement?.matches('[data-provider-switch-preview]')),true,'the preview takes focus so it is read out');

  // Cancel leaves everything as it was.
  await preview.getByRole('button',{name:'Cancel',exact:true}).click();
  await offer.waitFor();assert.equal(await preview.count(),0);assert.equal((await switches()).length,1);
  assert.equal(await page.evaluate(()=>document.activeElement?.dataset.providerSwitch),'claude','focus returns to the switch button');

  // Confirm applies it: the starting provider follows, and the offer turns around.
  await offer.click();await preview.waitFor();
  await preview.getByRole('button',{name:'Switch all agents to Claude',exact:true}).click();
  await page.locator('#toast').filter({hasText:'All agents now use Claude from their next reply.'}).waitFor();
  assert.deepEqual((await switches()).at(-1),{operation:'switch',provider:'claude',dryRun:false});
  const back=page.getByRole('button',{name:'Switch all agents to ChatGPT',exact:true});await back.waitFor();
  assert.equal(await page.locator('[data-provider-select="claude"]').getAttribute('aria-pressed'),'true');
  assert.equal(await preview.count(),0);

  // A target that is not connected: the plain message, no preview, nothing applied.
  await page.evaluate(()=>{fixture.refuse='Connect ChatGPT in Settings → AI provider first.';});
  const before=(await switches()).length;
  await back.click();
  await page.locator('[data-provider-error]').filter({hasText:'Connect ChatGPT in Settings → AI provider first.'}).waitFor();
  assert.equal(await page.locator('[data-provider-switch-preview]').count(),0);
  assert.deepEqual((await switches()).slice(before),[{operation:'switch',provider:'chatgpt',dryRun:true}]);

  // A phone in dark mode: the preview stacks, nothing runs off the screen, and it uses the theme's colours.
  await page.evaluate(()=>{fixture.refuse='';BuddyTheme.choose('dark');});
  await page.setViewportSize({width:390,height:844});
  await back.click();const phone=page.getByRole('group',{name:'Switch all agents to ChatGPT'});await phone.waitFor();
  const fit=await page.evaluate(()=>{const modal=document.querySelector('.modal'),box=document.querySelector('[data-provider-switch-preview]'),r=box.getBoundingClientRect(),style=getComputedStyle(box),root=getComputedStyle(document.documentElement);
   const probe=document.createElement('div');probe.style.background='var(--soft)';probe.style.color='var(--text)';document.body.append(probe);const want=getComputedStyle(probe);const expected={bg:want.backgroundColor,fg:want.color};probe.remove();
   const buttons=[...box.querySelectorAll('.provider-switch-actions button')].map(b=>b.getBoundingClientRect());
   return {modal:modal.scrollWidth<=modal.clientWidth,inside:r.left>=0&&r.right<=innerWidth,rows:[...box.querySelectorAll('.provider-switch-row')].every(row=>row.scrollWidth<=row.clientWidth+1),buttons:buttons.every(b=>b.right<=r.right+0.5),bg:style.backgroundColor,fg:style.color,expected,theme:document.documentElement.dataset.theme,soft:root.getPropertyValue('--soft').trim()};});
  assert.equal(fit.theme,'dark');assert.equal(fit.modal,true,'the settings sheet does not scroll sideways');assert.equal(fit.inside,true,'the preview stays on screen');
  assert.equal(fit.rows,true,'long model names wrap inside their row');assert.equal(fit.buttons,true,'both buttons fit');
  assert.equal(fit.bg,fit.expected.bg,'the preview uses the theme background');assert.equal(fit.fg,fit.expected.fg,'and the theme text colour');assert.notEqual(fit.bg,'rgb(246, 245, 242)','not the light theme colour');
  assert.match(await phone.textContent(),/Chief\s*Claude Opus 5 with a very long release name for small screens\s*→\s*to\s*GPT-5\.5 Pro extended reasoning preview build\s*The model it had before/);
  assert.deepEqual(errors,[]);
 }finally{await context?.close();await rm(directory,{recursive:true,force:true});}
});

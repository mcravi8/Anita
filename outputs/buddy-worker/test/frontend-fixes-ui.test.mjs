import test from 'node:test';import assert from 'node:assert/strict';import {chromium} from 'playwright-core';import {mkdtemp,rm} from 'node:fs/promises';import {tmpdir} from 'node:os';import {join} from 'node:path';
test('sidebar hover, repaint, search, Back to chat, IME Enter, reset and escaping behave',{timeout:60000},async()=>{
 const dir=await mkdtemp(join(tmpdir(),'buddy-fixes-ui-'));let context;
 try{
  context=await chromium.launchPersistentContext(dir,{channel:'chrome',headless:true,viewport:{width:1280,height:860}});const page=context.pages()[0];
  const errors=[];page.on('pageerror',e=>errors.push(String(e)));
  await page.goto(new URL('../../relay/index.html',import.meta.url).href);await page.waitForFunction(()=>!!window.BuddyFigures&&!!window.BuddyChat);
  await page.evaluate(()=>{
   document.getElementById('onboarding-root').innerHTML='';closeModal();
   state.agents=['Atlas','Nova','Scout'].map((name,i)=>({id:'id-'+name.toLowerCase(),name,role:'Role '+i,description:'x',avatarShape:['sphere','hex','pill'][i],avatarColor:['blue','peach','mint'][i],setupStatus:'ready',tools:{}}));state.groups=[];state.tasks=[];state.onboarding={status:'completed',agentId:'id-atlas'};state.runs={};
   state.files=[{id:'f1',name:'a.md',type:'Markdown',owner:'id-nova',revision:'"><img src=x onerror="window.pwned=1">',content:'x'}];
   state.messages={'id-atlas':Array.from({length:40},(_,i)=>({id:'m'+i,who:i%2?'id-atlas':'you',body:'Message number '+i+' with enough words to take some room in the thread.',time:'10:00'})),'id-nova':[],'id-scout':[]};state.drafts={};state.attachments={};
   window.sent=0;BuddyDesktop={saveState:async()=>({saved:true}),sendMessage:async()=>{sent++;}};ui.view={kind:'chat',target:'id-atlas'};render();
  });
  await page.waitForTimeout(500);
  // Hovering a row is noticed by the figures (the squash pop and attentive eyes depend on it).
  const row=await page.locator('.chat-row[data-id=id-scout]').boundingBox();await page.mouse.move(row.x+80,row.y+row.height/2);await page.waitForTimeout(250);
  assert.equal(await page.evaluate(()=>BuddyFigures.hovered()),'id-scout');
  await page.mouse.move(700,400);await page.waitForTimeout(250);assert.equal(await page.evaluate(()=>BuddyFigures.hovered()),null);
  // A rebuilt sidebar never shows its dot field blank, even for a single frame.
  const blank=await page.evaluate(async()=>{let n=0;for(let i=0;i<15;i++){render();await new Promise(r=>requestAnimationFrame(r));const f=document.querySelector('canvas.sidebar-field'),d=f.getContext('2d').getImageData(0,0,f.width,f.height).data;let lit=0;for(let k=3;k<d.length;k+=4)if(d[k]>140)lit++;if(!lit)n++;}return n;});
  assert.equal(blank,0,'the field is painted in the first frame after every render');
  // Typing in the sidebar search keeps the open chat where it was and does not rebuild the search box.
  await page.evaluate(()=>{const body=document.getElementById('chat-body');body.scrollTop=420;window.searchBox=document.getElementById('chat-search');});
  await page.locator('#chat-search').pressSequentially('No',{delay:30});
  const kept=await page.evaluate(()=>({scroll:document.getElementById('chat-body').scrollTop,sameBox:window.searchBox===document.getElementById('chat-search'),focused:document.activeElement===document.getElementById('chat-search'),rows:[...document.querySelectorAll('.chat-row')].map(r=>r.dataset.id)}));
  assert.ok(kept.scroll>=400,`the chat keeps its scroll (${kept.scroll})`);assert.ok(kept.sameBox&&kept.focused,'the search box is the same element and keeps focus');assert.deepEqual(kept.rows,['id-nova'],'the list is filtered');
  await page.locator('#chat-search').fill('');
  // Keyboard focus on the search box is clearly visible, not a hairline border change.
  await page.locator('#chat-search').focus();await page.keyboard.press('Shift+Tab');await page.keyboard.press('Tab');
  const ring=await page.evaluate(()=>{const box=document.querySelector('.chat-search'),cs=getComputedStyle(box);return {focused:document.activeElement?.id,style:cs.outlineStyle,width:cs.outlineWidth,color:cs.outlineColor};});
  assert.equal(ring.focused,'chat-search');assert.equal(ring.style,'solid');assert.equal(ring.width,'2px');assert.equal(ring.color,'rgb(102, 101, 95)','the ring uses --text2, which is well above the 3:1 needed');
  // Back to chat from another view works even when the remembered chat no longer exists.
  await page.evaluate(()=>{ui.lastChat='morgan';ui.view={kind:'tasks'};render();});await page.locator('[data-action=return-chat]').click();await page.waitForTimeout(200);
  assert.equal(await page.locator('#message-input').count(),1,'a chat with a composer is shown, not a blank pane');
  await page.evaluate(()=>{ui.view={kind:'chat',target:'gone'};render();});assert.equal(await page.locator('#message-input').count(),1,'an unknown chat falls back to the first agent');
  // Enter that commits an IME composition does not send the message.
  await page.evaluate(()=>{ui.view={kind:'chat',target:'id-atlas'};render();});
  await page.locator('#message-input').fill('こんにちは');
  await page.evaluate(()=>document.getElementById('message-input').dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',keyCode:229,bubbles:true,cancelable:true})));await page.waitForTimeout(200);
  assert.equal(await page.evaluate(()=>sent),0,'a composition-committing Enter is not a send');
  // A file revision is escaped wherever it is shown.
  await page.evaluate(()=>{ui.view={kind:'files'};render();});await page.waitForTimeout(200);
  assert.equal(await page.evaluate(()=>window.pwned),undefined);assert.equal(await page.locator('.files-table img').count(),0);
  // Restoring the sample workspace keeps the chosen appearance.
  await page.evaluate(()=>{state.theme='dark';BuddyTheme.apply();document.body.insertAdjacentHTML('beforeend','<button id="do-reset" data-action="reset">r</button>');});
  await page.locator('#do-reset').click();await page.waitForTimeout(300);
  assert.equal(await page.evaluate(()=>state.theme),'dark');assert.equal(await page.evaluate(()=>document.documentElement.dataset.theme),'dark');
  assert.deepEqual(errors,[]);
 }finally{await context?.close();await rm(dir,{recursive:true,force:true});}
});

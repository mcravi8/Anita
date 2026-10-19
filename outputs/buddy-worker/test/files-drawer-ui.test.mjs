import test from 'node:test';
import assert from 'node:assert/strict';
import {chromium} from 'playwright-core';
import {mkdtemp,rm} from 'node:fs/promises';
import {existsSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';

test('the Files drawer shows its list while an agent is still writing, instead of waiting for the reply to end',{skip:process.platform!=='darwin'||!existsSync('/Applications/Google Chrome.app'),timeout:60000},async()=>{
 const directory=await mkdtemp(path.join(tmpdir(),'buddy-files-drawer-.'));let context;
 try{
  context=await chromium.launchPersistentContext(path.join(directory,'browser.noindex'),{channel:'chrome',headless:true,viewport:{width:1100,height:850}});
  await context.route('**/*',r=>/^https?:/.test(r.request().url())?r.abort():r.continue());
  const page=context.pages()[0];await page.goto(new URL('../../relay/index.html',import.meta.url).href);await page.waitForFunction(()=>!!window.BuddyFiles);
  await page.evaluate(()=>{
   document.getElementById('onboarding-root').innerHTML='';closeModal();
   state.agents=[{id:'chief',name:'Chief',role:'Chief of staff',description:'x',setupStatus:'ready',avatarShape:'star',avatarColor:'lilac',tools:{projectFiles:true}}];state.messages={chief:[]};state.runs={};state.onboarding={status:'completed',agentId:'chief'};
   const folder={folderId:'research',name:'Directed Research',location:'/Users/example/Directed Research',available:true};
   window.BuddyDesktop={saveState:async()=>({saved:true}),projectFiles:async()=>{await new Promise(r=>setTimeout(r,120));return {...folder,folders:[folder],files:[{path:'notes.md',bytes:20}]};}};
   render();
   // A reply that is writing a file reports it with every streamed word.
   window.streaming=setInterval(()=>window.dispatchEvent(new CustomEvent('buddy-conversation',{detail:{type:'file',runId:'r',files:[{path:'notes.md',folderId:'research',revision:'v'+Math.random()}]}})),30);
   BuddyFiles.show();
  });
  await page.locator('[data-project-list] .project-tree-folder, [data-project-list] [data-action="project-file"], [data-project-list] .project-file, [data-project-list] button').first().waitFor({timeout:3000});
  assert.equal(await page.locator('[data-project-list] .connections-loading').count(),0,'the list replaced "Opening your folder…" while events were still arriving');
  await page.evaluate(()=>clearInterval(window.streaming));
 }finally{await context?.close();await rm(directory,{recursive:true,force:true});}
});

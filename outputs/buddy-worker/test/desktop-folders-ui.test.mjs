import test from 'node:test';
import assert from 'node:assert/strict';
import {chromium} from 'playwright-core';
import {mkdtemp,rm} from 'node:fs/promises';
import {existsSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';

test('Buddy desktop follows folders that are connected or disconnected elsewhere',{skip:process.platform!=='darwin'||!existsSync('/Applications/Google Chrome.app'),timeout:60000},async()=>{
 const directory=await mkdtemp(path.join(tmpdir(),'buddy-desktop-folders-.'));let context;
 try{
  context=await chromium.launchPersistentContext(path.join(directory,'browser.noindex'),{channel:'chrome',headless:true,viewport:{width:1200,height:900}});
  await context.route('**/*',r=>/^https?:/.test(r.request().url())?r.abort():r.continue());
  const page=context.pages()[0];await page.goto(new URL('../../relay/index.html',import.meta.url).href);
  await page.evaluate(()=>{
   document.getElementById('onboarding-root').innerHTML='';closeModal();
   state.agents=[{id:'chief',name:'Chief',role:'Chief of staff',description:'Coordinate',setupStatus:'ready',avatarShape:'star',avatarColor:'lilac',tools:{projectFiles:true}}];
   state.messages={chief:[]};state.groups=[];state.runs={};state.desktopProjects=[];state.onboarding={status:'completed',agentId:'chief'};ui.view={kind:'chat',target:'chief'};
   const folder=(id,name)=>({folderId:id,name,location:'/Users/example/'+name,available:true});
   window.connected=[folder('a','Alpha')];
   window.BuddyDesktop={saveState:async()=>({saved:true}),projectFiles:async()=>({...connected[0],folders:connected,files:[]})};
   render();BuddyWorkspace.open();
  });
  const names=async()=>{await page.locator('[data-desktop-new]').first().click();await page.locator('[name=project-folder]').first().waitFor({timeout:8000});const found=await page.locator('.desktop-folder-choice strong').allInnerTexts();await page.evaluate(()=>closeModal());return found;};
  assert.deepEqual(await names(),['Alpha']);
  await page.evaluate(()=>{connected.push({folderId:'b',name:'Beta',location:'/Users/example/Beta',available:true});window.dispatchEvent(new CustomEvent('buddy-conversation',{detail:{type:'project-files-changed'}}));});
  await page.waitForFunction(()=>true);
  await page.waitForTimeout(300);
  assert.deepEqual(await names(),['Alpha','Beta'],'a folder connected in the Files drawer can be picked for a project');
  await page.evaluate(()=>{connected.splice(0,1);window.dispatchEvent(new CustomEvent('buddy-conversation',{detail:{type:'project-files-changed'}}));});
  await page.waitForTimeout(300);
  assert.deepEqual(await names(),['Beta'],'a folder that was disconnected is no longer offered');
 }finally{await context?.close();await rm(directory,{recursive:true,force:true});}
});

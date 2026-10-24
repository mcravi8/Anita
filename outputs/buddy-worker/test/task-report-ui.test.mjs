import test from 'node:test';import assert from 'node:assert/strict';import {chromium} from 'playwright-core';import {mkdtemp,rm} from 'node:fs/promises';import {existsSync} from 'node:fs';import {tmpdir} from 'node:os';import {join} from 'node:path';
// The user, 23 Oct, on a finished task's page: "no task files and more user friendly description". The page says its status once, opens
// with what the report found, the files it saved and what comes next, keeps the working notes under Full report, and lists no project files.
const skip=process.platform!=='darwin'||!existsSync('/Applications/Google Chrome.app');

test('a finished task’s page: its status once, the report’s opening, saved files and Next, the rest under Full report, no file list',{skip,timeout:60000},async()=>{
 const dir=await mkdtemp(join(tmpdir(),'buddy-task-report-'));let context;
 try{
  context=await chromium.launchPersistentContext(join(dir,'browser.noindex'),{channel:'chrome',headless:true,viewport:{width:1280,height:860},reducedMotion:'reduce'});
  await context.route('**/*',r=>/^https?:/.test(r.request().url())?r.abort():r.continue());
  const page=context.pages()[0];const errors=[];page.on('pageerror',e=>errors.push(e.message));
  await page.goto(new URL('../../relay/index.html',import.meta.url).href);await page.waitForFunction(()=>!!window.BuddyWorkerUI);
  await page.evaluate(()=>{
   document.getElementById('onboarding-root').innerHTML='';closeModal();
   state.agents=[{id:'forge',name:'Forge',role:'Builder',avatarShape:'cube',avatarColor:'blue',setupStatus:'ready',tools:{}}];
   state.groups=[];state.onboarding={status:'completed',agentId:'forge'};state.runs={};state.drafts={};state.attachments={};state.proposals=[];state.teamPlans=[];state.messages={forge:[]};
   const result=['**Stage 2 is PARTIAL.** The calibration finished all 33 paths, but no process passed the gates, so the rates are blank. They are not estimates of 0%.',
    'The detector found 34 onsets and 17 eligible events. An independent replay matched every path, its moments and its detector counts.',
    'The [recovery rates](</p/stages/rates.csv>) and [verification](</p/stages/verification.md>) are saved in Research.',
    'Commands run: `python3 stages/scripts/calibrate.py` passed; `python3 stages/scripts/seal.py` passed; the first `verify.py` call exited 1 because a folder was missing; after fixing it the second passed.',
    'Choices made: I kept the inherited detector so the counts compare, and froze the seeds first. **Next:** Chief can use this partial snapshot under the fallback gate. Stage 4 was not started.',
    '','---','Command receipts: 15 finished, 13 exited successfully.'].join('\n');
   const task={id:'s2',workspace:state.conversationWorkspace,agentId:'forge',kind:'coding',provider:'chatgpt',title:'Run stage 2',status:'completed',progress:'Finished',attempt:1,result,
    files:[{path:'stages/rates.csv',absolutePath:'/p/stages/rates.csv'},{path:'stages/verification.md',absolutePath:'/p/stages/verification.md'}],
    fileList:Array.from({length:40},(_,i)=>({path:`stages/scripts/file_${i}.py`})),updatedAt:'2026-10-23T20:00:00Z'};
   window.BuddyDesktop={saveState:async()=>({saved:true}),worker:async p=>p.operation==='status'||p.operation==='start'?{workspace:state.conversationWorkspace,online:true,paused:false,tasks:[task],routines:[],decisions:[],notifications:{},plans:[],pulse:{agents:{}}}:p.operation==='detail'?{task}:p.operation==='notify'?{notifications:{}}:{}};
   navigate('chat','forge');
  });
  await page.evaluate(()=>BuddyWorkerUI.refresh(false));
  await page.evaluate(()=>{const b=document.createElement('button');b.dataset.workerTask='s2';document.body.append(b);b.click();b.remove();});
  const report=page.locator('.worker-report');await report.waitFor({timeout:8000});
  assert.deepEqual(await page.locator('.worker-status, .worker-progress').allInnerTexts(),['Finished'],'the status, said once');
  assert.match(await report.locator('.worker-report-lead').innerText(),/^Stage 2 is PARTIAL\. The calibration finished all 33 paths/);
  // (Outside the Mac app a file the report names is its name with its place on hover; in the app it opens.)
  assert.deepEqual(await report.locator('.worker-report-saved [title]').allInnerTexts(),['recovery rates','verification'],'the files it saved, named');
  assert.match(await report.locator('.worker-report-next').innerText(),/^Next\s+Chief can use this partial snapshot under the fallback gate\. Stage 4 was not started\.$/);
  const more=report.locator('.worker-report-more');
  assert.equal(await more.evaluate(d=>d.open),false,'the working notes start folded');
  assert.equal(await more.locator('p').first().isVisible(),false);
  await more.locator('summary').click();
  assert.match(await more.innerText(),/Commands run: python3 stages\/scripts\/calibrate\.py passed/);assert.match(await more.innerText(),/Command receipts: 15 finished, 13 exited successfully\./);
  assert.equal(await page.locator('.worker-files').count(),0,'no list of the project’s files');
  assert.equal(await page.getByText('stages/scripts/file_3.py').count(),0);
  // A redraw keeps Full report open.
  await page.evaluate(()=>BuddyWorkerUI.refresh(true));await page.waitForTimeout(200);
  assert.equal(await page.locator('.worker-report-more').evaluate(d=>d.open),true);
  assert.deepEqual(errors,[]);
 }finally{await context?.close();await rm(dir,{recursive:true,force:true});}
});

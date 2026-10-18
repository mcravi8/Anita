import test from 'node:test';
import assert from 'node:assert/strict';
import {chromium} from 'playwright-core';
import {mkdir,rm} from 'node:fs/promises';
import {existsSync} from 'node:fs';
import {randomUUID} from 'node:crypto';
import {tmpdir} from 'node:os';
import path from 'node:path';

test('team review keeps edits after a failed save, then adds the real receipt and opens its group',{skip:process.platform!=='darwin'||!existsSync('/Applications/Google Chrome.app')},async()=>{
  const directory=path.join(tmpdir(),'buddy-team-ui-'+randomUUID()+'.noindex');await mkdir(directory,{mode:0o700});
  let context;
  try{
    context=await chromium.launchPersistentContext(directory,{channel:'chrome',headless:true,viewport:{width:1100,height:850}});
    await context.route('**/*',route=>/^https?:/.test(route.request().url())?route.abort():route.continue());
    const page=context.pages()[0];await page.goto(new URL('../../relay/index.html',import.meta.url).href);
    await page.waitForFunction(()=>!!window.BuddyTeamBuilderUI);
    await page.evaluate(()=>{
      document.getElementById('onboarding-root').innerHTML='';closeModal();
      state.agents=[{id:'chief',name:'Chief',role:'Chief of staff',description:'Keep my instructions',avatarShape:'star',avatarColor:'lilac',setupStatus:'ready',tools:{web:true,projectFiles:true,desktop:true}}];state.groups=[];state.messages={chief:[{id:'reply',who:'chief',live:true,runId:'run',status:'completed',body:'A proposed research team.'}]};state.drafts={chief:'Keep this draft'};state.attachments={};state.proposals=[];state.runs={};state.teamPlans=[];state.appliedTeamPlans=[];state.onboarding={status:'completed',agentId:'chief'};ui.view={kind:'chat',target:'chief'};state.lastView=ui.view;
      window.BuddyDesktop={saveState:async()=>({saved:true}),reviewTeamPlan:async()=>{throw Error('Fixture save failure');}};
      window.fixturePlan={id:'plan',workspace:state.conversationWorkspace,native:true,status:'pending',revision:0,runId:'run',chat:'chief',actorName:'Chief',actorId:'chief',label:'Research team',draft:{teamName:'Research team',objective:'Find primary evidence',groupId:'',existingAgentIds:[],includeCreator:true,interviewNewAgents:false,reason:'A specialist can gather sources.',newAgents:[{name:'Scout',role:'Researcher',description:'Read primary sources and cite evidence.',avatarShape:'clover',avatarColor:'mint'}]}};
      BuddyTeamBuilderUI.merge(state,[fixturePlan]);render();BuddyTeamBuilderUI.review('plan');
    });
    await page.locator('.team-plan-member summary').click();
    assert.equal(await page.locator('[data-new-shape="0"] option:checked').textContent(),'Pill');
    assert.equal(await page.locator('[data-new-color="0"] option:checked').textContent(),'Green');
    await page.locator('[data-new-name="0"]').fill('Evidence scout');
    await page.locator('[data-new-instructions="0"]').fill('Verify primary sources and flag uncertainty.');
    await page.locator('#team-plan-form [type="submit"]').click();
    await page.locator('[data-team-plan-error]').filter({hasText:'Fixture save failure'}).waitFor();
    assert.equal(await page.locator('[data-new-name="0"]').inputValue(),'Evidence scout');
    assert.equal(await page.locator('#team-plan-form [type="submit"]').isEnabled(),true);
    await page.evaluate(()=>{
      BuddyDesktop.reviewTeamPlan=async payload=>{
        if(payload.config.newAgents[0].name!=='Evidence scout')throw Error('Edited configuration was lost');
        const agent={...payload.config.newAgents[0],id:'scout',sourceTeamPlanId:'plan',setupStatus:'ready'};
        return {saved:true,created:true,plan:{...fixturePlan,status:'created',revision:1,draft:payload.config,agents:[agent],memberIds:['chief','scout'],group:{id:'team',name:payload.config.teamName,objective:payload.config.objective,members:['chief','scout'],teamPlanIds:['plan']}}};
      };
    });
    await page.locator('#team-plan-form [type="submit"]').click();
    await page.locator('#team-plan-form').waitFor({state:'detached'});
    assert.deepEqual(await page.evaluate(()=>({agents:state.agents.length,groups:state.groups.length,instructions:state.agents[0].description,draft:state.drafts.chief})),{agents:2,groups:1,instructions:'Keep my instructions',draft:'Keep this draft'});
    await page.locator('[data-team-plan="plan"]').click();
    await page.locator('[data-team-plan-chat="team"]').click();
    assert.equal(await page.locator('.conversation-title h1').textContent(),'Research team');
    assert.equal(await page.locator('.conversation-subtitle').textContent(),'2 agents, you');
    await page.setViewportSize({width:390,height:844});
    await page.evaluate(()=>BuddyTeamBuilderUI.review('plan'));
    assert.equal(await page.locator('.modal').evaluate(el=>el.scrollWidth<=el.clientWidth),true);
  }finally{await context?.close();await rm(directory,{recursive:true,force:true});}
});

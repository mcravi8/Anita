import test from 'node:test';
import assert from 'node:assert/strict';
import {CodingSession} from '../coding-session.mjs';
const id='4b088c90-af25-410c-8a7d-74d54e9c1cad';
const config={apiKey:'fixture-key',budget:0.5,home:'/fixture/config',cwd:'/fixture/project',instructions:'Use native scoped tools.',tools:[{name:'buddy_coding_command',description:'Run',inputSchema:{type:'object',properties:{}}}],prompt:'Build the requested tool.',runId:'one',model:'claude-fixture'};
test('coding uses the Claude Code prompt, persists SDK sessions, and resumes the exact saved context',async()=>{
  const calls=[],events=[];
  const host=new CodingSession({query:input=>{calls.push(input);return {async *[Symbol.asyncIterator](){yield {type:'system',subtype:'init',session_id:id};yield {type:'result',result:'Built and checked.',total_cost_usd:0.02,is_error:false,session_id:id};},close(){}};},tool:(name,description,schema,call)=>({name,call}),createSdkMcpServer:x=>x,fromJSONSchema:()=>({shape:{}}),write:e=>events.push(e)});
  await host.start(config);await host.start({...config,runId:'two',resume:id,prompt:'Add the next feature.'});
  assert.equal(calls[0].options.systemPrompt.preset,'claude_code');assert.equal(calls[0].options.persistSession,true);assert.equal(calls[1].options.resume,id);assert.equal(calls[1].options.maxBudgetUsd,0.5);
  assert.deepEqual(calls[0].options.tools,[]);assert.deepEqual(calls[0].options.settingSources,[]);assert.deepEqual(calls[0].options.plugins,[]);assert.equal(calls[0].options.strictMcpConfig,true);assert.equal(calls[0].options.permissionMode,'dontAsk');
  assert.deepEqual(calls[0].options.allowedTools,['mcp__buddy__buddy_coding_command']);assert.equal(events.filter(e=>e.type==='result')[1].sessionId,id);assert.equal(events.filter(e=>e.type==='result')[1].runId,'two');host.close();
});
test('coding rejects stale tool replies, preserves errors and does not invent success on an empty stream',async()=>{
 const events=[],host=new CodingSession({query:()=>({async *[Symbol.asyncIterator](){},close(){}}),tool:()=>{},createSdkMcpServer:x=>x,fromJSONSchema:()=>({shape:{}}),write:e=>events.push(e)});
 await host.start({...config,tools:[]});assert.match(events.at(-1).error,/without a confirmed result/);
 let resolved=false;host.runId='new';host.pending.set('1',()=>{resolved=true;});host.result({runId:'old',id:'1',result:{exitCode:0}});assert.equal(resolved,false);host.result({runId:'new',id:'1',result:{exitCode:1}});assert.equal(resolved,true);
 await assert.rejects(host.start({...config,resume:'bad'}));host.close();await assert.rejects(host.start(config));
});

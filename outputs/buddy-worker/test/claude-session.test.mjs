import test from 'node:test';
import assert from 'node:assert/strict';
import {ClaudeSession} from '../claude-session.mjs';
const config={command:'start',apiKey:'fixture-key',budget:0.5,home:'/fixture/config',cwd:'/fixture',instructions:'Current agent policy',tools:[{name:'buddy_read',description:'Read',inputSchema:{type:'object',properties:{}}}],prompt:'first',runId:'one'};
function fixture(){
  const prepared=[],events=[],calls=[];
  const host=new ClaudeSession({startup:async({options})=>{const h={options,closed:false,used:false,close(){this.closed=true;},query(prompt){assert.equal(this.used,false);this.used=true;calls.push({prompt,options});return {async *[Symbol.asyncIterator](){yield {type:'stream_event',event:{delta:{text:'PRIVATE_STREAM_CONTENT'}}};yield {type:'assistant',message:{content:[{type:'text',text:'Observed answer'}]}};yield {type:'result',result:'Observed answer',total_cost_usd:0.04,is_error:false};},close(){}};}};prepared.push(h);return h;},tool:(name,description,schema,call)=>({name,call}),createSdkMcpServer:x=>x,fromJSONSchema:()=>({shape:{}}),write:x=>events.push(x)});
  return {host,prepared,events,calls};
}
test('idle preparation runs no model; the next message uses a ready process with its own budget',async()=>{
 const f=fixture();await f.host.start(config);await new Promise(r=>setImmediate(r));
 assert.equal(f.calls.length,1);assert.equal(f.prepared.length,2);assert.equal(f.prepared[1].used,false);
 await f.host.start({...config,runId:'two',prompt:'current history and second question'});
 assert.equal(f.calls.length,2);assert.equal(f.prepared[1].used,true);assert.equal(f.calls[1].options.maxBudgetUsd,0.5);assert.equal(f.events.filter(e=>e.type==='result')[1].cost,0.04);assert.equal(f.events.filter(e=>e.type==='result')[1].runId,'two');
 f.host.close();await new Promise(r=>setImmediate(r));assert.equal(f.prepared.at(-1).closed,true);
});
test('changed model, credentials, budget, tools or instructions discard the old prepared process',async()=>{
 for(const change of [{model:'different'},{apiKey:'new-fixture-key'},{budget:0.7},{tools:[]},{instructions:'revoked access'}]){
  const f=fixture();await f.host.start(config);await new Promise(r=>setImmediate(r));const old=f.prepared[1];
  await f.host.start({...config,...change,runId:'two'});assert.equal(old.closed,true);assert.equal(old.used,false);assert.equal(f.calls.length,2);f.host.close();
 }
});
test('closed connections cannot restart; stale turn replies cannot resolve current tool calls',async()=>{
 const f=fixture();f.host.runId='two';let resolved=false;f.host.pending.set('call',()=>{resolved=true;});
 f.host.result({id:'call',runId:'one',result:{saved:true}});assert.equal(resolved,false);
 f.host.result({id:'call',runId:'two',result:{saved:true}});assert.equal(resolved,true);f.host.close();await assert.rejects(f.host.start(config));
});

test('equivalent JSON field order preserves the ready process',async()=>{
 const f=fixture();await f.host.start(config);await new Promise(r=>setImmediate(r));const ready=f.prepared[1];
 const reordered=Object.fromEntries(Object.entries({...config,runId:'two'}).reverse());reordered.tools=[{inputSchema:{properties:{},type:'object'},description:'Read',name:'buddy_read'}];
 await f.host.start(reordered);assert.equal(ready.used,true);assert.equal(ready.closed,false);f.host.close();
});


test('missing worker run IDs fail before SDK startup instead of silently losing tool responses',async()=>{
 const f=fixture();await assert.rejects(f.host.start({...config,runId:undefined}),/missing its run ID/);
 assert.equal(f.prepared.length,0);assert.equal(f.calls.length,0);assert.equal(f.host.busy,false);f.host.close();
});


test('streaming activity keeps live work observable without exposing token or thinking contents',async()=>{
 const f=fixture();await f.host.start(config);
 assert.equal(f.calls[0].options.includePartialMessages,true);
 assert.deepEqual(f.events.find(e=>e.type==='activity'),{type:'activity',runId:'one'});
 assert.equal(JSON.stringify(f.events).includes('PRIVATE_STREAM_CONTENT'),false);f.host.close();
});

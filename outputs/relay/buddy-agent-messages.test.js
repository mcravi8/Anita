const {test}=require('node:test'),assert=require('node:assert/strict'),M=require('./buddy-agent-messages');
test('agent history rejects foreign workspaces and absent or identical participants',()=>{
 const state={conversationWorkspace:'w',agents:[{id:'chief'},{id:'inbox'}]},r={id:'exchange',fromAgentId:'chief',toAgentId:'inbox',question:'What needs attention?',body:'A verified deadline.'};
 assert.deepEqual(M.validRows(state,{workspace:'w',messages:[r,{...r,id:'removed',toAgentId:'other'},{...r,id:'self',toAgentId:'chief'}]}),[r]);assert.deepEqual(M.validRows(state,{workspace:'foreign',messages:[r]}),[]);
});
const state={conversationWorkspace:'w',agents:[{id:'chief'},{id:'inbox'}],runs:{}};
const event=(id,at,extra={})=>({id,exchangeId:'exchange',fromAgentId:'chief',toAgentId:'inbox',at,...extra});
const message=(id,createdAt)=>({id,who:'you',createdAt});
test('requests and replies remain at their actual points around intervening chat messages',()=>{
 const messages=[message('before','2026-10-18T18:00:00Z'),message('during','2026-10-18T18:02:00Z'),message('after','2026-10-18T18:04:00Z')];
 const events=[event('reply','2026-10-18T18:03:00Z'),event('request','2026-10-18T18:01:00Z')];
 const timeline=M.mergeTimeline(state,'chief',messages,events);
 assert.deepEqual(timeline.map(m=>m.id),['before','agent-activity-request','during','agent-activity-reply','after']);assert.equal(timeline[1].count,1);assert.equal(timeline[3].count,1);
 const newer=M.mergeTimeline(state,'chief',[...messages,message('new question','2026-10-18T19:00:00Z')],events);
 assert.deepEqual(newer.slice(0,-1),timeline,'a new question never pulls old activity down to the composer');assert.deepEqual(messages.map(m=>m.id),['before','during','after']);
});
test('nearby activity groups real messages, while separate times and removed peers stay separate',()=>{
 const events=[event('r1','2026-10-18T18:00:00Z'),event('r2','2026-10-18T18:01:00Z'),event('r2','2026-10-18T18:01:00Z'),event('later','2026-10-18T18:20:00Z'),event('removed','2026-10-18T18:21:00Z',{toAgentId:'removed'}),event('bad-time',''),event('self','2026-10-18T18:22:00Z',{toAgentId:'chief'})];
 const groups=M.mergeTimeline(state,'chief',[],events);assert.equal(groups.length,2);assert.equal(groups[0].count,2);assert.deepEqual(groups[0].peers,['inbox']);assert.deepEqual(groups[0].exchangeIds,['exchange']);assert.equal(groups[1].count,1);assert.equal(groups[0].at,'2026-10-18T18:00:00Z');
});
test('legacy clock labels use adjacent dated records across midnight and saved update timestamps',()=>{
 const at=(day,hour,minute)=>new Date(2026,9,day,hour,minute).toISOString();
 const messages=[{id:'legacy',time:'23:58'},message('dated',at(18,0,2)),{id:'notice',time:'00:10'},{id:'reply',runId:'run'}];
 const s={...state,runs:{run:{createdAt:at(18,0,20)}}};
 const out=M.mergeTimeline(s,'chief',messages,[event('before-midnight',at(17,23,59)),event('before-notice',at(18,0,9)),event('after-notice',at(18,0,11))],{notice:at(18,0,10)});
 assert.deepEqual(out.map(m=>m.id),['legacy','agent-activity-before-midnight','dated','agent-activity-before-notice','notice','agent-activity-after-notice','reply']);
});
test('check-ins that were cut short or dropped are not shown in the agent-message history, saved ones included',()=>{
 const s={conversationWorkspace:'w',agents:[{id:'chief'},{id:'inbox'}]},row=(id,status,extra={})=>({id,fromAgentId:'chief',toAgentId:'inbox',question:'Anything new in the inbox?',body:'',status,createdAt:'2026-10-20T14:30:01Z',startedAt:'2026-10-20T14:30:01Z',...extra});
 const stopped='This check stopped because access, settings, or its time limit changed.';
 const rows=[row('434788FF','interrupted',{error:stopped}),row('40AB5B6B','interrupted',{error:stopped}),row('dropped','cancelled',{error:'Team settings changed before this check finished.'}),row('answered','completed',{body:'Inbox is clear.'}),row('asked','running'),row('broken','failed',{error:'The check-in returned no verified structured result.'})];
 assert.deepEqual(M.validRows(s,{workspace:'w',messages:rows}).map(r=>r.id),['answered','asked','broken']);
});
test('task updates in a chat carry their time as workerUpdatedAt, so exchanges with Chief sit between them at the right point',()=>{
 // Forge's chat on 23 October: its task updates had no createdAt, their clock labels were read against one old dated message and stuck days
 // early, and every exchange with Chief from the 22nd and 23rd landed below the latest update.
 const update=(id,iso)=>({id,who:'forge',time:new Date(iso).toLocaleTimeString([],{hour:'2-digit',minute:'2-digit'}),live:true,workerTaskID:id,workerUpdatedAt:iso});
 const s={conversationWorkspace:'w',agents:[{id:'chief'},{id:'forge'}],runs:{}};
 const messages=[{id:'hello',who:'you',createdAt:'2026-10-21T19:57:00Z',time:'12:57'},update('s02a','2026-10-22T23:58:31Z'),update('s03','2026-10-23T07:08:00Z'),update('s02b','2026-10-23T07:21:03Z'),update('approval','2026-10-23T17:14:19Z')];
 const chief=(id,at)=>({id,exchangeId:id,fromAgentId:'chief',toAgentId:'forge',at});
 const out=M.mergeTimeline(s,'forge',messages,[chief('c1','2026-10-22T19:23:00Z'),chief('c2','2026-10-23T06:42:00Z'),chief('c3','2026-10-23T07:23:00Z'),chief('c4','2026-10-23T17:14:30Z')]);
 assert.deepEqual(out.map(m=>m.id),['hello','agent-activity-c1','s02a','agent-activity-c2','s03','s02b','agent-activity-c3','approval','agent-activity-c4']);
});
test('an automatic check-in is not a message: only what an agent asked or handed in, with its reply, is in the history',()=>{
 // Forge's chat on 24 October: "Chief requested an automatic check-in. Check-in completed without a message." filled the history. An
 // automatic check-in is Buddy asking a teammate for the supervisor; nobody wrote it. An older native build still sends them.
 const s={conversationWorkspace:'w',agents:[{id:'chief'},{id:'forge'}]},at='2026-10-24T17:59:20Z';
 const rows=[{id:'auto-quiet',fromAgentId:'chief',toAgentId:'forge',question:'',body:'',status:'completed',createdAt:at},
  {id:'auto-said',fromAgentId:'chief',toAgentId:'forge',question:'',body:'The revised report is nearly ready.',status:'completed',createdAt:at},
  {id:'asked',kind:'checkin',fromAgentId:'chief',toAgentId:'forge',question:'Is the Word check done?',body:'Not yet.',status:'completed',createdAt:at},
  {id:'plan:q',kind:'question',fromAgentId:'forge',toAgentId:'chief',question:'May I rent a second pod?',body:'Yes, one more.',detail:'The first one is full.',status:'completed',createdAt:at},
  {id:'plan:r',kind:'result',verdict:'sent back',title:'Final report',fromAgentId:'forge',toAgentId:'chief',question:'I saved the final report.',body:'Fix the table on page 9.',status:'completed',createdAt:at}];
 assert.deepEqual(M.validRows(s,{workspace:'w',messages:rows}).map(r=>r.id),['asked','plan:q','plan:r']);
});

const {test}=require('node:test'),assert=require('node:assert/strict'),A=require('./buddy-activity');
const state={conversationWorkspace:'w',agents:[{id:'chief'},{id:'inbox'}],groups:[{id:'team',name:'Research',members:['chief']}],messages:{},runs:{},proposals:[]};
test('notifications follow authoritative status transitions, stay workspace scoped, and persist read receipts',()=>{
 const t={id:'t',workspace:'w',agentId:'inbox',title:'Review inbox',status:'waiting_user',updatedAt:'2026-10-18T18:00:00Z'},worker={workspace:'w',tasks:[t]};
 const pending=A.collect(state,worker);assert.equal(pending.length,1);assert.equal(pending[0].kind,'needs');assert.equal(pending[0].taskId,'t');
 const finished=A.collect(state,{workspace:'w',tasks:[{...t,status:'completed'}]});assert.equal(finished.length,1);assert.equal(finished[0].kind,'finished');assert.notEqual(finished[0].id,pending[0].id);
 const read={...state,activitySeen:{[finished[0].id]:true}};assert.equal(A.collect(JSON.parse(JSON.stringify(read)),{workspace:'w',tasks:[{...t,status:'completed'}]})[0].unread,false);
 assert.deepEqual(A.collect(state,{workspace:'foreign',tasks:[t]}),[]);assert.deepEqual(A.collect(state,{workspace:'w',tasks:[{...t,workspace:'foreign'},{...t,agentId:'removed'}]}),[]);assert.deepEqual(A.collect(state,{workspace:'w',tasks:[{...t,status:'running'}]}),[]);
});
test('hidden agents keep their work and alerts, while teams always remain visible',()=>{
 const s={...state,hiddenAgents:['inbox','team']},entries=[{id:'chief'},{id:'inbox'},{id:'team',isGroup:true}],before=JSON.stringify(s);
 assert.deepEqual(A.splitChats(s,entries),{visible:[entries[0],entries[2]],hidden:[entries[1]]});assert.equal(JSON.stringify(s),before);
 assert.equal(A.collect(s,{workspace:'w',tasks:[{id:'t',agentId:'inbox',status:'waiting_review'}]})[0].kind,'needs');
});
test('resolved checks and worker-linked routine blockers do not create duplicate attention items',()=>{
 const worker={workspace:'w',tasks:[{id:'t',agentId:'inbox',status:'waiting_review'}],routines:[{id:'r',agentId:'inbox',status:'needs_attention',lastTaskID:'t'}]};
 assert.equal(A.collect(state,worker).length,1);assert.equal(A.collect(state,{}, {workspace:'w',checks:[{id:'old',agentId:'chief',kind:'overview',status:'failed'},{id:'new',agentId:'chief',kind:'overview',status:'completed'}]}).length,0);
 const repeated={workspace:'w',routines:Array.from({length:6},(_,n)=>({id:'r'+n,agentId:'inbox',status:'needs_attention',lastError:'Previous run needs attention.'}))};const grouped=A.collect(state,repeated);assert.equal(grouped.length,1);assert.equal(grouped[0].label,'6 scheduled checks');assert.equal(grouped[0].action,'background-work');
 const partial={...state,runs:{run:{runId:'run',target:'team',status:'completed',team:{partial:true}}}};assert.equal(A.collect(partial)[0].kind,'needs');partial.runs.run.team.partial=false;assert.equal(A.collect(partial)[0].kind,'finished');
});

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
test('read and unread controls clear badges without resolving work, persist, and distinguish a new failure',()=>{
 const s=structuredClone(state),t={id:'t',agentId:'inbox',status:'failed',attempt:1,progress:'The cost is uncertain.'},w={workspace:'w',tasks:[t]};
 const id=A.collect(s,w)[0].id;assert.equal(A.unreadCounts(A.collect(s,w)).needs,1);A.markRead(s,[id]);const loaded=JSON.parse(JSON.stringify(s));assert.equal(A.collect(loaded,w).length,1);assert.equal(A.unreadCounts(A.collect(loaded,w)).needs,0);assert.equal(t.status,'failed');A.markRead(loaded,[id],false);assert.equal(A.unreadCounts(A.collect(loaded,w)).needs,1);A.markRead(loaded,[id]);assert.equal(A.unreadCounts(A.collect(loaded,{workspace:'w',tasks:[{...t,attempt:2}]})).needs,1);
});
test('linked schedules share the actual task alert and check failures explain the cause',()=>{
 const w={workspace:'w',tasks:[{id:'t',agentId:'inbox',status:'failed',routineSeriesID:'series',progress:'This task’s Claude budget is exhausted or its last cost is uncertain.'}],routines:Array.from({length:6},(_,n)=>({id:'r'+n,agentId:'inbox',routineSeriesID:'series',status:'needs_attention'}))};assert.equal(A.collect(state,w).length,1);assert.match(A.collect(state,w)[0].description,/additional allowance/);
 const c=A.collect(state,{}, {workspace:'w',checks:[{id:'c',agentId:'chief',kind:'overview',status:'failed',error:'A team update referenced work outside its actual check-in.'}]})[0];assert.equal(c.checkId,'c');assert.match(c.description,/source reference/);assert.match(c.title,/Team update/);
});
test('an action that may not have gone through is something to check, whatever state its task is in',()=>{
 const t={id:'t',workspace:'w',agentId:'inbox',title:'Send the form',status:'paused',updatedAt:'2026-10-18T18:00:00Z',attempt:1,unconfirmedCount:1},worker=w=>({workspace:'w',tasks:[w]});
 for(const status of ['paused','cancelled','completed','failed']){
  const items=A.collect(state,worker({...t,status}));assert.equal(items.length,1,status);assert.equal(items[0].kind,'needs',status);assert.equal(items[0].actionLabel,status==='failed'?'Open task':'Check action',status);
 }
 assert.deepEqual(A.collect(state,worker({...t,unconfirmedCount:0})),[],'a paused task with nothing unconfirmed is not an item');
 assert.match(A.collect(state,worker(t))[0].description,/may not have gone through/);
 assert.match(A.collect(state,worker({...t,unconfirmedCount:3}))[0].description,/3 actions/);
 const interrupted=A.collect(state,worker({...t,status:'interrupted',progress:'The worker restarted while “Click Send” may have been sent. Check whether it went through before continuing. Nothing was automatically retried.'}));
 assert.match(interrupted[0].description,/Click Send/,'an interrupted task names the action instead of a generic message');
 assert.notEqual(A.collect(state,worker(t))[0].id,A.collect(state,worker({...t,unconfirmedCount:2}))[0].id,'a further unconfirmed action is a new item');
 assert.equal(A.collect(state,worker({...t,unconfirmedCount:0,status:'completed'}))[0].kind,'finished','finished work with nothing unconfirmed is unchanged');
});

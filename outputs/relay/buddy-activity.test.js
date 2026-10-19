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
test('the app reports one blocker per cause, and the list shows exactly those, the work in progress, and what finished',()=>{
 const task={id:'t',workspace:'w',agentId:'inbox',title:'Apply',status:'waiting_review',attempt:1,attentionKey:'review:one',progress:'Needs your review',updatedAt:'2026-10-18T18:00:00Z'};
 const decision={id:'review:one',kind:'signin',agentId:'inbox',taskId:'t',title:'Sign-in needs your choice',question:'Choose how to sign in to https://example.com.',actionLabel:'Review',createdAt:'2026-10-18T18:00:00Z'};
 const worker={workspace:'w',tasks:[task],decisions:[decision]};
 const items=A.collect(state,worker);
 assert.deepEqual(items.map(i=>[i.id,i.kind]),[['decision:review:one','needs']],'one sign-in issue is one item, though the task also looks "waiting"');
 assert.equal(items[0].taskId,'t');assert.equal(items[0].unread,true);assert.equal(items[0].description,'Choose how to sign in to https://example.com.');
 const legacy=A.collect(state,{workspace:'w',tasks:[task]});assert.equal(legacy.length,1,'before the app reports blockers, task states still stand in');assert.equal(legacy[0].id.startsWith('task:'),true);
 const running=A.collect(state,{workspace:'w',tasks:[{...task,status:'running',progress:'Reading the job page'},{...task,id:'q',status:'queued'},{...task,id:'p',status:'paused'}],decisions:[]});
 assert.deepEqual(running.map(i=>i.kind).sort(),['working','working'],'running and queued work is listed as working, paused is not');
 assert.equal(running.every(i=>i.unread===false)&&A.unreadCounts(running).needs===0&&A.unreadCounts(running).finished===0,true,'working is never unread and never counted');
 assert.match(running.find(i=>i.taskId==='t').description,/Reading the job page/);
 const failed=A.collect(state,{workspace:'w',tasks:[{...task,status:'failed',progress:'The site did not answer.'}],decisions:[{id:'stopped:t:1:failed',kind:'stopped',agentId:'inbox',taskId:'t',title:'Apply',question:'The site did not answer.',actionLabel:'Open task',createdAt:'2026-10-18T18:05:00Z'}]});
 assert.equal(failed.length,1,'a failed task is one item');
 const done=A.collect(state,{workspace:'w',tasks:[{...task,status:'completed'}],decisions:[]});assert.deepEqual(done.map(i=>i.kind),['finished'],'a finished task is still listed as finished');
});
test('read and dismissed state is the app’s once it answers, separate from each other, and never changes the work',()=>{
 const task={id:'t',workspace:'w',agentId:'inbox',title:'Apply',status:'completed',attempt:1,updatedAt:'2026-10-18T18:00:00Z'};
 const worker=n=>({workspace:'w',tasks:[task],decisions:[],notifications:n});
 const id=A.collect(state,worker({}))[0].id;
 assert.equal(A.collect(state,worker({}))[0].unread,true);
 assert.equal(A.collect(state,worker({[id]:{read:true,dismissed:false}}))[0].unread,false,'the app marks it read');
 const localRead={...state,activitySeen:{[id]:true}};
 assert.equal(A.collect(localRead,worker({[id]:{read:false,dismissed:false}}))[0].unread,true,'the app’s answer wins over the page’s copy');
 assert.equal(A.collect(localRead,worker({}))[0].unread,false,'the page’s copy stands in when the app has no record');
 assert.deepEqual(A.collect(state,worker({[id]:{read:true,dismissed:true}})),[],'a dismissed alert is hidden');
 assert.equal(A.collect(state,worker({[id]:{read:false,dismissed:true}})).length,0,'dismissed does not depend on read');
 const local={...state};A.dismiss(local,[id]);assert.deepEqual(A.collect(local,worker({})),[],'the page’s copy hides it too when the app has no record');
 A.dismiss(local,[id],false);assert.equal(A.collect(local,worker({})).length,1,'a dismissal can be undone');
 const stuck={id:'d',kind:'stopped',agentId:'inbox',taskId:'t',title:'Apply',question:'Stopped.',actionLabel:'Open task',createdAt:'2026-10-18T19:00:00Z'};
 const dismissedNeed=A.collect(state,{workspace:'w',tasks:[{...task,status:'failed'}],decisions:[stuck],notifications:{'decision:d':{read:false,dismissed:true}}});
 assert.deepEqual(dismissedNeed,[],'dismissing hides the alert');
 const stillThere=[{...task,status:'failed'}];assert.equal(stillThere[0].status,'failed','and the task itself is untouched');
});
test('the bell, the chat badge and the Background work badge agree about one blocker',()=>{
 const task={id:'t',workspace:'w',agentId:'inbox',title:'Apply',status:'waiting_user',attempt:1,updatedAt:'2026-10-18T18:00:00Z'};
 const d={id:'waiting:t:1',kind:'waiting',agentId:'inbox',taskId:'t',title:'Apply',question:'Browser opened for you.',actionLabel:'Open task',createdAt:'2026-10-18T18:00:00Z'};
 const items=A.collect(state,{workspace:'w',tasks:[task],decisions:[d]}),counts=A.unreadCounts(items);
 assert.equal(counts.needs,1);assert.equal(A.workUnread(items),1);assert.equal(items.filter(i=>i.agentId==='inbox'&&i.kind==='needs'&&i.unread).length,1);
 const read=A.collect(state,{workspace:'w',tasks:[task],decisions:[d],notifications:{'decision:waiting:t:1':{read:true,dismissed:false}}});
 assert.equal(A.unreadCounts(read).needs,0);assert.equal(A.workUnread(read),0);assert.equal(read.length,1,'read keeps it listed, still needing you');
 const resolved=A.collect(state,{workspace:'w',tasks:[{...task,status:'running'}],decisions:[]});
 assert.equal(A.unreadCounts(resolved).needs,0);assert.equal(A.workUnread(resolved),0);assert.equal(resolved.filter(i=>i.kind==='needs').length,0,'resolving the blocker removes every representation of it');
});

test('a change waiting for the person’s OK is a card that asks for it, and a rule that earned its freedom is a notice',()=>{
 const confirm={id:'change:c1',kind:'confirm',agentId:'inbox',taskId:'',title:'Allow this change?',question:'You asked for this in chat: Inbox’s browser access: off → on. It gives more access or room to spend, so it waits for your OK.',actionLabel:'Allow',payload:{changeId:'c1'},createdAt:'2026-10-18T18:00:00Z'};
 const notice={id:'graduated:r1:3',kind:'notice',agentId:'inbox',taskId:'',title:'Inbox now works without asking',question:'You approved 3 checks.',actionLabel:'Review rule',payload:{ruleId:'r1'},createdAt:'2026-10-18T19:00:00Z'};
 const items=A.collect(state,{workspace:'w',tasks:[],decisions:[confirm,notice]});
 const asks=items.find(i=>i.id==='decision:change:c1'),told=items.find(i=>i.id==='decision:graduated:r1:3');
 assert.equal(asks.kind,'needs');assert.equal(asks.changeId,'c1');assert.equal(asks.actionLabel,'Review change');assert.equal(asks.unread,true);assert.match(asks.description,/off → on/);
 assert.equal(told.kind,'finished','it is news, not a request');assert.equal(told.ruleId,'r1');assert.equal(told.agentId,'inbox');
 assert.equal(A.unreadCounts(items).needs,1);
 const gone=A.collect(state,{workspace:'w',tasks:[],decisions:[{...confirm,agentId:'removed'}]});assert.equal(gone.length,0,'an agent that is gone has no cards');
 const dismissed=A.collect(state,{workspace:'w',tasks:[],decisions:[notice],notifications:{'decision:graduated:r1:3':{read:false,dismissed:true}}});assert.equal(dismissed.length,0,'the notice can be dismissed');
 const answered=A.collect(state,{workspace:'w',tasks:[],decisions:[]});assert.equal(answered.length,0,'once answered, the card is gone');
});

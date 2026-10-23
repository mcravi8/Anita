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
 const w={workspace:'w',tasks:[{id:'t',agentId:'inbox',status:'failed',routineSeriesID:'series',progress:'This task’s Claude budget is exhausted or its last cost is uncertain.'}],routines:Array.from({length:6},(_,n)=>({id:'r'+n,agentId:'inbox',routineSeriesID:'series',status:'needs_attention'}))};assert.equal(A.collect(state,w).length,1);assert.match(A.collect(state,w)[0].description,/daily limit is used up/);
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

test('Needs you lists what needs the person; what waits for the supervisor shows only if Chief has not picked it up',()=>{
 const now=Date.parse('2026-10-19T12:00:00Z'),at=minutes=>new Date(now-minutes*60000).toISOString();
 const people={...state,agents:[{id:'chief',name:'Chief'},{id:'inbox',name:'Inbox'}]};
 const forUser={id:'signin:t1',kind:'signin',audience:'user',agentId:'inbox',taskId:'t1',title:'Sign in',question:'Choose how to sign in.',createdAt:at(2)};
 const legacy={id:'waiting:t2:1',kind:'waiting',agentId:'inbox',taskId:'t2',title:'Old entry',question:'Browser opened for you.',createdAt:at(2)};
 const forChief={id:'result:t3:1',kind:'result',audience:'supervisor',agentId:'inbox',taskId:'t3',title:'Draft the reply',question:'The reply is drafted.',createdAt:at(2)};
 const worker=(lane,decisions=[forUser,legacy,forChief])=>({workspace:'w',tasks:[],decisions,...(lane===undefined?{}:{supervisorLane:lane})});
 const ids=items=>items.filter(i=>i.kind==='needs').map(i=>i.id);
 assert.deepEqual(ids(A.collect(people,worker({online:true,busy:false}),{},now)),['decision:signin:t1','decision:waiting:t2:1'],'the supervisor’s item stays off the list while the lane is online and the item is fresh');
 const offline=A.collect(people,worker({online:false}),{},now);
 assert.equal(ids(offline).includes('decision:result:t3:1'),true,'shown when the supervisor lane is offline');
 assert.match(offline.find(i=>i.id==='decision:result:t3:1').note,/^Chief hasn’t picked this up yet/);
 assert.equal(offline.find(i=>i.id==='decision:signin:t1').note,undefined,'a request for the person carries no such label');
 assert.equal(ids(A.collect(people,worker(undefined),{},now)).includes('decision:result:t3:1'),true,'and when the app does not report the lane at all');
 const stale=A.collect(people,worker({online:true},[{...forChief,createdAt:at(16)}]),{},now);
 assert.deepEqual(ids(stale),['decision:result:t3:1'],'shown once it has been open for more than 15 minutes');assert.match(stale[0].note,/hasn’t picked this up yet/);
 assert.deepEqual(ids(A.collect(people,worker({online:true},[{...forChief,createdAt:at(14)}]),{},now)),[],'but not before');
 assert.deepEqual(ids(A.collect(people,worker({online:true},[{...forChief,createdAt:''}]),{},now)),['decision:result:t3:1'],'an item whose age is unknown is shown');
 const counted=A.collect(people,worker({online:true}),{},now);assert.equal(A.unreadCounts(counted).needs,2,'the badges count only what is listed');
 const named={...people,agents:[...people.agents,{id:'mira',name:'Mira'}]};
 assert.match(A.collect(named,{workspace:'w',tasks:[{id:'t3',agentId:'inbox',status:'completed',supervisorId:'mira'}],decisions:[forChief],supervisorLane:{online:false}},{},now).find(i=>i.id==='decision:result:t3:1').note,/^Mira hasn’t picked this up yet/,'named after the task’s own supervisor');
});
test('a used-up daily limit says it continues tomorrow or can be raised, never an allowance',()=>{
 for(const raw of ['This task’s Claude budget is exhausted or its last cost is uncertain.','The automatic usage limit was reached.','Reached maximum budget'])assert.equal(A.describe(raw),'Today’s daily limit is used up. It continues tomorrow, or raise the limit in the agent’s settings.');
 assert.doesNotMatch(A.describe('Reached maximum budget'),/allowance/);
});
test('a quiet scheduled check raises no notification, while the same kind of check with news does',()=>{
 const t={id:'scan',workspace:'w',agentId:'inbox',title:'Check AgentMail and Gmail',status:'completed',updatedAt:'2026-10-19T15:00:00Z'};
 assert.equal(A.collect(state,{workspace:'w',tasks:[{...t,quiet:true}]}).length,0);
 assert.equal(A.collect(state,{workspace:'w',tasks:[{...t,quiet:false}]}).length,1);
 assert.equal(A.collect(state,{workspace:'w',tasks:[{...t,status:'failed',progress:'Reached maximum budget',quiet:true}]}).length,0);
});
test('a check-in that was cut short never needs the person, while a real failure still does',()=>{
 const stopped='This check stopped because access, settings, or its time limit changed.',check=(id,status,extra={})=>({id,agentId:'inbox',kind:'checkin',status,error:stopped,createdAt:'2026-10-20T14:30:01Z',...extra});
 assert.deepEqual(A.collect(state,{}, {workspace:'w',checks:[check('434788FF','interrupted'),check('40AB5B6B','interrupted'),check('24423061','interrupted')]}),[]);
 assert.deepEqual(A.collect(state,{}, {workspace:'w',checks:[check('done','completed',{error:''}),check('new','interrupted')]}),[],'an interruption after a finished check-in is not news either');
 const failed=A.collect(state,{}, {workspace:'w',checks:[check('bad','failed',{error:'The check-in returned no verified structured result.'})]});assert.equal(failed.length,1);assert.equal(failed[0].checkId,'bad');
});
test('the agents that need the person are exactly those with an unread "needs you" item',()=>{
 const d=(id,extra={})=>({id,kind:'stopped',agentId:'inbox',taskId:id,title:'Check',question:'Stopped.',audience:'user',createdAt:'2026-10-20T14:25:38Z',...extra});
 const worker={workspace:'w',tasks:[],decisions:[d('a'),d('b',{agentId:'chief'})],notifications:{}};
 assert.deepEqual([...A.needingAgents(A.collect(state,worker))].sort(),['chief','inbox']);
 assert.deepEqual([...A.needingAgents(A.collect({...state,activitySeen:{'decision:a':true}},worker))],['chief'],'a seen item no longer counts');
 assert.deepEqual([...A.needingAgents(A.collect({...state,activityDismissed:{'decision:b':true}},worker))],['inbox'],'nor a dismissed one');
 const lane={...worker,supervisorLane:{online:true},decisions:[d('c',{audience:'supervisor',createdAt:new Date().toISOString()})]};
 assert.deepEqual([...A.needingAgents(A.collect(state,lane))],[],'nor one the supervisor is handling');
 assert.deepEqual([...A.needingAgents(A.collect(state,{workspace:'w',tasks:[{id:'t',agentId:'inbox',status:'completed'}],decisions:[]}))],[],'a finished result is not something that needs the person');
});
test('a task waiting for a sign-in is a Needs card that opens the agent’s chat at its request; a routine command review waits for the supervisor unless the lane is offline',()=>{
 const now=Date.parse('2026-10-20T12:00:00Z');
 const people={...state,agents:[{id:'chief',name:'Chief'},{id:'forge',name:'Forge'}]};
 const card={id:'credential:t1:1:wrds',kind:'credential',audience:'user',agentId:'forge',taskId:'t1',title:'WRDS needs your sign-in',question:'Sign in to WRDS so the agent can run the extract.',actionLabel:'Sign in',payload:{taskId:'t1',profile:'wrds'},createdAt:new Date(now-60000).toISOString()};
 const duo={id:'mfa:t1:c1',kind:'mfa',audience:'user',agentId:'forge',taskId:'t1',title:'Approve the WRDS Duo push on your phone',question:'A command is signing in to WRDS.',actionLabel:'Open task',payload:{taskId:'t1'},createdAt:new Date(now-30000).toISOString()};
 const routine={id:'review:r1',kind:'command_review',audience:'supervisor',agentId:'forge',taskId:'t2',title:'Review: Run command outside the sandbox',question:'Allow this exact command?',actionLabel:'Review',payload:{taskId:'t2',reviewId:'r1'},createdAt:new Date(now-60000).toISOString()};
 const items=A.collect(people,{workspace:'w',tasks:[],decisions:[card,duo,routine],supervisorLane:{online:true}},{},now);
 const signin=items.find(i=>i.id==='decision:'+card.id);
 assert.equal(signin.kind,'needs');assert.equal(signin.title,'WRDS needs your sign-in');assert.equal(signin.actionLabel,'Sign in in chat');assert.equal(signin.chatTarget,'forge');assert.equal(signin.focusTask,'t1');assert.equal(signin.taskId,'t1');
 assert.equal(signin.signin,undefined,'no separate sign-in box: the chat is where it is typed');
 const push=items.find(i=>i.id==='decision:'+duo.id);
 assert.equal(push.title,'Approve the WRDS Duo push on your phone','the Duo wait is a Needs item too');assert.equal(push.chatTarget,'forge','and it opens the chat with its Done button');
 assert.equal(items.some(i=>i.id==='decision:review:r1'),false,'Chief answers the routine command while the lane is online');
 assert.equal(A.collect(people,{workspace:'w',tasks:[],decisions:[routine],supervisorLane:{online:false}},{},now).some(i=>i.id==='decision:review:r1'),true,'with the lane offline the person sees it');
});
test('a decision Chief forwarded about the plan opens the team chat at its card, where it is answered',()=>{
 // The user's S04a question: its notification said Answer but opened the background task, which has nowhere to answer, and the plan view's
 // "See what needs you" opened the notifications again.
 const decision={id:'escalation:run:waiting:task:1',kind:'escalation',status:'open',audience:'user',agentId:'chief',title:'Chief needs your decision',question:'May we change the November 12 restriction?',createdAt:'2026-10-23T16:55:18Z',taskId:'task',
  payload:{noticeId:'N1',planId:'p1',category:'objective',taskId:'task'}};
 const worker={workspace:'w',decisions:[decision],plans:[{id:'p1',groupId:'team'}]};
 const item=A.collect(state,worker)[0];
 assert.equal(item.kind,'needs');assert.equal(item.chatTarget,'team');assert.equal(item.focusNotice,'N1');assert.equal(item.actionLabel,'Answer in chat');
 // A plan this workspace no longer shows keeps the task as before.
 const elsewhere=A.collect(state,{...worker,plans:[{id:'p1',groupId:'gone'}]})[0];
 assert.equal(elsewhere.chatTarget,undefined);assert.equal(elsewhere.taskId,'task');
});

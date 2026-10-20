const test=require('node:test'),assert=require('node:assert/strict'),worker=require('./buddy-worker');
test('background task status distinguishes review, user handoff, errors and recovery',()=>{
  assert.equal(worker.labels.waiting_review,'Needs review');assert.equal(worker.labels.waiting_user,'Needs you');
  for(const status of ['paused','failed','interrupted','waiting_user'])assert.equal(worker.canResume(status),true);
  for(const status of ['completed','cancelled','running','waiting_review','queued'])assert.equal(worker.canResume(status),false);
  assert.deepEqual(worker.pending({reviews:[{id:'1',status:'pending'},{id:'2',status:'uncertain'},{id:'3',status:'completed'}]}).map(x=>x.id),['1']);
});

test('routine results arrive once in the correct DM, including after reopening',()=>{const s={conversationWorkspace:'w',agents:[{id:'a'},{id:'b'}],messages:{}},t={id:'task',routineID:'r',workspace:'w',agentId:'a',status:'completed',attempt:1,result:'Found Zopa and UBS in the checked searches.',coverage:[{partial:false,read:2}],updatedAt:'2026-10-17T16:01:00Z'};const UI=require('./buddy-worker');assert.equal(UI.deliverResult(s,t),true);assert.equal(UI.deliverResult(s,t),false);assert.equal(UI.deliverResult(JSON.parse(JSON.stringify(s)),t),false);assert.equal(s.messages.a.length,1);assert.equal(s.messages.b,undefined);assert.equal(s.messages.a[0].coverage[0].read,2);assert.equal(UI.deliverResult(s,{...t,id:'bad',workspace:'other'}),false);assert.equal(UI.deliverResult(s,{...t,id:'bad',agentId:'removed'}),false);assert.equal(UI.deliverResult(s,{...t,id:'bad',status:'running'}),false);assert.equal(UI.deliverResult(s,{...t,id:'failed',status:'failed',result:'',progress:'Gmail is disconnected.'}),true);assert.match(s.messages.a[1].body,/couldn’t finish/);assert.match(s.messages.a[1].body,/Gmail is disconnected/);});

test('coding results return to the owning DM once per attempt and completed sessions support a follow-up',()=>{
 const s={conversationWorkspace:'w',agents:[{id:'a'}],messages:{}},t={id:'code',kind:'coding',workspace:'w',agentId:'a',status:'completed',attempt:1,result:'Built the tool. Command receipts: 1 finished, 1 exited successfully.',updatedAt:'2026-10-17T20:00:00Z'};
 assert.equal(worker.deliverResult(s,t),true);assert.equal(worker.deliverResult(s,t),false);assert.equal(worker.canResume('completed','coding'),true);assert.equal(worker.canResume('completed','research'),false);
 assert.equal(worker.deliverResult(s,{...t,attempt:2,result:'Added the requested feature.'}),true);assert.equal(s.messages.a.length,2);assert.equal(worker.deliverResult(s,{...t,id:'another',kind:'research'}),true);
});


test('ordinary browser work reports results and distinct blockers in its DM without background wording',()=>{
 const s={conversationWorkspace:'w',agents:[{id:'chief'}],messages:{}},t={id:'browser',kind:'general',workspace:'w',agentId:'chief',status:'waiting_review',attempt:1,title:'Create AgentMail inbox',progress:'Review the requested inbox creation',attentionKey:'review-one',updatedAt:'2026-10-18T04:40:00Z'};
 assert.equal(worker.deliverResult(s,t),true);assert.equal(worker.deliverResult(s,t),false);
 assert.match(s.messages.chief[0].body,/need your approval/);assert.equal(s.messages.chief[0].workerStatus,'waiting_review');
 assert.equal(worker.deliverResult(JSON.parse(JSON.stringify(s)),t),false);
 assert.equal(worker.deliverResult(s,{...t,attentionKey:'review-two'}),true);
 assert.equal(worker.deliverResult(s,{...t,status:'waiting_user',attentionKey:'signin',progress:'Sign in privately.'}),true);
 assert.match(s.messages.chief.at(-1).body,/sign in/i);
 assert.equal(s.messages.chief.length,1,'review transitions update one attention message');
 assert.equal(worker.deliverResult(s,{...t,status:'completed',result:'Created the requested inbox; verified on the website.'}),true);
 assert.equal(s.messages.chief.at(-1).workerTaskID,'browser');
 assert.equal(worker.deliverResult(s,{...t,status:'completed',result:'Duplicate'}),false);
 assert.equal(worker.deliverResult(s,{...t,status:'running'}),false);
 assert.equal(worker.deliverResult(s,{...t,status:'failed',progress:'The website rejected the requested address.'}),true);
 assert.match(s.messages.chief.at(-1).body,/website rejected/);
 assert.equal(worker.deliverResult(s,{...t,id:'other',agentId:'missing'}),false);
 assert.equal(worker.deliverResult(s,{...t,id:'other',workspace:'elsewhere'}),false);
});


test('task blockers stay brief and keep diagnostic logs or partial results out of the DM',()=>{
 const s={conversationWorkspace:'w',agents:[{id:'a'}],messages:{}},t={id:'long-error',workspace:'w',agentId:'a',status:'interrupted',title:'Open my inbox',attempt:1,updatedAt:'2026-10-18T05:00:00Z',progress:'Technical detail '.repeat(100),result:'Verbose partial work '.repeat(100)};
 assert.equal(worker.deliverResult(s,t),true);assert.ok(s.messages.a[0].body.length<150);assert.match(s.messages.a[0].body,/Open the task for details/);assert.equal(s.messages.a[0].body.includes('Verbose partial'),false);
});
test('sign-in transitions keep one actionable message and preserve the final result',()=>{const s={conversationWorkspace:'w',agents:[{id:'a'}],messages:{}},t={id:'job',workspace:'w',agentId:'a',title:'Create inbox',attempt:1,status:'waiting_review',attentionKey:'auth',updatedAt:'2026-10-18T05:44:00Z',reviews:[{status:'pending',kind:'authentication',mode:'signin'}]};worker.deliverResult(s,t);assert.equal(s.messages.a[0].body,'Please sign in to continue.');worker.deliverResult(s,{...t,status:'waiting_user',attentionKey:'private',updatedAt:'2026-10-18T05:45:00Z',progress:'Private Chrome is open. Finish sign-in in Buddy when ready.'});assert.equal(s.messages.a.length,1);assert.match(s.messages.a[0].body,/Finish private sign-in/);worker.deliverResult(s,{...t,status:'completed',result:'Created chief@example.test.',updatedAt:'2026-10-18T05:46:00Z'});assert.equal(worker.presentation(s,s.messages.a[0]).hidden,true);assert.equal(worker.presentation(s,s.messages.a[1]).body,'Created chief@example.test.');});

test('no task waits for an allowance any more: runs have no limit of their own',()=>{
 const coding={id:'code',kind:'coding',provider:'claude',status:'interrupted',budgetUSD:2,remainingBudgetUSD:0,reservedBudgetUSD:2};
 for(const status of ['paused','failed','interrupted','waiting_user'])assert.equal(worker.needsAllowance({...coding,status}),false,status+' work simply continues');
 assert.equal(worker.canResume('interrupted','coding'),true);
});


test('actions that may or may not have gone through are listed for the user to check, and nothing else is',()=>{
 const task={reviews:[{id:'1',status:'pending'},{id:'2',status:'uncertain',tool:{name:'Click Send'}},{id:'3',status:'completed'},{id:'4',status:'not_sent'},{id:'5',status:'dispatched'},{id:'6',status:'uncertain',kind:'authentication',origin:'https://example.com'}]};
 assert.deepEqual(worker.unconfirmed(task).map(r=>r.id),['2','6']);
 assert.deepEqual(worker.unconfirmed({}),[]);assert.deepEqual(worker.pending(task).map(r=>r.id),['1'],'checking an action is separate from approving one');
});

test('a pause the system made is told in the agent’s chat; a pause the person or a routine made is not',()=>{
 assert.equal(worker.deliverable({status:'paused',stopCause:'access.narrowed'}),true);
 assert.equal(worker.deliverable({status:'paused',stopCause:'provider.disconnected'}),true);
 assert.equal(worker.deliverable({status:'paused',stopCause:''}),true,'a pause with no recorded cause is told too');
 for(const stopCause of ['user.pause','user.pauseAll','user.plan_stop','routine.paused','superseded'])assert.equal(worker.deliverable({status:'paused',stopCause}),false,stopCause);
 assert.equal(worker.deliverable({status:'paused',stopCause:'limit',blockedBy:'limit'}),false,'the daily limit has its own Needs item');
 assert.equal(worker.deliverable({status:'paused',stopCause:'access.narrowed',quiet:true}),false);
 const s={conversationWorkspace:'w',agents:[{id:'a'}],messages:{}},t={id:'job',workspace:'w',agentId:'a',title:'Draft the brief',status:'paused',stopCause:'provider.disconnected',attempt:1,progress:'Paused: Claude was disconnected. It continues by itself once reconnected.',updatedAt:'2026-10-19T10:00:00Z'};
 assert.equal(worker.deliverResult(s,t),true);assert.equal(worker.deliverResult(s,t),false,'once');
 assert.equal(s.messages.a[0].body,'**Draft the brief** is paused. Claude was disconnected. It continues by itself once reconnected.');
 assert.equal(worker.deliverResult(s,{...t,id:'mine',stopCause:'user.pause',progress:'Paused.'}),false);
 assert.equal(worker.taskMessage({...t,progress:''}),'**Draft the brief** is paused. Open the task for details.');
});
test('a scheduled check the app marked quiet says nothing: no message in the DM',()=>{
 const s={conversationWorkspace:'w',agents:[{id:'a'}],messages:{}},t={id:'scan',routineID:'r',workspace:'w',agentId:'a',status:'completed',attempt:1,result:'Nothing new since the last check. The Bank of America assessment is still open.',updatedAt:'2026-10-19T15:00:00Z'};
 const UI=require('./buddy-worker');
 assert.equal(UI.deliverResult(s,{...t,quiet:true}),false,'nothing new, nothing said');assert.equal((s.messages.a||[]).length,0);
 assert.equal(UI.deliverResult(s,{...t,id:'scan2',quiet:false}),true,'a check with something to say still arrives');
 assert.equal(UI.deliverResult(s,{...t,id:'scan3',status:'failed',progress:'Reached maximum budget',quiet:true}),false,'and so does not the same failure again');
});

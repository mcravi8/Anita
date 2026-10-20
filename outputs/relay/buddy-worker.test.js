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

// An approval is two buttons. Approve sends what choosing "Approve once" and then Continue sent; Disapprove sends what "Cancel action" sent.
const commandReview={id:'cmd',kind:'coding',status:'pending',tool:{name:'Run command outside the sandbox',service:'Buddy coding project',arguments:{command:'curl -sSfL "https://example.invalid/history?range=max&format=csv" -o data/SPX_History.csv',reason:'Download the history'}},questions:[{id:'command',question:'Allow this command to run outside the project sandbox, with network access?',options:[{label:'Accept'},{label:'Decline'}]}]};
const browserReview={id:'op',kind:'browser',status:'pending',tool:{name:'Create inbox',service:'AgentMail',arguments:{address:'chief@example.invalid'}},questions:[{id:'operation',question:'Allow this exact browser operation?',options:[{label:'Accept'},{label:'Decline'}]}]};
test('an approval review is answered with Approve or Disapprove, and each sends exactly what the old controls sent',()=>{
 assert.equal(worker.isApproval(commandReview),true);assert.equal(worker.isApproval(browserReview),true);
 assert.equal(worker.isApproval({id:'q',questions:[{id:'name',question:'Which name?'}]}),false,'a real question keeps its input');
 assert.equal(worker.isApproval({id:'q',questions:[{id:'size',question:'Which size?',options:[{label:'Small'},{label:'Large'}]}]}),false,'a real choice keeps its choices');
 assert.equal(worker.isApproval({id:'c',kind:'checkpoint',questions:[]}),false);assert.equal(worker.isApproval({id:'a',kind:'authentication',questions:[]}),false);
 // The old card: choose "Approve once" (the option labelled Accept), then Continue.
 assert.deepEqual(worker.reviewRequest('task',commandReview,{},'approve'),{operation:'review',taskId:'task',id:'cmd',answers:{command:['Accept']},cancel:false,accept:true});
 assert.deepEqual(worker.reviewRequest('task',browserReview,{},'approve'),{operation:'review',taskId:'task',id:'op',answers:{operation:['Accept']},cancel:false,accept:true});
 // The old card: Cancel action, with nothing chosen.
 assert.deepEqual(worker.reviewRequest('task',commandReview,{},'decline'),{operation:'review',taskId:'task',id:'cmd',answers:{},cancel:true,accept:false});
 assert.deepEqual(worker.reviewRequest('task',browserReview,{},'decline'),{operation:'review',taskId:'task',id:'op',answers:{},cancel:true,accept:false});
 const mixed={...browserReview,questions:[...browserReview.questions,{id:'note',question:'Anything to add?'}]};
 assert.deepEqual(worker.reviewRequest('task',mixed,{note:'Use the work address'},'approve'),{operation:'review',taskId:'task',id:'op',answers:{note:['Use the work address'],operation:['Accept']},cancel:false,accept:true},'typed answers go with the approval');
 assert.deepEqual(worker.reviewRequest('task',{id:'q',questions:[{id:'name',question:'Which name?'}]},{name:'Ada'},'approve'),{operation:'review',taskId:'task',id:'q',answers:{name:['Ada']},cancel:false,accept:false},'a plain question is answered as before');
});

test('what was asked is named in one short line',()=>{
 assert.equal(worker.requestTitle(commandReview),'Request to run `curl … data/SPX_History.csv`');
 assert.equal(worker.requestTitle(browserReview),'Request to create inbox');
 assert.equal(worker.requestTitle({tool:{name:'Run command with network access',arguments:{command:'npm test'}}}),'Request to run `npm test`');
 assert.equal(worker.requestTitle({tool:{name:'Write files outside the project',arguments:{paths:['/a','/b']}}}),'Request to write files outside the project');
 assert.equal(worker.requestTitle({tool:{arguments:{command:'echo `whoami`\n  && ls'}}}),"Request to run `echo 'whoami' && ls`",'never two lines, never a broken code span');
 assert.equal(worker.requestTitle({}),'Request to continue');
 for(const r of [commandReview,browserReview,{tool:{name:'A '.repeat(200)}},{tool:{arguments:{command:'x'.repeat(5000)}}}]){const line=worker.requestTitle(r);assert.equal(line.includes('\n'),false);assert.ok(line.length<=80,line);}
});

test('the approval message in the chat changes to what was decided, in place, and stays that way after a reload',()=>{
 const s={conversationWorkspace:'w',agents:[{id:'coder'}],messages:{}},t={id:'code',kind:'coding',workspace:'w',agentId:'coder',title:'Fetch the S&P history',status:'waiting_review',attempt:1,progress:'A coding command needs network access',attentionKey:'cmd',updatedAt:'2026-10-20T10:00:00Z',reviews:[commandReview]};
 assert.equal(worker.deliverResult(s,t),true);
 const m=s.messages.coder[0];assert.equal(worker.presentation(s,m).body,'I need your approval to continue.');assert.notEqual(worker.presentation(s,m).link,false,'the Review task link is there while it waits');
 assert.equal(worker.recordDecision(s,'code',{reviewId:'cmd',title:worker.requestTitle(commandReview),verdict:'approved',by:'user'}),true);
 assert.equal(s.messages.coder.length,1,'the same message, not a second one');
 assert.equal(worker.presentation(s,m).body,'Request to run `curl … data/SPX_History.csv` — approved');assert.equal(worker.presentation(s,m).link,false,'Review task goes away');
 assert.equal(m.body,'Request to run `curl … data/SPX_History.csv` — approved','the chat list preview reads it too');
 const reloaded=JSON.parse(JSON.stringify(s));assert.equal(worker.presentation(reloaded,reloaded.messages.coder[0]).body,'Request to run `curl … data/SPX_History.csv` — approved');
 assert.equal(worker.recordDecision(s,'code',{reviewId:'cmd',title:'x',verdict:'disapproved',by:'user'}),false,'answered once');
 // The next approval in the same run gets its own message; the decided one stays as the record.
 const next={...commandReview,id:'cmd2',tool:{...commandReview.tool,arguments:{command:'npm test'}}};
 assert.equal(worker.deliverResult(s,{...t,attentionKey:'cmd2',updatedAt:'2026-10-20T10:01:00Z',reviews:[{...commandReview,status:'answered'},next]}),true);
 assert.equal(s.messages.coder.length,2);assert.equal(worker.presentation(s,s.messages.coder[0]).body,'Request to run `curl … data/SPX_History.csv` — approved');
 assert.equal(worker.recordDecision(s,'code',{reviewId:'cmd2',title:worker.requestTitle(next),verdict:'disapproved',by:'user'}),true);
 assert.equal(worker.presentation(s,s.messages.coder[1]).body,'Request to run `npm test` — disapproved');
 assert.equal(worker.deliverResult(s,{...t,status:'completed',result:'Saved the history.',updatedAt:'2026-10-20T10:02:00Z'}),true);
 assert.deepEqual(s.messages.coder.map(m=>worker.presentation(s,m).hidden),[false,false,false],'decisions stay in the chat after the result arrives');
});

test('a message saved before review ids were kept still finds its review from its delivery id',()=>{
 const s={conversationWorkspace:'w',agents:[{id:'a'}],messages:{a:[{id:'worker-job-1-waiting_review-op',who:'a',body:'I need your approval to continue.',live:true,status:'completed',workerTaskID:'job',workerStatus:'waiting_review',workerAttempt:1}]}};
 assert.equal(worker.recordDecision(s,'job',{reviewId:'op',title:'Request to create inbox',verdict:'approved',by:'user'}),true);
 assert.equal(worker.presentation(s,s.messages.a[0]).body,'Request to create inbox — approved');
 assert.equal(worker.recordDecision(s,'other',{reviewId:'op',title:'x',verdict:'approved',by:'user'}),false,'another task’s answer changes nothing');
});

test('an answer the supervisor gave is read from the review record, with its reason',()=>{
 const s={conversationWorkspace:'w',agents:[{id:'coder'}],messages:{}},t={id:'code',kind:'coding',workspace:'w',agentId:'coder',status:'waiting_review',attempt:1,attentionKey:'cmd',updatedAt:'2026-10-20T10:00:00Z',reviews:[commandReview]};
 worker.deliverResult(s,t);
 assert.equal(worker.reconcile(s,{...t,status:'running',reviews:[{...commandReview,status:'answered'}]}),false,'an older record without who answered changes nothing');
 assert.equal(worker.presentation(s,s.messages.coder[0]).body,'I need your approval to continue.');
 assert.equal(worker.reconcile(s,{...t,status:'running',reviews:[{...commandReview,status:'answered',answeredBy:'supervisor',answeredByName:'Chief',answerReason:'A read-only download of public prices.',answeredAt:'2026-10-20T10:00:30Z'}]}),true);
 const p=worker.presentation(s,s.messages.coder[0]);
 assert.equal(p.body,'Request to run `curl … data/SPX_History.csv` — approved by Chief');assert.match(p.details,/A read-only download of public prices\./);assert.equal(p.link,false);
 assert.equal(worker.reconcile(s,{...t,status:'running',reviews:[{...commandReview,status:'answered',answeredBy:'supervisor',answeredByName:'Chief',answerReason:'A read-only download of public prices.'}]}),false,'nothing new, nothing changed');
 const s2={conversationWorkspace:'w',agents:[{id:'coder'}],messages:{}};worker.deliverResult(s2,t);
 assert.equal(worker.reconcile(s2,{...t,status:'running',reviews:[{...commandReview,status:'cancelled',answeredBy:'supervisor',answeredByName:'Chief',answerReason:'It writes outside the project.'}]}),true);
 assert.equal(worker.presentation(s2,s2.messages.coder[0]).body,'Request to run `curl … data/SPX_History.csv` — disapproved by Chief');
 const s3={conversationWorkspace:'w',agents:[{id:'coder'}],messages:{}};worker.deliverResult(s3,t);
 assert.equal(worker.reconcile(s3,{...t,status:'running',reviews:[{...commandReview,status:'declined',answeredBy:'user'}]}),true);
 assert.equal(worker.presentation(s3,s3.messages.coder[0]).body,'Request to run `curl … data/SPX_History.csv` — disapproved','the user’s own answer reads without a name');
 assert.equal(worker.reconcile(s3,{...t,id:'elsewhere',workspace:'other',reviews:[{...commandReview,status:'answered',answeredBy:'supervisor',answeredByName:'Chief'}]}),false,'another workspace changes nothing');
});

test('a check of the work reads approved or changes requested once it is answered',()=>{
 const cp={id:'cp1',kind:'checkpoint',status:'pending',tool:{name:'Check the work',arguments:{rule:'Send the CV before applying'}},questions:[]};
 const s={conversationWorkspace:'w',agents:[{id:'a'}],messages:{}},t={id:'apply',workspace:'w',agentId:'a',status:'waiting_review',attempt:1,attentionKey:'cp1',updatedAt:'2026-10-20T10:00:00Z',reviews:[cp]};
 worker.deliverResult(s,t);assert.equal(worker.requestTitle(cp),'Check the work');
 assert.equal(worker.recordDecision(s,'apply',{reviewId:'cp1',title:worker.requestTitle(cp),verdict:'changes',by:'user'}),true);
 assert.equal(worker.presentation(s,s.messages.a[0]).body,'Check the work — changes requested');
});

test('a supervisor’s answer is never pinned on a message that does not say which review it was for',()=>{
 const s={conversationWorkspace:'w',agents:[{id:'coder'}],messages:{}},t={id:'code',kind:'coding',workspace:'w',agentId:'coder',status:'waiting_review',attempt:1,attentionKey:'A coding command needs network access',updatedAt:'2026-10-20T10:00:00Z',reviews:[]};
 assert.equal(worker.deliverResult(s,t),true);assert.deepEqual(worker.reviewIds(s.messages.coder[0]),[]);
 assert.equal(worker.reconcile(s,{...t,status:'running',reviews:[{...commandReview,status:'answered',answeredBy:'supervisor',answeredByName:'Chief'}]}),false);
 assert.equal(worker.presentation(s,s.messages.coder[0]).body,'I need your approval to continue.');
 assert.equal(worker.recordDecision(s,'code',{reviewId:'cmd',title:'Request to run `x`',verdict:'approved',by:'user'}),true,'the person’s own click, on the one waiting message, may');
});

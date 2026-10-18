const test=require('node:test'),assert=require('node:assert/strict'),worker=require('./buddy-worker');
test('background task status distinguishes review, user handoff, errors and recovery',()=>{
  assert.equal(worker.labels.waiting_review,'Needs review');assert.equal(worker.labels.waiting_user,'Needs you');
  for(const status of ['paused','failed','interrupted','waiting_user'])assert.equal(worker.canResume(status),true);
  for(const status of ['completed','cancelled','running','waiting_review','queued'])assert.equal(worker.canResume(status),false);
  assert.deepEqual(worker.pending({reviews:[{id:'1',status:'pending'},{id:'2',status:'uncertain'},{id:'3',status:'completed'}]}).map(x=>x.id),['1']);
});

test('routine results arrive once in the correct DM, including after reopening',()=>{const s={conversationWorkspace:'w',agents:[{id:'a'},{id:'b'}],messages:{}},t={id:'task',routineID:'r',workspace:'w',agentId:'a',status:'completed',attempt:1,result:'Found Zopa and UBS in the checked searches.',coverage:[{partial:false,read:2}],updatedAt:'2026-10-17T16:01:00Z'};const UI=require('./buddy-worker');assert.equal(UI.deliverResult(s,t),true);assert.equal(UI.deliverResult(s,t),false);assert.equal(UI.deliverResult(JSON.parse(JSON.stringify(s)),t),false);assert.equal(s.messages.a.length,1);assert.equal(s.messages.b,undefined);assert.equal(s.messages.a[0].coverage[0].read,2);assert.equal(UI.deliverResult(s,{...t,id:'bad',workspace:'other'}),false);assert.equal(UI.deliverResult(s,{...t,id:'bad',agentId:'removed'}),false);assert.equal(UI.deliverResult(s,{...t,id:'bad',status:'running'}),false);assert.equal(UI.deliverResult(s,{...t,id:'failed',status:'failed',result:'',progress:'Gmail is disconnected.'}),true);assert.match(s.messages.a[1].body,/needs attention/);assert.match(s.messages.a[1].body,/Gmail is disconnected/);});

test('coding results return to the owning DM once per attempt and completed sessions support a follow-up',()=>{
 const s={conversationWorkspace:'w',agents:[{id:'a'}],messages:{}},t={id:'code',kind:'coding',workspace:'w',agentId:'a',status:'completed',attempt:1,result:'Built the tool. Command receipts: 1 finished, 1 exited successfully.',updatedAt:'2026-10-17T20:00:00Z'};
 assert.equal(worker.deliverResult(s,t),true);assert.equal(worker.deliverResult(s,t),false);assert.equal(worker.canResume('completed','coding'),true);assert.equal(worker.canResume('completed','research'),false);
 assert.equal(worker.deliverResult(s,{...t,attempt:2,result:'Added the requested feature.'}),true);assert.equal(s.messages.a.length,2);assert.equal(worker.deliverResult(s,{...t,id:'another',kind:'research'}),true);
});


test('ordinary browser work reports results and distinct blockers in its DM without background wording',()=>{
 const s={conversationWorkspace:'w',agents:[{id:'chief'}],messages:{}},t={id:'browser',kind:'general',workspace:'w',agentId:'chief',status:'waiting_review',attempt:1,title:'Create AgentMail inbox',progress:'Review the requested inbox creation',attentionKey:'review-one',updatedAt:'2026-10-18T04:40:00Z'};
 assert.equal(worker.deliverResult(s,t),true);assert.equal(worker.deliverResult(s,t),false);
 assert.match(s.messages.chief[0].body,/needs your review/);assert.equal(s.messages.chief[0].workerStatus,'waiting_review');
 assert.equal(worker.deliverResult(JSON.parse(JSON.stringify(s)),t),false);
 assert.equal(worker.deliverResult(s,{...t,attentionKey:'review-two'}),true);
 assert.equal(worker.deliverResult(s,{...t,status:'waiting_user',attentionKey:'signin',progress:'Sign in privately.'}),true);
 assert.match(s.messages.chief.at(-1).body,/needs your input/);
 assert.equal(worker.deliverResult(s,{...t,status:'completed',result:'Created the requested inbox; verified on the website.'}),true);
 assert.equal(s.messages.chief.at(-1).workerTaskID,'browser');
 assert.equal(worker.deliverResult(s,{...t,status:'completed',result:'Duplicate'}),false);
 assert.equal(worker.deliverResult(s,{...t,status:'running'}),false);
 assert.equal(worker.deliverResult(s,{...t,status:'failed',progress:'The website rejected the requested address.'}),true);
 assert.match(s.messages.chief.at(-1).body,/website rejected/);
 assert.equal(worker.deliverResult(s,{...t,id:'other',agentId:'missing'}),false);
 assert.equal(worker.deliverResult(s,{...t,id:'other',workspace:'elsewhere'}),false);
});

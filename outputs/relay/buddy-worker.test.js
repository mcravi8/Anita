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
test('a sign-in the person answers in the chat has its own request message there, so the task adds none; an older record still says to press Done; the result still arrives',()=>{
 const s={conversationWorkspace:'w',agents:[{id:'a'}],messages:{}},t={id:'job',workspace:'w',agentId:'a',title:'Create inbox',attempt:1,status:'waiting_review',attentionKey:'auth',updatedAt:'2026-10-18T05:44:00Z',reviews:[{status:'pending',kind:'authentication',mode:'signin'}]};
 assert.equal(worker.deliverResult(s,t),false);assert.equal((s.messages.a||[]).length,0,'the chat’s sign-in request is the message');
 for(const need of ['signin','captcha','verification','credential'])assert.equal(worker.deliverResult(s,{...t,status:'waiting_user',attentionKey:need,checkpoint:{id:'c-'+need,need},updatedAt:'2026-10-18T05:44:30Z',progress:'Waiting for you'}),false,need);
 assert.equal(worker.deliverResult(s,{...t,status:'waiting_user',stopCause:'review.parked',checkpoint:{id:'p',need:'signin'},attentionKey:'parked',progress:'Set aside so other work could run.'}),true,'a review set aside is still told');
 delete s.messages.a;
 worker.deliverResult(s,{...t,status:'waiting_user',attentionKey:'private',updatedAt:'2026-10-18T05:45:00Z',progress:'Private Chrome is open. Finish sign-in in Buddy when ready.'});assert.equal(s.messages.a.length,1);assert.match(s.messages.a[0].body,/press Done/);
 worker.deliverResult(s,{...t,status:'completed',result:'Created chief@example.test.',updatedAt:'2026-10-18T05:46:00Z'});assert.equal(worker.presentation(s,s.messages.a[0]).hidden,true);assert.equal(worker.presentation(s,s.messages.a[1]).body,'Created chief@example.test.');
});
test('Browser sign-in is one “Set up once” section: one Open Chrome button, every agent with internet access listed as using it, and an older window named but never closed',()=>{
 const button=(op,label)=>`<button data-worker-op="${op}">${label}</button>`;
 const agents=[{id:'a',name:'Ada'},{id:'b',name:'Bo<b>'},{id:'c',name:'Cy'}];
 const html=worker.setupOnce({agents,using:['a','b'],legacy:[],button});
 assert.equal((html.match(/data-worker-op="open-google"/g)||[]).length,1,'one Open Chrome button for everyone');
 assert.match(html,/Set up once/);assert.match(html,/Every agent with internet access will use the accounts you sign in to here/);assert.match(html,/as many websites and accounts as you like, including more than one Google account/);
 assert.match(html,/Used by Ada, Bo&lt;b&gt;\./);assert.match(html,/No browser for Cy \(internet access is off\)/);assert.doesNotMatch(html,/<b>/);
 const open=worker.setupOnce({agents,using:['a'],open:{shared:true,taskId:null},legacy:['c'],button});
 assert.match(open,/data-worker-op="finish-signin">Done</);assert.doesNotMatch(open,/open-google/);assert.match(open,/Chrome is open\./);
 assert.match(open,/older private Chrome window \(Cy’s/);assert.match(open,/Buddy won’t close it/);
});
test('the Set up once card says which Google accounts the shared Chrome is signed in to, escaped, and nothing when the app did not say',()=>{
 const button=(op,label)=>`<button data-worker-op="${op}">${label}</button>`,agents=[{id:'a',name:'Ada'}];
 const both=worker.setupOnce({agents,using:['a'],legacy:[],button,accounts:{chrome:'me@gmail.com',accounts:['me@gmail.com','Me@usc.edu','x<b>@usc.edu']}});
 assert.match(both,/Chrome is signed in as <strong>me@gmail\.com<\/strong>\. Also signed in to Google: Me@usc\.edu, x&lt;b&gt;@usc\.edu\./);assert.doesNotMatch(both,/<b>/);
 assert.match(worker.setupOnce({agents,using:['a'],legacy:[],button,accounts:{chrome:null,accounts:['me@usc.edu']}}),/Signed in to Google as me@usc\.edu\. Chrome itself isn’t signed in, so Google Password Manager is off\./);
 assert.match(worker.setupOnce({agents,using:['a'],legacy:[],button,accounts:{chrome:null,accounts:[]}}),/Chrome isn’t signed in to a Google account yet\./);
 assert.doesNotMatch(worker.setupOnce({agents,using:['a'],legacy:[],button}),/worker-setup-account/,'an older app that sends no accounts shows no line');
});

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

test('a task waiting only on the supervisor\u2019s review posts nothing in the chat; anything waiting on the person still does',()=>{
 const base={id:'t',agentId:'chief',status:'waiting_review',attempt:1,progress:'A coding command waits for Chief\u2019s review',updatedAt:'2026-10-21T06:00:00Z'};
 const chief={...base,reviews:[{id:'r1',kind:'coding',status:'pending',route:'supervisor'}]};
 assert.equal(worker.supervisorWait(chief),true);assert.equal(worker.deliverable(chief),false,'no \u201cI need your approval\u201d for Chief\u2019s review');
 const mixed={...base,reviews:[{id:'r1',kind:'coding',status:'pending',route:'supervisor'},{id:'r2',kind:'coding',status:'pending',route:'user'}]};
 assert.equal(worker.deliverable(mixed),true,'one review that is the person\u2019s still shows');
 assert.equal(worker.deliverable({...base,reviews:[{id:'r2',kind:'coding',status:'pending',route:'user'}]}),true);
 assert.equal(worker.deliverable({...base,reviews:[{id:'r3',kind:'coding',status:'answered',route:'auto'}],status:'running'}),false,'Buddy\u2019s own approval never waits');
});

test('a coding command Buddy assessed reads as what it does and why, in everyday words (Chief’s real S01 requests)',()=>{
 const s01=(command,reason,assessment)=>({id:'r',kind:'coding',status:'pending',assessment,tool:{name:'Run command outside the sandbox',service:'Buddy coding project',arguments:{command,reason,project:'/x/Files',access:'Runs outside the project sandbox.'}},questions:[{id:'command',question:'Allow this command to run outside the project sandbox, with network access?',options:[{label:'Accept'},{label:'Decline'}]}]});
 const two=s01("/bin/zsh -lc 'curl -fL --max-time 90 https://download.documentfoundation.org/libreoffice/stable/26.8.1/mac/aarch64/ -o a.html\ncurl -fL --max-time 90 https://arxiv.org/html/2106.07040 -o b.html'",'Allow checking the LibreOffice package URL and an alternate full-text record for the paper?',{routine:true,reason:'2 downloads from download.documentfoundation.org and arxiv.org into the project.',hosts:['download.documentfoundation.org','arxiv.org'],writes:['a.html','b.html']});
 assert.deepEqual(worker.plainRequest(two),{what:'download 2 files from download.documentfoundation.org and arxiv.org',why:'Checking the LibreOffice package URL and an alternate full-text record for the paper',caution:''});
 assert.equal(worker.requestTitle(two),'Download 2 files from download.documentfoundation.org and arxiv.org');
 const one=s01("/bin/zsh -lc 'curl -fL https://arxiv.org/pdf/2106.07040 -o m.pdf'",'Allow downloading the second public full paper required for S01 verification?',{routine:true,reason:'A download from arxiv.org into the project.',hosts:['arxiv.org'],writes:['m.pdf']});
 assert.equal(worker.plainRequest(one).what,'download a file from arxiv.org');assert.equal(worker.plainRequest(one).why,'Downloading the second public full paper required for S01 verification');
 const unclear=s01('python3 fetch.py','Fetch the data',{routine:false,reason:'Buddy cannot tell exactly what this command does, so you decide.',hosts:[],writes:[]});
 assert.deepEqual(worker.plainRequest(unclear),{what:'run a command that uses the internet',why:'Fetch the data',caution:'Buddy cannot tell exactly what this command does, so you decide.'});
 assert.equal(worker.requestTitle({...one,assessment:{routine:true,reason:'A clone of a public repository from github.com into the project.'}}),'Copy a public code repository from github.com');
 assert.equal(worker.requestTitle({...one,assessment:{routine:true,reason:'A package install into the project.'}}),'Install packages into the project');
 assert.equal(worker.plainRequest(commandReview),null,'an older review without an assessment keeps its old wording');
 for(const r of [two,one,unclear]){const line=worker.requestTitle(r);assert.equal(line.includes('\n'),false);assert.doesNotMatch(line,/curl|zsh/,'no command text in the one line');}
});

test('a command that runs project scripts reads as which scripts it runs, and the chat line says what was decided (Chief’s real S01 render, 21 Oct 2026)',()=>{
 const command="/bin/zsh -lc 'python3 stages/S01_protocol/attempt_02/run_guard.py 200 python3 stages/S01_protocol/attempt_02/render_probe.py'";
 const scripts=[{path:'stages/S01_protocol/attempt_02/run_guard.py',sha256:'a'.repeat(64),bytes:746},{path:'stages/S01_protocol/attempt_02/render_probe.py',sha256:'b'.repeat(64),bytes:779}];
 const script={id:'s1',kind:'coding',status:'pending',route:'user',assessment:{routine:false,kind:'script',reason:'Runs the project scripts run_guard.py and render_probe.py.',runs:'Runs the project scripts run_guard.py and render_probe.py.',hosts:[],writes:[],scripts},
  tool:{name:'Run command outside the sandbox',service:'Buddy coding project',arguments:{command,reason:'Render the probe document with the project-local LibreOffice to check the template.',project:'/x/Files'}},questions:[{id:'command',question:'Allow this command to run outside the project sandbox, with network access?',options:[{label:'Accept'},{label:'Decline'}]}]};
 assert.deepEqual(worker.plainRequest(script),{what:'run the project scripts run_guard.py and render_probe.py',why:'Render the probe document with the project-local LibreOffice to check the template',caution:''});
 assert.equal(worker.requestTitle(script),'Run the project scripts run_guard.py and render_probe.py');
 const one={...script,assessment:{...script.assessment,reason:'Runs the project script render_probe.py.',runs:'Runs the project script render_probe.py.',scripts:scripts.slice(1)}};
 assert.equal(worker.plainRequest(one).what,'run the project script render_probe.py');
 // A script Buddy's own reading sent to the person still says which script it is, with what Buddy saw as the caution.
 const flagged={...script,assessment:{routine:false,kind:'sensitive',reason:'The script share.py can send data out of this Mac (requests.post).',runs:'Runs the project script share.py.',hosts:[],writes:[],scripts:[{path:'tools/share.py',sha256:'c'.repeat(64),bytes:90}]}};
 assert.deepEqual(worker.plainRequest(flagged),{what:'run the project script share.py',why:'Render the probe document with the project-local LibreOffice to check the template',caution:'The script share.py can send data out of this Mac (requests.post).'});
 assert.equal(worker.requestTitle({...script,assessment:{routine:true,kind:'routine',reason:'A look at running processes.',hosts:[],writes:[]}}),'Look at the running processes');
 // The person's answer turns the approval message into one line: what it was and what they decided.
 const s={conversationWorkspace:'w',messages:{chief:[{id:'worker-code-1-waiting_review-s1',workerTaskID:'code',workerAttempt:1,workerStatus:'waiting_review',workerReviewIds:['s1'],body:'I need your approval.'}]}};
 assert.equal(worker.recordDecision(s,'code',{reviewId:'s1',title:worker.requestTitle(script),verdict:'approved',by:'user'}),true);
 assert.equal(s.messages.chief[0].body,'Run the project scripts run_guard.py and render_probe.py — approved');
 assert.doesNotMatch(worker.requestTitle(script),/zsh|python3|stages\//,'no command text in the one line');
 // One the supervisor reads posts nothing in the chat.
 assert.equal(worker.deliverable({id:'code',agentId:'chief',status:'waiting_review',attempt:1,reviews:[{...script,route:'supervisor'}]}),false);
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
test('a task pinned to an account says “Uses …” on the task and on the reply that started it, escaped, and nothing when unpinned',()=>{
 assert.equal(worker.accountLine({account:'craviott@usc.edu'}),'Uses craviott@usc.edu');assert.equal(worker.accountLine({}),'');
 const html=worker.taskReceipts([{id:'t1',title:'Check <my> calendar',account:'craviott@usc.edu'}]);
 assert.match(html,/Uses craviott@usc\.edu/);assert.match(html,/data-worker-task="t1"/);assert.match(html,/Check &lt;my&gt; calendar/);assert.doesNotMatch(html,/<my>/);
 assert.equal(worker.taskReceipts([]),'');assert.equal(worker.taskReceipts(),'');
});

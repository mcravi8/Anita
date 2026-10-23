const {test}=require('node:test'),assert=require('node:assert/strict'),P=require('./buddy-plan');
// Fixtures follow the plan summary the worker puts in its status reply (C-7) and the pulse beside it (C-8).
const NOW=Date.parse('2026-10-19T10:30:00Z'),names={chief:'Chief',lyra:'Lyra',forge:'Forge'};
const task=(id,status,extra={})=>({id,title:'Task '+id,assignee:'lyra',kind:'research',status,workerTaskId:'',workerStatus:'',blockedOn:'none',resultSummary:'',updatedAt:'2026-10-19T10:00:00Z',...extra});
const stage=(n,status,tasks=[])=>({id:'s'+n,n,title:['Research','Build','Launch'][n-1],goal:'Goal of stage '+n,acceptance:['Criterion '+n+'a','Criterion '+n+'b'],status,tasks});
const plan=(status,run,extra={})=>({id:'p1',groupId:'team',objective:'Ship the portfolio',supervisorId:'chief',status,revision:1,scope:null,notices:[],
 stages:[stage(1,'proposed',[task('t1','pending'),task('t2','pending',{assignee:'forge'}),task('t3','pending')]),stage(2,'proposed'),stage(3,'proposed')],run:{working:[],needsYou:0,idleSince:null,...run},...extra});
const scope={through:1,quote:'get stage 1 done',at:'2026-10-19T09:00:00Z',status:'active'};
const active=(stage1,run,extra={})=>plan('active',run,{scope,stages:[stage(1,'working',stage1),stage(2,'proposed'),stage(3,'proposed')],...extra});
const pulse=agents=>({agents,queuePaused:false,privateSignIn:null,idleSince:null});

test('the banner says in plain words what is happening for every state of a plan',()=>{
 assert.equal(P.banner(plan('draft',{state:'draft'}),pulse({}),names,NOW),'Plan ready — which stage should the team get done?');
 const working=active([task('t1','done'),task('t2','dispatched',{assignee:'forge',workerTaskId:'w2',workerStatus:'running',updatedAt:'2026-10-19T10:18:00Z'}),task('t3','pending')],{state:'working',working:[{agentId:'forge',title:'Task t2',since:'2026-10-19T10:18:00Z'}]});
 assert.equal(P.banner(working,pulse({forge:{state:'working',taskId:'w2',title:'Task t2',since:'2026-10-19T10:18:00Z'}}),names,NOW),'Working on Stage 1 of 3 — 1 of 3 tasks done — Forge is working on “Task t2” (12 min)');
 assert.equal(P.banner(working,pulse({}),names,Date.parse('2026-10-19T11:23:00Z')),'Working on Stage 1 of 3 — 1 of 3 tasks done — Forge is working on “Task t2” (1 h 5 min)','longer work reads in hours');
 const two=active([task('t1','dispatched',{workerTaskId:'w1'}),task('t2','dispatched',{assignee:'forge',workerTaskId:'w2'}),task('t3','pending')],{state:'working'});
 assert.match(P.banner(two,pulse({}),names,NOW),/Lyra is working on “Task t1” \(30 min\), plus 1 more$/);
 const review=active([task('t1','review',{resultSummary:'Found five sources.'}),task('t2','pending'),task('t3','pending')],{state:'waiting_on_supervisor'});
 assert.equal(P.banner(review,pulse({}),names,NOW),'Chief is reviewing “Task t1”');
 assert.equal(P.banner(review,pulse({}),{},NOW),'Chief is reviewing “Task t1”','the supervisor is called Chief when the name is unknown');
 const checking=plan('active',{state:'waiting_on_supervisor'},{scope,stages:[stage(1,'review',[task('t1','done')]),stage(2,'proposed')]});
 assert.equal(P.banner(checking,pulse({}),names,NOW),'Chief is checking that Stage 1 is done');
 const needs=active([task('t1','blocked',{blockedOn:'user',title:'Sign in to the portal'}),task('t2','pending'),task('t3','pending')],{state:'needs_you',needsYou:1});
 assert.equal(P.banner(needs,pulse({}),names,NOW),'Needs you (1): “Sign in to the portal” (Lyra)');
 const escalated=active([task('t1','dispatched'),task('t2','pending'),task('t3','pending')],{state:'needs_you',needsYou:2},{notices:[{id:'e1',kind:'escalation',text:'Should I spend $40 on the domain? I recommend yes.',chat:true,status:'open',at:'2026-10-19T10:00:00Z'}]});
 assert.equal(P.banner(escalated,pulse({}),names,NOW),'Needs you (2): Should I spend $40 on the domain? I recommend yes.');
 const retry=active([task('t1','dispatched',{workerTaskId:'w1',blockedOn:'retry'}),task('t2','pending'),task('t3','pending')],{state:'working',working:[{agentId:'lyra',title:'Task t1',since:'2026-10-19T10:00:00Z'}]});
 assert.equal(P.banner(retry,pulse({lyra:{state:'retrying',taskId:'w1'}}),names,NOW),'Retrying “Task t1”');
 const holding=plan('holding',{state:'stage_done'},{scope:{...scope,status:'achieved'},stages:[stage(1,'done',[task('t1','done')]),stage(2,'proposed'),stage(3,'proposed')]});
 assert.equal(P.banner(holding,pulse({}),names,NOW),'Stage 1 is done — what next?');
 const idle=active([task('t1','done'),task('t2','pending'),task('t3','pending')],{state:'idle',idleSince:'2026-10-19T10:05:00Z'});
 assert.match(P.banner(idle,pulse({}),names,NOW),/^Idle since \S.* — nothing queued$/);
 const stopped=plan('holding',{state:'stopped'},{stages:[stage(1,'working',[task('t1','done')]),stage(2,'proposed')]});
 assert.match(P.banner(stopped,pulse({}),names,NOW),/^Stopped — nothing new will start/);
 const finished=plan('achieved',{state:'stage_done'},{stages:[stage(1,'done'),stage(2,'done'),stage(3,'done')]});
 assert.equal(P.banner(finished,pulse({}),names,NOW),'All 3 stages are done');
 assert.equal(P.banner(null),'');
});

test('an authorized stage with no tasks yet reads as the supervisor planning it, never as being checked',()=>{
 const through2={through:2,quote:'get stage 2 done',at:'2026-10-20T16:43:00Z',status:'active'},one=stage(1,'done',[task('t1','done')]);
 // Whatever the worker reports: a current Buddy says the plan waits on Chief; an older one said idle, or had sent the empty stage to its check.
 for(const [status,state] of [['working','waiting_on_supervisor'],['approved','waiting_on_supervisor'],['working','idle'],['review','waiting_on_supervisor']]){
  const p=plan('active',{state},{scope:through2,stages:[one,stage(2,status),stage(3,'proposed')]});
  assert.equal(P.banner(p,pulse({}),names,NOW),'Chief is planning Stage 2',`${status} / ${state}`);
  const html=P.stripHTML(p,pulse({}),names,{open:true,now:NOW});
  assert.match(html,/Chief is planning Stage 2/);assert.doesNotMatch(html,/is checking that|Being checked/,`${status} / ${state}`);
 }
 assert.equal(P.banner(plan('active',{state:'waiting_on_supervisor'},{scope:through2,stages:[one,stage(2,'working'),stage(3,'proposed')]}),pulse({}),{chief:'Ada'},NOW),'Ada is planning Stage 2','in the supervisor’s own name');
 assert.equal(P.stageChip(stage(2,'working')).label,'Planning');assert.equal(P.stageChip(stage(2,'review')).label,'Planning','a stage with no tasks is never shown as being checked');
 assert.equal(P.stageChip(stage(2,'review',[task('t9','done')])).label,'Being checked','a stage whose tasks are all done is');
 assert.equal(P.stageChip(stage(2,'proposed')).label,'Not started');assert.equal(P.stageChip(stage(2,'done')).label,'Done');
 const later=plan('active',{state:'working'},{scope:{...through2,through:1},stages:[stage(1,'working',[task('t1','dispatched',{workerTaskId:'w1'})]),stage(2,'proposed'),stage(3,'proposed')]});
 assert.doesNotMatch(P.banner(later,pulse({}),names,NOW),/planning/,'a stage outside the authorization is not being planned');
});

test('a task the person paused reads as paused by them, waiting for them to resume it, never as with the supervisor or as needing them',()=>{
 const one=active([task('t1','done'),task('t2','blocked',{assignee:'forge',blockedOn:'paused',workerTaskId:'w2',workerStatus:'paused'}),task('t3','pending')],{state:'paused'});
 assert.equal(P.banner(one,pulse({}),names,NOW),'You paused “Task t2” (Forge) — resume it to finish Stage 1');
 const two=active([task('t1','blocked',{blockedOn:'paused'}),task('t2','blocked',{assignee:'forge',blockedOn:'paused'}),task('t3','pending')],{state:'paused'});
 assert.equal(P.banner(two,pulse({}),names,NOW),'You paused 2 tasks — resume them to finish Stage 1');
 const html=P.stripHTML(one,pulse({}),names,{open:true,now:NOW});
 assert.match(html,/class="plan-strip tone-idle open"/);assert.match(html,/data-plan-state="paused"/);assert.match(html,/Paused by you/);
 assert.doesNotMatch(html,/With Chief|Needs you|See what needs you/);
 // Beside other work the paused task keeps its own chip, and the strip says what is going on.
 const beside=active([task('t1','dispatched',{workerTaskId:'w1'}),task('t2','blocked',{assignee:'forge',blockedOn:'paused'}),task('t3','pending')],{state:'working'});
 assert.match(P.banner(beside,pulse({}),names,NOW),/^Working on Stage 1 of 3 — 0 of 3 tasks done — Lyra is working on “Task t1”/);
 assert.equal(P.taskChip(task('t2','blocked',{blockedOn:'paused'}),pulse({}),'Chief').label,'Paused by you');
});

test('stage and task chips say where each piece of work stands',()=>{
 assert.deepEqual(['proposed','approved','working','review','done'].map(s=>P.stageChip({status:s}).label),['Not started','Up next','Working','Being checked','Done']);
 const chip=(t,p)=>P.taskChip(t,pulse(p||{}),'Chief').label;
 assert.equal(chip(task('a','pending')),'Waiting');assert.equal(chip(task('a','done')),'Done');assert.equal(chip(task('a','waived')),'Skipped');assert.equal(chip(task('a','review')),'Being reviewed');
 assert.equal(chip(task('a','dispatched',{workerTaskId:'w'})),'Working');
 assert.equal(chip(task('a','dispatched',{workerTaskId:'w'}),{lyra:{state:'retrying',taskId:'w'}}),'Retrying');
 assert.equal(chip(task('a','dispatched',{workerTaskId:'w'}),{lyra:{state:'with_supervisor',taskId:'w'}}),'Asking Chief');
 assert.equal(chip(task('a','dispatched',{workerTaskId:'w'}),{lyra:{state:'working',taskId:'other'}}),'Queued','the agent is busy with another task');
 assert.equal(chip(task('a','blocked',{blockedOn:'user'})),'Needs you');assert.equal(chip(task('a','blocked',{blockedOn:'supervisor'})),'With Chief');
});

test('the group chat shows the group’s plan, and a direct chat shows the plan that agent supervises',()=>{
 const state={agents:[{id:'chief',name:'Chief'},{id:'lyra',name:'Lyra'}],groups:[{id:'team',members:['chief','lyra']},{id:'other',members:['lyra']}]};
 const old={...plan('achieved',{state:'stage_done'}),id:'old',updatedAt:'2026-10-18T00:00:00Z'},live={...plan('active',{state:'working'}),id:'live',updatedAt:'2026-10-17T00:00:00Z'},elsewhere={...plan('draft',{state:'draft'}),id:'elsewhere',groupId:'other',supervisorId:'lyra'};
 const plans=[old,live,elsewhere];
 assert.equal(P.planFor(state,{kind:'chat',target:'team'},plans).id,'live','a live plan wins over one achieved earlier');
 assert.equal(P.planFor(state,{kind:'chat',target:'other'},plans).id,'elsewhere');
 assert.equal(P.planFor(state,{kind:'chat',target:'chief'},plans).id,'live','the supervisor’s own chat shows the plan they run');
 assert.equal(P.planFor(state,{kind:'chat',target:'lyra'},[old,live]),null,'an agent who supervises nothing has no strip');
 assert.equal(P.planFor(state,{kind:'tasks'},plans),null);assert.equal(P.planFor(state,{kind:'chat',target:'gone'},plans),null);assert.equal(P.planFor(state,{kind:'chat',target:'team'},undefined),null);
});

test('“Get stage N done” is offered only while no stage is authorized: in a draft, or once a stage is done',()=>{
 const draft=P.stripHTML(plan('draft',{state:'draft'}),pulse({}),names,{open:true,now:NOW});
 assert.match(draft,/>Get stage 1 done</);assert.match(draft,/>Get stages 1–2 done</);assert.match(draft,/>Get stages 1–3 done</);
 assert.match(draft,/data-plan-authorize="1"/);assert.match(draft,/Done when/);assert.match(draft,/Criterion 1a/);assert.match(draft,/Ship the portfolio/);
 const holding=P.stripHTML(plan('holding',{state:'stage_done'},{stages:[stage(1,'done',[task('t1','done')]),stage(2,'proposed'),stage(3,'proposed')]}),pulse({}),names,{open:true,now:NOW});
 assert.doesNotMatch(holding,/Get stage 1 done/);assert.match(holding,/>Get stage 2 done</);assert.match(holding,/>Get stages 2–3 done</);
 const working=P.stripHTML(active([task('t1','dispatched')]),pulse({}),names,{open:true,now:NOW});
 assert.doesNotMatch(working,/Get stage/);assert.match(working,/data-plan-stop/,'an active plan can be stopped');
 assert.doesNotMatch(draft,/data-plan-stop/,'a draft has nothing to stop');
 const closed=P.stripHTML(plan('draft',{state:'draft'}),pulse({}),names,{open:false,now:NOW});
 assert.match(closed,/aria-expanded="false"/);assert.match(closed,/plan-strip-body[^>]*hidden/);assert.match(closed,/Plan ready/);
 assert.match(P.stripHTML({...plan('draft',{state:'draft'}),objective:'<img src=x onerror=alert(1)>'},pulse({}),names,{open:true}),/&lt;img/,'plan text is escaped');
});

test('a stage counts as started only when the worker’s reply confirms it; an error reply is shown as it is',()=>{
 const ask={action:'authorize',planId:'p1',through:2,quote:'Get stages 1–2 done'},reply=s=>({plan:{id:'p1',status:'active',scope:s}});
 assert.equal(P.replyOutcome(reply({through:2,status:'active'}),ask).ok,true);
 assert.equal(P.replyOutcome(reply({through:2,status:'active'}),ask).plan.id,'p1');
 assert.equal(P.replyOutcome(reply({through:3,status:'active'}),ask).ok,true,'a wider scope covers it');
 for(const r of [reply({through:1,status:'active'}),reply({through:2,status:'withdrawn'}),reply(null),{},null,undefined,'ok']){const o=P.replyOutcome(r,ask);assert.equal(o.ok,false,JSON.stringify(r));assert.match(o.message,/hasn’t started/);assert.equal(o.plan,undefined,'nothing is shown as started');}
 const refused=P.replyOutcome({error:'Stage 1 is already done. Say “get stage 2 done” to continue.'},ask);
 assert.deepEqual(refused,{ok:false,message:'Stage 1 is already done. Say “get stage 2 done” to continue.'},'the worker’s own words, plainly');
 assert.equal(P.replyOutcome({error:'This plan is closed.'},{action:'stop',planId:'p1'}).ok,false);
 assert.equal(P.replyOutcome({plan:{id:'p1',status:'holding',scope:null}},{action:'stop',planId:'p1'}).ok,true);
 const html=P.stripHTML(plan('draft',{state:'draft'}),pulse({}),names,{open:false,error:'Stage 1 is <already> done.'});
 assert.match(html,/<p class="plan-error" role="alert">Stage 1 is &lt;already&gt; done\.<\/p>/,'and stays on the strip until the next try, even folded');
 assert.doesNotMatch(P.stripHTML(plan('draft',{state:'draft'}),pulse({}),names,{open:false}),/plan-error/);
});
test('chat notices arrive once, in the group or the supervisor’s chat, and never twice',()=>{
 const state={agents:[{id:'chief',name:'Chief'},{id:'lyra',name:'Lyra'}],groups:[{id:'team',members:['chief','lyra']}],messages:{team:[{id:'hello',who:'you',body:'hi'}]}};
 const notices=[{id:'n1',kind:'authorized',text:'Stage 1 authorized. The team is working on Stage 1 — Research.',chat:true,status:'open',at:'2026-10-19T10:00:00Z'},{id:'n2',kind:'stage_report',text:'Shown only on the strip.',chat:false,status:'open',at:'2026-10-19T10:01:00Z'}];
 const plans=[plan('active',{state:'working'},{notices}),{...plan('draft',{state:'draft'}),id:'dm',groupId:'',notices:[{id:'n3',kind:'proposal',text:'Here is the plan.',chat:true,at:'2026-10-19T10:02:00Z'}]},{...plan('draft',{state:'draft'}),id:'lost',groupId:'deleted',supervisorId:'gone',notices:[{id:'n4',kind:'proposal',text:'Nobody to tell.',chat:true}]}];
 const first=P.noticesToDeliver(state,plans);
 assert.deepEqual(first.map(i=>[i.target,i.message.id]),[['team','plan-notice-n1'],['chief','plan-notice-n3']]);
 const m=first[0].message;assert.equal(m.who,'chief');assert.equal(m.body,notices[0].text);assert.equal(m.live,true);assert.equal(m.status,'completed');assert.equal(m.planNotice,true);assert.equal(m.createdAt,'2026-10-19T10:00:00Z');
 assert.equal(state.messages.team.length,1,'finding them changes nothing');
 assert.deepEqual(P.deliverNotices(state,plans),['team','chief']);
 assert.equal(state.messages.team.length,2);assert.equal(state.messages.chief.length,1);
 assert.deepEqual(P.noticesToDeliver(state,plans),[],'a second look finds nothing new');
 assert.deepEqual(P.deliverNotices(state,plans),[]);
 assert.deepEqual(P.noticesToDeliver(JSON.parse(JSON.stringify(state)),plans),[],'including after the workspace is saved and reopened');
 assert.equal(P.noticesToDeliver({...state,messages:{}},[{...plans[0],supervisorId:'gone'}])[0].message.who,'team','with no supervisor left, the group itself speaks');
});

// A stage's deliverables: the files its tasks' background work saved, as the worker's result messages in each agent's chat carry them.
const receipt=(path,date,extra={})=>({id:'r-'+path+date,folderId:'research',path,revision:'v-'+date,kind:'created',actor:'lyra',actorName:'Lyra',date,...extra});
const result=(agent,workerTaskID,files,extra={})=>({id:`worker-${workerTaskID}-1-completed`,who:agent,body:'Done.',live:true,status:'completed',workerTaskID,workerStatus:'completed',files,...extra});
function finishedPlan(){
 return plan('holding',{state:'stage_done'},{scope:{...scope,status:'achieved'},stages:[
  stage(1,'done',[task('t1','done',{workerTaskId:'w1'}),task('t2','done',{assignee:'forge',workerTaskId:'w2'}),task('t3','waived')]),
  stage(2,'proposed',[task('t4','pending',{workerTaskId:'w4'})]),stage(3,'proposed')]});
}
const workState=()=>({agents:[{id:'chief',name:'Chief'},{id:'lyra',name:'Lyra'},{id:'forge',name:'Forge'}],groups:[{id:'team',members:['chief','lyra','forge']}],messages:{
 team:[{id:'hello',who:'you',body:'hi'}],
 lyra:[result('lyra','w1',[receipt('paper_draft.md','2026-10-20T10:00:00Z'),receipt('notes/sources.md','2026-10-20T10:01:00Z')])],
 forge:[result('forge','w2',[receipt('paper_draft.md','2026-10-20T11:00:00Z',{kind:'edited',actor:'forge',actorName:'Forge'}),receipt('figures/fig1.png','2026-10-20T11:02:00Z',{actor:'forge',actorName:'Forge'})]),
  result('forge','w4',[receipt('stage2.md','2026-10-20T12:00:00Z')],{id:'worker-w4-1-completed'}),result('forge','other',[receipt('unrelated.md','2026-10-20T12:00:00Z')],{id:'worker-other-1-completed'}),
  {id:'chat',who:'forge',body:'Saved it.',live:true,status:'completed',files:[receipt('chat-only.md','2026-10-20T12:00:00Z')]}]}});

test('a finished stage’s deliverables are the files its tasks saved: one per file, the latest save of each, newest first',()=>{
 const state=workState(),p=finishedPlan();
 const files=P.stageDeliverables(state,p,'s1');
 assert.deepEqual(files.map(f=>f.path),['figures/fig1.png','paper_draft.md','notes/sources.md']);
 assert.equal(files.find(f=>f.path==='paper_draft.md').kind,'edited','the newest save of a file wins');assert.equal(files.find(f=>f.path==='paper_draft.md').actorName,'Forge');
 assert.deepEqual(P.stageDeliverables(state,p,2).map(f=>f.path),['stage2.md'],'by stage number too, and only that stage’s tasks');
 assert.deepEqual(P.stageDeliverables(state,p,'s3'),[],'a stage with no tasks saved nothing');
 assert.deepEqual(P.stageDeliverables(state,p,'missing'),[]);
 const bad=workState();bad.messages.lyra[0].files.push({path:'no-folder.md',revision:'r'},null,{folderId:'research',path:'no-revision.md'});
 assert.equal(P.stageDeliverables(bad,p,'s1').length,3,'a receipt without its folder or revision is not a file to open');
});

test('a stage report goes to the group chat with that stage’s files attached; other notices carry text only',()=>{
 const state=workState(),p={...finishedPlan(),notices:[
  {id:'a1',kind:'authorized',text:'Stage 1 authorized.',chat:true,status:'open',at:'2026-10-20T09:00:00Z'},
  {id:'r1',kind:'stage_report',text:'Stage 1 — Research is done.\n\nNext is Stage 2 — Build.',chat:true,status:'open',at:'2026-10-20T12:30:00Z',refs:{stageId:'s1'}},
  {id:'r2',kind:'stage_report',text:'Stage 2 — Build is done.',chat:true,status:'open',at:'2026-10-20T13:30:00Z'}]};
 const out=P.noticesToDeliver(state,[p]);
 assert.deepEqual(out.map(i=>i.message.id),['plan-notice-a1','plan-notice-r1','plan-notice-r2']);
 assert.equal(out[0].message.files,undefined,'an authorization has no deliverables');
 assert.deepEqual(out[1].message.files.map(f=>f.path),['figures/fig1.png','paper_draft.md','notes/sources.md']);
 assert.deepEqual(out[2].message.files.map(f=>f.path),['stage2.md'],'a report without its stage reference is read by the stage it names');
 assert.equal(out[1].message.noticeKind,'stage_report');
 assert.deepEqual(P.noticeFiles(state,p,p.notices[1]).map(f=>f.path),['figures/fig1.png','paper_draft.md','notes/sources.md'],'the same files for a report delivered before, read when it is drawn');
});

test('the plan strip names every teammate working at once, and each of their tasks reads Working',()=>{
 const tasks=[task('t1','dispatched',{workerTaskId:'w1',workerStatus:'running'}),task('t2','dispatched',{assignee:'forge',workerTaskId:'w2',workerStatus:'running',updatedAt:'2026-10-19T10:18:00Z'}),task('t3','dispatched',{assignee:'chief',workerTaskId:'w3',workerStatus:'queued'})];
 const p=active(tasks,{state:'working'});
 const both=pulse({lyra:{state:'working',taskId:'w1'},forge:{state:'quiet',taskId:'w2'},chief:{state:'queued',taskId:'w3'}});
 assert.equal(P.banner(p,both,names,NOW),'Working on Stage 1 of 3 — 0 of 3 tasks done — Lyra is working on “Task t1” (30 min), Forge on “Task t2” (12 min), plus 1 more');
 assert.deepEqual(tasks.map(t=>P.taskChip(t,both).label),['Working','Working','Queued'],'each running task reads Working, the one waiting its turn Queued');
 assert.match(P.stripHTML(p,both,names,{now:NOW}),/Lyra is working on “Task t1” \(30 min\), Forge on “Task t2” \(12 min\)/);
 // With one at work it reads as it always did.
 assert.equal(P.banner(p,pulse({lyra:{state:'working',taskId:'w1'}}),names,NOW),'Working on Stage 1 of 3 — 0 of 3 tasks done — Lyra is working on “Task t1” (30 min), plus 2 more');
});

test('plan notices read as cards: a stage report with its criteria, rows and what comes next; a decision with its recommendation; an authorization as one line',()=>{
 const report='Acceptance: S01 PASS, independently signed off by Vera.\nOutputs: stages/S01_protocol/ contains spec_v1.sha256 and acceptance.md.\nDecision: Preserve frozen protocols because the rendering input is unchanged.\nIssues: No remaining S01 blockers.';
 const holding=plan('holding',{state:'stage_done'},{scope:{...scope,status:'achieved'},stages:[stage(1,'done',[task('t1','done')]),stage(2,'proposed'),stage(3,'proposed')],
  notices:[{id:'r1',kind:'stage_report',text:report+'\n\nNext is Stage 2 — Build: Goal of stage 2. Say “get stage 2 done”, or tell me what to change.',chat:true,status:'open',refs:{stageId:'s1'}},
   {id:'e1',kind:'escalation',text:'Approve the recommended suspension? My recommendation: Suspend S02a recovery until runtime access is back. The team keeps working on the rest meanwhile.',chat:true,status:'open',refs:{question:'Approve the recommended suspension?',recommendation:'Suspend S02a recovery until runtime access is back',category:'objective'}},
   {id:'a1',kind:'authorized',text:'Stage 2 authorized. The team is working on Stage 2 — Build. I\'ll report when it\'s done. I\'ll only interrupt you for sign-ins.',chat:true,status:'open'}]});
 const msg=n=>({id:'plan-notice-'+n.id,planNotice:true,planId:'p1',noticeKind:n.kind,body:n.text,whoName:'Chief'});
 assert.deepEqual(P.splitReport(holding.notices[0].text).rows.map(r=>r.label),['Acceptance','Outputs','Decision','Issues'],'labelled lines become rows, without the line about what comes next');
 assert.equal(P.splitReport('Stage 1 — Research is done.').prose,'Stage 1 — Research is done.','a report in prose stays prose');
 const card=P.noticeCard(holding,msg(holding.notices[0]));
 assert.equal(card.label,'Stage report');
 assert.match(card.html,/<h3>Stage 1 · Research<\/h3><span class="plan-chip done">Done<\/span>/);
 assert.match(card.html,/<dt>Issues<\/dt><dd>No remaining S01 blockers.<\/dd>/);
 assert.match(card.html,/class="met"><svg[^>]*>.*?<\/svg><span>Criterion 1a<\/span>/,'its stage’s criteria, met');
 assert.match(card.html,/data-plan-authorize="2"[^>]*>Get stage 2 done</,'the next stage is the person’s choice, on the card');
 assert.doesNotMatch(card.html,/Next is Stage 2/,'the plan’s sentence about what comes next is the footer, not part of the report');
 const started={...holding,status:'active',scope:{...scope,through:2},stages:[stage(1,'done'),stage(2,'working'),stage(3,'proposed')]};
 assert.match(P.noticeCard(started,msg(holding.notices[0])).html,/Stage 2 started/,'once chosen, the card says so instead of asking again');
 assert.doesNotMatch(P.noticeCard(started,msg(holding.notices[0])).html,/data-plan-authorize/);
 const decision=P.noticeCard(holding,msg(holding.notices[1]));
 assert.match(decision.html,/Needs your decision · a change to the plan/);
 assert.match(decision.html,/<h3>Approve the recommended suspension\?<\/h3>/);
 assert.match(decision.html,/Chief recommends<\/span><p>Suspend S02a recovery until runtime access is back<\/p>/);
 assert.match(decision.html,/data-plan-answer="approve" data-notice="e1"/);
 const answered={...holding,notices:holding.notices.map(n=>n.id==='e1'?{...n,status:'answered',refs:{...n.refs,answer:'Approved. Go ahead.'}}:n)};
 const done=P.noticeCard(answered,msg(holding.notices[1])).html;
 assert.match(done,/You answered<\/span><span class="plan-card-answer">Approved. Go ahead.<\/span>/);
 assert.doesNotMatch(done,/data-plan-answer/,'an answered question has no buttons');
 assert.match(P.noticeCard(holding,msg(holding.notices[1]),{reply:{open:true,draft:'Wait until Monday'}}).html,/<textarea[^>]*>Wait until Monday<\/textarea>/,'a reply being written is kept');
 const line=P.noticeCard(holding,msg(holding.notices[2]));
 assert.equal(line.line,true);assert.equal(line.html,'<strong>Stage 2 authorized</strong><span> · working on Stage 2 — Build</span>');
 assert.equal(P.noticeCard(null,msg(holding.notices[0])),null,'a notice whose plan is not known stays a plain message');
 assert.equal(P.noticeCard(holding,{...msg(holding.notices[0]),noticeKind:'proposal'}),null);
});

test('a question waiting for the person is answered from the plan view in one step: the button opens the team chat at its card',()=>{
 const asking=active([task('t1','done'),task('t2','pending'),task('t3','pending')],{state:'needs_you',needsYou:1},
  {notices:[{id:'N1',kind:'escalation',status:'open',text:'May we change the November 12 restriction? My recommendation: approve.',chat:true,refs:{question:'May we change the November 12 restriction?'}}]});
 const html=P.stripHTML(asking,pulse({}),names,{open:true,now:NOW});
 assert.match(html,/<button type="button" class="small-link plan-needs" data-action="chat" data-id="team" data-plan-notice-open="N1">Answer in chat<\/button>/);
 assert.doesNotMatch(html,/data-activity-open/);
 // Waiting for the person without a question card (a task held for them) still lists what needs them.
 const held=active([task('t1','blocked',{blockedOn:'user'}),task('t2','pending'),task('t3','pending')],{state:'needs_you',needsYou:1});
 assert.match(P.stripHTML(held,pulse({}),names,{open:true,now:NOW}),/data-activity-open>See what needs you/);
});

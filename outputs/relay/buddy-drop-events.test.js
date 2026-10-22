const test=require('node:test'),assert=require('node:assert/strict');
const worker=require('./buddy-worker.js'),plan=require('./buddy-plan.js'),signin=require('./buddy-signin.js'),drop=require('./buddy-drop-events.js');
// The desktop drop: which events put a Buddy on the screen while the person is in another app, and which never do.
const NOW=Date.parse('2026-10-21T12:00:00Z'),at=minutes=>new Date(NOW-minutes*60000).toISOString();
const team=()=>({conversationWorkspace:'w',agents:[{id:'chief',name:'Chief',avatarShape:'star',avatarColor:'lilac'},{id:'lyra',name:'Lyra',avatarShape:'sphere',avatarColor:'rose'},{id:'forge',name:'Forge',avatarShape:'hex',avatarColor:'peach'}],groups:[{id:'team',name:'Team',members:['chief','lyra','forge'],managedBy:'chief'}],messages:{}});
const task=(extra={})=>({id:'t1',workspace:'w',agentId:'lyra',title:'Find five portfolio references',status:'completed',attempt:1,result:'Five references saved.',updatedAt:at(1),...extra});
const coding={id:'r1',status:'pending',kind:'coding',tool:{name:'shell',arguments:{command:'npm test',reason:'Check the build'}},questions:[{id:'command',question:'Allow this exact command?',options:[{label:'Accept'},{label:'Decline'}]}]};

test('a finished background task the person started puts its agent on the screen, once, with the agent’s own look',()=>{
 const state=team(),t=task(),d=drop.forTask(state,t,NOW);
 assert.deepEqual(d,{eventId:worker.deliveryID(t),agentId:'lyra',kind:'done',text:'Find five portfolio references',chat:'lyra',name:'Lyra',shape:'sphere',color:'red'},'old figure names become the current shape and colour');
 const sent=[],emitter=drop.createEmitter({send:p=>sent.push(p)});
 assert.equal(emitter.emit(d),true);assert.equal(emitter.emit(drop.forTask(state,t,NOW)),false,'the same event is dropped once');
 assert.equal(sent.length,1);
 // A newer outcome of the same task is a new event.
 assert.equal(emitter.emit(drop.forTask(state,task({attempt:2}),NOW)),true);assert.equal(sent.length,2);
});

test('only the events that post a result or a request for the person make a drop',()=>{
 const state=team();
 assert.equal(drop.forTask(state,task({status:'running'}),NOW),null,'work in progress');
 assert.equal(drop.forTask(state,task({quiet:true}),NOW),null,'a quiet routine check');
 assert.equal(drop.forTask(state,task({workspace:'other'}),NOW),null,'another workspace');
 assert.equal(drop.forTask(state,task({agentId:'gone'}),NOW),null,'an agent no longer here');
 assert.equal(drop.forTask(state,task({updatedAt:at(40)}),NOW),null,'an old outcome read late (after a restart) is not news');
 assert.equal(drop.forTask(state,task({status:'interrupted'}),NOW),null,'an interruption Buddy recovers from itself');
 assert.equal(drop.forTask(state,task({status:'paused',stopCause:'user.pause'}),NOW),null,'a pause the person made');
 const failed=drop.forTask(state,task({status:'failed',result:'',progress:'Gmail is disconnected.'}),NOW);
 assert.equal(failed.kind,'needs');assert.match(failed.text,/^Couldn’t finish Find five/);
 assert.equal(drop.forTask(state,task({status:'failed',recovery:{state:'queued'}}),NOW),null,'a stop being retried by itself');
});

test('an approval or a question that reaches the person is a “needs you” drop',()=>{
 const state=team();
 const approve=drop.forTask(state,task({status:'waiting_review',reviews:[coding],attentionKey:'r1'}),NOW);
 assert.equal(approve.kind,'needs');assert.equal(approve.text,'Approve a command');assert.equal(approve.chat,'lyra');
 const check=drop.forTask(state,task({status:'waiting_review',reviews:[{id:'c1',status:'pending',kind:'checkpoint',tool:{arguments:{}}}],attentionKey:'c1'}),NOW);
 assert.equal(check.text,'Check the work');
 const ask=drop.forTask(state,task({status:'waiting_user',progress:'Which of the two CVs should I send?',checkpoint:{need:'decision'}}),NOW);
 assert.equal(ask.kind,'needs');assert.equal(ask.text,'Answer a question');
});

test('what the team supervisor handles never reaches the screen',()=>{
 const state=team();
 assert.equal(drop.forTask(state,task({status:'waiting_review',reviews:[{...coding,route:'supervisor'}],attentionKey:'r1'}),NOW),null,'a command review routed to the supervisor');
 assert.equal(drop.forTask(state,task({status:'waiting_user',progress:'Which source?',checkpoint:{need:'decision',routedTo:'supervisor'}}),NOW),null,'a question routed to the supervisor');
 assert.equal(drop.forTask(state,task({planTaskId:'pt1',reportsTo:'chief'}),NOW),null,'a plan task’s result, which Chief reviews (the stage report is the person’s news)');
 assert.equal(drop.forTask(state,task({reportsTo:'chief'}),NOW),null,'a task Chief handed out reports to Chief');
 assert.equal(drop.forTask(state,task({status:'failed',supervisorId:'chief'}),NOW),null,'a stop the supervisor looks at first');
 assert.equal(drop.forTask(state,task({status:'failed',supervisorId:'chief',stopCause:'provider.account'}),NOW).kind,'needs','a provider account problem is always the person’s');
 assert.equal(drop.forTask(state,task({status:'waiting_user',stopCause:'review.parked',progress:'Set aside'}),NOW),null,'a task set aside for an approval already asked');
 // A sign-in waits in the chat as its own request (buddy-signin.js); the task’s own message is not posted, so it makes no drop either.
 assert.equal(drop.forTask(state,task({status:'waiting_user',checkpoint:{need:'signin'}}),NOW),null);
});

test('a stage report from the plan is a “done” drop from the supervisor, an escalation or a stuck team asks the person, other notices stay quiet',()=>{
 const state=team(),notice=(id,kind,text,extra={})=>({id,kind,text,chat:true,status:'open',at:at(1),...extra});
 const plans=[{id:'p1',groupId:'team',supervisorId:'chief',stages:[{id:'s1',n:1,title:'Research',status:'done',tasks:[]}],notices:[
  notice('n0','authorized','Stage 1 authorized. The team is working on Stage 1 — Research.'),
  notice('n1','stage_report','Stage 1 — Research is done.',{refs:{stageId:'s1'}}),
  notice('n2','escalation','Should we pay $40 for the dataset? My recommendation: yes.',{refs:{question:'Should we pay $40 for the dataset?'}}),
  notice('n3','stuck','The team is stuck on Collect references: nothing moved it. Tell me how to proceed.'),
  notice('n4','stage_report','Stage 2 — Build is done.',{at:at(90)})]}];
 const drops=[];
 assert.deepEqual(plan.deliverNotices(state,plans,item=>drops.push(drop.forNotice(state,item,NOW))),['team','team','team','team','team']);
 assert.equal(state.messages.team.length,5,'every notice is still posted in the chat');
 assert.equal(drops[0],null,'the go-ahead the person just gave is not news to them');
 assert.deepEqual(drops[1],{eventId:'plan-notice-n1',agentId:'chief',kind:'done',text:'Stage 1 is done',chat:'team',name:'Chief',shape:'diamond',color:'lilac'});
 assert.equal(drops[2].kind,'needs');assert.equal(drops[2].text,'Should we pay $40 for the dataset?');
 assert.equal(drops[3].kind,'needs');assert.equal(drops[3].text,'The team is stuck');
 assert.equal(drops[4],null,'a report from long ago, read late');
 assert.deepEqual(plan.deliverNotices(state,plans,()=>assert.fail('a notice already in the chat is not delivered again')),[]);
});

test('a sign-in or a web step the person must do is a “needs you” drop from the agent, once per request',()=>{
 const state=team(),seen=[];
 const step={key:'step:t2:1',kind:'step',need:'signin',taskId:'t2',agentId:'forge',planId:'p1',url:'https://iopscience.iop.org/article/1',origin:'https://iopscience.iop.org',instruction:'Sign in with your USC account, then press Done.'};
 const snap={workspace:'w',plans:[{id:'p1',groupId:'team'}],signinRequests:[step]};
 assert.equal(signin.sync(state,snap,new Map(),r=>seen.push(drop.forSignin(state,r))),true);
 assert.equal(state.messages.forge.length,1);assert.equal(state.messages.team.length,1,'posted in the agent’s chat and the team chat');
 assert.deepEqual(seen,[{eventId:'signin-step:t2:1',agentId:'forge',kind:'needs',text:'Sign in to iopscience.iop.org',chat:'forge',name:'Forge',shape:'hex',color:'peach'}],'one drop for the request, from its agent, opening the agent’s chat');
 assert.equal(signin.sync(state,snap,new Map(),()=>assert.fail('the same request again is not new')),false);
 const mfa=drop.forSignin(state,{key:'mfa:t3:c1',kind:'mfa',service:'WRDS',taskId:'t3',agentId:'lyra'});
 assert.equal(mfa.text,'Approve the WRDS Duo push on your phone');
 assert.equal(drop.forSignin(state,{key:'x',kind:'signin',agentId:'gone',origin:'https://a.example'}),null,'an agent no longer here');
});

test('the setting turns the drop off, and a payload is always short, plain and complete',()=>{
 let on=false;const sent=[],emitter=drop.createEmitter({send:p=>sent.push(p),enabled:()=>on});
 const d=drop.forTask(team(),task(),NOW);
 assert.equal(emitter.emit(d),false);assert.equal(sent.length,0,'nothing reaches the Mac app while the setting is off');
 on=true;assert.equal(emitter.emit(d),true,'an event skipped while off is not remembered as shown');
 assert.equal(drop.enabled({}),true,'on by default');assert.equal(drop.enabled({desktopDrop:false}),false);assert.equal(drop.enabled({desktopDrop:true}),true);
 const long=drop.forTask(team(),task({title:'**Research** the `twelve` most influential portfolio websites of the last decade and summarise each one'}),NOW);
 assert.ok(long.text.length<=64,long.text);assert.doesNotMatch(long.text,/[*`]/);assert.match(long.text,/…$/);
 assert.deepEqual(Object.keys(long).sort(),['agentId','chat','color','eventId','kind','name','shape','text']);
 let threw=drop.createEmitter({send:()=>{throw Error('no bridge');}});assert.equal(threw.emit(d),false,'a missing bridge never breaks delivery');
 assert.equal(drop.createEmitter({send:()=>Promise.reject(Error('refused'))}).emit(d),true,'a refusal from the app is not an error on the page');
});

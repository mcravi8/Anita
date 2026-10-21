const test=require('node:test'),assert=require('node:assert/strict');
const {snapshot,tracker}=require('./buddy-figure-modes.js');
const agents=['lead','one','two','three'].map(id=>({id}));
const base=(runs={},extra={})=>({agents,groups:[{id:'team',members:['lead','one','two','three']}],runs,...extra});
const dm=(status,target='one',runId='r1')=>({[runId]:{runId,target,status}});
const group=(phase,entries=[],status='answering')=>({g1:{runId:'g1',target:'team',status,memberIds:['lead','one','two','three'],team:{phase,leadId:'lead',entries}}});
const fakeSink=()=>{
  const modes={},log=[];
  return {log,modes,getMode:id=>modes[id]||'ready',setMode:(id,m)=>{modes[id]=m;log.push(['mode',id,m]);},setFocus:(id,to,g)=>log.push(['focus',id,to,g]),handoff:(a,b)=>log.push(['handoff',a,b]),setGroupWork:(g,m)=>log.push(['work',g,m])};
};
test('a direct reply is planning while it starts and working while it streams',()=>{
  assert.deepEqual(snapshot(base(dm('starting'))).modes,{one:'planning'});
  assert.deepEqual(snapshot(base(dm('answering'))).modes,{one:'working'});
  assert.deepEqual(snapshot(base(dm('stopping'))).modes,{one:'working'});
  assert.deepEqual(snapshot(base(dm('completed'))).modes,{});
  assert.deepEqual(snapshot(base(dm('failed'))).modes,{});
});
test('an action waiting on the user means needs and a look at the user',()=>{
  const s=snapshot(base(dm('answering')),{pending:(_,runId)=>runId==='r1'?[{agentId:'one'}]:[]});
  assert.deepEqual(s.modes,{one:'needs'});assert.deepEqual(s.focus.one,{to:'user'});
});
test('a review from an agent that is not in the workspace is ignored',()=>{
  assert.deepEqual(snapshot(base(dm('answering')),{pending:()=>[{agentId:'ghost'}]}).modes,{one:'working'});
});
test('setup chats and team checks also read as working',()=>{
  const s=snapshot(base(),{setup:(_,id)=>id==='two'?{status:'answering'}:null,checking:id=>id==='three'});
  assert.deepEqual(s.modes,{two:'working',three:'working'});
});
test('group planning: the lead plans and the members look at the lead',()=>{
  const s=snapshot(base(group('planning')));
  assert.deepEqual(s.modes,{lead:'planning'});
  for(const id of ['one','two','three'])assert.deepEqual(s.focus[id],{to:'lead',group:'team'});
  assert.equal(s.focus.lead,undefined);
});
test('group working: working members work, the rest watch them, and the group row shows who is working',()=>{
  const entries=[{agentId:'one',status:'completed'},{agentId:'two',status:'working'},{agentId:'three',status:'queued'}];
  const s=snapshot(base(group('working',entries)));
  assert.deepEqual(s.modes,{two:'working'});assert.equal(s.work.team,'two');
  for(const id of ['lead','one','three'])assert.deepEqual(s.focus[id],{to:'two',group:'team'});
  const review=snapshot(base(group('working',[{agentId:'three',status:'review'}])));
  assert.deepEqual(review.modes,{three:'needs'});assert.deepEqual(review.focus.three,{to:'user'});
});
test('group replying: the lead works while the others look at them',()=>{
  const s=snapshot(base(group('replying',[{agentId:'one',status:'completed'}])));
  assert.deepEqual(s.modes,{lead:'working'});assert.equal(s.focus.one.to,'lead');
});
test('entries that name someone outside the run are ignored',()=>{
  assert.deepEqual(snapshot(base(group('working',[{agentId:'ghost',status:'working'}]))).modes,{});
});
test('a finished reply is done and then lets go; a failed one is stuck; a stopped one just rests',()=>{
  for(const [end,mode] of [['completed','done'],['failed','stuck'],['stopped','ready']]){
    const sink=fakeSink(),t=tracker(sink);
    t.update(base(dm('answering')));assert.equal(sink.modes.one,'working');
    t.update(base(dm(end)));assert.equal(sink.modes.one,mode,end);
  }
});
test('opening the app does not celebrate or blame runs that finished earlier',()=>{
  const sink=fakeSink(),t=tracker(sink);
  t.update(base({...dm('completed','one','a'),...dm('failed','two','b')}));
  assert.equal(sink.log.filter(e=>e[0]==='mode').length,0);
});
test('a completed team run is done for everyone, staggered 160 ms, lead first',()=>{
  const sink=fakeSink(),queue=[],t=tracker(sink,{later:(ms,fn)=>queue.push([ms,fn])});
  t.update(base(group('working',[{agentId:'one',status:'working'}])));
  t.update(base(group('completed',[],'completed')));
  const done=sink.log.filter(e=>e[0]==='mode'&&e[2]==='done');
  assert.deepEqual(done.map(e=>e[1]),['lead'],'the lead celebrates at once');
  assert.deepEqual(queue.map(q=>q[0]),[160,320,480]);
  queue.forEach(([,fn])=>fn());
  assert.deepEqual(sink.log.filter(e=>e[0]==='mode'&&e[2]==='done').map(e=>e[1]),['lead','one','two','three']);
});
test('work moving between members shows the member working, with no animation joining members or the group row',()=>{
  const sink=fakeSink(),t=tracker(sink);
  t.update(base(group('working',[{agentId:'one',status:'working'},{agentId:'two',status:'queued'}])));
  assert.equal(sink.modes.one,'working');
  t.update(base(group('working',[{agentId:'one',status:'completed'},{agentId:'two',status:'working'}])));
  assert.equal(sink.modes.two,'working','the one working is shown working');
  assert.deepEqual(sink.log.filter(e=>e[0]==='handoff'||e[0]==='work'),[],'but nothing streams from one member to another or to the group row');
  t.update(base({}));
  assert.deepEqual(sink.log.filter(e=>e[0]==='handoff'||e[0]==='work'),[]);
});
test('background work from the worker’s pulse moves the figures: working, waiting for a turn, and needing the person',()=>{
  const team={agents:[{id:'forge'},{id:'lyra'},{id:'chief'},{id:'mira'}],groups:[],runs:{}};
  const pulse=agents=>()=>({agents});
  assert.deepEqual(snapshot(team,{pulse:pulse({forge:{state:'working'}})}).modes,{forge:'working'},'Forge is working');
  assert.deepEqual(snapshot(team,{pulse:pulse({forge:{state:'quiet'},lyra:{state:'retrying'},chief:{state:'with_supervisor'},mira:{state:'needs_you'}})}).modes,{forge:'working',lyra:'planning',chief:'planning',mira:'needs'});
  assert.deepEqual(snapshot(team,{pulse:pulse({forge:{state:'idle'},ghost:{state:'working'}})}).modes,{},'idle rests, and an agent outside the workspace is ignored');
  assert.deepEqual(snapshot(team,{pulse:()=>undefined}).modes,{},'no pulse yet, nothing changes');
  assert.deepEqual(snapshot({...team,runs:dm('starting','forge')},{pulse:pulse({forge:{state:'needs_you'}})}).modes,{forge:'needs'},'needing the person outranks a reply starting');
  const before=globalThis.BuddyWorkerUI;globalThis.BuddyWorkerUI={pulse:()=>({agents:{lyra:{state:'working'}}})};
  try{assert.deepEqual(snapshot(team).modes,{lyra:'working'},'by default the pulse comes from the worker panel’s last status');}finally{globalThis.BuddyWorkerUI=before;}
  const sink=fakeSink(),t=tracker(sink);let agents={forge:{state:'working'}};
  t.update(team,{pulse:()=>({agents})});assert.equal(sink.modes.forge,'working');
  agents={};t.update(team,{pulse:()=>({agents})});assert.equal(sink.modes.forge,'ready','and rests again once the work is over');
});
test('a mode set by something else is not overwritten when the run ends',()=>{
  const sink=fakeSink(),t=tracker(sink);
  t.update(base(dm('answering')));sink.modes.one='stuck';
  t.update(base({}));assert.equal(sink.modes.one,'stuck');
});
test('an agent pulses "needs you" only while the bell still counts something unread for it',()=>{
  const A=require('./buddy-activity.js');
  const team={conversationWorkspace:'w',agents:[{id:'inbox',name:'Inbox'},{id:'chief',name:'Chief'}],groups:[],runs:{}};
  // Inbox's real case: its 06:00 check stopped, the open entry is the person's, and the person has already seen it.
  const decision={id:'stopped:A7BB0D7D-862A-4761-ABDE-8A02C3008EBE:1:failed',kind:'stopped',agentId:'inbox',taskId:'A7BB0D7D-862A-4761-ABDE-8A02C3008EBE',title:'Check AgentMail and Gmail (06:00)',question:'failed to refresh installed connector runtime state',audience:'user',createdAt:'2026-10-20T14:25:38Z'};
  const worker={workspace:'w',tasks:[],decisions:[decision],notifications:{}},pulse=()=>({agents:{inbox:{state:'needs_you'}}});
  const needing=s=>()=>A.needingAgents(A.collect(s,worker));
  assert.deepEqual(snapshot(team,{pulse,needing:needing(team)}).modes,{inbox:'needs'},'unread, it pulses');
  const seen={...team,activitySeen:{['decision:'+decision.id]:true}};
  assert.deepEqual(snapshot(seen,{pulse,needing:needing(seen)}).modes,{},'once the person has seen it, it rests');
  const dismissed={...team,activityDismissed:{['decision:'+decision.id]:true}};
  assert.deepEqual(snapshot(dismissed,{pulse,needing:needing(dismissed)}).modes,{},'and so once it is dismissed');
  const readInApp={...team};const readWorker={...worker,notifications:{['decision:'+decision.id]:{read:true,dismissed:false}}};
  assert.deepEqual(snapshot(readInApp,{pulse,needing:()=>A.needingAgents(A.collect(readInApp,readWorker))}).modes,{},'read on another screen (the app’s own copy) counts the same');
  assert.deepEqual(snapshot(team,{pulse,needing:()=>undefined}).modes,{inbox:'needs'},'without the notification list, the worker’s pulse alone decides, as before');
});

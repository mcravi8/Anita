const test=require('node:test'),assert=require('node:assert/strict');
const access=require('./buddy-folder-access.js');

const base=()=>({conversationWorkspace:'w1',agents:[{id:'chief',name:'Chief'},{id:'lyra',name:'Lyra'}],groups:[{id:'team',name:'Team',members:['chief','lyra']}],messages:{chief:[],lyra:[],team:[]}});
const desktop={id:'r1',status:'pending',name:'Desktop',label:'your Desktop',reason:'to read paper.pdf',path:'~/Desktop/paper.pdf',location:'/Users/m/Desktop',agentId:'chief',agentName:'Chief',
 waiting:[{agentId:'chief',agentName:'Chief',chat:'chief',taskId:'',runId:'run-1',planId:''},{agentId:'lyra',agentName:'Lyra',chat:'team',taskId:'',runId:'run-2',planId:''}]};

test('a request is one card in each waiting agent’s chat and in the group the turn was in, posted once',()=>{
 const state=base();
 assert.equal(access.sync(state,{workspace:'w1',requests:[desktop]},null),true);
 assert.deepEqual(Object.fromEntries(Object.entries(state.messages).map(([k,v])=>[k,v.length])),{chief:1,lyra:1,team:1});
 const card=state.messages.chief[0];
 assert.equal(card.kind,'access-request');assert.equal(card.status,'open');assert.equal(card.who,'chief');
 assert.equal(card.body,'Chief wants access to your Desktop — to read paper.pdf.');
 assert.equal(state.messages.team[0].who,'lyra','the group copy is in the name of the agent whose turn asked there');
 assert.equal(access.sync(state,{workspace:'w1',requests:[desktop]},null),false,'a second sync posts nothing new');
 assert.equal(access.sync(state,{workspace:'other',requests:[desktop]},null),false,'another workspace’s list is ignored');
});

test('a task’s request also goes to its team plan’s group chat',()=>{
 const state=base(),task={...desktop,id:'r2',waiting:[{agentId:'chief',agentName:'Chief',chat:'',taskId:'t1',planId:'p1'}]};
 access.sync(state,{workspace:'w1',requests:[task]},{plans:[{id:'p1',groupId:'team'}]});
 assert.equal(state.messages.chief.length,1);assert.equal(state.messages.team.length,1);assert.equal(state.messages.lyra.length,0);
});

test('an answer from anywhere settles every copy; a request the app no longer lists is over',()=>{
 const state=base();access.sync(state,{workspace:'w1',requests:[desktop]},null);
 access.sync(state,{workspace:'w1',requests:[{...desktop,status:'allowed'}]},null);
 assert.deepEqual([state.messages.chief[0].status,state.messages.team[0].status],['allowed','allowed']);
 assert.equal(state.messages.chief[0].result,'Allowed.');
 const other=base();access.sync(other,{workspace:'w1',requests:[desktop]},null);access.sync(other,{workspace:'w1',requests:[{...desktop,status:'declined'}]},null);
 assert.equal(other.messages.lyra[0].result,'Not allowed.');
 const gone=base();access.sync(gone,{workspace:'w1',requests:[desktop]},null);access.sync(gone,{workspace:'w1',requests:[]},null);
 assert.equal(gone.messages.chief[0].status,'closed');
});

test('allowed, each chat that waited gets one follow-up note; a task resumes natively and a no gets no turn',()=>{
 const waiting=[{requestId:'r1',status:'allowed',name:'Desktop',agentId:'chief',chat:'chief',taskId:''},{requestId:'r1',status:'allowed',name:'Desktop',agentId:'lyra',chat:'team',taskId:''},
  {requestId:'r3',status:'allowed',name:'Pictures',agentId:'chief',chat:'chief',taskId:''},{requestId:'r4',status:'allowed',name:'Music',agentId:'chief',chat:'',taskId:'t1'},{requestId:'r5',status:'declined',name:'Downloads',agentId:'lyra',chat:'lyra',taskId:''}];
 assert.deepEqual(access.followUps(waiting),[{chat:'chief',text:'Access to Desktop and Pictures granted; continue.'},{chat:'team',text:'Access to Desktop granted; continue.'}]);
 const state=base();
 assert.equal(access.outcome(state,[{agentId:'chief'}],'allow'),'Allowed — Chief is continuing.');
 assert.equal(access.outcome(state,[{agentId:'chief'},{agentId:'lyra'}],'home'),'Allowed — Chief and Lyra are continuing.');
 assert.equal(access.outcome(state,[{agentId:'chief'}],'deny'),'Not allowed.');
});

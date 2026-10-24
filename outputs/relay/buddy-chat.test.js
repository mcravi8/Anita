const {test}=require('node:test');const assert=require('node:assert/strict');const Chat=require('./buddy-chat');
const seed=()=>({agents:[{id:'a',name:'Alpha',role:'Writer',description:'Use concise prose.'},{id:'b',name:'Beta',role:'Reviewer',description:'Challenge assumptions.'}],messages:{},drafts:{a:'hello',b:'second'},attachments:{}});
test('independent chats and instructions route to the right agent',()=>{const s=seed(),a=Chat.begin(s,'a'),b=Chat.begin(s,'b');assert.notEqual(a.run.key,b.run.key);Chat.apply(s,{runId:a.run.runId,key:a.run.key,status:'answering',text:'alpha response'});assert.equal(s.messages.a[1].body,'alpha response');assert.equal(s.messages.b[1].body,'');assert.equal(b.payload.agent.description,'Challenge assumptions.');});
test('duplicate submissions are rejected without duplicating messages',()=>{const s=seed();Chat.begin(s,'a');assert.throws(()=>Chat.begin(s,'a'),/already answering/);assert.equal(s.messages.a.length,2);});
test('a retry keeps the user message and uses current instructions',()=>{const s=seed(),first=Chat.begin(s,'a');Chat.apply(s,{runId:first.run.runId,status:'failed',error:'offline'});s.agents[0].description='Write in Italian.';const next=Chat.begin(s,'a',{retryOf:first.run.runId});assert.equal(next.payload.agent.description,'Write in Italian.');assert.equal(s.messages.a.filter(m=>m.who==='you').length,1);assert.equal(next.run.userId,first.run.userId);});
test('partial stopped reply stays visible and ignores late streaming events',()=>{const s=seed(),first=Chat.begin(s,'a');Chat.apply(s,{runId:first.run.runId,status:'answering',text:'partial'});Chat.apply(s,{runId:first.run.runId,status:'stopped'});assert.equal(s.messages.a[1].body,'partial');assert.equal(Chat.apply(s,{runId:first.run.runId,status:'answering',text:'late'}),false);assert.equal(s.messages.a[1].body,'partial');assert.equal(Chat.active(s,'a'),undefined);});
test('reopening recovers an active backend reply or makes interruption retryable',()=>{const s=seed(),a=Chat.begin(s,'a'),b=Chat.begin(s,'b');Chat.recover(s,[{runId:a.run.runId,status:'answering',text:'still running'}]);assert.equal(s.runs[a.run.runId].status,'answering');assert.equal(s.runs[b.run.runId].status,'failed');assert.match(s.messages.b[1].error,/interrupted/);});
test('attachments, missing chats, empty or oversized input preserve the draft',()=>{const s=seed();s.attachments.a=[{name:'private.txt'}];assert.throws(()=>Chat.begin(s,'a'),/Remove the attachment/);assert.equal(s.drafts.a,'hello');assert.throws(()=>Chat.begin(s,'group'),/no longer available/);s.attachments.a=[];s.drafts.a=' '.repeat(2);assert.throws(()=>Chat.begin(s,'a'),/Write a message/);s.drafts.a='x'.repeat(30001);assert.throws(()=>Chat.begin(s,'a'),/30,000/);});
test('old workspace events cannot update a fresh conversation',()=>{const s=seed(),a=Chat.begin(s,'a');assert.equal(Chat.apply(s,{runId:a.run.runId,key:'another-workspace:a',status:'completed',text:'wrong'}),false);assert.equal(s.messages.a[1].body,'');});

const grouped=()=>({...seed(),groups:[{id:'team',name:'Launch',objective:'A clear announcement',members:['a','b']}],drafts:{a:'private message',team:'@Beta review a draft with Alpha'}});
test('group requests create one reply and do not mix direct histories',()=>{const s=grouped(),r=Chat.begin(s,'team');assert.equal(r.payload.kind,'group');assert.equal(r.payload.groupId,'team');assert.equal(r.payload.agent,undefined);assert.deepEqual(r.run.memberIds,['a','b']);assert.equal(s.messages.team.length,2);assert.equal(s.drafts.a,'private message');Chat.apply(s,{runId:r.run.runId,key:r.run.key,status:'answering',text:'One combined reply',team:{phase:'replying',leadId:'b',entries:[{agentId:'a',notes:'Actual draft',status:'completed'}],partial:false}});assert.equal(s.messages.team[1].team.leadId,'b');assert.equal(s.messages.team[1].body,'One combined reply');assert.equal(s.messages.a,undefined);});
test('a group cannot silently include missing or duplicate members',()=>{for(const members of [['missing'],['a','a'],[]]){const s=grouped();s.groups[0].members=members;assert.throws(()=>Chat.begin(s,'team'),/available agents/);assert.equal(s.messages.team,undefined);assert.equal(s.drafts.team,'@Beta review a draft with Alpha');}});
test('invalid group events cannot partially change run state',()=>{const s=grouped(),r=Chat.begin(s,'team');assert.equal(Chat.apply(s,{runId:r.run.runId,status:'completed',text:'bad',team:{leadId:'outsider'}}),false);assert.equal(r.run.status,'starting');assert.equal(s.messages.team[1].body,'');});
test('partial teamwork can retry with the latest members and one user message',()=>{const s=grouped(),r=Chat.begin(s,'team');Chat.apply(s,{runId:r.run.runId,status:'completed',text:'Missing review',team:{phase:'completed',leadId:'a',entries:[],partial:true}});assert.equal(Chat.apply(s,{runId:r.run.runId,status:'completed',text:'Late replacement'}),false);s.groups[0].members=['b'];const next=Chat.begin(s,'team',{retryOf:r.run.runId});assert.deepEqual(next.run.memberIds,['b']);assert.equal(next.run.userId,r.run.userId);assert.equal(s.messages.team.filter(m=>m.who==='you').length,1);});
test('reopening restores real group progress and notes',()=>{const s=grouped(),r=Chat.begin(s,'team');Chat.recover(s,[{runId:r.run.runId,key:r.run.key,status:'answering',team:{phase:'working',leadId:'a',entries:[{agentId:'b',status:'completed',notes:'Review result'}]}}]);assert.equal(s.messages.team[1].team.entries[0].notes,'Review result');Chat.apply(s,{runId:r.run.runId,status:'stopped'});assert.equal(Chat.apply(s,{runId:r.run.runId,status:'completed',text:'Late answer'}),false);});
test('actual save receipts survive partial replies, stop, and restart recovery',()=>{const s=seed(),r=Chat.begin(s,'a'),file={path:'brief.md',folderId:'f',revision:'v',actorName:'Alpha'};Chat.apply(s,{runId:r.run.runId,status:'answering',files:[file]});file.path='mutated';assert.equal(s.messages.a[1].files[0].path,'brief.md');Chat.apply(s,{runId:r.run.runId,status:'stopped'});assert.equal(s.messages.a[1].files.length,1);assert.equal(Chat.apply(s,{runId:r.run.runId,status:'answering',files:[]}),false);const next=Chat.begin(s,'b');Chat.recover(s,[{runId:next.run.runId,status:'completed',text:'Saved',files:[{path:'second.md',folderId:'f',revision:'v2'}]}]);assert.equal(s.messages.b[1].files[0].path,'second.md');});
test('completed service and file tools cannot finish a reply before its answer',()=>{const s=seed(),r=Chat.begin(s,'a');for(const tool of ['gmail.search_emails','gmail.read_email','buddy_write_file','buddy_propose_agent']){assert.equal(Chat.apply(s,{type:'tool',runId:r.run.runId,status:'completed',tool}),false);assert.equal(r.run.status,'starting');}Chat.apply(s,{type:'run',runId:r.run.runId,status:'answering',text:'The verified answer'});Chat.apply(s,{type:'run',runId:r.run.runId,status:'completed',text:'The verified answer'});assert.equal(s.messages.a[1].body,'The verified answer');assert.equal(r.run.status,'completed');});
test('an empty final reply shows a retryable error and keeps the original request',()=>{const s=seed(),r=Chat.begin(s,'a');Chat.apply(s,{type:'run',runId:r.run.runId,status:'completed',text:'  '});assert.equal(r.run.status,'failed');assert.match(s.messages.a[1].error,/No answer/);const retry=Chat.begin(s,'a',{retryOf:r.run.runId});assert.equal(retry.run.userId,r.run.userId);assert.equal(s.messages.a.filter(m=>m.who==='you').length,1);});
test('reopening repairs old empty completions while retaining actual proposal and file cards',()=>{const s=seed(),r=Chat.begin(s,'a');r.run.status=s.messages.a[1].status='completed';Chat.recover(s);assert.equal(r.run.status,'failed');for(const card of ['files','proposalIds']){const other=seed(),n=Chat.begin(other,'a');n.run.status=other.messages.a[1].status='completed';other.messages.a[1][card]=card==='files'?[{path:'brief.md'}]:['proposal'];Chat.recover(other);assert.equal(n.run.status,'completed');}});

test('actual email coverage survives partial runs and reconnect; invented shapes are ignored',()=>{const s=seed(),r=Chat.begin(s,'a'),c={id:'receipt',query:'newer_than:90d assessment',read:2,unread:1,partial:true};Chat.apply(s,{type:'run',runId:r.run.runId,status:'answering',coverage:[c,{query:'invented'}]});c.read=99;assert.equal(s.messages.a[1].coverage.length,1);assert.equal(s.messages.a[1].coverage[0].read,2);Chat.apply(s,{type:'run',runId:r.run.runId,status:'failed',error:'offline'});assert.equal(s.messages.a[1].coverage[0].partial,true);});
test('routine receipts attach only to their actual workspace and agent and never finish a reply',()=>{const s=seed(),r=Chat.begin(s,'a'),routine={id:'saved',workspace:s.conversationWorkspace,agentId:'a',title:'Morning review',nextRun:'2026-10-17T16:00:00Z',status:'active'};assert.equal(Chat.apply(s,{type:'routine',runId:r.run.runId,routine:{...routine,workspace:'wrong'}}),false);assert.equal(Chat.apply(s,{type:'routine',runId:r.run.runId,routine}),true);assert.equal(s.messages.a[1].routines[0].id,'saved');assert.equal(r.run.status,'starting');Chat.apply(s,{type:'routine',runId:r.run.runId,routine:{...routine,status:'paused'}});assert.equal(s.messages.a[1].routines.length,1);assert.equal(s.messages.a[1].routines[0].status,'paused');});

test('operational replies show a brief result and preserve expandable detail without changing history',()=>{
 const s=seed(),r=Chat.begin(s,'a'),body='Inbox is created. Seven checks are saved.\n\n'+('Technical scheduling detail. '.repeat(40)),m={runId:r.run.runId,body,routines:[{id:'r'}]};
 const shown=Chat.presentation(s,m);assert.equal(shown.body,'Inbox is created. Seven checks are saved.');assert.equal(shown.details,body);assert.equal(m.body,body);
 assert.equal(Chat.presentation(s,{...m,routines:[]}).body,body);
 r.run.text='Explain the full details';assert.deepEqual(Chat.presentation(s,m),{body});
});
test('worker result details collapse even without a conversation run; errors remain independent',()=>{
 const body='Please reconnect Gmail.\n\n'+('Observed diagnostic detail. '.repeat(40)),m={body,workerTaskID:'task',error:'Gmail disconnected'};
 assert.equal(Chat.presentation(seed(),m).body,'Please reconnect Gmail.');assert.equal(Chat.presentation(seed(),m).details,body);assert.equal(m.error,'Gmail disconnected');
});
test('a task result reads as the agent’s message: the team’s details after a line of three dashes fold, and an opening addressed to Chief loses the name',()=>{
 const s={...seed(),agents:[{id:'lyra',name:'Lyra'},{id:'chief',name:'Chief'}]};
 const message='I fixed the two figure captions and the spelling of one paper’s title in the report. Nothing in the results changes. Vera checks the new version next.';
 const body=message+'\n\n---\nFiles: stages/S04b_revision/citation_editorial_corrections_lyra_20261023_v2.md\nChoice: kept the DOCX at f12cbe0e… because only captions changed.\n\n---\nCommand receipts: 3 finished, 3 exited successfully.';
 const shown=Chat.presentation(s,{body,workerTaskID:'t'});
 assert.equal(shown.body,message,'the message shows whole');
 assert.match(shown.details,/^Files: stages\/S04b_revision\//);assert.match(shown.details,/Command receipts: 3 finished/,'the details and Buddy’s receipts fold under Details');
 assert.deepEqual(Chat.presentation(s,{body:'Created the inbox.\n\n---\nCommand receipts: 1 finished, 1 exited successfully.',workerTaskID:'t'}),{body:'Created the inbox.',details:'Command receipts: 1 finished, 1 exited successfully.'},'a short result keeps its receipts folded');
 // A result written for the supervisor, before results were split: it opens without the name, and the rest folds as before.
 const old='Chief: I saved the [editorial closure report](<file:///Users/x/editorial_closure.md>). I preserved the verified evidence; Forge’s corrections are listed in the report. Matteo’s Student ID is directly confirmed in the saved record, so no user input is currently missing. Native Word review remains team-owned; Stage 5 is not yet PASS. **Next:** separately gated S05 release, not started.';
 const was=Chat.presentation(s,{body:old,workerTaskID:'t'});
 assert.match(was.body,/^I saved the \[editorial closure report\]/,'the name it was addressed to is gone');assert.doesNotMatch(was.body,/Student ID|S05/,'the rest folds');assert.equal(was.details,old.replace(/^Chief: /,''));
 assert.equal(Chat.resultParts('**Chief:** coverage passes.',['Chief']).lead,'Coverage passes.');assert.equal(Chat.resultParts('**Chief: coverage passes.** More.',['Chief']).lead,'**Coverage passes.** More.','a bold opening keeps its bold');
 assert.equal(Chat.resultParts('Chiefly: nothing',['Chief']).lead,'Chiefly: nothing','only a teammate’s whole name is taken off');
 // A message that runs long after all still opens short, with everything folded.
 const long='I saved the report. '+'It explains a great deal more than it needs to. '.repeat(20)+'\n\n---\nFiles: a.md';
 const cut=Chat.presentation(s,{body:long,workerTaskID:'t'});assert.equal(cut.body,'I saved the report. It explains a great deal more than it needs to.');assert.match(cut.details,/Files: a\.md$/);
 assert.deepEqual(Chat.presentation(s,{body:'Chief: the plan.\n\n---\nnot a task'}),{body:'Chief: the plan.\n\n---\nnot a task'},'only a task’s result is read this way');
 // Links count as their labels and are never cut: two long file links in the first sentence were cut mid-link, and the raw address showed.
 const path='file:///Users/matteo/Desktop/USC/Semester%204/Directed%20Research/stages/S04b_revision/editorial_closeout_lyra_20261023/';
 const linked=`I saved the [28-comment tracker](<${path}comment_response.csv>) and [editorial closure report](<${path}editorial_closure.md>). The report lists the text corrections. `+'More detail follows here. '.repeat(30);
 assert.equal(Chat.presentation(s,{body:linked,workerTaskID:'t'}).body,`I saved the [28-comment tracker](<${path}comment_response.csv>) and [editorial closure report](<${path}editorial_closure.md>). The report lists the text corrections.`);
 const endless=`See [the report](<${path}r.md>) `+'and more words without an end '.repeat(20);
 const fallback=Chat.presentation(s,{body:endless,workerTaskID:'t'}).body;assert.match(fallback,/^See the report and more words/);assert.doesNotMatch(fallback,/file:|\]\(/,'with no sentence end in reach, the opening is cut as plain text, never inside a link');
});
test('brief previews retain email addresses and Markdown links intact',()=>{
 const body='I created **matteo-chief@agentmail.to** on the free plan. Seven checks are saved.\n\n'+('Details. '.repeat(80));
 const shown=Chat.presentation(seed(),{body,workerTaskID:'task'});assert.equal(shown.body,'I created **matteo-chief@agentmail.to** on the free plan. Seven checks are saved.');assert.equal(shown.details,body);
});
test('delegated routine receipts require the registered owner and a participating creator',()=>{
 const s=seed(),r=Chat.begin(s,'a'),routine={id:'r',workspace:s.conversationWorkspace,agentId:'b',nextRun:'2026-10-19T15:00:00Z'};
 assert.equal(Chat.apply(s,{type:'routine',runId:r.run.runId,routine}),false);
 assert.equal(Chat.apply(s,{type:'routine',runId:r.run.runId,routine,delegatedBy:'a'}),true);
 assert.equal(Chat.apply(s,{type:'routine',runId:r.run.runId,routine:{...routine,agentId:'missing'},delegatedBy:'a'}),false);
 const g=grouped(),gr=Chat.begin(g,'team');assert.equal(Chat.apply(g,{type:'routine',runId:gr.run.runId,routine:{...routine,workspace:g.conversationWorkspace},delegatedBy:'a'}),true);
 assert.equal(Chat.apply(g,{type:'routine',runId:gr.run.runId,routine:{...routine,workspace:g.conversationWorkspace},delegatedBy:'outsider'}),false);
});

test('a group request the agents answered for themselves shows no combined reply of its own',()=>{
 const entries=[{agentId:'lyra',status:'completed',notes:'Lyra says this.'},{agentId:'forge',status:'completed',notes:'Forge says that.'}];
 const s={runs:{r:{runId:'r',team:{direct:false,partial:false,entries}}}},m={runId:'r',status:'completed',body:'**Lyra**\nLyra says this.\n\n**Forge**\nForge says that.',team:{direct:false,entries}};
 assert.deepEqual(Chat.presentation(s,m),{hidden:true},'their messages are the reply');
 assert.deepEqual(Chat.presentation(s,{...m,files:[{path:'a.md'}]}),{body:'Saved from this request:'},'but saved files still show');
 s.runs.r.team.partial=true;assert.match(Chat.presentation(s,m).body,/couldn’t finish/,'a partial failure keeps a bubble to retry from');assert.equal(Chat.presentation(s,m).hidden,undefined);
 s.runs.r.team.partial=false;assert.equal(Chat.presentation(s,{...m,status:'answering'}).hidden,undefined,'while it is running the progress shows');
 assert.equal(Chat.presentation(s,{...m,status:'failed'}).hidden,undefined,'a failure is shown');
 s.runs.r.team.direct=true;assert.equal(Chat.presentation(s,m).hidden,undefined,'when no one else was needed the one agent’s answer is shown as it is');
 s.runs.r.team={direct:false,entries:[{agentId:'lyra',status:'failed',error:'x'}]};assert.equal(Chat.presentation(s,m).hidden,undefined,'with nothing from anyone, nothing is hidden');
 assert.equal(Chat.presentation({runs:{}},{runId:'zz',body:'Plain reply'}).body,'Plain reply');
});

test('a group reply keeps up to six members’ work, so nobody named in the request drops out',()=>{
 const people=['a','b','c','d','e','f','g'],s={...seed(),agents:people.map(id=>({id,name:id.toUpperCase(),role:'R',description:'D'})),groups:[{id:'team',name:'Team',members:people}],drafts:{team:'@everyone go'}};
 const r=Chat.begin(s,'team');Chat.apply(s,{runId:r.run.runId,status:'answering',team:{phase:'working',leadId:'a',entries:people.map(agentId=>({agentId,status:'working'}))}});
 assert.deepEqual(s.messages.team[1].team.entries.map(e=>e.agentId),['a','b','c','d','e','f']);
});
test('a reply that saved a routine but ended with no text is a finished reply, not "No answer came back"',()=>{
 const s=seed(),r=Chat.begin(s,'a'),routine={id:'saved',workspace:s.conversationWorkspace,agentId:'a',title:'Morning review',nextRun:'2026-10-17T16:00:00Z',status:'active'};
 Chat.apply(s,{type:'routine',runId:r.run.runId,routine});
 Chat.apply(s,{runId:r.run.runId,status:'completed',text:''});
 const m=s.messages.a[1];
 assert.notEqual(m.status,'failed','a retry would save the routine twice');assert.ok(!m.error,'no error is shown');assert.equal(m.routines.length,1);
});
test('a task the reply started says which account it uses: only a real address, for an agent in this chat, and it never finishes the reply',()=>{
 const s=seed(),r=Chat.begin(s,'a'),task={id:'task-1',title:'Check my calendar',account:'craviott@usc.edu',agentId:'a'};
 assert.equal(Chat.apply(s,{type:'task',runId:r.run.runId,task:{...task,account:'not an address'}}),false);
 assert.equal(Chat.apply(s,{type:'task',runId:r.run.runId,task:{...task,agentId:'b'}}),false,'another agent’s task is not this reply’s');
 assert.equal(Chat.apply(s,{type:'task',runId:'unknown',task}),false);
 assert.equal(Chat.apply(s,{type:'task',runId:r.run.runId,task}),true);
 assert.deepEqual(s.messages.a[1].tasks,[{id:'task-1',title:'Check my calendar',account:'craviott@usc.edu'}]);assert.equal(r.run.status,'starting');
 Chat.apply(s,{type:'task',runId:r.run.runId,task:{...task,account:'me@gmail.com'}});
 assert.equal(s.messages.a[1].tasks.length,1);assert.equal(s.messages.a[1].tasks[0].account,'me@gmail.com','the same task is updated in place');
 Chat.apply(s,{runId:r.run.runId,status:'completed',text:''});
 assert.equal(s.messages.a[1].status,'completed','a reply whose only content is the started task is not an empty answer');
 const g=grouped(),gr=Chat.begin(g,'team');
 assert.equal(Chat.apply(g,{type:'task',runId:gr.run.runId,task:{...task,agentId:'b'},delegatedBy:'b'}),true,'a member’s task in a group reply');
 assert.equal(Chat.apply(g,{type:'task',runId:gr.run.runId,task:{...task,agentId:'outsider'}}),false);
});

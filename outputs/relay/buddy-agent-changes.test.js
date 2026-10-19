const {test}=require('node:test'),assert=require('node:assert/strict'),C=require('./buddy-agent-changes');
const esc=s=>String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const make=()=>({conversationWorkspace:'w',agents:[{id:'a',name:'Sage',role:'Helper',description:'Help.',avatarShape:'sphere',avatarColor:'blue',tools:{web:true,projectFiles:true,desktop:false}},{id:'b',name:'Mia',role:'Helper',description:'Help.',tools:{}}],hiddenAgents:[]});
const change=(o)=>({id:'c'+(o.seq||1),agentId:'a',status:'applied',seq:1,...o});

test('changes the app recorded are carried into the page state, and carrying them twice changes nothing more',()=>{
 const state=make();
 const first=C.merge(state,[change({field:'name',old:'Sage',new:'Scout'}),change({field:'avatarColor',old:'blue',new:'gold',seq:2}),change({field:'tools.desktop',old:false,new:true,seq:3}),change({field:'hidden',old:false,new:true,seq:4})]);
 assert.equal(first.changed,true);assert.deepEqual(first.ids,['c1','c2','c3','c4']);
 assert.equal(state.agents[0].name,'Scout');assert.equal(state.agents[0].avatarColor,'gold');assert.equal(state.agents[0].tools.desktop,true);assert.equal(state.agents[0].tools.web,true,'other tools are untouched');assert.deepEqual(state.hiddenAgents,['a']);
 const snapshot=JSON.stringify(state);
 const again=C.merge(state,[change({field:'name',old:'Sage',new:'Scout'}),change({field:'hidden',old:false,new:true,seq:4})]);
 assert.equal(again.changed,false,'nothing new to do');assert.equal(JSON.stringify(state),snapshot);assert.deepEqual(again.ids,['c1','c4'],'but they are still reported as handled so they can be acknowledged');
});

test('the newest change to a setting wins, an undo arrives as a change of its own, and unfinished ones are ignored',()=>{
 const state=make();
 C.merge(state,[change({id:'late',field:'name',old:'Ranger',new:'Wren',seq:3}),change({id:'early',field:'name',old:'Sage',new:'Ranger',seq:2})]);
 assert.equal(state.agents[0].name,'Wren','applied in the order they were made, not the order they arrived');
 const undo=C.merge(state,[change({id:'back',field:'name',old:'Wren',new:'Ranger',seq:4})]);
 assert.equal(undo.changed,true);assert.equal(state.agents[0].name,'Ranger');
 const hidden=make();hidden.hiddenAgents=['a'];C.merge(hidden,[change({field:'hidden',old:true,new:false})]);assert.deepEqual(hidden.hiddenAgents,[],'showing an agent again');
 const ignored=make(),res=C.merge(ignored,[change({id:'p',field:'tools.web',old:false,new:true,status:'pending'}),change({id:'d',field:'name',old:'Sage',new:'X',status:'declined'}),change({id:'f',field:'name',old:'Sage',new:'Y',status:'failed'}),change({id:'u',field:'name',old:'Sage',new:'Z',status:'undone'})]);
 assert.equal(res.changed,false);assert.equal(ignored.agents[0].name,'Sage');assert.equal(ignored.agents[0].tools.web,true,'a change waiting for the person’s OK is never carried into anything');
});

test('only the page’s own fields are carried, and only into agents that exist',()=>{
 const state=make(),res=C.merge(state,[change({id:'r',field:'role',old:'Helper',new:'Boss'}),change({id:'i',field:'instructions',old:'Help.',new:'Do all'}),change({id:'m',field:'model',old:null,new:{provider:'claude',model:'x'}}),change({id:'g',agentId:'gone',field:'name',old:'A',new:'B'}),change({id:'t',field:'tools.web',old:true,new:'yes'}),change({id:'n',field:'name',old:'Sage',new:''})]);
 assert.equal(res.changed,false);assert.equal(state.agents[0].role,'Helper','the saved profile is the app’s to change, not the page’s');assert.equal(state.agents[0].description,'Help.');assert.equal(state.agents[0].tools.web,true);assert.equal(state.agents[0].name,'Sage','an empty name is never carried');
 assert.deepEqual(res.ids,['r','i','m','g','t','n'],'every one is reported as handled, so none comes back forever');
 assert.deepEqual(C.PAGE_FIELDS,['name','avatarShape','avatarColor','hidden','tools.web','tools.projectFiles','tools.desktop']);
 assert.equal(C.merge(make(),null).changed,false);assert.equal(C.merge(make(),[null,{},{id:5}]).ids.length,0);
});

test('rules and changes are written in plain words, escaped, with only the buttons that apply',()=>{
 const rules=[{id:'r1',text:'Show <b>the CV</b> first',status:'active',approved:2,needed:3,earned:false,relaxes:true},{id:'r2',text:'Apply directly',status:'active',approved:3,needed:3,earned:true,relaxes:true},{id:'r3',text:'Always ask',status:'paused',approved:0,needed:0,earned:false,relaxes:false}];
 const html=C.rulesHTML(rules,esc);
 assert.match(html,/Show &lt;b&gt;the CV&lt;\/b&gt; first/);assert.doesNotMatch(html,/<b>/);
 assert.match(html,/2 of 3 checks approved/);assert.match(html,/Earned: continues without asking/);assert.match(html,/Paused/);
 assert.equal((html.match(/data-rule-act="reset"/g)||[]).length,2,'"Ask me again" only where there is something to start over');
 assert.match(html,/data-rule-act="resume" data-rule-id="r3"/);assert.match(html,/data-rule-act="pause" data-rule-id="r1"/);
 assert.match(C.rulesHTML([],esc),/No standing rules yet/);
 const changes=[{id:'x1',summary:'Sage’s name: “Sage” → “Scout”',status:'applied',canUndo:true,at:'2026-10-18T12:00:00Z'},{id:'x2',summary:'Sage’s browser access: off → on',status:'pending',canUndo:false},{id:'x3',summary:'old',status:'undone',canUndo:false}];
 const list=C.changesHTML(changes,esc);
 assert.match(list,/data-change-undo="x1"/);assert.doesNotMatch(list,/data-change-undo="x2"/);assert.doesNotMatch(list,/data-change-undo="x3"/);
 assert.match(list,/data-change-answer="allow" data-change-id="x2"/);assert.match(list,/Waiting for your OK/);assert.match(list,/Undone/);
 assert.match(C.changesHTML([],esc),/Nothing changed from chat yet/);
 assert.equal((C.changesHTML(Array.from({length:30},(_,i)=>({id:'i'+i,summary:'s',status:'applied'})),esc).match(/class="change-row"/g)||[]).length,10,'only the latest ten are shown');
});

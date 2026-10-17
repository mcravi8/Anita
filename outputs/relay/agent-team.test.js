'use strict';
const {test}=require('node:test');
const assert=require('node:assert/strict');
const Team=require('./agent-team.js');

const settings={name:'Sage',role:'Writing partner',description:'Draft clear copy and bring it back for review.',avatarShape:'star',avatarColor:'red',tools:{web:false,projectFiles:true},groupIds:['launch']};
function workspace(){return Team.migrate({agents:[{id:'morgan',name:'Morgan',role:'Coordinator',description:'Coordinate the team.',color:'morgan'}],groups:[{id:'launch',members:['morgan']}],messages:{morgan:[]},tasks:[]});}
function propose(state){return Team.proposeAgent(state,{proposedBy:'morgan',chat:'morgan',suggestion:settings,reason:'The project needs writing support.'});}

test('migration preserves the existing agent and separates appearance from identity',()=>{
  const state=workspace();
  assert.equal(state.agents[0].name,'Morgan');
  assert.equal(state.agents[0].avatarShape,'star');
  assert.equal(state.agents[0].avatarColor,'lilac');
  assert.deepEqual(state.proposals,[]);
});

test('an agent suggestion cannot create teammates, memberships, chats, or tasks',()=>{
  const state=workspace(),before=Team.copy(state);
  const proposal=propose(state);
  assert.equal(proposal.status,'pending');
  assert.deepEqual(state.agents,before.agents);
  assert.deepEqual(state.groups,before.groups);
  assert.deepEqual(state.messages,before.messages);
  assert.deepEqual(state.tasks,before.tasks);
  assert.throws(()=>Team.approveProposal(state,proposal.id,settings,{actor:'agent'}),/Only you/);
  assert.throws(()=>Team.createAgent(state,settings,{actor:'agent'}),/Only you/);
  assert.equal(state.agents.length,1);
  assert.equal(proposal.status,'pending');
});

test('saved edits survive persistence and retain the original suggestion',()=>{
  const state=workspace(),proposal=propose(state);
  Team.saveProposal(state,proposal.id,{...settings,name:'Cleo',avatarColor:'mint'});
  const restored=Team.migrate(Team.copy(state));
  assert.equal(restored.proposals[0].draft.name,'Cleo');
  assert.equal(restored.proposals[0].draft.avatarColor,'mint');
  assert.equal(restored.proposals[0].suggested.name,'Sage');
  assert.equal(restored.proposals[0].status,'pending');
  assert.equal(restored.agents.length,1);
});

test('approval adds the reviewed configuration exactly once to its chosen groups',()=>{
  const state=workspace(),proposal=propose(state);
  Team.saveProposal(state,proposal.id,{...settings,name:'Cleo'});
  const agent=Team.approveProposal(state,proposal.id,undefined,{actor:'user'});
  assert.equal(agent.name,'Cleo');
  assert.equal(agent.sourceProposalId,proposal.id);
  assert.deepEqual(state.messages[agent.id],[]);
  assert.equal(proposal.status,'approved');
  assert.equal(proposal.decidedBy,'you');
  assert.deepEqual(state.groups[0].members,['morgan',agent.id]);
  assert.equal(Team.approveProposal(state,proposal.id,undefined,{actor:'user'}),agent);
  assert.equal(state.agents.length,2);
  assert.equal(state.groups[0].members.length,2);
});

test('matching shapes remain independent and settings do not alias proposal snapshots',()=>{
  const state=workspace(),original=Team.copy(state.agents[0]),proposal=propose(state);
  const agent=Team.approveProposal(state,proposal.id,settings,{actor:'user'});
  Team.updateAgent(state,agent.id,{...settings,name:'Sage',avatarColor:'blue',tools:{web:true,projectFiles:false},description:'Plan the next project.'});
  assert.equal(agent.avatarShape,state.agents[0].avatarShape);
  assert.equal(agent.avatarColor,'blue');
  assert.deepEqual(state.agents[0],original);
  assert.equal(proposal.approved.avatarColor,'red');
  assert.equal(proposal.approved.tools.web,false);
  assert.equal(proposal.suggested.description,settings.description);
});

test('invalid approval is atomic and can be corrected without losing the proposal',()=>{
  const state=workspace(),proposal=propose(state),before=Team.copy(state);
  assert.throws(()=>Team.approveProposal(state,proposal.id,{...settings,name:'MORGAN'}),/already has this name/);
  assert.deepEqual(state,before);
  assert.throws(()=>Team.approveProposal(state,proposal.id,{...settings,groupIds:['missing']}),/no longer available/);
  assert.deepEqual(state,before);
  assert.equal(Team.approveProposal(state,proposal.id,settings).name,'Sage');
});

test('declining a proposal adds nothing and cannot later become an approval',()=>{
  const state=workspace(),proposal=propose(state),before=Team.copy(state);
  Team.declineProposal(state,proposal.id,{actor:'user'});
  assert.equal(proposal.status,'declined');
  assert.deepEqual(state.agents,before.agents);
  assert.deepEqual(state.groups,before.groups);
  assert.deepEqual(state.messages,before.messages);
  assert.throws(()=>Team.approveProposal(state,proposal.id,settings),/declined/);
});


test('old pink agents and proposal snapshots migrate to red without losing configuration or decisions',()=>{
  const state=workspace();
  state.agents[0].avatarColor='rose';
  const proposal=propose(state);
  proposal.suggested.avatarColor='rose';
  proposal.draft.avatarColor='rose';
  proposal.approved={...Team.copy(settings),avatarColor:'rose'};
  const before=Team.copy(state);
  Team.migrate(state);
  assert.equal(state.agents[0].avatarColor,'red');
  for(const key of ['suggested','draft','approved']){
    assert.deepEqual(state.proposals[0][key],{...before.proposals[0][key],avatarColor:'red'});
  }
  assert.equal(state.proposals[0].status,'pending');
  assert.deepEqual(state.messages,before.messages);
  assert.deepEqual(state.groups,before.groups);
  assert.deepEqual(Team.migrate(Team.copy(state)),state);
});

test('removed grey migrates to the new blue while existing light blue and green identities stay stable',()=>{
  const state=workspace();
  state.agents[0].avatarColor='stone';
  const proposal=propose(state);
  proposal.suggested.avatarColor='stone';
  proposal.draft.avatarColor='stone';
  proposal.approved={...Team.copy(settings),avatarColor:'stone'};
  const before=Team.copy(state);
  Team.migrate(state);
  assert.equal(state.agents[0].avatarColor,'cobalt');
  for(const key of ['suggested','draft','approved'])assert.deepEqual(state.proposals[0][key],{...before.proposals[0][key],avatarColor:'cobalt'});
  assert.equal(state.proposals[0].status,'pending');
  assert.deepEqual(state.messages,before.messages);
  assert.deepEqual(state.groups,before.groups);
  assert.deepEqual(Team.migrate(Team.copy(state)),state);
  assert.equal(Team.appearance({avatarColor:'blue'}).avatarColor,'blue');
  assert.equal(Team.appearance({avatarColor:'mint'}).avatarColor,'mint');
  assert.equal(Team.colorOptions.find(c=>c.id==='blue').name,'Light blue');
  assert.equal(Team.colorOptions.find(c=>c.id==='cobalt').name,'Blue');
  assert.equal(Team.colorOptions.find(c=>c.id==='mint').name,'Green');
});

test('all shapes share palette midtones while retaining shadows, highlights and transparent edges',()=>{
  const medians={star:.7109,pebble:.4313,cube:.5960,clover:.7597};
  const sample=(table,x)=>{const index=x*256,lower=Math.floor(index),fraction=index-lower;return table[lower]+fraction*(table[Math.min(256,lower+1)]-table[lower]);};
  assert.equal(Team.colorOptions.length,7);
  assert.ok(!Team.colorOptions.some(c=>c.id==='rose'));
  assert.ok(!Team.colorOptions.some(c=>c.id==='stone'));
  assert.ok(Team.colorOptions.some(c=>c.id==='red'));
  for(const color of Team.colorOptions){
    const base=[1,3,5].map(i=>parseInt(color.swatch.slice(i,i+2),16)/255);
    for(const shape of Team.shapeOptions){
      const tables=Team.avatarColorTables(shape.id,color.id);
      assert.equal(tables.length,3);
      tables.forEach((table,channel)=>{
        assert.equal(table.length,257);
        assert.ok(table.every(v=>v>=0&&v<=1));
        assert.ok(Math.abs(sample(table,medians[shape.id])-base[channel])<.008,`${shape.id}/${color.id} midtone`);
        assert.ok(table[0]<base[channel]);
        assert.ok(table[256]>base[channel]||base[channel]===1);
      });
      assert.equal(Team.avatarFilter(shape.id,color.id),`url(#buddy-avatar-${shape.id}-${color.id})`);
    }
  }
  const markup=Team.avatarFilterMarkup();
  assert.equal((markup.match(/<filter id=/g)||[]).length,28);
  assert.equal((markup.match(/<feFuncA type="identity"/g)||[]).length,28);
});

test('Mac app access defaults on, can be removed, and survives agent configuration and migration',()=>{
 const initial=Team.config({name:'Chief',role:'Chief of Staff',description:'Help with work.'});assert.equal(initial.tools.desktop,true);
 const configured=Team.config({...initial,tools:{...initial.tools,desktop:false}});assert.equal(configured.tools.desktop,false);
 const workspace={agents:[{...configured,id:'chief'}],groups:[],proposals:[]};Team.migrate(workspace);assert.equal(workspace.agents[0].tools.desktop,false);
});

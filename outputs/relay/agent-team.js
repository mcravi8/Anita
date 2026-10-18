/* Frontend configuration and preview proposals. Live suggestions and approval are enforced by Buddy’s native bridge. */
'use strict';
const RelayTeam = (() => {
  const shapeOptions = [
    {id:'diamond',name:'Diamond'},
    {id:'sphere',name:'Sphere'},
    {id:'hex',name:'Hex'},
    {id:'pill',name:'Pill'}
  ];
  // ink is the figure colour on a light surface, inkDark on a dark one, text the author-name colour on light.
  // buddy-figures.js draws with the same inks; a test keeps the two tables equal.
  const colorOptions = [
    {id:'lilac',name:'Lilac',ink:'#8a63d2',inkDark:'#b9a0eb',text:'#6a46b0'},
    {id:'blue',name:'Light blue',ink:'#1f9bd6',inkDark:'#74c9f2',text:'#17739e'},
    {id:'peach',name:'Peach',ink:'#e07a2c',inkDark:'#f3a45d',text:'#a3541a'},
    {id:'mint',name:'Green',ink:'#2e9a48',inkDark:'#66c975',text:'#237536'},
    {id:'red',name:'Autumn red',ink:'#b8432e',inkDark:'#e2684f',text:'#8f3020'},
    {id:'gold',name:'Yellow',ink:'#d4a300',inkDark:'#ffe02f',text:'#806300'},
    {id:'cobalt',name:'Blue',ink:'#3561d8',inkDark:'#7fa0ff',text:'#2a4db0'}
  ];
  const copy = value => JSON.parse(JSON.stringify(value));
  const uid = () => globalThis.crypto?.randomUUID?.() || `${Date.now()}-${Math.random().toString(36).slice(2)}`;
  // Saved workspaces and model suggestions may still name the original 3D shapes or the first four personas.
  const legacyShape = {star:'diamond',pebble:'sphere',cube:'hex',clover:'pill'};
  const legacy = {morgan:['diamond','lilac'],atlas:['sphere','blue'],nova:['hex','peach'],scout:['pill','mint']};
  const normalizedShapeId = id => legacyShape[id]||id;
  const normalizedColorId = id => ({rose:'red',stone:'cobalt'}[id]||id);
  function appearance(agent={}) {
    const fallback=legacy[agent.color]||legacy.morgan;
    return {
      avatarShape:shapeOptions.some(s=>s.id===normalizedShapeId(agent.avatarShape))?normalizedShapeId(agent.avatarShape):fallback[0],
      avatarColor:colorOptions.some(c=>c.id===normalizedColorId(agent.avatarColor))?normalizedColorId(agent.avatarColor):fallback[1]
    };
  }
  function config(value={}) {
    return {
      name:String(value.name||'').trim(),role:String(value.role||'').trim(),description:String(value.description||'').trim(),
      ...appearance(value),
      tools:{web:value.tools?.web!==false,projectFiles:value.tools?.projectFiles!==false,desktop:value.tools?.desktop!==false},
      groupIds:Array.isArray(value.groupIds)?[...new Set(value.groupIds.map(String))]:[]
    };
  }
  function migrate(state) {
    state.proposals=Array.isArray(state.proposals)?state.proposals:[];
    for(const agent of state.agents) {
      Object.assign(agent,appearance(agent));
      agent.tools={web:agent.tools?.web!==false,projectFiles:agent.tools?.projectFiles!==false,desktop:agent.tools?.desktop!==false};
    }
    for(const proposal of state.proposals) {
      for(const key of ['suggested','draft','approved'])if(proposal[key])Object.assign(proposal[key],appearance(proposal[key]));
    }
    return state;
  }
  function validate(state,value,excludeId) {
    const c=config(value);
    if(!c.name||!c.role||!c.description)throw new Error('Add a name, role, and instructions.');
    if(c.name.length>40||c.role.length>55||c.description.length>1500)throw new Error('Keep the name under 40 characters, role under 55, and instructions under 1,500.');
    if(state.agents.some(a=>a.id!==excludeId&&a.name.toLowerCase()===c.name.toLowerCase()))throw new Error('An agent already has this name. Choose a different name.');
    if(c.groupIds.some(id=>!state.groups.some(g=>g.id===id)))throw new Error('A selected group is no longer available. Choose another group.');
    return c;
  }
  function createAgent(state,value,{actor='user',sourceProposalId=null}={}) {
    if(actor!=='user')throw new Error('Only you can add an agent to the team.');
    const c=validate(state,value);
    const agent={id:uid(),name:c.name,role:c.role,description:c.description,avatarShape:c.avatarShape,avatarColor:c.avatarColor,tools:copy(c.tools),status:'Ready to connect',sourceProposalId,setupStatus:'pending',setupSeed:c.description};
    state.agents.push(agent);
    state.messages[agent.id]=[];
    for(const group of state.groups)if(c.groupIds.includes(group.id)&&!group.members.includes(agent.id))group.members.push(agent.id);
    return agent;
  }
  function updateAgent(state,agentId,value) {
    const agent=state.agents.find(a=>a.id===agentId);
    if(!agent)throw new Error('This agent is no longer available.');
    const c=validate(state,value,agentId);
    Object.assign(agent,{name:c.name,role:c.role,description:c.description,avatarShape:c.avatarShape,avatarColor:c.avatarColor,tools:copy(c.tools)});
    return agent;
  }
  function proposeAgent(state,{proposedBy,chat,suggestion,reason,sample=false}) {
    if(!state.agents.some(a=>a.id===proposedBy))throw new Error('The suggesting agent is no longer available.');
    if(!state.agents.some(a=>a.id===chat)&&!state.groups.some(g=>g.id===chat))throw new Error('Choose an available conversation.');
    const suggested=config(suggestion);
    if(!suggested.name||!suggested.role||!suggested.description||!String(reason||'').trim())throw new Error('A suggestion needs a name, role, instructions, and reason.');
    const proposal={id:uid(),proposedBy,chat,reason:String(reason).trim(),suggested:copy(suggested),draft:copy(suggested),sample,status:'pending',createdAt:new Date().toISOString()};
    state.proposals.push(proposal);
    // A proposal is only a record: it never creates an agent, group membership, or executable task.
    return proposal;
  }
  function saveProposal(state,proposalId,value) {
    const proposal=state.proposals.find(p=>p.id===proposalId);
    if(!proposal||proposal.status!=='pending')throw new Error('This suggestion has already been decided.');
    const c=validate(state,value);
    proposal.draft=copy(c);
    return proposal;
  }
  function approveProposal(state,proposalId,value,{actor='user'}={}) {
    if(actor!=='user')throw new Error('Only you can approve an agent suggestion.');
    const proposal=state.proposals.find(p=>p.id===proposalId);
    if(!proposal)throw new Error('This suggestion is no longer available.');
    if(proposal.status==='approved')return state.agents.find(a=>a.id===proposal.agentId);
    if(proposal.status!=='pending')throw new Error('This suggestion was declined.');
    const c=validate(state,value||proposal.draft);
    const agent=createAgent(state,c,{actor:'user',sourceProposalId:proposal.id});
    Object.assign(proposal,{draft:copy(c),approved:copy(c),status:'approved',agentId:agent.id,decidedBy:'you',decidedAt:new Date().toISOString()});
    return agent;
  }
  function declineProposal(state,proposalId,{actor='user'}={}) {
    if(actor!=='user')throw new Error('Only you can decide an agent suggestion.');
    const proposal=state.proposals.find(p=>p.id===proposalId);
    if(!proposal||proposal.status!=='pending')throw new Error('This suggestion has already been decided.');
    Object.assign(proposal,{status:'declined',decidedBy:'you',decidedAt:new Date().toISOString()});
    return proposal;
  }
  return {shapeOptions,colorOptions,legacyShape,copy,appearance,config,migrate,validate,createAgent,updateAgent,proposeAgent,saveProposal,approveProposal,declineProposal};
})();
if(typeof module!=='undefined'&&module.exports)module.exports=RelayTeam;

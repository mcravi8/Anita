/* Frontend configuration and preview proposals. Live suggestions and approval are enforced by Buddy’s native bridge. */
'use strict';
const RelayTeam = (() => {
  const shapeOptions = [
    {id:'star',name:'Star',asset:'morgan',hue:270,originalColor:'lilac'},
    {id:'pebble',name:'Pebble',asset:'atlas',hue:220,originalColor:'blue'},
    {id:'cube',name:'Cube',asset:'nova',hue:30,originalColor:'peach'},
    {id:'clover',name:'Clover',asset:'scout',hue:145,originalColor:'mint'}
  ];
  const colorOptions = [
    {id:'lilac',name:'Lilac',hue:270,swatch:'#b9a0eb',text:'#73549d'},
    {id:'blue',name:'Light blue',swatch:'#74c9f2',text:'#27789e'},
    {id:'peach',name:'Peach',hue:30,swatch:'#f3a45d',text:'#9a5c2c'},
    {id:'mint',name:'Green',swatch:'#55b964',text:'#2b7836'},
    {id:'red',name:'Autumn red',swatch:'#bf4a34',text:'#883624',ink:'#ffffff'},
    {id:'gold',name:'Yellow',swatch:'#ffe02f',text:'#806c08'},
    {id:'cobalt',name:'Blue',swatch:'#4776df',text:'#345ba6',ink:'#ffffff'}
  ];
  const copy = value => JSON.parse(JSON.stringify(value));
  const uid = () => globalThis.crypto?.randomUUID?.() || `${Date.now()}-${Math.random().toString(36).slice(2)}`;
  const legacy = {morgan:['star','lilac'],atlas:['pebble','blue'],nova:['cube','peach'],scout:['clover','mint']};
  // Every shape uses the same surface palette. These measured source-lightness
  // landmarks align the four different original materials before recoloring.
  const lightness = {
    star:[0,.2527,.4907,.5110,.5396,.6214,.7109,.7762,.8868,.9825,1],
    pebble:[0,.1458,.2712,.2830,.3002,.3534,.4313,.5392,.6749,.8764,1],
    cube:[0,.1612,.3966,.4198,.4576,.5375,.5960,.6534,.7253,.8971,1],
    clover:[0,.3508,.4721,.5399,.5726,.6572,.7597,.8282,.8983,.9678,1]
  };
  const surfaceStops = [0,.01,.02,.05,.1,.25,.5,.75,.9,.99,1];
  const normalizedColorId = id => ({rose:'red',stone:'cobalt'}[id]||id);
  const rgb = hex => [1,3,5].map(i=>parseInt(hex.slice(i,i+2),16)/255);
  function surfaceColor(colorId,stop) {
    const base=rgb((colorOptions.find(c=>c.id===normalizedColorId(colorId))||colorOptions[0]).swatch);
    if(stop<=.01){const face=rgb('#323440');return face.map(v=>v*(.38+stop*62));}
    // Shadows stay in the selected hue; glossy highlights approach white.
    const shade=stop<=.5?.58+.42*((stop-.02)/.48):1;
    const highlight=stop>.5?Math.min(.95,(stop-.5)*1.9):0;
    return base.map(v=>v*Math.max(.58,shade)*(1-highlight)+highlight);
  }
  function avatarColorTables(shapeId,colorId) {
    const source=lightness[shapeId]||lightness.star;
    const targets=surfaceStops.map(stop=>surfaceColor(colorId,stop));
    return [0,1,2].map(channel=>Array.from({length:257},(_,sample)=>{
      const value=sample/256;
      let upper=source.findIndex(level=>level>=value);
      if(upper<=0)return targets[0][channel];
      const lower=upper-1,fraction=(value-source[lower])/(source[upper]-source[lower]);
      return targets[lower][channel]+fraction*(targets[upper][channel]-targets[lower][channel]);
    }));
  }
  function avatarFilter(shapeId,colorId) {
    const a=appearance({avatarShape:shapeId,avatarColor:colorId});
    return `url(#buddy-avatar-${a.avatarShape}-${a.avatarColor})`;
  }
  function avatarFilterMarkup() {
    const filters=shapeOptions.flatMap(shape=>colorOptions.map(color=>{
      const tables=avatarColorTables(shape.id,color.id);
      return `<filter id="buddy-avatar-${shape.id}-${color.id}" color-interpolation-filters="sRGB"><feColorMatrix type="matrix" values=".2126 .7152 .0722 0 0 .2126 .7152 .0722 0 0 .2126 .7152 .0722 0 0 0 0 0 1 0"/><feComponentTransfer>${['R','G','B'].map((channel,i)=>`<feFunc${channel} type="table" tableValues="${tables[i].map(v=>v.toFixed(5)).join(' ')}"/>`).join('')}<feFuncA type="identity"/></feComponentTransfer></filter>`;
    })).join('');
    return `<svg id="buddy-avatar-filters" xmlns="http://www.w3.org/2000/svg" width="0" height="0" aria-hidden="true" style="position:absolute;pointer-events:none"><defs>${filters}</defs></svg>`;
  }
  function appearance(agent={}) {
    const fallback=legacy[agent.color]||legacy.morgan;
    return {
      avatarShape:shapeOptions.some(s=>s.id===agent.avatarShape)?agent.avatarShape:fallback[0],
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
    const agent={id:uid(),name:c.name,role:c.role,description:c.description,avatarShape:c.avatarShape,avatarColor:c.avatarColor,tools:copy(c.tools),status:'Ready to connect',sourceProposalId};
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
  return {shapeOptions,colorOptions,copy,appearance,config,migrate,validate,createAgent,updateAgent,proposeAgent,saveProposal,approveProposal,declineProposal,avatarFilter,avatarFilterMarkup,avatarColorTables};
})();
if(typeof module!=='undefined'&&module.exports)module.exports=RelayTeam;

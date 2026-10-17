(function(root){
  'use strict';
  function normalize(value={}) {
    const seen=new Set();
    const apps=(Array.isArray(value.apps)?value.apps:[]).filter(a=>a&&typeof a.id==='string'&&!seen.has(a.id)&&seen.add(a.id)).map(a=>({id:a.id,name:String(a.name||'Connected service'),available:a.available===true&&((Number(a.readToolCount)||0)+(Number(a.actionToolCount)||0))>0,readToolCount:Math.max(0,Number(a.readToolCount)||0),actionToolCount:Math.max(0,Number(a.actionToolCount)||0)}));
    const access={};
    for(const [agent,ids] of Object.entries(value.access||{}))access[agent]=Array.isArray(ids)?[...new Set(ids.filter(id=>apps.some(a=>a.id===id)))]:[];
    return {apps,access};
  }
  function setAccess(snapshot,agent,id,allowed) {
    const app=snapshot.apps.find(a=>a.id===id);
    if(!app)throw Error('This connection is no longer available. Refresh the list.');
    if(allowed&&!app.available)throw Error('This connection is unavailable.');
    const current=new Set(snapshot.access[agent]||[]);
    if(allowed)current.add(id);else current.delete(id);
    snapshot.access[agent]=[...current];
  }
  const api={normalize,setAccess};
  if(typeof module!=='undefined')module.exports=api;
  root.BuddyConnections=api;
})(typeof globalThis!=='undefined'?globalThis:this);

if(typeof document!=='undefined') {
  const connectionsState={snapshot:BuddyConnections.normalize(),loaded:false,loading:false,error:'',generation:0,agentId:null};
  function connectionName(app){return app.name==='Search Service'?'Web search':app.name;}
  function connectionSymbol(app){
    const name=app.name.toLowerCase();
    const kind=name.includes('gmail')?'inbox':name.includes('drive')?'folder':name.includes('calendar')?'tasks':name.includes('contacts')?'people':'globe';
    return `<span class="connection-mark ${kind}">${icon(kind)}</span>`;
  }
  function connectionsRow(app){
    const agents=connectionsState.agentId?[findAgent(connectionsState.agentId)].filter(Boolean):state.agents;
    const count=agents.filter(a=>connectionsState.snapshot.access[a.id]?.includes(app.id)).length;
    const status=connectionsState.error?'Couldn’t verify':app.available?'Available':'Unavailable';
    return `<button class="connection-row" data-action="connection-detail" data-id="${esc(app.id)}" ${connectionsState.loading?'disabled':''}>${connectionSymbol(app)}<span class="connection-copy"><strong>${esc(connectionName(app))}</strong><small>${count?`${count} ${count===1?'agent':'agents'} can use`:'No agent access'}</small></span><span class="connection-state ${app.available&&!connectionsState.error?'available':''}">${status}</span>${icon('chevron')}</button>`;
  }
  function connectionsBody(){
    const common=['Gmail','Google Drive','Google Calendar','Google Contacts','GitHub','Search Service'];
    const apps=connectionsState.snapshot.apps;
    const first=apps.filter(a=>common.includes(a.name)).sort((a,b)=>common.indexOf(a.name)-common.indexOf(b.name));
    const extra=apps.filter(a=>!common.includes(a.name));
    const agent=findAgent(connectionsState.agentId);
    return `<div data-connections-view="list"><p class="modal-description">${agent?`Choose what ${esc(agent.name)} can use.`:'Choose what your agents can access.'}</p>${!window.BuddyDesktop?.connections?'<div class="connections-notice">Open the Buddy Mac app to see and manage your connections.</div>':connectionsState.error?`<div class="connections-notice error" role="alert">${esc(connectionsState.error)}</div>`:connectionsState.loading?'<p class="connections-loading" role="status">Checking your connections…</p>':'<p class="connections-caption">Available connections are on for every agent. Turn off any you don’t want.</p>'}${first.map(connectionsRow).join('')}${extra.length?`<details class="connections-more"><summary>More connections <span>${extra.length}</span>${icon('down')}</summary>${extra.map(connectionsRow).join('')}</details>`:''}${connectionsState.loaded&&!apps.length?'<div class="connections-empty">No connected services found. Open ChatGPT → Plugins to connect a service, then refresh here.</div>':''}<details class="connections-more computer-connections"><summary>Files & computers${icon('down')}</summary>${[['Local files','folder'],['Desktop control','monitor'],['Cloud computer','globe']].map(([name,symbol])=>`<button class="connection-row" data-action="${name==='Local files'&&window.BuddyDesktop?.projectFiles?'project-files':name==='Desktop control'?'computer-settings':'unavailable-connection'}" data-id="${esc(name)}"><span class="connection-mark">${icon(symbol)}</span><span class="connection-copy"><strong>${name}</strong><small>${name==='Local files'&&window.BuddyDesktop?.projectFiles?'Connected folders available':name==='Desktop control'?'Manage Mac app access':'Subscription connection unavailable'}</small></span>${icon('chevron')}</button>`).join('')}</details><div class="modal-actions connections-actions">${window.BuddyDesktop?.connections?`<button class="border-button" data-action="refresh-connections" ${connectionsState.loading?'disabled':''}>${connectionsState.loading?'Checking…':'Refresh'}</button><button class="border-button" data-action="open-chatgpt">Open ChatGPT</button>`:''}<button class="primary-button" data-action="close-modal">Done${icon('check')}</button></div></div>`;
  }
  function drawConnections(){openModal(connectionsState.agentId?`${agentName(connectionsState.agentId)} · Connections`:'Connections',connectionsBody());}
  async function refreshConnections(force=false){
    if(!window.BuddyDesktop?.connections)return;
    const generation=++connectionsState.generation;
    connectionsState.loading=true;connectionsState.error='';
    if(document.querySelector('[data-connections-view="list"]'))drawConnections();
    try {
      await window.BuddyDesktop.saveState(JSON.stringify(state));
      const snapshot=await window.BuddyDesktop.connections(force);
      if(generation!==connectionsState.generation)return;
      connectionsState.snapshot=BuddyConnections.normalize(snapshot);connectionsState.loaded=true;
    }catch(error){if(generation!==connectionsState.generation)return;connectionsState.error=String(error.message||error);}
    finally{if(generation===connectionsState.generation){connectionsState.loading=false;if(document.querySelector('[data-connections-view="list"]'))drawConnections();}}
  }
  function showConnections(agentId=null){connectionsState.agentId=agentId;drawConnections();refreshConnections(false);}
  function connectionDetail(id){
    const app=connectionsState.snapshot.apps.find(a=>a.id===id);if(!app)return;
    const agents=connectionsState.agentId?[findAgent(connectionsState.agentId)].filter(Boolean):state.agents;
    const available=app.available&&!connectionsState.error&&!connectionsState.loading;
    openModal(connectionName(app),`<div data-connections-view="detail"><div class="connection-detail-heading">${connectionSymbol(app)}<span class="connection-state ${available?'available':''}">${available?'Available':'Unavailable'}</span></div><p class="modal-description">${available?'Access is on by default. Agents can read and use supported actions. Actions may ask for your review in chat. Turn access off for any agent.':'This service currently has no usable connection in Buddy. You can remove existing access below.'}</p><div class="connection-agent-list">${agents.map(a=>{const checked=connectionsState.snapshot.access[a.id]?.includes(id);return `<label class="connection-agent">${avatar(a.id)}<span><strong>${esc(a.name)}</strong><small>${esc(a.role)}</small></span><input type="checkbox" data-connection-access="${esc(id)}" data-agent-id="${esc(a.id)}" aria-label="Allow ${esc(a.name)} to use ${esc(connectionName(app))}" ${checked?'checked':''} ${!available&&!checked?'disabled':''}></label>`;}).join('')}</div><p class="connections-caption">Changes save immediately. Changing access stops that agent’s current reply.</p><p class="field-error" id="connection-access-error" role="alert"></p><div class="modal-actions"><button class="border-button" data-action="connections-back">Back</button><button class="primary-button" data-action="close-modal">Done${icon('check')}</button></div></div>`);
  }
  document.addEventListener('change',async event=>{
    const input=event.target.closest('[data-connection-access]');if(!input)return;
    const appId=input.dataset.connectionAccess,agentId=input.dataset.agentId,allowed=input.checked;
    input.disabled=true;const error=document.getElementById('connection-access-error');if(error)error.textContent='';
    try{await window.BuddyDesktop.setConnectionAccess({agentId,connectionId:appId,allowed});BuddyConnections.setAccess(connectionsState.snapshot,agentId,appId,allowed);showToast(allowed?`${agentName(agentId)} can use this connection.`:`Access removed for ${agentName(agentId)}.`);}
    catch(reason){input.checked=!allowed;if(error?.isConnected)error.textContent=String(reason.message||reason);}
    finally{if(input.isConnected)input.disabled=(!connectionsState.snapshot.apps.find(a=>a.id===appId)?.available||!!connectionsState.error)&&!input.checked;}
  });
  document.addEventListener('click',event=>{
    const button=event.target.closest('[data-action]');if(!button)return;
    switch(button.dataset.action){
      case 'connections':showConnections(button.dataset.agentId||null);break;
      case 'connection-detail':connectionDetail(button.dataset.id);break;
      case 'connections-back':drawConnections();break;
      case 'refresh-connections':refreshConnections(true);break;
      case 'open-chatgpt':window.BuddyDesktop.openChatGPT().catch(()=>showToast('Couldn’t open ChatGPT.'));break;
      case 'unavailable-connection':openModal(button.dataset.id,`<p class="modal-description">${button.dataset.id==='Local files'?'Choosing folders and coordinated file editing will be added separately.':button.dataset.id==='Desktop control'?'Buddy does not currently have a connection for controlling your desktop apps.':'Buddy has no documented connection to dots’ included cloud computers. Cloud work stays within your ChatGPT subscription; no separately hosted computer will be provisioned.'}</p><p class="connections-caption">Your ChatGPT sign-in does not automatically grant this access.</p><div class="modal-actions"><button class="border-button" data-action="connections-back">Back to connections</button><button class="primary-button" data-action="close-modal">Done${icon('check')}</button></div>`);break;
    }
  });
}

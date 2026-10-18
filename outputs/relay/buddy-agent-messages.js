(function(root){
  'use strict';
  function validRows(state,payload){
    if(payload?.workspace!==state.conversationWorkspace)return [];
    const ids=new Set(state.agents.map(a=>a.id));
    return (payload.messages||[]).filter(r=>typeof r.id==='string'&&ids.has(r.fromAgentId)&&ids.has(r.toAgentId)&&r.fromAgentId!==r.toAgentId);
  }
  const api={validRows};root.BuddyAgentMessages=api;if(typeof module!=='undefined')module.exports=api;
  if(typeof document==='undefined')return;
  let summaryWorkspace='',summaries={},scope='',rows=[],next=null,generation=0,loading=false,error='',revision='',newActivity=false;
  const native=()=>!!window.BuddyDesktop?.worker;
  const time=value=>value?new Date(value).toLocaleString([],{month:'short',day:'numeric',hour:'2-digit',minute:'2-digit'}):'';
  const status=value=>({queued:'Queued',running:'Waiting for reply',completed:'Completed',failed:'Couldn’t complete',interrupted:'Interrupted',budget:'Usage limit reached',cancelled:'Cancelled'}[value]||value);
  api.summary=id=>{
    const s=summaryWorkspace===state.conversationWorkspace?summaries[id]:null;
    return s?.count?`<button type="button" class="agent-messages-link" data-agent-messages="${esc(id)}">${icon('people')}<span>${Number(s.count)} messages with ${s.peers.length} ${s.peers.length===1?'agent':'agents'}</span>${icon('chevron')}</button>`:'';
  };
  api.accept=value=>{
    if(value.workspace!==state.conversationWorkspace)return;
    summaryWorkspace=value.workspace;summaries=value.agentMessages||{};
    document.querySelectorAll('[data-agent-message-summary]').forEach(el=>el.innerHTML=api.summary(el.dataset.agentMessageSummary));
    if(document.querySelector('[data-agent-message-panel]')&&value.agentMessageRevision&&value.agentMessageRevision!==revision&&!loading){newActivity=true;const notice=document.querySelector('[data-agent-message-new]');if(notice)notice.hidden=false;}
  };
  function bubble(agent,body,extra='',reply=false){return `<div class="agent-exchange-message ${reply?'is-reply':''}"><div class="agent-exchange-sender">${avatar(agent,true)}<strong>${esc(agentName(agent))}</strong></div><div class="reply-markdown">${BuddyMarkdown.render(body)}</div>${extra}</div>`;}
  function exchange(r){
    const question=String(r.question||''),body=String(r.body||''),detail=String(r.detail||'');
    const requested=question?bubble(r.fromAgentId,question):`<p class="agent-exchange-system">${esc(agentName(r.fromAgentId))} requested an automatic check-in.</p>`;
    const more=body&&detail&&body!==detail?`<details><summary>Details</summary><div class="reply-markdown">${BuddyMarkdown.render(detail)}</div></details>`:'';
    const reply=r.status==='completed'?(body||detail?bubble(r.toAgentId,body||detail,more,true):'<p class="agent-exchange-system">Check-in completed without a message.</p>'):'';
    return `<section class="agent-exchange" data-agent-exchange="${esc(r.id)}"><div class="agent-exchange-heading"><span>${esc(agentName(r.fromAgentId))} → ${esc(agentName(r.toAgentId))}</span><time>${esc(time(r.createdAt))}</time></div>${requested}${reply}${r.status!=='completed'?`<p class="agent-exchange-status ${['failed','interrupted'].includes(r.status)?'is-error':''}" role="status">${esc(status(r.status))}${r.error?` · ${esc(r.error)}`:''}</p>`:''}</section>`;
  }
  function draw(){
    const panel=document.querySelector('[data-agent-message-panel]');if(!panel)return;
    panel.innerHTML=`<p class="modal-description">Saved requests and replies between your agents.</p><label class="field"><span>Show messages involving</span><select aria-label="Filter agent messages" data-agent-message-filter ${loading?'disabled':''}><option value="">All agents</option>${state.agents.map(a=>`<option value="${esc(a.id)}" ${scope===a.id?'selected':''}>${esc(a.name)}</option>`).join('')}</select></label><div class="agent-message-toolbar"><button type="button" class="small-link" data-agent-message-refresh ${loading?'disabled':''}>Refresh</button><span data-agent-message-new ${newActivity?'':'hidden'}>New activity available</span></div>${error?`<p class="field-error" role="alert">${esc(error)} Your saved messages are preserved. Try Refresh.</p>`:''}${loading?'<p class="team-caption" role="status">Loading messages…</p>':''}${next?`<button type="button" class="border-button" data-agent-message-earlier ${loading?'disabled':''}>Load earlier messages</button>`:''}<div class="agent-message-history" aria-busy="${loading}">${rows.map(exchange).join('')||(!loading&&!error?'<div class="agent-messages-empty"><h3>No agent messages yet</h3><p>Check-in requests and replies will appear here when your agents communicate.</p></div>':'')}</div>`;
  }
  async function load(earlier=false){
    const token=++generation,workspace=state.conversationWorkspace;loading=true;error='';draw();
    try{
      if(!native())throw Error('Open Buddy for Mac to view agent messages.');
      const value=await BuddyDesktop.worker({operation:'team',arguments:{action:'messages',...(scope?{agentId:scope}:{}),...(earlier&&next?{before:next}:{})}});
      if(token!==generation||!document.querySelector('[data-agent-message-panel]'))return;
      if(value.workspace!==workspace||state.conversationWorkspace!==workspace)throw Error('Your workspace changed. Reopen agent messages.');
      const page=validRows(state,value),combined=earlier?[...page,...rows]:page;rows=combined.filter((r,i)=>combined.findIndex(v=>v.id===r.id)===i);next=value.nextCursor||null;revision=value.messageRevision||'';newActivity=false;
    }catch(e){if(token===generation)error=String(e.message||e);}
    finally{if(token===generation){loading=false;draw();}}
  }
  api.open=id=>{scope=id||'';rows=[];next=null;error='';newActivity=false;openDrawer('Agent messages','<div data-agent-message-panel></div>');load();};
  document.addEventListener('click',e=>{const open=e.target.closest('[data-agent-messages]');if(open){api.open(open.dataset.agentMessages);return;}if(e.target.closest('[data-agent-message-refresh]'))load();else if(e.target.closest('[data-agent-message-earlier]')&&!loading)load(true);});
  document.addEventListener('change',e=>{if(e.target.matches('[data-agent-message-filter]')){scope=e.target.value;rows=[];next=null;load();}});
})(typeof globalThis!=='undefined'?globalThis:this);

(function(root){
  'use strict';
  function validRows(state,payload){
    if(payload?.workspace!==state.conversationWorkspace)return [];
    const ids=new Set(state.agents.map(a=>a.id));
    return (payload.messages||[]).filter(r=>typeof r.id==='string'&&ids.has(r.fromAgentId)&&ids.has(r.toAgentId)&&r.fromAgentId!==r.toAgentId);
  }
  const stamp=value=>{const n=Date.parse(value||'');return Number.isFinite(n)?n:NaN;};
  function mergeTimeline(state,agent,messages,events,updateTimes={}){
    const known=new Set(state.agents.map(a=>a.id)),seen=new Set();
    const activity=(events||[]).filter(e=>e&&typeof e.id==='string'&&typeof e.exchangeId==='string'&&!seen.has(e.id)&&seen.add(e.id)&&known.has(e.fromAgentId)&&known.has(e.toAgentId)&&e.fromAgentId!==e.toAgentId&&[e.fromAgentId,e.toAgentId].includes(agent)&&Number.isFinite(stamp(e.at))).slice().sort((a,b)=>stamp(a.at)-stamp(b.at)||a.id.localeCompare(b.id));
    if(!activity.length)return messages;
    const times=messages.map(m=>stamp(m.createdAt||updateTimes[m.id]||m.teamCheckedAt||state.runs?.[m.runId]?.createdAt));
    function clock(m,anchor,backwards){
      const match=String(m.time||'').match(/^(\d{1,2}):(\d{2})(?:\s*([ap])m)?$/i);if(!match||!Number.isFinite(anchor))return anchor;
      let hour=Number(match[1]);if(match[3])hour=hour%12+(match[3].toLowerCase()==='p'?12:0);if(hour>23||Number(match[2])>59)return anchor;
      const d=new Date(anchor);d.setHours(hour,Number(match[2]),0,0);
      if(backwards&&d.getTime()-anchor>12*3600000)d.setDate(d.getDate()-1);
      if(!backwards&&anchor-d.getTime()>12*3600000)d.setDate(d.getDate()+1);
      return backwards?Math.min(d.getTime(),anchor):Math.max(d.getTime(),anchor);
    }
    let previous=NaN;for(let i=0;i<times.length;i++){if(!Number.isFinite(times[i]))times[i]=clock(messages[i],previous,false);if(Number.isFinite(times[i]))previous=times[i];}
    let following=NaN;for(let i=times.length-1;i>=0;i--){if(!Number.isFinite(times[i]))times[i]=clock(messages[i],following,true);if(Number.isFinite(times[i]))following=times[i];}
    const slots=Array.from({length:messages.length+1},()=>[]);let position=0;
    for(const e of activity){while(position<messages.length&&(!Number.isFinite(times[position])||times[position]<=stamp(e.at)))position++;slots[position].push(e);}
    const result=[];
    for(let i=0;i<slots.length;i++){
      let group;
      for(const e of slots[i]){
        if(!group||stamp(e.at)-stamp(group.endAt)>5*60000||group.count>=40){group={kind:'agent-exchange',id:'agent-activity-'+e.id,agentId:agent,count:0,peers:[],exchangeIds:[],at:e.at,endAt:e.at};result.push(group);}
        group.count++;group.endAt=e.at;const peer=e.fromAgentId===agent?e.toAgentId:e.fromAgentId;if(!group.peers.includes(peer))group.peers.push(peer);if(!group.exchangeIds.includes(e.exchangeId))group.exchangeIds.push(e.exchangeId);
      }
      if(i<messages.length)result.push(messages[i]);
    }
    return result;
  }
  const api={validRows,mergeTimeline};root.BuddyAgentMessages=api;if(typeof module!=='undefined')module.exports=api;
  if(typeof document==='undefined')return;
  let summaryWorkspace='',summaries={},updateTimes={},scope='',selected=[],rows=[],next=null,generation=0,loading=false,error='',revision='',newActivity=false;
  const native=()=>!!window.BuddyDesktop?.worker;
  const time=value=>value?new Date(value).toLocaleString([],{month:'short',day:'numeric',hour:'2-digit',minute:'2-digit'}):'';
  const status=value=>({queued:'Queued',running:'Waiting for reply',completed:'Completed',failed:'Couldn’t complete',interrupted:'Interrupted',budget:'Usage limit reached',cancelled:'Cancelled'}[value]||value);
  api.timeline=(id,messages)=>mergeTimeline(state,id,messages,summaryWorkspace===state.conversationWorkspace?summaries[id]?.events:[],updateTimes);
  api.hasTimeline=id=>api.timeline(id,[]).length>0;
  api.marker=m=>`<div class="agent-message-activity" data-agent-activity="${esc(m.id)}"><time datetime="${esc(m.at)}" title="${esc(time(m.at)+(m.at!==m.endAt?' – '+time(m.endAt):''))}">${esc(time(m.at))}</time><button type="button" class="agent-messages-link" data-agent-messages="${esc(m.agentId)}" data-agent-exchanges="${esc(JSON.stringify(m.exchangeIds))}"><span class="agent-message-count">${m.count} ${m.count===1?'message':'messages'} with</span><span class="agent-message-peers">${m.peers.map(peer=>`<span class="agent-message-peer">${avatar(peer,true)}<span>${esc(agentName(peer))}</span></span>`).join(' ')}</span>${icon('chevron')}</button></div>`;
  api.accept=value=>{
    if(value.workspace!==state.conversationWorkspace)return;
    const changed=summaryWorkspace!==value.workspace||JSON.stringify(summaries)!==JSON.stringify(value.agentMessages||{});
    summaryWorkspace=value.workspace;summaries=value.agentMessages||{};updateTimes=Object.fromEntries((value.updates||[]).map(u=>[u.id,u.at]));
    if(changed&&ui.view.kind==='chat')refreshLiveChat(ui.view.target);
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
      const value=await BuddyDesktop.worker({operation:'team',arguments:{action:'messages',...(scope?{agentId:scope}:{}),...(selected.length?{exchangeIds:selected}:{}),...(earlier&&next?{before:next}:{})}});
      if(token!==generation||!document.querySelector('[data-agent-message-panel]'))return;
      if(value.workspace!==workspace||state.conversationWorkspace!==workspace)throw Error('Your workspace changed. Reopen agent messages.');
      const page=validRows(state,value),combined=earlier?[...page,...rows]:page;rows=combined.filter((r,i)=>combined.findIndex(v=>v.id===r.id)===i);next=value.nextCursor||null;revision=value.messageRevision||'';newActivity=false;
    }catch(e){if(token===generation)error=String(e.message||e);}
    finally{if(token===generation){loading=false;draw();}}
  }
  api.open=(id,exchangeIds=[])=>{scope=id||'';selected=exchangeIds;rows=[];next=null;error='';newActivity=false;openDrawer('Agent messages','<div data-agent-message-panel></div>');load();};
  document.addEventListener('click',e=>{const open=e.target.closest('[data-agent-messages]');if(open){api.open(open.dataset.agentMessages,JSON.parse(open.dataset.agentExchanges||'[]'));return;}if(e.target.closest('[data-agent-message-refresh]'))load();else if(e.target.closest('[data-agent-message-earlier]')&&!loading)load(true);});
  document.addEventListener('change',e=>{if(e.target.matches('[data-agent-message-filter]')){scope=e.target.value;selected=[];rows=[];next=null;load();}});
})(typeof globalThis!=='undefined'?globalThis:this);

(function(root){
  'use strict';
  // A check-in that was cut short (interrupted) or dropped (cancelled) said nothing and needs nobody, so it is not part of the history; the app
  // leaves it out, and one saved by an older build is left out here too.
  const quiet=new Set(['interrupted','cancelled']);
  function validRows(state,payload){
    if(payload?.workspace!==state.conversationWorkspace)return [];
    const ids=new Set(state.agents.map(a=>a.id));
    return (payload.messages||[]).filter(r=>typeof r.id==='string'&&ids.has(r.fromAgentId)&&ids.has(r.toAgentId)&&r.fromAgentId!==r.toAgentId&&!quiet.has(r.status)&&String(r.question||'').trim());
  }
  const stamp=value=>{const n=Date.parse(value||'');return Number.isFinite(n)?n:NaN;};
  function mergeTimeline(state,agent,messages,events,updateTimes={}){
    const known=new Set(state.agents.map(a=>a.id)),seen=new Set(),team=(state.groups||[]).find(g=>g.id===agent),members=new Set(team?.members||[]);
    const activity=(events||[]).filter(e=>{
      if(!e||typeof e.id!=='string'||typeof e.exchangeId!=='string'||seen.has(e.id)||!known.has(e.fromAgentId)||!known.has(e.toAgentId)||!Number.isFinite(stamp(e.at)))return false;
      if(team?!(e.item?.kind==='team-chat-item'&&members.has(e.fromAgentId)&&members.has(e.toAgentId)):e.fromAgentId===e.toAgentId||![e.fromAgentId,e.toAgentId].includes(agent))return false;
      seen.add(e.id);return true;
    }).slice().sort((a,b)=>stamp(a.at)-stamp(b.at)||a.id.localeCompare(b.id));
    if(!activity.length)return messages;
    // A task's update in the chat has no createdAt: its time is the task's (workerUpdatedAt). Read from its clock label alone, it stuck days
    // early and every later exchange with Chief landed below the latest update.
    const times=messages.map(m=>stamp(m.createdAt||m.workerUpdatedAt||updateTimes[m.id]||m.teamCheckedAt||state.runs?.[m.runId]?.createdAt));
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
        if(e.item){result.push(e.item);group=null;continue;}
        if(!group||stamp(e.at)-stamp(group.endAt)>5*60000||group.count>=40){group={kind:'agent-exchange',id:'agent-activity-'+e.id,agentId:agent,count:0,peers:[],exchangeIds:[],at:e.at,endAt:e.at};result.push(group);}
        group.count++;group.endAt=e.at;const peer=e.fromAgentId===agent?e.toAgentId:e.fromAgentId;if(!group.peers.includes(peer))group.peers.push(peer);if(!group.exchangeIds.includes(e.exchangeId))group.exchangeIds.push(e.exchangeId);
      }
      if(i<messages.length)result.push(messages[i]);
    }
    return result;
  }
  const api={validRows,mergeTimeline};root.BuddyAgentMessages=api;if(typeof module!=='undefined')module.exports=api;
  if(typeof document==='undefined')return;
  let summaryWorkspace='',summaries={},updateTimes={},scope='',focus=[],rows=[],next=null,generation=0,loading=false,error='',revision='',newActivity=false;
  const native=()=>!!window.BuddyDesktop?.worker;
  const time=value=>value?new Date(value).toLocaleString([],{month:'short',day:'numeric',hour:'2-digit',minute:'2-digit'}):'';
  const status=value=>({queued:'Queued',running:'Waiting for reply',completed:'Completed',failed:'Couldn’t complete',interrupted:'Interrupted',budget:'Usage limit reached',cancelled:'Cancelled'}[value]||value);
  api.timeline=(id,messages)=>findGroup(id)?window.BuddyTeamChat?.timeline(id,messages)||messages:mergeTimeline(state,id,messages,summaryWorkspace===state.conversationWorkspace?summaries[id]?.events:[],updateTimes);
  api.hasTimeline=id=>findGroup(id)?window.BuddyTeamChat?.hasTimeline(id)||false:api.timeline(id,[]).length>0;
  api.marker=m=>`<div class="agent-message-activity" data-agent-activity="${esc(m.id)}"><time datetime="${esc(m.at)}" title="${esc(time(m.at)+(m.at!==m.endAt?' – '+time(m.endAt):''))}">${esc(time(m.at))}</time><button type="button" class="agent-messages-link" data-agent-messages="${esc(m.agentId)}" data-agent-exchanges="${esc(JSON.stringify(m.exchangeIds))}"><span class="agent-message-count">${m.count} ${m.count===1?'message':'messages'} with</span><span class="agent-message-peers">${m.peers.map(peer=>`<span class="agent-message-peer">${avatar(peer,true)}<span>${esc(agentName(peer))}</span></span>`).join(' ')}</span>${icon('chevron')}</button></div>`;
  api.accept=value=>{
    if(value.workspace!==state.conversationWorkspace)return;
    const changed=summaryWorkspace!==value.workspace||JSON.stringify(summaries)!==JSON.stringify(value.agentMessages||{});
    summaryWorkspace=value.workspace;summaries=value.agentMessages||{};updateTimes=Object.fromEntries((value.updates||[]).map(u=>[u.id,u.at]));
    if(changed&&ui.view.kind==='chat')refreshLiveChat(ui.view.target);
    if(document.querySelector('[data-agent-message-panel]')&&value.agentMessageRevision&&value.agentMessageRevision!==revision&&!loading){newActivity=true;const notice=document.querySelector('[data-agent-message-new]');if(notice)notice.hidden=false;}
  };
  function bubble(agent,body,extra='',reply=false,tag=''){return `<div class="agent-exchange-message ${reply?'is-reply':''}"><div class="agent-exchange-sender">${avatar(agent,true)}<strong>${esc(agentName(agent))}</strong>${tag?`<span class="agent-exchange-verdict ${tag==='Sent back'?'is-back':''}">${esc(tag)}</span>`:''}</div><div class="reply-markdown">${BuddyMarkdown.render(body)}</div>${extra}</div>`;}
  // One exchange as a short conversation, both sides: what was asked or handed in, then the reply. A question and its answer, or a result and
  // the supervisor's verdict, come from the plan's record; a check-in is a question the supervisor asked a teammate.
  const kinds={question:'Question',result:'Work handed in',checkin:'Check-in'};
  function exchange(r){
    const ask=String(r.question||''),body=String(r.body||''),detail=String(r.detail||''),kind=kinds[r.kind]||'Check-in';
    const opening=bubble(r.fromAgentId,ask);
    const more=body&&detail&&body!==detail?`<details><summary>${r.kind==='question'?'Why':'Details'}</summary><div class="reply-markdown">${BuddyMarkdown.render(detail)}</div></details>`:'';
    const tag=r.verdict==='accepted'?'Accepted':r.verdict==='sent back'?'Sent back':'';
    const reply=r.status==='completed'?(body||detail?bubble(r.toAgentId,body||detail,more,true,tag):`<p class="agent-exchange-system">${esc(agentName(r.toAgentId))} didn’t reply.</p>`):'';
    const title=r.kind==='result'&&r.title?` · ${esc(r.title)}`:'';
    return `<section class="agent-exchange${focus.includes(r.id)?' is-focused':''}" data-agent-exchange="${esc(r.id)}"><div class="agent-exchange-heading"><span>${kind}${title}</span><time>${esc(time(r.createdAt))}</time></div>${opening}${reply}${r.status!=='completed'?`<p class="agent-exchange-status ${['failed','interrupted'].includes(r.status)?'is-error':''}" role="status">${esc(status(r.status))}${r.error?` · ${esc(r.error)}`:''}</p>`:''}</section>`;
  }
  // The history of the agent whose chat this is: everyone it talked with, oldest first. Opened from a "3 messages with Chief" marker, it shows
  // the same history and brings those messages into view.
  function draw(){
    const panel=document.querySelector('[data-agent-message-panel]');if(!panel)return;
    const name=scope?agentName(scope):'';
    panel.innerHTML=`<p class="modal-description">${name?`What ${esc(name)} and its teammates said to each other: questions and answers, work handed in and the replies, and check-ins.`:'What your agents said to each other.'}</p><div class="agent-message-toolbar"><button type="button" class="small-link" data-agent-message-refresh ${loading?'disabled':''}>Refresh</button><span data-agent-message-new ${newActivity?'':'hidden'}>New activity available</span></div>${error?`<p class="field-error" role="alert">${esc(error)} Your saved messages are preserved. Try Refresh.</p>`:''}${loading?'<p class="team-caption" role="status">Loading messages…</p>':''}${next?`<button type="button" class="border-button" data-agent-message-earlier ${loading?'disabled':''}>Load earlier messages</button>`:''}<div class="agent-message-history" aria-busy="${loading}">${rows.map(exchange).join('')||(!loading&&!error?`<div class="agent-messages-empty"><h3>No messages yet</h3><p>${name?`When ${esc(name)} and a teammate talk, it shows here.`:'When your agents talk to each other, it shows here.'}</p></div>`:'')}</div>`;
    if(loading||!rows.length)return;
    const target=panel.querySelector('.agent-exchange.is-focused')||[...panel.querySelectorAll('.agent-exchange')].pop();
    target?.scrollIntoView?.({block:target.classList.contains('is-focused')?'start':'end'});
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
    // The messages a marker was opened for may be older than the latest page: earlier pages load until they are in view.
    if(token===generation&&!error&&next&&focus.length&&!focus.some(id=>rows.some(r=>r.id===id))&&earlierPages++<10)load(true);
  }
  let earlierPages=0;
  // Opened from a chat: that agent's history, with no choice of whom to show. A group's or an unknown id shows everyone's.
  api.open=(id,exchangeIds=[])=>{scope=state.agents.some(a=>a.id===id)?id:'';focus=Array.isArray(exchangeIds)?exchangeIds:[];rows=[];next=null;error='';newActivity=false;earlierPages=0;openDrawer(scope?`${agentName(scope)} and teammates`:'Agent messages','<div data-agent-message-panel></div>');load();};
  document.addEventListener('click',e=>{const open=e.target.closest('[data-agent-messages]');if(open){api.open(open.dataset.agentMessages,JSON.parse(open.dataset.agentExchanges||'[]'));return;}if(e.target.closest('[data-agent-message-refresh]'))load();else if(e.target.closest('[data-agent-message-earlier]')&&!loading)load(true);});
})(typeof globalThis!=='undefined'?globalThis:this);

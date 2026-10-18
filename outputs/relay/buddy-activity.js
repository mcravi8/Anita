(function(root){
  'use strict';
  const needs=new Set(['waiting_review','waiting_user','failed','interrupted']);
  function collect(state,worker={},team={}){
    const agents=new Set((state.agents||[]).map(a=>a.id)),groups=new Set((state.groups||[]).map(g=>g.id)),items=[];
    const add=item=>items.push({...item,unread:state.activitySeen?.[item.id]!==true});
    const tasks=worker.workspace===state.conversationWorkspace?(worker.tasks||[]):[];
    for(const t of tasks){
      if(t.workspace&&t.workspace!==state.conversationWorkspace||!agents.has(t.agentId)||!needs.has(t.status)&&t.status!=='completed')continue;
      add({id:`task:${t.id}:${t.attempt||0}:${t.status}:${t.attentionKey||''}`,kind:needs.has(t.status)?'needs':'finished',title:t.title||'Agent task',agentId:t.agentId,at:t.updatedAt||t.createdAt,taskId:t.id});
    }
    if(worker.workspace===state.conversationWorkspace){
      const issues=new Map();
      for(const r of worker.routines||[]){if(r.status!=='needs_attention'||!agents.has(r.agentId)||tasks.some(t=>t.id===r.lastTaskID&&needs.has(t.status)))continue;const key=r.agentId+':'+(r.lastError||r.id);if(!issues.has(key))issues.set(key,[]);issues.get(key).push(r);}
      for(const [key,rows] of issues){const r=rows[0],name=state.agents.find(a=>a.id===r.agentId)?.name||'Scheduled';add(rows.length===1?{id:`routine:${r.id}:${r.lastTaskID||''}:${r.lastError||''}`,kind:'needs',title:r.title||'Scheduled check',agentId:r.agentId,at:r.updatedAt,routineId:r.id}:{id:'routine-group:'+key,kind:'needs',title:`${name} checks need attention`,label:`${rows.length} scheduled checks`,agentId:r.agentId,action:'background-work'});}
      if(worker.scheduleError)add({id:'scheduler:'+worker.scheduleError,kind:'needs',title:'Scheduled work needs attention',action:'background-work'});
    }
    for(const g of state.groups||[]){
      const runs=Object.values(state.runs||{}).filter(r=>r.target===g.id).sort((a,b)=>String(a.createdAt||'').localeCompare(String(b.createdAt||''))),run=runs.at(-1);
      if(!run||!['completed','failed','stopped'].includes(run.status)||run.status==='stopped')continue;
      add({id:`group:${run.runId}:${run.status}:${!!run.team?.partial}`,kind:run.status==='completed'&&!run.team?.partial?'finished':'needs',title:g.name,groupId:g.id,at:run.updatedAt||run.createdAt,action:'chat',target:g.id});
    }
    for(const a of state.agents||[]){
      const run=Object.values(state.runs||{}).filter(r=>r.target===a.id).sort((a,b)=>String(a.createdAt||'').localeCompare(String(b.createdAt||''))).at(-1);
      if(!run||!['completed','failed'].includes(run.status))continue;
      const text=String(run.text||'').split('\n')[0];add({id:`reply:${run.runId}:${run.status}`,kind:run.status==='completed'?'finished':'needs',label:run.status==='completed'?'Reply ready':'Couldn’t reply',title:text.length>90?text.slice(0,87)+'…':text||'Agent reply',agentId:a.id,at:run.updatedAt||run.createdAt,action:'chat',target:a.id});
    }
    const latest=new Map();
    if(team.workspace===state.conversationWorkspace)for(const c of team.checks||[])if(agents.has(c.agentId))latest.set(c.agentId+':'+c.kind,c);
    for(const c of latest.values())if(['failed','interrupted','budget'].includes(c.status))add({id:`check:${c.id}:${c.status}`,kind:'needs',title:c.kind==='memory'?'Preference learning needs attention':'Team update needs attention',agentId:c.agentId,at:c.startedAt||c.createdAt,action:'team-monitor'});
    for(const p of state.teamPlans||[])if(p.status==='pending')add({id:'plan:'+p.id,kind:'needs',title:p.label||'Team suggestion',agentId:p.actorId,at:p.createdAt,planId:p.id});
    for(const p of state.proposals||[])if(p.status==='pending'&&!p.sample)add({id:'proposal:'+p.id,kind:'needs',title:p.draft?.name||'Agent suggestion',at:p.createdAt,action:'review-proposal',target:p.id});
    return items.filter(i=>!i.groupId||groups.has(i.groupId)).sort((a,b)=>(a.kind==='needs'?0:1)-(b.kind==='needs'?0:1)||String(b.at||'').localeCompare(String(a.at||'')));
  }
  function splitChats(state,entries){const hidden=new Set(state.hiddenAgents||[]);return {visible:entries.filter(e=>e.isGroup||!hidden.has(e.id)),hidden:entries.filter(e=>!e.isGroup&&hidden.has(e.id))};}
  const api={collect,splitChats};root.BuddyActivity=api;if(typeof module!=='undefined')module.exports=api;if(typeof document==='undefined')return;
  let worker={},team={},workerError='',tab='needs';
  const all=()=>collect(state,worker,team);
  const counts=()=>{const list=all();return {needs:list.filter(i=>i.kind==='needs').length,finished:list.filter(i=>i.kind==='finished'&&i.unread).length};};
  const date=value=>value&&Number.isFinite(Date.parse(value))?new Date(value).toLocaleString([],{month:'short',day:'numeric',hour:'2-digit',minute:'2-digit'}):'';
  const hidden=id=>(state.hiddenAgents||[]).includes(id);
  api.nav=()=>`<button type="button" class="icon-button activity-nav" data-activity-open aria-label="Notifications" title="Notifications">${icon('bell')}<span data-activity-count hidden></span></button>`;
  api.chatBadge=id=>`<span class="chat-activity-badge" data-chat-activity="${esc(id)}"></span>`;
  api.hideMenu=id=>`<button type="button" class="menu-row" data-hide-agent="${esc(id)}">${icon(hidden(id)?'eye':'eye-off')}<span>${hidden(id)?'Show agent in chat list':'Hide agent'}<small>${hidden(id)?'Move back above the Hidden section.':'Keep their work running in the Hidden section.'}</small></span>${icon('chevron')}</button>`;
  api.chats=(entries,row)=>{const parts=splitChats(state,entries);return parts.visible.map(row).join('')+(parts.hidden.length?`<details class="hidden-agents" ${state.hiddenAgentsOpen||ui.chatFilter?'open':''}><summary>Hidden <span>${parts.hidden.length}</span><span data-hidden-attention></span>${icon('down')}</summary>${parts.hidden.map(row).join('')}</details>`:'');};
  function paint(){
    const list=all(),count=counts();
    document.querySelectorAll('[data-activity-count]').forEach(el=>{el.textContent=count.needs+count.finished;el.hidden=!(count.needs+count.finished);el.classList.toggle('has-needs',count.needs>0);el.parentElement.setAttribute('aria-label',`Notifications: ${count.needs} need you, ${count.finished} finished`);});
    document.querySelectorAll('[data-chat-activity]').forEach(el=>{const id=el.dataset.chatActivity,n=list.filter(i=>(i.agentId===id||i.groupId===id)&&i.kind==='needs').length,f=list.filter(i=>(i.agentId===id||i.groupId===id)&&i.kind==='finished'&&i.unread).length;el.innerHTML=n?`<span class="activity-dot needs" title="${n} need you" aria-label="${n} need you">${n}</span>`:f?`<span class="activity-dot finished" title="${f} finished" aria-label="${f} finished">${icon('check')}</span>`:'';});
    const hiddenCount=list.filter(i=>hidden(i.agentId)&&i.kind==='needs').length;document.querySelectorAll('[data-hidden-attention]').forEach(el=>el.textContent=hiddenCount?`${hiddenCount} ${hiddenCount===1?'needs':'need'} you`:'');
  }
  function draw(){
    const panel=document.querySelector('[data-activity-panel]');if(!panel)return;
    const list=all(),count=counts(),shown=list.filter(i=>i.kind===tab);
    panel.innerHTML=`<div class="activity-tabs" role="tablist" aria-label="Notifications"><button type="button" id="activity-needs" role="tab" aria-controls="activity-list" aria-selected="${tab==='needs'}" data-activity-tab="needs">Needs you <span>${count.needs}</span></button><button type="button" id="activity-finished" role="tab" aria-controls="activity-list" aria-selected="${tab==='finished'}" data-activity-tab="finished">Finished${count.finished?` <span>${count.finished}</span>`:''}</button></div>${workerError?`<p class="field-error" role="status">Couldn’t refresh background work. Showing saved updates. <button type="button" class="small-link" data-activity-refresh>Try again</button></p>`:''}${tab==='finished'&&count.finished?'<button type="button" class="small-link activity-read-all" data-activity-read-all>Mark finished as read</button>':''}<div class="activity-list" id="activity-list" role="tabpanel" aria-labelledby="activity-${tab}">${shown.map(i=>`<button type="button" class="activity-item ${i.unread?'unread':''}" data-activity-id="${esc(i.id)}" ${i.taskId?`data-worker-task="${esc(i.taskId)}"`:i.routineId?`data-worker-routine="${esc(i.routineId)}"`:i.planId?`data-team-plan="${esc(i.planId)}"`:`data-action="${esc(i.action)}" ${i.target?`data-id="${esc(i.target)}"`:''}`}><span>${i.agentId&&findAgent(i.agentId)?avatar(i.agentId,true):i.groupId?groupAvatar(i.groupId,true):icon(i.kind==='needs'?'info':'check')}</span><span><strong>${esc(i.title)}</strong><small>${esc(i.agentId?agentName(i.agentId):i.groupId?'Team':'Buddy')}${i.at?` · ${esc(date(i.at))}`:''}</small><span class="activity-caption ${i.kind}">${esc(i.label||(i.kind==='needs'?'Needs you':'Finished'))}</span></span>${icon('chevron')}</button>`).join('')||`<div class="agent-messages-empty"><h3>${tab==='needs'?'Nothing needs you':'No finished work yet'}</h3><p>${tab==='needs'?'Decisions, sign-ins and work that needs attention will appear here.':'Completed tasks and team work will appear here.'}</p></div>`}</div>`;
  }
  function changed(){paint();draw();}
  api.acceptWorker=value=>{if(value.workspace!==state.conversationWorkspace)return;worker=value;workerError='';changed();};
  api.acceptTeam=value=>{if(value.workspace!==state.conversationWorkspace)return;team=value;changed();};
  api.workerError=error=>{workerError=String(error||'');changed();};
  api.open=()=>{const count=counts();tab=count.needs?'needs':'finished';openDrawer('Notifications','<div data-activity-panel></div>');draw();};
  function repaintSidebar(){const old=document.querySelector('.sidebar');if(!old)return;old.outerHTML=sidebar();bindSidebarSearch();paint();}
  document.addEventListener('click',e=>{
    if(e.target.closest('[data-activity-open]')){api.open();return;}
    const choice=e.target.closest('[data-activity-tab]');if(choice){tab=choice.dataset.activityTab;draw();document.querySelector(`[data-activity-tab="${tab}"]`)?.focus();return;}
    const hide=e.target.closest('[data-hide-agent]');if(hide){const id=hide.dataset.hideAgent;if(!findAgent(id))return;state.hiddenAgents=hidden(id)?state.hiddenAgents.filter(x=>x!==id):[...(state.hiddenAgents||[]),id];save();if(hide.closest('#bot-settings'))hide.outerHTML=api.hideMenu(id);else closeModal();repaintSidebar();showToast(hidden(id)?`${agentName(id)} moved to Hidden.`:`${agentName(id)} is back in your chats.`);return;}
    const item=e.target.closest('[data-activity-id]');if(item){state.activitySeen||={};state.activitySeen[item.dataset.activityId]=true;save();paint();}
    const chat=e.target.closest('[data-action="chat"]');if(chat){state.activitySeen||={};for(const i of all().filter(i=>i.kind==='finished'&&(i.target===chat.dataset.id||i.agentId===chat.dataset.id)))state.activitySeen[i.id]=true;save();paint();}
    if(e.target.closest('[data-activity-read-all]')){state.activitySeen||={};for(const i of all().filter(i=>i.kind==='finished'))state.activitySeen[i.id]=true;save();changed();}
    if(e.target.closest('[data-activity-refresh]'))window.BuddyWorkerUI?.refresh();
  });
  document.addEventListener('keydown',e=>{if(!e.target.matches('[data-activity-tab]')||!['ArrowLeft','ArrowRight','Home','End'].includes(e.key))return;e.preventDefault();tab=e.key==='Home'?'needs':e.key==='End'?'finished':tab==='needs'?'finished':'needs';draw();document.querySelector(`[data-activity-tab="${tab}"]`)?.focus();});
  document.addEventListener('toggle',e=>{if(e.target.matches?.('.hidden-agents')&&!ui.chatFilter){state.hiddenAgentsOpen=e.target.open;save();}},true);
  window.addEventListener('buddy-view-updated',paint);window.addEventListener('buddy-conversation',()=>setTimeout(changed,0));repaintSidebar();paint();
})(typeof globalThis!=='undefined'?globalThis:this);

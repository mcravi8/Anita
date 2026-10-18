(function(root){
  'use strict';
  const needs=new Set(['waiting_review','waiting_user','failed','interrupted']);
  function describe(error){
    const raw=String(error||'');
    if(/referenced work outside|did not include a source/.test(raw))return 'The team summary used a source reference Buddy could not verify. Retry the update.';
    if(/did not account for work/.test(raw))return 'The status update was rejected even though the task’s blocker was already reported. Retry the update.';
    if(/saved format|structured result|lacked its evidence/.test(raw))return 'The AI response could not be saved in the expected format. Retry to save the update.';
    if(/budget.*exhausted|cost is uncertain|reserved budget|usage is unconfirmed/i.test(raw))return 'The Claude allowance is used or its last usage is unconfirmed. Open the task to choose an additional allowance.';
    if(/limit|budget/i.test(raw))return 'The automatic Claude allowance has been reached. Review the usage limit before retrying.';
    if(/sign.in|private chrome/i.test(raw))return 'Sign-in is needed to continue. Open the task to finish signing in.';
    if(/reconnect|disconnected/i.test(raw))return 'The selected AI connection needs reconnecting in Settings.';
    if(/restarted|interrupted|stopped without/i.test(raw))return 'The last attempt stopped before confirming a result. Your saved work is preserved.';
    return raw.replace(/sk-[A-Za-z0-9_-]+/g,'[private credential]').replace(/\b[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\b/ig,'').slice(0,240)||'Open this item to review the problem and its recovery options.';
  }
  const linked=(r,t)=>t.id===r.lastTaskID||r.routineSeriesID&&t.routineSeriesID===r.routineSeriesID&&r.agentId===t.agentId;
  function collect(state,worker={},team={}){
    const agents=new Set((state.agents||[]).map(a=>a.id)),groups=new Set((state.groups||[]).map(g=>g.id)),items=[];
    const name=id=>(state.agents||[]).find(a=>a.id===id)?.name||'Agent';
    const add=item=>items.push({...item,unread:state.activitySeen?.[item.id]!==true});
    const tasks=worker.workspace===state.conversationWorkspace?(worker.tasks||[]):[];
    for(const t of tasks){
      if(t.workspace&&t.workspace!==state.conversationWorkspace||!agents.has(t.agentId)||!needs.has(t.status)&&t.status!=='completed')continue;
      add({id:`task:${t.id}:${t.attempt||0}:${t.status}:${t.attentionKey||''}`,kind:needs.has(t.status)?'needs':'finished',title:t.title||'Agent task',description:needs.has(t.status)?describe(t.progress):'The task finished. Open it to see the result.',agentId:t.agentId,at:t.updatedAt||t.createdAt,taskId:t.id,actionLabel:needs.has(t.status)?'Open task':'View result'});
    }
    if(worker.workspace===state.conversationWorkspace){
      const issues=new Map();
      for(const r of worker.routines||[]){if(r.status!=='needs_attention'||!agents.has(r.agentId)||tasks.some(t=>linked(r,t)&&needs.has(t.status)))continue;const key=r.agentId+':'+(r.lastError||r.id);if(!issues.has(key))issues.set(key,[]);issues.get(key).push(r);}
      for(const [key,rows] of issues){const r=rows[0];add(rows.length===1?{id:`routine:${r.id}:${r.lastTaskID||''}:${r.lastError||''}`,kind:'needs',title:r.title||'Scheduled check',description:describe(r.lastError),agentId:r.agentId,at:r.updatedAt,routineId:r.id,actionLabel:'Review schedule'}:{id:'routine-group:'+key,kind:'needs',title:`${name(r.agentId)} checks are paused`,description:'A previous run needs attention before these checks can continue.',label:`${rows.length} scheduled checks`,agentId:r.agentId,action:'background-work',actionLabel:'Review schedules'});}
      if(worker.scheduleError)add({id:'scheduler:'+worker.scheduleError,kind:'needs',title:'Scheduled work stopped',description:describe(worker.scheduleError),action:'background-work',actionLabel:'Review schedules'});
    }
    for(const g of state.groups||[]){
      const run=Object.values(state.runs||{}).filter(r=>r.target===g.id).sort((a,b)=>String(a.createdAt||'').localeCompare(String(b.createdAt||''))).at(-1);
      if(!run||!['completed','failed'].includes(run.status))continue;
      const done=run.status==='completed'&&!run.team?.partial;
      add({id:`group:${run.runId}:${run.status}:${!!run.team?.partial}`,kind:done?'finished':'needs',title:g.name,description:done?'The team’s reply is ready.':describe(run.error||'Some teammates could not finish. Open the team chat to review their results.'),groupId:g.id,at:run.updatedAt||run.createdAt,action:'chat',target:g.id,actionLabel:'Open team chat'});
    }
    for(const a of state.agents||[]){
      const run=Object.values(state.runs||{}).filter(r=>r.target===a.id).sort((a,b)=>String(a.createdAt||'').localeCompare(String(b.createdAt||''))).at(-1);
      if(!run||!['completed','failed'].includes(run.status))continue;
      const text=String(run.text||'').split('\n')[0];add({id:`reply:${run.runId}:${run.status}`,kind:run.status==='completed'?'finished':'needs',label:run.status==='completed'?'Reply ready':'Couldn’t reply',title:text.length>90?text.slice(0,87)+'…':text||'Agent reply',description:run.status==='failed'?describe(run.error):`${a.name} has replied.`,agentId:a.id,at:run.updatedAt||run.createdAt,action:'chat',target:a.id,actionLabel:'Open chat'});
    }
    const latest=new Map();
    if(team.workspace===state.conversationWorkspace)for(const c of team.checks||[])if(agents.has(c.agentId))latest.set(c.agentId+':'+c.kind,c);
    for(const c of latest.values())if(['failed','interrupted','budget'].includes(c.status))add({id:`check:${c.id}:${c.status}`,kind:'needs',title:`${name(c.agentId)} · ${c.kind==='memory'?'Saved preferences':'Team update'}`,description:describe(c.error),agentId:c.agentId,at:c.finishedAt||c.startedAt||c.createdAt,checkId:c.id,actionLabel:c.kind==='memory'?'Review preferences':'Review update'});
    for(const p of state.teamPlans||[])if(p.status==='pending')add({id:'plan:'+p.id,kind:'needs',title:p.label||'Team suggestion',description:'Review this proposed team before adding it.',agentId:p.actorId,at:p.createdAt,planId:p.id,actionLabel:'Review team'});
    for(const p of state.proposals||[])if(p.status==='pending'&&!p.sample)add({id:'proposal:'+p.id,kind:'needs',title:p.draft?.name||'Agent suggestion',description:'Review this proposed agent before adding them.',at:p.createdAt,action:'review-proposal',target:p.id,actionLabel:'Review agent'});
    return items.filter(i=>!i.groupId||groups.has(i.groupId)).sort((a,b)=>(a.kind==='needs'?0:1)-(b.kind==='needs'?0:1)||String(b.at||'').localeCompare(String(a.at||'')));
  }
  function splitChats(state,entries){const hidden=new Set(state.hiddenAgents||[]);return {visible:entries.filter(e=>e.isGroup||!hidden.has(e.id)),hidden:entries.filter(e=>!e.isGroup&&hidden.has(e.id))};}
  function markRead(state,ids,read=true){state.activitySeen||={};for(const id of ids)state.activitySeen[id]=read;}
  function unreadCounts(items){return {needs:items.filter(i=>i.kind==='needs'&&i.unread).length,finished:items.filter(i=>i.kind==='finished'&&i.unread).length};}
  const api={collect,splitChats,describe,markRead,unreadCounts};root.BuddyActivity=api;if(typeof module!=='undefined')module.exports=api;if(typeof document==='undefined')return;
  let worker={},team={},workerError='',tab='needs';
  const all=()=>collect(state,worker,team),counts=()=>unreadCounts(all());
  const date=value=>value&&Number.isFinite(Date.parse(value))?new Date(value).toLocaleString([],{month:'short',day:'numeric',hour:'2-digit',minute:'2-digit'}):'';
  const hidden=id=>(state.hiddenAgents||[]).includes(id);
  api.nav=()=>`<button type="button" class="icon-button activity-nav" data-activity-open aria-label="Notifications" title="Notifications">${icon('bell')}<span data-activity-count hidden></span></button>`;
  api.chatBadge=id=>`<span class="chat-activity-badge" data-chat-activity="${esc(id)}"></span>`;
  api.hideMenu=id=>`<button type="button" class="menu-row" data-hide-agent="${esc(id)}">${icon(hidden(id)?'eye':'eye-off')}<span>${hidden(id)?'Show agent in chat list':'Hide agent'}<small>${hidden(id)?'Move back above the Hidden section.':'Keep their work running in the Hidden section.'}</small></span>${icon('chevron')}</button>`;
  api.chats=(entries,row)=>{const parts=splitChats(state,entries);return parts.visible.map(row).join('')+(parts.hidden.length?`<details class="hidden-agents" ${state.hiddenAgentsOpen||ui.chatFilter?'open':''}><summary>Hidden <span>${parts.hidden.length}</span><span data-hidden-attention></span>${icon('down')}</summary>${parts.hidden.map(row).join('')}</details>`:'');};
  function paint(){
    const list=all(),count=counts();
    document.querySelectorAll('[data-activity-count]').forEach(el=>{el.textContent=count.needs+count.finished;el.hidden=!(count.needs+count.finished);el.classList.toggle('has-needs',count.needs>0);el.parentElement.setAttribute('aria-label',`Notifications: ${count.needs} need you, ${count.finished} finished`);});
    document.querySelectorAll('[data-chat-activity]').forEach(el=>{const id=el.dataset.chatActivity,n=list.filter(i=>(i.agentId===id||i.groupId===id)&&i.kind==='needs'&&i.unread).length,f=list.filter(i=>(i.agentId===id||i.groupId===id)&&i.kind==='finished'&&i.unread).length;el.innerHTML=n?`<span class="activity-dot needs" title="${n} unread alerts" aria-label="${n} unread alerts">${n}</span>`:f?`<span class="activity-dot finished" title="${f} finished" aria-label="${f} finished">${icon('check')}</span>`:'';});
    const hiddenCount=list.filter(i=>hidden(i.agentId)&&i.kind==='needs'&&i.unread).length;document.querySelectorAll('[data-hidden-attention]').forEach(el=>el.textContent=hiddenCount?`${hiddenCount} unread`:'');
    const workCount=list.filter(i=>i.unread&&(i.taskId||i.routineId||i.id.startsWith('routine-group:')||i.id.startsWith('scheduler:'))).length;document.querySelectorAll('[data-worker-badge]').forEach(el=>{el.textContent=workCount||'';el.hidden=!workCount;});
  }
  api.paint=paint;
  function draw(){
    const panel=document.querySelector('[data-activity-panel]');if(!panel)return;
    const focus=document.activeElement?.dataset?.activityToggle,list=all(),count=counts(),shown=list.filter(i=>i.kind===tab);
    panel.innerHTML=`<div class="activity-tabs" role="tablist" aria-label="Notifications"><button type="button" id="activity-needs" role="tab" aria-controls="activity-list" aria-selected="${tab==='needs'}" data-activity-tab="needs">Needs you${count.needs?` <span>${count.needs}</span>`:''}</button><button type="button" id="activity-finished" role="tab" aria-controls="activity-list" aria-selected="${tab==='finished'}" data-activity-tab="finished">Finished${count.finished?` <span>${count.finished}</span>`:''}</button></div><div class="activity-toolbar"><p>Badges count unread updates. Reading an alert keeps the issue here.</p>${count.needs+count.finished?'<button type="button" class="small-link" data-activity-read-all>Mark all as read</button>':''}</div>${workerError?`<p class="field-error" role="status">Couldn’t refresh background work. Showing saved updates. <button type="button" class="small-link" data-activity-refresh>Try again</button></p>`:''}<div class="activity-list" id="activity-list" role="tabpanel" aria-labelledby="activity-${tab}">${shown.map(i=>`<section class="activity-entry ${i.unread?'unread':''}"><button type="button" class="activity-item ${i.unread?'unread':''}" data-activity-id="${esc(i.id)}" ${i.taskId?`data-worker-task="${esc(i.taskId)}"`:i.routineId?`data-worker-routine="${esc(i.routineId)}"`:i.planId?`data-team-plan="${esc(i.planId)}"`:i.checkId?`data-team-open-check="${esc(i.checkId)}"`:`data-action="${esc(i.action)}" ${i.target?`data-id="${esc(i.target)}"`:''}`}><span>${i.agentId&&findAgent(i.agentId)?avatar(i.agentId,true):i.groupId?groupAvatar(i.groupId,true):icon(i.kind==='needs'?'info':'check')}</span><span><strong>${esc(i.title)}</strong><span class="activity-description">${esc(i.description)}</span><small>${esc(i.agentId?agentName(i.agentId):i.groupId?'Team':'Buddy')}${i.at?` · ${esc(date(i.at))}`:''}</small><span class="activity-caption ${i.kind}">${esc(i.actionLabel||(i.kind==='needs'?'Review':'View result'))}</span></span>${icon('chevron')}</button><div class="activity-entry-footer"><span>${i.unread?'Unread':'Read'}${!i.unread&&i.kind==='needs'?' · Still needs attention':''}</span><button type="button" class="small-link" data-activity-toggle="${esc(i.id)}">Mark as ${i.unread?'read':'unread'}</button></div></section>`).join('')||`<div class="agent-messages-empty"><h3>${tab==='needs'?'Nothing needs you':'No finished work yet'}</h3><p>${tab==='needs'?'Decisions, sign-ins and work that needs attention will appear here.':'Completed tasks and team work will appear here.'}</p></div>`}</div>`;
    if(focus)panel.querySelector(`[data-activity-toggle="${CSS.escape(focus)}"]`)?.focus();
  }
  function changed(){paint();draw();}
  api.acceptWorker=value=>{if(value.workspace!==state.conversationWorkspace)return;worker=value;workerError='';changed();};
  api.acceptTeam=value=>{if(value.workspace!==state.conversationWorkspace)return;team=value;changed();};
  api.workerError=error=>{workerError=String(error||'');changed();};
  api.open=()=>{tab=all().some(i=>i.kind==='needs')?'needs':'finished';openDrawer('Notifications','<div data-activity-panel></div>');draw();};
  function repaintSidebar(){const old=document.querySelector('.sidebar');if(!old)return;old.outerHTML=sidebar();bindSidebarSearch();paint();}
  document.addEventListener('click',e=>{
    if(e.target.closest('[data-activity-open]')){api.open();return;}
    const choice=e.target.closest('[data-activity-tab]');if(choice){tab=choice.dataset.activityTab;draw();document.querySelector(`[data-activity-tab="${tab}"]`)?.focus();return;}
    const toggle=e.target.closest('[data-activity-toggle]');if(toggle){const item=all().find(i=>i.id===toggle.dataset.activityToggle);if(item){markRead(state,[item.id],item.unread);save();changed();}return;}
    if(e.target.closest('[data-activity-read-all]')){markRead(state,all().map(i=>i.id));save();changed();return;}
    const hide=e.target.closest('[data-hide-agent]');if(hide){const id=hide.dataset.hideAgent;if(!findAgent(id))return;state.hiddenAgents=hidden(id)?state.hiddenAgents.filter(x=>x!==id):[...(state.hiddenAgents||[]),id];save();if(hide.closest('#bot-settings'))hide.outerHTML=api.hideMenu(id);else closeModal();repaintSidebar();showToast(hidden(id)?`${agentName(id)} moved to Hidden.`:`${agentName(id)} is back in your chats.`);return;}
    const item=e.target.closest('[data-activity-id]');if(item){markRead(state,[item.dataset.activityId]);save();paint();}
    const chat=e.target.closest('[data-action="chat"]');if(chat){markRead(state,all().filter(i=>i.kind==='finished'&&(i.target===chat.dataset.id||i.agentId===chat.dataset.id)).map(i=>i.id));save();paint();}
    if(e.target.closest('[data-activity-refresh]'))window.BuddyWorkerUI?.refresh();
  });
  document.addEventListener('keydown',e=>{if(!e.target.matches('[data-activity-tab]')||!['ArrowLeft','ArrowRight','Home','End'].includes(e.key))return;e.preventDefault();tab=e.key==='Home'?'needs':e.key==='End'?'finished':tab==='needs'?'finished':'needs';draw();document.querySelector(`[data-activity-tab="${tab}"]`)?.focus();});
  document.addEventListener('toggle',e=>{if(e.target.matches?.('.hidden-agents')&&!ui.chatFilter){state.hiddenAgentsOpen=e.target.open;save();}},true);
  window.addEventListener('buddy-view-updated',paint);window.addEventListener('buddy-conversation',()=>setTimeout(changed,0));repaintSidebar();paint();
})(typeof globalThis!=='undefined'?globalThis:this);

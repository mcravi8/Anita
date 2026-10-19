(function(root){
  'use strict';
  const needs=new Set(['waiting_review','waiting_user','failed','interrupted']),working=new Set(['queued','running','starting','stopping']);
  function describe(error){
    const raw=String(error||'');
    if(/referenced work outside|did not include a source/.test(raw))return 'The team summary used a source reference Buddy could not verify. Retry the update.';
    if(/did not account for work/.test(raw))return 'The status update was rejected even though the task’s blocker was already reported. Retry the update.';
    if(/saved format|structured result|lacked its evidence/.test(raw))return 'The AI response could not be saved in the expected format. Retry to save the update.';
    if(/budget.*exhausted|cost is uncertain|reserved budget|usage is unconfirmed/i.test(raw))return 'The Claude allowance is used or its last usage is unconfirmed. Open the task to choose an additional allowance.';
    if(/limit|budget/i.test(raw))return 'The automatic Claude allowance has been reached. Review the usage limit before retrying.';
    if(/sign.in|private chrome/i.test(raw))return 'Sign-in is needed to continue. Open the task to finish signing in.';
    if(/reconnect|disconnected/i.test(raw))return 'The selected AI connection needs reconnecting in Settings.';
    if(/may have been sent/.test(raw))return raw.replace(/\s+/g,' ').slice(0,240);
    if(/restarted|interrupted|stopped without/i.test(raw))return 'The last attempt stopped before confirming a result. Your saved work is preserved.';
    return raw.replace(/sk-[A-Za-z0-9_-]+/g,'[private credential]').replace(/\b[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\b/ig,'').slice(0,240)||'Open this item to review the problem and its recovery options.';
  }
  const linked=(r,t)=>t.id===r.lastTaskID||r.routineSeriesID&&t.routineSeriesID===r.routineSeriesID&&r.agentId===t.agentId;
  function collect(state,worker={},team={}){
    const agents=new Set((state.agents||[]).map(a=>a.id)),groups=new Set((state.groups||[]).map(g=>g.id)),items=[];
    const name=id=>(state.agents||[]).find(a=>a.id===id)?.name||'Agent';
    // Read and dismissed state lives with the app once it has answered; the page keeps a copy for when it cannot.
    const native=worker.workspace===state.conversationWorkspace?(worker.notifications||{}):{};
    const isRead=id=>native[id]?native[id].read===true:state.activitySeen?.[id]===true;
    const isDismissed=id=>native[id]?native[id].dismissed===true:state.activityDismissed?.[id]===true;
    const add=item=>{if(isDismissed(item.id))return;items.push({...item,unread:!isRead(item.id)});};
    const tasks=worker.workspace===state.conversationWorkspace?(worker.tasks||[]):[];
    // Once the app reports its blockers (one per cause), they are the "needs you" list for background work; before that, task states stand in.
    const useDecisions=worker.workspace===state.conversationWorkspace&&Array.isArray(worker.decisions);
    for(const t of tasks){
      // An action that may or may not have gone through is something to check, whatever state the task is in.
      if(useDecisions&&agents.has(t.agentId)&&(!t.workspace||t.workspace===state.conversationWorkspace)){
        if(t.status==='completed')add({id:`task:${t.id}:${t.attempt||0}:${t.status}:${t.attentionKey||''}`,kind:'finished',title:t.title||'Agent task',description:'The task finished. Open it to see the result.',agentId:t.agentId,at:t.updatedAt||t.createdAt,taskId:t.id,actionLabel:'View result'});
        else if(working.has(t.status))items.push({id:`working:${t.id}:${t.attempt||0}`,kind:'working',unread:false,title:t.title||'Agent task',description:String(t.progress||'Working on it.').slice(0,200),agentId:t.agentId,at:t.updatedAt||t.createdAt,taskId:t.id,actionLabel:'Open task'});
        continue;
      }
      const unsure=Number(t.unconfirmedCount)||0,asks=needs.has(t.status)||unsure>0;
      if(t.workspace&&t.workspace!==state.conversationWorkspace||!agents.has(t.agentId)||!asks&&t.status!=='completed')continue;
      add({id:`task:${t.id}:${t.attempt||0}:${t.status}:${t.attentionKey||''}${unsure?':check'+unsure:''}`,kind:asks?'needs':'finished',title:t.title||'Agent task',description:needs.has(t.status)?describe(t.progress):unsure?(unsure===1?'An action may not have gone through. Open the task to check.':`${unsure} actions may not have gone through. Open the task to check.`):'The task finished. Open it to see the result.',agentId:t.agentId,at:t.updatedAt||t.createdAt,taskId:t.id,actionLabel:needs.has(t.status)?'Open task':unsure?'Check action':'View result'});
    }
    if(useDecisions)for(const d of worker.decisions){
      if(d.agentId&&!agents.has(d.agentId))continue;
      // A change asked for in chat that waits for the person's OK, and a rule that has earned its freedom (a notice, not a request).
      if(d.kind==='confirm'){add({id:'decision:'+d.id,kind:'needs',title:d.title||'Allow this change?',description:String(d.question||'').slice(0,320),agentId:d.agentId||undefined,at:d.createdAt,changeId:d.payload?.changeId,actionLabel:'Review change'});continue;}
      if(d.kind==='notice'){add({id:'decision:'+d.id,kind:'finished',title:d.title||'Update',description:String(d.question||'').slice(0,320),agentId:d.agentId||undefined,at:d.createdAt,ruleId:d.payload?.ruleId,actionLabel:'Review rule'});continue;}
      add({id:'decision:'+d.id,kind:'needs',title:d.title||'Needs you',description:['stopped','waiting','limit'].includes(d.kind)?describe(d.question):String(d.question||'').slice(0,240),agentId:d.agentId||undefined,at:d.createdAt,taskId:d.taskId,actionLabel:d.actionLabel||'Open task'});
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
  function dismiss(state,ids,dismissed=true){state.activityDismissed||={};for(const id of ids)state.activityDismissed[id]=dismissed;}
  // Unread alerts about background work: the number on the Background work entry, which must agree with the bell and the chat badges.
  function workUnread(items){return items.filter(i=>i.unread&&(i.taskId||i.routineId||i.id.startsWith('routine-group:')||i.id.startsWith('scheduler:'))).length;}
  function unreadCounts(items){return {needs:items.filter(i=>i.kind==='needs'&&i.unread).length,finished:items.filter(i=>i.kind==='finished'&&i.unread).length};}
  const api={collect,splitChats,describe,markRead,dismiss,unreadCounts,workUnread};root.BuddyActivity=api;if(typeof module!=='undefined')module.exports=api;if(typeof document==='undefined')return;
  let worker={},team={},workerError='',tab='needs';
  // Marks alerts read, unread or dismissed. The page copy changes at once; the app's copy is the shared one and answers with the full state.
  function setState(ids,patch){
    state.activitySeen||={};state.activityDismissed||={};worker.notifications||={};
    for(const id of ids){
      if('read' in patch)state.activitySeen[id]=patch.read;
      if('dismissed' in patch)state.activityDismissed[id]=patch.dismissed;
      worker.notifications[id]={read:state.activitySeen[id]===true,dismissed:state.activityDismissed[id]===true,...(worker.notifications[id]||{}),...patch};
    }
    save();changed();
    if(!window.BuddyDesktop?.worker||worker.workspace!==state.conversationWorkspace)return;
    for(let i=0;i<ids.length;i+=400)Promise.resolve(window.BuddyDesktop.worker({operation:'notify',ids:ids.slice(i,i+400),...patch})).then(r=>{if(r?.notifications){worker.notifications=r.notifications;changed();}}).catch(()=>{});
  }
  const all=()=>collect(state,worker,team),counts=()=>unreadCounts(all());
  const date=value=>value&&Number.isFinite(Date.parse(value))?new Date(value).toLocaleString([],{month:'short',day:'numeric',hour:'2-digit',minute:'2-digit'}):'';
  const hidden=id=>(state.hiddenAgents||[]).includes(id);
  api.nav=()=>`<button type="button" class="icon-button activity-nav" data-activity-open aria-label="Notifications" title="Notifications">${icon('bell')}<span data-activity-count hidden></span></button>`;
  api.chatBadge=id=>`<span class="chat-activity-badge" data-chat-activity="${esc(id)}"></span>`;
  api.hideMenu=id=>`<button type="button" class="menu-row" data-hide-agent="${esc(id)}">${icon(hidden(id)?'eye':'eye-off')}<span>${hidden(id)?'Show agent in chat list':'Hide agent'}<small>${hidden(id)?'Move back above the Hidden section.':'Keep their work running in the Hidden section.'}</small></span>${icon('chevron')}</button>`;
  api.chats=(entries,row)=>{const parts=splitChats(state,entries);return parts.visible.map(row).join('')+(parts.hidden.length?`<details class="hidden-agents" ${state.hiddenAgentsOpen||ui.chatFilter?'open':''}><summary title="${parts.hidden.length} hidden agents" aria-label="${parts.hidden.length} hidden agents"><span class="hidden-agents-label">Hidden</span><span class="hidden-agents-count">${parts.hidden.length}</span><span data-hidden-attention></span>${icon('down')}</summary>${parts.hidden.map(row).join('')}</details>`:'');};
  function paint(){
    const list=all(),count=counts();
    document.querySelectorAll('[data-activity-count]').forEach(el=>{el.textContent=count.needs+count.finished;el.hidden=!(count.needs+count.finished);el.classList.toggle('has-needs',count.needs>0);el.parentElement.setAttribute('aria-label',`Notifications: ${count.needs} need you, ${count.finished} finished`);});
    document.querySelectorAll('[data-chat-activity]').forEach(el=>{const id=el.dataset.chatActivity,n=list.filter(i=>(i.agentId===id||i.groupId===id)&&i.kind==='needs'&&i.unread).length,f=list.filter(i=>(i.agentId===id||i.groupId===id)&&i.kind==='finished'&&i.unread).length;el.innerHTML=n?`<span class="activity-dot needs" title="${n} unread alerts" aria-label="${n} unread alerts">${n}</span>`:f?`<span class="activity-dot finished" title="${f} finished" aria-label="${f} finished">${icon('check')}</span>`:'';});
    const hiddenCount=list.filter(i=>hidden(i.agentId)&&i.kind==='needs'&&i.unread).length;document.querySelectorAll('[data-hidden-attention]').forEach(el=>el.textContent=hiddenCount?`${hiddenCount} unread`:'');
    const workCount=workUnread(list);document.querySelectorAll('[data-worker-badge]').forEach(el=>{el.textContent=workCount||'';el.hidden=!workCount;});
  }
  api.paint=paint;
  function draw(){
    const panel=document.querySelector('[data-activity-panel]');if(!panel)return;
    const focus=document.activeElement?.dataset?.activityToggle,list=all(),count=counts(),shown=list.filter(i=>i.kind===tab);
    const tabButton=(id,label,n)=>`<button type="button" id="activity-${id}" role="tab" aria-controls="activity-list" aria-selected="${tab===id}" data-activity-tab="${id}">${label}${n?` <span>${n}</span>`:''}</button>`;
    const emptyText={needs:['Nothing needs you','Decisions, sign-ins and work that needs attention will appear here.'],working:['Nothing is running','Work in progress will appear here while it runs.'],finished:['No finished work yet','Completed tasks and team work will appear here.']}[tab]||['Nothing here',''];
    panel.innerHTML=`<div class="activity-tabs" role="tablist" aria-label="Notifications">${tabButton('needs','Needs you',count.needs)}${tabButton('working','Working',list.filter(i=>i.kind==='working').length)}${tabButton('finished','Finished',count.finished)}</div><div class="activity-toolbar"><p>Badges count unread updates. Reading or dismissing an alert never approves anything, and work that still needs you stays in its task.</p>${tab!=='working'&&shown.length?`<span class="activity-toolbar-actions">${shown.some(i=>i.unread)?'<button type="button" class="small-link" data-activity-read-all>Mark all as read</button>':''}<button type="button" class="small-link" data-activity-dismiss-all>Dismiss all</button></span>`:''}</div>${workerError?`<p class="field-error" role="status">Couldn’t refresh background work. Showing saved updates. <button type="button" class="small-link" data-activity-refresh>Try again</button></p>`:''}<div class="activity-list" id="activity-list" role="tabpanel" aria-labelledby="activity-${tab}">${shown.map(i=>`<section class="activity-entry ${i.unread?'unread':''}"><button type="button" class="activity-item ${i.unread?'unread':''}" data-activity-id="${esc(i.id)}" ${i.taskId?`data-worker-task="${esc(i.taskId)}"`:i.routineId?`data-worker-routine="${esc(i.routineId)}"`:i.planId?`data-team-plan="${esc(i.planId)}"`:i.checkId?`data-team-open-check="${esc(i.checkId)}"`:i.changeId?`data-change-confirm="${esc(i.changeId)}"`:i.ruleId?`data-rule-open="${esc(i.agentId||'')}"`:`data-action="${esc(i.action)}" ${i.target?`data-id="${esc(i.target)}"`:''}`}><span>${i.agentId&&findAgent(i.agentId)?avatar(i.agentId,true):i.groupId?groupAvatar(i.groupId,true):icon(i.kind==='needs'?'info':i.kind==='working'?'clock':'check')}</span><span><strong>${esc(i.title)}</strong><span class="activity-description">${esc(i.description)}</span><small>${esc(i.agentId?agentName(i.agentId):i.groupId?'Team':'Buddy')}${i.at?` · ${esc(date(i.at))}`:''}</small><span class="activity-caption ${i.kind}">${esc(i.actionLabel||(i.kind==='needs'?'Review':'View result'))}</span></span>${icon('chevron')}</button>${i.kind==='working'?'':`<div class="activity-entry-footer"><span>${i.unread?'Unread':'Read'}${!i.unread&&i.kind==='needs'?' · Still needs attention':''}</span><span class="activity-entry-actions"><button type="button" class="small-link" data-activity-toggle="${esc(i.id)}">Mark as ${i.unread?'read':'unread'}</button><button type="button" class="small-link" data-activity-dismiss="${esc(i.id)}">Dismiss</button></span></div>`}</section>`).join('')||`<div class="agent-messages-empty"><h3>${emptyText[0]}</h3><p>${emptyText[1]}</p></div>`}</div>`;
    if(focus)panel.querySelector(`[data-activity-toggle="${CSS.escape(focus)}"]`)?.focus();
  }
  function changed(){readOpenChat();paint();draw();}
  // The page keeps its own copy of the app's answer, so marking something read here never edits what the caller handed in.
  api.acceptWorker=value=>{if(value.workspace!==state.conversationWorkspace)return;worker={...value,notifications:{...(value.notifications||{})}};workerError='';changed();};
  api.acceptTeam=value=>{if(value.workspace!==state.conversationWorkspace)return;team=value;changed();};
  api.workerError=error=>{workerError=String(error||'');changed();};
  api.open=()=>{const kinds=new Set(all().map(i=>i.kind));tab=kinds.has('needs')?'needs':kinds.has('working')?'working':'finished';openDrawer('Notifications','<div data-activity-panel></div>');draw();};
  function repaintSidebar(){const old=document.querySelector('.sidebar');if(!old)return;old.outerHTML=sidebar();bindSidebarSearch();paint();}
  document.addEventListener('click',e=>{
    if(e.target.closest('[data-activity-open]')){api.open();return;}
    const choice=e.target.closest('[data-activity-tab]');if(choice){tab=choice.dataset.activityTab;draw();document.querySelector(`[data-activity-tab="${tab}"]`)?.focus();return;}
    const toggle=e.target.closest('[data-activity-toggle]');if(toggle){const item=all().find(i=>i.id===toggle.dataset.activityToggle);if(item)setState([item.id],{read:item.unread});return;}
    if(e.target.closest('[data-activity-read-all]')){setState(all().filter(i=>i.kind===tab).map(i=>i.id),{read:true});return;}
    const dismissOne=e.target.closest('[data-activity-dismiss]');if(dismissOne){setState([dismissOne.dataset.activityDismiss],{dismissed:true});return;}
    if(e.target.closest('[data-activity-dismiss-all]')){setState(all().filter(i=>i.kind===tab).map(i=>i.id),{dismissed:true});return;}
    const hide=e.target.closest('[data-hide-agent]');if(hide){const id=hide.dataset.hideAgent;if(!findAgent(id))return;state.hiddenAgents=hidden(id)?state.hiddenAgents.filter(x=>x!==id):[...(state.hiddenAgents||[]),id];save();if(hide.closest('#bot-settings'))hide.outerHTML=api.hideMenu(id);else closeModal();repaintSidebar();showToast(hidden(id)?`${agentName(id)} moved to Hidden.`:`${agentName(id)} is back in your chats.`);return;}
    const item=e.target.closest('[data-activity-id]');if(item&&!item.dataset.activityId.startsWith('working:'))setState([item.dataset.activityId],{read:true});
    const chat=e.target.closest('[data-action="chat"]');if(chat){const ids=all().filter(i=>i.kind==='finished'&&i.unread&&(i.target===chat.dataset.id||i.agentId===chat.dataset.id)).map(i=>i.id);if(ids.length)setState(ids,{read:true});}
    if(e.target.closest('[data-activity-refresh]'))window.BuddyWorkerUI?.refresh();
  });
  document.addEventListener('keydown',e=>{if(!e.target.matches('[data-activity-tab]')||!['ArrowLeft','ArrowRight','Home','End'].includes(e.key))return;e.preventDefault();const order=['needs','working','finished'],at=order.indexOf(tab);tab=e.key==='Home'?'needs':e.key==='End'?'finished':order[(at+(e.key==='ArrowRight'?1:order.length-1))%order.length];draw();document.querySelector(`[data-activity-tab="${tab}"]`)?.focus();});
  document.addEventListener('toggle',e=>{if(e.target.matches?.('.hidden-agents')&&!ui.chatFilter){state.hiddenAgentsOpen=e.target.open;save();}},true);
  // Opening a chat is reading what it has been telling you: its unread signal goes away (the alerts stay listed, and nothing is approved).
  function readOpenChat(){
    if(ui.view?.kind!=='chat'||document.querySelector('.modal-overlay'))return;
    const id=ui.view.target,ids=all().filter(i=>i.unread&&i.kind!=='working'&&(i.agentId===id||i.groupId===id||i.target===id)).map(i=>i.id);
    if(ids.length)setState(ids,{read:true});
  }
  window.addEventListener('buddy-view-updated',()=>{readOpenChat();paint();});window.addEventListener('buddy-conversation',()=>setTimeout(changed,0));repaintSidebar();paint();
})(typeof globalThis!=='undefined'?globalThis:this);

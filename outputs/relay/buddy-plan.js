/* The plan strip: what the team is working towards (the objective, its stages and their tasks) and what is happening right now, in one line
   above the composer of the team's chat, or of the supervisor's own chat. It reads the plan summary in the worker's status reply. The only
   things it sends are the person's own taps: get a stage done, or stop. Notices the plan marks for the chat (a stage authorized, a stage
   report) are added to that chat, once each. */
(function(root){
  'use strict';
  const esc=value=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const stagesOf=plan=>Array.isArray(plan?.stages)?plan.stages:[];
  const tasksOf=stage=>Array.isArray(stage?.tasks)?stage.tasks:[];
  const allTasks=plan=>stagesOf(plan).flatMap(tasksOf);
  const finished=t=>['done','waived'].includes(t?.status);
  const scopeActive=plan=>plan?.scope?.status==='active';
  const nameOf=(names,id)=>(typeof names==='function'?names(id):names?.[id])||'';
  const short=(text,n)=>{const t=String(text||'').trim().replace(/\s+/g,' ');return t.length>n?t.slice(0,n-1).trimEnd()+'…':t;};
  const quoted=title=>`“${short(title||'a task',70)}”`;
  const clock=at=>{const t=Date.parse(at||'');return Number.isFinite(t)?new Date(t).toLocaleTimeString([],{hour:'2-digit',minute:'2-digit'}):'';};
  function duration(since,now){
    const ms=now-Date.parse(since||'');if(!Number.isFinite(ms)||ms<60000)return '';
    const m=Math.floor(ms/60000);return m<60?` (${m} min)`:` (${Math.floor(m/60)} h${m%60?` ${m%60} min`:''})`;
  }
  // The worker reports the plan's run state; an older reply without it is read from the plan's own status.
  const runState=plan=>plan?.run?.state||(plan?.status==='draft'?'draft':plan?.status==='active'?'working':'stage_done');
  // The stage being worked on: the first one inside the authorized scope that is not done.
  function currentStage(plan){
    const stages=stagesOf(plan),through=scopeActive(plan)?Number(plan.scope.through)||0:Infinity;
    return stages.find(s=>s.status!=='done'&&s.n<=through)||stages.filter(s=>s.status==='done').at(-1)||stages[0]||null;
  }
  const firstOpen=plan=>stagesOf(plan).find(s=>s.status!=='done')||null;
  // A stage known to have no tasks yet has not been planned, so it is never being checked.
  const unplanned=stage=>Array.isArray(stage?.tasks)&&!stage.tasks.length;
  // The authorized stage the team is on, while it has no tasks: the supervisor is planning it.
  function planningStage(plan){
    if(plan?.status!=='active'||!scopeActive(plan))return null;
    const s=currentStage(plan);
    return s&&['approved','working','review'].includes(s.status)&&s.n<=(Number(plan.scope.through)||0)&&unplanned(s)?s:null;
  }

  // The group chat shows the group's plan; an agent's own chat shows the plan that agent supervises. A live plan wins over one achieved earlier.
  function planFor(state,view,plans){
    if(view?.kind!=='chat'||!view.target||!Array.isArray(plans))return null;
    const group=(state.groups||[]).find(g=>g.id===view.target),agent=!group&&(state.agents||[]).find(a=>a.id===view.target);
    if(!group&&!agent)return null;
    const rank=p=>({active:3,draft:2,holding:1}[p.status]||0),when=p=>String(p.updatedAt||p.createdAt||'');
    return plans.filter(p=>p&&(group?p.groupId===group.id:p.supervisorId===agent.id)).reduce((best,p)=>!best||rank(p)>rank(best)||rank(p)===rank(best)&&when(p)>=when(best)?p:best,null);
  }

  const STAGES={proposed:['Not started','idle'],approved:['Up next','ready'],working:['Working','working'],review:['Being checked','review'],done:['Done','done'],superseded:['Replaced','idle']};
  function stageChip(stage){
    if(['working','review'].includes(stage?.status)&&unplanned(stage))return {label:'Planning',tone:'review'};
    const [label,tone]=STAGES[stage?.status]||STAGES.proposed;return {label,tone};
  }
  // What the agent is doing according to the pulse, as far as it concerns this task: busy with another task means this one waits its turn.
  function liveState(task,pulse){
    const p=pulse?.agents?.[task?.assignee];if(!p)return '';
    if(p.taskId&&task.workerTaskId&&p.taskId!==task.workerTaskId)return task.status==='dispatched'?'queued':'';
    return p.state||'';
  }
  const isRetrying=(task,pulse)=>task.blockedOn==='retry'||liveState(task,pulse)==='retrying';
  function taskChip(task,pulse,supervisor='Chief'){
    const live=liveState(task,pulse);
    switch(task?.status){
      case 'done':return {label:'Done',tone:'done'};
      case 'waived':return {label:'Skipped',tone:'idle'};
      case 'review':return {label:'Being reviewed',tone:'review'};
      case 'blocked':return task.blockedOn==='user'?{label:'Needs you',tone:'needs'}:task.blockedOn==='retry'?{label:'Retrying',tone:'retry'}:{label:`With ${supervisor}`,tone:'review'};
      case 'dispatched':
        if(isRetrying(task,pulse))return {label:'Retrying',tone:'retry'};
        if(live==='needs_you'||task.blockedOn==='user')return {label:'Needs you',tone:'needs'};
        if(live==='with_supervisor')return {label:`Asking ${supervisor}`,tone:'review'};
        if(live==='queued'||!live&&task.workerStatus==='queued')return {label:'Queued',tone:'ready'};
        return {label:'Working',tone:'working'};
      case 'ready':return {label:'Ready',tone:'ready'};
      default:return {label:'Waiting',tone:'idle'};
    }
  }
  // What waits for the person: an open question Chief escalated, then any task held for them.
  function needsList(plan,names){
    const out=[];
    for(const n of Array.isArray(plan?.notices)?plan.notices:[])if(n?.kind==='escalation'&&(n.status||'open')==='open'&&String(n.text||'').trim())out.push(short(n.text,110));
    for(const t of allTasks(plan))if(t.blockedOn==='user'&&!finished(t))out.push(`${quoted(t.title)}${nameOf(names,t.assignee)?` (${nameOf(names,t.assignee)})`:''}`);
    return out;
  }
  const sinceOf=(task,run)=>(Array.isArray(run?.working)?run.working:[]).find(w=>w.agentId===task.assignee&&w.title===task.title)?.since||task.updatedAt;

  // One line that says what is happening, in plain words.
  function banner(plan,pulse,names,now=Date.now()){
    if(!plan)return '';
    const state=runState(plan),run=plan.run||{},stages=stagesOf(plan),total=stages.length,sup=nameOf(names,plan.supervisorId)||'Chief';
    if(plan.status==='draft'||state==='draft')return 'Plan ready — which stage should the team get done?';
    if(state==='stopped')return 'Stopped — nothing new will start. Which stage should the team get done?';
    if(state==='stage_done'||['holding','achieved'].includes(plan.status)){
      if(total&&stages.every(s=>s.status==='done'))return total===1?'The plan is done':`All ${total} stages are done`;
      const done=stages.filter(s=>s.status==='done').at(-1);
      return done?`Stage ${done.n} is done — what next?`:'Which stage should the team get done?';
    }
    if(state==='needs_you'){const items=needsList(plan,names),n=Math.max(Number(run.needsYou)||0,items.length,1);return `Needs you (${n})${items[0]?': '+items[0]:''}`;}
    const planning=planningStage(plan);if(planning)return `${sup} is planning Stage ${planning.n}`;
    const tasks=allTasks(plan);
    if(state==='waiting_on_supervisor'){
      const review=tasks.find(t=>t.status==='review');if(review)return `${sup} is reviewing ${quoted(review.title)}`;
      const asked=tasks.find(t=>t.status==='blocked'&&t.blockedOn==='supervisor');if(asked)return `${sup} is looking at ${quoted(asked.title)}`;
      const checking=stages.find(s=>s.status==='review');return checking?`${sup} is checking that Stage ${checking.n} is done`:`${sup} is reviewing the work`;
    }
    const stage=currentStage(plan),inStage=tasksOf(stage),done=inStage.filter(finished).length;
    const dispatched=tasks.filter(t=>t.status==='dispatched'),live=dispatched.filter(t=>!isRetrying(t,pulse));
    if(state==='working'||dispatched.length){
      if(!live.length&&dispatched.length)return `Retrying ${quoted(dispatched[0].title)}`;
      const head=`Working on Stage ${stage?.n??1} of ${total} — ${done} of ${inStage.length} tasks done`,t=live[0];
      if(!t)return head;
      return `${head} — ${nameOf(names,t.assignee)||'A teammate'} is working on ${quoted(t.title)}${duration(sinceOf(t,run),now)}${live.length>1?`, plus ${live.length-1} more`:''}`;
    }
    if(state==='idle'){const at=clock(run.idleSince);return at?`Idle since ${at} — nothing queued`:'Idle — nothing queued';}
    return `Working on Stage ${stage?.n??1} of ${total}`;
  }

  // Notices the plan marks for the chat, not yet in it: each goes to the group's chat, or to the supervisor's own chat for a plan with no group.
  function noticeTarget(state,plan){
    if(plan.groupId&&(state.groups||[]).some(g=>g.id===plan.groupId))return plan.groupId;
    return plan.supervisorId&&(state.agents||[]).some(a=>a.id===plan.supervisorId)?plan.supervisorId:'';
  }
  function noticesToDeliver(state,plans){
    const out=[],agents=new Set((state.agents||[]).map(a=>a.id));
    for(const plan of Array.isArray(plans)?plans:[]){
      const target=plan&&noticeTarget(state,plan);if(!target)continue;
      const have=new Set((state.messages?.[target]||[]).map(m=>m.id)),manager=(state.groups||[]).find(g=>g.id===target)?.managedBy;
      const who=agents.has(plan.supervisorId)?plan.supervisorId:agents.has(manager)?manager:target;
      for(const n of Array.isArray(plan.notices)?plan.notices:[]){
        if(n?.chat!==true||!n.id||!String(n.text||'').trim())continue;
        const id='plan-notice-'+n.id;if(have.has(id))continue;have.add(id);
        out.push({target,plan,notice:n,message:{id,who,body:String(n.text),time:clock(n.at),...(n.at?{createdAt:n.at}:{}),live:true,status:'completed',planNotice:true,planId:plan.id,noticeKind:n.kind}});
      }
    }
    return out;
  }
  function deliverNotices(state,plans){
    const items=noticesToDeliver(state,plans);state.messages||={};
    for(const i of items)(state.messages[i.target]||=[]).push(i.message);
    return items.map(i=>i.target);
  }

  // What the worker answered to a tap. A refusal comes back as {error}, shown in its own words. A stage counts as started only when the plan in
  // the reply says its authorized scope is active and reaches that stage; anything else is reported, never shown as started.
  function replyOutcome(result,args){
    const error=result&&typeof result==='object'&&typeof result.error==='string'?result.error.trim():'';
    if(error)return {ok:false,message:error};
    const plan=result&&typeof result==='object'&&result.plan&&typeof result.plan==='object'?result.plan:null;
    if(args?.action==='authorize'){
      const scope=plan?.scope;
      if(scope?.status==='active'&&Number(scope.through)>=Number(args.through))return {ok:true,plan};
      return {ok:false,message:`The team hasn’t started: Buddy didn’t confirm the go-ahead for Stage ${Number(args.through)}. Try again in a moment.`};
    }
    return plan?{ok:true,plan}:{ok:true};
  }

  const chevron='<svg class="icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="m7 10 5 5 5-5"/></svg>';
  const TONE={draft:'ready',working:'working',waiting_on_supervisor:'review',needs_you:'needs',stage_done:'done',stopped:'idle',idle:'idle'};
  function stripHTML(plan,pulse,names,{open=false,busy=false,now=Date.now(),offline=false,error=''}={}){
    if(!plan)return '';
    const state=runState(plan),sup=nameOf(names,plan.supervisorId)||'Chief',first=firstOpen(plan),off=busy?' disabled':'';
    const choosing=!!first&&!scopeActive(plan)&&['draft','holding'].includes(plan.status),body=`plan-strip-body-${String(plan.id||'plan').replace(/[^A-Za-z0-9_-]/g,'')}`;
    const avatar=id=>root.BuddyFigures?.avatarHTML?`<span class="plan-avatar" aria-hidden="true">${root.BuddyFigures.avatarHTML({id},24)}</span>`:'';
    const chip=c=>`<span class="plan-chip ${c.tone}">${esc(c.label)}</span>`;
    const stage=s=>{
      const n=Number(s.n)||0,notDone=s.status!=='done',tasks=tasksOf(s);
      const get=choosing&&notDone&&n>=first.n?`<button type="button" class="primary-button plan-authorize" data-plan-authorize="${n}"${off}>${n===first.n?`Get stage ${n} done`:`Get stages ${first.n}–${n} done`}</button>`:'';
      return `<li class="plan-stage" data-stage-status="${esc(s.status)}"><div class="plan-stage-head"><strong>Stage ${n} · ${esc(s.title)}</strong>${chip(stageChip(s))}</div>${s.goal?`<p class="plan-stage-goal">${esc(s.goal)}</p>`:''}${Array.isArray(s.acceptance)&&s.acceptance.length?`<div class="plan-done-when"><span>Done when</span><ul>${s.acceptance.map(a=>`<li>${esc(a)}</li>`).join('')}</ul></div>`:''}${tasks.length?`<ul class="plan-tasks">${tasks.map(t=>`<li class="plan-task" data-task-status="${esc(t.status)}">${avatar(t.assignee)}<span class="plan-task-copy"><span class="plan-task-title">${esc(t.title)}</span><small>${esc(nameOf(names,t.assignee)||'Not assigned')}</small></span>${chip(taskChip(t,pulse,sup))}</li>`).join('')}</ul>`:''}${notDone?`<div class="plan-stage-actions">${get}<button type="button" class="small-link" data-plan-change="${n}" aria-label="Change stage ${n}">Change…</button></div>`:''}</li>`;
    };
    const through=scopeActive(plan)?Number(plan.scope.through)||0:0;
    const footer=through?`<div class="plan-actions"><p>The team works through Stage ${through}, then stops. ${esc(sup)} reports when it’s done and only asks you about sign-ins, money, anything sent in your name, or a change to the plan.</p><button type="button" class="border-button" data-plan-stop${off}>Stop</button></div>`:'';
    return `<section class="plan-strip tone-${TONE[state]||'idle'}${open?' open':''}${offline?' offline':''}" data-plan-strip="${esc(plan.id)}" data-plan-state="${esc(state)}" aria-label="Team plan"><button type="button" class="plan-strip-head" data-plan-toggle aria-expanded="${open}" aria-controls="${body}"><span class="plan-dot" aria-hidden="true"></span><span class="plan-banner">${esc(banner(plan,pulse,names,now))}</span>${chevron}</button>${error?`<p class="plan-error" role="alert">${esc(error)}</p>`:''}<div class="plan-strip-body" id="${body}"${open?'':' hidden'}>${offline?'<p class="plan-offline">Background work is offline, so this may be out of date.</p>':''}${plan.objective?`<p class="plan-objective"><span>Objective</span>${esc(plan.objective)}</p>`:''}${state==='needs_you'?'<button type="button" class="small-link plan-needs" data-activity-open>See what needs you</button>':''}<ol class="plan-stages">${stagesOf(plan).map(stage).join('')}</ol>${footer}</div></section>`;
  }

  const api={planFor,stageChip,taskChip,banner,noticesToDeliver,deliverNotices,stripHTML,currentStage,replyOutcome};
  root.BuddyPlan=api;if(typeof module!=='undefined')module.exports=api;
  if(typeof document==='undefined')return;

  // Folded or open is remembered per plan and state: a draft or a finished stage opens by itself (there is a choice to make), work in progress folds.
  const chosen=new Map(),shown=new WeakMap(),failures=new Map();let busy=false;
  const keyOf=plan=>`${plan.id}:${runState(plan)}`;
  const isOpen=plan=>chosen.has(keyOf(plan))?chosen.get(keyOf(plan)):['draft','holding'].includes(plan.status);
  const names=()=>Object.fromEntries((state.agents||[]).map(a=>[a.id,a.name]));
  function current(){
    const snapshot=root.BuddyWorkerUI?.snapshot?.()||{};
    return {snapshot,plans:(!snapshot.workspace||snapshot.workspace===state.conversationWorkspace)&&Array.isArray(snapshot.plans)?snapshot.plans:[]};
  }
  function focusKey(el){
    for(const name of ['data-plan-toggle','data-plan-authorize','data-plan-change','data-plan-stop'])if(el?.hasAttribute?.(name)){const v=el.getAttribute(name);return v?`[${name}="${CSS.escape(v)}"]`:`[${name}]`;}
    return null;
  }
  // Same pattern as the setup offer: the strip sits at the top of the composer area and is redrawn only when what it says changes.
  function mount(){
    const strips=[...document.querySelectorAll('.plan-strip')];
    const wrap=typeof ui!=='undefined'&&ui.view?.kind==='chat'?document.querySelector('.composer-wrap'):null;
    const {snapshot,plans}=current(),plan=wrap?planFor(state,ui.view,plans):null,old=strips.find(el=>el.parentElement===wrap);
    for(const el of strips)if(el!==old||!plan)el.remove();
    if(!plan)return;
    // A refusal stays on the strip until the next tap, or until the plan itself moves on.
    if(failures.has(plan.id)&&failures.get(plan.id).state!==keyOf(plan))failures.delete(plan.id);
    const html=stripHTML(plan,root.BuddyWorkerUI?.pulse?.(),names(),{open:isOpen(plan),busy,offline:snapshot.online===false,error:failures.get(plan.id)?.message||''});
    if(old&&shown.get(old)===html)return;
    const chat=document.getElementById('chat-body'),bottom=!!chat&&chat.scrollHeight-chat.scrollTop-chat.clientHeight<120;
    const focus=old&&old.contains(document.activeElement)?focusKey(document.activeElement):null,scroll=old?.querySelector('.plan-strip-body')?.scrollTop||0;
    const holder=document.createElement('div');holder.innerHTML=html;const next=holder.firstElementChild;shown.set(next,html);
    if(old)old.replaceWith(next);else wrap.insertAdjacentElement('afterbegin',next);
    const inner=next.querySelector('.plan-strip-body');if(inner)inner.scrollTop=scroll;
    if(focus)next.querySelector(focus)?.focus({preventScroll:true});
    if(bottom)chat.scrollTop=chat.scrollHeight;
  }
  function deliver(){
    const {plans}=current();if(!plans.length)return;
    const targets=deliverNotices(state,plans);if(!targets.length)return;
    save();for(const target of new Set(targets))refreshLiveChat(target);
  }
  function change(n){
    const input=document.getElementById('message-input');if(!input)return;
    input.value=`Stage ${n}: `+input.value.replace(/^Stage \d+:\s*/,'');
    input.dispatchEvent(new Event('input'));input.focus();input.setSelectionRange(input.value.length,input.value.length);
  }
  async function send(plan,args){
    busy=true;failures.delete(args.planId);mount();
    let outcome;
    try{outcome=replyOutcome(await root.BuddyWorkerUI.request({operation:'plan',requestId:crypto.randomUUID(),arguments:args}),args);}
    catch(e){outcome={ok:false,message:String(e?.message||e)};}
    finally{busy=false;}
    if(outcome.ok&&outcome.plan?.id){
      // Show the confirmed answer at once; the status poll that follows brings the live state.
      const plans=root.BuddyWorkerUI.snapshot()?.plans,i=Array.isArray(plans)?plans.findIndex(p=>p?.id===outcome.plan.id):-1;if(i>=0)plans[i]=outcome.plan;
    }else if(!outcome.ok){failures.set(args.planId,{message:outcome.message,state:keyOf(plan)});showToast(outcome.message);}
    await root.BuddyWorkerUI.refresh(false);
  }
  document.addEventListener('click',async e=>{
    const el=e.target.closest?.('[data-plan-toggle],[data-plan-authorize],[data-plan-change],[data-plan-stop]');if(!el)return;
    const id=el.closest('.plan-strip')?.dataset.planStrip,plan=current().plans.find(p=>p.id===id);if(!plan)return;
    if(el.hasAttribute('data-plan-toggle')){chosen.set(keyOf(plan),!isOpen(plan));mount();return;}
    if(el.hasAttribute('data-plan-change')){change(Number(el.dataset.planChange));return;}
    if(busy||el.disabled)return;
    // The tap is the person's own decision; its words are the button's.
    if(el.hasAttribute('data-plan-authorize'))await send(plan,{action:'authorize',planId:plan.id,through:Number(el.dataset.planAuthorize),quote:el.textContent.trim()});
    else if(el.hasAttribute('data-plan-stop')&&confirm('Stop this plan? Nothing new will start and work in progress is paused. You can choose a stage again later.'))await send(plan,{action:'stop',planId:plan.id});
  });
  root.addEventListener('buddy-view-updated',mount);
  root.addEventListener('buddy-worker-snapshot',()=>{deliver();mount();});
  // In a group, a plan notice is Chief's message: shown under Chief's name and figure, like each member's own message in the group.
  if(typeof root.messageHTML==='function'){
    const original=root.messageHTML;
    root.messageHTML=function(m){
      const agent=m?.planNotice&&typeof findAgent==='function'?findAgent(m.who):null;
      if(!agent||typeof findGroup!=='function'||!findGroup(ui.view?.target))return original.apply(this,arguments);
      const author=typeof authorColor==='function'?`<button type="button" class="message-author" style="${authorColor(agent)}" data-action="agent-info" data-id="${esc(agent.id)}">${esc(agent.name)}</button>`:`<strong>${esc(agent.name)}</strong>`;
      return `<div class="message bot-message team-chat-contribution plan-notice">${avatar(agent.id,true)}<div class="bot-bubble"><div class="team-chat-author">${author}<span>Team plan</span></div><div class="reply-markdown">${BuddyMarkdown.render(m.body)}</div><time>${esc(m.time||'')}</time></div></div>`;
    };
  }
})(typeof globalThis!=='undefined'?globalThis:this);

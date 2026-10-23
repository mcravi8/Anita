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
      case 'blocked':return task.blockedOn==='user'?{label:'Needs you',tone:'needs'}:task.blockedOn==='retry'?{label:'Retrying',tone:'retry'}:task.blockedOn==='paused'?{label:'Paused by you',tone:'idle'}:{label:`With ${supervisor}`,tone:'review'};
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
      // Several teammates working at once, each on its own task (the pulse says who is busy with which): name each of them, up to three.
      const busy=live.filter(x=>['working','quiet'].includes(liveState(x,pulse)));
      if(busy.length>1){
        const shown=busy.slice(0,3),rest=live.length-shown.length;
        return `${head} — ${shown.map((x,i)=>`${nameOf(names,x.assignee)||'A teammate'}${i?' on':' is working on'} ${quoted(x.title)}${duration(sinceOf(x,run),now)}`).join(', ')}${rest>0?`, plus ${rest} more`:''}`;
      }
      return `${head} — ${nameOf(names,t.assignee)||'A teammate'} is working on ${quoted(t.title)}${duration(sinceOf(t,run),now)}${live.length>1?`, plus ${live.length-1} more`:''}`;
    }
    // Only runs the person paused hold the stage: it goes on once they resume them.
    if(state==='paused'){
      const held=tasks.filter(t=>t.status==='blocked'&&t.blockedOn==='paused'),t=held[0],who=t&&nameOf(names,t.assignee);
      if(held.length>1)return `You paused ${held.length} tasks — resume them to finish Stage ${stage?.n??1}`;
      return t?`You paused ${quoted(t.title)}${who?` (${who})`:''} — resume it to finish Stage ${stage?.n??1}`:'Paused by you';
    }
    if(state==='idle'){const at=clock(run.idleSince);return at?`Idle since ${at} — nothing queued`:'Idle — nothing queued';}
    return `Working on Stage ${stage?.n??1} of ${total}`;
  }

  // What a stage's tasks saved: the file receipts on their background work's result messages (each task's worker task id is on the plan), one
  // per file, the latest save of each, newest first. A receipt without its folder or revision is not a file that can be opened.
  function stageDeliverables(state,plan,stageRef){
    const stage=stagesOf(plan).find(s=>s.id===stageRef||Number.isFinite(Number(stageRef))&&Number(s.n)===Number(stageRef));if(!stage)return [];
    const ids=new Set(tasksOf(stage).map(t=>t?.workerTaskId).filter(Boolean));if(!ids.size)return [];
    const latest=new Map(),when=f=>Date.parse(f.date||'')||0;
    for(const list of Object.values(state?.messages||{}))for(const m of Array.isArray(list)?list:[]){
      if(!m||!ids.has(m.workerTaskID)||!Array.isArray(m.files))continue;
      for(const f of m.files){
        if(!f||typeof f.folderId!=='string'||!f.folderId||typeof f.path!=='string'||!f.path||typeof f.revision!=='string')continue;
        const key=`${f.folderId}:${f.path}`,prior=latest.get(key);if(!prior||when(f)>=when(prior))latest.set(key,f);
      }
    }
    return [...latest.values()].sort((a,b)=>when(b)-when(a));
  }
  // A stage report names its stage in its references, or, for one written without them, in its first words ("Stage 2 — Build is done").
  function noticeFiles(state,plan,notice){
    if(notice?.kind!=='stage_report')return [];
    const ref=notice.refs?.stageId||Number(String(notice.text||'').match(/^\s*Stage\s+(\d+)\b/i)?.[1]);
    return ref?stageDeliverables(state,plan,ref):[];
  }
  // A stage report as the plan writes it: Chief's report, then, after an empty line, what comes next ("Next is Stage 3 — …" or "That was the
  // last stage…"). A report written as labelled lines ("Outputs: …", "Issues: …") reads as rows; anything else stays prose.
  const labelled=/^\s*([A-Z][A-Za-z ]{1,24}):\s+(\S[\s\S]*)$/;
  function splitReport(text){
    const t=String(text||'').trim(),cut=t.search(/\n\s*\n(?=\s*(?:Next is Stage \d+|That was the last stage))/);
    const report=(cut>=0?t.slice(0,cut):t).trim(),lines=report.split('\n').map(l=>l.trim()).filter(Boolean),rows=lines.map(l=>l.match(labelled)).filter(Boolean);
    const structured=rows.length>=2&&rows.length>=lines.length-1,lead=structured&&!labelled.test(lines[0])?lines[0]:'';
    return {summary:lead,rows:structured?rows.map(r=>({label:r[1].trim(),text:r[2].trim()})):[],prose:structured?'':report};
  }
  const noticeOf=(plan,message)=>(Array.isArray(plan?.notices)?plan.notices:[]).find(n=>'plan-notice-'+n?.id===message?.id)||null;
  const stageOfNotice=(plan,notice,text)=>{
    const ref=notice?.refs?.stageId,n=Number(String(text||'').match(/^\s*Stage\s+(\d+)\b/i)?.[1]);
    return stagesOf(plan).find(s=>ref?s.id===ref:Number(s.n)===n)||null;
  };
  const CATEGORY={credential:'a sign-in',money_out:'money',third_party:'something sent in your name',objective:'a change to the plan',personal_fact:'something only you know'};
  const check='<svg class="plan-card-check" viewBox="0 0 24 24" aria-hidden="true"><path d="m5 12.5 4.5 4.5L19 7.5" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"/></svg>';
  // What comes after a finished stage, said once the person has chosen: started, done, or the choice to make, with its two buttons.
  function aheadHTML(plan,stage,{busy=false}={}){
    const next=stage&&stagesOf(plan).find(s=>Number(s.n)===Number(stage.n)+1);
    if(!next)return `<div class="plan-card-foot"><span>That was the last stage of the plan.</span></div>`;
    const title=`<span class="plan-card-next"><span>Next ·</span> Stage ${Number(next.n)} — ${esc(next.title)}</span>`;
    const started=next.status==='done'?`Stage ${Number(next.n)} is done`:scopeActive(plan)&&Number(plan.scope.through)>=Number(next.n)||['approved','working','review'].includes(next.status)?`Stage ${Number(next.n)} started`:'';
    if(started)return `<div class="plan-card-foot">${title}<span class="plan-card-settled">${check}${started}</span></div>`;
    const choosing=['draft','holding'].includes(plan.status),off=busy?' disabled':'';
    return `<div class="plan-card-foot">${title}${choosing?`<span class="plan-card-actions"><button type="button" class="border-button" data-plan-change="${Number(next.n)}"${off}>Change plan</button><button type="button" class="primary-button" data-plan-authorize="${Number(next.n)}"${off}>Get stage ${Number(next.n)} done</button></span>`:''}</div>`;
  }
  // A plan notice as a card in the chat: a stage report, a question for the person, a stuck notice, or (an authorization) one status line. A
  // notice whose plan is no longer known, or of another kind, is null and stays a plain message.
  function noticeCard(plan,message,{filesHTML='',markdown=s=>`<p>${esc(s)}</p>`,busy=false,reply=null}={}){
    if(!plan||!message?.planNotice)return null;
    const kind=message.noticeKind,text=String(message.body||'').trim(),notice=noticeOf(plan,message),refs=notice?.refs||{},off=busy?' disabled':'';
    if(kind==='authorized'){
      const m=text.match(/^(.*?\bauthorized)\.\s+The team is working on (.+?)\.\s+I['’]ll report/i);
      return {line:true,html:m?`<strong>${esc(m[1])}</strong><span> · working on ${esc(m[2])}</span>`:`<span>${esc(short(text,160))}</span>`};
    }
    if(kind==='stage_report'){
      const stage=stageOfNotice(plan,notice,text),{summary,rows,prose}=splitReport(text),done=stage?.status==='done';
      const criteria=Array.isArray(stage?.acceptance)&&stage.acceptance.length?`<div class="plan-card-section"><span class="plan-card-label">Done when</span><ul class="plan-card-criteria">${stage.acceptance.map(a=>`<li class="${done?'met':''}">${done?check:'<span class="plan-card-open" aria-hidden="true"></span>'}<span>${esc(a)}</span></li>`).join('')}</ul></div>`:'';
      const body=rows.length?`${summary?`<p class="plan-card-summary">${esc(summary)}</p>`:''}<dl class="plan-card-rows">${rows.map(r=>`<dt>${esc(r.label)}</dt><dd>${esc(r.text)}</dd>`).join('')}</dl>`:prose?`<div class="reply-markdown plan-card-prose">${markdown(prose)}</div>`:'';
      const head=stage?`<header class="plan-card-head"><h3>Stage ${Number(stage.n)} · ${esc(stage.title)}</h3>${done?`<span class="plan-chip done">Done</span>`:''}</header>`:'';
      return {label:'Stage report',html:`<article class="plan-card plan-card-report">${head}${body}${criteria}${filesHTML?`<div class="plan-card-section plan-card-files"><span class="plan-card-label">Files</span>${filesHTML}</div>`:''}${stage?aheadHTML(plan,stage,{busy}):''}</article>`};
    }
    if(kind==='escalation'){
      const question=String(refs.question||text.replace(/\s*My recommendation:[\s\S]*$/,'')).trim(),recommendation=String(refs.recommendation||'').trim();
      const what=CATEGORY[refs.category],status=notice?.status||'open',answer=String(refs.answer||'').trim();
      const advice=recommendation?`<div class="plan-card-advice"><span class="plan-card-label">${esc(message.whoName||'Chief')} recommends</span><p>${esc(recommendation)}</p></div>`:'';
      let foot;
      if(status==='answered')foot=`<div class="plan-card-foot"><span class="plan-card-settled">${check}You answered</span>${answer?`<span class="plan-card-answer">${esc(short(answer,220))}</span>`:''}</div>`;
      else if(status!=='open')foot='';
      else{
        const open=!!reply?.open,id=esc(notice?.id||'');
        foot=`<div class="plan-card-foot plan-card-decide">${recommendation?`<button type="button" class="primary-button" data-plan-answer="approve" data-notice="${id}"${off}>Approve</button><button type="button" class="border-button" data-plan-answer="disapprove" data-notice="${id}"${off}>Disapprove</button>`:''}<button type="button" class="${recommendation?'small-link':'primary-button'}" data-plan-answer="reply" data-notice="${id}" aria-expanded="${open}"${off}>Reply</button><span class="plan-card-note">The team keeps working on the rest meanwhile.</span></div>${open?`<form class="plan-card-reply" data-plan-reply="${id}"><label><span class="plan-card-label">Your answer</span><textarea rows="3" maxlength="2000" data-plan-reply-text="${id}">${esc(reply?.draft||'')}</textarea></label><button type="submit" class="primary-button"${off}>Send answer</button></form>`:''}`;
      }
      return {label:'Decision',html:`<article class="plan-card plan-card-decision${status==='open'?' open':''}"><span class="plan-card-badge">${status==='open'?`Needs your decision${what?` · ${esc(what)}`:''}`:'Your decision'}</span><h3>${esc(question)}</h3>${advice}${foot}</article>`};
    }
    if(kind==='stuck')return {label:'Stuck',html:`<article class="plan-card plan-card-stuck"><span class="plan-card-badge">The team is stuck</span><p>${esc(text.replace(/\s*Tell me how to proceed\.?\s*$/,''))}</p><div class="plan-card-foot"><button type="button" class="primary-button" data-plan-answer="chat">Tell ${esc(message.whoName||'Chief')} how to go on</button></div></article>`};
    return null;
  }
  // Notices the plan marks for the chat, not yet in it: each goes to the group's chat, or to the supervisor's own chat for a plan with no group.
  // A stage report brings the files that stage's work saved, so the deliverables are in the chat without anyone asking for them.
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
        const files=noticeFiles(state,plan,n);
        out.push({target,plan,notice:n,message:{id,who,body:String(n.text),time:clock(n.at),...(n.at?{createdAt:n.at}:{}),live:true,status:'completed',planNotice:true,planId:plan.id,noticeKind:n.kind,...(files.length?{files}:{})}});
      }
    }
    return out;
  }
  // `each` hears every notice as it is posted (the desktop drop, buddy-drop-events.js).
  function deliverNotices(state,plans,each){
    const items=noticesToDeliver(state,plans);state.messages||={};
    for(const i of items){(state.messages[i.target]||=[]).push(i.message);each?.(i);}
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
  const TONE={draft:'ready',working:'working',waiting_on_supervisor:'review',needs_you:'needs',paused:'idle',stage_done:'done',stopped:'idle',idle:'idle'};
  const tone=plan=>plan?TONE[runState(plan)]||'idle':'';
  // The same strip, folded above the composer or, docked in the project panel beside the chat, always open: its first line is then the live status,
  // not a toggle. Every button in it is the same button, handled the same way, wherever it is shown.
  function stripHTML(plan,pulse,names,{open=false,busy=false,now=Date.now(),offline=false,error='',docked=false}={}){
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
    if(docked)open=true;
    const line=`<span class="plan-dot" aria-hidden="true"></span><span class="plan-banner">${esc(banner(plan,pulse,names,now))}</span>`;
    const head=docked?`<div class="plan-strip-head">${line}</div>`:`<button type="button" class="plan-strip-head" data-plan-toggle aria-expanded="${open}" aria-controls="${body}">${line}${chevron}</button>`;
    return `<section class="plan-strip tone-${TONE[state]||'idle'}${open?' open':''}${docked?' docked':''}${offline?' offline':''}" data-plan-strip="${esc(plan.id)}" data-plan-state="${esc(state)}" aria-label="Team plan">${head}${error?`<p class="plan-error" role="alert">${esc(error)}</p>`:''}<div class="plan-strip-body" id="${body}"${open?'':' hidden'}>${offline?'<p class="plan-offline">Background work is offline, so this may be out of date.</p>':''}${plan.objective?`<p class="plan-objective"><span>Objective</span>${esc(plan.objective)}</p>`:''}${state==='needs_you'?'<button type="button" class="small-link plan-needs" data-activity-open>See what needs you</button>':''}<ol class="plan-stages">${stagesOf(plan).map(stage).join('')}</ol>${footer}</div></section>`;
  }

  // The plan in one line above the chat's composer: a segment for each stage (done, being worked on, still to come) and, in plain words, what
  // is happening now. It opens the plan view, where the whole plan and its buttons are.
  function stageStripHTML(plan,pulse,names,{now=Date.now(),offline=false}={}){
    if(!plan)return '';
    const said=banner(plan,pulse,names,now),seg=s=>`<span class="stage-seg${s.status==='done'?' done':['approved','working','review'].includes(s.status)?' now':''}"></span>`;
    const arrow='<svg class="icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="m10 7 5 5-5 5"/></svg>';
    return `<button type="button" class="stage-strip tone-${TONE[runState(plan)]||'idle'}${offline?' offline':''}" data-chat-view="plan" data-stage-strip="${esc(plan.id)}" aria-label="Open the plan. ${esc(said)}"><span class="stage-segs" aria-hidden="true">${stagesOf(plan).map(seg).join('')}</span><span class="plan-banner">${esc(said)}</span>${offline?'<span class="stage-offline">May be out of date</span>':''}${arrow}</button>`;
  }

  const api={planFor,stageChip,taskChip,banner,noticesToDeliver,deliverNotices,stripHTML,stageStripHTML,currentStage,replyOutcome,tone,stageDeliverables,noticeFiles,splitReport,noticeCard};
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
  // The plan of the chat on screen, if it has one (the chat then offers its plan view).
  const active=()=>typeof ui!=='undefined'&&ui.view?.kind==='chat'?planFor(state,ui.view,current().plans):null;
  // Same pattern as the setup offer: redrawn only when what it says changes. In the plan view the whole plan is in the view's slot, open; in the
  // chat it is one line at the top of the composer area that opens that view.
  function mount(){
    const inChat=typeof ui!=='undefined'&&ui.view?.kind==='chat';
    const {snapshot,plans}=current(),plan=inChat?planFor(state,ui.view,plans):null;
    // Both places are kept while the chat is on screen, so moving between the chat and its plan view never draws either again.
    const slot=inChat?document.querySelector('[data-project-plan-slot]'):null,wrap=inChat?document.querySelector('.composer-wrap'):null;
    for(const el of document.querySelectorAll('.plan-strip,.stage-strip'))if(!plan||el.parentElement!==slot&&el.parentElement!==wrap)el.remove();
    if(!plan)return;
    // A refusal stays on the strip until the next tap, or until the plan itself moves on.
    if(failures.has(plan.id)&&failures.get(plan.id).state!==keyOf(plan))failures.delete(plan.id);
    const offline=snapshot.online===false,pulse=root.BuddyWorkerUI?.pulse?.();
    if(slot)place(slot,stripHTML(plan,pulse,names(),{open:true,docked:true,busy,offline,error:failures.get(plan.id)?.message||''}),true);
    if(wrap)place(wrap,stageStripHTML(plan,pulse,names(),{offline}),false);
  }
  function place(host,html,docked){
    const old=[...host.children].find(el=>el.matches('.plan-strip,.stage-strip'));
    if(old&&shown.get(old)===html)return;
    const chat=document.getElementById('chat-body'),bottom=!docked&&!!chat&&chat.scrollHeight-chat.scrollTop-chat.clientHeight<120;
    const focus=old&&old.contains(document.activeElement)?focusKey(document.activeElement):null,scroll=old?.querySelector('.plan-strip-body')?.scrollTop||0;
    const view=host.closest('[data-chat-pane]'),had=docked&&!!old&&!!view&&!view.hidden&&(old.contains(document.activeElement)||document.activeElement===document.body);
    const holder=document.createElement('div');holder.innerHTML=html;const next=holder.firstElementChild;shown.set(next,html);
    if(old)old.replaceWith(next);else host.insertAdjacentElement('afterbegin',next);
    const inner=next.querySelector('.plan-strip-body');if(inner)inner.scrollTop=scroll;
    // A button that went with the redraw (a stage now started) leaves focus in the view, not on the page.
    if(focus&&next.querySelector(focus))next.querySelector(focus).focus({preventScroll:true});else if(had)view.focus({preventScroll:true});
    if(bottom)chat.scrollTop=chat.scrollHeight;
  }
  function deliver(){
    const {plans}=current();if(!plans.length)return;
    const targets=deliverNotices(state,plans,item=>root.BuddyDrop?.notice?.(state,item));if(!targets.length)return;
    save();for(const target of new Set(targets))refreshLiveChat(target);
  }
  // A change is said in the chat: from the plan view, the chat comes back for it.
  function change(n){
    root.BuddyProjectDock?.show?.('chat');
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
  // A question for the person, answered from its card in the chat: Approve and Disapprove say so in plain words, Reply sends what they write.
  // Each is their own tap, sent as their answer, exactly as their reply in the chat would be.
  const replies=new Map();
  const answers={approve:advice=>`Approved. Go ahead${advice?` with your recommendation: ${advice}`:'.'}`,disapprove:()=>'Not approved. Don’t go ahead with that; find another way or ask me again.'};
  async function answer(plan,noticeId,text){
    const said=String(text||'').trim().slice(0,2000);if(!said)return;
    await send(plan,{action:'answer',planId:plan.id,escalationId:noticeId,answer:said,quote:said});
    if(!failures.has(plan.id))replies.delete(noticeId);
    redrawCards(true);
  }
  // The cards in the chat follow the plan: a stage started, a question answered, buttons off while a tap is on its way.
  let drawn='',drawnFor='';
  function redrawCards(force=false){
    if(typeof ui==='undefined'||ui.view?.kind!=='chat'||typeof refreshLiveChat!=='function')return;
    const target=ui.view.target,ids=new Set((state.messages?.[target]||[]).filter(m=>m?.planNotice).map(m=>m.planId));if(!ids.size)return;
    const plans=current().plans.filter(p=>ids.has(p?.id));
    const sig=JSON.stringify([busy,plans.map(p=>[p.id,p.status,p.scope,stagesOf(p).map(s=>s.status),(p.notices||[]).map(n=>[n.id,n.status,n.refs?.answer||''])])]);
    // A chat just drawn already shows what the plan says; only a change after that draws its cards again.
    const fresh=drawnFor!==target;if(sig===drawn&&!fresh&&!force)return;
    drawn=sig;drawnFor=target;if(!fresh||force)refreshLiveChat(target);
  }
  document.addEventListener('click',async e=>{
    const el=e.target.closest?.('[data-plan-toggle],[data-plan-authorize],[data-plan-change],[data-plan-stop],[data-plan-answer]');if(!el)return;
    const id=el.closest('[data-plan-strip]')?.dataset.planStrip||el.closest('[data-plan-card]')?.dataset.planCard,plan=current().plans.find(p=>p.id===id);if(!plan)return;
    if(el.hasAttribute('data-plan-toggle')){chosen.set(keyOf(plan),!isOpen(plan));mount();return;}
    if(el.hasAttribute('data-plan-change')){change(Number(el.dataset.planChange));return;}
    if(el.dataset.planAnswer==='chat'){document.getElementById('message-input')?.focus();return;}
    if(el.dataset.planAnswer==='reply'){
      const n=el.dataset.notice,r=replies.get(n)||{open:false,draft:''};replies.set(n,{...r,open:!r.open});redrawCards(true);
      if(!r.open)document.querySelector(`[data-plan-reply-text="${CSS.escape(n)}"]`)?.focus();
      return;
    }
    if(busy||el.disabled)return;
    // The tap is the person's own decision; its words are the button's.
    if(el.hasAttribute('data-plan-authorize'))await send(plan,{action:'authorize',planId:plan.id,through:Number(el.dataset.planAuthorize),quote:el.textContent.trim()});
    else if(el.hasAttribute('data-plan-stop')&&confirm('Stop this plan? Nothing new will start and work in progress is paused. You can choose a stage again later.'))await send(plan,{action:'stop',planId:plan.id});
    else if(el.dataset.planAnswer in answers){const n=noticeOf(plan,{id:'plan-notice-'+el.dataset.notice});if(n)await answer(plan,n.id,answers[el.dataset.planAnswer](String(n.refs?.recommendation||'').trim()));}
  });
  document.addEventListener('input',e=>{const n=e.target?.dataset?.planReplyText;if(n!==undefined)replies.set(n,{...(replies.get(n)||{}),open:true,draft:e.target.value});});
  document.addEventListener('submit',async e=>{
    const form=e.target.closest?.('[data-plan-reply]');if(!form)return;e.preventDefault();
    const plan=current().plans.find(p=>p.id===form.closest('[data-plan-card]')?.dataset.planCard);if(!plan||busy)return;
    await answer(plan,form.dataset.planReply,form.querySelector('textarea')?.value);
  });
  root.addEventListener('buddy-view-updated',()=>{mount();redrawCards();});
  root.addEventListener('buddy-worker-snapshot',()=>{deliver();mount();redrawCards();});
  // A stage report brings its stage's files. One delivered before they were kept with it is drawn with them too, read from the plan; what was
  // saved stays as it was. A chat is drawn again for every streamed word, so they are looked up once per status reply (each brings new plan
  // objects, and with them any new results).
  const looked=new WeakMap();
  function deliverablesOf(m){
    if(Array.isArray(m?.files)&&m.files.length)return m.files;
    if(m?.noticeKind!=='stage_report')return [];
    const plan=current().plans.find(p=>p?.id===m.planId),notice=(Array.isArray(plan?.notices)?plan.notices:[]).find(n=>'plan-notice-'+n?.id===m.id);
    if(!plan||!notice)return [];
    let known=looked.get(plan);if(!known)looked.set(plan,known=new Map());
    if(!known.has(m.id))known.set(m.id,noticeFiles(state,plan,notice));
    return known.get(m.id);
  }
  // In a group, a plan notice is Chief's message: shown under Chief's name and figure, like each member's own message in the group. A notice
  // of a known plan is a card (a stage report, a decision, a stuck notice) or, for an authorization, one status line.
  if(typeof root.messageHTML==='function'){
    const original=root.messageHTML;
    root.messageHTML=function(m){
      if(!m?.planNotice)return original.apply(this,arguments);
      const files=deliverablesOf(m),agent=typeof findAgent==='function'?findAgent(m.who):null,group=!!agent&&typeof findGroup==='function'&&!!findGroup(ui.view?.target);
      const plan=current().plans.find(p=>p?.id===m.planId),noticeId=String(m.id||'').replace(/^plan-notice-/,'');
      const card=plan?noticeCard(plan,{...m,whoName:agent?.name},{filesHTML:root.BuddyFiles?.cards?.(files)||'',markdown:s=>BuddyMarkdown.render(s),busy,reply:replies.get(noticeId)}):null;
      if(card?.line)return `<div class="message plan-status-line" data-plan-card="${esc(plan.id)}"><p><span class="plan-dot" aria-hidden="true"></span>${card.html}${m.time?`<time>${esc(m.time)}</time>`:''}</p></div>`;
      if(card){
        const author=group?(typeof authorColor==='function'?`<button type="button" class="message-author" style="${authorColor(agent)}" data-action="agent-info" data-id="${esc(agent.id)}">${esc(agent.name)}</button>`:`<strong>${esc(agent.name)}</strong>`):'';
        return `<div class="message bot-message plan-notice plan-card-message${group?' team-chat-contribution':''}" data-plan-card="${esc(plan.id)}">${group?avatar(agent.id,true):''}<div class="bot-bubble">${group?`<div class="team-chat-author">${author}<span>${esc(card.label)}</span></div>`:''}${card.html}<time>${esc(m.time||'')}</time></div></div>`;
      }
      if(!agent||!group)return original.call(this,files.length&&!m.files?.length?{...m,files}:m);
      const author=typeof authorColor==='function'?`<button type="button" class="message-author" style="${authorColor(agent)}" data-action="agent-info" data-id="${esc(agent.id)}">${esc(agent.name)}</button>`:`<strong>${esc(agent.name)}</strong>`;
      return `<div class="message bot-message team-chat-contribution plan-notice">${avatar(agent.id,true)}<div class="bot-bubble"><div class="team-chat-author">${author}<span>Team plan</span></div><div class="reply-markdown">${BuddyMarkdown.render(m.body)}</div>${root.BuddyFiles?.cards?.(files)||''}<time>${esc(m.time||'')}</time></div></div>`;
    };
  }
  Object.assign(api,{active,mount});
})(typeof globalThis!=='undefined'?globalThis:this);

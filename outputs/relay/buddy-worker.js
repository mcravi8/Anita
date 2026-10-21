(function(root){
  'use strict';
  const labels={queued:'Queued',running:'Working',waiting_review:'Needs review',waiting_user:'Needs you',paused:'Paused',interrupted:'Interrupted',completed:'Finished',failed:'Couldn’t finish',cancelled:'Cancelled'};
  const canResume=(status,kind)=>['paused','interrupted','failed','waiting_user'].includes(status)||(kind==='coding'&&status==='completed');
  // A stopped Claude task keeps its earlier spend reserved, so continuing it needs a fresh allowance from the user. Coding sessions are no exception:
  // they zero their allowance when an attempt starts, so one that was interrupted or paused has none left.
  // Runs have no limit of their own, so no task waits for an allowance.
  const needsAllowance=()=>false;
  const pending=task=>(task.reviews||[]).filter(r=>r.status==='pending');
  // Actions that may or may not have gone through: Buddy stopped after handing them over and before it could confirm the result.
  const unconfirmed=task=>(task.reviews||[]).filter(r=>r.status==='uncertain');
  const authTitle=mode=>mode==='signup'?'Create an account':mode==='verification'?'Verify your email':'Sign in privately';
  // A scheduled email check that found nothing the person has not been told (the native side decides: `quiet`) stays in Background work and says nothing.
  // A pause the system made (access reduced, a provider disconnected, a cause it could not name) is told in the agent's chat, so work never stops
  // silently. A pause the person, a routine or a newer run made is not: they already know, and the daily limit has its own Needs item.
  const systemPause=t=>t?.status==='paused'&&t.blockedBy!=='limit'&&!/^(user|routine|superseded)/.test(t.stopCause||'');
  // A sign-in the person answers in the chat (a password to type, a step to finish and confirm with Done, a service sign-in to save) has a
  // message of its own there (buddy-signin.js); the task's own message would only say it again.
  const signinWait=t=>t?.status==='waiting_review'&&pending(t).length>0&&pending(t).every(r=>r.kind==='authentication')||t?.status==='waiting_user'&&t.stopCause!=='review.parked'&&['signin','captcha','verification','credential','file'].includes(t.checkpoint?.need);
  // A coding command waiting on the team supervisor's review is the supervisor's to answer, not the person's: it posts nothing in the chat.
  const supervisorWait=t=>t?.status==='waiting_review'&&pending(t).length>0&&pending(t).every(r=>r.route==='supervisor');
  const deliverable=t=>(['completed','failed','interrupted','waiting_review','waiting_user'].includes(t?.status)||systemPause(t))&&t?.quiet!==true&&!signinWait(t)&&!supervisorWait(t);
  const deliveryID=t=>`worker-${t.id}-${Number(t.attempt)||0}-${t.status}${['waiting_review','waiting_user'].includes(t.status)?'-'+encodeURIComponent(t.attentionKey||t.progress||''):''}`;
  const attention=status=>['waiting_review','waiting_user'].includes(status);
  // Background work › Browser sign-in: one Chrome for every agent. `agents` are the workspace's agents, `using` the ids of those with
  // internet access (Web research and Mac apps on), which use the accounts signed in here.
  const html=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  // Which Google accounts the shared Chrome is signed in to, as the app read them from Chrome's settings (names only). Nothing when unknown.
  function signedIn(accounts){
    if(!accounts||!Array.isArray(accounts.accounts))return '';
    const chrome=typeof accounts.chrome==='string'&&accounts.chrome?accounts.chrome:'',others=accounts.accounts.filter(a=>typeof a==='string'&&a.toLowerCase()!==chrome.toLowerCase());
    if(chrome)return `<p class="worker-setup-account" role="status">Chrome is signed in as <strong>${html(chrome)}</strong>.${others.length?` Also signed in to Google: ${others.map(html).join(', ')}.`:''}</p>`;
    if(others.length)return `<p class="worker-setup-account" role="status">Signed in to Google as ${others.map(html).join(', ')}. Chrome itself isn’t signed in, so Google Password Manager is off.</p>`;
    return '<p class="worker-setup-account" role="status">Chrome isn’t signed in to a Google account yet.</p>';
  }
  function setupOnce({agents=[],using=[],open=null,legacy=[],accounts=null,button}){
    const names=ids=>ids.map(id=>agents.find(a=>a.id===id)?.name).filter(Boolean).map(html);
    const users=names(using),without=agents.filter(a=>!using.includes(a.id)).map(a=>html(a.name));
    const old=names(legacy);
    return `<section class="worker-setup-once" aria-labelledby="worker-setup-title"><strong id="worker-setup-title">Set up once</strong><p>Sign in to your accounts in one Chrome window. Every agent with internet access will use the accounts you sign in to here.</p><p>You can sign in to as many websites and accounts as you like, including more than one Google account. Sign in to Chrome itself with your Google account to use Google Password Manager.</p>${open?`<p role="status"><strong>Chrome is open${open.taskId?' for a task':''}.</strong> Agents that need the browser wait until you press Done.</p><div class="worker-toolbar">${button('finish-signin','Done','',true)}${button('chrome-settings','Chrome account settings')}</div>`:`<div class="worker-toolbar">${button('open-google','Open Chrome','',true)}</div>`}${signedIn(accounts)}<small>${users.length?`Used by ${users.join(', ')}.`:'No agent has internet access yet.'}${without.length?` No browser for ${without.join(', ')} (internet access is off).`:''}</small></section>${old.length?`<p class="worker-legacy" role="alert">An older private Chrome window (${old.join(', ')}’s, from before every agent shared one Chrome) is still open. Close it yourself; Buddy won’t close it. Sign-ins made there don’t carry over.</p>`:''}`;
  }
  // The account a task must use (the person named it), as the task's details and the reply that started it say it.
  const accountLine=t=>typeof t?.account==='string'&&t.account?`Uses ${t.account}`:'';
  function taskReceipts(tasks=[]){
    return (Array.isArray(tasks)?tasks:[]).filter(t=>t&&typeof t.id==='string'&&accountLine(t)).map(t=>`<div class="task-receipt"><span><strong>${html(t.title||'Background task')}</strong><small>${html(accountLine(t))}</small></span><button type="button" data-worker-task="${html(t.id)}" aria-label="View task ${html(t.title||'')}">View task</button></div>`).join('');
  }
  function taskMessage(t){
    const auth=pending(t).find(r=>r.kind==='authentication');
    if(t.status==='waiting_review'&&auth)return auth.mode==='signup'?'I need your approval to create this account.':'Please sign in to continue.';
    if(t.status==='waiting_review')return 'I need your approval to continue.';
    if(t.status==='waiting_user'&&(/private|sign.?in/i.test(t.progress||'')||t.signInOrigin))return 'Please sign in in Buddy’s Chrome window, then press Done.';
    const progress=String(t.progress||'').split('\n')[0].trim();
    const brief=progress.length<=160&&!/\b[0-9a-f]{8}-[0-9a-f-]{27,}\b|\b\d\d:\d\d:\d\dZ\b/i.test(progress)?progress:'';
    if(t.status==='waiting_user')return brief||'I need a detail from you to continue.';
    if(t.status==='completed')return t.result;
    if(t.status==='paused'){const why=brief.replace(/^paused[:.]?\s*/i,'');return `**${String(t.title||'This task').slice(0,90)}** is paused. ${why?why[0].toUpperCase()+why.slice(1):'Open the task for details.'}`;}
    return `I couldn’t finish **${String(t.title||'this task').slice(0,90)}**. ${brief||'Open the task for details.'}`;
  }
  // An approval asks one thing: may this exact step go ahead? Its question offers "Accept" (the operation and command questions), and it is
  // answered with two buttons. A review that asks something else (a name, a choice between sizes) keeps its own inputs.
  const approvalQuestion=q=>Array.isArray(q?.options)&&q.options.some(o=>o?.label==='Accept');
  const isApproval=r=>!!r&&r.kind!=='authentication'&&r.kind!=='checkpoint'&&(r.questions||[]).some(approvalQuestion);
  // What answering sends. Approve is what choosing "Approve once" (the Accept option) and then Continue sent; Disapprove is what "Cancel action"
  // sent. The Mac app reads this shape as it always has.
  function reviewRequest(taskId,r,draft,operation){
    const values={...(draft||{})};
    if(operation==='approve')for(const q of r.questions||[])if(approvalQuestion(q))values[q.id]='Accept';
    const answers=Object.fromEntries(Object.entries(values).map(([k,v])=>[k,[v]]));
    return {operation:'review',taskId,id:r.id,answers,cancel:operation==='decline',accept:operation==='approve'&&(answers.operation?.[0]==='Accept'||r.kind==='coding'&&answers.command?.[0]==='Accept')};
  }
  // What was asked, in a few words, on one line: the command itself (shortened from the middle) or the action's name.
  const plain=value=>String(value??'').replace(/\s+/g,' ').replace(/[*_`[\]<>#|~\\]/g,'').trim();
  function shortCommand(text){
    const line=String(text||'').replace(/\s+/g,' ').trim().replace(/`/g,"'");
    if(line.length<=40)return line;
    const words=line.split(' '),first=words[0],last=words.at(-1);
    if(words.length>1&&first.length<=16&&last.length<=28)return `${first} … ${last}`;
    return `${line.slice(0,18).trimEnd()}…${line.slice(-18).trimStart()}`;
  }
  // A coding command's request in everyday words: what it does, from what Buddy itself read in the command (its review's assessment), and
  // the agent's own reason as the why. A command that runs project scripts says which ones ("run the project scripts a.py and b.py"), also
  // when what Buddy saw in one sent it to the person (that is then the caution). Null for anything that isn't a coding command, and for older
  // reviews Buddy didn't assess.
  function plainRequest(r){
    const a=r?.tool?.arguments||{};if(r?.kind!=='coding'||typeof a.command!=='string'||!a.command.trim()||!r.assessment||typeof r.assessment!=='object')return null;
    // Script names keep their underscores (run_guard.py), which never start emphasis inside a word.
    const said=plain(r.assessment?.reason).replace(/\.$/,''),runs=String(r.assessment?.runs??'').replace(/\s+/g,' ').replace(/[*`[\]<>#|~\\]/g,'').trim().replace(/\.$/,'');let m,what=a.sign_in?'sign in with your saved sign-in and run a command':'run a command that uses the internet';
    const script=r.assessment?.kind==='script';
    if(!a.sign_in&&(m=runs.match(/^Runs (.+)$/)))what=`run ${m[1]}`;
    else if(r.assessment?.routine){
      if((m=said.match(/^(\d+) downloads from (.+) into the project$/)))what=`download ${m[1]} files from ${m[2]}`;
      else if((m=said.match(/^A download from (.+) into the project$/)))what=`download a file from ${m[1]}`;
      else if((m=said.match(/^A download from (.+) \(shown, not saved\)$/)))what=`read a page from ${m[1]}`;
      else if((m=said.match(/^A clone of a public repository from (.+) into the project$/)))what=`copy a public code repository from ${m[1]}`;
      else if((m=said.match(/^A fetch of a public repository from (.+) into the project$/)))what=`update a public code repository from ${m[1]}`;
      else if(/^A package install into the project/.test(said))what='install packages into the project';
      else if(said==='A look at running processes')what='look at the running processes';
      else if(said)what=said[0].toLowerCase()+said.slice(1);
    }
    const why=plain(a.reason).replace(/^(please\s+)?allow(\s+me)?(\s+to)?\s+/i,'').replace(/^(can|may) i\s+/i,'').replace(/[?.!\s]+$/,'');
    return {what,why:why?why[0].toUpperCase()+why.slice(1):'',caution:r.assessment&&!r.assessment.routine&&!script?plain(r.assessment.reason):''};
  }
  function requestTitle(r){
    if(r?.kind==='checkpoint')return 'Check the work';
    const a=r?.tool?.arguments||{},name=plain(r?.tool?.name),said=plainRequest(r);
    if(said)return said.what[0].toUpperCase()+said.what.slice(1);
    if(typeof a.command==='string'&&a.command.trim())return `Request to run \`${shortCommand(a.command)}\``;
    if(!name)return 'Request to continue';
    const action=/^[A-Z][a-z]/.test(name)?name[0].toLowerCase()+name.slice(1):name;
    return `Request to ${action.length>56?action.slice(0,55).trimEnd()+'…':action}`;
  }
  const verdicts={approved:'approved',disapproved:'disapproved',changes:'changes requested'};
  const decisionLine=d=>`${d.title} — ${verdicts[d.verdict]||'answered'}${d.by==='supervisor'&&plain(d.byName)?` by ${plain(d.byName).slice(0,24)}`:''}`;
  // The reviews an approval message was posted for: kept on the message, or, for one saved before that, read from its delivery id.
  function reviewIds(m){
    if(Array.isArray(m.workerReviewIds))return m.workerReviewIds;
    const prefix=`worker-${m.workerTaskID}-${m.workerAttempt}-waiting_review-`;
    if(typeof m.id!=='string'||!m.id.startsWith(prefix))return [];
    try{return decodeURIComponent(m.id.slice(prefix.length)).split(':').filter(Boolean);}catch{return [];}
  }
  function decisionTarget(state,taskId,reviewId,strict=false){
    for(const list of Object.values(state.messages||{})){
      if(!Array.isArray(list))continue;
      const asked=list.filter(m=>m?.workerTaskID===taskId&&m.workerStatus==='waiting_review');
      const decided=asked.find(m=>m.workerDecision?.reviewId===reviewId);if(decided)return decided;
      const open=asked.filter(m=>!m.workerDecision),match=open.find(m=>reviewIds(m).includes(reviewId));if(match)return match;
      // Only the person's own click, which answers the review on screen, may fall back to the one message that does not say which review it was.
      const unknown=open.filter(m=>!reviewIds(m).length);if(!strict&&unknown.length===1)return unknown[0];
    }
    return null;
  }
  // The approval message becomes the record of the answer, in place: "Request to run `npm test` — approved". It is saved with the chat, so it
  // reads the same after a reload, and the next approval in the same run gets a message of its own.
  function recordDecision(state,taskId,decision,{replace=false}={}){
    const m=decisionTarget(state,taskId,decision.reviewId,replace);if(!m||m.workerDecision&&!replace)return false;
    const next={reviewId:decision.reviewId,title:String(decision.title||'Request to continue'),verdict:decision.verdict,by:decision.by==='supervisor'?'supervisor':'user',...(decision.byName?{byName:String(decision.byName).slice(0,80)}:{}),...(decision.reason?{reason:String(decision.reason).slice(0,2000)}:{}),at:decision.at||new Date().toISOString()};
    if(m.workerDecision&&['verdict','by','byName','reason'].every(k=>m.workerDecision[k]===next[k]))return false;
    m.workerDecision=next;m.body=decisionLine(next);return true;
  }
  // The Mac app says who answered each review (the person, or the team's supervisor on their behalf) and why. A record without that is left
  // alone: an older record cannot tell a person's "no" from a run that simply stopped.
  function verdictOf(r){
    if(r.kind==='checkpoint')return r.status==='answered'?'approved':r.status==='cancelled'?'changes':'';
    return ['cancelled','declined'].includes(r.status)?'disapproved':['answered','dispatched','completed','uncertain','not_sent'].includes(r.status)?'approved':'';
  }
  function reconcile(state,t){
    if(!t||t.workspace!==state.conversationWorkspace)return false;let changed=false;
    for(const r of t.reviews||[]){
      if(!r||r.status==='pending'||!['user','supervisor'].includes(r.answeredBy)||!(isApproval(r)||r.kind==='checkpoint'))continue;
      const verdict=verdictOf(r);if(!verdict)continue;
      if(recordDecision(state,t.id,{reviewId:r.id,title:requestTitle(r),verdict,by:r.answeredBy,byName:r.answeredBy==='supervisor'?r.answeredByName:undefined,reason:r.answerReason,at:r.answeredAt},{replace:true}))changed=true;
    }
    return changed;
  }
  function presentation(state,m){
    if(!m.workerTaskID)return {body:m.body,hidden:false};
    const d=m.workerDecision;
    if(d){
      const line=decisionLine(d),reason=d.reason?`${plain(d.byName)||(d.by==='supervisor'?'The supervisor':'You')}: ${d.reason}`:'';
      return {body:line,hidden:false,link:false,decided:true,tooltip:[line.replace(/`/g,''),reason].filter(Boolean).join('\n'),...(reason?{details:reason}:{})};
    }
    const messages=state.messages[m.who]||[],index=messages.indexOf(m);
    const superseded=attention(m.workerStatus)&&index>=0&&messages.slice(index+1).some(n=>n.workerTaskID===m.workerTaskID);
    return {body:attention(m.workerStatus)?taskMessage({status:m.workerStatus,progress:m.body}):m.body,hidden:superseded};
  }
  function deliverResult(state,t){
    if(!t||t.workspace!==state.conversationWorkspace||!state.agents.some(a=>a.id===t.agentId)||!deliverable(t))return false;
    state.messages[t.agentId]||=[];const id=deliveryID(t);if(state.messages[t.agentId].some(m=>m.id===id))return false;
    const body=taskMessage(t);
    if(!body)return false;
    const message={id,who:t.agentId,body,time:new Date(t.updatedAt).toLocaleTimeString([], {hour:'2-digit',minute:'2-digit'}),live:true,status:'completed',workerTaskID:t.id,workerStatus:t.status,workerAttempt:Number(t.attempt)||0,workerUpdatedAt:t.updatedAt,coverage:t.coverage||[],files:t.files||[],workerReviewIds:t.status==='waiting_review'&&Array.isArray(t.reviews)?pending(t).map(r=>r.id):undefined};
    // A message that already records an answer is never reused: it stays as that answer, and what comes next is a message of its own.
    const prior=attention(t.status)?state.messages[t.agentId].find(m=>m.workerTaskID===t.id&&attention(m.workerStatus)&&!m.workerDecision&&(m.workerAttempt===message.workerAttempt||m.id.startsWith(`worker-${t.id}-${message.workerAttempt}-`))):null;
    if(prior){if(prior.workerUpdatedAt&&prior.workerUpdatedAt>t.updatedAt)return false;Object.assign(prior,message);}else state.messages[t.agentId].push(message);return true;
  }
  const api={labels,canResume,needsAllowance,pending,unconfirmed,authTitle,systemPause,signinWait,deliverable,deliveryID,deliverResult,taskMessage,presentation,isApproval,reviewRequest,requestTitle,plainRequest,supervisorWait,recordDecision,reconcile,reviewIds,setupOnce,accountLine,taskReceipts};root.BuddyWorkerUI=api;if(typeof module!=='undefined')module.exports=api;
  if(typeof document==='undefined')return;
  let snapshot={online:false,tasks:[],routines:[],paused:false},detail=null,view='list',routine=null,busy=false,error='',last='',preview=null;
  const drafts=new Map();
  // Reviews answered from this page: their buttons stay off, so a second click cannot answer the same review again.
  const answered=new Set();
  const ordered=value=>Array.isArray(value)?value.map(ordered):value&&typeof value==='object'?Object.fromEntries(Object.keys(value).sort().map(k=>[k,ordered(value[k])])):value;
  const detailKey=()=>JSON.stringify(ordered([detail,snapshot.privateBrowser]));
  const key=()=>`buddy.worker.draft.${state.conversationWorkspace}`;
  function loadDraft(){try{return JSON.parse(localStorage.getItem(key()))||{};}catch{return {};}}
  const request=payload=>{if(!window.BuddyDesktop?.worker)throw Error('Open Buddy’s Mac app to use background work.');return window.BuddyDesktop.worker(payload);};
  const button=(op,label,extra='',primary=false)=>`<button type="button" class="${primary?'primary-button':'border-button'}" data-worker-op="${op}" ${extra} ${busy?'disabled':''}>${label}</button>`;
  function shell(body){openDrawer('Background work',`<div class="worker-panel" data-worker-panel>${body}<p class="field-error" data-worker-error role="alert">${esc(error)}</p></div>`);document.querySelector('.modal.drawer')?.classList.add('worker-drawer');}
  function privateBanner(){
    const open=snapshot.privateBrowser;if(!open)return '';
    if(open.legacy)return `<section class="worker-private" role="status"><strong>An older private Chrome window may be open</strong><p>${who(open.agentId)} used it before every agent shared one Chrome. Close that window yourself, then press Done.</p>${button('finish-signin','Done','',true)}</section>`;
    return `<section class="worker-private" role="status"><strong>Buddy’s Chrome window is open</strong><p>${open.agentId&&findAgent(open.agentId)?`${who(open.agentId)} is waiting. `:''}Sign in there; agents that need the browser wait until you press Done.</p>${button('finish-signin','Done','',true)}${button('chrome-settings','Chrome account settings')}<small>Done closes the window and lets Buddy check the website again.</small></section>`;
  }
  function profiles(){shell(`<h3>Browser sign-in</h3>${setupOnce({agents:state.agents,using:snapshot.browserAgents||state.agents.filter(a=>a.tools?.web!==false&&a.tools?.desktop!==false).map(a=>a.id),open:snapshot.privateBrowser&&!snapshot.privateBrowser.legacy?snapshot.privateBrowser:null,legacy:snapshot.legacyChrome||[],accounts:snapshot.chromeAccounts||null,button})}${snapshot.privateBrowser?.legacy?privateBanner():''}<details class="worker-more"><summary>How it works${icon('down')}</summary><p>Buddy’s Chrome window has no agent connection. Sign in through Chrome’s profile controls to make your saved Google passwords available; Gmail website sign-in alone may not turn on Password Manager.</p><p>All agents share this one private Chrome profile, each working in its own tab. Your normal Chrome and the separate profiles earlier versions of Buddy used are left as they are.</p><p>When an agent needs a password Chrome hasn’t saved, it asks in its chat with a private field: what you type there goes only into that website’s sign-in page, never into the chat. Steps on your phone or in this window end with a Done button.</p><p>Passwords, password-manager contents, and sign-in forms are kept out of what agents see. New accounts, recovery, security settings and payments always need you.</p></details>`);}
  function list(){
    const tasks=[...snapshot.tasks].reverse();
    shell(`<p class="worker-intro">A little work happening in the background.</p>${snapshot.scheduleError?`<p class="field-error" role="alert">${esc(snapshot.scheduleError)}</p>`:''}${privateBanner()}<div class="worker-toolbar"><span class="worker-state ${snapshot.online?'online':''}">${snapshot.online?(snapshot.paused?'Paused':'This Mac'):'Worker offline'}</span>${snapshot.online?button('new','New task','',true):button('start','Start worker','',true)}</div>${tasks.length?`<div class="worker-list">${tasks.map(t=>`<button class="menu-row" data-worker-task="${esc(t.id)}">${findAgent(t.agentId)?avatar(t.agentId):icon('spark')}<span><strong>${esc(t.title)}</strong><small>${esc(agentName(t.agentId))} · ${esc(labels[t.status]||t.status)}</small></span>${icon(t.status==='completed'?'check':'chevron')}</button>`).join('')}</div>`:'<div class="worker-empty"><span>✦</span><h3>Leave something with your Buddy</h3><p>Research a topic, prepare an application, or handle an email.</p></div>'}${routineList()}<details class="worker-more"><summary>Worker settings${icon('down')}</summary><p>Uses a separate Chrome profile and task folders. The worker keeps running when you quit Buddy. This Mac needs to stay awake and online.</p><div class="worker-toolbar">${snapshot.online?button('pauseAll',snapshot.paused?'Resume queue':'Pause queue'):''}${button('refresh','Refresh')}${button('profiles','Browser sign-in')}</div><p>New tasks use the agent’s saved model. Manage connections and the starting provider for new agents in Settings.</p><button type="button" class="border-button" data-action="provider-settings">AI provider settings</button><p class="worker-caption">Credits are used before paid balance. Console funding and auto-reload settings determine what happens when credits run out.</p></details>`);
  }
  function routineList(){return `<details class="worker-more" ${(snapshot.routines||[]).some(r=>r.status==='needs_attention')?'open':''}><summary>Routines${(snapshot.routines||[]).length?` · ${snapshot.routines.length}`:''}${icon('down')}</summary>${(snapshot.routines||[]).map(r=>`<button class="menu-row" data-worker-routine="${esc(r.id)}">${findAgent(r.agentId)?avatar(r.agentId):icon('clock')}<span><strong>${esc(r.title)}</strong><small>${r.status==='active'?`Next ${esc(new Date(r.nextRun).toLocaleString())}`:r.status==='needs_attention'?'Needs attention':'Paused'}</small></span>${icon('chevron')}</button>`).join('')}<p>Ask a Buddy “run this every morning”, or set a time here. This Mac needs to be awake and online. Missed runs catch up once.</p>${button('new-routine','New routine')}</details>`;}
  function routineForm(r=null){
    routine=r;view='routine-form';let d=r;try{d||=JSON.parse(localStorage.getItem(key()+'-routine')||'{}');}catch{d={};}
    shell(`<form id="worker-routine-form"><p class="worker-intro">${r?'Edit this routine.':'A small job, on a regular rhythm.'}</p><label class="field"><span>Agent</span><select name="agentId" ${r?'disabled':''}>${state.agents.map(a=>`<option value="${esc(a.id)}" ${a.id===(d.agentId||ui.view.target)?'selected':''}>${esc(a.name)}</option>`).join('')}</select></label><label class="field"><span>Name</span><input name="title" maxlength="150" required value="${esc(d.title||'')}"></label><label class="field"><span>What should they do?</span><textarea name="goal" maxlength="30000" rows="4" required>${esc(d.goal||'')}</textarea></label><div class="worker-toolbar"><label class="field"><span>Time</span><input name="time" type="time" required value="${String(d.hour??9).padStart(2,'0')}:${String(d.minute??0).padStart(2,'0')}"></label><label class="field"><span>Repeat</span><select name="days"><option value="daily" ${(d.weekdays||[]).join(',')==='1,2,3,4,5,6,7'?'selected':''}>Every day</option><option value="weekdays" ${(d.weekdays||[]).join(',')==='2,3,4,5,6'?'selected':''}>Weekdays</option><option value="custom" ${d.weekdays?.length&&!['1,2,3,4,5,6,7','2,3,4,5,6'].includes(d.weekdays.join(','))?'selected':''}>Custom days</option></select></label></div><fieldset class="worker-day-picker" data-custom-days ${d.weekdays?.length&&!['1,2,3,4,5,6,7','2,3,4,5,6'].includes(d.weekdays.join(','))?'':'hidden'}><legend>Days</legend><div>${['Sun','Mon','Tue','Wed','Thu','Fri','Sat'].map((day,i)=>`<label><input type="checkbox" name="weekday" value="${i+1}" ${(d.weekdays||[2,3,4,5,6]).includes(i+1)?'checked':''}><span>${day}</span></label>`).join('')}</div></fieldset><details class="worker-more"><summary>Search & timing options${icon('down')}</summary><label class="field"><span>Type</span><select name="kind">${[['general','General'],['email','Email'],['research','Research'],['applications','Applications']].map(([v,l])=>`<option value="${v}" ${v===d.kind?'selected':''}>${l}</option>`).join('')}</select></label><label class="field"><span>Gmail filter (required for email routines)</span><textarea name="query" rows="2" maxlength="2000" placeholder="newer_than:90d {assessment assessments}">${esc(d.query||'')}</textarea></label><p>Email routines read matching new messages, retain previous findings, and remember successful reads. Include relevant follow-up and completion messages in your filter.</p><label class="field"><span>Time zone</span><input name="timeZone" required value="${esc(d.timeZone||Intl.DateTimeFormat().resolvedOptions().timeZone)}"></label><p>${r?`Uses ${esc(r.model|| (r.provider==='claude'?'Claude':'ChatGPT'))}.`:'Uses the selected agent’s saved model when this routine is created.'} This Mac must be awake and online.</p></details><div class="modal-actions">${button('back','Cancel')}<button class="primary-button" type="submit">Save routine</button></div></form>`);
  }
  function routineDetail(r){routine=r;view='routine';shell(`${button('back','← All work')}<h3>${esc(r.title)}</h3><p class="worker-status">${r.status==='active'?'Scheduled':r.status==='needs_attention'?'Needs attention':'Paused'}</p><p>${who(r.agentId)} · ${esc(r.timeZone)}</p><p>Next ${esc(new Date(r.nextRun).toLocaleString())}</p>${r.lastError?`<p class="worker-progress" role="alert">${esc(r.lastError)}</p>`:''}<p class="worker-brief">${esc(r.goal)}</p><div class="worker-toolbar">${button('edit-routine','Edit')}${button(r.status==='active'?'pause-routine':'resume-routine',r.status==='active'?'Pause':'Resume')}${button('delete-routine','Remove routine')}</div>${r.lastTaskID?`<button class="menu-row" data-worker-task="${esc(r.lastTaskID)}">${icon('clock')}<span>Last run</span>${icon('chevron')}</button>`:''}<details class="worker-more"><summary>Search & execution${icon('down')}</summary>${r.query?`<pre>${esc(r.query)}</pre><p>The first Gmail scan checks the latest 24 hours. Later scans search new mail and retry unfinished reads. Analyzed message IDs are remembered across this agent’s schedules, including after restarts. Unresolved findings carry forward.</p>`:''}<p>This Mac needs to be awake and online. Missed runs catch up once. A failed or interrupted task pauses the routine for review. Sending and browser operations keep their existing review steps.</p><p>${r.provider==='claude'?'Claude':'ChatGPT subscription'}</p></details>`);}
  function form(){
    const d={provider:'',...loadDraft()};shell(`<form id="worker-new-form"><p class="worker-intro">Give your Buddy a brief. Come back for the result.</p><label class="field"><span>Agent</span><select name="agentId" required>${state.agents.map(a=>`<option value="${esc(a.id)}" ${a.id===(d.agentId||ui.view.target)?'selected':''}>${esc(a.name)}</option>`).join('')}</select></label><label class="field"><span>Task</span><input name="title" maxlength="150" placeholder="e.g. Research five roles for me" required value="${esc(d.title||'')}"></label><label class="field"><span>Brief</span><textarea name="goal" rows="6" maxlength="30000" placeholder="What should they do? Include links, useful files, and what a good result looks like." required>${esc(d.goal||'')}</textarea></label><details class="worker-more" ${d.provider==='claude'?'open':''}><summary>Options${icon('down')}</summary><label class="field"><span>Type of work</span><select name="kind">${[['general','Anything'],['research','Research'],['applications','Job application'],['email','Email'],['coding','Coding · Claude credits']].map(([v,l])=>`<option value="${v}" ${v===d.kind?'selected':''}>${l}</option>`).join('')}</select></label><label class="field"><span>Powered by</span><select name="provider"><option value="" ${!d.provider?'selected':''}>Use agent’s model</option><option value="chatgpt" ${d.provider==='chatgpt'?'selected':''}>ChatGPT subscription</option><option value="claude" ${d.provider==='claude'?'selected':''} ${snapshot.claudeConnected?'':'disabled'}>Claude API credits${snapshot.claudeConnected?'':' · connect in Settings'}</option></select></label></details><p class="worker-caption">Browser operations and connected actions come back for review. Sign-in stays private; Chrome unlock and unsupported verification need you.</p><div class="modal-actions">${button('back','Back')}<button type="submit" class="primary-button">Start task${icon('arrow')}</button></div></form>`);
  }
  function unconfirmedCard(r){
    const auth=r.kind==='authentication',args={...r.tool?.arguments};const body=BuddyActions.messagePreview(args.payload);if(body)args.message=body;
    const data=Object.entries(args).filter(([k])=>!['payload'].includes(k));
    return `<section class="worker-review worker-unconfirmed" data-worker-unconfirmed="${esc(r.id)}"><strong>Check whether this went through</strong><small>${esc(auth?authTitle(r.mode):r.tool?.name||'An action')} · ${esc(auth?r.origin||'':r.tool?.service||'Buddy private browser')}</small><p class="worker-caption">Buddy stopped before it could confirm this. Look at the site or service, then tell Buddy what you found. Buddy will not send an identical action until you do.</p>${data.length?`<dl>${data.map(([k,v])=>`<div><dt>${esc(k.replace(/_/g,' '))}</dt><dd>${esc(typeof v==='string'?v:JSON.stringify(v,null,2))}</dd></div>`).join('')}</dl>`:''}<div class="worker-toolbar">${button('resolve-no','It did not go through',`data-review-id="${esc(r.id)}"`)}${button('resolve-yes','It went through',`data-review-id="${esc(r.id)}"`,true)}</div></section>`;
  }
  // The person is asked to look at prepared work (a CV, a drafted application) because one of their own rules asked for it.
  function checkpointCard(r){
    const a=r.tool?.arguments||{},files=(a.files||[]).filter(Boolean);
    return `<section class="worker-review worker-checkpoint" data-worker-review="${esc(r.id)}"><strong>Check the work</strong><small>${a.of?`Check ${esc(a.check)} of ${esc(a.of)} · `:''}${esc(a.rule||'Your rule')}</small><p>${esc(a.summary||'')}</p>${files.length?`<ul class="worker-checkpoint-files">${files.map(f=>`<li><button type="button" class="small-link" data-worker-file="${esc(f)}">${esc(f)}</button></li>`).join('')}</ul>`:''}${a.effect?`<p class="worker-caption">${esc(a.effect)}</p>`:''}<fieldset><legend>If something needs changing, say what</legend><textarea data-worker-question="feedback" rows="3" maxlength="2000">${esc(drafts.get(r.id)?.feedback||'')}</textarea></fieldset><div class="worker-toolbar">${button('checkpoint-no','Needs changes',`data-review-id="${esc(r.id)}"`)}${button('checkpoint-yes','Looks good, continue',`data-review-id="${esc(r.id)}"`,true)}</div></section>`;
  }
  function review(r){
    if(r.kind==='checkpoint')return checkpointCard(r);
    if(r.kind==='authentication')return `<section class="worker-review worker-auth"><strong>${esc(authTitle(r.mode))}</strong><small>${esc(r.origin)}${r.accountEmail?` · ${esc(r.accountEmail)}`:''}</small><p>${esc(r.reason||'Continue your requested task.')}</p><p class="worker-caption">${r.mode==='signup'?'Choose or generate the new credential in Buddy’s Chrome window. Chrome can save it to Google Password Manager.':`Chrome keeps passwords private. You can also type the password in ${esc(agentName(detail?.agentId||''))}’s chat, in a private field that goes only to this website. Buddy receives the sign-in result.`} Allow email verification for this website during this sign-in.</p><div class="worker-toolbar">${button('auth-decline','Not now',`data-review-id="${esc(r.id)}"`)}${r.mode==='signin'?button('auth-saved','Use saved login',`data-review-id="${esc(r.id)}"`):''}${r.mode==='verification'?button('auth-verify','Verify email',`data-review-id="${esc(r.id)}"`,true):''}${button('auth-private',r.mode==='signup'?'Create privately':'Open privately',`data-review-id="${esc(r.id)}"`,r.mode!=='verification')}</div></section>`;
    const args={...r.tool?.arguments};const body=BuddyActions.messagePreview(args.payload);if(body)args.message=body;
    const data=Object.entries(args).filter(([k])=>!['payload'].includes(k));
    // An approval is answered with Approve or Disapprove; its question is shown as what the buttons answer. Any other question keeps its input.
    const approval=isApproval(r),off=answered.has(r.id)?'disabled':'';
    // A coding command reads as one line of what it wants to do and why; the command itself is under Details.
    const said=approval&&plainRequest(r);
    if(said)return `<section class="worker-review worker-plain-request" data-worker-review="${esc(r.id)}"><strong>${esc(agentName(detail?.agentId||'')||'The agent')} wants to ${esc(said.what)}.</strong>${said.why?`<p>Why: ${esc(said.why)}.</p>`:''}${said.caution?`<small class="worker-review-caution">${esc(said.caution)}</small>`:''}<details class="worker-review-details"><summary>Details</summary>${data.length?`<dl>${data.map(([k,v])=>`<div><dt>${esc(k.replace(/_/g,' '))}</dt><dd>${esc(typeof v==='string'?v:JSON.stringify(v,null,2))}</dd></div>`).join('')}</dl>`:''}</details><div class="worker-toolbar">${button('decline','Disapprove',`data-review-id="${esc(r.id)}" ${off}`)}${button('approve','Approve',`data-review-id="${esc(r.id)}" ${off}`,true)}</div></section>`;
    const asked=(r.questions||[]).map(q=>approval&&approvalQuestion(q)?`<p class="worker-review-question">${esc(q.question)}</p>`:`<fieldset><legend>${esc(q.question)}</legend>${q.options?.length?`<select data-worker-question="${esc(q.id)}"><option value="">Choose…</option>${q.options.map(o=>`<option value="${esc(o.label)}" ${drafts.get(r.id)?.[q.id]===o.label?'selected':''}>${esc(o.label==='Accept'?'Approve once':o.label)}</option>`).join('')}</select>`:`<textarea data-worker-question="${esc(q.id)}" rows="3" maxlength="10000">${esc(drafts.get(r.id)?.[q.id]||'')}</textarea>`}</fieldset>`).join('');
    return `<section class="worker-review" data-worker-review="${esc(r.id)}"><strong>${esc(r.tool?.name||'Review action')}</strong><small>${esc(r.tool?.service||'Buddy private browser')}</small>${data.length?`<dl>${data.map(([k,v])=>`<div><dt>${esc(k.replace(/_/g,' '))}</dt><dd>${esc(typeof v==='string'?v:JSON.stringify(v,null,2))}</dd></div>`).join('')}</dl>`:''}${asked}<div class="worker-toolbar">${button('decline',approval?'Disapprove':'Cancel action',`data-review-id="${esc(r.id)}" ${off}`)}${button('approve',approval?'Approve':'Continue',`data-review-id="${esc(r.id)}" ${off}`,true)}</div></section>`;
  }
  function taskBody(t){
    return `<div class="worker-task-heading">${findAgent(t.agentId)?avatar(t.agentId):''}<div><h3>${esc(t.title)}</h3><small>${esc(agentName(t.agentId))} · ${t.provider==='claude'?'Claude credits':'ChatGPT'}${accountLine(t)?` · <span class="worker-account">${esc(accountLine(t))}</span>`:''}</small></div></div><p class="worker-status" role="status">${esc(labels[t.status]||t.status)}</p><p class="worker-progress">${esc(needsAllowance(t)?'Choose an additional Claude allowance to continue this task. Previous unconfirmed usage stays recorded.':t.progress||'')}</p>${snapshot.privateBrowser?.taskId===t.id?privateBanner():''}${pending(t).map(review).join('')}${unconfirmed(t).map(unconfirmedCard).join('')}${typeof reviewCoverage==='function'?reviewCoverage(t.coverage):''}${t.result?`<article class="reply-markdown worker-result">${BuddyMarkdown.render(t.result,{files:t.files})}</article>`:''}${t.fileList?.length?`<div class="worker-files"><h4>Task files</h4>${t.fileList.map(f=>`<button class="menu-row" data-worker-file="${esc(f.path)}">${icon('file')}<span>${esc(f.path)}</span>${icon('chevron')}</button>`).join('')}</div>`:''}<div>${needsAllowance(t)&&canResume(t.status,t.kind)&&snapshot.privateBrowser?.taskId!==t.id?`<label class="field"><span>Additional Claude allowance (USD)</span><input type="number" min="0.10" max="10" step="0.10" data-worker-allowance aria-label="Additional Claude allowance in USD" value="${esc(drafts.get(t.id)?.allowance||'')}" placeholder="Choose an amount"><small>Authorizes this attempt only. Earlier unconfirmed usage: $${Number((t.reservedBudgetUSD||0)+(t.uncertainBudgetUSD||0)).toFixed(2)}.</small></label>`:''}${canResume(t.status,t.kind)&&snapshot.privateBrowser?.taskId!==t.id?`<label class="field"><span>What should they do next?</span><textarea data-worker-update rows="3" maxlength="10000" placeholder="Add a missing detail, answer a question, or say what you changed in the browser.">${esc(drafts.get(t.id)?.update||'')}</textarea></label>`:''}</div><div class="worker-toolbar">${canResume(t.status,t.kind)&&snapshot.privateBrowser?.taskId!==t.id?button('resume',t.kind==='coding'?'Continue coding':needsAllowance(t)?'Resume with this allowance':'Resume task','',true):''}${['queued','running','waiting_review'].includes(t.status)?button('pause','Pause'):''}${!['completed','cancelled'].includes(t.status)?button('cancel','Cancel task'):''}</div><details class="worker-more"><summary>Task details${icon('down')}</summary><p class="worker-brief">${esc(t.goal||'')}</p><p class="worker-caption">Saved ${esc(new Date(t.updatedAt).toLocaleString())}${t.spentUSD!=null?` · Estimated Claude usage $${Number(t.spentUSD).toFixed(4)}`:''}</p>${t.kind==='coding'?`<p class="worker-caption">Project: ${esc(t.codingProject||'Private task files')} · Saved coding context${t.codingSessionID?' available':''}</p>${t.commands?.length?`<details class="worker-receipt"><summary>Commands & checks</summary>${t.commands.map(c=>`<details><summary>${esc(c.code)} · ${c.status==='completed'?`exit ${esc(c.exitCode??c.signal??'unknown')}${c.timedOut?' · timed out':''}`:esc(c.status)}</summary><pre>${esc(c.output||'')}</pre></details>`).join('')}</details>`:''}`:`${button('browser','Open task browser')}<p class="worker-caption">Opens Buddy’s Chrome window at this task’s page. Agents’ pages wait while it is open; press Done when you’re finished.</p>`}${t.events?.length?`<details class="worker-receipt"><summary>Work activity</summary><ul>${t.events.map(e=>`<li>${esc(e.tool)} · ${esc(e.status)}</li>`).join('')}</ul></details>`:''}${(t.reviews||[]).filter(r=>r.status!=='pending').map(r=>`<details class="worker-receipt"><summary>${esc(r.tool?.name||'Action')} · ${esc(r.status)}</summary><pre>${esc(JSON.stringify(r.receipt||r.tool?.arguments||{},null,2))}</pre></details>`).join('')}</details>`;
  }
  function drawDetail(){shell(`${button('back','← All tasks')}<div data-worker-live>${taskBody(detail)}</div>`);last=detailKey();}
  // Both answers go off the moment one is chosen, so a double click cannot answer twice while the first answer is on its way.
  function hold(reviewId){document.querySelectorAll(`[data-worker-review="${CSS.escape(reviewId)}"] [data-worker-op]`).forEach(b=>{b.disabled=true;});}
  // The chat's approval message now says what was decided. It is saved with the chat, so it reads the same after a reload.
  function chatChanged(){save();if(ui.view.kind==='chat')refreshLiveChat(ui.view.target);}
  function decided(task,r,verdict){if(recordDecision(state,task.id,{reviewId:r.id,title:requestTitle(r),verdict,by:'user'}))chatChanged();}
  function showError(e){error=String(e.message||e);const el=document.querySelector('[data-worker-error]');if(el)el.textContent=error;else showToast(error);}
  async function refresh(redraw=true){
    const listKey=s=>JSON.stringify([s.online,s.paused,s.defaultProvider,s.privateBrowser?.agentId,s.privateBrowser?.taskId,s.tasks.map(t=>[t.id,t.title,t.agentId,t.status]),(s.routines||[]).map(r=>[r.id,r.status,r.nextRun])]);
    try{const before=listKey(snapshot);snapshot=await request({operation:'status'});await deliverRoutineResults();error='';const message=document.querySelector('[data-worker-error]');if(message)message.textContent='';if(redraw&&document.querySelector('[data-worker-panel]')){if(view==='list'&&before!==listKey(snapshot))list();else if(view==='routine'&&routine&&before!==listKey(snapshot)){const r=snapshot.routines?.find(r=>r.id===routine.id);if(r)routineDetail(r);else{view='list';list();}}else if(view==='task'&&detail){const result=await request({operation:'detail',taskId:detail.id});detail=result.task;if(reconcile(state,detail))chatChanged();const live=document.querySelector('[data-worker-live]');if(live&&!(live.contains(document.activeElement)&&document.activeElement.matches('input,textarea,select'))&&last!==detailKey()){live.innerHTML=taskBody(detail);last=detailKey();}}}badge();window.BuddyActivity?.acceptWorker(snapshot);}
    catch(e){window.BuddyActivity?.workerError(e.message||e);const wasOnline=snapshot.online!==false;snapshot.online=false;if(redraw&&view==='list'){if(wasOnline)list();showError(e);}}
    // Whatever the poll found, the plan strip and the figures read it now rather than at the next full render.
    finally{polled=Date.now();window.dispatchEvent(new CustomEvent('buddy-worker-snapshot'));}
  }
  // A plan being worked on, or anyone busy in the background, is checked every 5 seconds; otherwise every 15.
  let polled=0;
  const live=()=>(snapshot.plans||[]).some(p=>p?.status==='active')||Object.values(snapshot.pulse?.agents||{}).some(a=>a?.state&&a.state!=='idle');
  // A finished task with nothing to deliver (an empty result) is asked for once per outcome, not on every refresh.
  const examined=new Map(),outcome=t=>`${t.status}|${t.updatedAt||''}`;
  async function deliverRoutineResults(){
    let changed=false;
    for(const id of [...examined.keys()])if(!snapshot.tasks.some(t=>t.id===id&&deliverable(t)))examined.delete(id);
    for(const t of snapshot.tasks.filter(t=>deliverable(t)&&findAgent(t.agentId)&&examined.get(t.id)!==outcome(t)&&!(state.messages[t.agentId]||[]).some(m=>m.id===deliveryID(t))).slice(0,10)){
      const value=(await request({operation:'detail',taskId:t.id})).task;examined.set(t.id,outcome(t));if(reconcile(state,value))changed=true;if(deliverResult(state,value)){changed=true;}
    }
    // An approval answered without this page (the team's supervisor answering for the person) is read from the task once it stops waiting on it,
    // so the chat's message says who answered. Each waiting message is looked up at most a few times.
    for(const t of answeredElsewhere().slice(0,5)){
      const value=(await request({operation:'detail',taskId:t.id})).task;if(reconcile(state,value))changed=true;
    }
    if(changed){save();if(ui.view.kind==='chat')refreshLiveChat(ui.view.target);else render();}
  }
  const looked=new Map();
  function answeredElsewhere(){
    const out=[];
    for(const t of snapshot.tasks||[]){
      if(!findAgent(t.agentId))continue;
      const still=t.status==='waiting_review'?String(t.attentionKey||'').split(':'):[],seen=`${t.status}|${t.attentionKey||''}`;
      const open=(state.messages[t.agentId]||[]).filter(m=>m.workerTaskID===t.id&&m.workerStatus==='waiting_review'&&!m.workerDecision&&reviewIds(m).some(id=>!/\s/.test(id)&&!still.includes(id)));
      const due=open.filter(m=>{const l=looked.get(m.id);return !l||l.seen!==seen&&l.count<3;});
      if(!due.length)continue;
      for(const m of due){const l=looked.get(m.id);looked.set(m.id,{seen,count:(l?.count||0)+1});}
      out.push(t);
    }
    return out;
  }
  function badge(){if(window.BuddyActivity){BuddyActivity.paint();return;}const count=snapshot.tasks.filter(t=>['waiting_review','waiting_user','failed','interrupted'].includes(t.status)).length+(snapshot.routines||[]).filter(r=>r.status==='needs_attention').length+(snapshot.scheduleError?1:0);document.querySelectorAll('[data-worker-badge]').forEach(el=>{el.textContent=count||'';el.hidden=!count;});}
  api.refresh=refresh;api.snapshot=()=>snapshot;api.request=request;api.pulse=()=>snapshot.pulse||{agents:{}};
  api.open=async()=>{view='list';error='';list();await refresh();};
  api.profiles=async()=>{view='profiles';error='';profiles();try{snapshot=await request({operation:'start'});profiles();}catch(e){showError(e);}};
  document.addEventListener('input',e=>{if(e.target.matches('[data-worker-update]')&&detail)drafts.set(detail.id,{...drafts.get(detail.id),update:e.target.value});if(e.target.matches('[data-worker-allowance]')&&detail)drafts.set(detail.id,{...drafts.get(detail.id),allowance:e.target.value,budgetAuthorizationID:undefined});const form=e.target.closest('#worker-new-form,#worker-routine-form');if(form){try{localStorage.setItem(key()+(form.id==='worker-routine-form'?'-routine':''),JSON.stringify({...Object.fromEntries(new FormData(form)),...(form.id==='worker-routine-form'?{weekdays:[...form.querySelectorAll('[name=weekday]:checked')].map(v=>Number(v.value))}:{})}));}catch{}}});
  document.addEventListener('change',e=>{if(e.target.matches('#worker-routine-form [name=days]')){document.querySelector('[data-custom-days]').hidden=e.target.value!=='custom';}const el=e.target.closest('[data-worker-question]'),r=el?.closest('[data-worker-review]');if(r){const values=drafts.get(r.dataset.workerReview)||{};values[el.dataset.workerQuestion]=el.value;drafts.set(r.dataset.workerReview,values);}});
  document.addEventListener('submit',async e=>{
    const form=e.target.closest('#worker-routine-form');if(!form)return;e.preventDefault();if(busy)return;busy=true;
    const v=Object.fromEntries(new FormData(form)),[hour,minute]=(v.time||'09:00').split(':').map(Number),days=v.days==='daily'?[1,2,3,4,5,6,7]:v.days==='weekdays'?[2,3,4,5,6]:[...form.querySelectorAll('[name=weekday]:checked')].map(v=>Number(v.value));
    const submit=form.querySelector('button[type=submit]');submit.disabled=true;submit.textContent='Saving…';
    try{const draft=JSON.parse(localStorage.getItem(key()+'-routine')||'{}'),requestId=draft.requestId||crypto.randomUUID();localStorage.setItem(key()+'-routine',JSON.stringify({...v,requestId,hour,minute,weekdays:days}));const routineArgs={action:routine?'update':'create',...(routine?{routineID:routine.id}:{}),title:v.title,goal:v.goal,kind:v.kind,query:v.query,hour,minute,weekdays:days,timeZone:v.timeZone};const result=await request({operation:'routine',agentId:routine?.agentId||v.agentId,requestId,arguments:routineArgs});localStorage.removeItem(key()+'-routine');await refresh(false);routineDetail(result.routine);}catch(e){showError(e);}finally{busy=false;if(submit.isConnected){submit.disabled=false;submit.textContent='Save routine';}}
  });
  document.addEventListener('submit',async e=>{
    const form=e.target.closest('#worker-new-form');if(!form)return;e.preventDefault();if(busy)return;
    busy=true;error='';const values=Object.fromEntries(new FormData(form));if(!values.provider)delete values.provider;try{const draft=loadDraft();const requestId=draft.requestId||crypto.randomUUID();localStorage.setItem(key(),JSON.stringify({...values,requestId}));const submit=form.querySelector('button[type="submit"]');submit.disabled=true;submit.textContent='Saving…';
      const {budgetUSD:typedBudget,...rest}=values,chosenBudget=Number(typedBudget),withBudget=(values.kind==='coding'||values.provider==='claude')&&Number.isFinite(chosenBudget)&&chosenBudget>0;const result=await request({operation:'create',...rest,...(withBudget?{budgetUSD:chosenBudget}:{}),requestId});localStorage.removeItem(key());detail=result.task;view='task';drawDetail();await refresh();
    }catch(e){showError(e);}finally{busy=false;document.querySelectorAll('[data-worker-panel] [data-worker-op], #worker-new-form button').forEach(b=>b.disabled=false);const submit=document.querySelector('#worker-new-form button[type=submit]');if(submit)submit.textContent='Start task';}
  });
  document.addEventListener('click',async e=>{
    const entry=e.target.closest('[data-action="background-work"]');if(entry){api.open();return;}
    if(e.target.closest('[data-action="browser-signin"]')){api.profiles();return;}
    const routineEntry=e.target.closest('[data-worker-routine]');const task=e.target.closest('[data-worker-task]'),file=e.target.closest('[data-worker-file]'),op=e.target.closest('[data-worker-op]');if(!task&&!file&&!op&&!routineEntry)return;
    if(busy)return;busy=true;error='';
    try{
      if(routineEntry){const r=snapshot.routines?.find(r=>r.id===routineEntry.dataset.workerRoutine);if(r)routineDetail(r);}
      else if(task){detail=(await request({operation:'detail',taskId:task.dataset.workerTask})).task;view='task';drawDetail();if(reconcile(state,detail))chatChanged();}
      else if(file){preview=await request({operation:'preview',taskId:detail.id,path:file.dataset.workerFile});view='preview';shell(`${button('task-back','← Task')}<h3>${esc(preview.path)}</h3><div class="worker-document">${BuddyDocuments.preview(preview)}</div>`);}
      else {
        const operation=op.dataset.workerOp;
        if(operation==='new-routine'){routineForm();}
        else if(operation==='edit-routine'){routineForm(routine);}
        else if(['pause-routine','resume-routine','delete-routine'].includes(operation)){const action=operation.split('-')[0];await request({operation:'routine',agentId:routine.agentId,arguments:{action,routineID:routine.id}});await refresh(false);if(action==='delete'){view='list';list();}else routineDetail(snapshot.routines.find(r=>r.id===routine.id));}
        else if(operation==='new'){view='new';form();}
        else if(operation==='profiles'){view='profiles';profiles();}
        else if(operation==='chrome-settings'){await request({operation:'openChromeSettings'});await refresh(false);if(view==='task'&&detail)drawDetail();else profiles();}
        else if(operation==='open-google'){await request({operation:'openGoogle'});await refresh(false);profiles();}
        else if(operation==='finish-signin'){const done=await request({operation:'finishSignIn'});await refresh(false);if(view==='profiles')profiles();else if(view==='task'){detail=(await request({operation:'detail',taskId:detail.id})).task;drawDetail();}else list();if(done?.finished===false&&done.note)showError(done.note);}
        else if(operation.startsWith('auth-')){const r=pending(detail).find(r=>r.id===op.dataset.reviewId&&r.kind==='authentication');if(!r)throw Error('This sign-in request ended. Refresh the task.');await request({operation:'review',taskId:detail.id,id:r.id,accept:operation!=='auth-decline',authAction:operation.slice(5)});await refresh();}
        else if(operation==='back'){view='list';await refresh(false);list();}
        else if(operation==='task-back'){view='task';drawDetail();}
        else if(operation==='refresh'){await refresh();}
        else if(operation==='connectClaude'||operation==='disconnectClaude'){await request({operation});await refresh();}
        else if(operation==='start'){snapshot=await request({operation:'start'});list();}
        else if(operation==='pauseAll'){await request({operation,paused:!snapshot.paused});await refresh();}
        else if(operation==='resolve-yes'||operation==='resolve-no'){const r=unconfirmed(detail).find(r=>r.id===op.dataset.reviewId);if(!r)throw Error('This was already checked. Refresh the task.');detail=(await request({operation:'resolve',taskId:detail.id,id:r.id,confirmed:operation==='resolve-yes'})).task;drawDetail();await refresh(false);}
        else if(operation==='checkpoint-yes'||operation==='checkpoint-no'){
          const r=pending(detail).find(r=>r.id===op.dataset.reviewId&&r.kind==='checkpoint');if(!r)throw Error('This check ended. Refresh the task.');
          const feedback=String(document.querySelector(`[data-worker-review="${CSS.escape(r.id)}"] [data-worker-question="feedback"]`)?.value??drafts.get(r.id)?.feedback??'').slice(0,2000);
          if(operation==='checkpoint-no'&&!feedback.trim())throw Error('Say what needs changing so the agent can fix it.');
          const task=detail;hold(r.id);
          await request({operation:'review',taskId:task.id,id:r.id,accept:operation==='checkpoint-yes',feedback});answered.add(r.id);drafts.delete(r.id);
          decided(task,r,operation==='checkpoint-yes'?'approved':'changes');await refresh();
        }
        else if(operation==='approve'||operation==='decline'){
          const r=pending(detail).find(r=>r.id===op.dataset.reviewId);if(!r)throw Error('This review ended. Refresh the task.');
          const body=reviewRequest(detail.id,r,drafts.get(r.id),operation);
          if(operation==='approve'&&(r.questions||[]).some(q=>!body.answers[q.id]?.[0]))throw Error('Answer each question to continue.');
          const task=detail;hold(r.id);
          await request(body);answered.add(r.id);drafts.delete(r.id);
          if(isApproval(r))decided(task,r,operation==='approve'?'approved':'disapproved');await refresh();
        }
        else if(['resume','pause','cancel','browser'].includes(operation)){let allowance={};if(operation==='resume'&&needsAllowance(detail)){const amount=Number(drafts.get(detail.id)?.allowance);if(!Number.isFinite(amount)||amount<0.1||amount>10)throw Error('Choose an additional Claude allowance from $0.10 to $10.');const draft=drafts.get(detail.id);draft.budgetAuthorizationID||=crypto.randomUUID();allowance={additionalBudgetUSD:amount,budgetAuthorizationID:draft.budgetAuthorizationID};}if(operation==='resume'&&detail.kind==='coding'&&detail.status==='completed'&&!drafts.get(detail.id)?.update?.trim())throw Error('Add what you want to change before continuing this coding session.');await request(operation==='resume'&&detail.kind==='coding'&&!allowance.additionalBudgetUSD?{operation:'coding',agentId:detail.agentId,arguments:{action:'continue',taskId:detail.id,goal:drafts.get(detail.id)?.update||'Continue the original task and reconcile current project files and command receipts before retrying interrupted work.'}}:{operation,taskId:detail.id,...allowance,message:operation==='resume'?(drafts.get(detail.id)?.update||(detail.kind==='coding'?'Continue the original task and reconcile current project files and command receipts before retrying interrupted work.':'')):''});if(operation==='resume')drafts.delete(detail.id);await refresh();}
      }
    }catch(e){showError(e);}finally{busy=false;document.querySelectorAll('[data-worker-panel] [data-worker-op], #worker-new-form button').forEach(b=>b.disabled=answered.has(b.dataset.reviewId));}
  });
  document.addEventListener('click',async e=>{const a=e.target.closest('[data-action]')?.dataset.action;if(view!=='preview'||!preview||!document.querySelector('.worker-document')||!['document-prev','document-next'].includes(a))return;try{preview=await request({operation:'preview',taskId:detail.id,path:preview.path,page:(preview.previewPage||1)+(a==='document-next'?1:-1)});document.querySelector('.worker-document').innerHTML=BuddyDocuments.preview(preview);}catch(e){showError(e);}});
  document.addEventListener('change',e=>{if(view==='preview'&&e.target.id==='document-sheet'&&preview&&document.querySelector('.worker-document'))document.querySelector('.worker-document').innerHTML=BuddyDocuments.preview(preview,Number(e.target.value));});
  setInterval(()=>{if(!busy&&!['new','routine-form'].includes(view)&&document.querySelector('[data-worker-panel]'))refresh();},2500);
  setInterval(()=>{if(!busy&&!document.querySelector('[data-worker-panel]')&&Date.now()-polled>=(live()?4500:14500))refresh(false);},5000);
  setTimeout(()=>refresh(false),1800);
  // The page draws the open chat before this file has loaded, so its task messages were drawn without being read (an answered approval still
  // offered "Review task"). Draw them again now that they can be.
  if(typeof ui!=='undefined'&&ui.view?.kind==='chat'&&typeof refreshLiveChat==='function')refreshLiveChat(ui.view.target);
})(typeof globalThis!=='undefined'?globalThis:this);

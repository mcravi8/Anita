(function(root){
  'use strict';
  const labels={queued:'Queued',running:'Working',waiting_review:'Needs review',waiting_user:'Needs you',paused:'Paused',interrupted:'Interrupted',completed:'Finished',failed:'Couldn’t finish',cancelled:'Cancelled'};
  // A coding task waiting for its own command on a machine one of its leases holds: Buddy watches it and continues the task when it ends.
  const remoteWait=t=>t?.status==='paused'&&t.blockedBy==='remote';
  const label=t=>remoteWait(t)?'Running remotely':labels[t?.status]||t?.status||'';
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
  const systemPause=t=>t?.status==='paused'&&t.blockedBy!=='limit'&&t.blockedBy!=='remote'&&!/^(user|routine|superseded)/.test(t.stopCause||'');
  // A sign-in the person answers in the chat (a password to type, a step to finish and confirm with Done, a service sign-in to save) has a
  // message of its own there (buddy-signin.js); the task's own message would only say it again.
  // An account an agent wants Buddy to create (or a password to reset) is asked in the chat too, and so is a sign-up stopped for money.
  const signinWait=t=>t?.status==='waiting_review'&&pending(t).length>0&&pending(t).every(r=>r.kind==='authentication'||r.kind==='account')||t?.status==='waiting_user'&&t.stopCause!=='review.parked'&&['signin','captcha','verification','credential','file','payment'].includes(t.checkpoint?.need);
  // A coding command waiting on the team supervisor's review is the supervisor's to answer, not the person's: it posts nothing in the chat. So
  // is a question a task put to its supervisor (a checkpoint sent to Chief, "Waiting for Chief: …"): it is not a detail the person owes.
  const supervisorWait=t=>t?.status==='waiting_review'&&pending(t).length>0&&pending(t).every(r=>r.route==='supervisor')||t?.status==='waiting_user'&&t.stopCause==='checkpoint.supervisor';
  const deliverable=t=>(['completed','failed','interrupted','waiting_review','waiting_user'].includes(t?.status)||systemPause(t)||remoteWait(t))&&t?.quiet!==true&&!signinWait(t)&&!supervisorWait(t);
  const deliveryID=t=>`worker-${t.id}-${Number(t.attempt)||0}-${t.status}${['waiting_review','waiting_user'].includes(t.status)?'-'+encodeURIComponent(t.attentionKey||t.progress||''):''}`;
  const attention=status=>['waiting_review','waiting_user'].includes(status);
  // Background work › Browser sign-in: one Chrome for every agent. `agents` are the workspace's agents, `using` the ids of those with
  // internet access (Web research on; Mac apps is about other apps on this Mac, not Buddy's Chrome), which use the accounts signed in here.
  const browserUsers=agents=>(Array.isArray(agents)?agents:[]).filter(a=>a&&a.tools?.web!==false).map(a=>a.id);
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
    return `<section class="worker-setup-once" aria-labelledby="worker-setup-title"><strong id="worker-setup-title">Set up once</strong><p>Sign in to your accounts in one Chrome window. Every agent with internet access will use the accounts you sign in to here. Internet access is Web research in an agent’s settings; Mac apps doesn’t need to be on.</p><p>You can sign in to as many websites and accounts as you like, including more than one Google account. Sign in to Chrome itself with your Google account to use Google Password Manager.</p>${open?`<p role="status"><strong>Chrome is open${open.taskId?' for a task':''}.</strong> Agents that need the browser wait until you press Done.</p><div class="worker-toolbar">${button('finish-signin','Done','',true)}${button('chrome-settings','Chrome account settings')}</div>`:`<div class="worker-toolbar">${button('open-google','Open Chrome','',true)}</div>`}${signedIn(accounts)}<small>${users.length?`Used by ${users.join(', ')}.`:'No agent has internet access yet.'}${without.length?` No browser for ${without.join(', ')} (internet access is off).`:''}</small></section>${old.length?`<p class="worker-legacy" role="alert">An older private Chrome window (${old.join(', ')}’s, from before every agent shared one Chrome) is still open. Close it yourself; Buddy won’t close it. Sign-ins made there don’t carry over.</p>`:''}`;
  }
  // Background work › Browser sign-in › Saved sign-ins: the service sign-ins agents' commands use (WRDS), as the app's sign-in bridge says
  // (`profiles`: [{id, name, saved}], null while it is asked). Replace (Add when none is saved) opens a private username and password field
  // here, drawn empty: what is typed goes from it to the bridge and nowhere else. Remove asks once before it removes.
  function savedSignins({profiles=null,editing='',removing='',busy='',note=''}={}){
    let out='<section class="worker-saved-signins" aria-labelledby="worker-saved-title"><strong id="worker-saved-title">Saved sign-ins</strong><p>Sign-ins your agents’ commands use, such as WRDS. Buddy keeps them in your Mac’s Keychain; agents never see them. If one is wrong, replace it here.</p>';
    if(!Array.isArray(profiles))return out+'<p class="worker-caption" role="status">Checking…</p></section>';
    const field=(id,name,label,type,max)=>`<label class="signin-field"><span>${label}</span><input type="${type}" data-saved-input="${name}" autocomplete="off" autocapitalize="off" autocorrect="off" spellcheck="false" maxlength="${max}" aria-label="${label}"></label>`;
    const press=(attr,id,label,primary=false,off=false)=>`<button type="button" class="${primary?'primary-button':'border-button'}" ${attr}="${id}" ${off?'disabled':''}>${label}</button>`;
    for(const p of profiles){
      if(!p||typeof p.id!=='string')continue;
      const id=html(p.id),name=html(p.name||p.id),off=!!busy;
      out+=`<div class="worker-saved-row" data-saved-profile="${id}"><span><strong>${name}</strong><small>${p.saved?'Saved':'Not saved'}</small></span>${editing===p.id||removing===p.id?'':`<span class="worker-toolbar">${press('data-saved-replace',id,p.saved?'Replace':'Add',false,off)}${p.saved?press('data-saved-remove',id,'Remove',false,off):''}</span>`}</div>`;
      if(editing===p.id)out+=`<div class="signin-holder signin-holder-pair worker-saved-holder" data-saved-holder="${id}">${field(id,'username',`${name} username`,'text',200)}${field(id,'password',`${name} password`,'password',1000)}<div class="worker-toolbar">${press('data-saved-cancel',id,'Cancel',false,off)}${press('data-saved-save',id,busy===p.id?'Saving…':'Save',true,off)}</div></div><small class="signin-assurance">What you type goes straight to your Mac’s Keychain and ${p.saved?`replaces the saved ${name} sign-in`:`becomes your saved ${name} sign-in`}. It isn’t kept on this page, and agents never see it.</small>`;
      if(removing===p.id)out+=`<div class="worker-saved-confirm" role="alert"><p>Remove the saved ${name} sign-in? Commands that sign in to ${name} will ask you to sign in again.</p><div class="worker-toolbar">${press('data-saved-cancel',id,'Cancel',false,off)}${press('data-saved-confirm-remove',id,busy===p.id?'Removing…':'Remove',true,off)}</div></div>`;
    }
    // Website passwords the person chose to remember in a chat's private field (buddy-website-signins.js), and the web services agents use
    // through Buddy (buddy-services.js), list themselves here.
    return out+(note?`<p class="worker-caption" role="status">${html(note)}</p>`:'')+(root.BuddyWebsiteSignIns?.section?.()||'')+(root.BuddyServices?.section?.()||'')+'</section>';
  }
  // The account a task must use (the person named it), as the task's details and the reply that started it say it.
  const accountLine=t=>typeof t?.account==='string'&&t.account?`Uses ${t.account}`:'';
  // Working now, at the top of Background work: every task running at this moment (several agents can work at once, each on one task),
  // oldest first, with its agent, and how many may run at once. Nothing when nothing runs.
  function runningNow({tasks=[],running=[],maxRunning=0,agents=[]}={}){
    const now=(Array.isArray(running)?running:[]).map(id=>tasks.find(t=>t.id===id)).filter(Boolean);
    if(!now.length)return '';
    const who=t=>html(agents.find(a=>a.id===t.agentId)?.name||'An agent'),limit=Number(maxRunning)||0;
    return `<section class="worker-running" data-worker-running aria-label="Working now"><strong>Working now${limit?` · ${now.length} of ${limit} at once`:''}</strong><ul>${now.map(t=>`<li><button type="button" class="menu-row" data-worker-task="${html(t.id)}"><span><strong>${html(t.title)}</strong><small>${who(t)}</small></span></button></li>`).join('')}</ul></section>`;
  }
  // Run at once, in Worker settings: how many tasks may run at the same time, from 1 to 6 (the worker refuses anything else).
  function runLimitField(maxRunning){
    const value=[1,2,3,4,5,6].includes(Number(maxRunning))?Number(maxRunning):3;
    return `<label class="field worker-run-limit"><span>Run at once</span><select data-worker-max-running>${[1,2,3,4,5,6].map(n=>`<option value="${n}" ${n===value?'selected':''}>${n===1?'One task at a time':`Up to ${n} tasks`}</option>`).join('')}</select><small>Each agent works on one task at a time; its other tasks wait for it. More at once finishes sooner and uses more of this Mac.</small></label>`;
  }
  function taskReceipts(tasks=[]){
    return (Array.isArray(tasks)?tasks:[]).filter(t=>t&&typeof t.id==='string'&&accountLine(t)).map(t=>`<div class="task-receipt"><span><strong>${html(t.title||'Background task')}</strong><small>${html(accountLine(t))}</small></span><button type="button" data-worker-task="${html(t.id)}" aria-label="View task ${html(t.title||'')}">View task</button></div>`).join('');
  }
  function taskMessage(t){
    const auth=pending(t).find(r=>r.kind==='authentication');
    if(t.status==='waiting_review'&&auth)return auth.mode==='signup'?'I need your approval to create this account.':'Please sign in to continue.';
    // A request to a connected service, or files for a leased machine: what it is, and the most it can cost.
    const service=pending(t).find(r=>r.kind==='service'&&r.route!=='supervisor'),upload=pending(t).find(r=>r.kind==='upload');
    if(t.status==='waiting_review'&&service){const q=service.request||{},most=q.cost?.maxCostUSD;return `I need your OK for a request to ${plain(q.service)||'a service'}${typeof most==='number'?`: at most ${money(most)}`:''}.`;}
    if(t.status==='waiting_review'&&upload)return `I need your OK to send project files to ${plain(upload.upload?.host)||'a remote machine'}.`;
    // The status Buddy sends has no reviews, only the progress line it wrote for this wait ("Waiting for your OK for a request to RunPod:
    // at most $7.68"): the chat says that, in the agent's voice.
    const asked=String(t.progress||'').split('\n')[0].trim().match(/^Waiting for your OK ((?:for|to) .{1,200})$/);
    if(t.status==='waiting_review'&&asked)return `I need your OK ${asked[1].replace(/[.\s]+$/,'')}.`;
    // The chat draws its message again from what it said (presentation): that sentence stays as it is.
    if(t.status==='waiting_review'&&/^I need your OK (for|to) .{1,220}\.$/.test(String(t.progress||'').trim()))return String(t.progress).trim();
    if(remoteWait(t))return `**${String(t.title||'This task').slice(0,90)}** is running on a remote machine. I’ll continue when it’s done.`;
    if(t.status==='waiting_review')return 'I need your approval to continue.';
    if(t.status==='waiting_user'&&(/private|sign.?in/i.test(t.progress||'')||t.signInOrigin))return 'Please sign in in Buddy’s Chrome window, then press Done.';
    const progress=String(t.progress||'').split('\n')[0].trim();
    // A line the worker writes while a task runs ("Working on your request") says nothing about what the task is waiting for.
    const brief=progress.length<=160&&!/\b[0-9a-f]{8}-[0-9a-f-]{27,}\b|\b\d\d:\d\d:\d\dZ\b/i.test(progress)&&!/^(Queued|Working on (your request|the website))\.?$/i.test(progress)?progress:'';
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
  const money=v=>`$${Number(v).toFixed(2)}`;
  const hours=h=>{const n=Number(h)||0;if(n<1){const m=Math.round(n*60);return `${m} minute${m===1?'':'s'}`;}const t=Number.isInteger(n)?String(n):n.toFixed(1);return `${t} hour${n===1?'':'s'}`;};
  const size=b=>{let v=Number(b)||0,u=0;const units=['bytes','KB','MB','GB'];while(v>=1000&&u<units.length-1){v/=1000;u++;}return u?`${v<10?v.toFixed(1):Math.round(v)} ${units[u]}`:`${v} bytes`;};
  // A request to a connected service, or files for a leased machine, in everyday words: what, why, and the facts the card lists one per line
  // (the exact request, the agent's cost estimate, what Buddy deletes and when, what will be uploaded).
  // Paths and addresses keep their underscores and slashes (the card escapes what it shows).
  const line=value=>String(value??'').replace(/\s+/g,' ').trim();
  function serviceRequest(r){
    if(r?.kind==='upload'){
      const u=r.upload||{},files=Array.isArray(u.files)?u.files:[],count=files.reduce((n,f)=>n+(Number(f.files)||0),0);
      return {what:`send ${count} project file${count===1?'':'s'} to ${line(u.host)||'a remote machine'}`,why:plain(u.reason),caution:'These files leave this Mac.',
        facts:[`To: ${line(u.lease)||line(u.host)}`,...files.map(f=>`Sends: ${line(f.path)} (${Number(f.files)||0} files, ${size(f.bytes)})`)]};
    }
    const q=r?.request||{},service=plain(q.service)||'a service',facts=[];
    const query=q.query&&typeof q.query==='object'?Object.entries(q.query).map(([k,v])=>`${k}=${v}`).join('&'):'';
    facts.push(`Request: ${plain(q.method)} ${String(q.baseUrl||'').trim()}${String(q.path||'').trim()}${query?'?'+query:''}`);
    if(q.cost){const c=q.cost;facts.push(`Cost (${plain(q.agent)||'the agent'}’s estimate): ${typeof c.perHour==='number'?`${money(c.perHour)} an hour, `:''}${typeof c.total==='number'?`${money(c.total)} in all, `:''}for at most ${hours(c.maxHours)}: at most ${money(c.maxCostUSD)}`);}
    if(q.lease)facts.push(`Cleanup: Buddy calls ${line(q.lease.teardown)} when ${plain(q.agent)||'the agent'} is done, when the task ends, and after ${hours(q.lease.maxHours)} at the latest`);
    const uploads=Array.isArray(q.uploads)?q.uploads:[];
    if(uploads.length)facts.push(`Uploads to it: ${uploads.map(u=>`${line(u.path)} (${Number(u.files)||0} files, ${size(u.bytes)})`).join(', ')}`);
    return {what:`send a ${plain(q.method)} request to ${service}`,why:plain(q.reason),caution:q.charges?`${service} can charge you money.`:'',facts,body:typeof q.body==='string'?q.body:''};
  }
  function plainRequest(r){
    if(r?.kind==='service'||r?.kind==='upload')return serviceRequest(r);
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
  // An approval or a question is in the chat only while it waits on the person. Once it is answered (on the task's page, or by the supervisor),
  // or its task has moved on (it runs again, was cancelled or finished, or now waits on the supervisor), it leaves the chat; the task's page
  // keeps what was decided, and the message keeps it too (its body is the decision line). `tasks` are the tasks as the worker's last status
  // listed them, or null when that is not known: a waiting message then stays until a newer one about its task arrives.
  function presentation(state,m,tasks=tasksNow(state)){
    if(!m.workerTaskID)return {body:m.body,hidden:false};
    if(m.workerDecision)return {body:decisionLine(m.workerDecision),hidden:true,decided:true};
    const messages=state.messages[m.who]||[],index=messages.indexOf(m),asks=attention(m.workerStatus);
    const superseded=asks&&index>=0&&messages.slice(index+1).some(n=>n.workerTaskID===m.workerTaskID);
    const t=asks&&Array.isArray(tasks)?tasks.find(x=>x?.id===m.workerTaskID):null;
    const sameRun=t&&(typeof m.workerAttempt!=='number'||(Number(t.attempt)||0)===m.workerAttempt);
    const moved=asks&&Array.isArray(tasks)&&!(sameRun&&t.status===m.workerStatus&&deliverable(t));
    return {body:asks?taskMessage({status:m.workerStatus,progress:m.body}):m.body,hidden:superseded||moved};
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
  // A finished task's report on its page, for the person to take in at a glance: its opening, the lines that link the files it saved and
  // what comes next stay in view; the working notes (commands run, choices made, the command receipts Buddy adds after a rule) fold under
  // Full report. Null for a short report, which shows as it is. `more` is the rest of the report as written, so its lists and code survive.
  function reportParts(text){
    const all=String(text||'').trim();if(!all)return null;
    const cut=all.search(/\n[ \t]*-{3,}[ \t]*(\n|$)/),body=(cut<0?all:all.slice(0,cut)).trim(),receipts=cut<0?'':all.slice(cut).replace(/^\s*-{3,}\s*/,'').trim();
    let rest=body,next='';
    const said=rest.match(/(?:\*\*Next:\*\*|(?:^|(?<=[\s.]))Next:)[ \t]*([^\n]+)/);
    if(said){next=said[1].trim();rest=(rest.slice(0,said.index)+rest.slice(said.index+said[0].length)).replace(/[ \t]+$/gm,'');}
    const lines=rest.split('\n').map(l=>l.trim()).filter(Boolean);
    if(all.length<600&&lines.length<=3)return null;
    const lead=lines[0],saved=lines.slice(1).filter(l=>/\]\(/.test(l)&&!/^(\*\*)?(Commands? run|Choices made|Checks?)\b/i.test(l));
    let more=rest;for(const l of [lead,...saved])more=more.replace(l,'');
    more=[more.replace(/\n{3,}/g,'\n\n').trim(),receipts].filter(Boolean).join('\n\n');
    return {lead,saved,next,more};
  }
  // Background work as the Work page lists it: one row per piece of work. The runs of one plan task (each dispatch is a new task) are one
  // row, its latest run, with the earlier runs counted under it; other tasks are a row each. Rows that need the person come first, then what
  // is running or waiting its turn, then what has finished. Within each, the newest first.
  const NEEDS=new Set(['waiting_review','waiting_user','failed','interrupted']),RUNNING=new Set(['queued','starting','running','stopping','paused']);
  function workGroups(tasks=[]){
    const groups=new Map(),stamp=t=>Date.parse(t?.updatedAt||t?.createdAt||'')||0;
    (Array.isArray(tasks)?tasks:[]).forEach((t,order)=>{
      if(!t?.id)return;const key=t.planTaskId?'plan:'+t.planTaskId:'task:'+t.id;
      const g=groups.get(key)||{key,runs:[]};g.runs.push({t,order});groups.set(key,g);
    });
    const rows=[...groups.values()].map(g=>{
      const runs=g.runs.sort((a,b)=>stamp(b.t)-stamp(a.t)||b.order-a.order).map(r=>r.t),latest=runs[0];
      const earlier=runs.slice(1),count=status=>earlier.filter(t=>t.status===status).length;
      return {key:g.key,latest,earlier:earlier.length,finished:count('completed'),cancelled:count('cancelled'),
        section:NEEDS.has(latest.status)?'needs':RUNNING.has(latest.status)?'running':'finished',at:stamp(latest)};
    }).sort((a,b)=>b.at-a.at);
    return {needs:rows.filter(r=>r.section==='needs'),running:rows.filter(r=>r.section==='running'),finished:rows.filter(r=>r.section==='finished')};
  }
  // The tasks the worker's last status listed, for the chat's waiting messages (set by the page below; null in a test, or before it is known).
  let tasksNow=()=>null;
  const api={reportParts,workGroups,labels,label,remoteWait,canResume,needsAllowance,pending,unconfirmed,authTitle,systemPause,signinWait,deliverable,deliveryID,deliverResult,taskMessage,presentation,isApproval,reviewRequest,requestTitle,plainRequest,supervisorWait,recordDecision,reconcile,reviewIds,setupOnce,accountLine,taskReceipts,browserUsers,savedSignins,runningNow,runLimitField};root.BuddyWorkerUI=api;if(typeof module!=='undefined')module.exports=api;
  if(typeof document==='undefined')return;
  let snapshot={online:false,tasks:[],routines:[],paused:false},detail=null,view='list',routine=null,busy=false,error='',last='',preview=null;
  tasksNow=s=>snapshot.online===true&&Array.isArray(snapshot.tasks)&&(!snapshot.workspace||snapshot.workspace===s?.conversationWorkspace)?snapshot.tasks:null;
  // The chat list's line under a name reads the latest message still in the chat: a request that has left it (answered, or its task moved
  // on) is not what the chat says now. chatSummary (app.js) reads the chat's messages from the workspace, so for that one call it is handed
  // them without the trailing ones that draw nothing.
  if(typeof window.chatSummary==='function'){
    const summary=window.chatSummary;
    window.chatSummary=function(target){
      const list=state.messages?.[target];if(!Array.isArray(list)||typeof window.messageHTML!=='function')return summary.apply(this,arguments);
      let end=list.length;while(end>0&&list[end-1]?.who&&!window.messageHTML(list[end-1]))end--;
      if(end===list.length)return summary.apply(this,arguments);
      state.messages[target]=list.slice(0,end);try{return summary.apply(this,arguments);}finally{state.messages[target]=list;}
    };
  }
  // A poll can settle what a waiting message asked (its task moved on): the open chat drops the message then, not at its next redraw.
  window.addEventListener('buddy-worker-snapshot',()=>{
    if(typeof ui==='undefined'||ui.view?.kind!=='chat'||typeof refreshLiveChat!=='function')return;
    const drawn=new Set([...document.querySelectorAll('#messages > [data-chat-item]')].map(e=>e.dataset.chatItem));
    if((state.messages[ui.view.target]||[]).some(m=>m?.workerTaskID&&attention(m.workerStatus)&&drawn.has(m.id)&&presentation(state,m).hidden))refreshLiveChat(ui.view.target);
  });
  const drafts=new Map();
  // Saved sign-ins (Browser sign-in): the page knows only which are saved. What is typed lives in its field alone, until Save hands it to the
  // app's sign-in bridge; it never goes into the workspace, drafts, browser storage or the worker bridge.
  const freshSignins=()=>({profiles:null,editing:'',removing:'',busy:'',note:''});
  let signins=freshSignins();
  // Reviews answered from this page: their buttons stay off, so a second click cannot answer the same review again.
  const answered=new Set();
  const ordered=value=>Array.isArray(value)?value.map(ordered):value&&typeof value==='object'?Object.fromEntries(Object.keys(value).sort().map(k=>[k,ordered(value[k])])):value;
  const detailKey=()=>JSON.stringify(ordered([detail,snapshot.privateBrowser]));
  const key=()=>`buddy.worker.draft.${state.conversationWorkspace}`;
  function loadDraft(){try{return JSON.parse(localStorage.getItem(key()))||{};}catch{return {};}}
  const request=payload=>{if(!window.BuddyDesktop?.worker)throw Error('Open Buddy’s Mac app to use background work.');return window.BuddyDesktop.worker(payload);};
  const button=(op,label,extra='',primary=false)=>`<button type="button" class="${primary?'primary-button':'border-button'}" data-worker-op="${op}" ${extra} ${busy?'disabled':''}>${label}</button>`;
  // Background work is a page of the app, not a side panel: each of its views (the list, a task, a routine, a form, the sign-ins) is drawn on
  // it. A task opened from a chat (Review task, a receipt) or the sign-ins opened from Settings is a dialog over where the person is, so they
  // answer it and stay there; its way back to the list goes to the page.
  let pageBody='',where='page';
  const onPage=()=>typeof ui!=='undefined'&&ui.view?.kind==='work';
  const dialog=()=>where==='dialog'&&!onPage();
  function shell(body){
    pageBody=`<div class="worker-panel" data-worker-panel>${body}<p class="field-error" data-worker-error role="alert">${esc(error)}</p></div>`;
    if(dialog()){openModal('Background work',pageBody);document.querySelector('#modal-root .modal')?.classList.add('worker-dialog');return;}
    if(document.querySelector('#modal-root .modal-overlay'))closeModal();
    if(onPage())paintPage();else navigate('work');
  }
  function paintPage(){
    const layout=document.querySelector('.content-layout');if(!onPage()||!layout)return;
    let page=layout.querySelector(':scope > [data-work-page]');
    if(!page){layout.innerHTML=`<section class="center work-page" data-work-page aria-labelledby="work-page-title"><div class="page-scroll"><div class="work-page-inner"><div class="page-title-row"><div><h1 id="work-page-title" tabindex="-1">Background work</h1><p>What your team is doing on this Mac, one row for each piece of work.</p></div></div><div data-work-body></div></div></div></section>`;page=layout.querySelector(':scope > [data-work-page]');}
    document.querySelectorAll('[data-action="background-work"].worker-nav').forEach(b=>b.setAttribute('aria-current','page'));
    const at=page.querySelector('[data-work-body]');if(at._html===pageBody)return;
    const scroller=page.querySelector('.page-scroll'),top=scroller.scrollTop,focus=at.contains(document.activeElement)?document.activeElement:null;
    at.innerHTML=pageBody;at._html=pageBody;
    // A redraw of the same view keeps its place; a new view starts at the top.
    scroller.scrollTop=page.dataset.view===view?top:0;page.dataset.view=view;
    if(focus&&!at.contains(focus))page.querySelector('h1')?.focus({preventScroll:true});
  }
  // The app draws the page's frame for any view it does not know; the page is put in it, as it was last drawn, or as the list.
  window.addEventListener('buddy-view-updated',()=>{if(!onPage())return;if(pageBody)paintPage();else{view='list';list();refresh();}});
  function privateBanner(){
    const open=snapshot.privateBrowser;if(!open)return '';
    if(open.legacy)return `<section class="worker-private" role="status"><strong>An older private Chrome window may be open</strong><p>${who(open.agentId)} used it before every agent shared one Chrome. Close that window yourself, then press Done.</p>${button('finish-signin','Done','',true)}</section>`;
    return `<section class="worker-private" role="status"><strong>Buddy’s Chrome window is open</strong><p>${open.agentId&&findAgent(open.agentId)?`${who(open.agentId)} is waiting. `:''}Sign in there; agents that need the browser wait until you press Done.</p>${button('finish-signin','Done','',true)}${button('chrome-settings','Chrome account settings')}<small>Done closes the window and lets Buddy check the website again.</small></section>`;
  }
  function profiles(){shell(`<h3>Browser sign-in</h3>${setupOnce({agents:state.agents,using:snapshot.browserAgents||browserUsers(state.agents),open:snapshot.privateBrowser&&!snapshot.privateBrowser.legacy?snapshot.privateBrowser:null,legacy:snapshot.legacyChrome||[],accounts:snapshot.chromeAccounts||null,button})}${snapshot.privateBrowser?.legacy?privateBanner():''}${savedSignins(signins)}<details class="worker-more"><summary>How it works${icon('down')}</summary><p>Buddy’s Chrome window has no agent connection. Sign in through Chrome’s profile controls to make your saved Google passwords available; Gmail website sign-in alone may not turn on Password Manager.</p><p>All agents share this one private Chrome profile, each working in its own tab. Your normal Chrome and the separate profiles earlier versions of Buddy used are left as they are.</p><p>When an agent needs a password Chrome hasn’t saved, it asks in its chat with a private field: what you type there goes only into that website’s sign-in page, never into the chat. Steps on your phone or in this window end with a Done button.</p><p>Passwords, password-manager contents, and sign-in forms are kept out of what agents see. New accounts, recovery, security settings and payments always need you.</p></details>`);}
  function paintSignins(){const at=document.querySelector('[data-worker-panel] .worker-saved-signins');if(at)at.outerHTML=savedSignins(signins);}
  async function loadSignins(paint=true){
    try{if(!window.BuddyDesktop?.signin)throw Error('Open Buddy on this Mac to see your saved sign-ins.');const r=await window.BuddyDesktop.signin({action:'status'});signins.profiles=Array.isArray(r?.profiles)?r.profiles:[];}
    catch(e){signins.profiles=[];signins.note=String(e?.message||e);}
    if(paint&&view==='profiles')paintSignins();
  }
  const signinName=id=>signins.profiles?.find(p=>p.id===id)?.name||id;
  async function saveSignin(id){
    const holder=[...document.querySelectorAll('[data-saved-holder]')].find(h=>h.dataset.savedHolder===id);if(!holder||signins.busy)return;
    const inputs=[...holder.querySelectorAll('[data-saved-input]')],values=Object.fromEntries(inputs.map(i=>[i.dataset.savedInput,i.value]));
    if(!String(values.username||'').trim()||!values.password){(inputs.find(i=>!i.value)||inputs[0])?.focus();return;}
    // The fields are emptied before anything else happens; the values exist only in this call until the app has them.
    for(const i of inputs)i.value='';
    const name=signinName(id);signins.busy=id;signins.note='';paintSignins();
    let reply;
    try{if(!window.BuddyDesktop?.signin)throw Error('Open Buddy on this Mac to save a sign-in.');reply=await window.BuddyDesktop.signin({action:'provide',profile:id,username:values.username,password:values.password});}
    catch(e){reply={saved:false,error:String(e?.message||e)};}
    finally{values.username='';values.password='';signins.busy='';}
    if(reply?.saved){signins.editing='';signins.note=`Saved. Commands that sign in to ${name} use the new sign-in from now on.`;await loadSignins(false);}
    else signins.note=reply?.error||'That didn’t save, so nothing changed. Try again.';
    paintSignins();
  }
  async function removeSignin(id){
    if(signins.busy)return;
    const name=signinName(id);signins.busy=id;signins.note='';paintSignins();
    let reply;
    try{if(!window.BuddyDesktop?.signin)throw Error('Open Buddy on this Mac to remove a sign-in.');reply=await window.BuddyDesktop.signin({action:'remove',profile:id});}
    catch(e){reply={error:String(e?.message||e)};}
    finally{signins.busy='';}
    if(reply&&reply.saved===false&&!reply.error){signins.removing='';signins.note=`Removed. Commands that sign in to ${name} will ask you to sign in again.`;await loadSignins(false);}
    else signins.note=reply?.error||'That didn’t remove it. Try again.';
    paintSignins();
  }
  function workRow(r){
    const t=r.latest,plan=(snapshot.plans||[]).find(p=>p?.id===t.planId),stage=(plan?.stages||[]).find(s=>s?.id===t.stageId);
    const where=[agentName(t.agentId),t.kind==='coding'?'coding session':'',plan?(state.groups||[]).find(g=>g.id===plan.groupId)?.name||'':'',stage?`Stage ${stage.n}`:''].filter(Boolean).join(' · ');
    const before=r.earlier?`<span class="work-earlier">${r.earlier} earlier ${r.earlier===1?'run':'runs'}${r.finished||r.cancelled?`: ${[r.finished?`${r.finished} finished`:'',r.cancelled?`${r.cancelled} cancelled`:''].filter(Boolean).join(', ')}`:''}</span>`:'';
    const said=r.section!=='finished'&&t.progress?`<span class="work-progress">${esc(String(t.progress).slice(0,160))}</span>`:'';
    return `<button class="work-row work-${r.section}" data-worker-task="${esc(t.id)}">${findAgent(t.agentId)?avatar(t.agentId):icon('spark')}<span class="work-copy"><strong>${esc(t.title)}</strong><small>${esc(where)}</small>${said}${before}</span><span class="work-status">${r.section==='finished'&&t.status==='completed'?icon('check'):''}${esc(label(t))}</span></button>`;
  }
  function list(){
    const groups=workGroups(snapshot.tasks),section=(name,title,rows)=>rows.length?`<section class="work-section work-section-${name}" aria-label="${title}"><h2>${title}<span>${rows.length}</span></h2><div class="work-rows">${rows.map(workRow).join('')}</div></section>`:'';
    const any=groups.needs.length+groups.running.length+groups.finished.length;
    const offline=snapshot.online?'':`<section class="work-offline" role="status"><p><strong>Background work is paused:</strong> Buddy’s worker isn’t running. Nothing is lost; each task continues where it stopped.</p>${button('start','Start worker','',true)}</section>`;
    shell(`${offline}${snapshot.scheduleError?`<p class="field-error" role="alert">${esc(snapshot.scheduleError)}</p>`:''}${privateBanner()}${snapshot.online?`<div class="worker-toolbar"><span class="worker-state online">${snapshot.paused?'Paused':'This Mac'}</span>${button('new','New task','',true)}</div>${runningNow({tasks:snapshot.tasks,running:snapshot.running,maxRunning:snapshot.maxRunning,agents:state.agents})}`:''}${any?`${section('needs','Needs you',groups.needs)}${section('running','Running',groups.running)}${section('finished','Finished',groups.finished)}`:'<div class="worker-empty"><span>✦</span><h3>Leave something with your Buddy</h3><p>Research a topic, prepare an application, or handle an email.</p></div>'}${routineList()}<details class="worker-more"><summary>Worker settings${icon('down')}</summary>${snapshot.online?runLimitField(snapshot.maxRunning):''}<p>Uses a separate Chrome profile and task folders. The worker keeps running when you quit Buddy. This Mac needs to stay awake and online.</p><div class="worker-toolbar">${snapshot.online?button('pauseAll',snapshot.paused?'Resume queue':'Pause queue'):''}${button('refresh','Refresh')}${button('profiles','Browser sign-in')}</div><p>New tasks use the agent’s saved model. Manage connections and the starting provider for new agents in Settings.</p><button type="button" class="border-button" data-action="provider-settings">AI provider settings</button><p class="worker-caption">Credits are used before paid balance. Console funding and auto-reload settings determine what happens when credits run out.</p></details>`);
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
    // Answered only in the agent's chat, with a click on its card: nothing to answer here.
    if(r.kind==='account')return `<section class="worker-review worker-auth"><strong>${r.purpose==='reset'?'Reset your password':'Create an account'}</strong><small>${esc(r.origin||'')}${r.accountEmail?` · ${esc(r.accountEmail)}`:''}</small>${r.reason?`<p>${esc(r.reason)}</p>`:''}<p class="worker-caption">Answer in ${esc(agentName(detail?.agentId||'')||'the agent')}’s chat: ${r.purpose==='reset'?'Reset password':'Create account'} or Don’t. Buddy never pays or starts a paid trial.</p></section>`;
    if(r.kind==='authentication')return `<section class="worker-review worker-auth"><strong>${esc(authTitle(r.mode))}</strong><small>${esc(r.origin)}${r.accountEmail?` · ${esc(r.accountEmail)}`:''}</small><p>${esc(r.reason||'Continue your requested task.')}</p><p class="worker-caption">${r.mode==='signup'?'Choose or generate the new credential in Buddy’s Chrome window. Chrome can save it to Google Password Manager.':`Chrome keeps passwords private. You can also type the password in ${esc(agentName(detail?.agentId||''))}’s chat, in a private field that goes only to this website. Buddy receives the sign-in result.`} Allow email verification for this website during this sign-in.</p><div class="worker-toolbar">${button('auth-decline','Not now',`data-review-id="${esc(r.id)}"`)}${r.mode==='signin'?button('auth-saved','Use saved login',`data-review-id="${esc(r.id)}"`):''}${r.mode==='verification'?button('auth-verify','Verify email',`data-review-id="${esc(r.id)}"`,true):''}${button('auth-private',r.mode==='signup'?'Create privately':'Open privately',`data-review-id="${esc(r.id)}"`,r.mode!=='verification')}</div></section>`;
    const args={...r.tool?.arguments};const body=BuddyActions.messagePreview(args.payload);if(body)args.message=body;
    const data=Object.entries(args).filter(([k])=>!['payload'].includes(k));
    // An approval is answered with Approve or Disapprove; its question is shown as what the buttons answer. Any other question keeps its input.
    const approval=isApproval(r),off=answered.has(r.id)?'disabled':'';
    // A coding command reads as one line of what it wants to do and why; the command itself is under Details.
    const said=approval&&plainRequest(r);
    if(said)return `<section class="worker-review worker-plain-request" data-worker-review="${esc(r.id)}"><strong>${esc(agentName(detail?.agentId||'')||'The agent')} wants to ${esc(said.what)}.</strong>${said.why?`<p>Why: ${esc(said.why)}.</p>`:''}${said.facts?.length?`<ul class="worker-review-facts">${said.facts.map(f=>`<li>${esc(f)}</li>`).join('')}</ul>`:''}${said.body?`<pre class="worker-review-body">${esc(said.body)}</pre>`:''}${said.caution?`<small class="worker-review-caution">${esc(said.caution)}</small>`:''}<details class="worker-review-details"><summary>Details</summary>${data.length?`<dl>${data.map(([k,v])=>`<div><dt>${esc(k.replace(/_/g,' '))}</dt><dd>${esc(typeof v==='string'?v:JSON.stringify(v,null,2))}</dd></div>`).join('')}</dl>`:''}</details><div class="worker-toolbar">${button('decline','Disapprove',`data-review-id="${esc(r.id)}" ${off}`)}${button('approve','Approve',`data-review-id="${esc(r.id)}" ${off}`,true)}</div></section>`;
    const asked=(r.questions||[]).map(q=>approval&&approvalQuestion(q)?`<p class="worker-review-question">${esc(q.question)}</p>`:`<fieldset><legend>${esc(q.question)}</legend>${q.options?.length?`<select data-worker-question="${esc(q.id)}"><option value="">Choose…</option>${q.options.map(o=>`<option value="${esc(o.label)}" ${drafts.get(r.id)?.[q.id]===o.label?'selected':''}>${esc(o.label==='Accept'?'Approve once':o.label)}</option>`).join('')}</select>`:`<textarea data-worker-question="${esc(q.id)}" rows="3" maxlength="10000">${esc(drafts.get(r.id)?.[q.id]||'')}</textarea>`}</fieldset>`).join('');
    return `<section class="worker-review" data-worker-review="${esc(r.id)}"><strong>${esc(r.tool?.name||'Review action')}</strong><small>${esc(r.tool?.service||'Buddy private browser')}</small>${data.length?`<dl>${data.map(([k,v])=>`<div><dt>${esc(k.replace(/_/g,' '))}</dt><dd>${esc(typeof v==='string'?v:JSON.stringify(v,null,2))}</dd></div>`).join('')}</dl>`:''}${asked}<div class="worker-toolbar">${button('decline',approval?'Disapprove':'Cancel action',`data-review-id="${esc(r.id)}" ${off}`)}${button('approve',approval?'Approve':'Continue',`data-review-id="${esc(r.id)}" ${off}`,true)}</div></section>`;
  }
  // What the task's leases created on connected services, and where each stands (Buddy deletes them; a problem is said plainly).
  function leaseList(t){
    const list=Array.isArray(t.leases)?t.leases:[];if(!list.length)return '';
    const state={active:'Held',releasing:'Being deleted',released:'Deleted',void:'Nothing created',unknown:'Check the service',creating:'Being created'};
    return `<section class="worker-leases" aria-label="What this task created"><strong>Created on connected services</strong><ul>${list.map(l=>`<li><span>${esc(l.serviceName||l.service||'')} ${esc(l.resource||'')}</span><small>${esc(state[l.state]||l.state||'')}${typeof l.estimatedCostUSD==='number'?` · about ${money(l.estimatedCostUSD)} by the agent’s estimate`:''}${l.problem?` · ${esc(l.problem)}`:''}${l.lastError&&l.state==='releasing'?` · ${esc(l.lastError)}`:''}</small></li>`).join('')}</ul></section>`;
  }
  // The line under the status, unless it only says the status again ("Finished", "Finished").
  function progressLine(t){
    const said=needsAllowance(t)?'Choose an additional Claude allowance to continue this task. Previous unconfirmed usage stays recorded.':String(t.progress||'').trim();
    const same=s=>s.toLowerCase().replace(/[.!\s]+$/,'');
    return said&&same(said)!==same(label(t))?`<p class="worker-progress">${esc(said)}</p>`:'';
  }
  // The task's report (reportParts): what the person needs first, the rest one click away. The project's files are in the chat's Files view;
  // the ones the report names are linked from it.
  const reportOpen=new Set();
  function resultHTML(t){
    const md=s=>BuddyMarkdown.render(s,{files:t.files}),parts=reportParts(t.result);
    if(!parts)return `<article class="reply-markdown worker-result">${md(t.result)}</article>`;
    return `<article class="reply-markdown worker-result worker-report"><div class="worker-report-lead">${md(parts.lead)}</div>${parts.saved.length?`<div class="worker-report-saved">${md(parts.saved.join('\n\n'))}</div>`:''}${parts.next?`<div class="worker-report-next"><span>Next</span>${md(parts.next)}</div>`:''}${parts.more?`<details class="worker-report-more" data-worker-report="${esc(t.id)}"${reportOpen.has(t.id)?' open':''}><summary>Full report${typeof icon==='function'?icon('down'):''}</summary>${md(parts.more)}</details>`:''}</article>`;
  }
  document.addEventListener('toggle',e=>{const d=e.target;if(d?.matches?.('[data-worker-report]'))d.open?reportOpen.add(d.dataset.workerReport):reportOpen.delete(d.dataset.workerReport);},true);
  function taskBody(t){
    return `<div class="worker-task-heading">${findAgent(t.agentId)?avatar(t.agentId):''}<div><h3>${esc(t.title)}</h3><small>${esc(agentName(t.agentId))} · ${t.provider==='claude'?'Claude credits':'ChatGPT'}${accountLine(t)?` · <span class="worker-account">${esc(accountLine(t))}</span>`:''}</small></div></div><p class="worker-status" role="status">${esc(label(t))}</p>${leaseList(t)}${progressLine(t)}${snapshot.privateBrowser?.taskId===t.id?privateBanner():''}${pending(t).map(review).join('')}${unconfirmed(t).map(unconfirmedCard).join('')}${typeof reviewCoverage==='function'?reviewCoverage(t.coverage):''}${t.result?resultHTML(t):''}<div>${needsAllowance(t)&&canResume(t.status,t.kind)&&snapshot.privateBrowser?.taskId!==t.id?`<label class="field"><span>Additional Claude allowance (USD)</span><input type="number" min="0.10" max="10" step="0.10" data-worker-allowance aria-label="Additional Claude allowance in USD" value="${esc(drafts.get(t.id)?.allowance||'')}" placeholder="Choose an amount"><small>Authorizes this attempt only. Earlier unconfirmed usage: $${Number((t.reservedBudgetUSD||0)+(t.uncertainBudgetUSD||0)).toFixed(2)}.</small></label>`:''}${canResume(t.status,t.kind)&&snapshot.privateBrowser?.taskId!==t.id?`<label class="field"><span>What should they do next?</span><textarea data-worker-update rows="3" maxlength="10000" placeholder="Add a missing detail, answer a question, or say what you changed in the browser.">${esc(drafts.get(t.id)?.update||'')}</textarea></label>`:''}</div><div class="worker-toolbar">${canResume(t.status,t.kind)&&snapshot.privateBrowser?.taskId!==t.id?button('resume',t.kind==='coding'?'Continue coding':needsAllowance(t)?'Resume with this allowance':'Resume task','',true):''}${['queued','running','waiting_review'].includes(t.status)?button('pause','Pause'):''}${!['completed','cancelled'].includes(t.status)?button('cancel','Cancel task'):''}</div><details class="worker-more"><summary>Task details${icon('down')}</summary><p class="worker-brief">${esc(t.goal||'')}</p><p class="worker-caption">Saved ${esc(new Date(t.updatedAt).toLocaleString())}${t.spentUSD!=null?` · Estimated Claude usage $${Number(t.spentUSD).toFixed(4)}`:''}</p>${t.kind==='coding'?`<p class="worker-caption">Project: ${esc(t.codingProject||'Private task files')} · Saved coding context${t.codingSessionID?' available':''}</p>${t.commands?.length?`<details class="worker-receipt"><summary>Commands & checks${t.archivedCommands?` (the last ${esc(t.commands.length)}; ${esc(t.archivedCommands)} earlier are kept in the task’s history)`:''}</summary>${t.commands.map(c=>`<details><summary>${esc(c.code)} · ${c.status==='completed'?`exit ${esc(c.exitCode??c.signal??'unknown')}${c.timedOut?' · timed out':''}`:esc(c.status)}</summary><pre>${esc(c.output||'')}</pre></details>`).join('')}</details>`:''}`:`${button('browser','Open task browser')}<p class="worker-caption">Opens Buddy’s Chrome window at this task’s page. Agents’ pages wait while it is open; press Done when you’re finished.</p>`}${t.events?.length?`<details class="worker-receipt"><summary>Work activity</summary><ul>${t.events.map(e=>`<li>${esc(e.tool)} · ${esc(e.status)}</li>`).join('')}</ul></details>`:''}${(t.reviews||[]).filter(r=>r.status!=='pending').map(r=>`<details class="worker-receipt"><summary>${esc(r.tool?.name||'Action')} · ${esc(r.status)}</summary><pre>${esc(JSON.stringify(r.receipt||r.tool?.arguments||{},null,2))}</pre></details>`).join('')}</details>`;
  }
  function drawDetail(){shell(`${button('back','← All tasks')}<div data-worker-live>${taskBody(detail)}</div>`);last=detailKey();}
  // Both answers go off the moment one is chosen, so a double click cannot answer twice while the first answer is on its way.
  function hold(reviewId){document.querySelectorAll(`[data-worker-review="${CSS.escape(reviewId)}"] [data-worker-op]`).forEach(b=>{b.disabled=true;});}
  // The chat's approval message now says what was decided. It is saved with the chat, so it reads the same after a reload.
  function chatChanged(){save();if(ui.view.kind==='chat')refreshLiveChat(ui.view.target);}
  function decided(task,r,verdict){if(recordDecision(state,task.id,{reviewId:r.id,title:requestTitle(r),verdict,by:'user'}))chatChanged();}
  function showError(e){error=String(e.message||e);const el=document.querySelector('[data-worker-error]');if(el)el.textContent=error;else showToast(error);}
  async function refresh(redraw=true){
    const listKey=s=>JSON.stringify([s.online,s.paused,s.maxRunning,s.running,s.defaultProvider,s.privateBrowser?.agentId,s.privateBrowser?.taskId,s.tasks.map(t=>[t.id,t.title,t.agentId,t.status,t.progress||'']),(s.routines||[]).map(r=>[r.id,r.status,r.nextRun])]);
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
      // A result or request newly in the chat may also put its agent on the screen while the person is in another app (buddy-drop-events.js).
      const value=(await request({operation:'detail',taskId:t.id})).task;examined.set(t.id,outcome(t));if(reconcile(state,value))changed=true;if(deliverResult(state,value)){changed=true;root.BuddyDrop?.task?.(state,value);}
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
  api.open=async()=>{where='page';view='list';error='';list();await refresh();};
  // The panel is drawn once more when both the worker and the saved sign-ins have answered, so a field opened after that is never redrawn away.
  api.profiles=async()=>{where=onPage()?'page':'dialog';view='profiles';error='';signins=freshSignins();profiles();const listed=loadSignins(false);try{snapshot=await request({operation:'start'});await listed;profiles();}catch(e){await listed;paintSignins();showError(e);}};
  document.addEventListener('input',e=>{if(e.target.matches('[data-worker-update]')&&detail)drafts.set(detail.id,{...drafts.get(detail.id),update:e.target.value});if(e.target.matches('[data-worker-allowance]')&&detail)drafts.set(detail.id,{...drafts.get(detail.id),allowance:e.target.value,budgetAuthorizationID:undefined});const form=e.target.closest('#worker-new-form,#worker-routine-form');if(form){try{localStorage.setItem(key()+(form.id==='worker-routine-form'?'-routine':''),JSON.stringify({...Object.fromEntries(new FormData(form)),...(form.id==='worker-routine-form'?{weekdays:[...form.querySelectorAll('[name=weekday]:checked')].map(v=>Number(v.value))}:{})}));}catch{}}});
  // Run at once: the person's choice goes to the worker as it is made; the next free slot follows it.
  async function setRunLimit(value){if(busy)return;busy=true;error='';try{await request({operation:'maxRunning',value});await refresh();}catch(e){showError(e);}finally{busy=false;}}
  document.addEventListener('change',e=>{if(e.target.matches?.('[data-worker-max-running]')){setRunLimit(Number(e.target.value));return;}if(e.target.matches('#worker-routine-form [name=days]')){document.querySelector('[data-custom-days]').hidden=e.target.value!=='custom';}const el=e.target.closest('[data-worker-question]'),r=el?.closest('[data-worker-review]');if(r){const values=drafts.get(r.dataset.workerReview)||{};values[el.dataset.workerQuestion]=el.value;drafts.set(r.dataset.workerReview,values);}});
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
      else if(task){if(!task.closest('[data-worker-panel]'))where=onPage()?'page':'dialog';detail=(await request({operation:'detail',taskId:task.dataset.workerTask})).task;view='task';drawDetail();if(reconcile(state,detail))chatChanged();}
      else if(file){preview=await request({operation:'preview',taskId:detail.id,path:file.dataset.workerFile});view='preview';shell(`${button('task-back','← Task')}<h3>${esc(preview.path)}</h3><div class="worker-document">${BuddyDocuments.preview(preview)}</div>`);}
      else {
        const operation=op.dataset.workerOp;
        if(operation==='new-routine'){routineForm();}
        else if(operation==='edit-routine'){routineForm(routine);}
        else if(['pause-routine','resume-routine','delete-routine'].includes(operation)){const action=operation.split('-')[0];await request({operation:'routine',agentId:routine.agentId,arguments:{action,routineID:routine.id}});await refresh(false);if(action==='delete'){view='list';list();}else routineDetail(snapshot.routines.find(r=>r.id===routine.id));}
        else if(operation==='new'){view='new';form();}
        else if(operation==='profiles'){view='profiles';signins=freshSignins();profiles();loadSignins();}
        else if(operation==='chrome-settings'){await request({operation:'openChromeSettings'});await refresh(false);if(view==='task'&&detail)drawDetail();else profiles();}
        else if(operation==='open-google'){await request({operation:'openGoogle'});await refresh(false);profiles();}
        else if(operation==='finish-signin'){const done=await request({operation:'finishSignIn'});await refresh(false);if(view==='profiles')profiles();else if(view==='task'){detail=(await request({operation:'detail',taskId:detail.id})).task;drawDetail();}else list();if(done?.finished===false&&done.note)showError(done.note);}
        else if(operation.startsWith('auth-')){const r=pending(detail).find(r=>r.id===op.dataset.reviewId&&r.kind==='authentication');if(!r)throw Error('This sign-in request ended. Refresh the task.');await request({operation:'review',taskId:detail.id,id:r.id,accept:operation!=='auth-decline',authAction:operation.slice(5)});await refresh();}
        else if(operation==='back'){where='page';view='list';await refresh(false);list();}
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
        else if(['resume','pause','cancel','browser'].includes(operation)){let allowance={};
          // What the box holds now is what goes, however it got there: a paste or dictation can fill it without an input event.
          if(operation==='resume'){const box=document.querySelector('[data-worker-panel] [data-worker-update]');if(box?.value?.trim())drafts.set(detail.id,{...drafts.get(detail.id),update:box.value});}
          if(operation==='resume'&&needsAllowance(detail)){const amount=Number(drafts.get(detail.id)?.allowance);if(!Number.isFinite(amount)||amount<0.1||amount>10)throw Error('Choose an additional Claude allowance from $0.10 to $10.');const draft=drafts.get(detail.id);draft.budgetAuthorizationID||=crypto.randomUUID();allowance={additionalBudgetUSD:amount,budgetAuthorizationID:draft.budgetAuthorizationID};}if(operation==='resume'&&detail.kind==='coding'&&detail.status==='completed'&&!drafts.get(detail.id)?.update?.trim())throw Error('Add what you want to change before continuing this coding session.');await request(operation==='resume'&&detail.kind==='coding'&&!allowance.additionalBudgetUSD?{operation:'coding',agentId:detail.agentId,arguments:{action:'continue',taskId:detail.id,goal:drafts.get(detail.id)?.update||'Continue the original task and reconcile current project files and command receipts before retrying interrupted work.'}}:{operation,taskId:detail.id,...allowance,message:operation==='resume'?(drafts.get(detail.id)?.update||(detail.kind==='coding'?'Continue the original task and reconcile current project files and command receipts before retrying interrupted work.':'')):''});if(operation==='resume')drafts.delete(detail.id);await refresh();}
      }
    }catch(e){showError(e);}finally{busy=false;document.querySelectorAll('[data-worker-panel] [data-worker-op], #worker-new-form button').forEach(b=>b.disabled=answered.has(b.dataset.reviewId));}
  });
  document.addEventListener('click',e=>{
    const t=e.target.closest?.('[data-saved-replace],[data-saved-remove],[data-saved-cancel],[data-saved-save],[data-saved-confirm-remove]');if(!t||t.disabled||!t.closest('.worker-saved-signins'))return;
    e.preventDefault();const d=t.dataset;
    if(d.savedReplace){signins.editing=d.savedReplace;signins.removing='';signins.note='';paintSignins();document.querySelector('[data-saved-holder] [data-saved-input]')?.focus();}
    else if(d.savedRemove){signins.removing=d.savedRemove;signins.editing='';signins.note='';paintSignins();}
    else if(d.savedCancel){document.querySelectorAll('[data-saved-input]').forEach(i=>{i.value='';});signins.editing='';signins.removing='';paintSignins();}
    else if(d.savedSave)saveSignin(d.savedSave);
    else if(d.savedConfirmRemove)removeSignin(d.savedConfirmRemove);
  });
  document.addEventListener('keydown',e=>{
    const input=e.target.closest?.('[data-saved-input]');if(!input||e.key!=='Enter'||e.isComposing)return;
    e.preventDefault();const holder=input.closest('[data-saved-holder]'),next=[...holder.querySelectorAll('[data-saved-input]')].find(i=>!i.value);
    if(next&&next!==input)next.focus();else saveSignin(holder.dataset.savedHolder);
  });
  document.addEventListener('click',async e=>{const a=e.target.closest('[data-action]')?.dataset.action;if(view!=='preview'||!preview||!document.querySelector('.worker-document')||!['document-prev','document-next'].includes(a))return;try{preview=await request({operation:'preview',taskId:detail.id,path:preview.path,page:(preview.previewPage||1)+(a==='document-next'?1:-1)});document.querySelector('.worker-document').innerHTML=BuddyDocuments.preview(preview);}catch(e){showError(e);}});
  document.addEventListener('change',e=>{if(view==='preview'&&e.target.id==='document-sheet'&&preview&&document.querySelector('.worker-document'))document.querySelector('.worker-document').innerHTML=BuddyDocuments.preview(preview,Number(e.target.value));});
  setInterval(()=>{if(!busy&&!['new','routine-form'].includes(view)&&document.querySelector('[data-worker-panel]'))refresh();},2500);
  setInterval(()=>{if(!busy&&!document.querySelector('[data-worker-panel]')&&Date.now()-polled>=(live()?4500:14500))refresh(false);},5000);
  setTimeout(()=>refresh(false),1800);
  // The page draws the open chat before this file has loaded, so its task messages were drawn without being read (an answered approval still
  // offered "Review task"). Draw them again now that they can be.
  if(typeof ui!=='undefined'&&ui.view?.kind==='chat'&&typeof refreshLiveChat==='function')refreshLiveChat(ui.view.target);
  // Reopened on the Work page: the app drew its frame before this file loaded.
  if(onPage()){view='list';list();}
})(typeof globalThis!=='undefined'?globalThis:this);

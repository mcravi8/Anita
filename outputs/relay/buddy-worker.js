(function(root){
  'use strict';
  const labels={queued:'Queued',running:'Working',waiting_review:'Needs review',waiting_user:'Needs you',paused:'Paused',interrupted:'Interrupted',completed:'Finished',failed:'Couldn’t finish',cancelled:'Cancelled'};
  const canResume=status=>['paused','interrupted','failed','waiting_user'].includes(status);
  const pending=task=>(task.reviews||[]).filter(r=>r.status==='pending');
  const api={labels,canResume,pending};root.BuddyWorkerUI=api;if(typeof module!=='undefined')module.exports=api;
  if(typeof document==='undefined')return;
  let snapshot={online:false,tasks:[],paused:false},detail=null,view='list',busy=false,error='',last='',preview=null;
  const drafts=new Map();
  const key=()=>`buddy.worker.draft.${state.conversationWorkspace}`;
  function loadDraft(){try{return JSON.parse(localStorage.getItem(key()))||{};}catch{return {};}}
  const request=payload=>{if(!window.BuddyDesktop?.worker)throw Error('Open Buddy’s Mac app to use background work.');return window.BuddyDesktop.worker(payload);};
  const button=(op,label,extra='',primary=false)=>`<button type="button" class="${primary?'primary-button':'border-button'}" data-worker-op="${op}" ${extra} ${busy?'disabled':''}>${label}</button>`;
  function shell(body){openDrawer('Background work',`<div class="worker-panel" data-worker-panel>${body}<p class="field-error" data-worker-error role="alert">${esc(error)}</p></div>`);document.querySelector('.modal.drawer')?.classList.add('worker-drawer');}
  function list(){
    const tasks=[...snapshot.tasks].reverse();
    shell(`<p class="worker-intro">A little work happening in the background.</p><div class="worker-toolbar"><span class="worker-state ${snapshot.online?'online':''}">${snapshot.online?(snapshot.paused?'Paused':'This Mac'):'Worker offline'}</span>${snapshot.online?button('new','New task','',true):button('start','Start worker','',true)}</div>${tasks.length?`<div class="worker-list">${tasks.map(t=>`<button class="menu-row" data-worker-task="${esc(t.id)}">${findAgent(t.agentId)?avatar(t.agentId):icon('spark')}<span><strong>${esc(t.title)}</strong><small>${esc(agentName(t.agentId))} · ${esc(labels[t.status]||t.status)}</small></span>${icon(t.status==='completed'?'check':'chevron')}</button>`).join('')}</div>`:'<div class="worker-empty"><span>✦</span><h3>Leave something with your Buddy</h3><p>Research a topic, prepare an application, or handle an email.</p></div>'}<details class="worker-more"><summary>Worker settings${icon('down')}</summary><p>Uses a separate Chrome profile and task folders. The worker keeps running when you quit Buddy. This Mac needs to stay awake and online.</p><div class="worker-toolbar">${snapshot.online?button('pauseAll',snapshot.paused?'Resume queue':'Pause queue'):''}${button('refresh','Refresh')}</div><p>Default: your ChatGPT subscription. Claude uses your Console API credits and an estimated spending limit for each task. Connected services still use ChatGPT.</p>${snapshot.claudeConnected?`<span class="worker-state online">Claude API key connected</span>${button('disconnectClaude','Disconnect Claude')}`:button('connectClaude','Connect Claude credits')}<p class="worker-caption">Credits are used before paid balance. Console funding and auto-reload settings determine what happens when credits run out.</p></details>`);
  }
  function form(){
    const d=loadDraft();shell(`<form id="worker-new-form"><p class="worker-intro">Give your Buddy a brief. Come back for the result.</p><label class="field"><span>Agent</span><select name="agentId" required>${state.agents.map(a=>`<option value="${esc(a.id)}" ${a.id===(d.agentId||ui.view.target)?'selected':''}>${esc(a.name)}</option>`).join('')}</select></label><label class="field"><span>Task</span><input name="title" maxlength="150" placeholder="e.g. Research five roles for me" required value="${esc(d.title||'')}"></label><label class="field"><span>Brief</span><textarea name="goal" rows="6" maxlength="30000" placeholder="What should they do? Include links, useful files, and what a good result looks like." required>${esc(d.goal||'')}</textarea></label><details class="worker-more" ${d.provider==='claude'?'open':''}><summary>Options${icon('down')}</summary><label class="field"><span>Type of work</span><select name="kind">${[['general','Anything'],['research','Research'],['applications','Job application'],['email','Email']].map(([v,l])=>`<option value="${v}" ${v===d.kind?'selected':''}>${l}</option>`).join('')}</select></label><label class="field"><span>Powered by</span><select name="provider"><option value="chatgpt">ChatGPT subscription</option><option value="claude" ${d.provider==='claude'?'selected':''} ${snapshot.claudeConnected?'':'disabled'}>Claude API credits${snapshot.claudeConnected?'':' · connect in worker settings'}</option></select></label><label class="field"><span>Claude limit per task (USD)</span><input name="budgetUSD" type="number" min="0.10" max="10" step="0.10" value="${esc(d.budgetUSD||'0.50')}"></label><p class="worker-caption">An estimated SDK limit. The final request can exceed it. No automatic provider switching.</p></details><p class="worker-caption">Browser operations and connected actions come back for review. Logins and verification may need you.</p><div class="modal-actions">${button('back','Back')}<button type="submit" class="primary-button">Start task${icon('arrow')}</button></div></form>`);
  }
  function review(r){
    const args={...r.tool?.arguments};const body=BuddyActions.messagePreview(args.payload);if(body)args.message=body;
    const data=Object.entries(args).filter(([k])=>!['payload'].includes(k));
    return `<section class="worker-review" data-worker-review="${esc(r.id)}"><strong>${esc(r.tool?.name||'Review action')}</strong><small>${esc(r.tool?.service||'Buddy private browser')}</small>${data.length?`<dl>${data.map(([k,v])=>`<div><dt>${esc(k.replace(/_/g,' '))}</dt><dd>${esc(typeof v==='string'?v:JSON.stringify(v,null,2))}</dd></div>`).join('')}</dl>`:''}${(r.questions||[]).map((q,i)=>`<fieldset><legend>${esc(q.question)}</legend>${q.options?.length?`<select data-worker-question="${esc(q.id)}"><option value="">Choose…</option>${q.options.map(o=>`<option value="${esc(o.label)}" ${drafts.get(r.id)?.[q.id]===o.label?'selected':''}>${esc(o.label==='Accept'?'Approve once':o.label)}</option>`).join('')}</select>`:`<textarea data-worker-question="${esc(q.id)}" rows="3" maxlength="10000">${esc(drafts.get(r.id)?.[q.id]||'')}</textarea>`}</fieldset>`).join('')}<div class="worker-toolbar">${button('decline','Cancel action',`data-review-id="${esc(r.id)}"`)}${button('approve','Continue',`data-review-id="${esc(r.id)}"`,true)}</div></section>`;
  }
  function taskBody(t){
    return `<div class="worker-task-heading">${findAgent(t.agentId)?avatar(t.agentId):''}<div><h3>${esc(t.title)}</h3><small>${esc(agentName(t.agentId))} · ${t.provider==='claude'?'Claude credits':'ChatGPT'}</small></div></div><p class="worker-status" role="status">${esc(labels[t.status]||t.status)}</p><p class="worker-progress">${esc(t.progress||'')}</p>${pending(t).map(review).join('')}${t.result?`<article class="reply-markdown worker-result">${BuddyMarkdown.render(t.result)}</article>`:''}${t.fileList?.length?`<div class="worker-files"><h4>Task files</h4>${t.fileList.map(f=>`<button class="menu-row" data-worker-file="${esc(f.path)}">${icon('file')}<span>${esc(f.path)}</span>${icon('chevron')}</button>`).join('')}</div>`:''}<div>${canResume(t.status)?`<label class="field"><span>Anything to add before continuing?</span><textarea data-worker-update rows="3" maxlength="10000" placeholder="Add a missing detail, answer a question, or say what you changed in the browser.">${esc(drafts.get(t.id)?.update||'')}</textarea></label>`:''}</div><div class="worker-toolbar">${canResume(t.status)?button('resume','Resume task','',true):''}${['queued','running','waiting_review'].includes(t.status)?button('pause','Pause'):''}${!['completed','cancelled'].includes(t.status)?button('cancel','Cancel task'):''}</div><details class="worker-more"><summary>Task details${icon('down')}</summary><p class="worker-brief">${esc(t.goal||'')}</p><p class="worker-caption">Saved ${esc(new Date(t.updatedAt).toLocaleString())}${t.spentUSD!=null?` · Estimated Claude usage $${Number(t.spentUSD).toFixed(4)}`:''}</p>${button('browser','Open task browser')}<p class="worker-caption">Opening the browser pauses the queue. Handle login or verification yourself, then resume the task.</p>${t.events?.length?`<details class="worker-receipt"><summary>Work activity</summary><ul>${t.events.map(e=>`<li>${esc(e.tool)} · ${esc(e.status)}</li>`).join('')}</ul></details>`:''}${(t.reviews||[]).filter(r=>r.status!=='pending').map(r=>`<details class="worker-receipt"><summary>${esc(r.tool?.name||'Action')} · ${esc(r.status)}</summary><pre>${esc(JSON.stringify(r.receipt||r.tool?.arguments||{},null,2))}</pre></details>`).join('')}</details>`;
  }
  function drawDetail(){shell(`${button('back','← All tasks')}<div data-worker-live>${taskBody(detail)}</div>`);}
  function showError(e){error=String(e.message||e);const el=document.querySelector('[data-worker-error]');if(el)el.textContent=error;else showToast(error);}
  async function refresh(redraw=true){
    try{snapshot=await request({operation:'status'});error='';if(redraw&&document.querySelector('[data-worker-panel]')){if(view==='list')list();else if(view==='task'&&detail){const result=await request({operation:'detail',taskId:detail.id});detail=result.task;const live=document.querySelector('[data-worker-live]');if(live&&!(live.contains(document.activeElement)&&document.activeElement.matches('input,textarea,select'))&&last!==JSON.stringify(detail)){live.innerHTML=taskBody(detail);last=JSON.stringify(detail);}}}badge();}
    catch(e){snapshot.online=false;if(redraw&&view==='list'){list();showError(e);}}
  }
  function badge(){const count=snapshot.tasks.filter(t=>['waiting_review','waiting_user','failed','interrupted'].includes(t.status)).length;document.querySelectorAll('[data-worker-badge]').forEach(el=>{el.textContent=count||'';el.hidden=!count;});}
  api.open=async()=>{view='list';error='';list();await refresh();};
  document.addEventListener('input',e=>{if(e.target.matches('[data-worker-update]')&&detail)drafts.set(detail.id,{update:e.target.value});const form=e.target.closest('#worker-new-form');if(form){try{localStorage.setItem(key(),JSON.stringify(Object.fromEntries(new FormData(form))));}catch{}}});
  document.addEventListener('change',e=>{const el=e.target.closest('[data-worker-question]'),r=el?.closest('[data-worker-review]');if(r){const values=drafts.get(r.dataset.workerReview)||{};values[el.dataset.workerQuestion]=el.value;drafts.set(r.dataset.workerReview,values);}});
  document.addEventListener('submit',async e=>{
    const form=e.target.closest('#worker-new-form');if(!form)return;e.preventDefault();if(busy)return;
    busy=true;error='';const values=Object.fromEntries(new FormData(form));try{const draft=loadDraft();const requestId=draft.requestId||crypto.randomUUID();localStorage.setItem(key(),JSON.stringify({...values,requestId}));const submit=form.querySelector('button[type="submit"]');submit.disabled=true;submit.textContent='Saving…';
      const result=await request({operation:'create',...values,budgetUSD:values.provider==='claude'?Number(values.budgetUSD):0,requestId});localStorage.removeItem(key());detail=result.task;view='task';drawDetail();await refresh();
    }catch(e){showError(e);}finally{busy=false;document.querySelectorAll('[data-worker-panel] [data-worker-op], #worker-new-form button').forEach(b=>b.disabled=false);const submit=document.querySelector('#worker-new-form button[type=submit]');if(submit)submit.textContent='Start task';}
  });
  document.addEventListener('click',async e=>{
    const entry=e.target.closest('[data-action="background-work"]');if(entry){api.open();return;}
    const task=e.target.closest('[data-worker-task]'),file=e.target.closest('[data-worker-file]'),op=e.target.closest('[data-worker-op]');if(!task&&!file&&!op)return;
    if(busy)return;busy=true;error='';
    try{
      if(task){detail=(await request({operation:'detail',taskId:task.dataset.workerTask})).task;view='task';drawDetail();}
      else if(file){preview=await request({operation:'preview',taskId:detail.id,path:file.dataset.workerFile});view='preview';shell(`${button('task-back','← Task')}<h3>${esc(preview.path)}</h3><div class="worker-document">${BuddyDocuments.preview(preview)}</div>`);}
      else {
        const operation=op.dataset.workerOp;
        if(operation==='new'){view='new';form();}
        else if(operation==='back'){view='list';await refresh(false);list();}
        else if(operation==='task-back'){view='task';drawDetail();}
        else if(operation==='refresh'){await refresh();}
        else if(operation==='connectClaude'||operation==='disconnectClaude'){await request({operation});await refresh();}
        else if(operation==='start'){snapshot=await request({operation:'start'});list();}
        else if(operation==='pauseAll'){await request({operation,paused:!snapshot.paused});await refresh();}
        else if(operation==='approve'||operation==='decline'){
          const r=pending(detail).find(r=>r.id===op.dataset.reviewId);if(!r)throw Error('This review ended. Refresh the task.');
          const answers=Object.fromEntries(Object.entries(drafts.get(r.id)||{}).map(([k,v])=>[k,[v]]));
          if(operation==='approve'&&(r.questions||[]).some(q=>!answers[q.id]?.[0]))throw Error('Answer each question to continue.');
          await request({operation:'review',taskId:detail.id,id:r.id,answers,cancel:operation==='decline',accept:operation==='approve'&&answers.operation?.[0]==='Accept'});drafts.delete(r.id);await refresh();
        }
        else if(['resume','pause','cancel','browser'].includes(operation)){await request({operation,taskId:detail.id,message:operation==='resume'?(drafts.get(detail.id)?.update||''):''});if(operation==='resume')drafts.delete(detail.id);await refresh();}
      }
    }catch(e){showError(e);}finally{busy=false;document.querySelectorAll('[data-worker-panel] [data-worker-op], #worker-new-form button').forEach(b=>b.disabled=false);}
  });
  document.addEventListener('click',async e=>{const a=e.target.closest('[data-action]')?.dataset.action;if(view!=='preview'||!preview||!['document-prev','document-next'].includes(a))return;try{preview=await request({operation:'preview',taskId:detail.id,path:preview.path,page:(preview.previewPage||1)+(a==='document-next'?1:-1)});document.querySelector('.worker-document').innerHTML=BuddyDocuments.preview(preview);}catch(e){showError(e);}});
  document.addEventListener('change',e=>{if(view==='preview'&&e.target.id==='document-sheet'&&preview)document.querySelector('.worker-document').innerHTML=BuddyDocuments.preview(preview,Number(e.target.value));});
  setInterval(()=>{if(!busy&&view!=='new'&&document.querySelector('[data-worker-panel]'))refresh();},2500);
  setInterval(()=>{if(!busy&&!document.querySelector('[data-worker-panel]'))refresh(false);},15000);
  setTimeout(()=>refresh(false),1800);
})(typeof globalThis!=='undefined'?globalThis:this);

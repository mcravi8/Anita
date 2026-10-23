(function(root){
  'use strict';
  const statuses=['pending','answered','declined','cancelled','completed','failed','uncertain','expired'];
  function merge(workspace,records){
    workspace.toolInputs ||= {};
    let changed=false;
    for(const record of records||[]){
      const run=workspace.runs?.[record?.runId];
      if(!record||record.native!==true||record.workspace!==workspace.conversationWorkspace||!run||typeof record.id!=='string'||!statuses.includes(record.status))continue;
      if(record.status==='pending'&&!['starting','answering'].includes(run.status))continue;
      const old=workspace.toolInputs[record.id];
      if(old&&old.status!=='pending'&&record.status==='pending')continue;
      if(old&&['completed','failed','declined','cancelled'].includes(old.status)&&old.status!==record.status&&!['completed','failed'].includes(record.status))continue;
      if(JSON.stringify(old)!==JSON.stringify(record)){workspace.toolInputs[record.id]=structuredClone(record);changed=true;}
    }
    return changed;
  }
  function reconcile(workspace,records){
    let changed=merge(workspace,records);
    const known=new Set((records||[]).map(r=>r.id));
    for(const r of Object.values(workspace.toolInputs||{}))if(r.workspace===workspace.conversationWorkspace&&!known.has(r.id)&&['pending','answered'].includes(r.status)){
      r.status=r.status==='pending'?'expired':'uncertain';changed=true;
    }
    return changed;
  }
  function pending(workspace,runId){return Object.values(workspace.toolInputs||{}).filter(r=>r.workspace===workspace.conversationWorkspace&&r.runId===runId&&r.status==='pending');}
  function messagePreview(payload){
    const bodies=[];
    function collect(part,depth=0){
      if(!part||depth>8)return;
      const mime=String(part.mime_type||'').toLowerCase(),content=part.body?.content;
      if(typeof content==='string'&&['text/plain','text/html'].includes(mime)){
        let text=content;
        if(mime==='text/html')text=text.replace(/<(script|style)\b[^>]*>[\s\S]*?<\/\1\s*>/gi,'').replace(/<br\s*\/?\s*>/gi,'\n').replace(/<\/(p|div|li|h[1-6])\s*>/gi,'\n').replace(/<[^>]*>/g,'').replace(/&(#x[\da-f]+|#\d+|amp|lt|gt|quot|apos|nbsp);/gi,(raw,key)=>{
          const named={amp:'&',lt:'<',gt:'>',quot:'"',apos:"'",nbsp:' '},lower=key.toLowerCase();
          if(named[lower])return named[lower];
          const code=lower.startsWith('#x')?parseInt(lower.slice(2),16):parseInt(lower.slice(1),10);
          return code>0&&code<=0x10ffff?String.fromCodePoint(code):raw;
        }).trim();
        bodies.push({mime,text});
      }
      for(const child of Array.isArray(part.parts)?part.parts:[])collect(child,depth+1);
    }
    collect(payload);
    return bodies.length===1?bodies[0].text:bodies.map(b=>`${b.mime==='text/html'?'HTML':'Plain text'}:\n${b.text}`).join('\n\n');
  }
  const api={merge,reconcile,pending,messagePreview};root.BuddyActions=api;if(typeof module!=='undefined')module.exports=api;
  if(typeof document==='undefined')return;
  const sending=new Set(),errors=new Map();
  function title(r){const name=r.tool?.name||'';return name.replace(/^.*__/, '').replace(/_/g,' ').replace(/^./,c=>c.toUpperCase())||'Review action';}
  function details(r){
    const original=r.tool?.arguments;
    const body=messagePreview(original?.payload);
    const args=body?{...original,body:original.body||body}:original;
    if(!args||!Object.keys(args).length)return '';
    const labels={app:'App',target:'Control',operation:'Operation',scope:'Access',to:'To',recipient:'To',recipients:'To',cc:'Cc',bcc:'Bcc',subject:'Subject',body:'Message',text:'Message',content:'Message',body_text:'Message',email_id:'Email',email_ids:'Emails',draft_id:'Draft',thread_id:'Conversation'};
    const order=['app','target','operation','scope','to','recipient','recipients','cc','bcc','subject','body','body_text','text','content','email_id','email_ids','draft_id','thread_id'];
    const entries=Object.entries(args),primary=entries.filter(([k])=>labels[k]).sort(([a],[b])=>order.indexOf(a)-order.indexOf(b)),extra=entries.filter(([k])=>!labels[k]);
    const value=v=>typeof v==='string'?v:JSON.stringify(v,null,2);
    return `${primary.length?`<dl class="action-payload">${primary.map(([k,v])=>`<div><dt>${labels[k]}</dt><dd>${esc(k==='operation'&&v&&typeof v==='object'?({click:'Click this control',press_key:`Press ${v.key}`,type_text:`Type: ${v.text}`,set_value:`Enter: ${v.text}`,scroll:`Scroll ${v.direction} · ${v.pages||1} page${(v.pages||1)===1?'':'s'}`}[v.action]||value(v)):value(v))}</dd></div>`).join('')}</dl>`:''}${extra.length?`<details class="action-extra"><summary>Action details${icon('down')}</summary><pre>${esc(JSON.stringify(Object.fromEntries(extra),null,2))}</pre></details>`:''}`;
  }
  function choiceLabel(r,o){
    if(o.label.toLowerCase()!=='accept')return o.label;
    const tool=(r.tool?.name||'').split('__').pop();
    if(r.tool?.name==='Allow app access')return 'Allow app access';
    if(r.tool?.service==='Computer Use')return 'Allow operation';
    if(['send_email','send_draft'].includes(tool))return 'Send email';
    if(tool==='forward_emails')return 'Forward';
    return 'Approve';
  }
  function card(r){
    const busy=sending.has(r.id),agent=findAgent(r.agentId),heading=title(r);
    if(r.status!=='pending'){
      const messages={answered:'Review submitted · waiting for the result',completed:'Action completed',failed:'Action could not finish',declined:'Action declined',cancelled:'Review cancelled',expired:'Review ended · ask the agent again',uncertain:'Outcome not confirmed · check the service before retrying'};
      return `<details class="action-receipt ${r.status}" data-tool-input="${esc(r.id)}"><summary>${icon(r.status==='completed'?'check':'info')}<span>${messages[r.status]}</span>${icon('down')}</summary><strong>${esc(heading)}</strong><p>${esc(r.agentName||agent?.name||'Agent')}${r.tool?.service?` · ${esc(r.tool.service)}`:''}</p>${details(r)}${r.finishedAt?`<p>Finished ${esc(new Date(r.finishedAt).toLocaleString())}</p>`:''}${Object.keys(r.receipt||{}).length?`<details class="action-extra"><summary>Confirmation details${icon('down')}</summary><pre>${esc(JSON.stringify(r.receipt,null,2))}</pre></details>`:''}${r.error?`<p class="field-error">${esc(r.error)}</p>`:''}</details>`;
    }
    const questions=r.questions||[],quick=questions.length===1&&questions[0].options?.length&&!questions[0].isOther;
    return `<section class="action-review" data-tool-input="${esc(r.id)}" aria-label="${esc(heading)}" aria-busy="${busy}"><header>${agent?avatar(agent.id,true):''}<div><strong>${esc(heading)}</strong><small>${esc(r.agentName||agent?.name||'Agent')} needs your review</small></div></header>${details(r)}<form data-tool-input-form="${esc(r.id)}">${questions.map((q,i)=>`<fieldset ${busy?'disabled':''}><legend>${esc(q.question)}</legend>${quick?`<div class="action-choices">${q.options.map((o,index)=>`<button type="button" class="${o.label.toLowerCase()==='accept'?'primary-button':'border-button'}" data-input-choice="${esc(r.id)}" data-question="${esc(q.id)}" data-option="${index}" title="${esc(o.description||'')}">${esc(choiceLabel(r,o))}</button>`).join('')}</div>${q.options.some(o=>o.description)?`<details class="action-choice-help"><summary>What the choices mean${icon('down')}</summary>${q.options.map(o=>`<p><strong>${esc(o.label)}:</strong> ${esc(o.description||'')}</p>`).join('')}</details>`:''}`:`${(q.options||[]).map((o,index)=>`<label class="action-option"><input type="radio" name="q${i}" data-input-question="${esc(q.id)}" value="${index}" ${state.toolInputDrafts?.[r.id]?.[q.id]===o.label?'checked':''}><span><strong>${esc(o.label)}</strong><small>${esc(o.description||'')}</small></span></label>`).join('')}${!q.options?.length||q.isOther?`<label class="action-freeform">${q.isOther?'Custom answer':'Your answer'}<textarea id="action-answer-${esc(r.id)}-${i}" data-input-question="${esc(q.id)}" maxlength="10000" placeholder="Type your answer…">${esc(q.options?.some(o=>o.label===state.toolInputDrafts?.[r.id]?.[q.id])?'':state.toolInputDrafts?.[r.id]?.[q.id]||'')}</textarea></label>`:''}`}</fieldset>`).join('')}${errors.has(r.id)?`<p class="field-error" role="alert">${esc(errors.get(r.id))}</p>`:''}${busy?'<p class="action-wait" role="status">Submitting your choice…</p>':''}${!quick?`<div class="action-form-buttons"><button type="button" class="border-button" data-input-cancel="${esc(r.id)}" ${busy?'disabled':''}>Cancel</button><button class="primary-button" ${busy?'disabled':''}>Continue${icon('arrow')}</button></div>`:''}</form></section>`;
  }
  // A review leaves the reply once it is answered (or has ended); one that failed, or whose outcome Buddy could not confirm, stays, as it still
  // needs a look before anything is tried again.
  const shown=r=>['pending','failed','uncertain'].includes(r.status);
  api.cards=runId=>Object.values(state.toolInputs||{}).filter(r=>r.workspace===state.conversationWorkspace&&r.runId===runId&&shown(r)).map(card).join('');
  function redraw(runId){
    const focus=document.activeElement,id=focus?.id,start=focus?.selectionStart,end=focus?.selectionEnd;
    const run=state.runs[runId];if(run)refreshLiveChat(run.target);
    const el=id&&document.getElementById(id);if(el){el.focus({preventScroll:true});if(typeof start==='number')el.setSelectionRange(start,end);}
  }
  async function answer(id,answers,cancel=false){
    const r=state.toolInputs?.[id];if(!r||r.status!=='pending'||sending.has(id)||!window.BuddyDesktop?.answerToolInput)return;
    sending.add(id);errors.delete(id);redraw(r.runId);
    try{const result=await window.BuddyDesktop.answerToolInput({id,answers,cancel});if(!result.accepted||!result.request)throw Error('Buddy could not verify this choice. Your answer is preserved.');merge(state,[result.request]);save();
      // The card leaves the reply; a toast says the answer went.
      showToast(cancel?'Declined.':`Sent — ${r.agentName||findAgent(r.agentId)?.name||'the agent'} is continuing.`);}
    catch(error){errors.set(id,String(error.message||error));}
    finally{sending.delete(id);redraw(r.runId);}
  }
  document.addEventListener('click',event=>{
    const choice=event.target.closest('[data-input-choice]');if(choice){const r=state.toolInputs?.[choice.dataset.inputChoice],q=r?.questions.find(q=>q.id===choice.dataset.question),o=q?.options[Number(choice.dataset.option)];if(o)answer(r.id,{[q.id]:[o.label]});}
    const cancel=event.target.closest('[data-input-cancel]');if(cancel)answer(cancel.dataset.inputCancel,{},true);
  });
  document.addEventListener('input',event=>{
    const field=event.target.closest('[data-input-question]'),form=field?.closest('[data-tool-input-form]');if(!form)return;
    const id=form.dataset.toolInputForm,r=state.toolInputs?.[id],q=r?.questions.find(q=>q.id===field.dataset.inputQuestion);if(!q)return;
    state.toolInputDrafts ||= {};state.toolInputDrafts[id] ||= {};
    state.toolInputDrafts[id][q.id]=field.type==='radio'?q.options[Number(field.value)].label:field.value;save();
  });
  document.addEventListener('submit',event=>{const form=event.target.closest('[data-tool-input-form]');if(!form)return;event.preventDefault();const id=form.dataset.toolInputForm,r=state.toolInputs?.[id];const answers={};for(const q of r.questions)answers[q.id]=[state.toolInputDrafts?.[id]?.[q.id]||''];answer(id,answers);});
  window.addEventListener('buddy-conversation',event=>{
    if(event.detail?.type!=='tool-input')return;
    if(merge(state,[event.detail.request])){save();redraw(event.detail.runId);if(event.detail.request.status==='pending')showToast(`${event.detail.request.agentName} needs your review.`);}
  });
  api.boot=async()=>{if(!window.BuddyDesktop?.toolInputs)return;try{const snapshot=await window.BuddyDesktop.toolInputs();reconcile(state,snapshot.requests||[]);save();if(ui.view.kind==='chat')redraw(BuddyChat.active(state,ui.view.target)?.runId||'');}catch{showToast('Couldn’t load action reviews. Reopen Buddy to check before approving.');}};
})(typeof globalThis!=='undefined'?globalThis:this);

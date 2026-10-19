(function(root){
  'use strict';
  // Settings the page keeps in its own state. A change made in chat is recorded by the app first; the page then carries it into its own state,
  // saves, and only then tells the app it has done so (so a crash in between just repeats the same, harmless, steps).
  const PAGE_FIELDS=['name','avatarShape','avatarColor','hidden','tools.web','tools.projectFiles','tools.desktop'];
  function set(state,agent,field,value){
    if(field==='hidden'){const list=state.hiddenAgents||[],has=list.includes(agent.id),want=value===true;if(has===want)return false;state.hiddenAgents=want?[...list,agent.id]:list.filter(x=>x!==agent.id);return true;}
    if(field.startsWith('tools.')){const key=field.slice(6),tools={...(agent.tools||{})};if(typeof value!=='boolean'||tools[key]===value)return false;tools[key]=value;agent.tools=tools;return true;}
    if(typeof value!=='string'||!value||agent[field]===value)return false;
    agent[field]=value;return true;
  }
  // Oldest first, so the newest change to a setting wins. Returns whether the state changed and which changes were handled (including ones for
  // agents that no longer exist, so they do not come back).
  function merge(state,changes){
    const ids=[];let changed=false;
    for(const c of [...(changes||[])].sort((a,b)=>(a?.seq||0)-(b?.seq||0))){
      if(!c||typeof c.id!=='string')continue;
      ids.push(c.id);
      if(c.status!=='applied'||!PAGE_FIELDS.includes(c.field))continue;
      const agent=(state.agents||[]).find(a=>a.id===c.agentId);if(!agent)continue;
      if(set(state,agent,c.field,c.new))changed=true;
    }
    return {changed,ids};
  }
  const STATUS={applied:'Done',applying:'Applying',pending:'Waiting for your OK',declined:'Not allowed',undone:'Undone',failed:'Didn’t work'};
  function rulesHTML(rules,esc){
    if(!rules.length)return '<p class="rules-empty">No standing rules yet. Tell this agent one in chat, such as “for the first three, show me the work; after I approve them, go ahead without asking”.</p>';
    return rules.map(r=>{
      const state=r.status==='paused'?'Paused':r.earned?'Earned: continues without asking':r.relaxes?`${r.approved} of ${r.needed} checks approved`:'Shows its work every time';
      return `<div class="rule-row" data-rule="${esc(r.id)}"><p>${esc(r.text)}</p><small>${esc(state)}</small><span class="rule-actions"><button type="button" class="small-link" data-rule-act="${r.status==='paused'?'resume':'pause'}" data-rule-id="${esc(r.id)}">${r.status==='paused'?'Turn back on':'Pause'}</button>${r.earned||r.approved?`<button type="button" class="small-link" data-rule-act="reset" data-rule-id="${esc(r.id)}">Ask me again</button>`:''}<button type="button" class="small-link" data-rule-act="remove" data-rule-id="${esc(r.id)}">Remove</button></span></div>`;
    }).join('');
  }
  function changesHTML(changes,esc){
    if(!changes.length)return '<p class="rules-empty">Nothing changed from chat yet.</p>';
    return changes.slice(0,10).map(c=>`<div class="change-row" data-change="${esc(c.id)}"><p>${esc(c.summary)}</p><small>${esc(STATUS[c.status]||c.status)}${c.at?' · '+esc(new Date(c.at).toLocaleString([], {dateStyle:'medium',timeStyle:'short'})):''}</small>${c.canUndo?`<button type="button" class="small-link" data-change-undo="${esc(c.id)}">Undo</button>`:''}${c.status==='pending'?`<span class="rule-actions"><button type="button" class="small-link" data-change-answer="allow" data-change-id="${esc(c.id)}">Allow</button><button type="button" class="small-link" data-change-answer="deny" data-change-id="${esc(c.id)}">Not now</button></span>`:''}</div>`).join('');
  }
  const api={merge,PAGE_FIELDS,rulesHTML,changesHTML};root.BuddyAgentChanges=api;if(typeof module!=='undefined')module.exports=api;
  if(typeof document==='undefined')return;
  const call=arguments_=>BuddyDesktop.worker(arguments_);
  let adopting=false,needsPaint=false;
  const safeToPaint=()=>!document.querySelector('.modal-overlay')&&!/^(INPUT|TEXTAREA|SELECT)$/.test(document.activeElement?.tagName||'');
  function paint(){if(!needsPaint||!safeToPaint())return;needsPaint=false;if(typeof render==='function')render();window.dispatchEvent(new Event('buddy-view-updated'));}
  async function adopt(){
    if(adopting||!window.BuddyDesktop?.worker||typeof state==='undefined'||!state.conversationWorkspace)return;
    adopting=true;
    try{
      const r=await call({operation:'settings',arguments:{action:'pending',adopter:'page'}});
      const {changed,ids}=merge(state,r.changes);
      if(!ids.length)return;
      if(changed){if(!save())return;await persistenceQueue;needsPaint=true;}
      await call({operation:'settings',arguments:{action:'adopt',adopter:'page',ids}});
    }catch(e){/* the app may be starting; the next poll tries again */}
    finally{adopting=false;paint();}
  }
  // "Rules & changes" in an agent's settings: what it has been told to do, what changed from chat, and a way to undo.
  async function load(agent){
    const host=document.querySelector(`[data-agent-rules="${CSS.escape(agent)}"] [data-rules-body]`);if(!host)return;
    try{
      const r=await call({operation:'settings',arguments:{action:'list',agentId:agent}});
      const again=document.querySelector(`[data-agent-rules="${CSS.escape(agent)}"] [data-rules-body]`);if(!again)return;
      again.innerHTML=`<h4>Standing rules</h4>${rulesHTML(r.rules||[],esc)}<h4>Changes made from chat</h4>${changesHTML(r.changes||[],esc)}`;
    }catch(e){host.innerHTML='<p class="field-error">Couldn’t load rules. Open Buddy’s Mac app and try again.</p>';}
  }
  function inject(){
    const form=document.getElementById('bot-settings');if(!form||form.querySelector('.agent-rules'))return;
    const agent=form.querySelector('[data-agent-model]')?.dataset.agentModel||form.querySelector('[data-hide-agent]')?.dataset.hideAgent;if(!agent||!window.BuddyDesktop?.worker)return;
    form.querySelector('#bot-error')?.insertAdjacentHTML('beforebegin',`<section class="agent-rules" data-agent-rules="${esc(agent)}" aria-label="Rules and changes"><h3>Rules &amp; changes</h3><div data-rules-body><p class="rules-empty">Loading…</p></div></section>`);
    load(agent);
  }
  new MutationObserver(inject).observe(document.body,{childList:true,subtree:true});
  async function act(op,args,message){
    try{await call({operation:op,arguments:args});showToast(message);}catch(e){showToast(String(e.message||e));}
    const agent=document.querySelector('[data-agent-rules]')?.dataset.agentRules;if(agent)load(agent);
    window.BuddyWorkerUI?.refresh?.();adopt();
  }
  document.addEventListener('click',e=>{
    const rule=e.target.closest('[data-rule-act]');
    if(rule){e.preventDefault();const verb=rule.dataset.ruleAct;act('rules',{action:verb,ruleId:rule.dataset.ruleId},{pause:'Rule paused.',resume:'Rule is back on.',remove:'Rule removed.',reset:'Starting over: the checks come back until it earns them again.'}[verb]);return;}
    const undo=e.target.closest('[data-change-undo]');
    if(undo){e.preventDefault();act('settings',{action:'undo',changeId:undo.dataset.changeUndo},'Put back the way it was.');return;}
    const answer=e.target.closest('[data-change-answer]');
    if(answer){e.preventDefault();const allow=answer.dataset.changeAnswer==='allow';act('settings',{action:'answer',changeId:answer.dataset.changeId,allow},allow?'Done.':'Left as it was.');if(answer.closest('.modal-overlay'))closeModal();return;}
    // From Notifications: a change waiting for the person's OK opens as a plain question.
    const confirm=e.target.closest('[data-change-confirm]');
    if(confirm){e.preventDefault();open(confirm.dataset.changeConfirm);return;}
    const notice=e.target.closest('[data-rule-open]');
    if(notice&&notice.dataset.ruleOpen&&typeof agentInfo==='function'){e.preventDefault();closeModal();agentInfo(notice.dataset.ruleOpen);}
  });
  async function open(changeId){
    try{
      const r=await call({operation:'settings',arguments:{action:'list'}}),c=(r.changes||[]).find(x=>x.id===changeId);
      if(!c||c.status!=='pending'){showToast('This was already answered.');window.BuddyWorkerUI?.refresh?.();return;}
      openModal('Allow this change?',`<p class="modal-description">${esc(c.summary)}</p><p class="modal-description">You asked for this in chat. It gives more access or room to spend, so it waits for your OK.</p><div class="worker-toolbar"><button type="button" class="border-button" data-change-answer="deny" data-change-id="${esc(c.id)}">Not now</button><button type="button" class="primary-button" data-change-answer="allow" data-change-id="${esc(c.id)}">Allow</button></div>`);
    }catch(e){showToast(String(e.message||e));}
  }
  window.addEventListener('buddy-conversation',e=>{if(e.detail?.type==='agent-settings-changed')adopt();});
  window.addEventListener('buddy-view-updated',()=>setTimeout(paint,0));
  setInterval(()=>{adopt();paint();},5000);setTimeout(adopt,1500);
})(typeof globalThis!=='undefined'?globalThis:this);

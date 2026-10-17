(function(root){
  'use strict';
  const choice=(snapshot,agent)=>snapshot?.agents?.[agent]||null;
  const lookup=(snapshot,selected)=>snapshot?.models?.find(m=>m.provider===selected?.provider&&m.id===selected?.model);
  const label=(snapshot,agent)=>{const selected=choice(snapshot,agent);return lookup(snapshot,selected)?.name||selected?.model||(selected?.provider==='claude'?'Claude':'Choose model');};
  const groups=snapshot=>['chatgpt','claude'].map(provider=>({provider,name:provider==='chatgpt'?'OpenAI':'Claude',models:(snapshot?.models||[]).filter(m=>m.provider===provider&&m.current!==false)})).filter(g=>g.models.length);
  const api={choice,lookup,label,groups};root.BuddyModels=api;if(typeof module!=='undefined')module.exports=api;
  if(typeof document==='undefined')return;
  let snapshot={models:[],agents:{},errors:{}},loading=false,loaded=false,saving='',error='',activeAgent='',generation=0,pending=null,lastLoad=0;
  const native=()=>!!window.BuddyDesktop?.agentModels;
  const menu=document.createElement('div');menu.id='model-menu-root';document.body.append(menu);
  const selection=agent=>choice(snapshot,agent);
  const available=agent=>!!lookup(snapshot,selection(agent));
  function button(agent){const selected=selection(agent);return `<button type="button" class="agent-model-trigger" data-model-open="${esc(agent)}" aria-label="Choose model for ${esc(agentName(agent))}: ${esc(label(snapshot,agent))}" aria-haspopup="dialog" aria-expanded="${activeAgent===agent}" ${saving===agent?'disabled':''}>${selected?`<span class="agent-model-logo">${BuddyBrands.logo(selected.provider)}</span>`:''}<span>${esc(saving===agent?'Saving…':!loaded&&!selected?'Loading models…':label(snapshot,agent))}</span>${loaded&&selected&&!available(agent)?'<span class="model-unavailable">Not listed</span>':''}${icon('down')}</button>`;}
  function draw(){
    document.querySelectorAll('[data-agent-model]').forEach(el=>{const agent=el.dataset.agentModel;if(findAgent(agent))el.innerHTML=button(agent);});
    const hint=document.querySelector('.composer-hint');if(hint&&ui.view.kind==='chat'&&findAgent(ui.view.target)){const selected=selection(ui.view.target);if(window.BuddyAgentSetup?.required(findAgent(ui.view.target)))hint.textContent='Setup with Claude';else if(selected)hint.textContent=available(ui.view.target)?(selected.provider==='claude'?'Powered by Claude API credits':'Powered by your ChatGPT subscription'):'Saved model isn’t in current choices · choose another or reconnect';}
    if(activeAgent)drawMenu();
  }
  const triggerFor=agent=>document.querySelector(`.modal [data-model-open="${agent}"]`)||document.querySelector(`[data-model-open="${agent}"]`);
  function position(){const dialog=menu.querySelector('.model-popover'),anchor=triggerFor(activeAgent);if(!dialog||!anchor)return;const r=anchor.getBoundingClientRect();dialog.style.width=Math.min(340,innerWidth-24)+'px';dialog.style.left=Math.max(12,Math.min(innerWidth-dialog.offsetWidth-12,r.right-dialog.offsetWidth))+'px';dialog.style.top=Math.max(12,r.top-dialog.offsetHeight-8)+'px';}
  function drawMenu(){
    const query=menu.querySelector('[data-model-search]')?.value||'',focus=document.activeElement?.dataset?.modelSearch!==undefined;
    const selected=selection(activeAgent),filtered=groups(snapshot).map(g=>({...g,models:g.models.filter(m=>(m.name+' '+m.id).toLowerCase().includes(query.toLowerCase()))})).filter(g=>g.models.length);
    menu.innerHTML=`<button type="button" class="model-backdrop" data-model-close tabindex="-1" aria-label="Close model picker"></button><section class="model-popover" role="dialog" aria-label="Choose model for ${esc(agentName(activeAgent))}" aria-busy="${loading||!!saving}"><div class="model-popover-heading"><strong>Model</strong><button type="button" class="icon-button" data-model-close aria-label="Close model picker">${icon('close')}</button></div><input class="model-search" data-model-search aria-label="Search models" placeholder="Search models" value="${esc(query)}" autocomplete="off"><div class="model-options">${loading&&!loaded?'<p class="model-caption" role="status">Loading connected models…</p>':filtered.map(g=>`<div class="model-group"><h3><span class="agent-model-logo">${BuddyBrands.logo(g.provider)}</span>${g.name}</h3>${g.models.map(m=>`<button type="button" class="model-option" data-model-provider="${g.provider}" data-model-select="${esc(m.id)}" aria-pressed="${selected?.provider===g.provider&&selected.model===m.id}" ${saving?'disabled':''}><span>${esc(m.name)}</span>${selected?.provider===g.provider&&selected.model===m.id?icon('check'):''}</button>`).join('')}</div>`).join('')}${loaded&&!filtered.length?`<p class="model-caption">${snapshot.models.length?'No matching models.':'Connect OpenAI or Claude in Settings to choose a model.'}</p>`:''}</div>${Object.entries(snapshot.errors||{}).map(([p,e])=>`<p class="model-error">${esc(p==='chatgpt'?'OpenAI':'Claude')}: ${esc(e)}</p>`).join('')}${error?`<p class="model-error" role="alert">${esc(error)}</p>`:''}<div class="model-picker-footer"><p>${lookup(snapshot,selected)?.current===false?'Your saved model stays selected until you choose a current model.':`Saved for ${esc(agentName(activeAgent))}. Applies to the next reply.`}</p><button type="button" data-model-refresh ${loading||saving?'disabled':''}>Refresh</button><button type="button" data-model-connections>Connections</button></div></section>`;
    position();if(focus){const input=menu.querySelector('[data-model-search]');input.focus();input.setSelectionRange(query.length,query.length);}
  }
  function close(){const id=activeAgent;activeAgent='';menu.innerHTML='';draw();triggerFor(id)?.focus({preventScroll:true});}
  async function refresh(force=false){
    if(!native()){loaded=true;draw();return;}
    if(pending)return pending;
    if(!force&&loaded&&Date.now()-lastLoad<60000){draw();return;}
    const token=++generation;loading=true;draw();
    pending=(async()=>{try{const result=await BuddyDesktop.agentModels({operation:'list',refresh:force});if(token!==generation)return;snapshot=result;loaded=true;lastLoad=Date.now();error='';}catch(e){if(token===generation){error=String(e.message||e);loaded=true;}}finally{loading=false;pending=null;draw();}})();return pending;
  }
  async function choose(provider,model){
    if(saving||!activeAgent)return;const agent=activeAgent;saving=agent;error='';draw();
    try{const result=await BuddyDesktop.agentModels({operation:'set',agentId:agent,provider,model});snapshot=result;loaded=true;lastLoad=Date.now();saving='';close();showToast(`${agentName(agent)} will use ${label(snapshot,agent)} for the next reply.`);}
    catch(e){error=String(e.message||e);}
    finally{saving='';draw();}
  }
  api.slot=agent=>`<div class="agent-model-slot" data-agent-model="${esc(agent)}">${button(agent)}</div>`;
  api.settings=agent=>`<div class="agent-model-setting"><span>Model</span>${api.slot(agent)}</div>`;
  api.mount=()=>{draw();if(native()&&(!loaded||state.agents.some(a=>!snapshot.agents?.[a.id])))refresh(true);};
  api.current=selection;api.refresh=refresh;api.native=native;
  document.addEventListener('click',e=>{const open=e.target.closest('[data-model-open]'),option=e.target.closest('[data-model-select]');if(open){activeAgent=open.dataset.modelOpen;error='';drawMenu();refresh();menu.querySelector('[data-model-search]')?.focus();}else if(option)choose(option.dataset.modelProvider,option.dataset.modelSelect);else if(e.target.closest('[data-model-close]'))close();else if(e.target.closest('[data-model-refresh]'))refresh(true);else if(e.target.closest('[data-model-connections]')){close();BuddyProviders.open();}else if(activeAgent&&!menu.contains(e.target))close();});
  menu.addEventListener('input',e=>{if(e.target.matches('[data-model-search]'))drawMenu();});
  menu.addEventListener('keydown',e=>{if(e.key==='Escape'){e.preventDefault();e.stopPropagation();close();return;}if(e.key==='Tab'){const all=[...menu.querySelectorAll('button:not(:disabled):not(.model-backdrop),input:not(:disabled)')],first=all[0],last=all.at(-1);e.stopPropagation();if(e.shiftKey&&document.activeElement===first){e.preventDefault();last?.focus();}else if(!e.shiftKey&&document.activeElement===last){e.preventDefault();first?.focus();}return;}if(['ArrowDown','ArrowUp','Home','End'].includes(e.key)&&!(e.target.matches('[data-model-search]')&&['Home','End'].includes(e.key))){e.preventDefault();const buttons=[...menu.querySelectorAll('[data-model-select]:not(:disabled)')],index=buttons.indexOf(document.activeElement);const next=e.key==='Home'?0:e.key==='End'?buttons.length-1:e.key==='ArrowUp'?(index<=0?buttons.length-1:index-1):(index+1)%buttons.length;buttons[next]?.focus();}});
  window.addEventListener('resize',()=>{if(activeAgent)position();});
  window.addEventListener('buddy-provider-updated',()=>refresh(true));
  window.addEventListener('buddy-view-updated',()=>{if(activeAgent)close();api.mount();});
  api.mount();
})(typeof globalThis!=='undefined'?globalThis:this);

(function(root){
  'use strict';
  const uid=()=>globalThis.crypto.randomUUID();
  const Interview=root.BuddyAgentSetup||(typeof module!=='undefined'?require('./buddy-agent-setup'):null);
  const defaults=()=>({name:'Buddy',role:'Getting started',description:Interview.bootstrap,avatarShape:'star',avatarColor:'lilac',tools:{web:true,projectFiles:true},groupIds:[]});
  function blank(){return {version:1,messagingRevision:2,agents:[],groups:[],tasks:[],files:[],messages:{},drafts:{},attachments:{},proposals:[],runs:{},lastView:{kind:'chat',target:null},conversationWorkspace:uid(),onboarding:{version:1,status:'pending',registrationId:uid(),draft:defaults()}};}
  function migrate(value){
    if(!value.onboarding){const draft=defaults();let suffix=1;while(value.agents.some(a=>a.name.toLowerCase()===draft.name.toLowerCase())){draft.name=suffix===1?'My Buddy':`My Buddy ${suffix}`;suffix++;}value.onboarding={version:1,status:'pending',registrationId:uid(),draft};}
    value.onboarding.registrationId||=uid();value.onboarding.draft||=defaults();return value;
  }
  function needed(value){return !['completed','dismissed'].includes(value.onboarding?.status);}
  function prepare(value,input,team){
    if(value.onboarding?.status==='completed')return {state:team.copy(value),agent:team.copy(value.agents.find(a=>a.id===value.onboarding.agentId))};
    const next=migrate(team.copy(value)),config={...input,tools:{web:true,projectFiles:true},groupIds:[]};
    // Only a reviewed human submission adds the first agent. A stable ID makes
    // retrying a save with an uncertain outcome produce the same registration.
    const agent=team.createAgent(next,config,{actor:'user'}),temporary=agent.id;
    agent.id=next.onboarding.registrationId;agent.status='Ready';delete next.messages[temporary];next.messages[agent.id]=[];
    next.onboarding={...next.onboarding,status:'completed',agentId:agent.id,completedAt:new Date().toISOString(),draft:team.config(config)};
    agent.setupSeed=config.description===Interview.bootstrap?'':config.description;Interview.seed(next,agent);next.lastView={kind:'chat',target:agent.id};return {state:next,agent};
  }
  const api={blank,migrate,needed,prepare,defaults};root.BuddyOnboarding=api;if(typeof module!=='undefined')module.exports=api;
  if(typeof document==='undefined')return;
  let committing=false;
  const active=()=>!!document.querySelector('.onboarding-screen');
  function read(){const draft=state.onboarding.draft;return {name:document.getElementById('setup-name').value,description:draft.description||defaults().description,role:draft.role||defaults().role,avatarShape:document.querySelector('[name=avatar-shape]:checked')?.value||draft.avatarShape,avatarColor:document.querySelector('[name=avatar-color]:checked')?.value||draft.avatarColor,tools:{web:true,projectFiles:true},groupIds:[]};}
  function connectionBody(){return chatConnection.checking?'<span class="onboarding-connection-caption" role="status">Checking connections…</span>':chatConnection.claude?.connected?`${icon('check')}<span>Claude is ready to prepare your agent</span>`:window.BuddyDesktop?.providerSettings?`<button type="button" class="onboarding-connect" data-setup-sign-in>Connect Claude${icon('arrow')}</button>`:'<span class="onboarding-connection-caption">Open Buddy for Mac to prepare instructions with Claude.</span>';}
  function refreshConnection(){const el=document.getElementById('setup-connection');if(el)el.innerHTML=connectionBody();const button=el?.querySelector('[data-setup-sign-in]');if(button)button.addEventListener('click',async()=>{button.disabled=true;try{updateConnection(await window.BuddyDesktop.providerSettings({operation:'connect',provider:'claude'}));}catch(error){document.getElementById('setup-status').textContent=String(error.message||error);}finally{if(active())refreshConnection();}});}
  function close(){document.getElementById('onboarding-root').innerHTML='';document.getElementById('app').inert=!!document.querySelector('.modal-overlay');document.getElementById('message-input')?.focus();}
  async function dismiss(){if(committing||!state.agents.length)return;const candidate=RelayTeam.copy(state);candidate.onboarding.status='dismissed';try{await persistWorkspace(candidate);state=candidate;close();}catch(error){document.getElementById('setup-error').textContent=String(error.message||error);}}
  function open(){
    if(committing)return;
    if(state.onboarding?.status==='completed'&&findAgent(state.onboarding.agentId)){agentInfo(state.onboarding.agentId);return;}
    if(document.querySelector('.modal-overlay'))closeModal();migrate(state);
    if(state.onboarding.status==='completed'){state.onboarding.registrationId=uid();state.onboarding.draft=defaults();}state.onboarding.status='pending';save();
    const c=RelayTeam.config(state.onboarding.draft),picker=avatarPicker(c),cut=picker.indexOf('<fieldset');
    document.getElementById('app').inert=true;
    document.getElementById('onboarding-root').innerHTML=`<section class="onboarding-screen" role="dialog" aria-modal="true" aria-labelledby="setup-title"><div class="onboarding-scroll"><div class="onboarding-card"><div class="onboarding-brand">${buddyLogo()}<span>Buddy</span></div><h1 id="setup-title">Your first Buddy.</h1><p class="onboarding-intro">Give them a name. They’ll learn the job in chat.</p><form id="buddy-setup-form">${picker.slice(0,cut)}<details class="onboarding-look"><summary>Change their look${icon('down')}</summary>${picker.slice(cut)}</details><div class="field"><label for="setup-name">Name</label><input id="setup-name" value="${esc(c.name)}" placeholder="What should we call them?" maxlength="40" required autocomplete="off"></div><div id="setup-connection" class="onboarding-connection"></div><p id="setup-status" class="onboarding-status" role="status"></p><p id="setup-error" class="field-error" role="alert">${esc(workspaceReadError||'')}</p><button type="submit" class="primary-button onboarding-submit" ${workspaceReadError?'disabled':''}>Start chatting${icon('arrow')}</button>${state.agents.length?'<button type="button" class="onboarding-later" data-setup-later>Back to my chats</button><p class="onboarding-preserved">Your existing chats and files stay saved.</p>':''}</form></div></div></section>`;
    document.querySelector('.config-preview small').textContent='A few questions, then ready to help.';
    const form=document.getElementById('buddy-setup-form');
    const update=()=>{const value=read();state.onboarding.draft=value;document.getElementById('config-avatar-preview').innerHTML=configuredAvatar(value);document.getElementById('config-preview-name').textContent=value.name.trim()||'Your Buddy';for(const image of document.querySelectorAll('[data-shape-preview]'))image.style.filter=avatarFilter(image.dataset.shapePreview,value.avatarColor);save();};
    form.addEventListener('input',update);form.addEventListener('change',update);
    document.querySelector('[data-setup-later]')?.addEventListener('click',dismiss);
    form.addEventListener('submit',async event=>{
      event.preventDefault();if(committing)return;const error=document.getElementById('setup-error'),button=form.querySelector('[type=submit]');error.textContent='';
      let result;try{result=prepare(state,read(),RelayTeam);}catch(reason){error.textContent=reason.message;return;}
      committing=true;button.textContent='Saving your Buddy…';for(const field of form.querySelectorAll('button,input,textarea'))field.disabled=true;
      try{await persistWorkspace(result.state);state=result.state;ui.view=state.lastView;ui.lastChat=result.agent.id;ui.mobile=false;ui.chatFilter='';close();render();Interview.ensure(result.agent.id);document.getElementById('message-input')?.focus();}
      catch(reason){error.textContent=`${String(reason.message||reason)} Your choices are still here. Try again.`;for(const field of form.querySelectorAll('button,input,textarea'))field.disabled=false;button.innerHTML=`Start chatting${icon('arrow')}`;}
      finally{committing=false;}
    });
    refreshConnection();document.getElementById('setup-name').focus();
  }
  document.addEventListener('keydown',event=>{
    if(!active())return;
    if(event.key==='Escape'){event.preventDefault();event.stopImmediatePropagation();if(state.agents.length)dismiss();return;}
    if((event.metaKey||event.ctrlKey)&&['k','n',','].includes(event.key.toLowerCase())){event.preventDefault();event.stopImmediatePropagation();return;}
    if(event.key==='Tab'){const controls=[...document.querySelectorAll('.onboarding-screen button:not([disabled]),.onboarding-screen input:not([disabled]),.onboarding-screen textarea:not([disabled]),.onboarding-screen summary')].filter(el=>el.offsetParent!==null&&(!el.closest('details')||el.tagName==='SUMMARY'||el.closest('details').open)&&(!(el.type==='radio')||el.checked)),first=controls[0],last=controls.at(-1);if(event.shiftKey&&document.activeElement===first){event.preventDefault();last?.focus();}else if(!event.shiftKey&&document.activeElement===last){event.preventDefault();first?.focus();}}
  },true);
  document.addEventListener('click',event=>{if(active()&&!event.target.closest('.onboarding-screen')){event.preventDefault();event.stopImmediatePropagation();document.getElementById('setup-name')?.focus();}},true);
  document.addEventListener('click',event=>{if(event.target.closest('[data-action=onboarding]'))open();});
  window.addEventListener('buddy-conversation',event=>{if(event.detail?.type==='connection')refreshConnection();});
  Object.assign(api,{open,active,refreshConnection,boot:()=>{migrate(state);if(needed(state))open();}});
})(typeof globalThis!=='undefined'?globalThis:this);

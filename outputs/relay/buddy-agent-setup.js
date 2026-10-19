(function(root){
  'use strict';
  const bootstrap='Learn the job the user wants help with through the setup conversation before beginning work.';
  const busy=status=>['thinking','generating'].includes(status);
  const required=agent=>agent?.setupStatus==='pending';
  function seed(value,agent){
    agent.setupStatus='pending';value.agentSetup||={};
    if(value.agentSetup[agent.id])return;
    const first={id:crypto.randomUUID(),who:agent.id,body:`Hi, I'm ${agent.name}. What would you like me to take care of, and what would a good result look like?`,time:new Date().toLocaleTimeString([], {hour:'2-digit',minute:'2-digit'}),live:true,status:'completed',setup:true};
    value.agentSetup[agent.id]={workspace:value.conversationWorkspace,agentId:agent.id,status:'interview',revision:0,profileRevision:0,messages:[first]};
    value.messages[agent.id]=[first];
  }
  function apply(value,r){
    const a=value.agents.find(a=>a.id===r?.agentId);
    if(!a||r.workspace!==value.conversationWorkspace||!Number.isInteger(r.revision)||!Array.isArray(r.messages))return false;
    value.agentSetup||={};const old=value.agentSetup[a.id];
    if(old&&r.revision<old.revision)return false;
    value.agentSetup[a.id]=structuredClone(r);a.setupStatus=r.status==='ready'?'ready':'pending';
    if(typeof r.instructions==='string'&&typeof r.role==='string'&&(r.profileRevision||0)>=(a.profileRevision||0)&&(!(a.memoryRevision>0)||(r.profileRevision||0)>(a.profileRevision||0))){if((r.profileRevision||0)>(a.profileRevision||0)){delete a.memoryRevision;delete a.learnedRules;delete a.learningError;}a.description=r.instructions;a.role=r.role;a.profileRevision=r.profileRevision||0;}
    const previous=(value.messages[a.id]||[]).filter(m=>!m.setup);
    value.messages[a.id]=structuredClone(r.messages).concat(previous);
    if(busy(r.status))value.messages[a.id].push({id:`setup-pending-${a.id}`,who:a.id,body:'',time:'',live:true,status:'answering',setup:true});
    if(['failed','stopped'].includes(r.status))value.messages[a.id].push({id:`setup-error-${a.id}`,who:a.id,body:'',time:'',live:true,status:r.status,error:r.error||'Setup could not finish. Your answers are saved.',setup:true,setupRetry:true});
    return true;
  }
  function active(value,id){return busy(value.agentSetup?.[id]?.status)?{runId:`setup:${id}`,target:id,status:'answering',setup:true}:null;}
  const api={bootstrap,busy,required,seed,apply,active};root.BuddyAgentSetup=api;if(typeof module!=='undefined')module.exports=api;
  if(typeof document==='undefined')return;
  const starting=new Map(),sending=new Set();
  const request=payload=>{if(!window.BuddyDesktop?.agentSetup)throw Error('Open Buddy for Mac to prepare your agent with Claude.');return window.BuddyDesktop.agentSetup(payload);};
  function receive(r){
    if(!apply(state,r))return;save();refreshLiveChat(r.agentId);
    if(ui.view.kind==='chat'&&ui.view.target===r.agentId){
      const subtitle=document.querySelector('.conversation-subtitle');if(subtitle)subtitle.textContent=findAgent(r.agentId)?.role||'';
      const hint=document.querySelector('.composer-hint[data-action="connection"]');if(hint)hint.textContent=connectionLabel();window.BuddyModels?.mount();
      document.querySelector('[data-setup-finish]')?.remove();
      if(required(findAgent(r.agentId))&&!busy(r.status)&&r.messages.some(m=>m.who==='you'))document.querySelector('.composer-wrap')?.insertAdjacentHTML('beforeend',`<button type="button" class="composer-hint" data-setup-finish="${esc(r.agentId)}">Finish setup with what I’ve shared</button>`);
    }
  }
  async function ensure(id){
    const a=findAgent(id);if(!a||!required(a))return;
    if(starting.has(id))return starting.get(id);
    const promise=(async()=>{try{await persistenceQueue;const result=await request({action:'begin',agentId:id});receive(result.interview);}catch(e){showToast(String(e.message||e));}finally{starting.delete(id);}})();starting.set(id,promise);return promise;
  }
  async function send(id,{action='answer'}={}){
    if(sending.has(id)||active(state,id))return;sending.add(id);
    try{
      await ensure(id);const r=state.agentSetup?.[id];
      const text=state.drafts[id]||'';if(action==='answer'&&!text.trim())return;
      const result=await request({action,agentId:id,requestId:crypto.randomUUID(),revision:r?.revision,text});
      if(action==='answer'&&state.drafts[id]===text)state.drafts[id]='';
      receive(result.interview);if(ui.view.target===id){render();const body=document.getElementById('chat-body');if(body)body.scrollTop=body.scrollHeight;document.getElementById('message-input')?.focus();}
    }catch(e){showToast(String(e.message||e));}finally{sending.delete(id);}
  }
  async function edit(id,config){
    if(!window.BuddyDesktop?.agentSetup)return;
    await ensure(id);const result=await request({action:'edit',agentId:id,role:config.role,instructions:config.description});receive(result.interview);
  }
  // An agent that already has a complete role and instructions (a team plan wrote them) can skip the questions: saving them as they are finishes setup.
  const usable=a=>required(a)&&typeof a.role==='string'&&!!a.role.trim()&&a.role.length<=55&&typeof a.description==='string'&&!!a.description.trim()&&a.description.length<=1500;
  async function useInstructions(ids){
    const done=[];
    for(const id of ids){
      const a=findAgent(id);if(!a||!required(a))continue;
      if(!usable(a))throw Error(`${a.name}’s role or instructions are empty or too long (55 and 1,500 characters). Open their settings to shorten them.`);
      await edit(id,{role:a.role,description:a.description});done.push(id);
    }
    return done;
  }
  const pendingMembers=group=>(group?.members||[]).map(findAgent).filter(a=>a&&required(a));
  const list=names=>names.length>1?names.slice(0,-1).join(', ')+' and '+names.at(-1):names[0]||'';
  // Offers the one-click way out wherever the person is stuck on setup: the agent's own chat, its settings, and a team chat with unfinished members.
  function offer(){
    document.querySelectorAll('.setup-offer').forEach(el=>el.remove());
    if(typeof ui==='undefined'||ui.view?.kind!=='chat')return;
    const wrap=document.querySelector('.composer-wrap');if(!wrap)return;
    const target=ui.view.target,agent=findAgent(target),group=agent?null:findGroup(target);
    if(agent&&usable(agent))wrap.insertAdjacentHTML('afterbegin',`<div class="setup-offer"><span>${esc(agent.name)} can start with the instructions already saved.</span><button type="button" class="small-link" data-setup-use="${esc(agent.id)}">Skip the questions</button></div>`);
    else if(group){const pending=pendingMembers(group);if(pending.length)wrap.insertAdjacentHTML('afterbegin',`<div class="setup-offer"><span>${esc(list(pending.map(a=>a.name)))} ${pending.length>1?'haven’t':'hasn’t'} finished setup, so the team can’t start work yet.</span><button type="button" class="small-link" data-setup-use="${esc(pending.filter(usable).map(a=>a.id).join(','))}" ${pending.some(usable)?'':'disabled'}>Use their instructions</button></div>`);}
  }
  function offerInSettings(){
    const form=document.getElementById('bot-settings'),open=form?.querySelector('[data-continue-setup]');
    if(!form||!open||form.querySelector('[data-setup-use]'))return;
    const agent=findAgent(open.dataset.continueSetup);if(!usable(agent))return;
    open.insertAdjacentHTML('afterend',`<button type="button" class="small-link" data-setup-use="${esc(agent.id)}">Use these instructions and finish setup</button>`);
  }
  async function stop(id){try{const result=await request({action:'stop',agentId:id});receive(result.interview);}catch(e){showToast(String(e.message||e));}}
  window.addEventListener('buddy-conversation',event=>{if(event.detail?.type==='agent-setup')receive(event.detail.interview);});
  document.addEventListener('click',event=>{const button=event.target.closest('[data-setup-retry],[data-setup-finish],[data-continue-setup]');if(!button)return;const id=button.dataset.setupRetry||button.dataset.setupFinish||button.dataset.continueSetup;if(button.hasAttribute('data-continue-setup')){closeModal();navigate('chat',id);}else send(id,{action:button.hasAttribute('data-setup-retry')?'retry':'finish'});});
  let using=false;
  document.addEventListener('click',async event=>{
    const button=event.target.closest('[data-setup-use]');if(!button||using||button.disabled)return;
    const ids=String(button.dataset.setupUse).split(',').filter(Boolean);if(!ids.length)return;
    using=true;button.disabled=true;
    try{
      const done=await useInstructions(ids);
      if(document.getElementById('bot-settings'))closeModal();
      render();showToast(done.length>1?'Setup finished for '+list(done.map(id=>findAgent(id).name))+'.':done.length?`${findAgent(done[0]).name} is ready.`:'Nothing to finish.');
    }catch(e){showToast(String(e.message||e));button.disabled=false;}
    finally{using=false;}
  });
  window.addEventListener('buddy-view-updated',()=>{offer();});
  new MutationObserver(()=>offerInSettings()).observe(document.body,{childList:true,subtree:true});
  Object.assign(api,{useInstructions,usable,ensure,send,edit,stop,boot:async()=>{if(!window.BuddyDesktop?.agentSetup)return;try{const result=await request({action:'status'});for(const r of result.interviews||[])receive(r);if(ui.view.kind==='chat')ensure(ui.view.target);}catch(e){showToast(String(e.message||e));}}});
})(typeof globalThis!=='undefined'?globalThis:this);

(function(root){
  'use strict';
  const name=provider=>provider==='claude'?'Claude':'ChatGPT';
  const connected=(snapshot,provider)=>snapshot?.[provider]?.connected===true;
  const active=snapshot=>connected(snapshot,snapshot.provider||'chatgpt');
  const api={name,connected,active};root.BuddyProviders=api;if(typeof module!=='undefined')module.exports=api;
  if(typeof document==='undefined')return;
  let generation=0;
  let snapshot={provider:'chatgpt',chatgpt:{connected:false},claude:{connected:false}},loaded=false,busy='',error='',budgetDraft=null;
  const native=()=>!!window.BuddyDesktop?.providerSettings;
  const request=payload=>{if(!native())throw Error('Open the Buddy Mac app to manage AI connections.');return window.BuddyDesktop.providerSettings(payload);};
  function section(){
    return `<section class="provider-settings" data-provider-settings aria-label="AI provider" aria-busy="${!!busy}"><div class="provider-heading"><strong>AI provider</strong><span>${loaded?(active(snapshot)?'Connected':'Not connected'):'Checking…'}</span></div><p>Choose the starting provider for new agents. Each agent keeps its own model.</p><div class="provider-choices" role="group" aria-label="Choose AI provider">${['chatgpt','claude'].map(p=>`<button type="button" class="provider-choice ${snapshot.provider===p?'selected':''}" data-provider-select="${p}" aria-pressed="${snapshot.provider===p}" ${busy?'disabled':''}><span class="provider-symbol">${BuddyBrands.logo(p)}</span><span><strong>${name(p)}</strong><small>${p==='claude'?'API credits':'Your subscription'}</small></span>${snapshot.provider===p?icon('check'):''}</button>`).join('')}</div><div class="provider-connections">${['chatgpt','claude'].map(p=>`<div class="provider-row"><div class="provider-identity"><span class="provider-symbol">${BuddyBrands.logo(p)}</span><span><strong>${name(p)}</strong><small>${busy===p?'Connecting…':!loaded?'Checking…':connected(snapshot,p)?'Connected':'Not connected'}</small></span></div><div class="provider-row-actions">${connected(snapshot,p)?`<button type="button" data-provider-op="reconnect" data-provider="${p}" ${busy?'disabled':''}>Reconnect</button><button type="button" data-provider-op="disconnect" data-provider="${p}" ${busy?'disabled':''}>Disconnect</button>`:`<button type="button" class="border-button" data-provider-op="connect" data-provider="${p}" ${busy?'disabled':''}>Connect</button>`}</div></div>`).join('')}</div><details class="provider-details"><summary>How connections work${icon('down')}</summary><p>ChatGPT uses the account signed in on this Mac. Disconnect turns off Buddy’s access; your ChatGPT sign-in stays available to other apps.</p><p>Claude connects with a Console API key stored in macOS Keychain. Gmail, connected services, and Mac app control still need the ChatGPT connection.</p><p>The starting provider applies to new agents. Change an existing agent’s model in its chat. Running tasks keep their provider and model. Disconnecting pauses work that depends on that provider.</p></details>${!native()?'<p class="provider-caption">Open the Mac app to connect your accounts.</p>':''}<p class="field-error" data-provider-error role="alert">${esc(error)}</p></section>`;
  }
  function draw(){const el=document.querySelector('[data-provider-settings]');if(!el)return;const focus=document.activeElement,editing=focus?.matches('[data-provider-budget]');const selectedFocus=focus?.dataset?.providerSelect;const operationFocus=focus?.dataset?.providerOp;const opened=[...el.querySelectorAll('details')].map(x=>x.open);el.outerHTML=section();const replacement=document.querySelector('[data-provider-settings]');replacement?.querySelectorAll('details').forEach((d,i)=>d.open=opened[i]||false);if(editing)replacement?.querySelector('[data-provider-budget]')?.focus();else if(selectedFocus)replacement?.querySelector(`[data-provider-select="${selectedFocus}"]`)?.focus();else if(operationFocus)replacement?.querySelector(`[data-provider-op="${operationFocus}"]:not(:disabled), .provider-choice.selected`)?.focus();}
  function receive(value){if(!value?.provider)return;const next={...snapshot,...value};const stable=s=>JSON.stringify([s.provider,s.connected,s.chatgpt?.connected,s.chatgpt?.enabled,s.claude?.connected,s.claude?.enabled,s.error]);const changed=!loaded||stable(next)!==stable(snapshot);snapshot=next;loaded=true;if(changed&&!busy)draw();}
  async function refresh(){const token=++generation;try{const value=await request({operation:'status'});if(token!==generation)return;const hadError=!!error;error='';receive(value);if(hadError)draw();}catch(e){if(token!==generation)return;error=String(e.message||e);loaded=true;draw();}}
  function publish(value){receive(value);if(typeof updateConnection==='function')updateConnection(value);window.dispatchEvent(new CustomEvent('buddy-provider-updated',{detail:value}));}
  async function act(operation,provider){
    if(busy)return;++generation;busy=provider||'saving';error='';draw();
    try{
      let payload={operation,provider};
      if(operation==='budget'){const amount=Number(budgetDraft??snapshot.claudeBudgetUSD);if(!Number.isFinite(amount)||amount<0.1||amount>10)throw Error('Choose a limit between $0.10 and $10.');payload={operation:'select',provider:snapshot.provider,claudeBudgetUSD:amount};}
      const value=await request(payload);publish(value);
      if(value.started)showToast('Finish signing in on the ChatGPT page.');
      else if(value.cancelled){/* A cancelled native key dialog leaves the prior connection intact. */}
      else if(operation==='select')showToast(`${name(provider)} is the starting provider for new agents.`);
      else if(operation==='disconnect')showToast(`${name(provider)} disconnected from Buddy.`);
      else if(operation==='budget'){budgetDraft=null;showToast('Claude limit saved.');}
      else showToast(`${name(provider)} connected.`);
    }catch(e){error=String(e.message||e);}
    finally{busy='';draw();}
  }
  api.section=section;api.receive=receive;api.refresh=refresh;api.mount=()=>{if(native())refresh();else{loaded=true;draw();}};
  api.open=()=>{openModal('AI provider',`${section()}<div class="modal-actions"><button class="primary-button" data-action="close-modal">Done${icon('check')}</button></div>`);api.mount();};
  api.connect=provider=>act('connect',provider);
  document.addEventListener('click',e=>{const choose=e.target.closest('[data-provider-select]'),op=e.target.closest('[data-provider-op]');if(choose)act('select',choose.dataset.providerSelect);else if(op)act(op.dataset.providerOp,op.dataset.provider);else if(e.target.closest('[data-action="provider-settings"]'))api.open();});
  document.addEventListener('input',e=>{if(e.target.matches('[data-provider-budget]'))budgetDraft=e.target.value;});
  window.addEventListener('buddy-conversation',e=>{if(e.detail?.type==='connection')receive(e.detail);});
  window.addEventListener('buddy-provider-updated',e=>receive(e.detail));
  setInterval(()=>{if(document.querySelector('[data-provider-settings]')&&!busy)refresh();},8000);
})(typeof globalThis!=='undefined'?globalThis:this);

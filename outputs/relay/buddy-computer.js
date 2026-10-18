/* Computer access is checked by the native bridge. App operations use in-chat reviews. */
const BuddyComputerUI = (() => {
  let snapshot={enabled:false,available:false},loading=false,error='',generation=0;
  function draw(){
    openModal('This Mac',`<div data-computer-panel><div class="connection-detail-heading"><span class="connection-mark">${icon('monitor')}</span><span class="connection-state ${snapshot.enabled?'available':''}">${loading?'Checking…':snapshot.enabled&&snapshot.available?'Connected':snapshot.enabled?'Connection unavailable':snapshot.available?'Ready to connect':'Not connected'}</span></div><p class="modal-description">Let your agents see and operate apps on this Mac.</p><p class="connections-caption">One agent at a time. Clicks and typing come to you for review in chat. ChatGPT’s app permissions still apply.</p>${error?`<p class="connections-notice error" role="alert">${esc(error)}</p>`:''}${snapshot.enabled?`<div class="connection-agent-list">${state.agents.map(a=>`<label class="connection-agent">${avatar(a.id)}<span><strong>${esc(a.name)}</strong><small>${esc(a.role)}</small></span><input type="checkbox" data-computer-agent="${esc(a.id)}" aria-label="Allow ${esc(a.name)} to use Mac apps" ${a.tools?.desktop!==false?'checked':''}></label>`).join('')}</div><p class="connections-caption">Access starts on for every agent. Turn it off whenever you want.</p>`:''}<details class="connections-more"><summary>How access works${icon('down')}</summary><p class="connections-caption">Uses your ChatGPT subscription and the Computer Use plugin installed on this Mac. ChatGPT may ask for app access, Screen Recording, or Accessibility permission. Manage those permissions in ChatGPT.</p><p class="connections-caption">This Mac needs to stay on. Buddy cannot connect to dots’ included cloud computers through the available integration.</p><a href="https://learn.chatgpt.com/docs/computer-use" target="_blank" rel="noopener noreferrer">Computer Use guide</a></details><div class="modal-actions"><button class="border-button" data-action="connections-back">Back</button>${snapshot.enabled?'<button class="border-button" data-action="computer-disable">Disconnect</button>':snapshot.available?`<button class="primary-button" data-action="computer-enable" ${loading?'disabled':''}>Connect this Mac${icon('arrow')}</button>`:`<button class="border-button" data-action="open-chatgpt">Open ChatGPT</button><button class="primary-button" data-action="computer-refresh" ${loading?'disabled':''}>${loading?'Checking…':'Retry'}${icon('arrow')}</button>`}</div></div>`);
  }
  async function refresh(){
    const token=++generation;loading=true;error='';draw();
    try{if(!window.BuddyDesktop?.computerStatus)throw Error('Open the Buddy Mac app to connect computer access.');snapshot=await window.BuddyDesktop.computerStatus();error=snapshot.error||'';}
    catch(reason){snapshot={enabled:false,available:false};error=String(reason.message||reason);}
    finally{if(token===generation){loading=false;if(document.querySelector('[data-computer-panel]'))draw();}}
  }
  async function toggle(enabled){
    if(loading)return;loading=true;error='';draw();
    try{snapshot=await window.BuddyDesktop.setComputerAccess(enabled);showToast(enabled?'This Mac is connected.':'Mac app access disconnected.');}
    catch(reason){error=String(reason.message||reason);}
    finally{loading=false;if(document.querySelector('[data-computer-panel]'))draw();}
  }
  document.addEventListener('click',event=>{
    const action=event.target.closest('[data-action]')?.dataset.action;
    if(action==='computer-settings'||action==='computer-refresh')refresh();
    if(action==='computer-enable')toggle(true);
    if(action==='computer-disable')toggle(false);
  });
  document.addEventListener('change',async event=>{
    const input=event.target.closest('[data-computer-agent]');if(!input)return;
    const agent=findAgent(input.dataset.computerAgent);if(!agent)return;
    const previous=agent.tools?.desktop!==false;agent.tools={...agent.tools,desktop:input.checked};input.disabled=true;
    try{await persistWorkspace(state);save();showToast(input.checked?`${agent.name} can use Mac apps.`:`Mac app access removed for ${agent.name}.`);}
    catch(reason){agent.tools.desktop=previous;input.checked=previous;showToast(String(reason.message||reason));}
    finally{input.disabled=false;}
  });
  return {open:refresh};
})();

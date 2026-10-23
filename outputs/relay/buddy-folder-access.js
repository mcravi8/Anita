(function(root){
  'use strict';
  // Places on the Mac an agent asks for. When an agent names a path outside the connected folders, the Mac app asks the person once
  // (BuddyFolderAccess in BuddyProjectFiles.swift) and lists the request here (`folderAccess` list): "Chief wants access to your Desktop —
  // to read paper.pdf", with ✓ Allow, ✗ Don't allow and, smaller, Allow my whole home folder. Each request is one card in the asking agent's
  // chat, one in the group the turn was in, and one in the team plan's group chat for a task; all are the same request, so answering one
  // answers them all. Only the person's click answers it, through the app's own bridge, and what agents may use is kept by the app with the
  // folder records, never in page state. Allowed, a waiting chat agent gets a follow-up turn with a plain note; a task resumes by itself.
  const KEPT=['id','status','name','label','reason','path','location','agentId','agentName','answer'];
  const view=r=>{const out={};for(const k of KEPT)if(r?.[k]!==undefined&&r[k]!==null&&r[k]!=='')out[k]=r[k];out.waiting=(r?.waiting||[]).map(w=>({agentId:w.agentId,agentName:w.agentName,chat:w.chat||'',taskId:w.taskId||''}));return out;};
  const nameOf=(state,id,fallback)=>(state?.agents||[]).find(a=>a.id===id)?.name||fallback||'An agent';
  /** The card's first line: "Chief wants access to your Desktop". */
  const title=(r,who)=>`${who||r.agentName||'An agent'} wants access to ${r.label||'a folder on your Mac'}`;
  const summary=(r,who)=>`${title(r,who)}${r.reason?` — ${r.reason}`:''}.`;
  /** The chats a request is shown in: each waiting agent's own chat, the group a turn was in, and a task's team plan group chat. */
  function chatsFor(state,snapshot,request){
    const out=[],add=(id,agent)=>{if(id&&!out.some(x=>x.chat===id))out.push({chat:id,agent});};
    const waiting=request.waiting?.length?request.waiting:[{agentId:request.agentId}];
    for(const w of waiting){
      if((state.agents||[]).some(a=>a.id===w.agentId))add(w.agentId,w.agentId);
      if(w.chat&&(state.groups||[]).some(g=>g.id===w.chat))add(w.chat,w.agentId);
      const plan=w.planId?(snapshot?.plans||[]).find(p=>p?.id===w.planId):null;
      if(plan?.groupId&&(state.groups||[]).some(g=>g.id===plan.groupId))add(plan.groupId,w.agentId);
    }
    return out;
  }
  function messages(state,id){const out=[];for(const list of Object.values(state.messages||{}))if(Array.isArray(list))for(const m of list)if(m?.kind==='access-request'&&m.request?.id===id)out.push(m);return out;}
  const stamp=()=>new Date().toLocaleTimeString([],{hour:'2-digit',minute:'2-digit'});
  const answered=r=>r.status==='allowed'?'Allowed.':'Not allowed.';
  /** Brings the chats up to date with the app's list: a card for each open request, and what came of one answered elsewhere (its other
   *  copy, a whole-home answer on another card, Settings). Returns whether anything changed. */
  function sync(state,overview,snapshot){
    if(!overview||overview.workspace!==state.conversationWorkspace||!Array.isArray(overview.requests))return false;
    let changed=false;const listed=new Set();
    for(const r of overview.requests){
      if(typeof r?.id!=='string'||!r.id)continue;listed.add(r.id);
      if(r.status==='pending'){
        for(const {chat,agent} of chatsFor(state,snapshot,r)){
          state.messages[chat]||=[];
          const next=view(r),m=state.messages[chat].find(x=>x?.kind==='access-request'&&x.request?.id===r.id);
          if(!m){state.messages[chat].push({id:`access-${r.id}@${chat}`,kind:'access-request',who:agent,chat,request:next,status:'open',body:summary(next,nameOf(state,agent,r.agentName)),time:stamp(),createdAt:new Date().toISOString()});changed=true;continue;}
          if(m.status==='open'&&JSON.stringify(m.request)!==JSON.stringify(next)){m.request=next;changed=true;}
        }
        continue;
      }
      for(const m of messages(state,r.id))if(m.status==='open'||m.status==='sending'){m.status=r.status==='allowed'?'allowed':'declined';m.result=m.result||answered(r);m.request={...m.request,status:r.status};changed=true;}
    }
    // A request the app no longer has (its history is kept short) is over.
    for(const list of Object.values(state.messages||{}))if(Array.isArray(list))for(const m of list)if(m?.kind==='access-request'&&m.status==='open'&&!listed.has(m.request?.id)){m.status='closed';m.result='This request has ended.';changed=true;}
    return changed;
  }
  /** What came of the person's answer, on every copy of each request it answered. */
  function settle(state,id,patch){const found=messages(state,id);for(const m of found){Object.assign(m,patch);if(patch.status&&m.request)m.request.status=patch.status==='allowed'?'allowed':patch.status==='declined'?'declined':m.request.status;}return found.length>0;}
  /** "Access to Desktop granted; continue." for each chat a waiting agent asked in (a task resumes by itself). */
  function followUps(waiting){
    const chats=new Map();
    for(const w of waiting||[])if(w?.status==='allowed'&&w.chat&&!w.taskId){const names=chats.get(w.chat)||[];if(!names.includes(w.name))names.push(w.name);chats.set(w.chat,names);}
    return [...chats].map(([chat,names])=>({chat,text:`Access to ${names.join(' and ')} granted; continue.`}));
  }
  /** "Allowed — Chief is continuing." */
  function outcome(state,waiting,choice){
    if(choice==='deny')return 'Not allowed.';
    const names=[...new Set((waiting||[]).map(w=>nameOf(state,w.agentId,w.agentName)))];
    return names.length?`Allowed — ${names.length>1?names.slice(0,-1).join(', ')+' and '+names.at(-1)+' are':names[0]+' is'} continuing.`:'Allowed.';
  }
  const api={sync,settle,view,chatsFor,title,summary,followUps,outcome};root.BuddyFolderAccess=api;if(typeof module!=='undefined')module.exports=api;
  if(typeof document==='undefined')return;

  // MARK: on the page

  const busy=new Set();let overview=null,loading=null,lastLoad=0;
  const bridge=()=>{if(!window.BuddyDesktop?.folderAccess)throw Error('Open Buddy on this Mac to answer this.');return window.BuddyDesktop.folderAccess;};
  const short=path=>{const home=overview?.home;return home&&(path===home||String(path).startsWith(home+'/'))?'~'+String(path).slice(home.length):String(path||'');};
  function body(m){
    const r=m.request||{},who=nameOf(state,m.who,r.agentName),open=m.status==='open',off=!open||busy.has(r.id);
    let html=`<strong class="access-title">${esc(title(r,who))}${r.reason?` <span class="access-reason">— ${esc(r.reason)}</span>`:''}</strong>`;
    if(r.path)html+=`<small class="access-path">${esc(r.path)}</small>`;
    if(m.result)html+=`<p class="access-result ${m.status==='allowed'?'ok':''}" role="status">${esc(m.result)}</p>`;
    if(!open&&m.status!=='sending')return html;
    html+=`<div class="access-actions"><button type="button" class="primary-button" data-access-allow="${esc(r.id)}" ${off?'disabled':''}>✓ Allow</button><button type="button" class="border-button" data-access-deny="${esc(r.id)}" ${off?'disabled':''}>✗ Don’t allow</button></div>`;
    html+=`<button type="button" class="access-home" data-access-home="${esc(r.id)}" ${off?'disabled':''}>Allow my whole home folder</button>`;
    html+=`<small class="access-assurance">Asked once: your answer is kept in Files › Folder & access, where you can change it. Keys, passwords and system files stay private either way.</small>`;
    return html;
  }
  // Answered (here, in Settings, or ended), the card leaves the chat: only a request still open, or on its way, is drawn.
  function render(m){
    if(!['open','sending'].includes(m.status))return '';
    const a=findAgent(m.who)||findAgent(m.request?.agentId);if(!a)return '';
    const group=!!findGroup(ui.view.target),done=m.status!=='open';
    return `<div class="message bot-message access-message ${done?'access-ended':''}" data-access-request="${esc(m.request?.id||'')}">${group?avatar(a.id,true):''}<div class="bot-bubble access-bubble">${group?`<button class="message-author" style="${authorColor(a)}" data-action="agent-info" data-id="${esc(a.id)}">${esc(a.name)}</button>`:''}${body(m)}<time>${esc(m.time||'')}</time></div></div>`;
  }
  api.render=render;
  if(typeof window.messageHTML==='function'){const original=window.messageHTML;window.messageHTML=function(m){return m?.kind==='access-request'?render(m):original.apply(this,arguments);};}
  function redraw(){
    save();
    if(typeof ui!=='undefined'&&ui.view?.kind==='chat'&&typeof refreshLiveChat==='function')refreshLiveChat(ui.view.target);
    if(typeof repaintChatList==='function')repaintChatList();
  }
  // A follow-up turn in the chat the agent asked in, once that chat has finished answering (the agent's reply that asked may still be ending).
  async function followUp(chat,text){
    const until=Date.now()+120000;
    while(Date.now()<until&&BuddyChat.active(state,chat))await new Promise(r=>setTimeout(r,400));
    if(BuddyChat.active(state,chat)||!window.BuddyDesktop?.sendMessage||(!findAgent(chat)&&!findGroup(chat)))return;
    let run;
    try{
      const begun=BuddyChat.begin(state,chat,{text});run=begun.run;
      save();if(ui.view.kind==='chat'&&ui.view.target===chat)refreshLiveChat(chat);else repaintChatList();
      await persistWorkspace(state);await window.BuddyDesktop.sendMessage(begun.payload);
    }catch(error){if(run){BuddyChat.apply(state,{runId:run.runId,status:'failed',error:String(error.message||error)});save();refreshLiveChat(chat);}else showToast(String(error.message||error));}
  }
  /** After an answer or a Settings change: what it answered, on every card, and the follow-up turns for the chats that waited. */
  function apply(reply,id,choice){
    const waiting=reply?.waiting||[];
    for(const r of reply?.answered||[])settle(state,r.id,{status:r.status==='allowed'?'allowed':'declined',result:r.status==='allowed'?outcome(state,waiting.filter(w=>w.requestId===r.id),'allow'):'Not allowed.'});
    if(id&&reply?.request?.status&&reply.request.status!=='pending'&&!(reply.answered||[]).some(r=>r.id===id))settle(state,id,{status:reply.request.status==='allowed'?'allowed':'declined',result:answered(reply.request)});
    redraw();
    for(const f of followUps(waiting))followUp(f.chat,f.text);
    if(waiting.some(w=>w.taskId))window.BuddyWorkerUI?.refresh?.(false);
  }
  async function answer(id,choice){
    if(busy.has(id))return;
    busy.add(id);settle(state,id,{status:'sending',result:''});redraw();
    try{const reply=await bridge()({action:'answer',id,choice});busy.delete(id);apply(reply,id,choice);
      const said=messages(state,id).find(m=>m.result)?.result;showToast(reply?.resumeError||said||(choice==='deny'?'Not allowed.':'Allowed.'));}
    catch(error){busy.delete(id);settle(state,id,{status:'open',result:String(error?.message||error)});redraw();}
    refresh(true);
  }

  // MARK: Settings (Files › Folder & access)

  function settingsInner(){
    if(!overview)return '<p class="access-caption" role="status">Loading places agents can use…</p>';
    const rows=[],row=(name,detail,button)=>`<div class="access-row"><span><strong>${esc(name)}</strong><small>${esc(detail)}</small></span>${button}</div>`;
    rows.push(row('Whole home folder',overview.wholeHome?'Allowed: every place in your home folder, except keys, passwords and system files.':'Not allowed: agents ask once for each place.',overview.wholeHome?`<button type="button" class="border-button" data-access-setting="removeHome">Remove</button>`:`<button type="button" class="border-button" data-access-setting="allowHome">Allow</button>`));
    for(const f of overview.granted||[])rows.push(row(f.name,`Allowed · ${short(f.location)}`,`<button type="button" class="border-button" data-access-remove="${esc(f.folderId)}" aria-label="Remove ${esc(f.name)}">Remove</button>`));
    for(const d of overview.declined||[])rows.push(row(d.name,`Not allowed · ${short(d.path)}`,`<button type="button" class="border-button" data-access-place="${esc(d.path)}" aria-label="Allow ${esc(d.name)}">Allow</button>`));
    return `<h4>Places agents can use</h4><p class="access-caption">When an agent needs another place on your Mac, it asks once in the chat. Your answers are kept here.</p>${rows.join('')}<p class="field-error" data-access-error role="alert"></p>`;
  }
  function paintSettings(){for(const el of document.querySelectorAll('[data-folder-access-settings]'))el.innerHTML=settingsInner();}
  // The Files drawer (and the docked project panel) draw "Folder & access" themselves; the places agents can use go inside it, whenever it is drawn.
  function placeSettings(){
    if(!window.BuddyDesktop?.folderAccess)return;
    for(const details of document.querySelectorAll('.project-folder-details')){
      if(details.querySelector('[data-folder-access-settings]'))continue;
      const section=document.createElement('section');section.className='access-settings';section.dataset.folderAccessSettings='';section.innerHTML=settingsInner();
      details.insertBefore(section,details.querySelector(':scope > small'));refresh();
    }
  }
  new MutationObserver(placeSettings).observe(document.body,{childList:true,subtree:true});
  async function change(button,request){
    button.disabled=true;
    try{const reply=await request();if(reply&&reply.workspace)overview=reply;apply(reply);paintSettings();window.dispatchEvent(new CustomEvent('buddy-conversation',{detail:{type:'project-files-changed'}}));}
    catch(error){const el=button.closest('[data-folder-access-settings]')?.querySelector('[data-access-error]');if(el)el.textContent=String(error?.message||error);}
    finally{if(button.isConnected)button.disabled=false;refresh(true);}
  }

  async function refresh(force){
    if(!window.BuddyDesktop?.folderAccess)return null;
    if(loading)return loading;
    if(!force&&Date.now()-lastLoad<2500)return overview;
    loading=(async()=>{
      try{const value=await window.BuddyDesktop.folderAccess({action:'list'});lastLoad=Date.now();overview=value;if(sync(state,value,window.BuddyWorkerUI?.snapshot?.()))redraw();paintSettings();return value;}
      catch{return null;}finally{loading=null;}
    })();
    return loading;
  }
  api.refresh=refresh;
  document.addEventListener('click',e=>{
    const t=e.target.closest?.('[data-access-allow],[data-access-deny],[data-access-home],[data-access-setting],[data-access-remove],[data-access-place]');if(!t||t.disabled)return;
    e.preventDefault();
    if(t.dataset.accessAllow)answer(t.dataset.accessAllow,'allow');
    else if(t.dataset.accessDeny)answer(t.dataset.accessDeny,'deny');
    else if(t.dataset.accessHome)answer(t.dataset.accessHome,'home');
    else if(t.dataset.accessSetting)change(t,()=>bridge()({action:t.dataset.accessSetting}));
    else if(t.dataset.accessPlace)change(t,()=>bridge()({action:'allow',path:t.dataset.accessPlace}));
    else if(t.dataset.accessRemove)change(t,async()=>{const id=t.dataset.accessRemove;await window.BuddyDesktop.disconnectProjectFolder(id);if(state.activeFolderId===id){delete state.activeFolderId;save();}return null;});
  });
  window.addEventListener('buddy-conversation',e=>{const type=e.detail?.type;if(type==='folder-access'||type==='project-files-changed')refresh(true);else if(type==='run'&&['completed','failed','stopped'].includes(e.detail?.status))refresh(true);});
  window.addEventListener('buddy-worker-snapshot',()=>refresh());
  refresh(true);
})(typeof globalThis!=='undefined'?globalThis:this);

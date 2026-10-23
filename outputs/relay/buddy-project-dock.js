(function(root){
  'use strict';
  // The conversation's plan and files as views of the chat, not a panel beside it: Chat · Plan · Files in the chat's header, and the view chosen
  // takes the whole conversation column under it. The chat keeps its own width at every window size, and the plan and the files get the room of
  // a page. A view is offered when there is something to show: the chat's plan, or its connected folder. The choice is per chat, for this
  // session; opening a chat shows its messages.
  // A folder the person connected is their project, even while empty. Buddy's own folder becomes one once something is saved in it.
  const isProject=f=>!!f&&typeof f==='object'&&typeof f.folderId==='string'&&!!f.folderId&&Array.isArray(f.files)&&(f.managed!==true||f.files.length>0||Array.isArray(f.directories)&&f.directories.length>0);
  // The views a chat offers, in order, and the one shown: the choice while it is still offered, else the chat. With nothing beside the chat
  // there is no choice to show.
  function views({plan=false,files=false,chosen='chat'}={}){
    const list=['chat',...(plan?['plan']:[]),...(files?['files']:[])];
    return {list:list.length>1?list:[],shown:list.includes(chosen)?chosen:'chat'};
  }
  const api={isProject,views,docked:()=>false,reveal(){},lost(){},show(){}};root.BuddyProjectDock=api;if(typeof module!=='undefined')module.exports=api;
  if(typeof document==='undefined')return;

  let folder=null,folderKey='',target=null,loads=0,loading='',loadedAt=0,detailsOpen=false;
  const chosen=new Map(),scrolls={plan:0,files:0};
  // The plain browser page has no folders: it can only offer the plan.
  const native=()=>!!window.BuddyDesktop?.projectFiles&&!!root.BuddyFiles?.native?.();
  const key=()=>`${state.conversationWorkspace||''}|${state.activeFolderId||''}`;
  const conversation=()=>document.querySelector('.content-layout > .conversation');
  const chatView=()=>typeof ui!=='undefined'&&ui.view?.kind==='chat'&&!!conversation();
  const plan=()=>chatView()&&root.BuddyPlan?.active?root.BuddyPlan.active():null;
  const hasFiles=()=>native()&&folderKey===key()&&isProject(folder);
  const layout=()=>views({plan:!!plan(),files:hasFiles(),chosen:chosen.get(ui.view?.target)||'chat'});
  const LABEL={chat:'Chat',plan:'Plan',files:'Files'};

  function switcherHTML(list,shown){
    const tone=root.BuddyPlan?.tone?.(plan())||'idle';
    return `<div class="chat-views" role="tablist" aria-label="Views of this chat" data-chat-views>${list.map(v=>`<button type="button" role="tab" class="chat-view-tab${v==='plan'?` tone-${tone}`:''}" id="chat-view-tab-${v}" data-chat-view="${v}" aria-selected="${v===shown}" tabindex="${v===shown?0:-1}" aria-controls="${v==='chat'?'chat-body':'chat-pane'}">${v==='plan'?'<span class="plan-dot" aria-hidden="true"></span>':''}${LABEL[v]}</button>`).join('')}</div>`;
  }
  // The plan view holds the plan strip, open (BuddyPlan puts it in its slot); the files view holds the folder, as the Files drawer shows it.
  function paneHTML(view){
    const head=view==='files'?`<h2 class="chat-pane-title">${esc(folder?.name||'Files')}</h2>`:'';
    return `<section class="chat-pane" id="chat-pane" data-chat-pane="${view}" role="tabpanel" aria-labelledby="chat-view-tab-${view}" tabindex="-1"${view==='files'?' data-project-dock':''}><div class="chat-pane-inner">${head}${view==='plan'?'<div class="project-dock-plan" data-project-plan-slot></div>':'<div class="project-dock-body" data-project-dock-body></div>'}</div></section>`;
  }
  function restore(pane){
    const details=pane.querySelector('[data-project-dock-body] .project-folder-details');
    if(details&&detailsOpen)details.open=true;
  }
  function paint(){
    const convo=conversation();if(!chatView()||!convo){root.BuddyPlan?.mount?.();return;}
    const {list,shown}=layout(),island=convo.querySelector(':scope > .conversation-header .island');
    let nav=island?.querySelector('[data-chat-views]');
    if(!list.length)nav?.remove();
    else{
      const html=switcherHTML(list,shown);
      if(!nav||nav._html!==html){
        const holder=document.createElement('div');holder.innerHTML=html;const next=holder.firstElementChild;next._html=html;
        const focused=nav?.contains(document.activeElement)?document.activeElement.dataset.chatView:'';
        if(nav)nav.replaceWith(next);else island?.querySelector('.conversation-title')?.insertAdjacentElement('afterend',next);
        nav=next;if(focused)nav.querySelector(`[data-chat-view="${focused}"]`)?.focus({preventScroll:true});
      }
    }
    // The chat's own messages and composer stay in the page while another view is shown, so nothing typed or streaming is lost.
    if(convo.dataset.viewShown!==shown)convo.dataset.viewShown=shown;
    let pane=convo.querySelector(':scope > [data-chat-pane]');
    if(shown==='chat')pane?.remove();
    else{
      if(!pane||pane.dataset.chatPane!==shown){pane?.remove();convo.querySelector(':scope > .chat-body')?.insertAdjacentHTML('afterend',paneHTML(shown));pane=convo.querySelector(':scope > [data-chat-pane]');}
      if(shown==='files'&&pane){
        const title=pane.querySelector('.chat-pane-title');if(title&&title.textContent!==(folder?.name||'Files'))title.textContent=folder?.name||'Files';
        const body=pane.querySelector('[data-project-dock-body]'),inner=BuddyFiles.body(folder);
        if(body&&body._html!==inner){body.innerHTML=inner;body._html=inner;restore(pane);}
      }
    }
    // The plan strip goes where the view needs it: whole in the plan view, one line above the composer in the chat.
    root.BuddyPlan?.mount?.();
    if(pane&&pane.scrollTop!==scrolls[shown])pane.scrollTop=scrolls[shown];
  }
  function select(view,{focus=false}={}){
    if(!chatView()||!layout().list.includes(view))return;
    chosen.set(ui.view.target,view);paint();
    if(focus)(view==='chat'?document.getElementById('message-input'):conversation()?.querySelector('[data-chat-pane]'))?.focus({preventScroll:true});
    // The folder may have changed since it was last read.
    if(view==='files'&&native()&&Date.now()-loadedAt>2000)load();
  }
  // The folder is read without saving the workspace (a save already on its way is waited for). The answer is announced by BuddyFiles, which
  // is also how the drawer's loads reach the files view.
  async function load(){
    if(!native())return;
    const k=key();if(loading===k)return;
    const token=++loads;loading=k;
    try{await BuddyFiles.load({persist:false});}
    catch(error){if(token===loads&&k===key()){folder=null;folderKey=k;}}
    finally{if(token===loads){loading='';loadedAt=Date.now();}paint();}
  }
  function update(){
    if(!native()){paint();return;}
    const chat=typeof ui!=='undefined'&&ui.view?.kind==='chat'?ui.view.target:null;
    const stale=folderKey!==key()||!!chat&&chat!==target;if(chat)target=chat;
    paint();
    // On load and on every change of chat, the conversation's folder is read again.
    if(stale&&chatView())load();
  }

  window.addEventListener('buddy-project-folder',event=>{folder=event.detail||null;folderKey=key();loadedAt=Date.now();paint();});
  window.addEventListener('buddy-view-updated',update);
  // A plan can appear, finish or go away with any status reply, and the Plan tab's dot follows it.
  window.addEventListener('buddy-worker-snapshot',paint);
  document.addEventListener('scroll',event=>{const p=event.target?.closest?.('[data-chat-pane]');if(p&&event.target===p)scrolls[p.dataset.chatPane]=p.scrollTop;},true);
  document.addEventListener('toggle',event=>{if(event.target?.matches?.('[data-chat-pane] .project-folder-details'))detailsOpen=event.target.open;},true);
  // A tab, or the plan's line above the composer (it opens the plan view).
  document.addEventListener('click',event=>{
    const el=event.target.closest?.('[data-chat-view]');if(!el)return;
    select(el.dataset.chatView,{focus:!el.closest('[data-chat-views]')});
  });
  // The tabs move with the arrow keys, as tabs do; Escape in another view goes back to the chat.
  document.addEventListener('keydown',event=>{
    const pane=conversation()?.querySelector('[data-chat-pane]');
    if(event.key==='Escape'&&pane&&(pane.contains(event.target)||event.target===document.body)&&!document.querySelector('.modal-overlay')){select('chat',{focus:true});return;}
    const tab=event.target.closest?.('[data-chat-views] [data-chat-view]');if(!tab||!['ArrowLeft','ArrowRight','Home','End'].includes(event.key))return;
    const tabs=[...tab.parentElement.querySelectorAll('[data-chat-view]')],i=tabs.indexOf(tab);
    const next=event.key==='Home'?tabs[0]:event.key==='End'?tabs.at(-1):tabs[(i+(event.key==='ArrowRight'?1:-1)+tabs.length)%tabs.length];
    event.preventDefault();select(next.dataset.chatView);conversation()?.querySelector(`[data-chat-views] [data-chat-view="${next.dataset.chatView}"]`)?.focus();
  });

  // The files are a view of this chat when its folder is known: asking for them (the folder button, a viewer's Files) shows that view instead
  // of a drawer.
  api.docked=()=>chatView()&&hasFiles();
  api.reveal=()=>{if(api.docked())select('files',{focus:true});};
  // The folder could not be read any more (disconnected, moved): no files view, and the drawer says why.
  api.lost=()=>{folder=null;folderKey=key();paint();};
  api.show=(view,options)=>select(view,options);
  update();
})(typeof globalThis!=='undefined'?globalThis:this);

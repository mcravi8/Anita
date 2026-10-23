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
  // Arriving at a chat shows its latest messages: opened from anywhere else it shows its messages (not the view it showed last), and back from
  // its Plan or Files view the list is at the bottom, already there as it slides in (the person asked to land at the latest messages from
  // anywhere). Opening and redraws are buddy-chat-open.js's. `landed` is the chat and view last shown, null on another page.
  let landed=null;
  // The plain browser page has no folders: it can only offer the plan.
  const native=()=>!!window.BuddyDesktop?.projectFiles&&!!root.BuddyFiles?.native?.();
  const key=()=>`${state.conversationWorkspace||''}|${state.activeFolderId||''}`;
  const conversation=()=>document.querySelector('.content-layout > .conversation');
  const chatView=()=>typeof ui!=='undefined'&&ui.view?.kind==='chat'&&!!conversation();
  const plan=()=>chatView()&&root.BuddyPlan?.active?root.BuddyPlan.active():null;
  const hasFiles=()=>native()&&folderKey===key()&&isProject(folder);
  const layout=()=>views({plan:!!plan(),files:hasFiles(),chosen:chosen.get(ui.view?.target)||'chat'});
  const LABEL={chat:'Chat',plan:'Plan',files:'Files'};

  // The tabs, with the selector that sits under the chosen one and glides to the next (buddy-project-dock.css). The same tabs stay on the
  // page while the chat does; only what is chosen changes.
  function switcherHTML(list,tone){
    return `<div class="chat-views" role="tablist" aria-label="Views of this chat" data-chat-views><span class="chat-views-thumb" aria-hidden="true"></span>${list.map(v=>`<button type="button" role="tab" class="chat-view-tab${v==='plan'?` tone-${tone}`:''}" id="chat-view-tab-${v}" data-chat-view="${v}" aria-selected="false" tabindex="-1" aria-controls="${v==='chat'?'chat-body':`chat-pane-${v}`}">${v==='plan'?'<span class="plan-dot" aria-hidden="true"></span>':''}${LABEL[v]}</button>`).join('')}</div>`;
  }
  function placeThumb(nav,shown,instant){
    const thumb=nav.querySelector('.chat-views-thumb'),tab=nav.querySelector(`[data-chat-view="${shown}"]`);if(!thumb||!tab)return;
    if(instant)thumb.style.transition='none';
    thumb.style.width=tab.offsetWidth+'px';thumb.style.transform=`translateX(${tab.offsetLeft}px)`;
    if(instant){void thumb.offsetWidth;thumb.style.transition='';}
  }
  // The plan view holds the plan strip, open (BuddyPlan puts it in its slot); the files view holds the folder, as the Files drawer shows it.
  // Both stay on the page while the chat does, hidden when not shown, so moving between the views never draws them again.
  function paneHTML(view){
    const head=view==='files'?`<h2 class="chat-pane-title">${esc(folder?.name||'Files')}</h2>`:'';
    return `<section class="chat-pane" id="chat-pane-${view}" data-chat-pane="${view}" role="tabpanel" aria-labelledby="chat-view-tab-${view}" tabindex="-1" hidden${view==='files'?' data-project-dock':''}><div class="chat-pane-inner">${head}${view==='plan'?'<div class="project-dock-plan" data-project-plan-slot></div>':'<div class="project-dock-body" data-project-dock-body></div>'}</div></section>`;
  }
  function restore(pane){
    const details=pane.querySelector('[data-project-dock-body] .project-folder-details');
    if(details&&detailsOpen)details.open=true;
  }
  // Moving between views slides them in the tabs' order, Chat · Plan · Files: to the right of where you are, the view you leave goes out to
  // the left and the new one comes in from the right; to the left, the other way. Only the two views involved move, side by side.
  const ORDER=['chat','plan','files'],DURATION=420,EASE='cubic-bezier(.32,.72,0,1)';
  const calm=()=>typeof matchMedia==='function'&&matchMedia('(prefers-reduced-motion: reduce)').matches;
  let sliding=null;
  const partsOf=(convo,view)=>view==='chat'?[...convo.querySelectorAll(':scope > .chat-body, :scope > .composer-wrap')]:[convo.querySelector(`:scope > [data-chat-pane="${view}"]`)].filter(Boolean);
  function settle(convo,shown){
    if(convo.dataset.viewShown!==shown)convo.dataset.viewShown=shown;
    delete convo.dataset.viewSliding;
    for(const pane of convo.querySelectorAll(':scope > [data-chat-pane]'))pane.hidden=pane.dataset.chatPane!==shown;
  }
  function finishSlide(){if(!sliding)return;const s=sliding;sliding=null;for(const a of s.moves)a.cancel();if(s.convo.isConnected)settle(s.convo,s.to);}
  function slide(convo,from,to){
    finishSlide();
    const way=ORDER.indexOf(to)>ORDER.indexOf(from)?1:-1,width=convo.clientWidth||1;
    // While they move, both views are on the page (the chat's messages and composer, and the pane).
    convo.dataset.viewSliding='';
    for(const pane of convo.querySelectorAll(':scope > [data-chat-pane]'))pane.hidden=![from,to].includes(pane.dataset.chatPane);
    const timing={duration:DURATION,easing:EASE};
    const moves=[...partsOf(convo,from).map(el=>el.animate([{transform:'translateX(0)'},{transform:`translateX(${-way*width}px)`}],timing)),
      ...partsOf(convo,to).map(el=>el.animate([{transform:`translateX(${way*width}px)`},{transform:'translateX(0)'}],timing))];
    const run={moves,convo,to};sliding=run;
    Promise.all(moves.map(a=>a.finished)).then(()=>{if(sliding===run){sliding=null;settle(convo,to);}},()=>{});
  }
  // `from` is the view being left when the person moves to another one; any other paint draws what is chosen as it is.
  function paint(from=null){
    const convo=conversation();if(!chatView()||!convo){landed=null;root.BuddyPlan?.mount?.();return;}
    // Opening a chat from elsewhere shows its messages, whichever view it showed last.
    if(!landed||landed.target!==ui.view.target)chosen.delete(ui.view.target);
    const {list,shown}=layout(),island=convo.querySelector(':scope > .conversation-header .island');
    let nav=island?.querySelector('[data-chat-views]'),fresh=false;
    if(!list.length)nav?.remove();
    else{
      const tone=root.BuddyPlan?.tone?.(plan())||'idle',key=list.join(',')+'|'+tone;
      if(!nav||nav._key!==key){
        const holder=document.createElement('div');holder.innerHTML=switcherHTML(list,tone);const next=holder.firstElementChild;next._key=key;
        const focused=nav?.contains(document.activeElement)?document.activeElement.dataset.chatView:'';
        if(nav)nav.replaceWith(next);else island?.querySelector('.conversation-title')?.insertAdjacentElement('afterend',next);
        nav=next;fresh=true;if(focused)nav.querySelector(`[data-chat-view="${focused}"]`)?.focus({preventScroll:true});
      }
      for(const tab of nav.querySelectorAll('[data-chat-view]')){const on=tab.dataset.chatView===shown;tab.setAttribute('aria-selected',String(on));tab.tabIndex=on?0:-1;}
      placeThumb(nav,shown,fresh||calm());
    }
    for(const view of ['plan','files']){
      let pane=convo.querySelector(`:scope > [data-chat-pane="${view}"]`);
      if(!list.includes(view)){pane?.remove();continue;}
      if(!pane){convo.querySelector(':scope > .composer-wrap')?.insertAdjacentHTML('afterend',paneHTML(view));pane=convo.querySelector(`:scope > [data-chat-pane="${view}"]`);pane&&(pane.scrollTop=scrolls[view]);}
      if(view==='files'&&pane){
        const title=pane.querySelector('.chat-pane-title');if(title&&title.textContent!==(folder?.name||'Files'))title.textContent=folder?.name||'Files';
        const body=pane.querySelector('[data-project-dock-body]'),inner=BuddyFiles.body(folder);
        if(body&&body._html!==inner){body.innerHTML=inner;body._html=inner;restore(pane);}
      }
    }
    // The chat's own messages and composer stay in the page while another view is shown, so nothing typed or streaming is lost.
    if(from&&from!==shown&&list.includes(from)&&!calm())slide(convo,from,shown);
    else{if(sliding&&(sliding.convo!==convo||sliding.to!==shown))finishSlide();if(!sliding)settle(convo,shown);}
    // The plan strip goes where each view needs it: whole in the plan view, one line above the composer in the chat.
    root.BuddyPlan?.mount?.();
    land(convo,shown);
  }
  function land(convo,shown){
    const target=ui.view.target,body=convo.querySelector(':scope > .chat-body');
    if(shown==='chat'&&body&&landed?.target===target&&landed.shown!=='chat'){
      // Late layout (rendered text, the plan line) can make the list taller a moment later, so look again.
      const end=()=>{body.scrollTop=body.scrollHeight;};end();requestAnimationFrame(end);setTimeout(end,150);
    }
    landed={target,shown};
  }
  function select(view,{focus=false}={}){
    if(!chatView()||!layout().list.includes(view))return;
    const from=layout().shown;chosen.set(ui.view.target,view);paint(from);
    if(focus)(view==='chat'?document.getElementById('message-input'):conversation()?.querySelector(`[data-chat-pane="${view}"]`))?.focus({preventScroll:true});
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
  window.addEventListener('buddy-worker-snapshot',()=>paint());
  // The window or the sidebar changing width, or the font arriving, moves the tabs: the selector follows at once.
  const realign=()=>{const nav=conversation()?.querySelector('[data-chat-views]');if(nav&&chatView())placeThumb(nav,layout().shown,true);};
  window.addEventListener('resize',realign);document.fonts?.ready?.then(realign);
  document.addEventListener('scroll',event=>{const p=event.target?.closest?.('[data-chat-pane]');if(p&&event.target===p)scrolls[p.dataset.chatPane]=p.scrollTop;},true);
  document.addEventListener('toggle',event=>{if(event.target?.matches?.('[data-chat-pane] .project-folder-details'))detailsOpen=event.target.open;},true);
  // A tab, or the plan's line above the composer (it opens the plan view).
  document.addEventListener('click',event=>{
    const el=event.target.closest?.('[data-chat-view]');if(!el)return;
    select(el.dataset.chatView,{focus:!el.closest('[data-chat-views]')});
  });
  // The tabs move with the arrow keys, as tabs do; Escape in another view goes back to the chat.
  document.addEventListener('keydown',event=>{
    const pane=conversation()?.querySelector('[data-chat-pane]:not([hidden])');
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

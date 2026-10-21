(function(root){
  'use strict';
  // The conversation's project, docked to the right of the chat whenever there is room: its plan (objective, stages and their tasks, the same
  // strip and buttons as the card above the composer) and its connected folder's files (the same panel the Files drawer shows). No overlay: the
  // chat column gives up the space, so nothing covers the messages or the composer.
  // Room means: the 340-pixel panel (the drawer is 370) beside a chat column of at least 680, which keeps message lines near 80 characters and
  // the composer at a comfortable width. The main area must therefore be 1020 wide: a 1310-wide window with the sidebar open, 1098 with the
  // sidebar as a rail. It is measured, not assumed, so it is decided again whenever the main area changes size (the window, or the sidebar).
  const DOCK=340,CHAT=680;
  const fits=width=>typeof width==='number'&&Number.isFinite(width)&&width>=DOCK+CHAT;
  // A folder the person connected is their project, even while empty. Buddy's own folder becomes one once something is saved in it.
  const isProject=f=>!!f&&typeof f==='object'&&typeof f.folderId==='string'&&!!f.folderId&&Array.isArray(f.files)&&(f.managed!==true||f.files.length>0||Array.isArray(f.directories)&&f.directories.length>0);
  // The plan and the files are both long lists with their own scrolling. At 340 pixels, stacked, each would get half the height and a scroll
  // inside a scroll, so they take turns as two tabs (the plan first); the Plan tab keeps the plan's live dot, so its progress shows from Files too.
  function sections({plan=false,files=false,tab=''}={}){const list=[...(plan?['plan']:[]),...(files?['files']:[])];return {list,shown:list.includes(tab)?tab:list[0]||''};}
  // The person's choice: open or closed, and the tab last chosen. Kept in the saved workspace, so it holds in every chat and after a relaunch.
  function preference(value){const v=value&&typeof value==='object'&&!Array.isArray(value)?value:{};return {closed:v.closed===true,tab:['plan','files'].includes(v.tab)?v.tab:''};}
  const api={DOCK,CHAT,fits,isProject,sections,preference,docked:()=>false,reveal(){},lost(){},open(){},close(){}};root.BuddyProjectDock=api;if(typeof module!=='undefined')module.exports=api;
  if(typeof document==='undefined')return;

  let folder=null,folderKey='',target=null,loads=0,loading='',loadedAt=0,shown=false,detailsOpen=false,observer=null,observed=null,frame=0,leaving=null;
  const scrolls={plan:0,files:0};
  const calm=()=>typeof matchMedia==='function'&&matchMedia('(prefers-reduced-motion: reduce)').matches;
  // The plain browser page has no folders: its panel can only hold a plan.
  const native=()=>!!window.BuddyDesktop?.projectFiles&&!!root.BuddyFiles?.native?.();
  const key=()=>`${state.conversationWorkspace||''}|${state.activeFolderId||''}`;
  const element=()=>document.querySelector('[data-project-dock]');
  const room=()=>document.querySelector('.main-shell')?.getBoundingClientRect().width;
  const chatView=()=>typeof ui!=='undefined'&&ui.view?.kind==='chat'&&!!document.querySelector('.content-layout > .conversation');
  const pref=()=>preference(state.projectSidebar);
  const plan=()=>chatView()&&root.BuddyPlan?.active?root.BuddyPlan.active():null;
  const hasFiles=()=>native()&&folderKey===key()&&isProject(folder);
  const layout=()=>sections({plan:!!plan(),files:hasFiles(),tab:pref().tab});
  // There is something to show and room to show it; the person decides whether it is open.
  const available=()=>chatView()&&fits(room())&&layout().list.length>0;
  const wanted=()=>available()&&!pref().closed;
  const remember=change=>{state.projectSidebar={...pref(),...change};save();};

  const tabLabel={plan:'Plan',files:'Files'};
  function panelHTML(list){
    const tabs=list.length>1;
    const head=tabs?`<div class="project-dock-tabs" role="tablist" aria-label="Project">${list.map(s=>`<button type="button" class="project-dock-tab" role="tab" id="project-dock-tab-${s}" aria-controls="project-dock-${s}" data-project-dock-tab="${s}">${s==='plan'?'<span class="plan-dot" aria-hidden="true"></span>':''}${tabLabel[s]}</button>`).join('')}</div>`:`<h2>${tabLabel[list[0]]}</h2>`;
    const close=`<button type="button" class="icon-button project-dock-close" data-project-dock-close aria-label="Close project panel" title="Close project panel">${icon('close')}</button>`;
    const section=s=>`<div class="project-dock-section${s==='files'?' project-dock-body':''}" id="project-dock-${s}" data-project-dock-section="${s}"${tabs?` role="tabpanel" aria-labelledby="project-dock-tab-${s}"`:''}${s==='files'?' data-project-dock-body':''}>${s==='plan'?'<div class="project-dock-plan" data-project-plan-slot></div>':''}</div>`;
    return `<header class="project-dock-header">${head}${close}</header>${list.map(section).join('')}`;
  }
  function restore(el){
    const body=el.querySelector('[data-project-dock-body]'),details=body?.querySelector('.project-folder-details');
    if(details&&detailsOpen)details.open=true;
  }
  function paint(){
    // A panel sliding out is left to finish; what replaces it is drawn when it has gone.
    if(leaving){if(!leaving.isConnected)leaving=null;else{openButton();return;}}
    const el=element();
    if(!wanted()){if(el)el.remove();shown=false;openButton();root.BuddyPlan?.mount?.();return;}
    const {list,shown:tab}=layout();
    let aside=el;
    if(!aside){
      // A page redraw rebuilds the chat, and the panel with it. Only a panel that was not showing slides in; a redraw puts it straight back.
      const enter=!shown&&!calm();
      document.querySelector('.content-layout').insertAdjacentHTML('beforeend',`<aside class="project-dock${enter?' dock-enter':''}" data-project-dock tabindex="-1"><div class="project-dock-panel"></div></aside>`);
      aside=element();shown=true;
    }
    const panel=aside.querySelector('.project-dock-panel'),signature=list.join(',');
    if(panel.dataset.sections!==signature){panel.innerHTML=panelHTML(list);panel.dataset.sections=signature;}
    aside.setAttribute('aria-label',list.includes('files')&&folder?.name?`Project: ${folder.name}`:'Project');
    for(const b of panel.querySelectorAll('[data-project-dock-tab]')){
      const on=b.dataset.projectDockTab===tab;b.setAttribute('aria-selected',String(on));b.tabIndex=on?0:-1;
      if(b.dataset.projectDockTab==='plan')b.className=`project-dock-tab tone-${root.BuddyPlan?.tone?.(plan())||'idle'}`;
    }
    for(const s of panel.querySelectorAll('[data-project-dock-section]'))s.hidden=s.dataset.projectDockSection!==tab;
    // The folder changed while docked: the list is redrawn where it is, keeping its scroll and what was open.
    const body=panel.querySelector('[data-project-dock-body]');
    if(body){const inner=BuddyFiles.body(folder);if(body._html!==inner){body.innerHTML=inner;body._html=inner;restore(aside);}}
    openButton();
    // The plan strip moves into its place here (or back above the composer when there is none); then each section is where it was scrolled to.
    root.BuddyPlan?.mount?.();
    for(const s of panel.querySelectorAll('[data-project-dock-section]'))if(!s.hidden&&s.scrollTop!==scrolls[s.dataset.projectDockSection])s.scrollTop=scrolls[s.dataset.projectDockSection];
  }
  // Closed, the panel leaves a button in the chat's header (where the island's own buttons are) to open it again. It is offered only when the
  // panel would fit; otherwise the plan is above the composer and the files are behind the folder button, as before.
  function openButton(){
    const header=document.querySelector('.content-layout > .conversation > .conversation-header'),button=header?.querySelector('[data-project-dock-open]');
    if(!header||!pref().closed||!available()){button?.remove();return;}
    if(!button)header.insertAdjacentHTML('beforeend',`<button type="button" class="icon-button project-dock-open" data-project-dock-open aria-label="Open project panel" title="Open project panel">${icon('panel')}</button>`);
  }
  function close(){
    const el=element();remember({closed:true});
    if(!el||calm()){if(el)el.remove();shown=false;paint();document.querySelector('[data-project-dock-open]')?.focus({preventScroll:true});return;}
    // It slides out with the side panels' closing motion. The open button is there at once, and focus goes to it.
    leaving=el;el.removeAttribute('data-project-dock');el.classList.remove('dock-enter');el.classList.add('dock-leave');el.setAttribute('inert','');el.setAttribute('aria-hidden','true');
    openButton();document.querySelector('[data-project-dock-open]')?.focus({preventScroll:true});
    let done=false;
    const finish=()=>{if(done)return;done=true;if(leaving===el)leaving=null;el.remove();shown=false;paint();};
    el.addEventListener('animationend',e=>{if(e.target===el)finish();});setTimeout(finish,600);
  }
  function open(){
    if(leaving){leaving.remove();leaving=null;}
    remember({closed:false});shown=false;paint();
    element()?.focus({preventScroll:true});
    // The files may have changed while it was closed.
    if(native()&&Date.now()-loadedAt>2000)load();
  }
  function select(tab){
    if(!layout().list.includes(tab))return;
    remember({tab});paint();
  }
  // The folder is read without saving the workspace (a save already on its way is waited for). The answer is announced by BuddyFiles, which
  // is also how the drawer's loads reach the panel.
  async function load(){
    if(!native())return;
    const k=key();if(loading===k)return;
    const token=++loads;loading=k;
    try{await BuddyFiles.load({persist:false});}
    catch(error){if(token===loads&&k===key()){folder=null;folderKey=k;}}
    finally{if(token===loads){loading='';loadedAt=Date.now();}paint();}
  }
  function watch(){
    const shell=document.querySelector('.main-shell');if(!shell||shell===observed)return;
    observed=shell;if(typeof ResizeObserver!=='function')return;
    observer||=new ResizeObserver(schedule);observer.disconnect();observer.observe(shell);
  }
  // A panel that comes back after the window was too narrow first shows what it had, then reads the folder again, since changes were not
  // followed while it was away.
  function schedule(){
    cancelAnimationFrame(frame);
    frame=requestAnimationFrame(()=>{const was=shown;paint();if(!was&&shown&&native()&&Date.now()-loadedAt>2000)load();});
  }
  function update(){
    watch();
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
  window.addEventListener('resize',schedule);
  document.addEventListener('scroll',event=>{const s=event.target?.closest?.('[data-project-dock] [data-project-dock-section]');if(s&&event.target===s)scrolls[s.dataset.projectDockSection]=s.scrollTop;},true);
  document.addEventListener('toggle',event=>{if(event.target?.matches?.('[data-project-dock] .project-folder-details'))detailsOpen=event.target.open;},true);
  document.addEventListener('click',event=>{
    const el=event.target.closest?.('[data-project-dock-close],[data-project-dock-open],[data-project-dock-tab]');if(!el)return;
    if(el.hasAttribute('data-project-dock-close'))close();
    else if(el.hasAttribute('data-project-dock-open'))open();
    else{select(el.dataset.projectDockTab);element()?.querySelector(`[data-project-dock-tab="${el.dataset.projectDockTab}"]`)?.focus({preventScroll:true});}
  });
  // The tabs move with the arrow keys, as tabs do.
  document.addEventListener('keydown',event=>{
    const tab=event.target.closest?.('[data-project-dock] [data-project-dock-tab]');if(!tab||!['ArrowLeft','ArrowRight','Home','End'].includes(event.key))return;
    const tabs=[...tab.parentElement.querySelectorAll('[data-project-dock-tab]')],i=tabs.indexOf(tab);
    const next=event.key==='Home'?tabs[0]:event.key==='End'?tabs.at(-1):tabs[(i+(event.key==='ArrowRight'?1:-1)+tabs.length)%tabs.length];
    event.preventDefault();select(next.dataset.projectDockTab);element()?.querySelector(`[data-project-dock-tab="${next.dataset.projectDockTab}"]`)?.focus();
  });

  // The files are docked when the panel shows a Files section (the folder button then shows them here instead of opening a drawer).
  api.docked=()=>!!element()?.querySelector('[data-project-dock-body]');
  // Asked for the files while docked (the folder button): the Files tab comes forward, the panel takes focus, and its heading lights up briefly.
  api.reveal=()=>{
    if(!api.docked())return;
    if(pref().tab!=='files'&&layout().list.includes('plan'))select('files');
    const el=element();if(!el)return;el.focus({preventScroll:true});
    const heading=el.querySelector('.project-dock-header');if(!heading||calm())return;
    heading.classList.remove('dock-attention');void heading.offsetWidth;heading.classList.add('dock-attention');
  };
  // The folder could not be read any more (disconnected, moved): no files are docked, and the drawer says why.
  api.lost=()=>{folder=null;folderKey=key();paint();};
  api.open=open;api.close=close;
  update();
})(typeof globalThis!=='undefined'?globalThis:this);

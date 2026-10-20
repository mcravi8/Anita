(function(root){
  'use strict';
  // The conversation's project folder, docked to the right of the chat whenever there is room: the same panel the Files drawer shows, always open,
  // no overlay, and the chat column gives up the space (nothing covers the messages or the composer).
  // Room means: the 340-pixel panel (the drawer is 370) beside a chat column of at least 680, which keeps message lines near 80 characters and
  // the composer at a comfortable width. The main area must therefore be 1020 wide: a 1310-wide window with the sidebar open, 1098 with the
  // sidebar as a rail. It is measured, not assumed, so it is decided again whenever the main area changes size (the window, or the sidebar).
  const DOCK=340,CHAT=680;
  const fits=width=>typeof width==='number'&&Number.isFinite(width)&&width>=DOCK+CHAT;
  // A folder the person connected is their project, even while empty. Buddy's own folder becomes one once something is saved in it.
  const isProject=f=>!!f&&typeof f==='object'&&typeof f.folderId==='string'&&!!f.folderId&&Array.isArray(f.files)&&(f.managed!==true||f.files.length>0||Array.isArray(f.directories)&&f.directories.length>0);
  const api={DOCK,CHAT,fits,isProject,docked:()=>false,reveal(){},lost(){}};root.BuddyProjectDock=api;if(typeof module!=='undefined')module.exports=api;
  if(typeof document==='undefined')return;

  let folder=null,folderKey='',target=null,loads=0,loading='',loadedAt=0,shown=false,scroll=0,detailsOpen=false,observer=null,observed=null,frame=0;
  const calm=()=>typeof matchMedia==='function'&&matchMedia('(prefers-reduced-motion: reduce)').matches;
  // The plain browser page has no folders: nothing is docked there.
  const native=()=>!!window.BuddyDesktop?.projectFiles&&!!root.BuddyFiles?.native?.();
  const key=()=>`${state.conversationWorkspace||''}|${state.activeFolderId||''}`;
  const element=()=>document.querySelector('[data-project-dock]');
  const room=()=>document.querySelector('.main-shell')?.getBoundingClientRect().width;
  const chatView=()=>typeof ui!=='undefined'&&ui.view?.kind==='chat'&&!!document.querySelector('.content-layout > .conversation');
  const wanted=()=>native()&&chatView()&&folderKey===key()&&isProject(folder)&&fits(room());

  function restore(el){
    const body=el.querySelector('[data-project-dock-body]'),details=body.querySelector('.project-folder-details');
    if(details&&detailsOpen)details.open=true;body.scrollTop=scroll;
  }
  function paint(){
    const el=element();
    if(!wanted()){if(el)el.remove();shown=false;return;}
    const inner=BuddyFiles.body(folder);
    if(el){
      // The folder changed while docked: the list is redrawn where it is, keeping its scroll and what was open.
      const body=el.querySelector('[data-project-dock-body]');if(body._html===inner)return;
      body.innerHTML=inner;body._html=inner;restore(el);return;
    }
    // A page redraw rebuilds the chat, and the dock with it. Only a dock that was not showing slides in; a redraw puts it straight back.
    const enter=!shown&&!calm();
    document.querySelector('.content-layout').insertAdjacentHTML('beforeend',`<aside class="project-dock${enter?' dock-enter':''}" data-project-dock tabindex="-1" aria-label="Project files: ${esc(folder.name||'Files')}"><div class="project-dock-panel"><header class="project-dock-header"><h2>Files</h2></header><div class="project-dock-body" data-project-dock-body>${inner}</div></div></aside>`);
    const fresh=element();fresh.querySelector('[data-project-dock-body]')._html=inner;restore(fresh);shown=true;
  }
  // The folder is read without saving the workspace (a save already on its way is waited for). The answer is announced by BuddyFiles, which
  // is also how the drawer's loads reach the dock.
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
  // A dock that comes back after the window was too narrow first shows what it had, then reads the folder again, since changes were not
  // followed while it was away.
  function schedule(){
    cancelAnimationFrame(frame);
    frame=requestAnimationFrame(()=>{const was=shown;paint();if(!was&&shown&&Date.now()-loadedAt>2000)load();});
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
  window.addEventListener('resize',schedule);
  document.addEventListener('scroll',event=>{if(event.target?.matches?.('[data-project-dock-body]'))scroll=event.target.scrollTop;},true);
  document.addEventListener('toggle',event=>{if(event.target?.matches?.('[data-project-dock] .project-folder-details'))detailsOpen=event.target.open;},true);

  api.docked=()=>!!element();
  // Asked for the files while docked (the folder button): the dock takes focus, and its heading lights up briefly to say where they are.
  api.reveal=()=>{
    const el=element();if(!el)return;el.focus({preventScroll:true});
    const heading=el.querySelector('.project-dock-header');if(!heading||calm())return;
    heading.classList.remove('dock-attention');void heading.offsetWidth;heading.classList.add('dock-attention');
  };
  // The folder could not be read any more (disconnected, moved): nothing is docked, and the drawer says why.
  api.lost=()=>{folder=null;folderKey=key();paint();};
  update();
})(typeof globalThis!=='undefined'?globalThis:this);

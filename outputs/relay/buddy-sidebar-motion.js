(function(root){
  'use strict';
  // Changing the sidebar's width must not rebuild the sidebar: a rebuilt element starts in its final state, so nothing would move. This changes
  // the layout class, then updates the one toggle button that depends on it, in place, and lets the stylesheet glide everything.
  if(typeof document==='undefined'||typeof window.setSidebarCompact!=='function')return;
  const original=window.setSidebarCompact;
  window.setSidebarCompact=function(value){
    const shell=document.querySelector('.shell'),side=document.querySelector('.sidebar'),toggle=side?.querySelector('[data-action="sidebar-layout"]');
    if(!shell||!side||!toggle||typeof state==='undefined'||typeof icon!=='function')return original.call(this,value);
    state.sidebarCompact=value===true;save();
    const compact=state.sidebarCompact===true,label=compact?'Expand sidebar':'Compact sidebar';
    shell.classList.toggle('sidebar-compact',compact);
    toggle.setAttribute('aria-label',label);toggle.setAttribute('title',label);toggle.setAttribute('aria-pressed',String(compact));
    toggle.innerHTML=icon(compact?'sidebar-expand':'sidebar-collapse');
    window.BuddyActivity?.paint?.();
    toggle.focus();
    setTimeout(report,900);
  };
  // In the rail the logo opens the sidebar again (a second way back that does not depend on finding the toggle).
  document.addEventListener('click',e=>{
    if(typeof state==='undefined'||state.sidebarCompact!==true)return;
    if(e.target.closest('.sidebar .buddy-brand'))window.setSidebarCompact(false);
  });
  // What the sidebar looks like to the page, kept in the saved state, so a missing button can be diagnosed from what was really on screen.
  function describe(el){
    if(!el)return null;
    const b=el.getBoundingClientRect(),c=getComputedStyle(el),hit=document.elementFromPoint(b.left+b.width/2,b.top+b.height/2);
    return {rect:[b.left,b.top,b.width,b.height].map(Math.round),display:c.display,visibility:c.visibility,opacity:c.opacity,position:c.position,color:c.color,hit:hit?(hit.tagName+'.'+String(hit.className).slice(0,60)):null,hitIsSelf:!!hit&&(hit===el||el.contains(hit))};
  }
  function report(){
    try{
      const side=document.querySelector('.sidebar');if(!side||typeof state==='undefined')return;
      state.sidebarDiagnostics={at:new Date().toISOString(),compact:state.sidebarCompact===true,viewport:[innerWidth,innerHeight,devicePixelRatio],sidebar:{w:Math.round(side.getBoundingClientRect().width),scrollLeft:side.scrollLeft,scrollTop:side.scrollTop},
        toggle:describe(side.querySelector('.sidebar-layout-toggle')),bell:describe(side.querySelector('.activity-nav')),plus:describe(side.querySelector('[data-action="new-chat"]')),search:describe(side.querySelector('.compact-chat-search')),
        header:(()=>{const h=side.querySelector('.sidebar-header');if(!h)return null;const c=getComputedStyle(h);return {overflow:c.overflow,position:c.position,h:Math.round(h.getBoundingClientRect().height)};})()};
      save();
    }catch(e){/* diagnostics must never get in the way */}
  }
  setTimeout(report,2500);
})(typeof globalThis!=='undefined'?globalThis:this);

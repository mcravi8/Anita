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
  };
})(typeof globalThis!=='undefined'?globalThis:this);

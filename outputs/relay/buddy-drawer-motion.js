(function(root){
  'use strict';
  // Side panels (chat details, shared files and tasks, background work) slide in from the right and slide back out. The dialog code puts a panel
  // in and takes it out in one step, so this wraps it: opening marks a fresh panel to slide in; closing lets a copy of the panel, which cannot be
  // clicked and is not a dialog any more, carry on sliding out while the page is already usable again.
  if(typeof document==='undefined'||typeof root.openDrawer!=='function'||typeof root.closeModal!=='function')return;
  const calm=()=>typeof matchMedia==='function'&&matchMedia('(prefers-reduced-motion: reduce)').matches;
  const originalOpen=root.openDrawer,originalClose=root.closeModal;
  const panelOverlay=()=>document.querySelector('#modal-root > .drawer-overlay');

  root.openDrawer=function(...args){
    // Replacing what is shown in a panel that is already open (another tab, another agent) must not slide again.
    const fresh=!panelOverlay()&&!calm();
    const result=originalOpen.apply(this,args);
    if(fresh)panelOverlay()?.classList.add('drawer-enter');
    return result;
  };

  function copyOf(overlay){
    const copy=overlay.cloneNode(true);
    // A copy keeps what is on screen: pictures drawn on canvases, typed values, scroll positions.
    const canvases=[...overlay.querySelectorAll('canvas')],copies=[...copy.querySelectorAll('canvas')];
    canvases.forEach((canvas,index)=>{const target=copies[index];if(!target)return;target.width=canvas.width;target.height=canvas.height;try{target.getContext('2d').drawImage(canvas,0,0);}catch(error){/* a blank picture for 300 ms is fine */}});
    const fields=[...overlay.querySelectorAll('input,textarea,select')],fieldCopies=[...copy.querySelectorAll('input,textarea,select')];
    fields.forEach((field,index)=>{const target=fieldCopies[index];if(!target)return;if(field.type==='checkbox'||field.type==='radio')target.checked=field.checked;else target.value=field.value;});
    const scrolls=[...overlay.querySelectorAll('*')].map(el=>el.scrollTop),scrollCopies=[...copy.querySelectorAll('*')];
    copy.removeAttribute('id');copy.querySelectorAll('[id]').forEach(el=>el.removeAttribute('id'));
    const panel=copy.querySelector('.modal');if(panel)['role','aria-modal','aria-labelledby'].forEach(name=>panel.removeAttribute(name));
    copy.setAttribute('inert','');copy.setAttribute('aria-hidden','true');copy.classList.remove('drawer-enter');copy.classList.add('drawer-leaving');
    return {copy,restoreScroll:()=>scrolls.forEach((top,index)=>{if(top&&scrollCopies[index])scrollCopies[index].scrollTop=top;})};
  }

  root.closeModal=function(...args){
    const overlay=panelOverlay();
    const held=!!document.querySelector('#proposal-form[aria-busy=true],#team-plan-form[aria-busy=true]');
    const leaving=overlay&&!held&&!calm()?copyOf(overlay):null;
    const result=originalClose.apply(this,args);
    if(leaving&&!panelOverlay()){
      const {copy,restoreScroll}=leaving;
      document.body.appendChild(copy);restoreScroll();
      let gone=false;
      const finish=()=>{
        if(gone)return;gone=true;copy.remove();
        // A page redrawn while the copy was still there counted it as an open dialog; settle that now.
        const app=document.getElementById('app');if(app)app.inert=!!document.querySelector('.modal-overlay,.onboarding-screen');
      };
      copy.querySelector('.modal')?.addEventListener('animationend',finish,{once:true});
      setTimeout(finish,700);
    }
    return result;
  };
})(typeof globalThis!=='undefined'?globalThis:this);

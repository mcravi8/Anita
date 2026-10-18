/* Light / Dark / Match system. The choice lives in the saved workspace (state.theme); the resolved theme is
   written to <html data-theme>, so every stylesheet only ever needs [data-theme=dark] overrides. */
(function(root){
  'use strict';
  const CHOICES=['light','dark','system'];
  const normalize=choice=>CHOICES.includes(choice)?choice:'light';
  const resolve=(choice,systemDark)=>{const c=normalize(choice);return c==='system'?(systemDark?'dark':'light'):c;};
  // [choice, label, sidebar, page, text bars, card, quiet bars, accent dot] for the little window previews.
  const PREVIEWS=[
    ['light','Light','#f4f3ef','#fbfaf8','#141414','#ffffff','rgba(20,20,20,.18)','#8a63d2'],
    ['dark','Dark','#191918','#121211','#f2f0ea','#262624','rgba(255,255,255,.2)','#b9a0eb'],
    ['system','Match system','linear-gradient(90deg,#f4f3ef 50%,#191918 50%)','linear-gradient(90deg,#fbfaf8 50%,#121211 50%)','#8d8c86','rgba(141,140,134,.4)','rgba(141,140,134,.4)','#8a63d2']
  ];
  let host=null,mq=null;
  const systemDark=()=>!!(root.matchMedia&&root.matchMedia('(prefers-color-scheme: dark)').matches);
  const current=()=>normalize(host&&host.state()&&host.state().theme);
  function apply(){
    const choice=current(),theme=resolve(choice,systemDark());
    if(typeof document==='undefined')return theme;
    const el=document.documentElement;
    el.dataset.theme=theme;el.dataset.appearance=choice;el.style.colorScheme=theme;
    // The page reads this before anything else loads, so it starts in the right theme instead of flashing the other one.
    try{localStorage.setItem('buddy.appearance',choice);}catch{}
    const meta=document.querySelector('meta[name=theme-color]');if(meta)meta.content=theme==='dark'?'#121211':'#fbfaf8';
    root.BuddyFigures?.setDark(theme==='dark');
    try{Promise.resolve(root.BuddyDesktop?.setAppearance?.(choice)).catch(()=>{});}catch{}
    return theme;
  }
  function init(options){
    host=options;apply();
    if(!mq&&root.matchMedia){mq=root.matchMedia('(prefers-color-scheme: dark)');mq.addEventListener('change',()=>{if(current()==='system')apply();});}
  }
  function choose(choice){
    if(!host||!CHOICES.includes(choice))return;
    host.state().theme=choice;host.save();apply();
    for(const button of document.querySelectorAll('.theme-card[data-theme-choice]'))button.setAttribute('aria-pressed',String(button.dataset.themeChoice===choice));
  }
  function section(){
    const choice=current();
    return `<div class="appearance-settings"><div class="appearance-settings-head"><strong>Appearance</strong><p>Light, dark, or whatever your Mac is using.</p></div><div class="theme-cards" role="group" aria-label="Appearance">${PREVIEWS.map(([id,label,side,bg,bar,card,bar2,dot])=>`<button type="button" class="theme-card" aria-pressed="${id===choice}" data-theme-choice="${id}"><span class="theme-preview" style="background:${bg}" aria-hidden="true"><span class="theme-preview-side" style="background:${side}"></span><span class="theme-preview-main"><i style="background:${bar};width:62%"></i><i style="background:${bar2};width:84%"></i><b style="background:${card}"><u style="background:${dot}"></u></b></span></span><span class="theme-label">${label}</span></button>`).join('')}</div></div>`;
  }
  function mount(){
    for(const button of document.querySelectorAll('.theme-card[data-theme-choice]'))button.addEventListener('click',()=>choose(button.dataset.themeChoice));
  }
  const api={CHOICES,normalize,resolve,PREVIEWS,init,apply,choose,section,mount,current};
  if(typeof module!=='undefined'&&module.exports)module.exports=api;
  root.BuddyTheme=api;
})(typeof globalThis!=='undefined'?globalThis:this);

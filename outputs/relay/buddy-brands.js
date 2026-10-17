(function(root){
  'use strict';
  const assets={
    gmail:'gmail.svg','google drive':'google-drive.svg',drive:'google-drive.svg',
    'google calendar':'google-calendar.svg','google contacts':'google-contacts.png',
    github:'github.svg',chatgpt:'openai.svg',openai:'openai.svg',claude:'claude.svg',
    anthropic:'anthropic.svg',sites:'sites.svg',pets:'pets.svg','chatgpt space':'chatgpt-space.svg'
  };
  const escape=value=>String(value).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  function remote(value){
    if(typeof value!=='string'||value.length>4096)return '';
    try{const url=new URL(value);return url.protocol==='https:'&&url.hostname&&!url.username&&!url.password?url.href:'';}catch{return '';}
  }
  function source(value){
    const app=typeof value==='string'?{name:value}:value||{};
    const asset=assets[String(app.name||'').trim().toLowerCase()];
    return asset?`assets/brands/${asset}`:remote(app.iconUrl);
  }
  function logo(value){
    const src=source(value);
    return src?`<img class="brand-logo" src="${escape(src)}" alt="" aria-hidden="true" width="28" height="28" draggable="false" referrerpolicy="no-referrer">`:'';
  }
  const api={source,logo,remote};root.BuddyBrands=api;
  if(typeof module!=='undefined')module.exports=api;
  if(typeof document!=='undefined'){
    // A missing remote app icon retains the neutral capability symbol beneath it.
    document.addEventListener('error',event=>{if(event.target?.matches?.('.brand-logo'))event.target.remove();},true);
  }
})(typeof globalThis!=='undefined'?globalThis:this);

(function(root){
  'use strict';
  // Website passwords the person chose to remember in a chat's sign-in field ("Remember for shop.example (ada@example.com)"). They are in
  // the Mac's Keychain; the page only ever sees which site and which account, never a password. Background work › Browser sign-in shows
  // them with Replace and Remove next to the service sign-ins (WRDS).
  //
  // For that section: `BuddyWebsiteSignIns.section()` is the markup to put where the list goes; it fills itself in (and keeps itself up to
  // date) once it is on the page. `BuddyWebsiteSignIns.mount(element)` does the same for an element already there. `load()` reads the
  // list ([{origin, username, site}]) from the app's sign-in bridge. A new password typed for Replace goes from its field to the bridge and
  // nowhere else, and the field is emptied first.
  const esc=value=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const host=origin=>{try{return new URL(origin).host||String(origin);}catch{return String(origin||'');}};
  const keyOf=item=>`${item.origin}|${item.username||''}`;
  /** The section's markup for `list` (null while it loads). `editing`: the entry whose Replace field is open. */
  function html(list,{editing=null,busy=new Set(),error='',note=''}={}){
    let out=`<strong>Remembered website sign-ins</strong>`;
    if(error)out+=`<p class="field-error" role="alert">${esc(error)}</p>`;
    if(note)out+=`<p role="status">${esc(note)}</p>`;
    if(list===null)return out+'<p>Loading…</p>';
    if(!list.length)return out+'<p>None yet. When you type a website’s password in a chat, keep “Remember” on and Buddy fills it in next time.</p>';
    out+='<p>Kept in your Mac’s Keychain. Buddy types each one only into that site’s sign-in page, for that account. Agents never see them.</p>';
    for(const item of list){
      const key=keyOf(item),site=item.site||host(item.origin),off=busy.has(key);
      out+=`<div class="website-signin-row" data-website-signin="${esc(key)}"><span><strong>${esc(site)}</strong><small>${esc(item.username||'The account this site asks for')}</small></span>`;
      if(editing===key)out+=`<div class="signin-holder"><label class="signin-field"><span>New password for ${esc(site)}</span><input type="password" data-website-password="${esc(key)}" autocomplete="off" autocapitalize="off" autocorrect="off" spellcheck="false" maxlength="1000" aria-label="New password for ${esc(site)}"></label><button type="button" class="primary-button" data-website-save="${esc(key)}" ${off?'disabled':''}>${off?'Saving…':'Save'}</button><button type="button" class="border-button" data-website-cancel="${esc(key)}">Cancel</button></div>`;
      else out+=`<button type="button" class="border-button" data-website-replace="${esc(key)}" ${off?'disabled':''}>Replace</button><button type="button" class="border-button" data-website-remove="${esc(key)}" ${off?'disabled':''}>${off?'Removing…':'Remove'}</button>`;
      out+='</div>';
    }
    return out;
  }
  const api={html,host,keyOf};root.BuddyWebsiteSignIns=api;if(typeof module!=='undefined')module.exports=api;
  if(typeof document==='undefined')return;

  let list=null,editing=null,error='',note='';const busy=new Set();
  function bridge(){if(!window.BuddyDesktop?.signin)throw Error('Open Buddy on this Mac to manage remembered sign-ins.');return window.BuddyDesktop.signin;}
  function paint(){for(const element of document.querySelectorAll('[data-website-signins]'))element.innerHTML=html(list,{editing,busy,error,note});}
  async function load(){
    try{const reply=await bridge()({action:'sites'});list=Array.isArray(reply?.sites)?reply.sites:[];error='';}
    catch(e){list=list||[];error=String(e?.message||e);}
    paint();return list;
  }
  const section=()=>'<div class="website-signins" data-website-signins></div>';
  async function mount(element){if(!element)return;element.classList.add('website-signins');element.setAttribute('data-website-signins','');element.dataset.websiteMounted='1';paint();await load();}
  const find=key=>(list||[]).find(item=>keyOf(item)===key);
  async function change(key,payload,done){
    const item=find(key);if(!item||busy.has(key))return;
    busy.add(key);note='';paint();
    try{await bridge()({...payload,origin:item.origin,username:item.username||''});note=done(item);editing=null;error='';}
    catch(e){error=String(e?.message||e);}
    finally{busy.delete(key);}
    await load();
  }
  document.addEventListener('click',e=>{
    const target=e.target.closest?.('[data-website-replace],[data-website-remove],[data-website-save],[data-website-cancel]');if(!target||target.disabled)return;
    e.preventDefault();
    if(target.dataset.websiteReplace){editing=target.dataset.websiteReplace;note='';paint();document.querySelector(`[data-website-password="${CSS.escape(editing)}"]`)?.focus();}
    else if(target.dataset.websiteCancel){editing=null;paint();}
    else if(target.dataset.websiteRemove)change(target.dataset.websiteRemove,{action:'removeSite'},item=>`Removed the password for ${item.site||host(item.origin)}.`);
    else if(target.dataset.websiteSave){
      const key=target.dataset.websiteSave,input=document.querySelector(`[data-website-password="${CSS.escape(key)}"]`);
      if(!input?.value){input?.focus();return;}
      // The new password lives only in this call: the field is emptied before anything else happens.
      let password=input.value;input.value='';
      change(key,{action:'replaceSite',password},item=>`Replaced the password for ${item.site||host(item.origin)}.`).finally(()=>{password='';});
    }
  });
  document.addEventListener('keydown',e=>{const input=e.target.closest?.('[data-website-password]');if(!input||e.key!=='Enter'||e.isComposing)return;e.preventDefault();document.querySelector(`[data-website-save="${CSS.escape(input.dataset.websitePassword)}"]`)?.click();});
  // A section put on the page by its markup fills itself in.
  new MutationObserver(()=>{for(const element of document.querySelectorAll('[data-website-signins]:not([data-website-mounted])'))mount(element);}).observe(document.body,{childList:true,subtree:true});
  api.section=section;api.mount=mount;api.load=load;
})(typeof window!=='undefined'?window:globalThis);

(function(root){
  'use strict';
  // Connected services: web APIs the person connects once (RunPod, say) so agents can use them through Buddy, which adds the key itself.
  // Background work › Browser sign-in lists them next to Saved sign-ins, with Replace key and Remove, and a form to connect another; the
  // chat's card (buddy-signin.js) uses the same fields when an agent asks for a service that isn't connected yet. The page only ever sees a
  // service's name, address and choices: the key goes from its field to the app's sign-in bridge (and the Keychain) and nowhere else, and
  // the field is emptied first.
  const esc=value=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const eye=()=>typeof icon==='function'?icon('eye'):'';
  /** The fields that connect a service. `key` names the form; `values` fills it ({name, baseUrl, header, customHeader, charges});
   *  `fixedName` keeps the name the agent asked for. Names are on data-service-* attributes, values are read by `read(form)`. */
  // `signin`: the chat's card, whose redraws keep what is being typed (buddy-signin.js keeps any field marked data-signin-input).
  function fields(key,values={},{fixedName=false,replacing=false,signin=false}={}){
    const custom=values.header&&values.header!=='Authorization',k=esc(key),kept=name=>signin?` data-signin-input="${k}|${name}" data-signin-name="${name}"`:'';
    const input=(name,label,type,value='',extra='')=>`<label class="signin-field"><span>${esc(label)}</span><input type="${type}" data-service-input="${name}" data-service-for="${k}"${kept(name)} autocomplete="off" autocapitalize="off" autocorrect="off" spellcheck="false" aria-label="${esc(label)}" value="${esc(value)}" ${extra}></label>`;
    let out=fixedName?`<input type="hidden" data-service-input="name" data-service-for="${k}" value="${esc(values.name)}">`:input('name','Service name','text',values.name||'','maxlength="60" placeholder="RunPod"');
    out+=input('baseUrl','API address','url',values.baseUrl||'','maxlength="300" placeholder="https://rest.example.com/v1"');
    out+=`<label class="signin-field"><span>How the key is sent</span><select data-service-header data-service-for="${k}" aria-label="How the key is sent"><option value="Authorization" ${custom?'':'selected'}>Authorization: Bearer key</option><option value="custom" ${custom?'selected':''}>In another header…</option></select></label>`;
    out+=`<label class="signin-field" data-service-custom ${custom?'':'hidden'}><span>Header name</span><input type="text" data-service-input="customHeader" data-service-for="${k}"${kept('customHeader')} autocomplete="off" spellcheck="false" maxlength="64" placeholder="X-API-Key" aria-label="Header name" value="${esc(custom&&values.header!=='custom'?values.header:values.customHeader||'')}"></label>`;
    out+=`<fieldset class="service-charges" data-service-charges-for="${k}"><legend>Can this service charge you money?</legend><label><input type="radio" name="service-charges-${k}" value="yes" data-service-charges ${values.charges===true?'checked':''}> Yes</label><label><input type="radio" name="service-charges-${k}" value="no" data-service-charges ${values.charges===false?'checked':''}> No</label></fieldset>`;
    out+=`<label class="signin-field"><span>API key${replacing?' (leave empty to keep the saved one)':''}</span><span class="signin-secret"><input type="password" data-service-input="key" data-service-for="${k}"${kept('key')} autocomplete="off" autocapitalize="off" autocorrect="off" spellcheck="false" maxlength="500" aria-label="API key"><button type="button" class="signin-eye" data-signin-eye aria-label="Show password" aria-pressed="false">${eye()}</button></span></label>`;
    return out;
  }
  const assurance='The key goes to your Mac’s Keychain. Agents never see it; Buddy sends it only to this address. When the service can charge money, you approve every change an agent asks for there, with its cost.';
  /** What the form holds, as the bridge takes it. `missing` names the first field still to fill. */
  function read(form){
    const get=name=>form.querySelector(`[data-service-input="${name}"]`),header=form.querySelector('[data-service-header]')?.value||'Authorization';
    const charges=form.querySelector('[data-service-charges]:checked')?.value;
    const value={name:(get('name')?.value||'').trim(),baseUrl:(get('baseUrl')?.value||'').trim(),header:header==='custom'?(get('customHeader')?.value||'').trim():'Authorization',scheme:header==='custom'?'':'Bearer',key:get('key')?.value||''};
    if(charges)value.charges=charges==='yes';
    const missing=!value.name?'name':!value.baseUrl?'baseUrl':header==='custom'&&!value.header?'customHeader':charges===undefined?'charges':'';
    return {value,missing};
  }
  /** The Settings section for `list` (null while it loads). `editing`: the service whose Replace key form is open; `adding`: the form to
   *  connect another is open. */
  function html(list,{editing=null,adding=false,busy=new Set(),error='',note=''}={}){
    let out='<strong>Connected services</strong><p>Web services your agents use through Buddy, such as RunPod. Buddy keeps each key in your Mac’s Keychain and adds it to requests itself; agents never see it.</p>';
    if(error)out+=`<p class="field-error" role="alert">${esc(error)}</p>`;
    if(note)out+=`<p role="status">${esc(note)}</p>`;
    if(list===null)return out+'<p>Loading…</p>';
    if(!list.length&&!adding)out+='<p>None yet. When an agent needs one, it asks you in its chat; you can also connect one here.</p>';
    for(const s of list){
      const id=esc(s.id),off=busy.has(s.id);
      out+=`<div class="website-signin-row service-row" data-service-row="${id}"><span><strong>${esc(s.name)}</strong><small>${esc(s.baseUrl)} · ${s.charges?'Can charge money: you approve each change':'Can’t charge money'} · ${esc(s.sends||'')}${s.saved===false?' · Key missing':''}</small></span>`;
      if(editing===s.id)out+=`<div class="signin-holder service-form" data-service-form="${id}">${fields(s.id,{name:s.name,baseUrl:s.baseUrl,header:s.header,charges:s.charges},{fixedName:true,replacing:true})}<div class="worker-toolbar"><button type="button" class="border-button" data-service-cancel="${id}">Cancel</button><button type="button" class="primary-button" data-service-save="${id}" ${off?'disabled':''}>${off?'Saving…':'Save'}</button></div></div>`;
      else out+=`<button type="button" class="border-button" data-service-replace="${id}" ${off?'disabled':''}>Replace key</button><button type="button" class="border-button" data-service-remove="${id}" ${off?'disabled':''}>${off?'Removing…':'Remove'}</button>`;
      out+='</div>';
    }
    if(adding)out+=`<div class="signin-holder service-form" data-service-form="new">${fields('new')}<div class="service-foot"><small class="signin-assurance">${esc(assurance)}</small><div class="worker-toolbar"><button type="button" class="border-button" data-service-cancel="new">Cancel</button><button type="button" class="primary-button" data-service-save="new" ${busy.has('new')?'disabled':''}>${busy.has('new')?'Connecting…':'Connect'}</button></div></div></div>`;
    else out+='<div class="worker-toolbar"><button type="button" class="border-button" data-service-add>Connect a service</button></div>';
    return out;
  }
  const api={html,fields,read,assurance};root.BuddyServices=api;if(typeof module!=='undefined')module.exports=api;
  if(typeof document==='undefined')return;

  let list=null,editing=null,adding=false,error='',note='';const busy=new Set();
  function bridge(){if(!window.BuddyDesktop?.signin)throw Error('Open Buddy on this Mac to manage connected services.');return window.BuddyDesktop.signin;}
  function paint(){for(const element of document.querySelectorAll('[data-connected-services]'))element.innerHTML=html(list,{editing,adding,busy,error,note});}
  async function load(){
    try{const reply=await bridge()({action:'services'});list=Array.isArray(reply?.services)?reply.services:[];error='';}
    catch(e){list=list||[];error=String(e?.message||e);}
    paint();return list;
  }
  const section=()=>'<div class="website-signins connected-services" data-connected-services></div>';
  async function mount(element){if(!element)return;element.dataset.servicesMounted='1';paint();await load();}
  async function save(id){
    const form=document.querySelector(`[data-service-form="${CSS.escape(id)}"]`);if(!form||busy.has(id))return;
    const {value,missing}=read(form);
    if(missing){(missing==='charges'?form.querySelector('[data-service-charges]'):form.querySelector(`[data-service-input="${missing}"]`))?.focus();error=missing==='charges'?'Say whether this service can charge you money.':'';if(error)paint();return;}
    if(id==='new'&&!value.key){form.querySelector('[data-service-input="key"]')?.focus();return;}
    // The key lives only in this call: its field is emptied before anything else happens.
    const keyField=form.querySelector('[data-service-input="key"]');if(keyField)keyField.value='';
    busy.add(id);note='';error='';paint();
    try{const reply=await bridge()({action:'provideService',...value,...(value.key?{}:{key:''})});list=Array.isArray(reply?.services)?reply.services:list;note=id==='new'?`Connected ${value.name}.`:`Saved. ${value.name} uses the new settings from now on.`;editing=null;adding=false;}
    catch(e){error=String(e?.message||e);}
    finally{value.key='';busy.delete(id);}
    paint();
  }
  async function remove(id){
    if(busy.has(id))return;const s=(list||[]).find(x=>x.id===id);if(!s)return;
    busy.add(id);note='';paint();
    try{const reply=await bridge()({action:'removeService',id});list=Array.isArray(reply?.services)?reply.services:list;note=`Removed ${s.name}. Agents will ask you to connect it again if they need it.`;}
    catch(e){error=String(e?.message||e);}
    finally{busy.delete(id);}
    paint();
  }
  document.addEventListener('click',e=>{
    const target=e.target.closest?.('[data-service-add],[data-service-replace],[data-service-remove],[data-service-save],[data-service-cancel]');if(!target||target.disabled||!target.closest('[data-connected-services]'))return;
    e.preventDefault();
    if(target.matches('[data-service-add]')){adding=true;editing=null;note='';paint();document.querySelector('[data-service-form="new"] [data-service-input="name"]')?.focus();}
    else if(target.dataset.serviceReplace){editing=target.dataset.serviceReplace;adding=false;note='';paint();document.querySelector(`[data-service-form="${CSS.escape(editing)}"] [data-service-input="key"]`)?.focus();}
    else if(target.dataset.serviceCancel){if(target.dataset.serviceCancel==='new')adding=false;else editing=null;paint();}
    else if(target.dataset.serviceRemove)remove(target.dataset.serviceRemove);
    else if(target.dataset.serviceSave)save(target.dataset.serviceSave);
  });
  // "In another header…" shows the header name field.
  document.addEventListener('change',e=>{const select=e.target.closest?.('[data-service-header]');if(!select)return;const custom=select.closest('.service-form,.signin-holder')?.querySelector('[data-service-custom]');if(custom)custom.hidden=select.value!=='custom';});
  new MutationObserver(()=>{for(const element of document.querySelectorAll('[data-connected-services]:not([data-services-mounted])'))mount(element);}).observe(document.body,{childList:true,subtree:true});
  api.section=section;api.mount=mount;api.load=load;
})(typeof window!=='undefined'?window:globalThis);

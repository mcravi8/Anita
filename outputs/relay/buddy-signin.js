(function(root){
  'use strict';
  // Sign-ins and other steps only the person can do, asked in the chats. The Mac app says what is waiting (`signinRequests` in the worker's
  // status): a password or code to type for a website, a service sign-in to save (WRDS), a step to finish outside the chat (Buddy's Chrome
  // window, a push on the phone) and confirm with Done. Each request is one message in the agent's chat, and one in the team's group chat
  // when its task belongs to a team plan; both are the same request, so answering either answers both.
  //
  // What the person types goes from the field to the app's sign-in bridge and nowhere else: never into a message, the saved workspace,
  // drafts, browser storage or a log. The field is cleared as soon as it is sent. Messages keep only what was asked and what came of it.
  //
  // An account an agent wants Buddy to create on one site (or a password to reset there) asks "is that fine?" with ✓ and ✗, answered only
  // through the sign-in bridge; once the person said yes it says what Buddy is doing, then what came of it (`receipt`).
  const KINDS=new Set(['signin','step','credential','mfa','account']);
  const KEPT=['key','kind','taskId','agentId','reviewId','mode','origin','account','field','step','note','attempts','choices','profile','service','instruction','need','chromeOpen','legacy','title','url','target','coding','unknownPage','fetch','secret','baseUrl',
    'purpose','reason','what','working','done','receipt','created','details','money'];
  const host=origin=>{try{return new URL(origin).host||String(origin);}catch{return String(origin||'')||'this website';}};
  // A step on a web page is on its exact page (`url`), else on its site; one with neither is a step Buddy doesn't know the page of.
  const stepPage=r=>r.unknownPage?'':r.url||r.origin||'';
  // Where a file goes ("Directed Research/stages/S01_protocol/sources/sethna-2022.pdf"): its folder, and its name.
  const folderOf=target=>{const t=String(target||''),at=t.lastIndexOf('/');return at>0?t.slice(0,at):t;};
  const fileName=target=>String(target||'').split('/').pop();
  const nameOf=(state,id)=>(state?.agents||[]).find(a=>a.id===id)?.name;
  // The request as a message keeps it: what is asked and of whom. Never a token, never what was typed.
  function view(request){const out={};for(const key of KEPT)if(request[key]!==undefined&&request[key]!==null&&request[key]!=='')out[key]=request[key];return out;}
  // `who`: the agent's name, for a step Buddy doesn't know the page of.
  function title(r,who){
    const site=host(r.origin);
    if(r.kind==='account')return r.purpose==='reset'?`${who||'Your agent'} wants to reset your password on ${site} through your email — is that fine?`:`${who||'Your agent'} wants to create an account on ${site}${r.account?` with ${r.account}`:''} — is that fine?`;
    if(r.kind==='credential')return r.secret==='service'?`Connect ${r.service||'this service'}`:`${r.service||'This service'} needs your sign-in`;
    if(r.kind==='mfa')return `Approve the ${r.service||'sign-in'} Duo push on your phone`;
    if(r.kind==='step'){
      // Always the site, never "the website": the step's own page, and the account to use there.
      const page=stepPage(r);if(!page)return `Buddy doesn’t know which page — ask ${who||'the agent'}`;
      const at=host(page);
      if(r.need==='captcha')return `Finish the CAPTCHA on ${at}`;
      if(r.need==='payment')return r.money==='trial'?`This sign-up on ${at} starts a free trial that becomes paid`:`This sign-up on ${at} asks for payment details`;
      if(r.need==='verification')return `Finish verifying on ${at}`;
      if(r.need==='file'){const into=folderOf(r.target);return `Save ${/\.pdf$/i.test(String(r.target||''))?'the PDF':'the file'} from ${at}${into?` into ${into}`:''}`;}
      return `Sign in to ${at}${r.account?` as ${r.account}`:''}`;
    }
    if(r.mode==='signup')return `Create your account on ${site}`;
    if(r.field==='code')return `Code for ${site}`;
    return `Sign in to ${site}`;
  }
  // One plain line for the chat list and search; the message itself says the rest.
  const summary=(r,who)=>{const t=title(r,who);return /[.?!]$/.test(t)?t:t+'.';};
  // What an account card says while Buddy works on it.
  const working=r=>r.purpose==='reset'?`Resetting your password on ${host(r.origin)}…`:`Creating your account on ${host(r.origin)}…`;
  // Which chats a request is posted in: its agent's, and the group chat of the team plan its task belongs to.
  function chatsFor(state,snapshot,request){
    const out=[];
    if((state.agents||[]).some(a=>a.id===request.agentId))out.push(request.agentId);
    const plan=request.planId?(snapshot.plans||[]).find(p=>p?.id===request.planId):null;
    if(plan?.groupId&&(state.groups||[]).some(g=>g.id===plan.groupId))out.push(plan.groupId);
    return out;
  }
  const ended=m=>m.request?.kind==='mfa'?`The ${m.request.service||'sign-in'} step is over.`:m.request?.kind==='step'?'This step has ended.':m.request?.kind==='account'?'This request has ended.':'This sign-in request has ended.';
  const stamp=()=>new Date().toLocaleTimeString([],{hour:'2-digit',minute:'2-digit'});
  function messages(state,key){const out=[];for(const list of Object.values(state.messages||{}))if(Array.isArray(list))for(const m of list)if(m?.kind==='signin-request'&&m.request?.key===key)out.push(m);return out;}
  /** Brings the chats up to date with what the app says is waiting: a message for each new request, an updated one for a changed request,
   *  and a closed one for a request that has ended. Returns whether anything changed. */
  // `pins`: requests whose next try the page already knows from the app's answer (key → reviewId), so a status read just before that
  // answer cannot send the person's next try to the one that ended. `posted` hears each new request once, when its message is first put
  // in its agent's chat (the desktop drop, buddy-drop-events.js).
  function sync(state,snapshot,pins=new Map(),posted){
    if(!snapshot||snapshot.workspace!==state.conversationWorkspace||!Array.isArray(snapshot.signinRequests))return false;
    let changed=false;const open=new Set();
    for(const request of snapshot.signinRequests){
      if(!KINDS.has(request?.kind)||typeof request.key!=='string'||!request.key)continue;
      open.add(request.key);const next=view(request);
      const pin=pins.get(request.key);if(pin){if(pin.reviewId===next.reviewId||Date.now()>pin.until)pins.delete(request.key);else continue;}
      for(const chat of chatsFor(state,snapshot,request)){
        state.messages[chat]||=[];
        const m=state.messages[chat].find(x=>x?.kind==='signin-request'&&x.request?.key===request.key);
        if(!m){
          // An account request first seen while Buddy already works on it (or with its receipt) has no question left to answer.
          const status=next.done&&next.receipt?'done':next.working?'sending':'open';
          state.messages[chat].push({id:`signin-${request.key}${chat===request.agentId?'':'@'+chat}`,kind:'signin-request',who:request.agentId,chat,request:next,status,...(status==='done'?{result:next.receipt}:status==='sending'?{result:working(next)}:{}),body:summary(next,nameOf(state,request.agentId)),time:stamp(),createdAt:new Date().toISOString()});changed=true;if(chat===request.agentId)posted?.(next);continue;
        }
        if(m.status==='closed'||m.status==='done')continue;
        // What came of an account request: its receipt, in place.
        if(next.kind==='account'&&next.done&&next.receipt){m.request=next;m.status='done';m.result=next.receipt;m.body=summary(next,nameOf(state,request.agentId));changed=true;continue;}
        if(next.kind==='account'&&next.working&&m.status==='open'){m.status='sending';m.result||=working(next);changed=true;}
        if(JSON.stringify(m.request)!==JSON.stringify(next)){
          // A new try of the same request (a fresh field after a wrong password, a code step): the last outcome stays until it is answered.
          if(m.request?.reviewId&&next.reviewId&&m.request.reviewId!==next.reviewId&&m.status==='sending')m.status='open';
          m.request=next;m.body=summary(next,nameOf(state,request.agentId));changed=true;
        }
      }
    }
    // A request no longer waiting has ended: its messages say how, in place.
    for(const list of Object.values(state.messages||{}))if(Array.isArray(list))for(const m of list){
      if(m?.kind!=='signin-request'||m.status==='closed'||open.has(m.request?.key))continue;
      // An answer still on its way when the request ended says what it was.
      if(m.status==='sending')m.result=m.choice==='saved'?'Used your saved login.':m.choice==='verify'?'Used the code from Gmail.':m.choice==='private'?'Continued in Buddy’s Chrome window.':m.result;
      m.status='closed';m.result||=ended(m);changed=true;
    }
    return changed;
  }
  /** Records what came of the person's answer on every message of the request (its agent's chat and its group chat alike). */
  function settle(state,key,patch){
    const found=messages(state,key);
    for(const m of found){
      if(patch.status)m.status=patch.status;
      if('result' in patch)m.result=patch.result;
      // A request field the answer says is gone (no field to type into any more) is removed, not kept from before.
      if(patch.request)for(const [k,v] of Object.entries(patch.request)){if(!KEPT.includes(k)||v===undefined)continue;if(v===null||v==='')delete m.request[k];else m.request[k]=v;}
      if(patch.choice)m.choice=patch.choice;
      if(patch.acknowledged)m.acknowledged=true;
      m.body=summary(m.request||{},nameOf(state,m.request?.agentId));
    }
    return found.length>0;
  }
  const api={sync,settle,view,chatsFor,title,summary};root.BuddySignIn=api;if(typeof module!=='undefined')module.exports=api;
  if(typeof document==='undefined')return;

  // MARK: on the page

  const busy=new Set(),pins=new Map();
  const pinNext=(key,reply)=>{if(reply?.reviewId)pins.set(key,{reviewId:reply.reviewId,until:Date.now()+10000});};
  // A typed value lives only in its field. The chat redraws often (a reply streams, a status arrives), and a redraw would empty the
  // field mid-typing, so the field being typed in is moved into the redrawn message instead. It is let go the moment it is sent.
  const typing=new Map();let lastField=null;
  // "Remember for <site> (<account>)" on a password field, on unless the person turned it off for that request.
  const remember=new Map();
  const fieldKey=(key,name)=>`${key}|${name}`;
  // A password field has an eye that shows what was typed and hides it again; `value` fills a field in (the task's own email).
  const eyeIcon=()=>typeof icon==='function'?icon('eye'):'';
  function field(r,name,label,type,value=''){
    const input=`<input type="${type}" data-signin-input="${esc(fieldKey(r.key,name))}" data-signin-name="${esc(name)}" autocomplete="off" autocapitalize="off" autocorrect="off" spellcheck="false" maxlength="${name==='username'?200:1000}" aria-label="${esc(label)}"${value?` value="${esc(value)}"`:''}>`;
    if(type!=='password')return `<label class="signin-field"><span>${esc(label)}</span>${input}</label>`;
    return `<label class="signin-field"><span>${esc(label)}</span><span class="signin-secret">${input}<button type="button" class="signin-eye" data-signin-eye aria-label="Show password" aria-pressed="false">${eyeIcon()}</button></span></label>`;
  }
  const button=(attr,key,label,primary=false,disabled=false)=>`<button type="button" class="${primary?'primary-button':'border-button'}" ${attr}="${esc(key)}" ${disabled?'disabled':''}>${esc(label)}</button>`;
  function body(m){
    const r=m.request||{},site=host(r.origin),off=m.status!=='open'||busy.has(r.key),who=findAgent(r.agentId)?.name||'The agent';
    const done=m.status==='closed'||m.status==='done';
    let html=`<strong class="signin-title">${esc(title(r,who))}</strong>`;
    const about=[r.account?`Account: ${r.account}`:'',r.kind==='credential'&&r.profile?'Kept in your Mac’s Keychain':'',r.title?`For “${r.title}”`:''].filter(Boolean).join(' · ');
    if(about)html+=`<small class="signin-about">${esc(about)}</small>`;
    if(m.result)html+=`<p class="signin-result ${/signed in|saved|done —|continuing|created an account|^reset your password/i.test(m.result)?'ok':''}" role="status">${esc(m.result)}</p>`;
    // An account Buddy created: where its password is (the Keychain, not Chrome's Password Manager), and the list it is in.
    if(done&&r.kind==='account'&&r.created){
      if(r.details)html+=`<small class="signin-assurance">${esc(r.details)}</small>`;
      html+=`<div class="signin-actions"><button type="button" class="border-button" data-action="browser-signin">Saved sign-ins</button></div>`;
    }
    if(done)return html;
    if(r.note&&r.note!==m.result)html+=`<p class="signin-note">${esc(r.note)}</p>`;
    if(r.kind==='account'){
      // Why the agent needs it, what Buddy will do, and the two answers. Only this card's click answers it.
      if(r.reason)html+=`<p class="signin-note">${esc(r.reason)}</p>`;
      if(r.what)html+=`<small class="signin-assurance">${esc(r.what)}</small>`;
      if(m.status==='open'&&!r.working)html+=`<div class="signin-actions" data-signin-task="${esc(r.taskId)}"><button type="button" class="primary-button" data-signin-account="${esc(r.key)}|yes" ${off?'disabled':''}><span aria-hidden="true">✓ </span>${r.purpose==='reset'?'Reset password':'Create account'}</button><button type="button" class="border-button" data-signin-account="${esc(r.key)}|no" ${off?'disabled':''}><span aria-hidden="true">✗ </span>Don’t</button></div>`;
      return html;
    }
    if(r.kind==='signin'){
      if(r.field==='login'){
        // A sign-in that asks for both: the email (the task's own, filled in) and the password, like the site's own form.
        html+=`<div class="signin-holder signin-holder-pair" data-signin-holder="${esc(r.key)}" data-signin-task="${esc(r.taskId)}">${field(r,'username','Email address','email',r.account||'')}${field(r,'password','Password','password')}${button('data-signin-send',r.key,busy.has(r.key)?'Sending…':'Send',true,off)}</div>`;
        html+=`<label class="signin-remember"><input type="checkbox" data-signin-remember="${esc(r.key)}" ${remember.get(r.key)!==false?'checked':''} ${off?'disabled':''}><span>Remember for ${esc(site)}</span></label>`;
        html+=`<small class="signin-assurance signin-never">Never shown to ${esc(who)}. Filled directly to ${esc(site)}.</small>`;
      }else if(r.field){
        const label=r.field==='code'?`Code for ${site}`:r.field==='username'?`Email or username for ${site}`:`Password for ${site}`;
        html+=`<div class="signin-holder" data-signin-holder="${esc(r.key)}" data-signin-task="${esc(r.taskId)}">${field(r,r.field,label,r.field==='username'?'email':'password')}${button('data-signin-send',r.key,busy.has(r.key)?'Sending…':'Send',true,off)}</div>`;
        if(r.field==='password')html+=`<label class="signin-remember"><input type="checkbox" data-signin-remember="${esc(r.key)}" ${remember.get(r.key)!==false?'checked':''} ${off?'disabled':''}><span>Remember for ${esc(site)}${r.account?` (${esc(r.account)})`:''}</span></label>`;
        if(r.field==='password')html+=`<small class="signin-assurance signin-never">Never shown to ${esc(who)}. Filled directly to ${esc(site)}.</small>`;
        html+=`<small class="signin-assurance">Buddy types this into ${esc(site)}’s sign-in page and nowhere else. ${esc(who)} never sees it, and it isn’t saved in this chat.${r.field==='password'?' Remembered, it stays in your Mac’s Keychain and Buddy fills it in next time.':''}</small>`;
      }else if(r.step==='wait')html+=`<p class="signin-note">${esc(r.note||`${site} is waiting for a step you do elsewhere. Do it, then press Done.`)}</p>`;
      else if(!r.note)html+=`<p class="signin-note">${esc(r.mode==='signup'?`${who} wants to create an account on ${site}. Create it in Buddy’s Chrome window, where Chrome can save the new password.`:`${who} needs you to sign in to ${site}.`)}</p>`;
      const choices=r.choices||[];
      html+=`<div class="signin-actions">${r.step==='wait'?button('data-signin-check',r.key,'Done',true,off):''}${choices.includes('saved')?button('data-signin-choice',r.key+'|saved','Use saved login',!r.field&&r.step!=='wait',off):''}${choices.includes('verify')?button('data-signin-choice',r.key+'|verify','Get the code from Gmail',!r.field,off):''}${choices.includes('private')?button('data-signin-choice',r.key+'|private',r.mode==='signup'?'Create in Chrome':r.field?'Open Chrome instead':'Open Chrome',!r.field&&!choices.includes('saved')&&r.step!=='wait',off):''}${button('data-signin-choice',r.key+'|decline','Not now',false,off)}</div>`;
    }else if(r.kind==='credential'&&r.secret==='service'){
      // A service an agent asked for that isn't connected yet: its address (as the agent suggested it), how its key is sent, whether it
      // can charge money, and the key. The person checks and fills it in; the key goes to the Keychain, never into the chat.
      if(r.instruction)html+=`<p class="signin-note">${esc(r.instruction)}</p>`;
      const chosen=serviceChoices.get(r.key)||{};
      html+=`<div class="signin-holder service-form" data-signin-holder="${esc(r.key)}" data-signin-task="${esc(r.taskId)}">${root.BuddyServices?.fields(r.key,{name:r.service,baseUrl:r.baseUrl||'',...chosen},{fixedName:true,signin:true})||''}<div class="service-foot"><small class="signin-assurance">${esc(root.BuddyServices?.assurance||'')} ${esc(who)} never sees the key.</small>${button('data-signin-send',r.key,busy.has(r.key)?'Connecting…':'Connect',true,off)}</div></div>`;
    }else if(r.kind==='credential'){
      if(r.instruction)html+=`<p class="signin-note">${esc(r.instruction)}</p>`;
      html+=`<div class="signin-holder signin-holder-pair" data-signin-holder="${esc(r.key)}" data-signin-task="${esc(r.taskId)}">${field(r,'username',`${r.service||'Service'} username`,'text')}${field(r,'password',`${r.service||'Service'} password`,'password')}${button('data-signin-send',r.key,busy.has(r.key)?'Saving…':'Save',true,off)}</div>`;
      html+=`<small class="signin-assurance">Buddy keeps this in your Mac’s Keychain, so you’re asked only once. ${esc(who)} never sees it; Buddy fills it in only for commands you approve.</small>`;
    }else if(r.kind==='step'){
      // What to do on which page, Open the page (that exact page, in Buddy's Chrome) and Done. A step Buddy doesn't know the page of opens
      // nothing: the person asks the agent in this chat.
      const page=stepPage(r);
      // A sign-up Buddy stopped because it asks for money: Open the page (to do it themselves), Done once they have, or Skip. No field.
      if(r.need==='payment'){
        const head=title(r,who),said=String(r.instruction||''),rest=said.startsWith(head)?said.slice(head.length).replace(/^\.\s*/,''):said;
        if(rest)html+=`<p class="signin-note">${esc(rest)}</p>`;
        html+=`<div class="signin-actions" data-signin-task="${esc(r.taskId)}">${r.chromeOpen?button('data-signin-done',r.key,busy.has(r.key)?'Checking…':'Done',true,off):''}${page?button('data-signin-chrome',r.key,'Open the page',!r.chromeOpen,off):''}${button('data-signin-skip',r.key,'Skip',false,off)}</div>`;
        return html;
      }
      html+=`<p class="signin-note">${esc(r.instruction||'Finish the step, then press Done.')}</p>`;
      if(!page)html+=`<p class="signin-note">${esc(who)} didn’t say which page this is on. Reply in this chat to ask ${esc(who)} which page it needs.</p>`;
      html+=`<div class="signin-actions" data-signin-task="${esc(r.taskId)}">${button('data-signin-done',r.key,busy.has(r.key)?'Checking…':'Done',true,off)}${page?button('data-signin-chrome',r.key,'Open the page',false,off):button('data-signin-reply',r.key,'Reply in chat',false,false)}</div>`;
      if(r.need==='file')html+=`<small class="signin-assurance">Name it ${esc(fileName(r.target))}. Save it from the page into that folder, then press Done: ${esc(who)} checks it’s there before using it.</small>`;
      // A file Buddy's Chrome is fetching: the person only finishes the page; Done fetches it again and saves it.
      else if(r.fetch)html+=`<small class="signin-assurance">When you press Done, Buddy’s Chrome fetches it again and saves ${esc(fileName(r.target))} into ${esc(folderOf(r.target))}. Nothing to download yourself; ${esc(who)} continues from there.</small>`;
      else if(r.coding)html+=`<small class="signin-assurance">${esc(who)}’s commands can’t use what you sign in to in Chrome. Press Done and ${esc(who)} will ask you for the file instead.</small>`;
      else html+=`<small class="signin-assurance">Done tells Buddy to look again and carry on.</small>`;
    }else if(r.kind==='mfa'){
      html+=`<p class="signin-note">${esc(r.instruction||'Approve the push on your phone, then press Done.')}</p>`;
      html+=m.acknowledged?`<p class="signin-result" role="status">Thanks. This updates by itself when the command finishes.</p>`:`<div class="signin-actions" data-signin-task="${esc(r.taskId)}">${button('data-signin-mfa',r.key,'Done',true,off)}</div>`;
    }
    return html;
  }
  // Done or closed, the card leaves the chat; what came of the person's own answer is said once, as a toast (finish). An account Buddy created
  // stays as its receipt: it is something new (the account, and where its password is kept), not the answer said again.
  function finish(key,patch){settle(state,key,patch);if(['done','closed'].includes(patch.status)&&patch.result)showToast(patch.result);}
  const created=m=>m.status==='done'&&m.request?.kind==='account'&&!!m.request?.receipt;
  function render(m){
    if((m.status==='closed'||m.status==='done')&&!created(m))return '';
    const r=m.request||{},a=findAgent(r.agentId);if(!a)return '';
    const group=!!findGroup(ui.view.target),done=m.status==='closed'||m.status==='done';
    return `<div class="message bot-message signin-message ${done?'signin-ended':''}" data-signin-key="${esc(r.key||'')}">${group?avatar(a.id,true):''}<div class="bot-bubble signin-bubble">${group?`<button class="message-author" style="${authorColor(a)}" data-action="agent-info" data-id="${esc(a.id)}">${esc(a.name)}</button>`:''}${body(m)}<time>${esc(m.time||'')}</time></div></div>`;
  }
  api.render=render;
  // The chat draws messages through `messageHTML`; a sign-in request is drawn here.
  if(typeof window.messageHTML==='function'){const original=window.messageHTML;window.messageHTML=function(m){return m?.kind==='signin-request'?render(m):original.apply(this,arguments);};}
  function redraw(){
    save();
    if(typeof ui!=='undefined'&&ui.view?.kind==='chat'&&typeof refreshLiveChat==='function')refreshLiveChat(ui.view.target);
    if(typeof repaintChatList==='function')repaintChatList();
  }
  function request(key){return messages(state,key)[0]?.request||null;}
  function bridge(){if(!window.BuddyDesktop?.signin)throw Error('Open Buddy on this Mac to sign in.');return window.BuddyDesktop.signin;}
  // What the person chose on a service card (how the key is sent, whether it can charge money), kept across the chat's redraws.
  const serviceChoices=new Map();
  async function connect(key,r,holder){
    const {value,missing}=root.BuddyServices.read(holder);
    if(missing||!value.key){(missing==='charges'?holder.querySelector('[data-service-charges]'):holder.querySelector(`[data-service-input="${missing||'key'}"]`))?.focus();if(missing==='charges')settle(state,key,{result:`Say whether ${r.service||'this service'} can charge you money.`}),redraw();return;}
    // The key is emptied from its field and let go before anything else happens.
    for(const i of holder.querySelectorAll('[data-signin-input]')){if(i.dataset.signinName==='key')i.value='';typing.delete(i.dataset.signinInput);}
    busy.add(key);finish(key,{result:''});redraw();
    let reply;
    try{reply=await bridge()({action:'provideService',taskId:r.taskId,...value});}
    catch(error){reply={saved:false,error:String(error?.message||error)};}
    finally{value.key='';busy.delete(key);}
    finish(key,reply?.saved?{status:'done',result:reply.resumed?`Connected — ${agentName(r.agentId)} is continuing.`:`Connected ${value.name}.`}:{result:reply?.error||'That didn’t connect. Try again.'});
    redraw();window.BuddyWorkerUI?.refresh?.(false);
  }
  async function send(key){
    const r=request(key),holder=[...document.querySelectorAll('[data-signin-holder]')].find(h=>h.dataset.signinHolder===key);if(!r||!holder||busy.has(key))return;
    if(r.kind==='credential'&&r.secret==='service')return connect(key,r,holder);
    const inputs=[...holder.querySelectorAll('[data-signin-input]')],values=Object.fromEntries(inputs.map(i=>[i.dataset.signinName,i.value]));
    if(inputs.some(i=>!i.value)){(inputs.find(i=>!i.value)||inputs[0])?.focus();return;}
    // The field is emptied and let go before anything else happens; the value exists only in this call until the app has it.
    for(const i of inputs){i.value='';typing.delete(i.dataset.signinInput);}
    busy.add(key);finish(key,{result:''});redraw();
    let reply;
    try{
      const signin=bridge();
      reply=r.kind==='credential'?await signin({action:'provide',profile:r.profile,taskId:r.taskId,username:values.username,password:values.password})
        :r.field==='login'?await signin({action:'secret',taskId:r.taskId,reviewId:r.reviewId,value:values.password,username:values.username,remember:remember.get(key)!==false})
        :await signin({action:'secret',taskId:r.taskId,reviewId:r.reviewId,value:values[r.field],...(r.field==='password'?{remember:remember.get(key)!==false}:{})});
    }catch(error){reply={sent:false,error:String(error?.message||error)};}
    finally{for(const k of Object.keys(values))values[k]='';busy.delete(key);}
    pinNext(key,reply);
    if(r.kind==='credential')finish(key,reply?.saved?{status:'done',result:reply.resumed?`Saved — ${agentName(r.agentId)} is continuing.`:'Saved in your Keychain.'}:{result:reply?.error||'That didn’t save. Try again.'});
    else if(reply?.signedIn)finish(key,{status:'done',result:'Sent — signed in'+(reply.remembered?`. Remembered for ${host(r.origin)}.`:'')});
    else if(reply?.sent)finish(key,{result:reply.retry?'Sent — that didn’t work, try again':reply.chrome?'Sent — the website needs you in Buddy’s Chrome window.':'Sent — the website wants another step.',request:{reviewId:reply.reviewId,field:reply.field??null,note:reply.note,step:reply.step}});
    else finish(key,{result:reply?.note||reply?.error||'That didn’t go through. Nothing was sent. Try again.',request:reply?.reviewId?{reviewId:reply.reviewId}:undefined});
    redraw();window.BuddyWorkerUI?.refresh?.(false);
  }
  async function choose(key,choice){
    const r=request(key);if(!r||busy.has(key))return;
    busy.add(key);redraw();
    try{
      if(!window.BuddyDesktop?.worker)throw Error('Open Buddy on this Mac to sign in.');
      await window.BuddyDesktop.worker({operation:'review',taskId:r.taskId,id:r.reviewId,accept:choice!=='decline',...(choice==='decline'?{}:{authAction:choice})});
      finish(key,choice==='decline'?{status:'closed',result:`Not now. ${agentName(r.agentId)} won’t sign in.`}:{status:'sending',choice,result:choice==='saved'?'Trying your saved login…':choice==='verify'?'Getting the code from Gmail…':'Opening Buddy’s Chrome window…'});
    }catch(error){finish(key,{result:String(error?.message||error)});}
    finally{busy.delete(key);}
    redraw();window.BuddyWorkerUI?.refresh?.(false);
  }
  async function done(key,kind){
    const r=request(key);if(!r||busy.has(key))return;
    busy.add(key);redraw();
    let reply;
    try{reply=await bridge()(kind==='check'?{action:'check',taskId:r.taskId,reviewId:r.reviewId}:{action:'done',taskId:r.taskId});}
    catch(error){reply={done:false,note:String(error?.message||error)};}
    finally{busy.delete(key);}
    pinNext(key,reply);
    if(reply?.done||reply?.signedIn)finish(key,{status:'done',result:`Done — ${agentName(r.agentId)} is continuing.`});
    else finish(key,{result:reply?.note||'It isn’t finished yet. Finish the step, then press Done.',request:reply?.reviewId?{reviewId:reply.reviewId,field:reply.field??null,note:reply.note,step:reply.field?reply.field:'wait'}:{chromeOpen:reply?.reopened===true||r.chromeOpen}});
    redraw();window.BuddyWorkerUI?.refresh?.(false);
  }
  // ✓ Create account (or Reset password) / ✗ Don't: through the sign-in bridge, the only way the app takes this answer.
  async function account(key,allow){
    const r=request(key);if(!r||busy.has(key))return;
    busy.add(key);redraw();
    let reply;
    try{reply=await bridge()({action:'account',taskId:r.taskId,reviewId:r.reviewId,allow});}
    catch(error){reply={answered:false,error:String(error?.message||error)};}
    finally{busy.delete(key);}
    const site=host(r.origin);
    if(reply?.answered)finish(key,allow?{status:'sending',choice:'account',result:working(r)}:{status:'closed',result:r.purpose==='reset'?`Not now. Buddy won’t reset your password on ${site}.`:`Not now. ${agentName(r.agentId)} won’t create an account on ${site}.`});
    else finish(key,{result:reply?.error||'That didn’t go through. Try again.'});
    redraw();window.BuddyWorkerUI?.refresh?.(false);
  }
  // Skip on a sign-up Buddy stopped for money: the agent goes on without it.
  async function skipStep(key){
    const r=request(key);if(!r||busy.has(key))return;
    busy.add(key);redraw();
    let reply;
    try{reply=await bridge()({action:'skip',taskId:r.taskId});}
    catch(error){reply={skipped:false,error:String(error?.message||error)};}
    finally{busy.delete(key);}
    finish(key,reply?.skipped?{status:'done',result:`Skipped — ${agentName(r.agentId)} goes on without it.`}:{result:reply?.error||'That didn’t go through. Try again.'});
    redraw();window.BuddyWorkerUI?.refresh?.(false);
  }
  // The eye on a password field: shows what was typed, and hides it again.
  function toggleEye(button){
    const input=button.closest('.signin-secret')?.querySelector('input');if(!input)return;
    const show=input.type==='password';input.type=show?'text':'password';
    button.setAttribute('aria-pressed',String(show));button.setAttribute('aria-label',show?'Hide password':'Show password');
  }
  async function chrome(key){
    const r=request(key);if(!r||busy.has(key))return;
    busy.add(key);redraw();
    // The step's own page goes with the request; the app opens it only if it is still that step's page.
    const page=stepPage(r);
    try{await window.BuddyDesktop.worker({operation:'browser',taskId:r.taskId,...(page?{url:page}:{})});finish(key,{result:`Chrome is open at ${host(page)}. Finish there, then press Done.`,request:{chromeOpen:true}});}
    catch(error){finish(key,{result:String(error?.message||error)});}
    finally{busy.delete(key);}
    redraw();window.BuddyWorkerUI?.refresh?.(false);
  }
  // Done on a Duo push only acknowledges it: the message changes by itself when the command finishes. Its Needs item is put away too.
  function acknowledge(key){
    const r=request(key);if(!r)return;
    finish(key,{acknowledged:true});
    const [,task,command]=String(r.key).split(':'),id=`decision:mfa:${task}:${command||''}`;
    window.BuddyActivity?.markRead?.(state,[id]);window.BuddyActivity?.dismiss?.(state,[id]);
    try{window.BuddyDesktop?.worker?.({operation:'notify',ids:[id],read:true,dismissed:true});}catch{}
    redraw();window.BuddyActivity?.paint?.();
  }
  document.addEventListener('click',e=>{
    const target=e.target.closest?.('[data-signin-send],[data-signin-choice],[data-signin-check],[data-signin-done],[data-signin-chrome],[data-signin-mfa],[data-signin-reply],[data-signin-account],[data-signin-skip],[data-signin-eye]');if(!target||target.disabled)return;
    e.preventDefault();
    if(target.matches('[data-signin-eye]'))toggleEye(target);
    else if(target.dataset.signinAccount){const at=target.dataset.signinAccount.lastIndexOf('|');account(target.dataset.signinAccount.slice(0,at),target.dataset.signinAccount.slice(at+1)==='yes');}
    else if(target.dataset.signinSkip)skipStep(target.dataset.signinSkip);
    else if(target.dataset.signinSend)send(target.dataset.signinSend);
    else if(target.dataset.signinChoice){const at=target.dataset.signinChoice.lastIndexOf('|');choose(target.dataset.signinChoice.slice(0,at),target.dataset.signinChoice.slice(at+1));}
    else if(target.dataset.signinCheck)done(target.dataset.signinCheck,'check');
    else if(target.dataset.signinDone)done(target.dataset.signinDone,'done');
    else if(target.dataset.signinChrome)chrome(target.dataset.signinChrome);
    else if(target.dataset.signinMfa)acknowledge(target.dataset.signinMfa);
    else if(target.dataset.signinReply)document.getElementById('message-input')?.focus();
  });
  document.addEventListener('keydown',e=>{
    const input=e.target.closest?.('[data-signin-input]');if(!input||e.key!=='Enter'||e.isComposing)return;
    e.preventDefault();const holder=input.closest('[data-signin-holder]'),next=[...holder.querySelectorAll('[data-signin-input]')].find(i=>!i.value&&!i.closest('[hidden]'));
    if(next&&next!==input)next.focus();else send(holder.dataset.signinHolder);
  });
  document.addEventListener('change',e=>{
    const box=e.target.closest?.('[data-signin-remember]');if(box)remember.set(box.dataset.signinRemember,box.checked);
    // A service card's choices: kept for the next redraw.
    const holder=e.target.closest?.('[data-signin-holder].service-form');
    if(holder&&e.target.matches('[data-service-header],[data-service-charges]')){
      const now={...(serviceChoices.get(holder.dataset.signinHolder)||{})};
      if(e.target.matches('[data-service-header]'))now.header=e.target.value==='custom'?'custom':'Authorization';else now.charges=e.target.value==='yes';
      serviceChoices.set(holder.dataset.signinHolder,now);
    }
  });
  document.addEventListener('input',e=>{const input=e.target.closest?.('[data-signin-input]');if(!input)return;if(input.value)typing.set(input.dataset.signinInput,input);else typing.delete(input.dataset.signinInput);});
  document.addEventListener('focusin',e=>{if(e.target.closest?.('[data-signin-input]'))lastField=e.target;});
  new MutationObserver(records=>{
    if(!typing.size)return;
    for(const record of records)for(const node of record.addedNodes){
      if(node.nodeType!==1)continue;
      for(const fresh of node.matches('[data-signin-input]')?[node]:node.querySelectorAll('[data-signin-input]')){
        const kept=typing.get(fresh.dataset.signinInput);if(!kept||kept===fresh||kept.isConnected)continue;
        const focus=lastField===kept&&(document.activeElement===fresh||document.activeElement===document.body||!document.activeElement),start=kept.selectionStart,end=kept.selectionEnd;
        kept.disabled=fresh.disabled;fresh.replaceWith(kept);
        // A password shown with the eye stays shown, and its eye says so.
        const eye=kept.closest('.signin-secret')?.querySelector('[data-signin-eye]');if(eye&&kept.type==='text'){eye.setAttribute('aria-pressed','true');eye.setAttribute('aria-label','Hide password');}
        if(focus){kept.focus({preventScroll:true});try{kept.setSelectionRange(start,end);}catch{}}
      }
    }
  }).observe(document.body,{childList:true,subtree:true});
  // A Needs item for a sign-in opens the agent's chat at its request.
  document.addEventListener('click',e=>{
    const item=e.target.closest?.('[data-signin-open]');if(!item)return;
    const task=item.dataset.signinOpen,until=Date.now()+2500;
    // The drawer closes with a short animation, and the chat cannot take focus until it has gone.
    const reach=()=>{
      const app=document.getElementById('app');
      if((app?.inert||document.querySelector('.modal-overlay'))&&Date.now()<until)return setTimeout(reach,50);
      const at=[...document.querySelectorAll('[data-signin-task]')].filter(x=>x.dataset.signinTask===task).at(-1);if(!at)return;
      at.scrollIntoView({block:'center'});at.querySelector('input,button:not([disabled])')?.focus({preventScroll:true});
    };
    setTimeout(reach,30);
  });
  window.addEventListener('buddy-worker-snapshot',()=>{
    const snapshot=window.BuddyWorkerUI?.snapshot?.();if(!snapshot)return;
    if(sync(state,snapshot,pins,r=>window.BuddyDrop?.signin?.(state,r)))redraw();
    // A field being typed into for a request that has ended is let go, with what was typed in it.
    if(Array.isArray(snapshot.signinRequests)){const open=new Set(snapshot.signinRequests.map(r=>r?.key));for(const [id,input] of typing)if(!open.has(id.slice(0,id.lastIndexOf('|')))){input.value='';typing.delete(id);}}
  });
  // The open chat was drawn before this file loaded: draw its sign-in requests now.
  if(typeof ui!=='undefined'&&ui.view?.kind==='chat'&&typeof refreshLiveChat==='function')refreshLiveChat(ui.view.target);
})(typeof globalThis!=='undefined'?globalThis:this);

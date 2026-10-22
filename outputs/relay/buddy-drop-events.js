/* The desktop drop, Buddy's side. When something that is the person's own news reaches a chat (a background task they started has finished,
   a stage of the team plan is done) or something waits for their answer (an approval, a question, a sign-in or a step on a web page, a decision
   the supervisor passes on), the page asks the Mac app to show that agent at the top-left of the screen. The app shows it only while Buddy is in
   the background (buddy-drop.html draws it), and opens the chat when it is clicked.

   It is asked for from the three places that already decide a message is for the person: a task's result or request (buddy-worker.js), a plan
   notice (buddy-plan.js) and a sign-in or step request (buddy-signin.js), each once, when the message is first posted. What the supervisor
   handles (a command review routed to it, a question it answers, a plan task's result it reviews), routine check-ins, quiet checks and
   anything read late (an old outcome found after a restart) never make a drop. Settings › Desktop drop turns it off (`state.desktopDrop`). */
(function(root){
  'use strict';
  // An outcome older than this is not news: the page found it late (Buddy was closed, the worker restarted).
  const STALE=15*60*1000;
  const SHAPES=['diamond','sphere','hex','pill'],LEGACY_SHAPE={star:'diamond',pebble:'sphere',cube:'hex',clover:'pill'};
  const COLORS=['lilac','blue','peach','mint','red','gold','cobalt'],LEGACY_COLOR={rose:'red',stone:'cobalt'};
  const shapeOf=id=>{const s=LEGACY_SHAPE[id]||id;return SHAPES.includes(s)?s:'diamond';};
  const colorOf=id=>{const c=LEGACY_COLOR[id]||id;return COLORS.includes(c)?c:'lilac';};
  const load=(name,file)=>root[name]||(typeof module!=='undefined'&&typeof require==='function'?require(file):null);
  const worker=()=>load('BuddyWorkerUI','./buddy-worker.js'),signin=()=>load('BuddySignIn','./buddy-signin.js');
  // One plain line: no Markdown marks, no line breaks, shortened with an ellipsis.
  function short(text,n){const t=String(text??'').replace(/[*_`#>[\]|~\\]/g,'').replace(/\s+/g,' ').trim();return t.length>n?t.slice(0,n-1).trimEnd()+'…':t;}
  const host=origin=>{try{return new URL(origin).host||String(origin||'');}catch{return String(origin||'')||'a website';}};
  const fresh=(at,now)=>{const t=Date.parse(at||'');return !Number.isFinite(t)||now-t<=STALE;};
  const enabled=state=>state?.desktopDrop!==false;
  // The agent as the drop draws it: its name, figure and colour (older figure names read as today's).
  function look(state,id){const a=(state?.agents||[]).find(x=>x?.id===id);return a?{name:short(a.name||'Buddy',40)||'Buddy',shape:shapeOf(a.avatarShape),color:colorOf(a.avatarColor)}:null;}
  function make(state,{eventId,agentId,kind,text,chat}){
    const who=look(state,agentId);if(!who||!eventId||!chat||!['done','needs'].includes(kind))return null;
    return {eventId:String(eventId).slice(0,200),agentId,kind,text:short(text,64)||(kind==='done'?'Finished':'Needs you'),chat,...who};
  }
  // A task's result or request, as deliverResult (buddy-worker.js) posts it in the agent's chat.
  function forTask(state,t,now=Date.now()){
    const W=worker();if(!W||!t||t.workspace!==state?.conversationWorkspace||!W.deliverable(t)||!fresh(t.updatedAt,now))return null;
    const base={eventId:W.deliveryID(t),agentId:t.agentId,chat:t.agentId},title=short(t.title||'Background task',56);
    // Work the supervisor handed out (a plan's task, or one that reports to it) goes back to the supervisor; the stage report is the person's news.
    const handedOut=!!(t.planTaskId||t.reportsTo);
    if(t.status==='completed')return handedOut?null:make(state,{...base,kind:'done',text:title});
    if(t.status==='waiting_review'){
      // A command review routed to the supervisor is its to answer; a sign-in is asked in the chat as a request of its own.
      const r=W.pending(t).find(r=>r.route!=='supervisor'&&r.kind!=='authentication');if(!r)return null;
      const text=r.kind==='checkpoint'?'Check the work':r.kind==='coding'||typeof r.tool?.arguments?.command==='string'?'Approve a command':W.isApproval(r)?'Approve a step':'Answer a question';
      return make(state,{...base,kind:'needs',text});
    }
    if(t.status==='waiting_user'){
      // A question the supervisor answers, or a task set aside behind an approval already asked, is not a new ask.
      if(t.checkpoint?.routedTo==='supervisor'||t.stopCause==='review.parked')return null;
      return make(state,{...base,kind:'needs',text:/private|sign.?in/i.test(t.progress||'')||t.signInOrigin?`Sign in to ${host(t.signInOrigin)}`:'Answer a question'});
    }
    if(t.status==='failed'){
      // A stop being retried by itself needs nobody yet; one with a supervisor goes to the supervisor first, unless it is the provider account.
      if(handedOut||['pending','queued'].includes(t.recovery?.state)||t.supervisorId&&t.stopCause!=='provider.account')return null;
      return make(state,{...base,kind:'needs',text:`Couldn’t finish ${title}`});
    }
    // An interruption Buddy recovers from and a pause the system made are told in the chat, but they are not something finished or asked.
    return null;
  }
  // A notice the plan marks for the chat, as deliverNotices (buddy-plan.js) posts it: a stage report, or a question passed on to the person.
  function forNotice(state,item,now=Date.now()){
    const n=item?.notice,m=item?.message;if(!n||!m||!fresh(n.at,now))return null;
    const base={eventId:m.id,agentId:m.who,chat:item.target};
    if(n.kind==='stage_report'){
      const stage=(item.plan?.stages||[]).find(s=>s?.id===n.refs?.stageId)?.n||Number(String(n.text||'').match(/^\s*Stage\s+(\d+)\b/i)?.[1])||0;
      return make(state,{...base,kind:'done',text:stage?`Stage ${stage} is done`:'A stage is done'});
    }
    if(n.kind==='escalation')return make(state,{...base,kind:'needs',text:short(n.refs?.question||n.text,64)||'A decision for you'});
    if(n.kind==='stuck')return make(state,{...base,kind:'needs',text:'The team is stuck'});
    // "Stage 1 authorized" answers the person's own tap.
    return null;
  }
  // A sign-in, a step on a web page or a push on the phone, as sync (buddy-signin.js) first posts it in the agent's chat.
  function forSignin(state,r){
    const S=signin();if(!S||!r||typeof r.key!=='string'||!r.key)return null;
    return make(state,{eventId:'signin-'+r.key,agentId:r.agentId,chat:r.agentId,kind:'needs',text:S.title(r,look(state,r.agentId)?.name)});
  }
  // Each event at most once. A drop skipped while the setting is off is not remembered, and a refusal from the app never reaches the page.
  function createEmitter({send,enabled:on=()=>true,limit=500}={}){
    const seen=new Set();
    function emit(drop){
      if(!drop||!on()||seen.has(drop.eventId))return false;
      try{const sent=send?.(drop);if(sent&&typeof sent.catch==='function')sent.catch(()=>{});}catch{return false;}
      seen.add(drop.eventId);if(seen.size>limit)seen.delete(seen.values().next().value);
      return true;
    }
    return {emit,seen};
  }
  const api={forTask,forNotice,forSignin,createEmitter,enabled,look,STALE};
  root.BuddyDrop=api;if(typeof module!=='undefined')module.exports=api;
  if(typeof document==='undefined')return;

  // MARK: on the page
  const live=()=>typeof state!=='undefined'?state:null;
  const emitter=createEmitter({send:drop=>root.BuddyDesktop?.drop?.(drop),enabled:()=>enabled(live())});
  api.task=(s,t)=>emitter.emit(forTask(s,t));
  api.notice=(s,item)=>emitter.emit(forNotice(s,item));
  api.signin=(s,r)=>emitter.emit(forSignin(s,r));
  // The Mac app opens the chat a clicked holder was for. Only a chat that is here.
  api.open=chat=>{
    const s=live();if(!s||typeof chat!=='string'||!((s.agents||[]).some(a=>a.id===chat)||(s.groups||[]).some(g=>g.id===chat)))return false;
    if(document.querySelector('.modal')&&typeof closeModal==='function')closeModal();
    if(typeof navigate==='function')navigate('chat',chat);
    return true;
  };
  function setEnabled(on){
    const s=live();if(!s)return;
    s.desktopDrop=!!on;if(typeof save==='function')save();
    // Off also puts away whatever is on the screen now.
    if(!on){try{Promise.resolve(root.BuddyDesktop?.drop?.({clear:true})).catch(()=>{});}catch{}}
  }
  api.setEnabled=setEnabled;
  const section=()=>`<label class="settings-option desktop-drop-option"><div><strong>Desktop drop</strong><p>When an agent finishes or needs you while you’re in another app, a small Buddy appears at the top-left of your screen. Click it to open the chat.</p></div><input type="checkbox" data-desktop-drop-setting aria-label="Show the desktop drop" style="width:17px;height:17px;flex-shrink:0" ${enabled(live())?'checked':''}></label>`;
  // Settings is drawn by app.js; the row goes under Appearance. Only the Mac app can show a drop.
  if(typeof root.settings==='function'){
    const original=root.settings;
    root.settings=function(){
      const result=original.apply(this,arguments);
      const after=root.BuddyDesktop&&document.querySelector('#modal-root .appearance-settings');
      if(after&&!document.querySelector('[data-desktop-drop-setting]'))after.insertAdjacentHTML('afterend',section());
      return result;
    };
  }
  document.addEventListener('change',e=>{const box=e.target.closest?.('[data-desktop-drop-setting]');if(box)setEnabled(box.checked);});
})(typeof globalThis!=='undefined'?globalThis:this);

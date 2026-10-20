(function(root){
  'use strict';
  const busy = status => ['starting','answering','stopping'].includes(status);
  const uid = () => globalThis.crypto.randomUUID();
  function migrate(state){
    state.conversationWorkspace ||= uid(); state.runs ||= {};
    return state;
  }
  function active(state,target){ return Object.values(state.runs||{}).find(r=>r.target===target&&busy(r.status)); }
  function begin(state,target,{retryOf,runId=uid(),userId=uid(),replyId=uid(),time=new Date().toLocaleTimeString([], {hour:'2-digit',minute:'2-digit'})}={}){
    migrate(state);
    if(active(state,target))throw Error('This chat is already answering.');
    const agent=state.agents.find(a=>a.id===target);
    const group=(state.groups||[]).find(g=>g.id===target);
    if(!agent&&!group)throw Error('This chat is no longer available.');
    const members=group?.members.map(id=>state.agents.find(a=>a.id===id));
    if(group&&(!members.length||members.length>16||members.some(a=>!a)||new Set(group.members).size!==group.members.length))throw Error('Edit this group to choose between 1 and 16 available agents.');
    const previous=retryOf&&state.runs[retryOf];
    if(retryOf&&(!previous||previous.target!==target||!(['failed','stopped'].includes(previous.status)||previous.status==='completed'&&previous.team?.partial)))throw Error('That reply cannot be retried.');
    const text=(previous?.text??state.drafts[target]??'').trim();
    if(!text)throw Error('Write a message first.');
    if(text.length>30000)throw Error('Keep messages under 30,000 characters.');
    if(!retryOf&&state.attachments[target]?.length)throw Error('Remove the attachment, then choose a shared file from the folder button in the Mac app.');
    state.messages[target] ||= [];
    if(previous)userId=previous.userId;
    else state.messages[target].push({id:userId,who:'you',body:text,time,createdAt:new Date().toISOString(),live:true});
    const team=group?{phase:'planning',leadId:'',entries:[],memberIds:[...group.members],partial:false}:undefined;
    state.messages[target].push({id:replyId,who:target,body:'',time,live:true,runId,status:'starting',...(team?{team}: {})});
    const run={runId,target,key:`${state.conversationWorkspace}:${target}`,userId,replyId,text,createdAt:new Date().toISOString(),status:'starting',...(team?{team,memberIds:[...group.members]}: {})};
    state.runs[runId]=run;
    if(!previous)state.drafts[target]='';
    return {run,payload:group?{kind:'group',runId,key:run.key,text,groupId:target}:{runId,key:run.key,text,agentId:target,agent:{name:agent.name,role:agent.role,description:agent.description}}};
  }
  // A group request that agents answered for themselves has no reply of its own to show: their messages are the reply. (The run keeps them joined
  // in `body`, which history and search read.) What can still belong to the reply bubble is shown, and a failure keeps its retry.
  function agentsAnswered(state,message){
    const team=state.runs?.[message.runId]?.team||message.team;
    return !!team&&message.status==='completed'&&team.direct!==true&&Array.isArray(team.entries)&&team.entries.some(e=>e.status==='completed'&&String(e.notes||'').trim());
  }
  function presentation(state,message){
    if(agentsAnswered(state,message)){
      const team=state.runs?.[message.runId]?.team||message.team;
      if(team.partial)return {body:'Some of the work couldn’t finish. You can retry the request.'};
      const cards=typeof window!=='undefined'&&window.BuddyActions?.cards?String(window.BuddyActions.cards(message.runId)||''):'';
      return message.files?.length||message.proposalIds?.length||message.teamPlanIds?.length||message.routines?.length||message.coverage?.length||cards?{body:'Saved from this request:'}:{hidden:true};
    }
    const run=state.runs?.[message.runId],body=String(message.body||'');
    if(!body||message.setup||run&&/\b(?:explain|details|detail|why|breakdown|report|full|thorough)\b/i.test(run.text||''))return {body};
    const operational=message.teamPlanIds?.length||message.proposalIds?.length||message.routines?.length||message.workerTaskID;
    if(!operational||body.length<=360)return {body};
    const paragraph=body.trim().split(/\n\s*\n/)[0];let short='',remaining=paragraph;
    for(let i=0;i<2&&remaining;i++){const end=remaining.search(/[.!?](?=\s|$)/),sentence=end<0?remaining:remaining.slice(0,end+1);if((short+' '+sentence).trim().length>360)break;short=(short+' '+sentence).trim();remaining=end<0?'':remaining.slice(end+1).trimStart();}
    short=short.trim();if(!short)short=paragraph.slice(0,320).replace(/\s+\S*$/,'')+'…';
    return {body:short,details:body};
  }
  function apply(state,event){
    if(event.type==='routine'){
      const run=state.runs?.[event.runId],r=event.routine;
      const actor=event.delegatedBy,delegated=actor&&(actor===run?.target||run?.memberIds?.includes(actor))&&state.agents.some(a=>a.id===actor);
      if(!run||!r||typeof r.id!=='string'||r.workspace!==state.conversationWorkspace||!state.agents.some(a=>a.id===r.agentId)||r.agentId!==run.target&&!delegated||typeof r.nextRun!=='string')return false;
      run.routines||=[];const i=run.routines.findIndex(v=>v.id===r.id);if(i<0)run.routines.push(structuredClone(r));else run.routines[i]=structuredClone(r);
      const message=(state.messages[run.target]||[]).find(m=>m.id===run.replyId);if(message)message.routines=structuredClone(run.routines);return true;
    }
    // A tool finishing is progress inside a reply, not the reply finishing.
    if(event.type&&event.type!=='run')return false;
    const run=state.runs?.[event.runId];
    if(!run||event.key&&event.key!==run.key)return false;
    // Late stream events cannot reopen a completed or stopped reply.
    if(!busy(run.status))return false;
    if(!['starting','answering','stopping','completed','failed','stopped'].includes(event.status))return false;
    let team;
    if(run.memberIds&&event.team&&typeof event.team==='object') {
      team=structuredClone(event.team);
      if(team.leadId&&!run.memberIds.includes(team.leadId))return false;
      team.entries=(Array.isArray(team.entries)?team.entries:[]).filter(e=>run.memberIds.includes(e.agentId)).slice(0,6);
    }
    const message=(state.messages[run.target]||[]).find(m=>m.id===run.replyId);
    const body=typeof event.text==='string'?event.text:message?.body||'';
    const empty=event.status==='completed'&&!body.trim()&&!(event.files?.length||message?.files?.length||message?.proposalIds?.length||message?.teamPlanIds?.length||message?.routines?.length);
    const status=empty?'failed':event.status,error=empty?'No answer came back. Try again.':event.error||'';
    run.status=status;run.error=error;run.updatedAt=new Date().toISOString();
    if(team)run.team=team;
    if(Array.isArray(event.files))run.files=structuredClone(event.files.filter(f=>f&&typeof f.path==='string'&&typeof f.folderId==='string'&&typeof f.revision==='string').slice(0,180));
    if(typeof event.provider==='string')run.provider=event.provider;if(typeof event.model==='string')run.model=event.model;
    if(Array.isArray(event.coverage))run.coverage=structuredClone(event.coverage.filter(c=>c&&typeof c.id==='string'&&typeof c.query==='string'&&typeof c.partial==='boolean'&&Number.isInteger(c.read)&&Number.isInteger(c.unread)).slice(-10));
    if(message){if(run.provider)message.provider=run.provider;if(run.model)message.model=run.model;if(run.coverage)message.coverage=structuredClone(run.coverage);message.status=status;if(typeof event.text==='string')message.body=event.text;message.error=error;if(run.team)message.team=structuredClone(run.team);if(run.files)message.files=structuredClone(run.files);}
    return true;
  }
  function recover(state,snapshots=[]){
    for(const run of Object.values(state.runs||{})){
      const message=(state.messages[run.target]||[]).find(m=>m.id===run.replyId);
      if(run.status==='completed'&&message&&!message.body?.trim()&&!message.files?.length&&!message.proposalIds?.length&&!message.teamPlanIds?.length){
        run.status=message.status='failed';run.error=message.error='This reply finished without an answer. Try again.';
      }
      if(!busy(run.status))continue;
      const snapshot=snapshots.find(s=>s.runId===run.runId);
      apply(state,snapshot||{runId:run.runId,status:'failed',error:'This reply was interrupted when Buddy closed. You can retry it.'});
    }
  }
  const api={busy,migrate,active,begin,apply,recover,presentation};
  if(typeof module!=='undefined')module.exports=api;root.BuddyChat=api;
})(typeof globalThis!=='undefined'?globalThis:this);

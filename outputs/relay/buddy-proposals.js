(function(root){
  'use strict';
  function merge(workspace,records){
    let changed=false;workspace.proposals ||= [];
    for(const record of records){
      if(!record||record.native!==true||record.workspace!==workspace.conversationWorkspace||!['pending','approved','declined'].includes(record.status)||typeof record.id!=='string'||typeof record.runId!=='string'||!record.draft)continue;
      const value=structuredClone(record),index=workspace.proposals.findIndex(p=>p.id===value.id);
      if(index>=0&&workspace.proposals[index].status!=='pending'&&value.status==='pending')continue;
      if(index<0){workspace.proposals.push(value);changed=true;}else if((workspace.proposals[index].revision||0)<=(value.revision||0)&&JSON.stringify(workspace.proposals[index])!==JSON.stringify(value)){workspace.proposals[index]=value;changed=true;}
      const message=(workspace.messages[value.chat]||[]).find(m=>m.live&&m.runId===value.runId);
      if(message){message.proposalIds ||= [];if(!message.proposalIds.includes(value.id)){message.proposalIds.push(value.id);changed=true;}}
    }
    return changed;
  }
  function addApproved(workspace,result){
    const proposal=result.proposal,agent=result.agent;
    if(!proposal||proposal.native!==true||proposal.status!=='approved'||proposal.workspace!==workspace.conversationWorkspace||!agent||agent.id!==proposal.agentId||agent.sourceProposalId!==proposal.id)throw Error('Buddy couldn’t verify the saved agent. Reopen suggestions and try again.');
    merge(workspace,[proposal]);
    if(!workspace.agents.some(a=>a.id===agent.id))workspace.agents.push(structuredClone(agent));
    workspace.messages[agent.id] ||= [];
    for(const group of workspace.groups)if((proposal.approved?.groupIds||[]).includes(group.id)&&!group.members.includes(agent.id))group.members.push(agent.id);
    return agent;
  }
  const api={merge,addApproved};root.BuddyProposals=api;if(typeof module!=='undefined')module.exports=api;
  if(typeof document==='undefined')return;
  let error='',loading=false;
  function refreshView(){
    const body=document.getElementById('chat-body'),top=body?.scrollTop||0;
    const atEnd=body&&body.scrollHeight-top-body.clientHeight<120;
    const focused=document.activeElement,focusId=focused?.id,start=focused?.selectionStart,end=focused?.selectionEnd;
    render();
    const next=document.getElementById('chat-body');if(next)next.scrollTop=atEnd?next.scrollHeight:top;
    const control=focusId&&document.getElementById(focusId);if(control){control.focus({preventScroll:true});if(typeof start==='number')control.setSelectionRange(start,end);}
  }
  async function refresh(){
    if(!window.BuddyDesktop?.agentProposals)return;
    loading=true;error='';
    try{await persistenceQueue.catch(()=>{});const result=await window.BuddyDesktop.agentProposals();if(merge(state,result.proposals||[])){save();refreshView();}}
    catch(reason){error=String(reason.message||reason);}
    finally{loading=false;}
  }
  async function decide(proposal,action,config){
    await persistenceQueue.catch(()=>{});
    const result=await window.BuddyDesktop.reviewAgentProposal({proposalId:proposal.id,revision:proposal.revision,action,config});
    if(action==='approve')addApproved(state,result);else merge(state,[result.proposal]);
    save();return result;
  }
  window.addEventListener('buddy-conversation',event=>{
    if(event.detail?.type!=='proposal'||!event.detail.proposal)return;
    if(merge(state,[event.detail.proposal])){save();refreshView();}
  });
  Object.assign(api,{refresh,decide,getError:()=>error,isLoading:()=>loading,boot:()=>{if(window.BuddyDesktop?.agentProposals)refresh();}});
})(typeof globalThis!=='undefined'?globalThis:this);

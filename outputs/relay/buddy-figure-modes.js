/* Turns real workspace state into figure modes: a reply starting is "planning", streaming is "working", an action
   waiting on the user is "needs", a finished reply is "done" (then "ready"), a failed one is "stuck". Group runs add
   gaze toward the lead or the working member and a hand-off whenever the work moves between members. */
(function(root){
  'use strict';
  const busy=status=>['starting','answering','stopping'].includes(status);
  const RANK={planning:1,working:2,needs:3};

  // What every agent should look like right now. Pure: reads state, changes nothing.
  function snapshot(state,{pending=()=>[],setup=()=>null,checking=()=>false}={}){
    const modes={},focus={},work={},agents=new Set((state.agents||[]).map(a=>a.id));
    const set=(id,mode)=>{if(agents.has(id)&&(RANK[mode]||0)>(RANK[modes[id]]||0))modes[id]=mode;};
    const look=(ids,to,group)=>{for(const id of ids)if(agents.has(id)&&!focus[id])focus[id]={to,group};};
    for(const a of state.agents||[]){
      if(setup(state,a.id)||checking(a.id))set(a.id,'working');
    }
    for(const run of Object.values(state.runs||{})){
      if(!busy(run.status))continue;
      const group=(state.groups||[]).find(g=>g.id===run.target);
      for(const review of pending(state,run.runId)||[]){
        if(agents.has(review.agentId)){set(review.agentId,'needs');focus[review.agentId]={to:'user'};}
      }
      if(!group){
        set(run.target,run.status==='starting'?'planning':'working');
        continue;
      }
      const members=(run.memberIds||group.members).filter(id=>agents.has(id)),team=run.team||{};
      const lead=members.includes(team.leadId)?team.leadId:members[0];
      if(!lead)continue;
      if(!team.phase||team.phase==='planning'){
        set(lead,'planning');look(members.filter(id=>id!==lead),lead,group.id);
      }else if(team.phase==='replying'){
        set(lead,'working');look(members.filter(id=>id!==lead),lead,group.id);
      }else{
        const entries=Array.isArray(team.entries)?team.entries:[];
        const working=entries.find(e=>e.status==='working'&&members.includes(e.agentId));
        for(const e of entries){
          if(!members.includes(e.agentId))continue;
          if(e.status==='working')set(e.agentId,'working');
          else if(e.status==='review'){set(e.agentId,'needs');focus[e.agentId]={to:'user'};}
        }
        if(working){work[group.id]=working.agentId;look(members.filter(id=>id!==working.agentId),working.agentId,group.id);}
      }
    }
    return {modes,focus,work};
  }

  // Remembers the previous snapshot so it can see a run finishing (done / stuck) and the work moving (hand-off).
  function tracker(sink,{later=(ms,fn)=>setTimeout(fn,ms)}={}){
    let prevRuns=null,prevModes={},prevWork={};
    function update(state,helpers){
      const snap=snapshot(state,helpers),runs={},outcome={};
      for(const run of Object.values(state.runs||{}))runs[run.runId]=run;
      if(prevRuns){
        for(const run of Object.values(runs)){
          const was=prevRuns[run.runId];
          if(!was||!busy(was.status)||busy(run.status))continue;
          const group=(state.groups||[]).find(g=>g.id===run.target);
          const members=group?(run.memberIds||group.members):[run.target];
          const lead=group&&members.includes(run.team?.leadId)?run.team.leadId:members[0];
          if(run.status==='completed')[lead,...members.filter(id=>id!==lead)].forEach((id,k)=>{outcome[id]={mode:'done',delay:k*160};});
          else if(run.status==='failed')outcome[lead]={mode:'stuck',delay:0};
        }
      }
      for(const id of new Set([...Object.keys(snap.modes),...Object.keys(prevModes),...Object.keys(outcome)])){
        const want=snap.modes[id],end=outcome[id];
        if(want){if(sink.getMode(id)!==want)sink.setMode(id,want);}
        else if(end){
          const apply=()=>{sink.setFocus(id,null);sink.setMode(id,end.mode);};
          if(end.delay)later(end.delay,apply);else apply();
        }else if(prevModes[id]&&sink.getMode(id)===prevModes[id])sink.setMode(id,'ready');
      }
      for(const a of state.agents||[]){
        const f=snap.focus[a.id];
        sink.setFocus(a.id,f?.to||null,f?.group);
      }
      for(const gid of new Set([...Object.keys(snap.work),...Object.keys(prevWork)])){
        sink.setGroupWork(gid,snap.work[gid]||null);
        if(snap.work[gid]&&prevWork[gid]&&snap.work[gid]!==prevWork[gid])sink.handoff(prevWork[gid],snap.work[gid]);
      }
      prevRuns=Object.fromEntries(Object.entries(runs).map(([id,r])=>[id,{status:r.status}]));
      prevModes=snap.modes;prevWork=snap.work;
    }
    return {update};
  }

  let shared=null;
  function sync(state){
    if(!root.BuddyFigures||!state)return;
    shared||=tracker(root.BuddyFigures);
    shared.update(state,{
      pending:(s,runId)=>root.BuddyActions?.pending?.(s,runId)||[],
      setup:(s,id)=>root.BuddyAgentSetup?.active?.(s,id)||null,
      checking:id=>!!root.BuddyTeamMonitorUI?.isChecking?.(id)
    });
  }
  const api={snapshot,tracker,sync};
  if(typeof module!=='undefined'&&module.exports)module.exports=api;
  root.BuddyFigureModes=api;
})(typeof globalThis!=='undefined'?globalThis:this);

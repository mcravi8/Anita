/* Buddy interface with native conversations and per-agent service connections with in-chat action review. */
'use strict';
const STORAGE_KEY = 'relay.frontend.v1';
const buddyLogo = (compact=false) => `<img class="buddy-logo${compact?' compact':''}" src="assets/buddy-logo.svg" alt="" width="40" height="40" draggable="false">`;
const shapes = {
  plus:'<path d="M12 5v14M5 12h14"/>',
  close:'<path d="m6 6 12 12M18 6 6 18"/>',
  chevron:'<path d="m9 5 7 7-7 7"/>',
  down:'<path d="m7 10 5 5 5-5"/>',
  arrow:'<path d="M5 12h14m-5-5 5 5-5 5"/>',
  up:'<path d="M12 19V5m-5 5 5-5 5 5"/>',
  inbox:'<path d="M4 5h16v14H4zM4 13h4l2 3h4l2-3h4"/>',
  chat:'<path d="M20 11a8 8 0 0 1-8 8H4v-7a8 8 0 1 1 16-1Z"/>',
  tasks:'<rect x="4" y="3" width="16" height="18" rx="3"/><path d="m8 10 2 2 5-5M8 16h8"/>',
  file:'<path d="M14 3H6a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V9zM14 3v6h6M8 13h8M8 17h5"/>',
  folder:'<path d="M3 7V5a2 2 0 0 1 2-2h5l3 3h6a2 2 0 0 1 2 2v11H3Z"/>',
  monitor:'<rect x="3" y="4" width="18" height="13" rx="2"/><path d="M8 21h8M12 17v4"/>',
  grid:'<rect x="3" y="3" width="7" height="7" rx="1.5"/><rect x="14" y="3" width="7" height="7" rx="1.5"/><rect x="3" y="14" width="7" height="7" rx="1.5"/><rect x="14" y="14" width="7" height="7" rx="1.5"/>',
  settings:'<path d="M9.245 5.348L10.258 5.014L10.385 2.841L13.615 2.841L13.742 5.014L14.755 5.348L15.708 5.828L17.334 4.382L19.618 6.666L18.172 8.292L18.652 9.245L18.986 10.258L21.159 10.385L21.159 13.615L18.986 13.742L18.652 14.755L18.172 15.708L19.618 17.334L17.334 19.618L15.708 18.172L14.755 18.652L13.742 18.986L13.615 21.159L10.385 21.159L10.258 18.986L9.245 18.652L8.292 18.172L6.666 19.618L4.382 17.334L5.828 15.708L5.348 14.755L5.014 13.742L2.841 13.615L2.841 10.385L5.014 10.258L5.348 9.245L5.828 8.292L4.382 6.666L6.666 4.382L8.292 5.828Z"/><circle cx="12" cy="12" r="3"/>',
  search:'<circle cx="10.5" cy="10.5" r="6.5"/><path d="m16 16 5 5"/>',
  people:'<path d="M3 20v-2a5 5 0 0 1 5-5h2a5 5 0 0 1 5 5v2M17 13a4 4 0 0 1 4 4v3"/><circle cx="9" cy="6" r="4"/><path d="M17 2a4 4 0 0 1 0 8"/>',
  flag:'<path d="M5 21V4c4-3 8 3 14 0v10c-6 3-10-3-14 0"/>',
  check:'<path d="m5 12 4 4L19 6"/>',
  clock:'<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
  handoff:'<path d="M4 8h14m-4-4 4 4-4 4M20 16H6m4-4-4 4 4 4"/>',
  paperclip:'<path d="m8 13 6-6a3 3 0 0 1 4 4l-8 8a5 5 0 0 1-7-7l9-9a6 6 0 0 1 9 9l-8 8"/>',
  at:'<circle cx="12" cy="12" r="4"/><path d="M16 8v6a2 2 0 0 0 4 0v-2a8 8 0 1 0-3 6"/>',
  globe:'<circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3a16 16 0 0 1 0 18 16 16 0 0 1 0-18Z"/>',
  info:'<circle cx="12" cy="12" r="9"/><path d="M12 11v6M12 7h.01"/>',
  more:'<circle cx="5" cy="12" r="1"/><circle cx="12" cy="12" r="1"/><circle cx="19" cy="12" r="1"/>',
  panel:'<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M15 4v16"/>',
  menu:'<path d="M4 6h16M4 12h16M4 18h16"/>',
  spark:'<path d="m12 3 2.5 6.5L21 12l-6.5 2.5L12 21l-2.5-6.5L3 12l6.5-2.5Z"/>',
  compass:'<circle cx="12" cy="12" r="8.5"/><path d="m16 8-2 6-6 2 2-6Z"/>',
  prism:'<path d="m12 3 9 15H3ZM12 3v15M3 18l9-5 9 5"/>',
  clover:'<path d="M12 12C2 13 2 3 7 3c4 0 5 5 5 9Zm0 0c-1-10 9-10 9-5 0 4-5 5-9 5Zm0 0c10-1 10 9 5 9-4 0-5-5-5-9Zm0 0c1 10-9 10-9 5 0-4 5-5 9-5Z"/>',
  logo:'<path d="M4 6c0-2 2-4 4-4h5v7H9a5 5 0 0 0-5 5Z" fill="currentColor" stroke="none"/><path d="M20 18c0 2-2 4-4 4h-5v-7h4a5 5 0 0 0 5-5Z" fill="currentColor" stroke="none"/>',
  download:'<path d="M12 3v12m-5-5 5 5 5-5M4 16v5h16v-5"/>',
  pause:'<path d="M8 5v14M16 5v14"/>'
};
const icon = (name, cls='icon') => `<svg class="${cls}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${shapes[name]||shapes.spark}</svg>`;
const esc = value => String(value ?? '').replace(/[&<>"']/g, char => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[char]));
const id = () => globalThis.crypto?.randomUUID?.() || `${Date.now()}-${Math.random().toString(36).slice(2)}`;
const seed = () => RelayTeam.migrate(addDirectSamples({
  version:1,
  agents:[
    {id:'morgan',name:'Morgan',role:'Chief of staff',description:'Keeps the big picture in view. Turns your requests into a plan and brings the right bots together.',symbol:'spark',color:'morgan',status:'Coordinating the launch'},
    {id:'atlas',name:'Atlas',role:'Researcher',description:'Finds useful sources, spots patterns, and turns a wide search into a clear brief.',symbol:'compass',color:'atlas',status:'Research ready'},
    {id:'nova',name:'Nova',role:'Builder',description:'Turns ideas into working drafts. Builds, edits, and keeps the details moving.',symbol:'prism',color:'nova',status:'Draft ready for review'},
    {id:'scout',name:'Scout',role:'Reviewer',description:'A fresh pair of eyes. Checks the work, questions assumptions, and catches the little things.',symbol:'clover',color:'scout',status:'Reviewing the homepage'}
  ],
  groups:[
    {id:'launch',name:'Website launch',description:'A considered portfolio, ready to share.',members:['morgan','atlas','nova','scout'],objective:'Build a portfolio that feels like me. Keep it simple, thoughtful, and easy to explore.'},
    {id:'all',name:'All hands',description:'The whole team, in one conversation.',members:['morgan','atlas','nova','scout'],objective:'A place to think together and decide what comes next.'}
  ],
  tasks:[
    {id:'research',title:'Find a visual direction',description:'Compare three portfolio references. Look for clear typography, thoughtful spacing, and a simple project flow.',agent:'atlas',group:'launch',state:'done'},
    {id:'homepage',title:'Build the first homepage',description:'Use the brief and visual direction to create a first homepage draft. Keep project details easy to scan.',agent:'nova',group:'launch',state:'review',file:'homepage'},
    {id:'review',title:'Review the homepage',description:'Check the draft against the brief. Review small screens, readability, and whether the project links make sense.',agent:'scout',group:'launch',state:'queued',file:'homepage'}
  ],
  files:[
    {id:'homepage',name:'homepage.html',type:'HTML',owner:'nova',size:'4.2 KB',updated:'Sample · 10:24',content:'<!doctype html>\n<html lang="en">\n  <head><title>A considered portfolio</title></head>\n  <body>\n    <h1>Thoughtful work.\n        Made for real life.</h1>\n    <p>I design useful things for people and the places they live.</p>\n    <a href="#work">Explore selected work</a>\n  </body>\n</html>',revision:1},
    {id:'brief',name:'project-brief.md',type:'Markdown',owner:'morgan',size:'1.1 KB',updated:'Sample · 10:16',content:'# Website launch\n\nBuild a personal portfolio that feels simple, thoughtful, and easy to explore.\n\n## What matters\n- Clear, warm typography\n- Room for the work to breathe\n- Easy navigation on phones and desktops\n- Three selected projects\n\n## Team\nMorgan coordinates. Atlas researches. Nova builds. Scout reviews.\n\n## Finish line\nA homepage draft that is ready for your review.',revision:1},
    {id:'references',name:'visual-references.md',type:'Markdown',owner:'atlas',size:'2.8 KB',updated:'Sample · 10:21',content:'# Visual direction\n\nSample research brief for this frontend preview.\n\n## Direction\nA restrained editorial portfolio. Use a warm neutral background, confident serif headlines, and a simple sans serif for navigation.\n\n## Patterns to try\n1. A short introduction with one clear project link.\n2. A spacious grid of selected work.\n3. A simple footer with contact details.\n\nNo web research was performed by this frontend.',revision:1}
  ],
  messages:{
    launch:[
      {id:'m1',who:'you',body:'Let’s get my portfolio ready to share. Something clean and thoughtful, with a little personality. Can you all work on it together?',time:'10:14'},
      {id:'m2',who:'morgan',body:'Absolutely. I’ll keep everyone aligned and bring the finished draft back to you. Here’s how we’ll split it up:',time:'10:15',assignments:['research','homepage','review']},
      {id:'m3',who:'atlas',body:'I’ve pulled together a visual direction: warm neutrals, generous spacing, and a confident serif headline. The work should be the main event.',time:'10:21',sources:true},
      {id:'m4',kind:'handoff',from:'atlas',to:'nova',body:'Shared the visual direction with Nova'},
      {id:'m5',who:'nova',body:'The first homepage is ready. I kept the layout quiet and gave the introduction a little more character. The draft is in our shared workspace.',time:'10:24',file:'homepage'},
      {id:'m6',who:'scout',body:'I’ll take it from here. I’m checking the mobile layout, readability, and the path from the introduction to your projects.',time:'10:25',callout:'Ready for a review handoff. You can assign the homepage review directly from the task card.'}
    ],
    all:[],morgan:[],atlas:[],nova:[],scout:[]
  },drafts:{},attachments:{},lastView:{kind:'chat',target:'morgan'},filter:'all'
}));
function addDirectSamples(data) {
  if(data.messagingRevision===2)return data;
  const samples={
    morgan:[
      {id:'dm-sample-m1',who:'you',body:'Can you help me get my portfolio ready to share?',time:'10:14'},
      {id:'dm-sample-m2',who:'morgan',body:'Of course. I brought Atlas, Nova, and Scout into a group so we can work on it together.',time:'10:15',group:'launch'},
      {id:'dm-sample-m3',who:'morgan',body:'Atlas found a direction. Nova is building the first draft, and Scout will give it a second look.',time:'10:22',assignments:['research','homepage','review']},
      {id:'dm-sample-m4',who:'you',body:'Perfect. Keep it simple and give the work room to breathe.',time:'10:23'},
      {id:'dm-sample-m5',who:'morgan',body:'The first draft is ready. Have a look when you’ve got a moment.',time:'10:26',file:'homepage'}
    ],
    atlas:[
      {id:'dm-sample-a1',who:'you',body:'Any thoughts on the visual direction?',time:'10:18'},
      {id:'dm-sample-a2',who:'atlas',body:'Warm neutrals, plenty of space, and a clear introduction. Let the projects do the talking.',time:'10:21',sources:true}
    ],
    nova:[
      {id:'dm-sample-n1',who:'you',body:'Let’s start with a simple homepage.',time:'10:19'},
      {id:'dm-sample-n2',who:'nova',body:'First draft is ready for you. I kept the layout quiet and gave the work room to breathe.',time:'10:24',file:'homepage'}
    ],
    scout:[
      {id:'dm-sample-s1',who:'you',body:'Could you give the homepage a fresh pair of eyes?',time:'10:24'},
      {id:'dm-sample-s2',who:'scout',body:'I’ll check the phone layout, readability, and project links. You’ll find the review task in our shared workspace.',time:'10:25'}
    ]
  };
  for(const [key,messages] of Object.entries(samples))if(data.agents.some(a=>a.id===key)&&!(data.messages[key]?.length))data.messages[key]=messages;
  data.messagingRevision=2;
  if(data.lastView?.kind==='overview'||data.lastView?.target==='launch')data.lastView={kind:'chat',target:data.agents.some(a=>a.id==='morgan')?'morgan':data.agents[0]?.id};
  return data;
}
let storageAvailable=true,workspaceReadError='';
function load(){try{const raw=window.BuddyDesktop?window.BuddyDesktop.initialState:localStorage.getItem(STORAGE_KEY);if(raw){const parsed=JSON.parse(raw);if(parsed.version===1 && Array.isArray(parsed.agents) && Array.isArray(parsed.groups) && parsed.messages && parsed.drafts && Array.isArray(parsed.files)) return parsed;throw Error('Invalid workspace');}}catch{storageAvailable=false;workspaceReadError='Buddy couldn’t read your saved workspace. Reopen the app before continuing.';}return BuddyOnboarding.blank();}
let state=BuddyOnboarding.migrate(BuddyChat.migrate(RelayTeam.migrate(addDirectSamples(load()))));
const providerName=()=>chatConnection.provider==='claude'?'Claude':'ChatGPT';
let chatConnection={provider:'chatgpt',checking:!!window.BuddyDesktop?.connectionStatus,connected:false,error:''};
let ui={view:state.lastView||{kind:'chat',target:'morgan'},mobile:false,chatFilter:'',fileFilter:'',taskFilter:'__all__',lastChat:state.lastView?.kind==='chat'?state.lastView.target:'morgan'};
let modalReturnFocus=null, toastTimer=null;
function replyErrorText(message){
  return /selected model is at capacity/i.test(String(message))?'OpenAI is busy with this model. Your message is saved. Try again shortly.':String(message);
}
function showToast(message){
  const toast=document.getElementById('toast');if(!toast)return;
  clearTimeout(toastTimer);toast.textContent=String(message||'');toast.classList.add('show');
  toastTimer=setTimeout(()=>toast.classList.remove('show'),3500);
}
const findAgent = agentId => state.agents.find(a=>a.id===agentId);
const findGroup = groupId => state.groups.find(g=>g.id===groupId);
const findTask = taskId => state.tasks.find(t=>t.id===taskId);
const findFile = fileId => state.files.find(f=>f.id===fileId);
const avatarAssets={morgan:'assets/morgan-3d.png',atlas:'assets/atlas-3d.png',nova:'assets/nova-3d.png',scout:'assets/scout-3d.png'};
function avatarFilter(shapeId,colorId) {
  return RelayTeam.avatarFilter(shapeId,colorId);
}
document.body.insertAdjacentHTML('beforeend',RelayTeam.avatarFilterMarkup());
function configuredAvatar(value,small=false,title='') {
  const c=RelayTeam.appearance(value),shape=RelayTeam.shapeOptions.find(s=>s.id===c.avatarShape);
  return `<span class="avatar ${small?'small':''}" ${title?`title="${esc(title)}"`:''}><img src="${avatarAssets[shape.asset]}" style="filter:${avatarFilter(c.avatarShape,c.avatarColor)}" alt="" width="48" height="48" draggable="false"></span>`;
}
function thinkingAvatar(value,small=false){
  return `<span class="agent-thinking ${small?'small':''}" role="status" aria-label="${esc(value?.name||'Your team')} is working">${configuredAvatar(value||{},small)}<span class="agent-thoughts" aria-hidden="true"><i></i><i></i><i></i></span></span>`;
}
function agentIsThinking(target){const run=BuddyChat.active(state,target)||BuddyAgentSetup.active(state,target);return (!!run&&!window.BuddyActions?.pending(state,run.runId)?.length)||!!window.BuddyTeamMonitorUI?.isChecking(target);}
const avatar=(agentId,small=false)=>{const a=findAgent(agentId);return a?configuredAvatar(a,small,a.name):`<span class="avatar user ${small?'small':''}">Y</span>`;};
function avatarPicker(value={}) {
  const c=RelayTeam.config(value);
  return `<div class="config-preview"><span id="config-avatar-preview">${configuredAvatar(c)}</span><span><strong id="config-preview-name">${esc(c.name||'Your new agent')}</strong><small>One shape. Any personality.</small></span></div><fieldset class="appearance-field"><legend>Shape</legend><div class="shape-picker">${RelayTeam.shapeOptions.map(s=>`<label class="shape-choice"><input type="radio" name="avatar-shape" value="${s.id}" ${c.avatarShape===s.id?'checked':''} aria-label="${s.name} shape"><span><img data-shape-preview="${s.id}" src="${avatarAssets[s.asset]}" style="filter:${avatarFilter(s.id,c.avatarColor)}" alt=""><small>${s.name}</small></span></label>`).join('')}</div></fieldset><fieldset class="appearance-field color-field"><legend>Color</legend><div class="color-picker">${RelayTeam.colorOptions.map(color=>`<label class="color-choice" title="${color.name}"><input type="radio" name="avatar-color" value="${color.id}" ${c.avatarColor===color.id?'checked':''} aria-label="${color.name} color"><span style="--swatch:${color.swatch};--swatch-ink:${color.ink||'#323440'}">${icon('check')}</span></label>`).join('')}</div></fieldset>`;
}
function configFields(value,prefix,{groups=false}={}) {
  const c=RelayTeam.config(value);
  return `${avatarPicker(c)}<div class="config-basic-fields"><div class="field"><label for="${prefix}-name">Name</label><input id="${prefix}-name" value="${esc(c.name)}" placeholder="e.g. Sage" maxlength="40" required autocomplete="off"></div><div class="field"><label for="${prefix}-role">Role</label><input id="${prefix}-role" value="${esc(c.role)}" placeholder="e.g. Writing partner" maxlength="55" required></div></div><div class="field"><label for="${prefix}-description">Instructions</label><textarea id="${prefix}-description" placeholder="What should this agent help with? How should they work?" maxlength="1500" required>${esc(c.description)}</textarea></div><details class="config-preferences"><summary>Tools${groups?' & groups':''}${icon('down')}</summary><p>Shared files are available in the Mac app. Manage connected-service access through Connections.</p><label class="preference-option"><input type="checkbox" id="${prefix}-web" ${c.tools.web?'checked':''}><span>Web research preference</span></label><label class="preference-option"><input type="checkbox" id="${prefix}-files" ${c.tools.projectFiles?'checked':''}><span>Shared files · read, create & edit</span></label><label class="preference-option"><input type="checkbox" id="${prefix}-desktop" ${c.tools.desktop?'checked':''}><span>Mac apps · see and operate</span></label>${groups&&state.groups.length?`<h3>Add to a group</h3>${state.groups.map(g=>`<label class="preference-option"><input type="checkbox" name="config-group" value="${esc(g.id)}" ${c.groupIds.includes(g.id)?'checked':''}><span>${esc(g.name)}</span></label>`).join('')}`:''}<p>Tool access is on by default. Turning it off stops current work involving this agent. Connect your Mac through Connections.</p></details>`;
}
function readConfig(prefix) {
  return {
    name:document.getElementById(`${prefix}-name`).value,
    role:document.getElementById(`${prefix}-role`).value,
    description:document.getElementById(`${prefix}-description`).value,
    avatarShape:document.querySelector('[name=avatar-shape]:checked')?.value,
    avatarColor:document.querySelector('[name=avatar-color]:checked')?.value,
    tools:{web:document.getElementById(`${prefix}-web`).checked,projectFiles:document.getElementById(`${prefix}-files`).checked,desktop:document.getElementById(`${prefix}-desktop`).checked},
    groupIds:[...document.querySelectorAll('[name=config-group]:checked')].map(input=>input.value)
  };
}
function bindConfig(prefix) {
  const update=()=>{
    const c=readConfig(prefix);
    document.getElementById('config-avatar-preview').innerHTML=configuredAvatar(c);
    document.getElementById('config-preview-name').textContent=c.name.trim()||'Your new agent';
    for(const image of document.querySelectorAll('[data-shape-preview]'))image.style.filter=avatarFilter(image.dataset.shapePreview,c.avatarColor);
  };
  for(const input of document.querySelectorAll('[name=avatar-shape],[name=avatar-color]'))input.addEventListener('change',update);
  document.getElementById(`${prefix}-name`).addEventListener('input',update);
}
function newAgent(templateId) {
  const template=findAgent(templateId),c=template?RelayTeam.config(template):{avatarShape:'star',avatarColor:'lilac'};
  c.name='';if(template)c.avatarColor=template.avatarColor==='red'?'lilac':'red';
  openModal(template?'Create a similar agent':'Create an agent',`<p class="modal-description">Give them a name and a look. They'll ask about their job in chat.</p><form id="agent-form" class="agent-config-form">${avatarPicker(c)}<div class="field"><label for="agent-name">Name</label><input id="agent-name" maxlength="40" required autocomplete="off" placeholder="What should we call them?"></div><p class="field-error" id="agent-error" role="alert"></p>${formActions('Start chatting')}</form>`);
  const form=document.getElementById('agent-form');
  const read=()=>({name:document.getElementById('agent-name').value,role:'Getting started',description:BuddyAgentSetup.bootstrap,avatarShape:document.querySelector('[name=avatar-shape]:checked')?.value,avatarColor:document.querySelector('[name=avatar-color]:checked')?.value,tools:{web:true,projectFiles:true,desktop:true},groupIds:[]});
  const update=()=>{const value=read();document.getElementById('config-avatar-preview').innerHTML=configuredAvatar(value);document.getElementById('config-preview-name').textContent=value.name.trim()||'Your new agent';for(const image of form.querySelectorAll('[data-shape-preview]'))image.style.filter=avatarFilter(image.dataset.shapePreview,value.avatarColor);};
  form.addEventListener('input',update);form.addEventListener('change',update);
  form.addEventListener('submit',async event=>{
    event.preventDefault();const button=form.querySelector('[type=submit]');if(button.disabled)return;
    try {
      const candidate=RelayTeam.copy(state),agent=RelayTeam.createAgent(candidate,read(),{actor:'user'});agent.setupSeed=template?.description||'';BuddyAgentSetup.seed(candidate,agent);
      button.disabled=true;await persistWorkspace(candidate);state=candidate;closeModal();navigate('chat',agent.id);BuddyAgentSetup.ensure(agent.id);
    }catch(error){document.getElementById('agent-error').textContent=error.message;button.disabled=false;}
  });
}
function agentInfo(agentId) {
  const a=findAgent(agentId);if(!a)return;
  const originalRole=a.role,originalInstructions=a.description;
  openModal(`${a.name}’s settings`,`<form id="bot-settings" class="agent-config-form">${a.setupStatus==='pending'?`<p class="modal-description">Your Buddy is still learning the job. Continue the questions, or write their instructions here.</p><button type="button" class="small-link" data-continue-setup="${esc(a.id)}">Continue setup in chat${icon('arrow')}</button>`:''}${configFields(a,'edit')}${window.BuddyModels?.settings(a.id)||''}${window.BuddyTeamMonitorUI?.agentSection(a.id)||''}<p class="field-error" id="bot-error" role="alert"></p>${formActions()}</form>`);
  bindConfig('edit');window.BuddyModels?.mount();
  document.getElementById('bot-settings').addEventListener('submit',async event=>{
    event.preventDefault();
    try{const config=RelayTeam.validate(state,readConfig('edit'),a.id);const button=event.submitter;if(button)button.disabled=true;const changedInstructions=config.role!==originalRole||config.description!==originalInstructions;if(changedInstructions)await BuddyAgentSetup.edit(a.id,config);else{config.role=findAgent(a.id).role;config.description=findAgent(a.id).description;}RelayTeam.updateAgent(state,a.id,config);await persistWorkspace(state);closeModal();render();if(storageAvailable)showToast('Agent settings saved.');}
    catch(error){document.getElementById('bot-error').textContent=error.message;if(event.submitter)event.submitter.disabled=false;}
  });
}
const findProposal=proposalId=>state.proposals.find(p=>p.id===proposalId);
const pendingProposals=()=>state.proposals.filter(p=>p.status==='pending');
const pendingSuggestionCount=()=>pendingProposals().length+(window.BuddyTeamBuilderUI?.pending().length||0);
function proposalCard(proposalId) {
  const p=findProposal(proposalId);if(!p)return '';
  const c=p.approved||p.draft;
  return `<button class="proposal-card ${p.status}" data-action="review-proposal" data-id="${esc(p.id)}"><span class="proposal-kicker">${p.sample?'Sample suggestion':'Suggested agent'}</span><span class="proposal-card-main">${configuredAvatar(c)}<span><strong>${esc(c.name)}</strong><small>${esc(c.role)}</small></span>${icon(p.status==='pending'?'chevron':p.status==='approved'?'check':'close')}</span><span class="proposal-card-status">${p.status==='pending'?'Review before adding':p.status==='approved'?'Added by you':'Declined by you'}</span></button>`;
}
async function proposalList() {
  await Promise.all([BuddyProposals.refresh(),window.BuddyTeamBuilderUI?.refresh()]);
  const pending=pendingProposals(),teamPending=window.BuddyTeamBuilderUI?.pending().length||0,decided=state.proposals.filter(p=>p.status!=='pending');
  openDrawer('Agent suggestions',`${BuddyProposals.getError()?`<p class="field-error" role="alert">${esc(BuddyProposals.getError())}</p><button class="border-button" data-action="proposals">Try again</button>`:''}<p class="proposal-list-intro">Requested teams are created directly. Suggested teams wait for your approval.</p>${window.BuddyTeamBuilderUI?.list()||''}${pending.length?`<h3 class="section-caption">Waiting for you · ${pending.length}</h3>${pending.map(p=>proposalCard(p.id)).join('')}`:teamPending?'':`<div class="proposal-empty"><span class="menu-icon">${icon('people')}</span><h3>No suggestions waiting</h3><p>A suggested agent joins only after you approve their configuration.</p></div>`}${decided.length?`<h3 class="section-caption">Your decisions</h3>${decided.map(p=>proposalCard(p.id)).join('')}`:''}${window.BuddyDesktop?.agentProposals?'':`<div class="sample-proposal-entry"><button class="border-button" data-action="sample-proposal">Try a sample suggestion${icon('arrow')}</button><p>Preview example.</p></div>`}`);
}
function sampleProposal() {
  const group=findGroup(ui.view.target),source=findAgent(ui.view.target)||findAgent(group?.members[0])||state.agents[0];
  if(!source)return;
  const chat=group?.id||source.id;
  let name='Sage',suffix=2;
  while(state.agents.some(a=>a.name.toLowerCase()===name.toLowerCase())||state.proposals.some(p=>p.status==='pending'&&p.draft.name.toLowerCase()===name.toLowerCase()))name=`Sage ${suffix++}`;
  const proposal=RelayTeam.proposeAgent(state,{
    proposedBy:source.id,chat,sample:true,
    reason:'A dedicated writing partner could refine the project descriptions while the rest of the team works on the site.',
    suggestion:{name,role:'Writing partner',description:'Help write clear, warm project descriptions. Work from the shared brief, ask when context is missing, and bring drafts back for review before anything is published.',avatarShape:source.avatarShape,avatarColor:'red',tools:{web:false,projectFiles:true},groupIds:group?[group.id]:findGroup('launch')?['launch']:[]}
  });
  state.messages[chat]||=[];
  state.messages[chat].push({id:`proposal-sample-${id()}`,who:source.id,body:'A writing partner could help with the project copy. Here’s a suggested teammate for you to review.',time:new Date().toLocaleTimeString([], {hour:'2-digit',minute:'2-digit'}),proposalId:proposal.id});
  save();closeModal();navigate('chat',chat);reviewProposal(proposal.id);
}
function proposalReceipt(p) {
  const c=p.approved||p.draft;
  openModal(p.status==='approved'?'Agent added':'Suggestion declined',`<div class="proposal-receipt-profile">${configuredAvatar(c)}<h3>${esc(c.name)}</h3><p>${esc(c.role)}</p></div><div class="detail-row"><span>Suggested by</span><strong>${esc(p.proposedByName||agentName(p.proposedBy))}${p.sample?' · sample':''}</strong></div><div class="detail-row"><span>Your decision</span><strong>${p.status==='approved'?'Approved and added':'Declined'}</strong></div><div class="detail-section"><h3>Instructions</h3><p>${esc(c.description)}</p></div>${p.status==='approved'?`<div class="modal-actions"><button class="primary-button" data-action="proposal-open-agent" data-id="${esc(p.agentId)}">Open chat${icon('arrow')}</button></div>`:`<div class="modal-actions"><button class="border-button" data-action="proposals">All suggestions</button></div>`}`);
}
let proposalBusy=false;
function proposalReviewFields(value){const fields=configFields(value,'proposal',{groups:true}),start=fields.indexOf('<fieldset'),end=fields.indexOf('<div class="config-basic-fields"');return fields.slice(0,start)+`<details class="proposal-appearance"><summary>Change their look${icon('down')}</summary>${fields.slice(start,end)}</details>`+fields.slice(end);}
function reviewProposal(proposalId) {
  const p=findProposal(proposalId);if(!p)return;
  if(p.status!=='pending'){proposalReceipt(p);return;}
  openModal('Review suggested agent',`<div class="proposal-provenance"><span>${avatar(p.proposedBy,true)}Suggested by <strong>${esc(p.proposedByName||agentName(p.proposedBy))}</strong></span>${p.sample?'<span class="sample-label">Sample</span>':''}</div><p class="proposal-reason">${esc(p.reason)}</p><form id="proposal-form" class="agent-config-form" data-proposal="${esc(p.id)}">${proposalReviewFields(p.draft)}<p class="proposal-boundary">Not on your team yet. Edit anything before adding.</p><p class="field-error" id="proposal-error" role="alert"></p><div class="modal-actions proposal-actions"><button type="button" class="decline-button" data-action="decline-proposal" data-id="${esc(p.id)}">Decline</button><button type="button" class="border-button" data-action="save-proposal" data-id="${esc(p.id)}">Save for later</button><button type="submit" class="primary-button">Approve & add${icon('check')}</button></div></form>`);
  document.getElementById('proposal-form').closest('.modal').classList.add('proposal-modal');
  bindConfig('proposal');
  document.getElementById('proposal-form').addEventListener('submit',event=>{event.preventDefault();decideProposal(p.id,'approve');});
}
async function decideProposal(proposalId,action){
  if(proposalBusy)return;const p=findProposal(proposalId),form=document.getElementById('proposal-form'),error=document.getElementById('proposal-error');
  const config=action==='decline'?undefined:readConfig('proposal');
  try{if(config)RelayTeam.validate(state,config);}catch(reason){error.textContent=reason.message;return;}
  const actionButton=action==='approve'?form.querySelector('[type=submit]'):form.querySelector(`[data-action=${action==='save'?'save-proposal':'decline-proposal'}]`),originalLabel=actionButton.innerHTML,closeButton=document.querySelector('.modal-header [data-action=close-modal]');
  proposalBusy=true;form.setAttribute('aria-busy','true');error.textContent='';actionButton.textContent={approve:'Adding…',save:'Saving…',decline:'Declining…'}[action];if(closeButton)closeButton.disabled=true;for(const field of form.querySelectorAll('button,input,textarea'))field.disabled=true;
  try{
    let agent;
    if(p.native){const result=await BuddyProposals.decide(p,action,config);agent=result.agent;}
    else{const candidate=RelayTeam.copy(state);if(action==='approve')agent=RelayTeam.approveProposal(candidate,p.id,config,{actor:'user'});else if(action==='save')RelayTeam.saveProposal(candidate,p.id,config);else RelayTeam.declineProposal(candidate,p.id,{actor:'user'});await persistWorkspace(candidate);state=candidate;}
    form.removeAttribute('aria-busy');closeModal();render();
    showToast(action==='approve'?`${agent.name} joined your team.`:action==='save'?'Suggestion saved. It’s still waiting for your approval.':'Suggestion declined. No agent was added.');
  }catch(reason){const message=String(reason.message||reason);error.textContent=message.includes('Your choices are still here')?message:message+' Your choices are still here.';form.removeAttribute('aria-busy');actionButton.innerHTML=originalLabel;if(closeButton)closeButton.disabled=false;for(const field of form.querySelectorAll('button,input,textarea'))field.disabled=false;}
  finally{proposalBusy=false;}
}
function saveProposalDraft(proposalId){return decideProposal(proposalId,'save');}
function declineProposal(proposalId){return decideProposal(proposalId,'decline');}


const agentName = agentId => findAgent(agentId)?.name || 'You';
let persistenceQueue=Promise.resolve();
async function persistWorkspace(value){
  if(workspaceReadError)throw Error(workspaceReadError);
  const snapshot=JSON.stringify(value);
  const operation=persistenceQueue.catch(()=>{}).then(async()=>{if(window.BuddyDesktop){await window.BuddyDesktop.saveState(snapshot);}else localStorage.setItem(STORAGE_KEY,snapshot);storageAvailable=true;});
  persistenceQueue=operation;return operation;
}
function save(){if(workspaceReadError)return false;persistWorkspace(state).catch(()=>{storageAvailable=false;showToast('Buddy couldn’t save your workspace. Keep the app open and try again.');});return true;}

function navigate(kind,target){if(kind==='files'&&window.BuddyFiles?.native())return BuddyFiles.show();ui.view={kind,target};if(kind==='chat')ui.lastChat=target;ui.mobile=false;state.lastView=ui.view;save();render();document.querySelector('#main h1')?.focus({preventScroll:true});if(kind==='chat')BuddyAgentSetup.ensure(target);}
function chatSummary(targetId, fallback) {
  const draft=state.drafts[targetId];
  if(draft?.trim())return `Draft: ${draft.trim()}`;
  const last=(state.messages[targetId]||[]).filter(m=>m.who).at(-1);
  return last ? `${last.who==='you'?'You: ':''}${(last.body&&(last.who==='you'?last.body:BuddyMarkdown.preview(last.body)))|| (BuddyChat.busy(last.status)?(window.BuddyActions?.pending(state,last.runId)?.length?'Needs your review':last.team?teamPhase(last.team.phase):''):'')}` : fallback;
}
function groupAvatar(groupId, small=false) {
  const g=findGroup(groupId);
  return `<span class="group-avatar ${small?'small':''}" aria-hidden="true">${(g?.members||[]).slice(0,3).map(a=>avatar(a,true)).join('')||icon('people')}</span>`;
}
function sidebar() {
  const entries=[...state.agents.map(a=>({...a,isGroup:false})),...state.groups.map(g=>({...g,isGroup:true}))];
  const query=ui.chatFilter.toLowerCase().trim();
  const filtered=entries.filter(x=>`${x.name} ${x.role||''}`.toLowerCase().includes(query));
  return `<aside class="sidebar ${ui.mobile?'mobile-open':''}" aria-label="Chats">
    <header class="sidebar-header"><div class="buddy-brand">${buddyLogo()}<h2>Buddy</h2></div><div class="sidebar-header-actions">${pendingSuggestionCount()?`<button class="icon-button pending-suggestions-button" data-action="proposals" aria-label="Review ${pendingSuggestionCount()} agent suggestions" title="Agent suggestions">${icon('people')}<span>${pendingSuggestionCount()}</span></button>`:''}<button class="icon-button" data-action="new-chat" aria-label="New chat" title="New chat">${icon('plus')}</button><button class="icon-button mobile-sidebar-close" data-action="menu" aria-label="Close chats">${icon('close')}</button></div></header>
    <label class="chat-search">${icon('search')}<input id="chat-search" aria-label="Search chats" placeholder="Search" value="${esc(ui.chatFilter)}" autocomplete="off"></label>
    <nav class="chat-list" aria-label="Conversations">${filtered.map(x=>{const messages=(state.messages[x.id]||[]).filter(m=>m.who),last=messages.at(-1);return `<button class="chat-row ${agentIsThinking(x.id)?'is-working':''} ${ui.view.kind==='chat'&&ui.view.target===x.id?'selected':''}" data-action="chat" data-id="${esc(x.id)}" aria-label="Open ${esc(x.name)} chat" ${ui.view.kind==='chat'&&ui.view.target===x.id?'aria-current="page"':''}>${x.isGroup?groupAvatar(x.id):avatar(x.id)}<span class="chat-row-copy"><span class="chat-row-top"><strong>${esc(x.name)}</strong><time>${last?.time?esc(last.time):''}</time></span><span class="chat-snippet ${state.drafts[x.id]?.trim()?'has-draft':''}">${esc(chatSummary(x.id,x.isGroup?'Start a conversation':x.role))}</span></span></button>`;}).join('')}${!filtered.length?'<div class="chat-list-empty">No chats found.<br><button class="small-link" data-action="clear-chat-search">Clear search</button></div>':''}</nav>
    <footer class="sidebar-footer"><button class="worker-nav" data-buddy-desktop>${icon('folder')}<span>Buddy desktop</span></button><button class="worker-nav" data-action="background-work">${icon('spark')}<span>Background work</span><span class="worker-badge" data-worker-badge hidden></span></button><button class="workspace-button" data-action="settings" aria-label="Workspace settings">${buddyLogo(true)}<span>Your workspace</span>${icon('settings')}</button><button class="preview-status" data-action="connection">${BuddyBrands.logo(chatConnection.provider)}${chatConnection.connected?`${providerName()} connected`:window.BuddyDesktop?`Connect ${providerName()}`:'Frontend preview'}${icon('info','small-icon')}</button></footer>
  </aside>`;
}
const taskState = s => ({queued:'To do',working:'In progress',review:'Ready for review',done:'Done',paused:'Paused',failed:'Needs attention'}[s]||'To do');
function messageHTML(m) {
  if(m.kind==='handoff')return `<div class="handoff">${icon('handoff')}<span>${esc(m.body)}</span></div>`;
  if(m.kind==='notice')return `<div class="message-notice">${icon('info')}<span>${esc(m.body)}</span></div>`;
  if(m.who==='you')return `<div class="message user-message"><div class="user-bubble"><p>${esc(m.body).replace(/\n/g,'<br>')}</p>${m.attachments?.length?`<div class="attachments">${m.attachments.map(a=>`<span class="attachment-chip">${icon('paperclip')}${esc(a.name)}</span>`).join('')}</div>`:''}<time>${esc(m.time)}</time></div></div>`;
  const a=findAgent(m.team?.leadId)||findAgent(m.who),messageGroup=findGroup(m.who);if(!a&&!messageGroup)return '';
  const basePresentation=m.teamUpdate?window.BuddyTeamMonitorUI?.presentation(state,m):m.workerTaskID?window.BuddyWorkerUI?.presentation(state,m):null;
  const presentation=basePresentation?.hidden?basePresentation:window.BuddyChat?.presentation(state,{...m,body:basePresentation?.body??m.body})||basePresentation;
  if(presentation?.hidden)return '';
  const group=!!findGroup(ui.view.target);
  if(m.live){
    const review=window.BuddyActions?.pending(state,m.runId).length>0;
    const waiting=BuddyChat.busy(m.status)&&!m.body&&!review;
    const team=!!m.team,partial=m.team?.partial;
    const indicator=a||findAgent(messageGroup?.members?.[0]);
    const retryable=['failed','stopped'].includes(m.status)||m.status==='completed'&&partial;
    const working=BuddyChat.busy(m.status)&&!review;
    const status=review?'Waiting for your review':m.status==='completed'?(partial?'Some work couldn’t finish':esc(m.time)):m.status==='stopped'?'Stopped':m.status==='failed'?'Couldn’t finish':m.status==='stopping'?'Stopping…':working?thinkingAvatar(indicator,true):'';
    return `<div class="message bot-message ${team?'team-reply':''}">${team?(a?avatar(a.id,true):groupAvatar(messageGroup?.id||ui.view.target,true)):''}<div class="bot-bubble ${waiting?'thinking-only':''}">${team?`<span class="team-reply-author">${esc(a?.name||'Your team')}</span>`:''}<div class="reply-content">${BuddyMarkdown.render(presentation?.body??m.body)}</div>${waiting?thinkingAvatar(indicator):''}${presentation?.details?`<details class="team-update-evidence"><summary>Details</summary><div class="reply-markdown">${BuddyMarkdown.render(presentation.details)}</div></details>`:''}${window.BuddyActions?.cards(m.runId)||''}${window.BuddyFiles?.cards(m.files||[])||''}${reviewCoverage(m.coverage)}${window.BuddyTeamMonitorUI?.sources(m)||''}${routineReceipts(m.routines)}${m.workerTaskID?`<button class="routine-result-link" data-worker-task="${esc(m.workerTaskID)}">${m.workerStatus==='waiting_review'?'Review task':m.workerStatus==='waiting_user'?'Continue task':'View task'}${icon('chevron')}</button>`:''}${m.setupComplete?`<button class="routine-result-link" data-action="agent-info" data-id="${esc(a.id)}">View instructions${icon('chevron')}</button>`:''}${(m.proposalIds||[]).map(proposalCard).join('')}${(m.teamPlanIds||[]).map(id=>window.BuddyTeamBuilderUI?.card(id)||'').join('')}${m.error?`<div class="reply-error" role="alert">${esc(replyErrorText(m.error))}</div>`:''}${!waiting?`<div class="reply-status">${status}${team?`<button class="teamwork-link" data-action="teamwork" data-id="${esc(m.runId)}" aria-label="View teamwork for this reply">${icon('people')}Teamwork</button>`:''}${m.setupRetry?`<button data-setup-retry="${esc(a.id)}">Try again</button>`:retryable?`<button data-action="retry-message" data-id="${esc(m.runId)}">Try again</button>`:''}</div>`:''}</div></div>`;

  }
  return `<div class="message bot-message">${group?avatar(a.id,true):''}<div class="bot-bubble">${group?`<button class="message-author" style="color:${RelayTeam.colorOptions.find(c=>c.id===a.avatarColor).text}" data-action="agent-info" data-id="${esc(a.id)}">${esc(a.name)}</button>`:''}<p>${esc(m.body).replace(/\n/g,'<br>')}</p>${m.assignments?`<details class="message-details"><summary>${icon('tasks')}See the plan${icon('down')}</summary><div class="assignments">${m.assignments.map(taskId=>{const t=findTask(taskId);return t?`<button class="assignment" data-action="task" data-id="${esc(t.id)}">${avatar(t.agent,true)}<span>${esc(t.title)}<small>${esc(agentName(t.agent))} · ${taskState(t.state)}</small></span>${icon('chevron')}</button>`:'';}).join('')}</div></details>`:''}${m.sources?`<button class="inline-file" data-action="file" data-id="references">${icon('file')}Visual direction${icon('chevron')}</button>`:''}${m.file?artifactHTML(m.file):''}${m.proposalId?proposalCard(m.proposalId):''}${m.group?`<button class="chat-link" data-action="chat" data-id="${esc(m.group)}">${groupAvatar(m.group,true)}${esc(findGroup(m.group)?.name||'Group chat')}${icon('chevron')}</button>`:''}<time>${esc(m.time)}</time></div></div>`;
}
function reviewCoverage(values=[]){
  return values.map(c=>`<details class="inbox-coverage ${c.partial?'partial':''}"><summary>${c.prepared?`From routine · Checked ${esc(new Date(c.checkedAt||c.at).toLocaleString([], {month:'short',day:'numeric',hour:'2-digit',minute:'2-digit'}))}`:c.partial?'Email review incomplete':'Email search checked'} · ${Number(c.read)||0} read${c.skipped?` · ${Number(c.skipped)} previously reviewed`:''}${c.unread?` · ${Number(c.unread)} unread`:''}</summary><p>${c.prepared?`${esc(c.routineTitle||'Email routine')} · Saved result; mail may have changed since this check. `:''}${esc(c.scope||'Matching emails in this search; not the whole mailbox.')}</p><code>${esc(c.query)}</code><p>${Number(c.pages)||0} search pages · ${c.searchExhausted?'All pages returned for this query':'More results may remain'} · ${esc(new Date(c.checkedAt||c.at).toLocaleString())}</p>${(c.issues||[]).map(v=>`<p>${esc(v)}</p>`).join('')}</details>`).join('');
}
function routineReceipts(values=[]){
  if(values.length>1)return `<details class="team-update-evidence"><summary>${values.length} saved checks</summary>${routineReceipts(values.slice(0,1))}${values.slice(1).map(r=>routineReceipts([r])).join('')}</details>`;
  return values.map(r=>`<div class="routine-receipt">${icon('clock')}<span><strong>${esc(r.title)}</strong><small>${r.status==='active'?'Routine saved':esc(r.status)} · Next ${esc(new Date(r.nextRun).toLocaleString())} · ${esc(r.timeZone)}</small></span><button data-action="background-work" aria-label="Manage routine ${esc(r.title)}">Manage</button></div>`).join('');
}
function artifactHTML(fileId) {
  const f=findFile(fileId);if(!f)return '';
  return `<button class="artifact-card" data-action="file" data-id="${esc(f.id)}"><span class="artifact-icon">${icon('file')}</span><span><strong>${esc(f.name)}</strong><small>${esc(f.type)} · Version ${f.revision}</small></span>${icon('chevron')}</button>`;
}
function conversationMessages(messages){
  const samples=messages.filter(m=>m.id?.startsWith('dm-sample-')||/^m[1-6]$/.test(m.id)||findProposal(m.proposalId)?.sample);
  const live=messages.some(m=>m.live);
  if(live&&samples.length)return `<details class="sample-history"><summary>Example conversation${icon('down')}</summary>${samples.map(messageHTML).join('')}</details><div class="live-divider">Your conversation</div>${messages.filter(m=>!samples.includes(m)).map(messageHTML).join('')}`;
  return messages.map(messageHTML).join('');
}
function connectionLabel(){if(BuddyAgentSetup.required(findAgent(ui.view.target)))return 'Setup with Claude';return !storageAvailable?'Changes aren’t being saved':chatConnection.checking?`Connecting to ${providerName()}…`:chatConnection.connected?(chatConnection.provider==='claude'?'Powered by Claude API credits':'Powered by your ChatGPT subscription'):window.BuddyDesktop?`Connect ${providerName()}`:'Frontend preview';}
function sendControl(target,draft){
  const running=BuddyChat.active(state,target)||BuddyAgentSetup.active(state,target);
  return running?`<button type="button" class="send-button stop-button" id="send-message" data-action="stop-message" data-id="${esc(running.runId)}" aria-label="Stop reply" title="Stop reply (⌘.)" ${running.status==='stopping'?'disabled':''}><svg viewBox="0 0 24 24" aria-hidden="true"><rect x="5" y="5" width="14" height="14" rx="2"/></svg></button>`:`<button type="submit" class="send-button" id="send-message" aria-label="Send message" ${draft.trim()?'':'disabled'}>${icon('up')}</button>`;
}
function conversation() {
  const g=findGroup(ui.view.target),a=findAgent(ui.view.target),target=g||a;
  if(!target){ui.view={kind:'chat',target:state.agents[0]?.id};return '<section class="center"></section>';}
  const messages=state.messages[target.id]||[],draft=state.drafts[target.id]||'',attachments=state.attachments[target.id]||[];
  const sample=messages.some(m=>m.id?.startsWith('dm-sample-')||/^m[1-6]$/.test(m.id)||findProposal(m.proposalId)?.sample);
  return `<section class="center conversation"><header class="conversation-header"><button class="icon-button mobile-menu-button" data-action="menu" aria-label="Open chats">${icon('chevron')}</button><button class="conversation-title" data-action="chat-details" aria-label="${esc(target.name)} details">${g?groupAvatar(g.id):avatar(a.id)}<span><h1 tabindex="-1">${esc(target.name)}</h1><span class="conversation-subtitle">${g?`${g.members.length} agents, you` : esc(a.role)}</span></span></button><div class="header-tools"><button class="icon-button" data-action="workspace-details" data-section="files" aria-label="Shared files and tasks" title="Shared files and tasks">${icon('folder')}</button><button class="icon-button" data-action="chat-details" aria-label="Conversation details" title="Conversation details">${icon('more')}</button></div></header>
    <div class="chat-body" id="chat-body"><div class="chat-thread">${messages.length?`<div class="date-divider">${sample&&!messages.some(m=>m.live)?'Today · sample conversation':'Today'}</div><div id="messages">${conversationMessages(messages)}</div>`:`<div class="empty-chat">${g?groupAvatar(g.id):avatar(a.id)}<h2>${g?esc(g.name):`Say hi to ${esc(a.name)}.`}</h2><p>${g?'Your team, in one conversation.':esc(a.role)}</p><button class="suggestion" data-action="suggest" data-text="${g?'Let’s plan our next project.':'What can you help me with?'}">${g?'Plan something together':'What can you help me with?'}${icon('arrow')}</button></div>`}</div></div>
    <div class="composer-wrap"><form class="composer" id="composer" aria-label="Message ${esc(target.name)}">${attachments.length?`<div class="attachments">${attachments.map((a,index)=>`<span class="attachment-chip">${icon('paperclip')}${esc(a.name)}<button type="button" data-action="remove-attachment" data-index="${index}" aria-label="Remove ${esc(a.name)}">${icon('close')}</button></span>`).join('')}</div>`:''}<div class="composer-line"><button type="button" class="icon-button" data-action="attach" aria-label="${window.BuddyDesktop?.projectFiles?'Add a shared file':'Attach a file'}">${icon('plus')}</button><textarea id="message-input" aria-label="Message ${esc(target.name)}" placeholder="Message ${g?'the group':esc(a.name)}…" rows="1">${esc(draft)}</textarea><button type="button" class="icon-button mention-button" data-action="mention" aria-label="Mention an agent">${icon('at')}</button>${sendControl(target.id,draft)}</div>${!g?`<div class="composer-model-row">${window.BuddyModels?.slot(a.id)||`<div class="agent-model-slot" data-agent-model="${esc(a.id)}"></div>`}</div>`:''}<input type="file" id="attachment-input" hidden multiple></form><button class="composer-hint" data-action="connection">${esc(connectionLabel())}</button>${a&&BuddyAgentSetup.required(a)&&(state.agentSetup?.[a.id]?.messages||[]).some(m=>m.who==='you')&&!BuddyAgentSetup.active(state,a.id)?`<button type="button" class="composer-hint" data-setup-finish="${esc(a.id)}">Finish setup with what I’ve shared</button>`:''}</div>
  </section>`;
}
function startChat() {
  openModal('New chat',`<div class="new-chat-actions"><button class="menu-row" data-action="background-work"><span class="menu-icon">${icon('spark')}</span><span>Background work<small>Leave a task with your Buddy.</small></span>${icon('chevron')}</button><button class="menu-row" data-action="new-agent"><span class="menu-icon">${icon('spark')}</span><span>Create an agent<small>A new name, a new point of view.</small></span>${icon('plus')}</button><button class="menu-row" data-action="new-group"><span class="menu-icon">${icon('people')}</span><span>Create a group<small>Bring a few agents together.</small></span>${icon('plus')}</button><button class="menu-row" data-action="proposals"><span class="menu-icon">${icon('people')}</span><span>Agent suggestions<small>${pendingSuggestionCount()?`${pendingSuggestionCount()} waiting for your approval`:'You decide who joins the team.'}</small></span>${icon('chevron')}</button></div><h3 class="section-caption">Your agents</h3>${state.agents.map(a=>`<button class="menu-row" data-action="open-existing-chat" data-id="${esc(a.id)}">${avatar(a.id)}<span>${esc(a.name)}<small>${esc(a.role)}</small></span>${icon('chevron')}</button>`).join('')}`);
}
function openDrawer(title,body) {
  openModal(title,body);
  document.querySelector('.modal-overlay').classList.add('drawer-overlay');
  document.querySelector('.modal').classList.add('drawer');
}
function teamPhase(phase){return {planning:'Choosing the team',working:'Team working',replying:'Writing a reply',completed:'Finished',failed:'Couldn’t finish',stopped:'Stopped'}[phase]||'Team working';}
function teamStatus(status){return {queued:'Waiting',working:'Working',completed:'Done',failed:'Couldn’t finish',blocked:'Waiting on missing work',stopped:'Stopped'}[status]||'Waiting';}
function readingSummary(tools){
  tools=Array.isArray(tools)?tools.filter(t=>t.category!=='files'):[];
  if(!tools.length)return '';
  const done=tools.filter(t=>t.status==='completed').length,failed=tools.filter(t=>t.status==='failed').length,working=tools.filter(t=>t.status==='working').length;
  return `<p class="team-reading">${done?`${done} reading ${done===1?'step':'steps'} finished`:''}${working?`${done?' · ':''}Reading a connection`:''}${failed?`${done||working?' · ':''}${failed} reading ${failed===1?'step':'steps'} failed`:''}</p>`;
}
function teamworkBody(run){
  const team=run.team||{},lead=findAgent(team.leadId),entries=team.entries||[];
  return `<div class="teamwork-overview"><span class="teamwork-phase" role="status">${esc(run.status==='stopping'?'Stopping':teamPhase(team.phase))}</span>${lead?`<p>${esc(lead.name)} ${run.status==='completed'?'brought the reply together':['failed','stopped'].includes(run.status)?'was chosen to reply':team.phase==='replying'?'is bringing the reply together':'will bring the reply together'}.</p>`:''}${run.error?`<p class="reply-error" role="alert">${esc(run.error)}</p>`:''}</div>${entries.map(entry=>`<section class="teamwork-entry" data-agent-entry="${esc(entry.agentId)}"><div class="teamwork-person">${findAgent(entry.agentId)?avatar(entry.agentId):''}<span><strong>${esc(entry.name||agentName(entry.agentId))}</strong><small>${esc(entry.role||'')}</small></span><span class="teamwork-state ${esc(entry.status)}">${esc(teamStatus(entry.status))}</span></div><p class="teamwork-task">${esc(entry.task||'')}</p>${entry.dependsOn?.length?`<p class="teamwork-dependency">After ${entry.dependsOn.map(agentName).map(esc).join(', ')}</p>`:''}${entry.error?`<p class="reply-error">${esc(entry.error)}</p>`:''}${readingSummary(entry.tools)}${entry.notes?`<details class="teamwork-contribution" data-contribution="${esc(entry.agentId)}"><summary>Read contribution${icon('down')}</summary><div>${esc(entry.notes)}</div></details>`:''}</section>`).join('')}${!entries.length?`<p class="teamwork-simple">${team.phase==='planning'?'Choosing who can help with this request.':run.status==='completed'?'This request needed one reply, without extra assignments.':run.status==='failed'||run.status==='stopped'?'No assignments were completed.':'This request is being answered directly.'}</p>`:''}${readingSummary(team.replyTools)}<p class="teamwork-access">The team uses connections enabled for every member. Manage each agent’s access in their settings.</p>`;
}
function teamworkDetails(runId){
  const run=state.runs[runId];if(!run?.team)return;
  openDrawer('Teamwork',`<div data-teamwork-run="${esc(runId)}">${teamworkBody(run)}</div>`);
  const el=document.querySelector('[data-teamwork-run]');el.dataset.signature=JSON.stringify([run.status,run.error,run.team]);
}
function refreshTeamworkDetails(){
  const el=document.querySelector('[data-teamwork-run]');if(!el)return;
  const run=state.runs[el.dataset.teamworkRun];if(!run?.team)return;
  const signature=JSON.stringify([run.status,run.error,run.team]);if(el.dataset.signature===signature)return;
  const open=[...el.querySelectorAll('details[open]')].map(d=>d.dataset.contribution),focused=document.activeElement?.closest('[data-contribution]')?.dataset.contribution;
  const scroller=el.closest('.modal-body'),scroll=scroller.scrollTop;
  el.innerHTML=teamworkBody(run);el.dataset.signature=signature;
  for(const detail of el.querySelectorAll('details')){detail.open=open.includes(detail.dataset.contribution);if(detail.dataset.contribution===focused)detail.querySelector('summary').focus({preventScroll:true});}
  scroller.scrollTop=scroll;
}
function chatDetails() {
  const g=findGroup(ui.view.target),a=findAgent(ui.view.target),target=g||a;if(!target)return;
  openDrawer('Chat details',`<div class="detail-profile">${g?groupAvatar(g.id):avatar(a.id)}<h2>${esc(target.name)}</h2><p>${g?`${g.members.length} agents + you`:esc(a.role)}</p></div>${g?`<div class="detail-section"><h3>Shared goal</h3><p>${esc(g.objective)}</p></div><h3 class="section-caption">Members</h3>${g.members.map(id=>{const agent=findAgent(id);return agent?`<button class="menu-row" data-action="agent-info" data-id="${esc(id)}">${avatar(id)}<span>${esc(agent.name)}<small>${esc(agent.role)}</small></span>${icon('chevron')}</button>`:'';}).join('')}`:`<div class="detail-section"><h3>What ${esc(a.name)} helps with</h3><p data-agent-instructions="${esc(a.id)}">${esc(a.description)}</p></div>`}<div class="drawer-menu">${!g?`<button class="menu-row" data-action="clone-agent" data-id="${esc(a.id)}">${icon('plus')}<span>Create a similar agent</span>${icon('chevron')}</button>`:''}<button class="menu-row" data-action="proposals">${icon('people')}<span>Agent suggestions${pendingSuggestionCount()?` · ${pendingSuggestionCount()}`:''}</span>${icon('chevron')}</button>${!g?`<button class="menu-row" data-action="connections" data-agent-id="${esc(a.id)}">${icon('globe')}<span>Connections</span>${icon('chevron')}</button>`:''}<button class="menu-row" data-action="${g?'group-info':'agent-info'}" data-id="${esc(target.id)}">${icon('settings')}<span>${g?'Edit group':'Agent settings'}</span>${icon('chevron')}</button><button class="menu-row" data-action="background-work">${icon('spark')}<span>Background work</span>${icon('chevron')}</button><button class="menu-row" data-action="workspace-details" data-section="files">${icon('folder')}<span>Shared files & tasks</span>${icon('chevron')}</button><button class="menu-row" data-action="workspace-details" data-section="computer">${icon('monitor')}<span>Computer</span>${icon('chevron')}</button><button class="menu-row" data-action="settings">${icon('grid')}<span>Workspace settings</span>${icon('chevron')}</button></div>`);
}
function workspaceDetails(section='files') {
  if(section==='files'&&window.BuddyFiles?.native())return BuddyFiles.show();
  const g=findGroup(ui.view.target),tasks=state.tasks.filter(t=>g?t.group===g.id:true);
  const tabs=`<div class="drawer-tabs" aria-label="Workspace sections">${[['files','Files'],['tasks','Tasks'],['computer','Computer']].map(([id,label])=>`<button data-action="workspace-details" data-section="${id}" aria-pressed="${section===id}" class="${section===id?'selected':''}">${label}</button>`).join('')}</div>`;
  let body='';
  if(section==='files')body=`<div class="drawer-section-heading"><p>${state.files.length} shared files</p><button class="icon-button" data-action="new-file" aria-label="Create file">${icon('plus')}</button></div>${state.files.map(f=>`<button class="menu-row" data-action="file" data-id="${esc(f.id)}"><span class="menu-icon">${icon('file')}</span><span>${esc(f.name)}<small>${esc(agentName(f.owner))} · Version ${f.revision}</small></span>${icon('chevron')}</button>`).join('')||'<p class="drawer-empty">No files yet. Start with a blank page.</p>'}<button class="drawer-bottom-link" data-action="open-page" data-kind="files">All files${icon('arrow')}</button>`;
  if(section==='tasks')body=`<div class="drawer-section-heading"><p>${tasks.length} tasks${g?' in this group':''}</p><button class="icon-button" data-action="new-task" aria-label="Create task">${icon('plus')}</button></div>${tasks.map(t=>`<button class="menu-row" data-action="task" data-id="${esc(t.id)}">${avatar(t.agent)}<span>${esc(t.title)}<small>${esc(agentName(t.agent))} · ${taskState(t.state)}</small></span>${icon(t.state==='done'?'check':'chevron')}</button>`).join('')||'<p class="drawer-empty">Nothing to do here yet.</p>'}<button class="drawer-bottom-link" data-action="open-page" data-kind="tasks">All tasks${icon('arrow')}</button><p class="context-footnote">Sample work. Changes are saved locally.</p>`;
  if(section==='computer')body=`<div class="computer-state"><span class="menu-icon">${icon('monitor')}</span><h3>No computer connected</h3><p>Your agents will be able to work in a browser and with shared files here.</p><button class="border-button" data-action="computer-connect">Connection details${icon('arrow')}</button></div><button class="drawer-bottom-link" data-action="open-page" data-kind="computer">See the sample computer${icon('arrow')}</button>`;
  openDrawer('Shared workspace',tabs+body);
}
function overview(){return `<section class="center"><div class="page-scroll"><div class="overview-hero"><p class="eyebrow">A little more room to do good work</p><h1>Your own team.<br><em>All on the same page.</em></h1><p>A few capable minds, one shared workspace.<br>Talk to a bot, bring the team together, and move things forward.</p></div><div class="page-title-row" style="margin-bottom:10px"><h2 class="overview-caption" style="margin:0">Meet your team</h2><button class="border-button" data-action="new-agent">${icon('plus')}Create a bot</button></div><div class="overview-roster">${state.agents.map(a=>`<button class="agent-card" data-action="chat" data-id="${esc(a.id)}"><div class="agent-card-header">${avatar(a.id)}<span><strong>${esc(a.name)}</strong><small>${esc(a.role)}</small></span></div><p>${esc(a.description)}</p><span class="agent-card-footer">Open conversation${icon('arrow')}</span></button>`).join('')}</div><div class="page-title-row" style="margin-bottom:10px"><h2 class="overview-caption" style="margin:0">Better together</h2><button class="small-link" data-action="new-group">${icon('plus')}New group</button></div>${state.groups.map(g=>`<button class="group-card" data-action="chat" data-id="${esc(g.id)}"><span class="group-mark">${icon('people')}</span><span><strong>${esc(g.name)}</strong><p>${esc(g.description||`${g.members.length} bots working together`)}</p></span>${icon('arrow')}</button>`).join('')}</div></section>`;}
function tasksPage(){const filtered=state.tasks.filter(t=>ui.taskFilter==='__all__'||t.group===ui.taskFilter);return `<section class="center"><div class="page-scroll"><div class="page-title-row"><div><h1 tabindex="-1">Tasks</h1><p>See who’s doing what. Step in when it matters.</p></div><button class="primary-button" data-action="new-task">${icon('plus')}New task</button></div><div class="filter-tabs" aria-label="Filter tasks by group">${[{id:'__all__',name:'All tasks'},...state.groups].map(g=>`<button class="${ui.taskFilter===g.id?'selected':''}" aria-pressed="${ui.taskFilter===g.id}" data-action="task-filter" data-id="${esc(g.id)}">${esc(g.name)}</button>`).join('')}</div><div class="task-board">${[['queued','To do'],['review','In progress & review'],['done','Done']].map(([stage,label])=>{const tasks=filtered.filter(t=>stage==='review'?['working','review','paused','failed'].includes(t.state):t.state===stage);return `<section class="board-column"><div class="board-title"><i class="dot ${stage==='review'?'amber':stage==='done'?'':'gray'}"></i>${label}<span>${tasks.length}</span></div>${tasks.map(t=>`<button class="task-card" data-action="task" data-id="${esc(t.id)}"><h3>${esc(t.title)}</h3><p>${esc(t.description)}</p>${stage==='review'?`<span class="status-pill amber" style="margin-top:12px">${taskState(t.state)}</span>`:''}<div class="task-card-footer">${avatar(t.agent,true)}${esc(agentName(t.agent))}<span class="task-group">${esc(findGroup(t.group)?.name||'Personal task')}</span></div></button>`).join('')}${!tasks.length?'<div class="empty-column">Nothing here yet.</div>':''}</section>`;}).join('')}</div><div class="sample-notice" style="margin-top:25px">${icon('info')}<span>These tasks are stored in this preview. Bots will begin executing work after a model and tools are connected.</span></div></div></section>`;}
function filesPage(){const filtered=state.files.filter(f=>f.name.toLowerCase().includes(ui.fileFilter.toLowerCase()));return `<section class="center"><div class="page-scroll"><div class="page-title-row"><div><h1 tabindex="-1">Shared files</h1><p>Every bot can build on what the others leave here.</p></div><button class="primary-button" data-action="new-file">${icon('plus')}New file</button></div><label class="search-input">${icon('search')}<input id="file-search" placeholder="Find a file…" aria-label="Find a file" value="${esc(ui.fileFilter)}"></label><table class="files-table"><thead><tr><th>Name</th><th>Last edited by</th><th>Version</th><th>Open</th></tr></thead><tbody>${filtered.map(f=>`<tr><td><button class="file-cell" data-action="file" data-id="${esc(f.id)}">${icon('file')}${esc(f.name)}</button></td><td>${esc(agentName(f.owner))}</td><td>${f.revision}</td><td><button class="icon-button" data-action="file" data-id="${esc(f.id)}" aria-label="Open ${esc(f.name)}">${icon('arrow')}</button></td></tr>`).join('')}</tbody></table>${!filtered.length?'<div class="empty-state"><h2>No matching files.</h2><p>Try another name, or create a new file.</p></div>':''}<div class="sample-notice" style="margin-top:27px">${icon('info')}<span>Preview files stay on this device. Your desktop folders are not connected.</span></div></div></section>`;}
function portfolioPreview(){return `<div class="computer-preview-large"><div class="browser-chrome"><span class="traffic-lights"><i></i><i></i><i></i></span><span class="url-bar">homepage.html · sample visual preview</span>${icon('globe')}</div><div class="browser-preview"><div class="portfolio-nav"><span>YOUR NAME</span><span>Work&nbsp;&nbsp;&nbsp; About&nbsp;&nbsp;&nbsp; Contact</span></div><div class="portfolio-hero"><div><h2>Thoughtful work.<br>Made for real life.</h2><p>I design useful things for people<br>and the places they live.</p><span class="portfolio-link">Explore selected work ↗</span></div><div class="portfolio-art" aria-label="Abstract portfolio artwork"></div></div></div></div>`;}
function computerPage(){return `<section class="center"><div class="page-scroll"><div class="page-title-row"><div><h1 tabindex="-1">Computer</h1><p>The tools, files, and browser sessions they work with.</p></div><span class="status-pill">${icon('monitor')}Not connected</span></div><div class="connection-empty"><div class="empty-state"><span class="group-mark">${icon('monitor')}</span><h2>Give your team somewhere to work.</h2><p>Connect your Mac for local files, or a cloud computer for work that continues when you step away.</p><button class="primary-button" data-action="computer-connect">${icon('plus')}Connect a computer</button></div></div><div class="overview-caption" style="display:flex;align-items:center;justify-content:space-between">A look inside<span class="demo-tag">Sample desktop</span></div>${portfolioPreview()}<p class="context-footnote">This illustration shows where a shared browser view will appear. No remote session is running.</p></div></section>`;}
function render(){document.getElementById('app').innerHTML=`<div class="shell">${sidebar()}<div class="mobile-overlay ${ui.mobile?'visible':''}" data-action="menu"></div><main class="main-shell" id="main" ${ui.mobile?'inert':''}>${ui.view.kind!=='chat'?`<header class="secondary-header"><button class="border-button" data-action="return-chat">${icon('chevron','back-icon')}Back to chat</button><button class="icon-button" data-action="settings" aria-label="Workspace settings">${icon('settings')}</button></header>`:''}<div class="content-layout">${ui.view.kind==='chat'?conversation():ui.view.kind==='desktop'?(window.BuddyWorkspace?.page()||'<p>Opening Buddy desktop…</p>'):ui.view.kind==='tasks'?tasksPage():ui.view.kind==='files'?filesPage():ui.view.kind==='computer'?computerPage():overview()}</div></main></div>`;document.getElementById('app').inert=!!document.querySelector('.modal-overlay,.onboarding-screen');bindView();window.dispatchEvent(new Event('buddy-view-updated'));}
function bindView(){const chatSearch=document.getElementById('chat-search');if(chatSearch)chatSearch.addEventListener('input',()=>{const position=chatSearch.selectionStart;ui.chatFilter=chatSearch.value;render();const el=document.getElementById('chat-search');el.focus();el.setSelectionRange(position,position);});const textarea=document.getElementById('message-input');if(textarea){const resize=()=>{textarea.style.height='28px';textarea.style.height=`${Math.min(140,Math.max(28,textarea.scrollHeight))}px`;};resize();textarea.addEventListener('input',()=>{state.drafts[ui.view.target]=textarea.value;save();if(!BuddyChat.active(state,ui.view.target))document.getElementById('send-message').disabled=!textarea.value.trim();resize();const row=[...document.querySelectorAll('.chat-row')].find(x=>x.dataset.id===ui.view.target),snippet=row?.querySelector('.chat-snippet');if(snippet){snippet.textContent=chatSummary(ui.view.target,findAgent(ui.view.target)?.role||'Start a conversation');snippet.classList.toggle('has-draft',!!textarea.value.trim());}});textarea.addEventListener('keydown',e=>{if(e.key==='Enter'&&!e.shiftKey&&!e.isComposing){e.preventDefault();sendMessage();}});document.getElementById('composer').addEventListener('submit',e=>{e.preventDefault();sendMessage();});document.getElementById('attachment-input').addEventListener('change',e=>{const files=Array.from(e.target.files||[]);if(files.some(f=>f.size>10*1024*1024)){showToast('Choose files smaller than 10 MB. Your message is still saved.');return;}state.attachments[ui.view.target]=[...(state.attachments[ui.view.target]||[]),...files.map(f=>({name:f.name,size:f.size}))];save();render();document.getElementById('message-input')?.focus();});}
  const fileSearch=document.getElementById('file-search');if(fileSearch)fileSearch.addEventListener('input',()=>{const position=fileSearch.selectionStart;ui.fileFilter=fileSearch.value;render();const el=document.getElementById('file-search');el.focus();el.setSelectionRange(position,position);});
}
async function sendMessage(retryOf){
  const target=retryOf?state.runs[retryOf]?.target:ui.view.target;
  if(!target||BuddyChat.active(state,target)||BuddyAgentSetup.active(state,target))return;
  if(BuddyAgentSetup.required(findAgent(target))){await BuddyAgentSetup.send(target);return;}
  if(!window.BuddyDesktop?.sendMessage){showToast('Open the Buddy Mac app to chat with your agents.');return;}
  if(!findAgent(target)&&!findGroup(target)){showToast('This chat is no longer available.');return;}
  try {
    const {run,payload}=BuddyChat.begin(state,target,{retryOf});
    save();if(ui.view.target===target){render();document.getElementById('chat-body').scrollTop=document.getElementById('chat-body').scrollHeight;document.getElementById('message-input')?.focus();}
    try {await window.BuddyDesktop.saveState(JSON.stringify(state));await window.BuddyDesktop.sendMessage(payload);}
    catch(error){BuddyChat.apply(state,{runId:run.runId,status:'failed',error:String(error.message||error)});save();refreshLiveChat(target);}
  }catch(error){showToast(error.message);}
}
function refreshLiveChat(target){
  const row=[...document.querySelectorAll('.chat-row')].find(x=>x.dataset.id===target),snippet=row?.querySelector('.chat-snippet');
  if(snippet)snippet.textContent=chatSummary(target,findAgent(target)?.role||'Start a conversation');row?.classList.toggle('is-working',agentIsThinking(target));
  refreshTeamworkDetails();
  if(ui.view.kind!=='chat'||ui.view.target!==target)return;
  const body=document.getElementById('chat-body'),nearBottom=body&&body.scrollHeight-body.scrollTop-body.clientHeight<120;
  const focus=document.activeElement,focusId=focus?.id,selectionStart=focus?.selectionStart,selectionEnd=focus?.selectionEnd;
  let messages=document.getElementById('messages');
  if(!messages&&(state.messages[target]||[]).length){const thread=body?.querySelector('.chat-thread');if(thread){thread.innerHTML='<div class="date-divider">Today</div><div id="messages"></div>';messages=document.getElementById('messages');}}
  if(messages){const samplesOpen=messages.querySelector('.sample-history')?.open;messages.innerHTML=conversationMessages(state.messages[target]||[]);const examples=messages.querySelector('.sample-history');if(examples&&samplesOpen)examples.open=true;}
  const button=document.getElementById('send-message'),running=BuddyChat.active(state,target)||BuddyAgentSetup.active(state,target);if(button){if(running&&button.classList.contains('stop-button')&&button.dataset.id===running.runId)button.disabled=running.status==='stopping';else if(!running&&!button.classList.contains('stop-button'))button.disabled=!(state.drafts[target]||'').trim();else button.outerHTML=sendControl(target,state.drafts[target]||'');}
  const restored=focusId&&document.getElementById(focusId);if(restored&&restored!==focus){restored.focus({preventScroll:true});if(typeof selectionStart==='number')restored.setSelectionRange(selectionStart,selectionEnd);}
  if(nearBottom&&body)body.scrollTop=body.scrollHeight;
}
async function stopMessage(runId){
  if(runId?.startsWith('setup:'))return BuddyAgentSetup.stop(runId.slice(6));
  const run=state.runs[runId];if(!run||!BuddyChat.busy(run.status))return;
  BuddyChat.apply(state,{runId,status:'stopping'});save();refreshLiveChat(run.target);
  try {await window.BuddyDesktop.stopMessage(runId);}
  catch(error){if(!BuddyChat.busy(run.status))return;run.status='answering';const message=state.messages[run.target].find(m=>m.runId===runId);if(message)message.status='answering';save();refreshLiveChat(run.target);showToast('Couldn’t stop the reply. Try Stop again.');}
}
function updateConnection(value){
  chatConnection={...chatConnection,...value,checking:false,connected:!!value.connected,provider:value.provider||chatConnection.provider||'chatgpt',error:value.error||''};
  window.BuddyProviders?.receive(chatConnection);
  window.BuddyOnboarding?.refreshConnection();
  const hint=document.querySelector('.composer-hint');if(hint)hint.textContent=connectionLabel();window.BuddyModels?.mount();
  const status=document.querySelector('.preview-status');if(status){status.innerHTML=`${BuddyBrands.logo(chatConnection.provider)}${chatConnection.connected?`${providerName()} connected`:`Connect ${providerName()}`}${icon('info','small-icon')}`;status.classList.toggle('connected',chatConnection.connected);}
  if(document.querySelector('[data-connection-panel]'))connection();
}
async function checkConnection(){
  if(!window.BuddyDesktop?.connectionStatus)return;
  chatConnection.checking=true;
  try{updateConnection(await window.BuddyDesktop.connectionStatus());}
  catch(error){updateConnection({connected:false,error:String(error.message||error)});}
}
async function signIn(){
  if(window.BuddyProviders){return BuddyProviders.connect(chatConnection.provider||'chatgpt');}
  const button=document.querySelector('[data-action=sign-in]');if(button){button.disabled=true;button.textContent='Opening ChatGPT…';}
  try {await window.BuddyDesktop.signIn();showToast('Finish signing in on the ChatGPT page. Buddy will connect automatically.');}
  catch(error){showToast(String(error.message||error));}
  finally {if(button?.isConnected){button.disabled=false;button.textContent='Sign in with ChatGPT';}}
}
window.addEventListener('buddy-conversation',event=>{
  const detail=event.detail;if(!detail)return;
  if(detail.type==='connection'){updateConnection(detail);return;}
  if(!['run','routine'].includes(detail.type))return;
  const run=state.runs[detail.runId];
  if(BuddyChat.apply(state,detail)){save();refreshLiveChat(run.target);}
});
function openModal(title,body,wide=false){document.getElementById('app').inert=true;if(!document.querySelector('.modal-overlay'))modalReturnFocus=document.activeElement;document.getElementById('modal-root').innerHTML=`<div class="modal-overlay"><section class="modal ${wide?'wide':''}" role="dialog" aria-modal="true" aria-labelledby="modal-title"><header class="modal-header"><h2 id="modal-title">${esc(title)}</h2><button class="icon-button" data-action="close-modal" aria-label="Close dialog">${icon('close')}</button></header><div class="modal-body">${body}</div></section></div>`;const el=document.querySelector('.modal input:not([type=checkbox]),.modal textarea,.modal select')||document.querySelector('.modal .primary-button,.modal button');el?.focus();}
function closeModal(){if(document.querySelector('#proposal-form[aria-busy=true],#team-plan-form[aria-busy=true]'))return;const teamworkRun=document.querySelector('[data-teamwork-run]')?.dataset.teamworkRun;document.getElementById('modal-root').innerHTML='';document.getElementById('app').inert=false;const replyButton=teamworkRun&&[...document.querySelectorAll('[data-action=teamwork]')].find(button=>button.dataset.id===teamworkRun);if(modalReturnFocus?.isConnected)modalReturnFocus.focus();else if(replyButton)replyButton.focus();else document.querySelector('#main h1')?.focus();modalReturnFocus=null;}
function formActions(label='Save changes'){return `<div class="modal-actions"><button type="button" class="border-button" data-action="close-modal">Cancel</button><button type="submit" class="primary-button">${label}${icon('arrow')}</button></div>`;}
function groupForm(groupId){const g=findGroup(groupId);openModal(g?'Your group, your way.':'Bring a few minds together.',`<p class="modal-description">${g?'Choose who’s in this conversation and what you’re working toward.':'Create a group around a project, a question, or an ongoing job.'}</p><form id="group-form"><div class="field"><label for="group-name">Group name</label><input id="group-name" value="${esc(g?.name||'')}" placeholder="e.g. A new idea" maxlength="70" required></div><div class="field"><label for="group-goal">Shared goal</label><textarea id="group-goal" placeholder="What do you want this team to accomplish?" maxlength="1500" required>${esc(g?.objective||'')}</textarea></div><div class="field"><label>Who’s on the team?</label>${state.agents.map(a=>`<label class="member-picker" for="member-${esc(a.id)}">${avatar(a.id)}<span>${esc(a.name)}<small>${esc(a.role)}</small></span><input id="member-${esc(a.id)}" name="members" type="checkbox" value="${esc(a.id)}" ${g?.members.includes(a.id)?'checked':''}></label>`).join('')}</div><p class="field-error" id="group-error" role="alert"></p>${formActions(g?'Save group':'Create group')}</form>`);document.getElementById('group-form').addEventListener('submit',async e=>{e.preventDefault();const name=document.getElementById('group-name').value.trim(),objective=document.getElementById('group-goal').value.trim(),members=Array.from(document.querySelectorAll('[name=members]:checked')).map(x=>x.value);if(!name||!objective||members.length===0||members.length>16){document.getElementById('group-error').textContent='Add a name, goal, and between 1 and 16 agents.';return;}if(g){const active=BuddyChat.active(state,g.id);if(active){const button=e.submitter;if(button)button.disabled=true;try{await window.BuddyDesktop.stopMessage(active.runId);BuddyChat.apply(state,{runId:active.runId,status:'stopped'});}catch(error){document.getElementById('group-error').textContent='Couldn’t stop the current reply. Try saving again.';if(button)button.disabled=false;return;}}g.name=name;g.objective=objective;g.members=members;save();closeModal();render();showToast('Group updated.');}else{const groupId=id();state.groups.push({id:groupId,name,objective,members,description:`${members.length} bots working toward one goal.`});state.messages[groupId]=[];save();closeModal();navigate('chat',groupId);showToast('Your group is ready.');}});}
function fileModal(fileId,edit=false){const f=findFile(fileId);if(!f)return;const isHTML=f.type==='HTML'&&!edit&&f.revision===1;openModal(f.name,`<div class="file-preview-meta"><span>Shared workspace / ${esc(f.name)}</span><span>Version ${f.revision} · ${esc(agentName(f.owner))}</span></div>${isHTML?`${portfolioPreview()}<p class="context-footnote">Illustrative sample. Open “Edit contents” to inspect the saved file.</p>`:`<label class="field"><span class="sr-only">File contents</span><textarea id="file-content" class="file-preview-text" aria-label="Contents of ${esc(f.name)}" ${edit?'':'readonly'}>${esc(f.content)}</textarea></label>`}<div class="modal-actions"><button class="border-button" data-action="download-file" data-id="${esc(f.id)}">${icon('download')}Download</button>${edit?`<button class="primary-button" data-action="save-file" data-id="${esc(f.id)}">Save changes${icon('check')}</button>`:`<button class="primary-button" data-action="edit-file" data-id="${esc(f.id)}">Edit contents${icon('arrow')}</button>`}</div>`,true);}
function newFile(){if(window.BuddyFiles?.native())return BuddyFiles.newFile();openModal('Start with a blank page.',`<p class="modal-description">Create a file in your team’s preview workspace.</p><form id="file-form"><div class="field"><label for="file-name">File name</label><input id="file-name" placeholder="e.g. ideas.md" maxlength="90" required></div><div class="field"><label for="file-new-content">Contents</label><textarea id="file-new-content" placeholder="Leave a note, write a brief, or begin a draft." maxlength="100000" style="min-height:170px"></textarea></div><p class="field-error" id="file-error" role="alert"></p>${formActions('Create file')}</form>`);document.getElementById('file-form').addEventListener('submit',e=>{e.preventDefault();const name=document.getElementById('file-name').value.trim();if(!name||/[\\/]/.test(name)||state.files.some(f=>f.name.toLowerCase()===name.toLowerCase())){document.getElementById('file-error').textContent='Choose a unique file name without slashes.';return;}const content=document.getElementById('file-new-content').value;const fileId=id();state.files.push({id:fileId,name,content,owner:'you',revision:1,size:`${(new Blob([content]).size/1024).toFixed(1)} KB`,type:name.endsWith('.html')?'HTML':'Text',updated:'Edited in preview'});save();closeModal();render();fileModal(fileId,true);showToast('File created in this preview.');});}
function downloadFile(fileId){const f=findFile(fileId);if(!f)return;if(window.BuddyDesktop){window.BuddyDesktop.exportFile(f.name,f.content).then(result=>{if(result.saved)showToast('File saved.');}).catch(()=>showToast('Buddy couldn’t save this file. Try another folder.'));return;}const url=URL.createObjectURL(new Blob([f.content],{type:'text/plain;charset=utf-8'}));const a=document.createElement('a');a.href=url;a.download=f.name;a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);showToast('Downloaded your preview file.');}
function taskModal(taskId){const t=findTask(taskId);if(!t)return;openModal(t.title,`<div class="detail-row"><span>Assigned to</span><strong style="display:flex;align-items:center;gap:7px">${avatar(t.agent,true)}${esc(agentName(t.agent))}</strong></div><div class="detail-row"><span>Project</span><strong>${esc(findGroup(t.group)?.name||'Personal task')}</strong></div><div class="detail-row"><span>Status</span><strong>${taskState(t.state)}</strong></div><div class="detail-section"><h3>The brief</h3><p>${esc(t.description)}</p></div>${t.file?artifactHTML(t.file):''}<div class="sample-notice" style="margin-top:18px">${icon('info')}<span>Task changes are local to this frontend preview.</span></div><div class="modal-actions"><button class="border-button" data-action="handoff" data-id="${esc(t.id)}">${icon('handoff')}Hand off</button><button class="primary-button" data-action="task-state" data-id="${esc(t.id)}" data-state="${t.state==='done'?'queued':'done'}">${t.state==='done'?'Reopen task':'Mark done'}${icon(t.state==='done'?'arrow':'check')}</button></div>`);}
function handoff(taskId){const t=findTask(taskId);if(!t)return;openModal('Pass the work forward.',`<p class="modal-description">Choose who should own “${esc(t.title)}” next. The task brief and linked file stay with it.</p><div class="handoff-options">${state.agents.filter(a=>a.id!==t.agent).map(a=>`<button class="handoff-option" data-action="assign-task" data-task="${esc(t.id)}" data-id="${esc(a.id)}">${avatar(a.id)}${esc(a.name)}${icon('arrow')}</button>`).join('')}</div><p class="context-footnote" style="margin-top:17px">This changes the task’s owner in the preview. It won’t start a model request.</p>`);}
function newTask(){openModal('Give the team a next step.',`<form id="task-form"><div class="field"><label for="task-name">Task</label><input id="task-name" placeholder="e.g. Review the project brief" maxlength="150" required></div><div class="field"><label for="task-brief">Brief</label><textarea id="task-brief" placeholder="Describe what a useful result looks like." maxlength="3000" required></textarea></div><div class="field"><label for="task-agent">Assign to</label><select id="task-agent">${state.agents.map(a=>`<option value="${esc(a.id)}">${esc(a.name)} · ${esc(a.role)}</option>`).join('')}</select></div><div class="field"><label for="task-group">Group</label><select id="task-group">${state.groups.map(g=>`<option value="${esc(g.id)}">${esc(g.name)}</option>`).join('')}</select></div><p class="field-error" id="task-error" role="alert"></p>${formActions('Create task')}</form>`);document.getElementById('task-form').addEventListener('submit',e=>{e.preventDefault();const title=document.getElementById('task-name').value.trim(),description=document.getElementById('task-brief').value.trim();if(!title||!description){document.getElementById('task-error').textContent='Add a task name and a brief.';return;}state.tasks.push({id:id(),title,description,agent:document.getElementById('task-agent').value,group:document.getElementById('task-group').value,state:'queued'});save();closeModal();navigate('tasks');showToast('Task added. It’s ready for your team.');});}
function connection(){if(window.BuddyProviders){BuddyProviders.open();return;}openModal('ChatGPT connection',`<div data-connection-panel><div class="connection-icon">${BuddyBrands.logo('chatgpt')}</div><div class="detail-row"><span>ChatGPT subscription</span><strong>${chatConnection.checking?'Connecting…':chatConnection.connected?'Connected':'Not connected'}</strong></div>${chatConnection.connected?`<p class="modal-description">Your agents are ready to talk. Each one uses their own instructions and conversation history.</p><p class="connection-note">Uses your existing ChatGPT sign-in through Codex on this Mac and counts toward your subscription’s usage limits. Choose access for connected services in Workspace settings → Connections. Group agents can coordinate work and share a combined reply. Agents can read, create, and edit the shared folder. Connect Mac app control through Connections → Desktop control. Buddy cannot connect to dots’ included cloud computers.</p>`:`<p class="modal-description">${esc(chatConnection.error||'Connect your ChatGPT subscription in the Buddy Mac app to start talking to your agents.')}</p>`}<div class="modal-actions">${window.BuddyDesktop?`${!chatConnection.connected?`<button class="primary-button" data-action="sign-in">Sign in with ChatGPT${icon('arrow')}</button>`:''}<button class="border-button" data-action="check-connection">Refresh connection</button>`:''}<button class="${chatConnection.connected?'primary-button':'border-button'}" data-action="close-modal">Done${icon('check')}</button></div></div>`);}
function computerConnect(){BuddyComputerUI.open();}
function settings(){openModal('Workspace settings',`${window.BuddyProviders?.section()||''}${window.BuddyTeamMonitorUI?.budgetSection()||''}<div class="settings-option"><div><strong>Teamwork & updates</strong><p>Supervision, proactive check-ins, and learned preferences.</p></div><button class="border-button" data-action="team-monitor">Manage</button></div><div class="settings-option"><div><strong>Browser sign-in</strong><p>Google Password Manager and private sessions.</p></div><button class="border-button" data-action="browser-signin">Manage</button></div><div class="settings-option"><div><strong>Background work</strong><p>A private browser and files on this Mac.</p></div><button class="border-button" data-action="background-work">Open</button></div><div class="settings-option"><div><strong>Your first Buddy</strong><p>${state.onboarding?.status==='completed'?esc(agentName(state.onboarding.agentId)):'Choose a name, look, and what they help with.'}</p></div><button class="border-button" data-action="onboarding">${state.onboarding?.status==='completed'?'Edit':'Set up'}</button></div><div class="settings-option"><div><strong>Connections</strong><p>Services, files, and computer access.</p></div><button class="border-button" data-action="connections">Manage</button></div><div class="settings-option"><div><strong>Local storage</strong><p>${storageAvailable?'Your changes are saved on this device.':'Unavailable. Changes are temporary.'}</p></div><span class="status-pill">${storageAvailable?'Available':'Unavailable'}</span></div>${window.BuddyDesktop?'':`<div class="settings-option"><div><strong>Start fresh</strong><p>Restore the sample team and conversations.</p></div><button class="border-button" data-action="reset-confirm">Reset preview</button></div>`}<div class="modal-actions"><button class="primary-button" data-action="close-modal">Done${icon('check')}</button></div>`);window.BuddyProviders?.mount();}
function searchModal(){openModal('Find something in your workspace.',`<label class="search-input" style="width:100%">${icon('search')}<input id="workspace-search" placeholder="Bots, groups, and files…" aria-label="Search bots, groups, and files" autocomplete="off"></label><div id="search-results"></div>`);const update=()=>{const query=document.getElementById('workspace-search').value.toLowerCase().trim();const matches=[...state.agents.map(a=>({kind:'chat',target:a.id,name:a.name,label:a.role,i:'spark'})),...state.groups.map(g=>({kind:'chat',target:g.id,name:g.name,label:'Group chat',i:'people'})),...state.files.map(f=>({kind:'file',target:f.id,name:f.name,label:'Shared file',i:'file'}))].filter(x=>`${x.name} ${x.label}`.toLowerCase().includes(query)).slice(0,10);document.getElementById('search-results').innerHTML=matches.map(x=>`<button class="group-card" data-action="search-result" data-kind="${x.kind}" data-id="${esc(x.target)}" style="margin-top:6px;padding:12px">${icon(x.i)}<span><strong>${esc(x.name)}</strong><p>${esc(x.label)}</p></span>${icon('arrow')}</button>`).join('')||'<p class="modal-description" style="padding:15px 0">No matches. Try another name.</p>';};document.getElementById('workspace-search').addEventListener('input',update);update();}
function mention(){const g=findGroup(ui.view.target);const agents=g?state.agents.filter(a=>g.members.includes(a.id)):state.agents;openModal('Bring a bot into the conversation.',`<p class="modal-description">Choose a teammate to mention in your message.</p>${agents.map(a=>`<button class="group-card" data-action="insert-mention" data-id="${esc(a.id)}">${avatar(a.id)}<span><strong>${esc(a.name)}</strong><p>${esc(a.role)}</p></span>${icon('arrow')}</button>`).join('')}`);}
function resetConfirm(){openModal('Restore the sample workspace?',`<p class="modal-description">This removes the bots, groups, messages, and file edits you created on this device. Download any files you want to keep first.</p><div class="modal-actions"><button class="border-button" data-action="close-modal">Keep my work</button><button class="primary-button" data-action="reset">Restore sample</button></div>`);}
document.addEventListener('click',e=>{if(e.target.classList.contains('drawer-overlay')){closeModal();return;}const button=e.target.closest('[data-action]');if(!button)return;const action=button.dataset.action, target=button.dataset.id;
  switch(action){
    case 'navigate':navigate(button.dataset.kind);break;
    case 'new-chat':startChat();break;
    case 'open-existing-chat':closeModal();navigate('chat',target);break;
    case 'chat-details':chatDetails();break;
    case 'workspace-details':workspaceDetails(button.dataset.section||'files');break;
    case 'open-page':closeModal();navigate(button.dataset.kind);break;
    case 'return-chat':navigate('chat',ui.lastChat||state.agents[0]?.id);break;
    case 'clear-chat-search':ui.chatFilter='';render();document.getElementById('chat-search')?.focus();break;
    case 'chat':if(document.querySelector('.modal'))closeModal();navigate('chat',target);break;
    case 'new-agent':newAgent();break;
    case 'clone-agent':newAgent(target);break;
    case 'proposals':proposalList();break;
    case 'sample-proposal':sampleProposal();break;
    case 'review-proposal':reviewProposal(target);break;
    case 'save-proposal':saveProposalDraft(target);break;
    case 'decline-proposal':declineProposal(target);break;
    case 'proposal-open-agent':closeModal();navigate('chat',target);break;
    case 'new-group':groupForm();break;
    case 'group-info':case 'objective':groupForm(target);break;
    case 'agent-info':agentInfo(target);break;
    case 'task':taskModal(target);break;
    case 'new-task':newTask();break;
    case 'task-filter':ui.taskFilter=target;render();break;
    case 'file':fileModal(target);break;
    case 'edit-file':fileModal(target,true);break;
    case 'new-file':newFile();break;
    case 'save-file':{const f=findFile(target);f.content=document.getElementById('file-content').value;f.owner='you';f.revision+=1;f.updated='Edited in preview';f.size=`${(new Blob([f.content]).size/1024).toFixed(1)} KB`;save();closeModal();render();showToast('Saved a new version in the preview workspace.');break;}
    case 'download-file':downloadFile(target);break;
    case 'handoff':handoff(target);break;
    case 'assign-task':{const t=findTask(button.dataset.task),previous=t.agent;t.agent=target;t.state='queued';state.messages[t.group]||=[];state.messages[t.group].push({id:id(),kind:'handoff',from:previous,to:target,body:`You handed “${t.title}” from ${agentName(previous)} to ${agentName(target)}`});save();closeModal();render();showToast(`${agentName(target)} now owns the task.`);break;}
    case 'task-state':{const t=findTask(target);t.state=button.dataset.state;save();closeModal();render();showToast(t.state==='done'?'Task marked done in this preview.':'Task reopened.');break;}
    case 'connection':connection();break;
    case 'check-connection':checkConnection();break;
    case 'sign-in':signIn();break;
    case 'stop-message':stopMessage(target);break;
    case 'retry-message':sendMessage(target);break;
    case 'computer-connect':computerConnect();break;
    case 'settings':case 'workspace':settings();break;
    case 'search':searchModal();break;
    case 'search-result':closeModal();if(button.dataset.kind==='file')fileModal(target);else navigate('chat',target);break;
    case 'close-modal':closeModal();break;
    case 'menu':ui.mobile=!ui.mobile;render();document.querySelector(ui.mobile?'#chat-search':'.mobile-menu-button')?.focus();break;
    case 'context':workspaceDetails('files');break;
    case 'suggest':{const input=document.getElementById('message-input');input.value=button.dataset.text;input.dispatchEvent(new Event('input'));input.focus();break;}
    case 'attach':if(window.BuddyFiles?.native())BuddyFiles.show();else document.getElementById('attachment-input')?.click();break;
    case 'remove-attachment':state.attachments[ui.view.target].splice(Number(button.dataset.index),1);save();render();document.getElementById('message-input')?.focus();break;
    case 'mention':mention();break;
    case 'teamwork':teamworkDetails(target);break;
    case 'insert-mention':{closeModal();const input=document.getElementById('message-input');input.value=`${input.value}${input.value&&!input.value.endsWith(' ')?' ':''}@${agentName(target)} `;input.dispatchEvent(new Event('input'));input.focus();break;}
    case 'reset-confirm':resetConfirm();break;
    case 'reset':if(Object.values(state.runs||{}).some(r=>BuddyChat.busy(r.status))){showToast('Stop active replies before restoring the workspace.');break;}state=BuddyChat.migrate(seed());ui.view=state.lastView;ui.lastChat=state.lastView.target;ui.chatFilter='';ui.fileFilter='';ui.taskFilter='__all__';save();closeModal();render();showToast('Sample workspace restored.');break;
  }
});
document.addEventListener('keydown',e=>{
  if(document.querySelector('#proposal-form[aria-busy=true],#team-plan-form[aria-busy=true]')&&(e.key==='Escape'||(e.metaKey||e.ctrlKey)&&['k','n',','].includes(e.key.toLowerCase()))){e.preventDefault();return;}
  const modal=document.querySelector('.modal');
  const focusContainer=modal||(ui.mobile?document.querySelector('.sidebar.mobile-open'):null);
  if(e.key==='Escape'){if(modal)closeModal();else if(ui.mobile){ui.mobile=false;render();document.querySelector('.mobile-menu-button')?.focus();}return;}
  if((e.metaKey||e.ctrlKey)&&e.key==='.'){const running=BuddyChat.active(state,ui.view.target)||BuddyAgentSetup.active(state,ui.view.target);if(running){e.preventDefault();stopMessage(running.runId);}return;}
  if((e.metaKey||e.ctrlKey)&&e.key.toLowerCase()==='k'){e.preventDefault();searchModal();return;}
  if(focusContainer&&e.key==='Tab'){const focusable=[...focusContainer.querySelectorAll('button:not([disabled]),input:not([disabled]),textarea:not([disabled]),select:not([disabled]),a[href]')].filter(x=>x.offsetParent!==null);const first=focusable[0],last=focusable.at(-1);if(e.shiftKey&&document.activeElement===first){e.preventDefault();last?.focus();}else if(!e.shiftKey&&document.activeElement===last){e.preventDefault();first?.focus();}}
});
let breakpoint=innerWidth>680?'wide':'small';
window.addEventListener('resize',()=>{const next=innerWidth>680?'wide':'small';if(next!==breakpoint){breakpoint=next;ui.mobile=false;render();}});
window.addEventListener('offline',()=>showToast('You’re offline. Your messages and drafts stay saved.'));
window.addEventListener('online',()=>{showToast('You’re back online.');checkConnection();});
save();
render();
BuddyOnboarding.boot();
BuddyAgentSetup.boot();
BuddyProposals.boot();

if(window.BuddyDesktop?.activeRuns){
  window.BuddyDesktop.activeRuns().then(snapshots=>{BuddyChat.recover(state,snapshots);save();BuddyActions.boot();if(ui.view.kind==='chat')refreshLiveChat(ui.view.target);}).catch(()=>{BuddyChat.recover(state);save();BuddyActions.boot();if(ui.view.kind==='chat')refreshLiveChat(ui.view.target);});
  checkConnection();
}

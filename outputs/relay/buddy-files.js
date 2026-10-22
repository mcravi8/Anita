(function(root){
  'use strict';
  function savedFiles(receipts=[]){
    const latest=new Map();
    for(const file of receipts){if(file&&typeof file.path==='string'&&typeof file.folderId==='string'&&typeof file.revision==='string')latest.set(`${file.folderId}:${file.path}`,file);}
    return [...latest.values()];
  }
  function fileTree(files=[],directories=[]){
    const root={children:new Map()};
    function add(path,file,omitted=false){const parts=String(path||'').split('/');if(parts.some(p=>!p||p==='.'||p==='..'))return;let node=root;for(let i=0;i<parts.length;i++){const name=parts[i];if(!node.children.has(name))node.children.set(name,{name,path:parts.slice(0,i+1).join('/'),kind:'folder',children:new Map()});node=node.children.get(name);if(i===parts.length-1){if(file){node.kind='file';node.file=file;}node.omitted=omitted;}}}
    for(const dir of directories)add(dir.path,null,dir.omitted===true);for(const file of files)add(file.path,file);
    const list=node=>[...node.children.values()].sort((a,b)=>(a.kind==='folder'?0:1)-(b.kind==='folder'?0:1)||a.name.localeCompare(b.name,undefined,{numeric:true,sensitivity:'base'})).map(n=>({...n,children:list(n)}));return list(root);
  }
  const api={savedFiles,fileTree};root.BuddyFiles=api;
  if(typeof module!=='undefined')module.exports=api;
  if(typeof document==='undefined')return;
  const native=()=>!!window.BuddyDesktop?.projectFiles;
  let folder=null,current=null,generation=0;
  const loadedFolder=()=>folder;
  const message=error=>String(error.message||error);
  const fileIcon=()=>`<span class="artifact-icon">${icon('file')}</span>`;
  const bytes=n=>n<1024?`${n} B`:`${(n/1024).toFixed(1)} KB`;
  const date=value=>new Date(value).toLocaleString([], {month:'short',day:'numeric',hour:'2-digit',minute:'2-digit'});
  function treeHTML(value){const expanded=state.fileTreeExpanded?.[value.folderId]||[];const rows=nodes=>nodes.map(n=>n.kind==='folder'?`<details class="project-tree-folder" data-file-branch="${esc(n.path)}" data-tree-folder="${esc(value.folderId)}" ${expanded.includes(n.path)?'open':''}><summary>${icon('chevron','tree-chevron')}${icon('folder')}<span>${esc(n.name)}</span>${n.omitted?'<small>Dependencies</small>':''}</summary><div class="project-tree-children">${n.omitted?'<p class="tree-empty">Dependency contents are hidden here.</p>':n.children.length?rows(n.children):'<p class="tree-empty">Empty folder</p>'}</div></details>`:`<button class="project-tree-file" data-action="project-file" data-path="${esc(n.path)}" data-folder-id="${esc(value.folderId)}" title="${esc(n.path)}">${icon('file')}<span>${esc(n.name)}</span><small>${bytes(n.file.bytes)}</small></button>`).join('');return `<div class="project-tree">${rows(fileTree(value.files,value.directories))}</div>`;}
  // A move's receipt says where it went from and to: "Moved paper.pdf → stages/S01_protocol/source_retry/paper.pdf".
  const moved=file=>`Moved ${String(file.movedFrom||'').split('/').at(-1)} → ${file.path}`;
  function cards(receipts){
    const files=savedFiles(receipts);if(!files.length)return '';
    return `<div class="saved-file-cards">${files.slice(0,3).map(file=>`<button class="artifact-card" ${file.folder?'data-action="project-files"':`data-action="project-file" data-path="${esc(file.path)}" data-folder-id="${esc(file.folderId)}"`}>${file.folder?`<span class="artifact-icon">${icon('folder')}</span>`:fileIcon()}<span><strong>${esc(file.path.split('/').at(-1))}</strong><small>${file.kind==='moved'?esc(moved(file)):`Saved by ${esc(file.actorName||'Your team')}`}</small></span>${icon('chevron')}</button>${file.warning?`<p class="file-warning">${esc(file.warning)}</p>`:''}`).join('')}${files.length>3?`<button class="drawer-bottom-link" data-action="project-files">See all ${files.length} saved files${icon('arrow')}</button>`:''}</div>`;
  }
  // Every load of the folder is announced, so the docked project panel shows what the drawer shows. Reading the folder for the dock waits for
  // a save already on its way instead of making one.
  async function loadFolder({persist=true}={}){if(persist)await persistWorkspace(state);else if(typeof persistenceQueue!=='undefined')await persistenceQueue.catch(()=>{});folder=await window.BuddyDesktop.projectFiles(state.activeFolderId);window.dispatchEvent(new CustomEvent('buddy-project-folder',{detail:folder}));return folder;}
  function folderBody(folder=loadedFolder()){
    return `<button class="project-text-link" data-buddy-desktop>Buddy desktop${icon('arrow')}</button>${folder.folders?.length>1?`<label class="project-folder-select"><span class="sr-only">Connected folder</span><select aria-label="Connected folder" data-project-folder>${folder.folders.map(f=>`<option value="${esc(f.folderId)}" ${f.folderId===folder.folderId?'selected':''}>${esc(f.name)}${f.available===false?' · Unavailable':''}</option>`).join('')}</select></label>`:''}<div class="project-folder-heading"><span class="menu-icon">${icon('folder')}</span><span><strong>${esc(folder.name)}</strong><small>${folder.files.length} files · Originals on your Mac</small></span><button class="icon-button" data-action="project-new" aria-label="Create a shared file">${icon('plus')}</button></div><div class="project-file-list">${folder.files.length||folder.directories?.length?treeHTML(folder):`<div class="project-empty"><p>A place for your team’s work.</p><small>Ask an agent to create a file, or start one yourself.</small><button class="border-button" data-action="project-new">New file${icon('plus')}</button></div>`}</div>${folder.limited?'<p class="connections-caption">Showing up to 200 files and eight folder levels. Agents can open other supported files by name.</p>':''}<details class="project-folder-details"><summary>Folder & access${icon('down')}</summary><p class="project-location">${esc(folder.location)}</p><p>Changes save to the original files here. Access is on by default; remove it in an agent’s settings.</p><div class="project-folder-actions"><button class="border-button" data-action="project-reveal">Show in Finder</button>${folder.primary!==false?'<button class="border-button" data-action="project-choose">Change shared folder</button>':'<button class="border-button" data-action="project-disconnect">Disconnect folder</button>'}${window.BuddyDesktop?.addProjectFolder?'<button class="border-button" data-action="project-add">Connect another folder</button>':''}</div><small>Documents up to 32 MB; text up to 10 MB; raw binary tools up to 1 MB.</small></details>`;
  }
  async function show(){
    if(!native())return;
    // While the project is docked beside the chat, asking for the files (the folder button, a viewer's Files) shows the dock instead of a drawer.
    if(root.BuddyProjectDock?.docked()){
      if(document.querySelector('#modal-root .modal-overlay'))closeModal();
      root.BuddyProjectDock.reveal();current=null;
      try{await loadFolder();return;}catch(error){root.BuddyProjectDock.lost();}
    }
    const token=++generation;current=null;
    openDrawer('Files','<div data-project-list><p class="connections-loading" role="status">Opening your folder…</p></div>');
    try{await loadFolder();if(token===generation&&document.querySelector('[data-project-list]'))document.querySelector('[data-project-list]').innerHTML=folderBody();}
    catch(error){if(token===generation&&document.querySelector('[data-project-list]'))document.querySelector('[data-project-list]').innerHTML=`<p class="field-error" role="alert">${esc(message(error))}</p><button class="border-button" data-action="project-files">Try again</button><button class="border-button" data-action="project-primary">Open shared folder</button><button class="border-button" data-action="project-add">Connect a folder</button>`;}
  }
  function remember(){if(!current||!document.getElementById('project-content')||!current.editing)return;state.fileDrafts||={};state.fileDrafts[`${current.folderId}:${current.path}`]=document.getElementById('project-content').value;save();}
  function viewer(){
    const structured=['docx','xlsx','pdf'].includes(current.format);
    if(structured&&current.editing){documentEditor();return;}

    const key=`${current.folderId}:${current.path}`,draft=state.fileDrafts?.[key];
    openModal(current.path.split('/').at(-1),`<div data-project-view="${esc(current.path)}"><div class="file-preview-meta"><span title="${esc(current.originalPath||current.path)}">${esc(current.path)}<small>Original file · ${current.markdownViewer?'Markdown Viewer':'Saved on your Mac'}</small></span>${!current.editing?'<button class="project-text-link" data-action="project-reload">Reload</button>':''}${BuddyDocuments.fullPreviewAvailable(current.path)?'<button class="project-text-link" data-action="document-full-preview">Full preview</button>':''}<button class="project-text-link" data-action="project-versions">Saved versions</button></div><p class="file-changed-note" role="status" hidden>The original file changed. ${current.editing?'Your draft is still here. Compare it with the latest version.':'Reload to preview the latest saved version.'}</p>${current.editing?`<label class="field"><span class="sr-only">File contents</span><textarea id="project-content" class="file-preview-text project-content" aria-label="Contents of ${esc(current.path)}">${esc(draft!==undefined?draft:current.content)}</textarea></label>`:`<div class="document-preview">${BuddyDocuments.preview(current,current.sheetIndex||0)}</div>`}${current.notice?`<p class="document-caption">${esc(current.notice)}</p>`:''}<div id="project-file-error" class="field-error" role="alert"></div><div id="project-conflict" hidden><button class="border-button" data-action="project-latest">Compare latest version</button></div><div class="modal-actions"><button class="border-button" data-action="project-files">Files</button>${current.editing?'<button class="border-button" data-action="project-edit-cancel">View saved file</button><button class="primary-button" data-action="project-save">Save to original'+icon('check')+'</button>':'<button class="border-button" data-action="project-use">Use in chat</button>'+(current.editable?'<button class="primary-button" data-action="project-edit">Edit original'+icon('arrow')+'</button>':'')+'<button class="border-button" data-action="document-reveal">Show in Finder</button>'}</div></div>`,true);
    document.getElementById('project-content')?.addEventListener('input',remember);
  }
  async function open(path,folderId){
    const token=++generation;current=null;
    openModal(path.split('/').at(-1),'<div data-project-loading><p class="connections-loading" role="status">Reading the file…</p></div>',true);
    try{
      const result=await window.BuddyDesktop.previewProjectFile({path,folderId});
      if(token!==generation||!document.querySelector('[data-project-loading]'))return;
      current={...result,editing:false};viewer();
    }catch(error){if(token===generation&&document.querySelector('[data-project-loading]'))document.querySelector('[data-project-loading]').innerHTML=`<p class="field-error" role="alert">${esc(message(error))}</p><button class="border-button" data-action="project-file" data-path="${esc(path)}" data-folder-id="${esc(folderId)}">Try again</button><button class="border-button" data-action="project-files">Files</button>`;}
  }
  async function saveFile(button){
    remember();const file=current,area=document.getElementById('project-content'),error=document.getElementById('project-file-error');if(!file||!area)return;
    button.disabled=true;error.textContent='';
    try{
      const content=area.value,result=await window.BuddyDesktop.writeProjectFile({folderId:file.folderId,path:file.path,content,expectedVersion:file.version});
      delete state.fileDrafts?.[`${file.folderId}:${file.path}`];save();
      if(current===file&&area.isConnected){await open(file.path,file.folderId);showToast(result.warning||'File saved.');}
    }catch(reason){if(error.isConnected){error.textContent=message(reason);document.getElementById('project-conflict').hidden=!message(reason).toLowerCase().includes('file changed');}}
    finally{if(button.isConnected)button.disabled=false;}
  }
  async function compare(button){
    remember();const file=current;button.disabled=true;
    try{
      const latest=await window.BuddyDesktop.readProjectFile({path:file.path,folderId:file.folderId});if(current!==file||!document.querySelector('[data-project-view]'))return;
      const draft=state.fileDrafts[`${file.folderId}:${file.path}`];current={...latest,editing:true};
      openModal('Keep both changes',`<div data-project-compare><p class="modal-description">Your draft is saved. Merge it with the current file below before saving.</p><details class="project-latest" open><summary>Current saved file${icon('down')}</summary><pre>${esc(latest.content)}</pre></details><label class="field"><span>Your draft</span><textarea id="project-content" class="file-preview-text project-content" aria-label="Merged file contents">${esc(draft)}</textarea></label><div id="project-file-error" class="field-error" role="alert"></div><div id="project-conflict" hidden><button class="border-button" data-action="project-latest">Compare latest version</button></div><div class="modal-actions"><button class="border-button" data-action="project-files">Keep draft & close</button><button class="primary-button" data-action="project-save">Save merged file${icon('check')}</button></div></div>`,true);
      document.getElementById('project-content').addEventListener('input',remember);
    }catch(reason){const error=document.getElementById('project-file-error');if(error)error.textContent=message(reason);}
    finally{if(button.isConnected)button.disabled=false;}
  }
  async function newFile(){
    try{await loadFolder();}catch(reason){showToast(message(reason));return;}
    const selected=folder,token=++generation;current=null;state.newFileDraft||={name:'',content:''};
    openModal('New file',`<form id="project-new-form"><p class="modal-description">Save in ${esc(selected.name)}.</p><div class="field"><label for="project-new-name">File name</label><input id="project-new-name" placeholder="e.g. brief.docx, budget.xlsx, notes.md" value="${esc(state.newFileDraft.name)}" maxlength="1000" required></div><div class="field"><label for="project-new-content">Contents</label><textarea id="project-new-content" class="project-content" placeholder="Write a first draft. For Excel, separate columns with tabs and rows with new lines.">${esc(state.newFileDraft.content)}</textarea></div><p class="field-error" id="project-new-error" role="alert"></p>${formActions('Create file')}</form>`);
    const form=document.getElementById('project-new-form');form.addEventListener('input',()=>{state.newFileDraft={name:document.getElementById('project-new-name').value,content:document.getElementById('project-new-content').value};save();});
    form.addEventListener('submit',async event=>{
      event.preventDefault();const button=event.submitter,name=document.getElementById('project-new-name').value.trim(),content=document.getElementById('project-new-content').value;button.disabled=true;
      try{const ext=name.split('.').pop().toLowerCase();
        if(['docx','xlsx','pdf'].includes(ext)){
          let specification=ext==='docx'?{paragraphs:content.split('\n')}:ext==='pdf'?{pages:[content]}:{sheets:[{name:'Sheet1',cells:Object.fromEntries(content.split('\n').flatMap((row,r)=>row.split('\t').map((value,c)=>[BuddyDocuments.column(c+1)+(r+1),value])))}]};
          await window.BuddyDesktop.createProjectDocument({folderId:selected.folderId,path:name,specification});
        }else await window.BuddyDesktop.writeProjectFile({folderId:selected.folderId,path:name,content,expectedVersion:''});delete state.newFileDraft;save();if(token===generation&&form.isConnected){await open(name,selected.folderId);showToast('File created.');}}
      catch(reason){if(form.isConnected)document.getElementById('project-new-error').textContent=message(reason);}
      finally{if(button.isConnected)button.disabled=false;}
    });
  }
  function documentEditor(){
    const key=`${current.folderId}:${current.path}`,saved=state.fileDocumentDrafts?.[key];
    current.edit=current.edit||saved?.edit||BuddyDocuments.initialEdit(current,current.sheetIndex||0,current.selectedCell||'A1');
    current.draftStale=!!saved&&saved.version!==current.version&&!current.draftReviewed;
    openModal(current.path.split('/').at(-1),`<div class="document-editor"><p class="modal-description">${esc(current.path)}</p>${current.draftStale?'<p class="file-changed-note">The file changed after your draft. Review it against the current preview before saving.</p><button class="border-button" data-action="document-review-draft">Use this draft on the current file</button>':''}${BuddyDocuments.editor(current,current.edit)}<p class="file-changed-note" hidden>The file has changed. Your draft is still here.</p><div id="project-file-error" class="field-error" role="alert"></div><div id="project-conflict" hidden><button class="border-button" data-action="project-file" data-path="${esc(current.path)}" data-folder-id="${esc(current.folderId)}">Open latest file</button></div><div class="modal-actions"><button class="border-button" data-action="project-edit-cancel">View saved file</button><button class="primary-button" data-action="document-save" ${current.draftStale?'disabled':''}>Save change${icon('check')}</button></div></div>`,true);
    document.querySelector('.document-editor').addEventListener('input',event=>{if(event.target.dataset.documentInput){const key=event.target.dataset.documentInput;current.edit[key]=['paragraph','page','x','y','width','height','degrees'].includes(key)?Number(event.target.value):event.target.value;rememberDocument();}});
    document.querySelector('.document-editor').addEventListener('change',event=>{
      if(event.target.id==='document-paragraph'){const value=event.target.value;current.edit=value==='append'?{op:'append_paragraph',text:''}:{op:'replace_paragraph',paragraph:Number(value),text:current.paragraphs.find(p=>p.id===Number(value))?.text||''};rememberDocument();documentEditor();}
      else if(event.target.dataset.documentInput==='op'){current.edit.degrees??=0;rememberDocument();documentEditor();}
      else if(event.target.dataset.documentInput==='page'&&current.edit.op==='set_field'){current.edit.field='';rememberDocument();documentEditor();}
      else if(event.target.dataset.documentInput==='field'){current.edit.text=current.fields.find(f=>f.page===current.edit.page&&f.name===current.edit.field)?.value||'';rememberDocument();documentEditor();}
      else if(current.format==='xlsx'&&['cell','sheet'].includes(event.target.dataset.documentInput)){const sheet=current.sheets.findIndex(s=>s.name===current.edit.sheet);current.edit=BuddyDocuments.initialEdit(current,sheet,current.edit.cell.toUpperCase());rememberDocument();documentEditor();}
    });
  }
  function rememberDocument(){if(!current?.edit||current.draftStale)return;state.fileDocumentDrafts||={};state.fileDocumentDrafts[`${current.folderId}:${current.path}`]={version:current.version,edit:current.edit};save();}
  async function saveDocument(button){
    const file=current;if(file.draftStale)return;button.disabled=true;const error=document.getElementById('project-file-error');error.textContent='';
    try{const operation=BuddyDocuments.operation(file.edit);const result=await window.BuddyDesktop.editProjectDocument({folderId:file.folderId,path:file.path,expectedVersion:file.version,operations:[operation]});delete state.fileDocumentDrafts?.[`${file.folderId}:${file.path}`];save();if(current===file){await open(file.path,file.folderId);showToast(result.warning||'Document saved.');}}
    catch(reason){if(error.isConnected){error.textContent=message(reason);document.getElementById('project-conflict').hidden=!/changed/i.test(message(reason));}}
    finally{if(button.isConnected)button.disabled=false;}
  }
  async function pdfPage(direction){const file=current,page=(file.previewPage||1)+direction;if(page<1||page>file.pageCount)return;const token=++generation;const result=await window.BuddyDesktop.previewProjectFile({path:file.path,folderId:file.folderId,page});if(current===file&&token===generation){current={...result,editing:false};viewer();}}
  async function versions(){
    remember();const file=current;if(!file)return;const token=++generation;
    openModal('Saved versions','<div data-project-versions><p class="connections-loading" role="status">Opening saved versions…</p></div>');
    try{
      const entries=await window.BuddyDesktop.projectVersions({path:file.path,folderId:file.folderId});if(token!==generation||!document.querySelector('[data-project-versions]'))return;
      document.querySelector('[data-project-versions]').innerHTML=`<p class="modal-description">${esc(file.path)}. Restore puts back the contents from before a saved change.</p>${entries.map(entry=>`<div class="project-version"><span><strong>${esc(entry.actorName)} · ${entry.kind==='moved'?`Moved here from ${esc(entry.movedFrom||'another place')}`:entry.kind==='restored'?'Restored':entry.kind==='created'?'Created':'Edited'}</strong><small>${esc(date(entry.date))}</small></span>${entry.kind==='moved'?`<button class="border-button" data-action="project-restore" data-id="${esc(entry.id)}">Move back</button>`:entry.canRestoreBefore?`<button class="border-button" data-action="project-restore" data-id="${esc(entry.id)}">Restore before edit</button>`:''}</div>`).join('')||'<p class="connections-caption">No Buddy edits yet. The next change will save this version.</p>'}<p id="project-version-error" class="field-error" role="alert"></p><div class="modal-actions"><button class="primary-button" data-action="project-file" data-path="${esc(file.path)}" data-folder-id="${esc(file.folderId)}">Back to file${icon('arrow')}</button></div>`;
    }catch(reason){if(document.querySelector('[data-project-versions]'))document.querySelector('[data-project-versions]').innerHTML=`<p class="field-error" role="alert">${esc(message(reason))}</p><button class="border-button" data-action="project-file" data-path="${esc(file.path)}" data-folder-id="${esc(file.folderId)}">Back to file</button>`;}
  }
  async function restore(button){
    const file=current;button.disabled=true;
    try{const result=await window.BuddyDesktop.restoreProjectFile({path:file.path,folderId:file.folderId,receiptId:button.dataset.id,expectedVersion:file.version});if(result?.moved){current=null;closeModal();await show();showToast(`Moved back to ${result.to}.`);}else if(button.isConnected){await open(file.path,file.folderId);showToast('Earlier contents restored.');}}
    catch(reason){const error=document.getElementById('project-version-error');if(error)error.textContent=message(reason);}
    finally{if(button.isConnected)button.disabled=false;}
  }
  let listTimer=null,listSeq=0;
  async function changed(detail){
    // While an agent writes, every streamed update says the folder changed. Reload the list once things go quiet, and never let those reloads cancel the first load of the drawer (they share no counter), or the list would not appear until the reply ended.
    // The docked panel is refreshed the same way, from the same load: it repaints itself when the load is announced.
    if(document.querySelector('[data-project-list],[data-project-dock]')){clearTimeout(listTimer);listTimer=setTimeout(async()=>{const drawer=!!document.querySelector('[data-project-list]');if(!drawer&&!document.querySelector('[data-project-dock]'))return;const token=++listSeq;try{await loadFolder({persist:drawer});if(token===listSeq&&document.querySelector('[data-project-list]')){const el=document.querySelector('[data-project-list]'),expanded=el.querySelector('details')?.open,scroll=el.closest('.modal-body').scrollTop;el.innerHTML=folderBody();const d=el.querySelector('details');if(d&&expanded)d.open=true;el.closest('.modal-body').scrollTop=scroll;}}catch(reason){showToast(message(reason));}},300);}
    if(current?.editing){const receipts=detail.files||[detail.file].filter(Boolean);if(detail.type==='project-files-changed'||receipts.some(file=>file.folderId===current.folderId&&file.path===current.path&&file.revision!==current.version)){const note=document.querySelector('.file-changed-note');if(note)note.hidden=false;const conflict=document.getElementById('project-conflict');if(conflict)conflict.hidden=false;}}
  }
  document.addEventListener('click',async event=>{
    const button=event.target.closest('[data-action]');if(!button||!native())return;
    try{switch(button.dataset.action){
      case 'project-files':remember();await show();break;
      case 'project-file':remember();await open(button.dataset.path,button.dataset.folderId);break;
      case 'project-reload':await open(current.path,current.folderId);break;
      case 'project-new':await newFile();break;
      case 'project-edit':current.editing=true;viewer();break;
      case 'document-cell':if(current?.format==='xlsx'&&current.editable){current.selectedCell=button.dataset.cell;current.edit=BuddyDocuments.initialEdit(current,current.sheetIndex||0,current.selectedCell);current.editing=true;viewer();}break;
      case 'document-review-draft':current.draftReviewed=true;current.draftStale=false;rememberDocument();documentEditor();break;
      case 'document-save':await saveDocument(button);break;
      case 'document-prev':await pdfPage(-1);break;
      case 'document-next':await pdfPage(1);break;
      case 'document-full-preview':await window.BuddyDesktop.fullProjectPreview({path:current?.path||button.dataset.path,folderId:current?.folderId||button.dataset.folderId});break;
      case 'document-reveal':await window.BuddyDesktop.revealProjectFile({path:current.path,folderId:current.folderId});break;
      case 'project-edit-cancel':remember();current.editing=false;viewer();break;
      case 'project-save':await saveFile(button);break;
      case 'project-latest':await compare(button);break;
      case 'project-versions':await versions();break;
      case 'project-restore':await restore(button);break;
      case 'project-use':{const path=current.path;closeModal();if(ui.view.kind!=='chat')navigate('chat',ui.lastChat||state.agents[0]?.id);const input=document.getElementById('message-input');input.value+=`${input.value&&!input.value.endsWith(' ')?' ':''}Use the connected file “${path}” in folderId ${current.folderId}. `;input.dispatchEvent(new Event('input'));input.focus();break;}
      case 'project-choose':case 'project-add':{remember();button.disabled=true;await persistWorkspace(state);const result=await (button.dataset.action==='project-add'?window.BuddyDesktop.addProjectFolder():window.BuddyDesktop.chooseProjectFolder());if(!result.cancelled){folder=result;state.activeFolderId=result.folderId;save();await show();}break;}
      case 'project-disconnect':{remember();button.disabled=true;await window.BuddyDesktop.disconnectProjectFolder(folder.folderId);delete state.activeFolderId;save();await show();showToast('Folder disconnected. Its files are still on your Mac.');break;}
      case 'project-primary':delete state.activeFolderId;save();await show();break;
      case 'project-reveal':await window.BuddyDesktop.showProjectFolder(folder?.folderId);break;
    }}catch(reason){showToast(message(reason));}finally{if(button.isConnected)button.disabled=false;}
  });
  document.addEventListener('change',async event=>{if(event.target.id==='document-sheet'){current.sheetIndex=Number(event.target.value);viewer();return;}if(!event.target.matches('[data-project-folder]'))return;remember();state.activeFolderId=event.target.value;save();await show();});
  window.addEventListener('buddy-conversation',event=>{if(['file','project-files-changed'].includes(event.detail?.type)||event.detail?.files?.length)changed(event.detail);});
  document.addEventListener('toggle',event=>{const el=event.target;if(!el.matches?.('[data-file-branch]'))return;const folderId=el.dataset.treeFolder;state.fileTreeExpanded||={};const next=new Set(state.fileTreeExpanded[folderId]||[]);el.open?next.add(el.dataset.fileBranch):next.delete(el.dataset.fileBranch);const values=[...next];if(JSON.stringify(values)!==JSON.stringify(state.fileTreeExpanded[folderId]||[])){state.fileTreeExpanded[folderId]=values;save();}},true);
  let polling=false;setInterval(async()=>{const file=current;if(polling||!file||!document.querySelector('[data-project-view]')||!window.BuddyDesktop?.projectFileVersion||document.hidden)return;polling=true;try{const latest=await BuddyDesktop.projectFileVersion({path:file.path,folderId:file.folderId});if(current===file&&latest.version!==file.version){const note=document.querySelector('.file-changed-note');if(note)note.hidden=false;if(file.editing){const conflict=document.getElementById('project-conflict');if(conflict)conflict.hidden=false;}}}catch(e){const el=document.getElementById('project-file-error');if(current===file&&el)el.textContent=message(e);}finally{polling=false;}},4000);
  Object.assign(api,{native,show,open,newFile,cards,treeHTML,body:folderBody,load:loadFolder,openFolder:async folderId=>{state.activeFolderId=folderId;save();await show();}});
})(typeof globalThis!=='undefined'?globalThis:this);

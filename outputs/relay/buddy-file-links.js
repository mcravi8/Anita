(function(root){
  'use strict';
  // Agents write links to the files they saved: "[the draft](</Users/me/Semester 4/Directed Research/paper_draft.md>)", "file:///…", or a path
  // relative to the folder they saved into, "[ledger](verification/ledger.md)". Such a link opens the file in Buddy's viewer when it lies inside a
  // folder the person connected. Anything else (another place on the Mac, a path that climbs out with "..", another kind of address) opens nothing.
  const scheme=/^[a-z][a-z0-9+.-]*:/i;
  const decode=value=>{try{return decodeURIComponent(value);}catch{return value;}};
  // The parts of a path with "." and ".." worked out; null when ".." would climb above where it starts.
  function parts(path){
    const out=[];
    for(const part of String(path).split('/')){if(!part||part==='.')continue;if(part==='..'){if(!out.length)return null;out.pop();}else out.push(part);}
    return out;
  }
  const usable=f=>!!f&&typeof f.folderId==='string'&&!!f.folderId&&f.available!==false;
  // The path the address names, decoded, or null when it is not a path on this Mac.
  function pathOf(href){
    let text=String(href??'').trim();
    if(text.startsWith('<')&&text.endsWith('>'))text=text.slice(1,-1).trim();
    if(!text||/[\u0000-\u001f\\]/.test(text))return null;
    if(/^file:/i.test(text)){
      let url;try{url=new URL(text);}catch{return null;}
      if(url.host&&url.host!=='localhost')return null;
      return decode(url.pathname);
    }
    if(scheme.test(text)||text.startsWith('//'))return null;
    return decode(text.replace(/[?#].*$/s,''));
  }
  function resolve(href,{folders=[],files=[],activeFolderId='',listings={}}={}){
    const path=pathOf(href);
    // A folder, not a file, or nothing at all.
    if(!path||path.endsWith('/')||/[\u0000-\u001f]/.test(path))return null;
    const roots=(Array.isArray(folders)?folders:[]).filter(usable);if(!roots.length)return null;
    if(path.startsWith('/')){
      const wanted=parts(path);if(!wanted)return null;
      let best=null;
      for(const f of roots){
        const location=String(f.location||'');if(!location.startsWith('/'))continue;
        const base=parts(location);if(!base||!base.length||wanted.length<=base.length||!base.every((p,i)=>p===wanted[i]))continue;
        // A folder connected inside another one is the more precise answer.
        if(!best||base.length>best.depth)best={folderId:f.folderId,path:wanted.slice(base.length).join('/'),depth:base.length};
      }
      return best?{folderId:best.folderId,path:best.path}:null;
    }
    // "~" is a home folder this page does not know; "www.…" is a web address written without its https://.
    if(path.startsWith('~')||/^www\./i.test(path))return null;
    const relative=parts(path);if(!relative||!relative.length)return null;
    const rel=relative.join('/'),ids=new Set(roots.map(f=>f.folderId));
    // The folder of the files the message saved: the very file first, then the one folder they all went to.
    const saved=(Array.isArray(files)?files:[]).filter(f=>f&&ids.has(f.folderId)&&typeof f.path==='string');
    const exact=saved.find(f=>f.path===rel);if(exact)return {folderId:exact.folderId,path:rel};
    const listed=roots.filter(f=>{const l=listings?.[f.folderId];return Array.isArray(l)?l.includes(rel):l instanceof Set&&l.has(rel);});
    if(listed.length)return {folderId:(listed.find(f=>f.folderId===activeFolderId)||listed[0]).folderId,path:rel};
    const savedIn=[...new Set(saved.map(f=>f.folderId))];if(savedIn.length===1)return {folderId:savedIn[0],path:rel};
    // Otherwise, the folder the person has open, then the shared (primary) one.
    const fallback=roots.find(f=>f.folderId===activeFolderId)||roots.find(f=>f.primary===true)||(roots.length===1?roots[0]:null);
    return fallback?{folderId:fallback.folderId,path:rel}:null;
  }

  // What the page knows about the connected folders. A change means links drawn before may now open, or no longer: the remembered renderings go.
  let known={folders:[],activeFolderId:'',listings:{}},signature='';
  function configure({folders,activeFolderId,listings}={}){
    const next={folders:Array.isArray(folders)?folders.filter(usable).map(f=>({folderId:f.folderId,name:String(f.name||''),location:String(f.location||''),primary:f.primary===true,available:f.available!==false})):known.folders,
      activeFolderId:typeof activeFolderId==='string'?activeFolderId:known.activeFolderId,listings:listings&&typeof listings==='object'?listings:known.listings};
    const key=JSON.stringify([next.folders,next.activeFolderId,Object.entries(next.listings).map(([id,l])=>[id,Array.isArray(l)?l:[]])]);
    known=next;if(key===signature)return false;
    signature=key;root.BuddyMarkdown?.forget?.();return true;
  }
  const link=(href,hints={})=>resolve(href,{...known,files:hints?.files||[]});
  const api={resolve,configure,link,known:()=>known};root.BuddyFileLinks=api;if(typeof module!=='undefined')module.exports=api;
  if(typeof document==='undefined'||typeof window==='undefined')return;

  // The page learns the folders from every listing the Files panel loads (which names all connected folders and their places on the Mac), and
  // once per workspace from the folder list itself. Links already on screen are drawn again when that changes what they open.
  let workspace=null,asking=false;
  const redraw=()=>{if(typeof ui!=='undefined'&&ui.view?.kind==='chat'&&typeof refreshLiveChat==='function')refreshLiveChat(ui.view.target);};
  const active=()=>typeof state!=='undefined'&&typeof state.activeFolderId==='string'?state.activeFolderId:'';
  let lastOpen='';
  function learn(folder){
    if(!folder||typeof folder!=='object')return;
    const folders=Array.isArray(folder.folders)&&folder.folders.length?folder.folders:usable(folder)&&folder.location?[folder]:known.folders;
    if(usable(folder))lastOpen=folder.folderId;
    const listings={...known.listings};if(usable(folder)&&Array.isArray(folder.files))listings[folder.folderId]=folder.files.map(f=>f?.path).filter(p=>typeof p==='string');
    if(configure({folders,activeFolderId:active()||lastOpen,listings}))redraw();
  }
  async function ask(){
    if(asking||!window.BuddyDesktop?.projectFolders||typeof state==='undefined')return;
    const w=state.conversationWorkspace||'';if(workspace===w)return;
    asking=true;
    try{const value=await window.BuddyDesktop.projectFolders();if((state.conversationWorkspace||'')!==w)return;workspace=w;
      if(configure({folders:value?.folders||[],activeFolderId:active()||lastOpen}))redraw();}
    catch{/* the folders are learned from the next listing instead */}
    finally{asking=false;}
  }
  window.addEventListener('buddy-project-folder',event=>learn(event.detail));
  window.addEventListener('buddy-view-updated',()=>{ask();if(configure({activeFolderId:active()||lastOpen}))redraw();});
  // A folder connected or disconnected: ask again.
  window.addEventListener('buddy-conversation',event=>{if(event.detail?.type==='project-files-changed'){workspace=null;ask();}});
  // A file link is a link only to the keyboard and the eye; Buddy's file viewer opens it (buddy-files.js handles data-action="project-file").
  document.addEventListener('click',event=>{const a=event.target.closest?.('a[data-action="project-file"]');if(a)event.preventDefault();},true);

  // The message being drawn gives its links their folder: the files it saved. Any Markdown drawn for it (its reply, its details) reads that.
  if(typeof root.messageHTML==='function'&&root.BuddyMarkdown?.within){
    const original=root.messageHTML;
    root.messageHTML=function(m){return root.BuddyMarkdown.within({files:Array.isArray(m?.files)?m.files:[]},()=>original.apply(this,arguments));};
  }
  ask();
})(typeof globalThis!=='undefined'?globalThis:this);

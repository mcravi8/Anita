(function(root){
  'use strict';
  // A conversation opens at its newest message, not at the top of its history. Later updates keep the reader's place (the page already follows
  // new messages only when the reader is near the bottom).
  if(typeof document==='undefined')return;
  let opened=null;
  const toBottom=()=>{const body=document.getElementById('chat-body');if(body)body.scrollTop=body.scrollHeight;};
  window.addEventListener('buddy-view-updated',()=>{
    if(typeof ui==='undefined'||ui.view?.kind!=='chat'){opened=null;return;}
    if(opened===ui.view.target)return;
    opened=ui.view.target;
    toBottom();requestAnimationFrame(toBottom);setTimeout(toBottom,200);
  });
  // The first page draw happens before this file loads, so the chat that is already open gets the same treatment.
  setTimeout(()=>{if(typeof ui!=='undefined'&&ui.view?.kind==='chat'&&opened===null){opened=ui.view.target;toBottom();requestAnimationFrame(toBottom);}},0);
})(typeof globalThis!=='undefined'?globalThis:this);

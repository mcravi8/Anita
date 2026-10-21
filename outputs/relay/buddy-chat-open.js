(function(root){
  'use strict';
  // A conversation opens at its newest message, not at the top of its history, and keeps the reader's place when the page redraws.
  //
  // The page redraws the whole view for many reasons (a message arrives, a setting changes, a worker reports in), and each redraw builds a new
  // message list that starts at the top. So this wraps the redraw: it notes where the list was, and afterwards puts the new one back (at the
  // bottom if the reader was near it or the chat has just been opened).
  if(typeof document==='undefined'||typeof window.render!=='function')return;
  const body=()=>document.getElementById('chat-body');
  const toBottom=()=>{const el=body();if(el)el.scrollTop=el.scrollHeight;};
  const original=window.render;
  // Which chat the list on screen belongs to. (The view is changed before the redraw, so it cannot say what is still on screen.)
  let shown=null;
  window.render=function(...args){
    const el=body(),before=el&&shown?{target:shown,top:el.scrollTop,near:el.scrollHeight-el.scrollTop-el.clientHeight<120}:null;
    const result=original.apply(this,args);
    const chat=typeof ui!=='undefined'&&ui.view?.kind==='chat'&&!!body();
    shown=chat?ui.view.target:null;
    if(!chat)return result;
    if(before&&before.target===shown&&!before.near){body().scrollTop=before.top;return result;}
    // Newly opened, or the reader was already at the bottom: show the newest message. Late layout (rendered text, images) can make the list
    // taller a moment later, so look again.
    toBottom();requestAnimationFrame(toBottom);setTimeout(toBottom,150);
    return result;
  };
  // The first draw happens before this file loads, so the chat that is already open gets the same treatment.
  setTimeout(()=>{if(typeof ui!=='undefined'&&ui.view?.kind==='chat'&&body()){if(shown===null)shown=ui.view.target;toBottom();requestAnimationFrame(toBottom);}},0);
})(typeof globalThis!=='undefined'?globalThis:this);

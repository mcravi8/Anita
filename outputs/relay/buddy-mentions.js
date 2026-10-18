(function(root){
  'use strict';
  function query(text,caret){
    const before=String(text).slice(0,caret),match=before.match(/(?:^|\s)@([^@\n]{0,60})$/u);
    return match?{start:before.lastIndexOf('@'),end:caret,text:match[1]}:null;
  }
  function finished(agents,q){return !!q&&agents.some(a=>q.text.toLocaleLowerCase().startsWith(a.name.toLocaleLowerCase()+' '))&&!agents.some(a=>a.name.toLocaleLowerCase().startsWith(q.text.toLocaleLowerCase()));}
  function matches(agents,q){
    if(!q)return [];
    if(finished(agents,q))return [];
    const term=q.text.toLocaleLowerCase();
    return agents.filter(a=>typeof a.id==='string'&&typeof a.name==='string'&&(' '+a.name.toLocaleLowerCase()).includes(' '+term)).sort((a,b)=>Number(!a.name.toLocaleLowerCase().startsWith(term))-Number(!b.name.toLocaleLowerCase().startsWith(term))||a.name.localeCompare(b.name));
  }
  function insert(text,q,name){const suffix=text.slice(q.end);return {text:text.slice(0,q.start)+'@'+name+(suffix.startsWith(' ')?'':' ')+suffix,caret:q.start+name.length+2};}
  const api={query,matches,insert,finished};root.BuddyMentions=api;if(typeof module!=='undefined')module.exports=api;
  if(typeof document==='undefined')return;
  let input=null,menu=null,items=[],active=0,current=null,dismissed='';
  function close(){menu?.remove();menu=null;items=[];input?.setAttribute('aria-expanded','false');input?.removeAttribute('aria-activedescendant');}
  function place(){
    if(!menu||!input?.isConnected)return;
    const r=input.getBoundingClientRect(),width=Math.min(340,innerWidth-24),above=r.top-20,below=innerHeight-r.bottom-20;
    menu.style.width=width+'px';menu.style.left=Math.max(12,Math.min(r.left,innerWidth-width-12))+'px';menu.style.maxHeight=Math.max(50,Math.min(270,Math.max(above,below)))+'px';
    const height=menu.getBoundingClientRect().height;menu.style.top=(above>=height?Math.max(12,r.top-height-10):Math.min(innerHeight-height-12,r.bottom+10))+'px';
  }
  function paint(){
    menu.innerHTML=items.length?items.map((a,i)=>`<button type="button" role="option" id="buddy-mention-${i}" aria-selected="${i===active}" tabindex="-1" data-mention-choice="${esc(a.id)}">${avatar(a.id,true)}<span><strong>${esc(a.name)}</strong><small>${esc(a.role||'Agent')}</small></span></button>`).join(''):'<p role="status">No matching agents</p>';
    place();
    if(items.length){input.setAttribute('aria-activedescendant',`buddy-mention-${active}`);const row=menu.children[active];if(row.offsetTop<menu.scrollTop)menu.scrollTop=row.offsetTop;else if(row.offsetTop+row.offsetHeight>menu.scrollTop+menu.clientHeight)menu.scrollTop=row.offsetTop+row.offsetHeight-menu.clientHeight;}else input.removeAttribute('aria-activedescendant');
  }
  function update(){
    if(!input?.isConnected||document.activeElement!==input){close();return;}
    current=query(input.value,input.selectionStart);
    if(!current||finished(state.agents,current)||input.selectionStart!==input.selectionEnd||dismissed===input.value+'|'+input.selectionStart){close();return;}
    items=matches(state.agents,current);active=0;
    if(/\s$/.test(current.text)&&!items.length){close();return;}
    if(!menu){menu=document.createElement('div');menu.id='buddy-agent-mentions';menu.className='buddy-mention-menu';menu.setAttribute('role','listbox');menu.setAttribute('aria-label','Agents');document.body.append(menu);}
    input.setAttribute('aria-expanded','true');paint();
  }
  function choose(id){
    const a=state.agents.find(a=>a.id===id);if(!a||!current)return;
    const value=insert(input.value,current,a.name);input.value=value.text;input.focus();input.setSelectionRange(value.caret,value.caret);dismissed=value.text+'|'+value.caret;close();input.dispatchEvent(new Event('input',{bubbles:true}));
  }
  api.attach=el=>{
    close();input=el;dismissed='';el.setAttribute('aria-autocomplete','list');el.setAttribute('aria-controls','buddy-agent-mentions');el.setAttribute('aria-expanded','false');
    el.addEventListener('input',update);el.addEventListener('click',update);
    el.addEventListener('keyup',e=>{if(['ArrowLeft','ArrowRight','Home','End'].includes(e.key))update();});
    el.addEventListener('keydown',e=>{
      if(!menu||e.isComposing)return;
      if(e.key==='Escape'){e.preventDefault();e.stopPropagation();dismissed=el.value+'|'+el.selectionStart;close();}
      else if(items.length&&['ArrowDown','ArrowUp'].includes(e.key)){e.preventDefault();active=(active+(e.key==='ArrowDown'?1:items.length-1))%items.length;paint();}
      else if(items.length&&['Enter','Tab'].includes(e.key)&&!e.shiftKey){e.preventDefault();e.stopPropagation();choose(items[active].id);}
    },true);
  };
  api.open=el=>{if(!el)return;el.focus();const q=query(el.value,el.selectionStart);if(!q||finished(state.agents,q)){const at=el.selectionStart,tail=el.selectionEnd,prefix=at&&!/\s/.test(el.value[at-1])?' @':'@';el.setRangeText(prefix,at,tail,'end');el.dispatchEvent(new Event('input',{bubbles:true}));}dismissed='';update();};
  document.addEventListener('pointerdown',e=>{if(e.target.closest('[data-mention-choice]'))e.preventDefault();else if(menu&&!e.target.closest('.composer-line'))close();});
  document.addEventListener('click',e=>{const row=e.target.closest('[data-mention-choice]');if(row)choose(row.dataset.mentionChoice);});
  document.addEventListener('focusin',e=>{if(menu&&e.target!==input&&!menu.contains(e.target))close();});
  window.addEventListener('resize',place);
})(typeof globalThis!=='undefined'?globalThis:this);

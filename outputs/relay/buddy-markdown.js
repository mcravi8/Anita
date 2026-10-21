(function(root){
  'use strict';
  const escape=value=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  // A chat is drawn again whenever anything in it changes, and most of its messages have not. Rendering each one once costs a fraction of drawing a long chat on
  // every streamed word, so finished text is remembered (the newest few hundred) and the parser is built once.
  let parser=null;const remembered=new Map();
  // The message being drawn, for its links to files: a relative link is read in the folder of the files that message saved (buddy-file-links.js).
  let ambient=null,current=null;
  const hintsOf=context=>(Array.isArray(context?.files)?context.files:[]).filter(f=>f&&typeof f.folderId==='string'&&typeof f.path==='string');
  const hintKey=context=>hintsOf(context).map(f=>`${f.folderId}:${f.path}`).sort().join('|');
  function within(context,fn){const prior=ambient;ambient=context||null;try{return fn();}finally{ambient=prior;}}
  const shown=href=>{try{return decodeURI(href);}catch{return String(href);}};
  // CommonMark ends a link's address at a space, so "[draft](/Users/me/Semester 4/draft.md)" is no link at all. Agents write paths with spaces
  // that way; outside code, such an address is put in angle brackets, which is how Markdown writes an address with spaces.
  function bracketPaths(text){
    if(!text.includes(']('))return text;
    return text.split(/(```[\s\S]*?(?:```|$)|~~~[\s\S]*?(?:~~~|$)|`[^`\n]*`)/).map((part,i)=>i%2?part:part.replace(/\]\(((?:\/|file:\/\/)[^()<>\n]*?)\)/g,(all,address)=>{
      const titled=address.match(/^(.*?)(\s+(?:"[^"\n]*"|'[^'\n]*'))$/),path=(titled?titled[1]:address).trim();
      return /\s/.test(path)?`](<${path}>${titled?titled[2]:''})`:all;
    })).join('');
  }
  function render(value,context=ambient){
    const text=String(value??'');
    if(!text)return '';
    if(!root.marked||!root.DOMPurify)return escape(text).replace(/\n/g,'<br>');
    const key=`${hintKey(context)}\u0000${text}`,known=remembered.get(key);if(known!==undefined)return known;
    try{
      parser||=new root.marked.Marked({gfm:true,breaks:true,renderer:{
        html({text}){return escape(text);},
        image({text}){return escape(text);},
        link({href,title,tokens}){
          const label=this.parser.parseInline(tokens);
          // A file inside a connected folder opens in Buddy's viewer, like the file cards do.
          const file=root.BuddyFileLinks?.link?.(href,{files:hintsOf(current)});
          if(file)return `<a href="#" data-action="project-file" data-path="${escape(file.path)}" data-folder-id="${escape(file.folderId)}" title="${escape(title||file.path)}">${label}</a>`;
          let url=null;try{url=new URL(href);}catch{}
          if(url&&['https:','http:','mailto:'].includes(url.protocol))return `<a href="${escape(url.href)}"${title?` title="${escape(title)}"`:''} target="_blank" rel="noopener noreferrer">${label}</a>`;
          // Any other place on the Mac keeps its words, with the path to read on hover. Other kinds of address keep just the words.
          const path=!url&&!String(href||'').startsWith('#')||url?.protocol==='file:';
          return path&&href?`<span title="${escape(shown(href))}">${label}</span>`:label;
        }
      }});
      current=context;
      let parsed;try{parsed=parser.parse(bracketPaths(text));}finally{current=null;}
      const clean=root.DOMPurify.sanitize(parsed,{
        ALLOWED_TAGS:['p','br','strong','em','del','blockquote','ul','ol','li','h1','h2','h3','h4','h5','h6','pre','code','hr','table','thead','tbody','tr','th','td','a','span'],
        ALLOWED_ATTR:['href','title','target','rel','data-action','data-path','data-folder-id'],ALLOW_DATA_ATTR:false,ALLOW_ARIA_ATTR:false
      });
      const html=clean.replace(/<table>/g,'<div class="reply-table"><table>').replace(/<\/table>/g,'</table></div>');
      remembered.set(key,html);if(remembered.size>400)remembered.delete(remembered.keys().next().value);
      return html;
    }catch{return escape(text).replace(/\n/g,'<br>');}
  }
  // The folders changed (buddy-file-links.js): what a link opens may have changed, so nothing remembered is reused.
  function forget(){remembered.clear();}
  // Group messages saved earlier start with the speaker's name twice ("**Chief** **Chief:** ..."), which read as "ChiefChief:" in the sidebar. The chat already shows who is
  // speaking, so a preview keeps the name once.
  function speakerOnce(value){
    let text=String(value??'').replace(/^\s*\*\*([^*\n:]{1,40})\*\*\s*\*{0,2}\1\s*:\s*\*{0,2}\s*/u,'$1: ');
    if((text.match(/\*\*/g)||[]).length%2===1)text=text.replace(/\*\*(?!.*\*\*)/su,'');
    return text;
  }
  function preview(value){
    const text=speakerOnce(value);
    if(!root.document)return text;
    const el=root.document.createElement('div');el.innerHTML=render(text,null);
    return el.textContent.replace(/\s+/g,' ').trim();
  }
  root.BuddyMarkdown={render,preview,within,forget};
})(typeof globalThis!=='undefined'?globalThis:this);

(function(root){
  'use strict';
  const escape=value=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  // A chat is drawn again whenever anything in it changes, and most of its messages have not. Rendering each one once costs a fraction of drawing a long chat on
  // every streamed word, so finished text is remembered (the newest few hundred) and the parser is built once.
  let parser=null;const remembered=new Map();
  function render(value){
    const text=String(value??'');
    if(!text)return '';
    if(!root.marked||!root.DOMPurify)return escape(text).replace(/\n/g,'<br>');
    const known=remembered.get(text);if(known!==undefined)return known;
    try{
      parser||=new root.marked.Marked({gfm:true,breaks:true,renderer:{
        html({text}){return escape(text);},
        image({text}){return escape(text);},
        link({href,title,tokens}){
          const label=this.parser.parseInline(tokens);
          try{const url=new URL(href);if(!['https:','http:','mailto:'].includes(url.protocol))return label;
            return `<a href="${escape(url.href)}"${title?` title="${escape(title)}"`:''} target="_blank" rel="noopener noreferrer">${label}</a>`;
          }catch{return label;}
        }
      }});
      const clean=root.DOMPurify.sanitize(parser.parse(text),{
        ALLOWED_TAGS:['p','br','strong','em','del','blockquote','ul','ol','li','h1','h2','h3','h4','h5','h6','pre','code','hr','table','thead','tbody','tr','th','td','a'],
        ALLOWED_ATTR:['href','title','target','rel'],ALLOW_DATA_ATTR:false,ALLOW_ARIA_ATTR:false
      });
      const html=clean.replace(/<table>/g,'<div class="reply-table"><table>').replace(/<\/table>/g,'</table></div>');
      remembered.set(text,html);if(remembered.size>400)remembered.delete(remembered.keys().next().value);
      return html;
    }catch{return escape(text).replace(/\n/g,'<br>');}
  }
  function preview(value){
    if(!root.document)return String(value??'');
    const el=root.document.createElement('div');el.innerHTML=render(value);
    return el.textContent.replace(/\s+/g,' ').trim();
  }
  root.BuddyMarkdown={render,preview};
})(typeof globalThis!=='undefined'?globalThis:this);

(function(root){
  'use strict';
  const escape=value=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const column=n=>{let s='';for(;n;n=Math.floor((n-1)/26))s=String.fromCharCode(65+(n-1)%26)+s;return s;};
  function position(ref){const m=/^([A-Z]{1,3})([1-9]\d{0,6})$/.exec(ref);if(!m)return null;return {row:+m[2],col:[...m[1]].reduce((n,c)=>n*26+c.charCodeAt(0)-64,0)};}
  function grid(sheet){
    const cells=sheet.cells||[],indexed=new Map(cells.map(c=>[c.cell,c]));let rows=1,cols=1;
    for(const c of cells){const p=position(c.cell);if(p){rows=Math.max(rows,p.row);cols=Math.max(cols,p.col);}}
    const limited=rows>200||cols>30;rows=Math.min(rows,200);cols=Math.min(cols,30);
    return `<div class="document-grid"><table><thead><tr><th aria-label="Row number"></th>${Array.from({length:cols},(_,i)=>`<th>${column(i+1)}</th>`).join('')}</tr></thead><tbody>${Array.from({length:rows},(_,r)=>`<tr><th>${r+1}</th>${Array.from({length:cols},(_,c)=>{const ref=column(c+1)+(r+1),cell=indexed.get(ref),value=cell?.formula&&!cell.cached?'='+cell.formula:cell?.value??'';return `<td><button type="button" data-action="document-cell" data-cell="${ref}" title="${escape(cell?.formula?'='+cell.formula:ref)}">${escape(value)}</button></td>`;}).join('')}</tr>`).join('')}</tbody></table></div>${limited||sheet.limited?'<p class="document-caption">Preview shows the first 200 rows and 30 columns. Other cells can be edited by address or through chat.</p>':''}`;
  }
  function htmlDocument(text){
    const clean=root.DOMPurify?root.DOMPurify.sanitize(text,{WHOLE_DOCUMENT:true,FORBID_TAGS:['script','iframe','object','embed','form','base','meta','link'],FORBID_ATTR:['srcset','action','formaction']}):`<pre>${escape(text)}</pre>`;
    return `<!doctype html><html><head><meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:; font-src 'none'; form-action 'none'; base-uri 'none';"><style>body{margin:24px;font-family:system-ui;overflow-wrap:anywhere}img{max-width:100%}</style></head><body>${clean}</body></html>`;
  }
  function preview(file,sheetIndex=0){
    if(file.markdownViewer){
      const viewer=file.markdownViewer;
      let clean=root.DOMPurify?root.DOMPurify.sanitize(viewer.html,{FORBID_TAGS:['script','style','iframe','object','embed','form','base','meta','link'],FORBID_ATTR:['srcset','action','formaction','target','ping','download','autofocus']}):`<pre>${escape(file.content)}</pre>`;
      if(root.document){const template=document.createElement('template');template.innerHTML=clean;for(const a of template.content.querySelectorAll('a[href]')){const href=a.getAttribute('href');if(!href.startsWith('#')){a.title=href;a.removeAttribute('href');}}for(const img of template.content.querySelectorAll('img'))if(!/^data:image\/(png|jpeg|gif|webp);base64,/i.test(img.getAttribute('src')||'')){img.removeAttribute('src');img.alt=img.alt||'Image unavailable';}clean=template.innerHTML;}
      const outline=(viewer.headings||[]).length?`<details class="buddy-outline"><summary>Outline</summary><nav aria-label="Document outline">${viewer.headings.slice(0,100).map(h=>`<a href="#${escape(h.id)}" style="padding-left:${Math.min(5,Math.max(0,h.level-1))*12}px">${escape(h.title)}</a>`).join('')}</nav></details>`:'';
      const html=`<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'; font-src data:; form-action 'none'; base-uri 'none';"><style>${String(viewer.style||'').replace(/<\/style/gi,'')}\n:root{--top-inset:0px}body{margin:0;font-size:15px}#content{padding:28px;max-width:760px;margin:auto}.buddy-outline{font:12px/1.6 -apple-system,sans-serif;margin-bottom:24px;color:var(--secondary)}.buddy-outline summary{cursor:pointer}.buddy-outline nav{display:grid;gap:6px;margin-top:12px}.buddy-outline a{color:var(--link);text-decoration:none}img{max-width:100%}</style></head><body><article id="content">${outline}${clean}</article></body></html>`;
      return `<iframe class="document-markdown" title="${escape(file.path.split('/').pop())} · Markdown Viewer" sandbox="" referrerpolicy="no-referrer" srcdoc="${escape(html)}"></iframe><p class="markdown-viewer-caption">${escape(viewer.caption||'Markdown Viewer')}</p>`;
    }
    if(file.format==='docx'){
      const paragraphs=new Map((file.paragraphs||[]).map(p=>[p.id,p]));
      const render=p=>{if(!p)return '';const heading=/heading\s*([1-6])/i.exec(p.style||''),tag=p.style==='Title'?'h1':heading?'h'+Math.min(6,Number(heading[1])+1):'p';return `<${tag} data-paragraph="${p.id}">${escape(p.text)||'<br>'}</${tag}>`;};
      const blocks=file.blocks?.length?file.blocks.map(b=>b.type==='table'?`<div class="document-word-table"><table><tbody>${b.rows.map(row=>`<tr>${row.map(cell=>`<td>${cell.map(id=>render(paragraphs.get(id))).join('')}</td>`).join('')}</tr>`).join('')}</tbody></table></div>`:render(paragraphs.get(b.id))).join(''):(file.paragraphs||[]).map(render).join('');
      return `<article class="document-paper">${blocks}</article>`;
    }
    if(file.format==='xlsx'){const sheet=file.sheets?.[sheetIndex];return sheet?`<label class="document-sheet-label"><span class="sr-only">Sheet</span><select id="document-sheet">${file.sheets.map((s,i)=>`<option value="${i}" ${i===sheetIndex?'selected':''}>${escape(s.name)}</option>`).join('')}</select></label>${grid(sheet)}`:'<p>No sheets in this workbook.</p>';}
    if(file.format==='pdf')return `<div class="document-page-controls"><button class="border-button" data-action="document-prev" ${file.previewPage<=1?'disabled':''}>Previous</button><span>Page ${file.previewPage||1} of ${file.pageCount}</span><button class="border-button" data-action="document-next" ${file.previewPage>=file.pageCount?'disabled':''}>Next</button></div>${file.image?`<img class="document-page-image" src="${escape(file.image)}" alt="PDF page ${file.previewPage||1}">`:'<p>No page image is available.</p>'}`;
    if(file.format==='image')return `<img class="document-media-image" src="${escape(file.image)}" alt="${escape(file.path)}">`;
    if(file.format==='text'){
      if(file.markdownPlain)return `<pre class="document-code">${escape(file.content)}</pre>`;
      const ext=file.path.split('.').pop().toLowerCase();
      if(['md','markdown','mdown'].includes(ext))return `<article class="document-paper reply-markdown">${root.BuddyMarkdown?.render(file.content)||escape(file.content)}</article>`;
      if(['html','htm'].includes(ext))return `<iframe class="document-html" title="HTML preview" sandbox="" referrerpolicy="no-referrer" srcdoc="${escape(htmlDocument(file.content))}"></iframe>`;
      return `<pre class="document-code">${escape(file.content)}</pre>`;
    }
    return `<div class="document-unsupported"><p>${escape(file.notice)}</p><small>${escape(file.path.split('.').pop().toUpperCase())} · ${escape(file.bytes)} bytes</small></div>`;
  }
  function initialEdit(file,sheetIndex=0,selectedCell='A1'){
    if(file.format==='docx')return {op:'replace_paragraph',paragraph:0,text:file.paragraphs?.[0]?.text||''};
    if(file.format==='xlsx'){const sheet=file.sheets?.[sheetIndex],cell=sheet?.cells.find(c=>c.cell===selectedCell);return {op:'set_cell',sheet:sheet?.name||'',cell:selectedCell,value:cell?.formula?'='+cell.formula:cell?.value||'',valueType:cell?.formula?'formula':cell?.type==='n'&&cell.value!==''?'number':cell?.type==='b'?'boolean':'text'};}
    return {op:'add_text',page:file.previewPage||1,text:'',x:54,y:54,width:300,height:60};
  }
  function operation(edit){
    const out={...edit};delete out.valueType;
    if(edit.op==='set_cell'){
      if(edit.valueType==='number'){if(String(edit.value).trim()===''||!Number.isFinite(Number(edit.value)))throw Error('Enter a valid number.');out.value=Number(edit.value);}
      else if(edit.valueType==='boolean'){if(!['true','false'].includes(String(edit.value).toLowerCase()))throw Error('Enter true or false.');out.value=String(edit.value).toLowerCase()==='true';}
      else if(edit.valueType==='formula'){out.value=String(edit.value).startsWith('=')?edit.value:'='+edit.value;}
    }
    return out;
  }
  function editor(file,edit){
    const input=(key,label,type='text')=>`<label class="field"><span>${label}</span><input data-document-input="${key}" type="${type}" value="${escape(edit[key]??'')}" ${type==='number'?'step="any"':''}></label>`;
    const text=`<label class="field"><span>${file.format==='xlsx'?'Value':'Text'}</span><textarea class="document-edit-text" data-document-input="${file.format==='xlsx'?'value':'text'}">${escape(file.format==='xlsx'?edit.value:edit.text)}</textarea></label>`;
    if(file.format==='docx')return `<label class="field"><span>Paragraph</span><select id="document-paragraph"><option value="append" ${edit.op==='append_paragraph'?'selected':''}>Add a new paragraph</option>${file.paragraphs.map(p=>`<option value="${p.id}" ${edit.op==='replace_paragraph'&&p.id===edit.paragraph?'selected':''}>${p.id+1}. ${escape(p.text.slice(0,72)||'Empty paragraph')}</option>`).join('')}</select></label>${text}`;
    if(file.format==='xlsx')return `<div class="document-edit-row"><label class="field"><span>Sheet</span><select data-document-input="sheet">${file.sheets.map(s=>`<option ${s.name===edit.sheet?'selected':''}>${escape(s.name)}</option>`).join('')}</select></label>${input('cell','Cell')}</div><label class="field"><span>Value type</span><select data-document-input="valueType">${['text','number','formula','boolean'].map(t=>`<option value="${t}" ${edit.valueType===t?'selected':''}>${t[0].toUpperCase()+t.slice(1)}</option>`).join('')}</select></label>${text}`;
    const fields=file.fields||[];
    return `<div class="document-edit-row"><label class="field"><span>Change</span><select data-document-input="op">${[['add_text','Add text'],['highlight','Highlight area'],['set_field','Fill form field'],['rotate_page','Rotate page'],['append_page','Add text page']].map(([v,label])=>`<option value="${v}" ${v===edit.op?'selected':''}>${label}</option>`).join('')}</select></label>${edit.op==='append_page'?'':input('page','Page','number')}</div>${edit.op==='set_field'?`<label class="field"><span>Form field</span><select data-document-input="field"><option value="">Choose a field</option>${fields.filter(f=>f.page===+edit.page).map(f=>`<option value="${escape(f.name)}" ${f.name===edit.field?'selected':''}>${escape(f.name)}</option>`).join('')}</select></label>`:''}${['add_text','set_field','append_page'].includes(edit.op)?text:''}${['add_text','highlight'].includes(edit.op)?`<details><summary>Position on page</summary><p class="document-caption">Points measured from the top left.</p><div class="document-edit-row">${input('x','Left','number')}${input('y','Top','number')}${input('width','Width','number')}${input('height','Height','number')}</div></details>`:''}${edit.op==='rotate_page'?`<label class="field"><span>Rotation</span><select data-document-input="degrees">${[0,90,180,270].map(n=>`<option value="${n}" ${n===edit.degrees?'selected':''}>${n}°</option>`).join('')}</select></label>`:''}`;
  }
  function fullPreviewAvailable(path){return ['docx','pdf','doc','rtf','odt','pages','png','jpg','jpeg','gif','heic','webp','tiff','bmp','mp4','mov','m4v','mp3','m4a','wav','aiff','zip'].includes(path.split('.').pop().toLowerCase());}
  const api={fullPreviewAvailable,preview,editor,initialEdit,operation,position,column,htmlDocument};root.BuddyDocuments=api;if(typeof module!=='undefined')module.exports=api;
})(typeof globalThis!=='undefined'?globalThis:this);

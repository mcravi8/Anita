import test from 'node:test';
import assert from 'node:assert/strict';
import {chromium} from 'playwright-core';
import {mkdir,rm,cp,readFile} from 'node:fs/promises';
import {existsSync} from 'node:fs';
import {execFileSync} from 'node:child_process';
import {randomUUID} from 'node:crypto';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

test('Buddy desktop groups original folders and a repository, keeps failed edits, and embeds the actual Markdown Viewer',{skip:process.platform!=='darwin'||!existsSync('/Applications/Google Chrome.app'),timeout:180000},async()=>{
 const directory=path.join(tmpdir(),'buddy-desktop-ui-'+randomUUID()+'.noindex');await mkdir(directory,{mode:0o700});let context;
 try{
  const source=fileURLToPath(new URL('../../buddy-mac/',import.meta.url));await cp(path.join(source,'MarkdownViewer'),path.join(directory,'MarkdownViewer'),{recursive:true});
  const binary=path.join(directory,'viewer-test'),previewPath=path.join(directory,'preview.json');
  execFileSync('xcrun',['swiftc','-framework','JavaScriptCore',...['BuddyMarkdownRenderer.swift','BuddyMarkdownPreview.swift','BuddyDocuments.swift','BuddyProjectFiles.swift','tests/MarkdownPreview.swift'].map(n=>path.join(source,n)),'-o',binary],{env:{...process.env,CLANG_MODULE_CACHE_PATH:path.join(directory,'cache')},stdio:'pipe',timeout:120000});
  execFileSync(binary,[previewPath],{stdio:'pipe',timeout:30000});const nativePreview=JSON.parse(await readFile(previewPath,'utf8'));
  context=await chromium.launchPersistentContext(path.join(directory,'browser'),{channel:'chrome',headless:true,viewport:{width:1200,height:900}});
  const requests=[];await context.route('**/*',r=>{if(/^https?:/.test(r.request().url())){requests.push(r.request().url());return r.abort();}return r.continue();});
  const page=context.pages()[0];await page.goto(new URL('../../relay/index.html',import.meta.url).href);
  await page.evaluate(preview=>{
   document.getElementById('onboarding-root').innerHTML='';closeModal();
   state.agents=[{id:'chief',name:'Chief',role:'Chief of staff',description:'Keep Chief’s instructions',setupStatus:'ready',avatarShape:'star',avatarColor:'lilac',tools:{projectFiles:true}}];state.messages={chief:[]};state.groups=[];state.runs={};state.drafts={chief:'Existing draft'};state.attachments={};state.desktopProjects=[];state.onboarding={status:'completed',agentId:'chief'};ui.lastChat='chief';ui.view={kind:'chat',target:'chief'};
   window.fixturePreview={...preview,folderId:'research',originalPath:'/Users/example/Desktop/Directed Research/notes/README.md'};
   fixturePreview.markdownViewer.html+='<script>parent.__unsafe=true</script><img src="https://example.invalid/tracker"><a href="javascript:alert(1)">Unsafe</a>';
   window.savedStates=[];window.saveFailed=false;window.originalChanged=false;window.writes=[];window.nextVersion=fixturePreview.version;
   const folder={folderId:'research',name:'Directed Research',location:'/Users/example/Desktop/Directed Research',available:true};
   window.fixtureListing={...folder,folders:[folder],files:[{path:'notes/README.md',bytes:200},{path:'pipeline/data/shocks.csv',bytes:100},{path:'pipeline/run.py',bytes:20},{path:'proposal.docx',bytes:40}],directories:[{path:'notes'},{path:'pipeline'},{path:'pipeline/data'},{path:'empty'},{path:'venv',omitted:true}]};
   window.BuddyDesktop={
    saveState:async json=>{const value=JSON.parse(json);savedStates.push(value);if(value.desktopProjects?.length&&!saveFailed){saveFailed=true;throw Error('Fixture save failure');}return {saved:true};},
    projectFiles:async()=>fixtureListing,
    previewProjectFile:async()=>({...fixturePreview,version:nextVersion}),
    projectFileVersion:async()=>({version:nextVersion}),
    readProjectFile:async()=>({...fixturePreview,version:'external-version',content:fixturePreview.content+'\nExternal change.'}),
    writeProjectFile:async payload=>{writes.push(payload);if(!originalChanged){originalChanged=true;throw Error('File changed. Read its latest version and merge the changes.');}if(payload.expectedVersion!=='external-version')throw Error('Missing latest original version');fixturePreview.content=payload.content;fixturePreview.markdownViewer.html='<h1>Saved original</h1><p>Both edits retained.</p>';nextVersion='saved-version';return {saved:true};}
   };
   render();BuddyWorkspace.open();
  },nativePreview);
  await page.locator('[data-desktop-new]').first().click();await page.locator('[name=project-name]').fill('Directed Research');await page.locator('[name=project-folder]').check();await page.locator('[name=project-repository]').fill('https://github.com/example/research');
  await page.locator('#desktop-project-form [type=submit]').click();await page.locator('[data-desktop-form-error]').filter({hasText:'Fixture save failure'}).waitFor();
  assert.equal(await page.locator('[name=project-name]').inputValue(),'Directed Research');assert.equal(await page.locator('[name=project-repository]').inputValue(),'https://github.com/example/research');
  await page.locator('#desktop-project-form [type=submit]').click();await page.locator('#desktop-project-form').waitFor({state:'detached'});
  assert.equal(await page.locator('.desktop-source.repository').getAttribute('href'),'https://github.com/example/research');assert.match(await page.locator('.desktop-source.repository .brand-logo').getAttribute('src'),/github\.svg$/);
  assert.equal(await page.evaluate(()=>state.desktopProjects.length),1);assert.deepEqual(await page.evaluate(()=>savedStates.filter(s=>s.desktopProjects?.length).slice(0,2).map(s=>s.desktopProjects[0].id).every((v,_,a)=>v===a[0])),true);
  const screenshots=process.env.BUDDY_DESKTOP_SCREENSHOTS;if(screenshots){await mkdir(screenshots,{recursive:true});await page.screenshot({path:path.join(screenshots,'project-desktop.png')});}
  await page.setViewportSize({width:390,height:844});await page.evaluate(async()=>{await document.fonts.ready;await new Promise(requestAnimationFrame);});assert.equal(await page.locator('.secondary-header').count(),1);assert.equal(await page.locator('.buddy-desktop').evaluate(e=>e.scrollWidth<=e.clientWidth),true);if(screenshots)await page.screenshot({path:path.join(screenshots,'project-mobile.png')});await page.setViewportSize({width:1200,height:900});
  await page.locator('[data-desktop-folder]').click();await page.locator('[data-file-branch="pipeline"]>summary').waitFor();assert.equal(await page.locator('[data-action=project-file][data-path="pipeline/run.py"]').isVisible(),false);
  await page.locator('[data-file-branch="pipeline"]>summary').click();assert.equal(await page.locator('[data-action=project-file][data-path="pipeline/run.py"]').textContent(),'run.py20 B');assert.equal(await page.locator('[data-action=project-file][data-path="pipeline/data/shocks.csv"]').isVisible(),false);await page.locator('[data-file-branch="pipeline/data"]>summary').click();assert.equal(await page.locator('[data-action=project-file][data-path="pipeline/data/shocks.csv"]').isVisible(),true);
  if(screenshots)await page.screenshot({path:path.join(screenshots,'folder-tree.png')});
  await page.locator('[data-file-branch="notes"]>summary').click();await page.locator('[data-action=project-file][data-path="notes/README.md"]').click();
  const frame=page.frameLocator('.document-markdown');await frame.locator('#content strong').filter({hasText:'original'}).waitFor();assert.equal(await frame.locator('.katex').count()>0,true);assert.equal(await frame.locator('script').count(),0);assert.equal(await page.locator('.document-markdown').getAttribute('sandbox'),'');assert.equal(await page.evaluate(()=>window.__unsafe),undefined);assert.deepEqual(requests,[]);await frame.locator('.buddy-outline summary').click();assert.match(await frame.getByRole('link',{name:'Evidence',exact:true}).getAttribute('href'),/^about:srcdoc#/);await frame.getByRole('link',{name:'Evidence',exact:true}).click();await frame.locator('h2').filter({hasText:'Evidence'}).waitFor();assert.equal(await page.locator('.buddy-desktop').count(),1);
  if(screenshots)await page.screenshot({path:path.join(screenshots,'markdown-preview.png')});
  await page.locator('[data-action=project-edit]').click();await page.locator('#project-content').fill('# Both edits\n\nExternal change.\nSaved from Buddy.');await page.locator('[data-action=project-save]').click();await page.locator('#project-file-error').filter({hasText:'File changed'}).waitFor();assert.match(await page.locator('#project-content').inputValue(),/Saved from Buddy/);
  await page.locator('[data-action=project-latest]').click();await page.locator('[data-project-compare]').waitFor();await page.locator('[data-action=project-save]').click();await frame.locator('h1').filter({hasText:'Saved original'}).waitFor();assert.equal(await page.evaluate(()=>writes.at(-1).expectedVersion),'external-version');assert.equal(await page.evaluate(()=>writes.at(-1).folderId),'research');assert.equal(await page.evaluate(()=>writes.at(-1).path),'notes/README.md');
  await page.evaluate(()=>{closeModal();BuddyWorkspace.open(state.desktopProjects[0].id);});await page.locator('[data-desktop-use]').click();assert.match(await page.locator('#message-input').inputValue(),/^Existing draft[\s\S]*folderId: research[\s\S]*https:\/\/github.com\/example\/research/);assert.equal(await page.evaluate(()=>state.agents[0].description),'Keep Chief’s instructions');assert.equal(await page.evaluate(()=>state.messages.chief.length),0);
 }finally{await context?.close();await rm(directory,{recursive:true,force:true});}
});

import test from 'node:test';
import assert from 'node:assert/strict';
import {PrivateBrowser} from '../browser.mjs';
import {mkdtemp,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {createServer} from 'node:http';

// Chief on RunPod, 23 Oct: a click on the deploy page's "CPU" tab waited for the user's approval like any other browser step. A step that only
// shows something (a tab, a filter, a link, a search) is routine and goes ahead; one that could spend money, send, submit what
// was typed, delete, deploy, start or change something still waits for review.
const PAGE=`<title>Deploy</title><h1>Deploy a pod</h1>
<div role="tablist"><button role="tab" aria-selected="true">GPU</button><button role="tab">CPU</button></div>
<button type="button">Secure Cloud</button>
<a href="/pricing">Pricing</a> <a href="/pods/delete?id=1">Remove this pod</a>

<button type="button">Deploy On-Demand</button> <button type="button">Start pod</button> <button type="button">Delete pod</button> <button type="button">Continue</button>
<form action="/search"><input type="search" name="q" aria-label="Search templates"><button>Search</button></form>
<form action="/submit"><label>Name<input name="name"></label><button>Submit fixture</button></form>`;

test('a step that only shows something goes ahead by itself; one that spends, sends, submits, deletes or starts something waits for review',async()=>{
 const server=createServer((req,res)=>{res.setHeader('Content-Type','text/html');res.end(PAGE);});
 await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
 const origin=`http://127.0.0.1:${server.address().port}`,root=await mkdtemp(join(tmpdir(),'buddy-browser-routine-')),b=new PrivateBrowser(join(root,'profile'),{testOrigin:origin});
 try{
  const page=await b.navigate(origin+'/deploy');
  const ref=(name,role)=>{const c=page.controls.find(c=>c.name===name&&(!role||c.role===role));assert.ok(c,`the page lists ${name}: ${JSON.stringify(page.controls.map(c=>c.name))}`);return c.ref;};
  const click=async name=>(await b.prepare({snapshotId:page.snapshotId,action:'click',ref:ref(name)})).routine||'';
  for(const name of ['CPU','Secure Cloud','Pricing','Search'])assert.notEqual(await click(name),'',`“${name}” only shows something`);
  for(const name of ['Deploy On-Demand','Start pod','Delete pod','Remove this pod','Continue','Submit fixture'])assert.equal(await click(name),'',`“${name}” waits for review`);
  const fill=async(name,value)=>(await b.prepare({snapshotId:page.snapshotId,action:'fill',fields:[{ref:ref(name),value}]})).routine||'';
  assert.notEqual(await fill('Search templates','cpu'),'','typing into a search box is routine');
  assert.equal(await fill('Name','Fixture Person'),'','typing into another field waits for review');
  // Nothing was done while preparing.
  assert.equal(await b.page.locator('[name=name]').inputValue(),'');
 }finally{await b.close();await rm(root,{recursive:true,force:true});await new Promise(resolve=>server.close(resolve));}
});

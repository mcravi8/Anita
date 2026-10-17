'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),Actions=require('./buddy-actions');
const fixture=()=>({conversationWorkspace:'workspace',runs:{run:{target:'maze',status:'answering'}},toolInputs:{}});
const request=(changes={})=>({id:'input',native:true,workspace:'workspace',runId:'run',status:'pending',questions:[{id:'approve',question:'Send?',options:[{label:'Accept'},{label:'Decline'}]}],tool:{name:'send_email'},...changes});
test('only native review requests scoped to actual workspace and reply can appear',()=>{
 const state=fixture();assert.equal(Actions.merge(state,[request({native:false}),request({workspace:'other'}),request({runId:'unknown'})]),false);assert.deepEqual(Actions.pending(state,'run'),[]);
 assert.equal(Actions.merge(state,[request()]),true);assert.equal(Actions.pending(state,'run').length,1);
});
test('late or repeated review events cannot reopen a decided action',()=>{
 const state=fixture();Actions.merge(state,[request()]);Actions.merge(state,[request({status:'answered'})]);assert.equal(Actions.merge(state,[request()]),false);assert.deepEqual(Actions.pending(state,'run'),[]);
 Actions.merge(state,[request({status:'completed'})]);Actions.merge(state,[request({status:'uncertain'})]);assert.equal(state.toolInputs.input.status,'completed');
});
test('reopening expires unsubmitted reviews and preserves uncertainty after submitted decisions',()=>{
 const state=fixture();Actions.merge(state,[request(),request({id:'submitted',status:'answered'}),request({id:'done',status:'completed'})]);Actions.reconcile(state,[]);
 assert.equal(state.toolInputs.input.status,'expired');assert.equal(state.toolInputs.submitted.status,'uncertain');assert.equal(state.toolInputs.done.status,'completed');
});
test('same-process view recovery keeps native pending reviews, stopped replies reject new ones',()=>{
 const state=fixture();Actions.merge(state,[request()]);Actions.reconcile(state,[request()]);assert.equal(Actions.pending(state,'run').length,1);
 state.runs.run.status='stopped';assert.equal(Actions.merge(state,[request({id:'late'})]),false);
});

test('declined actions retain their evidence without becoming pending again',()=>{
 const state=fixture();Actions.merge(state,[request()]);Actions.merge(state,[request({status:'declined'})]);
 assert.equal(Actions.merge(state,[request()]),false);assert.deepEqual(Actions.pending(state,'run'),[]);
 Actions.merge(state,[request({status:'declined',receipt:{reason:'User declined'}})]);
 assert.equal(state.toolInputs.input.status,'declined');assert.equal(state.toolInputs.input.receipt.reason,'User declined');
 Actions.reconcile(state,[]);assert.equal(state.toolInputs.input.status,'declined');
});

test('Gmail HTML MIME messages show readable paragraphs and preserve literal encoded text',()=>{
 assert.equal(Actions.messagePreview({mime_type:'text/html',body:{content:'<p>Hi Ned,</p><p>Thank you &amp; goodbye.</p><p>&lt;img src=x&gt;</p>'}}),'Hi Ned,\nThank you & goodbye.\n<img src=x>');
 assert.equal(Actions.messagePreview({mime_type:'text/plain',body:{content:'Hi\nThank you.'}}),'Hi\nThank you.');
 const alternatives=Actions.messagePreview({mime_type:'multipart/alternative',parts:[{mime_type:'text/plain',body:{content:'Plain message'}},{mime_type:'text/html',body:{content:'<p>Formatted message</p>'}}]});
 assert.match(alternatives,/Plain message/);assert.match(alternatives,/Formatted message/);
 assert.equal(Actions.messagePreview({parts:{malformed:true}}),'');
});

const test=require('node:test'),assert=require('node:assert/strict');
const S=require('./buddy-services.js'),signin=require('./buddy-signin.js');

test('Connected services list each service with its address and whether it can charge money, never a key; Replace key and Remove, and a form to connect another',()=>{
 const list=[{id:'runpod',name:'RunPod',baseUrl:'https://rest.runpod.io/v2',header:'Authorization',scheme:'Bearer',charges:true,sends:'Authorization: Bearer …',saved:true},
  {id:'notes',name:'Notes',baseUrl:'https://notes.example.com/v1',header:'X-API-Key',scheme:'',charges:false,sends:'X-API-Key: …',saved:true}];
 const html=S.html(list);
 assert.match(html,/RunPod<\/strong><small>https:\/\/rest\.runpod\.io\/v2 · Can charge money: you approve each change · Authorization: Bearer …/);
 assert.match(html,/Notes<\/strong><small>https:\/\/notes\.example\.com\/v1 · Can’t charge money · X-API-Key: …/);
 assert.match(html,/data-service-replace="runpod"[^>]*>Replace key/);assert.match(html,/data-service-remove="notes"[^>]*>Remove/);
 assert.match(html,/data-service-add>Connect a service/);
 assert.equal(S.html(null).includes('Loading…'),true);assert.match(S.html([]),/None yet/);
 const adding=S.html(list,{adding:true});
 assert.match(adding,/data-service-form="new"/);assert.match(adding,/Can this service charge you money\?/);assert.match(adding,/type="password" data-service-input="key"/);
 assert.ok(!/checked/.test(S.fields('new')),'nothing is chosen for the person: they say whether it can charge money');
 const replacing=S.html(list,{editing:'notes'});
 assert.match(replacing,/leave empty to keep the saved one/);assert.match(replacing,/<option value="custom" selected>/);assert.match(replacing,/value="X-API-Key"/);
});
test('the chat card for a service an agent asked for: Connect RunPod, with the address the agent suggested, and nothing typed is ever kept in the message',()=>{
 assert.equal(signin.title({kind:'credential',secret:'service',service:'RunPod'}),'Connect RunPod');
 const kept=signin.view({key:'credential:t1:c1',kind:'credential',taskId:'t1',agentId:'forge',profile:'service:runpod',service:'RunPod',secret:'service',baseUrl:'https://rest.runpod.io/v2',instruction:'Connect RunPod so Forge can use its API.',value:'rpa_TYPED',key2:'x'});
 assert.equal(kept.secret,'service');assert.equal(kept.baseUrl,'https://rest.runpod.io/v2');assert.equal(kept.value,undefined);
 const card=S.fields('credential:t1:c1',{name:'RunPod',baseUrl:'https://rest.runpod.io/v2'},{fixedName:true,signin:true});
 assert.match(card,/type="hidden" data-service-input="name"[^>]*value="RunPod"/);assert.match(card,/data-signin-input="credential:t1:c1\|key"/);
});

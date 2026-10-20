const test=require('node:test'),assert=require('node:assert/strict'),providers=require('./buddy-providers');
test('selected provider readiness never falls back to another connected account',()=>{
 const s={provider:'claude',claude:{connected:false},chatgpt:{connected:true}};
 assert.equal(providers.active(s),false);s.claude.connected=true;assert.equal(providers.active(s),true);
 s.provider='chatgpt';s.chatgpt.connected=false;assert.equal(providers.active(s),false);
});
test('connection controls distinguish both accounts independently',()=>{
 const s={provider:'chatgpt',chatgpt:{connected:true},claude:{connected:false}};
 assert.equal(providers.connected(s,'chatgpt'),true);assert.equal(providers.connected(s,'claude'),false);
 assert.equal(providers.name('chatgpt'),'ChatGPT');assert.equal(providers.name('claude'),'Claude');
});
test('switch all agents is offered towards the provider that is not the starting one, and only a confirm applies it',()=>{
 assert.equal(providers.switchTarget({provider:'chatgpt'}),'claude');assert.equal(providers.switchTarget({provider:'claude'}),'chatgpt');assert.equal(providers.switchTarget({}),'claude');
 assert.deepEqual(providers.switchRequest('claude',true),{operation:'switch',provider:'claude',dryRun:true});
 assert.deepEqual(providers.switchRequest('chatgpt',false),{operation:'switch',provider:'chatgpt',dryRun:false});
 assert.deepEqual(providers.switchRequest('claude'),{operation:'switch',provider:'claude',dryRun:true},'a request without an explicit confirm is only a preview');
 const offer=providers.switchOffer({provider:'claude'},'');
 assert.match(offer,/data-provider-switch="chatgpt"/);assert.match(offer,/>Switch all agents to ChatGPT</);assert.match(offer,/each agent gets its earlier model again/);assert.doesNotMatch(offer,/disabled/);
 assert.match(providers.switchOffer({provider:'chatgpt'},'switch'),/disabled>Checking models…</);
});
test('the switch preview lists every agent with its current and new model, says what stays on Claude, and escapes names',()=>{
 const plan={provider:'claude',dryRun:true,applied:false,note:"Coding sessions and Chief's background supervision run on Claude. They keep using Claude while it stays connected.",agents:[
  {agentId:'chief',from:{provider:'chatgpt',model:'gpt-5.5-pro',name:'GPT-5.5 Pro'},to:{provider:'claude',model:'claude-opus-5',name:'Claude Opus 5'},how:'equivalent'},
  {agentId:'forge',from:{provider:'chatgpt',model:'gpt-5.5',name:'GPT-5.5'},to:{provider:'claude',model:'claude-sonnet-5',name:'Claude Sonnet 5'},how:'remembered'},
  {agentId:'inbox',from:{provider:'claude',model:'claude-haiku-5',name:'Claude Haiku 5'},to:{provider:'claude',model:'claude-haiku-5',name:'Claude Haiku 5'},how:'unchanged'},
  {agentId:'odd',from:{provider:'chatgpt',model:'',name:'Account default'},to:{provider:'claude',model:'claude-sonnet-5',name:'Claude Sonnet 5'},how:'equivalent'}]};
 const names={chief:'Chief',forge:'Forge',inbox:'Inbox',odd:'<img src=x>'},out=providers.switchPreview(plan,id=>names[id],'');
 assert.match(out,/<strong>Switch all agents to Claude\?<\/strong>/);assert.match(out,/New agents will start on Claude\./);
 const rows=out.split('<li class="provider-switch-row">').slice(1);assert.equal(rows.length,4);
 assert.match(rows[0],/Chief<\/span>.*GPT-5\.5 Pro<\/span>.*→.*Claude Opus 5<\/span>/);assert.doesNotMatch(rows[0],/had before/);
 assert.match(rows[1],/Forge.*GPT-5\.5<\/span>.*Claude Sonnet 5<\/span><small>The model it had before<\/small>/);
 assert.match(rows[2],/Inbox.*Claude Haiku 5<\/span><small>Already on Claude<\/small>/);assert.doesNotMatch(rows[2],/→/);
 assert.match(rows[3],/&lt;img src=x&gt;/);assert.doesNotMatch(out,/<img/);
 assert.match(out,/Coding sessions and Chief&#39;s background supervision run on Claude\. They keep using Claude while it stays connected\./);
 assert.match(out,/Replies and tasks already running finish on the model they started with\./);
 assert.match(out,/data-provider-switch-cancel >Cancel<\/button><button type="button" class="primary-button" data-provider-switch-confirm >Switch all agents to Claude<\/button>/);
 const busy=providers.switchPreview(plan,id=>names[id],'switch');assert.match(busy,/data-provider-switch-cancel disabled>Cancel/);assert.match(busy,/data-provider-switch-confirm disabled>Switching…</);
 assert.match(providers.switchPreview({...plan,provider:'chatgpt',agents:[]},()=>'', ''),/Switch all agents to ChatGPT\?/);
});

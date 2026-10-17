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

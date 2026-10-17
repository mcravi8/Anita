const test=require('node:test'),assert=require('node:assert/strict'),models=require('./buddy-models');
const snapshot=()=>({defaultProvider:'claude',agents:{chief:{provider:'chatgpt',model:'gpt-b'},maze:{provider:'claude',model:'claude-a'}},models:[{provider:'chatgpt',id:'gpt-a',name:'GPT A'},{provider:'chatgpt',id:'gpt-b',name:'GPT B'},{provider:'claude',id:'claude-a',name:'Claude A'}]});
test('picker groups both connected catalogs independently of global starting provider',()=>{
 const s=snapshot();assert.deepEqual(models.groups(s).map(g=>[g.name,g.models.length]),[['OpenAI',2],['Claude',1]]);
 s.defaultProvider='chatgpt';assert.equal(models.groups(s).length,2);
 s.models=s.models.filter(m=>m.provider!=='chatgpt');assert.deepEqual(models.groups(s).map(g=>g.name),['Claude']);
});
test('agent labels use that agent’s exact saved model and retain unavailable choice',()=>{
 const s=snapshot();assert.equal(models.label(s,'chief'),'GPT B');assert.equal(models.label(s,'maze'),'Claude A');
 s.models=s.models.filter(m=>m.id!=='gpt-b');assert.equal(models.label(s,'chief'),'gpt-b');assert.equal(models.lookup(s,models.choice(s,'chief')),undefined);
 assert.equal(models.label(s,'maze'),'Claude A');assert.equal(models.choice(s,'unknown'),null);
});
test('older active Claude versions stay named when saved but are absent from model choices',()=>{
 const s=snapshot();s.models.push({provider:'claude',id:'claude-older',name:'Older Claude',current:false});s.agents.maze.model='claude-older';
 assert.equal(models.label(s,'maze'),'Older Claude');assert.equal(models.groups(s)[1].models.some(m=>m.id==='claude-older'),false);
});

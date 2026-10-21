const {test}=require('node:test'),assert=require('node:assert/strict'),M=require('./buddy-mentions');
const agents=[{id:'i',name:'Inbox'},{id:'c',name:'Chief'},{id:'j',name:'Job Chief'},{id:'r',name:'Research'}];
test('at-sign suggestions start at the caret and exclude email addresses',()=>{
 assert.equal(M.query('mail me@example.com',19),null);assert.deepEqual(M.query('Ask @Ch about this',7),{start:4,end:7,text:'Ch'});assert.equal(M.query('Hello\n@',7).text,'');assert.equal(M.query('No mention',10),null);
});
test('current agents filter by partial names including spaces and removed names disappear',()=>{
 assert.deepEqual(M.matches(agents,M.query('@Ch',3)).map(a=>a.id),['c','j']);assert.deepEqual(M.matches(agents,M.query('@Job C',6)).map(a=>a.id),['j']);assert.equal(M.matches(agents,M.query('@Missing',8)).length,0);assert.equal(M.matches(agents,M.query('@Chief ',7)).length,0);assert.deepEqual(M.matches(agents.filter(a=>a.id!=='c'),M.query('@Ch',3)).map(a=>a.id),['j']);
});
test('choosing an agent replaces only the active fragment and preserves the rest of the draft',()=>{
 const draft='Ask @Ch about this';assert.deepEqual(M.insert(draft,M.query(draft,7),'Chief'),{text:'Ask @Chief about this',caret:11});
});
test('ordinary text after a completed mention does not reopen suggestions',()=>{assert.equal(M.finished(agents,M.query('@Chief hello there',18)),true);assert.equal(M.finished([...agents,{id:'long',name:'Chief of Staff'}],M.query('@Chief of',9)),false);});

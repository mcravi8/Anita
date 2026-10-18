const {test}=require('node:test'),assert=require('node:assert/strict'),M=require('./buddy-agent-messages');
test('agent history rejects foreign workspaces and absent or identical participants',()=>{
 const state={conversationWorkspace:'w',agents:[{id:'chief'},{id:'inbox'}]},r={id:'exchange',fromAgentId:'chief',toAgentId:'inbox',question:'What needs attention?',body:'A verified deadline.'};
 assert.deepEqual(M.validRows(state,{workspace:'w',messages:[r,{...r,id:'removed',toAgentId:'other'},{...r,id:'self',toAgentId:'chief'}]}),[r]);assert.deepEqual(M.validRows(state,{workspace:'foreign',messages:[r]}),[]);
});

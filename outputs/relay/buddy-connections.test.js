'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),Connections=require('./buddy-connections');
const fixture=()=>Connections.normalize({apps:[{id:'mail',name:'Gmail',available:true,readToolCount:10},{id:'files',name:'Drive',available:true,readToolCount:0},{id:'disabled',name:'Disabled',available:false,readToolCount:2}],access:{morgan:[],atlas:[]}});
test('unavailable or unverified connections cannot gain agent access',()=>{
 const value=fixture();assert.equal(value.apps.find(a=>a.id==='files').available,false);
 for(const id of ['files','disabled','missing'])assert.throws(()=>Connections.setAccess(value,'morgan',id,true));
 assert.deepEqual(value.access.morgan,[]);
});
test('allowing one agent is independent and revocation removes only that grant',()=>{
 const value=fixture();Connections.setAccess(value,'morgan','mail',true);Connections.setAccess(value,'morgan','mail',true);
 assert.deepEqual(value.access.morgan,['mail']);assert.deepEqual(value.access.atlas,[]);
 Connections.setAccess(value,'atlas','mail',true);Connections.setAccess(value,'morgan','mail',false);
 assert.deepEqual(value.access.morgan,[]);assert.deepEqual(value.access.atlas,['mail']);
});
test('an unavailable connection retains revocable grants, while unknown IDs and duplicates are discarded',()=>{
 const value=Connections.normalize({apps:[{id:'mail',name:'Gmail',available:false,readToolCount:3},{id:'mail',name:'Duplicate',available:true,readToolCount:9}],access:{morgan:['mail','missing','mail']}});
 assert.equal(value.apps.length,1);assert.deepEqual(value.access.morgan,['mail']);
 Connections.setAccess(value,'morgan','mail',false);assert.deepEqual(value.access.morgan,[]);
});
test('a usable action-only service is available, with upstream disabled services preserved',()=>{
 const value=Connections.normalize({apps:[{id:'send',name:'Actions',available:true,readToolCount:0,actionToolCount:2},{id:'off',available:false,readToolCount:0,actionToolCount:2}],access:{maze:[]}});
 assert.equal(value.apps[0].available,true);assert.equal(value.apps[0].actionToolCount,2);Connections.setAccess(value,'maze','send',true);assert.throws(()=>Connections.setAccess(value,'maze','off',true));
});

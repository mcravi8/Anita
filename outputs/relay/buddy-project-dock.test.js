const test=require('node:test'),assert=require('node:assert/strict'),dock=require('./buddy-project-dock');

test('a folder is a project when the person connected it, or when Buddy’s own folder has something in it',()=>{
 assert.equal(dock.isProject({folderId:'f',name:'Prices',files:[]}),true,'a folder the person connected, even empty');
 assert.equal(dock.isProject({folderId:'w',name:'Buddy files',managed:true,files:[]}),false);
 assert.equal(dock.isProject({folderId:'w',name:'Buddy files',managed:true,files:[{path:'notes.md',bytes:1}]}),true);
 assert.equal(dock.isProject({folderId:'w',name:'Buddy files',managed:true,files:[],directories:[{path:'drafts'}]}),true);
 for(const value of [null,undefined,{},{folderId:'f'},{files:[]},'folder'])assert.equal(dock.isProject(value),false);
});

test('a chat offers Chat, then Plan and Files when it has them, and shows the chosen view while it is still offered',()=>{
 assert.deepEqual(dock.views({plan:true,files:true}),{list:['chat','plan','files'],shown:'chat'},'a chat opens on its messages');
 assert.deepEqual(dock.views({plan:true,files:true,chosen:'files'}),{list:['chat','plan','files'],shown:'files'});
 assert.deepEqual(dock.views({plan:true,files:false,chosen:'files'}),{list:['chat','plan'],shown:'chat'},'a view that went away falls back to the chat');
 assert.deepEqual(dock.views({plan:false,files:true,chosen:'plan'}),{list:['chat','files'],shown:'chat'});
 assert.deepEqual(dock.views({plan:false,files:false,chosen:'plan'}),{list:[],shown:'chat'},'nothing beside the chat: no choice to show');
 assert.deepEqual(dock.views({plan:true,chosen:'<b>'}),{list:['chat','plan'],shown:'chat'},'only a real view counts');
});

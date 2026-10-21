const test=require('node:test'),assert=require('node:assert/strict'),dock=require('./buddy-project-dock');

test('the project is docked only when the chat column keeps a comfortable width beside it',()=>{
 assert.equal(dock.DOCK+dock.CHAT,1020,'a 340-pixel panel beside a chat column of at least 680');
 assert.equal(dock.fits(1150),true,'a 1440-wide window with the sidebar open');
 assert.equal(dock.fits(1042),true,'the default 1120-wide window with the sidebar as a rail');
 assert.equal(dock.fits(1020),true);assert.equal(dock.fits(1019),false);
 assert.equal(dock.fits(830),false,'the default window with the sidebar open');
 for(const value of [undefined,null,NaN,'wide'])assert.equal(dock.fits(value),false);
});

test('a folder is a project when the person connected it, or when Buddy’s own folder has something in it',()=>{
 assert.equal(dock.isProject({folderId:'f',name:'Prices',files:[]}),true,'a folder the person connected, even empty');
 assert.equal(dock.isProject({folderId:'w',name:'Buddy files',managed:true,files:[]}),false);
 assert.equal(dock.isProject({folderId:'w',name:'Buddy files',managed:true,files:[{path:'notes.md',bytes:1}]}),true);
 assert.equal(dock.isProject({folderId:'w',name:'Buddy files',managed:true,files:[],directories:[{path:'drafts'}]}),true);
 for(const value of [null,undefined,{},{folderId:'f'},{files:[]},'folder'])assert.equal(dock.isProject(value),false);
});

test('the panel shows the plan, the files, or both as two tabs, and remembers which one the person chose',()=>{
 assert.deepEqual(dock.sections({plan:true,files:true,tab:''}),{list:['plan','files'],shown:'plan'},'the plan first');
 assert.deepEqual(dock.sections({plan:true,files:true,tab:'files'}),{list:['plan','files'],shown:'files'});
 assert.deepEqual(dock.sections({plan:true,files:false,tab:'files'}),{list:['plan'],shown:'plan'},'a plan with no folder: the plan alone');
 assert.deepEqual(dock.sections({plan:false,files:true,tab:'plan'}),{list:['files'],shown:'files'},'a folder with no plan: the files alone');
 assert.deepEqual(dock.sections({plan:false,files:false}),{list:[],shown:''},'nothing to show, no panel');
});

test('closed or open is the person’s choice, read safely from the saved workspace',()=>{
 assert.deepEqual(dock.preference(undefined),{closed:false,tab:''},'open by default');
 assert.deepEqual(dock.preference({closed:true,tab:'files'}),{closed:true,tab:'files'});
 assert.deepEqual(dock.preference({closed:'yes',tab:'<b>'}),{closed:false,tab:''},'only a real choice counts');
 assert.deepEqual(dock.preference('closed'),{closed:false,tab:''});
});

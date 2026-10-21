const {test}=require('node:test'),assert=require('node:assert/strict'),links=require('./buddy-file-links');
// The folders as the Mac app lists them: Buddy's own folder (primary here), the person's research folder with spaces in its path, and a second
// project folder nested inside the first one's parent.
const research={folderId:'research',name:'Directed Research',location:'/Users/matteo/Desktop/USC/Semester 4/Directed Research',primary:false,available:true};
const own={folderId:'ws',name:'Buddy files',location:'/Users/matteo/Library/Application Support/Buddy/files/ws',primary:true,available:true};
const data={folderId:'data',name:'Data',location:'/Users/matteo/Desktop/USC/Semester 4/Directed Research/data',primary:false,available:true};
const folders=[own,research,data];

test('an absolute path inside a connected folder opens that file, with spaces, encoded, or as a file:// address',()=>{
 const at=href=>links.resolve(href,{folders});
 assert.deepEqual(at('/Users/matteo/Desktop/USC/Semester 4/Directed Research/paper_draft.md'),{folderId:'research',path:'paper_draft.md'});
 assert.deepEqual(at('/Users/matteo/Desktop/USC/Semester%204/Directed%20Research/paper_draft.md'),{folderId:'research',path:'paper_draft.md'},'the address as Markdown hands it over, encoded');
 assert.deepEqual(at('</Users/matteo/Desktop/USC/Semester 4/Directed Research/paper_draft.md>'),{folderId:'research',path:'paper_draft.md'},'angle brackets left on');
 assert.deepEqual(at('file:///Users/matteo/Desktop/USC/Semester%204/Directed%20Research/verification/ledger.md'),{folderId:'research',path:'verification/ledger.md'});
 assert.deepEqual(at('file://localhost/Users/matteo/Desktop/USC/Semester%204/Directed%20Research/a.md'),{folderId:'research',path:'a.md'});
 assert.deepEqual(at('/Users/matteo/Desktop/USC/Semester 4/Directed Research/data/prices.csv'),{folderId:'data',path:'prices.csv'},'the innermost connected folder wins');
 assert.deepEqual(at('/Users/matteo/Desktop/USC/Semester 4/Directed Research/drafts/../paper_draft.md#intro'),{folderId:'research',path:'paper_draft.md'},'".." that stays inside is worked out; the #part is dropped');
});

test('a path outside every connected folder, or one that climbs out, opens nothing',()=>{
 const at=href=>links.resolve(href,{folders,activeFolderId:'research'});
 for(const href of [
  '/Users/matteo/Documents/Other/notes.md',
  '/Users/matteo/Desktop/USC/Semester 4/Directed Research2/paper.md',
  '/Users/matteo/Desktop/USC/Semester 4/Directed Research/../secret.md',
  '/Users/matteo/Desktop/USC/Semester 4/Directed Research',
  '/Users/matteo/Desktop/USC/Semester 4/Directed Research/drafts/',
  '../secret.md','drafts/../../secret.md','~/notes.md',
  'file://evil.example/Users/matteo/Desktop/USC/Semester%204/Directed%20Research/a.md',
  'javascript:alert(1)','data:text/html,x','https://example.com/a.md','mailto:a@b.c','//example.com/a.md','#intro','','www.example.com'
 ])assert.equal(at(href),null,href);
 assert.equal(links.resolve('/Users/matteo/Desktop/USC/Semester 4/Directed Research/a.md',{folders:[{...research,available:false}]}),null,'a folder that is gone opens nothing');
 assert.equal(links.resolve('a.md',{folders:[]}),null,'no folders known yet');
});

test('a relative path is read in the folder of the files the message saved, then the folder the person has open, then the primary one',()=>{
 const ledger='verification/paper_audit_corrections_2026-10-20.md';
 assert.deepEqual(links.resolve(ledger,{folders,activeFolderId:'research'}),{folderId:'research',path:ledger},'the folder the person has open');
 assert.deepEqual(links.resolve(ledger,{folders}),{folderId:'ws',path:ledger},'else the primary folder');
 const saved=[{folderId:'data',path:'prices.csv',revision:'r1'}];
 assert.deepEqual(links.resolve(ledger,{folders,activeFolderId:'research',files:saved}),{folderId:'data',path:ledger},'the folder the message saved into');
 assert.deepEqual(links.resolve('prices.csv',{folders,activeFolderId:'research',files:[...saved,{folderId:'research',path:'x.md',revision:'r'}]}),{folderId:'data',path:'prices.csv'},'the very file it saved');
 assert.deepEqual(links.resolve(ledger,{folders,activeFolderId:'research',files:[...saved,{folderId:'ws',path:'x.md',revision:'r'}]}),{folderId:'research',path:ledger},'files in two folders are no hint: the open folder');
 assert.deepEqual(links.resolve(ledger,{folders,activeFolderId:'ws',listings:{research:[ledger]}}),{folderId:'research',path:ledger},'a folder known to hold that file');
 assert.deepEqual(links.resolve('./verification/a.md',{folders,activeFolderId:'research'}),{folderId:'research',path:'verification/a.md'});
 assert.deepEqual(links.resolve('verification%20notes/a.md',{folders,activeFolderId:'research'}),{folderId:'research',path:'verification notes/a.md'});
 assert.equal(links.resolve(ledger,{folders,activeFolderId:'gone',files:[{folderId:'gone',path:'x',revision:'r'}]}).folderId,'ws','a folder that is not connected is never used');
});

const test=require('node:test'),assert=require('node:assert/strict');
const S=require('./buddy-signin.js');
const people=()=>({conversationWorkspace:'w',agents:[{id:'ada',name:'Ada'},{id:'bo',name:'Bo'}],groups:[{id:'team',name:'Team',members:['ada','bo']}],messages:{}});
const request=(extra={})=>({key:'signin:t1:s1',kind:'signin',taskId:'t1',agentId:'ada',planId:'p1',reviewId:'r1',mode:'signin',origin:'https://shop.example',account:'ada@example.com',field:'password',step:'password',note:'',attempts:0,choices:['private'],title:'Read my last order',...extra});
const snapshot=(requests,extra={})=>({workspace:'w',signinRequests:requests,plans:[{id:'p1',groupId:'team'}],...extra});
const all=state=>Object.entries(state.messages).flatMap(([chat,list])=>list.map(m=>({chat,...m})));

test('a sign-in request is one message in the agent’s chat and one in its team’s group chat, kept up to date in place',()=>{
 const state=people();
 assert.equal(S.sync(state,snapshot([request()])),true);
 const posted=all(state);
 assert.deepEqual(posted.map(m=>m.chat).sort(),['ada','team'],'the agent’s chat and the plan’s group chat');
 assert.ok(posted.every(m=>m.kind==='signin-request'&&m.who==='ada'&&m.status==='open'&&m.request.key==='signin:t1:s1'&&m.body==='Sign in to shop.example.'));
 assert.ok(posted.every(m=>m.live!==true),'kept out of what is replayed to the model as conversation');
 assert.equal(S.sync(state,snapshot([request()])),false,'the same request again changes nothing');
 assert.equal(all(state).length,2,'never posted twice');
 // A new try of the same request (after a wrong password) updates both messages; it is still one request.
 assert.equal(S.sync(state,snapshot([request({reviewId:'r2',note:'That didn’t work. Check it and type it again.'})])),true);
 assert.ok(all(state).every(m=>m.request.reviewId==='r2'&&m.request.note.startsWith('That didn’t work')));
 assert.equal(all(state).length,2);
});

test('what a message keeps is what was asked: never a token or anything typed, and nothing from another workspace or a removed agent',()=>{
 const state=people();
 S.sync(state,snapshot([request({token:'secret-1',value:'Shop!pw',password:'x'})]));
 const saved=JSON.stringify(state);
 assert.ok(!saved.includes('secret-1')&&!saved.includes('Shop!pw')&&!saved.includes('"password":'),'only the request’s own fields are kept');
 assert.equal(S.sync(people(),{...snapshot([request()]),workspace:'other'}),false);
 const gone=people();gone.agents=[{id:'bo',name:'Bo'}];
 S.sync(gone,snapshot([request()]));
 assert.deepEqual(all(gone).map(m=>m.chat),['team'],'only the group chat, for an agent no longer in the workspace');
 const solo=people();S.sync(solo,{workspace:'w',signinRequests:[request({planId:null})],plans:[]});
 assert.deepEqual(all(solo).map(m=>m.chat),['ada'],'a task outside a team plan asks in its agent’s chat only');
});

test('answering in either chat answers both, and a request that ends closes both, saying how',()=>{
 const state=people();
 S.sync(state,snapshot([request()]));
 assert.equal(S.settle(state,'signin:t1:s1',{status:'done',result:'Sent — signed in'}),true);
 assert.ok(all(state).every(m=>m.status==='done'&&m.result==='Sent — signed in'));
 S.sync(state,snapshot([]));
 assert.ok(all(state).every(m=>m.status==='closed'&&m.result==='Sent — signed in'),'the outcome stays');
 const step=people();
 S.sync(step,snapshot([{key:'step:t2:c1',kind:'step',taskId:'t2',agentId:'bo',need:'signin',origin:'https://mail.example',instruction:'Sign in to mail.example in the Chrome window Buddy opened. When you’re finished, press Done.',chromeOpen:true}]));
 assert.equal(all(step)[0].body,'Sign in to mail.example.');
 S.sync(step,snapshot([]));
 assert.equal(all(step)[0].status,'closed');assert.equal(all(step)[0].result,'This step has ended.');
 // A field the answer says is gone is removed from the message (a step on the phone has nothing to type).
 const wait=people();S.sync(wait,snapshot([request()]));
 S.settle(wait,'signin:t1:s1',{result:'Sent — the website wants another step.',request:{reviewId:'r3',field:null,step:'wait'}});
 assert.ok(all(wait).every(m=>m.request.field===undefined&&m.request.step==='wait'&&m.request.reviewId==='r3'));
});

test('titles say what is asked in plain words',()=>{
 assert.equal(S.title({kind:'signin',origin:'https://shop.example',field:'code'}),'Code for shop.example');
 assert.equal(S.title({kind:'signin',origin:'https://shop.example',mode:'signup'}),'Create your account on shop.example');
 assert.equal(S.title({kind:'credential',service:'WRDS'}),'WRDS needs your sign-in');
 assert.equal(S.title({kind:'mfa',service:'WRDS'}),'Approve the WRDS Duo push on your phone');
 assert.equal(S.title({kind:'step',need:'captcha',origin:'https://shop.example'}),'Finish the CAPTCHA on shop.example');
});

test('a step on a web page always says which site, and which account; never “the website”',()=>{
 const article='https://iopscience.iop.org/article/10.1088/1742-5468/ac498c';
 assert.equal(S.title({kind:'step',need:'captcha',url:article,origin:'https://iopscience.iop.org'}),'Finish the CAPTCHA on iopscience.iop.org');
 assert.equal(S.title({kind:'step',need:'signin',url:article,account:'craviott@usc.edu'}),'Sign in to iopscience.iop.org as craviott@usc.edu','the site from the page itself, and the account');
 assert.equal(S.title({kind:'step',need:'signin',origin:'https://mail.example'}),'Sign in to mail.example');
 assert.equal(S.title({kind:'step',need:'verification',url:article}),'Finish verifying on iopscience.iop.org');
 // A coding task's blocked download: the file goes into the person's connected folder.
 assert.equal(S.title({kind:'step',need:'file',url:article,target:'Directed Research/stages/S01_protocol/sources/sethna-2022.pdf'}),'Save the PDF from iopscience.iop.org into Directed Research/stages/S01_protocol/sources');
 assert.equal(S.title({kind:'step',need:'file',url:'https://data.example/table',target:'Project/data.csv'}),'Save the file from data.example into Project');
 // A step saved without its page: Buddy says it doesn't know, and whom to ask.
 assert.equal(S.title({kind:'step',need:'signin',unknownPage:true},'Chief'),'Buddy doesn’t know which page — ask Chief');
 assert.equal(S.title({kind:'step',need:'signin',unknownPage:true}),'Buddy doesn’t know which page — ask the agent');
 for(const r of [{kind:'step',need:'captcha'},{kind:'step',need:'signin',origin:''},{kind:'signin'}])assert.doesNotMatch(S.title(r),/the website/,JSON.stringify(r));
 // The message keeps the page, where the file goes and whether it is a coding task.
 const state=people();
 S.sync(state,snapshot([{key:'step:t9:c1',kind:'step',taskId:'t9',agentId:'ada',need:'file',url:article,origin:'https://iopscience.iop.org',target:'Directed Research/a.pdf',coding:true,instruction:'Use the Download PDF button.',chromeOpen:false}]));
 const kept=all(state).find(m=>m.chat==='ada').request;
 assert.equal(kept.url,article);assert.equal(kept.target,'Directed Research/a.pdf');assert.equal(kept.coding,true);
 assert.equal(all(state).find(m=>m.chat==='ada').body,'Save the PDF from iopscience.iop.org into Directed Research.');
 S.sync(state,snapshot([{key:'step:t8:c1',kind:'step',taskId:'t8',agentId:'ada',need:'signin',unknownPage:true,origin:null}]));
 assert.equal(all(state).find(m=>m.request.key==='step:t8:c1').body,'Buddy doesn’t know which page — ask Ada.','the agent’s name, from the workspace');
});

const test=require('node:test'),assert=require('node:assert/strict');
const S=require('./buddy-signin.js');
// An account an agent wants Buddy to create (or a password to reset) on one site: one message in the agent's chat and one in its team's group
// chat, asking "is that fine?"; once the person said yes, what Buddy is doing; then, in place, what came of it.
const people=()=>({conversationWorkspace:'w',agents:[{id:'jobapply',name:'JobApply'},{id:'bo',name:'Bo'}],groups:[{id:'team',name:'Team',members:['jobapply','bo']}],messages:{}});
const ask=(extra={})=>({key:'account:t1:a1',kind:'account',taskId:'t1',agentId:'jobapply',planId:'p1',reviewId:'a1',purpose:'signup',origin:'https://jobs.ubs.com',account:'matteo.craviotto@gmail.com',
 reason:'To apply for the analyst role you asked about.',what:'Buddy makes a strong password and keeps it in your Keychain; it agrees to the site’s standard terms; it confirms the email in your Gmail.',title:'Apply at UBS',...extra});
const snapshot=(requests)=>({workspace:'w',signinRequests:requests,plans:[{id:'p1',groupId:'team'}]});
const all=state=>Object.entries(state.messages).flatMap(([chat,list])=>list.map(m=>({chat,...m})));

test('an account request asks in the agent’s words, once in each chat, and keeps why and what Buddy does',()=>{
 const state=people();
 assert.equal(S.sync(state,snapshot([ask()])),true);
 const posted=all(state);
 assert.deepEqual(posted.map(m=>m.chat).sort(),['jobapply','team']);
 assert.ok(posted.every(m=>m.status==='open'&&m.body==='JobApply wants to create an account on jobs.ubs.com with matteo.craviotto@gmail.com — is that fine?'),JSON.stringify(posted.map(m=>m.body)));
 assert.equal(S.title(ask(),'JobApply'),'JobApply wants to create an account on jobs.ubs.com with matteo.craviotto@gmail.com — is that fine?');
 assert.equal(S.title(ask({purpose:'reset'}),'JobApply'),'JobApply wants to reset your password on jobs.ubs.com through your email — is that fine?');
 assert.equal(posted[0].request.reason,'To apply for the analyst role you asked about.');assert.match(posted[0].request.what,/strong password/);
 assert.equal(S.sync(state,snapshot([ask()])),false,'never posted twice');
});

test('after the person’s yes the message says what Buddy is doing, then shows the receipt in both chats; a new site is a new message',()=>{
 const state=people();
 S.sync(state,snapshot([ask()]));
 S.settle(state,'account:t1:a1',{status:'sending',choice:'account',result:'Creating your account on jobs.ubs.com…'});
 assert.equal(S.sync(state,snapshot([ask({working:true})])),true);
 assert.ok(all(state).every(m=>m.status==='sending'&&m.result==='Creating your account on jobs.ubs.com…'));
 const receipt='Created an account on jobs.ubs.com as matteo.craviotto@gmail.com — password saved in your Keychain.';
 assert.equal(S.sync(state,snapshot([ask({done:true,created:true,receipt,details:'Chrome’s Password Manager can’t be filled in by automation, so Buddy keeps this password in your Mac’s Keychain.'})])),true);
 assert.ok(all(state).every(m=>m.status==='done'&&m.result===receipt&&m.request.created===true&&/Keychain/.test(m.request.details)),'the receipt, in place, in both chats');
 // The receipt stays when the request is no longer listed.
 S.sync(state,snapshot([]));
 assert.ok(all(state).every(m=>['done','closed'].includes(m.status)&&m.result===receipt&&m.request.created===true));
 // Another site asks again: a message of its own.
 S.sync(state,snapshot([ask({key:'account:t1:a2',reviewId:'a2',origin:'https://second.example'})]));
 assert.equal(all(state).filter(m=>m.request.key==='account:t1:a2'&&m.status==='open').length,2);
 // A message first seen when Buddy is already carrying on (the person said yes earlier in this task) has no question to answer.
 const later=people();S.sync(later,snapshot([ask({key:'account:t2:a3',reviewId:'a3',working:true})]));
 assert.ok(all(later).every(m=>m.status==='sending'));
});

test('a sign-up Buddy stopped for money says which kind, in plain words',()=>{
 const step={key:'step:t3:p1',kind:'step',taskId:'t3',agentId:'jobapply',need:'payment',money:'trial',url:'https://trial.example/join',origin:'https://trial.example',instruction:'This sign-up on trial.example starts a free trial that becomes paid. Buddy stopped.'};
 assert.equal(S.title(step,'JobApply'),'This sign-up on trial.example starts a free trial that becomes paid');
 assert.equal(S.title({...step,money:'payment'},'JobApply'),'This sign-up on trial.example asks for payment details');
 const state=people();S.sync(state,{workspace:'w',signinRequests:[step],plans:[]});
 assert.equal(all(state)[0].request.money,'trial','the kind is kept with the message');
});

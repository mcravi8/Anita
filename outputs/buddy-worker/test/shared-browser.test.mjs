import test from 'node:test';
import assert from 'node:assert/strict';
import {SharedBrowser} from '../browser.mjs';
import {mkdtemp,rm,writeFile,readFile,chmod} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {spawn} from 'node:child_process';
import {createServer} from 'node:http';
import {fileURLToPath} from 'node:url';

// One private Chrome profile for every agent: each agent's task drives its own page (a "session") in the one Chrome, and the person's typed
// password goes only into the page that asked for it.
const SECRET='Typed-Fixture-Pw-7731!';
// `host` '::1' puts a site on another "site" for Chrome (its own renderer process), as two agents on two websites are.
async function site(handler,host='127.0.0.1'){
 const server=createServer(async(req,res)=>{let body='';for await(const chunk of req)body+=chunk;res.setHeader('Content-Type','text/html');await handler(req,res,body);});
 await new Promise(r=>server.listen(0,host,r));
 return {server,origin:`http://${host.includes(':')?`[${host}]`:host}:${server.address().port}`,close:()=>new Promise(r=>server.close(r))};
}
const loginForm=(action='/session',extra='')=>`<title>Sign in</title><form method="post" action="${action}"><label>Email<input type="email" name="email" value="fixture@example.com"></label><label>Password<input type="password" name="password" autocomplete="current-password"></label>${extra}<button>Sign in</button></form>`;

test('every agent shares one private Chrome: each drives only its own page, accounts are shared, and one agent’s close, crash or stuck page leaves the other’s alone',{timeout:90000},async()=>{
 const a=await site((req,res)=>{
  if(req.url==='/sign')return res.writeHead(200,{'Set-Cookie':'account=fixture; Path=/; Max-Age=3600','Content-Type':'text/html'}),res.end('<h1>Signed in once</h1>');
  if(req.url==='/whoami')return res.end(`<h1>${/account=fixture/.test(req.headers.cookie||'')?'Signed in as fixture':'Signed out'}</h1>`);
  if(req.url==='/spin')return res.end('<h1>Spinning</h1><script>setTimeout(()=>{for(;;){}},200)</script>');
  res.end('<h1>Page one</h1><form><label>Name<input name="name"></label><button type="button">Go</button></form>');
 });
 const b=await site((req,res)=>res.end('<h1>Page two</h1><script>window.mark="kept"</script>'),'::1');
 const root=await mkdtemp(join(tmpdir(),'buddy-shared-browser-')),browser=new SharedBrowser(join(root,'profile'),{testOrigins:[a.origin,b.origin],commandDeadlineMs:2500});
 try{
  const one=browser.session('task-one'),two=browser.session('task-two');
  const first=await one.navigate(a.origin+'/one'),second=await two.navigate(b.origin+'/two');
  assert.match(first.text,/Page one/);assert.doesNotMatch(first.text,/Page two/);assert.match(second.text,/Page two/);assert.doesNotMatch(second.text,/Page one/);
  assert.equal(browser.context.pages().length,2,'two pages in one Chrome, one per agent');
  const again=await one.read();assert.match(again.text,/Page one/,'reading never shows another agent’s page');
  // An approval prepared on one agent's page cannot be used on the other's.
  const prepared=await one.prepare({snapshotId:again.snapshotId,action:'fill',fields:[{ref:again.controls.find(c=>c.name==='Name').ref,value:'Ada'}]});
  await assert.rejects(two.commit(prepared.token));
  assert.equal(await one.page.locator('[name=name]').inputValue(),'','nothing was filled by the other agent');
  // Accounts are shared: a sign-in made in one agent's page is there for the other.
  await one.navigate(a.origin+'/sign');
  assert.match((await two.navigate(a.origin+'/whoami')).text,/Signed in as fixture/);
  await two.navigate(b.origin+'/two');
  // The network guard covers every page.
  await assert.rejects(two.navigate('http://127.0.0.2/'));
  // Closing one agent's session leaves the other's page as it was.
  await browser.closeSession('task-one');
  assert.equal(browser.context.pages().length,1);assert.equal(await two.page.evaluate(()=>window.mark),'kept');
  // A crashed page is replaced for its own agent only.
  const crashed=browser.session('task-one');await crashed.navigate(a.origin+'/one');
  const cdp=await browser.context.newCDPSession(crashed.page);await cdp.send('Page.crash').catch(()=>{});
  for(let i=0;i<100&&crashed.page;i++)await new Promise(r=>setTimeout(r,50));
  assert.match((await crashed.navigate(a.origin+'/one')).text,/Page one/,'the agent whose page crashed gets a new one');
  assert.equal(await two.page.evaluate(()=>window.mark),'kept','the other agent’s page was untouched');
  // A page that stops responding is reset for its own agent only.
  await crashed.navigate(a.origin+'/spin');await new Promise(r=>setTimeout(r,400));
  await assert.rejects(crashed.read(),/stopped responding/);
  assert.equal(await two.page.evaluate(()=>window.mark),'kept','a stuck page elsewhere never resets this agent’s page');
  assert.match((await two.read()).text,/Page two/);
  assert.ok(browser.context,'Chrome kept running for the other agent');
  // When the last session closes, Chrome closes too, and opens again on the next use.
  await browser.closeSession('task-one');await browser.closeSession('task-two');
  assert.equal(browser.context,null);
  assert.match((await browser.session('task-three').navigate(a.origin+'/whoami')).text,/Signed in as fixture/,'the shared profile keeps the accounts');
 }finally{await browser.close();await rm(root,{recursive:true,force:true});await a.close();await b.close();}
});

test('a password typed in chat goes only into the page that asked, once, and never appears in what an agent observes',{timeout:60000},async()=>{
 const posts={a:[],b:[]};
 const a=await site((req,res,body)=>{
  if(req.method==='POST'){posts.a.push(new URLSearchParams(body).get('password'));res.writeHead(303,{Location:'/dashboard'});return res.end();}
  if(req.url==='/dashboard')return res.end(`<h1>Welcome back</h1><p>Your password ${SECRET} is saved, says this careless site.</p>`);
  res.end(loginForm());
 });
 const b=await site((req,res,body)=>{if(req.method==='POST')posts.b.push(body);res.end(loginForm());});
 const root=await mkdtemp(join(tmpdir(),'buddy-typed-secret-')),browser=new SharedBrowser(join(root,'profile'),{testOrigins:[a.origin,b.origin]});
 try{
  const one=browser.session('task-one'),two=browser.session('task-two');
  const seen=[await one.navigate(a.origin+'/login'),await two.navigate(b.origin+'/login')];
  assert.equal(seen[0].authentication.private,true);assert.deepEqual(seen[0].controls,[]);
  const plan=await one.secretPlan();
  assert.equal(plan.field,'password');assert.equal(plan.origin,a.origin);assert.equal(plan.account,'fixture@example.com');assert.equal(typeof plan.token,'string');
  await assert.rejects(two.fillSecret(plan.token,SECRET),'a token belongs to the page and agent that asked');
  assert.deepEqual(posts,{a:[],b:[]});
  const result=await one.fillSecret(plan.token,SECRET);
  seen.push(result);
  assert.equal(result.signedIn,true);assert.deepEqual(posts.a,[SECRET],'the site that asked received it exactly once');assert.deepEqual(posts.b,[],'the other agent’s site received nothing');
  await assert.rejects(one.fillSecret(plan.token,SECRET),'a token is used once');
  seen.push(await one.read(),await two.read(),await one.navigate(a.origin+'/dashboard'));
  for(const value of seen)assert.ok(!JSON.stringify(value).includes(SECRET),'never in an observation: '+JSON.stringify(value).slice(0,300));
  assert.match(JSON.stringify(seen.at(-1)),/\[private\]/,'a page that echoes it shows it hidden');
  assert.ok(!browser.scrub(`error ${SECRET} ${encodeURIComponent(SECRET)}`).includes(SECRET),'every message is scrubbed');
  assert.deepEqual(posts.a,[SECRET]);
 }finally{await browser.close();await rm(root,{recursive:true,force:true});await a.close();await b.close();}
});

test('a sign-in token refuses a changed page, another site, a stale request and odd values, and types nothing',{timeout:60000},async()=>{
 let posts=0;
 const a=await site((req,res)=>{if(req.method==='POST')posts++;res.end(loginForm());});
 const b=await site((req,res)=>{if(req.method==='POST')posts++;res.end(loginForm());});
 const root=await mkdtemp(join(tmpdir(),'buddy-token-refusals-')),browser=new SharedBrowser(join(root,'profile'),{testOrigins:[a.origin,b.origin],secretTTLms:300});
 try{
  const one=browser.session('task-one');await one.navigate(a.origin+'/login');
  let plan=await one.secretPlan();
  await one.page.evaluate(()=>document.forms[0].insertAdjacentHTML('beforeend','<label>Card number<input name="card"></label>'));
  await assert.rejects(one.fillSecret(plan.token,SECRET),/changed/);
  assert.equal(await one.page.locator('[name=password]').inputValue(),'','nothing was typed into a changed page');
  await one.navigate(a.origin+'/login');plan=await one.secretPlan();await one.navigate(b.origin+'/login');
  await assert.rejects(one.fillSecret(plan.token,SECRET),/changed/);
  await one.navigate(a.origin+'/login');plan=await one.secretPlan();await new Promise(r=>setTimeout(r,500));
  await assert.rejects(one.fillSecret(plan.token,SECRET),/expired/);
  for(const value of ['','two\nlines','x'.repeat(1001),42]){plan=await one.secretPlan();await assert.rejects(one.fillSecret(plan.token,value));}
  assert.equal(posts,0,'no request ever reached a site');
  assert.equal(await one.page.locator('[name=password]').inputValue(),'');
  // A page that asks for a new password (an account being created) is not a typed sign-in.
  await one.page.setContent('<form method="post" action="/x"><input type="password" autocomplete="new-password"><button>Create account</button></form>');
  await assert.rejects(one.secretPlan(),/new account|yourself/);
  // A code that confirms a payment is never typed from the chat.
  await one.page.setContent('<h1>Confirm your payment of $42.00</h1><form method="post" action="/pay"><label>Verification code<input autocomplete="one-time-code" name="otp"></label><button>Verify</button></form>');
  await assert.rejects(one.secretPlan(),/payment/);
 }finally{await browser.close();await rm(root,{recursive:true,force:true});await a.close();await b.close();}
});

test('a wrong password keeps asking with a fresh token, a code step relabels the request, and a step on the phone is re-checked on Done',{timeout:60000},async()=>{
 let approved=false;const got=[];
 const a=await site((req,res,body)=>{
  const form=new URLSearchParams(body);
  if(req.method==='POST'&&req.url==='/session'){got.push('password');if(form.get('password')===SECRET){res.writeHead(303,{Location:'/login/code'});return res.end();}return res.end(loginForm('/session','<p>Incorrect password.</p>'));}
  if(req.url==='/login/code')return res.end('<title>Verify</title><form method="post" action="/code"><label>Verification code<input name="otp" autocomplete="one-time-code" maxlength="6"></label><button>Verify</button></form>');
  if(req.method==='POST'&&req.url==='/code'){got.push('code:'+form.get('otp'));res.writeHead(303,{Location:'/login/approve'});return res.end();}
  if(req.url==='/login/approve')return res.end('<title>Approve</title><h1>Approve the sign-in on your phone</h1><script>setInterval(()=>fetch("/approved").then(r=>r.text()).then(t=>{if(t==="yes")location="/home"}),100)</script>');
  if(req.url==='/approved')return res.end(approved?'yes':'no');
  if(req.url==='/home')return res.end('<h1>Account home</h1>');
  res.end(loginForm());
 });
 const root=await mkdtemp(join(tmpdir(),'buddy-typed-steps-')),browser=new SharedBrowser(join(root,'profile'),{testOrigins:[a.origin]});
 try{
  const one=browser.session('task-one');await one.navigate(a.origin+'/login');
  const plan=await one.secretPlan();
  const wrong=await one.fillSecret(plan.token,'not-the-password');
  assert.equal(wrong.signedIn,false);assert.equal(wrong.next?.field,'password','still the password, with a fresh token');assert.notEqual(wrong.next.token,plan.token);
  const code=await one.fillSecret(wrong.next.token,SECRET);
  assert.equal(code.signedIn,false);assert.equal(code.next?.field,'code','the site now asks for a code');
  const waiting=await one.fillSecret(code.next.token,'480213');
  assert.equal(waiting.signedIn,false);assert.equal(waiting.next,null);assert.equal(waiting.waiting,true,'nothing to type: the person finishes a step elsewhere');
  assert.deepEqual(got,['password','password','code:480213']);
  assert.equal((await one.recheck()).signedIn,false,'Done before the step is finished says so');
  approved=true;await new Promise(r=>setTimeout(r,600));
  const done=await one.recheck();
  assert.equal(done.signedIn,true);assert.match(done.page.text,/Account home/);
  for(const value of [wrong,code,waiting,done])assert.ok(!JSON.stringify(value).includes(SECRET)&&!JSON.stringify(value).includes('480213'));
 }finally{await browser.close();await rm(root,{recursive:true,force:true});await a.close();}
});

test('the saved-login broker on the shared browser still checks only that Chrome filled a password, never its value',{timeout:60000},async()=>{
 const posts=[];
 const a=await site((req,res,body)=>{if(req.method==='POST'){posts.push(new URLSearchParams(body).get('password'));return res.end('<h1>Signed in with the saved login</h1>');}res.end(loginForm());});
 const root=await mkdtemp(join(tmpdir(),'buddy-shared-saved-')),browser=new SharedBrowser(join(root,'profile'),{testOrigins:[a.origin]});
 try{
  const one=browser.session('task-one');await one.navigate(a.origin+'/login');
  let plan=await one.prepareSignIn('signin');
  const unfilled=await one.useSaved(plan.token);
  assert.equal(unfilled.needsUser,true,'nothing saved: the person is asked');assert.deepEqual(posts,[]);
  // Chrome's Password Manager fills the field; the broker only learns that it is filled.
  await one.page.locator('[name=password]').evaluate(e=>{e.value='chrome-filled-fixture';});
  plan=await one.prepareSignIn('signin');const result=await one.useSaved(plan.token);
  assert.equal(result.performed,true);assert.deepEqual(posts,['chrome-filled-fixture']);assert.ok(!JSON.stringify(result).includes('chrome-filled-fixture'));
 }finally{await browser.close();await rm(root,{recursive:true,force:true});await a.close();}
});

test('the person’s Chrome window waits for other agents’ pages, then Done re-checks the page in the agent’s own session',{timeout:60000},async()=>{
 let signedIn=false;
 const a=await site((req,res)=>{
  if(req.url==='/inbox'){if(!signedIn){res.writeHead(302,{Location:'/login'});return res.end();}return res.end('<h1>Inbox</h1>');}
  res.end(loginForm());
 });
 const root=await mkdtemp(join(tmpdir(),'buddy-shared-handoff-')),program=join(root,'fake-chrome');
 await writeFile(program,`#!${process.execPath}\nrequire('node:fs').writeFileSync(${JSON.stringify(join(root,'args.json'))},JSON.stringify(process.argv.slice(2)));setInterval(()=>{},1000);`);await chmod(program,0o700);
 const browser=new SharedBrowser(join(root,'profile'),{testOrigins:[a.origin],manualExecutable:program});
 try{
  const one=browser.session('task-one'),two=browser.session('task-two');
  await one.navigate(a.origin+'/inbox');await two.navigate(a.origin+'/login');
  await assert.rejects(browser.manual(undefined,{session:'task-one'}),/using Buddy’s browser/,'another agent’s open page is never closed under it');
  await browser.closeSession('task-two');
  assert.equal((await browser.manual(undefined,{session:'task-one'})).private,true);
  assert.equal(browser.context,null,'no agent connection while the person uses Chrome');
  await assert.rejects(one.read(),/Chrome is open for you/);
  let args;for(let i=0;i<50;i++){try{args=JSON.parse(await readFile(join(root,'args.json'),'utf8'));break;}catch{await new Promise(r=>setTimeout(r,20));}}
  assert.ok(args.includes(a.origin+'/login'),'Chrome opens at the page that needed the person');assert.ok(args.includes(`--user-data-dir=${join(root,'profile')}`));
  assert.ok(!args.some(x=>/remote-debug|enable-automation|mock-keychain|password-store=basic/.test(x)));
  await browser.finishManual();
  assert.equal((await one.recheck({reload:true})).signedIn,false,'still signed out: Done says so');
  signedIn=true;
  const done=await one.recheck({reload:true});
  assert.equal(done.signedIn,true);assert.match(done.page.text,/Inbox/,'the page the agent wanted, re-opened in its own session');
 }finally{await browser.close();await rm(root,{recursive:true,force:true});await a.close();}
});

test('the browser bridge keeps sessions apart and binds a session to its website scope',{timeout:45000},async()=>{
 const root=await mkdtemp(join(tmpdir(),'buddy-shared-bridge-'));
 try{
  const p=spawn(process.execPath,[fileURLToPath(new URL('../browser.mjs',import.meta.url)),join(root,'profile')],{stdio:['pipe','pipe','pipe']});
  let output='';p.stdout.on('data',x=>output+=x);const errors=[];p.stderr.on('data',x=>errors.push(String(x)));
  const replies=async n=>{for(let i=0;i<400&&output.trim().split('\n').filter(Boolean).length<n;i++)await new Promise(r=>setTimeout(r,50));return output.trim().split('\n').filter(Boolean).map(l=>JSON.parse(l));};
  const send=value=>p.stdin.write(JSON.stringify(value)+'\n');
  send({id:1,command:'read'});
  send({id:2,command:'open',session:'scoped',scope:'https://a.example',url:'https://b.example/'});
  send({id:3,command:'open',session:'scoped',scope:'https://other.example',url:'https://a.example/'});
  send({id:4,command:'sessions'});
  send({id:5,command:'closeSession',session:'scoped'});
  send({id:6,command:'close'});p.stdin.end();
  const got=Object.fromEntries((await replies(6)).map(r=>[r.id,r]));
  assert.match(got[1].error,/session/,'every page command names its session');
  assert.match(got[2].error,/only for https:\/\/a\.example/);
  assert.match(got[3].error,/scope/,'a session keeps the website scope it was opened with');
  assert.deepEqual(got[4].result.sessions,['scoped']);
  assert.equal(got[5].result.closed,true);assert.equal(got[6].result.closed,true);
 }finally{await rm(root,{recursive:true,force:true});}
});

test('the person’s Chrome window never opens inside a Chrome an agent connection still drives',{timeout:45000},async()=>{
 const a=await site((req,res)=>res.end('<h1>Agent page</h1>'));
 const root=await mkdtemp(join(tmpdir(),'buddy-shared-driven-')),profile=join(root,'profile'),program=join(root,'fake-chrome');
 await writeFile(program,`#!${process.execPath}\nrequire('node:fs').writeFileSync(${JSON.stringify(join(root,'opened'))},'yes');setInterval(()=>{},1000);`);await chmod(program,0o700);
 const driving=new SharedBrowser(profile,{testOrigins:[a.origin]}),other=new SharedBrowser(profile,{testOrigins:[a.origin],manualExecutable:program});
 try{
  await driving.session('task-one').navigate(a.origin+'/');
  await assert.rejects(other.manual('google'),/still closing/);
  await new Promise(r=>setTimeout(r,300));
  await assert.rejects(readFile(join(root,'opened'),'utf8'),'no window was opened into it');
 }finally{await other.close().catch(()=>{});await driving.close();await rm(root,{recursive:true,force:true});await a.close();}
});

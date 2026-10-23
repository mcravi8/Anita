import test from 'node:test';
import assert from 'node:assert/strict';
import {publicAddress,publicURL,PrivateBrowser,sessionRefreshDestination} from '../browser.mjs';
import {mkdtemp,rm,symlink,writeFile,readFile,chmod} from 'node:fs/promises';
import {tmpdir,hostname} from 'node:os';
import {join} from 'node:path';
import {spawn} from 'node:child_process';
import {fileURLToPath} from 'node:url';

test('delegated Clerk refresh only permits the exact hosted handshake returning to the same website',()=>{
 const origin='https://console.agentmail.to';
 const handshake=back=>'https://clerk.console.agentmail.to/v1/client/handshake?redirect_url='+encodeURIComponent(back)+'&__session=private-fixture-token';
 assert.equal(sessionRefreshDestination(origin,handshake(origin+'/dashboard')),true);
 for(const raw of [handshake('https://other.example/'),handshake('https://console.agentmail.to.evil.example/'),handshake('http://console.agentmail.to/'),handshake(origin).replace('/handshake','/sign-in'),handshake(origin).replace('clerk.console.agentmail.to','attacker.example'),handshake(origin).replace('https://clerk','http://clerk'),handshake(origin).replace('clerk.console','user:password@clerk.console')])assert.equal(sessionRefreshDestination(origin,raw),false,raw);
 assert.equal(sessionRefreshDestination(origin,'https://clerk.console.agentmail.to/v1/client/handshake'),false);
});
import {createServer} from 'node:http';
test('private, mapped IPv6 and ambiguous network destinations are rejected',async()=>{
  for(const ip of ['127.0.0.1','10.2.3.4','172.16.2.1','192.168.0.1','169.254.169.254','100.64.0.1','0.0.0.0','224.0.0.1','::1','fc00::1','::ffff:127.0.0.1','2001:db8::1'])assert.equal(publicAddress(ip),false,ip);
  assert.equal(publicAddress('192.0.43.8'),true);assert.equal(publicAddress('192.0.0.1'),false);assert.equal(publicAddress('8.8.8.8'),true);assert.equal(publicAddress('2606:4700:4700::1111'),true);
  for(const url of ['file:///etc/passwd','javascript:alert(1)','http://localhost','http://127.0.0.1','http://user:pass@example.com','http://2130706433'])await assert.rejects(publicURL(url));
  await assert.rejects(publicURL('https://example.com',async()=>[{address:'8.8.8.8'},{address:'127.0.0.1'}]));
});
test('private browser forms require fresh, single-use exact operations; passwords are blocked',async()=>{
  let submissions=0;
  const server=createServer((req,res)=>{if(req.url.startsWith('/submit'))submissions++;res.setHeader('Content-Type','text/html');res.end(req.url.startsWith('/submit')?'<h1>Fixture submitted</h1>':'<h1>Inert application</h1><form action="/submit"><label>Name<input name="name"></label><button>Submit fixture</button></form>');});
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  const origin=`http://127.0.0.1:${server.address().port}`,root=await mkdtemp(join(tmpdir(),'buddy-browser-test-')),b=new PrivateBrowser(join(root,'profile'),{testOrigin:origin});
  try{
    const page=await b.navigate(origin);const name=page.controls.find(c=>c.name==='Name');
    assert.equal(submissions,0);
    const prepared=await b.prepare({snapshotId:page.snapshotId,action:'fill',fields:[{ref:name.ref,value:'Fixture Person'}]});
    assert.equal(await b.page.locator('[name=name]').inputValue(),'');assert.equal(prepared.preview.arguments.targets[0].value,'Fixture Person');
    const result=await b.commit(prepared.token);assert.equal(await b.page.locator('[name=name]').inputValue(),'Fixture Person');
    await assert.rejects(b.commit(prepared.token));assert.equal(submissions,0);
    const submit=result.page.controls.find(c=>c.name==='Submit fixture');
    const stale=await b.prepare({snapshotId:result.page.snapshotId,action:'click',ref:submit.ref});
    await b.page.locator('[name=name]').fill('Changed outside approval');await assert.rejects(b.commit(stale.token));assert.equal(submissions,0);
    const fresh=await b.read(),p=await b.prepare({snapshotId:fresh.snapshotId,action:'click',ref:fresh.controls.find(c=>c.name==='Submit fixture').ref});
    await b.commit(p.token);assert.equal(submissions,1);await assert.rejects(b.navigate('http://127.0.0.2'));
  }finally{await b.close();await rm(root,{recursive:true,force:true});await new Promise(resolve=>server.close(resolve));}
});

test('authentication pages reveal no fields, values or text; only the approved saved-login broker can submit',async()=>{
 let submits=0;
 const server=createServer((req,res)=>{res.setHeader('Content-Type','text/html');if(req.method==='POST'){submits++;res.end('<h1>Signed in fixture</h1>');return;}res.end('<title>Private login</title><form method="post" action="/done"><label>Email<input type="email" value="fixture@example.com"></label><label>Password<input type="password" name="password" autocomplete="current-password" value="synthetic-secret-42"></label><button>Sign in</button></form>');});
 await new Promise(r=>server.listen(0,'127.0.0.1',r));const origin=`http://127.0.0.1:${server.address().port}`,root=await mkdtemp(join(tmpdir(),'buddy-auth-test-')),b=new PrivateBrowser(join(root,'profile'),{testOrigin:origin});
 try{let page=await b.navigate(origin+'/login');assert.equal(page.authentication.private,true);assert.deepEqual(page.controls,[]);assert.ok(!JSON.stringify(page).includes('synthetic-secret-42'));await assert.rejects(b.prepare({snapshotId:'x',action:'fill',fields:[{ref:'0',value:'secret'}]}));
  await b.page.locator('[name=password]').evaluate(e=>e.type='text');page=await b.read();assert.equal(page.authentication.private,true);assert.ok(!JSON.stringify(page).includes('synthetic-secret-42'));
  await b.page.locator('[name=password]').evaluate(e=>e.type='password');const plan=await b.prepareSignIn('signin');assert.equal(plan.accountEmail,'fixture@example.com');assert.equal(submits,0);const result=await b.useSaved(plan.token);assert.equal(result.performed,true);assert.equal(submits,1);await assert.rejects(b.useSaved(plan.token));assert.ok(!JSON.stringify(result).includes('synthetic-secret-42'));
 }finally{await b.close();await rm(root,{recursive:true,force:true});await new Promise(r=>server.close(r));}
});

test('email verification is origin-bound, fresh and single-use, with the code absent from the result',async()=>{
 let codes=[];
 const server=createServer(async(req,res)=>{res.setHeader('Content-Type','text/html');if(req.method==='POST'){let data='';for await(const chunk of req)data+=chunk;codes.push(new URLSearchParams(data).get('otp'));res.end('<h1>Verified 410239</h1>');return;}res.end('<h1>Verify your email</h1><p>Code sent to fixture@example.com</p><form method="post" action="/verified"><label>Verification code<input name="otp" autocomplete="one-time-code" maxlength="6"></label><button>Verify</button></form>');});
 await new Promise(r=>server.listen(0,'127.0.0.1',r));const origin=`http://127.0.0.1:${server.address().port}`,root=await mkdtemp(join(tmpdir(),'buddy-code-test-')),b=new PrivateBrowser(join(root,'profile'),{testOrigin:origin});
 try{const page=await b.navigate(origin);assert.equal(page.authentication.kind,'verification');const plan=await b.verificationPlan();assert.equal(plan.email,'fixture@example.com');await assert.rejects(b.verifyEmail('forged','410239'));assert.deepEqual(codes,[]);const fresh=await b.verificationPlan();const result=await b.verifyEmail(fresh.token,'410239');assert.equal(result.performed,true);assert.deepEqual(codes,['410239']);assert.ok(!JSON.stringify(result).includes('410239'));await assert.rejects(b.verifyEmail(fresh.token,'410239'));
 }finally{await b.close();await rm(root,{recursive:true,force:true});await new Promise(r=>server.close(r));}
});

test('JSONL browser bridge starts through a symlinked application path',async()=>{
 const root=await mkdtemp(join(tmpdir(),'buddy-browser-entry-'));const alias=join(root,'browser.mjs');
 try{
  await symlink(fileURLToPath(new URL('../browser.mjs',import.meta.url)),alias);
  const p=spawn(process.execPath,[alias,join(root,'profile')],{stdio:['pipe','pipe','pipe']});let output='',errors='';p.stdout.on('data',x=>output+=x);p.stderr.on('data',x=>errors+=x);p.stdin.end(JSON.stringify({id:1,command:'close'})+'\n');
  const code=await new Promise((resolve,reject)=>{p.on('error',reject);p.on('exit',resolve);});assert.equal(code,0,errors);assert.equal(JSON.parse(output).result.closed,true);
 }finally{await rm(root,{recursive:true,force:true});}
});

test('private handoff launches an ordinary separate profile with no agent/debugging connection',async()=>{
 const root=await mkdtemp(join(tmpdir(),'buddy-private-window-test-')),program=join(root,'fake-chrome');
 await writeFile(program,`#!${process.execPath}\nrequire('node:fs').writeFileSync(${JSON.stringify(join(root,'args.json'))},JSON.stringify(process.argv.slice(2)));setInterval(()=>{},1000);`);await chmod(program,0o700);
 const b=new PrivateBrowser(join(root,'profile'),{manualExecutable:program});
 try{assert.equal((await b.manual('google')).private,true);assert.equal(b.context,null);await assert.rejects(b.read(),/Private sign-in is open/);
  let args;for(let i=0;i<50;i++){try{args=JSON.parse(await readFile(join(root,'args.json'),'utf8'));break;}catch{await new Promise(r=>setTimeout(r,20));}}
  assert.ok(args.includes('chrome://settings/people'));assert.ok(args.some(x=>x===`--user-data-dir=${join(root,'profile')}`));assert.ok(!args.some(x=>/remote-debug|enable-automation|mock-keychain|password-store=basic/.test(x)));
  assert.equal((await b.finishManual()).closed,true);
 }finally{await b.close();await rm(root,{recursive:true,force:true});}
});


test('private Chrome recovers only a same-user dead-process lock and keeps saved profile data',async()=>{
 const root=await mkdtemp(join(tmpdir(),'buddy-stale-profile-')),lock=join(root,'SingletonLock'),saved=join(root,'saved-fixture.txt');
 const dead=spawn(process.execPath,['-e','process.exit(0)']);await new Promise(r=>dead.once('exit',r));
 const b=new PrivateBrowser(root);
 try{await writeFile(saved,'keep saved browser data');await symlink(`${hostname()}-${dead.pid}`,lock);assert.equal(await b.profileLock(),null);assert.equal(await readFile(saved,'utf8'),'keep saved browser data');
  await symlink(`${hostname()}-${process.pid}`,lock);assert.equal(await b.profileLock(),process.pid);assert.equal(await readFile(saved,'utf8'),'keep saved browser data');
 }finally{await rm(root,{recursive:true,force:true});}
});
test('a Chrome process that exits before opening cannot report a successful private handoff',async()=>{
 const root=await mkdtemp(join(tmpdir(),'buddy-missing-window-')),program=join(root,'fake-chrome');await writeFile(program,'#!/bin/sh\nexit 1\n');await chmod(program,0o700);
 const b=new PrivateBrowser(join(root,'profile'),{manualExecutable:program});
 try{await assert.rejects(b.manual('google'),/Chrome did not open/);assert.equal(b.manualProcess,null);}finally{await rm(root,{recursive:true,force:true});}
});
test('finishing sign-in closes only the verified Chrome profile, including after a re-exec',async()=>{
 const root=await mkdtemp(join(tmpdir(),'buddy-reexec-profile-')),b=new PrivateBrowser(root,{manualExecutable:process.execPath}),child=spawn(process.execPath,['-e','setInterval(()=>{},1000)','--',`--user-data-dir=${root}`]);
 try{await new Promise(r=>child.once('spawn',r));await symlink(`${hostname()}-${child.pid}`,join(root,'SingletonLock'));await b.closeManualProfile();assert.ok(child.exitCode!==null||child.signalCode!==null);assert.equal(await b.profileLock(),null);}finally{if(child.exitCode===null&&child.signalCode===null)child.kill();await rm(root,{recursive:true,force:true});}
 const other=await mkdtemp(join(tmpdir(),'buddy-other-profile-')),kept=spawn(process.execPath,['-e','setInterval(()=>{},1000)','--',`--user-data-dir=${other}`]);
 await new Promise(r=>kept.once('spawn',r));
 const wrong=await mkdtemp(join(tmpdir(),'buddy-wrong-profile-')),c=new PrivateBrowser(wrong,{manualExecutable:process.execPath});
 try{await symlink(`${hostname()}-${kept.pid}`,join(wrong,'SingletonLock'));await assert.rejects(c.closeManualProfile(),/Close Buddy/);assert.equal(kept.exitCode,null);assert.equal(kept.signalCode,null);}finally{kept.kill();await rm(other,{recursive:true,force:true});await rm(wrong,{recursive:true,force:true});}
});

test('Google sign-in switches to existing-account login and reuses one saved account without exposing credentials',async()=>{
 let signupClicks=0,googleClicks=0,accountClicks=0,consentClicks=0,scenario='account';
 const server=createServer((req,res)=>{res.setHeader('Content-Type','text/html');
  if(req.url==='/sign-up')return res.end('<form><input type="password" autocomplete="new-password"><button type="button" onclick="fetch(\'/bad-signup\')">Google</button></form><a href="/sign-in">Sign in</a>');
  if(req.url==='/bad-signup'){signupClicks++;return res.end('Bad signup');}
  if(req.url==='/sign-in')return res.end(`<input type="password" autocomplete="current-password" value="private-fixture-password"><button onclick="location.href='/start-google'">Google</button>`);
  if(req.url==='/start-google'){googleClicks++;res.statusCode=302;res.setHeader('Location','/google/'+scenario);return res.end();}
  if(req.url==='/google/account')return res.end('<div role="link" tabindex="0" data-identifier="fixture@example.test" onclick="location.href=\'/account-selected\'">Fixture account</div>');
  if(req.url==='/account-selected'){accountClicks++;res.statusCode=302;res.setHeader('Location','/dashboard');return res.end();}
  if(req.url==='/google/multiple')return res.end('<div role="link" data-identifier="one@example.test">One</div><div role="link" data-identifier="two@example.test">Two</div>');
  if(req.url==='/google/consent')return res.end('<div data-identifier="fixture@example.test">Account</div><button onclick="location.href=\'/permission-granted\'">Allow</button>');
  if(req.url==='/permission-granted'){consentClicks++;return res.end('Wrong permission grant');}
  if(req.url==='/google/challenge')return res.end('<input type="password" value="private-google-password"><button>Continue</button>');
  res.end('<h1>Existing account dashboard</h1>');
 });
 await new Promise(r=>server.listen(0,'127.0.0.1',r));const origin=`http://127.0.0.1:${server.address().port}`,root=await mkdtemp(join(tmpdir(),'buddy-google-signin-')),b=new PrivateBrowser(join(root,'profile'),{testOrigin:origin,testGooglePath:'/google/'});
 try{
  await b.navigate(origin+'/sign-up');let plan=await b.prepareSignIn('signin');assert.equal(plan.googleAvailable,true);let result=await b.useSaved(plan.token);
  assert.equal(result.performed,true);assert.equal(result.method,'google');assert.equal(result.page.title,await b.page.title());assert.match(result.page.text,/Existing account dashboard/);assert.equal(signupClicks,0);assert.equal(googleClicks,1);assert.equal(accountClicks,1);assert.ok(!JSON.stringify(result).includes('private-fixture-password'));
  for(const value of ['multiple','consent','challenge']){scenario=value;await b.navigate(origin+'/sign-in');plan=await b.prepareSignIn('signin');result=await b.useSaved(plan.token);assert.equal(result.needsUser,true,value);assert.equal(result.method,'google');assert.equal(result.page,undefined);assert.ok(!JSON.stringify(result).includes('private-google-password'));}
  assert.equal(accountClicks,1,'multiple accounts and consent never select or grant automatically');assert.equal(consentClicks,0);
 }finally{await b.close();await rm(root,{recursive:true,force:true});await new Promise(r=>server.close(r));}
});

test('Google sign-in never registers an account or follows a different identity provider',async()=>{
 let bad=0;const server=createServer((req,res)=>{res.setHeader('Content-Type','text/html');if(req.url==='/register')return res.end('<input type="password" autocomplete="new-password"><button onclick="location.href=\'/bad\'">Google</button>');if(req.url==='/bad')bad++;res.end('<input type="password" autocomplete="current-password"><a href="https://not-google.example/login">Continue with Google</a>');});
 await new Promise(r=>server.listen(0,'127.0.0.1',r));const origin=`http://127.0.0.1:${server.address().port}`,root=await mkdtemp(join(tmpdir(),'buddy-google-scope-')),b=new PrivateBrowser(root,{testOrigin:origin});
 try{for(const path of ['/register','/sign-in']){await b.navigate(origin+path);const plan=await b.prepareSignIn('signin'),result=await b.useSaved(plan.token);assert.equal(result.needsUser,true);}assert.equal(bad,0);}finally{await b.close();await rm(root,{recursive:true,force:true});await new Promise(r=>server.close(r));}
});

test('Google OAuth popup keeps its callback alive until the original site is signed in',async()=>{
 let picks=0;const server=createServer((req,res)=>{res.setHeader('Content-Type','text/html');
  if(req.url==='/sign-in')return res.end('<input type="password"><button onclick="window.open(\'/google/account\')">Continue with Google</button>');
  if(req.url==='/google/account')return res.end('<div role="link" data-identifier="fixture@example.test" onclick="location.href=\'/oauth_callback\'">Fixture account</div>');
  if(req.url==='/oauth_callback'){picks++;return res.end('<script>setTimeout(()=>{window.opener.location="/dashboard";window.close();},300)</script>');}
  res.end('<h1>Signed-in popup fixture</h1>');
 });
 await new Promise(r=>server.listen(0,'127.0.0.1',r));const origin=`http://127.0.0.1:${server.address().port}`,root=await mkdtemp(join(tmpdir(),'buddy-google-popup-')),b=new PrivateBrowser(root,{testOrigin:origin,testGooglePath:'/google/'});
 try{await b.navigate(origin+'/sign-in');const plan=await b.prepareSignIn('signin'),result=await b.useSaved(plan.token);assert.equal(result.performed,true);assert.equal(result.method,'google');assert.match(result.page.text,/Signed-in popup fixture/);assert.equal(picks,1);assert.equal(b.context.pages().length,1);}finally{await b.close();await rm(root,{recursive:true,force:true});await new Promise(r=>server.close(r));}
});

test('Google login waits for a client-rendered sign-in page instead of clicking the old registration button',async()=>{
 let registration=0,signin=0;const server=createServer((req,res)=>{res.setHeader('Content-Type','text/html');
  if(req.url==='/sign-up')return res.end(`<input autocomplete="new-password" type="password"><button onclick="fetch('/bad-registration')">Google</button><a href="/sign-in" id="existing">Sign in</a><script>document.querySelector('#existing').addEventListener('click',event=>{event.preventDefault();history.pushState({},'',event.currentTarget.href);setTimeout(()=>{document.body.innerHTML=${JSON.stringify('<input type="password"><button onclick="location.href=\'/google/account\'">Google</button><a href="/sign-up">Sign up</a>')};},300);});</script>`);
  if(req.url==='/bad-registration'){registration++;return res.end('Not allowed');}
  if(req.url==='/google/account')return res.end('<div role="link" data-identifier="fixture@example.test" onclick="location.href=\'/dashboard\'">Fixture account</div>');
  signin++;res.end('<h1>Signed in through SPA Google</h1>');
 });
 await new Promise(r=>server.listen(0,'127.0.0.1',r));const origin=`http://127.0.0.1:${server.address().port}`,root=await mkdtemp(join(tmpdir(),'buddy-google-spa-')),b=new PrivateBrowser(root,{testOrigin:origin,testGooglePath:'/google/'});
 try{await b.navigate(origin+'/sign-up');const plan=await b.prepareSignIn('signin'),result=await b.useSaved(plan.token);assert.equal(result.performed,true);assert.equal(result.method,'google');assert.match(result.page.text,/Signed in through SPA Google/);assert.equal(registration,0);assert.ok(signin>=1);}finally{await b.close();await rm(root,{recursive:true,force:true});await new Promise(r=>server.close(r));}
});

test('delegated browser retains the existing session while restricting access to the shared website',async()=>{
 let outsideHits=0;const outside=createServer((req,res)=>{outsideHits++;res.end('<h1>Other site</h1>');});await new Promise(r=>outside.listen(0,'127.0.0.1',r));const other=`http://127.0.0.1:${outside.address().port}`;
 const server=createServer((req,res)=>{if(req.url==='/redirect'){res.writeHead(302,{Location:other});return res.end();}res.setHeader('Content-Type','text/html');res.end('<h1>Existing signed-in mailbox fixture</h1>');});
 await new Promise(r=>server.listen(0,'127.0.0.1',r));const origin=`http://127.0.0.1:${server.address().port}`,root=await mkdtemp(join(tmpdir(),'buddy-shared-site-')),profile=join(root,'profile');
 let b=new PrivateBrowser(profile,{testOrigin:origin});
 try{
  await b.navigate(origin);await b.context.addCookies([{name:'session',value:'fixture-session',url:origin,expires:Math.floor(Date.now()/1000)+3600}]);await b.close();
  b=new PrivateBrowser(profile,{testOrigin:origin,sharedOrigin:origin});const page=await b.navigate(origin);assert.match(page.text,/Existing signed-in mailbox/);assert.equal((await b.context.cookies(origin)).find(c=>c.name==='session')?.value,'fixture-session');
  await assert.rejects(b.navigate(other),/only for/);await assert.rejects(b.navigate(origin+'/redirect'));assert.equal(outsideHits,0,'cross-origin redirects never reach the other website');
  b.assertScope(origin+'/inboxes');assert.throws(()=>b.assertScope(other),/only for/);
 }finally{await b.close();await rm(root,{recursive:true,force:true});await new Promise(r=>server.close(r));await new Promise(r=>outside.close(r));}
});

test('a site that opens on its sign-up page, with a Sign in button, is signed in to with Google from its sign-in page and never registers',async()=>{
 // RunPod, 23 Oct: console.runpod.io opens on /signup ("Sign up with Google"); its "Sign in" is a button, not a link, and /login offers
 // "Google". Buddy saw no Google option on the sign-up page and could not get to the sign-in page, so the user had to sign in by hand.
 let registered=0,googleClicks=0,accountClicks=0;
 const server=createServer((req,res)=>{res.setHeader('Content-Type','text/html');
  if(req.url.startsWith('/signup'))return res.end(`<h1>Sign up for Fixture</h1><button onclick="fetch('/register-google');this.textContent='Registering'">Sign up with Google</button><button onclick="history.pushState({},'','/login');document.body.innerHTML='<h1>Log in</h1><input type=email><button onclick=&quot;location.href=\\'/start-google\\'&quot;>Google</button>'">Sign in</button>`);
  if(req.url==='/register-google'){registered++;return res.end('');}
  if(req.url==='/start-google'){googleClicks++;res.statusCode=302;res.setHeader('Location','/google/account');return res.end();}
  if(req.url==='/google/account')return res.end('<div role="link" tabindex="0" data-identifier="fixture@example.test" onclick="location.href=\'/account-selected\'">Fixture account</div>');
  if(req.url==='/account-selected'){accountClicks++;res.statusCode=302;res.setHeader('Location','/dashboard');return res.end();}
  res.end('<h1>Pods dashboard</h1>');
 });
 await new Promise(r=>server.listen(0,'127.0.0.1',r));const origin=`http://127.0.0.1:${server.address().port}`,root=await mkdtemp(join(tmpdir(),'buddy-google-button-signin-')),b=new PrivateBrowser(join(root,'profile'),{testOrigin:origin,testGooglePath:'/google/'});
 try{
  await b.navigate(origin+'/signup?redirect=%2F');const plan=await b.prepareSignIn('signin');
  assert.equal(plan.googleAvailable,true,'Google is available behind the sign-in button');
  const result=await b.useSaved(plan.token);
  assert.equal(result.performed,true,JSON.stringify(result));assert.equal(result.method,'google');assert.match(result.page.text,/Pods dashboard/);
  assert.equal(registered,0,'the sign-up Google button is never pressed');assert.equal(googleClicks,1);assert.equal(accountClicks,1);
 }finally{await b.close();await rm(root,{recursive:true,force:true});await new Promise(r=>server.close(r));}
});

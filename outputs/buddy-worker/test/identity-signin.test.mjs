import test from 'node:test';
import assert from 'node:assert/strict';
import {SharedBrowser} from '../browser.mjs';
import {mkdtemp,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {createServer} from 'node:http';

// Google, Microsoft and Apple sign-ins take a password or a one-time code typed in the chat's private field, like any other site: it goes
// only into that page. Recovery and security pages, a new password, and a code that confirms a payment still go to Buddy's Chrome window,
// and so does a sign-in Google refuses because an agent drives the browser.
const SECRET='Typed-Google-Pw-5150!';
async function google(){
 const posts=[];
 const server=createServer(async(req,res)=>{
  let body='';for await(const chunk of req)body+=chunk;
  res.setHeader('Content-Type','text/html');
  const u=new URL(req.url,'http://x');
  if(req.method==='POST'){posts.push({path:u.pathname,body:Object.fromEntries(new URLSearchParams(body))});res.writeHead(303,{Location:u.pathname==='/accounts/lookup'?'/accounts/signin':u.pathname==='/accounts/password'?'/accounts/code':u.pathname==='/accounts/rejected'?'/accounts/not-secure':'/mail/'});return res.end();}
  if(u.pathname==='/accounts/identifier')return res.end(`<title>Sign in – Google Accounts</title><h1>Sign in</h1><form method="post" action="/accounts/lookup"><label>Email or phone<input type="email" name="identifier" autocomplete="username"></label><button>Next</button></form>`);
  if(u.pathname==='/accounts/signin')return res.end(`<title>Sign in – Google Accounts</title><h1>Welcome</h1><form method="post" action="/accounts/password"><input type="email" name="identifier" value="craviott@usc.edu" readonly><label>Enter your password<input type="password" name="Passwd" autocomplete="current-password"></label><button>Next</button></form>`);
  if(u.pathname==='/accounts/code')return res.end(`<title>2-Step Verification</title><h1>2-Step Verification</h1><form method="post" action="/accounts/totp"><label>Enter code<input name="totpPin" autocomplete="one-time-code"></label><button>Next</button></form>`);
  if(u.pathname==='/accounts/blocked')return res.end(`<title>Sign in – Google Accounts</title><form method="post" action="/accounts/rejected"><input type="email" name="identifier" value="craviott@usc.edu" readonly><label>Enter your password<input type="password" name="Passwd"></label><button>Next</button></form>`);
  if(u.pathname==='/accounts/not-secure')return res.end(`<title>Couldn’t sign you in</title><h1>Couldn’t sign you in</h1><p>This browser or app may not be secure. Try using a different browser.</p>`);
  if(u.pathname==='/accounts/recovery')return res.end(`<title>Account recovery</title><h1>Recover your account</h1><form method="post" action="/accounts/r"><label>Enter the last password you remember<input type="password" name="p"></label><button>Next</button></form>`);
  if(u.pathname==='/accounts/pay')return res.end(`<title>Confirm your payment</title><h1>Confirm the purchase</h1><p>Enter the code we sent to approve this payment of $49.</p><form method="post" action="/accounts/p"><label>Verification code<input name="c" autocomplete="one-time-code"></label><button>Verify</button></form>`);
  if(u.pathname==='/accounts/new')return res.end(`<title>Create a password</title><form method="post" action="/accounts/n"><label>New password<input type="password" name="n" autocomplete="new-password"></label><button>Change</button></form>`);
  res.end('<title>Inbox</title><h1>Inbox</h1>');
 });
 await new Promise(r=>server.listen(0,'127.0.0.1',r));
 return {posts,origin:`http://127.0.0.1:${server.address().port}`,close:()=>new Promise(r=>server.close(r))};
}

test('Google’s own sign-in takes the typed password and then the typed code, only into its own page; recovery, a new password and a payment code still need Chrome; a refused automated sign-in goes to Chrome',{timeout:90000},async()=>{
 const g=await google(),root=await mkdtemp(join(tmpdir(),'buddy-identity-signin-'));
 const browser=new SharedBrowser(join(root,'profile.noindex'),{testOrigins:[g.origin],testGoogle:[g.origin],testGooglePath:'/accounts/'});
 try{
  const s=browser.session('task-g');
  // Google asks for the account first: the email is typed in the chat as well.
  await s.navigate(g.origin+'/accounts/identifier');
  const who=await s.secretPlan();
  assert.equal(who.field,'username');
  const asked=await s.fillSecret(who.token,'craviott@usc.edu');
  assert.equal(asked.signedIn,false);assert.equal(asked.next?.field,'password','then its password');
  assert.equal(g.posts[0].body.identifier,'craviott@usc.edu');g.posts.length=0;
  // A task pinned to one account types no other email.
  const pinned=browser.session('task-pinned','','craviott@usc.edu');await pinned.navigate(g.origin+'/accounts/identifier');
  await assert.rejects(pinned.fillSecret((await pinned.secretPlan()).token,'me.personal@gmail.com'),/craviott@usc\.edu/);
  assert.deepEqual(g.posts,[],'nothing was typed or sent');
  await s.navigate(g.origin+'/accounts/signin');
  const plan=await s.secretPlan();
  assert.equal(plan.field,'password');assert.equal(plan.account,'craviott@usc.edu');
  const first=await s.fillSecret(plan.token,SECRET);
  assert.equal(first.signedIn,false);assert.equal(first.next?.field,'code','Google now asks for the code, typed in the chat too');
  const second=await s.fillSecret(first.next.token,'492011');
  assert.equal(second.signedIn,true);assert.match(second.page.text,/Inbox/);
  assert.deepEqual(g.posts.map(p=>p.path),['/accounts/password','/accounts/totp']);
  assert.equal(g.posts[0].body.Passwd,SECRET);assert.equal(g.posts[1].body.totpPin,'492011');
  assert.ok(!JSON.stringify([plan,first,second]).includes(SECRET),'what was typed never comes back');
  // Still the person's, in Buddy's Chrome window.
  await s.navigate(g.origin+'/accounts/recovery');await assert.rejects(s.secretPlan(),/recovery|security/i);
  await s.navigate(g.origin+'/accounts/pay');await assert.rejects(s.secretPlan(),/payment/i);
  await s.navigate(g.origin+'/accounts/new');await assert.rejects(s.secretPlan(),/new password/i);
  // Google refuses the sign-in because an agent drives this browser: the person is sent to Buddy's Chrome window.
  await s.navigate(g.origin+'/accounts/blocked');
  const blocked=await s.fillSecret((await s.secretPlan()).token,SECRET);
  assert.equal(blocked.signedIn,false);assert.equal(blocked.needsChrome,true);assert.match(blocked.reason,/Chrome window/);
 }finally{await browser.close();await rm(root,{recursive:true,force:true});await g.close();}
});

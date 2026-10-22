import test from 'node:test';
import assert from 'node:assert/strict';
import {SharedBrowser} from '../browser.mjs';
import {mkdtemp,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {createServer} from 'node:http';

// "When it needs to access something and an account is needed, ask each time … it's not enabled to spend money or sign up for free trials."
// Once the person said yes in the chat, Buddy creates the account itself in the task's own page of Buddy's Chrome: the task's email, a
// password Buddy made (the agent never sees it), only the required standard terms ticked, then the email confirmed from the person's mailbox.
// A sign-up that asks for payment or starts a trial that becomes paid is stopped before anything is sent. A forgotten password is reset through
// the email. A fixture careers site on 127.0.0.1 with a stand-in mailbox; nothing reaches the internet (every other host is refused).
const EMAIL='matteo.craviotto@gmail.com',PASSWORD='Gen-7Qx!pV2m-rT9#kL4w',NEW_PASSWORD='Gen-3Hb!nW8z-cP5$yR1q';
const offline=async()=>{throw Error('offline fixture: no other host');};
async function careers(){
 const accounts=new Map(),mailbox=[],posts=[];let next=0;
 const token=()=>'t'+(++next)+'x'+Math.random().toString(36).slice(2,10);
 const form=(action,{title='Create your account',extra='',error='',email=''}={})=>`<title>${title}</title><h1>${title}</h1>${error?`<p role="alert" class="error">${error}</p>`:''}<form method="post" action="${action}">
  <label>Email<input type="email" name="email" value="${email}" required></label>
  <label>Password<input type="password" name="password" autocomplete="new-password" required></label>
  <label>Confirm password<input type="password" name="confirm" autocomplete="new-password" required></label>
  <label><input type="checkbox" name="terms" required> I agree to the Terms of Use and Privacy Policy</label>
  <label><input type="checkbox" name="marketing"> Subscribe to our newsletter and job alerts</label>${extra}
  <button type="submit">Create account</button></form><p>Already registered? <a href="/login">Sign in</a></p>`;
 const login=(error='',email='')=>`<title>Sign in</title><h1>Sign in</h1>${error?`<p role="alert">${error}</p>`:''}<form method="post" action="/login"><label>Email<input type="email" name="email" autocomplete="username" value="${email}"></label><label>Password<input type="password" name="password" autocomplete="current-password"></label><button>Sign in</button></form><p><a href="/forgot">Forgot password?</a> · <a href="/join">Create an account</a></p>`;
 const server=createServer(async(req,res)=>{
  let body='';for await(const chunk of req)body+=chunk;
  const url=new URL(req.url,'http://fixture'),f=new URLSearchParams(body),origin=`http://127.0.0.1:${server.address().port}`;
  const html=(text,status=200)=>{res.statusCode=status;res.setHeader('Content-Type','text/html');res.end(text);};
  const go=to=>{res.writeHead(303,{Location:to});res.end();};
  if(req.method==='POST')posts.push({path:url.pathname,fields:Object.fromEntries(f)});
  const join=(action,{extra='',then='/check-email'}={})=>{
   if(req.method!=='POST')return html(form(action,{extra}));
   if(f.get('password')!==f.get('confirm'))return html(form(action,{extra,error:'The passwords don’t match.'}));
   if(f.get('terms')!=='on')return html(form(action,{extra,error:'Please accept the terms.'}));
   if(accounts.has(f.get('email')))return html(form(action,{extra,error:'An account with this email already exists.'}));
   const t=token();accounts.set(f.get('email'),{password:f.get('password'),marketing:f.get('marketing')==='on',verified:false,first:f.get('first')||'',token:t});
   mailbox.push({to:f.get('email'),from:'no-reply@careers.fixture',subject:'Confirm your email',link:`${origin}/confirm?token=${t}`});
   return go(then);
  };
  if(url.pathname==='/join')return join('/join');
  if(url.pathname==='/join-name')return join('/join-name',{extra:'<label>First name *<input name="first" required></label>'});
  if(url.pathname==='/check-email')return html('<title>Check your email</title><h1>Check your email</h1><p>We sent a confirmation link to your email address. Open it to activate your account.</p>');
  if(url.pathname==='/confirm'){const who=[...accounts.values()].find(a=>a.token===url.searchParams.get('token'));if(!who)return html('<h1>This link has expired</h1>',404);who.verified=true;return html('<title>Welcome</title><h1>Email confirmed</h1><p>Welcome to the fixture careers site. Your applications will show here.</p>');}
  if(url.pathname==='/login'){
   if(req.method!=='POST')return html(login());
   const who=accounts.get(f.get('email'));
   if(!who||who.password!==f.get('password'))return html(login('Incorrect email or password.'));
   res.writeHead(303,{Location:'/home','Set-Cookie':'session=fixture-'+token()+'; Path=/'});return res.end();
  }
  if(url.pathname==='/home')return html('<title>Your applications</title><h1>Your applications</h1><p>No applications yet.</p>');
  if(url.pathname==='/forgot'){
   if(req.method!=='POST')return html('<title>Reset your password</title><h1>Forgot your password?</h1><form method="post" action="/forgot"><label>Email<input type="email" name="email"></label><button>Send reset link</button></form>');
   const who=accounts.get(f.get('email'));if(who){who.reset=token();mailbox.push({to:f.get('email'),from:'no-reply@careers.fixture',subject:'Reset your password',link:`${origin}/reset?token=${who.reset}`});}
   return html('<title>Check your email</title><h1>Check your email</h1><p>If an account exists, we emailed you a link to reset your password.</p>');
  }
  if(url.pathname==='/reset'){
   const who=[...accounts.values()].find(a=>a.reset&&a.reset===(url.searchParams.get('token')||f.get('token')));
   if(!who)return html('<h1>This link has expired</h1>',404);
   if(req.method!=='POST')return html(`<title>Choose a new password</title><h1>Choose a new password</h1><form method="post" action="/reset"><input type="hidden" name="token" value="${who.reset}"><label>New password<input type="password" name="password" autocomplete="new-password"></label><label>Confirm new password<input type="password" name="confirm" autocomplete="new-password"></label><button>Save new password</button></form>`);
   if(f.get('password')!==f.get('confirm'))return html('<h1>The passwords don’t match</h1>');
   who.password=f.get('password');who.reset='';return go('/login');
  }
  // A sign-up that starts a trial that becomes paid, one that asks for a card in a payment provider's frame, and one with a CAPTCHA.
  if(url.pathname==='/trial')return join('/trial',{extra:'<p>Start your 14-day free trial. Then $12/month, cancel anytime.</p>'});
  if(url.pathname==='/pay')return join('/pay',{extra:'<p>Payment details</p><iframe title="Secure card payment input frame" src="https://js.stripe.com/v3/elements-inner-card.html" width="300" height="40"></iframe>'});
  if(url.pathname==='/captcha')return join('/captcha',{extra:'<div class="g-recaptcha" data-sitekey="fixture-key" style="width:300px;height:70px"></div>'});
  // A sign-up whose next step is a code texted to the person's phone.
  if(url.pathname==='/sms')return join('/sms',{then:'/sms-code'});
  if(url.pathname==='/sms-code'){
   if(req.method!=='POST')return html('<title>Verify your phone</title><h1>Enter the code we texted to your phone</h1><form method="post" action="/sms-code"><label>Verification code<input name="otp" autocomplete="one-time-code" maxlength="6"></label><button>Verify</button></form>');
   return go('/home');
  }
  // A page where an agent might try to pay: a card number field and a trial button.
  if(url.pathname==='/upgrade')return html('<title>Premium</title><h1>Go premium</h1><form method="post" action="/upgrade"><label>Name on card<input name="holder" autocomplete="cc-name"></label><label>Card number<input name="card" autocomplete="cc-number"></label><button type="submit">Start free trial</button></form><a href="/home">Not now</a>');
  html('<h1>Not found</h1>',404);
 });
 await new Promise(r=>server.listen(0,'127.0.0.1',r));
 return {accounts,mailbox,posts,origin:`http://127.0.0.1:${server.address().port}`,close:()=>new Promise(r=>server.close(r))};
}
async function fixture(name,site){
 const root=await mkdtemp(join(tmpdir(),name));
 return {root,browser:new SharedBrowser(join(root,'profile.noindex'),{testOrigins:[site.origin],resolver:offline})};
}
const never=(values,needle)=>{for(const v of values)assert.ok(!JSON.stringify(v).includes(needle),'the generated password is never in what an agent or the chat sees: '+JSON.stringify(v).slice(0,400));};

test('after the person’s yes, Buddy fills the sign-up itself: the task’s email, its own password, only the required terms; it confirms the email and the next sign-in fills both fields',{timeout:120000},async()=>{
 const site=await careers(),{root,browser}=await fixture('buddy-accounts-signup-',site);
 try{
  const s=browser.session('task-apply','',EMAIL);
  // The agent sees nothing of the sign-up form: it is private.
  const read=await s.navigate(site.origin+'/join');
  assert.equal(read.authentication?.private,true);assert.deepEqual(read.controls,[]);
  const plan=await s.signupPlan({email:EMAIL});
  assert.equal(plan.found,true);assert.equal(plan.ready,true,JSON.stringify(plan));assert.equal(plan.origin,site.origin);
  assert.deepEqual(plan.terms,['I agree to the Terms of Use and Privacy Policy'],'the required terms are the only box Buddy ticks');
  assert.deepEqual(plan.optional,['Subscribe to our newsletter and job alerts'],'an optional newsletter box is left alone');
  assert.equal(plan.money,null,'a newsletter box is not a payment, even though it says subscribe');assert.equal(plan.captcha,false);
  assert.deepEqual(site.posts,[],'planning sends nothing');
  // A pinned task never signs up as another email.
  await assert.rejects(s.signup(plan.token,{email:'someone.else@example.com',password:PASSWORD}),/matteo\.craviotto@gmail\.com/);
  const again=await s.signupPlan({email:EMAIL});
  const made=await s.signup(again.token,{email:EMAIL,password:PASSWORD});
  assert.equal(made.created,true,JSON.stringify(made));assert.equal(made.verify,'link','the site sent a confirmation link');
  const account=site.accounts.get(EMAIL);
  assert.equal(account?.password,PASSWORD,'the site got Buddy’s password');assert.equal(account.marketing,false,'the newsletter box stayed unticked');
  assert.deepEqual(site.posts.map(p=>p.fields.terms),['on']);
  await assert.rejects(s.signup(again.token,{email:EMAIL,password:PASSWORD}),/again|used|changed/,'a plan is used once');
  // The confirmation link from the person's mailbox opens in the same page.
  const mail=site.mailbox.find(m=>m.to===EMAIL&&/confirm/i.test(m.subject));
  await assert.rejects(s.openLink('https://evil.example/confirm?token=x'),/another website/,'a link to another site is never opened');
  const opened=await s.openLink(mail.link);
  assert.equal(opened.opened,true);assert.equal(opened.private,false);assert.equal(site.accounts.get(EMAIL).verified,true);
  assert.match(opened.page.text,/Email confirmed/);
  // Next time: the sign-in form asks for both the email and the password (nothing is filled in yet).
  await s.navigate(site.origin+'/login');
  const login=await s.secretPlan();
  assert.equal(login.field,'login','an empty email field and a password field are asked for together');assert.equal(login.account,EMAIL,'with the task’s account to fill in');
  await assert.rejects(s.fillSecret(login.token,PASSWORD,{username:'someone.else@example.com'}),/matteo\.craviotto@gmail\.com/);
  const fresh=await s.secretPlan();
  const signed=await s.fillSecret(fresh.token,PASSWORD,{username:EMAIL});
  assert.equal(signed.signedIn,true,JSON.stringify(signed));assert.match(signed.page.text,/Your applications/);
  // The same email again: the site says the account exists, and nothing changes.
  await s.navigate(site.origin+'/join');
  const twice=await s.signup((await s.signupPlan({email:EMAIL})).token,{email:EMAIL,password:NEW_PASSWORD});
  assert.equal(twice.created,false);assert.equal(twice.exists,true,JSON.stringify(twice));
  assert.equal(site.accounts.get(EMAIL).password,PASSWORD);
  never([read,plan,again,made,opened,login,fresh,signed,twice,await s.read()],PASSWORD);
  never([twice],NEW_PASSWORD);
 }finally{await browser.close();await rm(root,{recursive:true,force:true});await site.close();}
});

test('a sign-up that starts a paid trial, asks for a card in a payment frame, or shows a CAPTCHA is stopped before anything is sent; a missing detail is named, not invented',{timeout:120000},async()=>{
 const site=await careers(),{root,browser}=await fixture('buddy-accounts-money-',site);
 try{
  const s=browser.session('task-money','',EMAIL);
  await s.navigate(site.origin+'/trial');
  const trial=await s.signupPlan({email:EMAIL});
  assert.equal(trial.money?.kind,'trial',JSON.stringify(trial));
  const refused=await s.signup(trial.token,{email:EMAIL,password:PASSWORD});
  assert.equal(refused.created,false);assert.equal(refused.money?.kind,'trial');
  await s.navigate(site.origin+'/pay');
  const pay=await s.signupPlan({email:EMAIL});
  assert.equal(pay.money?.kind,'payment',JSON.stringify(pay));
  assert.equal((await s.signup(pay.token,{email:EMAIL,password:PASSWORD})).created,false);
  await s.navigate(site.origin+'/captcha');
  const captcha=await s.signupPlan({email:EMAIL});
  assert.equal(captcha.captcha,true);
  const held=await s.signup(captcha.token,{email:EMAIL,password:PASSWORD});
  assert.equal(held.created,false);assert.equal(held.captcha,true);
  await s.navigate(site.origin+'/join-name');
  const named=await s.signupPlan({email:EMAIL});
  assert.equal(named.ready,false);assert.deepEqual(named.missing,['First name']);
  const given=await s.signupPlan({email:EMAIL,details:{'first name':'Matteo'}});
  assert.equal(given.ready,true);assert.deepEqual(given.fills,['First name']);
  assert.deepEqual(site.posts,[],'nothing was sent to any of them');
  assert.equal(site.accounts.size,0);
  // An agent's own step never types a card or starts a trial.
  await s.navigate(site.origin+'/upgrade');
  const page=await s.read();
  const card=page.controls.find(c=>/Card number/.test(c.name)),start=page.controls.find(c=>/Start free trial/.test(c.name));
  await assert.rejects(s.prepare({snapshotId:page.snapshotId,action:'fill',fields:[{ref:card.ref,value:'4242424242424242'}]}),/payment/i);
  await assert.rejects(s.prepare({snapshotId:page.snapshotId,action:'click',ref:start.ref}),/payment|trial/i);
  assert.deepEqual(site.posts,[]);
 }finally{await browser.close();await rm(root,{recursive:true,force:true});await site.close();}
});

test('a code the site texts is asked for, and a forgotten password is reset through the email with a new password Buddy makes',{timeout:120000},async()=>{
 const site=await careers(),{root,browser}=await fixture('buddy-accounts-reset-',site);
 try{
  const s=browser.session('task-sms','',EMAIL);
  await s.navigate(site.origin+'/sms');
  const made=await s.signup((await s.signupPlan({email:EMAIL})).token,{email:EMAIL,password:PASSWORD});
  assert.equal(made.created,true);assert.equal(made.verify,'code');assert.equal(made.channel,'sms','the site texted the code');
  assert.equal(made.next?.field,'code');
  const done=await s.fillSecret(made.next.token,'480213');
  assert.equal(done.signedIn,true);
  // The remembered password no longer works (the person changed it elsewhere): the site offers to reset it.
  site.accounts.get(EMAIL).password='changed-elsewhere';
  await s.navigate(site.origin+'/login');
  const tried=await s.fillSecret((await s.secretPlan()).token,PASSWORD,{username:EMAIL});
  assert.equal(tried.signedIn,false);
  const reset=await s.resetPlan();
  assert.equal(reset.available,true);assert.equal(reset.origin,site.origin);
  const requested=await s.resetStart(reset.token,{email:EMAIL});
  assert.equal(requested.requested,true,JSON.stringify(requested));
  const mail=site.mailbox.filter(m=>m.to===EMAIL&&/reset/i.test(m.subject)).at(-1);
  const opened=await s.openLink(mail.link);
  assert.equal(opened.private,true,'the new-password page is private');
  const changed=await s.resetFinish({password:NEW_PASSWORD});
  assert.equal(changed.changed,true,JSON.stringify(changed));
  assert.equal(site.accounts.get(EMAIL).password,NEW_PASSWORD);
  await s.navigate(reset.signInURL);
  const signed=await s.fillSecret((await s.secretPlan()).token,NEW_PASSWORD,{username:EMAIL});
  assert.equal(signed.signedIn,true);
  never([made,done,tried,reset,requested,opened,changed,signed,await s.read()],NEW_PASSWORD);
  never([made,done,tried,signed],PASSWORD);
 }finally{await browser.close();await rm(root,{recursive:true,force:true});await site.close();}
});

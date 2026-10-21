import {chromium} from 'playwright-core';
import {lookup} from 'node:dns/promises';
import {isIP} from 'node:net';
import {startGuardProxy,publicAddress} from './network-guard.mjs';
import {randomUUID, createHash} from 'node:crypto';
import {mkdir, chmod, lstat, readlink, unlink} from 'node:fs/promises';
import {hostname} from 'node:os';
import {resolve} from 'node:path';
import {createInterface} from 'node:readline';
import {pathToFileURL} from 'node:url';
import {realpathSync} from 'node:fs';
import {spawn,execFile} from 'node:child_process';
import {promisify} from 'node:util';

export {publicAddress};
const origins=value=>value instanceof Set?value:new Set([].concat(value||[]).filter(Boolean));
export async function publicURL(raw, resolver=lookup, testOrigin='') {
  const url=new URL(raw);
  if(!['https:','http:'].includes(url.protocol)||url.username||url.password) throw Error('Only public HTTP and HTTPS pages are supported.');
  if(origins(testOrigin).has(url.origin))return url.href;
  const host=url.hostname.replace(/^\[|\]$/g,'');
  if(host==='localhost'||host.endsWith('.localhost')||host.endsWith('.local')||host.endsWith('.internal'))throw Error('Local and private network pages are unavailable in Buddy’s browser.');
  const addresses=isIP(host)?[{address:host}]:await resolver(host,{all:true});
  if(!addresses.length||addresses.some(x=>!publicAddress(x.address)))throw Error('Local and private network pages are unavailable in Buddy’s browser.');
  return url.href;
}
// A delegated site may refresh its existing Clerk cookie, but the model never
// gets access to Clerk pages, tokens or a different redirect destination.
export function sessionRefreshDestination(shared,raw){
  try{
    const site=new URL(shared),url=new URL(raw),back=new URL(url.searchParams.get('redirect_url'));
    return site.protocol==='https:'&&url.protocol==='https:'&&!url.username&&!url.password&&url.hostname==='clerk.'+site.hostname&&url.port===site.port&&url.pathname==='/v1/client/handshake'&&back.origin===site.origin&&!back.username&&!back.password;
  }catch{return false;}
}
const hash=x=>createHash('sha256').update(JSON.stringify(x)).digest('hex');
const runFile=promisify(execFile);
const pause=ms=>new Promise(r=>setTimeout(r,ms));
// After a submit: wait for the page it leads to (if any) to load, without waiting long for a page that stays put.
async function afterSubmit(page,act){
  const navigated=new Promise(resolve=>{const on=f=>{if(f===page.mainFrame()){page.off('framenavigated',on);resolve(true);}};page.on('framenavigated',on);setTimeout(()=>{page.off('framenavigated',on);resolve(false);},2500);});
  await act();
  if(await navigated)await page.waitForLoadState('domcontentloaded',{timeout:6000}).catch(()=>{});
  await pause(250);
}
// A cut inside an emoji leaves half a surrogate pair, which the Mac app's JSON parser rejects (the whole line is dropped and the
// request waits for its timeout). Replace any lone surrogate before a frame is written.
const frame=value=>JSON.stringify(value,(key,item)=>typeof item==='string'?item.toWellFormed():item)+'\n';
// Identity providers refuse a browser that an agent connection drives, and their pages hold the person's whole account: the person signs
// in to them in Buddy's Chrome window.
const identityProvider=host=>/(^|\.)(google|microsoft|microsoftonline|live|apple|icloud)\.com$/i.test(host);
const OPEN_FOR_YOU='Private sign-in is open: Buddy’s private Chrome is open for you. Agents wait until you choose Done.';

// The account a task must use (the Mac app pins it from the person's own words; a model never sets it). With several Google accounts signed
// in to the one Chrome, Google opens a page as the default account (/u/0) unless the address says otherwise, so a pinned task's Google pages
// always name the account (authuser takes an email), the account chooser picks it, and nothing is done on a Google page that shows another.
const ACCOUNT=/^[A-Za-z0-9._%+-]{1,64}@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}$/;
export function pinnedAccount(value){
  if(value===undefined||value===null||value==='')return '';
  if(typeof value!=='string'||value.length>254||!ACCOUNT.test(value.trim()))throw Error('Choose the email address of the account this task uses.');
  return value.trim().toLowerCase();
}
const isEmail=value=>typeof value==='string'&&ACCOUNT.test(value.trim());
const googleProperty=host=>/(^|\.)(google\.com|youtube\.com)$/i.test(host);
const NUMBERED=/\/u\/\d+(?=\/|$)/;
const missingAccount=account=>`${account} isn’t signed in to Buddy’s Chrome. Sign in to ${account} in Buddy’s Chrome, then press Done.`;
const otherAccount=(seen,account)=>`This page is signed in as ${seen}, but this task must use ${account}. Buddy stopped instead of continuing as ${seen}.`;

/** One private Chrome profile for every agent (contract: "set it up once for everyone"). One profile is one Chrome process, so every agent
 *  shares the one Chrome: each task drives its own page, a `BrowserSession`, and only its own. The accounts (cookies, Chrome's Password
 *  Manager) are the profile's and so everyone's; pages, observed controls, approvals and sign-in requests are the session's alone. One
 *  network guard checks every request any page makes. A session that closes, crashes or stops responding takes only its own page with it. */
export class SharedBrowser {
  constructor(profile,{testOrigin='',testOrigins=[],testGooglePath='',testGoogle=[],commandDeadlineMs=40000,resolver=lookup,guardOptions={},manualExecutable='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',secretTTLms=600000}={}) {
    this.profile=resolve(profile);this.testOrigins=new Set([testOrigin,...testOrigins].filter(Boolean));this.testGooglePath=this.testOrigins.size?testGooglePath:'';
    // Test origins that stand in for Google's own sites (only ever one of the test origins).
    this.testGoogle=new Set([].concat(testGoogle).filter(o=>this.testOrigins.has(o)));
    this.commandDeadlineMs=commandDeadlineMs;this.resolver=resolver;this.guardOptions=guardOptions;this.manualExecutable=manualExecutable;this.secretTTLms=secretTTLms;
    this.context=null;this.launching=null;this.closing=null;this.spare=[];this.creating=0;this.sessions=new Map();this.manualProcess=null;this.handingOff=false;this.lastURL=null;
    this.secrets=new Set();this.secretOrigins=new Map();this.blockedAt=0;
  }
  isTestOrigin(origin){return this.testOrigins.has(origin);}
  /** One of Google's own sites (google.com and its subdomains, youtube.com), where several of the person's Google accounts can be signed in. */
  isGoogle(url){try{const u=url instanceof URL?url:new URL(url);return u.protocol==='https:'&&googleProperty(u.hostname)||this.testGoogle.has(u.origin);}catch{return false;}}
  /** Google's own sign-in and account-choice pages. */
  identityPage(url){try{const u=url instanceof URL?url:new URL(url);return u.protocol==='https:'&&u.hostname==='accounts.google.com'||!!this.testGooglePath&&this.isTestOrigin(u.origin)&&u.pathname.startsWith(this.testGooglePath);}catch{return false;}}
  /** The session of one task. `scope` (a delegated website's origin) and `account` (the email it must use) are fixed when it is first opened. */
  session(id,scope,account){
    if(typeof id!=='string'||!/^[A-Za-z0-9._:-]{1,120}$/.test(id))throw Error('Choose a browser session.');
    const pin=pinnedAccount(account);
    let s=this.sessions.get(id);
    if(!s){s=new BrowserSession(this,id,scope||'',pin);this.sessions.set(id,s);}
    else if(scope!==undefined&&scope!==null&&(scope||'')!==s.scope)throw Error('This browser session keeps the website scope it was opened with.');
    else if(account!==undefined&&account!==null&&pin!==s.account)throw Error('This browser session keeps the account it was opened with.');
    return s;
  }
  sessionFor(page){if(!page)return null;for(const s of this.sessions.values())if(s.page===page||s.owned.has(page))return s;return null;}
  // Everything a page can reach out with is checked against every secret the person typed or Chrome filled: none may leave for another site.
  remember(secret,origin){if(typeof secret!=='string'||!secret)return;this.secrets.add(secret);this.secretOrigins.set(secret,origin);}
  static forms(secret){return [...new Set([secret,encodeURIComponent(secret),new URLSearchParams({s:secret}).toString().slice(2)])];}
  scrub(value){if(typeof value==='string'){for(const secret of this.secrets)if(secret.length>=4)for(const form of SharedBrowser.forms(secret))value=value.split(form).join('[private]');return value;}if(Array.isArray(value))return value.map(x=>this.scrub(x));if(value&&typeof value==='object')return Object.fromEntries(Object.entries(value).map(([k,v])=>[k,this.scrub(v)]));return value;}
  async profileLock(){
    const path=resolve(this.profile,'SingletonLock');let meta;
    try{meta=await lstat(path);}catch(error){if(error.code==='ENOENT')return null;throw error;}
    if(!meta.isSymbolicLink()||meta.uid!==process.getuid())throw Error('Chrome’s profile lock needs manual inspection. Saved browser data was kept.');
    const target=await readlink(path),split=target.lastIndexOf('-'),host=target.slice(0,split),pid=Number(target.slice(split+1));
    if(host!==hostname()||!Number.isSafeInteger(pid)||pid<=0)throw Error('Chrome’s profile is locked by another session. Close Buddy’s private Chrome window first.');
    try{process.kill(pid,0);return pid;}catch(error){if(error.code!=='ESRCH')return pid;}
    // Only this account's same-host, dead-process lock is disposable. Never
    // reset a profile, touch a live lock, or read its cookies/password database.
    if(await readlink(path)!==target)throw Error('Chrome’s profile lock changed. Try again.');
    await unlink(path);return null;
  }
  async closeManualProfile(){
    let pid=await this.profileLock();if(!pid)return;
    const {stdout}=await runFile('/bin/ps',['-p',String(pid),'-ww','-o','command='],{timeout:2000,maxBuffer:65536}).catch(()=>({stdout:''}));
    const command=stdout.trim(),marker=`--user-data-dir=${this.profile}`;
    // Chrome can re-exec during Google sign-in. Only close the real Chrome
    // executable whose command explicitly names this private profile.
    if(!command.startsWith(this.manualExecutable+' ')||!command.includes(marker+' ')&&!command.endsWith(marker))throw Error('Close Buddy’s private Chrome window before finishing sign-in.');
    // The agents' own Chrome (driven through a debugging pipe) is never the person's window; it closes itself.
    if(/--remote-debugging|--enable-automation/.test(command))return;
    process.kill(pid,'SIGTERM');
    for(let i=0;i<40;i++){if(!await this.profileLock())return;await pause(100);}
    throw Error('Private Chrome is still closing. Try Finish private sign-in again.');
  }
  // Whether the Chrome holding the profile lock is one an agent connection drives (it has a debugging pipe).
  async automated(pid){const {stdout}=await runFile('/bin/ps',['-p',String(pid),'-ww','-o','command='],{timeout:2000,maxBuffer:65536}).catch(()=>({stdout:''}));return /--remote-debugging|--enable-automation/.test(stdout);}
  manualOpen(){const p=this.manualProcess;return this.handingOff||!!p&&p.exitCode===null&&p.signalCode===null;}
  async ensureContext(){
    if(this.closing)await this.closing;
    if(this.manualOpen())throw Error(OPEN_FOR_YOU);
    if(this.context)return this.context;
    if(!this.launching)this.launching=this.launch().finally(()=>{this.launching=null;});
    return await this.launching;
  }
  async launch() {
    if(this.manualOpen())throw Error(OPEN_FOR_YOU);
    await mkdir(this.profile,{recursive:true,mode:0o700});await chmod(this.profile,0o700);
    // A Chrome window still open on the profile (the person's, from before a restart) is never joined by an agent connection.
    if(await this.profileLock())throw Error('Buddy’s private Chrome window is still open. Close it, or choose Done, before agents use the browser.');
    // Every request Chrome makes goes through a proxy that checks the real destination as it connects (see network-guard.mjs). The bypass
    // list switches off Chrome's built-in exemption for localhost and loopback, which would otherwise skip the proxy entirely.
    if(!this.netGuard)this.netGuard=await startGuardProxy({resolver:this.resolver,allow:[...this.testOrigins].map(o=>{const u=new URL(o);return u.hostname.replace(/^\[|\]$/g,'')+':'+(u.port||(u.protocol==='https:'?'443':'80'));}),onBlocked:()=>{this.blockedAt=Date.now();},...this.guardOptions});
    // Use Chrome's real encrypted profile, never Playwright's mock Keychain/basic password store.
    const context=await chromium.launchPersistentContext(this.profile,{channel:'chrome',headless:true,chromiumSandbox:true,acceptDownloads:false,permissions:[],serviceWorkers:'block',proxy:{server:this.netGuard.server,username:this.netGuard.username,password:this.netGuard.password,bypass:'<-loopback>'},ignoreDefaultArgs:['--password-store=basic','--use-mock-keychain','--disable-sync'],args:['--disable-extensions','--disable-background-networking','--force-webrtc-ip-handling-policy=disable_non_proxied_udp']});
    this.spare=[...context.pages()];
    await context.route('**/*',route=>this.route(route));
    // If Chrome exits or crashes, forget the dead context so the next command starts a new one instead of failing forever.
    context.on('close',()=>{if(this.context!==context)return;this.context=null;this.spare=[];for(const s of this.sessions.values()){s.reset();s.owned.clear();}});
    context.on('page',p=>this.adopt(p));
    this.context=context;return context;
  }
  /** A page for `session`: the blank page Chrome opened with, or a new one. */
  async newPage(session){
    const context=await this.ensureContext();
    let page=this.spare.pop();while(page&&page.isClosed())page=this.spare.pop();
    if(!page){this.creating++;try{page=await context.newPage();}finally{this.creating--;}}
    session.owned.add(page);this.sweep();return page;
  }
  // A window nobody owns (one a page opened while a new agent page was being made) is closed.
  sweep(){if(this.creating||!this.context)return;for(const p of this.context.pages())if(!this.sessionFor(p)&&!this.spare.includes(p))p.close().catch(()=>{});}
  // A new window belongs to the agent whose Google sign-in opened it; any other is closed (a page an agent made opens nothing else).
  adopt(p){
    const flows=[...this.sessions.values()].filter(s=>s.googleFlow&&!s.googleFlow.popup);
    if(!this.creating&&flows.length===1){flows[0].googleFlow.popup=p;flows[0].owned.add(p);return;}
    p.opener().then(opener=>{
      // A page with no opener while an agent page is being made is that page (it is registered as soon as it is made).
      if(this.sessionFor(p)||!opener&&this.creating)return;
      const owner=opener&&this.sessionFor(opener);
      if(owner?.googleFlow&&!owner.googleFlow.popup){owner.googleFlow.popup=p;owner.owned.add(p);return;}
      p.close().catch(()=>{});
    }).catch(()=>p.close().catch(()=>{}));
  }
  async route(route){
    const request=route.request();
    let navigation=request.isNavigationRequest(),page=null;
    try{const frame=request.frame();page=frame.page();if(navigation)navigation=!frame.parentFrame();}catch{/* A popup's first request precedes its frame. Treat it as top-level. */}
    const flows=[...this.sessions.values()].filter(s=>s.googleFlow&&!s.googleFlow.popup);
    const s=this.sessionFor(page)||(flows.length===1?flows[0]:null);
    try{
      const url=new URL(await publicURL(request.url(),this.resolver,this.testOrigins)),payload=request.url()+' '+(request.postData()||'');
      for(const [secret,origin] of this.secretOrigins)if(url.origin!==origin&&SharedBrowser.forms(secret).some(form=>payload.includes(form)))throw Error('Private sign-in data cannot be sent to another origin.');
      if(!s){
        // A page no agent owns (a window about to be closed) may not wander off while a delegated website session is open.
        if(navigation&&[...this.sessions.values()].some(x=>x.scope))throw Error('This window belongs to no agent.');
        await route.continue();return;
      }
      const shared=s.scope;
      if(shared&&navigation&&!s.googleFlow&&url.origin!==shared&&!(s.sessionRefresh&&sessionRefreshDestination(shared,url.href)))throw Error('Outside shared website session.');
      // A pinned task's page heading to a Google page that does not name an account (a link it follows, a redirect) is sent to the same
      // address with the account named, so Google never opens it as the default account instead.
      if(navigation&&s.account&&request.method()==='GET'){const pinned=s.pinURL(url.href);if(pinned){await route.fulfill({status:302,headers:{location:pinned,'cache-control':'no-store'}});return;}}
      if(shared&&navigation&&!s.googleFlow){
        const response=await route.fetch({maxRedirects:0}),location=response.headers().location;
        if(location&&response.status()>=300&&response.status()<400){
          const destination=new URL(location,request.url());
          if(destination.origin!==shared){
            if(url.origin!==shared||!sessionRefreshDestination(shared,destination.href)||s.sessionRefreshes>=2)throw Error('Website redirected outside the delegated session to '+destination.origin);
            s.sessionRefresh=true;s.sessionRefreshes++;
          }else if(url.origin!==shared)s.sessionRefresh=false;
        }
        await route.fulfill({response});
      }else await route.continue();
    }catch(error){
      if(navigation&&s)s.blockedNavigation=String(error.message||error).split('\n')[0].replace(/https?:\/\/[^\s)]+/g,raw=>{try{return new URL(raw).origin;}catch{return '[website]';}}).slice(0,800);
      await route.abort('blockedbyclient').catch(()=>{});
    }
  }
  /** The exact page of a step the person does in their Chrome window: a public https page (or a test origin), and on Google's own sites
   *  with the task's account named in the address (authuser), so Google doesn't open it as the default account. Google's sign-in and
   *  account-choice pages are left as they are. */
  async stepPage(raw,account){
    const pin=pinnedAccount(account);
    let u;try{u=new URL(raw);}catch{throw Error('Buddy opens only public https pages for a step. Nothing was opened.');}
    if(u.protocol!=='https:'&&!this.isTestOrigin(u.origin))throw Error('Buddy opens only public https pages for a step. Nothing was opened.');
    u=new URL(await publicURL(u.href,this.resolver,this.testOrigins));
    if(pin&&this.isGoogle(u)&&!this.identityPage(u)){u.pathname=u.pathname.replace(NUMBERED,'')||'/';u.searchParams.set('authuser',pin);}
    return u.href;
  }
  /** The person's own Chrome window on the shared profile, for setting up accounts or finishing a step an agent cannot do. It has no agent
   *  connection, so the agents' Chrome closes first: never while another agent has a page open. `session` is the agent asking (it is
   *  pausing for this), `url` where to open (otherwise its page). `page` is a step's own exact page (with `account`, the one to use on it):
   *  the window opens at that page and nothing else; a step with no page at all opens nothing, never a blank window. Asked again while the
   *  window is open, the page is shown again in it, in a new window in front. */
  async manual(destination,{session:requester,url:target,page:step,account}={}){
    const existing=this.manualOpen();
    const exact=step?await this.stepPage(step,account):null;
    if(existing&&destination!=='google'){if(exact)await this.forward(exact);return {opened:true,private:true};}
    if(!existing&&[...this.sessions.values()].some(s=>s.id!==requester&&s.page&&!s.page.isClosed()))throw Error('Another agent is using Buddy’s browser right now. Try again when it has finished, or pause that task.');
    const owner=requester?this.sessions.get(requester):null;
    // An agent's step opens at its page (or, once that has closed, where it was told to); setup opens where the person last was.
    const own=owner?.page&&!owner.page.isClosed()?owner.page.url():owner?.lastURL;
    let url=destination==='google'?'chrome://settings/people':exact||(requester?own||target:target||this.lastURL)||'about:blank';
    if(requester&&url==='about:blank')throw Error('Buddy doesn’t know which page this step is on, so nothing was opened.');
    if(!['about:blank','chrome://settings/people'].includes(url))url=await publicURL(url,this.resolver,this.testOrigins);
    // From here until the window is open no agent page may start: an agent connection must never join the person's window.
    const handing=!existing;if(handing)this.handingOff=true;
    try{
      if(!existing)this.lastURL=url;await this.closeAutomation();await mkdir(this.profile,{recursive:true,mode:0o700});await chmod(this.profile,0o700);
      // The person's window must never open inside a Chrome an agent connection still drives (it would join that Chrome).
      const holder=await this.profileLock();if(holder&&await this.automated(holder))throw Error('Buddy’s browser is still closing. Try again in a moment.');
      // No debugging connection, automation flags, page scripts, screenshots, or password reads during the handoff. The page opens as the
      // only page Buddy asks for, in a new window; if Chrome restores the person's earlier tabs as it starts, it adds this page to the
      // window it restores last and brings that window to the front with this page showing. Its "Restore pages?" bubble is not shown.
      const child=spawn(this.manualExecutable,[`--user-data-dir=${this.profile}`,'--no-first-run','--no-default-browser-check','--disable-background-mode','--hide-crash-restore-bubble','--new-window',url],{stdio:'ignore'});
      await new Promise((resolve,reject)=>{child.once('spawn',resolve);child.once('error',()=>reject(Error('Could not open private Chrome. Install Google Chrome and try again.')));});
      await new Promise(resolve=>{const timer=setTimeout(resolve,350);child.once('exit',()=>{clearTimeout(timer);resolve();});});
      if((child.exitCode!==null||child.signalCode!==null)&&!await this.profileLock())throw Error('Chrome did not open. Your saved browser data was kept; try opening Chrome again.');
      if(!existing)this.manualProcess=child;
    }finally{if(handing)this.handingOff=false;}
    return {opened:true,private:true};
  }
  /** Shows `url` in the person's Chrome window that is already open: Chrome started again on the same profile hands the page to the running
   *  one, which opens it in a new window in front, and exits. */
  async forward(url){
    const child=spawn(this.manualExecutable,[`--user-data-dir=${this.profile}`,'--no-first-run','--no-default-browser-check','--disable-background-mode','--new-window',url],{stdio:'ignore'});
    await new Promise((resolve,reject)=>{child.once('spawn',resolve);child.once('error',()=>reject(Error('Could not open the page in Chrome. Try again.')));});
    await new Promise(resolve=>{const timer=setTimeout(resolve,5000);timer.unref();child.once('exit',()=>{clearTimeout(timer);resolve();});});
    child.unref();
  }
  async finishManual(){const p=this.manualProcess;if(p&&p.exitCode===null&&p.signalCode===null){p.kill('SIGTERM');await Promise.race([new Promise(resolve=>p.once('exit',resolve)),new Promise((_,reject)=>{const t=setTimeout(()=>reject(Error('Close Buddy’s private Chrome window before finishing sign-in.')),8000);t.unref();})]);}this.manualProcess=null;await this.closeManualProfile();return {closed:true,url:this.lastURL?.startsWith('https:')?new URL(this.lastURL).origin:null};}
  /** Ends one task's use of the browser: its pages close, nobody else's. Chrome itself closes with the last session. */
  async closeSession(id){
    const s=this.sessions.get(id);
    if(s){this.sessions.delete(id);const pages=[s.page,s.googleFlow?.popup,...s.owned].filter(Boolean);s.reset();s.owned.clear();await Promise.race([Promise.all(pages.map(p=>p.close({runBeforeUnload:false}).catch(()=>{}))),pause(5000)]);}
    if(!this.sessions.size&&this.context)await this.closeAutomation();
    return {closed:true,remaining:this.sessions.size};
  }
  async closeAutomation(){
    for(const s of this.sessions.values()){s.reset();s.owned.clear();}this.spare=[];
    if(this.launching)await this.launching.catch(()=>{});
    const c=this.context;this.context=null;
    if(c){const done=Promise.race([c.close().catch(()=>{}),pause(5000)]);this.closing=done;try{await done;}finally{if(this.closing===done)this.closing=null;}}
  }
  async close(){await this.closeAutomation();await this.finishManual();const guard=this.netGuard;this.netGuard=null;await guard?.close();}
}

/** One task's page in the shared Chrome: what it observed, what it may act on, and its sign-in requests. */
class BrowserSession {
  constructor(browser,id,scope,account=''){this.browser=browser;this.id=id;this.scope=scope;this.account=account;this.pinned=new Map();this.page=null;this.owned=new Set();this.refs=[];this.snapshot=null;this.prepared=null;this.authPlan=null;this.secretPlanState=null;this.googleFlow=null;this.lastURL=null;this.intendedURL=null;this.blockedNavigation=null;this.sessionRefresh=false;this.sessionRefreshes=0;}
  get sharedOrigin(){return this.scope;}
  /** The address a pinned task opens instead of `raw`: the same Google page with its account named (authuser), or null when it needs no
   *  change. `explicit` (an address the agent asked for) also replaces an account given by number (/u/1/), which may be any account; a page
   *  reached by a link or a redirect keeps it, and is checked before anything is done on it. A page Google keeps sending back without the
   *  account is left to that check too, so the two never go round in circles. */
  pinURL(raw,explicit=false){
    if(!this.account)return null;
    let u;try{u=new URL(raw);}catch{return null;}
    if(!this.browser.isGoogle(u)||this.browser.identityPage(u))return null;
    if(NUMBERED.test(u.pathname)){if(!explicit)return null;u.pathname=u.pathname.replace(NUMBERED,'')||'/';}
    else if((u.searchParams.get('authuser')||'').trim().toLowerCase()===this.account)return null;
    u.searchParams.set('authuser',this.account);
    if(!explicit){
      const key=u.href,now=Date.now(),last=this.pinned.get(key);
      for(const [k,v] of this.pinned)if(now-v.at>10000)this.pinned.delete(k);
      if(last&&now-last.at<10000&&last.count>=2)return null;
      this.pinned.set(key,{at:now,count:(last&&now-last.at<10000?last.count:0)+1});
    }
    return u.href;
  }
  /** Which account a Google page is signed in as: the email in the accessible label of Google's account button ("Google Account: Name
   *  (email)", on every Google app's bar), and on Gmail the address in the window title too. Empty when the page shows none, more than one
   *  when it shows several. */
  async pageAccount(page=this.page){
    return await page.evaluate(()=>{
      const found=new Set(),take=v=>{for(const m of String(v||'').matchAll(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/gi))found.add(m[0].toLowerCase());};
      for(const e of document.querySelectorAll('[aria-label]')){const label=e.getAttribute('aria-label')||'';if(/^\s*Google Account\b/i.test(label))take(label);}
      if(location.hostname==='mail.google.com'){const parts=document.title.split(' - ');if(parts.length>=3)take(parts[parts.length-2]);}
      return [...found];
    }).catch(()=>[]);
  }
  /** A pinned task acts on a Google page only when the page shows that it is signed in as the task's account. `strict`: an account Buddy
   *  cannot see is refused too (before an action); reading refuses only a page that shows another account. */
  async assertAccount({strict=true,tail=''}={}){
    if(!this.account||!this.page)return;
    const url=this.page.url();if(!this.browser.isGoogle(url)||this.browser.identityPage(url))return;
    const seen=await this.pageAccount();
    if(seen.length===1&&seen[0]===this.account)return;
    if(seen.length===1)throw Error(otherAccount(seen[0],this.account)+tail);
    if(strict)throw Error(`Buddy couldn’t tell which Google account this page is signed in as, and this task must use ${this.account}. Buddy stopped instead of acting on it.`+tail);
  }
  /** On Google's account chooser, the pinned account's own tile is chosen. 'missing' when the chooser does not offer it (it is not signed
   *  in to this Chrome); null on any other page, and on a password, code, CAPTCHA or permission step, which stays the person's. */
  async chooseAccount(page=this.page){
    if(!this.account||!page||!this.browser.identityPage(page.url()))return null;
    const url=new URL(page.url());
    if(/\/consent(?:\/|$)|\/approval(?:\/|$)|\/challenge(?:\/|$)|\/signin\/v\d+/i.test(url.pathname))return null;
    if(await page.locator('input[type=password],input[autocomplete="one-time-code"],iframe[src*="recaptcha"]').count())return null;
    const tiles=[];for(const tile of await page.locator('[data-identifier]').all())if(await tile.isVisible().catch(()=>false))tiles.push(tile);
    if(!tiles.length)return null;
    for(const tile of tiles){
      const id=String(await tile.getAttribute('data-identifier').catch(()=>'')||'').trim().toLowerCase();
      if(id===this.account){this.snapshot=null;await afterSubmit(page,()=>tile.click({timeout:12000}));return 'chosen';}
    }
    return 'missing';
  }
  /** The username a site's sign-in form holds (what Chrome filled, or what the site asks to sign in as); never a password. */
  async username(){
    const field=this.page.locator('input[type=email],input[autocomplete=username],input[autocomplete=email]').first();
    return await field.count()?await field.inputValue().catch(()=>null):null;
  }
  /** Why a sign-in on another site would be as the wrong account: its username is an email that is not the pinned one. */
  otherSignIn(user){return this.account&&isEmail(user||'')&&user.trim().toLowerCase()!==this.account?user.trim():'';}
  reset(){this.page=null;this.refs=[];this.snapshot=null;this.prepared=null;this.authPlan=null;this.secretPlanState=null;}
  async ready() {
    await this.browser.ensureContext();
    if(this.page&&!this.page.isClosed())return;
    this.reset();
    const page=await this.browser.newPage(this);this.page=page;page.setDefaultTimeout(12000);
    page.on('dialog',dialog=>dialog.dismiss().catch(()=>{}));
    // A crashed page is replaced at this agent's next step; nobody else's page is touched.
    page.on('crash',()=>{this.owned.delete(page);if(this.page===page)this.reset();page.close().catch(()=>{});});
    page.on('close',()=>{this.owned.delete(page);if(this.page===page)this.reset();});
  }
  async privacy(){
    const info=await this.page.evaluate(()=>{
      const inputs=[...document.querySelectorAll('input')];
      const sensitive=e=>/password|passphrase|one.?time|verification.?code|security.?code|recovery.?code|auth.?code|\botp\b/i.test([e.type,e.name,e.id,e.autocomplete,e.getAttribute('aria-label'),e.labels?.[0]?.textContent].join(' '));
      const passwords=inputs.filter(e=>e.type==='password'||/password|passphrase/i.test([e.name,e.id,e.autocomplete,e.getAttribute('aria-label')].join(' ')));
      const otp=inputs.filter(e=>e.autocomplete==='one-time-code'||/verification.?code|one.?time|\botp\b/i.test([e.name,e.id,e.getAttribute('aria-label'),e.labels?.[0]?.textContent].join(' ')));
      const identity=/^(accounts|passwords)\.google\.com$/.test(location.hostname)||/(?:^|\/)(?:login|signin|sign-in|sign-up|signup|register|oauth|authorize)(?:\/|$)/i.test(location.pathname);
      const recovery=/reset|recover|change.?password|security.?settings/i.test(location.pathname+' '+document.title+' '+document.body?.innerText.slice(0,1500));
      return {private:identity||inputs.some(sensitive),kind:recovery?'security':otp.length?'verification':passwords.some(e=>e.autocomplete==='new-password')?'signup':'signin',secrets:passwords.map(e=>e.value).filter(Boolean)};
    });
    for(const secret of info.secrets)this.browser.remember(secret,new URL(this.page.url()).origin);delete info.secrets;return info;
  }
  safeURL(){try{const u=new URL(this.page?.url()||this.lastURL);for(const key of [...u.searchParams.keys()])if(/code|token|password|secret|credential|assertion|ticket/i.test(key))u.searchParams.set(key,'[private]');u.hash='';return this.browser.scrub(u.href);}catch{return 'about:blank';}}
  async signature(){
    return hash(await this.page.evaluate(()=>({url:location.href,title:document.title,text:document.body?.innerText.slice(0,50000),forms:[...document.forms].map(f=>[f.action,f.method,f.target]),fields:[...document.querySelectorAll('input,textarea,select,button,a[href],[role=button]')].slice(0,300).map(e=>[e.tagName,e.getAttribute('type'),e.getAttribute('href'),e.getAttribute('name'),e.getAttribute('aria-label'),e.textContent?.slice(0,120),e.type==='password'?'[hidden]':e.value,e.checked])})));
  }
  // What a typed sign-in depends on: the page and the shape of its forms, not its other text (a clock, an ad). A new field, a different
  // form target or another page is a different request.
  async formSignature(){
    return hash(await this.page.evaluate(()=>({url:location.origin+location.pathname,title:document.title,forms:[...document.forms].map(f=>[f.getAttribute('action'),f.method,f.target]),fields:[...document.querySelectorAll('input,select,textarea,button,[role=button]')].filter(e=>e.type!=='hidden').slice(0,200).map(e=>[e.tagName,e.getAttribute('type'),e.getAttribute('name'),e.getAttribute('autocomplete'),e.getAttribute('aria-label'),(e.labels?.[0]?.textContent||'').trim().slice(0,80),e.tagName==='BUTTON'?e.textContent.trim().slice(0,80):'',e.form?[...document.forms].indexOf(e.form):-1])})));
  }
  assertScope(url=this.page.url()){if(this.scope&&new URL(url).origin!==this.scope)throw Error('This shared session is available only for '+this.scope+'.');}
  // A page that never yields (a script that spins) must not block the bridge for good: after the deadline this agent's page is closed and
  // its next command starts a fresh one. Other agents' pages are left alone. Only reading and preparing are guarded; a click or submit
  // that has begun is never cut off.
  async guard(work){
    const message='The page stopped responding, so Buddy reset the private browser. Open it again to continue.';
    let timer,reset=false;
    const stuck=new Promise((_,reject)=>{timer=setTimeout(()=>{reset=true;this.resetPage().finally(()=>reject(Error(message)));},this.browser.commandDeadlineMs);});
    // Closing the page also makes the stuck call fail, usually first, with a Playwright message; say what actually happened.
    try{return await Promise.race([work(),stuck]);}catch(error){throw reset?Error(message):error;}finally{clearTimeout(timer);}
  }
  async resetPage(){
    const pages=[this.page,this.googleFlow?.popup].filter(Boolean);this.reset();
    const closed=await Promise.race([Promise.all(pages.map(p=>p.close({runBeforeUnload:false}).catch(()=>{}))).then(()=>true),pause(8000).then(()=>false)]);
    // Only a Chrome that cannot even close one page is restarted.
    if(!closed)await this.browser.closeAutomation();
  }
  read(){return this.guard(()=>this.readPage());}
  async readPage(){
    const {resolver,testOrigins}=this.browser;
    await this.ready();
    // Google's account chooser, for a pinned task: its own account is chosen, never another one.
    if(this.account)for(let i=0;i<2;i++){this.assertScope();const chosen=await this.chooseAccount();if(chosen==='missing'){this.snapshot=null;throw Error(missingAccount(this.account));}if(!chosen)break;}
    this.assertScope();if(this.page.url()!=='about:blank')await publicURL(this.page.url(),resolver,testOrigins);this.refs=[];this.prepared=null;
    this.lastURL=this.page.url();const privacy=await this.privacy();
    if(privacy.private){this.snapshot=null;return {url:new URL(this.page.url()).origin,title:'Private sign-in',text:'Sign-in and verification contents are private. Use buddy_browser_signin; never request passwords in chat.',controls:[],authentication:{kind:privacy.kind,private:true}};}
    // A Google page signed in as another account shows the agent nothing of that account.
    try{await this.assertAccount({strict:false});}catch(error){this.snapshot=null;throw error;}
    const elements=await this.page.$$('a[href],button,input:not([type=hidden]),textarea,select,[role=button]');const controls=[];
    for(const e of elements.slice(0,250)) {
      if(!await e.isVisible())continue;
      const v=await e.evaluate(e=>({tag:e.tagName.toLowerCase(),type:e.getAttribute('type')||'',name:e.getAttribute('aria-label')||e.labels?.[0]?.textContent||e.getAttribute('placeholder')||e.getAttribute('name')||e.textContent?.trim().slice(0,180)||'',href:e.tagName==='A'?e.href:undefined,checked:e.checked,options:e.tagName==='SELECT'?[...e.options].slice(0,100).map(o=>({label:o.label,value:o.value})):undefined,value:e.type==='password'?'[hidden]':e.value}));
      controls.push({ref:String(this.refs.length),...v});this.refs.push(e);if(this.refs.length>=120)break;
    }
    this.snapshot={id:randomUUID(),signature:await this.signature(),url:this.page.url()};
    return this.browser.scrub({snapshotId:this.snapshot.id,url:this.safeURL(),title:await this.page.title(),text:(await this.page.locator('body').innerText().catch(()=>'' )).slice(0,26000),controls});
  }
  navigate(url){return this.guard(()=>this.navigatePage(url));}
  async navigatePage(url){
    this.assertScope(url);await this.ready();this.blockedNavigation=null;const started=Date.now();
    try{let target=await publicURL(url,this.browser.resolver,this.browser.testOrigins);target=this.pinURL(target,true)||target;this.intendedURL=target;await this.page.goto(target,{waitUntil:'domcontentloaded',timeout:30000});}
    catch(error){if(this.blockedNavigation)throw Error('Website navigation blocked: '+this.blockedNavigation);if(this.browser.blockedAt>=started)throw Error('Website navigation blocked: Local and private network pages are unavailable in Buddy’s browser.');throw error;}
    return this.read();
  }
  prepare(args){return this.guard(()=>this.preparePage(args));}
  async preparePage(args){
    const {resolver,testOrigins}=this.browser;
    await this.ready();this.assertScope();
    if((await this.privacy()).private)throw Error('This sign-in step is private. Request buddy_browser_signin instead of reading or filling credentials.');
    if(!this.snapshot||args.snapshotId!==this.snapshot.id||await this.signature()!==this.snapshot.signature)throw Error('The page changed. Read it again before proposing an operation.');
    await this.assertAccount();
    if(!['click','fill','select','upload'].includes(args.action))throw Error('Choose click, fill, select, or upload.');
    const changes=args.action==='fill'?args.fields:[{ref:args.ref,value:args.value}];
    if(!Array.isArray(changes)||!changes.length||changes.length>25)throw Error('Provide between one and twenty-five fields.');
    const targets=[];
    for(const change of changes){
      if(!/^\d{1,3}$/.test(String(change.ref)))throw Error('Use a visible control reference.');
      const e=this.refs[Number(change.ref)];if(!e||!await e.isVisible()||!await e.isEnabled())throw Error('This control is no longer visible. Read the page again.');
      const target=await e.evaluate(e=>({tag:e.tagName.toLowerCase(),type:e.getAttribute('type')||'',label:e.getAttribute('aria-label')||e.labels?.[0]?.textContent||e.getAttribute('placeholder')||e.getAttribute('name')||e.textContent?.trim().slice(0,180)||'',href:e.tagName==='A'?e.href:undefined}));
      if(/sign.?up|create.{0,15}account|\bregister\b/i.test(target.label))throw Error('New accounts need the private sign-up choice first. Use buddy_browser_signin with mode signup.');
      if(target.type==='password'||/password|credit.?card|social.?security|verification.?code|one.?time|captcha|accept.{0,20}terms|agree.{0,20}terms|sign.{0,10}contract|pay now|purchase|delete permanently/i.test(target.label))throw Error('Credentials, verification, and sensitive identity/payment fields need you. Open the browser and handle this step yourself.');
      if(args.action==='fill'&&(!['input','textarea'].includes(target.tag)||['checkbox','radio','file','submit','button'].includes(target.type)))throw Error('This control cannot be filled.');
      if(args.action==='upload'&&target.type!=='file')throw Error('Choose a file upload control.');
      if(args.action==='select'&&target.tag!=='select')throw Error('Choose a select control.');
      if(change.value!=null&&(typeof change.value!=='string'||change.value.length>12000))throw Error('Field content is too large.');
      if(target.href)await publicURL(target.href,resolver,testOrigins);
      targets.push({...target,ref:String(change.ref),value:change.value??''});
    }
    const formValues=args.action==='click'?await this.refs[Number(changes[0].ref)].evaluate(e=>[...(e.closest('form')?.querySelectorAll('input:not([type=hidden]),textarea,select')||[])].slice(0,100).map(f=>({field:f.labels?.[0]?.textContent?.trim()||f.getAttribute('aria-label')||f.name||f.type,value:f.type==='password'?'[hidden]':f.type==='file'?[...f.files].map(x=>x.name):['checkbox','radio'].includes(f.type)?f.checked:f.value}))):undefined;
    const token=randomUUID();this.prepared={token,args,targets,signature:this.snapshot.signature};
    return this.browser.scrub({token,preview:{name:`Browser: ${args.action}`,service:'Buddy private browser',arguments:{page:this.safeURL(),action:args.action,...(formValues?.length?{formValues}:{}),targets:targets.map(t=>({control:t.label||t.tag,...(t.href?{destination:t.href}:{}),...(args.action==='fill'||args.action==='select'?{value:t.value}:{}),...(args.action==='upload'?{file:args.fileName,bytes:args.bytes,version:args.version}: {})}))}}});
  }
  async commit(token,upload){
    const prepared=this.prepared;this.prepared=null;
    if(!prepared||!this.page||token!==prepared.token)throw Error('The page changed or this approval was already used. Read the page again. Nothing was sent by this request.');
    this.assertScope();
    if(await this.signature()!==prepared.signature)throw Error('The page changed or this approval was already used. Read the page again. Nothing was sent by this request.');
    // Checked again at the last moment: an approved step is never done as another account.
    await this.assertAccount({tail:' Nothing was sent by this request.'});
    this.snapshot=null;
    try{
      for(const target of prepared.targets){
        const e=this.refs[Number(target.ref)];
        if(prepared.args.action==='click')await e.click({timeout:12000});
        if(prepared.args.action==='fill')await e.fill(target.value);
        if(prepared.args.action==='select')await e.selectOption(target.value);
        if(prepared.args.action==='upload'){
          if(!upload||typeof upload.base64!=='string'||upload.base64.length>45*1024*1024)throw Error('The approved attachment is unavailable.');
          await e.setInputFiles({name:upload.name,mimeType:'application/octet-stream',buffer:Buffer.from(upload.base64,'base64')});
        }
      }
      await this.page.waitForLoadState('domcontentloaded',{timeout:6000}).catch(()=>{});
      return {performed:true,action:prepared.args.action,page:await this.readPage()};
    }catch(error){throw Error(`The browser operation did not return a confirmed result. Check the page before retrying: ${error.message}`);}
  }
  async prepareSignIn(mode='signin'){
    const {resolver,testOrigins}=this.browser;
    await this.ready();this.assertScope();const url=new URL(await publicURL(this.page.url(),resolver,testOrigins));
    if(url.protocol!=='https:'&&!this.browser.isTestOrigin(url.origin))throw Error('Sign-in requires HTTPS.');
    if(!['signin','signup','verification'].includes(mode))throw Error('Choose sign-in, account creation, or email verification.');
    const privacy=await this.privacy();if(privacy.kind==='security')throw Error('Account recovery and security changes need you in private Chrome.');
    const accountEmail=await this.username();
    // Whether Chrome's Password Manager has filled the password: a yes or no, never the value.
    const filled=await this.page.locator('input[type=password]').first().evaluate(e=>!!e.value).catch(()=>false);
    const token=randomUUID();this.authPlan={token,origin:url.origin,mode,signature:await this.signature(),created:Date.now()};
    const other=this.otherSignIn(accountEmail);
    return this.browser.scrub({token,origin:url.origin,mode,accountEmail,filled,googleAvailable:mode==='signin'&&!!await this.googleButton(this.page,url.origin),private:true,...(other?{accountReason:this.wrongSignIn(other)}:{})});
  }
  wrongSignIn(other){return `This sign-in is for ${other}, but this task must use ${this.account}. Choose ${this.account} in Buddy’s Chrome window, then press Done.`;}
  async useSaved(token){
    const plan=this.authPlan;this.authPlan=null;
    if(!plan||plan.token!==token||plan.mode!=='signin'||Date.now()-plan.created>300000||await this.signature()!==plan.signature)throw Error('This sign-in request changed or expired. Request it again.');
    const google=await this.useGoogle(plan.origin);if(google&&!google.switchedSignIn)return google;if(google?.switchedSignIn)plan.signature=await this.signature();
    // A pinned task never submits a saved login for another email: only the username is looked at, never the password.
    const other=this.otherSignIn(await this.username());
    if(other)return {needsUser:true,reason:this.wrongSignIn(other)};
    const password=this.page.locator('input[type=password][autocomplete="current-password"],input[type=password]:not([autocomplete="new-password"])').first();
    // Inspect only a boolean. No API exposes a password or the Password Manager vault.
    const ready=await password.count()?await password.evaluate(e=>{const f=e.form;if(!e.value||!f||[...f.elements].some(x=>x.autocomplete==='new-password'))return false;const target=new URL(f.action||location.href,location.href);return target.origin===location.origin&&f.method.toLowerCase()==='post';}).catch(()=>false):false;
    if(!ready)return {needsUser:true,reason:'Chrome has not filled a saved login. Open privately to choose a saved account or unlock Password Manager.'};
    const form=password.locator('xpath=ancestor::form');const button=form.locator('button[type=submit],button:not([type]),input[type=submit]').first();
    const label=await button.evaluate(e=>e.innerText||e.value||e.getAttribute('aria-label')||'').catch(()=> '');
    if(!/sign.?in|log.?in|continue|next/i.test(label)||/create|register|agree|accept|pay|purchase|reset|delete/i.test(label))return {needsUser:true,reason:'Choose this sign-in step in private Chrome.'};
    await this.privacy();if(await this.signature()!==plan.signature)throw Error('The sign-in form changed. Request it again.');this.snapshot=null;await button.click();await this.page.waitForLoadState('domcontentloaded',{timeout:6000}).catch(()=>{});
    return {performed:true,page:await this.readPage()};
  }
  googlePage(page){try{const u=new URL(page.url());return u.protocol==='https:'&&u.hostname==='accounts.google.com'||!!this.browser.testGooglePath&&this.browser.isTestOrigin(u.origin)&&u.pathname.startsWith(this.browser.testGooglePath);}catch{return false;}}
  async googleButton(page,origin){
    for(const item of await page.locator('button,a[href],[role=button]').all()){
      if(!await item.isVisible()||!await item.isEnabled())continue;
      const label=await item.evaluate(e=>(e.innerText||e.getAttribute('aria-label')||'').trim().replace(/\s+/g,' '));
      if(!/^(?:(?:continue|sign in|log in)(?: with)? )?google$/i.test(label))continue;
      const href=await item.getAttribute('href');if(href){const u=new URL(href,page.url());if(u.origin!==origin&&!(u.protocol==='https:'&&u.hostname==='accounts.google.com'))continue;}
      return item;
    }
    return null;
  }
  async useGoogle(origin){
    const root=this.page;let switchedSignIn=false;
    const signup=()=>/\/(?:sign-up|signup|register)(?:\/|$)/i.test(new URL(root.url()).pathname);
    if(signup()){
      // Login must not submit the registration form shown by some sites by default.
      let link;
      for(const item of await root.locator('a[href]').all()){
        if(!await item.isVisible())continue;
        const label=(await item.innerText()).trim(),href=new URL(await item.getAttribute('href'),root.url());
        if(/^(?:sign|log)\s?in$/i.test(label)&&href.origin===origin&&/\/(?:sign-in|signin|login)(?:\/|$)/i.test(href.pathname)){link=item;break;}
      }
      if(!link)return {needsUser:true,reason:'The site is on account creation rather than sign-in. Choose the existing-account sign-in privately.'};
      const oldLink=await link.elementHandle(),oldHref=await link.getAttribute('href');
      await link.click();await root.waitForLoadState('domcontentloaded',{timeout:6000}).catch(()=>{});
      const transitionDeadline=Date.now()+6000;let stillSignupLink=true;
      while(Date.now()<transitionDeadline){
        stillSignupLink=await oldLink.evaluate((e,href)=>e.isConnected&&e.getClientRects().length>0&&/^(?:sign|log)\s?in$/i.test(e.textContent.trim())&&e.getAttribute('href')===href,oldHref).catch(()=>false);
        if(!stillSignupLink)break;
        await pause(75);
      }
      if(stillSignupLink||new URL(root.url()).origin!==origin||signup())return {needsUser:true,reason:'The existing-account sign-in needs you.'};
      switchedSignIn=true;
    }
    if(new URL(root.url()).origin!==origin)return null;
    let google=await this.googleButton(root,origin);
    if(switchedSignIn&&!google){const deadline=Date.now()+3000;while(!google&&Date.now()<deadline){await pause(100);google=await this.googleButton(root,origin);}}
    if(!google)return switchedSignIn?{switchedSignIn:true}:null;
    this.snapshot=null;const flow={origin,popup:null};this.googleFlow=flow;let choseAccount=false;
    try{
      await google.click({timeout:12000});
      const deadline=Date.now()+12000;
      for(let i=0;i<32&&Date.now()<deadline;i++){
        const popup=flow.popup&&!flow.popup.isClosed()?flow.popup:null,page=popup||root;
        await page.waitForLoadState('domcontentloaded',{timeout:1200}).catch(()=>{});
        const url=new URL(page.url());
        if(this.googlePage(page)){
          // Only an unambiguous existing account tile is automatic. Passwords,
          // new accounts, OAuth permissions, agreements and challenges stay private.
          const tiles=page.locator('[data-identifier]'),visible=[];
          for(const tile of await tiles.all())if(await tile.isVisible())visible.push(tile);
          const challenge=await page.locator('input[type=password],input[autocomplete="one-time-code"],iframe[src*="recaptcha"]').count();
          const consent=/\/consent(?:\/|$)|\/approval(?:\/|$)|\/challenge(?:\/|$)|\/signin\/v\d+/i.test(url.pathname);
          // A pinned task chooses its own account's tile, whatever else is offered; without it, the person is asked to sign in to it.
          if(!choseAccount&&!challenge&&!consent&&this.account&&visible.length){
            const ids=[];for(const tile of visible)ids.push(String(await tile.getAttribute('data-identifier').catch(()=>'')||'').trim().toLowerCase());
            const mine=visible[ids.indexOf(this.account)];
            if(mine){choseAccount=true;await mine.click();continue;}
            this.page=page;return {needsUser:true,method:'google',reason:missingAccount(this.account),accountMissing:this.account};
          }
          if(!choseAccount&&!challenge&&!consent&&visible.length===1){choseAccount=true;await visible[0].click();continue;}
          if(challenge||consent||visible.length>1){this.page=page;return {needsUser:true,method:'google',reason:visible.length>1?'Choose which Google account to use privately.':'Google needs your sign-in, verification or permission choice.'};}
        }else if(url.origin===origin&&!(this.browser.testGooglePath&&url.pathname.startsWith(this.browser.testGooglePath))&&!/\/(?:oauth|[^/]*callback[^/]*|sso|authorize)(?:\/|$)/i.test(url.pathname)){
          this.page=page;const result=await this.readPage();
          if(!result.authentication?.private){if(popup)await root.close().catch(()=>{});return {performed:true,method:'google',page:result};}
        }
        // OAuth callbacks may briefly use the site's authentication subdomain.
        // Wait for the approved site without reading or acting on other origins.
        await pause(250);
      }
      this.page=flow.popup&&!flow.popup.isClosed()?flow.popup:root;
      return {needsUser:true,method:'google',reason:'Google sign-in needs a private account choice or verification.'};
    }finally{this.googleFlow=null;}
  }
  async verificationPlan(){
    await this.ready();this.assertScope();const p=await this.privacy();if(!p.private||p.kind!=='verification')throw Error('A supported email verification form is not visible.');
    const url=new URL(this.page.url());if(url.protocol!=='https:'&&!this.browser.isTestOrigin(url.origin))throw Error('Email verification requires HTTPS.');
    if(/(^|\.)(google|microsoft|apple)\.com$/i.test(url.hostname))throw Error('Identity-provider verification needs you in private Chrome.');
    const candidate=await this.page.evaluate(()=>{
      const input=[...document.querySelectorAll('input')].find(e=>e.autocomplete==='one-time-code');const form=input?.form;
      if(!input||!form||new URL(form.action||location.href,location.href).origin!==location.origin||form.method.toLowerCase()!=='post')return null;
      const body=document.body.innerText.slice(0,6000);if(!/e.?mail|inbox/i.test(body)||/reset|recover|password|payment|transfer|security.?settings/i.test(body))return null;
      const email=body.match(/\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/i)?.[0];
      const submit=[...form.querySelectorAll('button,input[type=submit]')].find(e=>/verify|confirm|continue/i.test(e.innerText||e.value||'')&&!/pay|purchase|agree|accept/i.test(e.innerText||e.value||''));
      if(!email||!submit)return null;return {email,length:input.maxLength>=4&&input.maxLength<=8?input.maxLength:6};
    });
    if(!candidate)throw Error('This verification step needs you: it must identify a full email address and a same-site email-code form.');
    const token=randomUUID();this.authPlan={token,origin:url.origin,mode:'verification',signature:await this.signature(),created:Date.now(),...candidate};
    return {token,origin:url.origin,...candidate};
  }
  async verifyEmail(token,code){
    const p=this.authPlan;this.authPlan=null;
    if(!p||p.token!==token||p.mode!=='verification'||Date.now()-p.created>300000||await this.signature()!==p.signature||!new RegExp(`^\\d{${p.length}}$`).test(code))throw Error('This verification request changed or expired.');
    this.browser.remember(code,p.origin);
    try{await this.page.locator('input[autocomplete="one-time-code"]').first().fill(code);const form=this.page.locator('input[autocomplete="one-time-code"]').first().locator('xpath=ancestor::form');if(await form.evaluate(f=>new URL(f.action||location.href,location.href).origin)!==p.origin)throw Error('Verification destination changed.');let submit;for(const e of await form.locator('button,input[type=submit]').all()){const label=await e.evaluate(e=>e.innerText||e.value||'');if(/verify|confirm|continue/i.test(label)&&!/pay|purchase|agree|accept/i.test(label)){submit=e;break;}}if(!submit)throw Error('Verification changed.');await submit.click();await this.page.waitForLoadState('domcontentloaded',{timeout:6000}).catch(()=>{});return {performed:true,page:await this.read()};}
    catch{throw Error('Verification was attempted without a confirmed result. Inspect the site before trying another code.');}
  }
  /** What the person can type for this page in Buddy's chat: its password field, or a one-time code field, with a one-use token bound to
   *  this session, this site, the shape of this page and a few minutes. `field` is null when there is nothing to type (the site waits for
   *  something the person does elsewhere). The model never sees a token; only the Mac app does. */
  secretPlan(){return this.guard(()=>this.planSecret());}
  async planSecret(){
    const {resolver,testOrigins}=this.browser;
    await this.ready();this.assertScope();this.secretPlanState=null;
    const url=new URL(await publicURL(this.page.url(),resolver,testOrigins));
    if(url.protocol!=='https:'&&!this.browser.isTestOrigin(url.origin))throw Error('Typing a password needs a secure (HTTPS) sign-in page. Do this step yourself in Buddy’s Chrome window.');
    if(identityProvider(url.hostname))throw Error('This identity provider’s sign-in needs you in Buddy’s Chrome window.');
    const privacy=await this.privacy();
    if(privacy.kind==='security')throw Error('Account recovery and security changes need you in Buddy’s Chrome window.');
    const candidates=[];
    for(const e of await this.page.$$('input')){
      const info=await e.evaluate(e=>({type:e.type,auto:e.autocomplete,label:[e.name,e.id,e.getAttribute('aria-label'),e.labels?.[0]?.textContent,e.placeholder].join(' '),shown:!!(e.offsetWidth||e.offsetHeight||e.getClientRects().length)&&getComputedStyle(e).visibility!=='hidden',usable:!e.disabled&&!e.readOnly})).catch(()=>null);
      if(!info?.shown||!info.usable)continue;
      if(info.type==='password'){candidates.push({e,kind:info.auto==='new-password'?'new':'password'});continue;}
      if(info.auto==='one-time-code'||/verification.?code|one.?time|\botp\b|security.?code|auth.?code|2fa|two.?factor/i.test(info.label))candidates.push({e,kind:'code'});
    }
    if(candidates.some(c=>c.kind==='new')||candidates.filter(c=>c.kind==='password').length>1)throw Error('This page asks for a new password (a new account or a password change). Do that yourself in Buddy’s Chrome window.');
    const codes=candidates.filter(c=>c.kind==='code'),pick=candidates.find(c=>c.kind==='password')||(codes.length===1?codes[0]:null);
    if(!pick)return {field:null,origin:url.origin,waiting:privacy.private};
    // A code that confirms a payment or a bank transfer is the person's to enter where they can see what it confirms.
    if(pick.kind==='code'&&await this.page.evaluate(()=>/payment|card ?number|credit card|debit|3-?d ?secure|verified by visa|securecode|bank|transfer|transaction|purchase|amount due|checkout/i.test(document.title+' '+(document.body?.innerText||'').slice(0,4000))).catch(()=>true))throw Error('A payment or bank verification needs you in Buddy’s Chrome window.');
    const form=await pick.e.evaluate(e=>e.form?{action:new URL(e.form.getAttribute('action')||location.href,location.href).origin,get:(e.form.getAttribute('method')||'').toLowerCase()==='get'}:null);
    if(form&&(form.action!==url.origin||form.get))throw Error('This sign-in form would send what you type elsewhere or in the page address. Do this step yourself in Buddy’s Chrome window.');
    let button=null;
    for(const b of await this.page.$$(form?'form button, form input[type=submit]':'button, input[type=submit], [role=button]')){
      const fit=await b.evaluate((b,field)=>{if(field.form&&b.form!==field.form)return false;if(!(b.offsetWidth||b.offsetHeight||b.getClientRects().length)||b.disabled)return false;const label=(b.innerText||b.value||b.getAttribute('aria-label')||'').trim();return /sign.?in|log.?in|continue|next|verify|submit|confirm|^ok$|done/i.test(label)&&!/create|register|sign.?up|agree|accept|pay|purchase|buy|reset|forgot|delete|remove|google|apple|microsoft|facebook|passkey/i.test(label);},pick.e).catch(()=>false);
      if(fit){button=b;break;}
    }
    const account=await this.username();
    // A pinned task types nothing into a sign-in for another email.
    const other=this.otherSignIn(account);
    if(other)throw Error(`This sign-in is for ${other}, but this task must use ${this.account}. Nothing was typed. Choose ${this.account} in Buddy’s Chrome window, then press Done.`);
    const token=randomUUID();
    this.secretPlanState={token,origin:url.origin,field:pick.e,kind:pick.kind,button,signature:await this.formSignature(),created:Date.now()};
    return this.browser.scrub({token,origin:url.origin,field:pick.kind,account:account||null,private:true});
  }
  /** Types what the person sent into the field the token was made for, and submits it, once. It is remembered only to keep it out of
   *  every observation and every request to another site. */
  async fillSecret(token,value){
    const plan=this.secretPlanState;this.secretPlanState=null;
    if(!plan||typeof token!=='string'||plan.token!==token)throw Error('This sign-in request was already used or replaced. Nothing was typed.');
    if(typeof value!=='string'||!value.length||value.length>1000||/[\0\r\n]/.test(value))throw Error('Type the password or code on one line, up to 1,000 characters. Nothing was typed.');
    if(!this.page||this.page.isClosed()||new URL(this.page.url()).origin!==plan.origin||await this.formSignature().catch(()=>'')!==plan.signature)throw Error('The sign-in page changed. Nothing was typed.');
    if(Date.now()-plan.created>this.browser.secretTTLms)throw Error('This sign-in request expired. Nothing was typed.');
    if(!await plan.field.isVisible().catch(()=>false)||!await plan.field.isEnabled().catch(()=>false))throw Error('The sign-in page changed. Nothing was typed.');
    if(this.otherSignIn(await this.username()))throw Error('The sign-in page now names another account. Nothing was typed.');
    this.browser.remember(value,plan.origin);this.snapshot=null;
    try{
      await plan.field.fill(value);
      await afterSubmit(this.page,()=>plan.button?plan.button.click({timeout:12000}):plan.field.press('Enter'));
    }catch{throw Error('The sign-in step did not return a confirmed result. Look at the page before trying again.');}
    return await this.outcome();
  }
  // Signed in when the page no longer asks for anything private. Otherwise: what can be typed next (a fresh token), or nothing to type.
  async outcome(){
    // A page that is still loading has no document to look at yet: look again in a moment.
    let privacy;for(let i=0;;i++){try{privacy=await this.privacy();break;}catch(error){if(i>=4||!this.page||this.page.isClosed())throw error;await pause(300);}}
    if(!privacy.private){this.snapshot=null;return {signedIn:true,performed:true,page:await this.readPage()};}
    let next=null,reason='';
    try{next=await this.planSecret();}catch(error){reason=String(error.message||error);}
    if(next?.token)return {signedIn:false,next:{token:next.token,field:next.field,origin:next.origin,account:next.account},kind:privacy.kind};
    return {signedIn:false,next:null,waiting:true,kind:privacy.kind,...(reason?{needsChrome:true,reason}:{})};
  }
  /** Done: look again. `reload` opens the page the agent wanted once more (after the person used Chrome's own window): the step's own page
   *  (`url`) when it named one, else the page this session was on. */
  recheck(options){return this.guard(()=>this.checkSignedIn(options));}
  async checkSignedIn({reload=false,url=''}={}){
    await this.ready();
    if(reload){
      let target=url||this.intendedURL||this.lastURL;if(!target)return {signedIn:false,unknown:true};
      this.assertScope(target);target=await publicURL(target,this.browser.resolver,this.browser.testOrigins);target=this.pinURL(target,true)||target;if(url)this.intendedURL=target;
      await this.page.goto(target,{waitUntil:'domcontentloaded',timeout:30000}).catch(()=>{});await pause(300);
    }
    return this.outcome();
  }
}

/** The single-session browser earlier code and tests use: one session named "default" in its own profile. */
export class PrivateBrowser extends SharedBrowser {
  constructor(profile,options={}){super(profile,options);this.main=this.session('default',options.sharedOrigin||'');}
  get page(){return this.main.page;}
  get snapshot(){return this.main.snapshot;}
  navigate(url){return this.main.navigate(url);}
  read(){return this.main.read();}
  prepare(args){return this.main.prepare(args);}
  commit(token,upload){return this.main.commit(token,upload);}
  prepareSignIn(mode){return this.main.prepareSignIn(mode);}
  useSaved(token){return this.main.useSaved(token);}
  verificationPlan(){return this.main.verificationPlan();}
  verifyEmail(token,code){return this.main.verifyEmail(token,code);}
  assertScope(url){return this.main.assertScope(url);}
  manual(destination){return super.manual(destination,{session:'default'});}
}

// The bridge to the Mac app: one process for the one shared profile. Each request that acts on a page names the task's session (and the
// delegated website scope and the account it was opened with); the app chooses them, never a model. Requests for different sessions run
// side by side, those for one session in order.
if(process.argv[1]&&import.meta.url===pathToFileURL(realpathSync(process.argv[1])).href){
  const browser=new SharedBrowser(process.argv[2]);
  const lanes=new Map();
  const pageCommands={open:(s,r)=>s.navigate(r.url),read:s=>s.read(),prepare:(s,r)=>s.prepare(r.arguments),commit:(s,r)=>s.commit(r.token,r.upload),prepareSignIn:(s,r)=>s.prepareSignIn(r.mode),useSaved:(s,r)=>s.useSaved(r.token),verificationPlan:s=>s.verificationPlan(),verifyEmail:(s,r)=>s.verifyEmail(r.token,r.code),secretPlan:s=>s.secretPlan(),fillSecret:(s,r)=>s.fillSecret(r.token,r.value),recheck:(s,r)=>s.recheck({reload:r.reload===true,url:typeof r.url==='string'?r.url:''})};
  async function answer(request){
    if(Object.hasOwn(pageCommands,request.command))return pageCommands[request.command](browser.session(request.session,request.scope??'',request.account??''),request);
    if(request.command==='manual')return browser.manual(undefined,{session:typeof request.session==='string'?request.session:undefined,url:typeof request.url==='string'?request.url:undefined,page:typeof request.page==='string'&&request.page?request.page:undefined,account:typeof request.account==='string'?request.account:undefined});
    if(request.command==='manualGoogle')return browser.manual('google',{session:typeof request.session==='string'?request.session:undefined});
    if(request.command==='finishManual')return browser.finishManual();
    if(request.command==='closeSession')return browser.closeSession(request.session);
    if(request.command==='sessions')return {sessions:[...browser.sessions.keys()],pages:[...browser.sessions.values()].filter(s=>s.page&&!s.page.isClosed()).map(s=>s.id),manual:browser.manualOpen()};
    if(request.command==='close'){await browser.close();return {closed:true};}
    throw Error('Unsupported browser command.');
  }
  const reply=(request,work)=>work.then(result=>process.stdout.write(frame({id:request?.id,result:browser.scrub(result)})),error=>process.stdout.write(frame({id:request?.id,error:browser.scrub(String(error?.message||error))})));
  const pending=new Set();let barrier=Promise.resolve();
  for await(const line of createInterface({input:process.stdin})){
    let request;
    try{if(line.length>48*1024*1024)throw Error('Browser message too large.');request=JSON.parse(line);}
    catch(error){process.stdout.write(frame({id:request?.id,error:browser.scrub(error.message)}));continue;}
    const lane=Object.hasOwn(pageCommands,request.command)||request.command==='closeSession'?'session:'+request.session:'browser';
    // Listing sessions and closing wait for everything already asked, and what comes after waits for them; anything else waits only
    // for its own session.
    const global=['sessions','close'].includes(request.command);
    const before=global?Promise.allSettled([...pending]):Promise.all([lanes.get(lane),barrier]);
    const run=before.then(()=>reply(request,Promise.resolve().then(()=>answer(request))));
    if(global)barrier=run;
    lanes.set(lane,run);pending.add(run);run.finally(()=>{pending.delete(run);if(lanes.get(lane)===run)lanes.delete(lane);});
  }
  await Promise.allSettled([...pending]);
  await browser.close();
}

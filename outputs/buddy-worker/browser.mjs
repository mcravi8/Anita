import {chromium} from 'playwright-core';
import {lookup} from 'node:dns/promises';
import {isIP} from 'node:net';
import {startGuardProxy,publicAddress} from './network-guard.mjs';
import {randomUUID, createHash} from 'node:crypto';
import {mkdir, chmod, lstat, readlink, unlink, writeFile, readdir, stat, rm, cp, copyFile, link, open} from 'node:fs/promises';
import {hostname, tmpdir} from 'node:os';
import {resolve, isAbsolute, join, basename, extname} from 'node:path';
import {constants as fsConstants} from 'node:fs';
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
// A wait that never keeps the bridge running by itself.
const idle=ms=>new Promise(r=>{const t=setTimeout(r,ms);t.unref?.();});
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
// The largest file Buddy downloads for a step: what a connected folder takes in one file.
const DOWNLOAD_LIMIT=32*1024*1024;
// A web page where a file was expected: a sign-in form, a CAPTCHA, an error page.
const webPage=(type,body)=>/^(text\/html|application\/xhtml\+xml)$/.test(type)||/^\s*<(!doctype html|html|head|body)\b/i.test(body.subarray(0,512).toString('latin1').replace(/^\uFEFF/,''));

// MARK: fetching a file with Buddy's Chrome (buddy_browser_fetch)

// The largest file one fetch saves.
export const FETCH_LIMIT=200*1024*1024;
const tooLarge=limit=>Error(`The file is larger than ${Math.max(1,Math.round(limit/1048576))} MB, so Buddy didn't save it.`);
const POSTED='The page tried to submit a form. A fetch only opens the address you gave (GET) and never submits anything, so nothing was sent and nothing was saved.';
// What a fetch saves: a relative path inside the folder Buddy chose, every part visible and plain. Returns its parts.
function savedName(raw){
  const text=typeof raw==='string'?raw.trim():'';
  const parts=text.split('/');
  if(!text||text.length>1000||text.startsWith('/')||/[\\:\0]/.test(text)||parts.length>12||parts.some(p=>!p||p.startsWith('.')||p.length>255||p!==p.trim()))
    throw Error('Give saveAs: a relative path inside the folder, with the file name (for example sources/article.pdf). No hidden names, no .., no absolute paths.');
  return parts;
}
// A page that stands between the person and the file: a CAPTCHA (its frames, its widgets, its words), a sign-in form, or an access check.
const CAPTCHA_SOURCES=/recaptcha|hcaptcha|challenges\.cloudflare\.com|turnstile|captcha|arkoselabs|funcaptcha|perimeterx|px-cloud|datadome|geetest/i;
const CAPTCHA_WORDS=/\bcaptcha\b|verify (that )?you(['\u2019]re| are) (a )?human|are you a (robot|human)|i['\u2019]?m not a robot|confirm (that )?you(['\u2019]re| are) (a )?human|checking (if the site connection is secure|your browser)|just a moment|press (&|and) hold|unusual traffic|security check|bot (check|detection|protection|manager)|human verification|make sure (it is|it['\u2019]s) (actually )?you/i;
const SIGNIN_TITLE=/\b(sign|log) ?in\b|\blogin\b/i;
const BLOCKED_WORDS=/access denied|forbidden|request (was )?blocked|not authori[sz]ed|subscription required|(log|sign) in to (access|continue|view|read)|institutional (access|login)|you (do not|don['\u2019]t) have access/i;
// A file's type from its first bytes or its name, when the website didn't say.
const KNOWN_TYPES={pdf:'application/pdf',csv:'text/csv',txt:'text/plain',json:'application/json',zip:'application/zip',xlsx:'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',docx:'application/vnd.openxmlformats-officedocument.wordprocessingml.document',png:'image/png',jpg:'image/jpeg',jpeg:'image/jpeg',gz:'application/gzip',html:'text/html',htm:'text/html'};
const typeOf=(head,name)=>head.subarray(0,5).toString('latin1')==='%PDF-'?'application/pdf':KNOWN_TYPES[extname(name||'').slice(1).toLowerCase()]||'application/octet-stream';
// An address as a receipt keeps it: no user name, no fragment, and no value of a parameter that may be a key or a ticket.
function receiptURL(raw){try{const u=new URL(raw);u.username='';u.password='';u.hash='';for(const key of [...u.searchParams.keys()])if(/code|token|password|secret|credential|assertion|ticket|sig|key|session|auth/i.test(key))u.searchParams.set(key,'[private]');return u.href;}catch{return '';}}
// macOS quarantine on every saved file, as a browser download has: macOS asks before anything in it is opened or run.
async function quarantine(path){
  if(process.platform!=='darwin')return;
  await runFile('/usr/bin/xattr',['-w','com.apple.quarantine',`0081;${Math.floor(Date.now()/1000).toString(16)};Buddy;${randomUUID().toUpperCase()}`,path],{timeout:5000}).catch(()=>{});
}
async function sha256File(path){const hash=createHash('sha256'),file=await open(path,'r');try{for await(const chunk of file.createReadStream())hash.update(chunk);}finally{await file.close().catch(()=>{});}return hash.digest('hex');}
async function head(path){const file=await open(path,'r');try{const buffer=Buffer.alloc(1024);const {bytesRead}=await file.read(buffer,0,1024,0);return buffer.subarray(0,bytesRead);}finally{await file.close().catch(()=>{});}}
// What is copied of the shared profile while the person's window is open: its sign-ins (cookies, site storage, saved logins, settings), not
// its locks, caches, history or other large stores the agents' pages never need (service workers are blocked for them anyway).
const NOT_COPIED=/^(Singleton(Lock|Cookie|Socket)|lockfile|Cache|Code Cache|GPUCache|DawnCache|DawnGraphiteCache|DawnWebGPUCache|GrShaderCache|GraphiteDawnCache|ShaderCache|Crashpad|component_crx_cache|extensions_crx_cache|Safe Browsing|BrowserMetrics.*|optimization_guide.*|OnDeviceHeadSuggestModel|Subresource Filter|CacheStorage|ScriptCache|Download Service|Service Worker|File System|blob_storage|GCM Store|Extensions|Extension State|Local Extension Settings|Sync Data|History|History-journal|Favicons|Favicons-journal|Top Sites|Top Sites-journal|Visited Links|Shortcuts|Shortcuts-journal|Media History|shared_proto_db|Feature Engagement Tracker|Segmentation Platform|VideoDecodeStats|Platform Notifications|BudgetDatabase|commerce_subscription_db|coupon_db|DIPS|DIPS-journal|SharedStorage|Accounts)$/;
// Google refuses a sign-in in a browser an agent drives; the person then finishes it in Buddy's Chrome window.
const GOOGLE_REFUSED='Google won\u2019t accept this sign-in in the browser agents use. Finish it in Buddy\u2019s Chrome window.';

// MARK: money (Buddy never pays, subscribes or starts a trial that becomes paid)

// A payment provider's own frame (where a card is typed), by its host.
const PAYMENT_FRAMES=/(^|\.)(stripe\.com|stripe\.network|braintreegateway\.com|braintree-api\.com|braintreepayments\.com|adyen\.com|adyenpayments\.com|paypal\.com|paypalobjects\.com|checkout\.com|recurly\.com|chargebee\.com|paddle\.com|squareup\.com|klarna\.com)$|^pay\.google\.com$/i;
// Words that ask for payment details, and words of a trial that becomes paid or of a paid plan.
const PAYMENT_WORDS=/card number|credit or debit card|enter your card|payment (method|details|information)|billing (address|details|information)|\bcvc\b|\bcvv\b/i;
const TRIAL_WORDS=/free[- ]trial|trial (ends|period|expires|converts)|after (your|the) trial|then [$\u20ac\u00a3]\s?\d/i;
const PLAN_WORDS=/[$\u20ac\u00a3]\s?\d[\d.,]*\s*(\/\s?(mo|month|yr|year)\b|per month|a month|billed (monthly|annually|yearly))|choose (a|your) plan|select (a|your) plan|pick (a|your) plan|\bcheckout\b/i;
// What a button that spends money says. ("PayPal" alone is not "pay".)
const MONEY_ACTIONS=/\bsubscribe\b|\bupgrade\b|start (my |your |a )?(free )?trial|\bbuy\b|\bpurchase\b|\bpay\b|place (your |my )?order|\bcheckout\b|check out|add (a )?(payment|card)/i;
// Words on a control (or in a link's address) that can spend, send, submit, delete, start or change something: a step with any of them waits
// for review, whatever else it looks like. Everything else that only shows something (a tab, a filter, a link, a section opened, a search) is
// routine and goes ahead by itself.
const CONSEQUENTIAL=/\b(send|submit|post|publish|share|invite|e-?mail|message|reply|comment|delete|remove|erase|destroy|terminate|stop|cancel|unsubscribe|deactivate|disable|enable|deploy|launch|start|run|rent|create|new|add|save|apply|confirm|approve|accept|agree|authori[sz]e|allow|grant|connect|disconnect|transfer|withdraw|deposit|top.?up|fund|credits?|billing|payment|pay|buy|order|checkout|upgrade|subscribe|sign.?(in|out|up)|log.?(in|out)|reset|change|update|edit|rename|install|uninstall|download|upload|import|export|restore|archive|move|copy|duplicate|schedule|book|reserve|register|join|follow|like|vote|report|block|request|claim|redeem|activate|verify|continue|proceed|finish|done|complete)\b/i;
const SEARCH_FIELD=/search|query|find|filter|(^|\s)q(\s|$)/i;
const NEVER_PAYS='Buddy never enters payment details, subscribes, upgrades or starts a trial. Nothing was done. If the user wants this, ask them with buddy_checkpoint (url of this page): they do it themselves in Buddy\u2019s Chrome.';
// The site a host belongs to (jobs.ubs.com and login.ubs.com are both ubs.com), for a link in an email; an IP address only matches itself.
function siteOf(host){
  const h=String(host||'').toLowerCase().replace(/^\[|\]$/g,'');if(isIP(h))return h;
  const parts=h.split('.');if(parts.length<=2)return h;
  const two=parts.slice(-2).join('.');
  return /^(co|com|org|net|ac|gov|edu|ne|or)\.[a-z]{2}$/.test(two)?parts.slice(-3).join('.'):two;
}
// A strong new password only Buddy knows: never shown to a model, typed only into the site it is for.
const goodPassword=value=>typeof value==='string'&&value.length>=12&&value.length<=200&&!/[\0\r\n]/.test(value);
// What a sign-up or reset form's own button says, and what it must not say.
const CREATE_BUTTON=/create|sign.?up|register|join|continue|next|submit|get started|open (an |my )?account|finish|done/i;
const NOT_CREATE=/\bpay\b|purchase|\bbuy\b|subscribe|trial|checkout|upgrade|order|google|apple|facebook|microsoft|linkedin|github|passkey|sign.?in with|log.?in with/i;
const RESET_LINK=/forgot|reset (your |my )?password|trouble (signing|logging) in|can['\u2019]?t (sign|log) in|lost (your |my )?password/i;
const RESET_BUTTON=/reset|send|continue|submit|next|request|email me|get (a )?link|save|change|update|set|confirm|done/i;
const MARKETING=/newsletter|marketing|offers?\b|promotion|partners?\b|\bnews\b|updates|special|tips|events|job alerts?|alerts|communications|e-?mails? (about|from)|subscribe|sms|text messages|third.?part/i;
const TERMS=/terms|conditions|privacy|policy|agreement|consent|data (protection|processing)|gdpr|eula|code of conduct|i (have )?read|i agree|i accept/i;
const MONEY_BOX=/payment|billing|charge|subscription|trial|auto.?renew|\bcard\b|\bfee\b|[$\u20ac\u00a3]\s?\d/i;

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
  constructor(profile,{testOrigin='',testOrigins=[],testGooglePath='',testGoogle=[],commandDeadlineMs=40000,resolver=lookup,guardOptions={},manualExecutable='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',secretTTLms=600000,fetchDeadlineMs=180000,downloadWaitMs=4000}={}) {
    this.profile=resolve(profile);this.testOrigins=new Set([testOrigin,...testOrigins].filter(Boolean));this.testGooglePath=this.testOrigins.size?testGooglePath:'';
    // Test origins that stand in for Google's own sites (only ever one of the test origins).
    this.testGoogle=new Set([].concat(testGoogle).filter(o=>this.testOrigins.has(o)));
    this.commandDeadlineMs=commandDeadlineMs;this.resolver=resolver;this.guardOptions=guardOptions;this.manualExecutable=manualExecutable;this.secretTTLms=secretTTLms;
    this.context=null;this.launching=null;this.closing=null;this.spare=[];this.creating=0;this.sessions=new Map();this.manualProcess=null;this.handingOff=false;this.lastURL=null;
    this.secrets=new Set();this.secretOrigins=new Map();this.blockedAt=0;
    // Downloads: only a fetch's own download is kept (one fetch at a time); any other is dropped. Chrome writes them in `downloadsDir`.
    this.fetchDeadlineMs=fetchDeadlineMs;this.downloadWaitMs=downloadWaitMs;this.fetchQueue=Promise.resolve();this.droppedDownloads=0;this.downloadsDir=null;
    // The Chrome the agents use runs on `contextProfile`: the shared profile, or while the person's window is open on it, a copy (`shadow`).
    // `manualOwner` is the task that window is for (null for the setup window): only that task waits for it.
    this.contextProfile=null;this.shadow=null;this.manualOwner=null;
  }
  /** Where the copy of the profile goes while the person's window is open (beside the profile, never in it). */
  get shadowPath(){return this.profile+'.while-open.noindex';}
  /** Whether `session` belongs to the task the person's window is open for (its own page, or its fetch). */
  ownsWindow(session){const owner=this.manualOwner;return !!owner&&!!session&&(session.id===owner||session.id.startsWith(owner+':'));}
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
  /** The agents' Chrome, for `session`. While the person's window is open on the shared profile, the agents' Chrome runs on the copy made
   *  when it opened; the task the window is for (and a moment with no copy) waits for the person instead. */
  async ensureContext(session){
    if(this.closing)await this.closing;
    const open=this.manualOpen();
    if(open&&(!this.shadow||this.ownsWindow(session)))throw Error(OPEN_FOR_YOU);
    const where=open?this.shadow:this.profile;
    if(this.launching){await this.launching.catch(()=>{});if(this.closing)await this.closing;}
    if(this.context&&this.contextProfile===where)return this.context;
    // The other profile's Chrome closes first (its pages are reset; each task opens its page again at its next step).
    if(this.context)await this.closeAutomation();
    if(!this.launching)this.launching=this.launch(where).finally(()=>{this.launching=null;});
    return await this.launching;
  }
  async launch(where=this.profile) {
    const copy=where!==this.profile;
    if(copy?!this.manualOpen()||where!==this.shadow:this.manualOpen())throw Error(OPEN_FOR_YOU);
    await mkdir(where,{recursive:true,mode:0o700});await chmod(where,0o700);
    // A Chrome window still open on the profile (the person's, from before a restart) is never joined by an agent connection.
    if(!copy&&await this.profileLock())throw Error('Buddy’s private Chrome window is still open. Close it, or choose Done, before agents use the browser.');
    // A copy left from a window that was open when Buddy stopped is no longer needed.
    if(!copy)await rm(this.shadowPath,{recursive:true,force:true}).catch(()=>{});
    if(!this.downloadsDir){const dir=join(tmpdir(),`buddy-browser-downloads-${randomUUID()}.noindex`);await mkdir(dir,{recursive:true,mode:0o700});this.downloadsDir=dir;}
    // Every request Chrome makes goes through a proxy that checks the real destination as it connects (see network-guard.mjs). The bypass
    // list switches off Chrome's built-in exemption for localhost and loopback, which would otherwise skip the proxy entirely.
    if(!this.netGuard)this.netGuard=await startGuardProxy({resolver:this.resolver,allow:[...this.testOrigins].map(o=>{const u=new URL(o);return u.hostname.replace(/^\[|\]$/g,'')+':'+(u.port||(u.protocol==='https:'?'443':'80'));}),onBlocked:()=>{this.blockedAt=Date.now();},...this.guardOptions});
    // Use Chrome's real encrypted profile, never Playwright's mock Keychain/basic password store.
    // Downloads are accepted into Buddy's own folder for Chrome's downloads, and only a fetch's own download is kept (see `routeDownload`).
    const context=await chromium.launchPersistentContext(where,{channel:'chrome',headless:true,chromiumSandbox:true,acceptDownloads:true,downloadsPath:this.downloadsDir,permissions:[],serviceWorkers:'block',proxy:{server:this.netGuard.server,username:this.netGuard.username,password:this.netGuard.password,bypass:'<-loopback>'},ignoreDefaultArgs:['--password-store=basic','--use-mock-keychain','--disable-sync'],args:['--disable-extensions','--disable-background-networking','--force-webrtc-ip-handling-policy=disable_non_proxied_udp']});
    this.spare=[...context.pages()];
    for(const p of context.pages())this.watchDownloads(p);
    await context.route('**/*',route=>this.route(route));
    // If Chrome exits or crashes, forget the dead context so the next command starts a new one instead of failing forever.
    context.on('close',()=>{if(this.context!==context)return;this.context=null;this.contextProfile=null;this.spare=[];for(const s of this.sessions.values()){s.reset();s.owned.clear();}});
    context.on('page',p=>{this.watchDownloads(p);this.adopt(p);});
    this.context=context;this.contextProfile=where;return context;
  }
  watchDownloads(page){page.on('download',download=>this.routeDownload(page,download));}
  /** A download is kept only when the fetch that asked for it is waiting on that very page; any other (a page that starts one by itself, a
   *  link an agent clicks) is cancelled and deleted at once. */
  routeDownload(page,download){
    const s=this.sessionFor(page),f=s?.fetching;
    if(f&&f.page===page&&!f.download){f.download=download;f.gotDownload(download);return;}
    this.droppedDownloads++;
    download.cancel().catch(()=>{}).finally(()=>download.delete().catch(()=>{}));
  }
  /** One fetch at a time across every task: Chrome's download folder then holds only that fetch's file. */
  serialFetch(work){const run=this.fetchQueue.then(work,work);this.fetchQueue=run.catch(()=>{});return run;}
  /** The copy of the shared profile the other tasks browse in while the person's window is open: made while no Chrome runs on the profile,
   *  without locks and caches. When it can't be made, they wait for the person as before. */
  async makeShadow(){
    await this.dropShadow();
    const dir=this.shadowPath;
    try{
      await rm(dir,{recursive:true,force:true});
      await cp(this.profile,dir,{recursive:true,force:true,errorOnExist:false,verbatimSymlinks:true,filter:src=>src===this.profile||!NOT_COPIED.test(basename(src))});
      await chmod(dir,0o700);this.shadow=dir;
    }catch{await rm(dir,{recursive:true,force:true}).catch(()=>{});this.shadow=null;}
  }
  /** Closes the agents' Chrome on the copy, if it runs there, and removes the copy. What an agent's page did in it is not kept. */
  async dropShadow(){
    const dir=this.shadow;this.shadow=null;
    if(this.contextProfile&&this.contextProfile!==this.profile)await this.closeAutomation();
    if(dir)await rm(dir,{recursive:true,force:true}).catch(()=>{});
  }
  /** A page for `session`: the blank page Chrome opened with, or a new one. */
  async newPage(session){
    const context=await this.ensureContext(session);
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
      // A fetch opens its address and nothing else: a form its page would submit (a POST, or any other method) never leaves Chrome.
      if(navigation&&s.fetching&&request.method()!=='GET'){s.fetching.posted=true;throw Error(POSTED);}
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
    if(!existing&&[...this.sessions.values()].some(s=>s.id!==requester&&!(requester&&s.id.startsWith(requester+':'))&&s.page&&!s.page.isClosed()))throw Error('Another agent is using Buddy’s browser right now. Try again when it has finished, or pause that task.');
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
      // The other tasks browse in a copy of the profile while the window is open; only the task it is for waits for the person.
      if(!existing){this.manualOwner=requester||null;await this.makeShadow();}
      // No debugging connection, automation flags, page scripts, screenshots, or password reads during the handoff. The page opens as the
      // only page Buddy asks for, in a new window; if Chrome restores the person's earlier tabs as it starts, it adds this page to the
      // window it restores last and brings that window to the front with this page showing. Its "Restore pages?" bubble is not shown.
      const child=spawn(this.manualExecutable,[`--user-data-dir=${this.profile}`,'--no-first-run','--no-default-browser-check','--disable-background-mode','--hide-crash-restore-bubble','--new-window',url],{stdio:'ignore'});
      await new Promise((resolve,reject)=>{child.once('spawn',resolve);child.once('error',()=>reject(Error('Could not open private Chrome. Install Google Chrome and try again.')));});
      await new Promise(resolve=>{const timer=setTimeout(resolve,350);child.once('exit',()=>{clearTimeout(timer);resolve();});});
      if((child.exitCode!==null||child.signalCode!==null)&&!await this.profileLock()){if(!existing){await this.dropShadow();this.manualOwner=null;}throw Error('Chrome did not open. Your saved browser data was kept; try opening Chrome again.');}
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
  async finishManual(){const p=this.manualProcess;if(p&&p.exitCode===null&&p.signalCode===null){p.kill('SIGTERM');await Promise.race([new Promise(resolve=>p.once('exit',resolve)),new Promise((_,reject)=>{const t=setTimeout(()=>reject(Error('Close Buddy’s private Chrome window before finishing sign-in.')),8000);t.unref();})]);}this.manualProcess=null;await this.closeManualProfile();
    // Everyone is back on the one profile, with whatever the person signed in to there.
    await this.dropShadow();this.manualOwner=null;
    return {closed:true,url:this.lastURL?.startsWith('https:')?new URL(this.lastURL).origin:null};}
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
    const c=this.context;this.context=null;this.contextProfile=null;
    if(c){const done=Promise.race([c.close().catch(()=>{}),pause(5000)]);this.closing=done;try{await done;}finally{if(this.closing===done)this.closing=null;}}
  }
  async close(){await this.closeAutomation();await this.finishManual();const guard=this.netGuard;this.netGuard=null;await guard?.close();const downloads=this.downloadsDir;this.downloadsDir=null;if(downloads)await rm(downloads,{recursive:true,force:true}).catch(()=>{});}
}

/** One task's page in the shared Chrome: what it observed, what it may act on, and its sign-in requests. */
class BrowserSession {
  constructor(browser,id,scope,account=''){this.browser=browser;this.id=id;this.scope=scope;this.account=account;this.pinned=new Map();this.page=null;this.owned=new Set();this.refs=[];this.snapshot=null;this.prepared=null;this.authPlan=null;this.secretPlanState=null;this.googleFlow=null;this.lastURL=null;this.intendedURL=null;this.blockedNavigation=null;this.sessionRefresh=false;this.sessionRefreshes=0;this.fetching=null;}
  get sharedOrigin(){return this.scope;}
  /** The address a pinned task opens instead of `raw`: the same Google page with its account named (authuser), or null when it needs no
   *  change. `explicit` (an address the agent asked for) also replaces an account given by number (/u/1/), which may be any account; a page
   *  reached by a link or a redirect keeps it, and is checked before anything is done on it. A page Google keeps sending back without the
   *  account is left to that check too, so the two never go round in circles. */
  pinURL(raw,explicit=false,account=this.account){
    if(!account)return null;
    let u;try{u=new URL(raw);}catch{return null;}
    if(!this.browser.isGoogle(u)||this.browser.identityPage(u))return null;
    if(NUMBERED.test(u.pathname)){if(!explicit)return null;u.pathname=u.pathname.replace(NUMBERED,'')||'/';}
    else if((u.searchParams.get('authuser')||'').trim().toLowerCase()===account)return null;
    u.searchParams.set('authuser',account);
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
  async assertAccount({tail=''}={}){
    if(!this.account||!this.page)return;
    const url=this.page.url();if(!this.browser.isGoogle(url)||this.browser.identityPage(url))return;
    // Only a page that clearly shows another account is refused. Many Google pages show none Buddy can read (YouTube, a help page, another
    // language): those go ahead, still opened with the task's account in the address and through the chooser's own tile.
    const seen=await this.pageAccount();
    if(!seen.length||seen.includes(this.account))return;
    throw Error((seen.length===1?otherAccount(seen[0],this.account):`This page shows other accounts (${seen.join(', ')}), not ${this.account}, the account this task must use. Buddy stopped instead of acting on it.`)+tail);
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
    await this.browser.ensureContext(this);
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
  /** The file a step asked the person for, fetched for them once they press Done: with the shared profile's cookies (what they signed in to
   *  in Buddy's Chrome) and through the same network guard as every page, each redirect checked like a page and kept to a delegated
   *  website's scope. Only the file itself is saved, to `dest` (a new `.part` file the Mac app names in the task's own folder), never over
   *  another; a web page in its place (a sign-in form, a CAPTCHA), an error, or a file over the limit is refused and nothing is written.
   *  `expect` 'pdf' also requires a PDF. Nothing is done on a page: the agent's page, if any, is left as it was. */
  async download(url,dest,{expect='',maxBytes=DOWNLOAD_LIMIT}={}){
    if(typeof dest!=='string'||!isAbsolute(dest)||!dest.endsWith('.part'))throw Error('Choose where Buddy saves the download.');
    const limit=Math.min(Number(maxBytes)||DOWNLOAD_LIMIT,DOWNLOAD_LIMIT),{resolver,testOrigins}=this.browser;
    let target=await publicURL(url,resolver,testOrigins);this.assertScope(target);target=this.pinURL(target,true)||target;
    const context=await this.browser.ensureContext(this);
    for(let hop=0;hop<=5;hop++){
      const response=await context.request.get(target,{maxRedirects:0,timeout:60000,failOnStatusCode:false});
      try{
        const status=response.status(),headers=response.headers();
        if(status>=300&&status<400&&headers.location){target=await publicURL(new URL(headers.location,target).href,resolver,testOrigins);this.assertScope(target);continue;}
        if(status<200||status>=300)throw Error(`The website answered ${status} instead of the file. Nothing was saved.`);
        const megabytes=Math.round(limit/1048576);
        if(Number(headers['content-length']||0)>limit)throw Error(`The file is larger than ${megabytes} MB, so Buddy didn't download it.`);
        const body=await response.body(),type=(headers['content-type']||'').split(';')[0].trim().toLowerCase();
        if(body.length>limit)throw Error(`The file is larger than ${megabytes} MB, so Buddy didn't download it.`);
        if(!body.length)throw Error('The website sent an empty file. Nothing was saved.');
        if(webPage(type,body))throw Error('The website sent a web page instead of the file, most likely a sign-in page or a CAPTCHA. Nothing was saved.');
        if(expect==='pdf'&&!body.subarray(0,1024).toString('latin1').includes('%PDF-'))throw Error('The website sent something that is not a PDF. Nothing was saved.');
        await writeFile(dest,body,{flag:'wx',mode:0o600}).catch(error=>{throw error?.code==='EEXIST'?Error('A download is already saved there. Nothing was replaced.'):error;});
        return {saved:true,bytes:body.length,sha256:createHash('sha256').update(body).digest('hex'),contentType:type,origin:new URL(target).origin};
      }finally{await response.dispose().catch(()=>{});}
    }
    throw Error('The website redirected too many times. Nothing was saved.');
  }
  /** buddy_browser_fetch: opens `raw` (GET only) in this task's own page of the shared Chrome, with the person's sign-ins and through the
   *  network guard, and saves the file it gives into `dir` (an absolute folder Buddy chose) as `saveAs` (relative, visible, never over another
   *  file: a number is added). The file is the page's own download, or the address itself when it is a file. Returns a receipt (path, bytes,
   *  type, sha256, the address and where it led), never the page, cookies or headers. A CAPTCHA, a sign-in form or an access check comes
   *  back as `challenge` for the person, and nothing is saved; an ordinary web page is not a file (unless saveAs ends in .html). `account`:
   *  the account an unpinned task names for this file (a pinned task's own always wins). */
  fetch(raw,options={}){return this.browser.serialFetch(()=>this.fetchFile(raw,options));}
  async fetchFile(raw,{dir,saveAs,maxBytes=FETCH_LIMIT,account}={}){
    if(typeof dir!=='string'||!isAbsolute(dir))throw Error('Choose the folder Buddy saves the file in.');
    const parts=savedName(saveAs),limit=Math.min(Number(maxBytes)||FETCH_LIMIT,FETCH_LIMIT);
    try{const st=await lstat(dir);if(!st.isDirectory())throw 0;}catch{throw Error('Choose the folder Buddy saves the file in: it is missing.');}
    let asked;try{asked=new URL(String(raw||''));}catch{throw Error('Give the file’s public http or https address.');}
    if(!['http:','https:'].includes(asked.protocol))throw Error('Buddy fetches only public http and https addresses.');
    const named=pinnedAccount(account);
    if(this.account&&named&&named!==this.account)throw Error(`This task must use ${this.account}, so Buddy won’t fetch as ${named}.`);
    const pin=this.account||named,{resolver,testOrigins}=this.browser;
    let target=await publicURL(asked.href,resolver,testOrigins);this.assertScope(target);target=this.pinURL(target,true,pin)||target;
    await this.ready();
    const page=this.page,downloads=this.browser.downloadsDir,before=new Set(await readdir(downloads).catch(()=>[]));
    let gotDownload;const downloaded=new Promise(r=>{gotDownload=r;});
    const fetching={page,download:null,posted:false,gotDownload};
    this.fetching=fetching;this.snapshot=null;this.refs=[];this.prepared=null;this.blockedNavigation=null;this.intendedURL=target;
    const deadline=Date.now()+this.browser.fetchDeadlineMs,started=Date.now(),site=new URL(target).host;
    const receipt={url:receiptURL(asked.href)};
    const save=download=>this.saveDownload(download,{dir,parts,limit,deadline,before,receipt});
    try{
      let response=null,failed=null;
      try{response=await page.goto(target,{waitUntil:'domcontentloaded',timeout:Math.max(1000,Math.min(45000,deadline-Date.now()))});}catch(error){failed=error;}
      if(fetching.posted)throw Error(POSTED);
      // An address that is itself a download ends its navigation at once ("Download is starting"); the download follows.
      if(!fetching.download&&failed)await Promise.race([downloaded,idle(1500)]);
      if(fetching.download)return await save(fetching.download);
      if(failed){
        if(this.blockedNavigation)throw Error('Website navigation blocked: '+this.blockedNavigation);
        if(this.browser.blockedAt>=started)throw Error('Website navigation blocked: Local and private network pages are unavailable in Buddy’s browser.');
        throw Error(`Buddy couldn’t open ${site}: ${String(failed.message||failed).split('\n')[0].replace(/^page\.goto: /,'').slice(0,200)} Nothing was saved.`);
      }
      const status=response?.status()??0,headers=response?await response.allHeaders().catch(()=>({})):{},type=(headers['content-type']||'').split(';')[0].trim().toLowerCase();
      // The address is a file Chrome shows itself (a PDF, a text or an image): its own body is the file.
      if(response&&type&&!/^(text\/html|application\/xhtml\+xml)$/.test(type)){
        if(status<200||status>=300)throw Error(`The website answered ${status} instead of the file. Nothing was saved.`);
        if(Number(headers['content-length']||0)>limit)throw tooLarge(limit);
        let body=await response.body().catch(()=>null);
        // Chrome shows a PDF in its viewer, and the response is then the viewer's page: the page reads the same address once more, in
        // Chrome itself (the same sign-ins and connection), and hands over its bytes.
        if(!body||webPage(type,body))body=await this.readInPage(page.url(),limit);
        if(!body)throw Error('Buddy couldn’t read the file the website sent. Nothing was saved.');
        if(body.length>limit)throw tooLarge(limit);
        if(!body.length)throw Error('The website sent an empty file. Nothing was saved.');
        if(!webPage(type,body))return await this.saveBody(body,{dir,parts,type,final:page.url(),via:'page',receipt});
      }
      // A web page. A pinned task on Google's account chooser picks its own account (the file may follow).
      if(this.account&&this.browser.identityPage(page.url())){
        const chosen=await this.chooseAccount(page);
        if(chosen==='missing')throw Error(missingAccount(this.account));
        if(chosen==='chosen'){await Promise.race([downloaded,idle(this.browser.downloadWaitMs)]);if(fetching.download)return await save(fetching.download);}
      }
      const challenge=await this.challengeOf(status);
      if(challenge)return this.challenged(challenge,status,receipt);
      // The page's own download (a "your download starts in a moment" page), else an ordinary page.
      await Promise.race([downloaded,idle(Math.max(0,Math.min(this.browser.downloadWaitMs,deadline-Date.now())))]);
      if(fetching.posted)throw Error(POSTED);
      if(fetching.download)return await save(fetching.download);
      const later=await this.challengeOf(status);
      if(later)return this.challenged(later,status,receipt);
      if(/\.html?$/i.test(parts[parts.length-1])&&status>=200&&status<300&&response){
        const body=await response.body().catch(()=>null);
        if(body&&body.length&&body.length<=limit)return await this.saveBody(body,{dir,parts,type:'text/html',final:page.url(),via:'page',receipt});
      }
      if(status>=400)throw Error(`The website answered ${status} instead of the file. Nothing was saved.`);
      throw Error(`${site} sent a web page, not a file, and it isn’t a CAPTCHA or a sign-in page. Nothing was saved. Give the file’s own address (such as the PDF link), or saveAs ending in .html to keep the page itself.`);
    }finally{
      this.fetching=null;
      // A download that was still starting when the fetch ended is not kept.
      if(fetching.download&&!fetching.saved)fetching.download.delete().catch(()=>{});
    }
  }
  /** The bytes at `url`, read by the page itself (GET, with the page's own cookies), in pieces; null when the page can't. */
  async readInPage(url,limit){
    const page=this.page,key='__buddyFetch'+randomUUID().replace(/-/g,'');
    try{
      const got=await page.evaluate(async({url,limit,key})=>{
        const r=await fetch(url,{credentials:'include',method:'GET',redirect:'follow'});
        if(!r.ok)return {status:r.status};
        const data=new Uint8Array(await r.arrayBuffer());
        if(data.length>limit)return {tooLarge:true};
        window[key]=data;return {bytes:data.length};
      },{url,limit,key});
      if(got?.tooLarge)throw tooLarge(limit);
      if(!got||typeof got.bytes!=='number')return null;
      const pieces=[],step=4*1024*1024;
      for(let at=0;at<got.bytes;at+=step)pieces.push(Buffer.from(await page.evaluate(({key,at,step})=>{const part=window[key].subarray(at,at+step);let text='';for(let i=0;i<part.length;i+=32768)text+=String.fromCharCode.apply(null,part.subarray(i,i+32768));return btoa(text);},{key,at,step}),'base64'));
      return Buffer.concat(pieces);
    }catch(error){if(/larger than/.test(error.message))throw error;return null;}
    finally{await page.evaluate(key=>{delete window[key];},key).catch(()=>{});}
  }
  challenged(challenge,status,receipt){
    let final=this.page?.url()||'';try{final=new URL(final).href;}catch{final='';}
    return {saved:false,challenge:{kind:challenge.kind,title:challenge.title,status,url:receipt.url,page:receiptURL(final),origin:final?new URL(final).origin:''}};
  }
  /** What stands between the person and the file on the page now: 'captcha', 'signin' or 'blocked', with the page's title; null for none. */
  async challengeOf(status){
    const info=await this.page.evaluate(()=>{
      const visible=e=>!!(e.offsetWidth||e.offsetHeight||e.getClientRects().length);
      return {title:document.title||'',text:(document.body?.innerText||'').slice(0,5000),
        sources:[...document.querySelectorAll('iframe[src],script[src]')].map(e=>e.getAttribute('src')||'').join(' '),
        widget:!!document.querySelector('.g-recaptcha,.h-captcha,.cf-turnstile,[data-sitekey],#challenge-form,#challenge-stage,#cf-challenge-running,#px-captcha,[id*="captcha" i],[class*="captcha" i]'),
        password:[...document.querySelectorAll('input[type=password]')].some(visible),
        login:/(^|\/)(login|log-in|signin|sign-in|sso|saml|shibboleth|idp|wayf|cas|auth|authenticate|oauth)(\/|$)/i.test(location.pathname)&&!!document.querySelector('input[type=email],input[autocomplete=username],input[name*="user" i],input[name*="email" i]')};
    }).catch(()=>null);
    if(!info)return null;
    const words=info.title+'\n'+info.text;
    const kind=CAPTCHA_SOURCES.test(info.sources)||info.widget||CAPTCHA_WORDS.test(words)?'captcha'
      :info.password||info.login||status===401||SIGNIN_TITLE.test(info.title)?'signin'
      :[401,403,407,429,451,503].includes(status)||BLOCKED_WORDS.test(words)?'blocked':null;
    return kind?{kind,title:info.title.replace(/\s+/g,' ').trim().slice(0,200)}:null;
  }
  /** Writes a new file into `dir` at `parts` (a number added when the name is taken: never over another file), with quarantine and no
   *  execute permission. `write` fills the hidden temporary file it is given. Returns the saved path, relative to `dir`. */
  async place(dir,parts,write){
    let folder=dir;
    for(const name of parts.slice(0,-1)){
      folder=join(folder,name);
      try{const st=await lstat(folder);if(!st.isDirectory()||st.isSymbolicLink())throw Error('A folder on that path is a link or a file. Nothing was saved.');}
      catch(error){if(error.code!=='ENOENT')throw error;await mkdir(folder,{mode:0o755});}
    }
    const temp=join(folder,`.buddy-fetch-${randomUUID()}.part`);
    try{
      await write(temp);await chmod(temp,0o644);await quarantine(temp);
      const name=parts[parts.length-1],ext=extname(name),stem=ext&&ext!==name?name.slice(0,-ext.length):name,suffix=ext&&ext!==name?ext:'';
      for(let n=1;n<=100;n++){
        const candidate=n===1?name:`${stem} (${n})${suffix}`;
        try{await link(temp,join(folder,candidate));return parts.slice(0,-1).concat(candidate).join('/');}
        catch(error){if(error.code!=='EEXIST')throw error;}
      }
      throw Error('That folder already has 100 files with this name. Nothing was saved.');
    }finally{await unlink(temp).catch(()=>{});}
  }
  async saveBody(body,{dir,parts,type,final,via,receipt}){
    const path=await this.place(dir,parts,temp=>writeFile(temp,body,{flag:'wx',mode:0o600}));
    return {saved:true,path,bytes:body.length,sha256:createHash('sha256').update(body).digest('hex'),contentType:type||typeOf(body,parts[parts.length-1]),...receipt,finalURL:receiptURL(final),via};
  }
  /** A fetch's own download: watched while Chrome writes it, stopped as soon as it passes the limit, then copied into place. */
  async saveDownload(download,{dir,parts,limit,deadline,before,receipt}){
    const downloads=this.browser.downloadsDir;let over=false;
    const watch=setInterval(async()=>{
      for(const name of await readdir(downloads).catch(()=>[])){
        if(before.has(name))continue;
        const size=(await stat(join(downloads,name)).catch(()=>null))?.size||0;
        if(size>limit&&!over){over=true;download.cancel().catch(()=>{});}
      }
    },100);
    try{
      let file;
      try{file=await Promise.race([download.path(),idle(Math.max(1000,deadline-Date.now())).then(()=>{throw Error('timeout');})]);}
      catch(error){download.cancel().catch(()=>{});if(over)throw tooLarge(limit);throw Error(error.message==='timeout'?'The download took too long, so Buddy stopped it. Nothing was saved.':'The download didn’t finish. Nothing was saved.');}
      if(over)throw tooLarge(limit);
      const failure=await download.failure().catch(()=>null);if(failure)throw Error(`The download didn’t finish (${failure}). Nothing was saved.`);
      const size=(await stat(file)).size;
      if(size>limit)throw tooLarge(limit);
      if(!size)throw Error('The website sent an empty file. Nothing was saved.');
      const start=await head(file);
      if(webPage('',start)&&!/\.html?$/i.test(parts[parts.length-1]))throw Error('The website sent a web page instead of the file, most likely a sign-in page or a CAPTCHA. Nothing was saved.');
      let sha256='';
      const path=await this.place(dir,parts,async temp=>{await copyFile(file,temp,fsConstants.COPYFILE_EXCL);sha256=await sha256File(temp);});
      if(this.fetching)this.fetching.saved=true;
      return {saved:true,path,bytes:size,sha256,contentType:typeOf(start,download.suggestedFilename()||parts[parts.length-1]),...receipt,finalURL:receiptURL(download.url()),via:'download'};
    }finally{clearInterval(watch);await download.delete().catch(()=>{});}
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
    try{await this.assertAccount();}catch(error){this.snapshot=null;throw error;}
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
      const target=await e.evaluate(e=>({tag:e.tagName.toLowerCase(),type:e.getAttribute('type')||'',label:e.getAttribute('aria-label')||e.labels?.[0]?.textContent||e.getAttribute('placeholder')||e.getAttribute('name')||e.textContent?.trim().slice(0,180)||e.value||'',href:e.tagName==='A'?e.href:undefined,auto:e.getAttribute('autocomplete')||'',name:[e.name,e.id].join(' ')}));
      // Buddy never types payment details or presses a button that pays, subscribes, upgrades or starts a trial.
      if(/^cc-/i.test(target.auto)||/card.?number|cardnumber|\bcvc\b|\bcvv\b|expir(y|ation)|billing|iban|routing number|account number|sort code/i.test(target.label+' '+target.name)||MONEY_ACTIONS.test(target.label))throw Error(NEVER_PAYS);
      if(/sign.?up|create.{0,15}account|\bregister\b/i.test(target.label))throw Error('New accounts are Buddy’s to create, after the user says yes: call buddy_browser_signup. Nothing was done.');
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
    const routine=await this.routineStep(args,targets,changes);
    return this.browser.scrub({token,routine,preview:{name:`Browser: ${args.action}`,service:'Buddy private browser',arguments:{page:this.safeURL(),action:args.action,...(formValues?.length?{formValues}:{}),targets:targets.map(t=>({control:t.label||t.tag,...(t.href?{destination:t.href}:{}),...(args.action==='fill'||args.action==='select'?{value:t.value}:{}),...(args.action==='upload'?{file:args.fileName,bytes:args.bytes,version:args.version}: {})}))}}});
  }
  // What a prepared step does, when it only shows something: one click on a control or link whose words cannot spend, send, submit, delete,
  // start or change anything (a button that submits a form counts only for a search form), or typing into a search box. Empty otherwise.
  async routineStep(args,targets,changes){
    const words=t=>`${t.label||''} ${t.name||''} ${t.href?decodeURIComponent(t.href):''}`;
    if(!targets.length||targets.some(t=>CONSEQUENTIAL.test(words(t))||MONEY_ACTIONS.test(t.label||'')))return '';
    const label=t=>String(t.label||t.tag).replace(/\s+/g,' ').trim().slice(0,60);
    if(args.action==='click'&&targets.length===1){
      const form=await this.refs[Number(changes[0].ref)].evaluate((e,pattern)=>{
        const f=e.closest('form');if(!f)return null;
        const submits=e.tagName==='BUTTON'?(e.getAttribute('type')||'submit').toLowerCase()==='submit':e.tagName==='INPUT'&&['submit','image'].includes((e.getAttribute('type')||'').toLowerCase());
        const search=new RegExp(pattern,'i'),fields=[...f.querySelectorAll('input:not([type=hidden]),textarea,select')];
        return {submits,search:fields.length>0&&fields.every(x=>(x.getAttribute('type')||'').toLowerCase()==='search'||x.getAttribute('role')==='searchbox'||search.test([x.name,x.id,x.getAttribute('aria-label'),x.getAttribute('placeholder')].join(' ')))};
      },SEARCH_FIELD.source);
      if(form?.submits&&!form.search)return '';
      const t=targets[0];
      return form?.submits?`a search on this page (“${label(t)}”)`:t.href?`opening the link “${label(t)}”`:`a click on “${label(t)}”, which only changes what the page shows`;
    }
    if(args.action==='fill'&&targets.every(t=>t.type==='search'||SEARCH_FIELD.test(`${t.label||''} ${t.name||''}`)))return 'typing into a search box';
    return '';
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
    return this.browser.scrub({token,origin:url.origin,mode,accountEmail,filled,googleAvailable:mode==='signin'&&(!!await this.googleButton(this.page,url.origin)||await this.googleBehindSignIn(url.origin)),private:true,...(other?{accountReason:this.wrongSignIn(other)}:{})});
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
  // A link or button that goes from account creation to the existing-account sign-in ("Sign in", "Log in"); a link must stay on the site and
  // lead to a sign-in page. RunPod's is a button.
  async signInControl(page,origin){
    for(const item of await page.locator('a[href],button,[role=button]').all()){
      if(!await item.isVisible().catch(()=>false))continue;
      const label=(await item.innerText().catch(()=>'')).trim();
      if(!/^(?:sign|log)\s?in$/i.test(label))continue;
      const href=await item.getAttribute('href');
      if(href){const u=new URL(href,page.url());if(u.origin!==origin||!/\/(?:sign-in|signin|login)(?:\/|$)/i.test(u.pathname))continue;}
      return item;
    }
    return null;
  }
  // A sign-up page that offers Google and a way to the sign-in page: Google is used from the sign-in page (useGoogle goes there first, and
  // never presses the sign-up page's own Google button). RunPod opens on such a page ("Sign up with Google").
  async googleBehindSignIn(origin){
    if(!/\/(?:sign-up|signup|register)(?:\/|$)/i.test(new URL(this.page.url()).pathname))return false;
    let offered=false;
    for(const item of await this.page.locator('button,a[href],[role=button]').all()){
      if(!await item.isVisible().catch(()=>false))continue;
      const label=await item.evaluate(e=>(e.innerText||e.getAttribute('aria-label')||'').trim().replace(/\s+/g,' ')).catch(()=>'');
      if(/^(?:(?:sign up|continue|sign in|log in)(?: with)? )?google$/i.test(label)){offered=true;break;}
    }
    return offered&&!!await this.signInControl(this.page,origin);
  }
  async useGoogle(origin){
    const root=this.page;let switchedSignIn=false;
    const signup=()=>/\/(?:sign-up|signup|register)(?:\/|$)/i.test(new URL(root.url()).pathname);
    if(signup()){
      // Login must not submit the registration form shown by some sites by default.
      const link=await this.signInControl(root,origin);
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
    // Google, Microsoft and Apple take a typed password or code like any site. Google may still refuse a browser an agent drives.
    if(await this.refusedSignIn())throw Error(GOOGLE_REFUSED);
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
    const codes=candidates.filter(c=>c.kind==='code');let pick=candidates.find(c=>c.kind==='password')||(codes.length===1?codes[0]:null);
    // An email-first sign-in (Google, Microsoft, Apple and many others) asks which account first: the person types it in the chat too.
    if(!pick){
      const users=[];
      for(const e of await this.page.$$('input')){
        const ok=await e.evaluate(e=>{const shown=!!(e.offsetWidth||e.offsetHeight||e.getClientRects().length)&&getComputedStyle(e).visibility!=='hidden';return shown&&!e.disabled&&!e.readOnly&&!['hidden','password','checkbox','radio','submit','button','file'].includes(e.type)&&(e.type==='email'||/username|email/i.test(e.autocomplete)||/identifier|e-?mail|username|login/i.test([e.name,e.id].join(' ')));}).catch(()=>false);
        if(ok)users.push(e);
      }
      if(users.length===1)pick={e:users[0],kind:'username'};
    }
    if(!pick)return {field:null,origin:url.origin,waiting:privacy.private};
    // A sign-in form whose email (or username) field is still empty asks for both: the person types both in the chat (the task's account
    // already in the email field), or Buddy fills both from a remembered sign-in.
    let user=null;
    if(pick.kind==='password'){
      const empty=[];
      for(const e of await this.page.$$('input')){
        const ok=await e.evaluate((e,field)=>{const shown=!!(e.offsetWidth||e.offsetHeight||e.getClientRects().length)&&getComputedStyle(e).visibility!=='hidden';return shown&&!e.disabled&&!e.readOnly&&!e.value&&e.form===field.form&&!['hidden','password','checkbox','radio','submit','button','file'].includes(e.type)&&(e.type==='email'||/username|email/i.test(e.autocomplete)||/identifier|e-?mail|user|login/i.test([e.name,e.id,e.getAttribute('aria-label'),e.labels?.[0]?.innerText].join(' ')));},pick.e).catch(()=>false);
        if(ok)empty.push(e);
      }
      if(empty.length===1)user=empty[0];
    }
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
    this.secretPlanState={token,origin:url.origin,field:pick.e,kind:user?'login':pick.kind,user,button,signature:await this.formSignature(),created:Date.now()};
    if(pick.kind==='username')return this.browser.scrub({token,origin:url.origin,field:'username',account:null,private:true});
    if(user)return this.browser.scrub({token,origin:url.origin,field:'login',account:this.account||null,private:true});
    return this.browser.scrub({token,origin:url.origin,field:pick.kind,account:account||null,private:true});
  }
  /** Types what the person sent into the field the token was made for, and submits it, once. It is remembered only to keep it out of
   *  every observation and every request to another site. */
  async fillSecret(token,value,{username}={}){
    const plan=this.secretPlanState;this.secretPlanState=null;
    if(!plan||typeof token!=='string'||plan.token!==token)throw Error('This sign-in request was already used or replaced. Nothing was typed.');
    if(typeof value!=='string'||!value.length||value.length>1000||/[\0\r\n]/.test(value))throw Error('Type the password or code on one line, up to 1,000 characters. Nothing was typed.');
    if(!this.page||this.page.isClosed()||new URL(this.page.url()).origin!==plan.origin||await this.formSignature().catch(()=>'')!==plan.signature)throw Error('The sign-in page changed. Nothing was typed.');
    if(Date.now()-plan.created>this.browser.secretTTLms)throw Error('This sign-in request expired. Nothing was typed.');
    if(!await plan.field.isVisible().catch(()=>false)||!await plan.field.isEnabled().catch(()=>false))throw Error('The sign-in page changed. Nothing was typed.');
    if(this.otherSignIn(await this.username()))throw Error('The sign-in page now names another account. Nothing was typed.');
    // The account typed for an email-first sign-in: a pinned task's own, never another. It is not a secret (it is in every Google address
    // of a pinned task), so it is not kept out of what agents see.
    if(plan.kind==='username'){if(this.account&&value.trim().toLowerCase()!==this.account)throw Error(`This task must use ${this.account}. Type that account, or choose it in Buddy’s Chrome window. Nothing was typed.`);}
    else this.browser.remember(value,plan.origin);
    // Both fields: the account (a pinned task's own, never another) and the password.
    let user='';
    if(plan.kind==='login'){
      user=typeof username==='string'?username.trim():'';
      if(!user||user.length>254||/[\0\r\n]/.test(user))throw Error('Type the email or username too. Nothing was typed.');
      if(this.account&&user.toLowerCase()!==this.account)throw Error(`This task must use ${this.account}. Type that account. Nothing was typed.`);
      if(!await plan.user.isVisible().catch(()=>false)||!await plan.user.isEnabled().catch(()=>false))throw Error('The sign-in page changed. Nothing was typed.');
    }
    this.snapshot=null;
    try{
      if(user)await plan.user.fill(user);
      await plan.field.fill(value);
      await afterSubmit(this.page,()=>plan.button?plan.button.click({timeout:12000}):plan.field.press('Enter'));
    }catch{throw Error('The sign-in step did not return a confirmed result. Look at the page before trying again.');}
    return await this.outcome();
  }
  // Signed in when the page no longer asks for anything private. Otherwise: what can be typed next (a fresh token), or nothing to type.
  async outcome(){
    // Google refused the sign-in because an agent drives this browser: the person finishes it in Buddy's Chrome window.
    if(await this.refusedSignIn())return {signedIn:false,next:null,waiting:false,kind:'signin',needsChrome:true,reason:GOOGLE_REFUSED};
    // A page that is still loading has no document to look at yet: look again in a moment.
    let privacy;for(let i=0;;i++){try{privacy=await this.privacy();break;}catch(error){if(i>=4||!this.page||this.page.isClosed())throw error;await pause(300);}}
    if(!privacy.private){this.snapshot=null;return {signedIn:true,performed:true,page:await this.readPage()};}
    let next=null,reason='';
    try{next=await this.planSecret();}catch(error){reason=String(error.message||error);}
    if(next?.token)return {signedIn:false,next:{token:next.token,field:next.field,origin:next.origin,account:next.account},kind:privacy.kind};
    return {signedIn:false,next:null,waiting:true,kind:privacy.kind,...(reason?{needsChrome:true,reason}:{})};
  }
  /** Whether this page is an identity provider's own "this browser or app may not be secure" refusal. */
  async refusedSignIn(){
    let u;try{u=new URL(this.page.url());}catch{return false;}
    if(!identityProvider(u.hostname)&&!this.browser.isGoogle(u)&&!this.browser.identityPage(u))return false;
    return await this.page.evaluate(()=>/this browser or app may not be secure|try using a different browser|couldn[’']t sign you in/i.test(document.title+' '+(document.body?.innerText||'').slice(0,3000))).catch(()=>false);
  }
  // MARK: accounts Buddy creates for the person, their forgotten passwords, and never paying

  /** Whether the page asks for money: payment details (card fields, a payment provider's frame, Apple Pay / Google Pay / PayPal buttons,
   *  "card number", "billing address") or a trial that becomes paid / a paid plan ("free trial", "then $12", "/month", "choose a plan",
   *  "checkout", a Subscribe or Upgrade button). The words of an optional checkbox (a newsletter Buddy never ticks) don't count. Returns
   *  {kind: 'payment'|'trial', what} or null. */
  async moneySignals(page=this.page){
    const info=await page.evaluate(()=>{
      const visible=e=>!!(e.offsetWidth||e.offsetHeight||e.getClientRects().length);
      const text=x=>String(x||'').replace(/\s+/g,' ').trim();
      const labelOf=e=>text(e.labels?.[0]?.innerText)||text(e.getAttribute('aria-label'))||text(e.closest('label')?.innerText)||text(e.placeholder);
      const fields=[...document.querySelectorAll('input,select')].filter(e=>visible(e)&&e.type!=='hidden'&&e.type!=='checkbox');
      const card=fields.some(e=>/^cc-/i.test(e.getAttribute('autocomplete')||'')||/card.?number|cardnumber|\bcvc\b|\bcvv\b|expir(y|ation) date|billing.?(address|zip|postal)/i.test([e.name,e.id,e.placeholder,e.getAttribute('aria-label'),labelOf(e)].join(' ')));
      const frames=[...document.querySelectorAll('iframe')].map(f=>{try{return new URL(f.getAttribute('src')||'about:blank',location.href).hostname;}catch{return '';}}).filter(Boolean);
      const wallet=[...document.querySelectorAll('apple-pay-button,google-pay-button,gpay-button,[class*="apple-pay" i],[class*="applepay" i],[class*="gpay" i],[class*="google-pay" i],[id*="paypal" i],[class*="paypal-button" i]')].some(visible);
      let words=(document.title||'')+'\n'+(document.body?.innerText||'').slice(0,20000);
      for(const box of document.querySelectorAll('input[type=checkbox]'))if(!box.required&&box.getAttribute('aria-required')!=='true'){const l=labelOf(box);if(l)words=words.split(l).join(' ');}
      const actions=[...document.querySelectorAll('button,input[type=submit],input[type=button],[role=button],a[href]')].filter(visible).map(e=>text(e.innerText||e.value||e.getAttribute('aria-label'))).filter(Boolean).slice(0,200);
      const headings=[...document.querySelectorAll('h1,h2,h3')].filter(visible).map(e=>text(e.innerText)).slice(0,40);
      return {card,frames,wallet,words,actions,headings};
    }).catch(()=>null);
    if(!info)return null;
    const said=(re,text)=>{const m=re.exec(text);return m?m[0].trim():'';};
    if(info.card)return {kind:'payment',what:'card details'};
    if(info.frames.some(h=>PAYMENT_FRAMES.test(h)))return {kind:'payment',what:'a payment provider’s card form'};
    if(info.wallet)return {kind:'payment',what:'a payment button'};
    let w=said(PAYMENT_WORDS,info.words);if(w)return {kind:'payment',what:w};
    w=said(TRIAL_WORDS,info.words)||info.actions.map(a=>said(/start (my |your |a )?(free )?trial/i,a)).find(Boolean)||'';if(w)return {kind:'trial',what:w};
    w=said(PLAN_WORDS,info.words);if(w)return {kind:'payment',what:w};
    w=[...info.actions,...info.headings].map(a=>said(MONEY_ACTIONS,a)).find(Boolean)||'';if(w)return {kind:'payment',what:w};
    return null;
  }
  /** Whether the page shows a CAPTCHA (its frames, its widgets, its words). */
  async captchaShown(){
    const info=await this.page.evaluate(()=>({sources:[...document.querySelectorAll('iframe[src],script[src]')].map(e=>e.getAttribute('src')||'').join(' '),
      widget:!!document.querySelector('.g-recaptcha,.h-captcha,.cf-turnstile,[data-sitekey],#challenge-form,#px-captcha,[id*="captcha" i],[class*="captcha" i]'),
      words:(document.title||'')+'\n'+(document.body?.innerText||'').slice(0,5000)})).catch(()=>null);
    return !!info&&(CAPTCHA_SOURCES.test(info.sources)||info.widget||CAPTCHA_WORDS.test(info.words));
  }
  /** The page's visible controls, with what Buddy needs to know of each: kind, label, whether required, which form. Never a password's value. */
  async controlsOf(){
    const out=[];
    for(const e of await this.page.$$('input,select,textarea,button,a[href],[role=button]')){
      const d=await e.evaluate(e=>{
        const text=x=>String(x||'').replace(/\s+/g,' ').trim();
        const shown=x=>!!x&&!!(x.offsetWidth||x.offsetHeight||x.getClientRects().length)&&getComputedStyle(x).visibility!=='hidden';
        const tag=e.tagName.toLowerCase(),type=(e.getAttribute('type')||(tag==='button'?'submit':'')).toLowerCase();
        const holder=e.labels?.[0]||e.closest('label');
        // A styled checkbox hides its own box and shows its label.
        const visible=shown(e)||(type==='checkbox'||type==='radio')&&shown(holder);
        if(!visible||type==='hidden')return null;
        const by=e.getAttribute('aria-labelledby');
        const pressable=tag==='button'||tag==='a'||e.getAttribute('role')==='button'||['submit','button'].includes(type);
        const label=(pressable?text(e.innerText||e.value||e.getAttribute('aria-label')):'')||text(holder?.innerText)||text(by&&by.split(/\s+/).map(id=>document.getElementById(id)?.innerText).join(' '))||text(e.getAttribute('aria-label'))||text(e.placeholder)||text(e.name||e.id);
        return {tag,type,auto:(e.getAttribute('autocomplete')||'').toLowerCase(),name:e.name||'',id:e.id||'',label:label.slice(0,240),required:!!e.required||e.getAttribute('aria-required')==='true',
          enabled:!e.disabled&&!e.readOnly,checked:!!e.checked,empty:!e.value,form:e.form?[...document.forms].indexOf(e.form):-1,href:tag==='a'?e.href:'',pressable,submit:pressable&&tag!=='a'&&(type==='submit'||tag==='input'&&type==='image')};
      }).catch(()=>null);
      if(d)out.push({...d,e});
    }
    return out;
  }
  /** The sign-up form on this page, or on the site's own sign-up page a link here leads to (followed once): its email and new-password
   *  fields, the required standard terms Buddy ticks, the optional boxes it leaves, other required fields filled from `details` (what the
   *  person told the agent, by label) or named as missing, its CAPTCHA and its money signals. Nothing is typed or sent. The token is for one
   *  `signup` on this very form within ten minutes. */
  signupPlan(options){return this.guard(()=>this.planSignup(options));}
  async planSignup({email,details}={},followed=false){
    const {resolver,testOrigins}=this.browser;
    await this.ready();this.assertScope();this.signupState=null;
    const url=new URL(await publicURL(this.page.url(),resolver,testOrigins));
    if(url.protocol!=='https:'&&!this.browser.isTestOrigin(url.origin))throw Error('Buddy creates accounts only on secure (https) pages. Nothing was created.');
    if(identityProvider(url.hostname)||this.browser.isGoogle(url))throw Error('Buddy doesn’t create Google, Microsoft or Apple accounts. Nothing was created.');
    const named=pinnedAccount(email||'')||'';
    if(this.account&&named&&named!==this.account)throw Error(`This task must use ${this.account}, so Buddy won’t create an account as ${named}. Nothing was created.`);
    const all=await this.controlsOf();
    const passwords=all.filter(c=>c.tag==='input'&&c.type==='password'&&c.enabled);
    const signupWords=/sign.?up|register|join|create|new account|get started/i;
    const newForm=passwords.some(c=>c.auto==='new-password')||passwords.length>=2;
    if(!passwords.length||!newForm&&!signupWords.test(url.pathname+' '+await this.page.title())){
      // A sign-in page that offers sign-up: Buddy follows its own link once.
      const link=all.find(c=>c.tag==='a'&&/sign.?up|create (an |your |new )?account|register|join( now| us)?|new (user|here|account)/i.test(c.label)&&!NOT_CREATE.test(c.label)&&(()=>{try{return new URL(c.href).origin===url.origin;}catch{return false;}})());
      if(link&&!followed){this.snapshot=null;await afterSubmit(this.page,()=>link.e.click({timeout:12000}));return this.planSignup({email,details},true);}
      return {found:false,origin:url.origin,reason:'There is no sign-up form on this page.'};
    }
    const form=passwords[0].form,inForm=c=>form<0||c.form===form;
    const fields=all.filter(inForm);
    const isEmail=c=>c.tag==='input'&&['email','text',''].includes(c.type)&&(c.type==='email'||/email|username/.test(c.auto)||/e-?mail/i.test(c.label+' '+c.name+' '+c.id));
    const emails=fields.filter(c=>isEmail(c)&&c.enabled);
    const given=Object.entries(details&&typeof details==='object'?details:{}).filter(([k,v])=>typeof k==='string'&&typeof v==='string'&&k.trim()&&v.trim()&&k.length<=80&&v.length<=200&&!/[\0\r\n]/.test(v)).slice(0,12);
    const words=k=>k.replace(/([a-z])([A-Z])/g,'$1 $2').toLowerCase().replace(/[^a-z0-9]+/g,' ').trim();
    const detailFor=label=>{const l=words(label);let best=null;for(const [k,v] of given){const w=words(k);if(w&&(l.includes(w)||w.includes(l)&&l.length>=3)&&(!best||w.length>best[0].length))best=[w,v];}return best?.[1]??null;};
    const missing=[],fills=[],terms=[],optional=[];let money=null;
    if(!emails.length)missing.push('Email');
    for(const c of fields){
      if(passwords.includes(c)||emails.includes(c)||c.pressable||!c.enabled)continue;
      if(c.type==='checkbox'){
        const required=c.required||/\*\s*$/.test(c.label);
        if(MONEY_BOX.test(c.label)){if(required||TERMS.test(c.label))money={kind:'payment',what:c.label.slice(0,120)};else optional.push(c.label);continue;}
        if(MARKETING.test(c.label)&&!required){optional.push(c.label);continue;}
        if(TERMS.test(c.label)&&!MARKETING.test(c.label)){terms.push(c);continue;}
        if(required)missing.push(c.label);else optional.push(c.label);
        continue;
      }
      if(c.type==='radio'||c.type==='file'){if(c.required)missing.push(c.label||c.name);continue;}
      if(!c.empty)continue;
      const value=detailFor(c.label||c.name);
      if(value!==null){fills.push({c,value});continue;}
      const phone=c.type==='tel'||/^tel/.test(c.auto)||/phone|mobile/i.test(c.label+' '+c.name);
      if(c.required||/\*\s*$/.test(c.label))missing.push(phone?'Phone number':c.label.replace(/\s*\*\s*$/,'')||c.name);
    }
    const submit=fields.find(c=>c.submit&&c.enabled&&CREATE_BUTTON.test(c.label)&&!NOT_CREATE.test(c.label))||null;
    if(!submit)missing.push('the button that creates the account');
    money=money||await this.moneySignals();
    const captcha=await this.captchaShown();
    const token=randomUUID();
    this.signupState={token,origin:url.origin,emails:emails.map(c=>c.e),passwords:passwords.filter(inForm).map(c=>c.e),terms:terms.map(c=>c.e),fills:fills.map(f=>({e:f.c.e,tag:f.c.tag,value:f.value})),submit:submit?.e,signature:await this.formSignature(),created:Date.now()};
    return this.browser.scrub({found:true,token,origin:url.origin,ready:!missing.length,missing:[...new Set(missing)],terms:terms.map(c=>c.label),optional,fills:fills.map(f=>f.c.label.replace(/\s*\*\s*$/,'')),captcha,money,page:this.safeURL()});
  }
  /** Creates the account the person said yes to: the task's email in every email field, Buddy's password in every new-password field (it
   *  joins the secrets kept out of everything an agent sees and every request to another site), the planned details, the required standard
   *  terms ticked, then the form's own button. Stops before sending on a payment or trial signal or a CAPTCHA. What came of it: created (and
   *  what the site asks next: a link or a code in the email, a code by text), not created (the site's message, an account that exists). */
  signup(token,options){return this.guard(()=>this.createAccount(token,options));}
  async createAccount(token,{email,password,details}={}){
    const plan=this.signupState;this.signupState=null;
    if(!plan||typeof token!=='string'||plan.token!==token)throw Error('This sign-up request was already used or replaced. Ask again; nothing was sent.');
    if(Date.now()-plan.created>600000)throw Error('This sign-up request expired. Ask again; nothing was sent.');
    if(!this.page||this.page.isClosed()||new URL(this.page.url()).origin!==plan.origin||await this.formSignature().catch(()=>'')!==plan.signature)throw Error('The sign-up page changed. Ask again; nothing was sent.');
    const named=pinnedAccount(email);
    if(!named)throw Error('Choose the email address for the new account. Nothing was sent.');
    if(this.account&&named!==this.account)throw Error(`This task must use ${this.account}, so Buddy won’t create an account as ${named}. Nothing was sent.`);
    if(!goodPassword(password))throw Error('Buddy needs a strong new password for this account. Nothing was sent.');
    const money=await this.moneySignals();if(money)return {created:false,money,page:receiptURL(this.page.url())};
    if(await this.captchaShown())return {created:false,captcha:true,page:receiptURL(this.page.url())};
    this.browser.remember(password,plan.origin);
    this.snapshot=null;
    for(const e of plan.emails)await e.fill(named);
    for(const e of plan.passwords)await e.fill(password);
    for(const f of plan.fills){if(f.tag==='select')await f.e.selectOption({label:f.value}).catch(()=>f.e.selectOption(f.value));else await f.e.fill(f.value);}
    for(const e of plan.terms)if(!await e.isChecked().catch(()=>false))await e.check({force:true}).catch(()=>e.evaluate(x=>x.click()));
    // Typing can reveal a price or a card form: checked again before the button.
    const later=await this.moneySignals();
    if(later){for(const e of plan.passwords)await e.fill('').catch(()=>{});return {created:false,money:later,page:receiptURL(this.page.url())};}
    if(!plan.submit)throw Error('Buddy couldn’t find the button that creates the account. Nothing was sent.');
    await afterSubmit(this.page,()=>plan.submit.click({timeout:12000}));
    return await this.accountOutcome(plan.origin);
  }
  /** What a sign-up's button led to. */
  async accountOutcome(origin){
    let info=null;
    for(let i=0;i<5&&!info;i++){info=await this.page.evaluate(()=>{
      const shown=e=>!!(e.offsetWidth||e.offsetHeight||e.getClientRects().length);
      const text=x=>String(x||'').replace(/\s+/g,' ').trim();
      const errors=[...document.querySelectorAll('[role=alert],.error,.errors,.invalid-feedback,.field-error,[aria-live]')].filter(shown).map(e=>text(e.innerText)).filter(Boolean);
      return {title:document.title||'',text:(document.body?.innerText||'').slice(0,6000),errors,newPasswords:[...document.querySelectorAll('input[type=password]')].filter(e=>shown(e)&&(e.autocomplete==='new-password'||document.querySelectorAll('input[type=password]').length>1)).length,
        code:[...document.querySelectorAll('input')].some(e=>shown(e)&&(e.autocomplete==='one-time-code'||/verification.?code|one.?time|\botp\b|security.?code|confirmation.?code/i.test([e.name,e.id,e.getAttribute('aria-label'),e.labels?.[0]?.innerText,e.placeholder].join(' '))))};
    }).catch(()=>null);if(!info)await pause(300);}
    if(!info)return {created:false,unknown:true,error:'The site didn’t show what happened.'};
    const words=info.title+'\n'+info.text,page=receiptURL(this.page.url());
    // "Already have an account? Sign in" is a link on many pages, so only the form shown again counts it; a page of its own must say it exists.
    const exists=/already (exists|registered|in use|taken)|account (with|for) (this|that) e-?mail/i.test(words);
    if(await this.captchaShown())return {created:false,captcha:true,page};
    if(info.newPasswords){
      const said=info.errors[0]||(words.split('\n').map(text=>text.trim()).find(l=>/error|invalid|already|must|required|too (short|weak|common)|match|please/i.test(l))||'');
      return this.browser.scrub({created:false,exists:exists||/already have an account/i.test(said),error:said.slice(0,300)||'The site didn’t take the sign-up.',page});
    }
    if(exists)return {created:false,exists:true,page};
    const money=await this.moneySignals();if(money)return {created:true,money,page};
    if(info.code){
      const channel=/\btext(ed)?\b|\bsms\b|phone|mobile/i.test(words)?'sms':'email';
      let next=null;try{const p=await this.planSecret();if(p?.token&&p.field==='code')next={token:p.token,field:'code',origin:p.origin};}catch{}
      return {created:true,verify:'code',channel,next,page};
    }
    if(/check your (e-?mail|inbox)|confirm(ation)? (link|e-?mail)|confirm your e-?mail|verify your e-?mail|we('ve| have)? (just )?(sent|e-?mailed)|activation (link|e-?mail)|activate your account/i.test(words))return {created:true,verify:'link',page};
    const privacy=await this.privacy();
    return {created:true,signedIn:!privacy.private,page,...(privacy.private?{}:{view:await this.readPage()})};
  }
  /** Opens a link from the person's email (a confirmation or a password reset) in this task's page: only a link to the same site as the page
   *  the task is on. */
  openLink(raw){return this.guard(()=>this.openMailLink(raw));}
  async openMailLink(raw){
    await this.ready();
    let u;try{u=new URL(String(raw||''));}catch{throw Error('That isn’t a link Buddy can open.');}
    if(u.protocol!=='https:'&&!this.browser.isTestOrigin(u.origin))throw Error('Buddy opens only secure (https) links from an email.');
    let here;try{here=new URL(this.page.url()!=='about:blank'?this.page.url():this.lastURL);}catch{throw Error('Buddy doesn’t know which website this task is on, so it didn’t open the link.');}
    if(siteOf(u.hostname)!==siteOf(here.hostname))throw Error('The link in the email leads to another website, so Buddy didn’t open it.');
    await this.navigatePage(u.href);
    const money=await this.moneySignals(),privacy=await this.privacy();
    return {opened:true,private:privacy.private,kind:privacy.kind,...(money?{money}:{}),page:privacy.private?{url:new URL(this.page.url()).origin,title:'Private sign-in'}:await this.readPage()};
  }
  /** On a sign-in page: the site's own "Forgot password?" link, for a reset the person said yes to. */
  resetPlan(){return this.guard(()=>this.planReset());}
  async planReset(){
    const {resolver,testOrigins}=this.browser;
    await this.ready();this.assertScope();this.resetState=null;
    const url=new URL(await publicURL(this.page.url(),resolver,testOrigins));
    if(url.protocol!=='https:'&&!this.browser.isTestOrigin(url.origin)||identityProvider(url.hostname)||this.browser.isGoogle(url))return {available:false,origin:url.origin};
    const link=(await this.controlsOf()).find(c=>c.pressable&&c.enabled&&RESET_LINK.test(c.label)&&(!c.href||(()=>{try{return new URL(c.href).origin===url.origin;}catch{return false;}})()));
    if(!link)return {available:false,origin:url.origin};
    const token=randomUUID();this.resetState={token,origin:url.origin,link:link.e,signIn:this.page.url(),created:Date.now()};
    return this.browser.scrub({available:true,token,origin:url.origin,signInURL:this.page.url()});
  }
  /** Asks the site to email a reset link to `email` (the task's account): its Forgot password link, its email field, its own button. */
  resetStart(token,options){return this.guard(()=>this.startReset(token,options));}
  async startReset(token,{email}={}){
    const plan=this.resetState;this.resetState=null;
    if(!plan||typeof token!=='string'||plan.token!==token||Date.now()-plan.created>600000)throw Error('This reset request was already used or expired. Nothing was sent.');
    const named=pinnedAccount(email);if(!named)throw Error('Choose the account’s email address. Nothing was sent.');
    if(this.account&&named!==this.account)throw Error(`This task must use ${this.account}. Nothing was sent.`);
    if(!this.page||new URL(this.page.url()).origin!==plan.origin)throw Error('The sign-in page changed. Nothing was sent.');
    this.snapshot=null;
    await afterSubmit(this.page,()=>plan.link.click({timeout:12000}));
    if(new URL(this.page.url()).origin!==plan.origin&&siteOf(new URL(this.page.url()).hostname)!==siteOf(new URL(plan.origin).hostname))throw Error('The reset page is on another website, so Buddy stopped. Nothing was sent.');
    const money=await this.moneySignals();if(money)return {requested:false,money,page:receiptURL(this.page.url())};
    if(await this.captchaShown())return {requested:false,captcha:true,page:receiptURL(this.page.url())};
    const all=await this.controlsOf();
    const field=all.find(c=>c.tag==='input'&&c.enabled&&['email','text',''].includes(c.type)&&(c.type==='email'||/email|username/.test(c.auto)||/e-?mail|username/i.test(c.label+' '+c.name)));
    if(!field)return {requested:false,reason:'The reset page doesn’t ask for an email address.',page:receiptURL(this.page.url())};
    const button=all.find(c=>c.submit&&c.enabled&&(field.form<0||c.form===field.form)&&RESET_BUTTON.test(c.label)&&!NOT_CREATE.test(c.label));
    if(!button)return {requested:false,reason:'Buddy couldn’t find the reset page’s button.',page:receiptURL(this.page.url())};
    await field.e.fill(named);
    await afterSubmit(this.page,()=>button.e.click({timeout:12000}));
    if(await this.captchaShown())return {requested:false,captcha:true,page:receiptURL(this.page.url())};
    const words=await this.page.evaluate(()=>(document.title||'')+'\n'+(document.body?.innerText||'').slice(0,4000)).catch(()=>'');
    if(/no account|not found|doesn['’]t exist|couldn['’]t find|isn['’]t registered|unknown e-?mail/i.test(words))return {requested:false,noAccount:true,page:receiptURL(this.page.url())};
    return {requested:true,page:receiptURL(this.page.url())};
  }
  /** On the page a reset link opened: Buddy's new password in its new-password fields, then its own button. */
  resetFinish(options){return this.guard(()=>this.finishReset(options));}
  async finishReset({password}={}){
    const {resolver,testOrigins}=this.browser;
    await this.ready();this.assertScope();
    const url=new URL(await publicURL(this.page.url(),resolver,testOrigins));
    if(url.protocol!=='https:'&&!this.browser.isTestOrigin(url.origin))throw Error('Buddy sets passwords only on secure (https) pages. Nothing was sent.');
    if(!goodPassword(password))throw Error('Buddy needs a strong new password. Nothing was sent.');
    const all=await this.controlsOf(),fields=all.filter(c=>c.tag==='input'&&c.type==='password'&&c.enabled);
    if(!fields.length)return {changed:false,reason:'This page doesn’t ask for a new password.'};
    if(fields.length>2)return {changed:false,reason:'This page asks for more than a new password. The user does it in Buddy’s Chrome window.'};
    const money=await this.moneySignals();if(money)return {changed:false,money,page:receiptURL(this.page.url())};
    if(await this.captchaShown())return {changed:false,captcha:true,page:receiptURL(this.page.url())};
    const form=fields[0].form,button=all.find(c=>c.submit&&c.enabled&&(form<0||c.form===form)&&RESET_BUTTON.test(c.label)&&!NOT_CREATE.test(c.label));
    if(!button)return {changed:false,reason:'Buddy couldn’t find the button that saves the new password.'};
    this.browser.remember(password,url.origin);this.snapshot=null;
    for(const f of fields)await f.e.fill(password);
    await afterSubmit(this.page,()=>button.e.click({timeout:12000}));
    const still=await this.page.evaluate(()=>[...document.querySelectorAll('input[type=password]')].filter(e=>!!(e.offsetWidth||e.offsetHeight)).length>1||[...document.querySelectorAll('input[autocomplete=new-password]')].some(e=>!!(e.offsetWidth||e.offsetHeight))).catch(()=>false);
    if(still)return this.browser.scrub({changed:false,reason:'The site didn’t take the new password.',page:receiptURL(this.page.url())});
    return {changed:true,page:receiptURL(this.page.url())};
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
  const pageCommands={download:(s,r)=>s.download(r.url,r.to,{expect:typeof r.expect==='string'?r.expect:'',maxBytes:r.maxBytes}),fetch:(s,r)=>s.fetch(r.url,{dir:r.dir,saveAs:r.saveAs,maxBytes:r.maxBytes,account:typeof r.fetchAccount==='string'?r.fetchAccount:''}),open:(s,r)=>s.navigate(r.url),read:s=>s.read(),prepare:(s,r)=>s.prepare(r.arguments),commit:(s,r)=>s.commit(r.token,r.upload),prepareSignIn:(s,r)=>s.prepareSignIn(r.mode),useSaved:(s,r)=>s.useSaved(r.token),verificationPlan:s=>s.verificationPlan(),verifyEmail:(s,r)=>s.verifyEmail(r.token,r.code),secretPlan:s=>s.secretPlan(),fillSecret:(s,r)=>s.fillSecret(r.token,r.value,{username:typeof r.username==='string'?r.username:undefined}),
    // Accounts Buddy creates after the person's yes, links from their email, and forgotten passwords. The password comes from the Mac app only.
    signupPlan:(s,r)=>s.signupPlan({email:typeof r.email==='string'?r.email:'',details:r.details&&typeof r.details==='object'?r.details:{}}),signup:(s,r)=>s.signup(r.token,{email:r.email,password:r.password}),
    openLink:(s,r)=>s.openLink(r.url),resetPlan:s=>s.resetPlan(),resetStart:(s,r)=>s.resetStart(r.token,{email:r.email}),resetFinish:(s,r)=>s.resetFinish({password:r.password}),recheck:(s,r)=>s.recheck({reload:r.reload===true,url:typeof r.url==='string'?r.url:''})};
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

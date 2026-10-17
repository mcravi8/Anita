import {chromium} from 'playwright-core';
import {lookup} from 'node:dns/promises';
import {isIP} from 'node:net';
import {randomUUID, createHash} from 'node:crypto';
import {mkdir, chmod} from 'node:fs/promises';
import {resolve} from 'node:path';
import {createInterface} from 'node:readline';
import {pathToFileURL} from 'node:url';
import {realpathSync,lstatSync} from 'node:fs';
import {spawn} from 'node:child_process';

export function publicAddress(ip) {
  if (isIP(ip) === 4) {
    const [a,b,c] = ip.split('.').map(Number);
    return !(a===0||a===10||a===127||a>=224||a===169&&b===254||a===172&&b>=16&&b<=31||a===192&&(b===168||b===0&&[0,2].includes(c))||a===100&&b>=64&&b<=127||a===198&&([18,19].includes(b)||b===51&&c===100)||a===203&&b===0&&c===113);
  }
  if(isIP(ip)===6) return /^2[0-9a-f]{3}:/i.test(ip)&&!ip.toLowerCase().startsWith('2001:db8:');
  return false;
}
export async function publicURL(raw, resolver=lookup, testOrigin='') {
  const url=new URL(raw);
  if(!['https:','http:'].includes(url.protocol)||url.username||url.password) throw Error('Only public HTTP and HTTPS pages are supported.');
  if(testOrigin && url.origin===testOrigin)return url.href;
  const host=url.hostname.replace(/^\[|\]$/g,'');
  if(host==='localhost'||host.endsWith('.localhost')||host.endsWith('.local')||host.endsWith('.internal'))throw Error('Local and private network pages are unavailable in Buddy’s browser.');
  const addresses=isIP(host)?[{address:host}]:await resolver(host,{all:true});
  if(!addresses.length||addresses.some(x=>!publicAddress(x.address)))throw Error('Local and private network pages are unavailable in Buddy’s browser.');
  return url.href;
}
const hash=x=>createHash('sha256').update(JSON.stringify(x)).digest('hex');
export class PrivateBrowser {
  constructor(profile,{testOrigin='',manualExecutable='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'}={}) {this.profile=resolve(profile);this.testOrigin=testOrigin;this.manualExecutable=manualExecutable;this.context=null;this.page=null;this.refs=[];this.snapshot=null;this.prepared=null;this.authPlan=null;this.manualProcess=null;this.lastURL=null;this.secrets=new Set();this.secretOrigins=new Map();}
  async launch(headed=false) {
    if(this.manualProcess&&this.manualProcess.exitCode===null&&this.manualProcess.signalCode===null)throw Error('Private sign-in is open. Finish it in Buddy before resuming automated work.');
    await this.closeAutomation(); await mkdir(this.profile,{recursive:true,mode:0o700});await chmod(this.profile,0o700);
    // Use Chrome's real encrypted profile, never Playwright's mock Keychain/basic password store.
    this.context=await chromium.launchPersistentContext(this.profile,{channel:'chrome',headless:!headed,chromiumSandbox:true,acceptDownloads:false,permissions:[],serviceWorkers:'block',ignoreDefaultArgs:['--password-store=basic','--use-mock-keychain','--disable-sync'],args:['--disable-extensions','--disable-background-networking']});
    await this.context.route('**/*',async route=>{try{const r=route.request(),url=new URL(await publicURL(r.url(),lookup,this.testOrigin)),payload=r.url()+' '+(r.postData()||'');for(const [secret,origin] of this.secretOrigins)if(url.origin!==origin&&(payload.includes(secret)||payload.includes(encodeURIComponent(secret))))throw Error('Private sign-in data cannot be sent to another origin.');await route.continue();}catch{await route.abort('blockedbyclient');}});
    if(!headed)this.context.on('page',p=>{if(p!==this.page)p.close().catch(()=>{});});
    this.page=this.context.pages()[0]||await this.context.newPage();this.page.setDefaultTimeout(12000);
    this.page.on('dialog',dialog=>dialog.dismiss().catch(()=>{}));
    return this;
  }
  async ready() {if(!this.context)await this.launch();}
  scrub(value){if(typeof value==='string'){for(const secret of this.secrets)if(secret.length>=4)value=value.split(secret).join('[private]');return value;}if(Array.isArray(value))return value.map(x=>this.scrub(x));if(value&&typeof value==='object')return Object.fromEntries(Object.entries(value).map(([k,v])=>[k,this.scrub(v)]));return value;}
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
    for(const secret of info.secrets){this.secrets.add(secret);this.secretOrigins.set(secret,new URL(this.page.url()).origin);}delete info.secrets;return info;
  }
  safeURL(){try{const u=new URL(this.page?.url()||this.lastURL);for(const key of [...u.searchParams.keys()])if(/code|token|password|secret|credential|assertion|ticket/i.test(key))u.searchParams.set(key,'[private]');u.hash='';return this.scrub(u.href);}catch{return 'about:blank';}}
  async signature(){
    return hash(await this.page.evaluate(()=>({url:location.href,title:document.title,text:document.body?.innerText.slice(0,50000),forms:[...document.forms].map(f=>[f.action,f.method,f.target]),fields:[...document.querySelectorAll('input,textarea,select,button,a[href],[role=button]')].slice(0,300).map(e=>[e.tagName,e.getAttribute('type'),e.getAttribute('href'),e.getAttribute('name'),e.getAttribute('aria-label'),e.textContent?.slice(0,120),e.type==='password'?'[hidden]':e.value,e.checked])})));
  }
  async read(){
    await this.ready();if(this.page.url()!=='about:blank')await publicURL(this.page.url(),lookup,this.testOrigin);this.refs=[];this.prepared=null;
    this.lastURL=this.page.url();const privacy=await this.privacy();
    if(privacy.private){this.snapshot=null;return {url:new URL(this.page.url()).origin,title:'Private sign-in',text:'Sign-in and verification contents are private. Use buddy_browser_signin; never request passwords in chat.',controls:[],authentication:{kind:privacy.kind,private:true}};}
    const elements=await this.page.$$('a[href],button,input:not([type=hidden]),textarea,select,[role=button]');const controls=[];
    for(const e of elements.slice(0,250)) {
      if(!await e.isVisible())continue;
      const v=await e.evaluate(e=>({tag:e.tagName.toLowerCase(),type:e.getAttribute('type')||'',name:e.getAttribute('aria-label')||e.labels?.[0]?.textContent||e.getAttribute('placeholder')||e.getAttribute('name')||e.textContent?.trim().slice(0,180)||'',href:e.tagName==='A'?e.href:undefined,checked:e.checked,options:e.tagName==='SELECT'?[...e.options].slice(0,100).map(o=>({label:o.label,value:o.value})):undefined,value:e.type==='password'?'[hidden]':e.value}));
      controls.push({ref:String(this.refs.length),...v});this.refs.push(e);if(this.refs.length>=120)break;
    }
    this.snapshot={id:randomUUID(),signature:await this.signature(),url:this.page.url()};
    return this.scrub({snapshotId:this.snapshot.id,url:this.safeURL(),title:await this.page.title(),text:(await this.page.locator('body').innerText().catch(()=>'' )).slice(0,26000),controls});
  }
  async navigate(url){await this.ready();await this.page.goto(await publicURL(url,lookup,this.testOrigin),{waitUntil:'domcontentloaded',timeout:30000});return this.read();}
  async prepare(args){
    await this.ready();
    if((await this.privacy()).private)throw Error('This sign-in step is private. Request buddy_browser_signin instead of reading or filling credentials.');
    if(!this.snapshot||args.snapshotId!==this.snapshot.id||await this.signature()!==this.snapshot.signature)throw Error('The page changed. Read it again before proposing an operation.');
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
      if(target.href)await publicURL(target.href,lookup,this.testOrigin);
      targets.push({...target,ref:String(change.ref),value:change.value??''});
    }
    const formValues=args.action==='click'?await this.refs[Number(changes[0].ref)].evaluate(e=>[...(e.closest('form')?.querySelectorAll('input:not([type=hidden]),textarea,select')||[])].slice(0,100).map(f=>({field:f.labels?.[0]?.textContent?.trim()||f.getAttribute('aria-label')||f.name||f.type,value:f.type==='password'?'[hidden]':f.type==='file'?[...f.files].map(x=>x.name):['checkbox','radio'].includes(f.type)?f.checked:f.value}))):undefined;
    const token=randomUUID();this.prepared={token,args,targets,signature:this.snapshot.signature};
    return this.scrub({token,preview:{name:`Browser: ${args.action}`,service:'Buddy private browser',arguments:{page:this.safeURL(),action:args.action,...(formValues?.length?{formValues}:{}),targets:targets.map(t=>({control:t.label||t.tag,...(t.href?{destination:t.href}:{}),...(args.action==='fill'||args.action==='select'?{value:t.value}:{}),...(args.action==='upload'?{file:args.fileName,bytes:args.bytes,version:args.version}: {})}))}}});
  }
  async commit(token,upload){
    const prepared=this.prepared;this.prepared=null;
    if(!prepared||token!==prepared.token||await this.signature()!==prepared.signature)throw Error('The page changed or this approval was already used. Read the page again. Nothing was sent by this request.');
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
      return {performed:true,action:prepared.args.action,page:await this.read()};
    }catch(error){throw Error(`The browser operation did not return a confirmed result. Check the page before retrying: ${error.message}`);}
  }
  async prepareSignIn(mode='signin'){
    await this.ready();const url=new URL(await publicURL(this.page.url(),lookup,this.testOrigin));
    if(url.protocol!=='https:'&&url.origin!==this.testOrigin)throw Error('Sign-in requires HTTPS.');
    if(!['signin','signup','verification'].includes(mode))throw Error('Choose sign-in, account creation, or email verification.');
    const privacy=await this.privacy();if(privacy.kind==='security')throw Error('Account recovery and security changes need you in private Chrome.');
    const accountEmail=await this.page.locator('input[type=email],input[autocomplete=username]').first().inputValue().catch(()=>null);
    const token=randomUUID();this.authPlan={token,origin:url.origin,mode,signature:await this.signature(),created:Date.now()};
    return this.scrub({token,origin:url.origin,mode,accountEmail,private:true});
  }
  async useSaved(token){
    const plan=this.authPlan;this.authPlan=null;
    if(!plan||plan.token!==token||plan.mode!=='signin'||Date.now()-plan.created>300000||await this.signature()!==plan.signature)throw Error('This sign-in request changed or expired. Request it again.');
    const password=this.page.locator('input[type=password][autocomplete="current-password"],input[type=password]:not([autocomplete="new-password"])').first();
    // Inspect only a boolean. No API exposes a password or the Password Manager vault.
    const ready=await password.evaluate(e=>{const f=e.form;if(!e.value||!f||[...f.elements].some(x=>x.autocomplete==='new-password'))return false;const target=new URL(f.action||location.href,location.href);return target.origin===location.origin&&f.method.toLowerCase()==='post';}).catch(()=>false);
    if(!ready)return {needsUser:true,reason:'Chrome has not filled a saved login. Open privately to choose a saved account or unlock Password Manager.'};
    const form=password.locator('xpath=ancestor::form');const button=form.locator('button[type=submit],button:not([type]),input[type=submit]').first();
    const label=await button.evaluate(e=>e.innerText||e.value||e.getAttribute('aria-label')||'').catch(()=> '');
    if(!/sign.?in|log.?in|continue|next/i.test(label)||/create|register|agree|accept|pay|purchase|reset|delete/i.test(label))return {needsUser:true,reason:'Choose this sign-in step in private Chrome.'};
    await this.privacy();if(await this.signature()!==plan.signature)throw Error('The sign-in form changed. Request it again.');this.snapshot=null;await button.click();await this.page.waitForLoadState('domcontentloaded',{timeout:6000}).catch(()=>{});
    return {performed:true,page:await this.read()};
  }
  async verificationPlan(){
    await this.ready();const p=await this.privacy();if(!p.private||p.kind!=='verification')throw Error('A supported email verification form is not visible.');
    const url=new URL(this.page.url());if(url.protocol!=='https:'&&url.origin!==this.testOrigin)throw Error('Email verification requires HTTPS.');
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
    this.secrets.add(code);this.secretOrigins.set(code,p.origin);
    try{await this.page.locator('input[autocomplete="one-time-code"]').first().fill(code);const form=this.page.locator('input[autocomplete="one-time-code"]').first().locator('xpath=ancestor::form');if(await form.evaluate(f=>new URL(f.action||location.href,location.href).origin)!==p.origin)throw Error('Verification destination changed.');let submit;for(const e of await form.locator('button,input[type=submit]').all()){const label=await e.evaluate(e=>e.innerText||e.value||'');if(/verify|confirm|continue/i.test(label)&&!/pay|purchase|agree|accept/i.test(label)){submit=e;break;}}if(!submit)throw Error('Verification changed.');await submit.click();await this.page.waitForLoadState('domcontentloaded',{timeout:6000}).catch(()=>{});return {performed:true,page:await this.read()};}
    catch{throw Error('Verification was attempted without a confirmed result. Inspect the site before trying another code.');}
  }
  async manual(destination){
    if(this.manualProcess&&this.manualProcess.exitCode===null&&this.manualProcess.signalCode===null)return {opened:true,private:true};
    let url=destination==='google'?'chrome://settings/people':this.page?.url()||this.lastURL||'about:blank';
    if(!['about:blank','chrome://settings/people'].includes(url))url=await publicURL(url,lookup,this.testOrigin);
    this.lastURL=url;await this.closeAutomation();await mkdir(this.profile,{recursive:true,mode:0o700});await chmod(this.profile,0o700);
    // No debugging connection, automation flags, page scripts, screenshots, or password reads during the handoff.
    const child=spawn(this.manualExecutable,[`--user-data-dir=${this.profile}`,'--no-first-run','--no-default-browser-check','--disable-background-mode','--new-window',url],{stdio:'ignore'});
    await new Promise((resolve,reject)=>{child.once('spawn',resolve);child.once('error',()=>reject(Error('Could not open private Chrome. Install Google Chrome and try again.')));});this.manualProcess=child;
    return {opened:true,private:true};
  }
  async finishManual(){const p=this.manualProcess;if(p&&p.exitCode===null&&p.signalCode===null){p.kill('SIGTERM');await Promise.race([new Promise(resolve=>p.once('exit',resolve)),new Promise((_,reject)=>{const t=setTimeout(()=>reject(Error('Close Buddy’s private Chrome window before finishing sign-in.')),8000);t.unref();})]);}this.manualProcess=null;let locked=false;try{lstatSync(resolve(this.profile,'SingletonLock'));locked=true;}catch{}if(locked)throw Error('An older private Chrome session is still open. Quit that private Chrome session before finishing sign-in.');return {closed:true,url:this.lastURL?.startsWith('https:')?new URL(this.lastURL).origin:null};}
  async closeAutomation(){this.snapshot=null;this.prepared=null;this.authPlan=null;this.refs=[];if(this.context){const c=this.context;this.context=null;await c.close().catch(()=>{});}this.page=null;}
  async close(){await this.closeAutomation();await this.finishManual();}
}
if(process.argv[1]&&import.meta.url===pathToFileURL(realpathSync(process.argv[1])).href){
  const browser=new PrivateBrowser(process.argv[2]);
  for await(const line of createInterface({input:process.stdin})){
    let request;
    try{if(line.length>48*1024*1024)throw Error('Browser message too large.');request=JSON.parse(line);let result;
      if(request.command==='open')result=await browser.navigate(request.url);
      else if(request.command==='read')result=await browser.read();
      else if(request.command==='prepare')result=await browser.prepare(request.arguments);
      else if(request.command==='commit')result=await browser.commit(request.token,request.upload);
      else if(request.command==='manual')result=await browser.manual();
      else if(request.command==='manualGoogle')result=await browser.manual('google');
      else if(request.command==='finishManual')result=await browser.finishManual();
      else if(request.command==='prepareSignIn')result=await browser.prepareSignIn(request.mode);
      else if(request.command==='useSaved')result=await browser.useSaved(request.token);
      else if(request.command==='verificationPlan')result=await browser.verificationPlan();
      else if(request.command==='verifyEmail')result=await browser.verifyEmail(request.token,request.code);
      else if(request.command==='close'){await browser.close();result={closed:true};}
      else throw Error('Unsupported browser command.');
      process.stdout.write(JSON.stringify({id:request.id,result:browser.scrub(result)})+'\n');
    }catch(error){process.stdout.write(JSON.stringify({id:request?.id,error:browser.scrub(error.message)})+'\n');}
  }
  await browser.close();
}

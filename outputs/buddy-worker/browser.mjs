import {chromium} from 'playwright-core';
import {lookup} from 'node:dns/promises';
import {isIP} from 'node:net';
import {randomUUID, createHash} from 'node:crypto';
import {mkdir, chmod} from 'node:fs/promises';
import {resolve} from 'node:path';
import {createInterface} from 'node:readline';
import {pathToFileURL} from 'node:url';
import {realpathSync} from 'node:fs';

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
  constructor(profile,{testOrigin=''}={}) {this.profile=resolve(profile);this.testOrigin=testOrigin;this.context=null;this.page=null;this.refs=[];this.snapshot=null;this.prepared=null;}
  async launch(headed=false) {
    await this.close(); await mkdir(this.profile,{recursive:true,mode:0o700});await chmod(this.profile,0o700);
    this.context=await chromium.launchPersistentContext(this.profile,{channel:'chrome',headless:!headed,chromiumSandbox:true,acceptDownloads:false,permissions:[],serviceWorkers:'block',args:['--disable-extensions','--disable-background-networking']});
    await this.context.route('**/*',async route=>{try{await publicURL(route.request().url(),lookup,this.testOrigin);await route.continue();}catch{await route.abort('blockedbyclient');}});
    this.context.on('page',p=>{if(p!==this.page)p.close().catch(()=>{});});
    this.page=this.context.pages()[0]||await this.context.newPage();this.page.setDefaultTimeout(12000);
    this.page.on('dialog',dialog=>dialog.dismiss().catch(()=>{}));
    return this;
  }
  async ready() {if(!this.context)await this.launch();}
  async signature(){
    return hash(await this.page.evaluate(()=>({url:location.href,title:document.title,text:document.body?.innerText.slice(0,50000),fields:[...document.querySelectorAll('input,textarea,select,button,a[href],[role=button]')].slice(0,300).map(e=>[e.tagName,e.getAttribute('type'),e.getAttribute('href'),e.getAttribute('name'),e.getAttribute('aria-label'),e.textContent?.slice(0,120),e.type==='password'?'[hidden]':e.value,e.checked])})));
  }
  async read(){
    await this.ready();if(this.page.url()!=='about:blank')await publicURL(this.page.url(),lookup,this.testOrigin);this.refs=[];this.prepared=null;
    const elements=await this.page.$$('a[href],button,input:not([type=hidden]),textarea,select,[role=button]');const controls=[];
    for(const e of elements.slice(0,250)) {
      if(!await e.isVisible())continue;
      const v=await e.evaluate(e=>({tag:e.tagName.toLowerCase(),type:e.getAttribute('type')||'',name:e.getAttribute('aria-label')||e.labels?.[0]?.textContent||e.getAttribute('placeholder')||e.getAttribute('name')||e.textContent?.trim().slice(0,180)||'',href:e.tagName==='A'?e.href:undefined,checked:e.checked,options:e.tagName==='SELECT'?[...e.options].slice(0,100).map(o=>({label:o.label,value:o.value})):undefined,value:e.type==='password'?'[hidden]':e.value}));
      controls.push({ref:String(this.refs.length),...v});this.refs.push(e);if(this.refs.length>=120)break;
    }
    this.snapshot={id:randomUUID(),signature:await this.signature(),url:this.page.url()};
    return {snapshotId:this.snapshot.id,url:this.page.url(),title:await this.page.title(),text:(await this.page.locator('body').innerText().catch(()=>'' )).slice(0,26000),controls};
  }
  async navigate(url){await this.ready();await this.page.goto(await publicURL(url,lookup,this.testOrigin),{waitUntil:'domcontentloaded',timeout:30000});return this.read();}
  async prepare(args){
    await this.ready();
    if(!this.snapshot||args.snapshotId!==this.snapshot.id||await this.signature()!==this.snapshot.signature)throw Error('The page changed. Read it again before proposing an operation.');
    if(!['click','fill','select','upload'].includes(args.action))throw Error('Choose click, fill, select, or upload.');
    const changes=args.action==='fill'?args.fields:[{ref:args.ref,value:args.value}];
    if(!Array.isArray(changes)||!changes.length||changes.length>25)throw Error('Provide between one and twenty-five fields.');
    const targets=[];
    for(const change of changes){
      if(!/^\d{1,3}$/.test(String(change.ref)))throw Error('Use a visible control reference.');
      const e=this.refs[Number(change.ref)];if(!e||!await e.isVisible()||!await e.isEnabled())throw Error('This control is no longer visible. Read the page again.');
      const target=await e.evaluate(e=>({tag:e.tagName.toLowerCase(),type:e.getAttribute('type')||'',label:e.getAttribute('aria-label')||e.labels?.[0]?.textContent||e.getAttribute('placeholder')||e.getAttribute('name')||e.textContent?.trim().slice(0,180)||'',href:e.tagName==='A'?e.href:undefined}));
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
    return {token,preview:{name:`Browser: ${args.action}`,service:'Buddy private browser',arguments:{page:this.snapshot.url,action:args.action,...(formValues?.length?{formValues}:{}),targets:targets.map(t=>({control:t.label||t.tag,...(t.href?{destination:t.href}:{}),...(args.action==='fill'||args.action==='select'?{value:t.value}:{}),...(args.action==='upload'?{file:args.fileName,bytes:args.bytes,version:args.version}: {})}))}}};
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
  async manual(){const url=this.page?.url();await this.launch(true);if(url&&url!=='about:blank')await this.navigate(url);return {opened:true};}
  async close(){this.snapshot=null;this.prepared=null;this.refs=[];if(this.context){const c=this.context;this.context=null;await c.close().catch(()=>{});}this.page=null;}
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
      else if(request.command==='close'){await browser.close();result={closed:true};}
      else throw Error('Unsupported browser command.');
      process.stdout.write(JSON.stringify({id:request.id,result})+'\n');
    }catch(error){process.stdout.write(JSON.stringify({id:request?.id,error:error.message})+'\n');}
  }
  await browser.close();
}

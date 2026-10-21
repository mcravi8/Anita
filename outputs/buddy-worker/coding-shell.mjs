import {spawn} from 'node:child_process';
import {realpath,mkdir} from 'node:fs/promises';
import {realpathSync} from 'node:fs';
import {createInterface} from 'node:readline';
import {pathToFileURL} from 'node:url';

// Commands run in a separate process from the SDK. Its environment never contains
// the API key. Seatbelt confines descendants as well as the initial shell.
// Without network=true a command has no network of any kind, not even to services on this Mac: a local proxy, VPN client or database
// would otherwise hand it the internet, or your data, without the review that network access requires.
// With network=true it gets IP networking only. Unix sockets stay denied (the worker's control socket is one), except the system DNS resolver's.
export function sandboxProfile(project,scratch,network=false) {
  const q=p=>JSON.stringify(p);
  return `(version 1)
(deny default)
(allow process-exec process-fork)
(allow signal (target same-sandbox))
(allow sysctl-read)
(allow file-read-metadata)
(allow file-read* (literal "/"))
(allow file-read* ${['/System','/usr','/bin','/sbin','/Library/Developer','/Library/Frameworks','/Library/Apple','/opt/homebrew','/dev',project,scratch].map(p=>`(subpath ${q(p)})`).join(' ')})
(allow file-read* (literal "/private/etc/localtime") (literal "/private/etc/hosts") (literal "/private/etc/resolv.conf") (literal "/private/etc/protocols") (literal "/private/etc/services") (subpath "/private/etc/ssl") (subpath "/private/var/db/timezone"))
(allow file-write* (subpath ${q(project)}) (subpath ${q(scratch)}) (literal "/dev/null"))
(allow mach-lookup (global-name "com.apple.system.logger") (global-name "com.apple.system.opendirectoryd.libinfo"))
${network?'(allow mach-lookup (global-name "com.apple.mDNSResponder"))':''}
${network?'(allow network-outbound (remote ip "*:*"))\n(allow network-outbound (remote unix-socket (path-literal "/private/var/run/mDNSResponder")))\n(allow network-inbound (local ip "localhost:*"))\n(allow network-bind (local ip "localhost:*"))':''}`;
}
// A command that signs in gets the person's saved sign-in as environment variables of its own process, and nothing else does: not this
// runner, not a later command, not the shell's history (zsh -f keeps none). The values never come back: every one, as written and as it
// appears in a web address, is replaced in the output, including where keeping the start and end of a long output cuts one in two.
const HIDDEN='[hidden]';
export function signInEnvironment(secrets,base){
  if(secrets==null)return {};
  if(typeof secrets!=='object'||Array.isArray(secrets))throw Error('Invalid sign-in for this command.');
  const entries=Object.entries(secrets);
  if(entries.length>4||entries.some(([key,value])=>!/^[A-Z][A-Z0-9_]{0,63}$/.test(key)||key in base||typeof value!=='string'||!value||value.length>4096||value.includes('\0')))throw Error('Invalid sign-in for this command.');
  return Object.fromEntries(entries);
}
export function redact(text,values){
  const forms=[...new Set(values.filter(v=>typeof v==='string'&&v).flatMap(v=>[v,encodeURIComponent(v)]))].sort((a,b)=>b.length-a.length);
  let out=text;for(const form of forms)out=out.split(form).join(HIDDEN);
  return out;
}
// A cut piece of output: whole values are hidden, and so is the part of one that the cut left at the end (`side` 'end') or start ('start').
export function redactPiece(text,values,side){
  let out=redact(text,values);
  const forms=[...new Set(values.filter(v=>typeof v==='string'&&v).flatMap(v=>[v,encodeURIComponent(v)]))];
  for(const form of forms)for(let k=form.length-1;k>0;k--){
    if(side==='end'&&out.endsWith(form.slice(0,k))){out=out.slice(0,out.length-k)+HIDDEN;break;}
    if(side==='start'&&out.startsWith(form.slice(form.length-k))){out=HIDDEN+out.slice(k);break;}
  }
  return out;
}
export class CodingShell {
  constructor(){this.child=null;this.closed=false;}
  async run({cwd,scratch,code,network=false,timeoutSeconds=120,secrets}) {
    if(this.closed||this.child)throw Error('The coding command runner is stopped or busy.');
    if(process.platform!=='darwin')throw Error('This coding runner requires the macOS sandbox.');
    if(typeof code!=='string'||!code.trim()||code.length>10000||code.includes('\0'))throw Error('Choose a command under 10,000 characters.');
    const project=await realpath(cwd);await mkdir(scratch,{recursive:true,mode:0o700});scratch=await realpath(scratch);
    const seconds=Math.min(300,Math.max(1,Number(timeoutSeconds)||120));
    const base={PATH:'/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin',HOME:scratch,TMPDIR:scratch,TMPPREFIX:scratch+'/zsh',LANG:'en_US.UTF-8',TERM:'dumb',CI:'1',NO_COLOR:'1',GIT_TERMINAL_PROMPT:'0',PYTHONNOUSERSITE:'1',npm_config_cache:scratch+'/npm',npm_config_userconfig:'/dev/null',PIP_CACHE_DIR:scratch+'/pip'};
    const signIn=signInEnvironment(secrets,base),hidden=Object.values(signIn);
    const env={...base,...signIn};
    return await new Promise((resolve,reject)=>{
      const at=Date.now();let output='',tail='',truncated=false,timedOut=false,settled=false;
      const child=spawn('/usr/bin/sandbox-exec',['-p',sandboxProfile(project,scratch,network),'/bin/zsh','-f','-c',code],{cwd:project,env,detached:true,stdio:['ignore','pipe','pipe']});this.child=child;
      // Errors are at the end of long output, so keep the start and the end and leave out the middle.
      const append=data=>{const text=data.toString();if(Buffer.byteLength(output)<16000)output+=text;else{truncated=true;tail=(tail+text).slice(-48000);}};child.stdout.on('data',append);child.stderr.on('data',append);
      const terminate=()=>{try{process.kill(-child.pid,'SIGKILL');}catch{}};
      const timer=setTimeout(()=>{timedOut=true;terminate();},seconds*1000);
      child.once('error',error=>{if(settled)return;settled=true;clearTimeout(timer);this.child=null;reject(error);});
      // 'close' waits for the output pipes, which a background process started in its own session can hold open for as long as it likes.
      // So finish as soon as the shell itself has exited (after a moment for its last output), and let go of the pipes.
      const kept=()=>!hidden.length?(truncated?output.slice(0,16000)+'\n… (the middle of the output is left out) …\n'+tail:output)
        :truncated?redactPiece(output.slice(0,16000),hidden,'end')+'\n… (the middle of the output is left out) …\n'+redactPiece(tail,hidden,'start'):redact(output,hidden);
      const finish=(exitCode,signal)=>{if(settled)return;settled=true;clearTimeout(timer);terminate();child.stdout.destroy();child.stderr.destroy();this.child=null;resolve({exitCode,signal,output:kept(),truncated,timedOut,durationMs:Date.now()-at,network,project});};
      child.once('close',finish);
      child.once('exit',(exitCode,signal)=>setTimeout(()=>finish(exitCode,signal),300));
    });
  }
  close(){this.closed=true;if(this.child){try{process.kill(-this.child.pid,'SIGKILL');}catch{}}}
}
if(process.argv[1]&&import.meta.url===pathToFileURL(realpathSync(process.argv[1])).href) {
  const shell=new CodingShell(),write=x=>process.stdout.write(JSON.stringify(x,(key,item)=>typeof item==='string'?item.toWellFormed():item)+'\n');
  process.on('SIGTERM',()=>{shell.close();process.exit(0);});process.on('SIGINT',()=>{shell.close();process.exit(0);});
  for await(const line of createInterface({input:process.stdin})) {
    try{const input=JSON.parse(line);if(input.command!=='run')throw Error('Unsupported coding command.');shell.run(input).then(result=>write({id:input.id,result}),error=>write({id:input.id,error:error.message}));}
    catch(error){write({error:error.message});}
  }
  shell.close();
}

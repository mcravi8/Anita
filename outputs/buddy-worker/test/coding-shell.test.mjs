import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,mkdir,writeFile,readFile,symlink,rm,realpath} from 'node:fs/promises';
import {createServer} from 'node:net';
import {CodingShell,sandboxProfile} from '../coding-shell.mjs';
test('real macOS sandbox runs builds with a clean environment and blocks outside reads/writes, symlinks and external network',{skip:process.platform!=='darwin'},async()=>{
 const root=await mkdtemp('/tmp/buddy-coding-test-'),shell=new CodingShell();
 try{
  await mkdir(root+'/project');await writeFile(root+'/private.txt','sensitive-fixture');await symlink(root+'/private.txt',root+'/project/link');
  process.env.ANTHROPIC_API_KEY='never-in-command';process.env.BUDDY_SECRET_TEST='private-env';
  const run=code=>shell.run({cwd:root+'/project',scratch:root+'/scratch',code});
  let result=await run('node -e \'if(process.env.ANTHROPIC_API_KEY||process.env.BUDDY_SECRET_TEST)process.exit(9);require("fs").writeFileSync("check.js","console.log(42)")\' && node --check check.js');assert.equal(result.exitCode,0,result.output);assert.match(await readFile(root+'/project/check.js','utf8'),/42/);
  result=await run("python3 - <<'PY'\nprint('heredoc-ok')\nPY");assert.equal(result.exitCode,0,result.output);assert.match(result.output,/heredoc-ok/);
  for(const code of ['cat ../private.txt','cat link','echo changed > ../private.txt','node -e \'require("fs").readFileSync(process.env.HOME+"/../../private.txt")\'']){result=await run(code);assert.notEqual(result.exitCode,0,code);assert.doesNotMatch(result.output,/sensitive-fixture/);}
  assert.equal(await readFile(root+'/private.txt','utf8'),'sensitive-fixture');
  result=await run('node -e \'require("net").connect(443,"192.0.2.1").on("error",e=>{console.log(e.code);process.exit(e.code==="EPERM"?0:2)})\'');assert.equal(result.exitCode,0,result.output);assert.match(result.output,/EPERM/);
  // Without network access a command cannot reach anything, not even a service on this Mac; with it (after review) it can.
  result=await run('node -e \'const s=require("http").createServer((q,r)=>r.end("local-ok")).listen(0,"127.0.0.1",()=>require("http").get("http://127.0.0.1:"+s.address().port,r=>{r.on("data",x=>console.log(String(x)));r.on("end",()=>s.close())}))\'');assert.notEqual(result.exitCode,0,'no local server without network access');assert.doesNotMatch(result.output,/local-ok/);
  result=await shell.run({cwd:root+'/project',scratch:root+'/scratch',network:true,code:'node -e \'const s=require("http").createServer((q,r)=>r.end("local-ok")).listen(0,"127.0.0.1",()=>require("http").get("http://127.0.0.1:"+s.address().port,r=>{r.on("data",x=>console.log(String(x)));r.on("end",()=>s.close())}))\''});assert.equal(result.exitCode,0,result.output);assert.match(result.output,/local-ok/,'a reviewed command with network access can use local services');
  result=await shell.run({cwd:root+'/project',scratch:root+'/scratch',code:'node -e \'setInterval(()=>{},1000)\'',timeoutSeconds:1});assert.equal(result.timedOut,true);assert.notEqual(result.exitCode,0);
 }finally{shell.close();delete process.env.ANTHROPIC_API_KEY;delete process.env.BUDDY_SECRET_TEST;await rm(root,{recursive:true,force:true});}
});

test('a reviewed network command reaches the internet but never a Unix socket on this Mac, such as the worker control socket',{skip:process.platform!=='darwin'},async()=>{
 const root=await realpath(await mkdtemp('/tmp/buddy-coding-unix-')),shell=new CodingShell(),socket=root+'/project/s.sock';
 await mkdir(root+'/project');
 const server=createServer(c=>c.end('socket-reached')).listen(socket);await new Promise(r=>server.once('listening',r));
 try{
  const code=`python3 -c "import socket;s=socket.socket(socket.AF_UNIX);s.connect('${socket}');print(s.recv(64).decode())"`;
  let result=await shell.run({cwd:root+'/project',scratch:root+'/scratch',network:true,code});
  assert.notEqual(result.exitCode,0,'network access is IP only: '+result.output);assert.doesNotMatch(result.output,/socket-reached/);
  result=await shell.run({cwd:root+'/project',scratch:root+'/scratch',code});
  assert.notEqual(result.exitCode,0,'and without network access there is no socket either');assert.doesNotMatch(result.output,/socket-reached/);
  const profile=sandboxProfile(root+'/project',root+'/scratch',true);
  assert.match(profile,/\(allow network-outbound \(remote ip "\*:\*"\)\)/,'outbound network is limited to IP addresses');
  assert.match(profile,/\(allow network-outbound \(remote unix-socket \(path-literal "\/private\/var\/run\/mDNSResponder"\)\)\)/,'the one Unix socket allowed is the DNS resolver, so host names still resolve');
  assert.doesNotMatch(profile,/\(allow network-outbound\)/,'never an unfiltered outbound rule');
  assert.doesNotMatch(sandboxProfile(root+'/project',root+'/scratch',false),/network-outbound/,'no network rule at all without network access');
 }finally{shell.close();server.close();await rm(root,{recursive:true,force:true});}
});

test('long command output keeps its end, where the error is, and says the middle was left out',{skip:process.platform!=='darwin'},async()=>{
 const root=await mkdtemp('/tmp/buddy-coding-tail-'),shell=new CodingShell();
 try{
  await mkdir(root+'/project');
  const result=await shell.run({cwd:root+'/project',scratch:root+'/scratch',code:'node -e \'console.log("HEAD-LINE");for(let i=0;i<4000;i++)console.log("filler line number "+i+" ............................");console.log("TRACEBACK-AT-THE-END")\''});
  assert.equal(result.truncated,true);assert.match(result.output,/HEAD-LINE/);assert.match(result.output,/TRACEBACK-AT-THE-END/,'the last lines survive');assert.match(result.output,/middle of the output is left out/);assert.ok(result.output.length<66000);
 }finally{await rm(root,{recursive:true,force:true});}
});
test('a saved sign-in reaches only the one command it is for, as its environment, and never comes back in the output',{skip:process.platform!=='darwin'},async()=>{
 const {signInEnvironment,redact,redactPiece}=await import('../coding-shell.mjs');
 const root=await mkdtemp('/tmp/buddy-coding-signin-'),shell=new CodingShell(),user='fixture-user-7Q2Z',pass='Fx!pw 93/ZK&not-real';
 try{
  await mkdir(root+'/project');
  const run=(code,secrets)=>shell.run({cwd:root+'/project',scratch:root+'/scratch',code,...(secrets?{secrets}:{})});
  let result=await run('node -e \'console.log("u="+process.env.PGUSER+" p="+process.env.PGPASSWORD+" q="+encodeURIComponent(process.env.PGPASSWORD));console.log(require("crypto").createHash("sha256").update(process.env.PGUSER+":"+process.env.PGPASSWORD).digest("hex"))\'',{PGUSER:user,PGPASSWORD:pass});
  assert.equal(result.exitCode,0,result.output);
  assert.match(result.output,/^u=\[hidden\] p=\[hidden\] q=\[hidden\]\n/,'the values, also as they appear in a web address, are hidden');
  assert.ok(result.output.includes((await import('node:crypto')).createHash('sha256').update(user+':'+pass).digest('hex')),'the exact values reached the command');
  assert.ok(!result.output.includes(user)&&!result.output.includes(pass));
  result=await run('node -e \'console.log(String(process.env.PGUSER)+" "+String(process.env.PGPASSWORD))\'');
  assert.equal(result.output,'undefined undefined\n','the next command has none of it');
  // A long output keeps its start and end; a value cut in two at either cut is hidden too.
  const long=await run('node -e \'process.stdout.write("a".repeat(15990)+process.env.PGPASSWORD+"b".repeat(60000)+process.env.PGPASSWORD.slice(0,5));process.stdout.write(process.env.PGPASSWORD.slice(5)+"c".repeat(100))\'',{PGPASSWORD:pass});
  assert.ok(long.truncated&&!long.output.includes(pass)&&!long.output.includes(pass.slice(0,6))&&!long.output.includes(pass.slice(-6)),'no piece of it survives the cut');
  for(const bad of [[],{path:'x'},{PATH:'/tmp'},{HOME:'/'},{PGPASSWORD:''},{PGPASSWORD:'a\0b'},{A:'1',B:'2',C:'3',D:'4',E:'5'}])assert.throws(()=>signInEnvironment(bad,{PATH:'',HOME:''}),/Invalid sign-in/,JSON.stringify(bad));
  await assert.rejects(run('true',{PATH:'/tmp/evil'}),/Invalid sign-in/,'a sign-in can never replace the runner\'s own environment');
  assert.equal(redact('x secret y secret',['secret']),'x [hidden] y [hidden]');
  assert.equal(redactPiece('aaa sec',['secret'],'end'),'aaa [hidden]');assert.equal(redactPiece('ret bbb',['secret'],'start'),'[hidden] bbb');
 }finally{shell.close();await rm(root,{recursive:true,force:true});}
});

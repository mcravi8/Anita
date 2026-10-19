import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,mkdir,writeFile,readFile,symlink,rm} from 'node:fs/promises';
import {CodingShell} from '../coding-shell.mjs';
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

test('long command output keeps its end, where the error is, and says the middle was left out',{skip:process.platform!=='darwin'},async()=>{
 const root=await mkdtemp('/tmp/buddy-coding-tail-'),shell=new CodingShell();
 try{
  await mkdir(root+'/project');
  const result=await shell.run({cwd:root+'/project',scratch:root+'/scratch',code:'node -e \'console.log("HEAD-LINE");for(let i=0;i<4000;i++)console.log("filler line number "+i+" ............................");console.log("TRACEBACK-AT-THE-END")\''});
  assert.equal(result.truncated,true);assert.match(result.output,/HEAD-LINE/);assert.match(result.output,/TRACEBACK-AT-THE-END/,'the last lines survive');assert.match(result.output,/middle of the output is left out/);assert.ok(result.output.length<66000);
 }finally{await rm(root,{recursive:true,force:true});}
});

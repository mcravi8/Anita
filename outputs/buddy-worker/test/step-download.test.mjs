import test from 'node:test';
import assert from 'node:assert/strict';
import {SharedBrowser} from '../browser.mjs';
import {mkdtemp,rm,readFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {createServer} from 'node:http';
import {createHash} from 'node:crypto';

// A file a step asked the person for (a paywalled article's PDF) is fetched by Buddy itself once they press Done: with what they signed in
// to in Buddy's Chrome (the shared profile's cookies), through the same network guard as every page, each redirect checked like a page.
// Only the file itself is saved, as a new file; a web page in its place (a sign-in form, a CAPTCHA) never is.
test('a step’s file downloads with the profile’s sign-in, follows the site’s redirect, and only a real file is saved, never over another',{timeout:60000},async()=>{
 const pdf=Buffer.from('%PDF-1.7\n% fixture: the published article\n%%EOF\n');
 let cookie='';
 const server=createServer((req,res)=>{
  if(req.url==='/login'){res.setHeader('Set-Cookie','member=yes; Path=/; Max-Age=3600');res.setHeader('Content-Type','text/html');res.end('<h1>Signed in</h1>');return;}
  if(req.url==='/article/ac498c/pdf'){res.statusCode=302;res.setHeader('Location','/files/ac498c.pdf');res.end();return;}
  if(req.url==='/files/ac498c.pdf'){
   cookie=req.headers.cookie||'';
   if(!/member=yes/.test(cookie)){res.setHeader('Content-Type','text/html');res.end('<!DOCTYPE html><html><body>Sign in through your institution, or solve the CAPTCHA.</body></html>');return;}
   res.setHeader('Content-Type','application/pdf');res.end(pdf);return;
  }
  if(req.url==='/disguised.pdf'){res.setHeader('Content-Type','application/pdf');res.end('<html><body>Access denied</body></html>');return;}
  if(req.url==='/away'){res.statusCode=302;res.setHeader('Location','http://127.0.0.2:9/secret.pdf');res.end();return;}
  if(req.url==='/gone.pdf'){res.statusCode=403;res.end('forbidden');return;}
  res.statusCode=404;res.end('missing');
 });
 await new Promise(r=>server.listen(0,'127.0.0.1',r));
 const origin=`http://127.0.0.1:${server.address().port}`,root=await mkdtemp(join(tmpdir(),'buddy-step-download-'));
 const browser=new SharedBrowser(join(root,'profile.noindex'),{testOrigin:origin});
 try{
  const task=browser.session('coding-task','','');
  // Before the person has signed in, the site sends a web page instead of the file: nothing is saved.
  await assert.rejects(task.download(origin+'/article/ac498c/pdf',join(root,'early.part'),{expect:'pdf'}),/web page/);
  await assert.rejects(readFile(join(root,'early.part')),'nothing was written');
  // The person signs in (here a page on the shared profile sets the site's cookie, as their Chrome window does).
  await browser.session('person','','').navigate(origin+'/login');
  const got=await task.download(origin+'/article/ac498c/pdf',join(root,'got.part'),{expect:'pdf'});
  assert.deepEqual(await readFile(join(root,'got.part')),pdf,'the file itself is saved');
  assert.equal(got.bytes,pdf.length);assert.equal(got.sha256,createHash('sha256').update(pdf).digest('hex'));assert.equal(got.contentType,'application/pdf');
  assert.match(cookie,/member=yes/,'with the profile’s sign-in');
  // Never over a file that is already there.
  await assert.rejects(task.download(origin+'/article/ac498c/pdf',join(root,'got.part'),{expect:'pdf'}),/already/);
  assert.deepEqual(await readFile(join(root,'got.part')),pdf);
  // A "PDF" that is a web page, an error page, a file over the limit, a redirect to a private address, and a page that is not public.
  await assert.rejects(task.download(origin+'/disguised.pdf',join(root,'disguised.part'),{expect:'pdf'}),/web page/);
  await assert.rejects(task.download(origin+'/gone.pdf',join(root,'gone.part')),/403/);
  await assert.rejects(task.download(origin+'/article/ac498c/pdf',join(root,'big.part'),{maxBytes:10}),/larger/);
  await assert.rejects(task.download(origin+'/away',join(root,'away.part')),/Local and private/);
  await assert.rejects(task.download('http://127.0.0.2:9/file.pdf',join(root,'private.part')),/Local and private/);
  for(const name of ['disguised.part','gone.part','big.part','away.part','private.part'])await assert.rejects(readFile(join(root,name)),name+' was not written');
  // Only where the Mac app says: an absolute path to a new download file.
  await assert.rejects(task.download(origin+'/article/ac498c/pdf','relative.part'),/where/);
  await assert.rejects(task.download(origin+'/article/ac498c/pdf',join(root,'article.pdf')),/where/);
  // A delegated website's session downloads from that website only.
  const scoped=browser.session('delegated','https://console.example.com','');
  await assert.rejects(scoped.download(origin+'/article/ac498c/pdf',join(root,'scoped.part')),/only for/);
 }finally{await browser.close();await rm(root,{recursive:true,force:true});await new Promise(r=>server.close(r));}
});

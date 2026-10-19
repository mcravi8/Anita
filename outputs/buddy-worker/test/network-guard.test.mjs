import test from 'node:test';import assert from 'node:assert/strict';
import net from 'node:net';import http from 'node:http';
import {startGuardProxy,publicAddress} from '../network-guard.mjs';

const PUBLIC='93.184.216.34',OTHER_PUBLIC='151.101.1.69';
const basic=guard=>'Basic '+Buffer.from(`${guard.username}:${guard.password}`).toString('base64');
// A "site": what the proxy's connect hook reaches whatever public address it was asked for.
async function site(handler){const server=http.createServer(handler);await new Promise(r=>server.listen(0,'127.0.0.1',r));return {server,port:server.address().port};}
const tcpEcho=async()=>{const sockets=new Set(),server=net.createServer(s=>{sockets.add(s);s.on('error',()=>{});s.on('data',d=>s.write(Buffer.concat([Buffer.from('echo:'),d])));});await new Promise(r=>server.listen(0,'127.0.0.1',r));return {server,port:server.address().port,close:()=>{for(const s of sockets)s.destroy();server.close();}};};
function raw(guard,text,{wait=300}={}){return new Promise((resolve,reject)=>{const s=net.connect(guard.port,'127.0.0.1');let out='';s.on('data',d=>out+=d);s.on('error',reject);s.on('connect',()=>s.write(text));setTimeout(()=>{s.destroy();resolve(out);},wait);});}
const status=reply=>(reply.match(/^HTTP\/1\.[01] (\d+)/)||[])[1];
const via=(guard,absolute,{auth=true,method='GET',body}={})=>new Promise((resolve,reject)=>{const url=new URL(absolute);const req=http.request({host:'127.0.0.1',port:guard.port,method,path:absolute,headers:{Host:url.host,...(auth?{'Proxy-Authorization':basic(guard)}:{})}},res=>{let text='';res.on('data',d=>text+=d);res.on('end',()=>resolve({status:res.statusCode,text,headers:res.headers}));});req.on('error',reject);if(body)req.write(body);req.end();});

test('only a client that knows the session password can use the proxy',async()=>{
 const guard=await startGuardProxy({resolver:async()=>[{address:PUBLIC}],connect:async()=>{throw Error('must not connect');}});
 try{
  assert.equal((await via(guard,'http://example.test/',{auth:false})).status,407);
  assert.equal(status(await raw(guard,'CONNECT example.test:443 HTTP/1.1\r\nHost: example.test:443\r\n\r\n')),'407');
  assert.equal(status(await raw(guard,`CONNECT example.test:443 HTTP/1.1\r\nHost: example.test:443\r\nProxy-Authorization: Basic ${Buffer.from('buddy:wrong').toString('base64')}\r\n\r\n`)),'407');
  assert.match(await raw(guard,'GET http://example.test/ HTTP/1.1\r\nHost: example.test\r\n\r\n'),/Proxy-Authenticate: Basic/i);
  assert.equal(guard.stats.allowed,0);
 }finally{await guard.close();}
});

test('private, local and mixed destinations are refused for plain requests and tunnels alike, before anything is connected',async()=>{
 const connected=[],blocked=[];
 const answers={'internal.test':['10.0.0.5'],'mixed.test':[PUBLIC,'127.0.0.1'],'mapped.test':['::ffff:127.0.0.1'],'docs.test':['192.0.2.7'],'linklocal.test':['169.254.169.254'],'empty.test':[]};
 const guard=await startGuardProxy({resolver:async name=>(answers[name]||[PUBLIC]).map(address=>({address})),connect:async(a,p)=>{connected.push(a+':'+p);throw Error('refused by fixture');},onBlocked:host=>blocked.push(host)});
 const auth=`Proxy-Authorization: ${basic(guard)}\r\n`;
 try{
  const targets=['127.0.0.1:8080','localhost:8080','foo.localhost:80','[::1]:80','10.1.2.3:80','192.168.1.1:80','169.254.169.254:80','172.16.0.1:80','100.64.0.1:80','0.0.0.0:80','[::ffff:127.0.0.1]:80','[fe80::1]:80','[fd00::1]:80','printer.local:80','db.internal:5432','internal.test:80','mixed.test:80','mapped.test:80','docs.test:80','linklocal.test:80','empty.test:80'];
  for(const target of targets){
   assert.equal(status(await raw(guard,`CONNECT ${target} HTTP/1.1\r\nHost: ${target}\r\n${auth}\r\n`)),'403',`CONNECT ${target}`);
   const plain=await via(guard,`http://${target}/`);assert.equal(plain.status,403,`GET ${target}`);assert.match(plain.text,/private network/i);
  }
  assert.deepEqual(connected,[],'nothing was connected to for any of them');
  assert.equal(guard.stats.blocked,targets.length*2);assert.ok(blocked.includes('internal.test')&&blocked.includes('127.0.0.1'));
  assert.ok(publicAddress(PUBLIC)&&publicAddress('2606:4700::1111')&&!publicAddress('::1')&&!publicAddress('2001:db8::1'));
 }finally{await guard.close();}
});

test('a public destination is reached through the address that was checked, and only that one',async()=>{
 const lookups=[],asked=[];
 const origin=await site((req,res)=>{res.setHeader('Content-Type','text/plain');res.end('hello '+req.headers.host+' '+req.url+' '+(req.headers['proxy-authorization']?'LEAKED':'clean'));});
 const guard=await startGuardProxy({
  // The first answer is public; any later lookup would say "your own computer" (DNS rebinding).
  resolver:async name=>{lookups.push(name);return [{address:lookups.length===1?PUBLIC:'127.0.0.1'}];},
  connect:async(address,port)=>{asked.push(address+':'+port);return net.connect(origin.port,'127.0.0.1');}
 });
 try{
  const reply=await via(guard,'http://rebind.example/path?x=1');
  assert.equal(reply.status,200);assert.match(reply.text,/^hello rebind\.example \/path\?x=1 clean$/,'host and path are kept, and the proxy password is not passed on');
  assert.deepEqual(lookups,['rebind.example'],'the name is looked up once for this request');
  assert.deepEqual(asked,[PUBLIC+':80'],'the connection went to the checked address, not to a second lookup result');
  // The next request looks the name up again, now gets a private answer, and is refused.
  const second=await via(guard,'http://rebind.example/');assert.equal(second.status,403);assert.deepEqual(asked,[PUBLIC+':80']);
 }finally{await guard.close();origin.server.close();}
});

test('an address that does not answer falls back to the next checked address, and an unknown name is a clean error',async()=>{
 const origin=await site((req,res)=>res.end('second address'));const tried=[];
 const guard=await startGuardProxy({
  resolver:async name=>{if(name==='gone.test')throw Object.assign(Error('ENOTFOUND'),{code:'ENOTFOUND'});return [{address:PUBLIC},{address:OTHER_PUBLIC}];},
  connect:async address=>{tried.push(address);if(address===PUBLIC)throw Error('unreachable');return net.connect(origin.port,'127.0.0.1');}
 });
 try{
  const reply=await via(guard,'http://two.test/');assert.equal(reply.text,'second address');assert.deepEqual(tried,[PUBLIC,OTHER_PUBLIC]);
  assert.equal((await via(guard,'http://gone.test/')).status,502);
 }finally{await guard.close();origin.server.close();}
});

test('a tunnel carries bytes both ways, and cleanup after a reset leaves the proxy running',async()=>{
 const echo=await tcpEcho();
 const guard=await startGuardProxy({resolver:async()=>[{address:PUBLIC}],connect:async()=>net.connect(echo.port,'127.0.0.1')});
 try{
  const reply=await new Promise((resolve,reject)=>{const s=net.connect(guard.port,'127.0.0.1');let buffer='';s.on('error',reject);s.on('connect',()=>s.write(`CONNECT secure.test:443 HTTP/1.1\r\nHost: secure.test:443\r\nProxy-Authorization: ${basic(guard)}\r\n\r\n`));
   s.on('data',d=>{buffer+=d;if(buffer.includes('200 Connection Established')&&!buffer.includes('echo:'))s.write('ping');if(buffer.includes('echo:ping')){s.destroy();resolve(buffer);}});setTimeout(()=>reject(Error('no echo: '+buffer)),4000);});
  assert.match(reply,/200 Connection Established/);assert.match(reply,/echo:ping/);
  // Resets and half-open clients must not take the process down.
  for(let i=0;i<5;i++){const s=net.connect(guard.port,'127.0.0.1');s.on('error',()=>{});s.on('connect',()=>{s.write(`CONNECT secure.test:443 HTTP/1.1\r\nProxy-Authorization: ${basic(guard)}\r\n\r\n`);setTimeout(()=>s.resetAndDestroy(),30);});}
  await new Promise(r=>setTimeout(r,500));
  assert.equal(status(await raw(guard,'GET http://x/ HTTP/1.1\r\nHost: x\r\n\r\n')),'407','still serving');
 }finally{await guard.close();echo.close();}
});

test('malformed and unsupported requests are rejected, not forwarded',async()=>{
 const connected=[];const guard=await startGuardProxy({resolver:async()=>[{address:PUBLIC}],connect:async(a,p)=>{connected.push(a);throw Error('no');}});
 const auth=`Proxy-Authorization: ${basic(guard)}\r\n`;
 try{
  assert.equal(status(await raw(guard,`CONNECT :::: HTTP/1.1\r\n${auth}\r\n`)),'400');
  assert.equal(status(await raw(guard,`CONNECT example.test:0 HTTP/1.1\r\n${auth}\r\n`)),'400');
  assert.equal(status(await raw(guard,`CONNECT example.test:99999 HTTP/1.1\r\n${auth}\r\n`)),'400');
  assert.equal(status(await raw(guard,`GET /just-a-path HTTP/1.1\r\nHost: x\r\n${auth}\r\n`)),'400','a request meant for a server, not a proxy');
  assert.equal(status(await raw(guard,`GET http://user:pass@example.test/ HTTP/1.1\r\nHost: example.test\r\n${auth}\r\n`)),'400','no credentials in addresses');
  assert.equal(status(await raw(guard,`GET https://example.test/ HTTP/1.1\r\nHost: example.test\r\n${auth}\r\n`)),'400','https must use CONNECT');
  assert.equal(status(await raw(guard,`GET ftp://example.test/ HTTP/1.1\r\nHost: example.test\r\n${auth}\r\n`)),'400');
  assert.equal(status(await raw(guard,`GET http://example.test/ HTTP/1.1\r\nHost: example.test\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n${auth}\r\n`)),'501','a bare Upgrade is not forwarded');
  assert.equal(status(await raw(guard,'\u0000\u0001 garbage\r\n\r\n')),undefined,'garbage gets no forwarding (the connection is dropped)');
  assert.deepEqual(connected,[]);
 }finally{await guard.close();}
});

test('the number of open connections is capped',async()=>{
 const echo=await tcpEcho();
 const guard=await startGuardProxy({maxConnections:4,resolver:async()=>[{address:PUBLIC}],connect:async()=>net.connect(echo.port,'127.0.0.1')});
 const holders=[];
 try{
  for(let i=0;i<8;i++){const s=net.connect(guard.port,'127.0.0.1');s.on('error',()=>{});holders.push(s);await new Promise(r=>s.once('connect',r));s.write(`CONNECT t${i}.test:443 HTTP/1.1\r\nProxy-Authorization: ${basic(guard)}\r\n\r\n`);await new Promise(r=>setTimeout(r,60));}
  const replies=await Promise.all(holders.map(s=>new Promise(r=>{let b='';s.on('data',d=>b+=d);setTimeout(()=>r(status(b)),200);})));
  assert.ok(replies.filter(x=>x==='200').length<=4&&replies.includes('503'),`some were turned away: ${replies}`);
 }finally{holders.forEach(s=>s.destroy());await guard.close();echo.close();}
});

test('closing the proxy ends every open connection',async()=>{
 const echo=await tcpEcho();const guard=await startGuardProxy({resolver:async()=>[{address:PUBLIC}],connect:async()=>net.connect(echo.port,'127.0.0.1')});
 const s=net.connect(guard.port,'127.0.0.1');s.on('error',()=>{});s.resume();await new Promise(r=>s.once('connect',r));s.write(`CONNECT t.test:443 HTTP/1.1\r\nProxy-Authorization: ${basic(guard)}\r\n\r\n`);await new Promise(r=>setTimeout(r,200));
 const closed=new Promise(r=>s.once('close',r));await guard.close();await Promise.race([closed,new Promise((_,j)=>setTimeout(()=>j(Error('connection stayed open')),2000))]);echo.close();
});

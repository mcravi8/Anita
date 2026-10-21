// A checking proxy for the private browser. Chrome sends every request through it (page loads, every redirect hop, images, scripts,
// frames, WebSockets), so each destination is checked once, at the moment of connecting, instead of only before a page is opened:
//  - the name is resolved here, every answer must be a public address, and the connection goes to the address that was checked, so a
//    site cannot answer "public" to the check and "your own computer" to the browser (DNS rebinding);
//  - a redirect hop, a subresource or a socket that points at the private network is refused like any other request;
//  - only a client that knows the per-session password may use it, and it listens on this Mac only.
import http from 'node:http';
import net, {isIP} from 'node:net';
import {lookup as dnsLookup} from 'node:dns/promises';
import {randomBytes, timingSafeEqual} from 'node:crypto';

export function publicAddress(ip) {
  if (isIP(ip) === 4) {
    const [a,b,c] = ip.split('.').map(Number);
    return !(a===0||a===10||a===127||a>=224||a===169&&b===254||a===172&&b>=16&&b<=31||a===192&&(b===168||b===0&&[0,2].includes(c))||a===100&&b>=64&&b<=127||a===198&&([18,19].includes(b)||b===51&&c===100)||a===203&&b===0&&c===113);
  }
  if(isIP(ip)===6) return /^2[0-9a-f]{3}:/i.test(ip)&&!ip.toLowerCase().startsWith('2001:db8:');
  return false;
}
const REFUSED='Local and private network pages are unavailable in Buddy’s browser.';
const privateName=name=>name==='localhost'||name.endsWith('.localhost')||name.endsWith('.local')||name.endsWith('.internal');
const defaultConnect=(address,port)=>new Promise((resolve,reject)=>{
  const socket=net.connect({host:address,port});
  const timer=setTimeout(()=>{socket.destroy();reject(Error('connect timeout'));},15000);
  socket.once('connect',()=>{clearTimeout(timer);socket.removeAllListeners('error');socket.setNoDelay(true);resolve(socket);});
  socket.once('error',error=>{clearTimeout(timer);reject(error);});
});
const splitHostPort=(value,fallback)=>{
  const match=/^\[([^\]]+)\](?::(\d+))?$/.exec(value)||/^([^:]+)(?::(\d+))?$/.exec(value);
  if(!match)return null;
  const port=match[2]?Number(match[2]):fallback;
  return port>=1&&port<=65535?{host:match[1].toLowerCase(),port}:null;
};

/** `allow` lists exact "host:port" destinations that are let through even though they are not public (the test fixture). `resolver` and
 *  `connect` can be replaced so tests can stand in for DNS and for the network. */
export async function startGuardProxy({resolver=dnsLookup,connect=defaultConnect,allow=[],onBlocked=()=>{},onEvent=()=>{},maxConnections=256}={}) {
  const password=randomBytes(24).toString('hex'),username='buddy',expected=Buffer.from('Basic '+Buffer.from(`${username}:${password}`).toString('base64'));
  const allowed=new Set(allow.map(x=>x.toLowerCase()));
  const sockets=new Set(),stats={allowed:0,blocked:0};
  const authorised=header=>{const given=Buffer.from(String(header||''));return given.length===expected.length&&timingSafeEqual(given,expected);};
  const refuse=(host,reason=REFUSED)=>{stats.blocked++;try{onBlocked(host,reason);}catch{}return Object.assign(Error(reason),{refused:true});};
  // Resolve once, check every answer, and connect to a checked address: the connection never depends on a second lookup.
  async function open(rawHost,port) {
    const host=rawHost.replace(/^\[|\]$/g,'').toLowerCase();
    if(allowed.has(`${host}:${port}`))return await connect(host,port);
    if(privateName(host))throw refuse(host);
    let addresses;
    try{addresses=isIP(host)?[{address:host}]:await resolver(host,{all:true,verbatim:true});}
    catch{throw Object.assign(Error('The name could not be resolved.'),{unresolved:true});}
    if(!addresses.length||addresses.some(entry=>!publicAddress(entry.address)))throw refuse(host);
    let last;
    for(const entry of addresses){try{return await connect(entry.address,port);}catch(error){last=error;}}
    throw last||Error('Could not connect.');
  }
  const track=socket=>{
    sockets.add(socket);socket.on('close',()=>sockets.delete(socket));socket.on('error',()=>{});
    socket.setTimeout(10*60*1000,()=>socket.destroy());
  };
  const deny=(socket,status,text)=>{
    if(!socket.writable)return;
    socket.end(`HTTP/1.1 ${status}\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: ${Buffer.byteLength(text)}\r\nConnection: close\r\n${status.startsWith('407')?'Proxy-Authenticate: Basic realm="Buddy"\r\n':''}\r\n${text}`);
  };

  const server=http.createServer(async(request,response)=>{
    request.socket.on('error',()=>{});
    onEvent({kind:'http',url:request.url,auth:!!request.headers['proxy-authorization']});
    if(!authorised(request.headers['proxy-authorization'])){response.writeHead(407,{'Proxy-Authenticate':'Basic realm="Buddy"','Content-Length':0,Connection:'close'});response.end();return;}
    let url;try{url=new URL(request.url);}catch{response.writeHead(400,{Connection:'close'});response.end('Not a proxy request.');return;}
    if(url.protocol!=='http:'||url.username||url.password){response.writeHead(400,{Connection:'close'});response.end('Only http addresses are forwarded here; https goes through CONNECT.');return;}
    if(sockets.size>=maxConnections){response.writeHead(503,{Connection:'close'});response.end('Too many connections.');return;}
    let upstream;
    try{upstream=await open(url.hostname,Number(url.port||80));}
    catch(error){response.writeHead(error.refused?403:502,{'Content-Type':'text/plain; charset=utf-8',Connection:'close'});response.end(error.refused?error.message:'Could not reach that address.');return;}
    track(upstream);stats.allowed++;
    const headers={...request.headers};for(const name of ['proxy-authorization','proxy-connection','connection','keep-alive','te','trailer','upgrade'])delete headers[name];
    headers.connection='close';
    const forward=http.request({createConnection:()=>upstream,method:request.method,path:url.pathname+url.search,headers,setHost:false});   // no agent: with an agent, Node would ignore createConnection and look the name up itself
    forward.on('response',answer=>{
      const reply={...answer.headers};for(const name of ['proxy-connection','connection','keep-alive'])delete reply[name];
      response.writeHead(answer.statusCode,answer.statusMessage,reply);answer.pipe(response);
    });
    forward.on('error',error=>{onEvent({kind:'forward-error',url:String(error.code||error.message),auth:true});if(!response.headersSent)response.writeHead(502,{'Content-Type':'text/plain; charset=utf-8',Connection:'close'});response.end('Could not reach that address.');});
    response.on('close',()=>{forward.destroy();upstream.destroy();});
    request.pipe(forward);
  });
  server.on('connect',async(request,client,head)=>{
    track(client);
    onEvent({kind:'connect',url:request.url,auth:!!request.headers['proxy-authorization']});
    if(!authorised(request.headers['proxy-authorization'])){deny(client,'407 Proxy Authentication Required','Proxy authentication required.');return;}
    const target=splitHostPort(request.url,443);
    if(!target){deny(client,'400 Bad Request','Not a valid destination.');return;}
    if(sockets.size>=maxConnections){deny(client,'503 Service Unavailable','Too many connections.');return;}
    let upstream;
    try{upstream=await open(target.host,target.port);}
    catch(error){deny(client,error.refused?'403 Forbidden':'502 Bad Gateway',error.refused?error.message:'Could not reach that address.');return;}
    track(upstream);stats.allowed++;
    if(!client.writable){upstream.destroy();return;}
    client.write('HTTP/1.1 200 Connection Established\r\n\r\n');
    if(head?.length)upstream.write(head);
    client.pipe(upstream);upstream.pipe(client);
    client.on('close',()=>upstream.destroy());upstream.on('close',()=>client.destroy());
  });
  // A WebSocket reaches here only as a CONNECT; a bare Upgrade request is not something this proxy forwards.
  server.on('upgrade',(request,socket)=>{track(socket);deny(socket,'501 Not Implemented','Upgrade requests are not forwarded.');});
  server.on('clientError',(error,socket)=>{try{socket.destroy();}catch{}});
  await new Promise((resolve,reject)=>{server.once('error',reject);server.listen(0,'127.0.0.1',resolve);});
  server.on('connection',track);
  return {
    port:server.address().port,username,password,stats,
    server:`http://127.0.0.1:${server.address().port}`,
    async close(){for(const socket of sockets)socket.destroy();await new Promise(resolve=>server.close(resolve));}
  };
}

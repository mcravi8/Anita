// Native Swift worker fixture using the real ClaudeSession protocol. No SDK query or network.
import {createInterface} from 'node:readline';
import {ClaudeSession} from '../claude-session.mjs';
const write=x=>process.stdout.write(JSON.stringify(x)+'\n');
const host=new ClaudeSession({
 tool:(name,description,schema,call)=>({name,call}),fromJSONSchema:()=>({shape:{}}),createSdkMcpServer:x=>x,write,
 startup:async({options})=>({close(){},query(){return {close(){},async *[Symbol.asyncIterator](){
  const tool=options.mcpServers.buddy.tools.find(t=>t.name==='buddy_browser');
  const value=await tool.call({operation:'open',url:'https://example.com'});
  const result=JSON.parse(value.content[0].text);
  if(!result.url||result.error)throw Error('Native browser response did not reach the selected model.');
  yield {type:'assistant',message:{content:[{type:'text',text:'Opened the website and checked the observed session.'}]}};
  yield {type:'result',result:'Opened the website and checked the observed session.',total_cost_usd:0.02,is_error:false};
 }};}})
});
for await(const line of createInterface({input:process.stdin})){
 const x=JSON.parse(line);
 if(x.command==='start')host.start(x).catch(e=>write({type:'error',runId:x.runId,error:e.message}));
 else if(x.command==='result')host.result(x);
}
host.close();

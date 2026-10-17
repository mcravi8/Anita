import {createInterface} from 'node:readline';
import {query,tool,createSdkMcpServer} from '@anthropic-ai/claude-agent-sdk';
import {z} from 'zod';
const write=x=>process.stdout.write(JSON.stringify(x)+'\n');
let started=false,next=0,pending=new Map(),session;
async function start(config){
  if(!config.apiKey||!Number.isFinite(config.budget)||config.budget<=0||config.budget>10)throw Error('Connect Claude API credits and set a task budget first.');
  const tools=config.tools.map(def=>{
    const schema=z.fromJSONSchema(def.inputSchema);
    return tool(def.name,def.description,schema.shape,async args=>new Promise(resolve=>{
      const id=String(++next);pending.set(id,resolve);write({type:'call',id,tool:def.name,arguments:args});
    }));
  });
  const safeEnv={PATH:process.env.PATH,HOME:config.home,TMPDIR:process.env.TMPDIR,ANTHROPIC_API_KEY:config.apiKey,CLAUDE_CONFIG_DIR:config.home,CLAUDE_AGENT_SDK_CLIENT_APP:'Buddy/0.12.0',DISABLE_AUTOUPDATER:'1',CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC:'1'};
  const names=config.tools.map(t=>'mcp__buddy__'+t.name);
  session=query({prompt:config.prompt,options:{cwd:config.cwd,env:safeEnv,settingSources:[],strictMcpConfig:true,plugins:[],tools:[],allowedTools:names,permissionMode:'dontAsk',persistSession:false,maxTurns:60,maxBudgetUsd:config.budget,model:config.model||'claude-sonnet-4-6',systemPrompt:config.instructions,mcpServers:{buddy:createSdkMcpServer({name:'buddy',version:'1.0.0',tools})},canUseTool:async name=>names.includes(name)?{behavior:'allow'}:{behavior:'deny',message:'Only Buddy tools are available.'}}});
  for await(const message of session){
    if(message.type==='assistant'){
      const text=message.message.content.filter(x=>x.type==='text').map(x=>x.text).join('\n');if(text)write({type:'progress',text});
    }
    if(message.type==='result')write({type:'result',text:message.result||'',error:message.is_error?(message.errors?.join('\n')||message.subtype):null,cost:message.total_cost_usd||0});
  }
}
for await(const line of createInterface({input:process.stdin})){
  try{
    const value=JSON.parse(line);
    if(value.command==='start'&&!started){started=true;start(value).then(()=>process.exit(0)).catch(e=>{write({type:'error',error:e.message});process.exit(1);});}
    else if(value.command==='result'&&pending.has(value.id)){const resolve=pending.get(value.id);pending.delete(value.id);resolve({content:[{type:'text',text:JSON.stringify(value.result)}],isError:!!value.result?.error});}
    else if(value.command==='stop'){session?.close();process.exit(0);}
  }catch{write({type:'error',error:'Invalid Claude bridge message.'});}
}
session?.close();

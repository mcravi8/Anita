// A ready SDK process is single use: every turn keeps its own budget and context.
// Preparing the next process performs the SDK handshake, never a model query.
function canonical(value){
  if(Array.isArray(value))return value.map(canonical);
  if(value&&typeof value==='object')return Object.fromEntries(Object.keys(value).sort().map(key=>[key,canonical(value[key])]));
  return value;
}
export class ClaudeSession {
  constructor({startup,tool,createSdkMcpServer,fromJSONSchema,write}) {
    Object.assign(this,{startup,tool,createSdkMcpServer,fromJSONSchema,write});
    this.pending=new Map();this.next=0;this.warm=null;this.signature=null;this.busy=false;this.closed=false;
  }
  options(config) {
    const tools=config.tools.map(def=>this.tool(def.name,def.description,this.fromJSONSchema(def.inputSchema).shape,args=>new Promise(resolve=>{
      const id=String(++this.next);this.pending.set(id,resolve);this.emit({type:'call',id,tool:def.name,arguments:args});
    })));
    const names=config.tools.map(t=>'mcp__buddy__'+t.name);
    return {cwd:config.cwd,env:{PATH:process.env.PATH,HOME:config.home,TMPDIR:process.env.TMPDIR,ANTHROPIC_API_KEY:config.apiKey,CLAUDE_CONFIG_DIR:config.home,CLAUDE_AGENT_SDK_CLIENT_APP:'Buddy/0.16.0',DISABLE_AUTOUPDATER:'1',CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC:'1'},settingSources:[],strictMcpConfig:true,plugins:[],tools:[],allowedTools:names,permissionMode:'dontAsk',persistSession:false,maxTurns:60,maxBudgetUsd:config.budget,...(config.outputSchema?{outputFormat:{type:'json_schema',schema:config.outputSchema}}:{}),model:config.model||'claude-sonnet-4-6',systemPrompt:config.instructions,mcpServers:{buddy:this.createSdkMcpServer({name:'buddy',version:'1.0.0',tools})},canUseTool:async name=>!this.closed&&this.busy&&names.includes(name)?{behavior:'allow'}:{behavior:'deny',message:'Only current Buddy tools are available.'}};
  }
  emit(event){this.write({...event,runId:this.runId});}
  async prepare(config) {
    const {prompt,command,runId,...stable}=config;
    const signature=JSON.stringify(canonical(stable));
    if(this.signature===signature&&this.warm)return;
    this.discardWarm();this.signature=signature;
    const prepared=this.startup({options:this.options(config),initializeTimeoutMs:30000});
    this.warm=prepared;
    try {const handle=await prepared;if(this.closed||this.warm!==prepared)handle.close();}
    catch(error){if(this.warm===prepared){this.warm=null;this.signature=null;}throw error;}
  }
  discardWarm(){const old=this.warm;this.warm=null;this.signature=null;old?.then(h=>h.close(),()=>{});}
  async start(config) {
    if(this.closed||this.busy)throw Error('The Claude connection is already in use or closed.');
    if(!config.apiKey||!Number.isFinite(config.budget)||config.budget<=0||config.budget>10)throw Error('Connect Claude API credits and set a task budget first.');
    this.busy=true;this.runId=config.runId;let result;
    try {
      await this.prepare(config);
      const warm=await this.warm;this.warm=null;this.signature=null;
      this.session=warm.query(config.prompt);
      for await(const message of this.session){
        if(message.type==='assistant'){
          const text=message.message.content.filter(x=>x.type==='text').map(x=>x.text).join('\n');if(text)this.emit({type:'progress',text});
        }
        if(message.type==='result')result={type:'result',text:message.structured_output?JSON.stringify(message.structured_output):message.result||'',error:message.is_error?(message.errors?.join('\n')||message.subtype):null,cost:message.total_cost_usd||0};
      }
    } catch(error){if(!this.closed)this.emit({type:'error',error:error.message});}
    finally {
      this.session?.close();this.session=null;this.busy=false;
      for(const resolve of this.pending.values())resolve({content:[{type:'text',text:'This turn ended.'}],isError:true});this.pending.clear();
      if(!this.closed){this.prepare(config).catch(()=>{});if(result)this.emit(result);}
    }
  }
  result(value){if(value.runId!==undefined&&value.runId!==this.runId)return;const resolve=this.pending.get(value.id);if(resolve){this.pending.delete(value.id);resolve({content:[{type:'text',text:JSON.stringify(value.result)}],isError:!!value.result?.error});}}
  close(){this.closed=true;this.discardWarm();this.session?.close();}
}

import {createLedger} from './token-ledger.mjs';
// A run has no limit of its own: error_max_budget_usd means the agent's daily limit ran out, which is a pause that continues by itself.
const stopReasons={error_max_budget_usd:'Today’s spending limit for this agent was reached. It continues tomorrow or after the user raises the daily limit.',error_max_turns:'It reached its limit on steps before it could finish. Continue it to keep going.',error_during_execution:'Claude hit an error while working.'};
const stopText=message=>message.errors?.length?message.errors.join('\n'):(message.subtype&&message.subtype!=='success'?(stopReasons[message.subtype]||message.subtype):(message.result||'Claude stopped before finishing.'));
export class CodingSession {
  constructor({query,tool,createSdkMcpServer,fromJSONSchema,write,ledgerPath}){Object.assign(this,{query,tool,createSdkMcpServer,fromJSONSchema,write,ledgerPath});this.pending=new Map();this.next=0;this.busy=false;this.closed=false;}
  emit(event){this.write({...event,runId:this.runId});}
  async start(config){
    if(this.closed||this.busy)throw Error('This coding session is busy or stopped.');
    // A run has no ceiling of its own (budget is null); a number here is only what a daily limit leaves room for.
    if(!config.apiKey||(config.budget!=null&&(!Number.isFinite(config.budget)||config.budget<=0)))throw Error('Connect Claude API credits first.');
    if(config.resume&&!/^[0-9a-f-]{36}$/i.test(config.resume))throw Error('Invalid saved coding session.');
    this.busy=true;this.runId=config.runId;
    const names=config.tools.map(t=>'mcp__buddy__'+t.name);
    const tools=config.tools.map(def=>this.tool(def.name,def.description,this.fromJSONSchema(def.inputSchema).shape,args=>new Promise(resolve=>{
      const id=String(++this.next);this.pending.set(id,resolve);this.emit({type:'call',id,tool:def.name,arguments:args});
    })));
    // lastText is the last thing the model said: a run that stops without a final result (a limit, an error) still reports what it had done.
    let result,lastActivity=0,lastText='';
    // Off unless a ledger path is set (BUDDY_TOKEN_LEDGER): then each model call's usage and input sizes are appended to that file.
    const ledger=createLedger(this.ledgerPath,{runId:config.runId,bridge:'coding-session'});ledger?.begin(config);
    try{
      this.session=this.query({prompt:config.prompt,options:{cwd:config.cwd,env:{PATH:process.env.PATH,HOME:config.home,TMPDIR:process.env.TMPDIR,ANTHROPIC_API_KEY:config.apiKey,CLAUDE_CONFIG_DIR:config.home,CLAUDE_AGENT_SDK_CLIENT_APP:'Buddy/0.18.0',DISABLE_AUTOUPDATER:'1',CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC:'1'},
        settingSources:[],plugins:[],strictMcpConfig:true,tools:[],allowedTools:names,permissionMode:'dontAsk',persistSession:true,includePartialMessages:true,...(config.resume?{resume:config.resume}:{}),model:config.model||'claude-sonnet-4-6',maxTurns:100,...(config.budget!=null?{maxBudgetUsd:config.budget}:{}),
        systemPrompt:{type:'preset',preset:'claude_code',append:config.instructions},mcpServers:{buddy:this.createSdkMcpServer({name:'buddy',version:'1.0.0',tools})}}});
      for await(const message of this.session){
        ledger?.observe(message);
        if(message.type==='stream_event'&&Date.now()-lastActivity>2000){lastActivity=Date.now();this.emit({type:'activity'});}
        if(message.type==='system'&&message.subtype==='init')this.emit({type:'session',sessionId:message.session_id});
        if(message.type==='assistant'){
          const text=message.message.content.filter(x=>x.type==='text').map(x=>x.text).join('\n');if(text){lastText=text;this.emit({type:'progress',text});}
        }
        if(message.type==='result')result={type:'result',text:message.result||lastText,subtype:message.subtype||'',error:message.is_error?stopText(message):null,cost:message.total_cost_usd||0,sessionId:message.session_id};
      }
      if(!this.closed)this.emit(result||{type:'error',error:'The coding session ended without a confirmed result.'});
    }catch(error){
      // A run that ended in a failed result (step or budget limit) has already been charged. The error that follows ends the task, so
      // deliver the result first or its cost is never recorded and the unused budget is never released.
      if(!this.closed){if(result?.error){this.emit(result);result=null;}this.emit({type:'error',error:error.message});}
    }
    finally{ledger?.end();this.session?.close();this.session=null;this.busy=false;for(const resolve of this.pending.values())resolve({content:[{type:'text',text:'Coding session ended.'}],isError:true});this.pending.clear();}
  }
  result(value){if(value.runId!==this.runId)return;const done=this.pending.get(value.id);if(done){this.pending.delete(value.id);done({content:[{type:'text',text:JSON.stringify(value.result)}],isError:!!value.result?.error});}}
  close(){this.closed=true;this.session?.close();for(const resolve of this.pending.values())resolve({content:[{type:'text',text:'Coding session stopped.'}],isError:true});this.pending.clear();}
}

import {appendFileSync} from 'node:fs';
// Opt-in token ledger for Claude runs: off unless BUDDY_TOKEN_LEDGER names a file. One JSON line per model call with the SDK's usage
// and the size, in characters, of each part of that call's input (instructions, tool schemas, briefing, live-work context, history,
// file contents, other tool output, the model's own earlier output). Sizes only, never content. It can never affect a run: every
// failure is swallowed.
const FILE_TOOLS=/(^|__)buddy_(read_file|read_binary_file|read_chat_history|search_files)$/;
const textSize=content=>typeof content==='string'?content.length:Array.isArray(content)?content.reduce((n,x)=>n+(typeof x?.text==='string'?x.text.length:0),0):0;
const usageOf=u=>({input:u?.input_tokens||0,cacheRead:u?.cache_read_input_tokens||0,cacheWrite:u?.cache_creation_input_tokens||0,output:u?.output_tokens||0});

/// How much of a prompt is briefing, live-work context (earlier tasks' results, user updates, the supervisor's plan and ledger) and
/// chat history, in characters.
export function promptParts(prompt){
  const text=typeof prompt==='string'?prompt:JSON.stringify(prompt??'');
  if(text.startsWith('{'))try{
    const brief=JSON.parse(text);
    if(brief&&typeof brief==='object'&&('plan' in brief||'ledger' in brief)){const live=['plan','ledger'].reduce((n,k)=>n+(k in brief?JSON.stringify(brief[k]).length:0),0);return {briefing:text.length-live,live,history:0};}
  }catch{}
  const history=text.match(/^Previous real (?:direct )?conversation[\s\S]*?(?=\n\nCurrent (?:user )?request:\n)/)?.[0].length||0;
  let live=0;
  for(const m of text.matchAll(/^(?:Inputs from earlier tasks|Updates from the user)[\s\S]*?(?=\n(?:Stage boundary:|Decisions:|Updates from the user:)|(?![\s\S]))/gm))live+=m[0].length;
  return {briefing:text.length-history-live,live,history};
}

export function createLedger(path,{runId,bridge,provider='claude',now=()=>new Date().toISOString()}={}){
  if(!path)return null;
  const chars={instructions:0,tools:0,briefing:0,live:0,history:0,file:0,tool:0,own:0},names=new Map();
  let call=null,calls=0;
  const write=line=>{try{appendFileSync(path,JSON.stringify({v:1,at:now(),provider,bridge,runId,...line})+'\n');}catch{}};
  // A call ends when its tool results come back, the next reply starts or the run ends; its output then joins later calls' input.
  const flush=()=>{if(!call)return;write({type:'call',call:++calls,model:call.model,usage:usageOf(call.usage),chars:call.chars});chars.own+=call.out;call=null;};
  const guard=f=>(...args)=>{try{f(...args);}catch{}};
  return {
    begin:guard(({instructions,tools,prompt}={})=>{
      chars.instructions=(instructions||'').length;chars.tools=JSON.stringify(tools||[]).length;Object.assign(chars,promptParts(prompt||''));
    }),
    observe:guard(message=>{
      if(message?.type==='assistant'){
        const m=message.message;if(!m?.id)return;
        if(call&&call.id!==m.id)flush();
        if(!call)call={id:m.id,model:m.model||'',chars:{...chars},out:0};
        call.usage=m.usage;
        for(const block of m.content||[]){
          if(block.type==='tool_use'){names.set(block.id,block.name||'');call.out+=(block.name||'').length+JSON.stringify(block.input??{}).length;}
          else call.out+=(block.text||block.thinking||'').length;
        }
      } else if(message?.type==='user'){
        const results=(Array.isArray(message.message?.content)?message.message.content:[]).filter(x=>x?.type==='tool_result');
        if(results.length)flush();
        for(const r of results)chars[FILE_TOOLS.test(names.get(r.tool_use_id)||'')?'file':'tool']+=textSize(r.content);
      } else if(message?.type==='result'){
        flush();write({type:'run',calls,subtype:message.subtype||'',usage:usageOf(message.usage),cost:message.total_cost_usd||0});
      }
    }),
    end:guard(()=>flush()),
  };
}

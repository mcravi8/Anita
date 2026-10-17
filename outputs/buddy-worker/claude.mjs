import {createInterface} from 'node:readline';
import {startup,tool,createSdkMcpServer} from '@anthropic-ai/claude-agent-sdk';
import {z} from 'zod';
import {ClaudeSession} from './claude-session.mjs';
const write=x=>process.stdout.write(JSON.stringify(x)+'\n');
const host=new ClaudeSession({startup,tool,createSdkMcpServer,fromJSONSchema:z.fromJSONSchema,write});
for await(const line of createInterface({input:process.stdin})){
  try{
    const value=JSON.parse(line);
    if(value.command==='start')host.start(value).catch(e=>write({type:'error',runId:value.runId,error:e.message}));
    else if(value.command==='result')host.result(value);
    else if(value.command==='stop'){host.close();process.exit(0);}
  }catch{write({type:'error',error:'Invalid Claude bridge message.'});}
}
host.close();

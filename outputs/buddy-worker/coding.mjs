import {createInterface} from 'node:readline';
import {query,tool,createSdkMcpServer} from '@anthropic-ai/claude-agent-sdk';
import {z} from 'zod';
import {CodingSession} from './coding-session.mjs';
const write=x=>process.stdout.write(JSON.stringify(x)+'\n');
const host=new CodingSession({query,tool,createSdkMcpServer,fromJSONSchema:z.fromJSONSchema,write});
process.on('SIGTERM',()=>{host.close();process.exit(0);});
for await(const line of createInterface({input:process.stdin})){
  try{const value=JSON.parse(line);if(value.command==='start')host.start(value).catch(error=>write({type:'error',runId:value.runId,error:error.message}));else if(value.command==='result')host.result(value);else if(value.command==='stop'){host.close();process.exit(0);}}
  catch{write({type:'error',error:'Invalid coding session message.'});}
}
host.close();

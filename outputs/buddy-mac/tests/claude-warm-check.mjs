// Read-only SDK lifecycle smoke: initialization only, no prompt or model spend.
import {startup} from '../../buddy-worker/node_modules/@anthropic-ai/claude-agent-sdk/sdk.mjs';
import {mkdtemp,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
const dir=await mkdtemp(join(tmpdir(),'buddy-sdk-init.noindex-'));
try{
 const ready=await startup({options:{cwd:dir,env:{PATH:process.env.PATH,HOME:dir,TMPDIR:dir,CLAUDE_CONFIG_DIR:dir,DISABLE_AUTOUPDATER:'1',CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC:'1'},settingSources:[],strictMcpConfig:true,plugins:[],tools:[],permissionMode:'dontAsk',persistSession:false,maxTurns:60,maxBudgetUsd:0.5},initializeTimeoutMs:30000});
 ready.close();console.log('PASS: installed Claude SDK prepares a ready process without a prompt or credentials.');
}finally{await rm(dir,{recursive:true,force:true});}

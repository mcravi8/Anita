const test=require('node:test'),assert=require('node:assert/strict');
const F=require('./buddy-figures.js'),E=F.engine;
F.configure({agent:id=>({a:{id:'a',avatarShape:'sphere',avatarColor:'blue'}})[id]||null,group:id=>id==='g'?{id:'g',members:['a','gone']}:id==='empty'?{id:'empty',members:['gone']}:null,agentIds:()=>['a']});
const lit=(shape,size=25,tweak=()=>{})=>{
  const M=E.mkSim(),r=E.mkR(M,shape,'lilac',{x:0,y:0,s:1.12},1);tweak(r);
  const P=2.6,half=size,N=Math.ceil(2*half/P)+2,grid=Array.from({length:N},()=>Array(N).fill(0));
  E.headCells((i,j,v)=>{if(i>=0&&j>=0&&i<N&&j<N)grid[j][i]=Math.max(grid[j][i],v);},N*P/2,N*P/2,half,[r],{order:[0],rings:true,group:0},P,N,N);
  return {grid,N,at:(x,y)=>grid[Math.round(N/2+y*half/P-.5)][Math.round(N/2+x*half/P-.5)]};
};
test('legacy shape and colour ids migrate to the figure set and unknown ids fall back',()=>{
  assert.deepEqual(['star','pebble','cube','clover'].map(F.normShape),['diamond','sphere','hex','pill']);
  assert.deepEqual(['diamond','sphere','hex','pill'].map(F.normShape),['diamond','sphere','hex','pill']);
  assert.equal(F.normShape('blob'),'diamond');assert.equal(F.normShape(undefined),'diamond');
  assert.equal(F.normColor('rose'),'red');assert.equal(F.normColor('stone'),'cobalt');assert.equal(F.normColor('nope'),'lilac');assert.equal(F.normColor('gold'),'gold');
});
test('every shape is a filled head with the eyes cut out and nothing outside the circle',()=>{
  for(const shape of F.SHAPES){
    const {grid,at,N}=lit(shape);
    assert.ok(at(0,.35)>.6,`${shape}: body below the eyes is solid`);
    assert.ok(at(F.engine.EYEDX[shape],-.03)<.2,`${shape}: right eye is empty`);
    assert.ok(at(-F.engine.EYEDX[shape],-.03)<.2,`${shape}: left eye is empty`);
    assert.equal(grid[0][0],0);assert.equal(grid[N-1][N-1],0);
  }
});
test('the shapes are distinct silhouettes',()=>{
  const counts=Object.fromEntries(F.SHAPES.map(s=>[s,lit(s).grid.flat().filter(v=>v>.5).length]));
  assert.equal(new Set(Object.values(counts)).size,4,JSON.stringify(counts));
  const rowWidth=(shape,y)=>lit(shape).grid[Math.round(lit(shape).N/2+y*25/2.6-.5)].filter(v=>v>.3).length;
  assert.ok(rowWidth('pill',0)>rowWidth('diamond',.7),'pill is wider than a diamond near the edge');
});
test('eyes grow as the figure shrinks and close when blinking',()=>{
  assert.deepEqual(E.gridFor(176,false),[45,1]);assert.deepEqual(E.gridFor(50,false),[25,1.4]);assert.deepEqual(E.gridFor(32,false),[19,1.8]);
  const [n,es]=E.gridFor(50,true);assert.equal(n,31);assert.ok(Math.abs(es-1.82)<1e-9);
  const open=lit('pill',25,r=>{r.open=1;}),shut=lit('pill',25,r=>{r.open=.05;});
  assert.ok(open.at(.2,-.03)<.2);assert.ok(shut.at(.2,-.03)>.4,'a closed eye fills in');
});
test('modes move the springs the way the design says',()=>{
  const run=(mode,seconds=2,attn=false)=>{const M=E.mkSim();let t=0;for(;t<seconds;t+=1/60)E.stepSim(M,mode,null,t,1/60,attn);return M;};
  const working=run('working');assert.ok(working.S.work.x>.8&&working.S.eyeH.x<.95,'working: progress ring on, eyes lowered');
  const stuck=run('stuck');assert.ok(Math.abs(stuck.S.tilt.x-.13)<.01&&Math.abs(stuck.S.eyeH.x-.75)<.02,'stuck: tilt and narrowed eyes');
  const done=run('done');assert.ok(done.S.happy.x>.9&&done.spinT>=0,'done: happy eyes and a spin');
  const needs=run('needs',3);assert.ok(needs.pulseT>0&&needs.S.eyeH.x>1.1,'needs: pulses and widens its eyes');
  const ready=run('ready');assert.ok(Math.abs(ready.S.work.x)<.01&&Math.abs(ready.S.tilt.x)<.01);
  assert.ok(run('ready',2,true).S.eyeH.x>1.1,'attention widens the eyes 14%');
});
test('a spin turns the body once and eyes stay upright',()=>{
  const M=E.mkSim();E.stepSim(M,'done',null,0,1/60,false);
  assert.equal(E.mkR(M,'pill','mint',{x:0,y:0,s:1},.05).rot,0);
  const mid=E.mkR(M,'pill','mint',{x:0,y:0,s:1},.5).rot,end=E.mkR(M,'pill','mint',{x:0,y:0,s:1},1.05).rot;
  assert.ok(mid>0&&mid<Math.PI*2);assert.ok(Math.abs(end-Math.PI*2)<.05);
  assert.equal(E.mkR(M,'diamond','mint',{x:0,y:0,s:1},-5).rot,Math.PI/4,'a diamond rests on its point');
});
test('gaze follows the focus vector and ink follows the theme',()=>{
  const M=E.mkSim();for(let t=0;t<2;t+=1/60)E.stepSim(M,'ready',[.5,-.2],t,1/60,false);
  assert.ok(Math.abs(M.S.lx.x-.5)<.02&&Math.abs(M.S.ly.x+.2)<.02);
  E.setDark(false);const light=E.mkR(M,'pill','lilac',{x:0,y:0,s:1},1).ink;E.setDark(true);const dark=E.mkR(M,'pill','lilac',{x:0,y:0,s:1},1).ink;E.setDark(false);
  assert.deepEqual(light,[0x8a,0x63,0xd2]);assert.deepEqual(dark,[0xb9,0xa0,0xeb]);
});
test('avatar markup targets a live agent, an unsaved look, a group, or the logo',()=>{
  assert.match(F.avatarHTML({id:'a'},34),/data-fig="agent" data-fig-id="a" data-size="34"/);
  const inline=F.avatarHTML({id:'new',avatarShape:'cube',avatarColor:'rose'},40);
  assert.match(inline,/data-shape="hex" data-color="red"/);assert.doesNotMatch(inline,/data-fig-id/);
  assert.match(F.avatarHTML({id:'g',members:['a','gone']},50),/data-fig="group" data-fig-id="g"/);
  assert.match(F.avatarHTML({id:'empty',members:['gone']},50),/data-fig="logo"/);
  assert.match(F.logoHTML(44),/data-fig="logo" .*data-size="44"/);
  assert.match(F.avatarHTML({id:'a"><img src=x onerror=1>'},30),/data-shape="diamond"/);
  assert.doesNotMatch(F.avatarHTML({id:'g',members:['a'],name:'<b>'},30),/<b>/);
  assert.doesNotMatch(F.slotHTML('agent','x"><script>','50'),/<script>/);
});
test('slots keep a head in the field instead of its own canvas',()=>{
  assert.match(F.slotAvatarHTML({id:'a'},50),/data-slot="row:a" data-kind="agent" data-fig-id="a" data-size="50"/);
  assert.match(F.slotAvatarHTML({id:'g',members:['a']},50),/data-kind="group"/);
  assert.match(F.slotAvatarHTML({id:'empty',members:['gone']},50),/data-slot="row:empty" data-kind="logo"/);
  assert.match(F.slotHTML('logo','',44,'logo'),/data-slot="logo"/);
});
test('a transient mode returns to ready on its own timer',async()=>{
  const mock=require('node:test').mock;mock.timers.enable({apis:['setTimeout']});
  F.setMode('a','done');assert.equal(F.getMode('a'),'done');mock.timers.tick(1699);assert.equal(F.getMode('a'),'done');mock.timers.tick(2);assert.equal(F.getMode('a'),'ready');
  F.setMode('a','stuck');mock.timers.tick(7000);assert.equal(F.getMode('a'),'stuck');mock.timers.tick(1100);assert.equal(F.getMode('a'),'ready');
  F.setMode('a','working');mock.timers.tick(60000);assert.equal(F.getMode('a'),'working','working never times out');
  F.setMode('a','ready');mock.timers.reset();
});
test('reduced motion drops the idle life but keeps every signal of state',()=>{
  const run=(mode,calm,seconds=4)=>{const M=E.mkSim();let blinked=false,sy=[];for(let t=0;t<seconds;t+=1/60){E.stepSim(M,mode,null,t,1/60,false,calm);if(M.blinkT>=0)blinked=true;sy.push(M.S.sy.x);}return {M,blinked,swing:Math.max(...sy)-Math.min(...sy)};};
  assert.ok(run('ready',false,6).blinked,'a normal figure blinks');assert.ok(!run('ready',true,6).blinked,'a calm figure does not');
  assert.ok(run('working',false).swing>.01&&run('working',true).swing<.001,'no working bob when calm');
  assert.ok(run('working',true).M.S.work.x>.8,'the progress ring still shows');
  assert.ok(run('needs',true).M.pulseT>0&&run('needs',true).M.S.by.x===0,'the needs pulse stays, the hop does not');
  assert.ok(run('done',true).M.S.happy.x>.9&&run('done',true).M.spinT<0,'happy eyes stay, the spin does not');
  assert.ok(Math.abs(run('stuck',true).M.S.tilt.x-.13)<.01,'stuck still tilts');
  const M=E.mkSim();for(let t=0;t<2;t+=1/60)E.stepSim(M,'ready',[.5,-.2],t,1/60,false,true);
  assert.ok(Math.abs(M.S.lx.x-.5)<.02,'gaze toward the user or another agent is information, so it stays');
});

test('a working group\'s ring goes round and round at full strength, however many of its members are working, without starting again',()=>{
  // One of four members working used to cap the sweep at a quarter, two at half: the ring showed the members' average progress. Then it
  // filled up, held and jumped back to empty; now its light goes round continuously.
  const members=working=>[0,1,2,3].map(k=>({work:k<working?1:0,prog:k<working?.6:0}));
  for(const working of [1,2,3,4]){
    let most=0,least=1,jump=0,prev=E.groupSweep(members(working),0).gprog;
    for(let t=.02;t<12;t+=.02){const g=E.groupSweep(members(working),t).gprog;most=Math.max(most,g);least=Math.min(least,g);const step=((g-prev)%1+1)%1;jump=Math.max(jump,step);prev=g;}
    assert.ok(most>.99&&least<.01,`${working} working: the light goes all the way round`);
    assert.ok(jump<.02,`${working} working: it moves at one pace, never jumping back to the start (largest step ${jump})`);
    assert.equal(E.groupSweep(members(working),1).group,1,`${working} working: the ring shows at full strength`);
  }
  assert.equal(E.groupSweep(members(0),1).group,0,'nobody working: no ring');
});

test('the working light is brightest where it is, fades behind it, and the track never goes dark',()=>{
  assert.ok(Math.abs(E.trail(.5,.5)-1)<1e-9,'full at the light itself');
  assert.ok(E.trail(.5,.4)>E.trail(.5,.25)&&E.trail(.5,.25)>E.trail(.5,.6),'it fades behind the light, and just ahead of it is the dimmest');
  for(let at=0;at<1;at+=.01)assert.ok(E.trail(.3,at)>=.08,'the faint track shows all the way round');
  assert.ok(Math.abs(E.trail(.02,.98)-E.trail(1.02,.98))<1e-9,'the same light after a full lap');
  // A single agent's ring goes round the same way, and never resets while it works.
  const M=E.mkSim(),pos=[];for(let t=0;t<9;t+=.05){E.stepSim(M,'working',null,t,.05,0,false,false);pos.push(M.prog);}
  assert.ok(pos.every(p=>p>=0&&p<1));
  assert.ok(pos.slice(1).every((p,i)=>((p-pos[i])%1+1)%1<.03),'one pace, all the way round');
});

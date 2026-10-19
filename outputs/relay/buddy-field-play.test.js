const test=require('node:test'),assert=require('node:assert/strict');
const Figures=require('./buddy-figures.js');
globalThis.BuddyFigures=Figures;
const Play=require('./buddy-field-play.js');
const E=Figures.engine;

// A repeatable source of "random" numbers.
const seeded=(seed=1)=>()=>{seed=(seed*16807)%2147483647;return seed/2147483647;};

test('the background patterns form, hold, fade and rest, and never repeat the pattern that just ended',()=>{
  const random=seeded(7);
  let {sv,k}=Play.saverAt(null,0,random);
  assert.equal(k,0,'starts empty');
  const at=t=>Play.saverAt(sv,t,random).k;
  assert.ok(at(Play.FORM/2)>.4&&at(Play.FORM/2)<.6,'forming');
  assert.equal(at(Play.FORM+1),1,'holding');
  assert.ok(at(Play.FORM+Play.HOLD+Play.FADE/2)>.4&&at(Play.FORM+Play.HOLD+Play.FADE/2)<.6,'fading');
  assert.equal(at(Play.FORM+Play.HOLD+Play.FADE+1),0,'resting');
  const seen=new Set();
  for(let cycle=1;cycle<=40;cycle++){const before=sv.idx;Play.saverAt(sv,cycle*(Play.CYCLE+.1),random);assert.notEqual(sv.idx,before,'a new pattern each cycle');seen.add(sv.idx);}
  assert.ok(seen.size>=5,'and the cycle visits many patterns');
});

test('a pattern is drawn in a scattered order: more of it appears as it forms, and every cell it lights is inside the field',()=>{
  const count=(idx,k)=>{const cells=new Set();Play.saverCells(idx,k,60,90,.04,(i,j,v)=>{assert.ok(i>=0&&j>=0&&i<60&&j<90);assert.ok(v>0&&v<=.04+1e-9);cells.add(i+','+j);});return cells;};
  for(let idx=0;idx<Play.PATS.length;idx++){
    const a=count(idx,.3),b=count(idx,.7),c=count(idx,1);
    assert.ok(a.size<=b.size&&b.size<=c.size,`pattern ${idx} only grows while it forms`);
    for(const cell of a)assert.ok(b.has(cell),'a lit cell stays lit as the pattern forms');
    assert.ok(c.size>5,`pattern ${idx} is visible once formed`);
    assert.equal(count(idx,0).size,0,'nothing at progress 0');
  }
});

test('unread counts are drawn as dot-matrix digits, and nine plus a bit shows 9+',()=>{
  assert.equal(Play.countText(0),'0');assert.equal(Play.countText(7),'7');assert.equal(Play.countText(9),'9');assert.equal(Play.countText(10),'9+');assert.equal(Play.countText(250),'9+');
  assert.equal(Play.glyphWidth('7'),3);assert.equal(Play.glyphWidth('9+'),7);
  for(const digit of '0123456789+'){
    const cells=Play.glyphCells(digit);
    assert.ok(cells.length>=5,`${digit} has dots`);
    for(const c of cells){assert.ok(c.gi>=0&&c.gi<3&&c.gj>=0&&c.gj<5,'inside the 3 x 5 cell grid');}
  }
  const two=Play.glyphCells('9+'),columns=new Set(two.map(c=>c.c));
  assert.deepEqual([...columns].sort(),[0,1],'each character is its own column group');
  // Different digits look different.
  const key=d=>Play.glyphCells(d).map(c=>`${c.gi}${c.gj}`).join();
  assert.equal(new Set([...'0123456789'].map(key)).size,10);
});

test('roots grow out of the head, stay inside the row, branch, and are the same every time for the same dice',()=>{
  const bounds={x0:-28,x1:250,y0:-29,y1:29};
  const make=seed=>Play.makeRoots({bounds,r0:15,ids:2,random:seeded(seed)});
  const a=make(3),b=make(3),c=make(11);
  assert.deepEqual(a.pts,b.pts,'repeatable');
  assert.notDeepEqual(a.pts,c.pts,'but different dice grow different roots');
  assert.ok(a.pts.length>200&&a.pts.length<=2600,`a good number of points: ${a.pts.length}`);
  assert.ok(a.tips.length>=12,'at least one tip per root');
  for(const p of a.pts){assert.ok(p.x>bounds.x0&&p.x<bounds.x1&&p.y>bounds.y0&&p.y<bounds.y1,'never leaves the row');assert.ok(p.ci===0||p.ci===1,'each root has one of the group’s inks');}
  assert.ok(a.pts.some(p=>p.w>0),'some roots branch');
  assert.ok(a.smax>100,'and they reach across the row');
  const near=a.pts.filter(p=>p.s<=2.5);
  assert.ok(near.every(p=>Math.hypot(p.x,p.y)<20),'they start at the head');
});

test('the thought cloud grows with its progress, sits above the head, and is empty at zero',()=>{
  const cells=(grow,t=0)=>{const out=[];E_cloud(grow,t,out);return out;};
  const E_cloud=(grow,t,out)=>Play.cloudCells(60,100,25,grow,t,0,2.6,100,100,(i,j,v)=>out.push({i,j,v}),false);
  const none=cells(0),some=cells(1);
  assert.ok(some.length>40,`a cloud is a good number of cells: ${some.length}`);
  assert.ok(none.length<some.length/2,'smaller while it is still growing in');
  for(const c of some){assert.ok(c.v>0&&c.v<=1);assert.ok((c.j+.5)*2.6<100,'above the head’s centre');assert.ok((c.i+.5)*2.6>=60-3,'to the right of the head’s centre line');}
  const flat=(t)=>{const out=[];Play.cloudCells(60,100,25,1,t,0,2.6,100,100,(i,j,v)=>out.push(i+','+j+','+v.toFixed(3)),true);return out.join(';');};
  assert.equal(flat(0),flat(5),'reduced motion: the cloud is a still picture');
  assert.notEqual(cells(1,0).map(c=>c.j).join(),cells(1,.7).map(c=>c.j).join(),'otherwise it drifts');
});

// ---- the part that plugs into the figures ----
function host(extra={}){
  const sims={};
  const cfg={agent:id=>['a','b'].includes(id)?{id}:null,group:id=>id==='g'?{members:['a','b']}:null,agentIds:()=>['a','b'],groupIds:()=>['g'],replies:()=>0,...extra.cfg};
  const modes={...extra.modes};
  return {clock:0,dt:1/60,calm:false,ids:['a','b'],cfg,sim:id=>sims[id]||(sims[id]=E.mkSim()),getMode:id=>modes[id]||'ready',sims,modes};
}
function reset(){
  const s=Play.state;s.sleepAfter=Play.SLEEP_AFTER;s.asleep=false;s.lastAct=0;s.awake.clear();s.unread={};s.seen={};s.arrivals=[];s.keys=[];s.bursts=[];s.zzz=[];s.typingT=null;s.viewing=null;s.sv=null;s.prevSel=null;s.cloud={};
}
const advance=(h,seconds)=>{h.clock+=seconds;Play.extension.frame(h);};

test('agents fall asleep after fifteen idle seconds, but never while something is running, and only ready agents sleep',()=>{
  reset();const h=host();
  Play.extension.frame(h);
  advance(h,14);assert.equal(Play.state.asleep,false,'not yet');
  advance(h,2);assert.equal(Play.state.asleep,true,'after fifteen seconds');
  assert.equal(Play.extension.sleeping('a',{known:true,mode:'ready'}),true);
  assert.equal(Play.extension.sleeping('a',{known:true,mode:'working'}),false,'a working agent is awake');
  assert.equal(Play.extension.sleeping('logo',{known:false,mode:'ready'}),false,'the logo never sleeps');
  reset();const busy=host({modes:{a:'working'}});
  for(let i=0;i<30;i++)advance(busy,2);
  assert.equal(Play.state.asleep,false,'a run keeps everyone awake');
  busy.modes.a='ready';advance(busy,1);assert.equal(Play.state.asleep,false,'the rest starts when the run ends, not before it');
  advance(busy,16);assert.equal(Play.state.asleep,true,'and arrives fifteen seconds after it');
});

test('sleep is a state of the figure: closed eyes and a lowered gaze, with a slow breath that reduced motion drops',()=>{
  const awake=E.mkSim(),asleep=E.mkSim(),calm=E.mkSim();
  for(let t=0;t<3;t+=1/60){E.stepSim(awake,'ready',null,t,1/60,false,false,false);E.stepSim(asleep,'ready',null,t,1/60,false,false,true);E.stepSim(calm,'ready',null,t,1/60,false,true,true);}
  assert.ok(awake.S.open.x>.9,'awake eyes are open');
  assert.ok(asleep.S.open.x<.2&&calm.S.open.x<.2,`asleep eyes are shut (${asleep.S.open.x})`);
  assert.ok(asleep.S.ly.x>.2,'and the gaze is lowered');
  assert.ok(Math.abs(calm.S.sy.x-1)<1e-6,'reduced motion does not breathe');
  const working=E.mkSim();for(let t=0;t<3;t+=1/60)E.stepSim(working,'working',null,t,1/60,false,false,true);
  assert.ok(working.S.open.x>.9,'a working agent ignores the sleep request');
});

test('choosing an agent wakes it and only it; waking them all ends the sleep',()=>{
  reset();const h=host();Play.extension.frame(h);advance(h,20);assert.equal(Play.state.asleep,true);
  Play.wakeAgents(['a']);
  assert.equal(Play.extension.sleeping('a',{known:true,mode:'ready'}),false,'the chosen one is awake');
  assert.equal(Play.extension.sleeping('b',{known:true,mode:'ready'}),true,'the others sleep on');
  assert.equal(Play.state.asleep,true);
  Play.wakeAgents(['b']);assert.equal(Play.state.asleep,false,'everyone awake: no more sleep');
  assert.equal(Play.state.awake.size,0);
  Play.wakeAgents(['a']);assert.equal(Play.state.awake.size,0,'nothing to wake when nobody sleeps');
});

test('a reply that lands in a chat you are not looking at becomes an unread count and a converging burst; looking at the chat clears it',()=>{
  reset();let replies={a:0,b:0,g:0};
  const h=host({cfg:{replies:id=>replies[id]}});
  Play.extension.frame(h);
  assert.deepEqual(Play.state.unread,{},'what was already there is not unread');
  replies.b=2;advance(h,.5);
  assert.equal(Play.state.unread.b,2);assert.equal(Play.state.arrivals.length,1);assert.equal(Play.state.arrivals[0].id,'b');
  replies.b=3;advance(h,.5);assert.equal(Play.state.unread.b,3,'counts add up');
  replies.g=1;advance(h,.5);assert.equal(Play.state.unread.g,1,'a group counts too');
  // The bounce reaches the members of a group.
  assert.ok(h.sims.a&&h.sims.b,'members of the group were bounced');
  replies.a=0;advance(h,.5);assert.equal(Play.state.unread.a,undefined,'nothing new, nothing unread');
  // Fewer messages than before (a reset workspace) never makes a negative or phantom count.
  replies.b=0;advance(h,.5);assert.equal(Play.state.unread.b,3);replies.b=1;advance(h,.5);assert.equal(Play.state.unread.b,4,'new ones after a reset still count');
  // Looking at the chat clears it.
  global.document={querySelector:()=>({dataset:{id:'b'}})};
  advance(h,.5);assert.equal(Play.state.unread.b,undefined);assert.equal(Play.state.viewing,'b');
  delete global.document;
});

test('under reduced motion a new reply still counts as unread but nothing bounces or converges',()=>{
  reset();let n=0;const h=host({cfg:{replies:id=>id==='a'?n:0}});h.calm=true;
  Play.extension.frame(h);n=1;advance(h,.5);
  assert.equal(Play.state.unread.a,1);assert.equal(Play.state.arrivals.length,0);
});

test('the agent you are writing to looks toward the composer while you type, and only that agent',()=>{
  reset();Play.state.viewing='a';
  const clock=3;Figures.now=()=>clock;
  Play.state.typingT=clock-.5;assert.equal(Play.extension.listening('a'),true);assert.equal(Play.extension.listening('b'),false);
  Play.state.typingT=clock-2;assert.equal(Play.extension.listening('a'),false,'it looks back after a moment');
  Play.state.typingT=null;assert.equal(Play.extension.listening('a'),false);
});

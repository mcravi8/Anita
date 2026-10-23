/* Halftone dot figures: one ink colour, eyes cut out as negative space, motion driven by real agent state.
   Ported from the design handoff (Buddy Field Sidebar). The engine half is pure and unit-tested; the runtime half
   finds canvas[data-fig] elements, paints the sidebar dot field, and follows the cursor. */
(function(root){
  'use strict';
  const TAU=Math.PI*2;
  const rgb=h=>{const n=parseInt(h.slice(1),16);return [n>>16,(n>>8)&255,n&255];};
  const hash=(a,b)=>{const s=Math.sin(a*127.1+b*311.7)*43758.5453;return s-Math.floor(s);};
  const sst=(e0,e1,x)=>{const k=Math.max(0,Math.min(1,(x-e0)/(e1-e0)));return k*k*(3-2*k);};
  const rnd=(a,b)=>a+Math.random()*(b-a);
  const easeIO=k=>k<.5?4*k*k*k:1-Math.pow(-2*k+2,3)/2;
  const sdBox=(px,py,bx,by,r)=>{const qx=Math.abs(px)-bx+r,qy=Math.abs(py)-by+r;return Math.hypot(Math.max(qx,0),Math.max(qy,0))+Math.min(Math.max(qx,qy),0)-r;};
  const sdHex=(x,y,r)=>{x=Math.abs(x);y=Math.abs(y);const dt=2*Math.min(-.866025404*x+.5*y,0);x-=dt*-.866025404;y-=dt*.5;x-=Math.max(-.577350269*r,Math.min(.577350269*r,x));y-=r;return Math.hypot(x,y)*Math.sign(y);};
  const eyeSD=(px,py,e,hap)=>{
    const hh=Math.max(e.h,.014);
    let d=sdBox(px-e.cx,py-e.cy,e.w,hh,Math.min(e.w,hh));
    if(hap>.005){const ax=px-e.cx,ay=py-e.cy-.045,R=e.w*1.25,th=e.w*.45;const da=ay<0?Math.abs(Math.hypot(ax,ay)-R)-th:Math.min(Math.hypot(ax-R,ay),Math.hypot(ax+R,ay))-th;d+=(da-d)*hap;}
    return d;
  };
  const shade=(qx,qy)=>(.8+.2*sst(-.7,.5,qx*.55+qy*.85))*(1-.6*Math.exp(-(Math.pow(qx+.27,2)+Math.pow(qy+.3,2))/.012));

  // Ink per colour id: [light, dark]. agent-team.js carries the same values for swatches (a test keeps them equal).
  const INK={lilac:['#8a63d2','#b9a0eb'],blue:['#1f9bd6','#74c9f2'],peach:['#e07a2c','#f3a45d'],mint:['#2e9a48','#66c975'],red:['#b8432e','#e2684f'],gold:['#d4a300','#ffe02f'],cobalt:['#3561d8','#7fa0ff']};
  const INKRGB=Object.fromEntries(Object.entries(INK).map(([id,pair])=>[id,pair.map(rgb)]));
  const SHAPES=['diamond','sphere','hex','pill'];
  const LEGACY_SHAPE={star:'diamond',pebble:'sphere',cube:'hex',clover:'pill'};
  const LEGACY_COLOR={rose:'red',stone:'cobalt'};
  const normShape=id=>SHAPES.includes(LEGACY_SHAPE[id]||id)?(LEGACY_SHAPE[id]||id):'diamond';
  const normColor=id=>INK[LEGACY_COLOR[id]||id]?(LEGACY_COLOR[id]||id):'lilac';
  const EYEDX={diamond:.16,sphere:.17,hex:.15,pill:.2};
  const HUD=[{x:0,y:-.36,s:.5},{x:-.38,y:.14,s:.5},{x:.14,y:.32,s:.52},{x:.44,y:-.06,s:.42}];
  const HUD_ORDER=[2,1,3,0];
  const NEU_L=rgb('#141414'),NEU_D=rgb('#f2f0ea');
  let NEU=NEU_L,DARK=false;
  const setDark=value=>{DARK=!!value;NEU=DARK?NEU_D:NEU_L;};

  // Springs [rest, stiffness, damping] and the per-figure simulation state.
  function mkSim(){
    const S={},def={lx:[0,300,24],ly:[0,300,24],by:[0,200,14],sx:[1,380,14],sy:[1,380,14],tilt:[0,90,9],open:[1,220,15],eyeH:[1,260,18],happy:[0,120,16],work:[0,40,12.6]};
    for(const k in def)S[k]={x:def[k][0],v:0,target:def[k][0],k:def[k][1],c:def[k][2]};
    return {S,mode:'ready',nextSac:rnd(0,1),nextBlink:rnd(1,4),blinkT:-10,dbl:false,prog:0,nextHop:0,spinT:-10,pulseT:-10,ri:0,ph:rnd(0,6)};
  }
  // calm (prefers-reduced-motion) drops the idle life — breathing, bobbing, glancing, blinking, hops and spins — and keeps
  // every signal of state: the progress ring, the needs pulse, happy eyes, the tilt and where the eyes point.
  function stepSim(M,mode,fv,t,dt,attn,calm,sleep){
    const S=M.S;
    if(mode!==M.mode){
      M.mode=mode;M.nextSac=t;
      if(mode==='done'&&!calm){S.by.v-=2.2;S.sy.v+=1.8;M.spinT=t;}
      if(mode==='working')M.prog=0;
      if(mode==='needs')M.nextHop=t+.1;
      if(mode==='planning')M.ri=0;
    }
    const T={open:1,eyeH:1,happy:0,work:0,sx:1,sy:1,tilt:0,by:0};
    if(mode==='ready')T.sy=calm?1:1+.015*Math.sin(t*1.6+M.ph);
    else if(mode==='working'){T.work=1;T.eyeH=.88;T.sy=calm?1:1+.015*Math.sin(t*6+M.ph);M.prog=(M.prog+dt/LAP)%1;}
    else if(mode==='needs'){T.eyeH=1.15;if(t>=M.nextHop){if(!calm){S.by.v-=1.4;S.sy.v+=1;}M.nextHop=t+1.7;M.pulseT=t;}}
    else if(mode==='done')T.happy=1;
    else if(mode==='stuck'){T.tilt=.13;T.eyeH=.75;}
    for(const k in T)S[k].target=T[k];
    if(attn)S.eyeH.target*=1.14;
    if(fv){S.lx.target=fv[0];S.ly.target=fv[1];}
    else if(t>=M.nextSac){
      if(calm){S.lx.target=0;S.ly.target=mode==='working'?.3:mode==='planning'?-.4:mode==='done'?-.15:mode==='stuck'?.12:0;M.nextSac=t+1;}
      else if(mode==='working'){S.lx.target=rnd(-.3,.3);S.ly.target=rnd(.22,.38);M.nextSac=t+rnd(.22,.5);}
      else if(mode==='planning'){const k=M.ri++;S.lx.target=-.6+(k%5)*.3;S.ly.target=-.5+(Math.floor(k/5)%2)*.14;M.nextSac=t+(k%5===4?.45:.2);}
      else if(mode==='needs'||mode==='done'||mode==='stuck'){S.lx.target=0;S.ly.target=mode==='done'?-.15:mode==='stuck'?.12:0;M.nextSac=t+1;}
      else{if(Math.random()<.45){S.lx.target=0;S.ly.target=0;}else{S.lx.target=rnd(-.6,.6);S.ly.target=rnd(-.4,.3);}M.nextSac=t+rnd(.8,2.6);}
    }
    // Asleep (idle for a while): eyes shut, gaze dropped, a slow breath. Only a ready agent sleeps; any other mode wakes it.
    if(sleep&&mode==='ready'){S.open.target=.07;S.lx.target=0;S.ly.target=.3;S.sy.target=calm?1:1+.035*Math.sin(t*1.3+M.ph);}
    const hd=dt/2;
    for(let it=0;it<2;it++)for(const k in S){const s=S[k];s.v+=(s.k*(s.target-s.x)-s.c*s.v)*hd;s.x+=s.v*hd;}
    if(t>=M.nextBlink){if(!calm)M.blinkT=t;M.nextBlink=t+(M.dbl||Math.random()<.2?.3:rnd(2.4,5.2));M.dbl=false;}
  }
  function mkR(M,shape,color,pos,t){
    const S=M.S,st=t-M.spinT;
    const spin=st>=0&&st<1.1?TAU*easeIO(Math.min(1,Math.max(0,(st-.05)/.95))):0;
    const bt=(t-M.blinkT)/.16,bk=M.mode!=='done'&&bt>=0&&bt<1?Math.sin(bt*Math.PI):0;
    return {x:pos.x,y:pos.y,s:pos.s,shape,rot:(shape==='diamond'?Math.PI/4:0)+spin,eyeDX:EYEDX[shape]||.18,lx:S.lx.x,ly:S.ly.x,by:S.by.x,sx:S.sx.x,sy:S.sy.x,tilt:S.tilt.x,eyeH:S.eyeH.x,open:Math.max(0,S.open.x)*(1-bk*.95),happy:Math.max(0,Math.min(1,S.happy.x)),work:Math.max(0,S.work.x),prog:Math.min(1,M.prog),pulse:Math.min(1,(t-M.pulseT)/1.2),ink:color==='graphite'?NEU:INKRGB[normColor(color)][DARK?1:0]};
  }
  function prep(r,es){
    const sph=r.shape==='sphere',lk=sph?.2:.13,lx=r.lx,ly=r.ly,eh0=.155*es*r.eyeH*r.open;
    const eyes=[-1,1].map(s=>{
      const cx=s*r.eyeDX*(1-.1*Math.abs(lx))+lx*lk;
      let w=.06*es*(1-.14*Math.max(0,-s*lx));
      if(sph)w*=1-.45*Math.pow(Math.min(1,Math.abs(cx)/.56),2);
      return {cx,w,cy:-.03+ly*(sph?.13:.09),h:eh0};
    });
    return {r,sph,dia:r.shape==='diamond',hex:r.shape==='hex',e0:eyes[0],e1:eyes[1],cs:Math.cos(r.tilt),sn:Math.sin(r.tilt),cr:Math.cos(r.rot),sr:Math.sin(r.rot),reach:r.s*.95+.12+(r.pulse<1?.5:0)};
  }
  const EV={dB:0,dE:0,qx:0,qy:0},ACC={v:0,col:null};
  function evalM(m,u,v){
    const r=m.r;
    const bu=(u-r.x)/r.s-r.lx*.03,bv=(v-r.y)/r.s-r.by;
    const px=(bu*m.cs+bv*m.sn)/r.sx,py=(-bu*m.sn+bv*m.cs)/r.sy;
    const qx=px*m.cr+py*m.sr,qy=-px*m.sr+py*m.cr;
    const dB=m.dia?sdBox(qx,qy,.44,.44,.13):m.sph?Math.hypot(px,py)-.56:m.hex?sdHex(qy,qx,.42)-.1:sdBox(qx,qy,.58,.4,.36);
    EV.dB=dB*r.s;EV.dE=Math.min(eyeSD(px,py,m.e0,r.happy),eyeSD(px,py,m.e1,r.happy))*r.s;EV.qx=qx;EV.qy=qy;
  }
  function accumFx(m,u0,v0,X){
    const r=m.r;
    if(X.rings&&r.work>.01){
      const band=Math.exp(-Math.pow((EV.dB-.05)/X.bw,2));
      if(band>.04){let fr=(Math.atan2(v0-r.y,u0-r.x)+Math.PI/2)/TAU;fr-=Math.floor(fr);const vv=band*r.work*trail(r.prog,fr);if(vv>ACC.v){ACC.v=vv;ACC.col=r.ink;}}
    }
    if(r.pulse<1){const pv=Math.exp(-Math.pow((EV.dB-.03-r.pulse*.45)/.05,2))*(1-r.pulse);if(pv>ACC.v){ACC.v=pv;ACC.col=r.ink;}}
  }
  // One cell of a figure at normalised (u0,v0). Returns a shared scratch record (f = head coverage, H = head ink,
  // maxB = body coverage) so the per-cell hot loop allocates nothing; effects are left in ACC.
  const CELL={f:0,H:null,maxB:0};
  function cellAt(M,ord,edge,gap,X,u0,v0){
    let f=0,H=NEU,maxB=0,block=0;
    ACC.v=0;ACC.col=NEU;
    for(const k of ord){
      const m=M[k],r=m.r;
      if(Math.abs(u0-r.x)>m.reach||Math.abs(v0-r.y)>m.reach)continue;
      evalM(m,u0,v0);
      const bc=sst(edge,-edge,EV.dB);
      if(bc>maxB)maxB=bc;
      if(bc>.001&&block<.999){let ff=bc*(1-sst(edge,-edge,EV.dE))*(1-block);if(m.sph)ff*=shade(EV.qx,EV.qy);if(ff>f){f=ff;H=r.ink;}}
      block=Math.max(block,gap?sst(edge,-edge,EV.dB-gap):bc);
      accumFx(m,u0,v0,X);
    }
    CELL.f=f;CELL.H=H;CELL.maxB=maxB;
    return CELL;
  }
  // A working ring is a light that goes round and round at one pace, its tail fading behind it over the faint track: it never fills up and
  // starts again (it used to fill in 4.2 s, hold, and jump back to empty). `head` and `at` are fractions of the circle from the top.
  const LAP=3;
  function trail(head,at){const lag=((head-at)%1+1)%1;return .08+.92*Math.exp(-lag*4);}
  // A group's ring goes round on its own clock while any member works, at full strength. It used to show the members' average progress and
  // strength, so one of four working stopped it at a quarter and two at half.
  function groupSweep(R,t){return {group:R.reduce((s,r)=>Math.max(s,r.work),0),gprog:(t/LAP)%1};}
  function groupRing(X,u0,v0,radius){
    if(!(X.group>.01))return;
    const d=Math.hypot(u0,v0),band=Math.exp(-Math.pow((d-radius)/X.bw,2));
    if(band>.04){let fr=(Math.atan2(v0,u0)+Math.PI/2)/TAU;fr-=Math.floor(fr);const vv=band*X.group*trail(X.gprog,fr);if(vv>ACC.v){ACC.v=vv;ACC.col=NEU;}}
  }
  function drawAv(c,n,es,R,X,t){
    const h=(n-1)/2,sp=300/(n-1),edge=.6/h;
    X.bw=Math.max(.03,edge*.9);
    const multi=R.length>1,gap=multi?Math.max(.03,edge*1.1):0;
    const M=R.map(r=>prep(r,es)),ord=multi?X.order:[0],rMax=.6*sp;
    for(let j=0;j<n;j++){
      const v0=(j-h)/h;
      for(let i=0;i<n;i++){
        const u0=(i-h)/h,d=Math.hypot(u0,v0);
        if(d>1.02)continue;
        let a=0;
        if(X.amb){const n1=.5+.5*Math.sin(u0*3.1+t*.7+1.3*Math.sin(v0*2.3-t*.5)),n2=.5+.5*Math.cos(v0*2.7-t*.55+Math.sin(u0*1.9+t*.35));a=X.amb*(.1+.45*n1*n2);}
        const {f,H,maxB}=cellAt(M,ord,edge,gap,X,u0,v0);
        groupRing(X,u0,v0,.9);
        const A=ACC.col,out=1-maxB,aP=Math.min(1,a)*out,rP=Math.min(1,ACC.v)*out;
        const val=Math.min(1,f+aP+rP);
        if(X.clean&&val<.02)continue;
        const rad=.35+val*(rMax-.35);
        const tot=f+aP+rP+.02,wh=f/tot,wr=rP/tot,wa=1-wh-wr;
        c.beginPath();c.arc(10+i*sp,10+j*sp,rad,0,TAU);
        c.fillStyle=`rgba(${(H[0]*wh+NEU[0]*wa+A[0]*wr)|0},${(H[1]*wh+NEU[1]*wa+A[1]*wr)|0},${(H[2]*wh+NEU[2]*wa+A[2]*wr)|0},${Math.min(1,.22+val*1.6)})`;
        c.fill();
      }
    }
  }
  function gridFor(size,multi){
    let n,es;
    if(size>=140){n=45;es=1;}else if(size>=70){n=33;es=1.15;}else if(size>=44){n=25;es=1.4;}else if(size>=36){n=23;es=1.5;}else{n=19;es=1.8;}
    if(multi){n+=6;es*=1.3;}
    return [n,es];
  }
  // Renders one head into a shared dot field: put(i,j,value,colour) per lit cell of pitch P.
  function headCells(put,cx,cy,half,R,X,P,cols,rows){
    const multi=R.length>1,hc=half/P,edge=.6/hc;
    let es=hc>20?1:hc>12?1.4:1.8;if(multi)es*=1.3;
    X.bw=Math.max(.03,edge*.9);
    const gap=multi?Math.max(.03,edge*1.1):0,M=R.map(r=>prep(r,es)),ord=multi?X.order:[0];
    const i0=Math.max(0,Math.floor((cx-half*1.05)/P)),i1=Math.min(cols-1,Math.ceil((cx+half*1.05)/P));
    const j0=Math.max(0,Math.floor((cy-half*1.05)/P)),j1=Math.min(rows-1,Math.ceil((cy+half*1.05)/P));
    for(let j=j0;j<=j1;j++)for(let i=i0;i<=i1;i++){
      const u0=((i+.5)*P-cx)/half,v0=((j+.5)*P-cy)/half;
      if(u0*u0+v0*v0>1.1)continue;
      const {f,H,maxB}=cellAt(M,ord,edge,gap,X,u0,v0);
      groupRing(X,u0,v0,.92);
      const rP=Math.min(1,ACC.v)*(1-maxB);
      if(f>=rP)put(i,j,f,H);else put(i,j,rP,ACC.col);
    }
  }

  // ---- runtime ------------------------------------------------------------------------------------------------
  const esc=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  let cfg={agent:()=>null,group:()=>null,agentIds:()=>[]};
  const sims={},modes={},focus={},focusGroup={},groupWork={};
  let handoffs=[],timers=[],mouse=null,hoverId=null,hoverPrev=null,slotPos={},poked=0;
  let clock=0,last=0,fc=0,raf=0,started=false,dirty=true,io=null,mo=null,canvases=[],calmQuery=null,paintedField=null;
  const visible=new Set(),observed=new Set(),fresh=new Set();
  let baseCache={key:'',canvas:null};
  const sim=id=>sims[id]||(sims[id]=mkSim());
  const configure=options=>{cfg=Object.assign({},cfg,options);};
  // Extensions add to the field without the engine knowing what they draw: frame(host) runs before the figures step,
  // listening(id)/sleeping(id) steer a figure's eyes and rest, and field(ctx) writes cells into the shared dot field.
  const extensions=[];
  const extend=ext=>{if(ext&&!extensions.includes(ext))extensions.push(ext);return ()=>{const k=extensions.indexOf(ext);if(k>=0)extensions.splice(k,1);};};
  const call=(name,arg)=>{for(const ext of extensions)if(typeof ext[name]==='function'){try{ext[name](arg);}catch(error){console.error(`Buddy field extension ${name} failed`,error);}}};
  const ask=(name,id,info)=>{for(const ext of extensions)if(typeof ext[name]==='function'){try{if(ext[name](id,info))return true;}catch(error){console.error(`Buddy field extension ${name} failed`,error);}}return false;};
  const later=(ms,fn)=>{const id=setTimeout(()=>{timers=timers.filter(x=>x!==id);fn();},ms);timers.push(id);};
  function setMode(id,mode){
    modes[id]=mode;
    if(mode==='done')later(1700,()=>{if(modes[id]==='done')modes[id]='ready';});
    if(mode==='stuck')later(8000,()=>{if(modes[id]==='stuck')modes[id]='ready';});
  }
  const getMode=id=>modes[id]||'ready';
  const setFocus=(id,target,groupId)=>{focus[id]=target||null;focusGroup[id]=target&&groupId?groupId:null;};
  const handoff=(from,to)=>{if(from&&to&&from!==to)handoffs.push({from,to,t0:clock});};
  const setGroupWork=(groupId,memberId)=>{if(memberId)groupWork[groupId]=memberId;else delete groupWork[groupId];};
  const poke=()=>{poked=clock||.001;};
  function vec(id,other){
    const order=cfg.group(focusGroup[id])?.members||cfg.agentIds();
    const a=HUD[Math.max(0,order.indexOf(id))%4],b=HUD[Math.max(0,order.indexOf(other))%4],dx=b.x-a.x,dy=b.y-a.y,dl=Math.hypot(dx,dy);
    return dl<.001?[0,0]:[dx/dl*.8,dy/dl*.6];
  }

  function canvasTag(kind,attrs,px){
    return `<canvas class="fig fig-${kind}" data-fig="${kind}" ${attrs} data-size="${px}" width="${px}" height="${px}" style="width:${px}px;height:${px}px" aria-hidden="true"></canvas>`;
  }
  function logoHTML(size=40){return canvasTag('logo','',Math.round(size));}
  function avatarHTML(value,size=34){
    const px=Math.round(size);
    if(value&&Array.isArray(value.members)){
      if(value.members.some(id=>cfg.agent(id)))return canvasTag('group',`data-fig-id="${esc(value.id)}"`,px);
      return logoHTML(px);
    }
    if(value&&value.id&&cfg.agent(value.id))return canvasTag('agent',`data-fig-id="${esc(value.id)}"`,px);
    return canvasTag('agent',`data-shape="${normShape(value?.avatarShape)}" data-color="${normColor(value?.avatarColor)}"`,px);
  }
  // A placeholder the sidebar field draws a head into (the head is part of the field, not its own canvas).
  const slotHTML=(kind,id,size,key)=>`<span class="fig-slot" data-slot="${esc(key||`row:${id}`)}" data-kind="${kind}" data-fig-id="${esc(id||'')}" data-size="${size}" style="width:${size}px;height:${size}px" aria-hidden="true"></span>`;
  const fieldHTML=()=>'<canvas class="sidebar-field" aria-hidden="true"></canvas>';
  function slotAvatarHTML(value,size){
    if(value&&Array.isArray(value.members))return value.members.some(id=>cfg.agent(id))?slotHTML('group',value.id,size):slotHTML('logo','',size,`row:${value.id}`);
    return value&&value.id?slotHTML('agent',value.id,size):slotHTML('logo','',size);
  }

  function membersOf(groupId){return (cfg.group(groupId)?.members||[]).slice(0,4).map(id=>cfg.agent(id)).filter(Boolean);}
  // A figure in the chat's floating header is a still picture of who the chat is with: drawn from a pose that is never stepped (no blinking,
  // glancing, breathing or working ring), whatever the agent is doing. The sidebar and the messages keep the live figures.
  let restPose=null;
  const rest=()=>restPose||(restPose=mkSim());
  function paintCanvas(el,t,dpr){
    // CSS decides how big the figure is drawn (a row, a header, a hero); data-size is only the default.
    const kind=el.dataset.fig,size=el.clientWidth||+el.dataset.size||34,still=!!el.closest('.island');
    let R,X;
    if(kind==='group'){
      const mem=membersOf(el.dataset.figId);if(!mem.length)return;
      R=mem.map((a,k)=>mkR(still?rest():sim(a.id),normShape(a.avatarShape),normColor(a.avatarColor),HUD[k],t));
      X={order:HUD_ORDER.filter(k=>k<R.length),rings:false,...groupSweep(R,t),amb:size>100?.28:0,clean:size<=100};
    }else{
      let shape,color,M,pos={x:0,y:0,s:1.12};
      if(kind==='agent'){
        const a=el.dataset.figId?cfg.agent(el.dataset.figId):null;
        if(el.dataset.figId&&!a)return;
        shape=normShape(a?a.avatarShape:el.dataset.shape);color=normColor(a?a.avatarColor:el.dataset.color);M=still?rest():sim(a?a.id:'anon');
      }else{shape='pill';color='graphite';M=sim('logo');pos={x:0,y:.02,s:1.32};}
      R=[mkR(M,shape,color,pos,t)];
      X={order:[0],rings:true,group:0,amb:size>100?.25:0,clean:size<=100};
    }
    const px=Math.round(size*dpr);
    if(el.width!==px){el.width=px;el.height=px;}
    const c=el.getContext('2d');
    c.setTransform(1,0,0,1,0,0);c.clearRect(0,0,px,px);
    const s=px/320;c.setTransform(s,0,0,s,0,0);
    const [n,es]=gridFor(size,R.length>1);
    drawAv(c,n,es,R,X,t);
  }

  function paintField(side,cv,t,dpr){
    const rect=side.getBoundingClientRect(),W=rect.width,H=rect.height,P=2.6;
    if(W<8||H<8||rect.right<=0)return;
    const pw=Math.round(W*dpr),ph=Math.round(H*dpr);
    if(cv.width!==pw||cv.height!==ph){cv.width=pw;cv.height=ph;}
    const cols=Math.ceil(W/P),rows=Math.ceil(H/P),N=cols*rows;
    if(!paintField.buf||paintField.buf.N!==N)paintField.buf={N,val:new Float32Array(N),cr:new Float32Array(N),cg:new Float32Array(N),cb:new Float32Array(N),mark:new Uint8Array(N),list:new Int32Array(N),n:0};
    const B=paintField.buf;
    for(let k=0;k<B.n;k++){const id=B.list[k];B.mark[id]=0;B.val[id]=0;}
    B.n=0;
    let clipY0=-Infinity,clipY1=Infinity;
    const put=(i,j,v,col)=>{
      if(v<=.012||i<0||j<0||i>=cols||j>=rows)return;
      const y=(j+.5)*P;if(y<clipY0||y>clipY1)return;
      const id=j*cols+i;
      if(!B.mark[id]){B.mark[id]=1;B.list[B.n++]=id;}else if(v<=B.val[id])return;
      B.val[id]=Math.min(1,v);B.cr[id]=col[0];B.cg[id]=col[1];B.cb[id]=col[2];
    };
    const list=side.querySelector('.chat-list'),lr=list&&list.getBoundingClientRect();
    const listY0=lr?lr.top-rect.top:-Infinity,listY1=lr?lr.bottom-rect.top:Infinity;
    const pos={};
    for(const el of side.querySelectorAll('[data-slot]')){
      const r=el.getBoundingClientRect();
      if(!r.width)continue;
      pos[el.dataset.slot]={x:r.left-rect.left+r.width/2,y:r.top-rect.top+r.height/2,spec:{kind:el.dataset.kind,id:el.dataset.figId,size:+el.dataset.size||50},scroll:el.dataset.slot.startsWith('row:')};
    }
    slotPos={};for(const key in pos)slotPos[key]=pos[key];
    for(const key in pos){
      const p=pos[key];if(p.spec.kind!=='group')continue;
      (cfg.group(p.spec.id)?.members||[]).slice(0,4).forEach((id,k)=>{if(!slotPos['row:'+id])slotPos['row:'+id]={x:p.x+HUD[k].x*p.spec.size/2,y:p.y+HUD[k].y*p.spec.size/2};});
    }
    const rowEls=[...side.querySelectorAll('.chat-row[data-id]')];
    hoverId=null;
    if(mouse){const mx=mouse.x+rect.left,my=mouse.y+rect.top;for(const el of rowEls){const r=el.getBoundingClientRect();if(mx>=r.left&&mx<=r.right&&my>=r.top&&my<=r.bottom){hoverId=el.dataset.id;break;}}}
    const sel=rowEls.find(el=>el.classList.contains('selected')||el.getAttribute('aria-current')==='page');
    if(sel){
      const r=sel.getBoundingClientRect(),x0=r.left-rect.left,y0=r.top-rect.top,w=r.width,h=r.height;
      clipY0=listY0;clipY1=listY1;
      for(let j=Math.max(0,Math.floor(y0/P));j<=Math.min(rows-1,Math.ceil((y0+h)/P));j++)for(let i=Math.max(0,Math.floor(x0/P));i<=Math.min(cols-1,Math.ceil((x0+w)/P));i++){
        const px=(i+.5)*P-x0,py=(j+.5)*P-y0;
        if(sdBox(px-w/2,py-h/2,w/2,h/2,14)>0)continue;
        put(i,j,.17-.07*(px/w)+.02*Math.sin(px*.08-t*2),NEU);
      }
      clipY0=-Infinity;clipY1=Infinity;
    }
    if(mouse){
      const mx=mouse.x,my=mouse.y,R0=48;
      for(let j=Math.max(0,Math.floor((my-R0)/P));j<=Math.min(rows-1,Math.ceil((my+R0)/P));j++)for(let i=Math.max(0,Math.floor((mx-R0)/P));i<=Math.min(cols-1,Math.ceil((mx+R0)/P));i++){
        const d=Math.hypot((i+.5)*P-mx,(j+.5)*P-my);if(d<R0)put(i,j,.2*Math.pow(1-d/R0,2),NEU);
      }
    }
    const curve=(a,b,s)=>{const c={x:Math.min(a.x,b.x)-34,y:(a.y+b.y)/2},k=1-s;return {x:k*k*a.x+2*k*s*c.x+s*s*b.x,y:k*k*a.y+2*k*s*c.y+s*s*b.y};};
    const blob=(p,a,col,rr)=>{
      for(let j=Math.max(0,Math.floor((p.y-rr)/P));j<=Math.min(rows-1,Math.ceil((p.y+rr)/P));j++)for(let i=Math.max(0,Math.floor((p.x-rr)/P));i<=Math.min(cols-1,Math.ceil((p.x+rr)/P));i++){
        const dd=Math.pow((i+.5)*P-p.x,2)+Math.pow((j+.5)*P-p.y,2);put(i,j,a*Math.exp(-dd/(rr*rr*.35)),col);
      }
    };
    const inkOf=id=>{const a=cfg.agent(id);return a?INKRGB[normColor(a.avatarColor)][DARK?1:0]:NEU;};
    const streams=[];
    for(const gid in groupWork){const gp=slotPos['row:'+gid],mp=slotPos['row:'+groupWork[gid]];if(gp&&mp)streams.push({a:mp,b:gp,col:inkOf(groupWork[gid]),n:6,speed:.55,amp:.75});}
    handoffs=handoffs.filter(h=>t-h.t0<1.6);
    for(const h of handoffs){const a=slotPos['row:'+h.from],b=slotPos['row:'+h.to];if(a&&b)streams.push({a,b,col:inkOf(h.from),n:10,speed:.9,amp:Math.sin((t-h.t0)/1.6*Math.PI)});}
    clipY0=listY0;clipY1=listY1;
    for(const st of streams)for(let q=0;q<st.n;q++){const s=(t*st.speed+q/st.n)%1,p=curve(st.a,st.b,s);blob(p,st.amp*(.25+.75*Math.sin(s*Math.PI)),st.col,6);}
    clipY0=-Infinity;clipY1=Infinity;
    if(extensions.length){
      const rowMap=new Map(rowEls.map(el=>[el.dataset.id,el]));
      call('field',{t,P,cols,rows,W,H,rect,side,put,blob,pos,slotPos,rowEls:rowMap,hoverId,mouse,NEU,DARK,calm:!!(calmQuery&&calmQuery.matches),cfg,
        clip:on=>{if(on){clipY0=listY0;clipY1=listY1;}else{clipY0=-Infinity;clipY1=Infinity;}},
        inkOf:id=>inkOf(cfg.group(id)?.members?.[0]||id),
        getMode:id=>modes[id]||'ready',sim,compact:!!side.closest('.sidebar-compact')});
      clipY0=-Infinity;clipY1=Infinity;
    }
    for(const key in pos){
      const {x:cx,y:cy,spec,scroll}=pos[key],half=spec.size/2;
      if(cy<-half*3||cy>H+half*3)continue;
      if(scroll){clipY0=listY0;clipY1=listY1;}else{clipY0=-Infinity;clipY1=Infinity;}
      let R,X;
      if(spec.kind==='group'){
        const mem=membersOf(spec.id);if(!mem.length)continue;
        R=mem.map((a,k)=>Object.assign(mkR(sim(a.id),normShape(a.avatarShape),normColor(a.avatarColor),HUD[k],t),{pulse:1}));
        X={order:HUD_ORDER.filter(k=>k<R.length),rings:false,...groupSweep(R,t)};
      }else{
        const a=spec.kind==='agent'?cfg.agent(spec.id):null;if(spec.kind==='agent'&&!a)continue;
        const M=a?sims[a.id]:sims.logo;if(!M)continue;
        R=[Object.assign(mkR(M,a?normShape(a.avatarShape):'pill',a?normColor(a.avatarColor):'graphite',a?{x:0,y:0,s:1.05}:{x:0,y:.02,s:1.25},t),{pulse:1})];
        X={order:[0],rings:true,group:0};
        if(a){
          const col=INKRGB[normColor(a.avatarColor)][DARK?1:0],pt=t-M.pulseT;
          if(pt>=0&&pt<1.8){
            const rr=half+pt/1.8*150,fade=1-pt/1.8,R1=rr+10;
            for(let j=Math.max(0,Math.floor((cy-R1)/P));j<=Math.min(rows-1,Math.ceil((cy+R1)/P));j++)for(let i=Math.max(0,Math.floor((cx-R1)/P));i<=Math.min(cols-1,Math.ceil((cx+R1)/P));i++){
              const d=Math.hypot((i+.5)*P-cx,(j+.5)*P-cy),dz=Math.abs(d-rr);if(dz<9)put(i,j,.55*fade*Math.exp(-dz*dz/14),col);
            }
          }
        }
      }
      headCells(put,cx,cy,half,R,X,P,cols,rows);
    }
    const c=cv.getContext('2d');
    c.setTransform(1,0,0,1,0,0);c.clearRect(0,0,pw,ph);
    const key=`${pw}x${ph}:${DARK}`;
    if(baseCache.key!==key){
      const base=document.createElement('canvas');base.width=pw;base.height=ph;
      const b=base.getContext('2d');b.scale(dpr,dpr);b.fillStyle=DARK?'rgba(242,240,234,.07)':'rgba(20,20,20,.075)';
      for(let j=0;j<rows;j++)for(let i=0;i<cols;i++){b.beginPath();b.arc((i+.5)*P,(j+.5)*P,.32,0,TAU);b.fill();}
      baseCache={key,canvas:base};
    }
    c.drawImage(baseCache.canvas,0,0);
    c.setTransform(dpr,0,0,dpr,0,0);
    const rMax=.62*P;
    for(let k=0;k<B.n;k++){
      const id=B.list[k],v=B.val[id],i=id%cols,j=(id-i)/cols;
      c.beginPath();c.arc((i+.5)*P,(j+.5)*P,.32+v*(rMax-.32),0,TAU);
      c.fillStyle=`rgba(${B.cr[id]|0},${B.cg[id]|0},${B.cb[id]|0},${Math.min(1,.2+v*1.6)})`;
      c.fill();
    }
  }

  function rescan(){
    canvases=[...document.querySelectorAll('canvas[data-fig]')];
    const live=new Set(canvases);
    for(const el of observed)if(!live.has(el)){if(io)io.unobserve(el);observed.delete(el);visible.delete(el);}
    // A canvas that was just inserted is painted at once so a re-render never flashes empty avatars.
    for(const el of canvases)if(!observed.has(el)){if(io)io.observe(el);observed.add(el);fresh.add(el);}
    dirty=false;
  }
  function frame(){
    const tn=performance.now()/1000,dt=Math.min(1/30,tn-(last||tn));last=tn;
    clock+=dt;
    const calm=!!(calmQuery&&calmQuery.matches);
    if(dirty)rescan();
    const side=document.querySelector('.sidebar'),fieldEl=side&&side.querySelector('canvas.sidebar-field');
    sim('logo');sim('anon');
    const ids=new Set([...cfg.agentIds(),...Object.keys(sims)]);
    if(extensions.length)call('frame',{clock,dt,calm,ids:cfg.agentIds(),cfg,sim,getMode:id=>modes[id]||'ready',hoverId});
    for(const id of ids){
      // Buddy's own logo (the sidebar's header and its workspace button) is a mark, not a character: it keeps its resting pose, with no
      // blinking, glancing, breathing or bounce.
      if(id==='logo')continue;
      const M=sim(id),f=focus[id],mode=modes[id]||'ready',known=!!cfg.agent(id);
      let fv=f==='user'?[0,0]:f&&f!==id?vec(id,f):null;
      const sp=slotPos['row:'+id];
      if(ask('listening',id,{mode,known}))fv=[.9,.05];
      else if(mouse&&sp){const dx=mouse.x-sp.x,dy=mouse.y-sp.y,dd=Math.hypot(dx,dy)||1,k=Math.min(1,dd/70);fv=[dx/dd*k*.85,dy/dd*k*.65];}
      if(hoverId===id&&hoverPrev!==id){M.S.sy.v+=1.1;M.S.sx.v-=.5;}
      stepSim(M,mode,fv,clock,dt,hoverId===id,calm,known&&ask('sleeping',id,{mode,known}));
    }
    hoverPrev=hoverId;
    if(poked){if(!calm){const m=sim('anon');m.spinT=clock;m.S.by.v-=1.2;}poked=0;}
    fc++;
    const dpr=Math.min(2,window.devicePixelRatio||1);
    // A sidebar that was just rebuilt is painted at once, so a re-render never shows the dot field blank for a frame.
    if(fieldEl&&(fieldEl!==paintedField||fc%2===0)){paintField(side,fieldEl,clock,dpr);paintedField=fieldEl;}
    let i=0;
    for(const el of canvases){
      i++;
      if(!fresh.has(el)&&((i+fc)%2||(io&&!visible.has(el))))continue;
      fresh.delete(el);
      paintCanvas(el,clock,dpr);
    }
  }
  function start(){
    if(started||typeof document==='undefined')return;
    if(!document.body){document.addEventListener('DOMContentLoaded',start,{once:true});return;}
    started=true;
    if(typeof matchMedia!=='undefined')calmQuery=matchMedia('(prefers-reduced-motion: reduce)');
    if(typeof IntersectionObserver!=='undefined')io=new IntersectionObserver(entries=>{for(const e of entries)e.isIntersecting?visible.add(e.target):visible.delete(e.target);});
    mo=new MutationObserver(()=>{dirty=true;});mo.observe(document.body,{childList:true,subtree:true});
    document.addEventListener('mousemove',e=>{
      const side=e.target.closest&&e.target.closest('.sidebar');
      if(!side){mouse=null;return;}
      const r=side.getBoundingClientRect();mouse={x:e.clientX-r.left,y:e.clientY-r.top};
    },{passive:true});
    document.documentElement.addEventListener('mouseleave',()=>{mouse=null;});
    const loop=()=>{try{frame();}catch(error){console.error('Buddy figures stopped painting',error);return;}raf=requestAnimationFrame(loop);};
    raf=requestAnimationFrame(loop);
  }
  function stop(){cancelAnimationFrame(raf);timers.forEach(clearTimeout);timers=[];started=false;if(io)io.disconnect();if(mo)mo.disconnect();io=mo=null;observed.clear();visible.clear();fresh.clear();}

  const engine={mkSim,stepSim,mkR,prep,evalM,drawAv,gridFor,headCells,sdBox,sdHex,eyeSD,setDark,HUD,HUD_ORDER,EYEDX,hash,easeIO,rnd,sst,TAU,groupSweep,trail,LAP};
  const hovered=()=>hoverId;
  const api={hovered,extend,now:()=>clock,sim:id=>sims[id]||null,avatarHTML,logoHTML,slotHTML,slotAvatarHTML,fieldHTML,setMode,getMode,setFocus,handoff,setGroupWork,poke,configure,setDark,start,stop,normShape,normColor,INK,SHAPES,LEGACY_SHAPE,LEGACY_COLOR,engine};
  if(typeof module!=='undefined'&&module.exports)module.exports=api;
  root.BuddyFigures=api;
  if(typeof document!=='undefined')start();
})(typeof globalThis!=='undefined'?globalThis:this);

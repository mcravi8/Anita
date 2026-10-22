/* The desktop drop's page: what the Mac app's transparent panel at the top-left of the screen shows while Buddy is in the background.
   Ported from the design handoff (Buddy Desktop Drop): a black holder builds from halftone dots switching on in random order (slightly
   favouring the centre), a solid disc with a soft shadow lands, and the agent pops in inside it in its own ink. Finished: one spin and happy
   eyes, then slow blinks. Needs you: looks at you, double-blinks, a small hop and a faint pulse ring every 2.4s. A label (name · status) peeks
   out to the right for about three seconds; hover brings it back. A click pops the holder and the app opens that chat. Up to four stack 92px
   apart and spring up when one goes; the same agent again wobbles its holder and updates its label.

   The app drives it: BuddyDropPage.show(item), .hover(id|null), .click(id), .clear(). The page tells the app (messageHandlers.buddyDrop)
   when it is ready, where its holders and visible labels are (so only those take clicks), which holder was clicked, and when it is empty.
   With Reduce Motion the holder and figure are there at once, without the build, spin, hop or wobble; the label and the click stay. */
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

  // Ink per colour id: [light, dark], the same values as the app's figures (buddy-figures.js) and the design's palette.
  const INK={lilac:['#8a63d2','#b9a0eb'],blue:['#1f9bd6','#74c9f2'],peach:['#e07a2c','#f3a45d'],mint:['#2e9a48','#66c975'],red:['#b8432e','#e2684f'],gold:['#d4a300','#ffe02f'],cobalt:['#3561d8','#7fa0ff']};
  const INKRGB=Object.fromEntries(Object.entries(INK).map(([id,pair])=>[id,pair.map(rgb)]));
  const SHAPES=['diamond','sphere','hex','pill'],EYEDX={diamond:.16,sphere:.17,hex:.15,pill:.2};
  const NEU=rgb('#141414');
  // Dark: the holder stays the design's black disc (the figure's inks are drawn against it), the figure takes the design's dark inks, the label
  // the dark card, and the rings outside the disc and a faint rim are drawn light so they show over dark windows.
  let dark=false;

  // MARK: the figure (the design's engine)
  function mkSim(){
    const S={},def={lx:[0,300,24],ly:[0,300,24],by:[0,200,14],sx:[1,380,14],sy:[1,380,14],tilt:[0,90,9],open:[1,220,15],eyeH:[1,260,18],happy:[0,120,16],work:[0,40,12.6]};
    for(const k in def)S[k]={x:def[k][0],v:0,target:def[k][0],k:def[k][1],c:def[k][2]};
    return {S,mode:'ready',nextSac:rnd(0,1),nextBlink:rnd(1,4),blinkT:-10,dbl:false,prog:0,nextHop:0,spinT:-10,pulseT:-10,ri:0,ph:rnd(0,6),hops:0};
  }
  // calm (Reduce Motion) drops the spin, the hop, the breathing and the glancing, and keeps the signals: happy eyes, the gaze, the pulse.
  function stepSim(M,mode,fv,t,dt,attn,calm){
    const S=M.S;
    if(mode!==M.mode){
      M.mode=mode;M.nextSac=t;
      if(mode==='done'&&!calm)M.spinT=t;
      if(mode==='needs')M.nextHop=t+.1;
    }
    const T={open:1,eyeH:1,happy:0,work:0,sx:1,sy:1,tilt:0,by:0};
    if(mode==='ready')T.sy=calm?1:1+.015*Math.sin(t*1.6+M.ph);
    else if(mode==='needs'){T.eyeH=1.15;if(t>=M.nextHop){if(!calm){S.by.v-=1.4;S.sy.v+=1;M.hops++;}M.nextHop=t+1.7;M.pulseT=t;}}
    else if(mode==='done')T.happy=1;
    for(const k in T)S[k].target=T[k];
    if(attn)S.eyeH.target*=1.14;
    if(fv){S.lx.target=fv[0];S.ly.target=fv[1];}
    else if(t>=M.nextSac){
      if(mode==='needs'||mode==='done'||calm){S.lx.target=0;S.ly.target=mode==='done'?-.15:0;M.nextSac=t+1;}
      else{if(Math.random()<.45){S.lx.target=0;S.ly.target=0;}else{S.lx.target=rnd(-.6,.6);S.ly.target=rnd(-.4,.3);}M.nextSac=t+rnd(.8,2.6);}
    }
    const hd=dt/2;
    for(let it=0;it<2;it++)for(const k in S){const s=S[k];s.v+=(s.k*(s.target-s.x)-s.c*s.v)*hd;s.x+=s.v*hd;}
    if(t>=M.nextBlink){if(!calm)M.blinkT=t;M.nextBlink=t+(M.dbl||Math.random()<.2?.3:rnd(2.4,5.2));M.dbl=false;}
  }
  function mkR(M,shape,color,pos,t){
    const S=M.S,st=t-M.spinT;
    const spin=st>=0&&st<1.1?TAU*easeIO(Math.min(1,Math.max(0,(st-.05)/.95))):0;
    const bt=(t-M.blinkT)/.16,bk=M.mode!=='done'&&bt>=0&&bt<1?Math.sin(bt*Math.PI):0;
    return {x:pos.x,y:pos.y,s:pos.s,shape,rot:(shape==='diamond'?Math.PI/4:0)+spin,eyeDX:EYEDX[shape]||.18,lx:S.lx.x,ly:S.ly.x,by:S.by.x,sx:S.sx.x,sy:S.sy.x,tilt:S.tilt.x,eyeH:S.eyeH.x,open:Math.max(0,S.open.x)*(1-bk*.95),happy:Math.max(0,Math.min(1,S.happy.x)),pulse:Math.min(1,(t-M.pulseT)/1.2),ink:(INKRGB[color]||INKRGB.lilac)[dark?1:0]};
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
  const EV={dB:0,dE:0,qx:0,qy:0};
  function evalM(m,u,v){
    const r=m.r;
    const bu=(u-r.x)/r.s-r.lx*.03,bv=(v-r.y)/r.s-r.by;
    const px=(bu*m.cs+bv*m.sn)/r.sx,py=(-bu*m.sn+bv*m.cs)/r.sy;
    const qx=px*m.cr+py*m.sr,qy=-px*m.sr+py*m.cr;
    const dB=m.dia?sdBox(qx,qy,.44,.44,.13):m.sph?Math.hypot(px,py)-.56:m.hex?sdHex(qy,qx,.42)-.1:sdBox(qx,qy,.58,.4,.36);
    EV.dB=dB*r.s;EV.dE=Math.min(eyeSD(px,py,m.e0,r.happy),eyeSD(px,py,m.e1,r.happy))*r.s;EV.qx=qx;EV.qy=qy;
  }
  // One figure into a 320-unit square: head cells in its ink, eyes cut out, and its own pulse ring when it hops.
  function drawAv(c,n,es,r){
    const h=(n-1)/2,sp=300/(n-1),edge=.6/h,rMax=.6*sp,m=prep(r,es);
    for(let j=0;j<n;j++){
      const v0=(j-h)/h;
      for(let i=0;i<n;i++){
        const u0=(i-h)/h;if(Math.hypot(u0,v0)>1.02||Math.abs(u0-r.x)>m.reach||Math.abs(v0-r.y)>m.reach)continue;
        evalM(m,u0,v0);
        const maxB=sst(edge,-edge,EV.dB);let f=0,ring=0;
        if(maxB>.001){f=maxB*(1-sst(edge,-edge,EV.dE));if(m.sph)f*=shade(EV.qx,EV.qy);}
        if(r.pulse<1)ring=Math.exp(-Math.pow((EV.dB-.03-r.pulse*.45)/.05,2))*(1-r.pulse);
        const rP=Math.min(1,ring)*(1-maxB),val=Math.min(1,f+rP);
        if(val<.02)continue;
        const H=r.ink,tot=f+rP+.02,wh=f/tot,wr=rP/tot,wa=1-wh-wr;
        c.beginPath();c.arc(10+i*sp,10+j*sp,.35+val*(rMax-.35),0,TAU);
        c.fillStyle=`rgba(${(H[0]*wh+NEU[0]*wa+H[0]*wr)|0},${(H[1]*wh+NEU[1]*wa+H[1]*wr)|0},${(H[2]*wh+NEU[2]*wa+H[2]*wr)|0},${Math.min(1,.22+val*1.6)})`;
        c.fill();
      }
    }
  }
  function gridFor(size){
    if(size>=140)return [45,1];if(size>=70)return [33,1.15];if(size>=44)return [25,1.4];if(size>=36)return [23,1.5];return [19,1.8];
  }

  // MARK: the drop
  const DR_X=50,DR_R=34,DR_S0=76,DR_SH=92,DR_P=3,MAX=4,BUILD=1.25,W=340;
  const KIND={done:'Finished',needs:'Needs you'};
  const notes=[],N={};
  let canvas=null,layer=null,t=0,lastDraw=0,quietSince=0,raf=0,hover=null,hoverOff=0,reduce=false,lastRegions='';
  const calmQuery=root.matchMedia?root.matchMedia('(prefers-reduced-motion: reduce)'):null,darkQuery=root.matchMedia?root.matchMedia('(prefers-color-scheme: dark)'):null;
  const calm=()=>reduce||!!calmQuery?.matches;
  const post=message=>{try{root.webkit?.messageHandlers?.buddyDrop?.postMessage(message);}catch{}};
  const live=()=>notes.filter(i=>N[i.id]&&!N[i.id].popT);
  const plain=(v,n)=>String(v??'').replace(/[\u0000-\u001f\u007f]+/g,' ').replace(/\s+/g,' ').trim().slice(0,n);
  function clean(i){
    if(!i||typeof i!=='object')return null;
    const id=typeof i.id==='string'?i.id.trim():'';if(!id||id.length>200||!Object.hasOwn(KIND,i.kind))return null;
    return {id,kind:i.kind,name:plain(i.name,60)||'Buddy',text:plain(i.text,90),chat:plain(i.chat,200),shape:SHAPES.includes(i.shape)?i.shape:'diamond',color:Object.hasOwn(INK,i.color)?i.color:'lilac'};
  }
  function element(id){
    const el=document.createElement('div');el.className='drop-note';el.dataset.dropId=id;
    const button=document.createElement('button');button.type='button';button.className='drop-holder';
    const label=document.createElement('div');label.className='drop-label';
    const name=document.createElement('span');name.className='drop-name';
    const text=document.createElement('span');text.className='drop-text';
    label.append(name,text);el.append(button,label);
    for(const part of [button,label]){
      part.addEventListener('click',()=>click(id));
      part.addEventListener('mouseenter',()=>setHover(id));
      part.addEventListener('mouseleave',()=>setHover(null));
    }
    layer.append(el);
    return {el,button,label,name,text};
  }
  function fill(n){
    const i=n.item,kind=KIND[n.kind];
    n.dom.name.textContent=i.name;n.dom.text.textContent=i.text?`${kind} · ${i.text}`:kind;
    n.dom.button.setAttribute('aria-label',`${i.name} — ${kind.toLowerCase()}${i.text?`: ${i.text}`:''}. Open in Buddy`);
  }
  // The app's item: {id (the agent), name, kind: done|needs, text, chat, shape, color, reduceMotion}.
  function show(raw){
    const i=clean(raw);if(!i||!canvas)return false;
    if(typeof raw.reduceMotion==='boolean')reduce=raw.reduceMotion;
    const c=calm(),cur=N[i.id];
    if(cur&&!cur.popT){
      // The same agent again: a wobble, the latest label, and the figure plays its state again.
      cur.item=i;cur.kind=i.kind;cur.kicks++;cur.modeSet=false;
      if(!c){cur.kick=t;cur.M.S.sy.v+=1.6;cur.M.S.by.v-=.8;}
      const k=notes.findIndex(x=>x.id===i.id);if(k>=0)notes[k]=i;
      fill(cur);cur.peekFrom=t;cur.peekTo=t+2.8;loop();return true;
    }
    if(cur)remove(i.id);
    const lv=live();
    if(lv.length>=MAX)pop(lv[0].id,true);
    const slot=Math.min(lv.length,MAX-1),cyLand=DR_S0+slot*DR_SH,land=c?0:1.3;
    const n={item:i,kind:i.kind,t0:c?t-BUILD-.6:t,cy:cyLand,vcy:0,M:mkSim(),kick:-10,kicks:0,nextB:0,bk:0,popT:0,ph:Math.random()*6,modeSet:false,mode:null,modeT:0,
      peekFrom:t+land+.25,peekTo:t+land+3.4,shown:false,visible:false,head:document.createElement('canvas'),dom:element(i.id)};
    N[i.id]=n;notes.push(i);fill(n);
    loop();return true;
  }
  function remove(id){const n=N[id];if(!n)return;n.dom.el.remove();delete N[id];const k=notes.findIndex(x=>x.id===id);if(k>=0)notes.splice(k,1);if(hover===id)hover=null;}
  function pop(id,silent){
    const n=N[id];if(!n||n.popT)return;
    n.popT=t||.0001;
    setTimeout(()=>{if(N[id]!==n)return;remove(id);if(!notes.length){draw();post({type:'empty'});}},300);
    if(!silent)post({type:'open',id,chat:n.item.chat});
    loop();
  }
  // A click on a holder (or its visible label), from the page's own pointer or from the app, which takes the click in its panel.
  function click(id){const n=N[id];if(!n||n.popT||!n.visible)return false;pop(id,false);return true;}
  // The pointer over a holder or its label. Leaving waits a moment, so the pointer can cross from the holder to the label.
  function setHover(id){
    clearTimeout(hoverOff);
    if(id){if(N[id]&&!N[id].popT){hover=id;loop();}return;}
    hoverOff=setTimeout(()=>{hover=null;loop();},200);
  }
  function clear(){const lv=live();for(const i of lv)pop(i.id,true);if(!notes.length)post({type:'empty'});}

  function busy(){
    if(hover)return true;
    for(const i of notes){const n=N[i.id];if(n.popT||t-n.t0<BUILD+3.5||t-n.kick<1.5||Math.abs(n.vcy)>.5||n.shown!==labelWanted(n))return true;}
    return false;
  }
  const labelWanted=n=>!n.popT&&(hover===n.item.id||n.peekFrom<=t&&t<n.peekTo);
  function loop(){if(!raf&&canvas)raf=requestAnimationFrame(frame);}
  function frame(){
    raf=0;
    const tn=performance.now()/1000;
    // Settled holders only breathe and blink: thirty frames a second is plenty, and fifteen once nothing has happened for twenty seconds,
    // which saves the battery while one waits for a click.
    if(busy())quietSince=t;
    const step=t-quietSince>20?1/15:1/30;
    if(lastDraw&&quietSince!==t&&tn-lastDraw<step-.002){raf=requestAnimationFrame(frame);return;}
    const dt=Math.min(step,tn-(lastDraw||tn));lastDraw=tn;t+=dt;
    draw(dt);
    if(notes.length)raf=requestAnimationFrame(frame);else lastDraw=0;
  }
  function draw(dt=0){
    dark=!!darkQuery?.matches;
    const dpr=Math.min(2,root.devicePixelRatio||1),H=canvas.clientHeight||440;
    if(canvas.width!==Math.round(W*dpr)||canvas.height!==Math.round(H*dpr)){canvas.width=Math.round(W*dpr);canvas.height=Math.round(H*dpr);}
    const c=canvas.getContext('2d');
    c.setTransform(1,0,0,1,0,0);c.clearRect(0,0,canvas.width,canvas.height);c.setTransform(dpr,0,0,dpr,0,0);
    let k=0;
    for(const i of notes){const n=N[i.id];drawNote(c,i.id,n,t,dt,n.popT?-1:k,dpr,H);if(!n.popT)k++;}
    regions();
  }
  const scratch={v:0,w:0};
  function drawNote(c,id,n,t,dt,slot,dpr,H){
    const i=n.item,cm=calm(),a=t-n.t0,Rf=DR_R,cx=DR_X,kE=Math.min(1,a/BUILD);
    if(slot>=0){const tg=DR_S0+slot*DR_SH;if(cm){n.cy=tg;n.vcy=0;}else{n.vcy+=(170*(tg-n.cy)-21*n.vcy)*dt;n.cy+=n.vcy*dt;}}
    const cy=n.cy,pk=n.popT?Math.min(1,(t-n.popT)/.3):0,kw=t-n.kick,fade=cm?1-pk:1;
    // The holder takes the pointer once it has landed.
    const visible=a>BUILD&&!n.popT;
    const ty=(cy-DR_R-4).toFixed(1);if(ty!==n.ty){n.ty=ty;n.dom.el.style.transform=`translate3d(0,${ty}px,0)`;}
    if(visible!==n.visible){n.visible=visible;n.dom.el.style.visibility=visible?'visible':'hidden';}
    const want=labelWanted(n);if(want!==n.shown){n.shown=want;n.dom.label.classList.toggle('shown',want);}
    let R=Rf+(cm?0:.35*Math.sin(t*2.1+n.ph));
    if(!cm&&kw<1.2)R+=2.6*Math.exp(-kw*4)*Math.sin(kw*18);
    if(!cm)R*=1-pk*.55;
    const fill=easeIO(kE),seed=n.ph*17.3,solid=sst(.9,1,kE)*(cm?1:1-pk);
    if(solid>.01){
      c.save();c.globalAlpha=solid*fade;c.shadowColor=dark?'rgba(0,0,0,.5)':'rgba(20,20,20,.28)';c.shadowBlur=20;c.shadowOffsetY=6;
      c.beginPath();c.arc(cx,cy,Math.max(.1,R-.6),0,TAU);c.fillStyle='#141414';c.fill();c.restore();
    }
    const hc=a-BUILD-.08;let hs=hc<=0?0:Math.max(0,1-Math.exp(-hc*6.5)*Math.cos(hc*9))*(1-pk);
    if(cm)hs=hc>0?1:0;
    if(hc>0&&!n.modeSet){n.modeSet=true;n.mode=n.kind==='done'?'done':'needs';n.modeT=t;n.nextB=t+.5;}
    if(n.mode==='done'&&t-n.modeT>1.4)n.mode='ready';
    const hov=hover===id,fv=hov?[.75,0]:n.kind==='needs'?[0,0]:null;
    if(dt>0){
      stepSim(n.M,n.mode||'ready',fv,t,dt,hov,cm);
      // Blinks follow the state, not chance: a needs-you double blink, a finished agent's slow blink.
      n.M.nextBlink=1e9;
      if(n.modeSet&&t>=n.nextB){if(!cm)n.M.blinkT=t;n.bk++;n.nextB=t+(n.kind==='needs'?(n.bk%2?.24:1.2):(n.bk%2?.26:1.9));}
    }
    const pulseOn=n.kind==='needs'&&n.modeSet&&!pk,pc=pulseOn?((t-n.modeT)%2.4)/.8:9;
    // The halftone holder: v is the disc (dots switching on while it builds), w the rings outside it (the needs pulse, the pop).
    const f=(x,y)=>{
      const dx=x-cx,dy=y-cy,d0=Math.hypot(dx,dy),d=d0-R;
      let v=sst(1.5,-1.5,d)*(cm?1:1-pk);
      if(kE<1&&v>0){const th=hash(Math.floor(x/DR_P)+seed,Math.floor(y/DR_P)-seed)*.78+Math.min(1,d0/R)*.22;v*=sst(th-.06,th+.02,fill*1.04);}
      let w=0;
      if(pc<1)w=.36*Math.pow(1-pc,1.5)*Math.exp(-Math.pow((d0-(R+3+pc*24))/2.6,2));
      if(pk>0&&!cm)w=Math.max(w,.6*(1-pk)*Math.exp(-Math.pow((d0-(Rf+pk*30))/2.4,2)));
      scratch.v=v;scratch.w=w;
    };
    const P=DR_P,x1=cx+Rf*1.6+30,y0=cy-Rf-34,y1=cy+Rf+34,disc='rgb(20,20,20)',ring=dark?'rgb(242,240,234)':disc;
    let style='';
    for(let j=Math.max(0,Math.floor(y0/P));j<=Math.min(Math.ceil(H/P),Math.ceil(y1/P));j++){
      const y=(j+.5)*P;
      for(let i2=0;i2<=Math.min(Math.ceil(W/P),Math.ceil(x1/P));i2++){
        const x=(i2+.5)*P;f(x,y);const val=Math.max(scratch.v,scratch.w);if(val<.03)continue;
        const col=scratch.v>=scratch.w?disc:ring;if(col!==style){c.fillStyle=col;style=col;}
        c.globalAlpha=Math.min(1,.3+val*1.4)*fade;
        c.beginPath();c.arc(x,y,.3+Math.min(1,val)*P*.6,0,TAU);c.fill();
      }
    }
    c.globalAlpha=1;
    if(dark&&solid>.01){c.save();c.globalAlpha=solid*fade;c.strokeStyle='rgba(242,240,234,.16)';c.lineWidth=1;c.beginPath();c.arc(cx,cy,R+.5,0,TAU);c.stroke();c.restore();}
    if(hs>.01){
      const sz=2*Math.max(14,Rf-4),px=Math.round(sz*dpr),hcv=n.head;
      if(hcv.width!==px){hcv.width=px;hcv.height=px;}
      const hx=hcv.getContext('2d');hx.setTransform(1,0,0,1,0,0);hx.clearRect(0,0,px,px);const s3=px/320;hx.setTransform(s3,0,0,s3,0,0);
      const g=gridFor(sz);drawAv(hx,g[0],g[1],mkR(n.M,i.shape,i.color,{x:0,y:.02,s:1.08},t));
      const dw=sz*hs*(R/Rf);c.globalAlpha=fade;c.drawImage(hcv,cx-dw/2,cy-dw/2,dw,dw);c.globalAlpha=1;
    }
  }
  // Where the app should take clicks: each landed holder (a circle) and each label while it shows. Sent only when it changes.
  function regions(){
    const rects=[],r1=v=>Math.round(v*2)/2;
    for(const i of notes){
      const n=N[i.id];if(!n.visible)continue;
      rects.push({id:i.id,part:'holder',x:DR_X-38,y:r1(n.cy-38),w:76,h:76,round:true});
      if(n.shown){const b=n.dom.label.getBoundingClientRect();if(b.width)rects.push({id:i.id,part:'label',x:r1(b.left),y:r1(b.top),w:r1(b.width),h:r1(b.height)});}
    }
    const json=JSON.stringify(rects);if(json!==lastRegions){lastRegions=json;post({type:'regions',rects});}
  }
  function snapshot(){
    return {calm:calm(),t,notes:notes.map(i=>{const n=N[i.id];return {id:i.id,kind:n.kind,text:i.text,chat:i.chat,cy:n.cy,vcy:n.vcy,built:t-n.t0>BUILD,popping:!!n.popT,kicks:n.kicks,mode:n.mode||'ready',spun:n.M.spinT>-10,hopped:n.M.hops>0,label:n.shown};})};
  }
  root.BuddyDropPage={show,hover:id=>setHover(typeof id==='string'?id:null),click,clear,snapshot};
  function start(){
    canvas=document.querySelector('canvas.drop-canvas');layer=document.querySelector('.drop-notes');
    darkQuery?.addEventListener?.('change',()=>{if(notes.length)loop();});
    post({type:'ready'});
  }
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',start,{once:true});else start();
})(typeof globalThis!=='undefined'?globalThis:this);

/* Field play: the extra life of the sidebar dot field, ported from the design handoff (Buddy Field Play).
   Quiet patterns forming in the background, a thought cloud over an agent that is working, roots that grow from an agent's
   head when its chat opens, a dot-matrix count of unread replies (and dots that converge when one lands), dots that flow from
   the composer into the agent you are writing to, and agents that close their eyes after a while idle.
   The pure half (patterns, glyphs, roots, cloud) is unit-tested; the runtime half plugs into BuddyFigures.extend. */
(function(root){
  'use strict';
  const TAU=Math.PI*2;
  const hash=(a,b)=>{const s=Math.sin(a*127.1+b*311.7)*43758.5453;return s-Math.floor(s);};
  const easeIO=k=>k<.5?4*k*k*k:1-Math.pow(-2*k+2,3)/2;
  const sdBox=(px,py,bx,by,r)=>{const qx=Math.abs(px)-bx+r,qy=Math.abs(py)-by+r;return Math.hypot(Math.max(qx,0),Math.max(qy,0))+Math.min(Math.max(qx,qy),0)-r;};

  // ---- background patterns: each says how bright the cell (i,j) is, 0 to 1 ----
  const PATS=[
    (i,j)=>(i%10===0&&j%10===0?1:i%10===0||j%10===0?.6:0),
    (i,j,c)=>{const d=Math.max(Math.abs(i-c.ci),Math.abs(j-c.cj));return d%8===0?1:0;},
    (i,j)=>((i+j)%9===0||((i-j)%9+9)%9===0?.8:0),
    (i,j)=>(i%6===0&&j%6===0?1:0),
    (i,j,c)=>{const d=Math.hypot(i-c.ci,j-c.cj);return Math.abs(d-Math.round(d/9)*9)<.5?1:0;},
    (i,j)=>{const k=((j%12)+12)%12,m=i%12;return Math.abs(Math.abs(m-6)-k)<.6&&k<=6?.9:0;},
    (i,j)=>{const r=Math.floor(j/7),o=r%2?4:0;return j%7===0||((i+o)%8===0)?.7:0;},
    (i,j)=>(i%4===0&&j%4===0&&(Math.floor(i/16)+Math.floor(j/16))%2===0?1:0)
  ];
  // A pattern forms over FORM seconds, holds, fades, and the field rests for GAP before the next one.
  const FORM=5,HOLD=10,FADE=5,GAP=3,CYCLE=FORM+HOLD+FADE+GAP;
  function saverAt(sv,t,random=Math.random){
    if(!sv)sv={idx:Math.floor(random()*PATS.length),t0:t};
    if(t-sv.t0>CYCLE){sv.idx=(sv.idx+1+Math.floor(random()*(PATS.length-1)))%PATS.length;sv.t0=t;}
    const a=t-sv.t0,k=a<FORM?a/FORM:a<FORM+HOLD?1:a<FORM+HOLD+FADE?1-(a-FORM-HOLD)/FADE:0;
    return {sv,k};
  }
  // Cells of the pattern that are lit at progress k (they appear and dissolve in a scattered order, not as a wipe).
  function saverCells(idx,k,cols,rows,amp,put){
    if(!(k>0))return;
    const f=PATS[idx],ctx={ci:Math.round(cols/2),cj:Math.round(rows*.42)},seed=idx*13.7;
    for(let j=0;j<rows;j++)for(let i=0;i<cols;i++){
      const v=f(i,j,ctx);if(!v)continue;
      const th=hash(i+seed,j-seed),vis=Math.max(0,Math.min(1,(k-th*.85)/.15));
      if(vis>0)put(i,j,amp*v*vis);
    }
  }

  // ---- unread count in dot-matrix digits: 3 x 5 cells per character, one cell between ----
  const GLYPH={0:'111101101101111',1:'010110010010111',2:'111001111100111',3:'111001111001111',4:'101101111001001',5:'111100111001111',6:'111100111101111',7:'111001010010010',8:'111101111101111',9:'111101111001111','+':'000010111010000'};
  const countText=n=>n>9?'9+':String(Math.max(0,Math.floor(n)||0));
  const glyphWidth=text=>text.length*4-1;
  function glyphCells(text){
    const out=[];
    for(let c=0;c<text.length;c++){const g=GLYPH[text[c]];if(!g)continue;for(let q=0;q<15;q++)if(g[q]==='1'){const gi=q%3;out.push({c,gi,gj:(q-gi)/3});}}
    return out;
  }

  // ---- roots: grow from the head across the row, bouncing off its edges ----
  // bounds are relative to the head's centre. random() returns [0,1); pass a fixed one to get the same roots every time.
  function makeRoots({bounds,r0,ids=1,random=Math.random}){
    const rnd=(a,b)=>a+random()*(b-a),bx=bounds,pts=[],tips=[];
    const inside=(x,y)=>x>bx.x0&&x<bx.x1&&y>bx.y0&&y<bx.y1;
    const grow=(x,y,a,s,depth,ci,maxL)=>{
      let len=0;
      while(len<maxL&&pts.length<2600){
        a+=rnd(-.3,.3)+(Math.cos(a)<.2?.04*Math.sign(Math.sin(a)||1):0);
        let nx=x+Math.cos(a)*2.4,ny=y+Math.sin(a)*2.4;
        if(nx<=bx.x0||nx>=bx.x1){a=Math.PI-a;nx=x+Math.cos(a)*2.4;}
        if(ny<=bx.y0||ny>=bx.y1){a=-a;ny=y+Math.sin(a)*2.4;}
        if(!inside(nx,ny))break;
        x=nx;y=ny;len+=2.4;s+=2.4;
        pts.push({x,y,s,ci,w:depth});
        if(depth<4&&random()<.06)grow(x,y,a+(random()<.5?-1:1)*rnd(.5,1.1),s,depth+1,ci,(maxL-len)*rnd(.45,.8));
      }
      tips.push({x,y,s,ci});
    };
    const nRoot=12;
    for(let q=0;q<nRoot;q++){const a=q/nRoot*TAU+rnd(-.2,.2);grow(Math.cos(a)*r0,Math.sin(a)*r0,a,0,0,q%Math.max(1,ids),rnd(160,300));}
    return {pts,tips,smax:pts.reduce((m,p)=>Math.max(m,p.s),1)};
  }
  const GROW=2.3,BURST=3.5;

  // ---- thought cloud over a working agent: value of each cell it covers ----
  function cloudCells(cx,cy,half,grow,t,ph,P,cols,rows,emit,calm){
    const bob=calm?0:Math.sin(t*2.2+ph)*1.5,tt=calm?0:t;
    const ccx=cx+half*.55,ccy=cy-half*.95+bob,sc=.55+.45*grow;
    const puffs=[[-9,2,6.5],[-2,-3,8],[7,-1,7],[12,3,5],[2,4,6.5]].map(p=>[ccx+p[0]*sc,ccy+p[1]*sc,p[2]*sc*(1+.06*Math.sin(tt*3+p[0]))]);
    const bubs=[[cx+half*.32,cy-half*.58,1.8],[cx+half*.42,cy-half*.72,2.6]];
    const x1=ccx+22,y0=ccy-16,y1=cy-half*.5;
    for(let j=Math.max(0,Math.floor(y0/P));j<=Math.min(rows-1,Math.ceil(y1/P));j++)for(let i=Math.max(0,Math.floor(cx/P));i<=Math.min(cols-1,Math.ceil(x1/P));i++){
      const px=(i+.5)*P,py=(j+.5)*P;
      let dmin=1e9;for(const p of puffs)dmin=Math.min(dmin,Math.hypot(px-p[0],py-p[1])-p[2]);
      let bv=0;if(grow>.5)for(const b of bubs){const db=Math.hypot(px-b[0],py-b[1])-b[2]*sc;if(db<1)bv=Math.max(bv,.42*Math.min(1,1-db));}
      if(dmin<1.2){
        const inner=.5+.5*Math.sin(px*.5+py*.3-tt*4)*Math.cos(py*.45-tt*2.6),rim=Math.exp(-dmin*dmin/2.2);
        emit(i,j,grow*Math.min(1,dmin<0?.3+.28*inner+.3*rim:.55*(1.2-dmin)));
      }else if(bv)emit(i,j,bv*grow);
    }
  }

  // ---- runtime ------------------------------------------------------------------------------------------------
  const SLEEP_AFTER=15;
  const RUNNING=new Set(['working','planning','needs']);
  const state={sleepAfter:SLEEP_AFTER,asleep:false,lastAct:0,awake:new Set(),zzz:[],nextZ:0,bursts:[],arrivals:[],keys:[],unread:{},seen:{},typingT:null,sv:null,prevSel:null,cloud:{},host:null,viewing:null};
  const unreadOf=id=>state.unread[id]||0;
  const membersOf=(cfg,id)=>cfg&&cfg.group&&cfg.group(id)?.members||[id];
  const activity=()=>{if(!state.asleep)state.lastAct=root.BuddyFigures?.now?.()||0;};
  const bounce=(host,id,by,sy,delay=0)=>{
    const run=()=>{const M=host.sim(id);M.S.by.v-=by;M.S.sy.v+=sy;};
    if(delay)setTimeout(run,delay);else run();
  };
  function wakeAgents(ids){
    const host=state.host;if(!host||!state.asleep)return;
    ids.forEach((id,k)=>{
      if(state.awake.has(id))return;
      state.awake.add(id);
      setTimeout(()=>{const M=host.sim(id);M.S.by.v-=1.3;M.S.sy.v+=1.2;M.S.open.v+=4;},90*k);
    });
    if(host.cfg.agentIds().every(id=>state.awake.has(id))){state.asleep=false;state.awake.clear();state.lastAct=host.clock;}
  }
  const viewingId=()=>typeof document==='undefined'?null:document.querySelector('.sidebar .chat-row.selected')?.dataset.id||null;

  const extension={
    // Once per frame, before the figures move: sleep, and what has arrived while you were elsewhere.
    frame(host){
      state.host=host;
      const running=host.ids.some(id=>RUNNING.has(host.getMode(id)));
      if(running)state.lastAct=host.clock;
      if(!state.asleep&&!running&&host.clock-state.lastAct>state.sleepAfter){state.asleep=true;state.awake.clear();}
      if(typeof host.cfg.replies!=='function')return;
      const viewing=viewingId(),groups=host.cfg.groupIds?host.cfg.groupIds():[];
      state.viewing=viewing;
      for(const id of [...host.ids,...groups]){
        const n=host.cfg.replies(id),was=state.seen[id];
        if(id===viewing){delete state.unread[id];state.seen[id]=n;continue;}
        if(was===undefined||n<was){state.seen[id]=n;continue;}
        if(n>was){
          state.seen[id]=n;state.unread[id]=unreadOf(id)+(n-was);
          if(!host.calm){state.arrivals.push({id,t0:host.clock});membersOf(host.cfg,id).forEach((m,k)=>bounce(host,m,1.3,1.1,80*k));}
        }
      }
      for(const id of Object.keys(state.unread))if(!state.unread[id])delete state.unread[id];
    },
    listening(id){
      const now=root.BuddyFigures?.now?.()||0;
      return state.typingT!=null&&now-state.typingT<1.4&&id===state.viewing;
    },
    sleeping(id,info){return state.asleep&&info.known&&!state.awake.has(id)&&info.mode==='ready';},

    field(c){
      const {t,P,cols,rows,W,put,blob,pos,rowEls,rect,NEU,calm,inkOf,compact,clip,getMode,sim,cfg}=c;
      // Rows know when they carry an unread count, so the snippet leaves room for it.
      for(const [id,el] of rowEls)el.classList.toggle('field-unread',unreadOf(id)>0);

      // 1. patterns forming and dissolving behind everything
      if(!calm){
        const {sv,k}=saverAt(state.sv,t);state.sv=sv;
        saverCells(sv.idx,k,cols,rows,state.asleep?.075:.042,(i,j,v)=>put(i,j,v,NEU));
      }

      clip(true);
      // 2. opening a chat: roots grow out of the head, fill the row, and a thin ink border holds for a moment
      const sel=[...rowEls].find(([,el])=>el.classList.contains('selected')||el.getAttribute('aria-current')==='page')?.[0]||null;
      if(sel&&state.prevSel&&sel!==state.prevSel&&!calm){
        const hm=pos['row:'+sel],el=rowEls.get(sel);
        if(hm&&el){
          const rr=el.getBoundingClientRect(),members=membersOf(cfg,sel);
          const bounds={x0:rr.left-rect.left-hm.x+3,x1:rr.right-rect.left-hm.x-3,y0:rr.top-rect.top-hm.y+3,y1:rr.bottom-rect.top-hm.y-3};
          const roots=makeRoots({bounds,r0:hm.spec.size/2*.62,ids:members.length});
          state.bursts.push({id:sel,t0:t,ids:members,...roots});
          members.forEach(m=>{const M=sim(m);M.S.sy.v+=1.4;M.S.sx.v-=.7;});
        }
      }
      if(sel)state.prevSel=sel;
      state.bursts=state.bursts.filter(b=>t-b.t0<BURST);
      for(const bu of state.bursts)paintRoots(c,bu);

      // 3. unread counts and the dots that converge when a reply lands
      state.arrivals=state.arrivals.filter(a=>t-a.t0<1.3);
      const badgeAt=id=>{const el=rowEls.get(id),p0=pos['row:'+id];if(!el||!p0)return null;const r=el.getBoundingClientRect();return compact?{x:r.right-rect.left-10,y:r.top-rect.top+11}:{x:r.right-rect.left-13,y:p0.y+3};};
      for(const id in state.unread){
        const n=unreadOf(id),b=n&&badgeAt(id);if(!b)continue;
        const col=inkOf(id),text=countText(n),w=glyphWidth(text),i0=Math.round(b.x/P-w/2),j0=Math.round(b.y/P-2.5);
        for(const g of glyphCells(text))put(i0+g.c*4+g.gi,j0+g.gj,.82+(calm?0:.18*Math.sin(t*3-g.gj*.7-g.c)),col);
      }
      for(const a of state.arrivals){
        const b=badgeAt(a.id);if(!b)continue;
        const k=(t-a.t0)/1.3,e=easeIO(Math.min(1,k/.8)),col=inkOf(a.id);
        for(let q=0;q<12;q++){const ang=q/12*TAU+k*1.5,rr=46*(1-e);blob({x:b.x+Math.cos(ang)*rr,y:b.y+Math.sin(ang)*rr*.8},.75*Math.sin(Math.min(1,k*1.25)*Math.PI),col,3.2);}
      }

      // 4. typing: dots flow from the composer into the agent you are writing to
      state.keys=state.keys.filter(kp=>t-kp.t0<.75);
      const lp=state.keys.length&&state.viewing&&pos['row:'+state.viewing];
      if(lp&&!calm){
        const col=inkOf(state.viewing),x1=lp.x+lp.spec.size*.6;
        for(const kp of state.keys){const a2=(t-kp.t0)/.75,e2=1-Math.pow(1-a2,2);blob({x:W-4-e2*(W-4-x1),y:lp.y+kp.dy*(1-e2)},.55*Math.sin(Math.min(1,a2*1.4)*Math.PI*.5+.2)*(1-a2*.6),col,5);}
      }

      // 5. sleepers breathe out little z's
      if(state.asleep&&!calm){
        if(!state.nextZ||t>state.nextZ){
          state.nextZ=t+.5+Math.random()*.6;
          const ids=Object.keys(pos).filter(k=>k.startsWith('row:')&&cfg.agent(k.slice(4))&&!state.awake.has(k.slice(4))&&getMode(k.slice(4))==='ready');
          if(ids.length)state.zzz.push({key:ids[Math.floor(Math.random()*ids.length)],t0:t});
        }
        state.zzz=state.zzz.filter(z=>t-z.t0<2.4);
        for(const z of state.zzz){
          const p0=pos[z.key];if(!p0)continue;
          const a3=(t-z.t0)/2.4;
          blob({x:p0.x+p0.spec.size*.35+a3*26+Math.sin(a3*9)*4,y:p0.y-p0.spec.size*.35-a3*34},.5*Math.sin(a3*Math.PI),inkOf(z.key.slice(4)),3+a3*3);
        }
      }else state.zzz=[];

      // 6. a thought cloud over every agent that is working
      for(const key in pos){
        if(!key.startsWith('row:'))continue;
        const p0=pos[key];if(p0.spec.kind!=='agent')continue;
        const id=key.slice(4),cl=state.cloud[id]||(state.cloud[id]={in:0,out:0,on:false}),working=getMode(id)==='working';
        if(working&&!cl.on){cl.on=true;cl.in=t;cl.out=0;}
        else if(!working&&cl.on){cl.on=false;cl.out=t;}
        if(!cl.on&&!(cl.out&&t-cl.out<.5))continue;
        const kin=Math.min(1,(t-cl.in)/.45),kout=cl.on?1:1-(t-cl.out)/.5,grow=easeIO(calm?(cl.on?1:0):Math.min(kin,Math.max(0,kout)));
        const col=inkOf(id),ph=sim(id).ph;
        cloudCells(p0.x,p0.y,p0.spec.size/2,grow,t,ph,P,cols,rows,(i,j,v)=>put(i,j,v,col),calm);
      }
      clip(false);
    }
  };

  // The roots, the row's ink border (held for a moment), and the faint ink that fills the row while they grow.
  function paintRoots(c,bu){
    const {t,P,cols,rows,pos,rowEls,rect,put,blob,inkOf,NEU}=c;
    const p0=pos['row:'+bu.id];if(!p0)return;
    const a=t-bu.t0,gf=(1-Math.pow(1-Math.min(1,a/GROW),1.8))*(bu.smax+4),life=a<2.4?1:Math.max(0,1-(a-2.4)/.6);
    const fillK=Math.max(0,Math.min(1,(a-1.1)/1.1)),rowEl=rowEls.get(bu.id);
    const bk=a<2.15?0:a<2.35?(a-2.15)/.2:a<3.15?1:Math.max(0,1-(a-3.15)/.3);
    const inks=bu.ids.map(id=>inkOf(id)||NEU);
    if(rowEl&&(bk>0||fillK>0)){
      const rb=rowEl.getBoundingClientRect(),x0=rb.left-rect.left,y0=rb.top-rect.top,w=rb.width,hh=rb.height,ink=inks[0];
      for(let j=Math.max(0,Math.floor(y0/P)-1);j<=Math.min(rows-1,Math.ceil((y0+hh)/P)+1);j++)for(let i=Math.max(0,Math.floor(x0/P)-1);i<=Math.min(cols-1,Math.ceil((x0+w)/P)+1);i++){
        const px=(i+.5)*P-x0,py=(j+.5)*P-y0,d=sdBox(px-w/2,py-hh/2,w/2,hh/2,14);
        if(bk>0&&Math.abs(d+.6)<P*.62)put(i,j,bk*.42,ink);
        if(fillK>0&&d<=-1&&hash(i*.9,j*1.1)<=fillK)put(i,j,life*.16*(.6+.4*hash(j,i)),ink);
      }
    }
    for(const pt of bu.pts){
      if(pt.s>gf)continue;
      const behind=gf-pt.s,v=life*(.26+.55*Math.exp(-behind/10))*(1-pt.w*.12);
      put(Math.floor((p0.x+pt.x)/P),Math.floor((p0.y+pt.y)/P),v,inks[pt.ci]);
    }
    for(const tp of bu.tips)if(tp.s<=gf)blob({x:p0.x+tp.x,y:p0.y+tp.y},life*.8,inks[tp.ci],3.4+Math.sin(t*5+tp.x)*.6);
    for(const pt of bu.pts){const ds=gf-pt.s;if(ds>=0&&ds<4)blob({x:p0.x+pt.x,y:p0.y+pt.y},life*.65,inks[pt.ci],2.6);}
  }

  function install(figures){
    if(typeof document==='undefined'||!figures||typeof figures.extend!=='function')return;
    figures.extend(extension);
    document.addEventListener('keydown',activity,true);
    document.addEventListener('pointerdown',activity,true);
    document.addEventListener('wheel',activity,{capture:true,passive:true});
    document.addEventListener('mousemove',e=>{if(e.target.closest&&e.target.closest('.sidebar'))activity();},{passive:true});
    document.addEventListener('input',e=>{
      if(!e.target||e.target.id!=='message-input')return;
      const now=figures.now();state.typingT=now;activity();
      state.keys.push({t0:now,dy:Math.random()*20-10});if(state.keys.length>40)state.keys.shift();
    },true);
    // Only choosing an agent wakes it (a group wakes its members): the others keep sleeping.
    document.addEventListener('click',e=>{
      const row=e.target.closest&&e.target.closest('.sidebar .chat-row[data-id]');
      if(row&&state.host)wakeAgents(membersOf(state.host.cfg,row.dataset.id));
    },true);
  }

  const api={PATS,CYCLE,FORM,HOLD,FADE,GAP,saverAt,saverCells,GLYPH,countText,glyphWidth,glyphCells,makeRoots,GROW,BURST,cloudCells,SLEEP_AFTER,extension,state,install,wakeAgents};
  if(typeof module!=='undefined'&&module.exports)module.exports=api;
  root.BuddyFieldPlay=api;
  if(typeof document!=='undefined')install(root.BuddyFigures);
})(typeof globalThis!=='undefined'?globalThis:this);

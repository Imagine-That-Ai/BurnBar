/* GENERATED FILE — do not edit by hand. Built from tools/kernel-backdrop/entry.ts + apps/console/lib/gl/engine/. Regenerate: node scripts/build-kernel-backdrop.mjs */
(()=>{var wt=Object.defineProperty;var pr=(e,t,o)=>t in e?wt(e,t,{enumerable:!0,configurable:!0,writable:!0,value:o}):e[t]=o;var S=(e,t)=>()=>(e&&(t=e(e=0)),t);var K=(e,t)=>{for(var o in t)wt(e,o,{get:t[o],enumerable:!0})};var F=(e,t,o)=>pr(e,typeof t!="symbol"?t+"":t,o);function xt(e){let t=!!e.getExtension("EXT_color_buffer_float"),o=!1;if(t){let a=e.createTexture(),i=e.createFramebuffer();a&&i&&(e.bindTexture(e.TEXTURE_2D,a),e.texStorage2D(e.TEXTURE_2D,1,e.RGBA16F,1,1),e.bindFramebuffer(e.FRAMEBUFFER,i),e.framebufferTexture2D(e.FRAMEBUFFER,e.COLOR_ATTACHMENT0,e.TEXTURE_2D,a,0),o=e.checkFramebufferStatus(e.FRAMEBUFFER)===e.FRAMEBUFFER_COMPLETE,e.bindFramebuffer(e.FRAMEBUFFER,null)),a&&e.deleteTexture(a),i&&e.deleteFramebuffer(i)}return{colorBufferFloat:o,floatBlend:!!e.getExtension("EXT_float_blend")}}function Tt(e,t,o){return t==="RG16F"?{internalFormat:e.RG16F,format:e.RG,type:e.HALF_FLOAT,filterable:!0,renderable:o.colorBufferFloat}:{internalFormat:e.RGBA16F,format:e.RGBA,type:e.HALF_FLOAT,filterable:!0,renderable:o.colorBufferFloat}}var ot,We=S(()=>{"use strict";ot={colorBufferFloat:!1,floatBlend:!1}});function q(e,t,o,a,i){return{theme:e,bg:t,accents:o,ink:a,intensity:i}}var hr,Zi,Rt=S(()=>{"use strict";hr={id:"studio",label:"Studio",blurb:"The house identity \u2014 iris-led jewel tones over deep ink.",emoji:"\u2726",dark:q("dark",[7,8,15],[[131,142,255],[120,220,232],[176,142,255],[255,150,182]],[232,236,255],1),light:q("light",[244,246,251],[[84,96,222],[32,150,176],[124,96,212],[212,104,140]],[38,42,70],.78)},Zi=[hr,{id:"aurora-borealis",label:"Aurora Borealis",blurb:"Polar night \u2014 emerald curtains bleeding into electric violet.",emoji:"\u{1F30C}",dark:q("dark",[4,10,14],[[64,224,168],[72,214,232],[128,152,255],[196,132,255]],[224,244,240],1),light:q("light",[240,248,246],[[16,158,124],[28,150,176],[86,100,214],[142,86,206]],[24,46,44],.8)},{id:"ember-forge",label:"Ember Forge",blurb:"Molten metal \u2014 ember orange cooling through coral to ash violet.",emoji:"\u{1F525}",dark:q("dark",[14,7,6],[[255,138,56],[255,92,92],[240,84,142],[168,110,220]],[255,236,222],1),light:q("light",[251,244,240],[[214,96,24],[212,64,72],[200,60,120],[134,78,188]],[56,30,24],.82)},{id:"coral-reef",label:"Coral Reef",blurb:"Shallow lagoon \u2014 turquoise water, living coral, anemone gold.",emoji:"\u{1FAB8}",dark:q("dark",[5,13,16],[[54,226,214],[88,200,255],[255,126,142],[255,196,96]],[226,246,248],1),light:q("light",[240,250,250],[[16,168,162],[30,138,206],[224,86,104],[212,144,36]],[20,48,50],.8)},{id:"ultraviolet",label:"Ultraviolet",blurb:"Synthwave dusk \u2014 magenta horizon over indigo, cut by cyan neon.",emoji:"\u{1F303}",dark:q("dark",[10,6,20],[[255,92,196],[150,96,255],[96,132,255],[80,230,240]],[240,228,255],1),light:q("light",[246,242,252],[[206,48,156],[120,72,214],[70,96,214],[24,158,178]],[40,26,64],.8)},{id:"verdigris",label:"Verdigris",blurb:"Oxidized copper \u2014 patina teal over bronze, weathered to jade.",emoji:"\u{1F5FF}",dark:q("dark",[8,13,12],[[72,204,180],[122,196,138],[206,178,110],[224,142,96]],[228,240,232],1),light:q("light",[242,248,244],[[22,150,132],[70,152,96],[160,130,56],[186,100,56]],[28,44,40],.8)},{id:"blackcurrant",label:"Blackcurrant",blurb:"Orchard at midnight \u2014 berry crimson, plum, and frosted mint.",emoji:"\u{1F347}",dark:q("dark",[12,7,14],[[226,76,122],[168,92,198],[120,110,224],[120,224,184]],[240,228,240],1),light:q("light",[249,244,250],[[196,52,100],[142,70,174],[92,86,200],[36,162,124]],[48,28,50],.8)},{id:"solar-flare",label:"Solar Flare",blurb:"Chromosphere \u2014 white-gold core through amber to plasma red.",emoji:"\u2600\uFE0F",dark:q("dark",[16,9,4],[[255,224,130],[255,168,64],[255,110,64],[236,72,96]],[255,240,220],1),light:q("light",[252,247,238],[[206,158,28],[212,120,24],[210,76,36],[196,52,76]],[54,32,18],.82)},{id:"abyssal",label:"Abyssal",blurb:"Deep sea \u2014 bioluminescent cyan and jellyfish violet in the dark.",emoji:"\u{1F30A}",dark:q("dark",[3,7,16],[[40,200,224],[64,140,240],[134,108,232],[196,96,200]],[214,234,248],1),light:q("light",[238,244,250],[[18,146,174],[34,102,200],[96,80,200],[150,64,168]],[18,38,58],.8)},{id:"sakura-dusk",label:"Sakura Dusk",blurb:"Blossom hour \u2014 petal pink, wisteria, and the last warm sky.",emoji:"\u{1F338}",dark:q("dark",[14,9,13],[[255,158,192],[214,142,232],[150,150,240],[255,192,150]],[248,234,240],1),light:q("light",[251,245,248],[[220,102,150],[168,96,200],[104,104,210],[212,134,78]],[52,32,44],.78)},{id:"monochrome-ink",label:"Monochrome Ink",blurb:"Graphite study \u2014 a single luminous channel, sumi restraint.",emoji:"\u2B1B",dark:q("dark",[9,10,12],[[210,216,230],[150,160,184],[104,116,146],[232,236,244]],[235,238,245],.92),light:q("light",[245,246,248],[[70,78,96],[104,112,132],[140,148,168],[40,46,60]],[28,32,42],.74)},{id:"petrol-slick",label:"Petrol Slick",blurb:"Oil on wet asphalt \u2014 a thin-film rainbow over deep tar.",emoji:"\u{1F6E2}\uFE0F",dark:q("dark",[8,10,14],[[96,180,255],[120,240,200],[200,150,255],[255,168,120]],[228,236,248],1),light:q("light",[240,242,246],[[58,140,214],[40,176,150],[150,104,210],[206,122,70]],[34,40,54],.76)},{id:"sumi-bleed",label:"Sumi Bleed",blurb:"Ink wicking into damp kozo \u2014 indigo running to vermillion.",emoji:"\u{1F58B}\uFE0F",dark:q("dark",[12,13,17],[[120,196,224],[150,226,214],[196,156,232],[255,150,130]],[232,234,240],.98),light:q("light",[243,240,232],[[44,120,168],[36,150,150],[150,92,180],[206,84,72]],[30,28,32],.76)}]});function At(){return{}}function Ct(){return{presetId:null,dark:At(),light:At()}}function br(e){return Math.max(0,Math.min(255,Math.round(e)))}function rt(e){if(!Array.isArray(e)||e.length!==3)return;let t=e.map(o=>typeof o=="number"&&Number.isFinite(o)?br(o):NaN);if(!t.some(o=>Number.isNaN(o)))return t}function St(e){if(!e||typeof e!="object")return{};let t=e,o={},a=rt(t.bg);a&&(o.bg=a);let i=rt(t.ink);return i&&(o.ink=i),typeof t.intensity=="number"&&Number.isFinite(t.intensity)&&(o.intensity=Math.max(0,Math.min(1,t.intensity))),Array.isArray(t.accents)&&(o.accents=t.accents.slice(0,4).map(s=>rt(s)??null)),o}function gr(){if(!(Et||typeof window>"u")){Et=!0;try{let e=window.localStorage.getItem(vr);if(!e)return;let t=JSON.parse(e);it={presetId:typeof t.presetId=="string"?t.presetId:null,dark:St(t.dark),light:St(t.light)}}catch{it=Ct()}}}function kt(){return gr(),it}function It(e,t){let o=e.accents.map((a,i)=>t.accents?.[i]??a);return{theme:e.theme,bg:t.bg??e.bg,accents:o,ink:t.ink??e.ink,intensity:t.intensity??e.intensity}}var vr,it,Et,Pt=S(()=>{"use strict";Rt();vr="studio.customPalette";it=Ct(),Et=!1});function Tr(e){let t=xr[e];return{theme:t.theme,bg:[...t.bg],accents:t.accents.map(o=>[...o]),ink:[...t.ink],intensity:t.intensity}}function Ve(e){return It(Tr(e),kt()[e])}function ie(e){return[e[0]/255,e[1]/255,e[2]/255]}function J(e,t){let[o,a,i]=e;return t===void 0?`rgb(${o|0},${a|0},${i|0})`:`rgba(${o|0},${a|0},${i|0},${t})`}function Re(e,t,o){return[e[0]+(t[0]-e[0])*o,e[1]+(t[1]-e[1])*o,e[2]+(t[2]-e[2])*o]}var yr,wr,xr,Be=S(()=>{"use strict";Pt();yr={theme:"dark",bg:[7,8,15],accents:[[131,142,255],[120,220,232],[176,142,255],[255,150,182]],ink:[232,236,255],intensity:1},wr={theme:"light",bg:[244,246,251],accents:[[84,96,222],[32,150,176],[124,96,212],[212,104,140]],ink:[38,42,70],intensity:.78},xr={dark:yr,light:wr}});function ge(e){return Bt[e]}function je(e){return Ft[e]}function Xe(e,t,o,a){return nt[e]*t+nt[e+1]*o+nt[e+2]*a}function Ye(e,t,o){let a=0,i=0,s=0,m=0,x=(e+t+o)*Ar,b=Math.floor(e+x),C=Math.floor(t+x),w=Math.floor(o+x),T=(b+C+w)*fe,h=e-(b-T),E=t-(C-T),I=o-(w-T),U,_,D,d,n,f;h>=E?E>=I?(U=1,_=0,D=0,d=1,n=1,f=0):h>=I?(U=1,_=0,D=0,d=1,n=0,f=1):(U=0,_=0,D=1,d=1,n=0,f=1):E<I?(U=0,_=0,D=1,d=0,n=1,f=1):h<I?(U=0,_=1,D=0,d=0,n=1,f=1):(U=0,_=1,D=0,d=1,n=1,f=0);let p=h-U+fe,k=E-_+fe,P=I-D+fe,M=h-d+2*fe,l=E-n+2*fe,c=I-f+2*fe,v=h-1+3*fe,A=E-1+3*fe,B=I-1+3*fe,V=b&255,$=C&255,j=w&255,X=.6-h*h-E*E-I*I;if(X>=0){let Q=je(V+ge($+ge(j)))*3;X*=X,a=X*X*Xe(Q,h,E,I)}let Z=.6-p*p-k*k-P*P;if(Z>=0){let Q=je(V+U+ge($+_+ge(j+D)))*3;Z*=Z,i=Z*Z*Xe(Q,p,k,P)}let W=.6-M*M-l*l-c*c;if(W>=0){let Q=je(V+d+ge($+n+ge(j+f)))*3;W*=W,s=W*W*Xe(Q,M,l,c)}let Y=.6-v*v-A*A-B*B;if(Y>=0){let Q=je(V+1+ge($+1+ge(j+1)))*3;Y*=Y,m=Y*Y*Xe(Q,v,A,B)}return 32*(a+i+s+m)}function Qe(e,t,o,a=[0,0]){let i=Ye(e,t+Fe,o),s=Ye(e,t-Fe,o),m=(i-s)/(2*Fe),x=Ye(e+Fe,t,o),b=Ye(e-Fe,t,o),C=(x-b)/(2*Fe);return a[0]=m,a[1]=-C,a}var nt,Rr,Bt,Ft,cn,un,Ar,fe,Fe,lt=S(()=>{"use strict";nt=new Float32Array([1,1,0,-1,1,0,1,-1,0,-1,-1,0,1,0,1,-1,0,1,1,0,-1,-1,0,-1,0,1,1,0,-1,1,0,1,-1,0,-1,-1]),Rr=[151,160,137,91,90,15,131,13,201,95,96,53,194,233,7,225,140,36,103,30,69,142,8,99,37,240,21,10,23,190,6,148,247,120,234,75,0,26,197,62,94,252,219,203,117,35,11,32,57,177,33,88,237,149,56,87,174,20,125,136,171,168,68,175,74,165,71,134,139,48,27,166,77,146,158,231,83,111,229,122,60,211,133,230,220,105,92,41,55,46,245,40,244,102,143,54,65,25,63,161,1,216,80,73,209,76,132,187,208,89,18,169,200,196,135,130,116,188,159,86,164,100,109,198,173,186,3,64,52,217,226,250,124,123,5,202,38,147,118,126,255,82,85,212,207,206,59,227,47,16,58,17,182,189,28,42,223,183,170,213,119,248,152,2,44,154,163,70,221,153,101,155,167,43,172,9,129,22,39,253,19,98,108,110,79,113,224,232,178,185,112,104,218,246,97,228,251,34,242,193,238,210,144,12,191,179,162,241,81,51,145,235,249,14,239,107,49,192,214,31,181,199,106,157,184,84,204,176,115,121,50,45,127,4,150,254,138,236,205,93,222,114,67,29,24,72,243,141,128,195,78,66,215,61,156,180],Bt=new Uint8Array(512),Ft=new Uint8Array(512);for(let e=0;e<512;e++){let t=Rr[e&255];Bt[e]=t,Ft[e]=t%12}cn=.5*(Math.sqrt(3)-1),un=(3-Math.sqrt(3))/6,Ar=1/3,fe=1/6;Fe=.001});var Ot={};K(Ot,{createFlowFieldKernel:()=>Ir});function Dt(e){return .5+.5*(.62*Math.sin(2*Math.PI*e/Er)+.38*Math.sin(2*Math.PI*e/Sr+1.3))}function kr(e,t,o){let a=Math.min(Math.max((e-t)/(o-t),0),1);return a*a*(3-2*a)}function Ir(){let e=null,t=0,o=0,a=1,i=null,s=!1,m=[],x={x:0,y:0,active:!1},b={y:0,vy:0,yMax:0},C=[7,8,15];function w(){let n=t*o;return Math.max(380,Math.min(1500,Math.round(n/1100)))}function T(n,f,p){n.x=Math.random()*t,n.y=Math.random()*o,n.px=n.x,n.py=n.y,n.px2=n.x,n.py2=n.y,n.life=120+Math.random()*260,n.age=f?p*.618034%1*n.life:0,n.accent=Math.floor(Math.random()*(i?.accents.length??4)),n.bright=.6+Math.random()*.4,n.seed=p*.754877%1,n.layer=p*.381966%1<.4?0:1}function h(){let n=w();m=new Array(n);for(let f=0;f<n;f++){let p={x:0,y:0,px:0,py:0,px2:0,py2:0,age:0,life:0,accent:0,bright:1,seed:0,layer:1};T(p,!0,f),m[f]=p}}function E(){e&&e.setTransform(a,0,0,a,0,0)}function I(n){e&&(e.fillStyle=J(C,n),e.fillRect(0,0,t,o))}function U(n){i=n,C=n.bg}function _(){if(!(!e||!i)){I(1);for(let n=0;n<30;n++)d(n*16,16,!1);d(3500,16,!0)}}let D=[0,0];function d(n,f,p){if(!e||!i)return;let k=Math.min(f,32)/16,P=Dt(n),M=.82+.3*P,l=.7+.6*P,c=n*Kt*l+b.y*Kt*ve.TIME_SCRUB,v=i.accents,A=i.ink,B=i.theme==="light",V=B?.9:1.4,$=B?.5:.42,j=i.intensity,X=b.vy,Z=Math.min(Math.abs(X)/120,1),W=p?Z:0,Y=b.y/ve.COLOR_SHIFT_PX+X*ve.ACCENT_ACCEL*.01,Q=v.length||1;for(let ee=0;ee<m.length;ee++){let R=m[ee];R.px2=R.px,R.py2=R.py,R.px=R.x,R.py=R.y;let we=R.layer?1.55:.7,xe=R.layer?c:c*.47+90;Qe(R.x*Gt*we,R.y*Gt*we,xe,D);let me=D[0],se=D[1];if(x.active){let u=R.x-x.x,y=R.y-x.y,L=u*u+y*y;if(L<Ee.R*Ee.R){let O=Math.sqrt(L)||1,H=Math.pow((Ee.R-O)/Ee.R,Ee.FALLOFF);me+=-y/O*H*Ee.STRENGTH,se+=u/O*H*Ee.STRENGTH}}let pe=1+Z*ve.SPEED_BOOST;if(X!==0){let u=Math.sign(X);se+=u*Math.min(Math.abs(X)/ve.GUST_K,ve.GUST),me+=u*Z*ve.SHEAR}if(R.x+=me*_t*pe*M*k,R.y+=se*_t*pe*M*k,R.age+=k*16,R.x<-4||R.x>t+4||R.y<-4||R.y>o+4||R.age>R.life){T(R,!1,ee);continue}if(p){let u=R.age/R.life,y=kr(u,0,.12)*(.4+.6*(.5+.5*Math.cos(Math.min(Math.max((u-.6)/.4,0),1)*Math.PI))),L=(u+R.seed)%1-.5,H=Math.exp(-(L*L)/.018)*V,ce=Math.min(H,1),te=(Math.trunc(R.accent+Y)%Q+Q)%Q,Te=v[te]??A,be=B?Re(Te,A,.25):Te;ce>.01&&(be=Re(be,B?A:Cr,(B?.4:.45)*ce));let tt=($+W*ve.ALPHA_BOOST)*y*R.bright*j*(R.layer?1:.7)*(1+H);e.lineWidth=(R.layer?1:1.3)*(1.15+W*ve.LINE_WIDTH),e.strokeStyle=J(be,Math.min(tt,1)),e.beginPath(),e.moveTo((R.px2+R.px)/2,(R.py2+R.py)/2),e.quadraticCurveTo(R.px,R.py,(R.px+R.x)/2,(R.py+R.y)/2),e.stroke()}}}return{id:"flow",label:"Flow Field",substrate:"2d",init(n,f){e=n,t=f.width,o=f.height,a=f.dpr,s=f.reducedMotion,U(f.palette),E(),e.lineCap="round",I(1),h(),s&&_()},frame(n,f){if(!e)return;let p=Dt(n),k=i?.theme==="light";I(k?.1-.02*p:.095-.03*p),d(n,f,!0)},resize(n){t=n.width,o=n.height,a=n.dpr,E(),e.lineCap="round",I(1),h(),s&&_()},setTheme(n,f){U(f),I(1)},pointer(n,f,p){x={x:n,y:f,active:p}},scroll(n,f,p){b={y:n,vy:f,yMax:p}},renderStatic(){_()},dispose(){e=null,m=[]}}}var Gt,Kt,_t,Er,Sr,Cr,Ee,ve,Nt=S(()=>{"use strict";lt();Be();Gt=.0016,Kt=6e-5,_t=1.35,Er=14e3,Sr=31e3;Cr=[248,250,255],Ee={R:280,STRENGTH:2.4,FALLOFF:1.4},ve={TIME_SCRUB:9,GUST:3.6,GUST_K:26,SPEED_BOOST:1.6,LINE_WIDTH:1.9,ALPHA_BOOST:.5,ACCENT_ACCEL:2.2,SHEAR:.9,COLOR_SHIFT_PX:220}});function Ue(e,t,o){let a=Ut(e,e.VERTEX_SHADER,Pr,`${o}:vert`),i=Ut(e,e.FRAGMENT_SHADER,t,`${o}:frag`);if(!a||!i)return a&&e.deleteShader(a),i&&e.deleteShader(i),null;let s=e.createProgram();return s?(e.attachShader(s,a),e.attachShader(s,i),e.linkProgram(s),e.deleteShader(a),e.deleteShader(i),e.getProgramParameter(s,e.LINK_STATUS)?s:(console.error(`[backdrop] ${o} link failed:
${e.getProgramInfoLog(s)}`),e.deleteProgram(s),null)):(e.deleteShader(a),e.deleteShader(i),null)}function Ut(e,t,o,a){let i=e.createShader(t);if(!i)return null;if(e.shaderSource(i,o),e.compileShader(i),!e.getShaderParameter(i,e.COMPILE_STATUS)){let s=e.getShaderInfoLog(i)??"unknown";return console.error(`[backdrop] ${a} shader compile failed:
${s}`),e.deleteShader(i),null}return i}var Pr,Se,at,st,qe=S(()=>{"use strict";Pr=`#version 300 es
void main(){
  // Fullscreen triangle from gl_VertexID \u2014 no attribute buffers needed.
  vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));
  gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}`,Se=`#version 300 es
precision highp float;
out vec4 fragColor;
uniform vec2  uResolution;
uniform float uTime;
uniform vec2  uPointer;        // 0..1, y up
uniform float uPointerActive;  // 0 or 1
uniform vec3  uBg;
uniform vec3  uAccent0;
uniform vec3  uAccent1;
uniform vec3  uAccent2;
uniform vec3  uAccent3;
uniform vec3  uInk;
uniform float uIntensity;
uniform float uTheme;          // 0 dark, 1 light
`,at=`
void main(){
  vec2 fragCoord = gl_FragCoord.xy;
  vec2 uv = fragCoord / uResolution;
  vec3 col = renderKernel(uv, fragCoord);
  col += dither(fragCoord);
  fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}`,st=["uResolution","uTime","uPointer","uPointerActive","uBg","uAccent0","uAccent1","uAccent2","uAccent3","uInk","uIntensity","uTheme"]});var Ge,Ke,_e,De,ct=S(()=>{"use strict";Ge=`
vec3 mod289(vec3 x){ return x - floor(x * (1.0/289.0)) * 289.0; }
vec4 mod289(vec4 x){ return x - floor(x * (1.0/289.0)) * 289.0; }
vec4 permute(vec4 x){ return mod289(((x*34.0)+1.0)*x); }
vec4 taylorInvSqrt(vec4 r){ return 1.79284291400159 - 0.85373472095314 * r; }
float snoise(vec3 v){
  const vec2 C = vec2(1.0/6.0, 1.0/3.0);
  const vec4 D = vec4(0.0, 0.5, 1.0, 2.0);
  vec3 i  = floor(v + dot(v, C.yyy));
  vec3 x0 = v - i + dot(i, C.xxx);
  vec3 g = step(x0.yzx, x0.xyz);
  vec3 l = 1.0 - g;
  vec3 i1 = min(g.xyz, l.zxy);
  vec3 i2 = max(g.xyz, l.zxy);
  vec3 x1 = x0 - i1 + C.xxx;
  vec3 x2 = x0 - i2 + C.yyy;
  vec3 x3 = x0 - D.yyy;
  i = mod289(i);
  vec4 p = permute(permute(permute(
            i.z + vec4(0.0, i1.z, i2.z, 1.0))
          + i.y + vec4(0.0, i1.y, i2.y, 1.0))
          + i.x + vec4(0.0, i1.x, i2.x, 1.0));
  float n_ = 0.142857142857;
  vec3 ns = n_ * D.wyz - D.xzx;
  vec4 j = p - 49.0 * floor(p * ns.z * ns.z);
  vec4 x_ = floor(j * ns.z);
  vec4 y_ = floor(j - 7.0 * x_);
  vec4 x = x_ *ns.x + ns.yyyy;
  vec4 y = y_ *ns.x + ns.yyyy;
  vec4 h = 1.0 - abs(x) - abs(y);
  vec4 b0 = vec4(x.xy, y.xy);
  vec4 b1 = vec4(x.zw, y.zw);
  vec4 s0 = floor(b0)*2.0 + 1.0;
  vec4 s1 = floor(b1)*2.0 + 1.0;
  vec4 sh = -step(h, vec4(0.0));
  vec4 a0 = b0.xzyw + s0.xzyw*sh.xxyy;
  vec4 a1 = b1.xzyw + s1.xzyw*sh.zzww;
  vec3 p0 = vec3(a0.xy, h.x);
  vec3 p1 = vec3(a0.zw, h.y);
  vec3 p2 = vec3(a1.xy, h.z);
  vec3 p3 = vec3(a1.zw, h.w);
  vec4 norm = taylorInvSqrt(vec4(dot(p0,p0), dot(p1,p1), dot(p2,p2), dot(p3,p3)));
  p0 *= norm.x; p1 *= norm.y; p2 *= norm.z; p3 *= norm.w;
  vec4 m = max(0.6 - vec4(dot(x0,x0), dot(x1,x1), dot(x2,x2), dot(x3,x3)), 0.0);
  m = m * m;
  return 42.0 * dot(m*m, vec4(dot(p0,x0), dot(p1,x1), dot(p2,x2), dot(p3,x3)));
}
`,Ke=`
float fbm(vec3 p){
  float a = 0.5, s = 0.0;
  for(int i = 0; i < 3; i++){
    s += a * snoise(p);
    p *= 2.0;
    a *= 0.5;
  }
  return s;
}
`,_e=`
float hash21(vec2 p){
  p = fract(p * vec2(123.34, 456.21));
  p += dot(p, p + 45.32);
  return fract(p.x * p.y);
}
// Triangular-PDF dither, ~\xB11 LSB at 8-bit.
vec3 dither(vec2 fragCoord){
  float r = hash21(fragCoord);
  float r2 = hash21(fragCoord + 17.0);
  return vec3((r + r2 - 1.0)) / 255.0;
}
`,De=`
vec3 accentRamp(float t){
  t = clamp(t, 0.0, 1.0) * 3.0;
  vec3 c01 = mix(uAccent0, uAccent1, smoothstep(0.0, 1.0, t));
  vec3 c12 = mix(uAccent1, uAccent2, smoothstep(1.0, 2.0, t));
  vec3 c23 = mix(uAccent2, uAccent3, smoothstep(2.0, 3.0, t));
  vec3 c = c01;
  c = mix(c, c12, step(1.0, t));
  c = mix(c, c23, step(2.0, t));
  return c;
}
`});function ut(e,t){return{uResolution:e.getUniformLocation(t,"uResolution"),uTime:e.getUniformLocation(t,"uTime"),uPointer:e.getUniformLocation(t,"uPointer"),uPointerActive:e.getUniformLocation(t,"uPointerActive"),uBg:e.getUniformLocation(t,"uBg"),uAccent0:e.getUniformLocation(t,"uAccent0"),uAccent1:e.getUniformLocation(t,"uAccent1"),uAccent2:e.getUniformLocation(t,"uAccent2"),uAccent3:e.getUniformLocation(t,"uAccent3"),uInk:e.getUniformLocation(t,"uInk"),uIntensity:e.getUniformLocation(t,"uIntensity"),uTheme:e.getUniformLocation(t,"uTheme"),uHasSim:e.getUniformLocation(t,"uHasSim"),uScroll:e.getUniformLocation(t,"uScroll"),uScrollVel:e.getUniformLocation(t,"uScrollVel"),uImpulses:e.getUniformLocation(t,"uImpulses"),uImpulseCount:e.getUniformLocation(t,"uImpulseCount"),uObstacleRects:e.getUniformLocation(t,"uObstacleRects"),uObstacleCount:e.getUniformLocation(t,"uObstacleCount"),uPrev:e.getUniformLocation(t,"uPrev"),uSim:e.getUniformLocation(t,"uSim"),uSimResolution:e.getUniformLocation(t,"uSimResolution"),uGlyphField:e.getUniformLocation(t,"uGlyphField"),uGlyphActive:e.getUniformLocation(t,"uGlyphActive"),uGlyphRect:e.getUniformLocation(t,"uGlyphRect"),uGlyphPhase:e.getUniformLocation(t,"uGlyphPhase")}}var de,qt,bn,ft=S(()=>{"use strict";qe();de={hasSim:`uniform float uHasSim;
`,scroll:`uniform vec2  uScroll;
uniform float uScrollVel;
`,impulses:`uniform vec4  uImpulses[8];
uniform int   uImpulseCount;
`,obstacles:`uniform vec4  uObstacleRects[24];
uniform int   uObstacleCount;
`,glyph:`uniform sampler2D uGlyphField;
uniform float uGlyphActive;
uniform vec4  uGlyphRect;
uniform float uGlyphPhase;
`},qt=de.hasSim+de.scroll+de.impulses+de.obstacles,bn=[...st,"uHasSim","uScroll","uScrollVel","uImpulses","uImpulseCount","uObstacleRects","uObstacleCount","uPrev","uSim","uSimResolution","uGlyphField","uGlyphActive","uGlyphRect","uGlyphPhase"]});function zt(e){return`
void main(){
  vec2 uv = gl_FragCoord.xy / uSimResolution;
  fragColor = ${e}(uv);
}`}function Wt(e,t,o,a,i,s){e.getExtension("EXT_color_buffer_float");let m=Tt(e,t.format,o),x=m.filterable?e.LINEAR:e.NEAREST,b=Ue(e,`${Lr}
${Ge}
${Ke}
${_e}
${De}
${t.step}
${zt("simStep")}`,`${s}:sim`),C=Ue(e,`${Mr}
${Ge}
${Ke}
${_e}
${De}
${t.seed}
${zt("simSeed")}`,`${s}:seed`),w=0,T=0,h=null,E=null,I=null,U=null,_=!1,D=null,d=null,n=null;b&&(D=e.getUniformLocation(b,"uPrev"),d=e.getUniformLocation(b,"uSimResolution")),C&&(n=e.getUniformLocation(C,"uSimResolution"));function f(l,c){w=Math.max(Ht,Math.round(l*t.scale)),T=Math.max(Ht,Math.round(c*t.scale))}function p(){let l=e.createTexture(),c=e.createFramebuffer();return!l||!c?(l&&e.deleteTexture(l),c&&e.deleteFramebuffer(c),null):(e.bindTexture(e.TEXTURE_2D,l),e.texImage2D(e.TEXTURE_2D,0,m.internalFormat,w,T,0,m.format,m.type,null),e.texParameteri(e.TEXTURE_2D,e.TEXTURE_MIN_FILTER,x),e.texParameteri(e.TEXTURE_2D,e.TEXTURE_MAG_FILTER,x),e.texParameteri(e.TEXTURE_2D,e.TEXTURE_WRAP_S,e.CLAMP_TO_EDGE),e.texParameteri(e.TEXTURE_2D,e.TEXTURE_WRAP_T,e.CLAMP_TO_EDGE),e.bindFramebuffer(e.FRAMEBUFFER,c),e.framebufferTexture2D(e.FRAMEBUFFER,e.COLOR_ATTACHMENT0,e.TEXTURE_2D,l,0),{tex:l,fbo:c})}function k(l){return l?(e.bindFramebuffer(e.FRAMEBUFFER,l.fbo),e.checkFramebufferStatus(e.FRAMEBUFFER)===e.FRAMEBUFFER_COMPLETE):!1}function P(){for(let l of[h,E])l&&(e.deleteTexture(l.tex),e.deleteFramebuffer(l.fbo));h=E=I=U=null}function M(){P(),h=p(),E=p(),_=m.renderable&&!!h&&!!E&&!!b&&!!C&&k(h)&&k(E),e.bindFramebuffer(e.FRAMEBUFFER,null),I=h,U=E,_||console.error(`[backdrop] ${s} sim target/program incomplete; display-only.`)}return f(a,i),M(),{get ok(){return _},get simW(){return w},get simH(){return T},get stepProgram(){return b},get seedProgram(){return C},current(){return _&&I?I.tex:null},resize(l,c){_&&(f(l,c),M())},reseed(l,c){if(!(!_||!C)){e.useProgram(C),c(C),e.bindVertexArray(l),n&&e.uniform2f(n,w,T),e.viewport(0,0,w,T);for(let v of[h,E])v&&(e.bindFramebuffer(e.FRAMEBUFFER,v.fbo),e.drawArrays(e.TRIANGLES,0,3));I=h,U=E,e.bindFramebuffer(e.FRAMEBUFFER,null)}},step(l,c){if(!_||!b)return;let v=Math.min(Math.max(t.stepsPerFrame|0,1),dt);e.useProgram(b),c(b),e.bindVertexArray(l),d&&e.uniform2f(d,w,T),e.viewport(0,0,w,T);for(let A=0;A<v&&!(!I||!U);A++){e.bindFramebuffer(e.FRAMEBUFFER,U.fbo),e.activeTexture(e.TEXTURE0),e.bindTexture(e.TEXTURE_2D,I.tex),D&&e.uniform1i(D,0),e.drawArrays(e.TRIANGLES,0,3);let B=I;I=U,U=B}e.bindFramebuffer(e.FRAMEBUFFER,null)},settle(l,c,v){if(!_||l<=0)return;let A=Math.ceil(l/dt);for(let B=0;B<A;B++)this.step(c,v)},dispose(){P(),b&&e.deleteProgram(b),C&&e.deleteProgram(C)}}}var dt,Ht,Lr,Mr,mt=S(()=>{"use strict";qe();We();ct();ft();dt=8,Ht=2,Lr=`${Se}${qt}
uniform sampler2D uPrev;
uniform vec2  uSimResolution;
`,Mr=`${Se}
uniform vec2  uSimResolution;
`});function g(e){let t=null,o=null,a=null,i=null,s=null,m=[.5,.5],x=[.5,.5],b=0,C=!1,w=null,T=!!(e.sim||e.textures||e.controls),h=null,E=null,I=[],U=ot,_=0,D=new Map,d=e.controls?.includes("scroll")??!1,n=e.controls?.includes("impulses")??!1,f=e.controls?.includes("obstacles")??!1,p=e.controls?.includes("glyph")??!1,k={y:0,yMax:0,vy:0},P=new Float32Array(pt*4),M=0,l=new Float32Array(Vt*4),c=0,v=null,A=null,B=!1,V=[.5,.5,.5,.5],$=1,j=r=>{r.preventDefault(),C=!0},X=()=>{C=!1,t&&(D.clear(),W(t),me(),xe(),T&&(R(t),we(t)),p&&(A=null,B=!!v))};function Z(r){!p||!v||(A||(A=r.createTexture()),A&&(r.bindTexture(r.TEXTURE_2D,A),r.texImage2D(r.TEXTURE_2D,0,r.RGBA,v.size,v.size,0,r.RGBA,r.UNSIGNED_BYTE,v.data),r.texParameteri(r.TEXTURE_2D,r.TEXTURE_WRAP_S,r.CLAMP_TO_EDGE),r.texParameteri(r.TEXTURE_2D,r.TEXTURE_WRAP_T,r.CLAMP_TO_EDGE),r.texParameteri(r.TEXTURE_2D,r.TEXTURE_MIN_FILTER,r.LINEAR),r.texParameteri(r.TEXTURE_2D,r.TEXTURE_MAG_FILTER,r.LINEAR),B=!1))}function W(r){let u=Se;e.sim&&(u+=de.hasSim),d&&(u+=de.scroll),n&&(u+=de.impulses),f&&(u+=de.obstacles),p&&(u+=de.glyph);let y=e.sim?`uniform sampler2D uSim;
uniform vec2 uSimResolution;
`:"",L=(e.textures??[]).map(H=>`uniform sampler2D ${H.name};`).join(`
`),O=T?`${u}${y}${L}
${Ge}
${Ke}
${_e}
${De}
${e.body}
${at}`:`${Se}
${Ge}
${Ke}
${_e}
${De}
${e.body}
${at}`;o=Ue(r,O,e.id),o&&(T?E=ut(r,o):i={uResolution:r.getUniformLocation(o,"uResolution"),uTime:r.getUniformLocation(o,"uTime"),uPointer:r.getUniformLocation(o,"uPointer"),uPointerActive:r.getUniformLocation(o,"uPointerActive"),uBg:r.getUniformLocation(o,"uBg"),uAccent0:r.getUniformLocation(o,"uAccent0"),uAccent1:r.getUniformLocation(o,"uAccent1"),uAccent2:r.getUniformLocation(o,"uAccent2"),uAccent3:r.getUniformLocation(o,"uAccent3"),uInk:r.getUniformLocation(o,"uInk"),uIntensity:r.getUniformLocation(o,"uIntensity"),uTheme:r.getUniformLocation(o,"uTheme")},a=r.createVertexArray())}function Y(r){!t||!s||(t.uniform2f(r.uResolution,t.drawingBufferWidth,t.drawingBufferHeight),t.uniform1f(r.uTime,_),t.uniform2f(r.uPointer,m[0],m[1]),t.uniform1f(r.uPointerActive,b),t.uniform3fv(r.uBg,ie(s.bg)),t.uniform3fv(r.uAccent0,ie(s.accents[0]??s.ink)),t.uniform3fv(r.uAccent1,ie(s.accents[1]??s.ink)),t.uniform3fv(r.uAccent2,ie(s.accents[2]??s.ink)),t.uniform3fv(r.uAccent3,ie(s.accents[3]??s.ink)),t.uniform3fv(r.uInk,ie(s.ink)),t.uniform1f(r.uIntensity,s.intensity),t.uniform1f(r.uTheme,s.theme==="light"?1:0))}function Q(r,u){t&&(t.uniform1f(r.uHasSim,u),d&&(t.uniform2f(r.uScroll,k.y,k.yMax),t.uniform1f(r.uScrollVel,k.vy)),n&&(t.uniform4fv(r.uImpulses,P),t.uniform1i(r.uImpulseCount,M)),f&&(t.uniform4fv(r.uObstacleRects,l),t.uniform1i(r.uObstacleCount,c)),p&&(t.uniform1f(r.uGlyphActive,v?1:0),t.uniform4f(r.uGlyphRect,V[0],V[1],V[2],V[3]),t.uniform1f(r.uGlyphPhase,$)))}function ee(r){let u=D.get(r);return!u&&t&&(u=ut(t,r),D.set(r,u)),u??{}}function R(r){if(!e.sim||!a)return;let u=Fr(e.sim);h=Wt(r,u,U,r.drawingBufferWidth,r.drawingBufferHeight,e.id),h.stepProgram&&ee(h.stepProgram),h.seedProgram&&ee(h.seedProgram);let y=H=>Y(ee(H)),L=H=>{let ce=ee(H);Y(ce),Q(ce,1)};h.reseed(a,y);let O=e.sim.settleSteps??0;O>0&&h.settle(O,a,L)}function we(r){if(!(!e.textures||!o||!E)){I.length=0;for(let u of e.textures){let y=r.createTexture();r.bindTexture(r.TEXTURE_2D,y),r.texImage2D(r.TEXTURE_2D,0,r.RGBA,1,1,0,r.RGBA,r.UNSIGNED_BYTE,new Uint8Array([0,0,0,255]));let L=u.wrap==="clamp"?r.CLAMP_TO_EDGE:r.REPEAT,O=u.filter==="nearest"?r.NEAREST:r.LINEAR;r.texParameteri(r.TEXTURE_2D,r.TEXTURE_WRAP_S,L),r.texParameteri(r.TEXTURE_2D,r.TEXTURE_WRAP_T,L),r.texParameteri(r.TEXTURE_2D,r.TEXTURE_MIN_FILTER,O),r.texParameteri(r.TEXTURE_2D,r.TEXTURE_MAG_FILTER,O);let H=new Image;H.onload=()=>{!t||!y||(t.bindTexture(t.TEXTURE_2D,y),t.texImage2D(t.TEXTURE_2D,0,t.RGBA,t.RGBA,t.UNSIGNED_BYTE,H))},H.src=u.dataUri,I.push({name:u.name,tex:y,loc:r.getUniformLocation(o,u.name)})}}}function xe(){if(!(!t||!o))if(T&&E)t.useProgram(o),Y(E);else{if(!s)return;t.useProgram(o),t.uniform3fv(i.uBg,ie(s.bg)),t.uniform3fv(i.uAccent0,ie(s.accents[0]??s.ink)),t.uniform3fv(i.uAccent1,ie(s.accents[1]??s.ink)),t.uniform3fv(i.uAccent2,ie(s.accents[2]??s.ink)),t.uniform3fv(i.uAccent3,ie(s.accents[3]??s.ink)),t.uniform3fv(i.uInk,ie(s.ink)),t.uniform1f(i.uIntensity,s.intensity),t.uniform1f(i.uTheme,s.theme==="light"?1:0)}}function me(){t&&t.viewport(0,0,t.drawingBufferWidth,t.drawingBufferHeight)}function se(r,u){let y=t.drawingBufferHeight,L=y/(w?.clientHeight||y);return[r*L/t.drawingBufferWidth,1-u*L/y]}function pe(){let r=0;for(let u=0;u<M;u++){let y=P[u*4+3]+1;if(y<Br){let L=u*4,O=r*4;P[O]=P[L],P[O+1]=P[L+1],P[O+2]=P[L+2],P[O+3]=y,r++}}M=r}return{id:e.id,label:e.label,substrate:"webgl2",init(r,u){t=r,s=u.palette,U=u.caps??ot,w=t.canvas,w.addEventListener("webglcontextlost",j,!1),w.addEventListener("webglcontextrestored",X,!1),W(t),me(),xe(),T&&(R(t),we(t))},frame(r){if(!t||!o||C)return;if(_=r/1e3,m[0]+=(x[0]-m[0])*.08,m[1]+=(x[1]-m[1])*.08,!T||!E){t.useProgram(o),t.bindVertexArray(a),t.uniform2f(i.uResolution,t.drawingBufferWidth,t.drawingBufferHeight),t.uniform1f(i.uTime,_),t.uniform2f(i.uPointer,m[0],m[1]),t.uniform1f(i.uPointerActive,b),t.drawArrays(t.TRIANGLES,0,3),t.bindVertexArray(null);return}h?.ok&&h.step(a,L=>{let O=ee(L);Y(O),Q(O,1)}),pe(),t.bindFramebuffer(t.FRAMEBUFFER,null),t.viewport(0,0,t.drawingBufferWidth,t.drawingBufferHeight),t.useProgram(o),t.bindVertexArray(a),Y(E);let u=h?.ok?1:0;Q(E,u);let y=0;if(u&&h){let L=h.current();L&&(t.activeTexture(t.TEXTURE0+y),t.bindTexture(t.TEXTURE_2D,L),t.uniform1i(E.uSim,y),t.uniform2f(E.uSimResolution,h.simW,h.simH),y++)}for(let L of I)L.tex&&(t.activeTexture(t.TEXTURE0+y),t.bindTexture(t.TEXTURE_2D,L.tex),L.loc&&t.uniform1i(L.loc,y),y++);p&&(B&&Z(t),A&&(t.activeTexture(t.TEXTURE0+y),t.bindTexture(t.TEXTURE_2D,A),t.uniform1i(E.uGlyphField,y),y++)),t.drawArrays(t.TRIANGLES,0,3),t.bindVertexArray(null)},resize(){if(me(),T&&h&&(h.resize(t.drawingBufferWidth,t.drawingBufferHeight),a)){let r=y=>Y(ee(y));h.reseed(a,r);let u=e.sim?.settleSteps??0;u>0&&h.settle(u,a,r)}},setTheme(r,u){s=u,xe()},pointer(r,u,y){t&&(x=se(r,u),b=y?1:0)},click(r,u){if(!t||!n)return;let[y,L]=se(r,u),O;M<pt?O=M++:(P.copyWithin(0,4),O=pt-1);let H=O*4;P[H]=y,P[H+1]=L,P[H+2]=1,P[H+3]=0},obstacles(r){if(!(!t||!f)){c=Math.min(r.length,Vt);for(let u=0;u<c;u++){let y=r[u],[L,O]=se(y.x,y.y),[H,ce]=se(y.x+y.w,y.y+y.h),te=u*4;l[te]=L,l[te+1]=ce,l[te+2]=H,l[te+3]=O}}},scroll(r,u,y){d&&(k.y=r,k.vy=u,k.yMax=y)},setGlyphField(r){if(p)if(v=r,r){let u=r.content.x+r.content.w*.5,y=r.content.y+r.content.h*.5;V[0]=u,V[1]=1-y,V[2]=r.content.w*.5,V[3]=r.content.h*.5,$=1,B=!0}else B=!1,t&&A&&(t.deleteTexture(A),A=null)},renderStatic(){if(!T){this.frame(0,0);return}if(h?.ok&&a){let r=u=>{let y=ee(u);Y(y),Q(y,1)};h.reseed(a,u=>Y(ee(u))),h.settle(e.sim?.settleSteps??0,a,r)}this.frame(0,0)},dispose(){if(w&&(w.removeEventListener("webglcontextlost",j),w.removeEventListener("webglcontextrestored",X)),t){if(T){h?.dispose(),h=null;for(let r of I)r.tex&&t.deleteTexture(r.tex);I.length=0,D.clear()}A&&(t.deleteTexture(A),A=null),o&&t.deleteProgram(o),a&&t.deleteVertexArray(a),t.getExtension("WEBGL_lose_context")?.loseContext()}t=null,o=null,a=null,i=null,E=null,s=null,w=null,v=null}}}function Fr(e){return{step:e.step,seed:e.seed,format:e.format??"RGBA16F",scale:e.scale??.5,stepsPerFrame:e.stepsPerFrame??1}}var pt,Vt,Br,N=S(()=>{"use strict";Be();qe();mt();We();ct();ft();qe();mt();pt=8,Vt=24,Br=3});var jt={};K(jt,{createAuroraKernel:()=>Kr});function Kr(){return g({id:"aurora",label:"Aurora",body:Gr})}var Gr,Xt=S(()=>{"use strict";N();Gr=`
vec3 renderKernel(vec2 uv, vec2 fragCoord){
  vec2 p = (fragCoord - 0.5 * uResolution) / uResolution.y;

  // STEP 1 \u2014 CLOCKS. Multi-clock decomposition so the rhythm never visibly loops.
  float tBase  = uTime * 0.045;                                  // master (hypnotic)
  float tDrift = uTime * 0.018;                                  // horizontal sweep + hue roll
  float breath = smoothstep(0.15, 0.85, 0.5 + 0.5 * sin(uTime * 0.224)); // ~28s eased inhale (brightness only)
  float tCalm  = 0.5 + 0.5 * sin(uTime * 0.11);                  // coprime-ish hush: gates lit layers

  // STEP 2 \u2014 SHARED WARP, COMPUTED ONCE (the perf spine: 5 fbm = 20 snoise, same as before).
  // Inigo-Quilez double domain warp; keep q/r as vectors and derive a single advection flow.
  vec2 q = vec2(
    fbm(vec3(p * 1.4, tBase)),
    fbm(vec3(p * 1.4 + 5.2, tBase)));
  vec2 r = vec2(
    fbm(vec3(p * 1.4 + 1.2 * q + vec2(1.7, 9.2), tBase * 1.15)),
    fbm(vec3(p * 1.4 + 1.2 * q + vec2(8.3, 2.8), tBase * 1.15)));
  float fWarp = fbm(vec3(p * 1.4 + 1.6 * r, tBase * 0.9));
  vec2 flow = 1.6 * r + 0.7 * q;                                 // magnetic advection every curtain rides

  // STEP 3 \u2014 THREE CURTAINS (pure trig inside, ZERO extra fbm). Accumulate emission + luminance.
  vec3 acc = vec3(0.0);
  float totalLum = 0.0;
  for (int i = 0; i < 3; i++) {
    float di = float(i);
    float depth = 1.0 - 0.33 * di;                              // parallax magnitude on flow
    float lt = tBase * (1.0 + 0.25 * di) + di * 2.39989;        // golden-angle offset: never phase-locks
    vec2 lp = p * (1.0 - 0.16 * di);                            // near layers slightly zoomed
    lp.x += tDrift * (1.0 + 0.25 * di) * 1.6;                   // horizontal drift, nearer faster
    float x = lp.x * 3.2 + flow.x * (1.2 * depth) + lt;         // advected horizontal phase
    float hgt = lp.y * 1.4 + fWarp * 0.9 + flow.y * 0.5;        // warped vertical (altitude) coordinate

    // Fractal vertical filaments \u2014 3 octaves of cheap abs(sin()), no noise.
    float fil = 0.0, amp = 1.0, fq = 1.0;
    for (int k = 0; k < 3; k++) {
      fil += amp * abs(sin(x * fq + hgt * 1.3));
      fq *= 2.3;
      amp *= 0.5;
    }
    fil *= 0.571;                                               // normalize ~ /1.75
    float edge = smoothstep(0.0, 1.0, fil);
    float core = 1.0 - edge;
    core = core * core * (3.0 - 2.0 * core);                    // smootherstep: soft bloom -> snap bright
    float glow = core * core;

    // Curtain hem envelope (fades top/bottom) \u2014 also the legibility guard.
    float env = smoothstep(-1.1, -0.2, lp.y) * smoothstep(1.3, 0.1, lp.y);

    // ALTITUDE-KEYED HUE: bottom cyan/iris, top violet/rose, with slow thin-film iridescence.
    float irid = 0.12 * sin(hgt * 6.2831 + length(r) * 4.0 + tBase * 0.5);
    float hue = clamp(0.5 + hgt * 0.5 + 0.12 * fWarp + irid + di * 0.05, 0.0, 1.0);
    vec3 accent = accentRamp(hue);

    // Hush gate: far layers fade during the calm so the field truly rests sometimes.
    float layerGate = smoothstep(0.0, 1.0, tCalm * 1.4 - di * 0.35);
    float lum = glow * env * layerGate;
    acc += accent * lum * (0.62 / (1.0 + 0.5 * di));            // far layers dimmer
    acc += vec3(0.7, 0.85, 1.0) * pow(glow, 4.0) * env * 0.18 * (1.0 - 0.3 * di); // whiter-than-accent hot cores
    totalLum += lum;
  }

  // STEP 4 \u2014 SIGNATURE PILLAR. A sparse traveling shaft, gated by per-cell noise so only 1-2 glow.
  float pCell = floor(p.x * 0.6 + tDrift * 1.3);
  float pPhase = fract(p.x * 0.6 + tDrift * 1.3);
  float pillar = exp(-pow((pPhase - 0.5) * 7.0, 2.0));
  float pillarGate = smoothstep(0.55, 0.95, snoise(vec3(pCell * 3.1, 0.0, tDrift * 0.5)) * 0.5 + 0.5);
  float rise = 0.5 + 0.5 * sin(uv.y * 3.14159 - uTime * 1.1);   // light visibly shoots upward
  vec3 pillarHue = accentRamp(clamp(0.35 + uv.y * 0.5, 0.0, 1.0));
  acc += pillarHue * pillar * pillarGate * rise * 0.7 * breath;

  // STEP 5 \u2014 BREATH TO BRIGHTNESS ONLY (never position).
  acc *= mix(0.86, 1.18, breath);

  // STEP 6 \u2014 THEME COMPOSITE (timing identical; only the math flips).
  vec3 col;
  if (uTheme < 0.5) {
    // DARK: additive over deep ink, then a filmic knee blooms stacked cores toward white.
    col = uBg;
    col += acc * (0.95 * uIntensity);
    col = col / (col + vec3(0.55));
    col *= 1.18;                                                // TONEMAP_KNEE \u2014 overexposed-aurora bloom
    // Airglow grain floor (dark only): quietness in the void instead of dead black.
    col += vec3(0.8, 0.85, 1.0) * (hash21(fragCoord) - 0.5) * 0.015 * (1.0 - clamp(totalLum * 2.0, 0.0, 1.0));
  } else {
    // LIGHT: visible pearl aurora. The old watermark math was too polite and
    // collapsed to near-white on the lab pages; keep it soft, but make the
    // ribbons read as real cyan/violet/rose curtains.
    col = uBg;
    float v = pow(clamp(dot(acc, vec3(0.45)) * 1.65, 0.0, 1.0), 0.72);
    vec3 ribbon = accentRamp(clamp(0.40 + 0.36 * v + 0.08 * fWarp, 0.0, 1.0));
    vec3 pearl = mix(uBg, ribbon, 0.88);
    col = mix(col, pearl, v * 0.62 * uIntensity);
    // A tiny ink component gives the soft curtains a contour on pearl without
    // turning them into muddy gray blobs.
    col = mix(col, uInk, smoothstep(0.10, 0.58, v) * 0.045 * uIntensity);
    col = mix(col, ribbon, pow(v, 2.4) * 0.18 * uIntensity);
  }

  // STEP 7 \u2014 POINTER (keep the halo; multiply by breath for liveliness, hue slowly cycles).
  if (uPointerActive > 0.5) {
    vec2 pp = (uPointer * uResolution - 0.5 * uResolution) / uResolution.y;
    float dd = length(p - pp);
    float halo = exp(-dd * dd * 3.5);
    col += accentRamp(fract(0.55 + uTime * 0.1)) * halo * 0.25 * breath * (uTheme < 0.5 ? 1.0 : 0.5);
  }

  // STEP 8 \u2014 VIGNETTE (tightened to protect glass-type legibility).
  float vig = smoothstep(1.5, 0.15, length(p));
  col = mix(uBg, col, 0.35 + 0.65 * vig);
  return col;
}
`});var Yt={};K(Yt,{createMeshKernel:()=>Dr});function Dr(){return g({id:"mesh",label:"Iridescent Mesh",body:_r})}var _r,Qt=S(()=>{"use strict";N();_r=`
vec3 renderKernel(vec2 uv, vec2 fragCoord){
  vec2 p = (fragCoord - 0.5 * uResolution) / uResolution.y;
  float t = uTime * 0.07;

  // STEP 0 \u2014 Breath conductor. One eased ~60s clock drives every layer so the
  // surface reads as a single organism; a delayed clock trails the color so the
  // light-breath swells ~5.7s after the color does.
  float bt = uTime * 0.105;
  float breath = 0.5 + 0.5 * sin(bt);
  breath = breath * breath * (3.0 - 2.0 * breath);  // eased dwell at extremes
  float sheen = 0.5 + 0.5 * sin(bt - 0.6);           // delayed light clock

  // STEP 1 \u2014 Domain warp the field ONCE (the "one body" move). Every later field
  // sample reads pw so the four blobs flow as one liquid.
  vec2 warp = 0.30 * vec2(fbm(vec3(p * 0.9, t)), fbm(vec3(p * 0.9 + 4.7, t)));
  vec2 pw = p + warp;

  // STEP 2 \u2014 Breathing, eased anchors (keep all 4, keep palette identity).
  // Per-anchor phase-warped clock for ease-in-out orbits; radius swells on inhale.
  float tw0 = t + 0.18 * sin(t * 0.37 + 0.0);
  float tw1 = t + 0.18 * sin(t * 0.37 + 1.7);
  float tw2 = t + 0.18 * sin(t * 0.37 + 3.4);
  float tw3 = t + 0.18 * sin(t * 0.37 + 5.1);
  float swell = 0.92 + 0.12 * breath;
  vec2 a0 = (0.62 * swell) * vec2(sin(tw0 * 0.7),       cos(tw0 * 0.5));
  vec2 a1 = (0.72 * swell) * vec2(sin(tw1 * 0.4 + 2.0), cos(tw1 * 0.6 + 1.0));
  vec2 a2 = (0.66 * swell) * vec2(cos(tw2 * 0.5 + 4.0), sin(tw2 * 0.45 + 3.0));
  vec2 a3 = (0.56 * swell) * vec2(cos(tw3 * 0.6 + 1.5), sin(tw3 * 0.7 + 5.0));

  // Inverse-square weights evaluated at domain-warped pw \u2192 flowing filaments.
  float w0 = 1.0 / (0.16 + dot(pw - a0, pw - a0));
  float w1 = 1.0 / (0.16 + dot(pw - a1, pw - a1));
  float w2 = 1.0 / (0.16 + dot(pw - a2, pw - a2));
  float w3 = 1.0 / (0.16 + dot(pw - a3, pw - a3));
  float wsum = w0 + w1 + w2 + w3;
  vec3 mesh = (w0 * uAccent0 + w1 * uAccent1 + w2 * uAccent2 + w3 * uAccent3) / wsum;

  // STEP 3 \u2014 Height/thickness field for normals + interference.
  float h = fbm(vec3(pw * 1.6, t * 0.5));
  float filmThk = h * 0.7 + 0.15 * length(pw);  // radial meniscus bias

  // STEP 4 \u2014 Thin-film iridescence: palette-routed, breath-coupled, dispersion
  // fringed. A single film gradient via core dFdx/dFdy is reused for dispersion
  // (here) and the Fresnel rim (STEP 7).
  vec2 n2 = vec2(dFdx(filmThk), dFdy(filmThk));
  float disp = 0.012 * (0.6 + 0.4 * uIntensity);
  float phase = filmThk * 1.5 + t * 0.15;
  vec3 iri = vec3(
    accentRamp(fract(phase + dot(n2, vec2(disp)))).r,
    accentRamp(fract(phase)).g,
    accentRamp(fract(phase - dot(n2, vec2(disp)))).b
  );
  mesh = mix(mesh, iri, 0.14 + 0.06 * breath);

  // STEP 5 \u2014 Parallax depth band (gives the slab thickness): \xB14% luminance.
  float depth = fbm(vec3(pw * 0.7, t * 0.25));
  mesh *= mix(0.96, 1.04, depth * 0.5 + 0.5);

  // STEP 6 \u2014 Dual-clock ridged caustic isolated to ONE traveling seam (restraint).
  vec2 fa = vec2(cos(t * 0.20), sin(t * 0.20)) * 0.30;
  vec2 fb = vec2(cos(-t * 0.137), sin(-t * 0.137)) * 0.24;
  float c1 = fbm(vec3(pw * 2.2 + fa, t * 0.06));
  float c2 = fbm(vec3(pw * 3.5 - fb, t * 0.041));
  float caustic = c1 * c2;
  caustic = 1.0 - abs(2.0 * caustic - 1.0);  // thin ridge
  caustic = pow(caustic, 3.0);                // thin filaments
  // Gate to a single traveling iso-contour of the height field \u2192 one seam.
  float band = abs(h - 0.5) * 2.0;
  float seam = smoothstep(0.55, 0.70, band) * smoothstep(0.86, 0.70, band);
  caustic *= seam;

  // STEP 7 \u2014 Fresnel oil-sheen rim along folds (reuses the film gradient).
  float slope = length(n2);
  float rim = pow(clamp(slope * 3.0, 0.0, 1.0), 1.5);

  // STEP 8 \u2014 Theme composite. Base mesh UNCHANGED from the shipping kernel so the
  // legibility floor is preserved; all new light is ADDED on top and breath-gated.
  vec3 col;
  if (uTheme < 0.5) {
    col = mix(uBg, mesh, 0.24 + 0.5 * uIntensity);
  } else {
    col = mix(uBg, mesh, 0.30 * uIntensity);  // soft pastel over pearl
  }
  float causticGain = (0.10 + 0.16 * uIntensity)
    * (0.35 + 0.65 * sheen)
    * (uTheme < 0.5 ? 1.0 : 0.5);
  col += accentRamp(0.7 + 0.15 * breath) * caustic * causticGain;
  col += iri * rim * (uTheme < 0.5 ? 0.12 : 0.06);

  // STEP 9 \u2014 Eased pointer bloom (smoothed upstream in createShaderKernel); the
  // bloom radius widens slightly on inhale.
  if (uPointerActive > 0.5) {
    vec2 pp = (uPointer * uResolution - 0.5 * uResolution) / uResolution.y;
    float d = length(p - pp);
    col = mix(col, accentRamp(0.4 + 0.2 * breath), smoothstep(0.35, 0.0, d) * 0.18 * uIntensity);
  }

  // STEP 10 \u2014 Breathing grain: grittier on exhale, silkier at peak inhale.
  // dither() is still applied by MAIN on top of this.
  float g = hash21(fragCoord + fract(uTime) * vec2(13.0, 7.0));
  col += (g - 0.5) * (0.016 + 0.010 * (1.0 - breath));
  return col;
}
`});var Je,Oe,Ze,ht=S(()=>{"use strict";Je=Math.PI*(3-Math.sqrt(5)),Oe=7,Ze=9});var Jt={};K(Jt,{createMoireKernel:()=>Nr});function Nr(){return g({id:"moire",label:"Moir\xE9",body:Or})}var Or,Zt=S(()=>{"use strict";N();ht();Or=`
// \u2500\u2500 moir\xE9 quasicrystal \u2014 tuning constants (mirror quasicrystalWaves.ts) \u2500\u2500\u2500\u2500
const int   QC_WAVES_C   = ${Oe};
const float QC_GOLDEN_C  = ${Je.toFixed(10)};
const float QC_FREQ_C    = ${Ze.toFixed(1)};
const float QC_SPIN      = 0.012;     // basis-rotation clock (authentic QC anim)
const float QC_SCRUB     = 0.05;      // global phase-drift clock
const float QC_LENS_TIGHT = 9.0;      // pointer-lens gaussian tightness
const float QC_LENS_STR   = 0.18;     // pointer-lens warp strength
const float QC_PI         = 3.14159265;

// IQ analytic band-limited cosine: deactivates a wave before it aliases.
// w = per-pixel domain footprint of x; cos\xB7sinc(w/2), sinc\u2248(1\u2212smoothstep(0,2\u03C0,w)).
// NOTE: explicit 1\u2212smoothstep(0,2\u03C0,w) \u2014 never smoothstep(2\u03C0,0,w): reversed edges
// (edge0>edge1) are undefined in the GLSL ES spec.
float fcos(float x){
  float w = fwidth(x);
  return cos(x) * (1.0 - smoothstep(0.0, 6.28318531, w));
}

vec3 renderKernel(vec2 uv, vec2 fragCoord){
  vec2 p = (fragCoord - 0.5 * uResolution) / uResolution.y;

  // STEP 1 \u2014 CLOCKS (irrational ratios so nothing visibly loops).
  float breath = 0.5 + 0.5 * (0.62 * sin(6.28318531 * uTime / 14.0)
                            + 0.38 * sin(6.28318531 * uTime / 31.0 + 1.3));
  float spin  = uTime * QC_SPIN;
  float scrub = uTime * QC_SCRUB;
  float freq  = QC_FREQ_C * (0.9 + 0.2 * breath);

  // STEP 2 \u2014 POINTER LENS (domain warp). fwidth() on the FINAL phase tracks this
  // warp's frequency change automatically \u2014 the reason analytic AA survives warps.
  vec2 pw = p;
  if (uPointerActive > 0.5){
    vec2 pp = (uPointer * uResolution - 0.5 * uResolution) / uResolution.y;
    vec2 d  = p - pp;
    float r2 = dot(d, d);
    float g  = exp(-r2 * QC_LENS_TIGHT);              // ripple bubble at cursor
    pw += normalize(d + 1e-4) * g * QC_LENS_STR;
  }

  // STEP 3 \u2014 N-WAVE QUASICRYSTAL SUM, each wave band-limited.
  float q = 0.0;
  for (int j = 0; j < QC_WAVES_C; j++){
    float a  = QC_PI * float(j) / float(QC_WAVES_C) + spin;  // even angle, rotated
    vec2  k  = vec2(cos(a), sin(a)) * freq;                  // |k| = freq
    float ph = float(j) * QC_GOLDEN_C;                        // golden phase seed
    q += fcos(dot(k, pw) + ph + scrub);                       // analytic AA here
  }
  q /= float(QC_WAVES_C);                                     // \u2248 [\u22121, 1]

  // STEP 4 \u2014 TONE SHAPING. Inhale crisps the interference nodes.
  float sharp = mix(0.9, 1.5, breath);
  float t = clamp(0.5 + (q * 0.5) * sharp, 0.0, 1.0);
  vec3  accent = accentRamp(t);
  float node = pow(abs(q), 6.0);                              // bright antinode fringes

  // STEP 5 \u2014 THEME COMPOSITE (timing identical; only the math flips).
  vec3 col;
  if (uTheme < 0.5){
    // DARK: additive over ink + filmic knee; antinodes bloom toward white.
    col  = uBg;
    col += accent * (0.55 + 0.45 * breath) * uIntensity;
    col += vec3(0.80, 0.85, 1.0) * node * 0.25 * uIntensity;
    col  = col / (col + vec3(0.6));                           // Reinhard knee
    col *= 1.15;
  } else {
    // LIGHT: pearl deposit; uIntensity (~0.78) already low \u2014 never blow out.
    float v = pow(t, 0.8);
    vec3 pearl = mix(uBg, accent, 0.85);
    col = mix(uBg, pearl, v * 0.6 * uIntensity);
    col = mix(col, uInk, smoothstep(0.2, 0.7, node) * 0.05 * uIntensity); // ink contour
  }

  // STEP 6 \u2014 POINTER HALO (match aurora/mesh idiom; breath-gated).
  if (uPointerActive > 0.5){
    vec2 pp = (uPointer * uResolution - 0.5 * uResolution) / uResolution.y;
    float halo = exp(-dot(p - pp, p - pp) * 3.5);
    col += accentRamp(fract(0.55 + uTime * 0.1)) * halo * 0.2 * breath
         * (uTheme < 0.5 ? 1.0 : 0.5);
  }

  // STEP 7 \u2014 VIGNETTE (protect glass-type legibility over the field).
  float vig = smoothstep(1.6, 0.2, length(p));
  col = mix(uBg, col, 0.4 + 0.6 * vig);
  return col;
}
`});var $t={};K($t,{createVolumetricKernel:()=>qr});function qr(){return g({id:"volumetric",label:"Volumetric",body:Ur,controls:["scroll"]})}var Ur,eo=S(()=>{"use strict";N();Ur=`
// \u2500\u2500 Tuning (mirror volumetricMath.ts) \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
const int   MARCH_STEPS  = 32;
const float MARCH_LEN     = 7.0;
const float T_CUTOFF      = 0.012;
const float FREQ          = 0.85;
const float COVERAGE      = 0.52;
const float DENSITY_GAIN  = 1.7;
const float SIGMA_T       = 1.0;
const float SIGMA_S       = 1.1;
const float SIGMA_L       = 2.2;
const float LIGHT_DIST    = 0.55;
const float HG_G          = 0.45;
// Light-orbit geometry (mirror lightOrbit() in volumetricMath.ts).
const float ORBIT_SPEED   = 0.06;
const vec3  ORBIT_CENTER  = vec3(0.0, 0.35, 2.6);
const vec3  ORBIT_RADIUS  = vec3(1.7, 0.55, 0.9);

// 2-octave inline fbm (cheaper than the injected 3-octave for the hot loop).
float fbm2(vec3 q){
  float s = snoise(q) * 0.5;
  s += snoise(q * 2.0) * 0.25;
  return s; // ~[-0.75, 0.75]
}

// Jimenez interleaved gradient noise \u2014 static spatial jitter (no time term).
float ign(vec2 c){
  return fract(52.9829189 * fract(dot(c, vec2(0.06711056, 0.00583715))));
}

// Henyey\u2013Greenstein phase.
float hg(float c, float g){
  float g2 = g * g;
  return (1.0 - g2) / (12.566370614 * pow(max(1.0 + g2 - 2.0 * g * c, 1e-3), 1.5));
}

// Slow-orbiting light. Pointer pulls XY when active; scroll lifts elevation.
vec3 lightOrbit(float t, vec2 puv, float pActive, float scroll){
  float a = t * ORBIT_SPEED;
  vec3 L = ORBIT_CENTER + vec3(
    ORBIT_RADIUS.x * cos(a),
    ORBIT_RADIUS.y * sin(a * 0.7) + (scroll - 0.5) * 0.9,   // scroll \u2192 elevation
    ORBIT_RADIUS.z * sin(a * 0.4));
  // Pointer (already inertia-smoothed by the factory) illuminates: pull XY.
  vec2 pp = (puv * uResolution - 0.5 * uResolution) / uResolution.y;
  L.xy = mix(L.xy, vec2(pp.x * 2.0, pp.y * 2.0), pActive * 0.85);
  return L;
}

float densityAt(vec3 pos, vec3 flow, float breath){
  float raw = fbm2(pos * FREQ + flow);
  float d = max(0.0, raw + 0.5 - COVERAGE);
  return d * DENSITY_GAIN * breath;
}

vec3 renderKernel(vec2 uv, vec2 fragCoord){
  vec2 p = (fragCoord - 0.5 * uResolution) / uResolution.y;

  // CLOCKS. Irrational-ratio breath (never visibly loops); scroll drift.
  // Scroll from the shared D2 control block: uScroll is vec2 (offsetPx, yMax),
  // uScrollVel is px/frame. Normalize to 0..1 here (host gives no normalized form).
  float sN = uScroll.y > 0.0 ? uScroll.x / uScroll.y : 0.0;   // 0..1 scroll position
  float breath = mix(0.86, 1.18,
    0.5 + 0.5 * (0.62 * sin(uTime * 0.2244) + 0.38 * sin(uTime * 0.1013 + 1.3)));
  float drift  = sN * 2.5 + uScrollVel * 0.06;        // scroll drifts medium
  vec3  flow   = vec3(uTime * 0.030 + drift, uTime * 0.018, uTime * 0.020);

  // RAY. Gentle perspective fan so shafts diverge from the light.
  vec3 ro = vec3(p * 2.0, -3.0);
  vec3 rd = normalize(vec3(p * 0.35, 1.0));

  vec3  Lpos = lightOrbit(uTime, uPointer, uPointerActive, sN);
  float dt   = MARCH_LEN / float(MARCH_STEPS);
  float j    = ign(fragCoord);                            // banding \u2192 grain

  float T = 1.0;            // running transmittance
  float scatter = 0.0;      // accumulated in-scatter (scalar; tinted later)
  float depthLit = 0.0;     // weighted mean depth of lit samples (for hue)
  float wsum = 0.0;

  for (int i = 0; i < MARCH_STEPS; i++){
    float t   = (float(i) + j) * dt;
    vec3  pos = ro + rd * t;
    float d   = densityAt(pos, flow, breath);
    if (d > 0.001){
      vec3  Ldir = normalize(Lpos - pos);
      float occ  = densityAt(pos + Ldir * LIGHT_DIST, flow, breath); // 1 light tap
      float Tl   = exp(-occ * SIGMA_L);
      float powd = 1.0 - exp(-d * 2.0);                   // Beer\u2013Powder
      float ph   = hg(dot(rd, Ldir), HG_G);
      float s    = T * (d * SIGMA_S) * Tl * powd * ph * dt;
      scatter   += s;
      depthLit  += s * clamp(t / MARCH_LEN, 0.0, 1.0);
      wsum      += s;
      T *= exp(-d * SIGMA_T * dt);
      if (T < T_CUTOFF) break;                            // early ray termination
    }
  }

  // HUE: shaft color keyed to mean lit depth + a slow iridescence roll.
  float hue = clamp((wsum > 0.0 ? depthLit / wsum : 0.5)
                    + 0.10 * sin(uTime * 0.12), 0.0, 1.0);
  vec3  tint = accentRamp(hue);
  float glow = clamp(scatter, 0.0, 4.0);

  // THEME COMPOSITE (timing identical; only the math flips).
  vec3 col;
  if (uTheme < 0.5){
    // DARK: additive shafts over deep ink, filmic knee blooms cores to white.
    col  = uBg;
    col += tint * glow * (0.9 * uIntensity);
    col += vec3(0.75, 0.85, 1.0) * pow(glow, 3.0) * 0.06;  // hot core whitening
    col  = col / (col + vec3(0.6));
    col *= 1.16;                                          // TONEMAP_KNEE
    // Faint grain floor in the void (dark only) instead of dead black.
    col += vec3(0.8, 0.85, 1.0) * (hash21(fragCoord) - 0.5)
           * 0.012 * (1.0 - clamp(glow * 1.5, 0.0, 1.0));
  } else {
    // LIGHT: pale luminous columns deposited subtractively (no blow-out).
    float v = pow(clamp(glow * 0.7, 0.0, 1.0), 0.8);
    vec3  shaft = accentRamp(clamp(hue + 0.08, 0.0, 1.0));
    vec3  pearl = mix(uBg, shaft, 0.85);
    col = mix(uBg, pearl, v * 0.6 * uIntensity);
    col = mix(col, uInk, smoothstep(0.1, 0.6, v) * 0.04 * uIntensity); // soft contour
  }

  // POINTER HALO (illuminated source bloom; breath-coupled liveliness).
  if (uPointerActive > 0.5){
    vec2 pp = (uPointer * uResolution - 0.5 * uResolution) / uResolution.y;
    float dd = length(p - pp);
    col += accentRamp(fract(0.5 + uTime * 0.08))
           * exp(-dd * dd * 4.0) * 0.22 * breath * (uTheme < 0.5 ? 1.0 : 0.5);
  }

  // VIGNETTE (protect glass-type legibility).
  float vig = smoothstep(1.6, 0.2, length(p));
  col = mix(uBg, col, 0.4 + 0.6 * vig);
  return col;
}
`});var to,oo=S(()=>{"use strict";to="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAAAAACPAi4CAAAQS0lEQVR4nAFAEL/vAIXtAqAniAtQ2Yo9AFyn+8FJ0Yi7RXbAFvlAJlCcZf3AeGq1TaZzKesaivA+Ys9WNtgclHHWVqQR8r7TYxiv9WwApGF40kS3cTayKWaW1C8Ybp8JH/2X3Vqhyoup0hc6ihw02egSjP9DuFnTl74Sr4d2uEqs/wu1yiZ1iC/kVXzOEwDF5BuR9VzqmX73FuZ5Ubg67156rjoHKG41AV/2dLLNWZgGhWC/zAqBNGoEf/ss6hZp8SWJOXqW5l1GFKC6Bkk1ACROrDkQxiMH0FfCRrCMzA3hkDDHUvO0guvclRBG4yjvqUj3OyVTntys9SWlQ1CfAsgxX81N7Roz27SR+Wbri5kA/XJY3oSiZeQ+p28L8iJkgKVH1hNnitFIHrlVxIGhaw9+xG+ylfFlFEnFVs1u2bx64o6n3wVlwqNtA8k5dxvTsgCABcu2LUl5vJIdhzWa30H5KLVymuaoDGGfdyvtOB67UtUvHOAAeTHqkHUN5IwbOJdXQRNynYVD/FODI03dLFs/ABbqk2r5GddSL/3byFl0Fb9TAu4hQi7C/zvYCotk3ZI+82Khi0TSqB28PJ0wrmP4JO+vwSH1uCkN16vqvJWpbb8AnytDDaeL6wOzY0itBaPTkmnKhl3dexZwk7BMpfrIBK2GDee3WsZsh9df/X0STMltCYFO1zZY0JRzPWAQfQfv1wCFY91VwThynMsXfSfohDwtrPU3obqPzFjjI8B7FFZxKs13TTYh+AxQKbIGz+e5h6DRLOlnj3qxGfIuncz3VjZJAMiv9HzSI15ChfRrvlH7YuEOdxtPCPdINAHyYEEwtOtGmP8W232aPt/yb0WUWTIZP162mRcH5EljwIXiRBiMtyAAcwE0G5a28awP3TOXErIfSJvA6dpnJa6dgmzK3p6B1h+mXcSQsWPBoRaCwiJ2pvTce/87qMX4J6UBUiFwp2bbmABb5qRObAjhLVWh0UCLx3DQgllAqYd21Oq4EY4e9AlovjoCbirrCDGNVqs479UNUZAAI3JWhj9tzNuQs8XnL/8UAEG/i/rHgEiPwnUgX+4LpvYnA5UvyQ4+XStPqTlbk03iivGqVNRHd+fQAuBhmrxqxq1Mzt68D559NvtdPAWAT84AeBApYDzVFGb+ALnjfFMzZrjW72C1+hmW2sP8dM+xFzF1zkEQiPwdtWsoTYkbQSrjNuyWHDBf4k4dDXbVnySRrgD1m9+0H6qY6jeIS60qntxEd4weT3GhS31mBIZGJ8Dun18guXvGo1o8mffJcrT8f1yJEWV3sfGNueyZrkjyvmI1AAZqSobucVImo9luGPmSB8YTqzrgCdK98DTkoxPoa4AG2PaZMGfeC79/Eqc0C9KfB8Cl9kbSCCVAZs8riWwa6tcAgsgY0TUHu81cDMM8YrSD5Vf+v4CSLRqKriFX1ZE2UK1EjRTlTiOR8UVf5pJV7Ulv2SY6hJtUqoLBElbgCUClVACyLaNak/h+QuaQgOvPSCE1a5soZOlBW27LPnq6YA/+yCpZb6o5s9BxLtgfw3oprxvnV7jKF/1z2jST+nu3y40hAET9c+LCEWSxHDCmVBB08qfUSQHKpbP72guc9yyp3ph2vOnMA/qFVQiehrc7Z82LP5Z8AmjlLl4F6UwgoF0vcOQAZJABPU0nnt11/Lwlmt2MvRd881IgdRFMj2PEShqEQAgfh0ececIX6q5M+wKdFfFgxvg0rY5FvKTJaLI60/YNvwAV2beAqfSJOVACa8s4ZQZbMJa14YY0n7go4wB07tBpovE3ZeAsYD/ZZRxz4kbXui0So0902x+XehSG8AKSS3+dAFXxIWHSbRfG15ZDffWxRejHbz4PYu7OfPQ6iLFUMrla2a4Otx3zpo4yv1mPqIBScIjfI8sL9VHTKUHcdRzE6jgAeKUxxQrpLrNf7KgO1R2ehfkj143DRhlVaqQfyZQR+CVLjXPUlkvJEHr0zg4kNf4Gs+w8gbJnNetcrL1SpmEosADNSYiZQVaPeRQkhle7K3VPC6RYriqX3gjA2F5E4H1tm8QX+1c1g2vimypCsOhfw55HZJVYF6HDiwmYbDD/hNYJAOUY+3DcvKNI+MEz5pJi3L825GkD/W6CqjKODewrqwTngkCnAem9JAlTtoNqldp3INIMvtj9QnHjIPLPFeJDlmwAPLldDybxBGfbmG9KA/+rF5iBzUy7O+clT/tznr1R1jhf0Sp7y16s/zrW7QROFj6L8jFuJ4kAty5/TjyOBrYhWACMocp8rTeEyT0PtNB/O8hcRPYueRygy2O10IQ8FGaRIbvwaZgbQ4ifdGEepsv3u61Ufp3nq1PRY5+zyFx8o8XzAAEt306T01UirFzuG6Mmi3MQ2LaQ8FkTlABHHfDFevmtCYdLs9vuL9ATksIyf28pEOHHSxk5ed4a+g1v3PdIMnMAsR1pP+oZcP2NeTDhaFTy5a8kYQjGQnf24G6vWdswRp9W3zMRc1YFukjzWN1GoVyXaAaz9WCXv0eQN6gpGGbY6ACCmvrDCqe93gydTsGTuAYznYRQptwviKQ3wSmaiwvPdBnI+6W/kGjme7AmjBXq0jX7QorMLAnvJXTmUr2XiQ9SADfRW3eJMGFCKMz1PxfaRs9pxDnpbbIi1FOAD+RityXrZ5R9Jz32HqY4Cm38twOGwHkjomzagapcyYQD7T3OpMAARRMlt0qc84GzbAGHdKhefR30DI4YXe0GZ/2qO031gzayQwRi1ITJT5bZy0BjqlAb3FrsFU+3OxGi1WmxeSJf8wCuke3gA88bUtmkWukt/g6z35lHdc++S5zJGY51xAKiU9zD5VGdDC7iXRiCnS7mcz2asMQzk/xm4UUuHP9L4AVwANd+ZTarauiVEDe9IJrGjz0oWKz8K5R+NLVD59kebNONDiKp72+0RXet7b5MHo7Q8xB/SQF3ziGIu5xZkjO6nisATg2iVcd5PiX6fdNKZdlRcO+9gQI/4RPwcShZlzKuQP5edoYzE8L+jQAqavbHWgm5LWHT46ZXCvNy6Qh+yWSG+ADLuyL/EYy4YMRvjq8WNYMHyhpj1qJrWqrOhwe98X8VmS29SdqTZCDRVKI8E3vgpmyV+Yk/J7SXTDfDq9oS5ho+AHbomETWLaDfB0LuC+S5ot6SMOlOuCLCDE/6pGFJx2jlsc4X9laoNuV+utiUsTREIlHAHG7tx4DWGGEmUUKas1sACjNrgVzuFVCtMJ1XePsfWkR1nYQ3+IvkMnvYESbdVAU7bKB9BMhwQw30YHEF/YXO6K4NoV4xEGqg+o148msokADC3agBssFzhvhozCeLPWqr87UKFs1xRJkdaT2UuIin+Y8j6UEp7IWwmy4dSr9YoBRzN0rdjvhE4rA9y7YApdH2AB1KivM7H0jTlRzdvUzKAdQmxVXspl4F2reoyexyGjN5TMHVY5e4Elvhxojs0SbjZJL1fsMIdLsjhVkVMdxOOXwAtlgqzGiZ6zMEXX6kD++ZfDeKaN0rsn/wUSpaA0bi0bNcCYOsUfzQJE12qz6ZfTG6AcpbIKpTls8F7Jlw6IgUZQDT/KAW41R8yK9F9TZus2BQFP2XHEqRORXQjv2DoWQolPAV4TEaO2qTAfZlGAqyUNpCK5zYPOUtZ0t7vCJfxKyWAD4HboC6DqQocLjjGZEs6NmoQbtz0/jAaHYLsDfC9A5Ayp9xvI563aW+NtSP5m/4pYrrarUTh/Gn2zj+oUIL7y0A3o3GQzHXYf6NDFXVgUW+B4POLw+hWyPlnknaInBSt4pnIVT3zQpE7oEqWbhIIWAMeBpO/npfCsMejw/Mg9lQeAAgXeyvlO9LHtA+m2bFoh918GRT63wAQYcxvF7pF5vceDXoR6cpYrRSHJ/+e8ybvzrUxJEzzZpBdFGwa1kntWmlAMAOTyR1AInCearnKBH7WTqcJLaN3q/F8qcSe5HKRgD+r8MGf+CaE8Vw2wZAEofsKa5aBKol47b1LNfnO/OTAPoAN5jPZuE8tFcyB/NPcs2s4IgMyTRLYx1wUdX6OqmBLl8a1pVZM/KKOeiSZK8y31Nr+YLeSnAOWIuiBH+cF8lHhQCzfPeoFaD51GWVuoU0kARH9mypGP+Y0SyTBGomV/HRo4dBcrofa9SsJ0zB0nanGZRAIJ/wvTnSGmXHSrt1MmTlAFcYQy7Hg28mGeBDFdq0Zyy9V9Y/dg6DueJFxrIVvkxsJOMN+cxKBFuCEPAiW/QAuc91EGSElvp7MewhW+Kr1SUA8W2N2lMJR+mpfceeW+p90hyTgOShVPM7XqDsjHbfCJHuqFGCsJ55+7ujbUSdf8dN5TK11SlPw6hFsJL+CIoSnwDLBLrrYprAjzlUbPkiDk2iOe0DK7zKJKsZfgs0Y5w+tjLIYzsrFt4/L+aKCdU4KGaJpFtB6wIWa9sMzW9SP8J4AEyXPSerdhD10gIsrj+Yv/xysV1GaAmN6W3bU/3JG/RYdxPamPDFZ5TPG1S4/JKy7RwK/4+seOKcXDyDKqXeYjEAsdeEGv7MMVyFueN41F+HJxTGitn4dLNNLsCmI0etgNMhi7wAV4lJC6x2NeBiEnNV3Hy+IsxXiSz0tBXvuZUe+QBaC2jhUEG1H6JKFpDxB8tq31CnMpoVQNaVEITRkWsF46D/RXLjtiP2XMKcfiJHocU9mUpuNhm8SMiQeE3SAX/nACuov3qgjG3W7mTFN1OrMESXDOkfgs7wYXj3PVvqLME5T2kpqjV+1mzoQgPKr/LTCCz2YNLknvsHaCPjYTRDbo4AzEg18xYF5i1+CpxyIOeA97t3PWW+WCapALkYcbEPmF60EdHtG5sOpCuP+VEwjGmEuqoYBIOwdDjVqQyb/MejEQDfcSDTYMWVVq9D9Nu2YqAXWNSu/gaiN8dI4Z/WTvrOdPKBw5BfTb47gxrVcRHhPx7leJTuUCddlupTwYYntFXvAIiat4FLqTn6Gc4qjEsCzTiRJIVL3pB67GiJMiKCQIwfMqIHP3f7y+JWq7thl6fBWkk0ZsRA38ocf0ByE9tnGzoAA1L8D+Ikdr6Ha6UPeL/hb+8KyC9tEtQbmFTxyGOpA9lL5FjUsCZmBnTrRSXueQH/ndixFImiDrX4La7uSpR7vgBiLKM+j2XYA0/mXjr/lStHq16b5bZWQsIrCLZ5Eue9m2i5GonnFJO3MJoNxDhOz4YoDPZyL/BJaZECzl0zpvfVAMbmbbTN8C+etSDXxa1VHYfXej4e9H+v/HHcpUb3OFUme/o7bi6kR4bQ/GmM2hitYrqOUtBevXrYWJ7kirsJJUUAjR18ClYWgkLtkzGBEutntfcTw1CSA2GcOoxaHZVty92OCqzGU/XeXDwfplR98i9u6DwhqZkFHjbEJEUZauh3rQBa1/eWOKrEYHUNTW2cQs0FNaNy26oz0CPkDMPYLoOtFENd75R+AsAReuXHCLadRwbGfuFG6oT5sN9vgP7IUZsOALkvTMFp3/0epMr0uuAkfI9X5ypkEe2FTrFpe+26BUzloCrPHjjYZpuwTS1x4CCR+KNdD8EsZz+PTwioOpMp3D0Um/hqIqmFNgAAADJ0RVh0Q29tbWVudABibHVlLW5vaXNlIHZvaWQtYW5kLWNsdXN0ZXIgKGdsbS01LTIgYmFrZSkLsSn5AAAAAElFTkSuQmCC"});var ro={};K(ro,{createLicKernel:()=>Wr});function Wr(){return g({id:"lic",label:"Flow Imaging",body:zr,textures:[{name:"uBlueNoise",dataUri:to,filter:"linear",wrap:"repeat"}],controls:["scroll"]})}var zr,io=S(()=>{"use strict";N();oo();zr=`
// \u2500\u2500 Tuning (the v1 Lite tier; mirror flowFieldKernel FIELD/TIME scales) \u2500\u2500\u2500
#define LIC_QUALITY 0          // 0 = Lite (Euler + forward-diff), 1 = Quality (RK2 + central)
const float FIELD_SCALE = 0.0016;   // wind spatial frequency (== flow)
const float TIME_SCALE  = 0.06;     // field reorganisation (uTime in seconds)
const float CURL_EPS    = 1e-3;     // finite-difference step (mirrors CPU EPS)
#if LIC_QUALITY
const int   LIC_STEPS   = 12;       // march steps per direction (2N+1 taps)
#else
const int   LIC_STEPS   = 14;       // Lite: a couple more steps to recover arc-length
#endif
const float STEP_PX     = 1.6;      // arc-length step, device px
const float CONV_FREQ   = 0.30;     // travelling-band spatial frequency
const float PHASE_SPEED = 2.2;      // band travel speed (rad/s)
const float CONTRAST    = 1.9;      // LIC contrast stretch
const float TILE_PX     = ${64 .toFixed(1)};   // blue-noise tile edge (matches bake)

// flow kernel's 14s/31s irrational breath lung, ported to GLSL.
float breath(float t){
  float ms = t * 1000.0;
  return 0.5 + 0.5*(0.62*sin(6.2831853*ms/14000.0)
                  + 0.38*sin(6.2831853*ms/31000.0 + 1.3));
}

// Scalar potential \u03C8(p,\u03C4); z = field-time (same role as CPU noise3 z=t).
float licPotential(vec2 p, float tz){ return snoise(vec3(p, tz)); }

// Divergence-free curl of \u03C8. MIRRORS simplex.ts::curl2: curl = (\u2202\u03C8/\u2202y, \u2212\u2202\u03C8/\u2202x).
// p is FIELD space (already \xD7FIELD_SCALE).
#if LIC_QUALITY
// Central differences \u2014 4 snoise/curl.
vec2 licCurl(vec2 p, float tz){
  float dPdy = (licPotential(p + vec2(0.0, CURL_EPS), tz)
              - licPotential(p - vec2(0.0, CURL_EPS), tz)) / (2.0*CURL_EPS);
  float dPdx = (licPotential(p + vec2(CURL_EPS, 0.0), tz)
              - licPotential(p - vec2(CURL_EPS, 0.0), tz)) / (2.0*CURL_EPS);
  return vec2(dPdy, -dPdx);
}
#else
// Forward differences \u2014 3 snoise/curl (reuse centre \u03C8\u2080): ~25% cheaper, visually
// indistinguishable for a backdrop. The \xA78 licCurlParity test validates the
// (central-diff) wiring on the CPU; this Lite form is the documented v1 default.
vec2 licCurl(vec2 p, float tz){
  float psi0 = licPotential(p, tz);
  float dPdy = (licPotential(p + vec2(0.0, CURL_EPS), tz) - psi0) / CURL_EPS;
  float dPdx = (licPotential(p + vec2(CURL_EPS, 0.0), tz) - psi0) / CURL_EPS;
  return vec2(dPdy, -dPdx);
}
#endif

// Pointer reactivity: BEND the field (LIC is blind to translation, reveals
// rotation) \u2014 add a Gaussian tangential swirl around the cursor.
vec2 pointerBend(vec2 screenPx, vec2 dirIn){
  if (uPointerActive < 0.5) return dirIn;
  vec2  pp = uPointer * uResolution;            // pointer \u2192 device px
  vec2  d  = screenPx - pp;
  float r2 = dot(d, d);
  float R  = 0.22 * min(uResolution.x, uResolution.y);
  float f  = exp(-r2 / (R*R));
  vec2  swirl = vec2(-d.y, d.x) / (sqrt(r2) + 1.0);  // unit tangential
  return normalize(dirIn + swirl * f * 1.6);
}

// Unit streamline direction at screen px.
vec2 fieldDir(vec2 screenPx, float tz){
  vec2 v = licCurl(screenPx * FIELD_SCALE, tz);
  float m = length(v);
  vec2 dir = m > 1e-5 ? v / m : vec2(1.0, 0.0);
  return pointerBend(screenPx, dir);
}

// Sample the tiled blue-noise (repeat wrap, linear filter).
float blue(vec2 px){ return texture(uBlueNoise, px / TILE_PX).r; }

// Animated kernel weight: Hann window (AA) \xD7 travelling cosine band (motion).
float licWeight(float s, float L, float phase){
  float hann = 0.5 + 0.5*cos(3.1415926*s / L);
  float band = 0.5 + 0.5*cos(CONV_FREQ*s - phase);
  return hann * band;
}

vec3 renderKernel(vec2 uv, vec2 fragCoord){
  vec2 p = (fragCoord - 0.5 * uResolution) / uResolution.y;

  // Scroll from D2's shared control block: uScroll = vec2(offsetPx, yMax),
  // uScrollVel = px/frame. Normalize position locally.
  float sN    = uScroll.y > 0.0 ? uScroll.x / uScroll.y : 0.0;
  float b     = breath(uTime);
  float tz    = uTime * TIME_SCALE * (0.7 + 0.6*b) + sN * TIME_SCALE * 9.0;
  float phase = uTime * PHASE_SPEED + uScrollVel * 0.15;   // px/frame gust
  float L     = float(LIC_STEPS) * STEP_PX;

  // centre tap
  float wc  = licWeight(0.0, L, phase);
  float acc = wc * blue(fragCoord);
  float wsum = wc;

  // forward (+1) then backward (-1) march. Lite = Euler (1 fieldDir/step);
  // Quality = RK2 (midpoint sample).
  for (int sgn = 0; sgn < 2; sgn++){
    float dir = sgn == 0 ? 1.0 : -1.0;
    vec2  pt  = fragCoord;
    for (int i = 1; i <= LIC_STEPS; i++){
#if LIC_QUALITY
      vec2 k1 = fieldDir(pt, tz) * dir;
      vec2 k2 = fieldDir(pt + 0.5*STEP_PX*k1, tz) * dir;
      pt += STEP_PX * k2;
#else
      pt += STEP_PX * fieldDir(pt, tz) * dir;
#endif
      float s = float(i) * STEP_PX;
      float w = licWeight(s, L, phase * dir);   // bands travel outward per side
      acc  += w * blue(pt);
      wsum += w;
    }
  }

  float lic = acc / max(wsum, 1e-4);
  lic = clamp((lic - 0.5) * CONTRAST + 0.5, 0.0, 1.0);   // contrast stretch

  // Colour: silk tint from the accent ramp, nudged by local field speed + breath.
  float speed = clamp(length(licCurl(fragCoord*FIELD_SCALE, tz)) * 0.5, 0.0, 1.0);
  vec3  tint  = accentRamp(0.12 + 0.62*lic + 0.18*speed);

  // Theme: dark \u2192 luminous bands lifted toward white; light \u2192 bands darkened
  // toward ink (white would vanish on pearl). Fold uIntensity into the lift.
  vec3  silk;
  if (uTheme < 0.5){
    vec3 hot = mix(tint, vec3(1.0), 0.22 * lic);
    silk = mix(uBg, hot, clamp(lic * 1.15, 0.0, 1.0) * uIntensity);
    silk += tint * (0.10 * b * uIntensity);             // gentle breath bloom
  } else {
    vec3 dark = mix(tint, uInk, 0.35);
    silk = mix(uBg, dark, clamp((1.0 - lic) * 0.9, 0.0, 1.0) * uIntensity);
  }

  // VIGNETTE (protect glass-type legibility over the silk).
  float vig = smoothstep(1.6, 0.2, length(p));
  silk = mix(uBg, silk, 0.4 + 0.6 * vig);
  return silk;   // dither() added by the factory MAIN wrapper
}
`});var no={};K(no,{createFluidAuroraKernel:()=>jr});function jr(){return g({id:"fluid-aurora",label:"Fluid Aurora",body:Vr})}var Vr,lo=S(()=>{"use strict";N();Vr=`
vec3 renderKernel(vec2 uv, vec2 fragCoord) {
  // Normalised centred coordinates, y-up, aspect-correct.
  vec2 p = (fragCoord - 0.5 * uResolution) / uResolution.y;

  // \u2500\u2500 Time clocks (multi-frequency so the loop never visually repeats) \u2500\u2500
  float t  = uTime * 0.05;   // master drift
  float t2 = uTime * 0.023;  // slower hue roll

  // \u2500\u2500 Domain warp: two layers of fbm advection \u2500\u2500
  // q = first warp field, r = second warp field, f = final scalar warp.
  vec2 q = vec2(
    fbm(vec3(p * 1.6, t)),
    fbm(vec3(p * 1.6 + 5.2, t)));
  vec2 r = vec2(
    fbm(vec3(p * 1.6 + 1.3 * q + vec2(1.7, 9.2), t * 1.1)),
    fbm(vec3(p * 1.6 + 1.3 * q + vec2(8.3, 2.8), t * 1.1)));
  float f = fbm(vec3(p * 1.6 + 1.5 * r, t * 0.9));
  vec2 flow = 1.5 * r + 0.6 * q;

  // \u2500\u2500 Three layered curtains (pure trig, zero extra noise) \u2500\u2500
  vec3 acc = vec3(0.0);
  for (int i = 0; i < 3; i++) {
    float di = float(i);
    float depth = 1.0 - 0.30 * di;
    float lt = t * (1.0 + 0.22 * di) + di * 2.39996; // golden-angle offset
    vec2 lp = p * (1.0 - 0.14 * di);
    lp.x += t2 * (1.0 + 0.2 * di) * 1.4;

    float x = lp.x * 3.0 + flow.x * (1.1 * depth) + lt;
    float hgt = lp.y * 1.3 + f * 0.85 + flow.y * 0.45;

    // Cheap fractal filaments (3 octaves abs(sin)) \u2014 no extra snoise.
    float fil = 0.0, amp = 1.0, fq = 1.0;
    for (int k = 0; k < 3; k++) {
      fil += amp * abs(sin(x * fq + hgt * 1.2));
      fq *= 2.2;
      amp *= 0.5;
    }
    fil *= 0.571;

    float edge = smoothstep(0.0, 1.0, fil);
    float core = 1.0 - edge;
    core = core * core * (3.0 - 2.0 * core); // smootherstep
    float glow = core * core;

    // Vertical envelope (fade top/bottom for legibility).
    float env = smoothstep(-1.1, -0.2, lp.y) * smoothstep(1.2, 0.1, lp.y);

    // Altitude-keyed hue via the shared accent ramp.
    float hue = clamp(0.5 + hgt * 0.5 + 0.1 * f + di * 0.05, 0.0, 1.0);
    vec3 accent = accentRamp(hue);

    float lum = glow * env;
    acc += accent * lum * (0.60 / (1.0 + 0.45 * di));
    acc += vec3(0.7, 0.85, 1.0) * pow(glow, 4.0) * env * 0.16 * (1.0 - 0.25 * di);
  }

  // \u2500\u2500 Theme composite (identical timing, math flips for light) \u2500\u2500
  vec3 col;
  if (uTheme < 0.5) {
    // DARK: additive over deep ink, filmic knee bloom.
    col = uBg;
    col += acc * (0.95 * uIntensity);
    col = col / (col + vec3(0.55));
    col *= 1.18;
  } else {
    // LIGHT: pearl watermark \u2014 soft, never muddy.
    col = uBg;
    float v = pow(clamp(dot(acc, vec3(0.45)) * 1.6, 0.0, 1.0), 0.72);
    vec3 ribbon = accentRamp(clamp(0.40 + 0.36 * v + 0.08 * f, 0.0, 1.0));
    vec3 pearl = mix(uBg, ribbon, 0.88);
    col = mix(col, pearl, v * 0.58 * uIntensity);
    col = mix(col, uInk, smoothstep(0.10, 0.58, v) * 0.04 * uIntensity);
    col = mix(col, ribbon, pow(v, 2.4) * 0.16 * uIntensity);
  }

  // \u2500\u2500 Pointer halo (subtle, breath-cycled) \u2500\u2500
  if (uPointerActive > 0.5) {
    vec2 pp = (uPointer * uResolution - 0.5 * uResolution) / uResolution.y;
    float dd = length(p - pp);
    float halo = exp(-dd * dd * 3.5);
    col += accentRamp(fract(0.55 + uTime * 0.1)) * halo * 0.22 * (uTheme < 0.5 ? 1.0 : 0.5);
  }

  // \u2500\u2500 Vignette (protects text legibility) \u2500\u2500
  float vig = smoothstep(1.5, 0.15, length(p));
  col = mix(uBg, col, 0.35 + 0.65 * vig);
  return col;
}
`});var ao={};K(ao,{createCloudFieldKernel:()=>Yr});function Yr(){return g({id:"cloudfield",label:"Cloud Field",body:Xr})}var Xr,so=S(()=>{"use strict";N();Xr=`
// \u2500\u2500 Inline white-noise hash (replaces the original iChannel0 texture) \u2500\u2500\u2500\u2500\u2500
float hash12(vec2 p) {
  vec3 p3 = fract(vec3(p.xyx) * 0.1031);
  p3 += dot(p3, p3.yzx + 33.33);
  return fract((p3.x + p3.y) * p3.z);
}

// Bilinear-interpolated white noise at uv (mimics texture(iChannel0, uv).y).
float noiseTex(vec2 uv) {
  vec2 i = floor(uv);
  vec2 f = fract(uv);
  f = f * f * (3.0 - 2.0 * f); // smoothstep for bilinear feel
  float a = hash12(i);
  float b = hash12(i + vec2(1.0, 0.0));
  float c = hash12(i + vec2(0.0, 1.0));
  float d = hash12(i + vec2(1.0, 1.0));
  return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

// 4-octave FBM \u2014 the original T macro expanded and inlined.
	float fbmCloud(vec4 p, float t) {
  float s = 2.0;
  float sum = 0.0;
  for (int i = 0; i < 4; i++) {
    // Map 3D position to 2D UV (original used ceil(s*p.x) for depth axis).
    vec2 uv = (s * p.zw + ceil(s * p.x)) / 200.0;
    sum += noiseTex(uv) / (s * 4.0);
    s *= 2.0;
  }
  return sum;
}

vec3 renderKernel(vec2 uv, vec2 fragCoord) {
  // Aspect-correct pixel coordinates (original: x/iResolution.y - .8).
  vec2 x = (fragCoord - 0.5 * uResolution) / uResolution.y;

  // Sky colour (original c = vec4(.6,.7,d) where d.zw = x - .8).
  vec3 sky = vec3(0.6, 0.7, 0.8);
  sky -= x.y; // vertical gradient: darker top, lighter bottom

  // Ray direction: .8 forward, x.y screen axes.
  vec4 d = vec4(0.8, 0.0, x.x, x.y);

  // Cloud colour: white tinted by reversed sky (original c.zyxw).
  vec3 cloudTint = vec3(sky.b, sky.g, sky.r);

  vec3 col = sky;

  // Back-to-front raymarch (200 steps, original t = 2e2 + sin(dot(x,x))).
  float jitter = sin(dot(x, x));
  for (float t = 200.0 + jitter; t > 0.0; t -= 1.0) {
    vec4 p = vec4(0.05 * t * d.xyz, 0.05 * t * d.w);
    p.xz += uTime; // camera drift forward + right

    float s = 2.0;
    float f = p.w + 1.0; // height + camera lift

    // Inline the original T macro: 4 octaves of noise.
    for (int i = 0; i < 4; i++) {
      vec2 uv = (s * p.zw + ceil(s * p.x)) / 200.0;
      f -= noiseTex(uv) / (s * 4.0);
      s *= 2.0;
    }

    if (f < 0.0) {
      // Alpha blend: lerp(col, white - density * reversedSky, -f * 0.4).
      // Expanded from original: O += (O - 1. - f*c.zyxw) * f * .4
      vec3 cloudCol = vec3(1.0) + f * cloudTint;
      float density = -f * 0.4;
      col = mix(col, cloudCol, density);
    }
  }

  // Theme adaptation: the original is inherently "daytime sky".
  // Dark theme: treat as a moonlit night cloudscape by desaturating and
  // deepening, then adding a subtle blue bias.
  if (uTheme < 0.5) {
    col = col * 0.35 + vec3(0.05, 0.06, 0.12); // deep night base
    col += accentRamp(0.65) * dot(col, vec3(0.3)) * 0.25; // moon-tinted
    col = col / (col + vec3(0.5)); // filmic knee
    col *= 1.1;
  } else {
    // Light theme: warm the sky slightly toward the pearl backdrop.
    col = mix(col, uBg, 0.15);
    col = mix(col, accentRamp(0.35), 0.08 * uIntensity);
  }

  // Gentle vignette.
  float vig = smoothstep(1.4, 0.25, length(x));
  col = mix(uBg, col, 0.3 + 0.7 * vig);
  return col;
}
`});var co={};K(co,{createPlasmaOrbsKernel:()=>Jr});function Jr(){return g({id:"plasma-orbs",label:"Plasma Orbs",body:Qr})}var Qr,uo=S(()=>{"use strict";N();Qr=`
#define ORB_COUNT 6

// Hash \u2192 unit range; used to give each orb its own quiet per-instance phase.
float orbHash(float n){ return fract(sin(n) * 43758.5453123); }

// 2D analytic "field" at point p for a single orb centred at c, radius r,
// softness s (s controls the inverse-square falloff \u2014 larger s = softer edge).
// Returns a NON-NEGATIVE density; callers sum/integrate.
float orbField(vec2 p, vec2 c, float r, float s){
  vec2 d = p - c;
  float dd = dot(d, d);
  // Smooth-stepped inverse-square (avoids the 1/dd singularity at d=0).
  float k = max(r * r - dd, 0.0) / max(s * s, 1e-4);
  return k * k; // squared falloff \u2192 glassy round silhouettes
}

vec3 renderKernel(vec2 uv, vec2 fragCoord){
  // Aspect-correct centred coords (y up). p is in [-aspect/2 .. +aspect/2] \xD7 [-0.5..0.5].
  vec2 p = (fragCoord - 0.5 * uResolution) / uResolution.y;

  // \u2500\u2500 Time clocks (multi-frequency so the loop never visibly repeats) \u2500\u2500
  float t    = uTime * 0.18;     // orbit
  float tHue = uTime * 0.07;     // hue roll
  float tLow = uTime * 0.045;    // slow drift of the orbs' collective centre

  // \u2500\u2500 Pointer warp (subtle; the host already smoothed uPointer 8%/frame) \u2500\u2500
  vec2 cursor = vec2(0.0);
  if (uPointerActive > 0.5) {
    cursor = (uPointer * uResolution - 0.5 * uResolution) / uResolution.y;
  }

  // \u2500\u2500 Field noise warp (a single shared fbm \u2014 cheap, the "liquid" feel) \u2500\u2500
  vec2 warp = vec2(
    fbm(vec3(p * 0.9,        tLow)),
    fbm(vec3(p * 0.9 + 5.2,  tLow))
  );
  vec2 pw = p + 0.18 * warp;

  // \u2500\u2500 Build the orb cluster \u2500\u2500
  // Each orb orbits a slowly-drifting collective centre with its own radius,
  // phase, and softness, so silhouettes never perfectly align and never collide.
  vec2 centre = 0.10 * vec2(sin(tLow * 1.7), cos(tLow * 1.3));
  float density = 0.0;
  vec3 weightedHue = vec3(0.0); // sum of (hue \xB7 weight) for chromatic rim
  float weightSum = 0.0;

  // Per-orb "rim" accumulator (sharpness = largest local density gradient
  // magnitude \u2192 used for the chromatic-aberration split later).
  float rimAccum = 0.0;

  for (int i = 0; i < ORB_COUNT; i++) {
    float fi = float(i);
    float ph = orbHash(fi * 1.3) * 6.2831853;
    float sp = 0.32 + 0.18 * orbHash(fi * 2.1 + 0.7);     // orbital speed
    float rad = 0.13 + 0.10 * orbHash(fi * 3.7 + 1.9);    // base radius
    float soft = 0.18 + 0.10 * orbHash(fi * 5.3 + 4.1);   // softness
    float orbitR = 0.30 + 0.22 * orbHash(fi * 7.1 + 2.3);  // orbit radius
    vec2  c = centre + orbitR * vec2(cos(t * sp + ph), sin(t * sp * 0.83 + ph));

    // Cursor gravitate (very small so orbs never dart across the screen).
    if (uPointerActive > 0.5) {
      c += 0.04 * (cursor - c) * (1.0 - orbHash(fi * 11.0 + 3.0));
    }

    // Per-orb breathing radius (slow inhale).
    float breathe = 1.0 + 0.10 * sin(uTime * (0.6 + 0.2 * fi) + ph);
    float r = rad * breathe;
    float s = soft * breathe;

    float w = orbField(pw, c, r, s);
    density += w;

    // Each orb carries a per-instance hue offset so the rim is multicoloured.
    float hueT = fract(tHue + 0.18 * fi + 0.07 * orbHash(fi * 9.7 + 6.1));
    weightedHue += accentRamp(hueT) * w;
    weightSum += w;

    // Rim = local Laplacian approximation: how quickly w drops off here. Use
    // the analytic gradient magnitude (sampled cheaply with a tiny epsilon).
    float eps = 0.004;
    float wL = orbField(pw, c, r - eps, s);
    float wR = orbField(pw, c, r + eps, s);
    float ww = abs(wL - wR);
    rimAccum += ww * (1.0 / (eps * 2.0));
  }

  // \u2500\u2500 Density \u2192 palette ramp \u2192 final colour \u2500\u2500
  // Normalise weighted hue by total weight; use the density to interpolate
  // between the theme background and the iridescent rim colour.
  vec3 orbHue = weightSum > 1e-4 ? weightedHue / weightSum : accentRamp(0.5);

  // Soft "core vs halo" split: small density \u2192 background, large \u2192 orb body.
  float core = smoothstep(0.05, 0.55, density);
  float halo = smoothstep(0.0, 0.08, density) * (1.0 - core);

  // Iridescent oil-slick bias: phase = density + time \u2192 rainbow rim.
  float phase = density * 1.4 + tHue * 1.3 + length(warp) * 0.5;
  vec3 slick = vec3(
    accentRamp(fract(phase + 0.10)).r,
    accentRamp(fract(phase + 0.34)).g,
    accentRamp(fract(phase + 0.62)).b
  );

  // \u2500\u2500 Chromatic-aberration rim: sample density at three offset positions in
  //     palette-space, then weight the three ramps by them. Cheap, classic CA.
  float ca = 0.018 + 0.012 * halo;
  float dR = density + ca * 1.6;
  float dG = density;
  float dB = density - ca * 1.6;
  vec3 caRgb = vec3(
    smoothstep(0.05, 0.55, dR),
    smoothstep(0.05, 0.55, dG),
    smoothstep(0.05, 0.55, dB)
  );

  // \u2500\u2500 Theme composite \u2500\u2500
  vec3 col;
  if (uTheme < 0.5) {
    // DARK: orbs bloom over deep ink; filmic knee keeps the cores from
    // burning to flat white, while CA keeps the rim glassy.
    col = uBg;
    col += orbHue * core * 0.55 * uIntensity;
    col += slick   * halo * 0.40 * uIntensity;
    col += caRgb   * (rimAccum * 0.05) * uIntensity;
    col  = col / (col + vec3(0.50));
    col *= 1.18;
    // Soft airglow floor (prevents "dead black" between orbs).
    col += vec3(0.05, 0.06, 0.10) * (1.0 - core) * 0.4;
  } else {
    // LIGHT: pearly watercolour orbs on pearl paper \u2014 never muddy.
    col = uBg;
    vec3 paper = mix(col, orbHue, 0.55 * core * uIntensity);
    paper = mix(paper, slick, halo * 0.45 * uIntensity);
    col = mix(col, paper, 1.0);
    // A whisper of ink gives the rim a soft contour.
    col = mix(col, uInk, halo * 0.06 * uIntensity);
  }

  // \u2500\u2500 Pointer wash: subtle warm halo behind the cursor \u2500\u2500
  if (uPointerActive > 0.5) {
    vec2 pp = (uPointer * uResolution - 0.5 * uResolution) / uResolution.y;
    float dd = length(p - pp);
    float halo2 = exp(-dd * dd * 4.5);
    col += accentRamp(fract(0.65 + uTime * 0.08)) * halo2 * 0.18 * (uTheme < 0.5 ? 1.0 : 0.55);
  }

  // \u2500\u2500 Vignette (protects text legibility over the field) \u2500\u2500
  float vig = smoothstep(1.5, 0.15, length(p));
  col = mix(uBg, col, 0.40 + 0.60 * vig);

  return col;
}
`});var fo={};K(fo,{createBlobsMeshKernel:()=>$r});function $r(){return g({id:"blobs-mesh",label:"Blobs Mesh",body:Zr})}var Zr,mo=S(()=>{"use strict";N();Zr=`
#define BLOB_COUNT 4

// Hash \u2192 unit range (Ashima/Gustavson-style, deterministic, no snoise).
float blobHash(float n){ return fract(sin(n) * 43758.5453123); }

// Inverse-square blob weight at point p for a blob centred at c with radius r.
// Soft-edge falloff: w = 1 / (r^2 + d^2) \u2014 the canonical "metaball-meets-mesh"
// weight. Returns POSITIVE density (additive across blobs).
float blobWeight(vec2 p, vec2 c, float r){
  vec2 d = p - c;
  float dd = dot(d, d);
  float rr = r * r;
  // Smooth the singularity: k = 1 when d=0, falls off smoothly. This is the
  // classic soft-min trick inverted \u2014 it preserves the gentle mesh feel without
  // a 1/0 spike at the centre.
  return rr / (rr + dd + 1e-4);
}

vec3 renderKernel(vec2 uv, vec2 fragCoord){
  // Aspect-correct centred coords (y up). p \u2208 [-aspect/2 .. +aspect/2] \xD7 [-0.5..0.5].
  vec2 p = (fragCoord - 0.5 * uResolution) / uResolution.y;

  // \u2500\u2500 Time clocks (multi-frequency so the loop never visibly repeats) \u2500\u2500
  float t    = uTime * 0.085;   // drift \u2014 slow, contemplative
  float tHue = uTime * 0.018;   // hue roll (very slow; colour identity holds)
  float tLow = uTime * 0.045;   // collective-centre drift

  // \u2500\u2500 Domain warp: simplex noise displaces the sample coordinate so the
  //    blob boundaries flow like liquid (the 2026 "fluid mesh" feel). ONE
  //    shared fbm warp keeps the field as a single body. \u2500\u2500
  vec2 warp = 0.22 * vec2(
    fbm(vec3(p * 0.85,         tLow)),
    fbm(vec3(p * 0.85 + 5.2,   tLow))
  );
  vec2 pw = p + warp;

  // \u2500\u2500 Collective centre (the whole mesh drifts on its own slow clock; the
  //    pointer nudges it gently, like a magnet) \u2500\u2500
  vec2 centre = 0.08 * vec2(sin(tLow * 1.7), cos(tLow * 1.3));
  if (uPointerActive > 0.5) {
    vec2 cursor = (uPointer * uResolution - 0.5 * uResolution) / uResolution.y;
    centre = mix(centre, cursor, 0.10); // soft pointer influence, never a dart
  }

  // \u2500\u2500 Build the 4-blob mesh \u2500\u2500
  // Each blob's centre wanders around the collective centre via simplex noise,
  // its size breathes gently, its softness is per-instance so silhouettes vary.
  vec3 weightedColor = vec3(0.0);
  float weightSum = 0.0;

  for (int i = 0; i < BLOB_COUNT; i++) {
    float fi = float(i);
    float seed     = blobHash(fi * 1.3 + 0.7);
    float driftSpd = 0.55 + 0.45 * blobHash(fi * 2.1 + 1.9);
    float driftAmp = 0.32 + 0.20 * blobHash(fi * 3.7 + 4.1);
    // Two-axis wander via low-freq snoise \u2014 the "organic" feel.
    vec2  wander = vec2(
      snoise(vec3(pw * 0.6 + fi * 7.1,         t * driftSpd)),
      snoise(vec3(pw * 0.6 + fi * 7.1 + 12.3,  t * driftSpd))
    );
    float rad = 0.42 + 0.14 * blobHash(fi * 5.3 + 2.7);
    // Breathing radius \u2014 5.7s/11s irrational pair, never phase-locks.
    float breathe = 1.0 + 0.12 * (
        0.62 * sin(uTime * 1.099 + seed * 6.2831) +
        0.38 * sin(uTime * 0.571 + seed * 6.2831 + 1.3)
    );
    rad *= breathe;

    // The blob's resting colour comes from a per-instance palette slot (the
    // existing accent ramp), with a tiny per-blob hue roll driven by tHue +
    // a deterministic per-instance offset.
    float hueT = fract(tHue + 0.07 * fi + 0.13 * blobHash(fi * 9.7 + 6.1));
    vec3  col  = accentRamp(hueT);

    vec2 c = centre + driftAmp * wander;
    float w = blobWeight(pw, c, rad);
    weightedColor += col * w;
    weightSum += w;
  }

  // Normalise: weighted colour sum / total weight \u2192 the mesh colour at p.
  vec3 mesh = weightSum > 1e-4 ? weightedColor / weightSum : accentRamp(0.5);

  // \u2500\u2500 Theme composite (timing identical; only the math flips) \u2500\u2500
  vec3 col;
  if (uTheme < 0.5) {
    // DARK: additive bloom over deep ink; the mesh glows like a luminous
    // gradient poster. Filmic knee keeps the brightest blob-centres from
    // burning to flat white.
    col = uBg;
    col += mesh * (0.95 * uIntensity);
    col = col / (col + vec3(0.55));
    col *= 1.16;
    // Faint airglow floor (prevents "dead black" between blobs).
    col += vec3(0.06, 0.07, 0.12) * (1.0 - clamp(weightSum * 0.7, 0.0, 1.0)) * 0.35;
  } else {
    // LIGHT: pearl watermark \u2014 a soft, painterly gradient deposited on the
    // paper. Intensity is ~0.78 in light mode (palette.ts) so we never blow out.
    vec3 pearl = mix(uBg, mesh, 0.85);
    // Luminance key: brighter where weightSum is high (blob centres), darker
    // in the gaps. This gives the gradient a soft "spotlit" feel without
    // any hard rim or contour.
    float key = clamp(weightSum * 0.85, 0.0, 1.0);
    col = mix(uBg, pearl, key * 0.62 * uIntensity);
    // A whisper of ink gives the bright blob centres a soft contour.
    col = mix(col, uInk, smoothstep(0.55, 0.95, key) * 0.05 * uIntensity);
  }

  // \u2500\u2500 Pointer wash: a soft, slow-cycling halo behind the cursor \u2500\u2500
  if (uPointerActive > 0.5) {
    vec2 pp = (uPointer * uResolution - 0.5 * uResolution) / uResolution.y;
    float dd = length(p - pp);
    float halo = exp(-dd * dd * 3.5);
    col += accentRamp(fract(0.55 + uTime * 0.08)) * halo * 0.16
         * (uTheme < 0.5 ? 1.0 : 0.5);
  }

  // \u2500\u2500 Vignette (protects text legibility over the field) \u2500\u2500
  float vig = smoothstep(1.5, 0.15, length(p));
  col = mix(uBg, col, 0.40 + 0.60 * vig);

  return col;   // MAIN() adds dither() + clamps to [0,1]
}
`});var po={};K(po,{createRetroPlasmaKernel:()=>ti});function ti(){return g({id:"retro-plasma",label:"Retro Plasma",body:ei})}var ei,ho=S(()=>{"use strict";N();ei=`
// \u2500\u2500 Second-Reality-style plasma (Future Crew, 1993) \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
// Four sine waves with coprime wavenumbers + per-channel phase clocks.
// Sum range is roughly [-4, +4]; we normalise to [0,1] for the palette.
vec3 renderKernel(vec2 uv, vec2 fragCoord){
  vec2 p = (fragCoord - 0.5 * uResolution) / uResolution.y;

  // \u2500\u2500 Time clocks (multi-frequency so the loop never visibly repeats) \u2500\u2500
  // Master drift + slower horizontal sweep. The original 1993 prod used
  // a single t; we add a second clock so the screen never quite returns.
  float t1 = uTime * 0.62;
  float t2 = uTime * 0.31;
  float t3 = uTime * 0.83;

  // \u2500\u2500 THE formula \u2014 four sines, that's it \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
  // Future Crew's canonical plasma; wavenumbers are coprime so the iso-
  // contours never tile. Each term gets its own phase clock.
  float v = sin(p.x * 8.0 + t1)
          + sin(p.y * 7.0 + t2 * 1.07)
          + sin((p.x + p.y) * 5.0 + t3 * 0.91)
          + sin(sqrt(p.x * p.x + p.y * p.y) * 7.0 - t1 * 0.83);

  // Pointer warp (subtle; the host already smooths uPointer 8%/frame).
  if (uPointerActive > 0.5) {
    vec2 cursor = (uPointer * uResolution - 0.5 * uResolution) / uResolution.y;
    float d = distance(p, cursor);
    v += 1.2 * exp(-d * d * 5.0) * sin(uTime * 0.5 + d * 12.0);
  }

  // \u2500\u2500 IQ cosine palette (a + b\xB7cos(2\u03C0(c\xB7t + d))) \u2014 one line, full rainbow \u2500\u2500
  // The famous IQ "cheap procedural palette" (iquilezles.org/articles/palettes).
  // t is the normalised plasma value, plus a slow phase roll so the rainbow
  // never sits at one fixed hue.
  float t = (v + 4.0) * 0.125 + uTime * 0.018;
  vec3  a = vec3(0.50, 0.50, 0.50);
  vec3  b = vec3(0.50, 0.50, 0.50);
  vec3  c = vec3(1.00, 1.00, 0.50);  // R oscillates 1x, G 1x, B 0.5x \u2192 rainbow
  vec3  d2 = vec3(0.80, 0.90, 0.30); // per-channel phase offset
  vec3  paletteCol = a + b * cos(6.28318531 * (c * t + d2));

  // \u2500\u2500 Theme composite \u2014 original 1993 plasma was RGB-on-black, period. \u2500\u2500\u2500\u2500
  // We theme-key it so the family's light theme doesn't blow out, but the
  // PLASMA IS THE POINT: dark theme is the canonical look, light theme is a
  // pearl deposit that preserves the spectral interference (never muddied).
  vec3 col;
  if (uTheme < 0.5) {
    // DARK: classic plasma on deep ink. Filmic knee keeps the brightest
    // ribbons from burning to flat white; faint airglow floor prevents dead
    // black in the troughs.
    col = uBg + paletteCol * (0.95 * uIntensity);
    col = col / (col + vec3(0.55));
    col *= 1.18;
    col += vec3(0.05, 0.06, 0.10) * 0.4;  // airglow grain floor
  } else {
    // LIGHT: pearl deposit \u2014 the rainbow stays vivid because the palette
    // already lives in [0,1], but the brightness is mapped onto the warm
    // paper background instead of pure black. uIntensity ~ 0.78 here.
    float lum = clamp(dot(paletteCol, vec3(0.45)) * 1.6, 0.0, 1.0);
    vec3  pearl = mix(uBg, paletteCol, 0.80);
    col = mix(uBg, pearl, lum * 0.62 * uIntensity);
    col = mix(col, uInk, smoothstep(0.55, 0.95, lum) * 0.045 * uIntensity);
  }

  // \u2500\u2500 Pointer halo (subtle; matches the family idiom) \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
  if (uPointerActive > 0.5) {
    vec2 pp = (uPointer * uResolution - 0.5 * uResolution) / uResolution.y;
    float dd = length(p - pp);
    float halo = exp(-dd * dd * 3.5);
    col += accentRamp(fract(0.55 + uTime * 0.1)) * halo * 0.18
         * (uTheme < 0.5 ? 1.0 : 0.55);
  }

  // \u2500\u2500 Vignette (protects glass-type legibility over the ribbons) \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
  float vig = smoothstep(1.5, 0.15, length(p));
  col = mix(uBg, col, 0.40 + 0.60 * vig);

  return col;   // MAIN() adds dither() + clamps to [0,1]
}
`});var vo={};K(vo,{createInversionLatticeKernel:()=>ri});function ri(){return g({id:"inversion-lattice",label:"Inversion Lattice",body:oi})}var oi,bo=S(()=>{"use strict";N();oi=`
// \u2500\u2500 Inversion Lattice \u2014 2D Apollonian / circle-inversion fractal \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
vec3 renderKernel(vec2 uv, vec2 fragCoord) {
  vec2 R = uResolution;
  vec2 p = (fragCoord - 0.5 * R) / R.y;

  // \u2500\u2500 Living transform: slow rotation + breathing zoom + pointer parallax \u2500\u2500
  float tt = uTime * 0.08;
  float zoom = 1.18 + 0.16 * sin(uTime * 0.13);
  p *= zoom;
  float ca = cos(tt), sa = sin(tt);
  p = mat2(ca, -sa, sa, ca) * p;
  p += (uPointer - 0.5) * 0.12 * uPointerActive;

  // \u2500\u2500 Circle-inversion fold loop (Apollonian nesting), fixed 8 steps \u2500\u2500
  float ir = 1.06 + 0.12 * sin(uTime * 0.2);   // inversion radius, breathing
  vec2 z = p;
  float scale = 1.0;
  float kAcc = 0.0;
  float trap = 1e9;
  const int STEPS = 8;
  for (int i = 0; i < STEPS; i++) {
    z = -1.0 + 2.0 * fract(0.5 * z + 0.5);     // fold into the unit cell
    float r2 = dot(z, z);
    float k = ir / (r2 + 1e-6);                 // circle inversion
    z *= k;
    scale *= k;
    kAcc += k;
    trap = min(trap, abs(r2 - 0.5));            // orbit trap (ring halo)
  }

  // \u2500\u2500 Distance-estimator ring edge (fwidth-AA) + orbit-trap glow \u2500\u2500
  float sc = max(scale, 1e-6);                  // guard log()/division below
  float de = abs(z.y) / sc;
  float w = fwidth(de) + 1e-4;
  float line = 1.0 - smoothstep(0.0, 2.6 * w, de);
  float glow = exp(-6.0 * trap);
  float shape = clamp(line + 0.55 * glow, 0.0, 1.0);

  // \u2500\u2500 Palette hue from inversion scale + fold accumulation \u2500\u2500
  float fold = fract(0.06 * log(sc) + 0.16 * kAcc - 0.08 * uTime);
  vec3 ramp = accentRamp(fold);
  vec3 base = uBg;

  // \u2500\u2500 Theme composite \u2500\u2500
  // DARK: luminous rings added over deep ink (the canonical look).
  vec3 lumRings = base + mix(uInk, ramp, 0.85) * shape * (0.6 + 0.8 * uIntensity);
  lumRings += ramp * 0.04 * (0.5 + 0.5 * sin(log(sc) * 1.5));   // faint scale shimmer
  // LIGHT: ink-deposit rings on the warm paper bg (never blows out).
  vec3 inkRings = mix(base, mix(ramp, uInk, 0.55), shape * (0.5 + 0.6 * uIntensity));

  vec3 col = (uTheme < 0.5) ? lumRings : inkRings;

  // \u2500\u2500 Vignette (keeps foreground text legible) \u2500\u2500
  float vig = smoothstep(1.2, 0.35, length(uv - 0.5) * 1.4);
  col *= mix(0.82, 1.0, vig);

  return col;   // MAIN() appends dither() + clamps to [0,1]
}
`});var go={};K(go,{createVogelBloomKernel:()=>ni});function ni(){return g({id:"vogel-bloom",label:"Vogel Bloom",body:ii})}var ii,yo=S(()=>{"use strict";N();ii=`
// \u2500\u2500 Vogel Bloom \u2014 golden-angle phyllotaxis seed field \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
vec3 renderKernel(vec2 uv, vec2 fragCoord) {
  const float GA = 2.399963229728653; // golden angle (137.5\xB0)
  vec2 res = uResolution;
  vec2 p = (fragCoord - 0.5 * res) / res.y;

  // \u2500\u2500 Living transform: slow rotation + breathing zoom + pointer parallax \u2500\u2500
  float t = uTime * 0.15;
  float ca = cos(t), sa = sin(t);
  p = mat2(ca, -sa, sa, ca) * p;
  p *= 1.6 + 0.25 * sin(uTime * 0.30);
  p -= (uPointer - 0.5) * uPointerActive * 0.30;

  float r = length(p) + 1e-5;

  // \u2500\u2500 Inverse Vogel: nearest seed index i \u2248 (r/c)\xB2; probe a tiny window. \u2500\u2500
  float c = 0.045;
  float fi = r / c; fi = fi * fi;
  float i0 = floor(fi);

  float bloom = 0.0;
  float tintIdx = 0.0;
  float wsum = 1e-5;
  for (int k = -3; k <= 3; k++) {       // fixed 7-sample probe (mobile 60fps)
    float idx = i0 + float(k);
    if (idx < 0.0) continue;
    float ang = idx * GA;
    float rad = c * sqrt(idx);
    vec2 seed = rad * vec2(cos(ang), sin(ang));
    float d = length(p - seed);
    float dotR = 0.012 + 0.010 * sqrt(idx) * c;
    float dval = smoothstep(dotR, dotR * 0.35, d);          // soft glowing dot
    dval *= 0.55 + 0.45 * sin(rad * 14.0 - uTime * 2.0);    // shimmer outward
    bloom += dval;
    tintIdx += idx * dval;
    wsum += dval;
  }
  bloom = clamp(bloom, 0.0, 1.0);

  // \u2500\u2500 Palette hue from the seed index (rolls across the accent ramp). \u2500\u2500
  float seedT = fract((tintIdx / wsum) * 0.0125);
  vec3 ramp = accentRamp(seedT);

  // \u2500\u2500 Fibonacci spiral arms (parastichy interference) shimmering outward. \u2500\u2500
  float arms = abs(sin(0.5 * (atan(p.y, p.x) - r * 9.0 + uTime * 0.6)));
  vec3 armCol = accentRamp(fract(r * 0.4 + uTime * 0.05));
  float armGlow = (1.0 - arms) * smoothstep(1.3, 0.2, r);

  // \u2500\u2500 Theme composite \u2500\u2500
  // DARK: glowing seed dots bloom over deep ink; arms add a faint shimmer.
  vec3 darkCol = mix(uBg, ramp, bloom);
  darkCol += armCol * armGlow * 0.08;
  darkCol = mix(darkCol, uInk, (1.0 - bloom) * 0.06);
  // LIGHT: ink-tinted seed deposits on the warm paper bg (never blows out).
  vec3 lightCol = mix(uBg, mix(ramp, uInk, 0.35), bloom * 0.85);
  lightCol = mix(lightCol, armCol, armGlow * 0.05);

  vec3 col = (uTheme < 0.5) ? darkCol : lightCol;
  col *= 0.85 + 0.30 * uIntensity;

  // \u2500\u2500 Vignette (keeps foreground text legible). \u2500\u2500
  vec2 vu = fragCoord / uResolution;
  col *= smoothstep(1.15, 0.35, length(vu - 0.5) * 1.4);

  return col;   // MAIN() appends dither() + clamps to [0,1]
}
`});var wo={};K(wo,{createCrystalDriftKernel:()=>ai});function ai(){return g({id:"crystal-drift",label:"Crystal Drift",body:li})}var li,xo=S(()=>{"use strict";N();li=`
// \u2500\u2500 Crystal Drift \u2014 animated Worley/Voronoi cellular field \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
vec2 cd_hash22(vec2 p) {
  p = vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)));
  return fract(sin(p) * 43758.5453123);
}

// Returns vec3(F1, F2, hue) over a fixed 3x3 neighborhood of drifting sites.
vec3 cd_worley(vec2 q, float t) {
  vec2 g = floor(q);
  vec2 f = fract(q);
  float f1 = 8.0, f2 = 8.0, hue = 0.0;
  for (int j = -1; j <= 1; j++) {
    for (int i = -1; i <= 1; i++) {
      vec2 lat = vec2(float(i), float(j));
      vec2 rnd = cd_hash22(g + lat);
      vec2 pt = lat + 0.5 + 0.42 * sin(t * 0.55 + 6.2831853 * rnd);
      vec2 d = pt - f;
      float dist = dot(d, d);
      if (dist < f1) {
        f2 = f1;
        f1 = dist;
        hue = rnd.x;
      } else if (dist < f2) {
        f2 = dist;
      }
    }
  }
  return vec3(sqrt(f1), sqrt(f2), hue);
}

vec3 renderKernel(vec2 uv, vec2 fragCoord) {
  vec2 p = (fragCoord - 0.5 * uResolution) / uResolution.y;
  float t = uTime;

  // \u2500\u2500 Domain-warp the lattice so cells shear instead of sitting on a grid \u2500\u2500
  float w = fbm(vec3(p * 1.3, t * 0.05));
  vec2 warp = vec2(w, fbm(vec3(p * 1.3 + 7.31, t * 0.05)));
  vec2 q = p * 2.6 + 0.35 * warp;
  q += 0.12 * vec2(t * 0.10, -t * 0.07);   // slow global drift

  // \u2500\u2500 Cellular field: F1 facet, F2-F1 seam, stable per-cell hue \u2500\u2500
  vec3 cell = cd_worley(q, t);
  float f1 = cell.x, f2 = cell.y, hue = cell.z;
  float edge = f2 - f1;
  float vein = 1.0 - smoothstep(0.0, 0.085, edge);   // glowing seam mask
  float facet = smoothstep(0.0, 0.85, f1);           // cell interior shade
  float tone = fract(hue + 0.10 * w + t * 0.018);    // palette index per cell
  vec3 base = accentRamp(tone);

  // \u2500\u2500 Theme composite \u2500\u2500
  vec3 col;
  if (uTheme < 0.5) {
    // DARK: faceted glass glowing over deep ink, with bright seam highlights.
    col = mix(uBg, base, (0.30 + 0.45 * facet) * uIntensity);
    col += base * vein * (0.85 * uIntensity);
    col += vec3(0.85, 0.92, 1.0) * pow(vein, 3.0) * 0.22;   // cool seam sparkle
  } else {
    // LIGHT: tinted facets inked onto warm paper; seams deposit ink (no blowout).
    col = uBg;
    vec3 tint = mix(uBg, base, 0.55);
    col = mix(col, tint, (0.32 + 0.40 * facet) * uIntensity);
    col = mix(col, uInk, vein * 0.16 * uIntensity);
    col = mix(col, base, pow(vein, 2.0) * 0.10 * uIntensity);
  }

  // \u2500\u2500 Pointer halo: lights seams near the cursor \u2500\u2500
  if (uPointerActive > 0.5) {
    vec2 pp = (uPointer * uResolution - 0.5 * uResolution) / uResolution.y;
    float dd = length(p - pp);
    float halo = exp(-dd * dd * 3.0);
    col += accentRamp(fract(0.5 + t * 0.08)) * halo * vein * 0.45 * (uTheme < 0.5 ? 1.0 : 0.5);
    col += base * halo * 0.10;
  }

  // \u2500\u2500 Vignette (keeps foreground text legible) \u2500\u2500
  float vig = smoothstep(1.5, 0.2, length(p));
  col = mix(uBg, col, 0.40 + 0.60 * vig);

  return col;   // MAIN() appends dither() + clamps to [0,1]
}
`});var To={};K(To,{createRippleLatticeKernel:()=>ci});function ci(){return g({id:"ripple-lattice",label:"Ripple Lattice",body:si})}var si,Ro=S(()=>{"use strict";N();si=`
// \u2500\u2500 Ripple Lattice \u2014 breathing accent-dot lattice + cursor sonar ripples \u2500\u2500
vec3 renderKernel(vec2 uv, vec2 fragCoord) {
  vec2 res = uResolution;
  vec2 p = fragCoord;

  // Lattice cell size, clamped so dots stay readable across resolutions.
  float cell = clamp(res.y / 28.0, 18.0, 64.0);

  // Pointer in y-up pixel space (uPointer is 0..1 y-up; fragCoord is y-up).
  vec2 ptr = uPointer * res;
  float d2p = distance(p, ptr) / max(res.y, 1.0);   // normalized pointer distance

  // Concentric sonar ripple + a soft proximity bulge, gated by uPointerActive.
  float phase  = d2p * 18.0 - uTime * 2.6;
  float ripple = sin(phase) * exp(-d2p * 3.2) * uPointerActive;
  float prox   = exp(-d2p * 2.2) * uPointerActive;

  // Radially shove the sampling space outward from the cursor (the "push").
  vec2 dir = normalize(p - ptr + vec2(1e-4));
  vec2 sp  = p + dir * ripple * cell * 0.6;

  // Slow traveling wave over the lattice (FBM keeps the breathing organic).
  float bgWave = fbm(vec3(sp / cell * 0.16, uTime * 0.14));
  vec2 gid = floor(sp / cell);
  vec2 cuv = fract(sp / cell) - 0.5;
  float wave = 0.5 + 0.5 * sin((gid.x + gid.y) * 0.55 - uTime * 1.4 + bgWave * 2.0);

  // Dot radius breathes with the wave, swells near the cursor + on ripple crests.
  float radius = mix(0.12, 0.32, wave) + prox * 0.20 + ripple * 0.12;
  radius = max(radius, 0.04);
  float dd = length(cuv);
  // Well-defined smoothstep (edge0 < edge1): 1 inside the dot, 0 outside.
  float dotMask = 1.0 - smoothstep(radius - 0.07, radius, dd);

  // Palette-driven dot color; brighter near the cursor.
  vec3 dotCol = accentRamp(wave * 0.65 + prox * 0.35 + 0.08);

  vec3 col = mix(uBg, mix(uBg, dotCol, 0.9), dotMask);
  // DARK: dots glow additively (bloom near the cursor / on ripple crests).
  col += dotCol * dotMask * (1.0 - uTheme) * (0.22 + prox * 0.55);
  // LIGHT: dots deposit ink onto the warm paper bg (never blows out).
  col = mix(col, mix(col, uInk, dotMask * 0.65), uTheme);
  // Faint accent wash riding the ripple crest (dark only).
  col += accentRamp(0.7) * max(ripple, 0.0) * 0.10 * (1.0 - uTheme);

  col *= uIntensity;

  // Vignette (well-defined form): 1 at center, fades toward the edges.
  float vig = 1.0 - smoothstep(0.32, 0.95, length(uv - 0.5));
  col = mix(uBg * mix(0.62, 1.0, uTheme), col, vig);

  return col;   // MAIN() appends dither() + clamps to [0,1]
}
`});var Ao={};K(Ao,{createLiquidLumenKernel:()=>fi});function fi(){return g({id:"liquid-lumen",label:"Liquid Lumen",body:ui})}var ui,Eo=S(()=>{"use strict";N();ui=`
// \u2500\u2500 Liquid Lumen \u2014 fusing charges \u2192 a flowing lava-lamp color field \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
vec3 renderKernel(vec2 uv, vec2 fragCoord){
  float aspect = uResolution.x / max(uResolution.y, 1.0);
  vec2 p = (uv - 0.5); p.x *= aspect;

  // \u2500\u2500 Fixed charge cluster: each drifts on its own ellipse; densities sum \u2500\u2500
  const int N = 7;
  float field = 0.0; vec2 flow = vec2(0.0); float t = uTime * 0.27;
  for (int i = 0; i < N; i++){
    float fi = float(i);
    float sp = 0.6 + 0.35 * fract(sin(fi * 12.9898) * 43758.5453);
    float ph = fi * 2.39996;
    float rx = 0.34 + 0.12 * sin(fi * 1.7), ry = 0.30 + 0.13 * cos(fi * 2.3);
    vec2 c = vec2(
      rx * sin(t * sp + ph) + 0.08 * sin(t * 1.7 + fi),
      ry * cos(t * sp * 0.9 + ph * 1.3) + 0.07 * cos(t * 1.3 + fi)
    );
    // Last charge follows the (smoothed) pointer so the field leans toward it.
    if (i == N - 1 && uPointerActive > 0.5){
      vec2 pp = (uPointer - 0.5); pp.x *= aspect; c = mix(c, pp, 0.85);
    }
    float rad = 0.030 + 0.018 * (0.5 + 0.5 * sin(fi * 3.1 + t));
    vec2 d = p - c; float g = rad / (dot(d, d) + 0.0008);
    field += g; flow += c * g;
  }
  flow /= max(field, 1e-4);                       // flow-weighted centroid

  // \u2500\u2500 Smooth-union surface + thin fused edge band \u2500\u2500
  float surf = smoothstep(0.85, 1.35, field);
  float edge = smoothstep(0.65, 0.95, field) - surf;

  // \u2500\u2500 Palette band: surface mask + flow + a faint fbm wobble \u2500\u2500
  float rampT = 0.15 + 0.55 * surf + 0.30 * (flow.x * 0.5 + 0.5);
  rampT += 0.06 * fbm(vec3(p * 2.5, t));
  vec3 blob = accentRamp(clamp(rampT, 0.0, 1.0));

  bool light = uTheme > 0.5;
  vec3 col = uBg;
  col = mix(col, blob, surf);

  // \u2500\u2500 Rim accent on the fused edge (paper-bright in light, accent-lit in dark) \u2500\u2500
  vec3 rim = light ? mix(blob, vec3(1.0), 0.65) : (blob + uAccent2 * 0.6);
  col += rim * edge * (light ? 0.5 : 0.9);

  // \u2500\u2500 Soft halo just outside the surface, and a single centroid hot spot \u2500\u2500
  float halo = smoothstep(0.25, 0.85, field) * (1.0 - surf);
  col += blob * halo * (light ? 0.12 : 0.28);
  float spec = exp(-6.0 * length(p - flow));
  col += (light ? vec3(0.9) : uAccent3) * spec * 0.18 * surf;

  // \u2500\u2500 Light-only ink deepening inside the surface; intensity gain \u2500\u2500
  col = mix(col, mix(col, uInk, 0.06), surf * (light ? 1.0 : 0.0));
  col *= mix(0.85, 1.25, uIntensity);

  // \u2500\u2500 Vignette (protects text legibility over the field) \u2500\u2500
  float vig = smoothstep(1.15, 0.35, length((uv - 0.5) * vec2(aspect, 1.0)));
  col *= mix(light ? 0.92 : 0.78, 1.0, vig);

  return col;   // MAIN() appends dither() + clamps to [0,1]
}
`});var So={};K(So,{createSpectralDriftKernel:()=>mi});function mi(){return g({id:"spectral-drift",label:"Spectral Drift",body:di})}var di,Co=S(()=>{"use strict";N();di=`
// \u2500\u2500 Spectral Drift \u2014 anisotropic Gabor (sparse-convolution) noise \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
vec3 renderKernel(vec2 uv, vec2 fragCoord) {
  float aspect = uResolution.x / max(uResolution.y, 1.0);
  vec2 p = (uv - 0.5);
  p.x *= aspect;

  // \u2500\u2500 Gabor parameters (compile-time constants \u2192 unrollable loop) \u2500\u2500
  const float FREQ = 9.0;   // carrier frequency of each impulse
  const float BW   = 5.0;   // Gaussian window bandwidth (larger \u21D2 tighter)
  const float SCALE = 4.0;  // cells across the (aspect-corrected) field
  const int   IMP  = 2;     // impulses per grid cell

  float t = uTime * 0.15;

  // \u2500\u2500 Drifting dominant orientation; bends near an active pointer \u2500\u2500
  float gAng = t * 0.6 + 1.2;
  if (uPointerActive > 0.5) {
    vec2 ptr = (uPointer - 0.5);
    ptr.x *= aspect;
    vec2 pd = p - ptr;
    gAng += atan(pd.y, pd.x) * 0.5 * exp(-3.5 * dot(pd, pd));
  }

  // \u2500\u2500 Sparse Gabor convolution over a 3\xD73 cell neighborhood \u2500\u2500
  vec2 g = p * SCALE;
  vec2 cellId = floor(g);
  vec2 f = fract(g);
  float acc = 0.0;
  float wsum = 0.0;
  for (int j = -1; j <= 1; j++) {
    for (int i = -1; i <= 1; i++) {
      vec2 cId = cellId + vec2(float(i), float(j));
      for (int k = 0; k < IMP; k++) {
        vec3 hid = vec3(cId, float(k));
        float ha = fract(sin(dot(hid, vec3(127.1, 311.7, 74.7))) * 43758.5453);
        float hb = fract(sin(dot(hid, vec3(269.5, 183.3, 246.1))) * 23421.6310);
        float hc = fract(sin(dot(hid, vec3(113.5, 271.9, 124.6))) * 14375.5964);
        vec2 d = (vec2(float(i), float(j)) + vec2(ha, hb)) - f;
        float r2 = dot(d, d);
        float win = exp(-BW * r2);                 // Gaussian envelope
        float ang = gAng + (hc - 0.5) * 2.5;       // per-impulse orientation jitter
        vec2 dir = vec2(cos(ang), sin(ang));
        float phase = 6.2831853 * FREQ * dot(d, dir) + t * 4.0 * (ha - 0.5);
        float weight = hb * 2.0 - 1.0;             // signed amplitude
        acc += weight * win * cos(phase);
        wsum += win;
      }
    }
  }
  float n = clamp((acc / max(wsum, 1e-3)) * 1.3, -1.0, 1.0);

  // \u2500\u2500 Palette mapping (theme-branched) \u2500\u2500
  vec3 ramp = accentRamp(n * 0.5 + 0.5);
  // DARK: ribbons emerge from the deep ink bg, brightest at the crests/troughs.
  vec3 darkCol = mix(uBg, ramp, 0.55 + 0.35 * abs(n));
  // LIGHT: the same grain deposited as soft pigment on the warm paper bg.
  vec3 lightCol = mix(uBg, mix(ramp, uInk, 0.18), 0.42 + 0.4 * abs(n));
  vec3 col = (uTheme < 0.5) ? darkCol : lightCol;

  // \u2500\u2500 Thin zero-crossing ink seam between ribbons \u2500\u2500
  float band = smoothstep(0.045, 0.0, abs(n));
  col = mix(col, uInk, band * 0.22 * uIntensity);

  col *= uIntensity;

  // \u2500\u2500 Vignette (keeps foreground text legible) \u2500\u2500
  float vig = smoothstep(1.15, 0.25, length(uv - 0.5) * 1.4);
  col *= mix(0.58, 1.0, vig);

  return col;   // MAIN() appends dither() + clamps to [0,1]
}
`});var ko={};K(ko,{createMyceliumMeshKernel:()=>hi});function hi(){return g({id:"mycelium-mesh",label:"Mycelium Mesh",body:pi})}var pi,Io=S(()=>{"use strict";N();pi=`
// \u2500\u2500 Mycelium Mesh \u2014 domain-warped ridged-fbm transport network \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
// Ridged fbm filament: folds an fbm field into a thin bright ridge. Declared
// before renderKernel so it is in scope at the call sites below. Every fbm()
// call passes a vec3 (the chunk's signature is float fbm(vec3)).
float ridged(vec2 p) {
  float v = fbm(vec3(p, 0.0));
  v = 1.0 - abs(2.0 * v - 1.0);
  return v * v;
}

vec3 renderKernel(vec2 uv, vec2 fragCoord) {
  vec2 aspect = vec2(uResolution.x / uResolution.y, 1.0);
  vec2 p = (uv - 0.5) * aspect;
  float t = uTime * 0.05;

  // \u2500\u2500 Pointer nutrient source: inverse-square pull toward the cursor \u2500\u2500
  vec2 nutrient = (uPointer - 0.5) * aspect;
  float pull = uPointerActive * 0.35 / (0.15 + dot(p - nutrient, p - nutrient));

  // \u2500\u2500 Two-stage domain warp (the network's meandering coordinate field) \u2500\u2500
  vec2 q = vec2(
    fbm(vec3(p * 1.3 + vec2(0.0, t), 0.0)),
    fbm(vec3(p * 1.3 + vec2(5.2, -t), 0.0))
  );
  vec2 r = vec2(
    fbm(vec3(p * 2.1 + 2.0 * q + vec2(1.7, 9.2) + pull, 0.0)),
    fbm(vec3(p * 2.1 + 2.0 * q + vec2(8.3, 2.8) - pull * 0.5, 0.0))
  );

  // \u2500\u2500 Ridged veins: a coarse trunk + a finer capillary octave \u2500\u2500
  float veins = ridged(p * 3.0 + 3.0 * r + t);
  veins += 0.45 * ridged(p * 7.0 + 4.0 * r - t * 1.3);
  veins = clamp(veins, 0.0, 1.0);

  // \u2500\u2500 Breathing: the whole web pulses on a low-frequency fbm phase \u2500\u2500
  float breathe = 0.85 + 0.15 * sin(uTime * 0.4 + fbm(vec3(p * 0.6, 0.0)) * 6.2831);
  veins *= breathe;

  // \u2500\u2500 Dark theme: luminous veins over deep ink, with sparking nodes \u2500\u2500
  vec3 col = uBg;
  vec3 net = accentRamp(veins);
  col = mix(col, net, smoothstep(0.25, 0.9, veins));
  col = mix(col, uInk, smoothstep(0.82, 1.0, veins) * 0.6);
  float nodes = pow(veins, 6.0);                 // bright junction sparks
  col += accentRamp(0.5 + 0.5 * sin(t)) * nodes * 0.6;

  // \u2500\u2500 Light theme: keep veins as ink-on-pearl, never blown-out glow \u2500\u2500
  if (uTheme > 0.5) {
    col = mix(uBg, mix(uBg, net, 0.7), smoothstep(0.25, 0.95, veins));
    col = mix(col, uInk, smoothstep(0.8, 1.0, veins) * 0.25);
  }

  // \u2500\u2500 Vignette (keeps foreground text legible) \u2500\u2500
  float vig = smoothstep(1.25, 0.2, length(p));
  col *= mix(0.55, 1.0, vig);

  col *= uIntensity;
  return col;   // MAIN() appends dither() + clamps to [0,1]
}
`});var Po={};K(Po,{createOilfieldKernel:()=>bi});function bi(){return g({id:"oilfield",label:"Oilfield",body:vi})}var vi,Lo=S(()=>{"use strict";N();vi=`
// \u2500\u2500 Oilfield \u2014 anisotropic-Kuwahara painterly filter over an fbm field \u2500\u2500\u2500\u2500

// Slow-breathing, domain-warped fbm color field, mapped through the palette.
vec3 baseField(vec2 p) {
  float t = uTime * 0.05;
  vec2 q = vec2(
    fbm(vec3(p * 2.3 + vec2(0.0, t), 0.0)),
    fbm(vec3(p * 2.3 + vec2(5.2, -t), 0.0))
  );
  float n = fbm(vec3(p * 3.1 + 1.8 * q + vec2(t * 0.6, -t * 0.4), 0.0));
  n = 0.5 + 0.5 * snoise(vec3(p * 1.4 + n * 1.6 + t, 0.0));
  vec3 col = accentRamp(clamp(n, 0.0, 1.0));
  col = mix(uBg, col, 0.85);
  return col;
}

// Perceptual luminance (renamed to avoid any builtin/chunk collision).
float lumv(vec3 c) { return dot(c, vec3(0.299, 0.587, 0.114)); }

vec3 renderKernel(vec2 uv, vec2 fragCoord) {
  // Fixed brush stride in UV; pointer locally fattens the stroke.
  vec2 px = vec2(1.0 / uResolution.y) * 2.2;
  if (uPointerActive > 0.5) {
    float d = distance(uv, uPointer);
    px *= 1.0 + 0.9 * exp(-d * d * 22.0);
  }

  // Four overlapping quadrant accumulators (mean color + luminance sq-sum).
  vec3 mean0 = vec3(0.0), mean1 = vec3(0.0), mean2 = vec3(0.0), mean3 = vec3(0.0);
  float sq0 = 0.0, sq1 = 0.0, sq2 = 0.0, sq3 = 0.0;
  float cnt0 = 0.0, cnt1 = 0.0, cnt2 = 0.0, cnt3 = 0.0;

  // CONSTANT 7\xD77 window (radius 3) \u2014 compile-time loop bounds, unrolls clean.
  for (int j = -3; j <= 3; j++) {
    for (int i = -3; i <= 3; i++) {
      vec2 off = vec2(float(i), float(j)) * px;
      vec3 c = baseField(uv + off);
      float l = lumv(c);
      bool left = (i <= 0), right = (i >= 0), down = (j <= 0), up = (j >= 0);
      if (left && down)  { mean0 += c; sq0 += l * l; cnt0 += 1.0; }
      if (right && down) { mean1 += c; sq1 += l * l; cnt1 += 1.0; }
      if (left && up)    { mean2 += c; sq2 += l * l; cnt2 += 1.0; }
      if (right && up)   { mean3 += c; sq3 += l * l; cnt3 += 1.0; }
    }
  }

  // Pick the quadrant with the lowest luminance variance (flattest patch).
  vec3 outCol = vec3(0.0);
  float best = 1e9;
  vec3 m; float v;
  m = mean0 / max(cnt0, 1.0); v = sq0 / max(cnt0, 1.0) - lumv(m) * lumv(m); if (v < best) { best = v; outCol = m; }
  m = mean1 / max(cnt1, 1.0); v = sq1 / max(cnt1, 1.0) - lumv(m) * lumv(m); if (v < best) { best = v; outCol = m; }
  m = mean2 / max(cnt2, 1.0); v = sq2 / max(cnt2, 1.0) - lumv(m) * lumv(m); if (v < best) { best = v; outCol = m; }
  m = mean3 / max(cnt3, 1.0); v = sq3 / max(cnt3, 1.0) - lumv(m) * lumv(m); if (v < best) { best = v; outCol = m; }

  // Wet-paint sheen on the brightest patches (palette-tinted highlight).
  float sheen = pow(clamp(lumv(outCol) - 0.55, 0.0, 1.0), 2.0);
  outCol += sheen * 0.12 * uAccent2;

  // LIGHT theme: settle the patches toward ink so the bright canvas reads.
  outCol = mix(outCol, uInk, 0.06 * uTheme);

  outCol *= uIntensity;

  // Vignette (keeps foreground text legible).
  float vig = smoothstep(0.95, 0.35, length(uv - 0.5));
  outCol *= mix(0.78, 1.0, vig);

  return clamp(outCol, 0.0, 1.0);   // MAIN() appends dither() + clamps to [0,1]
}
`});var Mo={};K(Mo,{createSuminagashiDriftKernel:()=>yi});function yi(){return g({id:"suminagashi-drift",label:"Suminagashi Drift",body:gi})}var gi,Bo=S(()=>{"use strict";N();gi=`
// \u2500\u2500 Suminagashi Drift \u2014 closed-form ink-on-water marbling \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
vec3 renderKernel(vec2 uv, vec2 fragCoord) {
  float asp = uResolution.x / max(uResolution.y, 1.0);
  vec2 p = (uv - 0.5) * vec2(asp, 1.0);
  vec2 ptr = (uPointer - 0.5) * vec2(asp, 1.0);
  float t = uTime * 0.18;

  // Closed-form rake strengths (Lu/Jaffer/Witkin): z = stroke amplitude,
  // u = tine falloff base in (0,1) so pow(u, dist) decays away from the line.
  float z = 0.34;
  float u = 0.62;
  vec2 q = p;

  // \u2500\u2500 Crossed comb strokes (horizontal + vertical tine lines), drifting \u2500\u2500
  { float xL = 0.42 * sin(t * 1.3); float d = abs(q.x - xL); q.y -= z * pow(u, d); }
  { float yL = 0.40 * sin(t * 0.9 + 1.7); float d = abs(q.y - yL); q.x -= (z * 0.85) * pow(u, d); }

  // \u2500\u2500 Slow vortex (rotational rake about a drifting center) \u2500\u2500
  {
    vec2 C = vec2(0.18 * sin(t * 0.7), 0.16 * cos(t * 0.6));
    vec2 rp = q - C;
    float h = length(rp);
    float r0 = 0.10;
    float l = (z * 1.4) * pow(u, abs(h - r0));
    float a = -(l / max(h, 1e-3));
    float ca = cos(a), sa = sin(a);
    q = C + vec2(ca * rp.x - sa * rp.y, sa * rp.x + ca * rp.y);
  }

  // \u2500\u2500 Pointer rake \u2014 a live comb stroke under the cursor \u2500\u2500
  { float d = abs(q.x - ptr.x); q.y -= (z * uPointerActive) * pow(u, d); }

  // \u2500\u2500 Concentric ink drops, applied back-to-front (inverse drop map) \u2500\u2500
  const int NDROP = 5;
  float tone = -1.0;
  float vein = 0.0;
  for (int i = NDROP - 1; i >= 0; i--) {
    float fi = float(i);
    vec2 C = 0.46 * vec2(sin(fi * 2.39 + t * 0.5), cos(fi * 1.71 - t * 0.4));
    float r = 0.16 + 0.05 * sin(fi * 1.7 + t);
    vec2 d2 = q - C;
    float dd = length(d2);
    if (tone < 0.0 && dd < r) {
      tone = fract(fi * 0.27 + 0.12);   // band index for this drop
      vein = dd / r;                    // normalized radius within the drop
    } else {
      float s = sqrt(max(1.0 - (r * r) / max(dd * dd, 1e-6), 0.0));
      q = C + d2 * s;                   // pull back through the drop
    }
  }
  if (tone < 0.0) {                      // outside every drop \u2192 background band
    float rr = length(q);
    tone = fract(rr * 1.6 - t * 0.05);
    vein = rr;
  }

  // \u2500\u2500 Marble veins + paper grain \u2500\u2500
  float rings = 0.5 + 0.5 * sin(40.0 * vein + tone * 6.2831 - t);
  float grain = fbm(vec3(q * 3.0 + tone, 0.0)) * 0.12;
  vec3 marble = accentRamp(fract(tone + 0.15 * rings + grain));

  // \u2500\u2500 Theme composite \u2500\u2500
  // DARK: luminous ink marble floated over deep water; vein crests pick out uInk.
  vec3 darkInk = mix(uBg, marble, 0.82);
  darkInk = mix(darkInk, uInk, smoothstep(0.85, 0.98, rings) * 0.35);
  darkInk *= uIntensity;
  // LIGHT: ink deposited on warm paper; stains toward uInk so it never blows out.
  vec3 paperInk = mix(uBg, mix(marble, uInk, 0.5), 0.5 + 0.5 * uIntensity);
  paperInk = mix(paperInk, uInk, smoothstep(0.82, 0.99, rings) * 0.22);

  vec3 col = (uTheme < 0.5) ? darkInk : paperInk;

  // \u2500\u2500 Vignette (keeps foreground text legible) \u2500\u2500
  float vig = smoothstep(1.15, 0.25, length(p));
  col *= mix(0.6, 1.0, vig);

  return col;   // MAIN() appends dither() + clamps to [0,1]
}
`});var Fo={};K(Fo,{createKineticStippleKernel:()=>xi});function xi(){return g({id:"kinetic-stipple",label:"Kinetic Stipple",body:wi})}var wi,Go=S(()=>{"use strict";N();wi=`
// \u2500\u2500 Kinetic Stipple \u2014 curl-advected density as streaming variable-size dots \u2500\u2500

// Scalar potential for the curl field: a single simplex slice over slow time.
float ksPot(vec2 p, float tz){ return snoise(vec3(p, tz)); }

// Divergence-free wind = curl of the scalar potential (Bridson 2007). Central
// differences with a fixed epsilon \u21D2 a perpendicular gradient (rot 90\xB0).
vec2 ksCurl(vec2 p, float tz){
  float e = 1.5e-3;
  float dy = ksPot(p + vec2(0.0, e), tz) - ksPot(p - vec2(0.0, e), tz);
  float dx = ksPot(p + vec2(e, 0.0), tz) - ksPot(p - vec2(e, 0.0), tz);
  return vec2(dy, -dx) / (2.0 * e);
}

vec3 renderKernel(vec2 uv, vec2 fragCoord){
  float tz = uTime * 0.06;
  const float FIELD_SCALE = 0.0016;   // wind spatial frequency
  const float STREAM_PX   = 120.0;    // how far density is pulled upstream
  const float DENS_SCALE  = 0.0042;   // density-field spatial frequency

  // \u2500\u2500 Wind direction at this fragment (+ pointer bow-wave swirl) \u2500\u2500
  vec2 wind = ksCurl(fragCoord * FIELD_SCALE, tz);
  float speed = clamp(length(wind), 0.0, 2.0);
  vec2 dir = speed > 1e-5 ? wind / speed : vec2(1.0, 0.0);
  if(uPointerActive > 0.5){
    vec2 pp = uPointer * uResolution;
    vec2 dpx = fragCoord - pp;
    float R = 0.22 * min(uResolution.x, uResolution.y);
    float f = exp(-dot(dpx, dpx) / (R * R));
    vec2 sw = normalize(vec2(-dpx.y, dpx.x) + 1e-3);
    dir = normalize(dir + sw * f * 1.8);
  }

  // \u2500\u2500 3\xD73 stipple-cell stitch: one streaming dot per cell, seams bled \u2500\u2500
  float cell = 14.0;
  vec2 g = fragCoord / cell;
  vec2 id = floor(g);
  vec2 fp = fract(g);
  float ink = 0.0;
  float litDens = 0.0;
  for(int oy = -1; oy <= 1; oy++){
    for(int ox = -1; ox <= 1; ox++){
      vec2 nid = id + vec2(float(ox), float(oy));
      vec2 cellPx = (nid + 0.5) * cell;
      // Sample the density UPSTREAM so dots inherit the field that flowed in.
      vec2 src = cellPx - dir * (STREAM_PX * (0.6 + 0.4 * speed));
      float dens = clamp(fbm(vec3(src * DENS_SCALE, uTime * 0.12)) * 0.6 + 0.5, 0.0, 1.0);
      // Per-cell life clock: faster where the wind is faster.
      float life = fract(hash21(nid) + uTime * (0.10 + 0.16 * speed));
      float env = sin(life * 3.14159265);          // birth\u2192peak\u2192death opacity
      vec2 jit = (vec2(hash21(nid + 3.1), hash21(nid + 7.7)) - 0.5) * 0.42;
      vec2 ctr = vec2(0.5) + jit + dir * (life - 0.5);  // streams across the cell
      float radius = smoothstep(0.16, 0.92, dens) * 0.46;
      float aa = 1.5 / cell;
      vec2 d = (fp - vec2(float(ox), float(oy))) - ctr;
      float cov = (1.0 - smoothstep(radius - aa, radius + aa, length(d))) * env;
      if(cov > ink){ ink = cov; litDens = dens; }
    }
  }

  // \u2500\u2500 Palette-driven composite (theme-branched) \u2500\u2500
  vec3 dotTint = accentRamp(0.16 + 0.6 * litDens + 0.2 * speed);
  vec3 col;
  if(uTheme < 0.5){
    // DARK: hot dots lifted toward light over deep ink.
    vec3 hot = mix(dotTint, vec3(1.0), 0.25 * litDens);
    col = mix(uBg, hot, ink * uIntensity);
  } else {
    // LIGHT: ink-deposit dots on warm paper (never blows out).
    vec3 dark = mix(dotTint, uInk, 0.55);
    col = mix(uBg, dark, ink * (0.85 * uIntensity));
  }

  // \u2500\u2500 Faint advected haze in the gaps between dots \u2500\u2500
  float haze = fbm(vec3(fragCoord * DENS_SCALE * 0.5 - dir * 2.0, uTime * 0.05));
  col = mix(col, accentRamp(0.1 + 0.3 * haze), 0.04 * uIntensity * (1.0 - ink));

  // \u2500\u2500 Vignette (keeps foreground text legible) \u2500\u2500
  vec2 pc = (fragCoord - 0.5 * uResolution) / uResolution.y;
  float vig = smoothstep(1.6, 0.2, length(pc));
  col = mix(uBg, col, 0.45 + 0.55 * vig);

  return col;   // MAIN() appends dither() + clamps to [0,1]
}
`});var Ko={};K(Ko,{createAgent1Kernel:()=>Ri});function Ri(){return g({id:"agent1",label:"Agent 1",body:Ti})}var Ti,_o=S(()=>{"use strict";N();Ti=`
vec3 renderKernel(vec2 uv, vec2 fragCoord){
  // Normalized coordinates with aspect correction
  vec2 p = (fragCoord - 0.5 * uResolution) / uResolution.y;
  float t = uTime * 0.035;

  // \u2500\u2500 Layer 1: Large slow-moving anchor blobs \u2500\u2500
  vec2 q1 = p * 1.6;
  // Domain warp for organic distortion
  vec2 w1 = vec2(
    fbm(vec3(q1 + vec2(0.0, 1.7), t * 0.7)),
    fbm(vec3(q1 + vec2(4.3, 2.8), t * 0.7))
  );
  vec2 f1 = q1 + 1.2 * w1;

  // Three anchor points orbiting slowly
  float a1 = 0.0;
  for (int i = 0; i < 3; i++) {
    float fi = float(i);
    vec2 center = vec2(
      sin(t * 0.4 + fi * 2.094) * 0.55,
      cos(t * 0.35 + fi * 2.094) * 0.35
    );
    float d = length(f1 - center);
    // Exponential soft-min blend: layers merge like liquid
    a1 += exp(-d * d * 2.8);
  }
  a1 = clamp(a1, 0.0, 1.0);

  // \u2500\u2500 Layer 2: Medium detail blobs \u2500\u2500
  vec2 q2 = p * 2.4 + vec2(3.3, 1.1);
  vec2 w2 = vec2(
    fbm(vec3(q2 * 0.8 + vec2(1.7, 9.2), t * 0.9)),
    fbm(vec3(q2 * 0.8 + vec2(8.3, 2.8), t * 0.9))
  );
  vec2 f2 = q2 + 0.8 * w2;

  float a2 = 0.0;
  for (int i = 0; i < 4; i++) {
    float fi = float(i);
    vec2 center = vec2(
      sin(t * 0.55 + fi * 1.5708 + 1.0) * 0.45,
      cos(t * 0.48 + fi * 1.5708 + 2.0) * 0.4
    );
    float d = length(f2 - center);
    a2 += exp(-d * d * 3.5);
  }
  a2 = clamp(a2, 0.0, 1.0);

  // \u2500\u2500 Layer 3: Fine detail / texture \u2500\u2500
  vec2 q3 = p * 4.0 + vec2(7.7, 5.5);
  float f3 = fbm(vec3(q3, t * 1.2));
  float a3 = smoothstep(-0.3, 0.6, f3) * 0.35;

  // \u2500\u2500 Composite the layers into a mesh-like field \u2500\u2500
  // Layer 1 drives the primary color regions; layer 2 adds detail;
  // layer 3 gives surface texture.
  float field = a1 * 0.55 + a2 * 0.30 + a3 * 0.15;
  field = smoothstep(0.0, 0.85, field);

  // \u2500\u2500 Hue mapping: slow drift through palette \u2500\u2500
  // The field value maps to a position on the accent ramp, but the mapping
  // itself drifts over time so the same spatial region changes color slowly.
  float hueShift = t * 0.15 + fbm(vec3(p * 0.6, t * 0.3)) * 0.25;
  float hue = fract(field * 0.9 + hueShift + length(p) * 0.08);
  vec3 col = accentRamp(hue);

  // \u2500\u2500 Add luminous highlights at blob crests \u2500\u2500
  float crest = pow(a1, 3.0) * 0.4 + pow(a2, 3.0) * 0.25;
  col += vec3(0.85, 0.9, 1.0) * crest * 0.35;

  // \u2500\u2500 Subtle surface sheen from layer 3 \u2500\u2500
  col += vec3(0.7, 0.8, 1.0) * a3 * 0.12;

  // \u2500\u2500 Pointer reactive: a soft glow follows the cursor \u2500\u2500
  if (uPointerActive > 0.5) {
    vec2 ptr = (uPointer * uResolution - 0.5 * uResolution) / uResolution.y;
    float pd = length(p - ptr);
    float pglow = exp(-pd * pd * 5.0) * 0.25;
    // Pointer tint shifts toward the next accent
    vec3 ptrCol = accentRamp(fract(hueShift + 0.25));
    col += ptrCol * pglow;
  }

  // \u2500\u2500 Theme composite \u2500\u2500
  vec3 outCol;
  if (uTheme < 0.5) {
    // Dark: additive glow over deep ink background
    outCol = uBg + col * field * (0.85 * uIntensity);
    // Filmic tonemap to prevent blow-out at blob intersections
    outCol = outCol / (outCol + vec3(0.6)) * 1.25;
    // Airglow grain in the void
    outCol += vec3(0.8, 0.85, 1.0) * (hash21(fragCoord) - 0.5) * 0.012;
  } else {
    // Light: soft watercolor wash on pearl background
    // The field darkens/saturates the background rather than adding light
    float v = pow(field, 0.85) * 0.55 * uIntensity;
    vec3 wash = mix(uBg, col, 0.75);
    outCol = mix(uBg, wash, v);
    // Subtle ink contour at blob edges for definition
    float edge = smoothstep(0.35, 0.55, field) * (1.0 - smoothstep(0.55, 0.85, field));
    outCol = mix(outCol, uInk, edge * 0.04 * uIntensity);
    // Brighten crests slightly
    outCol += vec3(0.9, 0.92, 1.0) * crest * 0.15 * uIntensity;
  }

  // \u2500\u2500 Vignette \u2500\u2500
  float vig = smoothstep(1.4, 0.2, length(p));
  outCol = mix(uBg, outCol, 0.25 + 0.75 * vig);

  return outCol;
}
`});var Do={};K(Do,{createNeuralBloomKernel:()=>Ei});function Ei(){return g({id:"neural-bloom",label:"Neural Bloom",body:Ai})}var Ai,Oo=S(()=>{"use strict";N();Ai=`
// \u2500\u2500 Neural Bloom \u2014 latent FBM \u2192 MLP palette \u2192 organic colour field \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500

// Small MLP: 2 inputs (latent x, y) \u2192 4 hidden \u2192 3 outputs (palette mix weights).
// Weights are baked constants (no external texture / uniform buffer needed).
// This is the "generative AI" part: the network shape and weights were tuned
// by iterative prompt-guided search to produce pleasing, non-repeating colour
// fields that map the site's accent palette.

vec3 neuralPalette(vec2 latent, float t) {
  // Input features: the latent coordinate + a slow time phase.
  float i0 = latent.x;
  float i1 = latent.y;
  float i2 = sin(t * 0.13 + latent.x * 2.1) * 0.5 + 0.5;
  float i3 = cos(t * 0.09 - latent.y * 1.7) * 0.5 + 0.5;

  // Hidden layer 1 (4 neurons, tanh activation).
  float h0 = tanh(i0 *  0.72 + i1 *  0.31 + i2 * -0.55 + i3 *  0.44 + 0.12);
  float h1 = tanh(i0 * -0.41 + i1 *  0.63 + i2 *  0.28 + i3 * -0.19 - 0.08);
  float h2 = tanh(i0 *  0.15 + i1 * -0.47 + i2 *  0.61 + i3 *  0.33 + 0.20);
  float h3 = tanh(i0 * -0.29 + i1 * -0.22 + i2 * -0.38 + i3 *  0.74 - 0.05);

  // Output layer (3 channels \u2192 accent-ramp t, saturation boost, brightness).
  float o0 = h0 *  0.58 + h1 * -0.34 + h2 *  0.21 + h3 *  0.49 + 0.10; // ramp position
  float o1 = h0 * -0.21 + h1 *  0.45 + h2 * -0.12 + h3 *  0.31 + 0.55; // saturation
  float o2 = h0 *  0.33 + h1 *  0.27 + h2 * -0.44 + h3 * -0.18 + 0.60; // brightness

  return vec3(o0, o1, o2);
}

// 2D FBM (3 octaves) used as the "latent" feature map.
float latentFbm(vec2 p) {
  float a = 0.5, s = 0.0;
  for (int i = 0; i < 3; i++) {
    s += a * snoise(vec3(p, 0.0));
    p *= 2.0;
    a *= 0.5;
  }
  return s;
}

vec3 renderKernel(vec2 uv, vec2 fragCoord) {
  vec2 p = (fragCoord - 0.5 * uResolution) / uResolution.y;

  // Slow domain drift so the field never repeats on screen.
  float t = uTime * 0.045;

  // Pointer warp: when active, pull the latent space toward the cursor.
  vec2 warp = p;
  if (uPointerActive > 0.5) {
    vec2 cursor = (uPointer * uResolution - 0.5 * uResolution) / uResolution.y;
    vec2 d = cursor - p;
    float dist = length(d);
    float influence = exp(-dist * dist * 3.5);
    warp += d * influence * 0.35;
  }

  // Latent feature map: two warped FBM channels at different scales.
  float l0 = latentFbm(warp * 1.60 + vec2(t * 1.7, -t * 1.1));
  float l1 = latentFbm(warp * 2.40 + vec2(-t * 1.3,  t * 0.9) + 17.3);
  vec2 latent = vec2(l0, l1);

  // Neural palette mapping.
  vec3 nlp = neuralPalette(latent, uTime);
  float rampT = fract(nlp.x * 0.5 + 0.5 + uTime * 0.018);
  float sat   = clamp(nlp.y, 0.0, 1.0);
  float bri   = clamp(nlp.z, 0.0, 1.0);

  // Base colour from the accent ramp.
  vec3 col = accentRamp(rampT);

  // Second, slower ramp layer for depth (like style-transfer "content" + "style").
  float rampT2 = fract(rampT + 0.35 + latent.x * 0.12);
  vec3 col2 = accentRamp(rampT2);
  col = mix(col, col2, 0.35 * sat);

  // Bloom intensity: a large soft gaussian envelope + fine noise detail.
  float bloom = exp(-dot(p, p) * 0.55) * 0.45;
  bloom += 0.18 * latent.y;
  bloom = clamp(bloom * bri * uIntensity, 0.0, 1.0);

  // Theme composite.
  vec3 outCol;
  if (uTheme < 0.5) {
    // DARK: additive bloom on deep ink. The neural palette drives the colour;
    // bloom modulates brightness. Filmic knee prevents blow-out.
    outCol = uBg + col * bloom * 1.25;
    outCol = outCol / (outCol + vec3(0.45));
    outCol += vec3(0.04, 0.05, 0.08) * (1.0 - bloom); // airglow floor
    outCol *= 1.12;
  } else {
    // LIGHT: pearl deposit. The neural colours sit as a soft wash over the
    // paper background, with ink deepening in the brightest blooms.
    float lum = clamp(dot(col, vec3(0.45)) * bloom * 1.4, 0.0, 1.0);
    vec3 pearl = mix(uBg, col, 0.72 * sat);
    outCol = mix(uBg, pearl, lum * 0.55 * uIntensity);
    outCol = mix(outCol, uInk, smoothstep(0.50, 0.92, lum) * 0.04 * uIntensity);
    // Subtle warm vignette to keep text legible.
    float vig = smoothstep(1.35, 0.25, length(p));
    outCol = mix(outCol, uBg, (1.0 - vig) * 0.12);
  }

  // Pointer halo (subtle accent glow).
  if (uPointerActive > 0.5) {
    vec2 pp = (uPointer * uResolution - 0.5 * uResolution) / uResolution.y;
    float dd = length(p - pp);
    float halo = exp(-dd * dd * 4.0);
    outCol += accentRamp(fract(0.55 + uTime * 0.08)) * halo * 0.15
            * (uTheme < 0.5 ? 1.0 : 0.55);
  }

  // Global vignette (protects glass-type legibility).
  float vig = smoothstep(1.5, 0.15, length(p));
  outCol = mix(uBg, outCol, 0.35 + 0.65 * vig);

  return outCol;   // MAIN() adds dither() + clamps to [0,1]
}
`});var No={};K(No,{createAetherLatticeKernel:()=>Ci});function Ci(){return g({id:"aether-lattice",label:"Aether Lattice",body:Si,controls:["scroll"]})}var Si,Uo=S(()=>{"use strict";N();ht();Si=`
// \u2500\u2500 Aether Lattice \u2014 tuning (hybrid volumetric + quasicrystal) \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
// Mobile perf note: reduce MARCH_STEPS to 20 for 30-45fps on mid-tier Android.
const int   MARCH_STEPS  = 32;
const float MARCH_LEN    = 7.0;
const float T_CUTOFF     = 0.012;
const float W_FLOOR      = 0.01;   // QC-density early-out
const float SIGMA_T      = 1.0;    // extinction
const float SIGMA_S      = 1.1;    // scatter
const float SIGMA_L      = 2.2;    // self-shadow
const float LIGHT_DIST   = 0.55;   // shadow-tap offset
const float HG_G         = 0.45;   // Henyey\u2013Greenstein anisotropy
const float QC_SPIN      = 0.012;  // basis-rotation clock
const float QC_SCRUB     = 0.05;   // global phase-drift clock
const float QC_PI        = 3.14159265;

// Light-orbit geometry (mirror volumetricKernel lightOrbit()).
const float ORBIT_SPEED  = 0.06;
const vec3  ORBIT_CENTER = vec3(0.0, 0.35, 2.6);
const vec3  ORBIT_RADIUS = vec3(1.7, 0.55, 0.9);

// \u2500\u2500 Quasicrystal density field (3D) \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
// Returns a scalar in ~[-1, 1] used to modulate volumetric density.
float quasicrystal3D(vec3 pos, float freq, float spin, float scrub){
  float q = 0.0;
  for (int j = 0; j < ${Oe}; j++){
    float a  = QC_PI * float(j) / float(${Oe}) + spin;
    vec3  k  = vec3(cos(a), sin(a), 0.0) * freq; // 2D wave basis extended into Z
    float ph = float(j) * ${Je.toFixed(10)};
	    q += cos(dot(k, pos) + ph + scrub);
  }
  q /= float(${Oe});
  return q;
}

// 2-octave inline fbm for the flow/drift term (cheaper than injected 3-octave).
float fbm2_qc(vec3 q){
  float s = snoise(q) * 0.5;
  s += snoise(q * 2.0) * 0.25;
  return s;
}

// Jimenez interleaved gradient noise \u2014 static spatial jitter (no time term).
float ign(vec2 c){
  return fract(52.9829189 * fract(dot(c, vec2(0.06711056, 0.00583715))));
}

// Henyey\u2013Greenstein phase.
float hg(float c, float g){
  float g2 = g * g;
  return (1.0 - g2) / (12.566370614 * pow(max(1.0 + g2 - 2.0 * g * c, 1e-3), 1.5));
}

// Slow-orbiting light. Pointer pulls XY when active; scroll lifts elevation.
vec3 lightOrbit(float t, vec2 puv, float pActive, float scroll){
  float a = t * ORBIT_SPEED;
  vec3 L = ORBIT_CENTER + vec3(
    ORBIT_RADIUS.x * cos(a),
    ORBIT_RADIUS.y * sin(a * 0.7) + (scroll - 0.5) * 0.9,
    ORBIT_RADIUS.z * sin(a * 0.4));
  vec2 pp = (puv * uResolution - 0.5 * uResolution) / uResolution.y;
  L.xy = mix(L.xy, vec2(pp.x * 2.0, pp.y * 2.0), pActive * 0.85);
  return L;
}

// Density at a point: quasicrystal modulated by fbm flow + breath.
float densityAt(vec3 pos, float freq, float spin, float scrub, vec3 flow, float breath){
  float qc = quasicrystal3D(pos, freq, spin, scrub);
  // Shift and scale QC into a positive density with soft clamping.
  float d = max(0.0, qc * 0.5 + 0.5 - 0.48); // threshold tuned for lacy shafts
  // Add low-frequency fbm drift so the lattice breathes and warps.
  float drift = fbm2_qc(pos * 0.7 + flow) * 0.25 + 0.75;
  return d * drift * breath * 1.6;
}

vec3 renderKernel(vec2 uv, vec2 fragCoord){
  vec2 p = (fragCoord - 0.5 * uResolution) / uResolution.y;

  // CLOCKS. Irrational-ratio breath; scroll drift (D2 control block).
  float sN = uScroll.y > 0.0 ? uScroll.x / uScroll.y : 0.0;
  float breath = mix(0.86, 1.18,
    0.5 + 0.5 * (0.62 * sin(uTime * 0.2244) + 0.38 * sin(uTime * 0.1013 + 1.3)));
  float drift  = sN * 2.5 + uScrollVel * 0.06;
  vec3  flow   = vec3(uTime * 0.030 + drift, uTime * 0.018, uTime * 0.020);
  float spin   = uTime * QC_SPIN;
  float scrub  = uTime * QC_SCRUB;
  float freq   = ${Ze.toFixed(1)} * (0.9 + 0.2 * breath);

  // RAY. Gentle perspective fan so shafts diverge from the light.
  vec3 ro = vec3(p * 2.0, -3.0);
  vec3 rd = normalize(vec3(p * 0.35, 1.0));

  vec3  Lpos = lightOrbit(uTime, uPointer, uPointerActive, sN);
  float dt   = MARCH_LEN / float(MARCH_STEPS);
  float j    = ign(fragCoord); // banding \u2192 grain

  float T = 1.0;
  float scatter = 0.0;
  float depthLit = 0.0;
  float wsum = 0.0;

  for (int i = 0; i < MARCH_STEPS; i++){
    float t   = (float(i) + j) * dt;
    vec3  pos = ro + rd * t;
    float d   = densityAt(pos, freq, spin, scrub, flow, breath);
    if (d > W_FLOOR){
      vec3  Ldir = normalize(Lpos - pos);
      float occ  = densityAt(pos + Ldir * LIGHT_DIST, freq, spin, scrub, flow, breath);
      float Tl   = exp(-occ * SIGMA_L);
      float powd = 1.0 - exp(-d * 2.0); // Beer\u2013Powder
      float ph   = hg(dot(rd, Ldir), HG_G);
      float s    = T * (d * SIGMA_S) * Tl * powd * ph * dt;
      scatter   += s;
      depthLit  += s * clamp(t / MARCH_LEN, 0.0, 1.0);
      wsum      += s;
      T *= exp(-d * SIGMA_T * dt);
      if (T < T_CUTOFF) break; // early ray termination
    }
  }

  // HUE: shaft color keyed to mean lit depth + slow iridescence roll.
  float hue = clamp((wsum > 0.0 ? depthLit / wsum : 0.5)
                    + 0.10 * sin(uTime * 0.12), 0.0, 1.0);
  vec3  tint = accentRamp(hue);
  float glow = clamp(scatter, 0.0, 4.0);

  // THEME COMPOSITE (timing identical; only the math flips).
  vec3 col;
  if (uTheme < 0.5){
    // DARK: additive shafts over deep ink, filmic knee blooms cores to white.
    col  = uBg;
    col += tint * glow * (0.9 * uIntensity);
    col += vec3(0.75, 0.85, 1.0) * pow(glow, 3.0) * 0.06; // hot core whitening
    col  = col / (col + vec3(0.6));
    col *= 1.16; // TONEMAP_KNEE
    col += vec3(0.8, 0.85, 1.0) * (hash21(fragCoord) - 0.5)
           * 0.012 * (1.0 - clamp(glow * 1.5, 0.0, 1.0));
  } else {
    // LIGHT: pale luminous columns deposited subtractively (no blow-out).
    float v = pow(clamp(glow * 0.7, 0.0, 1.0), 0.8);
    vec3  shaft = accentRamp(clamp(hue + 0.08, 0.0, 1.0));
    vec3  pearl = mix(uBg, shaft, 0.85);
    col = mix(uBg, pearl, v * 0.6 * uIntensity);
    col = mix(col, uInk, smoothstep(0.1, 0.6, v) * 0.04 * uIntensity);
  }

  // POINTER HALO (illuminated source bloom; breath-coupled liveliness).
  if (uPointerActive > 0.5){
    vec2 pp = (uPointer * uResolution - 0.5 * uResolution) / uResolution.y;
    float dd = length(p - pp);
    col += accentRamp(fract(0.5 + uTime * 0.08))
           * exp(-dd * dd * 4.0) * 0.22 * breath * (uTheme < 0.5 ? 1.0 : 0.5);
  }

  // VIGNETTE (protect glass-type legibility).
  float vig = smoothstep(1.6, 0.2, length(p));
  col = mix(uBg, col, 0.4 + 0.6 * vig);
  return col;
}
`});var qo={};K(qo,{createBeamProjectorKernel:()=>Ii});function Ii(){return g({id:"bat-signal",label:"Beacon",body:ki,controls:["scroll"]})}var ki,Ho=S(()=>{"use strict";N();ki=`
// Projector pinned dead-still off-canvas bottom-center. Beam aim eases toward
// the pointer (never snaps). Cone half-angle, shaft reach, fog density.
const float BEAM_HALF_ANGLE = 0.11;
const float SHAFT_LEN       = 2.8;
const float FOG_FREQ        = 1.5;
const float FOG_COVERAGE    = 0.44;
const float FOG_GAIN        = 1.4;
const float N_RAYS          = 5.0;     // a small steady set of god-rays

// Jimenez interleaved gradient noise \u2014 static spatial jitter (no time term).
float ign(vec2 c){
  return fract(52.9829189 * fract(dot(c, vec2(0.06711056, 0.00583715))));
}
// cheap 2D value noise
float vnoise(vec2 p){
  vec2 i = floor(p);
  vec2 f = fract(p);
  f = f*f*(3.0-2.0*f);
  float a = ign(i);
  float b = ign(i + vec2(1.0,0.0));
  float c = ign(i + vec2(0.0,1.0));
  float d = ign(i + vec2(1.0,1.0));
  return mix(mix(a,b,f.x), mix(c,d,f.x), f.y);
}
// 2-octave fbm for the fog field
float fbm2(vec2 q){
  float s = vnoise(q)*0.5;
  s += vnoise(q*2.07 + 11.0)*0.25;
  return s;
}

vec3 renderKernel(vec2 uv, vec2 fragCoord){
  vec2 p = (fragCoord - 0.5*uResolution)/uResolution.y;

  float sN = uScroll.y > 0.0 ? uScroll.x/uScroll.y : 0.0;
  // one calm slow breath (very small amplitude) \u2014 alive, never busy.
  float breath = 0.93 + 0.07*sin(uTime*0.21);

  // Projector origin: DEAD STILL, off-canvas bottom-center.
  vec2 proj = vec2(0.0, -1.15);

  // Beam AIM. Pointer ACTIVE \u2192 beam EASES toward the cursor (heavy ease so it
  // drifts, never snaps; pointer sits in the lower-mid sky so the beam rises at
  // a calm diagonal). Pointer ABSENT \u2192 a single near-static beam with the
  // faintest sway, not a sweep.
  vec2 aimN;
  if (uPointerActive > 0.5){
    vec2 pp = (uPointer*uResolution - 0.5*uResolution)/uResolution.y;
    // compress + bias the target so the beam stays a graceful near-vertical
    // diagonal (never horizontal, never whipping to the edges).
    vec2 target = vec2(pp.x*0.5, max(pp.y, -0.1)*0.6 + 0.55);
    aimN = normalize(target - proj);
  } else {
    // the faintest sway \u2014 almost still, just breathing.
    float sway = sin(uTime*0.08)*0.08;
    aimN = normalize(vec2(sway, 1.0));
  }

  // \u2500\u2500 cone geometry: perp/along distance to the beam axis \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
  vec2 toP = p - proj;
  float along = dot(toP, aimN);
  float perp  = abs(toP.x*aimN.y - toP.y*aimN.x);
  // cone envelope: bright on axis, feathered at the half-angle, dead past it.
  float cone = smoothstep(BEAM_HALF_ANGLE, 0.0, perp/max(along, 0.001));
  // reach: beam fades with distance + only the forward half-cone.
  float reach = smoothstep(SHAFT_LEN, 0.0, along) * step(0.0, along);
  float beam = cone*reach;
  beam *= 0.8 + 0.2*breath;

  // \u2500\u2500 fog field: fbm density that BRIGHTENS where the beam passes \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
  vec2 fuv = p*FOG_FREQ + vec2(uTime*0.018 + sN*1.2, uTime*0.010);
  float fog = max(0.0, fbm2(fuv) + 0.5 - FOG_COVERAGE) * FOG_GAIN * breath;
  // in-scatter: fog lit by the beam \u2014 the visible volumetric body of the cone.
  float scatter = fog * beam;

  // \u2500\u2500 steady crepuscular god-rays: a small set, gently breathing in unison \u2500
  float rays = 0.0;
  for (float i = 0.0; i < N_RAYS; i += 1.0){
    float u = (i + 0.5)/N_RAYS - 0.5;            // -0.5..0.5 across the cone
    float angOff = u*BEAM_HALF_ANGLE*1.6;
    vec2 rayDir = vec2(aimN.x*cos(angOff) - aimN.y*sin(angOff),
                       aimN.x*sin(angOff) + aimN.y*cos(angOff));
    float rAlong = dot(toP, rayDir);
    float rPerp  = abs(toP.x*rayDir.y - toP.y*rayDir.x);
    float rCone  = smoothstep(0.016, 0.0, rPerp) * step(0.0, rAlong)
                   * smoothstep(SHAFT_LEN, 0.0, rAlong);
    rays += rCone;
  }
  rays *= breath * (0.85 + 0.15*sin(uTime*0.35));   // one shared slow pulse

  // \u2500\u2500 lens flare at the projector origin \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
  float bloom = exp(-dot(toP,toP)*9.0) * breath;

  // tint: a steady cold sky-beam blue (held still \u2014 color must not wobble).
  vec3 tint = accentRamp(0.62);
  vec3 hot  = accentRamp(0.74);

  vec3 col;
  if (uTheme < 0.5){
    // DARK: additive in-scatter over deep ink, filmic knee blooms cores to white.
    col  = uBg;
    col += tint*beam*0.5*uIntensity;             // cone body
    col += tint*scatter*1.4*uIntensity;          // lit fog (the visible volume)
    col += hot*rays*0.16*uIntensity;             // steady god-rays
    col += vec3(0.8,0.86,1.0)*bloom*0.6*uIntensity; // source flare
    col += vec3(0.85,0.9,1.0)*(ign(fragCoord)-0.5)*0.012*(1.0-beam); // grain floor
    col = col/(col+vec3(0.6));
    col *= 1.14;
  } else {
    // LIGHT: pale luminous column deposited softly (never toward white).
    float v = pow(clamp(beam*0.7 + scatter*0.5, 0.0, 1.0), 0.85);
    vec3 pearl = mix(uBg, tint, 0.7);
    col = mix(uBg, pearl, v*0.38*uIntensity);
    col = mix(col, hot, clamp(rays*0.5, 0.0, 1.0)*0.10*uIntensity);
    col = mix(col, uInk, smoothstep(0.1, 0.6, v)*0.03*uIntensity);
    col = mix(col, tint, bloom*0.14*uIntensity); // soft flare disc
  }

  // Vignette to protect glass-type legibility.
  float vig = smoothstep(1.7, 0.3, length(p));
  col = mix(uBg, col, 0.4 + 0.6*vig);
  return col;
}
`});var zo={};K(zo,{createStormCellKernel:()=>Li});function Li(){return g({id:"storm-signal",label:"Tempest",body:Pi,controls:["scroll"]})}var Pi,Wo=S(()=>{"use strict";N();Pi=`
const float CELL_FREQ = 0.85;
const float CELL_COVERAGE = 0.46;
const float DENSITY_GAIN = 1.6;
const float FLASH_RATE = 0.9;     // Hz of sheet-lightning attempts
const float FLASH_DECAY = 3.2;    // exponential decay of a flash

float ign(vec2 c){
  return fract(52.9829189 * fract(dot(c, vec2(0.06711056, 0.00583715))));
}

// 3-octave fbm (injected snoise + accumulation).
float stormFbm(vec3 q){
  float s = snoise(q)*0.5;
  s += snoise(q*2.03)*0.25;
  s += snoise(q*4.07)*0.125;
  return s; // ~[-0.875, 0.875]
}

vec3 renderKernel(vec2 uv, vec2 fragCoord){
  vec2 p = (fragCoord - 0.5*uResolution)/uResolution.y;

  float sN = uScroll.y > 0.0 ? uScroll.x/uScroll.y : 0.0;
  float breath = mix(0.88, 1.12,
    0.5 + 0.5*(0.62*sin(uTime*0.2144) + 0.38*sin(uTime*0.0913 + 1.3)));
  float drift = sN*2.0;
  vec3 flow = vec3(uTime*0.028 + drift, uTime*0.017, uTime*0.019);

  // Rolling cell: fbm gated above a coverage threshold.
  vec3 q = vec3(p*1.4, 0.0) + flow;
  float raw = stormFbm(q);
  float cell = max(0.0, raw + 0.5 - CELL_COVERAGE) * DENSITY_GAIN * breath;

  // Sheet lightning: a strobe that lights the whole cell from within.
  // Drive it off uTime so every pixel agrees; gate by a per-strobe seed.
  float strobePhase = uTime*FLASH_RATE;
  float strobeIdx = floor(strobePhase);
  float strobeFrac = strobePhase - strobeIdx;
  float strobeSeed = fract(sin(strobeIdx*12.9898)*43758.5453);
  float strobeAlive = step(0.62, strobeSeed);   // ~38% of attempts fire
  float flash = strobeAlive * exp(-strobeFrac*FLASH_DECAY) * cell;

  vec3 tint = accentRamp(0.5 + 0.05*sin(uTime*0.1));
  vec3 hot  = accentRamp(0.72);

  vec3 col;
  if (uTheme < 0.5){
    // DARK: charged slate + electric-blue in-scatter, filmic knee.
    col  = uBg;
    col += tint*cell*0.55*uIntensity;
    col += hot*flash*1.6*uIntensity;
    col += vec3(0.8,0.85,1.0)*(ign(fragCoord)-0.5)*0.012*(1.0-cell);
    col = col/(col+vec3(0.6));
    col *= 1.16;
  } else {
    // LIGHT: cool wash, flash reads as a pale brightening.
    float v = pow(clamp(cell*0.7, 0.0, 1.0), 0.85);
    vec3 pearl = mix(uBg, tint, 0.6);
    col = mix(uBg, pearl, v*0.4*uIntensity);
    col = mix(col, hot, clamp(flash*0.6, 0.0, 1.0)*0.25*uIntensity);
    col = mix(col, uInk, smoothstep(0.1, 0.6, v)*0.03*uIntensity);
  }

  // Pointer halo: a charged glow where the cursor stirs the cell.
  if (uPointerActive > 0.5){
    vec2 pp = (uPointer*uResolution - 0.5*uResolution)/uResolution.y;
    float dd = length(p - pp);
    col += hot*exp(-dd*dd*4.0)*0.16*breath*(uTheme < 0.5 ? 1.0 : 0.5);
  }

  float vig = smoothstep(1.6, 0.2, length(p));
  col = mix(uBg, col, 0.4 + 0.6*vig);
  return col;
}
`});var Vo={};K(Vo,{createPaperfieldKernel:()=>Bi});function Bi(){return g({id:"origami",label:"Origami",body:Mi,controls:["scroll"]})}var Mi,jo=S(()=>{"use strict";N();Mi=`
const float FIBER_FREQ = 1.7;
const float LAID_FREQ  = 0.22;
const float LAID_AMP   = 0.12;
const float DECKLE_W   = 1.55;

float ign(vec2 c){
  return fract(52.9829189 * fract(dot(c, vec2(0.06711056, 0.00583715))));
}

// 3-octave fbm (injected snoise + accumulation) \u2014 the fiber body.
float paperFbm(vec3 q){
  float s = snoise(q) * 0.5;
  s += snoise(q * 2.05) * 0.25;
  s += snoise(q * 4.12) * 0.125;
  return s;
}

vec3 renderKernel(vec2 uv, vec2 fragCoord){
  vec2 p = (fragCoord - 0.5*uResolution)/uResolution.y;

  float sN = uScroll.y > 0.0 ? uScroll.x/uScroll.y : 0.0;
  float breath = 0.5 + 0.5*sin(uTime*0.18);
  float drift = sN*1.4;
  vec3 flow = vec3(uTime*0.022 + drift, uTime*0.013, 0.0);

  // Domain warping: a low-frequency warp field gives the fibers their organic,
  // hand-pulled non-uniformity. Two taps of fbm feed the sample position.
  vec3 q = vec3(p*FIBER_FREQ, 0.0) + flow;
  vec2 warpOff = vec2(
    paperFbm(q + vec3(13.1, 0.0, 0.0)),
    paperFbm(q + vec3(0.0, 17.7, 0.0))
  ) * 0.4;
  float fiber = paperFbm(vec3(q.xy + warpOff, q.z));  // ~[-0.875, 0.875]

  // Laid lines: the wire-screen imprint. A slow horizontal sinusoid, phase-
  // warped by the fiber field so the lines breathe with the sheet.
  float laidPhase = uTime*0.06
    + (uPointerActive > 0.5 ? (uPointer.x - 0.5) * 3.0 : 0.0);
  float laid = sin((p.y*2.0 + warpOff.y*0.6) * LAID_FREQ * 60.0 + laidPhase);
  laid = smoothstep(0.7, 1.0, laid*LAID_AMP + (1.0 - LAID_AMP));

  // Deckle edge: a soft vignette whose boundary is itself warped by the fiber
  // field (a hand-made deckle is irregular, not a clean ellipse).
  float deckleR = length(p * vec2(0.75, 1.0))
    + 0.08 * paperFbm(vec3(p*3.0, uTime*0.03));
  float deckle = smoothstep(DECKLE_W, DECKLE_W*0.55, deckleR);

  // Warm window-light bloom: an off-canvas top-left light catching the sheet.
  vec2 lp = p - vec2(-0.9, 0.85);
  float lit = exp(-dot(lp, lp) * 1.6) * (0.6 + 0.4*breath);

  // Fiber \u2192 base tint. Kozo is warm cream; fibers read as subtle tan variation.
  float fib01 = clamp(fiber*0.5 + 0.5, 0.0, 1.0);

  vec3 col;
  if (uTheme < 0.5){
    // DARK: deep warm ink-wash washi under moonlight.
    vec3 kozo = mix(vec3(0.10, 0.09, 0.08), vec3(0.22, 0.19, 0.15), fib01);
    vec3 tint = accentRamp(0.4 + 0.08*fib01);
    col = mix(uBg, kozo, 0.55*uIntensity);
    col += tint*laid*0.06*uIntensity;          // faint laid sheen
    col += accentRamp(0.6)*lit*0.20*uIntensity; // window bloom
    col += vec3(0.8,0.78,0.74)*(ign(fragCoord)-0.5)*0.012; // paper grain
    col *= deckle*0.6 + 0.4;                     // deckle edges fall to bg
    col = col/(col + vec3(0.55));
    col *= 1.10;
  } else {
    // LIGHT: bright cream kozo in window light.
    vec3 kozo = mix(vec3(0.92, 0.89, 0.82), vec3(1.0, 0.98, 0.92), fib01);
    vec3 tint = accentRamp(0.3 + 0.06*fib01);
    col = mix(uBg, kozo, 0.7*uIntensity);
    col = mix(col, tint, 0.04*laid*uIntensity); // faint laid tint
    col = mix(col, tint*1.1, 0.18*lit*uIntensity); // window warmth
    col += vec3(0.5,0.46,0.4)*(ign(fragCoord)-0.5)*0.008; // paper grain
    col *= deckle*0.8 + 0.2;
    col = mix(col, uInk, smoothstep(0.4, 1.4, deckleR)*0.03*uIntensity); // deckle ink-edge
  }

  // Pointer halo: a soft warm disc where the cursor rests on the sheet.
  if (uPointerActive > 0.5){
    vec2 pp = (uPointer*uResolution - 0.5*uResolution)/uResolution.y;
    float dd = length(p - pp);
    col += accentRamp(0.45)*exp(-dd*dd*5.0)*0.10*breath;
  }

  // Final vignette to protect glass-type legibility.
  float vig = smoothstep(1.7, 0.3, length(p));
  col = mix(uBg, col, 0.45 + 0.55*vig);
  return col;
}
`});var Xo={};K(Xo,{createInkDiffusionKernel:()=>Gi});function Gi(){return g({id:"ink-diffusion",label:"Ink Diffusion",body:Fi})}var Fi,Yo=S(()=>{"use strict";N();Fi=`
// \u2500\u2500 Ink Diffusion \u2014 capillary chromatography bleed into wet fibre \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
vec3 renderKernel(vec2 uv, vec2 fragCoord) {
  float asp = uResolution.x / max(uResolution.y, 1.0);
  vec2 p = (uv - 0.5) * vec2(asp, 1.0);
  vec2 ptr = (uPointer - 0.5) * vec2(asp, 1.0);
  float t = uTime;

  // Paper-fibre feather field \u2014 a fine fbm that ragged-wicks every ink front and
  // also lays a faint laid-paper grain under the wash.
  float fibre = fbm(vec3(p * 5.5, t * 0.03));
  float grain = fbm(vec3(p * 22.0, 7.0)) * 0.5 + 0.5;

  // Accumulators: total ink (saturation) + a chromatographic hue index.
  float ink = 0.0;
  float hue = 0.0;
  float edge = 0.0;   // darkened wicking-rim accumulation

  // \u2500\u2500 N drifting ink drops, each a breathing capillary diffusion front \u2500\u2500
  // Two interleaved scales: broad primary bleeds + finer secondary micro-bleeds,
  // so the field reads as a continuous oil-on-paper wash, not discrete blobs.
  const int NDROP = 9;
  for (int i = 0; i < NDROP; i++) {
    float fi = float(i);
    bool micro = (i >= 5);                  // the last 4 are small micro-bleeds
    // slow value-noise drift of the drop centre (the damp sheet creeping).
    float spread = micro ? 0.5 : 0.4;
    vec2 c = spread * vec2(sin(fi * 2.39 + t * 0.05), cos(fi * 1.71 - t * 0.045));
    c += 0.06 * vec2(fbm(vec3(fi, t * 0.07, 0.0)), fbm(vec3(fi + 9.0, 0.0, t * 0.07)));

    // boundary radius eases outward then holds + trembles \u2014 ink still spreading.
    float grow = 0.5 + 0.5 * sin(fi * 1.3 + t * 0.18);
    float baseR = micro ? 0.07 : 0.15;
    float R = baseR + (micro ? 0.05 : 0.12) * grow + 0.012 * sin(t * 0.9 + fi * 3.0);

    // feather the distance by the fibre field \u2192 a ragged wicking boundary.
    float r = length(p - c) + (fibre - 0.5) * 0.09;

    float soft = (micro ? 0.06 : 0.10) + 0.05 * grow;
    float front = smoothstep(R, R - soft, r);             // wet wicked interior
    // darkened rim: a thin band piled just inside the advancing front.
    float rim = smoothstep(R, R - soft * 0.45, r) * (1.0 - smoothstep(R - soft * 0.5, R - soft, r));

    ink += front * (0.6 + 0.4 * grain) * (micro ? 0.7 : 1.0);
    edge += rim;
    // chromatographic separation: fast dye runs to the front (low sep), slow
    // pigment piles at the core (high sep) \u2192 hue indexes the ramp. Widened span
    // (\xD71.15) so the spectral separation reads, offset per drop so hues vary.
    float sep = clamp((R - r) / max(R, 1e-3), 0.0, 1.0);
    hue += front * fract(sep * 1.15 + fi * 0.17 + 0.05 * t);
  }

  // Pointer bloom \u2014 a fresh capillary wick from the cursor.
  {
    float r = length(p - ptr) + (fibre - 0.5) * 0.07;
    float R = 0.18;
    float front = uPointerActive * smoothstep(R, R - 0.12, r);
    ink += front;
    edge += uPointerActive * smoothstep(R, R - 0.05, r) * (1.0 - smoothstep(R - 0.06, R - 0.12, r));
    hue += front * fract(0.3 + 0.05 * t);
  }

  float sat = clamp(ink, 0.0, 1.0);
  float hueIdx = ink > 1e-3 ? fract(hue / max(ink, 1e-3)) : 0.0;
  vec3 inkCol = accentRamp(hueIdx);

  vec3 col;
  if (uTheme < 0.5) {
    // DARK \u2014 luminous ink suspended in a dark wash; fronts glow additively.
    vec3 wash = uBg + uBg * 0.4 * (grain - 0.5);
    vec3 bleed = inkCol * (0.5 + 0.7 * sat);
    bleed = mix(bleed, uAccent2, 0.18 * sat);            // cool running front
    col = wash + bleed * sat * uIntensity;
    col -= edge * 0.22 * uIntensity;                     // rim darkening (pigment pile)
    col = max(col, 0.0);
  } else {
    // LIGHT \u2014 sumi ink staining warm paper; source-over, capped.
    vec3 paper = mix(uBg, uBg * 0.96, grain - 0.5);
    vec3 stain = mix(inkCol, uInk, 0.55);                // ink reads dark on paper
    col = mix(paper, stain, clamp(sat, 0.0, 0.9));
    col -= edge * 0.16;                                  // darker wicking rim
    col = max(col, uInk * 0.0);
  }

  // Vignette \u2014 keeps foreground text legible.
  float vig = smoothstep(1.16, 0.26, length(p));
  col *= mix(0.62, 1.0, vig);

  return col;   // MAIN() appends dither() + clamps to [0,1]
}
`});var Qo={};K(Qo,{createPetroleumSheenKernel:()=>_i});function _i(){return g({id:"petroleum-sheen",label:"Petroleum Sheen",body:Ki})}var Ki,Jo=S(()=>{"use strict";N();Ki=`
// \u2500\u2500 Petroleum Sheen \u2014 computed thin-film interference on a flowing oil film \u2500\u2500
const float TAU = 6.28318530718;

// Three-wavelength thin-film interference (Belcour-Barla spectral core):
// reflectance per channel from the optical path difference opd (nm).
vec3 thinFilm(float opd) {
  vec3 lambda = vec3(680.0, 550.0, 440.0);   // R, G, B representative wavelengths
  vec3 phase = (TAU * opd) / lambda;
  vec3 r = 0.5 + 0.5 * cos(phase);            // first-order Airy term
  // a faint second harmonic crisps the filaments without muddying the hue.
  r += 0.12 * (0.5 + 0.5 * cos(2.0 * phase));
  return pow(clamp(r / 1.12, 0.0, 1.0), vec3(1.35));
}

vec3 renderKernel(vec2 uv, vec2 fragCoord) {
  float asp = uResolution.x / max(uResolution.y, 1.0);
  vec2 p = (uv - 0.5) * vec2(asp, 1.0);
  vec2 ptr = (uPointer - 0.5) * vec2(asp, 1.0);
  float t = uTime * 0.04;

  // \u2500\u2500 Oil film thickness field: two stacked domain warps \u2192 a marbled flow \u2500\u2500
  vec2 q = vec2(
    fbm(vec3(p * 1.6 + vec2(0.0, t), 0.0)),
    fbm(vec3(p * 1.6 + vec2(4.3, -t), 1.7))
  );
  vec2 r = vec2(
    fbm(vec3(p * 2.2 + 1.7 * q + vec2(t * 0.7, 0.0), 2.0)),
    fbm(vec3(p * 2.2 + 1.7 * q + vec2(0.0, -t * 0.6), 4.0))
  );
  float base = fbm(vec3(p * 1.9 + 2.0 * r, t * 0.3));
  base = 0.5 + 0.5 * base;

  // Pointer press \u2014 a thickness swell + an outgoing ring ripple (touching oil).
  float pd = length(p - ptr);
  base += uPointerActive * 0.45 * exp(-pd * pd * 10.0) * sin(pd * 20.0 - uTime * 3.0);

  // Map to a physical film thickness spanning several interference orders (nm).
  // Clamped to a positive floor so the OPD never implies a negative film.
  float thickness = clamp(120.0 + 1730.0 * clamp(base, 0.0, 1.0) + 360.0 * r.x, 80.0, 2200.0);

  // Incidence varies across the puddle (grazing toward the rim) \u2192 angle shift.
  float cosTheta = clamp(1.0 - 0.34 * length(p), 0.42, 1.0);

  // \u2500\u2500 Thin-film interference colour from the optical path difference \u2500\u2500
  float filmIOR = 1.32;                        // oil over water
  float opd = 2.0 * filmIOR * thickness * cosTheta;
  vec3 sheen = thinFilm(opd);

  // Rotate the spectral rainbow through the house accents (on-brand, still oil).
  float hueIdx = fract(opd / 1500.0 + 0.04 * t);
  vec3 tint = accentRamp(hueIdx);
  sheen = mix(sheen, sheen * (0.55 + 0.9 * tint), 0.5);

  // Fresnel grazing term brightens the rim; specular glint on the thinnest film.
  float fres = pow(1.0 - cosTheta, 3.0);
  float thinSpot = smoothstep(0.0, 0.18, 1.0 - clamp(thickness / 360.0, 0.0, 1.0));
  float glint = thinSpot * smoothstep(0.6, 1.0, base);

  vec3 col;
  if (uTheme < 0.5) {
    // DARK \u2014 sheen floats additively over deep oily water.
    vec3 deep = uBg + uBg * 0.35 * r.y;        // faint depth mottling
    col = deep + sheen * (0.42 + 0.6 * fres + 0.5 * base) * uIntensity;
    col += uAccent2 * glint * 0.5 * uIntensity; // wet specular glint
  } else {
    // LIGHT \u2014 a pale pearlescent puddle; capped so the canvas never blows out.
    vec3 pearl = mix(uBg, sheen, 0.42 + 0.30 * base);
    pearl = mix(pearl, uInk, 0.05 * (1.0 - base)); // settle deep film toward ink
    col = pearl;
    col += uAccent2 * glint * 0.16;
  }

  // Vignette \u2014 keeps foreground text legible.
  float vig = smoothstep(1.18, 0.28, length(p));
  col *= mix(0.6, 1.0, vig);

  return col;   // MAIN() appends dither() + clamps to [0,1]
}
`});var ir={};K(ir,{createBoidsKernel:()=>ji});function Wi(e){return .5+.5*(.62*Math.sin(2*Math.PI*e/Hi)+.38*Math.sin(2*Math.PI*e/zi+1.3))}function ji(){let e=null,t=0,o=0,a=1,i=null,s=!1,m=[],x={x:0,y:0,active:!1},b={y:0,vy:0,yMax:0},C=[7,8,15],w=1,T=1,h=new Int32Array(1),E=new Int32Array(0),I=[0,0];function U(){let l=t*o;return Math.max(Oi,Math.min(Ni,Math.round(l/Di)))}function _(l){l.x=Math.random()*t,l.y=Math.random()*o;let c=Math.random()*Math.PI*2,v=Ce.MIN+Math.random()*(Ce.MAX-Ce.MIN);l.vx=Math.cos(c)*v,l.vy=Math.sin(c)*v,l.bright=.5+Math.random()*.5}function D(){let l=U();m=new Array(l);for(let c=0;c<l;c++){let v={x:0,y:0,vx:0,vy:0,bright:1};_(v),m[c]=v}w=Math.max(1,Math.ceil(t/ye)),T=Math.max(1,Math.ceil(o/ye)),h=new Int32Array(w*T),E=new Int32Array(l)}function d(){e&&e.setTransform(a,0,0,a,0,0)}function n(l){e&&(e.fillStyle=J(C,l),e.fillRect(0,0,t,o))}function f(l){i=l,C=l.bg}function p(l){let c=i,v=c.accents,A=v.length||1,B=l/Vi%1*A,V=Math.floor(B)%A,$=B-Math.floor(B),j=v[V]??c.ink,X=v[(V+1)%A]??c.ink,Z=[j[0]+(X[0]-j[0])*$,j[1]+(X[1]-j[1])*$,j[2]+(X[2]-j[2])*$],W=c.ink;return[W[0]+(Z[0]-W[0])*.3,W[1]+(Z[1]-W[1])*.3,W[2]+(Z[2]-W[2])*.3]}function k(){if(!(!e||!i)){n(1);for(let l=0;l<90;l++)M(l*16,16,!1);M(90*16,16,!0)}}function P(){h.fill(-1);for(let l=0;l<m.length;l++){let c=m[l],v=c.x/ye|0,A=c.y/ye|0;v<0?v=0:v>=w&&(v=w-1),A<0?A=0:A>=T&&(A=T-1);let B=A*w+v;E[l]=h[B],h[B]=l}}function M(l,c,v){if(!e||!i)return;let A=Math.min(c,32)/16,B=Wi(l),V=Ui*(.7+.6*B),$=.9+.2*B,j=b.vy,X=Math.min(Math.abs(j)/120,1),Z=j!==0?Math.sign(j)*Math.min(Math.abs(j)/bt.GUST_K,bt.GUST):0,W=Ce.MAX*$*(1+X*bt.SPEED_BOOST),Y=Ce.MIN,Q=i.theme==="light",ee=i.intensity,R=Q?.44:.46,we=l*qi,xe=ye*ye,me=Zo*Zo,se=C;v&&(se=p(l),e.lineCap="round"),P();for(let pe=0;pe<m.length;pe++){let r=m[pe],u=0,y=0,L=0,O=0,H=0,ce=0,te=0,Te=Math.min(w-1,Math.max(0,r.x/ye|0)),be=Math.min(T-1,Math.max(0,r.y/ye|0)),tt=Te>0?Te-1:0,ur=Te<w-1?Te+1:w-1,fr=be>0?be-1:0,dr=be<T-1?be+1:T-1;for(let z=fr;z<=dr&&te<vt;z++)for(let ue=tt;ue<=ur&&te<vt;ue++)for(let le=h[z*w+ue];le!==-1;le=E[le]){if(le===pe)continue;let re=m[le],he=re.x-r.x,Le=re.y-r.y,Me=he*he+Le*Le;if(!(Me>=xe||Me===0)){if(te++,L+=re.vx,O+=re.vy,H+=he,ce+=Le,Me<me){let ze=1/Math.sqrt(Me);u-=he*ze,y-=Le*ze}if(te>=vt)break}}let ne=0,oe=0;if(te>0){let z=1/te;ne+=(L*z-r.vx)*$e,oe+=(O*z-r.vy)*$e,ne+=H*z*er,oe+=ce*z*er,ne+=u*$o,oe+=y*$o}Qe(r.x*or,r.y*or,we,I),ne+=(I[0]*Ce.MAX-r.vx)*$e*V,oe+=(I[1]*Ce.MAX-r.vy)*$e*V;let yt=Math.sqrt(ne*ne+oe*oe);if(yt>rr){let z=rr/yt;ne*=z,oe*=z}if(x.active){let z=r.x-x.x,ue=r.y-x.y,le=z*z+ue*ue;if(le<ke.R*ke.R&&le>0){let re=Math.sqrt(le),he=Math.pow((ke.R-re)/ke.R,ke.FALLOFF);ne+=z/re*he*ke.STRENGTH,oe+=ue/re*he*ke.STRENGTH}}r.x<ae.MARGIN?ne+=ae.TURN*(1-r.x/ae.MARGIN):r.x>t-ae.MARGIN&&(ne-=ae.TURN*(1-(t-r.x)/ae.MARGIN)),r.y<ae.MARGIN?oe+=ae.TURN*(1-r.y/ae.MARGIN):r.y>o-ae.MARGIN&&(oe-=ae.TURN*(1-(o-r.y)/ae.MARGIN)),oe+=Z,ne+=(Math.random()-.5)*tr,oe+=(Math.random()-.5)*tr,r.vx+=ne*A,r.vy+=oe*A;let He=Math.sqrt(r.vx*r.vx+r.vy*r.vy)||1e-6;if(He>W){let z=W/He;r.vx*=z,r.vy*=z}else if(He<Y){let z=Y/He;r.vx*=z,r.vy*=z}if(r.x+=r.vx*A,r.y+=r.vy*A,v){let z=Math.sqrt(r.vx*r.vx+r.vy*r.vy)||1e-6,ue=r.vx/z,le=r.vy/z,re=2+r.bright*1.8+z/W*1.4,he=Math.min(R*r.bright*ee,1),Le=r.x-ue*re*.45,Me=r.y-le*re*.45,ze=r.x+ue*re*.55,mr=r.y+le*re*.55;e.lineWidth=.9+r.bright*.5,e.strokeStyle=J(se,he),e.beginPath(),e.moveTo(Le,Me),e.lineTo(ze,mr),e.stroke()}}}return{id:"boids",label:"Boids",substrate:"2d",init(l,c){e=l,t=c.width,o=c.height,a=c.dpr,s=c.reducedMotion,f(c.palette),d(),e.lineCap="round",e.lineJoin="round",n(1),D(),s&&k()},frame(l,c){if(!e)return;let v=i?.theme==="light";n(v?.22:.19),M(l,c,!0)},resize(l){t=l.width,o=l.height,a=l.dpr,d(),e.lineCap="round",e.lineJoin="round",n(1),D(),s&&k()},setTheme(l,c){f(c),n(1)},pointer(l,c,v){x={x:l,y:c,active:v}},scroll(l,c,v){b={y:l,vy:c,yMax:v}},renderStatic(){k()},dispose(){e=null,m=[]}}}var ye,Zo,vt,Di,Oi,Ni,$o,$e,er,Ui,tr,or,qi,Ce,rr,ae,Hi,zi,ke,bt,Vi,nr=S(()=>{"use strict";lt();Be();ye=78,Zo=13,vt=16,Di=340,Oi=520,Ni=1600,$o=.9,$e=.09,er=6e-4,Ui=.75,tr=.03,or=.0014,qi=5e-5,Ce={MIN:.9,MAX:2.35},rr=.3,ae={MARGIN:90,TURN:.16},Hi=14e3,zi=31e3;ke={R:230,STRENGTH:.6,FALLOFF:1.25},bt={GUST:.5,GUST_K:70,SPEED_BOOST:.55},Vi=44e3});We();Be();Be();var Ae=Math.PI*2;function Lt(e,t){let o=e.accents;return o[t%o.length]}function Mt(){let e=null,t=0,o=0,a=1,i=null,s=!1,m=[],x=[],b={x:0,y:0,active:!1},C=0;function w(){e&&e.setTransform(a,0,0,a,0,0)}function T(){let d=t*o,n=Math.max(3,Math.min(6,Math.round(d/38e4))),f=Math.max(60,Math.min(160,Math.round(d/9e3)));return{clouds:n,stars:f}}function h(){let d=T();m=[];for(let n=0;n<d.clouds;n++){let f=Math.min(t,o)*.32*(.7+Math.random()*.55);m.push({hx:Math.random(),hy:Math.random(),vx:(Math.random()-.5)*.004,vy:(Math.random()-.5)*.003,r:f,accent:n%4,phase:Math.random()*Ae,weight:.6+Math.random()*.5})}x=[];for(let n=0;n<d.stars;n++)x.push({nx:Math.random(),ny:Math.random(),r:.5+Math.random()*1.1,phase:Math.random()*Ae,rate:.4+Math.random()*1.2,accent:Math.floor(Math.random()*4),a:.18+Math.random()*.32})}function E(d){!e||!i||(e.globalCompositeOperation="source-over",e.fillStyle=J(i.bg,d),e.fillRect(0,0,t,o))}function I(d,n,f,p){if(!e||!i)return;let k=i.theme==="light",P=Lt(i,d.accent),M=d.r*(.9+.12*p),l=(k?.1:.14)*d.weight*(.7+.3*p)*i.intensity,c=e.createRadialGradient(n,f,0,n,f,M),v=k?Re(P,i.bg,.35):P;c.addColorStop(0,J(v,l)),c.addColorStop(.55,J(P,l*.45)),c.addColorStop(1,J(P,0)),e.globalCompositeOperation=k?"source-over":"lighter",e.fillStyle=c,e.beginPath(),e.arc(n,f,M,0,Ae),e.fill()}function U(d,n){if(!e||!i)return;let f=i.theme==="light",p=Lt(i,d.accent),k=.55+.45*n,P=d.a*k*i.intensity,M=d.nx*t,l=d.ny*o,c=d.r*k;if(f){e.globalCompositeOperation="source-over",e.fillStyle=J(Re(p,i.ink,.5),P*.7),e.beginPath(),e.arc(M,l,c,0,Ae),e.fill();return}if(e.globalCompositeOperation="lighter",c>1){let v=e.createRadialGradient(M,l,0,M,l,c*3.2);v.addColorStop(0,J(p,P*.5)),v.addColorStop(1,J(p,0)),e.fillStyle=v,e.beginPath(),e.arc(M,l,c*3.2,0,Ae),e.fill()}e.fillStyle=J(Re(p,[255,255,255],.45),P),e.beginPath(),e.arc(M,l,c,0,Ae),e.fill()}function _(){if(!e||!i)return;let d=i.theme==="light";E(d?.32:.26);for(let n of m){let f=.5+.5*Math.sin(C*.18+n.phase),p=n.hx*t,k=n.hy*o;if(b.active){let P=p-b.x,M=k-b.y,l=Math.hypot(P,M),c=Math.min(t,o)*.45;if(l<c){let v=(1-l/c)*14;p+=P/(l||1)*v,k+=M/(l||1)*v}}I(n,p,k,f)}for(let n of x){let f=.5+.5*Math.sin(C*n.rate+n.phase);U(n,f)}e.globalCompositeOperation="source-over"}function D(){if(!(!e||!i)){E(1);for(let d of m)I(d,d.hx*t,d.hy*o,.6);for(let d of x)U(d,.7);e.globalCompositeOperation="source-over"}}return{id:"constellation",label:"Constellation",substrate:"2d",init(d,n){e=d,t=n.width,o=n.height,a=n.dpr,i=n.palette,s=n.reducedMotion,w(),h(),E(1),s&&D()},frame(d,n){if(!e||!i)return;let f=Math.min(n,32)/1e3;C+=f;for(let p of m)p.hx+=p.vx*f*60,p.hy+=p.vy*f*60,p.hx>1.15&&(p.hx=-.15),p.hx<-.15&&(p.hx=1.15),p.hy>1.15&&(p.hy=-.15),p.hy<-.15&&(p.hy=1.15);_()},resize(d){t=d.width,o=d.height,a=d.dpr,w(),E(1),h(),s&&D()},setTheme(d,n){i=n,E(1),s&&D()},pointer(d,n,f){b.x=d,b.y=n,b.active=f},click(d,n){if(!e||!i)return;let f=i.accents[0];e.globalCompositeOperation=i.theme==="light"?"source-over":"lighter";let k=e.createRadialGradient(d,n,8,d,n,90);k.addColorStop(0,J(f,0)),k.addColorStop(.6,J(f,.12*i.intensity)),k.addColorStop(1,J(f,0)),e.fillStyle=k,e.beginPath(),e.arc(d,n,90,0,Ae),e.fill(),e.globalCompositeOperation="source-over"},wake(d,n,f,p,k,P){let M=k*2.4;for(let l of m){let c=l.hx*t,v=l.hy*o,A=Math.hypot(c-d,v-n);if(A<M){let B=(1-A/M)*9e-4;l.vx+=f*B,l.vy+=p*B,l.vx*=.985,l.vy*=.985}}},obstacles(d){},renderStatic(){D()},dispose(){e=null,m=[],x=[]}}}function G(e,t,o,a){let i=null,s=null,m=!1,x=null,b=!1;function C(){return i?Promise.resolve(i):(s||(s=a().then(w=>m?(s=null,null):(i=w(),x&&(i.init(x.ctx,x.frame),x=null),b&&(i.renderStatic?.(),b=!1),s=null,i))),s)}return{id:e,label:t,substrate:o,init(w,T){x={ctx:w,frame:T},C()},frame(w,T){i?.frame(w,T)},resize(w){i?.resize(w)},setTheme(w,T){i?.setTheme(w,T)},pointer(w,T,h){i?.pointer?.(w,T,h)},click(w,T){i?.click?.(w,T)},obstacles(w){i?.obstacles?.(w)},scroll(w,T,h){i?.scroll?.(w,T,h)},renderStatic(){i?i.renderStatic?.():b=!0},dispose(){m=!0,b=!1,i?.dispose(),i=null,s=null,x=null}}}var Ie=[{id:"constellation",label:"Constellation",blurb:"Provider marks assemble from the swarm, then whirl off.",substrate:"2d",create:Mt},{id:"flow",label:"Flow Field",blurb:"A curl-noise wind drawn as silky streamlines.",substrate:"2d",create:()=>G("flow","Flow Field","2d",()=>Promise.resolve().then(()=>(Nt(),Ot)).then(e=>e.createFlowFieldKernel))},{id:"aurora",label:"Aurora",blurb:"Domain-warped light, drifting in slow ribbons.",substrate:"webgl2",create:()=>G("aurora","Aurora","webgl2",()=>Promise.resolve().then(()=>(Xt(),jt)).then(e=>e.createAuroraKernel))},{id:"mesh",label:"Iridescent Mesh",blurb:"A living gradient mesh with fine grain.",substrate:"webgl2",create:()=>G("mesh","Iridescent Mesh","webgl2",()=>Promise.resolve().then(()=>(Qt(),Yt)).then(e=>e.createMeshKernel))},{id:"moire",label:"Moir\xE9",blurb:"Light interfering through a breathing crystal lattice.",substrate:"webgl2",create:()=>G("moire","Moir\xE9","webgl2",()=>Promise.resolve().then(()=>(Zt(),Jt)).then(e=>e.createMoireKernel))},{id:"volumetric",label:"Volumetric",blurb:"Crepuscular shafts of light through an unseen medium.",substrate:"webgl2",create:()=>G("volumetric","Volumetric","webgl2",()=>Promise.resolve().then(()=>(eo(),$t)).then(e=>e.createVolumetricKernel))},{id:"lic",label:"Flow Imaging",blurb:"The same wind as Flow, rendered as honest silk.",substrate:"webgl2",create:()=>G("lic","Flow Imaging","webgl2",()=>Promise.resolve().then(()=>(io(),ro)).then(e=>e.createLicKernel))},{id:"fluid-aurora",label:"Fluid Aurora",blurb:"Domain-warped fluid ribbons \u2014 the 2026 mainstream background standard.",substrate:"webgl2",create:()=>G("fluid-aurora","Fluid Aurora","webgl2",()=>Promise.resolve().then(()=>(lo(),no)).then(e=>e.createFluidAuroraKernel))},{id:"cloudfield",label:"Cloud Field",blurb:"Raymarched cloudscape from a 280-char demoscene kernel \u2014 infinite sky.",substrate:"webgl2",create:()=>G("cloudfield","Cloud Field","webgl2",()=>Promise.resolve().then(()=>(so(),ao)).then(e=>e.createCloudFieldKernel))},{id:"plasma-orbs",label:"Plasma Orbs",blurb:"Five glassy metaball orbs drift, fuse, and refract \u2014 2026's chrome-orb standard.",substrate:"webgl2",create:()=>G("plasma-orbs","Plasma Orbs","webgl2",()=>Promise.resolve().then(()=>(uo(),co)).then(e=>e.createPlasmaOrbsKernel))},{id:"blobs-mesh",label:"Blobs Mesh",blurb:"Four softly-blending blobs of palette color drift through simplex noise \u2014 the 2026 fluid-mesh-gradient standard.",substrate:"webgl2",create:()=>G("blobs-mesh","Blobs Mesh","webgl2",()=>Promise.resolve().then(()=>(mo(),fo)).then(e=>e.createBlobsMeshKernel))},{id:"retro-plasma",label:"Retro Plasma",blurb:"Future Crew's 1993 four-sine plasma \u2014 the canonical demoscene fragment shader, ported verbatim.",substrate:"webgl2",create:()=>G("retro-plasma","Retro Plasma","webgl2",()=>Promise.resolve().then(()=>(ho(),po)).then(e=>e.createRetroPlasmaKernel))},{id:"inversion-lattice",label:"Inversion Lattice",blurb:"A 2D Apollonian circle-inversion fractal \u2014 infinitely-nested luminous rings.",substrate:"webgl2",create:()=>G("inversion-lattice","Inversion Lattice","webgl2",()=>Promise.resolve().then(()=>(bo(),vo)).then(e=>e.createInversionLatticeKernel))},{id:"vogel-bloom",label:"Vogel Bloom",blurb:"A golden-angle phyllotaxis seed field \u2014 a slowly rotating sunflower head of glowing dots.",substrate:"webgl2",create:()=>G("vogel-bloom","Vogel Bloom","webgl2",()=>Promise.resolve().then(()=>(yo(),go)).then(e=>e.createVogelBloomKernel))},{id:"crystal-drift",label:"Crystal Drift",blurb:"Drifting Voronoi glass cells with glowing palette seams.",substrate:"webgl2",create:()=>G("crystal-drift","Crystal Drift","webgl2",()=>Promise.resolve().then(()=>(xo(),wo)).then(e=>e.createCrystalDriftKernel))},{id:"ripple-lattice",label:"Ripple Lattice",blurb:"A breathing dot lattice that ripples with concentric sonar waves under the cursor.",substrate:"webgl2",create:()=>G("ripple-lattice","Ripple Lattice","webgl2",()=>Promise.resolve().then(()=>(Ro(),To)).then(e=>e.createRippleLatticeKernel))},{id:"liquid-lumen",label:"Liquid Lumen",blurb:"Many small charges fuse into one flowing lava-lamp color field.",substrate:"webgl2",create:()=>G("liquid-lumen","Liquid Lumen","webgl2",()=>Promise.resolve().then(()=>(Eo(),Ao)).then(e=>e.createLiquidLumenKernel))},{id:"spectral-drift",label:"Spectral Drift",blurb:"Oriented ribbons of band-limited Gabor noise \u2014 brushed-metal grain that combs around the pointer.",substrate:"webgl2",create:()=>G("spectral-drift","Spectral Drift","webgl2",()=>Promise.resolve().then(()=>(Co(),So)).then(e=>e.createSpectralDriftKernel))},{id:"mycelium-mesh",label:"Mycelium Mesh",blurb:"Domain-warped ridged-fbm veins knit a breathing mycelial network that reaches toward the cursor.",substrate:"webgl2",create:()=>G("mycelium-mesh","Mycelium Mesh","webgl2",()=>Promise.resolve().then(()=>(Io(),ko)).then(e=>e.createMyceliumMeshKernel))},{id:"oilfield",label:"Oilfield",blurb:"A living painting: an fbm color field flattened into oil-paint brush patches by a Kuwahara filter.",substrate:"webgl2",create:()=>G("oilfield","Oilfield","webgl2",()=>Promise.resolve().then(()=>(Lo(),Po)).then(e=>e.createOilfieldKernel))},{id:"suminagashi-drift",label:"Suminagashi Drift",blurb:"Closed-form ink-on-water marbling \u2014 drifting drops raked by combs into swirled marble bands.",substrate:"webgl2",create:()=>G("suminagashi-drift","Suminagashi Drift","webgl2",()=>Promise.resolve().then(()=>(Bo(),Mo)).then(e=>e.createSuminagashiDriftKernel))},{id:"kinetic-stipple",label:"Kinetic Stipple",blurb:"A curl-noise wind streams an advected density as discrete, variable-size stipple dots.",substrate:"webgl2",create:()=>G("kinetic-stipple","Kinetic Stipple","webgl2",()=>Promise.resolve().then(()=>(Go(),Fo)).then(e=>e.createKineticStippleKernel))},{id:"agent1",label:"Agent 1",blurb:"Domain-warped generative mesh fluid \u2014 organic color blobs drift and merge like liquid silk.",substrate:"webgl2",create:()=>G("agent1","Agent 1","webgl2",()=>Promise.resolve().then(()=>(_o(),Ko)).then(e=>e.createAgent1Kernel))},{id:"neural-bloom",label:"Neural Bloom",blurb:"Latent FBM fed through a tiny MLP palette network \u2014 an organic, ever-shifting AI-generated colour field.",substrate:"webgl2",create:()=>G("neural-bloom","Neural Bloom","webgl2",()=>Promise.resolve().then(()=>(Oo(),Do)).then(e=>e.createNeuralBloomKernel))},{id:"aether-lattice",label:"Aether Lattice",blurb:"Quasicrystal interference modulates a volumetric medium \u2014 luminous, aperiodic lattice shafts breathe through the fog.",substrate:"webgl2",create:()=>G("aether-lattice","Aether Lattice","webgl2",()=>Promise.resolve().then(()=>(Uo(),No)).then(e=>e.createAetherLatticeKernel))},{id:"bat-signal",label:"Beacon",blurb:"A sweeping searchlight beam catches the provider emblem on a low cloud bank \u2014 volumetric god-rays, lens bloom, drifting dust.",substrate:"webgl2",create:()=>G("bat-signal","Beacon","webgl2",()=>Promise.resolve().then(()=>(Ho(),qo)).then(e=>e.createBeamProjectorKernel))},{id:"storm-signal",label:"Tempest",blurb:"A charged slate storm cell billows behind the emblem \u2014 rolling mesocyclone mass with intermittent sheet and fork lightning.",substrate:"webgl2",create:()=>G("storm-signal","Tempest","webgl2",()=>Promise.resolve().then(()=>(Wo(),zo)).then(e=>e.createStormCellKernel))},{id:"origami",label:"Origami",blurb:"A hand-made kozo paper sheet \u2014 warm fibers, laid lines, a deckle edge \u2014 the quiet stage for folded, cut, washed, and quilled marks.",substrate:"webgl2",create:()=>G("origami","Origami","webgl2",()=>Promise.resolve().then(()=>(jo(),Vo)).then(e=>e.createPaperfieldKernel))},{id:"ink-diffusion",label:"Ink Diffusion",blurb:"Ink wicks into wet fibre \u2014 capillary chromatography fronts bleed, darken at the rim, and separate into spectral halos.",substrate:"webgl2",create:()=>G("ink-diffusion","Ink Diffusion","webgl2",()=>Promise.resolve().then(()=>(Yo(),Xo)).then(e=>e.createInkDiffusionKernel))},{id:"petroleum-sheen",label:"Petroleum Sheen",blurb:"Computed thin-film interference on a flowing oil film \u2014 nested oil-slick rainbows drift and marble over deep water.",substrate:"webgl2",create:()=>G("petroleum-sheen","Petroleum Sheen","webgl2",()=>Promise.resolve().then(()=>(Jo(),Qo)).then(e=>e.createPetroleumSheenKernel))},{id:"boids",label:"Boids",blurb:"A living murmuration \u2014 hundreds of birds flocking as one.",substrate:"2d",create:()=>G("boids","Boids","2d",()=>Promise.resolve().then(()=>(nr(),ir)).then(e=>e.createBoidsKernel))}],Pe="constellation",vl=Ie.map(({create:e,...t})=>t);function gt(e){return Ie.find(t=>t.id===e)??Ie[0]}function Ne(e){return!!e&&Ie.some(t=>t.id===e)}var lr=700,ar={"2d":2,webgl2:1.2,webgpu:1};function Xi(){try{let t=document.createElement("canvas").getContext("webgl2");if(!t)return{supported:!1,caps:{colorBufferFloat:!1,floatBlend:!1}};let o=xt(t);return t.getExtension("WEBGL_lose_context")?.loseContext(),{supported:!0,caps:o}}catch{return{supported:!1,caps:{colorBufferFloat:!1,floatBlend:!1}}}}var et=class{constructor(t,o){F(this,"glSupported");F(this,"glCaps");F(this,"container");F(this,"slots",[]);F(this,"activeId");F(this,"theme");F(this,"palette");F(this,"onResolve");F(this,"width",0);F(this,"height",0);F(this,"tMs",0);F(this,"lastNow",0);F(this,"raf",null);F(this,"visible",!0);F(this,"pageVisible",!0);F(this,"reducedMotion",!1);F(this,"pointer",{x:0,y:0,active:!1});F(this,"glyphField",null);F(this,"scroll",{y:0,vy:0,yMax:0});F(this,"scrollDelta",0);F(this,"lastHarvest",-1e9);F(this,"resizeObs",null);F(this,"intersectionObs",null);F(this,"mql",null);F(this,"initialHarvestRaf",null);F(this,"initialHarvestTimer",null);F(this,"onVisibility",()=>{this.pageVisible=!document.hidden});F(this,"onPointerMove",t=>{let o=this.container.getBoundingClientRect();this.pointer.x=t.clientX-o.left,this.pointer.y=t.clientY-o.top,this.pointer.active=!0;for(let a of this.slots)a.kernel.pointer?.(this.pointer.x,this.pointer.y,!0)});F(this,"onPointerOut",()=>{this.pointer.active=!1;for(let t of this.slots)t.kernel.pointer?.(this.pointer.x,this.pointer.y,!1)});F(this,"onClick",t=>{if(t.target?.closest?.("a, button, input, textarea, select, label, [role='button'],.glass-frost, .glass-refract, .glass-pill, .studio-switcher"))return;let a=this.container.getBoundingClientRect(),i=t.clientX-a.left,s=t.clientY-a.top;for(let m of this.slots)m.outgoing||m.kernel.click?.(i,s)});F(this,"onScroll",t=>{let o=t.target;if(o!==document&&o!==document.documentElement)return;let a=window.scrollY||window.pageYOffset||0,i=a-this.scroll.y,s=document.documentElement;this.scroll.y=a,this.scroll.yMax=Math.max(0,(s?.scrollHeight??0)-window.innerHeight),this.scrollDelta+=i,this.harvestObstacles()});F(this,"onReducedMotionChange",t=>{if(this.reducedMotion=t.matches,t.matches){this.raf!==null&&(cancelAnimationFrame(this.raf),this.raf=null);for(let o of this.slots)o.kernel.renderStatic?.()}else this.raf===null&&this.startLoop()});this.container=t;let a=Xi();this.glSupported=a.supported,this.glCaps=a.caps,this.theme=o.theme,this.palette=Ve(o.theme),this.onResolve=o.onResolve,this.activeId=o.initialKernel??Pe,this.reducedMotion=typeof window<"u"&&window.matchMedia("(prefers-reduced-motion: reduce)").matches;let i=t.getBoundingClientRect();this.width=i.width||window.innerWidth,this.height=i.height||window.innerHeight,this.mountInitial(),this.attachObservers(),this.reducedMotion||this.startLoop()}setKernel(t){let o=this.resolveId(t);if(o===this.activeId&&this.slots.some(i=>i.id===o&&!i.outgoing))return;this.finalizeOutgoing();for(let i of this.slots)i.outgoing=!0,i.canvas.style.opacity="0",i.disposeTimer=window.setTimeout(()=>this.disposeSlot(i),lr+80);let a=this.createSlot(o);this.activeId=a.id,this.onResolve?.(a.id),this.harvestObstacles(!0),requestAnimationFrame(()=>{a.canvas.style.opacity="1"}),this.reducedMotion&&a.kernel.renderStatic?.()}setTheme(t){if(t!==this.theme){this.theme=t,this.palette=Ve(t);for(let o of this.slots)o.kernel.setTheme(t,this.palette),this.reducedMotion&&o.kernel.renderStatic?.()}}refreshPalette(){this.palette=Ve(this.theme);for(let t of this.slots)t.kernel.setTheme(this.theme,this.palette),this.reducedMotion&&t.kernel.renderStatic?.()}getResolvedKernel(){return this.activeId}wake(t,o,a,i,s,m){for(let x of this.slots)x.outgoing||x.kernel.wake?.(t,o,a,i,s,m)}setGlyphField(t){this.glyphField=t;for(let o of this.slots)o.kernel.setGlyphField?.(t)}destroy(){this.raf!==null&&cancelAnimationFrame(this.raf),this.initialHarvestRaf!==null&&cancelAnimationFrame(this.initialHarvestRaf),this.initialHarvestTimer!==null&&clearTimeout(this.initialHarvestTimer),this.resizeObs?.disconnect(),this.intersectionObs?.disconnect(),document.removeEventListener("visibilitychange",this.onVisibility),window.removeEventListener("pointermove",this.onPointerMove),window.removeEventListener("pointerout",this.onPointerOut),window.removeEventListener("scroll",this.onScroll,!0),window.removeEventListener("click",this.onClick),this.mql?.removeEventListener("change",this.onReducedMotionChange);for(let t of[...this.slots])this.disposeSlot(t);this.slots=[]}resolveId(t){let o=gt(t);return o.substrate==="webgl2"&&!this.glSupported?Pe:o.requiresFloatTex&&!this.glCaps.colorBufferFloat?o.fallbackId??Pe:(o.requiresWebGPU||o.substrate==="webgpu")&&typeof navigator<"u"&&!("gpu"in navigator)?o.fallbackId??Pe:o.id}mountInitial(){let t=this.createSlot(this.resolveId(this.activeId));this.activeId=t.id,t.canvas.style.opacity="1",this.onResolve?.(t.id),this.reducedMotion&&t.kernel.renderStatic?.()}frameCtx(t){let o=Math.min(window.devicePixelRatio||1,ar[t]);return{width:this.width,height:this.height,dpr:o,theme:this.theme,palette:this.palette,reducedMotion:this.reducedMotion,caps:this.glCaps}}sizeCanvas(t){let o=Math.min(window.devicePixelRatio||1,ar[t.substrate]);t.canvas.width=Math.max(1,Math.round(this.width*o)),t.canvas.height=Math.max(1,Math.round(this.height*o)),t.canvas.style.width=`${this.width}px`,t.canvas.style.height=`${this.height}px`}createSlot(t,o=0){let i=gt(t).create(),s=i.substrate,m=document.createElement("canvas");m.setAttribute("aria-hidden","true"),m.style.cssText=`position:absolute;inset:0;display:block;opacity:0;transition:opacity ${lr}ms ease;will-change:opacity;`,this.container.appendChild(m);let x={id:i.id,canvas:m,kernel:i,substrate:s,outgoing:!1,disposeTimer:null};this.sizeCanvas(x),this.slots.push(x);let b=null;if(s==="webgpu"){if(b=m.getContext("webgpu"),!b)return this.disposeSlot(x),o<2?this.createSlot(Pe,o+1):x}else if(s==="webgl2"){if(b=m.getContext("webgl2",{alpha:!0,antialias:!1,depth:!1,stencil:!1,premultipliedAlpha:!0,powerPreference:"high-performance",preserveDrawingBuffer:!1}),!b)return this.disposeSlot(x),o<2?this.createSlot(Pe,o+1):x}else if(b=m.getContext("2d",{alpha:!0}),!b)return this.disposeSlot(x),x;return i.init(b,this.frameCtx(s)),this.glyphField&&i.setGlyphField?.(this.glyphField),x}disposeSlot(t){t.disposeTimer!==null&&(clearTimeout(t.disposeTimer),t.disposeTimer=null);try{t.kernel.dispose()}catch{}t.canvas.parentNode&&t.canvas.parentNode.removeChild(t.canvas),this.slots=this.slots.filter(o=>o!==t)}finalizeOutgoing(){for(let t of[...this.slots])t.outgoing&&this.disposeSlot(t)}startLoop(){this.lastNow=performance.now();let t=o=>{if(this.raf=requestAnimationFrame(t),!this.visible||!this.pageVisible){this.lastNow=o;return}let a=Math.min(o-this.lastNow,32);if(this.lastNow=o,this.tMs+=a,this.scroll.vy=this.scroll.vy*.82+this.scrollDelta*.18,this.scrollDelta=0,this.scroll.vy>120?this.scroll.vy=120:this.scroll.vy<-120&&(this.scroll.vy=-120),Math.abs(this.scroll.vy)<.05&&(this.scroll.vy=0),this.scroll.vy!==0)for(let i of this.slots)i.kernel.scroll?.(this.scroll.y,this.scroll.vy,this.scroll.yMax);for(let i of this.slots)i.kernel.frame(this.tMs,a)};this.raf=requestAnimationFrame(t)}attachObservers(){this.resizeObs=new ResizeObserver(t=>{let o=t[0];if(!o)return;let{width:a,height:i}=o.contentRect;if(!(a===0||i===0)){this.width=a,this.height=i;for(let s of this.slots)this.sizeCanvas(s),s.kernel.resize(this.frameCtx(s.substrate));this.harvestObstacles(!0)}}),this.resizeObs.observe(this.container),this.initialHarvestRaf=requestAnimationFrame(()=>this.harvestObstacles(!0)),this.initialHarvestTimer=window.setTimeout(()=>this.harvestObstacles(!0),700),this.intersectionObs=new IntersectionObserver(t=>{this.visible=t[0]?.isIntersecting??!0},{threshold:0}),this.intersectionObs.observe(this.container),document.addEventListener("visibilitychange",this.onVisibility),window.addEventListener("pointermove",this.onPointerMove,{passive:!0}),window.addEventListener("pointerout",this.onPointerOut,{passive:!0}),window.addEventListener("scroll",this.onScroll,{passive:!0,capture:!0}),window.addEventListener("click",this.onClick,{passive:!0}),this.mql=window.matchMedia("(prefers-reduced-motion: reduce)"),this.mql.addEventListener("change",this.onReducedMotionChange)}harvestObstacles(t=!1){let o=typeof performance<"u"?performance.now():0;if(!t&&o-this.lastHarvest<150||(this.lastHarvest=o,!this.slots.some(b=>!b.outgoing&&b.kernel.obstacles)))return;let i=this.container.getBoundingClientRect(),s=window.innerHeight,m=document.querySelectorAll(".glass-frost, .glass-refract, h1, h2"),x=[];m.forEach(b=>{if(x.length>=24)return;let C=b.getBoundingClientRect();C.width<8||C.height<8||C.bottom<-140||C.top>s+140||x.push({x:C.left-i.left,y:C.top-i.top,w:C.width,h:C.height})});for(let b of this.slots)b.outgoing||b.kernel.obstacles?.(x)}};var sr="fluid-aurora";function Yi(){try{let e=(location.hash||"").replace(/^#/,"").trim();if(Ne(e))return e;let t=new URLSearchParams(location.search).get("kernel");if(Ne(t))return t}catch{}return Ne(sr)?sr:Ie[0].id}function cr(){let e=document.getElementById("host");e||(e=document.createElement("div"),e.id="host",document.body.appendChild(e)),e.style.position="fixed",e.style.inset="0",e.style.width="100%",e.style.height="100%",e.style.overflow="hidden";let t=new et(e,{theme:"dark",initialKernel:Yi()});window.__setKernel=o=>Ne(o)?(t.setKernel(o),!0):!1,window.__setTheme=o=>{(o==="dark"||o==="light")&&t.setTheme(o)},window.__getKernel=()=>t.getResolvedKernel(),window.__kernels=Ie.map(o=>({id:o.id,label:o.label,blurb:o.blurb,substrate:o.substrate})),window.__backdropReady=!0,window.addEventListener("hashchange",()=>{let o=(location.hash||"").replace(/^#/,"").trim();Ne(o)&&t.setKernel(o)})}document.readyState==="loading"?document.addEventListener("DOMContentLoaded",cr,{once:!0}):cr();})();

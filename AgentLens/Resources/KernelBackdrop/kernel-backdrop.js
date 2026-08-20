/* GENERATED FILE — do not edit by hand. Built from tools/kernel-backdrop/entry.ts + packages/gl-engine/src/engine/. Regenerate: node scripts/build-kernel-backdrop.mjs */
(()=>{var f1=Object.defineProperty;var M2=(t,e,o)=>e in t?f1(t,e,{enumerable:!0,configurable:!0,writable:!0,value:o}):t[e]=o;var O=(t,e)=>()=>(t&&(e=t(t=0)),e);var Y=(t,e)=>{for(var o in e)f1(t,o,{get:e[o],enumerable:!0})};var v=(t,e,o)=>M2(t,typeof e!="symbol"?e+"":e,o);function p1(t){let e=!!t.getExtension("EXT_color_buffer_float"),o=!1;if(e){let r=t.createTexture(),n=t.createFramebuffer();r&&n&&(t.bindTexture(t.TEXTURE_2D,r),t.texStorage2D(t.TEXTURE_2D,1,t.RGBA16F,1,1),t.bindFramebuffer(t.FRAMEBUFFER,n),t.framebufferTexture2D(t.FRAMEBUFFER,t.COLOR_ATTACHMENT0,t.TEXTURE_2D,r,0),o=t.checkFramebufferStatus(t.FRAMEBUFFER)===t.FRAMEBUFFER_COMPLETE,t.bindFramebuffer(t.FRAMEBUFFER,null)),r&&t.deleteTexture(r),n&&t.deleteFramebuffer(n)}return{colorBufferFloat:o,floatBlend:!!t.getExtension("EXT_float_blend")}}function h1(t,e,o){return e==="RG16F"?{internalFormat:t.RG16F,format:t.RG,type:t.HALF_FLOAT,filterable:!0,renderable:o.colorBufferFloat}:{internalFormat:t.RGBA16F,format:t.RGBA,type:t.HALF_FLOAT,filterable:!0,renderable:o.colorBufferFloat}}var Ke,be=O(()=>{Ke={colorBufferFloat:!1,floatBlend:!1}});function e0(t,e,o,r,n){return{theme:t,bg:e,accents:o,ink:r,intensity:n}}var B2,ln,b1=O(()=>{B2={id:"studio",label:"Studio",blurb:"The house identity \u2014 iris-led jewel tones over deep ink.",emoji:"\u2726",dark:e0("dark",[7,8,15],[[131,142,255],[120,220,232],[176,142,255],[255,150,182]],[232,236,255],1),light:e0("light",[244,246,251],[[84,96,222],[32,150,176],[124,96,212],[212,104,140]],[38,42,70],.78)},ln=[B2,{id:"aurora-borealis",label:"Aurora Borealis",blurb:"Polar night \u2014 emerald curtains bleeding into electric violet.",emoji:"\u{1F30C}",dark:e0("dark",[4,10,14],[[64,224,168],[72,214,232],[128,152,255],[196,132,255]],[224,244,240],1),light:e0("light",[240,248,246],[[16,158,124],[28,150,176],[86,100,214],[142,86,206]],[24,46,44],.8)},{id:"ember-forge",label:"Ember Forge",blurb:"Molten metal \u2014 ember orange cooling through coral to ash violet.",emoji:"\u{1F525}",dark:e0("dark",[14,7,6],[[255,138,56],[255,92,92],[240,84,142],[168,110,220]],[255,236,222],1),light:e0("light",[251,244,240],[[214,96,24],[212,64,72],[200,60,120],[134,78,188]],[56,30,24],.82)},{id:"coral-reef",label:"Coral Reef",blurb:"Shallow lagoon \u2014 turquoise water, living coral, anemone gold.",emoji:"\u{1FAB8}",dark:e0("dark",[5,13,16],[[54,226,214],[88,200,255],[255,126,142],[255,196,96]],[226,246,248],1),light:e0("light",[240,250,250],[[16,168,162],[30,138,206],[224,86,104],[212,144,36]],[20,48,50],.8)},{id:"ultraviolet",label:"Ultraviolet",blurb:"Synthwave dusk \u2014 magenta horizon over indigo, cut by cyan neon.",emoji:"\u{1F303}",dark:e0("dark",[10,6,20],[[255,92,196],[150,96,255],[96,132,255],[80,230,240]],[240,228,255],1),light:e0("light",[246,242,252],[[206,48,156],[120,72,214],[70,96,214],[24,158,178]],[40,26,64],.8)},{id:"verdigris",label:"Verdigris",blurb:"Oxidized copper \u2014 patina teal over bronze, weathered to jade.",emoji:"\u{1F5FF}",dark:e0("dark",[8,13,12],[[72,204,180],[122,196,138],[206,178,110],[224,142,96]],[228,240,232],1),light:e0("light",[242,248,244],[[22,150,132],[70,152,96],[160,130,56],[186,100,56]],[28,44,40],.8)},{id:"blackcurrant",label:"Blackcurrant",blurb:"Orchard at midnight \u2014 berry crimson, plum, and frosted mint.",emoji:"\u{1F347}",dark:e0("dark",[12,7,14],[[226,76,122],[168,92,198],[120,110,224],[120,224,184]],[240,228,240],1),light:e0("light",[249,244,250],[[196,52,100],[142,70,174],[92,86,200],[36,162,124]],[48,28,50],.8)},{id:"solar-flare",label:"Solar Flare",blurb:"Chromosphere \u2014 white-gold core through amber to plasma red.",emoji:"\u2600\uFE0F",dark:e0("dark",[16,9,4],[[255,224,130],[255,168,64],[255,110,64],[236,72,96]],[255,240,220],1),light:e0("light",[252,247,238],[[206,158,28],[212,120,24],[210,76,36],[196,52,76]],[54,32,18],.82)},{id:"abyssal",label:"Abyssal",blurb:"Deep sea \u2014 bioluminescent cyan and jellyfish violet in the dark.",emoji:"\u{1F30A}",dark:e0("dark",[3,7,16],[[40,200,224],[64,140,240],[134,108,232],[196,96,200]],[214,234,248],1),light:e0("light",[238,244,250],[[18,146,174],[34,102,200],[96,80,200],[150,64,168]],[18,38,58],.8)},{id:"sakura-dusk",label:"Sakura Dusk",blurb:"Blossom hour \u2014 petal pink, wisteria, and the last warm sky.",emoji:"\u{1F338}",dark:e0("dark",[14,9,13],[[255,158,192],[214,142,232],[150,150,240],[255,192,150]],[248,234,240],1),light:e0("light",[251,245,248],[[220,102,150],[168,96,200],[104,104,210],[212,134,78]],[52,32,44],.78)},{id:"monochrome-ink",label:"Monochrome Ink",blurb:"Graphite study \u2014 a single luminous channel, sumi restraint.",emoji:"\u2B1B",dark:e0("dark",[9,10,12],[[210,216,230],[150,160,184],[104,116,146],[232,236,244]],[235,238,245],.92),light:e0("light",[245,246,248],[[70,78,96],[104,112,132],[140,148,168],[40,46,60]],[28,32,42],.74)},{id:"petrol-slick",label:"Petrol Slick",blurb:"Oil on wet asphalt \u2014 a thin-film rainbow over deep tar.",emoji:"\u{1F6E2}\uFE0F",dark:e0("dark",[8,10,14],[[96,180,255],[120,240,200],[200,150,255],[255,168,120]],[228,236,248],1),light:e0("light",[240,242,246],[[58,140,214],[40,176,150],[150,104,210],[206,122,70]],[34,40,54],.76)},{id:"sumi-bleed",label:"Sumi Bleed",blurb:"Ink wicking into damp kozo \u2014 indigo running to vermillion.",emoji:"\u{1F58B}\uFE0F",dark:e0("dark",[12,13,17],[[120,196,224],[150,226,214],[196,156,232],[255,150,130]],[232,234,240],.98),light:e0("light",[243,240,232],[[44,120,168],[36,150,150],[150,92,180],[206,84,72]],[30,28,32],.76)}]});function v1(){return{}}function x1(){return{presetId:null,dark:v1(),light:v1()}}function G2(t){return Math.max(0,Math.min(255,Math.round(t)))}function De(t){if(!Array.isArray(t)||t.length!==3)return;let e=t.map(o=>typeof o=="number"&&Number.isFinite(o)?G2(o):NaN);if(!e.some(o=>Number.isNaN(o)))return e}function y1(t){if(!t||typeof t!="object")return{};let e=t,o={},r=De(e.bg);r&&(o.bg=r);let n=De(e.ink);return n&&(o.ink=n),typeof e.intensity=="number"&&Number.isFinite(e.intensity)&&(o.intensity=Math.max(0,Math.min(1,e.intensity))),Array.isArray(e.accents)&&(o.accents=e.accents.slice(0,4).map(a=>De(a)??null)),o}function _2(){if(!(g1||typeof window>"u")){g1=!0;try{let t=window.localStorage.getItem(F2);if(!t)return;let e=JSON.parse(t);Oe={presetId:typeof e.presetId=="string"?e.presetId:null,dark:y1(e.dark),light:y1(e.light)}}catch{Oe=x1()}}}function R1(){return _2(),Oe}function w1(t,e){let o=t.accents.map((r,n)=>e.accents?.[n]??r);return{theme:t.theme,bg:e.bg??t.bg,accents:o,ink:e.ink??t.ink,intensity:e.intensity??t.intensity}}var F2,Oe,g1,T1=O(()=>{b1();F2="studio.customPalette";Oe=x1(),g1=!1});function N2(t){let e=O2[t];return{theme:e.theme,bg:[...e.bg],accents:e.accents.map(o=>[...o]),ink:[...e.ink],intensity:e.intensity}}function ve(t){return w1(N2(t),R1()[t])}function w0(t){return[t[0]/255,t[1]/255,t[2]/255]}function o0(t,e){let[o,r,n]=t;return e===void 0?`rgb(${o|0},${r|0},${n|0})`:`rgba(${o|0},${r|0},${n|0},${e})`}function b0(t,e,o){return[t[0]+(e[0]-t[0])*o,t[1]+(e[1]-t[1])*o,t[2]+(e[2]-t[2])*o]}var K2,D2,O2,U0=O(()=>{T1();K2={theme:"dark",bg:[7,8,15],accents:[[131,142,255],[120,220,232],[176,142,255],[255,150,182]],ink:[232,236,255],intensity:1},D2={theme:"light",bg:[244,246,251],accents:[[84,96,222],[32,150,176],[124,96,212],[212,104,140]],ink:[38,42,70],intensity:.78},O2={dark:K2,light:D2}});function H0(t){return k1[t]}function Re(t){return L1[t]}function we(t,e,o,r){return We[t]*e+We[t+1]*o+We[t+2]*r}function Te(t,e,o){let r=0,n=0,a=0,s=0,c=(t+e+o)*V2,f=Math.floor(t+c),y=Math.floor(e+c),I=Math.floor(o+c),p=(f+y+I)*M0,m=t-(f-p),S=e-(y-p),A=o-(I-p),_,N,z,x,u,R;m>=S?S>=A?(_=1,N=0,z=0,x=1,u=1,R=0):m>=A?(_=1,N=0,z=0,x=1,u=0,R=1):(_=0,N=0,z=1,x=1,u=0,R=1):S<A?(_=0,N=0,z=1,x=0,u=1,R=1):m<A?(_=0,N=1,z=0,x=0,u=1,R=1):(_=0,N=1,z=0,x=1,u=1,R=0);let E=m-_+M0,F=S-N+M0,K=A-z+M0,q=m-x+2*M0,d=S-u+2*M0,g=A-R+2*M0,C=m-1+3*M0,D=S-1+3*M0,W=A-1+3*M0,r0=f&255,s0=y&255,t0=I&255,i0=.6-m*m-S*S-A*A;if(i0>=0){let l0=Re(r0+H0(s0+H0(t0)))*3;i0*=i0,r=i0*i0*we(l0,m,S,A)}let c0=.6-E*E-F*F-K*K;if(c0>=0){let l0=Re(r0+_+H0(s0+N+H0(t0+z)))*3;c0*=c0,n=c0*c0*we(l0,E,F,K)}let Z=.6-q*q-d*d-g*g;if(Z>=0){let l0=Re(r0+x+H0(s0+u+H0(t0+R)))*3;Z*=Z,a=Z*Z*we(l0,q,d,g)}let a0=.6-C*C-D*D-W*W;if(a0>=0){let l0=Re(r0+1+H0(s0+1+H0(t0+1)))*3;a0*=a0,s=a0*a0*we(l0,C,D,W)}return 32*(r+n+a+s)}function re(t,e,o,r=[0,0]){let n=Te(t,e+oe,o),a=Te(t,e-oe,o),s=(n-a)/(2*oe),c=Te(t+oe,e,o),f=Te(t-oe,e,o),y=(c-f)/(2*oe);return r[0]=s,r[1]=-y,r}var We,z2,k1,L1,bn,vn,V2,M0,oe,Se=O(()=>{We=new Float32Array([1,1,0,-1,1,0,1,-1,0,-1,-1,0,1,0,1,-1,0,1,1,0,-1,-1,0,-1,0,1,1,0,-1,1,0,1,-1,0,-1,-1]),z2=[151,160,137,91,90,15,131,13,201,95,96,53,194,233,7,225,140,36,103,30,69,142,8,99,37,240,21,10,23,190,6,148,247,120,234,75,0,26,197,62,94,252,219,203,117,35,11,32,57,177,33,88,237,149,56,87,174,20,125,136,171,168,68,175,74,165,71,134,139,48,27,166,77,146,158,231,83,111,229,122,60,211,133,230,220,105,92,41,55,46,245,40,244,102,143,54,65,25,63,161,1,216,80,73,209,76,132,187,208,89,18,169,200,196,135,130,116,188,159,86,164,100,109,198,173,186,3,64,52,217,226,250,124,123,5,202,38,147,118,126,255,82,85,212,207,206,59,227,47,16,58,17,182,189,28,42,223,183,170,213,119,248,152,2,44,154,163,70,221,153,101,155,167,43,172,9,129,22,39,253,19,98,108,110,79,113,224,232,178,185,112,104,218,246,97,228,251,34,242,193,238,210,144,12,191,179,162,241,81,51,145,235,249,14,239,107,49,192,214,31,181,199,106,157,184,84,204,176,115,121,50,45,127,4,150,254,138,236,205,93,222,114,67,29,24,72,243,141,128,195,78,66,215,61,156,180],k1=new Uint8Array(512),L1=new Uint8Array(512);for(let t=0;t<512;t++){let e=z2[t&255];k1[t]=e,L1[t]=e%12}bn=.5*(Math.sqrt(3)-1),vn=(3-Math.sqrt(3))/6,V2=1/3,M0=1/6;oe=.001});function j0(t,e,o){let r=$1(t,t.VERTEX_SHADER,Lo,`${o}:vert`),n=$1(t,t.FRAGMENT_SHADER,e,`${o}:frag`);if(!r||!n)return r&&t.deleteShader(r),n&&t.deleteShader(n),null;let a=t.createProgram();return a?(t.attachShader(a,r),t.attachShader(a,n),t.linkProgram(a),t.deleteShader(r),t.deleteShader(n),t.getProgramParameter(a,t.LINK_STATUS)?a:(console.error(`[backdrop] ${o} link failed:
${t.getProgramInfoLog(a)}`),t.deleteProgram(a),null)):(t.deleteShader(r),t.deleteShader(n),null)}function $1(t,e,o,r){if(t.isContextLost())return null;let n=t.createShader(e);if(!n)return null;if(t.shaderSource(n,o),t.compileShader(n),!t.getShaderParameter(n,t.COMPILE_STATUS)){if(t.isContextLost())return t.deleteShader(n),null;let a=t.getShaderInfoLog(n)??"unknown";return console.error(`[backdrop] ${r} shader compile failed:
${a}`),t.deleteShader(n),null}return n}var Lo,X0,e1,t1,ne=O(()=>{Lo=`#version 300 es
void main(){
  // Fullscreen triangle from gl_VertexID \u2014 no attribute buffers needed.
  vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));
  gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}`,X0=`#version 300 es
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
`,e1=`
void main(){
  vec2 fragCoord = gl_FragCoord.xy;
  vec2 uv = fragCoord / uResolution;
  vec3 col = renderKernel(uv, fragCoord);
  col += dither(fragCoord);
  fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}`,t1=["uResolution","uTime","uPointer","uPointerActive","uBg","uAccent0","uAccent1","uAccent2","uAccent3","uInk","uIntensity","uTheme"]});var at={};Y(at,{createFlowFieldKernel:()=>_o});function it(t){return .5+.5*(.62*Math.sin(2*Math.PI*t/Mo)+.38*Math.sin(2*Math.PI*t/Bo+1.3))}function Go(t,e,o){let r=Math.min(Math.max((t-e)/(o-e),0),1);return r*r*(3-2*r)}function _o(){let t=null,e=0,o=0,r=1,n=null,a=!1,s=[],c={x:0,y:0,active:!1},f={y:0,vy:0,yMax:0},y=[7,8,15];function I(){let u=e*o;return Math.max(380,Math.min(1500,Math.round(u/1100)))}function p(u,R,E){u.x=Math.random()*e,u.y=Math.random()*o,u.px=u.x,u.py=u.y,u.px2=u.x,u.py2=u.y,u.life=120+Math.random()*260,u.age=R?E*.618034%1*u.life:0,u.accent=Math.floor(Math.random()*(n?.accents.length??4)),u.bright=.6+Math.random()*.4,u.seed=E*.754877%1,u.layer=E*.381966%1<.4?0:1}function m(){let u=I();s=new Array(u);for(let R=0;R<u;R++){let E={x:0,y:0,px:0,py:0,px2:0,py2:0,age:0,life:0,accent:0,bright:1,seed:0,layer:1};p(E,!0,R),s[R]=E}}function S(){t&&t.setTransform(r,0,0,r,0,0)}function A(u){t&&(t.fillStyle=o0(y,u),t.fillRect(0,0,e,o))}function _(u){n=u,y=u.bg}function N(){if(!(!t||!n)){A(1);for(let u=0;u<30;u++)x(u*16,16,!1);x(3500,16,!0)}}let z=[0,0];function x(u,R,E){if(!t||!n)return;let F=Math.min(R,32)/16,K=it(u),q=.82+.3*K,d=.7+.6*K,g=u*rt*d+f.y*rt*K0.TIME_SCRUB,C=n.accents,D=n.ink,W=n.theme==="light",r0=W?.9:1.4,s0=W?.5:.42,t0=n.intensity,i0=f.vy,c0=Math.min(Math.abs(i0)/120,1),Z=E?c0:0,a0=f.y/K0.COLOR_SHIFT_PX+i0*K0.ACCENT_ACCEL*.01,l0=C.length||1;for(let u0=0;u0<s.length;u0++){let G=s[u0];G.px2=G.px,G.py2=G.py,G.px=G.x,G.py=G.y;let v0=G.layer?1.55:.7,F0=G.layer?g:g*.47+90;re(G.x*ot*v0,G.y*ot*v0,F0,z);let S0=z[0],x0=z[1];if(c.active){let w=G.x-c.x,P=G.y-c.y,H=w*w+P*P;if(H<Q0.R*Q0.R){let X=Math.sqrt(H)||1,J=Math.pow((Q0.R-X)/Q0.R,Q0.FALLOFF);S0+=-P/X*J*Q0.STRENGTH,x0+=w/X*J*Q0.STRENGTH}}let A0=1+c0*K0.SPEED_BOOST;if(i0!==0){let w=Math.sign(i0);x0+=w*Math.min(Math.abs(i0)/K0.GUST_K,K0.GUST),S0+=w*c0*K0.SHEAR}if(G.x+=S0*nt*A0*q*F,G.y+=x0*nt*A0*q*F,G.age+=F*16,G.x<-4||G.x>e+4||G.y<-4||G.y>o+4||G.age>G.life){p(G,!1,u0);continue}if(E){let w=G.age/G.life,P=Go(w,0,.12)*(.4+.6*(.5+.5*Math.cos(Math.min(Math.max((w-.6)/.4,0),1)*Math.PI))),H=(w+G.seed)%1-.5,J=Math.exp(-(H*H)/.018)*r0,m0=Math.min(J,1),d0=(Math.trunc(G.accent+a0)%l0+l0)%l0,G0=C[d0]??D,L0=W?b0(G0,D,.25):G0;m0>.01&&(L0=b0(L0,W?D:Fo,(W?.4:.45)*m0));let ee=(s0+Z*K0.ALPHA_BOOST)*P*G.bright*t0*(G.layer?1:.7)*(1+J);t.lineWidth=(G.layer?1:1.3)*(1.15+Z*K0.LINE_WIDTH),t.strokeStyle=o0(L0,Math.min(ee,1)),t.beginPath(),t.moveTo((G.px2+G.px)/2,(G.py2+G.py)/2),t.quadraticCurveTo(G.px,G.py,(G.px+G.x)/2,(G.py+G.y)/2),t.stroke()}}}return{id:"flow",label:"Flow Field",substrate:"2d",init(u,R){t=u,e=R.width,o=R.height,r=R.dpr,a=R.reducedMotion,_(R.palette),S(),t.lineCap="round",A(1),m(),a&&N()},frame(u,R){if(!t)return;let E=it(u),F=n?.theme==="light";A(F?.1-.02*E:.095-.03*E),x(u,R,!0)},resize(u){e=u.width,o=u.height,r=u.dpr,S(),t.lineCap="round",A(1),m(),a&&N()},setTheme(u,R){_(R),A(1)},pointer(u,R,E){c={x:u,y:R,active:E}},scroll(u,R,E){f={y:u,vy:R,yMax:E}},renderStatic(){N()},dispose(){t=null,s=[]}}}var ot,rt,nt,Mo,Bo,Fo,Q0,K0,lt=O(()=>{Se();U0();ot=.0016,rt=6e-5,nt=1.35,Mo=14e3,Bo=31e3;Fo=[248,250,255],Q0={R:280,STRENGTH:2.4,FALLOFF:1.4},K0={TIME_SCRUB:9,GUST:3.6,GUST_K:26,SPEED_BOOST:1.6,LINE_WIDTH:1.9,ALPHA_BOOST:.5,ACCENT_ACCEL:2.2,SHEAR:.9,COLOR_SHIFT_PX:220}});var ie,ae,le,se,o1=O(()=>{ie=`
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
`,ae=`
float fbm(vec3 p){
  float a = 0.5, s = 0.0;
  for(int i = 0; i < 3; i++){
    s += a * snoise(p);
    p *= 2.0;
    a *= 0.5;
  }
  return s;
}
`,le=`
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
`,se=`
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
`});function r1(t,e){return{uResolution:t.getUniformLocation(e,"uResolution"),uTime:t.getUniformLocation(e,"uTime"),uPointer:t.getUniformLocation(e,"uPointer"),uPointerActive:t.getUniformLocation(e,"uPointerActive"),uBg:t.getUniformLocation(e,"uBg"),uAccent0:t.getUniformLocation(e,"uAccent0"),uAccent1:t.getUniformLocation(e,"uAccent1"),uAccent2:t.getUniformLocation(e,"uAccent2"),uAccent3:t.getUniformLocation(e,"uAccent3"),uInk:t.getUniformLocation(e,"uInk"),uIntensity:t.getUniformLocation(e,"uIntensity"),uTheme:t.getUniformLocation(e,"uTheme"),uHasSim:t.getUniformLocation(e,"uHasSim"),uScroll:t.getUniformLocation(e,"uScroll"),uScrollVel:t.getUniformLocation(e,"uScrollVel"),uImpulses:t.getUniformLocation(e,"uImpulses"),uImpulseCount:t.getUniformLocation(e,"uImpulseCount"),uObstacleRects:t.getUniformLocation(e,"uObstacleRects"),uObstacleCount:t.getUniformLocation(e,"uObstacleCount"),uPrev:t.getUniformLocation(e,"uPrev"),uSim:t.getUniformLocation(e,"uSim"),uSimResolution:t.getUniformLocation(e,"uSimResolution"),uGlyphField:t.getUniformLocation(e,"uGlyphField"),uGlyphActive:t.getUniformLocation(e,"uGlyphActive"),uGlyphRect:t.getUniformLocation(e,"uGlyphRect"),uGlyphPhase:t.getUniformLocation(e,"uGlyphPhase")}}var B0,st,Un,n1=O(()=>{ne();B0={hasSim:`uniform float uHasSim;
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
`},st=B0.hasSim+B0.scroll+B0.impulses+B0.obstacles,Un=[...t1,"uHasSim","uScroll","uScrollVel","uImpulses","uImpulseCount","uObstacleRects","uObstacleCount","uPrev","uSim","uSimResolution","uGlyphField","uGlyphActive","uGlyphRect","uGlyphPhase"]});function ut(t){return`
void main(){
  vec2 uv = gl_FragCoord.xy / uSimResolution;
  fragColor = ${t}(uv);
}`}function dt(t,e,o,r,n,a){t.getExtension("EXT_color_buffer_float");let s=h1(t,e.format,o),c=s.filterable?t.LINEAR:t.NEAREST,f=j0(t,`${Ko}
${ie}
${ae}
${le}
${se}
${e.step}
${ut("simStep")}`,`${a}:sim`),y=j0(t,`${Do}
${ie}
${ae}
${le}
${se}
${e.seed}
${ut("simSeed")}`,`${a}:seed`),I=0,p=0,m=null,S=null,A=null,_=null,N=!1,z=null,x=null,u=null;f&&(z=t.getUniformLocation(f,"uPrev"),x=t.getUniformLocation(f,"uSimResolution")),y&&(u=t.getUniformLocation(y,"uSimResolution"));function R(d,g){I=Math.max(ct,Math.round(d*e.scale)),p=Math.max(ct,Math.round(g*e.scale))}function E(){let d=t.createTexture(),g=t.createFramebuffer();return!d||!g?(d&&t.deleteTexture(d),g&&t.deleteFramebuffer(g),null):(t.bindTexture(t.TEXTURE_2D,d),t.texImage2D(t.TEXTURE_2D,0,s.internalFormat,I,p,0,s.format,s.type,null),t.texParameteri(t.TEXTURE_2D,t.TEXTURE_MIN_FILTER,c),t.texParameteri(t.TEXTURE_2D,t.TEXTURE_MAG_FILTER,c),t.texParameteri(t.TEXTURE_2D,t.TEXTURE_WRAP_S,t.CLAMP_TO_EDGE),t.texParameteri(t.TEXTURE_2D,t.TEXTURE_WRAP_T,t.CLAMP_TO_EDGE),t.bindFramebuffer(t.FRAMEBUFFER,g),t.framebufferTexture2D(t.FRAMEBUFFER,t.COLOR_ATTACHMENT0,t.TEXTURE_2D,d,0),{tex:d,fbo:g})}function F(d){return d?(t.bindFramebuffer(t.FRAMEBUFFER,d.fbo),t.checkFramebufferStatus(t.FRAMEBUFFER)===t.FRAMEBUFFER_COMPLETE):!1}function K(){for(let d of[m,S])d&&(t.deleteTexture(d.tex),t.deleteFramebuffer(d.fbo));m=S=A=_=null}function q(){K(),m=E(),S=E(),N=s.renderable&&!!m&&!!S&&!!f&&!!y&&F(m)&&F(S),t.bindFramebuffer(t.FRAMEBUFFER,null),A=m,_=S,N||console.error(`[backdrop] ${a} sim target/program incomplete; display-only.`)}return R(r,n),q(),{get ok(){return N},get simW(){return I},get simH(){return p},get stepProgram(){return f},get seedProgram(){return y},current(){return N&&A?A.tex:null},resize(d,g){N&&(R(d,g),q())},reseed(d,g){if(!(!N||!y)){t.useProgram(y),g(y),t.bindVertexArray(d),u&&t.uniform2f(u,I,p),t.viewport(0,0,I,p);for(let C of[m,S])C&&(t.bindFramebuffer(t.FRAMEBUFFER,C.fbo),t.drawArrays(t.TRIANGLES,0,3));A=m,_=S,t.bindFramebuffer(t.FRAMEBUFFER,null)}},step(d,g){if(!N||!f)return;let C=Math.min(Math.max(e.stepsPerFrame|0,1),i1);t.useProgram(f),g(f),t.bindVertexArray(d),x&&t.uniform2f(x,I,p),t.viewport(0,0,I,p);for(let D=0;D<C&&!(!A||!_);D++){t.bindFramebuffer(t.FRAMEBUFFER,_.fbo),t.activeTexture(t.TEXTURE0),t.bindTexture(t.TEXTURE_2D,A.tex),z&&t.uniform1i(z,0),t.drawArrays(t.TRIANGLES,0,3);let W=A;A=_,_=W}t.bindFramebuffer(t.FRAMEBUFFER,null)},settle(d,g,C){if(!N||d<=0)return;let D=Math.ceil(d/i1);for(let W=0;W<D;W++)this.step(g,C)},dispose(){K(),f&&t.deleteProgram(f),y&&t.deleteProgram(y)}}}var i1,ct,Ko,Do,a1=O(()=>{ne();be();o1();n1();i1=8,ct=2,Ko=`${X0}${st}
uniform sampler2D uPrev;
uniform vec2  uSimResolution;
`,Do=`${X0}
uniform vec2  uSimResolution;
`});function M(t){let e=null,o=null,r=null,n=null,a=null,s=[.5,.5],c=[.5,.5],f=0,y=!1,I=null,p=!!(t.sim||t.textures||t.controls),m=null,S=null,A=[],_=Ke,N=0,z=new Map,x=t.controls?.includes("scroll")??!1,u=t.controls?.includes("impulses")??!1,R=t.controls?.includes("obstacles")??!1,E=t.controls?.includes("glyph")??!1,F={y:0,yMax:0,vy:0},K=new Float32Array(l1*4),q=0,d=new Float32Array(mt*4),g=0,C=null,D=null,W=!1,r0=[.5,.5,.5,.5],s0=1,t0=l=>{l.preventDefault(),y=!0},i0=()=>{y=!1,e&&(z.clear(),Z(e),S0(),F0(),p&&(G(e),v0(e)),E&&(D=null,W=!!C))};function c0(l){!E||!C||(D||(D=l.createTexture()),D&&(l.bindTexture(l.TEXTURE_2D,D),l.texImage2D(l.TEXTURE_2D,0,l.RGBA,C.size,C.size,0,l.RGBA,l.UNSIGNED_BYTE,C.data),l.texParameteri(l.TEXTURE_2D,l.TEXTURE_WRAP_S,l.CLAMP_TO_EDGE),l.texParameteri(l.TEXTURE_2D,l.TEXTURE_WRAP_T,l.CLAMP_TO_EDGE),l.texParameteri(l.TEXTURE_2D,l.TEXTURE_MIN_FILTER,l.LINEAR),l.texParameteri(l.TEXTURE_2D,l.TEXTURE_MAG_FILTER,l.LINEAR),W=!1))}function Z(l){let w=X0;t.sim&&(w+=B0.hasSim),x&&(w+=B0.scroll),u&&(w+=B0.impulses),R&&(w+=B0.obstacles),E&&(w+=B0.glyph);let P=t.sim?`uniform sampler2D uSim;
uniform vec2 uSimResolution;
`:"",H=(t.textures??[]).map(J=>`uniform sampler2D ${J.name};`).join(`
`),X=p?`${w}${P}${H}
${ie}
${ae}
${le}
${se}
${t.body}
${e1}`:`${X0}
${ie}
${ae}
${le}
${se}
${t.body}
${e1}`;o=j0(l,X,t.id),o&&(p?S=r1(l,o):n={uResolution:l.getUniformLocation(o,"uResolution"),uTime:l.getUniformLocation(o,"uTime"),uPointer:l.getUniformLocation(o,"uPointer"),uPointerActive:l.getUniformLocation(o,"uPointerActive"),uBg:l.getUniformLocation(o,"uBg"),uAccent0:l.getUniformLocation(o,"uAccent0"),uAccent1:l.getUniformLocation(o,"uAccent1"),uAccent2:l.getUniformLocation(o,"uAccent2"),uAccent3:l.getUniformLocation(o,"uAccent3"),uInk:l.getUniformLocation(o,"uInk"),uIntensity:l.getUniformLocation(o,"uIntensity"),uTheme:l.getUniformLocation(o,"uTheme")},r=l.createVertexArray())}function a0(l){!e||!a||(e.uniform2f(l.uResolution,e.drawingBufferWidth,e.drawingBufferHeight),e.uniform1f(l.uTime,N),e.uniform2f(l.uPointer,s[0],s[1]),e.uniform1f(l.uPointerActive,f),e.uniform3fv(l.uBg,w0(a.bg)),e.uniform3fv(l.uAccent0,w0(a.accents[0]??a.ink)),e.uniform3fv(l.uAccent1,w0(a.accents[1]??a.ink)),e.uniform3fv(l.uAccent2,w0(a.accents[2]??a.ink)),e.uniform3fv(l.uAccent3,w0(a.accents[3]??a.ink)),e.uniform3fv(l.uInk,w0(a.ink)),e.uniform1f(l.uIntensity,a.intensity),e.uniform1f(l.uTheme,a.theme==="light"?1:0))}function l0(l,w){e&&(e.uniform1f(l.uHasSim,w),x&&(e.uniform2f(l.uScroll,F.y,F.yMax),e.uniform1f(l.uScrollVel,F.vy)),u&&(e.uniform4fv(l.uImpulses,K),e.uniform1i(l.uImpulseCount,q)),R&&(e.uniform4fv(l.uObstacleRects,d),e.uniform1i(l.uObstacleCount,g)),E&&(e.uniform1f(l.uGlyphActive,C?1:0),e.uniform4f(l.uGlyphRect,r0[0],r0[1],r0[2],r0[3]),e.uniform1f(l.uGlyphPhase,s0)))}function u0(l){let w=z.get(l);return!w&&e&&(w=r1(e,l),z.set(l,w)),w??{}}function G(l){if(!t.sim||!r)return;let w=No(t.sim);m=dt(l,w,_,l.drawingBufferWidth,l.drawingBufferHeight,t.id),m.stepProgram&&u0(m.stepProgram),m.seedProgram&&u0(m.seedProgram);let P=J=>a0(u0(J)),H=J=>{let m0=u0(J);a0(m0),l0(m0,1)};m.reseed(r,P);let X=t.sim.settleSteps??0;X>0&&m.settle(X,r,H)}function v0(l){if(!(!t.textures||!o||!S)){A.length=0;for(let w of t.textures){let P=l.createTexture();l.bindTexture(l.TEXTURE_2D,P),l.texImage2D(l.TEXTURE_2D,0,l.RGBA,1,1,0,l.RGBA,l.UNSIGNED_BYTE,new Uint8Array([0,0,0,255]));let H=w.wrap==="clamp"?l.CLAMP_TO_EDGE:l.REPEAT,X=w.filter==="nearest"?l.NEAREST:l.LINEAR;l.texParameteri(l.TEXTURE_2D,l.TEXTURE_WRAP_S,H),l.texParameteri(l.TEXTURE_2D,l.TEXTURE_WRAP_T,H),l.texParameteri(l.TEXTURE_2D,l.TEXTURE_MIN_FILTER,X),l.texParameteri(l.TEXTURE_2D,l.TEXTURE_MAG_FILTER,X);let J=new Image;J.onload=()=>{!e||!P||(e.bindTexture(e.TEXTURE_2D,P),e.texImage2D(e.TEXTURE_2D,0,e.RGBA,e.RGBA,e.UNSIGNED_BYTE,J))},J.src=w.dataUri,A.push({name:w.name,tex:P,loc:l.getUniformLocation(o,w.name)})}}}function F0(){if(!(!e||!o))if(p&&S)e.useProgram(o),a0(S);else{if(!a)return;e.useProgram(o),e.uniform3fv(n.uBg,w0(a.bg)),e.uniform3fv(n.uAccent0,w0(a.accents[0]??a.ink)),e.uniform3fv(n.uAccent1,w0(a.accents[1]??a.ink)),e.uniform3fv(n.uAccent2,w0(a.accents[2]??a.ink)),e.uniform3fv(n.uAccent3,w0(a.accents[3]??a.ink)),e.uniform3fv(n.uInk,w0(a.ink)),e.uniform1f(n.uIntensity,a.intensity),e.uniform1f(n.uTheme,a.theme==="light"?1:0)}}function S0(){e&&e.viewport(0,0,e.drawingBufferWidth,e.drawingBufferHeight)}function x0(l,w){let P=e.drawingBufferHeight,H=P/(I?.clientHeight||P);return[l*H/e.drawingBufferWidth,1-w*H/P]}function A0(){let l=0;for(let w=0;w<q;w++){let P=K[w*4+3]+1;if(P<Oo){let H=w*4,X=l*4;K[X]=K[H],K[X+1]=K[H+1],K[X+2]=K[H+2],K[X+3]=P,l++}}q=l}return{id:t.id,label:t.label,substrate:"webgl2",init(l,w){e=l,a=w.palette,_=w.caps??Ke,I=e.canvas,I.addEventListener("webglcontextlost",t0,!1),I.addEventListener("webglcontextrestored",i0,!1),Z(e),S0(),F0(),p&&(G(e),v0(e))},frame(l){if(!e||!o||y)return;if(N=l/1e3,s[0]+=(c[0]-s[0])*.08,s[1]+=(c[1]-s[1])*.08,!p||!S){e.useProgram(o),e.bindVertexArray(r),e.uniform2f(n.uResolution,e.drawingBufferWidth,e.drawingBufferHeight),e.uniform1f(n.uTime,N),e.uniform2f(n.uPointer,s[0],s[1]),e.uniform1f(n.uPointerActive,f),e.drawArrays(e.TRIANGLES,0,3),e.bindVertexArray(null);return}m?.ok&&m.step(r,H=>{let X=u0(H);a0(X),l0(X,1)}),A0(),e.bindFramebuffer(e.FRAMEBUFFER,null),e.viewport(0,0,e.drawingBufferWidth,e.drawingBufferHeight),e.useProgram(o),e.bindVertexArray(r),a0(S);let w=m?.ok?1:0;l0(S,w);let P=0;if(w&&m){let H=m.current();H&&(e.activeTexture(e.TEXTURE0+P),e.bindTexture(e.TEXTURE_2D,H),e.uniform1i(S.uSim,P),e.uniform2f(S.uSimResolution,m.simW,m.simH),P++)}for(let H of A)H.tex&&(e.activeTexture(e.TEXTURE0+P),e.bindTexture(e.TEXTURE_2D,H.tex),H.loc&&e.uniform1i(H.loc,P),P++);E&&(W&&c0(e),D&&(e.activeTexture(e.TEXTURE0+P),e.bindTexture(e.TEXTURE_2D,D),e.uniform1i(S.uGlyphField,P),P++)),e.drawArrays(e.TRIANGLES,0,3),e.bindVertexArray(null)},resize(){if(S0(),p&&m&&(m.resize(e.drawingBufferWidth,e.drawingBufferHeight),r)){let l=P=>a0(u0(P));m.reseed(r,l);let w=t.sim?.settleSteps??0;w>0&&m.settle(w,r,l)}},setTheme(l,w){a=w,F0()},pointer(l,w,P){e&&(c=x0(l,w),f=P?1:0)},click(l,w){if(!e||!u)return;let[P,H]=x0(l,w),X;q<l1?X=q++:(K.copyWithin(0,4),X=l1-1);let J=X*4;K[J]=P,K[J+1]=H,K[J+2]=1,K[J+3]=0},obstacles(l){if(!(!e||!R)){g=Math.min(l.length,mt);for(let w=0;w<g;w++){let P=l[w],[H,X]=x0(P.x,P.y),[J,m0]=x0(P.x+P.w,P.y+P.h),d0=w*4;d[d0]=H,d[d0+1]=m0,d[d0+2]=J,d[d0+3]=X}}},scroll(l,w,P){x&&(F.y=l,F.vy=w,F.yMax=P)},setGlyphField(l){if(E)if(C=l,l){let w=l.content.x+l.content.w*.5,P=l.content.y+l.content.h*.5;r0[0]=w,r0[1]=1-P,r0[2]=l.content.w*.5,r0[3]=l.content.h*.5,s0=1,W=!0}else W=!1,e&&D&&(e.deleteTexture(D),D=null)},renderStatic(){if(!p){this.frame(0,0);return}if(m?.ok&&r){let l=w=>{let P=u0(w);a0(P),l0(P,1)};m.reseed(r,w=>a0(u0(w))),m.settle(t.sim?.settleSteps??0,r,l)}this.frame(0,0)},dispose(){if(I&&(I.removeEventListener("webglcontextlost",t0),I.removeEventListener("webglcontextrestored",i0)),e){if(p){m?.dispose(),m=null;for(let l of A)l.tex&&e.deleteTexture(l.tex);A.length=0,z.clear()}D&&(e.deleteTexture(D),D=null),o&&e.deleteProgram(o),r&&e.deleteVertexArray(r),e.getExtension("WEBGL_lose_context")?.loseContext()}e=null,o=null,r=null,n=null,S=null,a=null,I=null,C=null}}}function No(t){return{step:t.step,seed:t.seed,format:t.format??"RGBA16F",scale:t.scale??.5,stepsPerFrame:t.stepsPerFrame??1}}var l1,mt,Oo,Q=O(()=>{U0();ne();a1();be();o1();n1();ne();a1();l1=8,mt=24,Oo=3});var ft={};Y(ft,{createAuroraKernel:()=>Wo});function Wo(){return M({id:"aurora",label:"Aurora",body:Uo})}var Uo,pt=O(()=>{Q();Uo=`
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
`});var ht={};Y(ht,{createMeshKernel:()=>qo});function qo(){return M({id:"mesh",label:"Iridescent Mesh",body:Ho})}var Ho,bt=O(()=>{Q();Ho=`
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
`});var Le,ce,Ie,s1=O(()=>{Le=Math.PI*(3-Math.sqrt(5)),ce=7,Ie=9});var vt={};Y(vt,{createMoireKernel:()=>Vo});function Vo(){return M({id:"moire",label:"Moir\xE9",body:zo})}var zo,gt=O(()=>{Q();s1();zo=`
// \u2500\u2500 moir\xE9 quasicrystal \u2014 tuning constants (mirror quasicrystalWaves.ts) \u2500\u2500\u2500\u2500
const int   QC_WAVES_C   = ${ce};
const float QC_GOLDEN_C  = ${Le.toFixed(10)};
const float QC_FREQ_C    = ${Ie.toFixed(1)};
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
`});var yt={};Y(yt,{createVolumetricKernel:()=>jo});function jo(){return M({id:"volumetric",label:"Volumetric",body:Xo,controls:["scroll"]})}var Xo,xt=O(()=>{Q();Xo=`
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
`});var Rt,wt=O(()=>{Rt="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAAAAACPAi4CAAAQS0lEQVR4nAFAEL/vAIXtAqAniAtQ2Yo9AFyn+8FJ0Yi7RXbAFvlAJlCcZf3AeGq1TaZzKesaivA+Ys9WNtgclHHWVqQR8r7TYxiv9WwApGF40kS3cTayKWaW1C8Ybp8JH/2X3Vqhyoup0hc6ihw02egSjP9DuFnTl74Sr4d2uEqs/wu1yiZ1iC/kVXzOEwDF5BuR9VzqmX73FuZ5Ubg67156rjoHKG41AV/2dLLNWZgGhWC/zAqBNGoEf/ss6hZp8SWJOXqW5l1GFKC6Bkk1ACROrDkQxiMH0FfCRrCMzA3hkDDHUvO0guvclRBG4yjvqUj3OyVTntys9SWlQ1CfAsgxX81N7Roz27SR+Wbri5kA/XJY3oSiZeQ+p28L8iJkgKVH1hNnitFIHrlVxIGhaw9+xG+ylfFlFEnFVs1u2bx64o6n3wVlwqNtA8k5dxvTsgCABcu2LUl5vJIdhzWa30H5KLVymuaoDGGfdyvtOB67UtUvHOAAeTHqkHUN5IwbOJdXQRNynYVD/FODI03dLFs/ABbqk2r5GddSL/3byFl0Fb9TAu4hQi7C/zvYCotk3ZI+82Khi0TSqB28PJ0wrmP4JO+vwSH1uCkN16vqvJWpbb8AnytDDaeL6wOzY0itBaPTkmnKhl3dexZwk7BMpfrIBK2GDee3WsZsh9df/X0STMltCYFO1zZY0JRzPWAQfQfv1wCFY91VwThynMsXfSfohDwtrPU3obqPzFjjI8B7FFZxKs13TTYh+AxQKbIGz+e5h6DRLOlnj3qxGfIuncz3VjZJAMiv9HzSI15ChfRrvlH7YuEOdxtPCPdINAHyYEEwtOtGmP8W232aPt/yb0WUWTIZP162mRcH5EljwIXiRBiMtyAAcwE0G5a28awP3TOXErIfSJvA6dpnJa6dgmzK3p6B1h+mXcSQsWPBoRaCwiJ2pvTce/87qMX4J6UBUiFwp2bbmABb5qRObAjhLVWh0UCLx3DQgllAqYd21Oq4EY4e9AlovjoCbirrCDGNVqs479UNUZAAI3JWhj9tzNuQs8XnL/8UAEG/i/rHgEiPwnUgX+4LpvYnA5UvyQ4+XStPqTlbk03iivGqVNRHd+fQAuBhmrxqxq1Mzt68D559NvtdPAWAT84AeBApYDzVFGb+ALnjfFMzZrjW72C1+hmW2sP8dM+xFzF1zkEQiPwdtWsoTYkbQSrjNuyWHDBf4k4dDXbVnySRrgD1m9+0H6qY6jeIS60qntxEd4weT3GhS31mBIZGJ8Dun18guXvGo1o8mffJcrT8f1yJEWV3sfGNueyZrkjyvmI1AAZqSobucVImo9luGPmSB8YTqzrgCdK98DTkoxPoa4AG2PaZMGfeC79/Eqc0C9KfB8Cl9kbSCCVAZs8riWwa6tcAgsgY0TUHu81cDMM8YrSD5Vf+v4CSLRqKriFX1ZE2UK1EjRTlTiOR8UVf5pJV7Ulv2SY6hJtUqoLBElbgCUClVACyLaNak/h+QuaQgOvPSCE1a5soZOlBW27LPnq6YA/+yCpZb6o5s9BxLtgfw3oprxvnV7jKF/1z2jST+nu3y40hAET9c+LCEWSxHDCmVBB08qfUSQHKpbP72guc9yyp3ph2vOnMA/qFVQiehrc7Z82LP5Z8AmjlLl4F6UwgoF0vcOQAZJABPU0nnt11/Lwlmt2MvRd881IgdRFMj2PEShqEQAgfh0ececIX6q5M+wKdFfFgxvg0rY5FvKTJaLI60/YNvwAV2beAqfSJOVACa8s4ZQZbMJa14YY0n7go4wB07tBpovE3ZeAsYD/ZZRxz4kbXui0So0902x+XehSG8AKSS3+dAFXxIWHSbRfG15ZDffWxRejHbz4PYu7OfPQ6iLFUMrla2a4Otx3zpo4yv1mPqIBScIjfI8sL9VHTKUHcdRzE6jgAeKUxxQrpLrNf7KgO1R2ehfkj143DRhlVaqQfyZQR+CVLjXPUlkvJEHr0zg4kNf4Gs+w8gbJnNetcrL1SpmEosADNSYiZQVaPeRQkhle7K3VPC6RYriqX3gjA2F5E4H1tm8QX+1c1g2vimypCsOhfw55HZJVYF6HDiwmYbDD/hNYJAOUY+3DcvKNI+MEz5pJi3L825GkD/W6CqjKODewrqwTngkCnAem9JAlTtoNqldp3INIMvtj9QnHjIPLPFeJDlmwAPLldDybxBGfbmG9KA/+rF5iBzUy7O+clT/tznr1R1jhf0Sp7y16s/zrW7QROFj6L8jFuJ4kAty5/TjyOBrYhWACMocp8rTeEyT0PtNB/O8hcRPYueRygy2O10IQ8FGaRIbvwaZgbQ4ifdGEepsv3u61Ufp3nq1PRY5+zyFx8o8XzAAEt306T01UirFzuG6Mmi3MQ2LaQ8FkTlABHHfDFevmtCYdLs9vuL9ATksIyf28pEOHHSxk5ed4a+g1v3PdIMnMAsR1pP+oZcP2NeTDhaFTy5a8kYQjGQnf24G6vWdswRp9W3zMRc1YFukjzWN1GoVyXaAaz9WCXv0eQN6gpGGbY6ACCmvrDCqe93gydTsGTuAYznYRQptwviKQ3wSmaiwvPdBnI+6W/kGjme7AmjBXq0jX7QorMLAnvJXTmUr2XiQ9SADfRW3eJMGFCKMz1PxfaRs9pxDnpbbIi1FOAD+RityXrZ5R9Jz32HqY4Cm38twOGwHkjomzagapcyYQD7T3OpMAARRMlt0qc84GzbAGHdKhefR30DI4YXe0GZ/2qO031gzayQwRi1ITJT5bZy0BjqlAb3FrsFU+3OxGi1WmxeSJf8wCuke3gA88bUtmkWukt/g6z35lHdc++S5zJGY51xAKiU9zD5VGdDC7iXRiCnS7mcz2asMQzk/xm4UUuHP9L4AVwANd+ZTarauiVEDe9IJrGjz0oWKz8K5R+NLVD59kebNONDiKp72+0RXet7b5MHo7Q8xB/SQF3ziGIu5xZkjO6nisATg2iVcd5PiX6fdNKZdlRcO+9gQI/4RPwcShZlzKuQP5edoYzE8L+jQAqavbHWgm5LWHT46ZXCvNy6Qh+yWSG+ADLuyL/EYy4YMRvjq8WNYMHyhpj1qJrWqrOhwe98X8VmS29SdqTZCDRVKI8E3vgpmyV+Yk/J7SXTDfDq9oS5ho+AHbomETWLaDfB0LuC+S5ot6SMOlOuCLCDE/6pGFJx2jlsc4X9laoNuV+utiUsTREIlHAHG7tx4DWGGEmUUKas1sACjNrgVzuFVCtMJ1XePsfWkR1nYQ3+IvkMnvYESbdVAU7bKB9BMhwQw30YHEF/YXO6K4NoV4xEGqg+o148msokADC3agBssFzhvhozCeLPWqr87UKFs1xRJkdaT2UuIin+Y8j6UEp7IWwmy4dSr9YoBRzN0rdjvhE4rA9y7YApdH2AB1KivM7H0jTlRzdvUzKAdQmxVXspl4F2reoyexyGjN5TMHVY5e4Elvhxojs0SbjZJL1fsMIdLsjhVkVMdxOOXwAtlgqzGiZ6zMEXX6kD++ZfDeKaN0rsn/wUSpaA0bi0bNcCYOsUfzQJE12qz6ZfTG6AcpbIKpTls8F7Jlw6IgUZQDT/KAW41R8yK9F9TZus2BQFP2XHEqRORXQjv2DoWQolPAV4TEaO2qTAfZlGAqyUNpCK5zYPOUtZ0t7vCJfxKyWAD4HboC6DqQocLjjGZEs6NmoQbtz0/jAaHYLsDfC9A5Ayp9xvI563aW+NtSP5m/4pYrrarUTh/Gn2zj+oUIL7y0A3o3GQzHXYf6NDFXVgUW+B4POLw+hWyPlnknaInBSt4pnIVT3zQpE7oEqWbhIIWAMeBpO/npfCsMejw/Mg9lQeAAgXeyvlO9LHtA+m2bFoh918GRT63wAQYcxvF7pF5vceDXoR6cpYrRSHJ/+e8ybvzrUxJEzzZpBdFGwa1kntWmlAMAOTyR1AInCearnKBH7WTqcJLaN3q/F8qcSe5HKRgD+r8MGf+CaE8Vw2wZAEofsKa5aBKol47b1LNfnO/OTAPoAN5jPZuE8tFcyB/NPcs2s4IgMyTRLYx1wUdX6OqmBLl8a1pVZM/KKOeiSZK8y31Nr+YLeSnAOWIuiBH+cF8lHhQCzfPeoFaD51GWVuoU0kARH9mypGP+Y0SyTBGomV/HRo4dBcrofa9SsJ0zB0nanGZRAIJ/wvTnSGmXHSrt1MmTlAFcYQy7Hg28mGeBDFdq0Zyy9V9Y/dg6DueJFxrIVvkxsJOMN+cxKBFuCEPAiW/QAuc91EGSElvp7MewhW+Kr1SUA8W2N2lMJR+mpfceeW+p90hyTgOShVPM7XqDsjHbfCJHuqFGCsJ55+7ujbUSdf8dN5TK11SlPw6hFsJL+CIoSnwDLBLrrYprAjzlUbPkiDk2iOe0DK7zKJKsZfgs0Y5w+tjLIYzsrFt4/L+aKCdU4KGaJpFtB6wIWa9sMzW9SP8J4AEyXPSerdhD10gIsrj+Yv/xysV1GaAmN6W3bU/3JG/RYdxPamPDFZ5TPG1S4/JKy7RwK/4+seOKcXDyDKqXeYjEAsdeEGv7MMVyFueN41F+HJxTGitn4dLNNLsCmI0etgNMhi7wAV4lJC6x2NeBiEnNV3Hy+IsxXiSz0tBXvuZUe+QBaC2jhUEG1H6JKFpDxB8tq31CnMpoVQNaVEITRkWsF46D/RXLjtiP2XMKcfiJHocU9mUpuNhm8SMiQeE3SAX/nACuov3qgjG3W7mTFN1OrMESXDOkfgs7wYXj3PVvqLME5T2kpqjV+1mzoQgPKr/LTCCz2YNLknvsHaCPjYTRDbo4AzEg18xYF5i1+CpxyIOeA97t3PWW+WCapALkYcbEPmF60EdHtG5sOpCuP+VEwjGmEuqoYBIOwdDjVqQyb/MejEQDfcSDTYMWVVq9D9Nu2YqAXWNSu/gaiN8dI4Z/WTvrOdPKBw5BfTb47gxrVcRHhPx7leJTuUCddlupTwYYntFXvAIiat4FLqTn6Gc4qjEsCzTiRJIVL3pB67GiJMiKCQIwfMqIHP3f7y+JWq7thl6fBWkk0ZsRA38ocf0ByE9tnGzoAA1L8D+Ikdr6Ha6UPeL/hb+8KyC9tEtQbmFTxyGOpA9lL5FjUsCZmBnTrRSXueQH/ndixFImiDrX4La7uSpR7vgBiLKM+j2XYA0/mXjr/lStHq16b5bZWQsIrCLZ5Eue9m2i5GonnFJO3MJoNxDhOz4YoDPZyL/BJaZECzl0zpvfVAMbmbbTN8C+etSDXxa1VHYfXej4e9H+v/HHcpUb3OFUme/o7bi6kR4bQ/GmM2hitYrqOUtBevXrYWJ7kirsJJUUAjR18ClYWgkLtkzGBEutntfcTw1CSA2GcOoxaHZVty92OCqzGU/XeXDwfplR98i9u6DwhqZkFHjbEJEUZauh3rQBa1/eWOKrEYHUNTW2cQs0FNaNy26oz0CPkDMPYLoOtFENd75R+AsAReuXHCLadRwbGfuFG6oT5sN9vgP7IUZsOALkvTMFp3/0epMr0uuAkfI9X5ypkEe2FTrFpe+26BUzloCrPHjjYZpuwTS1x4CCR+KNdD8EsZz+PTwioOpMp3D0Um/hqIqmFNgAAADJ0RVh0Q29tbWVudABibHVlLW5vaXNlIHZvaWQtYW5kLWNsdXN0ZXIgKGdsbS01LTIgYmFrZSkLsSn5AAAAAElFTkSuQmCC"});var Tt={};Y(Tt,{createLicKernel:()=>Jo});function Jo(){return M({id:"lic",label:"Flow Imaging",body:Qo,textures:[{name:"uBlueNoise",dataUri:Rt,filter:"linear",wrap:"repeat"}],controls:["scroll"]})}var Qo,St=O(()=>{Q();wt();Qo=`
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
`});var At={};Y(At,{createFluidAuroraKernel:()=>$o});function $o(){return M({id:"fluid-aurora",label:"Fluid Aurora",body:Zo})}var Zo,Et=O(()=>{Q();Zo=`
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
`});var Ct={};Y(Ct,{createCloudFieldKernel:()=>tr});function tr(){return M({id:"cloudfield",label:"Cloud Field",body:er})}var er,Pt=O(()=>{Q();er=`
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
`});var kt={};Y(kt,{createPlasmaOrbsKernel:()=>rr});function rr(){return M({id:"plasma-orbs",label:"Plasma Orbs",body:or})}var or,Lt=O(()=>{Q();or=`
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
`});var It={};Y(It,{createBlobsMeshKernel:()=>ir});function ir(){return M({id:"blobs-mesh",label:"Blobs Mesh",body:nr})}var nr,Mt=O(()=>{Q();nr=`
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
  float maxWeight = 0.0;   // strongest single-blob influence at p \u2014 the
                           // spatial key that keeps blob centres readable
                           // (a flat weightSum wash is what made the field
                           // read as a featureless gradient).

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
    float rad = 0.36 + 0.12 * blobHash(fi * 5.3 + 2.7);
    // Breathing radius \u2014 5.7s/11s irrational pair, never phase-locks.
    float breathe = 1.0 + 0.12 * (
        0.62 * sin(uTime * 1.099 + seed * 6.2831) +
        0.38 * sin(uTime * 0.571 + seed * 6.2831 + 1.3)
    );
    rad *= breathe;

    // The blob's resting colour comes from a per-instance palette slot (the
    // existing accent ramp), with a tiny per-blob hue roll driven by tHue +
    // a deterministic per-instance offset.
    float hueT = fract(tHue + 0.13 * fi + 0.13 * blobHash(fi * 9.7 + 6.1));
    vec3  col  = accentRamp(hueT);

    // Quadrant anchor per blob: even angular spread + deterministic jitter.
    // Without it the four noise-driven centres can start on top of each
    // other, and the mesh opens as a featureless wash until they separate.
    float ang = fi * 1.5708 + blobHash(fi * 4.3 + 2.2) * 0.9;
    vec2 anchor = 0.34 * vec2(cos(ang), sin(ang));

    vec2 c = centre + anchor + driftAmp * wander;
    float w = blobWeight(pw, c, rad);
    weightedColor += col * w;
    weightSum += w;
    maxWeight = max(maxWeight, w);
  }

  // Normalise: weighted colour sum / total weight \u2192 the mesh colour at p.
  vec3 mesh = weightSum > 1e-4 ? weightedColor / weightSum : accentRamp(0.5);

  // \u2500\u2500 Theme composite (timing identical; only the math flips) \u2500\u2500
  vec3 col;
  if (uTheme < 0.5) {
    // DARK: additive bloom over deep ink; the mesh glows like a luminous
    // gradient poster. The maxWeight key concentrates the bloom at blob
    // centres and lets the gaps fall back toward the ink, so the blobs read
    // as distinct bodies instead of one saturated wash. Filmic knee keeps
    // the brightest blob-centres from burning to flat white.
    float key = smoothstep(0.12, 0.9, maxWeight);
    col = uBg;
    col += mesh * (0.95 * uIntensity) * (0.22 + 0.78 * key);
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
`});var Bt={};Y(Bt,{createRetroPlasmaKernel:()=>lr});function lr(){return M({id:"retro-plasma",label:"Retro Plasma",body:ar})}var ar,Ft=O(()=>{Q();ar=`
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
`});var Gt={};Y(Gt,{createInversionLatticeKernel:()=>cr});function cr(){return M({id:"inversion-lattice",label:"Inversion Lattice",body:sr})}var sr,_t=O(()=>{Q();sr=`
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
`});var Kt={};Y(Kt,{createVogelBloomKernel:()=>dr});function dr(){return M({id:"vogel-bloom",label:"Vogel Bloom",body:ur})}var ur,Dt=O(()=>{Q();ur=`
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
`});var Ot={};Y(Ot,{createCrystalDriftKernel:()=>fr});function fr(){return M({id:"crystal-drift",label:"Crystal Drift",body:mr})}var mr,Nt=O(()=>{Q();mr=`
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
`});var Ut={};Y(Ut,{createRippleLatticeKernel:()=>hr});function hr(){return M({id:"ripple-lattice",label:"Ripple Lattice",body:pr})}var pr,Wt=O(()=>{Q();pr=`
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
`});var Ht={};Y(Ht,{createLiquidLumenKernel:()=>vr});function vr(){return M({id:"liquid-lumen",label:"Liquid Lumen",body:br})}var br,qt=O(()=>{Q();br=`
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
`});var zt={};Y(zt,{createSpectralDriftKernel:()=>yr});function yr(){return M({id:"spectral-drift",label:"Spectral Drift",body:gr})}var gr,Vt=O(()=>{Q();gr=`
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
`});var Xt={};Y(Xt,{createMyceliumMeshKernel:()=>Rr});function Rr(){return M({id:"mycelium-mesh",label:"Mycelium Mesh",body:xr})}var xr,jt=O(()=>{Q();xr=`
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
`});var Yt={};Y(Yt,{createOilfieldKernel:()=>Tr});function Tr(){return M({id:"oilfield",label:"Oilfield",body:wr})}var wr,Qt=O(()=>{Q();wr=`
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
`});var Jt={};Y(Jt,{createSuminagashiDriftKernel:()=>Ar});function Ar(){return M({id:"suminagashi-drift",label:"Suminagashi Drift",body:Sr})}var Sr,Zt=O(()=>{Q();Sr=`
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
`});var $t={};Y($t,{createKineticStippleKernel:()=>Cr});function Cr(){return M({id:"kinetic-stipple",label:"Kinetic Stipple",body:Er})}var Er,e2=O(()=>{Q();Er=`
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
`});var t2={};Y(t2,{createAgent1Kernel:()=>kr});function kr(){return M({id:"agent1",label:"Agent 1",body:Pr})}var Pr,o2=O(()=>{Q();Pr=`
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
`});var r2={};Y(r2,{createNeuralBloomKernel:()=>Ir});function Ir(){return M({id:"neural-bloom",label:"Neural Bloom",body:Lr})}var Lr,n2=O(()=>{Q();Lr=`
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
`});var i2={};Y(i2,{createAetherLatticeKernel:()=>Br});function Br(){return M({id:"aether-lattice",label:"Aether Lattice",body:Mr,controls:["scroll"]})}var Mr,a2=O(()=>{Q();s1();Mr=`
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
  for (int j = 0; j < ${ce}; j++){
    float a  = QC_PI * float(j) / float(${ce}) + spin;
    vec3  k  = vec3(cos(a), sin(a), 0.0) * freq; // 2D wave basis extended into Z
    float ph = float(j) * ${Le.toFixed(10)};
	    q += cos(dot(k, pos) + ph + scrub);
  }
  q /= float(${ce});
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
  float freq   = ${Ie.toFixed(1)} * (0.9 + 0.2 * breath);

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
`});var l2={};Y(l2,{createBeamProjectorKernel:()=>Gr});function Gr(){return M({id:"bat-signal",label:"Beacon",body:Fr,controls:["scroll"]})}var Fr,s2=O(()=>{Q();Fr=`
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
`});var c2={};Y(c2,{createStormCellKernel:()=>Kr});function Kr(){return M({id:"storm-signal",label:"Tempest",body:_r,controls:["scroll"]})}var _r,u2=O(()=>{Q();_r=`
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
`});var d2={};Y(d2,{createPaperfieldKernel:()=>Or});function Or(){return M({id:"origami",label:"Origami",body:Dr,controls:["scroll"]})}var Dr,m2=O(()=>{Q();Dr=`
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
`});var f2={};Y(f2,{createInkDiffusionKernel:()=>Ur});function Ur(){return M({id:"ink-diffusion",label:"Ink Diffusion",body:Nr})}var Nr,p2=O(()=>{Q();Nr=`
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
`});var h2={};Y(h2,{createPetroleumSheenKernel:()=>Hr});function Hr(){return M({id:"petroleum-sheen",label:"Petroleum Sheen",body:Wr})}var Wr,b2=O(()=>{Q();Wr=`
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
`});var T2={};Y(T2,{createBoidsKernel:()=>$r});function Jr(t){return .5+.5*(.62*Math.sin(2*Math.PI*t/Yr)+.38*Math.sin(2*Math.PI*t/Qr+1.3))}function $r(){let t=null,e=0,o=0,r=1,n=null,a=!1,s=[],c={x:0,y:0,active:!1},f={y:0,vy:0,yMax:0},y=[7,8,15],I=1,p=1,m=new Int32Array(1),S=new Int32Array(0),A=[0,0];function _(){let d=e*o;return Math.max(zr,Math.min(Vr,Math.round(d/qr)))}function N(d){d.x=Math.random()*e,d.y=Math.random()*o;let g=Math.random()*Math.PI*2,C=J0.MIN+Math.random()*(J0.MAX-J0.MIN);d.vx=Math.cos(g)*C,d.vy=Math.sin(g)*C,d.bright=.5+Math.random()*.5}function z(){let d=_();s=new Array(d);for(let g=0;g<d;g++){let C={x:0,y:0,vx:0,vy:0,bright:1};N(C),s[g]=C}I=Math.max(1,Math.ceil(e/q0)),p=Math.max(1,Math.ceil(o/q0)),m=new Int32Array(I*p),S=new Int32Array(d)}function x(){t&&t.setTransform(r,0,0,r,0,0)}function u(d){t&&(t.fillStyle=o0(y,d),t.fillRect(0,0,e,o))}function R(d){n=d,y=d.bg}function E(d){let g=n,C=g.accents,D=C.length||1,W=d/Zr%1*D,r0=Math.floor(W)%D,s0=W-Math.floor(W),t0=C[r0]??g.ink,i0=C[(r0+1)%D]??g.ink,c0=[t0[0]+(i0[0]-t0[0])*s0,t0[1]+(i0[1]-t0[1])*s0,t0[2]+(i0[2]-t0[2])*s0],Z=g.ink;return[Z[0]+(c0[0]-Z[0])*.3,Z[1]+(c0[1]-Z[1])*.3,Z[2]+(c0[2]-Z[2])*.3]}function F(){if(!(!t||!n)){u(1);for(let d=0;d<90;d++)q(d*16,16,!1);q(90*16,16,!0)}}function K(){m.fill(-1);for(let d=0;d<s.length;d++){let g=s[d],C=g.x/q0|0,D=g.y/q0|0;C<0?C=0:C>=I&&(C=I-1),D<0?D=0:D>=p&&(D=p-1);let W=D*I+C;S[d]=m[W],m[W]=d}}function q(d,g,C){if(!t||!n)return;let D=Math.min(g,32)/16,W=Jr(d),r0=Xr*(.7+.6*W),s0=.9+.2*W,t0=f.vy,i0=Math.min(Math.abs(t0)/120,1),c0=t0!==0?Math.sign(t0)*Math.min(Math.abs(t0)/u1.GUST_K,u1.GUST):0,Z=J0.MAX*s0*(1+i0*u1.SPEED_BOOST),a0=J0.MIN,l0=n.theme==="light",u0=n.intensity,G=l0?.44:.46,v0=d*jr,F0=q0*q0,S0=v2*v2,x0=y;C&&(x0=E(d),t.lineCap="round"),K();for(let A0=0;A0<s.length;A0++){let l=s[A0],w=0,P=0,H=0,X=0,J=0,m0=0,d0=0,G0=Math.min(I-1,Math.max(0,l.x/q0|0)),L0=Math.min(p-1,Math.max(0,l.y/q0|0)),ee=G0>0?G0-1:0,fe=G0<I-1?G0+1:I-1,pe=L0>0?L0-1:0,Fe=L0<p-1?L0+1:p-1;for(let b=pe;b<=Fe&&d0<c1;b++)for(let U=ee;U<=fe&&d0<c1;U++)for(let L=m[b*I+U];L!==-1;L=S[L]){if(L===A0)continue;let T=s[L],B=T.x-l.x,V=T.y-l.y,$=B*B+V*V;if(!($>=F0||$===0)){if(d0++,H+=T.vx,X+=T.vy,J+=B,m0+=V,$<S0){let p0=1/Math.sqrt($);w-=B*p0,P-=V*p0}if(d0>=c1)break}}let f0=0,i=0;if(d0>0){let b=1/d0;f0+=(H*b-l.vx)*Me,i+=(X*b-l.vy)*Me,f0+=J*b*y2,i+=m0*b*y2,f0+=w*g2,i+=P*g2}re(l.x*R2,l.y*R2,v0,A),f0+=(A[0]*J0.MAX-l.vx)*Me*r0,i+=(A[1]*J0.MAX-l.vy)*Me*r0;let h=Math.sqrt(f0*f0+i*i);if(h>w2){let b=w2/h;f0*=b,i*=b}if(c.active){let b=l.x-c.x,U=l.y-c.y,L=b*b+U*U;if(L<Z0.R*Z0.R&&L>0){let T=Math.sqrt(L),B=Math.pow((Z0.R-T)/Z0.R,Z0.FALLOFF);f0+=b/T*B*Z0.STRENGTH,i+=U/T*B*Z0.STRENGTH}}l.x<T0.MARGIN?f0+=T0.TURN*(1-l.x/T0.MARGIN):l.x>e-T0.MARGIN&&(f0-=T0.TURN*(1-(e-l.x)/T0.MARGIN)),l.y<T0.MARGIN?i+=T0.TURN*(1-l.y/T0.MARGIN):l.y>o-T0.MARGIN&&(i-=T0.TURN*(1-(o-l.y)/T0.MARGIN)),i+=c0,f0+=(Math.random()-.5)*x2,i+=(Math.random()-.5)*x2,l.vx+=f0*D,l.vy+=i*D;let k=Math.sqrt(l.vx*l.vx+l.vy*l.vy)||1e-6;if(k>Z){let b=Z/k;l.vx*=b,l.vy*=b}else if(k<a0){let b=a0/k;l.vx*=b,l.vy*=b}if(l.x+=l.vx*D,l.y+=l.vy*D,C){let b=Math.sqrt(l.vx*l.vx+l.vy*l.vy)||1e-6,U=l.vx/b,L=l.vy/b,T=2+l.bright*1.8+b/Z*1.4,B=Math.min(G*l.bright*u0,1),V=l.x-U*T*.45,$=l.y-L*T*.45,p0=l.x+U*T*.55,n0=l.y+L*T*.55;t.lineWidth=.9+l.bright*.5,t.strokeStyle=o0(x0,B),t.beginPath(),t.moveTo(V,$),t.lineTo(p0,n0),t.stroke()}}}return{id:"boids",label:"Boids",substrate:"2d",init(d,g){t=d,e=g.width,o=g.height,r=g.dpr,a=g.reducedMotion,R(g.palette),x(),t.lineCap="round",t.lineJoin="round",u(1),z(),a&&F()},frame(d,g){if(!t)return;let C=n?.theme==="light";u(C?.22:.19),q(d,g,!0)},resize(d){e=d.width,o=d.height,r=d.dpr,x(),t.lineCap="round",t.lineJoin="round",u(1),z(),a&&F()},setTheme(d,g){R(g),u(1)},pointer(d,g,C){c={x:d,y:g,active:C}},scroll(d,g,C){f={y:d,vy:g,yMax:C}},renderStatic(){F()},dispose(){t=null,s=[]}}}var q0,v2,c1,qr,zr,Vr,g2,Me,y2,Xr,x2,R2,jr,J0,w2,T0,Yr,Qr,Z0,u1,Zr,S2=O(()=>{Se();U0();q0=78,v2=13,c1=16,qr=340,zr=520,Vr=1600,g2=.9,Me=.09,y2=6e-4,Xr=.75,x2=.03,R2=.0014,jr=5e-5,J0={MIN:.9,MAX:2.35},w2=.3,T0={MARGIN:90,TURN:.16},Yr=14e3,Qr=31e3;Z0={R:230,STRENGTH:.6,FALLOFF:1.25},u1={GUST:.5,GUST_K:70,SPEED_BOOST:.55},Zr=44e3});be();U0();var U2={primary:[255,255,255],secondary:[235,239,246],muted:[218,224,234],accent:[255,226,166],icon:[242,246,252],focus:[255,255,255],shadow:[0,0,0],scrim:[5,7,11]},W2={primary:[13,17,23],secondary:[31,41,55],muted:[55,65,81],accent:[91,52,0],icon:[24,33,45],focus:[13,17,23],shadow:[255,255,255],scrim:[248,250,252]},S1={light:U2,dark:W2};function A1(t){return Math.min(1,Math.max(0,t))}function Ne(t){let e=A1(t/255);return e<=.04045?e/12.92:Math.pow((e+.055)/1.055,2.4)}function Ue(t){return .2126*Ne(t[0])+.7152*Ne(t[1])+.0722*Ne(t[2])}function H2(t,e){let o=typeof t=="number"?t:Ue(t),r=typeof e=="number"?e:Ue(e),n=Math.max(o,r),a=Math.min(o,r);return(n+.05)/(a+.05)}function q2(t,e,o){let r=A1(o);return[t[0]*r+e[0]*(1-r),t[1]*r+e[1]*(1-r),t[2]*r+e[2]*(1-r)]}function W0(t){return`rgb(${Math.round(t[0])} ${Math.round(t[1])} ${Math.round(t[2])})`}function ge(t,e,o,r){let n=Number.POSITIVE_INFINITY;for(let a of t){let s=q2(o,a,r);n=Math.min(n,H2(e,s))}return Number.isFinite(n)?n:1}function ye(t,e,o=4.5){let r=S1[e],n=ge(t,r.muted,r.scrim,0);if(n>=o)return{tone:e,scrimOpacity:0,contrastRatio:n};let a=0,s=1;for(let c=0;c<14;c+=1){let f=(a+s)/2;ge(t,r.muted,r.scrim,f)>=o?s=f:a=f}return{tone:e,scrimOpacity:s,contrastRatio:ge(t,r.muted,r.scrim,s)}}function E1(t,e){let o=ye(t,"light"),r=ye(t,"dark"),n=Math.abs(o.scrimOpacity-r.scrimOpacity);return e&&n<.045?e==="light"?o:r:o.scrimOpacity<=r.scrimOpacity?o:r}function C1(t,e,o,r=e.scrimOpacity){let n=S1[e.tone],a=t.map(Ue),s=ge(t,n.muted,n.scrim,r);return{tone:e.tone,primary:W0(n.primary),secondary:W0(n.secondary),muted:W0(n.muted),accent:W0(n.accent),icon:W0(n.icon),focus:W0(n.focus),shadow:W0(n.shadow),scrim:W0(n.scrim),scrimOpacity:r,minLuminance:a.length>0?Math.min(...a):0,maxLuminance:a.length>0?Math.max(...a):0,contrastRatio:s,sampleCount:t.length,samplingDurationMs:0,source:o}}var xe=class{constructor(){v(this,"tone");v(this,"pendingTone");v(this,"pendingSince",0);v(this,"lastScrimOpacity",0)}update(e){let o=e.samples.length>0?e.samples:[[7,8,15]],r=E1(o,this.tone);if(!this.tone)this.tone=r.tone,this.pendingTone=void 0;else if(r.tone!==this.tone){let c=ye(o,this.tone);c.scrimOpacity>.72&&r.scrimOpacity+.2<c.scrimOpacity?(this.tone=r.tone,this.pendingTone=void 0):this.pendingTone!==r.tone?(this.pendingTone=r.tone,this.pendingSince=e.nowMs):e.nowMs-this.pendingSince>=900&&(this.tone=r.tone,this.pendingTone=void 0)}else this.pendingTone=void 0;let n=ye(o,this.tone),a=n.scrimOpacity,s=a>=this.lastScrimOpacity?a:Math.max(a,this.lastScrimOpacity-.08);return this.lastScrimOpacity=s,C1(o,n,e.source,s)}reset(){this.tone=void 0,this.pendingTone=void 0,this.pendingSince=0,this.lastScrimOpacity=0}};function P1(t,e="palette"){let o=[t.bg,...t.accents,t.ink],r=E1(o,t.theme==="dark"?"light":"dark");return C1(o,r,e)}Se();U0();var I1=[.3127,.9615,16640703,3,.3237,.9615,16499797,3,.332,.9615,16509892,3,.3071,.9588,16636563,3,.3403,.956,16640186,3,.2961,.9505,16035909,3,.3459,.9477,16704959,3,.2822,.9422,16708829,3,.3459,.9394,16626223,3,.2712,.9339,16709088,3,.2656,.9283,16636059,3,.3459,.9283,16702873,3,.2573,.9228,16709602,3,.3431,.9228,16571041,3,.2518,.9173,16704178,3,.3348,.9117,16363832,3,.2407,.909,16709852,3,.2352,.9034,16574652,3,.332,.9034,16708053,3,.2297,.8979,16504215,3,.3265,.8979,16559146,3,.2131,.8841,16708309,3,.2214,.8896,16364376,3,.321,.8841,16640972,3,.1992,.8702,16572859,3,.3127,.8702,16567429,3,.1854,.8564,16570783,3,.3071,.8564,16643300,3,.1716,.8426,16505494,3,.2988,.8426,16300636,3,.1577,.8287,16708317,3,.2933,.8287,16499320,3,.1467,.8149,16234320,3,.2905,.8204,16508870,3,.2878,.8149,16570270,3,.1384,.8066,16572339,3,.2822,.8011,16505263,3,.1328,.8011,16639168,3,.1245,.7928,16710376,3,.2767,.79,16292647,3,.119,.7844,16568974,3,.2739,.7817,16360766,3,.1107,.7761,16707798,3,.2712,.7734,16361792,3,.1079,.7706,16432218,3,.0996,.7623,16638648,3,.2684,.7595,16576736,3,.0941,.754,16500076,3,.0858,.7457,16709341,3,.2629,.7485,16626260,3,.2601,.7402,16492868,3,.0775,.7319,16362566,3,.2573,.7319,16621360,3,.0692,.7236,16643297,3,.2546,.718,16433533,3,.0636,.7153,16640450,3,.0581,.707,16438421,3,.2518,.7042,16639424,3,.0526,.6987,16371338,3,.047,.6904,16502150,3,.249,.6931,16569767,3,.2463,.6876,16358460,3,.0415,.6821,16635534,3,.2463,.6765,16576994,3,.036,.6738,16505765,3,.0304,.6655,16639162,3,.2435,.6627,16575450,3,.0249,.6572,16642004,3,.0194,.6489,16709347,0,.2407,.6489,16572359,0,.0138,.6378,16373409,0,.238,.635,16626815,0,.0111,.6323,16370831,0,.0055,.6212,16299612,0,.2352,.6212,16615202,0,0,.6129,16637877,0,.2352,.6074,16631195,0,-.0055,.6046,16709863,0,-.0111,.5935,16708830,0,.2352,.5935,16638673,0,-.0138,.5852,16306582,0,.2352,.5852,16641250,0,.2324,.5797,16419123,0,-.0194,.5769,16709861,0,-.0221,.5659,16294969,0,.2324,.5659,16486467,0,-.0277,.5576,16572849,0,.2324,.552,16487239,0,-.0304,.5493,15968852,0,-.036,.5382,16040583,0,.2324,.5382,16549171,0,-.0415,.5271,16640457,0,.2324,.5271,16611362,0,-.0443,.5216,16709349,0,.2352,.5216,16704989,0,-.047,.5105,16365927,0,.2352,.5105,16695713,0,-.0526,.4967,16237694,0,.2352,.4967,16614974,0,-.0553,.4884,16298850,0,.238,.4828,16634559,0,-.0581,.4828,16372123,0,-.0636,.469,16573117,0,.238,.469,16348205,0,-.0664,.4552,16422703,0,.2407,.4552,16426624,0,-.0719,.4413,16166742,0,.2435,.4413,16235940,0,-.0775,.4275,16375478,0,.2463,.4275,16368813,0,-.0802,.4137,15966289,0,.2463,.4192,16084023,0,.249,.4137,16504260,0,-.2435,.4054,16693599,0,-.2297,.4054,16638393,0,-.083,.4054,15970157,0,.2518,.3998,16502971,0,-.2546,.3998,16301696,0,-.2186,.3971,16688196,0,-.0858,.3971,16237448,0,-.2601,.386,16495192,0,-.2103,.3915,16634266,0,-.0885,.386,16432249,0,.2546,.386,16560014,0,-.2048,.386,16629353,0,-.2573,.3722,16295231,0,-.1965,.3777,16558669,0,-.0913,.3722,16358982,0,.2573,.3722,16550238,0,-.1909,.3722,16631429,0,-.2546,.3611,16642269,0,-.1854,.3639,16618799,0,-.0968,.3583,16642004,0,.2601,.3611,16153165,0,-.1771,.3556,16636594,0,.2629,.3556,16501947,0,-.249,.3528,16158766,0,-.2463,.3445,16357433,0,-.1716,.3473,16699293,0,-.0968,.35,16163664,0,.2656,.3445,16434865,0,-.0996,.3417,16369293,0,-.166,.339,16698523,0,-.2435,.3307,16636073,0,-.1605,.3307,16637117,0,-.1024,.3307,16306340,0,.2684,.3307,16283214,0,-.2407,.3168,16707027,0,-.1577,.3224,16550701,0,-.1051,.3168,16304541,0,.2739,.3168,16434357,0,-.1522,.3141,16560232,0,-.238,.3058,16505263,0,-.1467,.303,16619582,0,-.1079,.303,16501921,0,.2767,.303,16209452,0,-.2352,.2975,16489269,0,-.2352,.2892,16237184,0,-.1411,.2947,16636088,0,-.1107,.2892,16437671,0,.2822,.2892,16227978,0,-.1384,.2864,16624218,0,-.2352,.2753,16576988,0,-.1328,.2753,16636086,0,-.1107,.2809,16289343,0,.2878,.2753,16441303,2,-.1134,.2753,16638148,0,-.2352,.2615,16709090,0,-.1273,.2615,16705489,0,-.1162,.2615,16708322,0,.2905,.2615,16018763,2,-.2352,.2476,16508614,0,-.1162,.2476,16419112,0,.2961,.2476,16361877,2,-.2352,.2338,16168041,0,-.119,.2393,16708319,0,.3016,.2338,16574439,2,-.238,.22,16241312,0,.3016,.2255,15285274,2,.3044,.22,15892587,2,-.2407,.2061,16370583,0,.3099,.2061,16506327,2,-.2435,.1923,16228178,0,.3127,.1923,16089973,2,-.3957,.1812,16688416,0,-.249,.1812,16572864,0,.3154,.1812,15886937,2,.5589,.184,16639460,2,.5728,.1812,15483979,2,-.4095,.1785,16632180,0,-.3818,.1785,16497501,0,.5479,.1757,15693434,2,.5838,.1757,16220544,2,-.2518,.1757,16642267,0,.3182,.1757,16439766,2,-.4178,.1729,16710119,0,-.4234,.1674,16709600,0,-.3708,.1646,16505778,0,-.2546,.1646,15966811,0,.321,.1646,16574182,2,.5423,.1646,14694723,2,.5921,.1674,16574186,2,.5949,.1619,16360357,2,-.4317,.1591,16705987,0,-.4372,.1508,16493884,0,-.3708,.1508,16432760,0,-.2629,.1508,16641752,0,.321,.1508,15743517,2,.5368,.1508,15768989,2,.6004,.1508,15560053,2,-.451,.137,16368507,0,-.3708,.137,16571053,0,-.2684,.137,16294993,0,.3237,.137,15817286,2,.534,.137,15567503,2,.606,.1425,16304331,2,.6087,.1342,15358303,2,-.4649,.1204,16625223,0,-.3708,.1231,16641755,0,-.2767,.1259,16707806,0,.3265,.1231,16157569,2,.5313,.1231,15768989,2,.6143,.1231,15360874,2,-.2795,.1204,16572350,0,-.4704,.1148,16362566,0,-.3735,.1093,16488486,0,-.2878,.1093,16709352,0,.3293,.1093,16637921,2,.5285,.1093,16166831,2,.6198,.1148,16502993,2,-.4759,.1093,16632951,0,.6226,.1065,15627387,2,-.4842,.101,16709609,0,-.3735,.0955,16488231,0,-.2961,.0955,16165483,0,.3293,.0955,16433344,2,.5257,.0955,16236987,2,.6281,.0955,15699090,2,-.4898,.0927,16434287,0,-.4981,.0844,16708572,0,-.3708,.0816,16574928,0,-.3016,.0872,16223546,0,.3293,.0816,15899030,2,.5257,.0872,14829905,2,.6336,.0844,16109528,2,.523,.0816,16036528,2,-.3099,.0789,16634279,0,-.5008,.0789,16500343,0,.6364,.0789,16508139,2,-.5091,.0706,16708058,0,-.3708,.0678,16498803,0,-.3154,.0733,16706001,0,.3293,.0678,16096666,2,.5202,.0678,15633288,2,.6392,.0678,15160675,2,-.321,.065,16292171,0,-.5147,.0623,16504989,0,-.5202,.054,16166731,0,-.368,.054,16575183,0,-.3293,.0567,16241074,0,.3293,.054,16502220,2,.5174,.054,14629185,2,.6447,.054,15097193,2,-.3348,.0512,16506558,0,-.5313,.0401,16567923,0,-.368,.0401,16489266,0,-.3431,.0429,16505779,0,.3265,.0401,15686998,2,.5119,.0429,15905201,2,.6475,.0457,14892874,2,.6502,.0401,15561341,2,-.3486,.0374,16375747,0,.5091,.0374,16573923,2,-.5368,.0318,16232e3,0,-.3652,.0291,16566920,0,-.3569,.0291,16634533,0,.3237,.0263,15347483,2,.5064,.0263,15362929,2,.6558,.0263,15904950,2,-.5451,.0235,16707794,0,-.5506,.0152,16509128,0,.3237,.0125,16437451,2,.5008,.0125,14963293,2,.6613,.0125,16442087,2,-.5562,.0069,16571035,0,-.5617,-.0014,16237679,0,.3182,-.0014,14887455,2,.4925,-.0014,16174802,2,.6641,-.0014,14832478,2,-.5672,-.0097,16236388,0,.3182,-.0097,16439510,2,.487,-.0125,15834787,2,.6696,-.0152,16368320,2,-.5728,-.0152,16642780,0,.3154,-.0152,16094871,2,.4815,-.0208,16231848,2,-.5783,-.0263,16500833,0,.3099,-.0291,15083811,2,.4759,-.0291,16169657,2,.6724,-.0291,15227749,2,-.5838,-.0346,16371580,0,-.5894,-.0429,16438410,0,.3071,-.0429,16569818,2,.4704,-.0374,15902636,2,.6752,-.0401,14632276,2,.4649,-.0457,15100276,2,.6779,-.0457,15771057,2,-.5949,-.0512,16374434,0,.2988,-.0567,14626080,2,.4593,-.0512,15969457,2,.6807,-.0567,15435671,2,-.6004,-.0595,16638895,0,.451,-.0595,16370636,2,-.606,-.0678,16574652,0,.2933,-.0706,15696250,2,.4427,-.0678,16641e3,2,.6835,-.0706,14768997,2,.44,-.0733,15226716,2,-.6115,-.0761,16643551,0,-.6143,-.0844,16365385,0,.285,-.0844,14958134,2,.4317,-.0816,14893381,2,.6862,-.0844,14169407,2,.4234,-.0872,16172488,2,-.6226,-.0955,16709597,0,.2795,-.0955,15967138,0,.4151,-.0955,16436429,2,.689,-.0927,15165291,2,.6918,-.101,16165553,2,-.6253,-.101,16707008,1,.4123,-.101,16106949,2,.2739,-.1038,15367037,1,-.6309,-.1121,16572836,1,.2684,-.1121,15293018,1,.4123,-.1121,15434889,2,.6945,-.1121,16439517,2,-.6364,-.1231,16508340,1,.2629,-.1204,15686755,1,.4206,-.1259,16106955,2,.6945,-.1259,14298936,2,.2573,-.1287,15900318,1,.4344,-.1259,14970998,2,.4483,-.1259,15169659,2,.4621,-.1259,15168116,2,.4759,-.1259,15166835,2,-.6392,-.1287,16441508,1,.487,-.1287,14176087,2,-.6447,-.1397,16508334,1,.2518,-.137,16503759,1,.4925,-.1342,16505048,2,.6973,-.1397,14432063,2,-.202,-.1397,16706271,1,.5008,-.1425,13838898,2,.2463,-.1425,15695485,1,-.2103,-.1453,15893842,1,-.6502,-.1508,16442289,1,-.2158,-.1508,16096371,1,-.1965,-.1536,15825231,1,.238,-.1536,16440030,1,.5008,-.1536,15574954,2,.7001,-.1536,14834788,2,-.653,-.1563,16574652,1,-.2241,-.1591,16287562,1,.2324,-.1591,15837606,1,-.6586,-.1674,16643296,1,-.2297,-.1674,16639961,1,-.1992,-.1674,16707297,1,.2269,-.1646,14906230,1,.5008,-.1674,15705511,2,.7028,-.1674,15771572,2,.2186,-.1729,15036530,1,-.6613,-.1785,16366159,1,-.2435,-.1812,16625013,1,-.1992,-.1812,16703949,1,.2131,-.1785,15436163,1,.5008,-.1812,15772331,2,.7028,-.1785,14368330,2,.2546,-.1812,15557467,1,.2684,-.1812,15483971,1,.2822,-.1812,15418178,1,.2961,-.1812,15483204,2,.3099,-.1812,15351362,2,.3237,-.1812,15285569,2,.3376,-.1812,15286855,2,.3514,-.1812,15286342,2,.3652,-.1812,15220549,2,.3791,-.1812,15287886,2,.3929,-.1812,15222350,2,.4068,-.1812,15156298,2,.4206,-.1812,15286860,2,.4344,-.1812,15096670,2,.2463,-.184,16572125,1,.7056,-.184,16572647,2,-.6669,-.1868,16710119,1,.2048,-.1868,15302271,1,.4427,-.1868,14829909,2,-.6696,-.1951,16640698,1,-.2573,-.1951,15760443,1,-.1992,-.1951,16637127,1,.1992,-.1923,15965857,1,.2407,-.1951,16094091,1,.4483,-.1951,15232627,2,.5008,-.1951,15708336,2,.7056,-.1951,15305368,2,.1909,-.1978,14498100,1,-.6752,-.2089,16644584,1,-.2629,-.2034,16496781,1,-.1965,-.2089,16226161,1,.1826,-.2061,15563646,1,.2407,-.2089,15890284,1,.451,-.2089,16376291,2,.5008,-.2089,15840949,2,.7056,-.2089,13508137,2,-.2684,-.2089,16024650,1,.1743,-.2144,16573418,1,-.6779,-.22,16309662,1,-.2739,-.2172,16372411,1,-.1965,-.2172,16707301,1,.1688,-.2172,15432311,1,.2407,-.2227,15692648,1,.451,-.2227,16508392,2,.5008,-.2227,15973306,2,.7084,-.2227,15574958,2,-.1937,-.2227,15828065,1,-.2822,-.2255,15758127,1,.1577,-.2255,15818325,1,-.6807,-.2255,16644066,1,-.6835,-.2366,16506784,1,-.2878,-.2338,16225895,1,-.1909,-.2366,16369337,1,.1439,-.2366,16437200,1,.1522,-.231,16436945,1,.2407,-.2366,15493986,1,.4483,-.2366,14628148,2,.5008,-.2366,16039612,2,.7084,-.2366,14837101,2,-.2933,-.2421,16304303,1,.1328,-.2421,14958138,1,-.6862,-.2504,16431164,1,-.2988,-.2504,16437431,1,-.1854,-.2504,16301481,1,.1273,-.2476,16233647,1,.2407,-.2504,15625317,1,.4483,-.2504,14497845,2,.5008,-.2504,15907255,2,.7111,-.2504,16506850,2,.119,-.2532,15968934,1,-.6918,-.2643,16575412,1,-.3044,-.2587,16504773,1,-.1771,-.2643,15897976,1,.1024,-.2643,16638178,1,.1107,-.2587,16301503,1,.2407,-.2643,15626085,1,.4483,-.2643,14431798,2,.5008,-.2643,15840950,2,.7111,-.2643,16438487,2,-.3099,-.2643,15829586,1,.0941,-.267,15355468,1,-.6945,-.2781,16175747,1,-.3182,-.2753,16087600,1,-.1716,-.2726,15966080,1,.0858,-.2726,16028303,1,.2407,-.2781,15625827,1,.4483,-.2781,14433082,2,.5008,-.2781,15906999,2,.7111,-.2781,16439001,2,.0747,-.2781,15563117,1,-.166,-.2809,16507101,1,-.321,-.2809,16099442,1,.0636,-.2836,15566200,1,-.6973,-.2919,16171100,1,-.3265,-.2919,16638412,1,-.1577,-.2892,16704475,1,.0581,-.2864,16027530,1,.2407,-.2919,15691877,1,.4483,-.2919,14236217,2,.5008,-.2919,15840435,2,.7111,-.2919,16372180,2,.047,-.2919,16297379,1,-.1494,-.2947,15830894,1,.036,-.2975,16372428,1,-.7001,-.3058,16233540,1,-.332,-.3002,16506576,1,-.1439,-.3002,16507357,1,.0194,-.303,15768726,1,.0277,-.3002,15969697,1,.2407,-.3058,15758184,1,.4483,-.3058,14104116,2,.5008,-.3058,15906229,2,.7111,-.3058,16439772,2,-.3376,-.3058,15758378,1,-.1328,-.3058,15900562,1,.0055,-.3085,16569300,1,-.1217,-.3113,16234406,1,-.0083,-.3113,15628132,1,-.7028,-.3196,16500060,1,-.3431,-.3168,16233352,1,-.1162,-.3141,16636369,1,-.1051,-.3168,16234659,1,-.0221,-.3141,15418675,1,-.0138,-.3141,16636375,1,.2407,-.3196,15758184,1,.4483,-.3196,14104372,2,.5008,-.3196,15906486,2,.7084,-.3196,14110294,2,-.036,-.3168,15486266,1,-.0913,-.3196,16364445,1,-.0775,-.3196,15755086,1,-.0636,-.3196,15685181,1,-.0498,-.3196,16029316,1,-.3486,-.3251,15829580,1,-.7056,-.3334,16372614,1,-.3514,-.3334,16507343,1,.2407,-.3334,15560550,1,.4483,-.3334,14169651,2,.5008,-.3334,15840693,2,.7084,-.3334,15107212,2,-.7056,-.3417,16497737,1,-.3569,-.3445,16641510,1,.2407,-.3473,15559779,1,.4483,-.3473,14103088,2,.5008,-.3473,15841207,2,.7084,-.3473,16442602,2,-.7084,-.35,16378045,1,-.3625,-.35,15758881,1,-.7084,-.3611,16436078,1,-.3652,-.3611,16509404,1,.2407,-.3611,15625828,1,.4483,-.3611,14235703,2,.5008,-.3611,15908028,2,.7056,-.3611,15376041,2,-.7111,-.3749,16576467,1,-.3735,-.3749,15827507,1,.2407,-.3749,15429477,1,.4483,-.3749,14368061,2,.5008,-.3749,15909054,2,.7028,-.3749,14440547,2,-.0083,-.3777,16641767,1,.0055,-.3777,16239803,1,.0194,-.3777,16305852,1,.0332,-.3777,16305595,1,.047,-.3777,16239030,1,.0609,-.3777,16172979,1,.0747,-.3777,16172209,1,.0885,-.3777,16106673,1,.1024,-.3777,16106930,1,.1162,-.3777,16172981,1,.13,-.3777,16239033,1,.1439,-.3777,16304826,1,.1577,-.3777,16304053,1,.1716,-.3777,16509407,1,-.7111,-.3888,16439185,1,-.3791,-.3888,16022572,1,-.0194,-.3888,15508355,1,-.0138,-.3832,15234374,1,.1854,-.3888,16573660,1,.2407,-.3888,15428964,1,.4483,-.3888,14302267,2,.5008,-.3888,15909311,2,.7028,-.3888,16046305,2,-.7111,-.4026,16438148,1,-.3846,-.4026,16216091,1,-.0221,-.4026,16108465,1,.1882,-.4026,16440533,1,.2407,-.4026,15429479,1,.4483,-.4026,14301496,2,.5008,-.4026,15908540,2,.7001,-.4026,15906488,2,-.7111,-.4164,16437886,1,-.3874,-.4137,16091712,1,-.0221,-.4164,16041900,1,.1882,-.4164,16441302,1,.2407,-.4164,15298407,1,.4483,-.4164,14300983,2,.5008,-.4164,15842749,2,.6973,-.4164,15978195,2,-.3901,-.422,16022823,1,-.7111,-.4303,16503681,1,-.3901,-.4303,16574939,1,-.0221,-.4303,16172457,1,.1882,-.4303,16506582,1,.2407,-.4303,15560551,1,.4483,-.4303,14168882,2,.5008,-.4303,15908798,2,.6945,-.4303,16377319,2,-.7111,-.4441,16573875,1,-.3929,-.4441,16641762,1,-.0221,-.4441,16237992,1,.1882,-.4441,16506068,1,.2407,-.4441,15560036,1,.4483,-.4441,14103347,2,.5008,-.4441,15974334,2,.6918,-.4386,15642806,2,.689,-.4469,14777729,2,-.7084,-.4579,16234062,1,-.3957,-.4579,16574425,1,-.0221,-.4579,16172197,1,.1882,-.4579,16506068,1,.2407,-.4579,15494757,1,.4483,-.4579,14236474,2,.5008,-.4579,15974335,2,.6862,-.4579,15507367,2,-.7084,-.4718,16574398,1,-.3985,-.4718,16299923,1,-.0221,-.4718,16303527,1,.1882,-.4718,16507097,1,.2407,-.4718,15493729,1,.4483,-.4718,14304321,2,.5008,-.4718,15974848,2,.6807,-.4718,13251124,2,-.7056,-.4856,16564324,1,-.4012,-.4856,16149541,1,-.0221,-.4856,16303782,1,.1882,-.4856,16507870,1,.2407,-.4856,15427422,1,.4483,-.4856,14107200,2,.5008,-.4856,15975618,2,.6779,-.4828,14507619,2,.6752,-.4884,13116201,2,-.7028,-.4994,16427322,1,-.4012,-.4994,16221515,1,-.0221,-.4994,16303267,1,.1882,-.4994,16573919,1,.2407,-.4994,15429221,1,.4483,-.4994,13908792,2,.5008,-.4994,15975105,2,.6724,-.4994,14906236,2,-.7001,-.5133,16558131,1,-.4012,-.5133,16348212,1,-.0221,-.5133,16303527,1,.1882,-.5133,16572891,1,.2407,-.5133,15363173,1,.4483,-.5133,13908279,2,.5008,-.5133,15842749,2,.6669,-.5133,14047322,2,-.6973,-.5271,16299344,1,-.3985,-.5271,16363405,1,-.2712,-.5243,16092982,1,-.2573,-.5216,16373169,1,-.2435,-.5216,16308152,1,-.2297,-.5216,16308409,1,-.2158,-.5216,16242104,1,-.202,-.5216,16176311,1,-.1882,-.5216,16176312,1,-.1743,-.5216,16242622,1,-.1605,-.5216,16243137,1,-.1467,-.5216,16243139,1,-.1328,-.5216,16309448,1,-.119,-.5216,16441289,1,-.1051,-.5216,16375237,1,-.0913,-.5216,16508885,1,-.0221,-.5271,16303783,1,.1882,-.5271,16506584,1,.2407,-.5271,15296609,1,.4483,-.5271,14039353,2,.5008,-.5271,15777469,2,.6641,-.5216,14646661,2,-.2795,-.5299,16098897,1,-.0802,-.5299,16363392,1,.6613,-.5299,16042191,2,-.6945,-.5382,16431709,1,-.3957,-.541,16505029,1,-.285,-.541,16509391,1,-.0747,-.541,16632492,1,-.0221,-.541,16369319,1,.1882,-.541,16572891,1,.2407,-.541,15296609,1,.4483,-.541,13974329,2,.5008,-.541,15909570,2,.6558,-.541,15177369,2,-.6918,-.5465,16557621,1,-.6918,-.5548,16708314,1,-.3929,-.5548,16498594,1,-.285,-.5548,16576217,1,-.0747,-.5548,16501936,1,-.0221,-.5548,16303527,1,.1882,-.5548,16507097,1,.2407,-.5548,15231331,1,.4483,-.5548,13842228,2,.5008,-.5548,15909571,2,.653,-.5493,16113637,2,.6475,-.5576,14580609,2,-.6862,-.5686,16700286,1,-.3901,-.5659,16432031,1,-.285,-.5686,16642524,1,-.0747,-.5686,16502711,1,-.0221,-.5686,16303270,1,.1882,-.5686,16571862,1,.2407,-.5686,15296867,1,.4483,-.5686,13643565,2,.5008,-.5686,15975621,2,.6419,-.5686,14845841,2,-.3874,-.5714,16641765,1,-.6835,-.5797,16707799,1,-.3846,-.5825,16565166,1,-.285,-.5825,16642010,1,-.0747,-.5825,16568505,1,-.0221,-.5825,16303526,1,.1882,-.5825,16506841,1,.2407,-.5825,15428709,1,.4483,-.5825,13643565,2,.5008,-.5825,15975363,2,.6364,-.5769,13185078,2,.6336,-.5852,15843009,2,-.6779,-.588,16488986,1,-.6752,-.5963,16361774,1,-.3791,-.5963,16488559,1,-.285,-.5963,16642268,1,-.0747,-.5963,16503483,1,-.0221,-.5963,16237733,1,.1882,-.5963,16506583,1,.2407,-.5963,15363944,1,.4483,-.5963,13840432,2,.5008,-.5963,15777727,2,.6253,-.5963,12791349,2,-.6696,-.6101,16364363,1,-.3763,-.6046,16079653,1,-.285,-.6101,16643041,1,-.0747,-.6101,16504514,1,-.0221,-.6101,16369062,1,.1882,-.6101,16505810,1,.2407,-.6101,15429224,1,.4483,-.6101,13774896,2,.5008,-.6101,15777212,2,.6226,-.6046,15575471,2,-.3708,-.6101,16708073,1,.617,-.6129,15107727,2,-.6669,-.6184,16638382,1,-.3652,-.6212,16633527,1,-.285,-.624,16642525,1,-.0747,-.624,16504257,1,-.0221,-.624,16369319,1,.1882,-.624,16505811,1,.2407,-.624,15429737,1,.4483,-.624,13710387,2,.5008,-.624,15843005,2,.6115,-.6212,14978191,2,-.6641,-.624,16637610,1,-.3597,-.6295,16571857,1,.606,-.6295,14451590,2,-.6558,-.6378,16163119,1,-.3597,-.635,16078613,1,-.285,-.6378,16576216,1,-.0747,-.6378,16503998,1,-.0221,-.6378,16369319,1,.1882,-.6378,16506326,1,.2407,-.6378,15299178,1,.4483,-.6378,13776693,2,.5008,-.6378,15843262,2,.6004,-.6378,14584720,2,-.5617,-.6406,16569523,1,-.5479,-.6378,15760688,1,-.534,-.6378,15891762,1,-.5202,-.6378,15891507,1,-.5064,-.6378,15890739,1,-.4925,-.6378,15890229,1,-.4787,-.6378,15955511,1,-.4649,-.6378,15889462,1,-.451,-.6378,15823670,1,-.4372,-.6378,15822904,1,-.4234,-.6378,15821876,1,-.4095,-.6378,15820590,1,-.3957,-.6378,16017454,1,-.3818,-.6378,15950374,1,-.368,-.6378,16146977,1,-.57,-.6433,16167791,1,-.653,-.6461,16571819,1,-.5755,-.6489,16640469,1,-.285,-.6516,16642266,1,-.0747,-.6516,16504771,1,-.0221,-.6516,16303011,1,.1882,-.6516,16507098,1,.2407,-.6516,15364201,1,.4483,-.6516,13644848,2,.5008,-.6516,15710648,2,.5949,-.6461,15437716,2,-.6502,-.6516,16640970,1,.5894,-.6544,15710138,2,-.5838,-.6572,16165977,1,-.6419,-.6655,16705732,1,-.5866,-.6655,16231774,1,-.285,-.6655,16575958,1,-.0747,-.6655,16570307,1,-.0221,-.6655,16171167,1,.1882,-.6655,16572891,1,.2407,-.6655,15232357,1,.4483,-.6655,13579056,2,.5008,-.6655,15776442,2,.5838,-.6627,16178140,2,.5783,-.6682,14840174,2,-.6336,-.6793,16441795,1,-.5866,-.6793,16436376,1,-.285,-.6793,16575441,1,-.0747,-.6793,16503997,1,-.0221,-.6793,16171423,1,.1882,-.6793,16573404,1,.2407,-.6793,15035493,1,.4483,-.6793,13644849,2,.5008,-.6793,15711419,2,.5728,-.6765,15973055,2,.5645,-.6848,13721700,2,-.6253,-.6904,16365648,1,-.5866,-.6931,16505010,1,-.285,-.6931,16575699,1,-.0747,-.6931,16503998,1,-.0221,-.6931,16303010,1,.1882,-.6931,16573404,1,.2407,-.6931,15099746,1,.4483,-.6931,13578800,2,.5008,-.6931,15644341,2,.5589,-.6931,15642034,2,-.5202,-.6931,16570201,1,-.5064,-.6931,16569695,1,-.4925,-.6931,16503387,1,-.4787,-.6931,16568924,1,-.4649,-.6931,16502622,1,-.451,-.6931,16436832,1,-.4372,-.6931,16502373,1,-.4234,-.6931,16502119,1,-.4095,-.6931,16436072,1,-.3957,-.6931,16501350,1,-.3818,-.6931,16435041,1,-.368,-.6931,16434781,1,-.3542,-.6931,16436333,1,-.6226,-.6959,16375738,1,-.5313,-.6959,16709854,1,-.3459,-.6959,16504976,1,-.6143,-.707,16307100,1,-.5866,-.707,16439470,1,-.5368,-.707,16377500,1,-.3376,-.707,16506780,1,-.285,-.707,16641236,1,-.0747,-.707,16504e3,1,-.0221,-.707,16237217,1,.1882,-.707,16508127,1,.2407,-.707,15099746,1,.4483,-.707,13446959,2,.5008,-.707,15578548,2,.5451,-.707,13123395,2,-.6032,-.7208,16365908,1,-.5866,-.7208,16569502,1,-.5368,-.7208,16441998,1,-.3376,-.7208,16566105,1,-.285,-.7208,16641236,1,-.0747,-.7208,16437948,1,-.0221,-.7208,16170909,1,.1882,-.7208,16573920,1,.2407,-.7208,15233130,1,.4483,-.7208,13579058,2,.5008,-.7208,15645112,2,.5396,-.7153,15776958,2,.534,-.7208,15508648,2,-.5977,-.7291,16306585,1,-.5866,-.7346,16701864,1,-.5368,-.7346,16441994,1,-.3376,-.7346,16566621,1,-.285,-.7346,16641751,1,-.0747,-.7346,16503483,1,-.0221,-.7346,16171169,1,.1882,-.7346,16573407,1,.2407,-.7346,15168622,1,.4483,-.7346,13448499,2,.5008,-.7346,15449789,2,.5257,-.7291,15641010,2,.5202,-.7346,15312550,2,-.5368,-.7485,16441477,1,-.3376,-.7485,16501090,1,-.285,-.7485,16642267,1,-.0747,-.7485,16503227,1,-.0221,-.7485,16171939,1,.1882,-.7485,16507871,1,.2407,-.7485,15101801,1,.4483,-.7485,13316913,2,.5008,-.7485,15184564,2,.5119,-.7429,16104897,2,-.5368,-.7623,16441217,1,-.3376,-.7623,16567396,1,-.285,-.7623,16642267,1,-.0747,-.7623,16502713,1,-.0221,-.7623,16236960,1,.1882,-.7623,16574178,1,.2407,-.7623,14969957,1,.4483,-.7623,13317428,2,-.5368,-.7761,16441213,1,-.3376,-.7761,16567915,1,-.285,-.7761,16642008,1,-.0747,-.7761,16503483,1,-.0221,-.7761,16170911,1,.1882,-.7761,16507869,1,.2407,-.7761,14838116,1,.4483,-.7761,13450816,2,-.5368,-.79,16572533,1,-.3376,-.79,16502380,1,-.285,-.79,16642008,1,-.0747,-.79,16504513,1,-.0221,-.79,16236446,1,.1882,-.79,16506841,1,.2407,-.79,14837087,1,.4483,-.79,13716303,2,-.5313,-.8011,16709860,1,-.3376,-.8038,16567911,1,-.285,-.8038,16642006,1,-.0747,-.8038,16504256,1,-.0221,-.8038,16170652,1,.1882,-.8038,16573405,1,.2407,-.8038,14771040,1,.4455,-.8011,16239828,2,-.523,-.8066,16642236,1,.4372,-.8066,15576242,2,-.5174,-.8121,16710633,1,-.3376,-.8177,16567913,1,-.285,-.8177,16641491,1,-.0747,-.8177,16569791,1,-.0221,-.8177,16105118,1,.1882,-.8177,16507869,1,.2407,-.8177,14508641,1,.4289,-.8121,15378601,2,-.5064,-.8204,16710110,1,.4206,-.8177,15112092,2,.4123,-.8232,14318201,2,-.4925,-.8287,16241501,1,-.3376,-.8315,16568174,1,-.285,-.8315,16641491,1,-.0747,-.8315,16570821,1,-.0221,-.8315,16237475,1,.1882,-.8315,16572890,1,.2407,-.8315,14375256,1,.404,-.8287,13920109,2,.3957,-.8343,14647686,2,-.4842,-.8343,16239697,1,-.4759,-.8426,16643546,1,-.3376,-.8453,16502636,1,-.285,-.8453,16640975,1,-.0747,-.8453,16570566,1,-.0221,-.8453,16237217,1,.1882,-.8453,16572890,1,.2407,-.8453,14375511,1,.3874,-.8398,15179684,2,.3791,-.8453,16235965,2,-.4649,-.8481,16241513,1,.368,-.8509,14777985,2,-.451,-.8564,16436565,1,-.3376,-.8592,16567916,1,-.285,-.8592,16574926,1,-.0747,-.8592,16504772,1,-.0221,-.8592,16171166,1,.1882,-.8592,16507097,1,.2407,-.8592,14245208,1,.3625,-.8536,14379372,2,.3514,-.8592,13452870,2,-.44,-.8647,16708557,1,.3431,-.8647,14382197,2,-.4344,-.8675,16641208,1,-.3376,-.873,16502900,1,-.285,-.873,16641233,1,-.0747,-.873,16504513,1,-.0221,-.873,16303525,1,.1882,-.873,16572634,1,.2407,-.873,14376794,1,.3376,-.8675,13718101,2,-.4234,-.873,16442791,1,.3237,-.8758,15912143,2,-.4151,-.8758,16302405,1,.3154,-.8785,14185845,2,-.4068,-.8813,16505742,1,-.3376,-.8868,16371313,1,-.285,-.8868,16575696,1,-.0747,-.8868,16570307,1,-.0221,-.8868,16303780,1,.1882,-.8868,16573664,1,.2407,-.8868,14442845,1,.3099,-.8813,14252154,2,-.3957,-.8868,16637072,1,.2961,-.8896,16641e3,2,-.3846,-.8924,16508335,1,.285,-.8924,14314088,2,-.3791,-.8951,16510149,1,-.3376,-.9007,16501873,1,-.285,-.9007,16575181,1,-.0747,-.9007,16570563,1,-.0221,-.9007,16237473,1,.1882,-.9007,16574178,1,.2407,-.9007,14577514,1,.2795,-.8951,15113114,1,-.368,-.8979,16234563,1,.2684,-.8979,13317171,1,-.3542,-.9062,16643554,1,.2546,-.9062,16372955,1,-.3403,-.9117,16709858,1,-.285,-.9145,16575184,1,-.0747,-.9145,16505543,1,-.0221,-.9145,16303008,1,.1882,-.9145,16573406,1,.2435,-.9117,16638687,1,-.285,-.9283,16508624,1,-.0747,-.9283,16505287,1,-.0221,-.9283,16303263,1,.1854,-.9283,15436919,1,-.2712,-.9339,16442309,1,.1716,-.9339,16706275,1,.1633,-.9339,14904400,1,-.2573,-.9366,16173206,1,-.0747,-.9422,16373698,1,-.0221,-.9422,16105371,1,.155,-.9366,15636348,1,-.2435,-.9394,15904368,1,.1439,-.9394,15839903,1,-.2297,-.9422,15967836,1,.13,-.9422,15640213,1,-.2158,-.9449,16099686,1,.1024,-.9477,16235947,1,.1162,-.9449,15704204,1,-.202,-.9477,16167023,1,.0941,-.9477,15298119,1,-.1882,-.9505,16433552,1,-.1743,-.9532,16638406,1,-.0747,-.956,16370611,1,-.0221,-.956,16040093,1,.0747,-.9532,16707305,1,.0858,-.9505,16565683,1,-.1605,-.956,16708322,1,.0609,-.9532,15566944,1,-.1467,-.956,16034932,1,-.1328,-.9588,16642274,1,.0332,-.956,15300684,1,.047,-.956,16237482,1,-.119,-.9588,16171676,1,-.1051,-.9588,15702889,1,-.0913,-.9588,15633496,1,-.0083,-.9588,15567706,1,.0055,-.9588,15638908,1,.0194,-.9588,16437174,1,.3182,.956,16688401,0,.3348,.956,16620813,0,.3044,.9532,16488973,0,.2933,.9505,16642512,3,.2878,.9394,16621070,0,.3016,.9422,16621579,0,.3182,.9422,16687882,0,.3348,.9422,16688140,0,.3459,.9422,16627780,3,.2739,.9339,16365396,3,.2712,.9228,16686603,0,.285,.9256,16621323,0,.3016,.9256,16621578,0,.3182,.9256,16687115,0,.3348,.9256,16687627,0,.2573,.92,16557866,0,.2546,.9062,16686094,0,.2684,.909,16686603,0,.285,.909,16686858,0,.3016,.909,16686603,0,.3182,.909,16686860,0,.332,.909,16490521,0,.2407,.9034,16553995,0,.2352,.8924,16620047,0,.2518,.8924,16620554,0,.2684,.8924,16624161,0,.285,.8924,16685834,0,.3016,.8924,16686090,0,.3182,.8924,16686347,0,.2214,.8868,16486922,0,.2048,.873,16292382,0,.2186,.8758,16619276,0,.2352,.8758,16620040,0,.2518,.8758,16690471,0,.2684,.8758,16619787,0,.285,.8758,16685579,0,.3016,.8758,16685579,0,.3154,.8758,16566398,3,.1882,.8564,16488212,0,.202,.8592,16620303,0,.2186,.8592,16620043,0,.2352,.8592,16691240,0,.2518,.8592,16487178,0,.2684,.8592,16619531,0,.285,.8592,16619531,0,.3016,.8592,16685837,0,.1716,.8398,16289819,0,.1854,.8426,16685581,0,.202,.8426,16620555,0,.2186,.8426,16625960,0,.2352,.8426,16421641,0,.2518,.8426,16552714,0,.2684,.8426,16618506,0,.285,.8426,16618507,0,.155,.8232,16425777,0,.1688,.826,16685070,0,.1854,.826,16620041,0,.202,.826,16625960,0,.2186,.826,16624930,0,.2352,.826,16552458,0,.2518,.826,16551944,0,.2684,.826,16617737,0,.285,.826,16617229,0,.1522,.8094,16619533,0,.1688,.8094,16620041,0,.1854,.8094,16625957,0,.202,.8094,16560159,0,.2186,.8094,16617225,0,.2352,.8094,16617224,0,.2518,.8094,16616967,0,.2684,.8094,16616711,0,.2822,.8094,16550409,0,.1411,.8038,16685324,0,.1356,.7928,16685067,0,.1522,.7928,16685322,0,.1688,.7928,16626470,0,.1854,.7928,16625952,0,.202,.7928,16550663,0,.2186,.7928,16616713,0,.2352,.7928,16616455,0,.2518,.7928,16616455,0,.2684,.7928,16616456,0,.2795,.7955,16628576,3,.1245,.7872,16551946,0,.1217,.7734,16685071,0,.1356,.7761,16685066,0,.1522,.7761,16423692,0,.1688,.7761,16560930,0,.1854,.7761,16559906,0,.202,.7761,16550409,0,.2186,.7761,16616457,0,.2352,.7761,16616201,0,.2518,.7761,16615943,0,.2684,.7761,16615432,0,.1051,.7568,16684558,0,.119,.7595,16685068,0,.1356,.7595,16685836,0,.1522,.7595,16627493,0,.1688,.7595,16560929,0,.1854,.7595,16550410,0,.202,.7595,16550152,0,.2186,.7595,16549896,0,.2352,.7595,16680968,0,.2518,.7595,16680710,0,.2656,.7595,16485404,0,.0941,.7512,16486671,0,.0885,.7402,16684812,0,.1024,.7429,16684810,0,.119,.7429,16684810,0,.1356,.7429,16630069,0,.1522,.7429,16561698,0,.1688,.7429,16490004,0,.1854,.7429,16549896,0,.202,.7429,16549383,0,.2186,.7429,16614663,0,.2352,.7429,16614664,0,.2518,.7429,16614921,0,.2629,.7457,16634258,3,.0775,.7346,16707539,3,.0747,.7236,16682507,0,.0858,.7263,16618765,0,.1024,.7263,16619528,0,.119,.7263,16632130,0,.1356,.7263,16628776,0,.1522,.7263,16627489,0,.1688,.7263,16549385,0,.1854,.7263,16549383,0,.202,.7263,16548871,0,.2186,.7263,16548615,0,.2352,.7263,16614151,0,.2518,.7263,16614666,0,.0692,.7097,16618250,0,.0858,.7097,16618761,0,.1024,.7097,16491801,0,.119,.7097,16698180,0,.1356,.7097,16628518,0,.1522,.7097,16490007,0,.1688,.7097,16548615,0,.1854,.7097,16614150,0,.202,.7097,16548103,0,.2186,.7097,16613382,0,.2352,.7097,16613383,0,.249,.7097,16480774,0,.0581,.7042,16027929,0,.0553,.6904,16683274,0,.0692,.6931,16618247,0,.0858,.6931,16618758,0,.1024,.6931,16698444,0,.119,.6931,16628776,0,.1356,.6931,16628519,0,.1522,.6931,16613640,0,.1688,.6931,16547845,0,.1854,.6931,16613638,0,.202,.6931,16547846,0,.2186,.6931,16547334,0,.2352,.6931,16612615,0,.2463,.6931,16414729,0,.0443,.6876,16706767,3,.0387,.6738,16354573,0,.0526,.6765,16684296,0,.0692,.6765,16618504,0,.0858,.6765,16566095,0,.1024,.6765,16697417,0,.119,.6765,16628779,0,.1356,.6765,16626730,0,.1522,.6765,16482054,0,.1688,.6765,16481542,0,.1854,.6765,16481544,0,.202,.6765,16481800,0,.2186,.6765,16547336,0,.2352,.6765,16546824,0,.2463,.6793,16572864,3,.036,.6599,16683792,0,.0526,.6599,16684041,0,.0692,.6599,16554254,0,.0858,.6599,16631364,0,.1024,.6599,16562729,0,.119,.6599,16628264,0,.1356,.6599,16482055,0,.1522,.6599,16415750,0,.1688,.6599,16481030,0,.1854,.6599,16481031,0,.202,.6599,16481288,0,.2186,.6599,16481289,0,.2352,.6599,16546828,0,.0249,.6544,16365403,3,.0221,.6406,16684557,0,.036,.6433,16684300,0,.0526,.6433,16684042,0,.0692,.6433,16631367,0,.0858,.6433,16631364,0,.1024,.6433,16628518,0,.119,.6433,16562213,0,.1356,.6433,16481542,0,.1522,.6433,16480774,0,.1688,.6433,16480519,0,.1854,.6433,16480263,0,.202,.6433,16480776,0,.2186,.6433,16480521,0,.2352,.6433,16545547,0,.0083,.624,16289303,0,.0194,.6267,16683791,0,.036,.6267,16684299,0,.0526,.6267,16694078,0,.0692,.6267,16696644,0,.0858,.6267,16629291,0,.1024,.6267,16693796,0,.119,.6267,16557336,0,.1356,.6267,16547078,0,.1522,.6267,16480517,0,.1688,.6267,16414213,0,.1854,.6267,16479750,0,.202,.6267,16545542,0,.2186,.6267,16545544,0,.2324,.6267,16611594,0,.0055,.6074,16683531,0,.0194,.6101,16683531,0,.036,.6101,16683786,0,.0526,.6101,16696645,0,.0692,.6101,16696643,0,.0858,.6101,16628519,0,.1024,.6101,16627491,0,.119,.6101,16546309,0,.1356,.6101,16546053,0,.1522,.6101,16545285,0,.1688,.6101,16413958,0,.1854,.6101,16479494,0,.202,.6101,16479238,0,.2186,.6101,16544776,0,.2324,.6101,16543747,0,-.0083,.5908,16550155,0,.0028,.5935,16683531,0,.0194,.5935,16683529,0,.036,.5935,16694333,0,.0526,.5935,16630850,0,.0692,.5935,16630585,0,.0858,.5935,16693541,0,.1024,.5935,16627236,0,.119,.5935,16480263,0,.1356,.5935,16480006,0,.1522,.5935,16479237,0,.1688,.5935,16544518,0,.1854,.5935,16478726,0,.202,.5935,16544262,0,.2186,.5935,16544006,0,.2324,.5935,16544776,0,-.0111,.5742,16682766,0,.0028,.5769,16683274,0,.0194,.5769,16682762,0,.036,.5769,16630335,0,.0526,.5769,16630077,0,.0692,.5769,16628261,0,.0858,.5769,16693284,0,.1024,.5769,16561955,0,.119,.5769,16480006,0,.1356,.5769,16479238,0,.1522,.5769,16478981,0,.1688,.5769,16478471,0,.1854,.5769,16543750,0,.202,.5769,16477957,0,.2186,.5769,16543238,0,.2297,.5769,16410370,0,-.0221,.5686,16504479,0,-.0249,.5576,16353036,0,-.0138,.5603,16682763,0,.0028,.5603,16682762,0,.0194,.5603,16555542,0,.036,.5603,16695610,0,.0526,.5603,16563507,0,.0692,.5603,16693541,0,.0858,.5603,16693285,0,.1024,.5603,16624928,0,.119,.5603,16413446,0,.1356,.5603,16478470,0,.1522,.5603,16412679,0,.1688,.5603,16477701,0,.1854,.5603,16477701,0,.202,.5603,16477444,0,.2186,.5603,16542726,0,.2297,.5603,16475394,0,-.0277,.5437,16681995,0,-.0138,.5465,16682507,0,.0028,.5465,16682764,0,.0194,.5465,16565051,0,.036,.5465,16629814,0,.0526,.5465,16629300,0,.0692,.5465,16693284,0,.0858,.5465,16692771,0,.1024,.5465,16219657,0,.119,.5465,16412677,0,.1356,.5465,16412165,0,.1522,.5465,16477188,0,.1688,.5465,16476933,0,.1854,.5465,16476678,0,.202,.5465,16476677,0,.2186,.5465,16542214,0,.2297,.5465,16540419,0,.3154,.9532,16688141,0,.3348,.9532,16688402,0,.2822,.9283,16621581,0,.3099,.9339,16687370,0,.3348,.9339,16622346,0,.2573,.9173,16685320,0,.2463,.8979,16620302,0,.2767,.9007,16621066,0,.3099,.9007,16686347,0,.332,.9117,16554509,0,.2241,.8868,16685839,0,.2131,.8647,16619789,0,.2435,.8675,16624164,0,.2767,.8675,16619787,0,.3044,.8702,16685325,0,.1909,.8536,16686098,0,.1799,.8315,16619787,0,.2103,.8343,16625705,0,.2435,.8343,16552457,0,.2767,.8343,16617737,0,.2961,.8453,16618763,0,.1577,.8204,16685840,0,.1467,.7983,16685324,0,.1771,.8011,16626213,0,.2103,.8011,16616713,0,.2435,.8011,16616711,0,.2712,.8011,16616454,0,.1162,.7623,16685068,0,.1439,.7678,16553995,0,.1771,.7678,16494882,0,.2103,.7678,16550152,0,.2435,.7678,16615432,0,.2656,.7706,16616461,0,.0858,.7291,16618765,0,.1107,.7346,16619529,0,.1439,.7346,16627491,0,.1771,.7346,16615433,0,.2103,.7346,16548870,0,.2435,.7346,16614408,0,.0802,.6987,16618759,0,.1107,.7014,16698185,0,.1439,.7014,16627493,0,.1771,.7014,16613638,0,.2103,.7014,16547590,0,.238,.7014,16547336,0,.0553,.6931,16683785,0,.047,.6655,16684298,0,.0775,.6682,16630861,0,.1107,.6682,16563244,0,.1439,.6682,16416263,0,.1771,.6682,16415751,0,.2103,.6682,16481288,0,.2352,.6682,16481290,0,.0277,.6544,16683277,0,.0194,.6295,16683791,0,.0443,.635,16684299,0,.0775,.635,16631109,0,.1107,.635,16628004,0,.1439,.635,16481029,0,.1771,.635,16414214,0,.2103,.635,16480007,0,.2324,.635,16611852,0,.0138,.5991,16683530,0,.0443,.6018,16565317,0,.0775,.6018,16628521,0,.1107,.6018,16690721,0,.1439,.6018,16480006,0,.1771,.6018,16413445,0,.2103,.6018,16478982,0,.2297,.6018,16544521,0,-.0138,.5659,16682763,0,.0111,.5686,16683018,0,.0443,.5686,16629819,0,.0775,.5686,16693540,0,.1107,.5686,16545031,0,.1439,.5686,16412934,0,.1771,.5686,16477702,0,.2103,.5686,16477445,0,.2297,.5686,16475650,0,-.0194,.5327,16681995,0,.0111,.5354,16624425,0,.0443,.5354,16629041,0,.0775,.5354,16692515,0,.1107,.5354,16346372,0,.1439,.5354,16411140,0,.1771,.5354,16410629,0,.2103,.5354,16476166,0,.2297,.5327,16409348,0,-.0387,.5216,16614153,0,-.0443,.4967,16681228,0,-.0221,.5022,16614923,0,.0111,.5022,16694581,0,.0443,.5022,16626983,0,.0775,.5022,16691491,0,.1107,.5022,16280068,0,.1439,.5022,16279302,0,.1771,.5022,16343813,0,.2103,.5022,16409349,0,.2324,.4994,16537602,0,-.0498,.4662,16680720,0,-.0221,.469,16614412,0,.0111,.469,16693037,0,.0443,.469,16691489,0,.0775,.469,16690722,0,.1107,.469,16278276,0,.1439,.469,16343302,0,.1771,.469,16277253,0,.2103,.469,16341765,0,.2324,.4662,16472583,0,-.0526,.433,16679692,0,-.0221,.4358,16547338,0,.0111,.4358,16625701,0,.0443,.4358,16690465,0,.0775,.4358,16689953,0,.1107,.4358,16211459,0,.1439,.4358,16276229,0,.1771,.4358,16274948,0,.2103,.4358,16209158,0,.2352,.433,16142853,0,-.0747,.4275,16219155,0,-.0775,.3998,16612878,0,-.0553,.4026,16678412,0,-.0221,.4026,16561450,0,.0111,.4026,16624930,0,.0443,.4026,16624159,0,.0775,.4026,16689441,0,.1107,.4026,16209923,0,.1439,.4026,16209412,0,.1771,.4026,16143365,0,.2103,.4026,16207621,0,.238,.3998,16141317,0,-.2463,.3943,16680974,0,-.2241,.3915,16681741,0,-.2463,.3694,16680205,0,-.2214,.3694,16680462,0,-.0802,.3666,16679694,0,-.0553,.3694,16678159,0,-.0221,.3694,16690468,0,.0111,.3694,16623904,0,.0443,.3694,16623136,0,.0775,.3694,16622623,0,.1107,.3694,16142851,0,.1439,.3694,16142853,0,.1771,.3694,16141829,0,.2103,.3694,16074756,0,.2435,.3666,16204805,0,-.1937,.3611,16680207,0,-.2407,.339,16680204,0,-.2214,.3362,16679438,0,-.1882,.3334,16679436,0,-.0858,.3334,16678159,0,-.0553,.3362,16676878,0,-.0221,.3362,16689442,0,.0111,.3362,16688673,0,.0443,.3362,16622111,0,.0775,.3362,16687391,0,.1107,.3362,16142340,0,.1439,.3362,16141573,0,.1771,.3362,16075013,0,.2103,.3362,16073477,0,.2435,.3362,16072708,0,.2656,.3307,16070411,0,-.166,.3251,16677648,0,-.238,.3168,16615191,0,-.2186,.303,16679182,0,-.1882,.303,16677900,0,-.1577,.3002,16677133,0,-.0885,.303,16609806,0,-.0553,.303,16609292,0,-.0221,.303,16687646,0,.0111,.303,16687135,0,.0443,.303,16686365,0,.0775,.303,16686366,0,.1107,.303,15682818,0,.1439,.303,16074757,0,.1771,.303,16007940,0,.2103,.303,16007173,0,.2435,.303,15940613,0,.2684,.3002,16005383,0,-.1051,.2947,16608010,0,-.2186,.2698,16679694,0,-.1882,.2698,16677387,0,-.155,.2698,16676618,0,-.1134,.2615,16413977,0,-.0885,.2698,16543245,0,-.0553,.2698,16214794,0,-.0221,.2698,16620574,0,.0111,.2698,16685596,0,.0443,.2698,16684827,0,.0775,.2698,16553499,0,.1107,.2698,16620578,0,.1439,.2698,16073476,0,.1771,.2698,16072197,0,.2103,.2698,16005893,0,.2435,.2698,15873797,0,.2739,.267,15938308,0,-.2186,.2338,16678926,0,-.1882,.2366,16676619,0,-.155,.2366,16675594,0,-.1217,.2338,16616491,0,-.0885,.2366,16607500,0,-.0553,.2366,16487708,0,-.0221,.2366,16684829,0,.0111,.2366,16684059,0,.0443,.2366,16683290,0,.0775,.2366,16617499,0,.1107,.2366,16551708,0,.1439,.2366,16006660,0,.1771,.2366,16071430,0,.2103,.2366,15939589,0,.2435,.2366,15937796,0,.2767,.2366,15805699,0,.2988,.2283,15802625,2,-.2214,.2034,16677388,0,-.1882,.2034,16675850,0,-.155,.2034,16674827,0,-.1217,.2034,16608012,0,-.0885,.2034,16606989,0,-.0553,.2034,16683804,0,-.0221,.2034,16617754,0,.0111,.2034,16616729,0,.0443,.2034,16616472,0,.0775,.2034,16616218,0,.1107,.2034,16615708,0,.1439,.2034,15939843,0,.1771,.2034,15938820,0,.2103,.2034,15872516,0,.2435,.2034,15871493,0,.2767,.2034,15739396,0,.3016,.2006,15608068,2,-.2407,.1951,16544009,0,-.2463,.1674,16675852,0,-.2214,.1702,16675851,0,-.1882,.1702,16675339,0,-.155,.1702,16673804,0,-.1217,.1702,16607245,0,-.0885,.1702,16540430,0,-.0553,.1702,16616987,0,-.0221,.1702,16615704,0,.0111,.1702,16615448,0,.0443,.1702,16614680,0,.0775,.1702,16549144,0,.1107,.1702,16614426,0,.1439,.1702,15873026,0,.1771,.1702,15872003,0,.2103,.1702,15806212,0,.2435,.1702,15805189,0,.2767,.1702,15738373,0,.3071,.1674,15672838,2,-.3874,.1646,16684812,0,.5506,.1646,15080225,2,.5755,.1646,15145759,2,-.4151,.1619,16684301,0,.5949,.1563,14684703,2,-.4206,.137,16683531,0,-.3874,.137,16683018,0,-.2518,.1342,16611597,0,-.2214,.137,16675339,0,-.1882,.137,16674573,0,-.155,.137,16607500,0,-.1217,.137,16540430,0,-.0885,.137,16550684,0,-.0553,.137,16615705,0,-.0221,.137,16548631,0,.0111,.137,16548119,0,.0443,.137,16547863,0,.0775,.137,16546837,0,.1107,.137,16612631,0,.1439,.137,15806467,0,.1771,.137,15740420,0,.2103,.137,15739395,0,.2435,.137,15738628,0,.2767,.137,15671811,0,.3099,.1342,15606022,2,.5479,.1342,14949152,2,.5755,.137,14883615,2,.6004,.1314,14948897,2,-.4455,.1287,16684306,0,-.2739,.1231,16544266,0,-.451,.101,16685067,0,-.4206,.1038,16616971,0,-.3874,.101,16681992,0,-.2822,.0982,16611084,0,-.2546,.1038,16676108,0,-.2214,.1038,16674828,0,-.1882,.1038,16607756,0,-.155,.1038,16540684,0,-.1217,.1038,16408333,0,-.0885,.1038,16549145,0,-.0553,.1038,16483096,0,-.0221,.1038,16546325,0,.0111,.1038,16546068,0,.0443,.1038,16546070,0,.0775,.1038,16479765,0,.1107,.1038,16545817,0,.1439,.1038,15805955,0,.1771,.1038,15739139,0,.2103,.1038,15804163,0,.2435,.1038,15672067,0,.2767,.1038,15540228,0,.3099,.101,15408389,2,.5451,.101,15080479,2,.5755,.1038,14883103,2,.6087,.101,14817569,2,-.4787,.0955,16685071,0,.6281,.0899,14159126,2,-.4842,.0678,16619019,0,-.4538,.0706,16625956,0,-.4206,.0706,16682506,0,-.3874,.0678,16681481,0,-.2878,.0706,16676106,0,-.2546,.0706,16675084,0,-.2214,.0706,16608267,0,-.1882,.0706,16606732,0,-.155,.0706,16474380,0,-.1217,.0706,16548377,0,-.0885,.0706,16547864,0,-.0553,.0706,16479252,0,-.0221,.0706,16544533,0,.0111,.0706,16478483,0,.0443,.0706,16412692,0,.0775,.0706,16412436,0,.1107,.0706,16281109,0,.1439,.0706,15805444,0,.1771,.0706,15804420,0,.2103,.0706,15737603,0,.2435,.0706,15605764,0,.2767,.0706,15473668,0,.3099,.0706,15342085,2,.523,.065,14748695,2,.5423,.0706,15080737,2,.5755,.0706,14817823,2,.6087,.0706,14620704,2,.6336,.065,14293021,2,-.3127,.0623,16545041,0,-.5091,.0595,16618251,0,-.5174,.0346,16684808,0,-.487,.0374,16626733,0,-.4538,.0374,16624928,0,-.4206,.0374,16616201,0,-.3874,.0374,16679946,0,-.3182,.0346,16611085,0,-.2878,.0374,16609803,0,-.2546,.0374,16608524,0,-.2214,.0374,16672780,0,-.1882,.0374,16606220,0,-.155,.0374,16548378,0,-.1217,.0374,16482072,0,-.0885,.0374,16412178,0,-.0553,.0374,16411667,0,-.0221,.0374,16411412,0,.0111,.0374,16345363,0,.0443,.0374,16344851,0,.0775,.0374,16344850,0,.1107,.0374,15672834,0,.1439,.0374,15804677,0,.1771,.0374,15606788,0,.2103,.0374,15606020,0,.2435,.0374,15604740,0,.2767,.0374,15472644,0,.3099,.0374,15340292,2,.5174,.0346,15014945,2,.5423,.0374,14818079,2,.5755,.0374,14752032,2,.6087,.0374,14424096,2,.6392,.0346,14161182,2,-.3486,.0291,16611086,0,-.5396,.0235,16618511,0,-.5479,-.0014,16620041,0,-.5202,.0042,16685833,0,-.487,.0042,16625440,0,-.4538,.0042,16681995,0,-.4206,.0042,16680713,0,-.3874,.0042,16613129,0,-.3542,.0042,16545033,0,-.321,.0042,16609803,0,-.2878,.0042,16608778,0,-.2546,.0042,16673547,0,-.2214,.0042,16606732,0,-.1882,.0042,16408331,0,-.155,.0042,16481305,0,-.1217,.0042,16349464,0,-.0885,.0042,16410131,0,-.0553,.0042,16344339,0,-.0221,.0042,16344083,0,.0111,.0042,16277265,0,.0443,.0042,16277265,0,.0775,.0042,16277011,0,.1107,.0042,15738114,0,.1439,.0042,15803139,0,.1771,.0042,15671300,0,.2103,.0042,15604483,0,.2435,.0042,15472643,0,.2767,.0042,15340291,0,.3071,.0042,15208452,2,.5119,.0014,15014688,2,.5423,.0042,14948896,2,.5755,.0042,14751775,2,.6087,.0042,14424097,2,.6419,.0014,14292254,2,.6613,-.0069,14293026,2,.4925,-.0097,14816026,2,-.5755,-.0346,16686601,0,-.5534,-.0291,16620553,0,-.5202,-.0291,16564807,0,-.487,-.0291,16690462,0,-.4538,-.0291,16615689,0,-.4206,-.0291,16679433,0,-.3874,-.0291,16612106,0,-.3542,-.0291,16610313,0,-.321,-.0291,16609033,0,-.2878,-.0291,16673545,0,-.2546,-.0291,16606987,0,-.2214,-.0291,16474123,0,-.1882,-.0291,16481047,0,-.155,-.0291,16348952,0,-.1217,-.0291,16276752,0,-.0885,-.0291,16342033,0,-.0553,-.0291,16276753,0,-.0221,-.0291,16342035,0,.0111,-.0291,16209936,0,.0443,-.0291,16209936,0,.0775,-.0291,16078866,0,.1107,-.0291,15737602,0,.1439,-.0291,15671555,0,.1771,-.0291,15604739,0,.2103,-.0291,15538179,0,.2435,-.0291,15405826,0,.2767,-.0291,15273474,0,.3016,-.0291,14879489,2,.4842,-.0346,14949667,2,.5091,-.0291,15080481,2,.5423,-.0291,14948640,2,.5755,-.0291,14620446,2,.6087,-.0291,14424096,2,.6419,-.0291,14292511,2,.6669,-.0318,14293538,2,-.5838,-.065,16686858,0,-.5534,-.0623,16425235,0,-.5202,-.0623,16562740,0,-.487,-.0623,16689692,0,-.4538,-.0623,16680713,0,-.4206,-.0623,16612617,0,-.3874,-.0623,16611337,0,-.3542,-.0623,16610057,0,-.321,-.0623,16674571,0,-.2878,-.0623,16542219,0,-.2546,-.0623,16479249,0,-.2214,-.0623,16481303,0,-.1882,-.0623,16414743,0,-.155,-.0623,16341263,0,-.1217,-.0623,16340750,0,-.0885,-.0623,16275215,0,-.0553,-.0623,16209167,0,-.0221,-.0623,16274193,0,.0111,-.0623,16208400,0,.0443,-.0623,16208657,0,.0775,-.0623,15803908,0,.1107,-.0623,15737091,0,.1439,-.0623,15735811,0,.1771,-.0623,15604228,0,.2103,-.0623,15471619,0,.2435,-.0623,15339266,0,.2767,-.0623,15141634,0,.2988,-.0512,14550017,2,.4787,-.065,15014688,2,.5091,-.0623,14948895,2,.5423,-.0623,14817568,2,.5755,-.0623,14555167,2,.6087,-.0623,14292766,2,.6419,-.0623,14161438,2,.6696,-.065,13833501,2,.451,-.0706,15145504,2,-.606,-.0761,16685063,0,-.6087,-.0899,16686602,0,-.5866,-.0872,16687113,0,-.5534,-.0872,16696903,0,-.5202,-.0872,16693290,0,-.487,-.0872,16688923,0,-.4538,-.0872,16619542,0,-.4206,-.0872,16612105,0,-.3874,-.0872,16544776,0,-.3542,-.0872,16543754,0,-.321,-.0872,16608523,0,-.2878,-.0872,16613653,0,-.2546,-.0872,16613140,0,-.2214,-.0872,16480788,0,-.1882,-.0872,16341263,0,-.155,-.0872,16340495,0,-.1217,-.0872,16339983,0,-.0885,-.0872,16274191,0,-.0553,-.0872,16142606,0,-.0221,-.0872,16207630,0,.0111,-.0872,16207631,0,.0443,-.0872,16207637,0,.0775,-.0872,15803395,0,.1107,-.0872,15736835,0,.1439,-.0872,15670020,0,.1771,-.0872,15603459,0,.2103,-.0872,15405571,0,.2435,-.0872,15208195,0,.2712,-.0872,14944770,0,.4455,-.0899,15014688,2,.4759,-.0872,15080479,2,.5091,-.0872,14883359,2,.5423,-.0872,14752287,2,.5755,-.0872,14489632,2,.6087,-.0872,14227230,2,.6419,-.0872,13964830,2,.6724,-.0899,13833244,2,.4234,-.0927,14948383,2,-.6143,-.1065,16687367,1,-.5866,-.1038,16687112,1,-.5534,-.1038,16631112,1,-.5202,-.1038,16692777,1,-.487,-.1038,16688665,1,-.4538,-.1038,16687128,1,-.4206,-.1038,16546312,1,-.3874,-.1038,16545034,1,-.3542,-.1038,16543497,1,-.321,-.1038,16545552,1,-.2878,-.1038,16548373,1,-.2546,-.1038,16547349,1,-.2214,-.1038,16345619,1,-.1882,-.1038,16340751,1,-.155,-.1038,16339727,1,-.1217,-.1038,16208398,1,-.0885,-.1038,16273422,1,-.0553,-.1038,16141581,1,-.0221,-.1038,16141325,1,.0111,-.1038,16272144,1,.0443,-.1038,15804165,1,.0775,-.1038,15868676,1,.1107,-.1038,15736580,1,.1439,-.1038,15669764,1,.1771,-.1038,15537155,1,.2103,-.1038,15339523,1,.2435,-.1038,15207683,1,.2656,-.1038,15142404,1,.4206,-.1065,14948638,2,.4427,-.1038,15014687,2,.4759,-.1038,15079967,2,.5091,-.1038,14817824,2,.5423,-.1038,14686494,2,.5755,-.1038,14358303,2,.6087,-.1038,14161693,2,.6419,-.1038,13899037,2,.6752,-.1065,13767708,2,-.617,-.1314,16687624,1,-.5866,-.1287,16425745,1,-.5534,-.1287,16626984,1,-.5202,-.1287,16692262,1,-.487,-.1287,16687637,1,-.4538,-.1287,16686870,1,-.4206,-.1287,16685847,1,-.3874,-.1287,16553237,1,-.3542,-.1287,16550933,1,-.321,-.1287,16548883,1,-.2878,-.1287,16548373,1,-.2546,-.1287,16414484,1,-.2214,-.1287,16209163,1,-.1854,-.1287,16274702,1,-.155,-.1287,16142094,1,-.1217,-.1287,16141325,1,-.0885,-.1287,16141069,1,-.0553,-.1287,16206093,1,-.0221,-.1287,16140044,1,.0111,-.1287,16140046,1,.0443,-.1287,15737860,1,.0775,-.1287,15802371,1,.1107,-.1287,15604740,1,.1439,-.1287,15538180,1,.1771,-.1287,15406084,1,.2103,-.1287,15142659,1,.2407,-.1287,15207427,1,.2629,-.1148,15010314,1,.4206,-.1176,15342368,2,.4427,-.1176,14949150,2,.4787,-.1204,15015199,2,.5119,-.1287,14621216,2,.5423,-.1287,14621473,2,.5755,-.1287,14358560,2,.6087,-.1287,14030622,2,.6419,-.1287,13767965,2,.6752,-.1287,13767709,2,-.6392,-.1397,16688136,1,.6945,-.1397,13699345,2,-.6447,-.1646,16687628,1,-.6198,-.1619,16687626,1,-.5866,-.1619,16696646,1,-.5534,-.1619,16626982,1,-.5202,-.1619,16559907,1,-.487,-.1619,16624158,1,-.4538,-.1619,16686614,1,-.4206,-.1619,16685333,1,-.3874,-.1619,16618005,1,-.3542,-.1619,16615956,1,-.321,-.1619,16549399,1,-.2878,-.1619,16274954,1,-.2546,-.1619,16208647,1,-.2297,-.1563,16208392,1,-.1826,-.1646,16141329,1,-.155,-.1619,16206351,1,-.1217,-.1619,16140045,1,-.0885,-.1619,16139533,1,-.0553,-.1619,16204813,1,-.0221,-.1619,15941131,1,.0111,-.1619,15869700,1,.0443,-.1619,15737092,1,.0775,-.1619,15802117,1,.1107,-.1619,15604228,1,.1439,-.1619,15471876,1,.1771,-.1619,15208194,1,.2103,-.1619,15076611,1,.2324,-.1508,15404806,1,.5147,-.1619,14555678,2,.5423,-.1619,14490143,2,.5755,-.1619,14227487,2,.6087,-.1619,13899293,2,.6419,-.1619,13767965,2,.6752,-.1619,13701915,2,.6973,-.1646,14029081,2,-.6502,-.1978,16688649,1,-.6198,-.1951,16687626,1,-.5866,-.1951,16628531,1,-.5534,-.1951,16691233,1,-.5202,-.1951,16624926,1,-.487,-.1951,16623387,1,-.4538,-.1951,16686357,1,-.4206,-.1951,16618515,1,-.3874,-.1951,16617493,1,-.3542,-.1951,16484630,1,-.321,-.1951,16210697,1,-.2878,-.1951,16144136,1,-.2601,-.1895,16405771,1,-.1826,-.1951,16008207,1,-.155,-.1951,16073229,1,-.1217,-.1951,16006924,1,-.0885,-.1951,16006668,1,-.0553,-.1951,15940363,1,-.0221,-.1951,15804675,1,.0111,-.1951,15803397,1,.0443,-.1951,15736580,1,.0775,-.1951,15604227,1,.1107,-.1951,15471875,1,.1439,-.1951,15405316,1,.1771,-.1951,15207427,1,.1992,-.184,15010823,1,.5147,-.1951,14490399,2,.5423,-.1951,14424608,2,.5755,-.1951,14096157,2,.6087,-.1951,13964829,2,.6419,-.1951,13767964,2,.6752,-.1951,13767451,2,.7001,-.1978,13899034,2,.2518,-.1978,15478308,1,.2767,-.1978,15412002,1,.3099,-.1978,15279649,2,.3431,-.1978,15213089,2,.3763,-.1978,15015457,2,.4095,-.1978,14884129,2,.4372,-.2006,14621474,2,-.6696,-.2061,16687367,1,-.6752,-.231,16688650,1,-.653,-.2283,16688394,1,-.6198,-.2283,16689173,1,-.5866,-.2283,16691745,1,-.5534,-.2283,16624669,1,-.5202,-.2283,16623129,1,-.487,-.2283,16687384,1,-.4538,-.2283,16685844,1,-.4206,-.2283,16683799,1,-.3874,-.2283,16550678,1,-.3542,-.2283,16276229,1,-.321,-.2283,16209928,1,-.2933,-.2255,16144135,1,-.1799,-.2283,15941135,1,-.155,-.2283,15940364,1,-.1217,-.2283,15939851,1,-.0885,-.2283,15872773,1,-.0553,-.2283,15870979,1,-.0221,-.2283,15804164,1,.0111,-.2283,15671812,1,.0443,-.2283,15670275,1,.0775,-.2283,15406850,1,.1107,-.2283,15274243,1,.1411,-.2255,15273475,1,.166,-.2172,14355460,1,.2518,-.2283,15216418,1,.2767,-.2283,15346978,1,.3099,-.2283,15280162,2,.3431,-.2283,15147552,2,.3763,-.2283,15015201,2,.4095,-.2283,14818080,2,.4372,-.2283,14555680,2,.5147,-.2283,14359071,2,.5423,-.2283,14293535,2,.5755,-.2283,14096414,2,.6087,-.2283,13834270,2,.6419,-.2283,13636893,2,.6752,-.2283,13505307,2,.7001,-.2283,13439768,2,-.6779,-.2643,16688649,1,-.653,-.2615,16687628,1,-.6198,-.2615,16629057,1,-.5866,-.2615,16625185,1,-.5534,-.2615,16624156,1,-.5202,-.2615,16622104,1,-.487,-.2615,16686357,1,-.4538,-.2615,16619286,1,-.4206,-.2615,16082693,1,-.3874,-.2615,16277766,1,-.3542,-.2615,16276743,1,-.3237,-.2615,16144135,1,-.3016,-.2476,16077063,1,-.1743,-.2559,16006152,1,-.1522,-.2615,15939845,1,-.1217,-.2615,15873027,1,-.0885,-.2615,15872004,1,-.0553,-.2615,15870468,1,-.0221,-.2615,15737859,1,.0111,-.2615,15605507,1,.0443,-.2615,15473411,1,.0775,-.2615,15274498,1,.1051,-.2532,15274755,1,.2518,-.2615,15282211,1,.2767,-.2615,15347234,1,.3099,-.2615,15279904,2,.3431,-.2615,15147809,2,.3763,-.2615,14949921,2,.4095,-.2615,14686750,2,.4372,-.2615,14555425,2,.5147,-.2615,14096927,2,.5423,-.2615,14096670,2,.5755,-.2615,13965086,2,.6087,-.2615,13899549,2,.6419,-.2615,13636893,2,.6752,-.2615,13505564,2,.7001,-.2615,13308698,2,-.6835,-.2975,16687882,1,-.653,-.2947,16687116,1,-.6198,-.2947,16627765,1,-.5866,-.2947,16623899,1,-.5534,-.2947,16622872,1,-.5202,-.2947,16687126,1,-.487,-.2947,16620054,1,-.4538,-.2947,16280327,1,-.4206,-.2947,16213509,1,-.3874,-.2947,16278022,1,-.3542,-.2947,16276488,1,-.332,-.2864,16276746,1,-.1467,-.2864,15939331,1,-.119,-.2947,15873285,1,-.0885,-.2947,16002821,1,-.0553,-.2947,16001797,1,-.0221,-.2947,15802884,1,.0111,-.2919,15670787,1,.0415,-.2864,15474180,1,.0636,-.2809,15009280,1,.2518,-.2947,15347747,1,.2767,-.2947,15346978,1,.3099,-.2947,15214112,2,.3431,-.2947,15016736,2,.3763,-.2947,14818850,2,.4095,-.2947,14555936,2,.4372,-.2947,14359071,2,.5147,-.2947,14096928,2,.5423,-.2947,14096927,2,.5755,-.2947,13965085,2,.6087,-.2947,13768221,2,.6419,-.2947,13636894,2,.6752,-.2947,13374748,2,.7001,-.2947,13243676,2,-.6862,-.3279,16688139,1,-.653,-.3279,16686860,1,-.6198,-.3279,16626734,1,-.5866,-.3279,16623384,1,-.5534,-.3279,16622101,1,-.5202,-.3279,16620822,1,-.487,-.3279,16281094,1,-.4538,-.3279,16280068,1,-.4206,-.3279,16278533,1,-.3874,-.3279,16343815,1,-.3597,-.3279,16277256,1,-.1079,-.3141,15217942,1,-.0858,-.3141,15937030,1,-.0553,-.3141,16068102,1,-.0304,-.3141,15273731,1,.2518,-.3279,15347490,1,.2767,-.3279,15281186,1,.3099,-.3279,15083040,2,.3431,-.3279,14885407,2,.3763,-.3279,14687520,2,.4095,-.3279,14490399,2,.4372,-.3279,14228256,2,.5147,-.3279,14097183,2,.5423,-.3279,14096926,2,.5755,-.3279,13834270,2,.6087,-.3279,13637148,2,.6419,-.3279,13571356,2,.6752,-.3279,13374749,2,.7001,-.3279,13243932,2,-.7028,-.3334,16686599,1,-.7056,-.3639,16687878,1,-.6862,-.3611,16687883,1,-.653,-.3611,16686092,1,-.6198,-.3611,16625704,1,-.5866,-.3611,16622357,1,-.5534,-.3611,16621078,1,-.5202,-.3611,16154890,1,-.487,-.3611,16215301,1,-.4538,-.3611,16411141,1,-.4206,-.3611,16410118,1,-.3874,-.3611,16278278,1,-.3652,-.3528,15948037,1,.2518,-.3611,15215906,1,.2767,-.3611,15149857,1,.3099,-.3611,15082528,2,.3431,-.3611,14819102,2,.3763,-.3611,14621983,2,.4095,-.3611,14490398,2,.4372,-.3611,14228256,2,.5147,-.3611,13965855,2,.5423,-.3611,13900319,2,.5755,-.3611,13703455,2,.6087,-.3611,13571869,2,.6419,-.3611,13440285,2,.6752,-.3611,13374749,2,.6973,-.3611,13374747,2,-.7056,-.3943,16754700,1,-.6862,-.3943,16687625,1,-.653,-.3943,16685578,1,-.6198,-.3943,16689439,1,-.5866,-.3943,16622101,1,-.5534,-.3943,16621336,1,-.5202,-.3943,16281605,1,-.487,-.3943,16280838,1,-.4538,-.3943,16345351,1,-.4206,-.3943,16344582,1,-.3929,-.3943,16343559,1,-.0111,-.3971,15555362,1,.0111,-.3943,15686175,1,.0443,-.3943,15619101,1,.0775,-.3943,15553055,1,.1107,-.3943,15486239,1,.1439,-.3943,15419933,1,.1743,-.3971,15419935,1,.2518,-.3943,15150627,1,.2767,-.3943,15084322,1,.3099,-.3943,15016993,2,.3431,-.3943,14819361,2,.3763,-.3943,14621983,2,.4095,-.3943,14424606,2,.4372,-.3943,14162720,2,.5147,-.3943,13834783,2,.5423,-.3943,13835296,2,.5755,-.3943,13637662,2,.6087,-.3943,13440797,2,.6419,-.3943,13243932,2,.6752,-.3943,13243677,2,.6973,-.3915,12979732,2,-.7056,-.4275,16753930,1,-.6862,-.4275,16686859,1,-.653,-.4275,16685068,1,-.6198,-.4275,16687896,1,-.5866,-.4275,16686870,1,-.5534,-.4275,16215555,1,-.5202,-.4275,16346885,1,-.487,-.4275,16411654,1,-.4538,-.4275,16410630,1,-.4206,-.4275,16409094,1,-.3985,-.4275,16277514,1,-.0138,-.4275,15620642,1,.0111,-.4275,15685919,1,.0443,-.4275,15684637,1,.0775,-.4275,15618076,1,.1107,-.4275,15617053,1,.1439,-.4275,15485469,1,.1743,-.4275,15484700,1,.2518,-.4275,15150115,1,.2767,-.4275,15083554,1,.3099,-.4275,14951202,2,.3431,-.4275,14688032,2,.3763,-.4275,14490912,2,.4095,-.4275,14359584,2,.4372,-.4275,14162720,2,.5147,-.4275,13638432,2,.5423,-.4275,13637918,2,.5755,-.4275,13637919,2,.6087,-.4275,13375517,2,.6419,-.4275,13243934,2,.6752,-.4275,13112861,2,.6945,-.4137,12716045,2,-.7056,-.4607,16684295,1,-.6862,-.4607,16685835,1,-.653,-.4607,16684813,1,-.6198,-.4607,16621846,1,-.5866,-.4607,16554004,1,-.5534,-.4607,16347397,1,-.5202,-.4607,16411909,1,-.487,-.4607,16411141,1,-.4538,-.4607,16409862,1,-.4206,-.4607,16408069,1,-.4012,-.4579,16275465,1,-.0138,-.4607,15686177,1,.0111,-.4607,15751711,1,.0443,-.4607,15684892,1,.0775,-.4607,15617819,1,.1107,-.4607,15551516,1,.1439,-.4607,15485212,1,.1743,-.4607,15484187,1,.2518,-.4607,15084066,1,.2767,-.4607,15018019,1,.3099,-.4607,14819872,2,.3431,-.4607,14622495,2,.3763,-.4607,14490911,2,.4095,-.4607,14228255,2,.4372,-.4607,13966369,2,.5147,-.4607,13506845,2,.5423,-.4607,13572383,2,.5755,-.4607,13375517,2,.6087,-.4607,13309723,2,.6419,-.4607,13178397,2,.6724,-.4607,13113117,2,-.7028,-.4856,16683269,1,-.6862,-.4939,16685066,1,-.653,-.4939,16684042,1,-.6198,-.4939,16684300,1,-.5866,-.4939,16282375,1,-.5534,-.4939,16281860,1,-.5202,-.4939,16411653,1,-.487,-.4939,16344838,1,-.4538,-.4939,16343302,1,-.4206,-.4939,16275719,1,-.4012,-.4801,16342547,1,-.0138,-.4939,15685920,1,.0111,-.4939,15685662,1,.0443,-.4939,15750428,1,.0775,-.4939,15618076,1,.1107,-.4939,15485980,1,.1439,-.4939,15419675,1,.1743,-.4939,15484444,1,.2518,-.4939,14953250,1,.2767,-.4939,14821412,1,.3099,-.4939,14754338,2,.3431,-.4939,14491681,2,.3763,-.4939,14359840,2,.4095,-.4939,14162720,2,.4372,-.4939,13769761,2,.5147,-.4939,13572381,2,.5423,-.4939,13441054,2,.5755,-.4939,13309981,2,.6087,-.4939,13112860,2,.6419,-.4939,13112603,2,.6669,-.4939,13047324,2,-.6835,-.5271,16684555,1,-.653,-.5271,16683530,1,-.6198,-.5271,16683018,1,-.5866,-.5271,16281862,1,-.5534,-.5271,16346629,1,-.5202,-.5271,16411143,1,-.487,-.5271,16344070,1,-.4538,-.5271,16342789,1,-.4206,-.5271,16340230,1,-.0138,-.5271,15685921,1,.0111,-.5271,15685660,1,.0443,-.5271,15685148,1,.0775,-.5271,15618588,1,.1107,-.5271,15617564,1,.1439,-.5271,15419674,1,.1743,-.5271,15418908,1,.2518,-.5271,14887459,1,.2767,-.5271,14755874,1,.3099,-.5271,14557473,2,.3431,-.5271,14360096,2,.3763,-.5271,14228767,2,.4095,-.5271,14097183,2,.4372,-.5271,13834783,2,.5147,-.5271,13375774,2,.5423,-.5271,13375774,2,.5755,-.5271,13243932,2,.6087,-.5271,13047069,2,.6419,-.5271,12916254,2,.6613,-.5188,12653595,2,-.4012,-.5327,16205065,1,-.2546,-.5327,16287265,1,-.2214,-.5327,16088608,1,-.1882,-.5327,16021536,1,-.155,-.5327,16020513,1,-.1217,-.5327,16019744,1,-.0913,-.5354,16150303,1,-.2767,-.5354,16353320,1,-.6779,-.5603,16684553,1,-.653,-.5603,16683530,1,-.6198,-.5603,16682507,1,-.5866,-.5603,16281861,1,-.5534,-.5603,16346372,1,-.5202,-.5603,16345094,1,-.487,-.5603,16408837,1,-.4538,-.5603,16342022,1,-.4206,-.5603,16340230,1,-.3985,-.5631,16208138,1,-.2767,-.5603,16353578,1,-.2546,-.5603,16287265,1,-.2214,-.5603,16154400,1,-.1882,-.5603,16087328,1,-.155,-.5603,16086048,1,-.1217,-.5603,16085023,1,-.0913,-.5603,16215069,1,-.0138,-.5603,15686177,1,.0111,-.5603,15685917,1,.0443,-.5603,15685148,1,.0775,-.5603,15553053,1,.1107,-.5603,15617821,1,.1439,-.5603,15485467,1,.1743,-.5603,15418651,1,.2518,-.5603,14755874,1,.2767,-.5603,14755362,1,.3099,-.5603,14557217,2,.3431,-.5603,14294559,2,.3763,-.5603,14031390,2,.4095,-.5603,13900317,2,.4372,-.5603,13637917,2,.5147,-.5603,13179424,2,.5423,-.5603,13179423,2,.5755,-.5603,13113118,2,.6087,-.5603,13047326,2,.6364,-.5576,12784924,2,-.6724,-.5908,16683785,1,-.653,-.5935,16683274,1,-.6198,-.5935,16616713,1,-.5866,-.5935,16347653,1,-.5534,-.5935,16280581,1,-.5202,-.5935,16344069,1,-.487,-.5935,16408324,1,-.4538,-.5935,16340997,1,-.4206,-.5935,16274182,1,-.3901,-.5963,16141320,1,-.2767,-.5935,16288040,1,-.2546,-.5935,16287266,1,-.2214,-.5935,16154655,1,-.1882,-.5935,16087585,1,-.155,-.5935,16086304,1,-.1217,-.5935,16085023,1,-.0913,-.5935,16083997,1,-.0138,-.5935,15686175,1,.0111,-.5935,15685917,1,.0443,-.5935,15619610,1,.0775,-.5935,15553053,1,.1107,-.5935,15486492,1,.1439,-.5935,15353883,1,.1743,-.5935,15353115,1,.2518,-.5935,14689825,1,.2767,-.5935,14623777,1,.3099,-.5935,14425888,2,.3431,-.5935,14228767,2,.3763,-.5935,14031390,2,.4095,-.5935,13768988,2,.4372,-.5935,13506845,2,.5147,-.5935,13113630,2,.5423,-.5935,13047837,2,.5755,-.5935,12916509,2,.6087,-.5935,12850718,2,.6309,-.5825,12258321,2,-.6475,-.6267,16683274,1,-.6198,-.6267,16682506,1,-.5866,-.6267,16282631,1,-.5534,-.624,16214535,1,-.5202,-.624,16343302,1,-.487,-.624,16407045,1,-.4538,-.624,16274695,1,-.4206,-.624,16206855,1,-.3874,-.624,16140038,1,-.2767,-.6267,16353575,1,-.2546,-.6267,16287264,1,-.2214,-.6267,16154399,1,-.1882,-.6267,16087841,1,-.155,-.6267,16086047,1,-.1217,-.6267,16085022,1,-.0913,-.6267,16083741,1,-.0138,-.6267,15752225,1,.0111,-.6267,15751710,1,.0443,-.6267,15619611,1,.0775,-.6267,15552794,1,.1107,-.6267,15485978,1,.1439,-.6267,15353627,1,.1743,-.6267,15353115,1,.2518,-.6267,14624290,1,.2767,-.6267,14492449,1,.3099,-.6267,14425631,2,.3431,-.6267,14163231,2,.3763,-.6267,13965855,2,.4095,-.6267,13637916,2,.4372,-.6267,13441309,2,.5147,-.6267,13047838,2,.5423,-.6267,12982045,2,.5755,-.6267,12850974,2,.6004,-.624,12720156,2,-.3652,-.6295,16335364,1,-.6419,-.6544,16684300,1,-.617,-.6599,16616972,1,-.5921,-.6599,16416266,1,-.2767,-.6599,16288297,1,-.2546,-.6599,16287264,1,-.2214,-.6599,16154399,1,-.1882,-.6599,16021790,1,-.155,-.6599,16086302,1,-.1217,-.6599,16084766,1,-.0913,-.6599,16017692,1,-.0138,-.6599,15686434,1,.0111,-.6599,15751966,1,.0443,-.6599,15619612,1,.0775,-.6599,15487003,1,.1107,-.6599,15485980,1,.1439,-.6599,15419419,1,.1743,-.6599,15353115,1,.2518,-.6599,14427939,1,.2767,-.6599,14361378,1,.3099,-.6599,14163232,2,.3431,-.6599,14031903,2,.3763,-.6599,13900574,2,.4095,-.6599,13637917,2,.4372,-.6599,13309981,2,.5147,-.6599,12785437,2,.5423,-.6599,12916767,2,.5728,-.6572,12850973,2,-.6143,-.6904,16683275,1,-.5949,-.6931,16352266,1,-.2767,-.6931,16288039,1,-.2546,-.6931,16287265,1,-.2214,-.6931,16154655,1,-.1882,-.6931,16021790,1,-.155,-.6931,16020510,1,-.1217,-.6931,16084766,1,-.0913,-.6931,16017692,1,-.0138,-.6931,15686433,1,.0111,-.6931,15686173,1,.0443,-.6931,15685404,1,.0775,-.6931,15553052,1,.1107,-.6931,15552285,1,.1439,-.6931,15420189,1,.1743,-.6931,15353628,1,.2518,-.6931,14295840,1,.2767,-.6931,14164256,1,.3099,-.6931,14097951,2,.3431,-.6931,13901088,2,.3763,-.6931,13703709,2,.4095,-.6931,13506845,2,.4372,-.6931,13244701,2,.5147,-.6931,12851229,2,.5423,-.6931,12851229,2,.5645,-.6821,12259346,2,-.5174,-.7042,16699700,1,-.487,-.7014,16632621,1,-.4538,-.7014,16696363,1,-.4206,-.7014,16629292,1,-.3874,-.7014,16627499,1,-.3542,-.7042,16560681,1,-.606,-.7153,16090135,1,-.5949,-.7208,16614405,1,-.5202,-.7263,16699957,1,-.487,-.7263,16698157,1,-.4538,-.7263,16696621,1,-.4206,-.7263,16629291,1,-.3874,-.7263,16627243,1,-.3542,-.7263,16560427,1,-.2767,-.7263,16222246,1,-.2546,-.7263,16287522,1,-.2214,-.7263,16154656,1,-.1882,-.7263,15955999,1,-.155,-.7263,15954973,1,-.1217,-.7263,16085023,1,-.0913,-.7263,16017692,1,-.0138,-.7263,15620639,1,.0111,-.7263,15686429,1,.0443,-.7263,15685659,1,.0775,-.7263,15553308,1,.1107,-.7263,15552542,1,.1439,-.7263,15354653,1,.1743,-.7263,15288349,1,.2518,-.7263,14230560,1,.2767,-.7263,14164513,1,.3099,-.7263,14032415,2,.3431,-.7263,13770015,2,.3763,-.7263,13507358,2,.4095,-.7263,13375772,2,.4372,-.7263,13113373,2,.5119,-.7263,13047837,2,.5313,-.7153,13048094,2,-.5202,-.7595,16699700,1,-.487,-.7595,16698159,1,-.4538,-.7595,16630574,1,-.4206,-.7595,16628778,1,-.3874,-.7595,16626986,1,-.3542,-.7595,16494636,1,-.2767,-.7595,16353574,1,-.2546,-.7595,16287520,1,-.2214,-.7595,16154656,1,-.1882,-.7595,15956255,1,-.155,-.7595,16020254,1,-.1217,-.7595,16019230,1,-.0913,-.7595,16017693,1,-.0138,-.7595,15621152,1,.0111,-.7595,15686687,1,.0443,-.7595,15620124,1,.0775,-.7595,15487772,1,.1107,-.7595,15421213,1,.1439,-.7595,15288860,1,.1743,-.7595,15222300,1,.2518,-.7595,14033953,1,.2767,-.7595,13967648,1,.3099,-.7595,13835808,2,.3431,-.7595,13573151,2,.3763,-.7595,13441565,2,.4095,-.7595,13178908,2,.4372,-.7595,13048093,2,.5036,-.7457,12388109,2,-.5174,-.7928,16699958,1,-.487,-.7928,16698159,1,-.4538,-.7928,16564780,1,-.4206,-.7928,16628264,1,-.3874,-.7928,16626731,1,-.3542,-.7928,16494381,1,-.2767,-.7928,16288039,1,-.2546,-.7928,16221985,1,-.2214,-.7928,16089632,1,-.1882,-.7928,16022047,1,-.155,-.7928,16020509,1,-.1217,-.7928,16019230,1,-.0913,-.7928,15952414,1,-.0138,-.7928,15686689,1,.0111,-.7928,15686942,1,.0443,-.7928,15554332,1,.0775,-.7928,15553309,1,.1107,-.7928,15486749,1,.1439,-.7928,15288860,1,.1743,-.7928,15222300,1,.2518,-.7928,13836833,1,.2767,-.7928,13836320,1,.3099,-.7928,13704735,2,.3431,-.7928,13507102,2,.3763,-.7928,13310493,2,.4095,-.7928,13179165,2,.4372,-.7928,12917278,2,-.5064,-.8149,16699948,1,-.4815,-.8232,16697903,1,-.4538,-.826,16630572,1,-.4206,-.826,16628518,1,-.3874,-.826,16626730,1,-.3542,-.826,16494380,1,-.2767,-.826,16354088,1,-.2546,-.826,16287777,1,-.2214,-.826,16154655,1,-.1882,-.826,16021792,1,-.155,-.826,15954460,1,-.1217,-.826,15953437,1,-.0913,-.826,15886877,1,-.0138,-.826,15686689,1,.0111,-.826,15686686,1,.0443,-.826,15554333,1,.0775,-.826,15487772,1,.1107,-.826,15420956,1,.1439,-.826,15354397,1,.1743,-.826,15222299,1,.2518,-.826,13508897,1,.2767,-.826,13574176,1,.3099,-.826,13573149,2,.3431,-.826,13441822,2,.3763,-.826,13245214,2,.4068,-.8177,13114139,2,-.4483,-.8509,16695593,1,-.4178,-.8592,16694056,1,-.3874,-.8592,16626731,1,-.3542,-.8592,16494637,1,-.2767,-.8592,16288549,1,-.2546,-.8592,16287777,1,-.2214,-.8592,16154654,1,-.1882,-.8592,16022048,1,-.155,-.8592,15954716,1,-.1217,-.8592,16019229,1,-.0913,-.8592,15952670,1,-.0138,-.8592,15621152,1,.0111,-.8592,15621150,1,.0443,-.8592,15554331,1,.0775,-.8592,15421467,1,.1107,-.8592,15420699,1,.1439,-.8592,15288604,1,.1743,-.8592,15222300,1,.2518,-.8592,13508639,1,.2767,-.8592,13508897,1,.3099,-.8592,13442077,2,.3431,-.8536,13376284,2,.368,-.8481,12848396,2,-.4068,-.8785,16495389,1,-.3818,-.8841,16560939,1,-.3542,-.8896,16429102,1,-.2767,-.8924,16223015,1,-.2546,-.8924,16222240,1,-.2214,-.8924,16089118,1,-.1882,-.8924,16021789,1,-.155,-.8924,16020509,1,-.1217,-.8924,16085278,1,-.0913,-.8924,16018719,1,-.0138,-.8924,15622179,1,.0111,-.8924,15687455,1,.0443,-.8924,15554332,1,.0775,-.8924,15421722,1,.1107,-.8924,15355163,1,.1439,-.8924,15354396,1,.1743,-.8924,15156764,1,.2518,-.8924,13705762,1,.2767,-.8868,13378079,1,.3016,-.8813,13246750,2,-.2767,-.92,16223273,1,-.2518,-.9228,16157217,1,-.2186,-.9256,16220447,1,-.1882,-.9256,16022302,1,-.155,-.9256,16021022,1,-.1217,-.9256,16019744,1,-.0913,-.9256,15887393,1,-.0138,-.9256,15622437,1,.0111,-.9256,15621921,1,.0443,-.9256,15489054,1,.0775,-.9256,15355931,1,.1107,-.9256,15289115,1,.1439,-.9228,15288607,1,.1743,-.92,14959902,1,-.2075,-.9449,16021786,1,-.1826,-.9477,16085523,1,-.1522,-.9477,16151837,1,-.119,-.9505,15953693,1,-.0913,-.9505,15756062,1,-.0138,-.9505,15556127,1,.0111,-.9505,15425311,1,.0443,-.9477,15488539,1,.0775,-.9477,15223060,1,.0996,-.9449,15023887,1],M1=2666;var He={anthropic:[-.3695,-.0402,-.4497,-.1423,-.3566,-.2011,-.4814,-.2089,-.4981,-.1723,-.4441,-.025,-.3615,-.2029,-.4732,-.2089,-.366,-.189,-.4683,-.2229,-.3695,-.204,-.4894,-.189,-.4851,-.1863,-.487,-.1863,-.457,-.1397,-.3695,-.048,-.3925,-.0793,-.4522,-.082,-.3695,-.0445,-.1833,-.0616,-.1828,-.1942,-.31,-.2089,-.3267,-.1723,-.3138,-.0372,-.1779,-.082,-.2303,-.2255,-.3056,-.2281,-.1728,-.1168,-.2019,-.1723,-.2311,-.2229,-.1796,-.0846,-.3138,-.1898,-.3243,-.1788,-.3156,-.1723,-.2894,-.1082,-.295,-.0989,-.242,-.082,-.2821,-.1712,-.2821,-.1424,-.2019,-.048,-.1931,-.0616,-.2019,-.0454,-.0157,-.0666,-.0214,-.1942,-.1443,-.2089,-.0157,-.082,-.0263,-.2133,-.138,-.2153,-.0052,-.1916,-.0219,-.1723,-.1332,-.2229,-.0101,-.1185,-.1032,-.1712,-.0902,-.0627,-.0983,-.082,-.1008,-.1406,-.0959,-.0846,-.0306,-.048,-.0263,-.0562,-.0343,-.0437,.1027,-.0846,.119,-.1132,.0717,-.1712,.1648,-.216,.0214,-.1476,.1573,-.1916,.0312,-.2089,.1624,-.189,.0344,-.2136,.1519,-.1942,.0607,-.1712,.1202,-.1211,.1227,-.1298,.0693,-.1712,.1182,-.1159,.0588,-.0981,.1575,-.0576,.1599,-.0454,.0684,-.0981,.1589,-.0428,-.3609,.2157,-.423,.0846,-.3566,.0251,-.4814,.0567,-.5,.1204,-.3695,.2308,-.4708,.0358,-.3591,.0277,-.4024,.0469,-.3639,.0616,-.4814,.0651,-.4918,.0835,-.4832,.0835,-.4626,.1208,-.3639,.1887,-.3642,.2104,-.4538,.0846,-.359,.213,-.2821,.172,-.189,.0695,-.3305,.0469,-.2019,.0642,-.3218,.0414,-.1915,.0407,-.2802,.047,-.1982,.0616,-.2894,.1667,-.287,.2104,-.2915,.213,-.04,.1942,-.0214,.0764,-.0717,.064,-.1591,.0251,-.1524,.1942,-.1194,.0303,-.1567,.0341,-.0717,.1016,-.029,.1738,-.0619,.0469,-.0239,.1765,-.1518,.0423,-.0717,.106,-.0424,.0469,-.0287,.1712,-.1218,.1648,-.1274,.1931,-.1019,.1738,-.1194,.1577,-.1145,.1667,-.0511,.2078,-.0449,.1942,-.0529,.2113,.1145,.0846,.1605,.2157,.1065,.0251,.0214,.0616,.0028,.1817,.1599,.2104,.0684,.0303,.0676,.0277,.1624,.213,.1333,.0713,.1389,.0329,.1538,.2078,.0214,.0668,.011,.0706,.0158,.0835,.0439,.2078,.0482,.1265,.0402,.2121,.3176,.1942,.3262,.0616,.1947,.0469,.3009,.2207,.3089,.0668,.198,.0469,.3176,.0642,.3195,.1738,.2021,.0423,.3251,.0695,.2283,.0846,.2821,.1931,.2369,.1144,.2344,.1765,.2679,.1712,.3065,.2033,.3089,.2104,.3044,.213,.5,.1712,.4499,.1476,.4069,.0936,.5,.0695,.3585,.0469,.4871,.0642,.3672,.0414,.4976,.0407,.4088,.0469,.4908,.0616,.394,.0964,.4555,.1156],copilot:[-.0221,.0877,-.0012,.085,.0165,.0771,.031,.064,.0414,.0469,.0476,.0265,.0496,.003,.0473,-.0231,.0404,-.0456,.0288,-.0646,.0128,-.0792,-.0066,-.088,-.0293,-.0909,-.0438,-.0894,-.0568,-.085,-.0683,-.0776,-.0689,-.0771,-.0694,-.0766,-.07,-.0761,-.07,-.1039,-.07,-.1317,-.07,-.1594,-.0832,-.1594,-.0963,-.1594,-.1094,-.1594,-.1094,-.0783,-.1094,.0029,-.1094,.084,-.0963,.084,-.0832,.084,-.07,.084,-.07,.079,-.07,.0741,-.07,.0691,-.0698,.0694,-.0695,.0696,-.0692,.0699,-.0566,.0792,-.0421,.0851,-.0258,.0876,-.0246,.0876,-.0233,.0877,-.0221,.0877,.3048,.0877,.3285,.085,.3486,.0771,.365,.0638,.3771,.046,.3843,.0244,.3867,-.001,.3841,-.0261,.3764,-.0478,.3634,-.0661,.3461,-.0799,.3253,-.0881,.3011,-.0909,.2776,-.0882,.2573,-.0801,.2403,-.0667,.2276,-.0489,.22,-.0278,.2175,-.0034,.2201,.0227,.228,.045,.2412,.0633,.2589,.0769,.2801,.085,.3048,.0877,-.2173,.0877,-.1937,.085,-.1736,.0771,-.1571,.0638,-.1451,.046,-.1379,.0244,-.1355,-.001,-.1381,-.0261,-.1458,-.0478,-.1588,-.0661,-.1761,-.0799,-.1969,-.0881,-.221,-.0909,-.2446,-.0882,-.2649,-.0801,-.2819,-.0667,-.2946,-.0489,-.3022,-.0278,-.3047,-.0034,-.3021,.0227,-.2942,.045,-.281,.0633,-.2633,.0769,-.2421,.085,-.2173,.0877,-.3803,.1505,-.3597,.1495,-.3414,.1463,-.3255,.1409,-.3241,.1403,-.3227,.1396,-.3213,.139,-.3213,.1243,-.3213,.1095,-.3213,.0948,-.3248,.0968,-.3283,.0987,-.3318,.1007,-.347,.1075,-.3633,.1116,-.3807,.113,-.4025,.1104,-.4212,.1027,-.437,.0899,-.4491,.0727,-.4563,.0518,-.4587,.0272,-.4565,.004,-.4497,-.0157,-.4386,-.0319,-.4239,-.0439,-.4063,-.0511,-.3859,-.0535,-.366,-.052,-.348,-.0474,-.332,-.0398,-.3284,-.0376,-.3249,-.0354,-.3213,-.0333,-.3213,-.0473,-.3213,-.0612,-.3213,-.0752,-.3225,-.0759,-.3238,-.0765,-.3251,-.0772,-.3438,-.0848,-.3652,-.0894,-.3893,-.0909,-.4204,-.0873,-.4473,-.0765,-.4698,-.0585,-.4866,-.0347,-.4966,-.0067,-.5,.0257,-.4962,.0604,-.4849,.0905,-.4661,.1159,-.4415,.1351,-.4129,.1467,-.3803,.1505,.4603,.1331,.4603,.1167,.4603,.1004,.4603,.084,.4735,.084,.4868,.084,.5,.084,.5,.0721,.5,.0602,.5,.0483,.4868,.0483,.4735,.0483,.4603,.0483,.4603,.0212,.4603,-.0059,.4603,-.033,.4607,-.0403,.4617,-.046,.4634,-.05,.4636,-.0504,.4639,-.0507,.4641,-.0511,.4668,-.0533,.4709,-.0547,.4764,-.0552,.481,-.0548,.4851,-.0535,.4886,-.0514,.4924,-.0486,.4962,-.0457,.5,-.0429,.5,-.0562],cursor:[-.416,.0813,-.3978,.0813,-.3795,.0813,-.3613,.0813,-.3613,.0712,-.3613,.0612,-.3613,.0512,-.3789,.0512,-.3965,.0512,-.4142,.0512,-.44,.0456,-.4581,.0287,-.465,-0,-.4581,-.0287,-.44,-.0456,-.4142,-.0512,-.3965,-.0512,-.3789,-.0512,-.3613,-.0512,-.3613,-.0612,-.3613,-.0712,-.3613,-.0813,-.3803,-.0813,-.3993,-.0813,-.4183,-.0813,-.4607,-.072,-.4894,-.0447,-.5,-0,-.4888,.0447,-.459,.072,-.416,.0813,-.3334,.0813,-.3221,.0813,-.3108,.0813,-.2995,.0813,-.2995,.0482,-.2995,.015,-.2995,-.0181,-.2956,-.0385,-.2832,-.0505,-.2615,-.0544,-.2398,-.0505,-.2274,-.0385,-.2234,-.0181,-.2234,.015,-.2234,.0482,-.2234,.0813,-.2121,.0813,-.2009,.0813,-.1896,.0813,-.1896,.0458,-.1896,.0104,-.1896,-.025,-.1973,-.0563,-.2211,-.0767,-.2615,-.084,-.3019,-.0767,-.3257,-.0562,-.3334,-.0248,-.3334,.0106,-.3334,.0459,-.3334,.0813,-.0125,.0352,-.0158,.0187,-.0244,.0057,-.0369,-.0028,-.0369,-.0029,-.0369,-.0031,-.0369,-.0032,-.0247,-.0079,-.0173,-.0172,-.0146,-.0299,-.0144,-.047,-.0142,-.0641,-.0139,-.0813,-.0252,-.0813,-.0365,-.0813,-.0478,-.0813,-.048,-.066,-.0483,-.0507,-.0485,-.0354,-.0507,-.0266,-.0568,-.021,-.0668,-.019,-.0856,-.019,-.1044,-.019,-.1232,-.019,-.1232,-.0397,-.1232,-.0605,-.1232,-.0813,-.1345,-.0813,-.1458,-.0813,-.1571,-.0813,-.1571,-.0271,-.1571,.0271,-.1571,.0813,-.1259,.0813,-.0947,.0813,-.0636,.0813,-.0367,.0761,-.019,.0607,-.0125,.0352,-.0466,.0306,-.0491,.0423,-.0563,.0496,-.068,.0521,-.0864,.0521,-.1048,.0521,-.1232,.0521,-.1232,.0377,-.1232,.0234,-.1232,.009,-.1046,.009,-.0861,.009,-.0675,.009,-.0564,.0115,-.0492,.0188,-.0466,.0306,.1155,-.0338,.1132,-.0244,.1067,-.0188,.097,-.0164,.0845,-.0153,.0719,-.0141,.0594,-.013,.0321,-.0064,.0156,.0085,.01,.0336,.0165,.0596,.0343,.0757,.0608,.0813,.0885,.0813,.1162,.0813,.1438,.0813,.1438,.0715,.1438,.0618,.1438,.0521,.1169,.0521,.09,.0521,.0631,.0521,.053,.0501,.0464,.0442,.0441,.0345,.0465,.0249,.0532,.019,.0633,.0164,.0761,.0154,.0889,.0143,.1016,.0132,.127,.0068,.1436,-.0082,.1496,-.0336,.1434,-.0597,.1262,-.0758,.1009,-.0813,.072,-.0813,.0431,-.0813,.0142,-.0813,.0142,-.0715,.0142,-.0618,.0142,-.0521,.042,-.0521,.0698,-.0521,.0977,-.0521,.1072,-.0498,.1133,-.0434,.1155,-.0338,.2487,.084,.293,.0737,.3218,.0447,.332,2e-4,.3214,-.0444,.292,-.0736,.2473,-.084,.1993,.0197,.2072,.0706,.2487,.084,.297,-0,.2907,.0293,.2736,.0479],openai:[-.3936,.1345,-.4472,.1199,-.4854,.0817,-.5,.0281,-.4854,-.0255,-.4472,-.0637,-.3936,-.0783,-.34,-.0638,-.3018,-.0256,-.2872,.0281,-.3227,.0635,-.3582,.099,-.3936,.1345,-.3936,-.0402,-.4268,-.031,-.4503,-.0067,-.4592,.0281,-.4261,.0189,-.4025,-.0054,-.3936,-.0402,-.1797,.0754,-.1984,.0729,-.2148,.0658,-.2272,.0547,-.2272,.0606,-.2272,.0665,-.2272,.0724,-.2401,.0724,-.2529,.0724,-.2657,.0724,-.2657,.0034,-.2657,-.0655,-.2657,-.1345,-.2529,-.1345,-.2401,-.1345,-.2272,-.1345,-.2272,-.1095,-.2272,-.0846,-.2272,-.0597,-.215,-.0699,-.1986,-.0762,-.1797,-.0783,-.1421,-.0682,-.1157,-.0411,-.1058,-.0015,-.1157,.0381,-.1421,.0653,-.1797,.0754,-.1862,-.0449,-.2066,-.0395,-.2217,-.0244,-.2275,-.0015,-.2071,-.0069,-.192,-.022,-.1862,-.0449,-.0154,.0754,-.0535,.0652,-.0803,.038,-.0904,-.0015,-.0812,-.041,-.055,-.0682,-.0142,-.0783,.0198,-.0713,.0438,-.0532,.057,-.0287,.0445,-.0287,.032,-.0287,.0195,-.0287,.0121,-.0384,4e-4,-.0449,-.0145,-.0473,-.0324,-.0429,-.0458,-.0311,-.0529,-.0136,-.0157,-.0136,.0216,-.0136,.0588,-.0136,.0588,-.0086,.0588,-.0036,.0588,.0015,.0498,.0385,.0244,.0651,-.0154,.0753,-.0154,.0754,-.0526,.0136,-.045,.0298,-.0317,.0405,-.0145,.0443,.0034,.0403,.0163,.0294,.0222,.0136,-.0028,.0136,-.0277,.0136,-.0526,.0136,.1611,.0754,.144,.0729,.1287,.0659,.1176,.055,.1176,.0608,.1176,.0666,.1176,.0724,.1048,.0724,.092,.0724,.0792,.0724,.0792,.0231,.0792,-.0261,.0792,-.0754,.092,-.0754,.1048,-.0754,.1176,-.0754,.1176,-.0489,.1176,-.0224,.1176,.0041,.1216,.0243,.1328,.0375,.1501,.0423,.1658,.0378,.1755,.0259,.1788,.0083,.1788,-.0196,.1788,-.0475,.1788,-.0754,.1916,-.0754,.2044,-.0754,.2172,-.0754,.2172,-.0454,.2172,-.0155,.2172,.0145,.2101,.0465,.1906,.0677,.1611,.0754,.3156,.1315,.2877,.0625,.2599,-.0064,.232,-.0754,.2457,-.0754,.2594,-.0754,.273,-.0754,.279,-.0603,.2849,-.0452,.2908,-.0301,.3225,-.0301,.3542,-.0301,.3859,-.0301,.3918,-.0452,.3977,-.0603,.4037,-.0754,.4175,-.0754,.4314,-.0754,.4453,-.0754,.4177,-.0064,.39,.0626,.3623,.1315,.3467,.1315,.3311,.1315,.3156,.1315,.3041,.0041,.3155,.033,.3269,.0619,.3384,.0907,.3497,.0619,.361,.033,.3723,.0041,.3496,.0041,.3268,.0041,.3041,.0041,.5,.1315,.487,.1315,.474,.1315,.461,.1315,.461,.0625,.461,-.0064,.461,-.0754,.474,-.0754,.487,-.0754,.5,-.0754,.5,-.0064,.5,.0625,.5,.1315],deepseek:[.4152,.1009,.3983,.1009,.3899,.0499,.3899,-.0522,.4068,-.0522,.4152,-.0011,.4152,.1009,-.4423,.0598,-.4327,.0598,-.4327,.0449,-.4375,.0374,-.4471,.0374,-.4642,.0339,-.4756,.0218,-.479,.0038,-.464,-.0039,-.4463,-.0039,-.4313,.0038,-.4241,.0196,-.4233,.0512,-.4233,.0958,-.4064,.0958,-.398,.0465,-.398,-.0522,-.4149,-.0522,-.4233,-.049,-.4233,-.0428,-.4264,-.0428,-.4353,-.0474,-.4536,-.0506,-.4819,-.0448,-.4965,-.0257,-.5,.0039,-.4945,.0338,-.4754,.054,-.4471,.0598,-.0664,-.0482,-.076,-.0482,-.076,-.0333,-.0712,-.0258,-.0616,-.0258,-.0445,-.0223,-.0331,-.0102,-.0297,.0078,-.0447,.0154,-.0582,.0091,-.0616,-.009,-.0616,-.0703,-.07,-.1009,-.0869,-.1009,-.0869,.0089,-.0784,.0637,-.0616,.0637,-.0616,.0575,-.06,.0543,-.0569,.0543,-.0495,.059,-.0313,.0622,-.0029,.0564,.0162,.0362,.0217,.0062,.0162,-.0238,-.0029,-.044,-.0312,-.0497,-.0514,-.0487,-.2629,-.0033,-.2629,.0027,-.2642,.0218,-.2767,.0491,-.3026,.0623,-.3332,.0623,-.3591,.0491,-.3717,.0219,-.3717,-.0103,-.3591,-.0376,-.3332,-.0508,-.3026,-.0508,-.2767,-.0376,-.2685,-.0249,-.2742,-.0174,-.2908,-.0174,-.3064,-.0253,-.3248,-.0253,-.3403,-.0174,-.3478,-.001,-.3478,.0183,-.3403,.0347,-.3248,.0426,-.3064,.0426,-.2908,.0347,-.2847,.0239,-.2989,.0176,-.3303,.0176,-.3303,.0056,-.3079,-4e-4,-.2629,-4e-4,-.2629,-.0023,-.1357,.0057,-.1357,-3e-4,-.1582,-.0033,-.2032,-.0033,-.2032,.0087,-.1882,.0147,-.1584,.0147,-.1624,.0268,-.1731,.0369,-.1908,.0405,-.1982,.0242,-.1982,.0048,-.1908,-.0115,-.1752,-.0194,-.1568,-.0194,-.1413,-.0115,-.1397,-.0096,-.1306,-.0086,-.1139,-.0086,-.1201,-.0229,-.1366,-.0374,-.166,-.0434,-.1785,-.0161,-.1681,.0085,-.1387,.0145,-.1261,-.0128,-.1284,-.0173,-.1357,.0057,.093,-.0486,.0635,-.0522,.0341,-.0486,.0142,-.0363,.0085,-.018,.0283,-.018,.0389,-.0217,.0448,-.0279,.057,-.0309,.0714,-.0309,.0836,-.0279,.0895,-.0217,.0895,-.0143,.0836,-.0081,.0709,-.0051,.0496,-.0039,.0262,.0039,.0149,.02,.0149,.0389,.0262,.0551,.0496,.0629,.0774,.0628,.1008,.0551,.1121,.039,.1047,.0295,.0876,.0295,.0851,.0365,.0767,.0413,.0641,.0427,.0587,.0365,.0588,.0291,.0641,.0229,.0747,.0199,.0964,.0187,.1223,.011,.1348,-.0052,.1348,-.0241,.1223,-.0403,.1106,-.0425,.2457,.0057,.2457,-3e-4,.2232,-.0033,.1783,-.0033,.1783,.0087,.1932,.0147,.223,.0147,.219,.0268,.2084,.0369,.1907,.0405,.1832,.0242,.1832,.0048,.1907,-.0115,.2062,-.0194,.2246,-.0194,.2402,-.0115],codex:[.3952,-.0346,.3736,-.0052,.3521,.0241,.3306,.0535,.3436,.0535,.3565,.0535,.3695,.0535,.3846,.0331,.3997,.0126,.4148,-.0078,.4299,.0126,.445,.0331,.46,.0535,.4727,.0535,.4853,.0535,.4979,.0535,.4765,.0244,.4551,-.0047,.4337,-.0339,.4558,-.0642,.4779,-.0945,.5,-.1248,.4869,-.1248,.4738,-.1248,.4608,-.1248,.4452,-.1034,.4296,-.082,.414,-.0606,.3982,-.082,.3824,-.1034,.3666,-.1248,.3539,-.1248,.3412,-.1248,.3284,-.1248,.3507,-.0947,.3729,-.0647,.3952,-.0346,.237,-.1284,.2218,-.1271,.2075,-.1233,.1942,-.117,.1825,-.1083,.1725,-.0975,.1643,-.0845,.1581,-.0697,.1544,-.0533,.1532,-.0353,.1544,-.0175,.1581,-.0014,.1643,.0132,.1727,.0262,.1828,.037,.1946,.0456,.2076,.052,.2215,.0558,.2363,.0571,.2563,.0549,.274,.0485,.2895,.0378,.3018,.0234,.3104,.0059,.3151,-.0146,.3159,-.0231,.3162,-.0322,.3162,-.0421,.2732,-.0421,.2301,-.0421,.1871,-.0421,.1892,-.0588,.1942,-.073,.2021,-.0845,.2122,-.093,.2236,-.0981,.2363,-.0999,.237,-.0999,.2377,-.0999,.2385,-.0999,.248,-.099,.2567,-.0964,.2645,-.092,.2711,-.0861,.2761,-.079,.2795,-.0706,.2909,-.0706,.3023,-.0706,.3137,-.0706,.2799,-.1089,.2564,-.1251,.237,-.1284,.2816,-.0153,.2795,-.0027,.2749,.008,.2681,.0168,.2593,.0235,.2492,.0275,.2377,.0289,.2369,.0289,.2361,.0289,.2352,.0289,.2243,.0277,.2142,.024,.2049,.0178,.1974,.0094,.1918,-.0017,.1882,-.0153,.2193,-.0153,.2505,-.0153,.2816,-.0153,.0207,-.1284,.0058,-.1271,-.0081,-.1233,-.021,-.117,-.0323,-.1083,-.0418,-.0975,-.0495,-.0845,-.0553,-.0697,-.0587,-.0535,-.0599,-.0357,-.0587,-.0179,-.0551,-.0016,-.0492,.0132,-.0412,.0262,-.0314,.037,-.0199,.0456,-.0069,.052,.0072,.0558,.0221,.0571,.0343,.0562,.0456,.0536,.056,.0492,.0652,.0435,.0727,.0369,.0785,.0292,.0785,.0611,.0785,.093,.0785,.1248,.0898,.1248,.1011,.1248,.1124,.1248,.1124,.0416,.1124,-.0416,.1124,-.1248,.1011,-.1248,.0898,-.1248,.0785,-.1248,.0785,-.1166,.0785,-.1084,.0785,-.1002,.0728,-.1077,.0652,-.1143,.0557,-.1202,.0448,-.1247,.0331,-.1275,.0207,-.1284,.0275,-.0995,.0371,-.0986,.046,-.0959,.0542,-.0913,.0615,-.0852,.0675,-.0777,.0724,-.0688,.0762,-.0586,.0784,-.0476,.0792,-.0357,.0784,-.0238,.0762,-.0128,.0724,-.0028,.0675,.0062,.0615,.0138,.0542,.02,.0535,.02,.0528,.02,.0521,.02,.0378,.018,.0255,.012,.015,.0021,.0073,-.0109,.0026,-.0262,.0011,-.0439,.0026,-.0615],opencode:[-.4231,-.0385,-.4402,-.0385,-.4573,-.0385,-.4744,-.0385,-.4744,-.0214,-.4744,-.0043,-.4744,.0128,-.4573,.0128,-.4402,.0128,-.4231,.0128,-.4231,-.0043,-.4231,-.0214,-.4231,-.0385,-.4231,.0385,-.4402,.0385,-.4573,.0385,-.4744,.0385,-.4744,.0128,-.4744,-.0128,-.4744,-.0385,-.4573,-.0385,-.4402,-.0385,-.4231,-.0385,-.4231,-.0128,-.4231,.0128,-.4231,.0385,-.3974,-.0641,-.4316,-.0641,-.4658,-.0641,-.5,-.0641,-.5,-.0214,-.5,.0214,-.5,.0641,-.4658,.0641,-.4316,.0641,-.3974,.0641,-.3974,.0214,-.3974,-.0214,-.3974,-.0641,-.2949,-.0385,-.312,-.0385,-.3291,-.0385,-.3462,-.0385,-.3462,-.0214,-.3462,-.0043,-.3462,.0128,-.3291,.0128,-.312,.0128,-.2949,.0128,-.2949,-.0043,-.2949,-.0214,-.2949,-.0385,-.3462,-.0385,-.3291,-.0385,-.312,-.0385,-.2949,-.0385,-.2949,-.0128,-.2949,.0128,-.2949,.0385,-.312,.0385,-.3291,.0385,-.3462,.0385,-.3462,.0128,-.3462,-.0128,-.3462,-.0385,-.2692,-.0641,-.2949,-.0641,-.3205,-.0641,-.3462,-.0641,-.3462,-.0727,-.3462,-.0812,-.3462,-.0897,-.3547,-.0897,-.3632,-.0897,-.3718,-.0897,-.3718,-.0385,-.3718,.0128,-.3718,.0641,-.3376,.0641,-.3034,.0641,-.2692,.0641,-.2692,.0214,-.2692,-.0214,-.2692,-.0641,-.141,-.0128,-.141,-.0214,-.141,-.0299,-.141,-.0385,-.1667,-.0385,-.1923,-.0385,-.2179,-.0385,-.2179,-.0299,-.2179,-.0214,-.2179,-.0128,-.1923,-.0128,-.1667,-.0128,-.141,-.0128,-.1667,-.0128,-.1923,-.0128,-.2179,-.0128,-.2179,-.0214,-.2179,-.0299,-.2179,-.0385,-.1923,-.0385,-.1667,-.0385,-.141,-.0385,-.141,-.047,-.141,-.0556,-.141,-.0641,-.1752,-.0641,-.2094,-.0641,-.2436,-.0641,-.2436,-.0214,-.2436,.0214,-.2436,.0641,-.2094,.0641,-.1752,.0641,-.141,.0641,-.141,.0385,-.141,.0128,-.141,-.0128,-.2179,.0128,-.2009,.0128,-.1838,.0128,-.1667,.0128,-.1667,.0214,-.1667,.0299,-.1667,.0385,-.1838,.0385,-.2009,.0385,-.2179,.0385,-.2179,.0299,-.2179,.0214,-.2179,.0128,-.0385,-.0641,-.0556,-.0641,-.0726,-.0641,-.0897,-.0641,-.0897,-.0385,-.0897,-.0128,-.0897,.0128,-.0726,.0128,-.0556,.0128,-.0385,.0128,-.0385,-.0128,-.0385,-.0385,-.0385,-.0641,-.0385,.0385,-.0556,.0385,-.0726,.0385,-.0897,.0385,-.0897,.0043,-.0897,-.0299,-.0897,-.0641,-.0983,-.0641,-.1068,-.0641,-.1154,-.0641,-.1154,-.0214,-.1154,.0214,-.1154,.0641,-.0897,.0641,-.0641,.0641,-.0385,.0641,-.0385,.0556,-.0385,.047,-.0385,.0385,-.0128,-.0641,-.0214,-.0641,-.0299,-.0641,-.0385,-.0641,-.0385,-.0299,-.0385,.0043,-.0385,.0385,-.0299,.0385,-.0214,.0385,-.0128,.0385,-.0128,.0043,-.0128,-.0299,-.0128,-.0641,.1154,-.0385],zai:[.4077,-.1739,.4077,-.0674,.4077,.039,.4077,.1454,.4372,.1454,.4667,.1454,.4963,.1454,.4963,.039,.4963,-.0674,.4963,-.1739,.4667,-.1739,.4372,-.1739,.4077,-.1739,.4522,.1866,.4444,.196,.4398,.2066,.4383,.2184,.4398,.23,.4444,.2405,.4522,.2498,.4647,.2483,.4759,.2438,.4858,.2364,.4937,.2271,.4984,.2167,.5,.2051,.4984,.1933,.4937,.1827,.4859,.1733,.4746,.1777,.4634,.1821,.4522,.1866,.1592,-.1799,.1395,-.1787,.1214,-.1752,.1047,-.1693,.0971,-.154,.0925,-.1364,.091,-.1165,.0921,-.0997,.0953,-.0848,.1008,-.0718,.1081,-.0606,.1169,-.0508,.1274,-.0427,.142,-.0393,.1571,-.0367,.1727,-.0348,.183,-.0327,.1913,-.0301,.1975,-.0269,.2017,-.0229,.2043,-.0178,.2051,-.0115,.2051,-.0111,.2051,-.0107,.2051,-.0103,.2037,.0019,.1996,.0121,.1927,.0203,.1833,.0263,.1717,.0299,.1577,.0311,.1429,.0299,.1302,.0264,.1197,.0205,.0924,.0227,.0651,.0249,.0378,.0271,.0511,.0403,.0669,.0512,.085,.06,.1054,.0664,.1278,.0703,.1523,.0716,.1698,.0709,.1868,.0688,.2032,.0654,.219,.0604,.2335,.054,.2467,.046,.2585,.0365,.2686,.0252,.2768,.0124,.283,-.0021,.2866,-.0184,.2879,-.0365,.2879,-.1083,.2879,-.1801,.2879,-.2518,.2599,-.2518,.2319,-.2518,.2039,-.2518,.2039,-.2371,.2039,-.2223,.2039,-.2076,.203,-.2076,.2022,-.2076,.2014,-.2076,.1957,-.2172,.1888,-.226,.1808,-.234,.1681,-.2374,.1542,-.2395,.139,-.2402,.1457,-.2201,.1525,-.2,.1592,-.1799,.1845,-.1188,.1971,-.1179,.2086,-.1154,.2191,-.1111,.2283,-.1052,.2361,-.0982,.2426,-.0899,.2473,-.0806,.2501,-.0706,.2511,-.0598,.2511,-.0485,.2511,-.0372,.2511,-.0259,.2479,-.0276,.2441,-.0293,.2396,-.0309,.2342,-.0316,.2288,-.0324,.2234,-.0332,.2135,-.035,.2044,-.0374,.1962,-.0404,.189,-.0442,.183,-.0487,.1781,-.0539,.1745,-.0599,.1724,-.0669,.1717,-.0747,.1731,-.0858,.1775,-.0951,.1848,-.1024,.1944,-.1076,.2057,-.1107,.2184,-.1117,.2071,-.1141,.1958,-.1164,.1845,-.1188,-.0545,-.1793,-.0529,-.1664,-.048,-.1547,-.0399,-.1444,-.0294,-.1363,-.0177,-.1314,-.0046,-.1298,.0082,-.1314,.0198,-.1363,.0303,-.1444,.0387,-.1547,.0437,-.1664,.0453,-.1793,.0445,-.1882,.0422,-.1966,.0382,-.2044,.0332,-.2114,.0272,-.2175,.0202,-.2225,-.0047,-.2081,-.0296,-.1937,-.0545,-.1793,-.4996,-.1739,-.4996,-.1561,-.4996,-.1383,-.4996,-.1205,-.4288,-.0211,-.358,.0783,-.2872,.1776,-.3581,.1776,-.4291,.1776,-.5,.1776,-.5,.2024,-.5,.2271,-.5,.2518],minimax:[-.5,-.0909,-.5,-.0303,-.5,.0303,-.5,.0909,-.4872,.0909,-.4744,.0909,-.4615,.0909,-.4482,.0702,-.4348,.0495,-.4214,.0288,-.4084,.0495,-.3954,.0702,-.3824,.0909,-.3703,.0909,-.3582,.0909,-.3462,.0909,-.3462,.0303,-.3462,-.0303,-.3462,-.0909,-.3582,-.0908,-.3703,-.0906,-.3824,-.0904,-.3824,-.0519,-.3824,-.0135,-.3824,.025,-.3923,.0107,-.4022,-.0036,-.4121,-.0179,-.4181,-.0179,-.4242,-.0179,-.4302,-.0179,-.4407,-.0036,-.4511,.0107,-.4615,.025,-.4615,-.0136,-.4615,-.0523,-.4615,-.0909,-.4744,-.0909,-.4872,-.0909,-.5,-.0909,-.2775,.0909,-.2892,.0909,-.3009,.0909,-.3126,.0909,-.3126,.0303,-.3126,-.0303,-.3126,-.0909,-.3009,-.0909,-.2892,-.0909,-.2775,-.0909,-.2775,-.0303,-.2775,.0303,-.2775,.0909,-.2451,.0909,-.2328,.0909,-.2205,.0909,-.2082,.0909,-.1855,.0534,-.1628,.0158,-.1401,-.0217,-.1401,.0158,-.1401,.0534,-.1401,.0909,-.128,.0909,-.1159,.0909,-.1038,.0909,-.1038,.0303,-.1038,-.0303,-.1038,-.0909,-.1159,-.0909,-.128,-.0909,-.1401,-.0909,-.1628,-.0538,-.1855,-.0166,-.2082,.0206,-.2082,-.0164,-.2082,-.0534,-.2082,-.0904,-.2205,-.0904,-.2328,-.0904,-.2451,-.0904,-.2451,-.0299,-.2451,.0305,-.2451,.0909,-.0352,.0909,-.0476,.0909,-.0601,.0909,-.0725,.0909,-.0725,.0303,-.0725,-.0303,-.0725,-.0909,-.0601,-.0909,-.0476,-.0909,-.0352,-.0909,-.0352,-.0303,-.0352,.0303,-.0352,.0909,-.0033,.0909,-.0033,.0303,-.0033,-.0303,-.0033,-.0909,.0095,-.0909,.0223,-.0909,.0352,-.0909,.0352,-.0523,.0352,-.0136,.0352,.025,.0456,.0107,.056,-.0036,.0665,-.0179,.0725,-.0179,.0786,-.0179,.0846,-.0179,.0945,-.0036,.1044,.0107,.1143,.025,.1143,-.0135,.1143,-.0519,.1143,-.0904,.1264,-.0906,.1385,-.0908,.1506,-.0909,.1506,-.0303,.1506,.0303,.1506,.0909,.1385,.0909,.1264,.0909,.1143,.0909,.1013,.0702,.0883,.0495,.0753,.0288,.0619,.0495,.0485,.0702,.0352,.0909,.0223,.0909,.0095,.0909,-.0033,.0909,.1736,-.0909,.1929,-.0303,.2121,.0303,.2313,.0909,.2467,.0909,.2621,.0909,.2775,.0909,.2969,.0303,.3163,-.0303,.3357,-.0909,.3222,-.0909,.3086,-.0909,.2951,-.0909,.2924,-.0818,.2897,-.0726,.287,-.0635,.2653,-.0635,.2437,-.0635,.222,-.0635,.2193,-.0726,.2165,-.0818,.2137,-.0909,.2004,-.0909,.187,-.0909,.1736,-.0909,.2315,-.0327,.2469,-.0327,.2623,-.0327,.2777,-.0327,.2701,-.0074,.2625,.0179,.2549,.0431,.2471,.0179,.2393,-.0074,.2315,-.0327,.5,.0909,.4855,.0909,.4711,.0909,.4566,.0909,.4456,.0725,.4346,.0541,.4237,.0356,.4125,.0541],kimi:[.4789,.0599,.486,.0599,.493,.0599,.5,.0599,.5,.0209,.5,-.018,.5,-.0569,.493,-.0569,.486,-.0569,.4789,-.0569,.4789,-.018,.4789,.0209,.4789,.0599,.2651,.0599,.2651,.0494,.2651,.0389,.2651,.0284,.2715,.0284,.2779,.0284,.2842,.0284,.2842,.0214,.2842,.0144,.2842,.0074,.2779,.0074,.2715,.0074,.2651,.0074,.2651,-.0141,.2651,-.0355,.2651,-.0569,.2581,-.0569,.2511,-.0569,.2441,-.0569,.2441,-.0355,.2441,-.0141,.2441,.0074,.2382,.0074,.2322,.0074,.2263,.0074,.2263,.0144,.2263,.0214,.2263,.0284,.2322,.0284,.2382,.0284,.2441,.0284,.2441,.0389,.2441,.0494,.2441,.0599,.2511,.0599,.2581,.0599,.2651,.0599,.1178,-.0061,.1178,-.0231,.1178,-.04,.1178,-.057,.1112,-.057,.1045,-.057,.0978,-.057,.0978,-.0394,.0978,-.0219,.0978,-.0043,.0943,.0058,.0867,.0113,.0792,.013,.0791,.013,.0789,.013,.0788,.013,.0705,.0112,.0617,.0043,.0576,-.0101,.0576,-.0257,.0576,-.0414,.0576,-.057,.0507,-.057,.0438,-.057,.0368,-.057,.0368,-.0181,.0368,.0209,.0368,.0598,.0438,.0598,.0508,.0599,.0577,.0599,.0577,.0461,.0577,.0323,.0577,.0185,.0673,.0272,.0783,.031,.0862,.0319,.0916,.0316,.0966,.0306,.1013,.0291,.1056,.0269,.1093,.0241,.1125,.0206,.1146,.0173,.1161,.014,.117,.0106,.1175,.0065,.1177,9e-4,.1178,-.0061,.0227,.0149,.018,.0101,.0133,.0053,.0086,5e-4,-.0096,.01,-.0258,.011,-.0345,.0061,-.0317,4e-4,-.0204,-.003,-.0062,-.0058,-.0049,-.0061,-.0037,-.0064,-.0024,-.0067,.0093,-.0104,.0202,-.0179,.0247,-.0313,.0172,-.0488,.0011,-.0575,-.0164,-.0599,-.0331,-.0567,-.0493,-.0491,-.0622,-.0399,-.0571,-.0346,-.0521,-.0294,-.047,-.0241,-.0289,-.0354,-.0107,-.0382,0,-.0333,-9e-4,-.0271,-.011,-.024,-.0289,-.0215,-.0449,-.0156,-.0546,-.006,-.0578,.0032,-.0542,.0157,-.0424,.0273,-.02,.0325,-.0026,.0306,.0114,.0248,.0227,.0149,-.1127,.0126,-.1128,.0126,-.1129,.0126,-.1234,.0096,-.1308,.002,-.1336,-.0098,-.1336,-.0255,-.1336,-.0412,-.1336,-.0569,-.1413,-.0569,-.1489,-.0569,-.1566,-.0569,-.1566,-.0283,-.1566,2e-4,-.1566,.0288,-.1492,.0288,-.1418,.0288,-.1344,.0288,-.1344,.0247,-.1344,.0206,-.1344,.0165,-.1342,.0167,-.1341,.017,-.1339,.0172,-.1285,.0233,-.1191,.0296,-.1052,.0323,-.0892,.0285,-.0763,.0179,-.0711,.0014,-.0711,-.0181,-.0711,-.0375,-.0711,-.0569,-.0789,-.0569,-.0868,-.0569,-.0947,-.0569,-.0947,-.0393,-.0947,-.0217,-.0947,-.0042,-.0982,.0061,-.1056,.0113],cline:[.4243,-.0757,.41,-.0749,.3965,-.0724,.3838,-.0683,.3838,-.0658,.3838,-.0633,.3838,-.0608,.3846,-.0457,.3871,-.0316,.3912,-.0184,.3967,-.0064,.4034,.0044,.4114,.014,.4252,.0132,.4379,.0107,.4495,.0066,.46,.0012,.4693,-.0055,.4773,-.0135,.4842,-.0227,.4899,-.0331,.4943,-.0446,.4975,-.057,.4994,-.0701,.5,-.084,.5,-.0903,.5,-.0966,.5,-.103,.4565,-.103,.4131,-.103,.3696,-.103,.3696,-.1033,.3696,-.1036,.3696,-.1039,.3712,-.1121,.3733,-.1194,.3759,-.1258,.379,-.1315,.3829,-.1368,.3875,-.1416,.3927,-.1462,.3984,-.15,.4048,-.153,.4117,-.1553,.4191,-.1566,.4269,-.1571,.4376,-.1564,.4477,-.1543,.4574,-.1508,.4653,-.1584,.4732,-.166,.481,-.1737,.4732,-.1829,.463,-.1915,.4504,-.1994,.4359,-.2058,.4193,-.2096,.4009,-.2109,.4087,-.1658,.4165,-.1207,.4243,-.0757,.4189,.0952,.4128,.0948,.407,.0937,.4015,.0917,.3964,.0892,.3916,.086,.3873,.0821,.3833,.0775,.3798,.0724,.3768,.0667,.408,.0667,.4393,.0667,.4705,.0667,.4705,.0676,.4705,.0686,.4705,.0696,.4702,.0754,.4691,.0811,.4674,.0867,.4615,.0889,.4551,.0902,.448,.0906,.4383,.0921,.4286,.0937,.4189,.0952,.1048,-.072,.1048,-.0056,.1048,.0608,.1048,.1272,.118,.1272,.1313,.1272,.1446,.1272,.1455,.1178,.1464,.1083,.1473,.0989,.1501,.1026,.1531,.1061,.1562,.1094,.1595,.1126,.163,.1155,.1667,.1182,.1722,.1112,.1769,.1031,.1807,.0937,.1834,.0832,.1851,.0713,.1856,.058,.1856,.0166,.1856,-.0249,.1856,-.0663,.171,-.0663,.1563,-.0663,.1416,-.0663,.1416,-.0251,.1416,.0161,.1416,.0573,.1413,.065,.1404,.0719,.1389,.0779,.1367,.083,.134,.0875,.1308,.0912,.1255,.0909,.1205,.0902,.1157,.0889,.1157,.0416,.1157,-.0058,.1157,-.0532,.101,-.0532,.0863,-.0532,.0717,-.0532,.0827,-.0595,.0937,-.0657,.1048,-.072,-.1116,.1272,-.0764,.1272,-.0411,.1272,-.0059,.1272,-.0059,.073,-.0059,.0187,-.0059,-.0355,.0136,-.0355,.0332,-.0355,.0527,-.0355,.0527,-.0477,.0527,-.0598,.0527,-.072,-.0021,-.072,-.0568,-.072,-.1116,-.072,-.1116,-.0598,-.1116,-.0477,-.1116,-.0355,-.0911,-.0355,-.0707,-.0355,-.0503,-.0355,-.0503,.0065,-.0503,.0486,-.0503,.0906,-.0707,.0906,-.0911,.0906,-.1116,.0906,-.1116,.1028,-.1116,.115,-.1116,.1272,-.0543,.1788,-.0541,.1823,-.0535,.1855,-.0525,.1886,-.0501,.1905,-.0475,.1921,-.0446,.1934,-.0412,.1944,-.0377,.195,-.0339,.1952,-.0277,.1946,-.0223,.1929,-.0178,.1901,-.0143,.1864],kilocode:[.4709,-.0707,.4542,-.0684,.4406,-.0614,.431,-.0507,.4262,-.0365,.4255,-.0193,.4255,-.0012,.428,.0144,.4382,.024,.455,.0263,.4715,.024,.4849,.017,.4943,.0061,.4994,-.008,.5,-.0226,.5,-.0356,.4556,-.0356,.4334,-.0381,.4334,-.0432,.4358,-.056,.4432,-.0637,.4552,-.0662,.4648,-.065,.4716,-.0612,.475,-.055,.4912,-.055,.4963,-.0637,.4843,-.0774,.4659,-.0847,.4603,-.0807,.4709,-.0707,.4921,-.0049,.4921,-.001,.4898,.0116,.4827,.0195,.4709,.0222,.4591,.0195,.4548,.0147,.4548,.012,.4846,.0122,.4988,.0117,.4976,.0104,.494,-.0011,.3457,-.0707,.3269,-.0658,.3141,-.0512,.3097,-.0295,.3097,-.01,.3108,.0116,.3195,.03,.3355,.04,.354,.0404,.3669,.0336,.3739,.0211,.3729,.0149,.3692,.0187,.373,.0187,.3747,.0272,.3741,.0444,.3741,.0646,.3823,.0747,.3987,.0747,.3987,-.021,.3907,-.0688,.3747,-.0688,.3747,-.055,.3729,-.0481,.3692,-.0481,.3729,-.0443,.3739,-.0506,.3669,-.0633,.354,-.0699,.3543,-.0495,.365,-.0471,.3718,-.0397,.3741,-.0283,.3741,-.0102,.3736,.005,.3688,.0143,.3601,.0194,.3485,.0194,.3396,.0145,.3349,.0051,.3343,-.0102,.3343,-.0283,.3366,-.0398,.3436,-.0471,.3543,-.0495,.2303,-.07,.2151,-.0654,.2102,-.0511,.2096,-.0339,.2096,-.0161,.212,-4e-4,.2223,.0092,.239,.0116,.2559,.0092,.2662,-4e-4,.2687,-.0159,.2687,-.0339,.2681,-.0511,.263,-.0654,.2479,-.07,.239,-.0491,.2501,-.0468,.2572,-.0396,.2597,-.0281,.2597,-.0103,.2591,.005,.2542,.0143,.2451,.0191,.2331,.0191,.2239,.0143,.219,.005,.2184,-.0103,.2184,-.0281,.2209,-.0396,.228,-.0468,.239,-.0491,.1152,-.0702,.0998,-.0656,.0882,-.0567,.0809,-.0441,.0784,-.0283,.0784,.0133,.079,.0425,.0839,.0568,.0993,.0615,.1169,.0615,.1321,.0568,.1371,.0425,.1295,.0342,.113,.0342,.1105,.0456,.1034,.0526,.0922,.055,.0808,.0526,.0736,.0456,.0711,.0344,.0711,-.0074,.0718,-.0345,.0767,-.0438,.086,-.0485,.0983,-.0485,.1075,-.0438,.1124,-.0345,.1212,-.0283,.1378,-.0283,.1352,-.0439,.1249,-.0535,.1081,-.0558,.1187,-.0658,-.1085,-.0705,-.1252,-.0683,-.1355,-.0586,-.1379,-.0428,-.1379,-.025,-.1373,-.0079,-.1324,.0063,-.1173,.011,-.0996,.011,-.0845,.0063,-.0794,-.0078,-.0788,-.0249,-.0788,-.0428,-.0813,-.0586,-.0916,-.0683,-.1085,-.0705,-.1024,-.0485,-.0933,-.0438,-.0885,-.0344,-.0878,-.0192,-.0878,-.0014,-.0903,.0102,-.0974,.0173,-.1085,.0196,-.1195,.0173,-.1236,.0054,-.1236,-.0124,-.1212,-.0239],roocode:[-.4635,-.0068,-.4369,-.0068,-.4159,-.0062,-.4047,-.0013,-.3991,.0092,-.3991,.0239,-.4047,.034,-.4159,.0389,-.4369,.0395,-.4635,.0395,-.4635,.0086,-.5,.0676,-.4403,.0676,-.4033,.0672,-.3905,.0639,-.3833,.0547,-.3788,.0439,-.3773,.0319,-.3801,.0143,-.3885,3e-4,-.4035,-.0093,-.4035,-.0096,-.3993,-.0113,-.3924,-.0155,-.3872,-.0212,-.3835,-.028,-.3812,-.0358,-.3798,-.0441,-.3792,-.051,-.3789,-.0575,-.3785,-.0646,-.3777,-.0719,-.3763,-.0789,-.374,-.0847,-.3846,-.0872,-.4089,-.0872,-.4119,-.0754,-.4143,-.0607,-.4205,-.0496,-.432,-.0443,-.448,-.0436,-.4635,-.0436,-.4635,-.0865,-.4757,-.1079,-.5,-.1079,-.5,.0091,-.3181,-.0374,-.3175,-.0469,-.3156,-.0558,-.312,-.0637,-.3065,-.0698,-.299,-.074,-.289,-.0754,-.2791,-.074,-.273,-.0684,-.2702,-.06,-.2708,-.0506,-.2756,-.044,-.2855,-.0425,-.2955,-.044,-.3057,-.0431,-.3181,-.0374,-.3506,-.0282,-.3467,-.0116,-.3391,.0024,-.3262,.0107,-.3086,.0128,-.2946,.0052,-.2838,-.0057,-.2762,-.0197,-.2723,-.0363,-.2776,-.0505,-.2916,-.0579,-.308,-.0618,-.3196,-.0543,-.3216,-.0365,-.3412,-.0371,-.1876,-.0374,-.187,-.0469,-.1851,-.0558,-.1816,-.0637,-.1729,-.0666,-.1624,-.0666,-.1537,-.0637,-.15,-.0558,-.149,-.0468,-.1502,-.0374,-.1589,-.0344,-.1694,-.0344,-.1781,-.0374,-.1845,-.0374,-.2206,-.0374,-.2187,-.0196,-.2129,-.0042,-.2037,.0082,-.1872,.0123,-.1689,.0123,-.1525,.0082,-.1386,6e-4,-.1278,-.0103,-.1202,-.0243,-.1163,-.0409,-.1216,-.0551,-.1356,-.0625,-.152,-.0664,-.1703,-.0664,-.1867,-.0625,-.1906,-.046,-.2009,-.037,-.2206,-.0374,.0729,.0118,.0598,.0075,.0609,-.0061,.0642,-.019,.07,-.0303,.0832,-.0344,.1013,-.0338,.117,-.0248,.1264,-.0084,.1404,.002,.164,.002,.1601,-.0173,.1479,-.0285,.1286,-.0305,.1049,-.0277,.0847,-.0191,.0687,-.0059,.0637,.016,.0637,.0397,.0687,.0618,.0783,.0812,.0922,.0968,.1103,.1079,.0359,.0724,.0535,.0711,.0703,.0676,.0766,.0514,.0664,.0423,.0429,.0423,.0681,.0223,.1566,-.0374,.1572,-.0469,.1591,-.0558,.1626,-.0637,.1682,-.0698,.1757,-.074,.1856,-.0754,.1955,-.074,.2017,-.0684,.2044,-.06,.2038,-.0506,.199,-.044,.1891,-.0425,.1792,-.044,.169,-.0431,.1566,-.0374,.1241,-.0282,.128,-.0116,.1355,.0024,.1484,.0107,.1661,.0128,.1838,.0107,.199,.0048,.2114,-.0045,.2206,-.0169,.2264,-.0323,.2284,-.0501,.216,-.0592,.2007,-.065,.183,-.0669,.1654,-.065,.155,-.0546,.1531,-.0368,.1334,-.0372,.343,-.037,.3424,-.0275,.3378,-.0211,.3282,-.0197,.3185,-.0211,.3146,-.0275],hermes:[.4912,.1215,.4505,.1948,.424,.1591,.5,.0303,.4305,-.0126,.3901,.0587,.3906,.0725,.4126,.0147,.4641,.0064,.4083,.101,.3851,.1495,.4199,.2013,.4453,.2031,.4452,.1789,.4758,.1283,-.3906,.1108,-.3813,.1693,-.4022,.1984,-.3477,.2008,-.3189,.2004,-.3186,.199,-.3322,.1744,-.3329,.0497,-.3281,.0084,-.3837,-.001,-.3814,.0093,-.39,.025,-.4032,.0137,-.384,-.0012,-.4597,.0024,-.4499,.0369,-.4498,.1607,-.4963,.1973,-.4434,.1991,-.4173,.1962,-.4386,.1501,-.4193,.1099,-.4082,.1108,.0963,.3644,.0967,.2527,.1087,.1931,.0688,.1813,.0878,.224,.0845,.3028,.0665,.3139,.0916,.1427,.1078,.0838,.1436,.201,.2092,.2024,.1927,.1928,.1869,.1516,.1875,.0255,.2034,-6e-4,.2054,-.0033,.1765,-.0033,.1246,-.0027,.145,.0223,.1467,.0948,.1464,.1818,.1476,.179,.2851,0,.3527,.0776,.3531,.0323,.2212,-.0074,.2432,.0266,.2428,.0691,.221,.0982,.2639,.0997,.3521,.0408,.2858,.1942,.2858,.1087,.2868,.1077,.3256,.1506,.3263,.1007,.326,.0567,.2873,.0985,.2863,.0018,-.2101,.0137,-.1745,.0766,-.1745,-.0074,-.295,-.0028,-.2839,.036,-.2864,.0803,-.3071,.0986,-.1965,.0998,-.1765,.0276,-.2412,.1658,-.241,.1084,-.2398,.1076,-.201,.1499,-.2007,.0902,-.2392,.104,-.2403,.0055,-.0631,.0993,-.0315,.0954,-.0167,.0895,-.0423,.1473,-.0287,.1292,-.1047,.1267,-.0826,.1577,-.0817,.159,-.0843,.1806,-.1048,.1986,-.053,.1999,.0324,.1468,-.0367,.0977,-.0842,.1658,-.0841,.102,-.0706,.1054,-.0562,.1191,-.0492,.14,-.0489,.1543,-.0665,.1921,-.0841,.1978,-.287,-.1989,-.3258,-.2754,-.3948,-.2513,-.4099,-.1124,-.3091,-.0636,-.2903,-.1407,-.3318,-.1014,-.3526,-.1776,-.2976,-.2644,-.2949,-.2314,-.3081,-.1743,-.287,-.1676,-.4867,-.2218,-.4764,-.1622,-.4604,-.0739,-.4173,-.0684,-.3918,-.2731,-.4454,-.2726,-.4287,-.2692,-.4396,-.2368,-.4852,-.2739,-.4422,-.2065,-.4494,-.0922,-.4765,-.2066,-.1431,-.2651,-.0887,-.2206,-.0745,-.1901,-.142,-.2726,-.1884,-.2608,-.1838,-.2204,-.1904,-.1755,-.2076,-.1661,-.076,-.1654,-.0906,-.2069,-.1437,-.229,-.1433,-.2583,-.1232,-.2524,-.1033,-.2163,-.1025,-.2186,-.1026,-.3086,-.1226,-.2751,-.1415,-.3644,-.0154,-.123,-.0148,-.2064,-.0038,-.259,-.0417,-.2705,-.0225,-.1923,-.0385,-.184,5e-4,-.1832,.0023,-.1569,-.0048,-.0732,.0304,-.0585,.0092,-.1027,-.0535,-.0363,-.0154,-.123,.2702,-.0626,.2701,-.1514,.261,-.1273,.2232,-.0683,.2234,-.2239,.2303,-.2581,.2465,-.268,.1816,-.2681,.17,-.2647,.1835,-.2458,.1856,-.1647],piagent:[-.4953,-.0709,-.5,-.0653,-.4941,-.059,-.485,-.0504,-.4872,.0485,-.4982,.0533,-.5,.0588,-.4692,.0634,-.4515,.0583,-.4554,.0521,-.4663,.0463,-.4663,-.0537,-.4555,-.0596,-.4515,-.0658,-.4693,-.0709,-.4438,-.0689,-.4439,-.0628,-.4363,-.0592,-.4309,-.0187,-.4426,.0086,-.4444,.0134,-.4285,.0225,-.4149,.0185,-.4118,.0142,-.3884,.0242,-.3528,-.0183,-.3472,-.0592,-.3398,-.0628,-.3399,-.0689,-.3653,-.0711,-.37,-.0258,-.3858,.0097,-.3876,-.0446,-.3797,-.0526,-.3742,-.0583,-.3789,-.0638,-.4309,-.0686,-.3282,-.0711,-.3329,-.0655,-.3275,-.0599,-.3194,-.0518,-.3206,.0108,-.3315,.0118,-.3337,.0173,-.3285,.0233,-.3229,.0333,-.2815,.0733,-.2566,.0685,-.2412,.0732,-.2374,-.0518,-.2292,-.0599,-.2237,-.0655,-.2287,-.0711,-.2674,-.0689,-.2676,-.0628,-.2599,-.0591,-.2543,.0116,-.2674,.0564,-.3073,.0425,-.2819,.0237,-.276,.018,-.2807,.0111,-.302,.01,-.3019,-.0553,-.293,-.0603,-.2889,-.066,-.138,-.0528,-.2189,-.0502,-.1621,.0215,-.1443,-.0109,-.1858,-.0515,-.1427,-.0418,-.1366,-.0497,-.2083,-.0178,-.2055,-.0203,-.1604,-.0028,-.1947,.0088,-.1087,.0186,-.067,.0235,-.0572,.0213,-.0475,-.0044,-.0524,-.0068,-.0853,.0131,-.0961,-.0523,-.052,-.0478,-.0465,-.056,-.1242,-.0501,-.0277,.0083,-.039,.0103,-.0393,.0182,-.0186,.0403,-.0083,.0416,-.0016,.0253,.0155,.0208,.0133,.0135,-.0085,-.0068,6e-4,-.0552,.0058,-.0628,-.0286,-.0482,.0279,-.0693,.0278,-.0632,.0354,-.0595,.0408,-.0193,.0292,.0079,.0273,.0127,.0438,.022,.0578,-.0044,.0632,-.0595,.0708,-.0632,.0707,-.0693,.0321,-.0714,.054,.0635,.0471,.0413,.0774,.0015,.0711,-.0242,.0553,-.0078,.1157,.011,.1035,-.0538,.1727,-.0714,.1679,-.0659,.1734,-.0603,.1814,-.0522,.178,.0053,.1679,.0123,.1721,.0177,.1964,.0233,.1979,.0139,.2037,.0156,.2567,.0127,.26,-.0557,.2688,-.0607,.273,-.0664,.2612,-.0714,.2424,-.0668,.2372,.0094,.2248,-.0124,.2301,-.0522,.2378,-.0559,.2376,-.062,.199,-.0641,.4822,-.0713,.4513,-.0667,.4531,-.0611,.4642,-.0564,.4664,.0428,.4572,.0514,.4513,.0578,.4561,.0634,.4994,.0613,.4995,.0549,.4903,.0502,.4847,-.0195,.4922,-.0587,.5,-.0652,.4978,-.0708,.3165,-.0713,.3115,-.0658,.3165,-.0602,.3296,-.0494,.3638,.047,.3503,.0532,.3494,.0594,.3704,.0634,.3988,.0238,.438,-.0586,.4454,-.0632,.4452,-.0692,.4037,-.0713,.3987,-.0657,.4035,-.0603,.41,-.0517,.4019,-.033,.3514,-.033,.3441,-.05,.3516,-.0607,.3564,-.0658,.3516,-.0713,.3966,-.0208,.3778,.0309,.3621,-.0019],google:[-.2556,4e-4,-.259,-.0311,-.269,-.058,-.2857,-.0803,-.3105,-.1001,-.3401,-.112,-.3744,-.116,-.4077,-.1119,-.4374,-.0998,-.4635,-.0796,-.4838,-.0534,-.4959,-.0235,-.5,.0101,-.4959,.0438,-.4838,.0737,-.4635,.0998,-.4374,.1201,-.4077,.1322,-.3744,.1363,-.357,.1352,-.3402,.1321,-.3241,.1268,-.3093,.1197,-.2964,.1108,-.2853,.1002,-.2927,.0928,-.3002,.0854,-.3076,.0779,-.3158,.0863,-.3254,.0933,-.3365,.099,-.3614,.096,-.3837,.0869,-.4033,.0717,-.4183,.0517,-.4273,.0287,-.4303,.0026,-.4107,-.0126,-.3884,-.0217,-.3635,-.0248,-.3407,-.0225,-.3207,-.0158,-.3034,-.0045,-.2897,.0106,-.2804,.0292,-.2757,.0511,-.305,.0511,-.3342,.0511,-.3635,.0511,-.3635,.0608,-.3635,.0705,-.3635,.0801,-.3244,.0801,-.2854,.0801,-.2463,.0801,-.2454,.0739,-.2448,.0678,-.2447,.0619,-.1472,.1209,-.1241,.1183,-.1044,.1102,-.088,.0969,-.0758,.0788,-.0685,.0563,-.066,.0296,-.0661,.0285,-.0663,.0273,-.0664,.0262,-.1138,.0262,-.1612,.0262,-.2086,.0262,-.2065,.0109,-.201,-.0023,-.1922,-.0133,-.1811,-.0216,-.1686,-.0266,-.1547,-.0283,-.1362,-.025,-.1205,-.015,-.1077,.0017,-.0984,-.0029,-.089,-.0074,-.0797,-.0119,-.1156,-.0851,-.1387,-.1136,-.1561,-.1185,-.1792,-.1157,-.1994,-.1073,-.2168,-.0932,-.23,-.075,-.238,-.0537,-.2406,-.0295,-.2381,-.0055,-.2303,.0157,-.2175,.034,-.2006,.0481,-.1808,.0566,-.1581,.0594,-.1588,.0308,-.1701,.0295,-.1803,.0259,-.1893,.0199,-.1969,.0118,-.2025,.002,-.2062,-.0094,-.1743,-.0094,-.1423,-.0094,-.1104,-.0094,-.1126,.0015,-.1173,.0111,-.1245,.0193,-.134,.0257,-.1455,.0295,-.1588,.0308,-.0256,-.1125,-.036,-.1125,-.0464,-.1125,-.0568,-.1125,-.0568,-.057,-.0568,-.0015,-.0568,.0539,-.0469,.0539,-.0369,.0539,-.0269,.0539,-.0269,.0462,-.0269,.0385,-.0269,.0308,-.0265,.0308,-.026,.0308,-.0256,.0308,-.02,.0385,-.0126,.0453,-.0036,.0512,.0062,.0558,.016,.0585,.0258,.0594,.0375,.0584,.0483,.0556,.0581,.0509,.0737,.0686,.0928,.0793,.1155,.0828,.1333,.0809,.1481,.075,.16,.0651,.1687,.0517,.1739,.035,.1757,.0149,.1757,-.0198,.1757,-.0544,.1757,-.0891,.1653,-.0891,.1548,-.0891,.1444,-.0891,.1444,-.056,.1444,-.0229,.1444,.0101,.1435,.0243,.1406,.0356,.1359,.0439,.129,.0497,.1194,.0531,.1074,.0543,.096,.0526,.0859,.0475,.0771,.039,.0703,.0282,.0662,.0162,.0649,.003,.0649,-.0277,.0649,-.0584,.0649,-.0891,.0544,-.0891,.044,-.0891,.0336,-.0891,.0336,-.056,.0336,-.0229,.0336,.0101,.0326,.0243,.0298,.0356],antigravity:[.461,-.0505,.4507,-.0494,.4531,-.0441,.4552,-.0394,.4572,-.0351,.4624,-.024,.4382,.0392,.4561,.0236,.4695,-.0076,.4886,.0392,.4891,.0141,.4664,-.0381,.4638,-.0442,.3967,.0265,.4004,.036,.4078,.0479,.4183,.0538,.4235,.036,.4338,.0297,.4183,.0265,.4186,-.0111,.4243,-.018,.4307,-.0178,.434,-.0196,.4249,-.0243,.4165,-.0089,.4128,.0265,.3996,.0265,.3779,.015,.3884,.036,.3849,-.0271,.3833,.0497,.3891,.052,.3929,.0454,.3891,.0389,.3838,.0444,.3189,.015,.3217,.036,.3413,-.0147,.3612,.036,.3637,.015,.3394,-.0271,.2679,-.0278,.2678,-.0147,.2816,-.0061,.2961,-.0054,.3048,-.0074,.3088,-.0078,.3066,.003,.2914,.0103,.279,.0099,.2791,.017,.3023,.0113,.3096,-.0203,.3029,-.047,.2996,-.0379,.2978,-.0397,.2825,-.0338,.2844,-.0185,.2947,-.0097,.2954,.0015,.2804,.0019,.2729,-.0094,.2797,-.0196,.2806,-.0202,.2147,.015,.2247,.036,.2249,.0259,.2275,.0302,.2359,.0363,.2414,.0357,.2434,.0274,.2434,-.0116,.2268,-.0167,.1662,-.0554,.1508,-.0489,.1432,-.0381,.1545,-.0372,.1669,-.0458,.1865,-.0404,.1918,-.0221,.1915,-.0174,.1828,-.0252,.1657,-.0251,.1557,-.0056,.1659,.0124,.1823,.0069,.1877,.0014,.1879,.0104,.1979,-.0098,.1961,-.0626,.1782,-.0711,.1713,-.0188,.1803,-.0068,.1803,.0113,.1713,.023,.1581,.0181,.151,.0042,.1535,-.0134,.1644,-.0206,.1202,-.006,.1272,.036,.1307,-.0271,.1254,.0476,.1203,.0519,.1257,.0572,.1329,.0552,.1349,.0479,.1297,.0426,.1254,.0476,.0731,.036,.0842,.042,.0912,.0538,.0947,.036,.1102,.0329,.0999,.0265,.0947,-.0079,.0985,-.0172,.1059,-.0181,.1104,-.0162,.1055,-.0259,.0934,-.0139,.0928,.0265,.0788,.0265,.0128,-.006,.0195,.036,.0229,.0268,.0253,.0297,.0394,.0376,.0612,.0312,.0671,-1e-4,.0601,-.0271,.0566,.0118,.049,.0268,.0345,.0272,.0256,.0181,.0221,-.0174,.0136,-.0238,-.0509,.032,-.0278,.0615,.002,-.0271,-.0117,-.0108,-.0528,-.0027,-.0657,-.0271,-.0222,.0178,-.0324,.0455,-.034,.0486,-.0414,.0285,-.0286,.0072,-.493,-.0042,-.4492,.0711,-.4182,.0541,-.4393,.0561,-.4851,.021,-.4379,-.0138,-.418,.0049,-.4496,.0119,-.4341,.0256,-.4026,.0201,-.4143,-.015,-.3331,.0032,-.3546,-.0183,-.3498,.0134,-.381,.0134,-.3654,-.0163,-.2628,.0032,-.2843,-.0183,-.2795,.0134,-.3107,.0134,-.2951,-.0163,-.1956,.0335,-.1998,-.0437,-.2492,-.0477,-.2424,-.0338,-.217,-.0431,-.209,-.0233,-.2095,-.0217,-.2416,-.0247,-.2444,-6e-4,-.2398,-.0041],goose:[-.3176,-.0435,-.3297,-.0918,-.3626,-.1222,-.4114,-.1327,-.4511,-.1265,-.4807,-.1078,-.4989,-.0768,-.4852,-.0719,-.4715,-.067,-.4579,-.0622,-.4486,-.0808,-.4329,-.0929,-.4114,-.0972,-.3852,-.0922,-.3678,-.076,-.3615,-.0475,-.3615,-.043,-.3615,-.0385,-.3615,-.034,-.3747,-.0463,-.3931,-.0549,-.4157,-.0581,-.461,-.0451,-.4899,-.0108,-.5,.0373,-.4899,.0854,-.461,.1197,-.4157,.1327,-.3932,.1295,-.3748,.1208,-.3615,.1086,-.3615,.1154,-.3615,.1222,-.3615,.1291,-.3469,.1291,-.3322,.1291,-.3176,.1291,-.3176,.0715,-.3176,.014,-.3176,-.0435,-.3608,.0391,-.3667,.069,-.383,.0878,-.4073,.0943,-.4334,.0875,-.4499,.068,-.4557,.0373,-.4499,.0067,-.4334,-.0128,-.4073,-.0197,-.383,-.0133,-.3667,.0053,-.3608,.0347,-.3608,.0362,-.3608,.0377,-.3608,.0391,-.0953,.0329,-.1073,-.0195,-.1398,-.0543,-.188,-.0669,-.2361,-.0543,-.2687,-.0195,-.2807,.0329,-.2687,.0853,-.2361,.1201,-.188,.1327,-.1398,.1201,-.1073,.0853,-.0953,.0329,-.2363,.0329,-.2304,-8e-4,-.2137,-.0224,-.188,-.03,-.1622,-.0224,-.1456,-8e-4,-.1396,.0329,-.1456,.0666,-.1622,.0882,-.188,.0958,-.2137,.0882,-.2304,.0666,-.2363,.0329,.1148,.0329,.1028,-.0195,.0702,-.0543,.0221,-.0669,-.0312,.0557,-.0226,.1164,.0221,.1327,.053,.0994,.0839,.0662,.1148,.0329,-.0263,.0329,-.0203,-8e-4,-.0036,-.0224,.0221,-.03,.0161,.0037,-5e-4,.0253,-.0263,.0329,-.052,.0253,-.0687,.0037,-.0746,-.03,-.0585,-.009,-.0424,.0119,-.0263,.0329,.1314,-.0263,.1424,-.0175,.1534,-.0088,.1644,-0,.1789,-.0163,.1982,-.0272,.2201,-.0311,.2377,-.0287,.2508,-.0211,.256,-.0073,.2507,.005,.235,.0117,.2094,.0172,.179,.0251,.1544,.041,.1442,.072,.1538,.1034,.1802,.1248,.2193,.1327,.2513,.128,.2782,.1153,.297,.0965,.2871,.0876,.2772,.0787,.2673,.0698,.254,.0845,.2369,.0937,.2168,.0969,.2011,.0943,.1908,.0871,.1871,.076,.1916,.0654,.2045,.0592,.2252,.0545,.2588,.0462,.287,.0296,.2988,-.0033,.288,-.037,.2596,-.059,.2197,-.0669,.1848,-.0622,.154,-.0485,.1314,-.0263,.4165,-.0669,.3678,-.0542,.3351,-.0193,.3231,.0329,.3349,.0838,.3671,.1193,.4146,.1327,.4615,.1199,.4902,.086,.5,.038,.5,.0331,.5,.0283,.5,.0234,.4551,.0234,.4101,.0234,.3652,.0234,.3737,-.005,.3914,-.0232,.4165,-.0296,.4364,-.026,.4518,-.0156,.4612,.0011,.4737,-.0037,.4863,-.0084,.4989,-.0132,.4801,-.042,.4519,-.0604,.4165,-.0669,.4143,.0958,.3935,.0913,.3774,.0781,.3674,.0563],openclaw:[.3881,-.0486,.3433,-.0486,.3191,.0475,.3563,.0475,.3631,.0128,.3668,-.0215,.3692,-.0215,.3772,.0166,.3868,.0475,.4329,.0475,.4424,.0166,.4504,-.0215,.4529,-.0215,.4567,.0128,.4634,.0475,.5,.0475,.4747,-.0486,.4299,-.0486,.4175,-.0101,.4104,.0187,.4079,.0187,.4007,-.0101,.3881,-.0486,.2928,-.0486,.2816,-.0344,.2803,-.0273,.2797,-.0045,.278,.0141,.2684,.0179,.2534,.0172,.2477,.0114,.2473,.0073,.2234,.007,.2115,.0073,.2144,.0229,.2295,.0403,.2551,.0488,.2852,.047,.3054,.0351,.3145,.0147,.3152,-.0304,.2335,-.0497,.2135,-.0382,.2099,-.0198,.2154,-.0087,.2279,-.0014,.2543,.0025,.2816,-.0015,.2711,-.0159,.2487,-.0185,.2468,-.0208,.2504,-.0228,.261,-.023,.2735,-.0212,.2796,-.0159,.2816,-.0097,.2833,-.0147,.2824,-.0259,.2782,-.0322,.2623,-.0454,.2441,-.0489,.201,-.0486,.1651,-.0486,.1651,.0791,.201,.0791,.201,-.0486,.0604,-.047,.0314,-.0287,.0175,.0025,.0203,.0396,.0394,.0667,.073,.0801,.113,.0781,.1412,.0633,.1548,.0374,.1557,.0243,.129,.0233,.1157,.0254,.113,.0382,.0971,.0462,.0729,.0455,.0649,.0324,.0659,.0104,.0796,.0029,.1044,.0047,.115,.0163,.1157,.025,.1424,.0261,.1557,.024,.1521,.0023,.1334,-.0202,.1007,-.0309,.0871,-.0442,-.0041,-.0486,-.028,-.0325,-.0285,.0058,-.0361,.0156,-.0556,.0169,-.0665,.0108,-.0694,.001,-.0728,.0067,-.0728,.0183,-.0653,.0227,-.0504,.0323,-.0273,.0338,-.0088,.026,9e-4,.0109,.0027,-.0226,.0044,-.0586,-.0682,-.0486,-.104,-.0486,-.104,.0475,-.0705,.0475,-.0705,.0179,-.0682,.017,-.0682,-.0486,-.1872,-.0483,-.2103,-.0362,-.2219,-.0118,-.2195,.0182,-.1975,.0315,-.167,.0298,-.1446,.0172,-.1336,-.0055,-.1329,-.0184,-.1332,-.0227,-.1773,-.0244,-.1992,-.0123,-.1598,-.0063,-.1453,-.0138,-.1479,-.0131,-.15,-.0015,-.1616,.0044,-.1815,.0031,-.189,-.0068,-.1895,-.0189,-.1875,-.0325,-.1758,-.0389,-.1572,-.0384,-.1506,-.0336,-.1502,-.0297,-.1263,-.029,-.1144,-.0305,-.1173,-.0444,-.1319,-.0595,-.1569,-.0672,-.1672,-.0562,-.2847,-.0497,-.3048,-.0378,-.3123,-.0238,-.316,-.0165,-.3148,-.0017,-.3121,-.0058,-.3079,-.0141,-.2983,-.0174,-.2836,-.0177,-.2726,-.0148,-.2674,-.0079,-.2667,.0034,-.2703,.0118,-.2792,.0158,-.2961,.0162,-.3099,.0104,-.3136,-4e-4,-.3169,.0069,-.3167,.0215,-.3105,.0302,-.2947,.0463,-.2665,.0487,-.2447,.0387,-.2326,.0182,-.2342,-.0074,-.2523,-.021,-.2709,-.0326,-.3124,-.081,-.3483,-.081,-.3483,.0475,-.3147,.0475,-.3147,.0204,-.3124,.0179],ollama:[-.3876,.1054,-.4128,.1032,-.4403,.0945,-.459,.0825,-.478,.0621,-.4888,.043,-.4972,.0158,-.4999,-.0089,-.499,-.0345,-.4929,-.0632,-.4839,-.0834,-.4673,-.1053,-.4501,-.1192,-.4244,-.1307,-.4006,-.135,-.3747,-.135,-.3455,-.1291,-.3253,-.1195,-.304,-.1015,-.2912,-.0839,-.2804,-.0582,-.2758,-.0348,-.2838,.004,-.3229,.0709,-.3494,.096,-.381,.1052,-.3788,.0716,-.3592,.0676,-.3459,.0611,-.3346,.0517,-.3238,.0361,-.3178,.0211,-.3137,-7e-4,-.3155,-.0182,-.3299,-.0294,-.3438,-.0352,-.3597,-.0381,-.3814,-.0376,-.3969,-.0338,-.4134,-.0249,-.4242,-.0144,-.4341,.0017,-.4394,.0168,-.4423,.034,-.4427,.0579,-.4404,.0758,-.4341,.0951,-.4265,.1083,-.4132,.1219,-.4003,.1295,-.3854,.1341,-.3696,.1316,-.3744,.1157,-.3804,.0958,-.3852,.0799,-.2472,.0758,-.2472,.0167,-.2472,-.0424,-.2472,-.1163,-.2403,-.131,-.2288,-.131,-.2195,-.131,-.2103,-.1163,-.2103,-.0572,-.2103,.002,-.2103,.0758,-.2149,.1054,-.2265,.1054,-.2357,.1054,-.2472,.1054,-.173,.0611,-.173,.002,-.173,-.0719,-.173,-.131,-.1615,-.131,-.1523,-.131,-.1407,-.131,-.1361,-.1015,-.1361,-.0424,-.1361,.0315,-.1361,.0906,-.1453,.1054,-.1546,.1054,-.1661,.1054,-.0259,.0414,-.0411,.0407,-.0577,.0379,-.0691,.034,-.0817,.0266,-.0906,.0184,-.0974,.0082,-.103,-.0071,-.0968,-.0111,-.0854,-.012,-.0762,-.0127,-.0667,-.0119,-.0644,-.0059,-.0611,-8e-4,-.0557,.0043,-.0507,.0074,-.0439,.0099,-.0376,.011,-.0285,.0115,-.0128,.0095,-.0015,.0034,.0062,-.01,.0075,-.0217,.0075,-.0237,.0075,-.0253,.0075,-.0274,6e-4,-.028,-.0086,-.0282,-.02,-.0285,-.0292,-.0287,-.0506,-.0307,-.0655,-.0341,-.0812,-.0409,-.0917,-.0483,-.1,-.0575,-.1064,-.0714,-.1085,-.0844,-.1076,-.0978,-.1047,-.1069,-.0983,-.1169,-.0911,-.1239,-.0825,-.1292,-.0699,-.1337,-.0582,-.1354,-.0438,-.1353,-.0338,-.1341,-.0223,-.1313,-.0139,-.1281,-.0071,-.1244,6e-4,-.1188,.0062,-.1135,.01,-.1117,.01,-.1172,.01,-.1241,.01,-.1297,.0165,-.131,.0272,-.131,.0358,-.131,.0444,-.1243,.0444,-.0975,.0444,-.0641,.0444,-.0373,.0442,-.0164,.0414,2e-4,.037,.0114,.0288,.0229,.0188,.031,.0028,.0379,-.0127,.0408,.0074,-.0544,.0074,-.057,.0074,-.0591,.0074,-.0618,.0072,-.0676,.0045,-.0786,3e-4,-.0864,-.0057,-.0934,-.0152,-.1003,-.0237,-.1042,-.0356,-.1069,-.0449,-.1073,-.0519,-.1064,-.0568,-.1048,-.0612,-.1025,-.0658,-.0989,-.0684,-.0955,-.0702,-.0907,-.0707,-.0865,-.0667,-.071,-.0577,-.0624,-.0436,-.0571,-.0249,-.0553,-.0157,-.0551,-.0041,-.0547,.0051,-.0545,.1515,.0411,.1397,.0384,.1283,.033,.1148,.0223,.1121,.0229,.1121,.0283,.1121,.0326,.1098,.0369,.1006,.0369,.0913,.0369,.0798,.0369,.0752,.0159,.0752,-.0366,.0752,-.0786,.0752,-.131,.0844,-.131,.0937,-.131,.1052,-.131,.1121,-.1247,.1121,-.0933,.1121,-.0681,.1121,-.0367,.1125,-.0243,.114,-.0167,.1176,-.008,.1218,-.0018,.1285,.0048,.1347,.0083,.1435,.0104,.1552,.01,.1676,.0052,.1773,-.0075,.1804,-.0231,.1805,-.0536,.1805,-.0794,.1805,-.1117,.1828,-.131,.192,-.131,.2036,-.131,.2128,-.131,.2174,-.1118,.2174,-.0861,.2174,-.0541,.2174,-.0284,.218,-.0197,.2203,-.0103,.2236,-.0039,.2292,.0027,.2343,.0066,.2415,.0096,.2478,.0105,.2564,.0102,.2661,.0083,.2724,.0055,.2784,3e-4,.2818,-.0051,.2846,-.014,.2857,-.0226,.2858,-.0404,.2858,-.0728,.2858,-.0987,.2858,-.131,.295,-.131,.3066,-.131,.3158,-.131,.3227,-.1242,.3227,-.0898,.3227,-.0622,.3227,-.0278,.3221,-.0109,.3185,.0042,.3132,.0148,.3059,.0242,.2942,.0334,.2837,.0382,.2691,.0411,.2586,.0413,.249,.0403,.2422,.0386,.236,.0363,.2283,.032,.2222,.0273,.2147,.0196,.2082,.0174,.1954,.0307,.1822,.0376,.1664,.041,.4219,.0412,.4076,.0399,.392,.0361,.3815,.0315,.3692,.0227,.3614,.0135,.3556,.0024,.3542,-.0107,.3634,-.0115,.3748,-.0124,.384,-.0131,.3894,-.0103,.3927,-.0033,.3965,.0014,.4025,.006,.4075,.0085,.4148,.0105,.4215,.0114,.4315,.0114,.449,.007,.458,-.0012,.4629,-.0173,.4631,-.0225,.4631,-.0245,.4631,-.0261,.4631,-.0278,.4516,-.0281,.4425,-.0283,.431,-.0286,.4175,-.0292,.3973,-.0322,.3835,-.0365,.3717,-.0426,.3594,-.0527,.3525,-.0628,.3478,-.0777,.3471,-.0904,.3492,-.1025,.3531,-.1111,.359,-.1187,.3686,-.1268,.3779,-.1313,.3914,-.1347,.4038,-.1356,.4169,-.1348,.4265,-.1332,.4355,-.1306,.4451,-.1263,.4517,-.1223,.4591,-.1162,.4644,-.1105,.4657,-.1145,.4657,-.12,.4657,-.1255,.4678,-.131,.4764,-.131,.4871,-.131,.4957,-.131,.5,-.1109,.5,-.0841,.5,-.0574,.5,-.0239,.499,-.0094,.4951,.006,.4897,.0164,.4798,.0272,.4685,.0342,.4548,.0388,.4342,.0413,.4631,-.0554,.4631,-.0581,.4631,-.0602,.4631,-.0628,.4621,-.0721,.4593,-.0806,.4532,-.09,.4463,-.0965,.4363,-.1025,.4273,-.1056,.4148,-.1073,.4078,-.1071,.4025,-.1061,.3966,-.1038,.3924,-.1012,.3884,-.0972,.3863,-.0937,.3851,-.0887,.3856,-.0797,.3907,-.0685,.4043,-.0593,.4211,-.0558,.4353,-.0552,.4446,-.0549,.4561,-.0546],windsurf:[-.2056,.0568,-.2164,.0568,-.2217,.0137,-.2217,-.0725,-.2203,-.0751,-.2134,-.0755,-.2027,-.0755,-.2027,.0107,-.2037,.0548,-.2056,.0568,-.2165,.1053,-.2051,.1053,-.2026,.1039,-.2022,.0953,-.2022,.0813,-.2156,.0813,-.2222,.0883,-.2222,.1024,-.2208,.1049,-.2203,.1053,-.2222,.1053,-.1258,.0585,-.149,.0449,-.149,.0488,-.1542,.0508,-.1648,.0508,-.1648,-.0354,-.1644,-.08,-.1618,-.0814,-.1513,-.0814,-.146,-.0542,-.146,4e-4,-.133,.0324,-.1104,.0073,-.1104,-.0481,-.1089,-.0507,-.102,-.0511,-.0913,-.0511,-.0913,.0084,-.0971,.0646,-.1372,.0849,-.1279,.0767,-.1094,.0604,.0548,.0629,.0548,.1024,.0563,.1049,.063,.1053,.0736,.1053,.0761,.1039,.0765,.0431,.0765,-.0755,.066,-.0755,.0607,-.0729,.0607,-.0678,.0565,-.0635,.0435,-.0735,.0115,-.0821,-.0385,-.0502,-.0379,.0287,.0123,.0604,.0438,.0518,.0539,.0431,.0548,.0431,-.0176,-.0439,.021,-.0619,.0594,-.0439,.0594,.022,.021,.0402,-.0066,.0061,.1758,-.0026,.1585,4e-4,.1355,.0062,.1273,.0211,.139,.0393,.177,.0391,.1913,.0193,.1928,.017,.1995,.0166,.2099,.0166,.2126,.0182,.2046,.0419,.159,.0605,.1126,.0406,.1111,6e-4,.1439,-.017,.1629,-.0205,.1848,-.026,.1934,-.0404,.1813,-.0609,.1556,-.0632,.1451,-.0632,.1737,-.1007,.2308,-.1,.2574,-.0625,.238,-.032,.2038,-.018,.1758,-.0026,.3123,-.06,.3251,-.028,.3251,.0265,.3255,.0553,.328,.0567,.3387,.0567,.3456,.0563,.3471,.0538,.3471,-.0324,.3417,-.0755,.331,-.0755,.331,-.0718,.3298,-.0666,.3239,-.0667,.301,-.0802,.2612,-.0772,.2396,-.0354,.2396,.024,.24,.0553,.2426,.0567,.2533,.0567,.2601,.0563,.2616,.0538,.2616,-.0016,.264,-.0506,.2962,-.0627,.2922,-.0627,.4757,.0568,.4757,.0683,.4774,.0803,.488,.0864,.496,.0864,.5,.0918,.5,.1024,.4944,.1024,.4713,.0981,.4537,.0667,.4537,.0581,.4479,.0538,.4363,.0538,.41,.0493,.3975,.0407,.3935,.0454,.3935,.051,.3882,.0538,.3775,.0538,.3775,-.0324,.3779,-.077,.3804,-.0784,.3911,-.0784,.3965,-.0514,.3965,.0026,.4102,.0331,.4406,.0357,.4567,.0357,.4567,-.0384,.4571,-.077,.4596,-.0785,.4703,-.0785,.4757,-.0394,.4757,.0386,.4919,.0386,.5,.0437,.5,.0538,.4838,.0538,.4757,.0548,.4757,.0568,-.3019,.0046,-.2773,.1031,-.265,.1031,-.2572,.1026,-.256,.0994,-.2869,-.0192,-.3133,-.0785,-.3352,-.0785,-.3559,.0222,-.3663,.0725,-.3665,.0725,-.3922,-.0266,-.4203,-.0762,-.4509,-.0762,-.4836,.0423,-.4939,.1016],xai:[.4312,.2671,.4541,.2671,.4771,.2671,.5,.2671,.5,.089,.5,-.089,.5,-.2671,.4771,-.2671,.4541,-.2671,.4312,-.2671,.4312,-.089,.4312,.089,.4312,.2671,.0842,.2671,.1084,.2671,.1326,.2671,.1568,.2671,.2258,.089,.2949,-.089,.364,-.2671,.339,-.2671,.3141,-.2671,.2892,-.2671,.2705,-.2174,.2518,-.1678,.2331,-.1182,.1568,-.1182,.0805,-.1182,.0042,-.1182,-.0145,-.1678,-.0332,-.2174,-.0519,-.2671,-.0759,-.2671,-.0998,-.2671,-.1238,-.2671,-.0545,-.089,.0149,.089,.0842,.2671,.2121,-.0584,.1807,.0242,.1493,.1067,.1179,.1893,.0869,.1067,.056,.0242,.0251,-.0584,.0874,-.0584,.1498,-.0584,.2121,-.0584,-.3571,-.0636,-.4003,-.0025,-.4434,.0586,-.4865,.1197,-.4611,.1197,-.4357,.1197,-.4102,.1197,-.3796,.0741,-.3489,.0284,-.3182,-.0172,-.2863,.0284,-.2544,.0741,-.2225,.1197,-.1993,.1197,-.1761,.1197,-.1529,.1197,-.1953,.0589,-.2377,-.002,-.2801,-.0628,-.2332,-.1309,-.1863,-.199,-.1394,-.2671,-.1646,-.2671,-.1898,-.2671,-.215,-.2671,-.2504,-.215,-.2858,-.1628,-.3212,-.1107,-.3569,-.1628,-.3925,-.215,-.4282,-.2671,-.4521,-.2671,-.4761,-.2671,-.5,-.2671,-.4524,-.1992,-.4047,-.1314,-.3571,-.0636]};var qe=[{id:"factory",label:"Factory"},{id:"claudecode",label:"Claude Code"},{id:"codex",label:"Codex"},{id:"opencode",label:"OpenCode"},{id:"openclaw",label:"OpenClaw"},{id:"openclaude",label:"OpenClaude"},{id:"omp",label:"OMP"},{id:"hermes",label:"Hermes"},{id:"geminicli",label:"Gemini CLI"},{id:"junie",label:"Junie"},{id:"antigravity",label:"Antigravity"},{id:"openai",label:"OpenAI"},{id:"openburnbar",label:"OpenBurnBar"},{id:"deepseek",label:"DeepSeek"},{id:"minimax",label:"MiniMax"},{id:"zai",label:"Zai"},{id:"xai",label:"xAI"},{id:"mimo",label:"MiMo"},{id:"cursor",label:"Cursor"},{id:"copilot",label:"Copilot"},{id:"kimi",label:"Kimi"},{id:"aider",label:"Aider"},{id:"cline",label:"Cline"},{id:"kilocode",label:"Kilo Code"},{id:"roocode",label:"Roo Code"},{id:"forgedev",label:"Forge"},{id:"augment",label:"Augment"},{id:"piagent",label:"Pi Agent"},{id:"goose",label:"Goose"},{id:"ollama",label:"Ollama"},{id:"windsurf",label:"Windsurf"},{id:"warp",label:"Warp"},{id:"cursoragent",label:"Cursor Agent"},{id:"fx",label:"fx"}],Ae=qe.map(({id:t})=>t);function B1(t){if(t==null)return[...Ae];let e=new Set(t);return Ae.filter(o=>e.has(o))}var X2=14e3,j2=16e3,Y2=7500,F1=.9,Ve=170,Q2=620,J2=980,Z2=1500,G1=.62,$2=.018,eo=.962,to=2.05,_1=.0015,oo=65e-6,K1=55e-6,D1=.092,O1=.01,ro=.86,no=2.15,io=[250,107,6],Xe=[253,196,44],N1=[18,7,3],ao=1.55,U1=["/brand/burnbar-logo-mark.png","/provider-logos/openburnbar.png"],W1={openai:[16,163,127],anthropic:[204,120,92],google:[66,133,244],cursor:[0,229,255],ollama:[255,255,255],copilot:[255,255,255],deepseek:[77,163,255],codex:[250,107,6],opencode:[139,92,246],hermes:[200,191,181],xai:[255,255,255]},lo=["factory","claudecode","codex","opencode","openclaw","openclaude","omp","hermes","geminicli","junie","antigravity","openai","openburnbar","deepseek","minimax","zai","xai","mimo","cursor","copilot","kimi","aider","cline","kilocode","roocode","forgedev","augment","piagent","goose","ollama","windsurf","warp","cursoragent","fx"],so={claudecode:"claude-code.png",geminicli:"gemini.png",xai:"grok.png"},X1=new Map,H1=new Set,co={claudecode:"anthropic",geminicli:"google",openai:"openai"},je=null;function uo(){if(je)return je;let t=I1,e=new Array(M1),o=0;for(let r=0;r+3<t.length;r+=4){let n=t[r+2];e[o++]={x:t[r],y:t[r+1],rgb:[n>>16&255,n>>8&255,n&255],role:t[r+3]}}return je=e,e}function j1(t){let e=co[t]??t,o=He[e];return o&&o.length>=2?e:null}function mo(t){let e=B1(t);return lo.filter(o=>e.includes(o))}function fo(t){let e=mo(t),o=[];for(let r=0;r<e.length;r+=2)o.push(e.slice(r,r+2));return o}function po(t,e,o){if(!o)return["swarm"];let r=fo(t).map(n=>({type:"shapeProviderLogo",providers:n}));return e?r.length===0?["swarm"]:r.flatMap(n=>[n,"swarm"]):["swarm","shapeDollar","swarm","shapeCode","swarm","shapeBurnBarLogo",...r.flatMap(n=>["swarm",n]),"swarm","shapeRings","swarm","shapeRouterFlow"]}function ho(){return["shapeBurnBarLogo","swarm"]}function bo(t,e,o){if(t<=0)return[];if(t===1)return[{centerX:e>960?e*.74:e*.5,centerY:e>960?o*.3:o*.24,scale:Math.min(e,o)*.34}];let r;e>=1320?r=5:e>=920?r=4:r=2;let n=Math.min(t,r),a=Math.ceil(t/n),s=Math.min(300,Math.max(180,e*.78/Math.max(n-1,1))),c=Math.min(210,Math.max(130,o*.44/Math.max(a-1,1))),f=c*Math.max(a-1,0),y=o*(a>1?.4:.34),I=Math.min(Math.min(e,o)*.32,Math.max(110,Math.min(s,a>1?c:o*.32)*.72)),p=[];for(let m=0;m<t;m++){let S=Math.floor(m/n),A=m%n,_=Math.min(n,t-S*n),N=s*Math.max(_-1,0),z=e*.5-N/2+s*A,x=y-f/2+c*S;p.push({centerX:z,centerY:x,scale:I})}return p}function vo(t){let e=[];for(let o=0;o+1<t.length;o+=2)e.push({x:t[o],y:t[o+1],role:"logo-flame-inner",progress:Math.random()});return e}function q1(t){return qe.find(e=>e.id===t)?.label??t}function Ye(t,e){if(typeof document>"u")return[];let o=400,r=document.createElement("canvas");r.width=o,r.height=o;let n=r.getContext("2d");if(!n)return[];n.fillStyle="#000",n.fillRect(0,0,o,o),n.fillStyle="#fff",n.font=`600 ${e}px ui-monospace, Menlo, monospace`,n.textAlign="center",n.textBaseline="middle",n.fillText(t,o/2,o/2);let a=n.getImageData(0,0,o,o).data,s=[],c=6;for(let f=0;f<o;f+=c)for(let y=0;y<o;y+=c){let I=(f*o+y)*4;a[I]>128&&s.push({x:(y-o/2)/(o/2),y:-((f-o/2)/(o/2)),role:null,progress:Math.random()})}return s}function go(t){let e=q1(t).split(/\s+/).filter(Boolean),o=e.length>1?e.map(r=>r[0]).join("").slice(0,4):q1(t).replace(/[^a-z0-9]/gi,"").slice(0,6);return Ye(o||"?",150)}function yo(t){let o=document.createElement("canvas");o.width=240,o.height=240;let r=o.getContext("2d");if(!r)return[];r.clearRect(0,0,240,240);let n=Math.min(240/Math.max(t.naturalWidth||240,1),240/Math.max(t.naturalHeight||240,1)),a=(t.naturalWidth||240)*n,s=(t.naturalHeight||240)*n;r.drawImage(t,(240-a)/2,(240-s)/2,a,s);let c=r.getImageData(0,0,240,240).data,f=[],y=4;for(let I=0;I<240;I+=y)for(let p=0;p<240;p+=y){let m=(I*240+p)*4,S=c[m+3]??0,A=(c[m]??0)+(c[m+1]??0)+(c[m+2]??0);S<48||A<30||f.push({x:(p-240/2)/(240/2),y:-((I-240/2)/(240/2)),role:"logo-flame-inner",progress:Math.random(),rgb:[c[m]??0,c[m+1]??0,c[m+2]??0]})}return f}function xo(t,e){if(H1.has(t)||typeof Image>"u")return;H1.add(t);let o=new Image;o.onload=()=>{let n=yo(o);n.length>0&&(X1.set(t,n),e())},o.onerror=()=>{};let r=so[t]??`${t}.png`;o.src=`/provider-logos/${r}`}function Ro(t,e){let o=j1(t);if(o)return vo(He[o]);let r=X1.get(t);return r||(xo(t,e),go(t))}function wo(t=3){let e=[];for(let o=0;o<t;o++){let r=.2+o*.25,n=80+o*50;for(let a=0;a<n;a++){let s=a/n*Math.PI*2;e.push({x:Math.cos(s)*r,y:Math.sin(s)*r,role:null,progress:Math.random()})}}return e}function To(){let t=[];for(let r=0;r<100;r++){let n=r/100*Math.PI*2,a=.08;t.push({x:-.45+Math.cos(n)*a,y:Math.sin(n)*a,role:"gateway",progress:r/100})}let o=[{x:.45,y:-.28,role:"target-1"},{x:.45,y:0,role:"target-2"},{x:.45,y:.28,role:"target-3"}];for(let r of o)for(let n=0;n<50;n++){let a=n/50*Math.PI*2,s=.05;t.push({x:r.x+Math.cos(a)*s,y:r.y+Math.sin(a)*s,role:r.role,progress:n/50})}for(let r=0;r<o.length;r++){let n=o[r],a=`path-${r+1}`;for(let s=0;s<60;s++){let c=s/60,f=-.45+(n.x- -.45)*c,y=n.y*(3*c*c-2*c*c*c);t.push({x:f,y,role:a,progress:c})}}return t}function z1(t){let e=Array.from({length:t},(o,r)=>r);for(let o=t-1;o>0;o--){let r=Math.random()*(o+1)|0,n=e[o];e[o]=e[r],e[r]=n}return e}function So(t){let e=t.naturalWidth||t.width,o=t.naturalHeight||t.height;if(!e||!o)return null;let r=document.createElement("canvas");r.width=e,r.height=o;let n=r.getContext("2d");if(!n)return null;n.drawImage(t,0,0);let a=n.getImageData(0,0,e,o),s=a.data;for(let c=0;c<s.length;c+=4){let f=s[c]??0,y=s[c+1]??0,I=s[c+2]??0,p=s[c+3]??0,m=Math.max(f,y,I),S=Math.min(f,y,I),A=m===0?0:1-S/m;(p<16||m>245&&A<.08)&&(s[c+3]=0)}return n.putImageData(a,0,0),r}function Ao(t){return Math.min(2.5,Math.max(.35,t))}function Eo(t,e,o,r){let n=[255,255,255],a=[0,0,0],s=r-Math.floor(r),c=b0(t,n,e),f=b0(t,a,o);return b0(f,c,s)}function Co(t){let e=j1(t)??t;return W1[e]??W1[t]??[242,242,247]}function Po(t,e=.35){return b0(t,[255,236,200],e)}function ko(t){return t==null||!Number.isFinite(t)||t<=0?1:Math.min(4,Math.max(.25,t*60))}function de(t){return typeof t=="string"?t:t.type}function V1(t){return typeof t!="string"&&t.type==="shapeProviderLogo"}function Ce(t={}){let e=null,o=0,r=0,n=1,a=null,s=!1,c=Ao(t.motionSpeedMultiplier??1),f=t.enableSwarmSparkles??!1,y=t.logoHero===!0,I=t.providerGlyphs??Ae,p=y?t.autoCycleShapes===!1?["shapeBurnBarLogo"]:ho():po(I,t.excludeBrandShapes??!0,t.autoCycleShapes??!0),m=t.allowsClickCycle??!1,S=uo(),A=[],_=p[0]??"swarm",N=0,z=0,x=0,u=null,R=null,E=0,F=0,K={x:0,y:0,active:!1},q=[],d=[],g=[],C=[],D=!1,W=null,r0=!1,s0=[0,0];function t0(i){return y?(de(i)==="swarm"?Y2:j2)/c:X2/c}function i0(){let i=o*r,h=Math.round(i/Q2);return Math.max(J2,Math.min(Z2,h,S.length))}function c0(){if(r0||typeof Image>"u")return;r0=!0;let i=h=>{if(h>=U1.length)return;let k=new Image;k.onload=()=>{let b=So(k);b&&(W=b)},k.onerror=()=>i(h+1),k.src=U1[h]};i(0)}function Z(){D||(y||(q=Ye("$",280),d=Ye("</>",220),g=wo(),C=To()),D=!0)}function a0(i){let h=A.length||i0(),k=h<=1?0:Math.round(i*(S.length-1)/Math.max(h-1,1));return S[k]??S[0]}function l0(i){let h=a0(i),k=b0(h.rgb,Xe,.25),{cx:b,cy:U,scale:L}=o>0?v0():{cx:300,cy:300,scale:180},T=Math.random()*Math.PI*2,B=L*(.45+Math.random()*1.15);return{x:b+Math.cos(T)*B,y:U+Math.sin(T)*B,vx:(Math.random()-.5)*.9,vy:(Math.random()-.5)*.9-.15,size:.85+Math.random()*1.55,seed:Math.random()*Math.PI*2,home:i,tx:null,ty:null,tr:h.rgb[0],tg:h.rgb[1],tb:h.rgb[2],cr:k[0],cg:k[1],cb:k[2],role:h.role,roleStr:null,logoProviderId:null,slotIndex:null,flowProgress:Math.random(),opacity:.55+Math.random()*.4}}function u0(){let i=i0();A=new Array(i);for(let h=0;h<i;h++)A[h]=l0(h)}function G(i){i.tx=null,i.ty=null,i.roleStr=null,i.logoProviderId=null,i.slotIndex=null;let h=a0(i.home);i.role=h.role,i.tr=h.rgb[0],i.tg=h.rgb[1],i.tb=h.rgb[2]}function v0(){let i=o*.5,h=r*.5,k=Math.min(o,r)*(o>960?.46:.5);return{cx:i,cy:h,scale:k}}function F0(i){if(i==="shapeBurnBarLogo"||y)return v0();let h=o*.5,k=r*.45,b=.35;if(o>960)switch(i){case"shapeRings":h=o*.78,k=r*.3,b=.38;break;case"shapeRouterFlow":h=o*.5,k=r*.26,b=.6;break;default:h=o*.74,k=r*.28,b=.32}else switch(i){case"shapeRings":k=r*.24,b=.34;break;case"shapeRouterFlow":k=r*.24,b=.62;break;default:k=r*.22,b=.32}return{cx:h,cy:k,scale:Math.min(o,r)*b}}function S0(i){switch(i){case"shapeDollar":return q;case"shapeCode":return d;case"shapeRings":return g;case"shapeRouterFlow":return C;default:return[]}}function x0(){let{cx:i,cy:h,scale:k}=v0(),b=A.length,U=S.length;for(let L=0;L<b;L++){let T=A[L],B=b<=1?0:Math.round(L*(U-1)/Math.max(b-1,1)),V=S[B]??S[0];T.tx=i+V.x*k,T.ty=h-V.y*k,T.tr=V.rgb[0],T.tg=V.rgb[1],T.tb=V.rgb[2],T.role=V.role,T.roleStr=null,T.logoProviderId=null,T.slotIndex=0,T.home=L,T.x+=(T.tx-T.x)*.22,T.y+=(T.ty-T.y)*.22}}function A0(i){let h=i.filter(T=>T.points.length>0),k=h.length;if(k===0){for(let T of A)G(T);return}let b=Array.from({length:k},()=>[]),U=z1(A.length);for(let T=0;T<U.length;T++)b[T%k].push(U[T]);let L=bo(k,o,r);for(let T=0;T<k;T++){let B=h[T],V=L[T],$=b[T],p0=Co(B.providerId);for(let n0=0;n0<$.length;n0++){let N0=$[n0],h0=A[N0],_0;if($.length<=B.points.length){let V0=n0/Math.max($.length-1,1);_0=Math.min(B.points.length-1,Math.round((B.points.length-1)*V0))}else _0=n0%B.points.length;let I0=B.points[_0];h0.tx=V.centerX+I0.x*V.scale,h0.ty=V.centerY-I0.y*V.scale;let te=I0.rgb??Eo(p0,.18,.12,h0.seed);h0.tr=te[0],h0.tg=te[1],h0.tb=te[2],h0.roleStr=I0.role,h0.logoProviderId=B.providerId,h0.slotIndex=T,h0.flowProgress=I0.progress}}}function l(i){Z();let h=S0(i),{cx:k,cy:b,scale:U}=F0(i),L=z1(A.length);for(let T=0;T<L.length;T++){let B=A[L[T]];if(T<h.length){let V=h[T];B.tx=k+V.x*U,B.ty=b-V.y*U,B.roleStr=V.role,B.flowProgress=V.progress,B.logoProviderId=null,B.slotIndex=0;let $=b0(io,Xe,(B.seed%1+1)/2);B.tr=$[0],B.tg=$[1],B.tb=$[2]}else G(B)}}function w(i,h){return typeof i=="string"||typeof h=="string"?i===h:i.type===h.type&&i.providers.join(",")===h.providers.join(",")}function P(i,h){if(_=i,E=h,R=null,F=0,e&&m0(.5),i==="swarm"){for(let k of A)G(k);return}if(i==="shapeBurnBarLogo"){x0();return}if(V1(i)){Z();let k=i.providers.map(b=>({providerId:b,points:Ro(b,()=>{V1(_)&&w(_,i)&&P(_,u??0)})}));A0(k);return}l(i)}function H(i){if(!m||p.length<2)return;let h=p.findIndex(k=>w(k,_));N=(h<0?N:h)+1,N%=p.length,P(p[N],i),z=i+t0(_)}function X(){e&&e.setTransform(n,0,0,n,0,0)}function J(){return a?a.theme==="light"?a.bg:b0(a.bg,N1,.72):N1}function m0(i){e&&(e.globalCompositeOperation="source-over",e.fillStyle=o0(J(),i),e.fillRect(0,0,o,r))}function d0(){if(!e)return;let{cx:i,cy:h}=v0(),k=Math.max(o,r)*.72,b=e.createRadialGradient(i,h,k*.18,i,h,k);b.addColorStop(0,"rgba(48,14,4,0)"),b.addColorStop(1,a?.theme==="light"?"rgba(40,24,12,0.08)":"rgba(0,0,0,0.46)"),e.fillStyle=b,e.fillRect(0,0,o,r)}function G0(i,h,k,b,U,L,T){re(i.x*_1,i.y*_1,T*oo,s0);let B=s0[0],V=s0[1],$=0,p0=0;if(U!=null&&L!=null){let E0=i.x-U,C0=i.y-L,P0=Math.sqrt(E0*E0+C0*C0);if(P0<Ve&&P0>0){let g0=(Ve-P0)/Ve;$=E0/P0*g0*F1,p0=C0/P0*g0*F1}}let n0=c;if(!(i.tx!=null&&i.ty!=null)){let{cx:E0,cy:C0}=v0();i.vx+=(B*G1+$)*h*b*n0,i.vy+=(V*G1+p0-$2)*h*b*n0,i.vx+=(E0-i.x)*K1*b,i.vy+=(C0-i.y)*K1*b;let P0=Math.pow(eo,b);i.vx*=P0,i.vy*=P0;let g0=Math.hypot(i.vx,i.vy),k0=to*n0;g0>k0&&g0>0&&(i.vx=i.vx/g0*k0,i.vy=i.vy/g0*k0),i.x+=i.vx*b,i.y+=i.vy*b,i.x<-20&&(i.x=o+20),i.x>o+20&&(i.x=-20),i.y<-20&&(i.y=r+20),i.y>r+20&&(i.y=-20);let y0=b0([i.tr,i.tg,i.tb],Xe,.28),R0=.08;i.cr+=(y0[0]-i.cr)*R0,i.cg+=(y0[1]-i.cg)*R0,i.cb+=(y0[2]-i.cb)*R0,i.opacity=.64+.22*(.5+.5*Math.sin(T*.003+i.seed));return}if(de(_)==="shapeRouterFlow"&&i.roleStr){let E0=o*.5,C0=r*.48,P0=o>960?.7:.8,g0=Math.min(o,r)*P0,k0=i.roleStr;if(k0==="gateway"){let y0=i.seed+x*15;i.tx=E0+(-.45+Math.cos(y0)*.08)*g0,i.ty=C0+Math.sin(y0)*.08*g0}else if(k0.startsWith("target-")){let y0=0;k0==="target-1"&&(y0=-.28),k0==="target-3"&&(y0=.28);let R0=i.seed+x*12;i.tx=E0+(.45+Math.cos(R0)*.05)*g0,i.ty=C0+(y0+Math.sin(R0)*.05)*g0}else if(k0.startsWith("path-")){let y0=0;k0==="path-1"&&(y0=-.28),k0==="path-3"&&(y0=.28),i.flowProgress+=.003*b*c,i.flowProgress>1&&(i.flowProgress=0);let R0=i.flowProgress;i.tx=E0+(-.45+.9*R0)*g0,i.ty=C0+y0*(3*R0*R0-2*R0*R0*R0)*g0}}let h0=i.tx,_0=i.ty;if(_==="shapeBurnBarLogo"){let E0=Math.sin(T*.011+i.seed)*(i.role===3?3.4:i.role===0?1.6:.45),C0=i.role===3||i.role===0?Math.sin(T*.007+i.seed*1.7)*2.2:0;h0+=E0,_0-=C0,f&&i.role===3&&Math.sin(T*.004+i.seed*9.1)>.94&&(i.vy-=1.8*h*n0,i.vx+=Math.sin(i.seed*13)*.6)}let I0=h0-i.x,te=_0-i.y,V0=Math.hypot(I0,te);V0>.4&&(i.vx+=I0/V0*D1*k*b*n0*Math.min(V0,80),i.vy+=te/V0*D1*k*b*n0*Math.min(V0,80)),i.vx+=(B*O1+$)*h*b*n0,i.vy+=(V*O1+p0)*h*b*n0;let m1=Math.pow(ro,b);i.vx*=m1,i.vy*=m1;let he=Math.hypot(i.vx,i.vy),Ge=no*n0;he>Ge&&he>0&&(i.vx=i.vx/he*Ge,i.vy=i.vy/he*Ge),i.x+=i.vx*b,i.y+=i.vy*b;let _e=.16;i.cr+=(i.tr-i.cr)*_e,i.cg+=(i.tg-i.cg)*_e,i.cb+=(i.tb-i.cb)*_e,i.opacity=Math.min(1,.72*ao)}function L0(i){if(de(_)==="swarm"){F+=(0-F)*.08;return}let h=0,k=0;for(let L of A){if(L.tx==null||L.ty==null)continue;h++;let T=L.tx-L.x,B=L.ty-L.y;T*T+B*B<64&&k++}let b=h>0?k/h:0;(b>=.9||i-E>5500)&&R==null&&(R=i);let U=R!=null?1:Math.min(1,b);F+=(U-F)*.07}function ee(){if(!e||!W||_!=="shapeBurnBarLogo")return;let{cx:i,cy:h,scale:k}=v0(),b=k*2,U=(a?.theme==="light"?.16:.34)*F*(a?.intensity??1);U<.02||(e.save(),e.globalCompositeOperation="source-over",e.globalAlpha=U,e.drawImage(W,i-b/2,h-b/2,b,b),e.restore())}function fe(i){if(!e||!a)return;let h=a.intensity,b=(a.theme==="light"?.2:.38)*h;e.save(),e.globalCompositeOperation="lighter";for(let U=0;U<A.length;U++){let L=A[U],T=.86+.14*Math.sin(i*.006+L.seed),B=L.tx!=null,$=1/(1+Math.hypot(L.vx,L.vy)*.22),p0=Math.max(1,L.size*(B?2.35:2.05)*T*$),n0=Math.max(.4,L.size*(B?.64:.58)*T*$),N0=[L.cr,L.cg,L.cb],h0=b*L.opacity;if(e.fillStyle=o0(N0,h0*.26),e.beginPath(),e.arc(L.x,L.y,p0,0,Math.PI*2),e.fill(),e.fillStyle=o0(Po(N0,.14),h0*.88),e.beginPath(),e.arc(L.x,L.y,n0,0,Math.PI*2),e.fill(),f&&B&&(L.role===3||L.role===0)){let _0=Math.sin(x*(.7+U%5*.13)+L.seed);if(_0>.93){let I0=((_0-.93)/.07)**2;e.fillStyle=o0([255,244,220],I0*.55),e.beginPath(),e.arc(L.x,L.y,n0*.55,0,Math.PI*2),e.fill()}}}e.restore()}function pe(i,h){if(!e||!a)return;Z();let k=u!=null?(i-u)/1e3:null,b=ko(k);u=i,!s&&p.length>1&&i>=z&&(N=(N+1)%p.length,P(p[N],i),z=i+t0(_));let U=s?0:1,L=s?.05:1;x+=.004*b*c;let T=K.active?K.x:null,B=K.active?K.y:null;for(let V of A)G0(V,U,L,b,T,B,i);L0(i),h&&(ee(),fe(i))}function Fe(){P("shapeBurnBarLogo",0);for(let i of A)i.tx==null||i.ty==null||(i.x=i.tx,i.y=i.ty,i.vx=0,i.vy=0,i.cr=i.tr,i.cg=i.tg,i.cb=i.tb,i.opacity=.95);F=1,R=0}function f0(){!e||!a||(m0(1),d0(),Fe(),ee(),fe(0))}return{id:"swarmEmber",label:"Swarm Ember",substrate:"2d",init(i,h){e=i,o=h.width,r=h.height,n=h.dpr,s=h.reducedMotion,a=h.palette,X(),c0(),u0(),N=0,_=p[0]??"swarm",u=null,P(_,0),z=t0(_),m0(1),d0(),s?f0():pe(0,!0)},frame(i,h){if(!e||s)return;let k=a?.theme==="light",b=de(_)!=="swarm"&&F<.82,U=de(_)==="swarm"&&i-E<1600;m0(k?.24:b||U?.28:.16),pe(i,!0)},resize(i){o=i.width,r=i.height,n=i.dpr,s=i.reducedMotion,a=i.palette,X(),u0(),P(_,u??0),m0(1),d0(),s&&f0()},setTheme(i,h){a=h,m0(1),d0(),s&&f0()},pointer(i,h,k){K={x:i,y:h,active:k}},click(i,h){H(u??0)},wake(i,h,k,b,U,L){K.active||(K={x:i,y:h,active:!0});let T=U*2.4;for(let B of A){let V=B.x-i,$=B.y-h,p0=V*V+$*$;if(p0<T*T&&p0>0){let n0=Math.sqrt(p0),N0=(1-n0/T)*L*.18;B.vx+=V/n0*N0,B.vy+=$/n0*N0}}},renderStatic(){f0()},dispose(){e=null,A=[],W=null}}}var Qe=16.666666666666668;function Y1(t){let e=Math.round(t);if(!Number.isFinite(e)||e<=0||e%30===0)return 30;if(e%36===0)return 36;if(e%24===0)return 24;for(let o=36;o>=24;o--)if(e%o===0)return o;return 30}function Je(t,e,o){return o>0?t-e>=1e3/o:!0}function Ze(t,e,o){let r=o>0?100:32,n=t-e;return!Number.isFinite(n)||n<0?0:Math.min(n,r)}function $e(t,e=24){return!(t>0)||!(e>0)?1:1-Math.exp(-t/e)}function Q1(t,e){if(!(e>0))return 0;let o=e/Qe;return 1-Math.pow(1-t,o)}function J1(t,e){if(!(e>0))return 1;let o=e/Qe;return Math.pow(t,o)}function Z1(){return{lastNow:0,lastFrameAdvanceAt:0,primed:!1}}function Pe(t,e,o){if(!t.primed)return t.primed=!0,t.lastNow=e,t.lastFrameAdvanceAt=e,{presented:!0,dt:o>0?1e3/o:Qe,alpha:1};if(!Je(e,t.lastFrameAdvanceAt,o))return{presented:!1,dt:0,alpha:1};let r=Ze(e,t.lastNow,o);t.lastNow=e,t.lastFrameAdvanceAt=e;let n=o>0&&o<60;return{presented:!0,dt:r,alpha:n?$e(r):1}}ne();var Io=`#version 300 es
precision highp float;
out vec4 fragColor;
uniform sampler2D uHistory;
uniform sampler2D uCurrent;
uniform float uAlpha;
void main() {
  vec2 uv = gl_FragCoord.xy / vec2(textureSize(uHistory, 0));
  vec4 history = texture(uHistory, uv);
  vec4 current = texture(uCurrent, uv);
  fragColor = mix(history, current, uAlpha);
}`,ke=class{constructor(){v(this,"history2d",null);v(this,"history2dCtx",null);v(this,"primed2d",!1);v(this,"gl",null);v(this,"program",null);v(this,"vao",null);v(this,"historyTex",null);v(this,"currentTex",null);v(this,"locHistory",null);v(this,"locCurrent",null);v(this,"locAlpha",null);v(this,"texW",0);v(this,"texH",0);v(this,"primedGl",!1)}apply2d(e,o,r){if(r>=1){this.capture2d(e);return}let n=e.width,a=e.height;if(n<1||a<1)return;let s=this.ensure2d(n,a),c=this.history2dCtx;if(!(!s||!c)){if(!this.primed2d){this.capture2d(e);return}c.globalAlpha=r,c.drawImage(e,0,0),o.save(),o.setTransform(1,0,0,1,0,0),o.globalAlpha=1,o.drawImage(s,0,0),o.restore()}}applyWebgl(e,o){let r=e.drawingBufferWidth,n=e.drawingBufferHeight;if(!(r<1||n<1)&&!(!this.ensureGl(e,r,n)||!this.program||!this.vao||!this.historyTex||!this.currentTex)){if(e.bindFramebuffer(e.FRAMEBUFFER,null),o>=1){this.captureWebgl(e);return}if(e.bindTexture(e.TEXTURE_2D,this.currentTex),e.copyTexImage2D(e.TEXTURE_2D,0,e.RGBA,0,0,r,n,0),!this.primedGl){e.bindTexture(e.TEXTURE_2D,this.historyTex),e.copyTexImage2D(e.TEXTURE_2D,0,e.RGBA,0,0,r,n,0),this.primedGl=!0;return}e.useProgram(this.program),e.uniform1i(this.locHistory,0),e.uniform1i(this.locCurrent,1),e.uniform1f(this.locAlpha,o),e.activeTexture(e.TEXTURE0),e.bindTexture(e.TEXTURE_2D,this.historyTex),e.activeTexture(e.TEXTURE1),e.bindTexture(e.TEXTURE_2D,this.currentTex),e.viewport(0,0,r,n),e.disable(e.BLEND),e.disable(e.DEPTH_TEST),e.bindVertexArray(this.vao),e.drawArrays(e.TRIANGLES,0,3),e.bindVertexArray(null),e.bindTexture(e.TEXTURE_2D,this.historyTex),e.copyTexImage2D(e.TEXTURE_2D,0,e.RGBA,0,0,r,n,0),e.activeTexture(e.TEXTURE0)}}dispose(){this.history2d=null,this.history2dCtx=null,this.primed2d=!1,this.gl&&(this.program&&this.gl.deleteProgram(this.program),this.vao&&this.gl.deleteVertexArray(this.vao),this.historyTex&&this.gl.deleteTexture(this.historyTex),this.currentTex&&this.gl.deleteTexture(this.currentTex)),this.gl=null,this.program=null,this.vao=null,this.historyTex=null,this.currentTex=null,this.primedGl=!1}capture2d(e){let o=e.width,r=e.height,n=this.ensure2d(o,r),a=this.history2dCtx;!n||!a||o<1||r<1||(a.globalAlpha=1,a.drawImage(e,0,0),this.primed2d=!0)}captureWebgl(e){let o=e.drawingBufferWidth,r=e.drawingBufferHeight;!this.ensureGl(e,o,r)||!this.historyTex||(e.bindFramebuffer(e.FRAMEBUFFER,null),e.bindTexture(e.TEXTURE_2D,this.historyTex),e.copyTexImage2D(e.TEXTURE_2D,0,e.RGBA,0,0,o,r,0),this.primedGl=!0)}ensure2d(e,o){this.history2d||(this.history2d=document.createElement("canvas"),this.history2dCtx=this.history2d.getContext("2d",{alpha:!1}));let r=this.history2d,n=this.history2dCtx;return!r||!n?null:((r.width!==e||r.height!==o)&&(r.width=e,r.height=o,this.primed2d=!1),r)}ensureGl(e,o,r){if(this.gl!==e){if(this.disposeGlResources(),this.gl=e,this.program=j0(e,Io,"shutter"),!this.program)return!1;this.locHistory=e.getUniformLocation(this.program,"uHistory"),this.locCurrent=e.getUniformLocation(this.program,"uCurrent"),this.locAlpha=e.getUniformLocation(this.program,"uAlpha"),this.vao=e.createVertexArray(),this.historyTex=this.makeTex(e),this.currentTex=this.makeTex(e),this.texW=0,this.texH=0,this.primedGl=!1}return!this.vao||!this.historyTex||!this.currentTex?!1:((this.texW!==o||this.texH!==r)&&(this.allocTex(e,this.historyTex,o,r),this.allocTex(e,this.currentTex,o,r),this.texW=o,this.texH=r,this.primedGl=!1),!0)}makeTex(e){let o=e.createTexture();return o?(e.bindTexture(e.TEXTURE_2D,o),e.texParameteri(e.TEXTURE_2D,e.TEXTURE_MIN_FILTER,e.LINEAR),e.texParameteri(e.TEXTURE_2D,e.TEXTURE_MAG_FILTER,e.LINEAR),e.texParameteri(e.TEXTURE_2D,e.TEXTURE_WRAP_S,e.CLAMP_TO_EDGE),e.texParameteri(e.TEXTURE_2D,e.TEXTURE_WRAP_T,e.CLAMP_TO_EDGE),o):null}allocTex(e,o,r,n){e.bindTexture(e.TEXTURE_2D,o),e.texImage2D(e.TEXTURE_2D,0,e.RGBA,r,n,0,e.RGBA,e.UNSIGNED_BYTE,null)}disposeGlResources(){this.gl&&(this.program&&this.gl.deleteProgram(this.program),this.vao&&this.gl.deleteVertexArray(this.vao),this.historyTex&&this.gl.deleteTexture(this.historyTex),this.currentTex&&this.gl.deleteTexture(this.currentTex),this.program=null,this.vao=null,this.historyTex=null,this.currentTex=null)}};U0();var Y0=Math.PI*2;function et(t,e){let o=t.accents;return o[e%o.length]}function tt(){let t=null,e=0,o=0,r=1,n=null,a=!1,s=[],c=[],f={x:0,y:0,active:!1},y=0;function I(){t&&t.setTransform(r,0,0,r,0,0)}function p(){let x=e*o,u=Math.max(3,Math.min(6,Math.round(x/38e4))),R=Math.max(60,Math.min(160,Math.round(x/9e3)));return{clouds:u,stars:R}}function m(){let x=p();s=[];for(let u=0;u<x.clouds;u++){let R=Math.min(e,o)*.32*(.7+Math.random()*.55);s.push({hx:Math.random(),hy:Math.random(),vx:(Math.random()-.5)*.004,vy:(Math.random()-.5)*.003,r:R,accent:u%4,phase:Math.random()*Y0,weight:.6+Math.random()*.5})}c=[];for(let u=0;u<x.stars;u++)c.push({nx:Math.random(),ny:Math.random(),r:.5+Math.random()*1.1,phase:Math.random()*Y0,rate:.4+Math.random()*1.2,accent:Math.floor(Math.random()*4),a:.18+Math.random()*.32})}function S(x){!t||!n||(t.globalCompositeOperation="source-over",t.fillStyle=o0(n.bg,x),t.fillRect(0,0,e,o))}function A(x,u,R,E){if(!t||!n)return;let F=n.theme==="light",K=et(n,x.accent),q=x.r*(.9+.12*E),d=(F?.1:.14)*x.weight*(.7+.3*E)*n.intensity,g=t.createRadialGradient(u,R,0,u,R,q),C=F?b0(K,n.bg,.35):K;g.addColorStop(0,o0(C,d)),g.addColorStop(.55,o0(K,d*.45)),g.addColorStop(1,o0(K,0)),t.globalCompositeOperation=F?"source-over":"lighter",t.fillStyle=g,t.beginPath(),t.arc(u,R,q,0,Y0),t.fill()}function _(x,u){if(!t||!n)return;let R=n.theme==="light",E=et(n,x.accent),F=.55+.45*u,K=x.a*F*n.intensity,q=x.nx*e,d=x.ny*o,g=x.r*F;if(R){t.globalCompositeOperation="source-over",t.fillStyle=o0(b0(E,n.ink,.5),K*.7),t.beginPath(),t.arc(q,d,g,0,Y0),t.fill();return}if(t.globalCompositeOperation="lighter",g>1){let C=t.createRadialGradient(q,d,0,q,d,g*3.2);C.addColorStop(0,o0(E,K*.5)),C.addColorStop(1,o0(E,0)),t.fillStyle=C,t.beginPath(),t.arc(q,d,g*3.2,0,Y0),t.fill()}t.fillStyle=o0(b0(E,[255,255,255],.45),K),t.beginPath(),t.arc(q,d,g,0,Y0),t.fill()}function N(){if(!t||!n)return;let x=n.theme==="light";S(x?.32:.26);for(let u of s){let R=.5+.5*Math.sin(y*.18+u.phase),E=u.hx*e,F=u.hy*o;if(f.active){let K=E-f.x,q=F-f.y,d=Math.hypot(K,q),g=Math.min(e,o)*.45;if(d<g){let C=(1-d/g)*14;E+=K/(d||1)*C,F+=q/(d||1)*C}}A(u,E,F,R)}for(let u of c){let R=.5+.5*Math.sin(y*u.rate+u.phase);_(u,R)}t.globalCompositeOperation="source-over"}function z(){if(!(!t||!n)){S(1);for(let x of s)A(x,x.hx*e,x.hy*o,.6);for(let x of c)_(x,.7);t.globalCompositeOperation="source-over"}}return{id:"constellation",label:"Constellation",substrate:"2d",init(x,u){t=x,e=u.width,o=u.height,r=u.dpr,n=u.palette,a=u.reducedMotion,I(),m(),S(1),a&&z()},frame(x,u){if(!t||!n)return;let R=Math.min(u,32)/1e3;y+=R;for(let E of s)E.hx+=E.vx*R*60,E.hy+=E.vy*R*60,E.hx>1.15&&(E.hx=-.15),E.hx<-.15&&(E.hx=1.15),E.hy>1.15&&(E.hy=-.15),E.hy<-.15&&(E.hy=1.15);N()},resize(x){e=x.width,o=x.height,r=x.dpr,I(),S(1),m(),a&&z()},setTheme(x,u){n=u,S(1),a&&z()},pointer(x,u,R){f.x=x,f.y=u,f.active=R},click(x,u){if(!t||!n)return;let R=n.accents[0];t.globalCompositeOperation=n.theme==="light"?"source-over":"lighter";let F=t.createRadialGradient(x,u,8,x,u,90);F.addColorStop(0,o0(R,0)),F.addColorStop(.6,o0(R,.12*n.intensity)),F.addColorStop(1,o0(R,0)),t.fillStyle=F,t.beginPath(),t.arc(x,u,90,0,Y0),t.fill(),t.globalCompositeOperation="source-over"},wake(x,u,R,E,F,K){let q=F*2.4;for(let d of s){let g=d.hx*e,C=d.hy*o,D=Math.hypot(g-x,C-u);if(D<q){let W=(1-D/q)*9e-4;d.vx+=R*W,d.vy+=E*W,d.vx*=.985,d.vy*=.985}}},obstacles(x){},renderStatic(){z()},dispose(){t=null,s=[],c=[]}}}U0();function j(t,e,o,r){let n=null,a=null,s=!1,c=null,f=!1;function y(p,m){if(o!=="2d")return;let S=m;S.setTransform(p.dpr,0,0,p.dpr,0,0),S.fillStyle=o0(p.palette.bg),S.fillRect(0,0,p.width,p.height)}function I(){if(n)return Promise.resolve(n);if(!a)try{a=r().then(p=>{if(s)return a=null,null;if(n=p(),c){let m=c.ctx;o==="webgl2"&&typeof m.isContextLost=="function"&&m.isContextLost()||n.init(c.ctx,c.frame),c=null}return f&&(n.renderStatic?.(),f=!1),a=null,n}).catch(()=>(a=null,null))}catch{a=Promise.resolve(null).then(p=>(a=null,p))}return a}return{id:t,label:e,substrate:o,init(p,m){c={ctx:p,frame:m},y(m,p),I()},frame(p,m){n?.frame(p,m)},resize(p){n?n.resize(p):c&&(c={...c,frame:p},y(p,c.ctx))},setTheme(p,m){if(n)n.setTheme(p,m);else if(c){let S={...c.frame,theme:p,palette:m};c={...c,frame:S},y(S,c.ctx)}},pointer(p,m,S){n?.pointer?.(p,m,S)},click(p,m){n?.click?.(p,m)},obstacles(p){n?.obstacles?.(p)},scroll(p,m,S){n?.scroll?.(p,m,S)},renderStatic(){n?n.renderStatic?.():f=!0},dispose(){s=!0,f=!1,n?.dispose(),n=null,a=null,c=null}}}var $0=[{id:"constellation",label:"Constellation",blurb:"Provider marks assemble from the swarm, then whirl off.",substrate:"2d",create:tt},{id:"flow",label:"Flow Field",blurb:"A curl-noise wind drawn as silky streamlines.",substrate:"2d",create:()=>j("flow","Flow Field","2d",()=>Promise.resolve().then(()=>(lt(),at)).then(t=>t.createFlowFieldKernel))},{id:"aurora",label:"Aurora",blurb:"Domain-warped light, drifting in slow ribbons.",substrate:"webgl2",create:()=>j("aurora","Aurora","webgl2",()=>Promise.resolve().then(()=>(pt(),ft)).then(t=>t.createAuroraKernel))},{id:"mesh",label:"Iridescent Mesh",blurb:"A living gradient mesh with fine grain.",substrate:"webgl2",create:()=>j("mesh","Iridescent Mesh","webgl2",()=>Promise.resolve().then(()=>(bt(),ht)).then(t=>t.createMeshKernel))},{id:"moire",label:"Moir\xE9",blurb:"Light interfering through a breathing crystal lattice.",substrate:"webgl2",create:()=>j("moire","Moir\xE9","webgl2",()=>Promise.resolve().then(()=>(gt(),vt)).then(t=>t.createMoireKernel))},{id:"volumetric",label:"Volumetric",blurb:"Crepuscular shafts of light through an unseen medium.",substrate:"webgl2",create:()=>j("volumetric","Volumetric","webgl2",()=>Promise.resolve().then(()=>(xt(),yt)).then(t=>t.createVolumetricKernel))},{id:"lic",label:"Flow Imaging",blurb:"The same wind as Flow, rendered as honest silk.",substrate:"webgl2",create:()=>j("lic","Flow Imaging","webgl2",()=>Promise.resolve().then(()=>(St(),Tt)).then(t=>t.createLicKernel))},{id:"fluid-aurora",label:"Fluid Aurora",blurb:"Domain-warped fluid ribbons \u2014 the 2026 mainstream background standard.",substrate:"webgl2",create:()=>j("fluid-aurora","Fluid Aurora","webgl2",()=>Promise.resolve().then(()=>(Et(),At)).then(t=>t.createFluidAuroraKernel))},{id:"cloudfield",label:"Cloud Field",blurb:"Raymarched cloudscape from a 280-char demoscene kernel \u2014 infinite sky.",substrate:"webgl2",create:()=>j("cloudfield","Cloud Field","webgl2",()=>Promise.resolve().then(()=>(Pt(),Ct)).then(t=>t.createCloudFieldKernel))},{id:"plasma-orbs",label:"Plasma Orbs",blurb:"Five glassy metaball orbs drift, fuse, and refract \u2014 2026's chrome-orb standard.",substrate:"webgl2",create:()=>j("plasma-orbs","Plasma Orbs","webgl2",()=>Promise.resolve().then(()=>(Lt(),kt)).then(t=>t.createPlasmaOrbsKernel))},{id:"blobs-mesh",label:"Blobs Mesh",blurb:"Four softly-blending blobs of palette color drift through simplex noise \u2014 the 2026 fluid-mesh-gradient standard.",substrate:"webgl2",create:()=>j("blobs-mesh","Blobs Mesh","webgl2",()=>Promise.resolve().then(()=>(Mt(),It)).then(t=>t.createBlobsMeshKernel))},{id:"retro-plasma",label:"Retro Plasma",blurb:"Future Crew's 1993 four-sine plasma \u2014 the canonical demoscene fragment shader, ported verbatim.",substrate:"webgl2",create:()=>j("retro-plasma","Retro Plasma","webgl2",()=>Promise.resolve().then(()=>(Ft(),Bt)).then(t=>t.createRetroPlasmaKernel))},{id:"inversion-lattice",label:"Inversion Lattice",blurb:"A 2D Apollonian circle-inversion fractal \u2014 infinitely-nested luminous rings.",substrate:"webgl2",create:()=>j("inversion-lattice","Inversion Lattice","webgl2",()=>Promise.resolve().then(()=>(_t(),Gt)).then(t=>t.createInversionLatticeKernel))},{id:"vogel-bloom",label:"Vogel Bloom",blurb:"A golden-angle phyllotaxis seed field \u2014 a slowly rotating sunflower head of glowing dots.",substrate:"webgl2",create:()=>j("vogel-bloom","Vogel Bloom","webgl2",()=>Promise.resolve().then(()=>(Dt(),Kt)).then(t=>t.createVogelBloomKernel))},{id:"crystal-drift",label:"Crystal Drift",blurb:"Drifting Voronoi glass cells with glowing palette seams.",substrate:"webgl2",create:()=>j("crystal-drift","Crystal Drift","webgl2",()=>Promise.resolve().then(()=>(Nt(),Ot)).then(t=>t.createCrystalDriftKernel))},{id:"ripple-lattice",label:"Ripple Lattice",blurb:"A breathing dot lattice that ripples with concentric sonar waves under the cursor.",substrate:"webgl2",create:()=>j("ripple-lattice","Ripple Lattice","webgl2",()=>Promise.resolve().then(()=>(Wt(),Ut)).then(t=>t.createRippleLatticeKernel))},{id:"liquid-lumen",label:"Liquid Lumen",blurb:"Many small charges fuse into one flowing lava-lamp color field.",substrate:"webgl2",create:()=>j("liquid-lumen","Liquid Lumen","webgl2",()=>Promise.resolve().then(()=>(qt(),Ht)).then(t=>t.createLiquidLumenKernel))},{id:"spectral-drift",label:"Spectral Drift",blurb:"Oriented ribbons of band-limited Gabor noise \u2014 brushed-metal grain that combs around the pointer.",substrate:"webgl2",create:()=>j("spectral-drift","Spectral Drift","webgl2",()=>Promise.resolve().then(()=>(Vt(),zt)).then(t=>t.createSpectralDriftKernel))},{id:"mycelium-mesh",label:"Mycelium Mesh",blurb:"Domain-warped ridged-fbm veins knit a breathing mycelial network that reaches toward the cursor.",substrate:"webgl2",create:()=>j("mycelium-mesh","Mycelium Mesh","webgl2",()=>Promise.resolve().then(()=>(jt(),Xt)).then(t=>t.createMyceliumMeshKernel))},{id:"oilfield",label:"Oilfield",blurb:"A living painting: an fbm color field flattened into oil-paint brush patches by a Kuwahara filter.",substrate:"webgl2",create:()=>j("oilfield","Oilfield","webgl2",()=>Promise.resolve().then(()=>(Qt(),Yt)).then(t=>t.createOilfieldKernel))},{id:"suminagashi-drift",label:"Suminagashi Drift",blurb:"Closed-form ink-on-water marbling \u2014 drifting drops raked by combs into swirled marble bands.",substrate:"webgl2",create:()=>j("suminagashi-drift","Suminagashi Drift","webgl2",()=>Promise.resolve().then(()=>(Zt(),Jt)).then(t=>t.createSuminagashiDriftKernel))},{id:"kinetic-stipple",label:"Kinetic Stipple",blurb:"A curl-noise wind streams an advected density as discrete, variable-size stipple dots.",substrate:"webgl2",create:()=>j("kinetic-stipple","Kinetic Stipple","webgl2",()=>Promise.resolve().then(()=>(e2(),$t)).then(t=>t.createKineticStippleKernel))},{id:"agent1",label:"Agent 1",blurb:"Domain-warped generative mesh fluid \u2014 organic color blobs drift and merge like liquid silk.",substrate:"webgl2",create:()=>j("agent1","Agent 1","webgl2",()=>Promise.resolve().then(()=>(o2(),t2)).then(t=>t.createAgent1Kernel))},{id:"neural-bloom",label:"Neural Bloom",blurb:"Latent FBM fed through a tiny MLP palette network \u2014 an organic, ever-shifting AI-generated colour field.",substrate:"webgl2",create:()=>j("neural-bloom","Neural Bloom","webgl2",()=>Promise.resolve().then(()=>(n2(),r2)).then(t=>t.createNeuralBloomKernel))},{id:"aether-lattice",label:"Aether Lattice",blurb:"Quasicrystal interference modulates a volumetric medium \u2014 luminous, aperiodic lattice shafts breathe through the fog.",substrate:"webgl2",create:()=>j("aether-lattice","Aether Lattice","webgl2",()=>Promise.resolve().then(()=>(a2(),i2)).then(t=>t.createAetherLatticeKernel))},{id:"bat-signal",label:"Beacon",blurb:"A sweeping searchlight beam catches the provider emblem on a low cloud bank \u2014 volumetric god-rays, lens bloom, drifting dust.",substrate:"webgl2",create:()=>j("bat-signal","Beacon","webgl2",()=>Promise.resolve().then(()=>(s2(),l2)).then(t=>t.createBeamProjectorKernel))},{id:"storm-signal",label:"Tempest",blurb:"A charged slate storm cell billows behind the emblem \u2014 rolling mesocyclone mass with intermittent sheet and fork lightning.",substrate:"webgl2",create:()=>j("storm-signal","Tempest","webgl2",()=>Promise.resolve().then(()=>(u2(),c2)).then(t=>t.createStormCellKernel))},{id:"origami",label:"Origami",blurb:"A hand-made kozo paper sheet \u2014 warm fibers, laid lines, a deckle edge \u2014 the quiet stage for folded, cut, washed, and quilled marks.",substrate:"webgl2",create:()=>j("origami","Origami","webgl2",()=>Promise.resolve().then(()=>(m2(),d2)).then(t=>t.createPaperfieldKernel))},{id:"ink-diffusion",label:"Ink Diffusion",blurb:"Ink wicks into wet fibre \u2014 capillary chromatography fronts bleed, darken at the rim, and separate into spectral halos.",substrate:"webgl2",create:()=>j("ink-diffusion","Ink Diffusion","webgl2",()=>Promise.resolve().then(()=>(p2(),f2)).then(t=>t.createInkDiffusionKernel))},{id:"petroleum-sheen",label:"Petroleum Sheen",blurb:"Computed thin-film interference on a flowing oil film \u2014 nested oil-slick rainbows drift and marble over deep water.",substrate:"webgl2",create:()=>j("petroleum-sheen","Petroleum Sheen","webgl2",()=>Promise.resolve().then(()=>(b2(),h2)).then(t=>t.createPetroleumSheenKernel))},{id:"boids",label:"Boids",blurb:"A living murmuration \u2014 hundreds of birds flocking as one.",substrate:"2d",create:()=>j("boids","Boids","2d",()=>Promise.resolve().then(()=>(S2(),T2)).then(t=>t.createBoidsKernel))},{id:"swarmEmber",label:"Swarm Ember",blurb:"Embers murmurate into the BurnBar flame, hold with heat, and dissolve.",substrate:"2d",create:()=>Ce({enableSwarmSparkles:!0,logoHero:!0})}],D0="constellation",Ui=$0.map(({create:t,...e})=>e);function me(t){return $0.find(e=>e.id===t)??$0[0]}function ue(t){return!!t&&$0.some(e=>e.id===t)}function A2(t,e,o,r=me){let n=r(t),a=t,s="native";n.substrate==="webgl2"&&!o?(a=D0,s="webgl2-unavailable"):n.requiresFloatTex&&!e.colorBufferFloat&&(a=n.fallbackId??D0,s="float-target-unavailable");let c=r(a);return{requestedId:t,resolvedId:a,requestedSubstrate:n.substrate,resolvedSubstrate:c.substrate,reason:s,fallback:a!==t,glSupported:o}}var E2=700,C2=500,P2=[.14,.5,.86],d1=[.18,.5,.82],O0=24,z0=16,k2={"2d":2,webgl2:1.2,webgpu:1};function en(){try{let e=document.createElement("canvas").getContext("webgl2");if(!e)return{supported:!1,caps:{colorBufferFloat:!1,floatBlend:!1}};let o=p1(e);return e.getExtension("WEBGL_lose_context")?.loseContext(),{supported:!0,caps:o}}catch{return{supported:!1,caps:{colorBufferFloat:!1,floatBlend:!1}}}}var Be=class{constructor(e,o){v(this,"glSupported");v(this,"glCaps");v(this,"container");v(this,"slots",[]);v(this,"activeId");v(this,"requestedKernelId");v(this,"theme");v(this,"palette");v(this,"swarmEmberOptions");v(this,"onResolve");v(this,"onReadability");v(this,"readabilityRegions");v(this,"readability",new xe);v(this,"readabilityCanvas",null);v(this,"readabilityContext",null);v(this,"readabilityWorker");v(this,"readabilityWorkerURL",null);v(this,"readabilityWorkerRequest",0);v(this,"readabilityWorkerPending",new Map);v(this,"lastReadabilityProfile",null);v(this,"lastReadabilitySample",-1/0);v(this,"readabilitySampling",!1);v(this,"readabilityResampleRequested",!1);v(this,"destroyed",!1);v(this,"onStatus");v(this,"width",0);v(this,"height",0);v(this,"tMs",0);v(this,"lastNow",0);v(this,"raf",null);v(this,"visible",!0);v(this,"pageVisible",!0);v(this,"retryRequestedKernelOnVisible",!1);v(this,"hostVisible",!0);v(this,"reducedMotion",!1);v(this,"maxFps",0);v(this,"clock",Z1());v(this,"shutter",new ke);v(this,"cinematicDebug",{lastDt:0,lastAlpha:1,presentCount:0,skipCount:0});v(this,"pointer",{x:0,y:0,active:!1});v(this,"glyphField",null);v(this,"scroll",{y:0,vy:0,yMax:0});v(this,"scrollDelta",0);v(this,"lastHarvest",-1e9);v(this,"resizeObs",null);v(this,"intersectionObs",null);v(this,"mql",null);v(this,"initialHarvestRaf",null);v(this,"initialHarvestTimer",null);v(this,"initialReadabilityRaf",null);v(this,"onVisibility",()=>{let e=this.pageVisible;this.pageVisible=!document.hidden,this.pageVisible&&this.scheduleReadabilitySample(),!e&&this.pageVisible&&this.retryRequestedKernelOnVisible&&this.transitionKernel(this.requestedKernelId,!0)});v(this,"onPointerMove",e=>{let o=this.container.getBoundingClientRect();this.pointer.x=e.clientX-o.left,this.pointer.y=e.clientY-o.top,this.pointer.active=!0;for(let r of this.slots)r.kernel.pointer?.(this.pointer.x,this.pointer.y,!0)});v(this,"onPointerOut",()=>{this.pointer.active=!1;for(let e of this.slots)e.kernel.pointer?.(this.pointer.x,this.pointer.y,!1)});v(this,"onClick",e=>{if(e.target?.closest?.("a, button, input, textarea, select, label, [role='button'],.glass-frost, .glass-refract, .glass-pill, .studio-switcher"))return;let r=this.container.getBoundingClientRect(),n=e.clientX-r.left,a=e.clientY-r.top;for(let s of this.slots)s.outgoing||s.kernel.click?.(n,a)});v(this,"onScroll",e=>{let o=e.target;if(o!==document&&o!==document.documentElement)return;let r=window.scrollY||window.pageYOffset||0,n=r-this.scroll.y,a=document.documentElement;this.scroll.y=r,this.scroll.yMax=Math.max(0,(a?.scrollHeight??0)-window.innerHeight),this.scrollDelta+=n,this.harvestObstacles()});v(this,"onReducedMotionChange",e=>{if(this.reducedMotion=e.matches,e.matches){this.raf!==null&&(cancelAnimationFrame(this.raf),this.raf=null);for(let o of this.slots)o.kernel.renderStatic?.();this.scheduleReadabilitySample()}else this.raf===null&&(this.startLoop(),this.scheduleReadabilitySample())});this.container=e;let r=en();this.glSupported=r.supported,this.glCaps=r.caps,this.theme=o.theme,this.palette=o.palette??ve(o.theme),this.swarmEmberOptions=o.swarmEmberOptions,this.onResolve=o.onResolve,this.onReadability=o.onReadability,this.readabilityRegions=o.readabilityRegions,this.onStatus=o.onStatus,this.activeId=o.initialKernel??D0,this.requestedKernelId=this.activeId,this.maxFps=o.maxFps&&o.maxFps>0?Math.min(o.maxFps,60):0,this.reducedMotion=o.reducedMotionOverride??(typeof window<"u"&&window.matchMedia("(prefers-reduced-motion: reduce)").matches);let n=e.getBoundingClientRect();this.width=n.width||window.innerWidth,this.height=n.height||window.innerHeight,this.mountInitial(),this.attachObservers(),this.reducedMotion?this.scheduleReadabilitySample():this.startLoop()}setKernel(e){this.transitionKernel(e,!1)}transitionKernel(e,o){this.requestedKernelId=e;let r=this.resolveKernel(e);if(!o&&r.resolvedId===this.activeId&&this.slots.some(s=>s.id===r.resolvedId&&!s.outgoing&&!s.contextLost)){this.publishResolution(r);return}this.finalizeOutgoing();for(let s of this.slots)s.outgoing=!0,s.canvas.style.opacity="0",s.disposeTimer=window.setTimeout(()=>this.disposeSlot(s),E2+80);let n=this.createSlot(r.resolvedId);this.activeId=n.id,n.id===r.resolvedId&&n.substrate===r.resolvedSubstrate&&(this.retryRequestedKernelOnVisible=!1),this.publishResolution(this.withSlotResolution(r,n)),this.harvestObstacles(!0),this.emitPaletteReadability(),n.id!==r.resolvedId&&(n.canvas.style.opacity="1"),requestAnimationFrame(()=>{n.canvas.parentNode&&(n.canvas.style.opacity="1")}),this.reducedMotion&&n.kernel.renderStatic?.(),this.scheduleReadabilitySample()}setTheme(e){if(e!==this.theme){this.theme=e,this.palette=ve(e);for(let o of this.slots)o.kernel.setTheme(e,this.palette),this.reducedMotion&&o.kernel.renderStatic?.();this.readability.reset(),this.emitPaletteReadability(),this.scheduleReadabilitySample()}}refreshPalette(){this.palette=ve(this.theme);for(let e of this.slots)e.kernel.setTheme(this.theme,this.palette),this.reducedMotion&&e.kernel.renderStatic?.();this.emitPaletteReadability(),this.scheduleReadabilitySample()}setPalette(e){this.palette={theme:this.theme,bg:[...e.bg],accents:e.accents.map(o=>[...o]),ink:[...e.ink],intensity:e.intensity};for(let o of this.slots)o.kernel.setTheme(this.theme,this.palette),this.reducedMotion&&o.kernel.renderStatic?.();this.emitPaletteReadability(),this.scheduleReadabilitySample()}getResolvedKernel(){return this.activeId}getRuntimeState(){return{hostVisible:this.hostVisible,renderLoopScheduled:this.raf!==null,reducedMotion:this.reducedMotion,resolvedKernel:this.activeId}}getCinematicDebug(){return{...this.cinematicDebug,maxFps:this.maxFps}}setHostVisible(e){this.hostVisible!==e&&(this.hostVisible=e,e?this.raf===null&&!this.reducedMotion&&(this.startLoop(),this.scheduleReadabilitySample()):(this.raf!==null&&(cancelAnimationFrame(this.raf),this.raf=null),this.initialReadabilityRaf!==null&&(cancelAnimationFrame(this.initialReadabilityRaf),this.initialReadabilityRaf=null)))}setMaxFps(e){this.maxFps=Number.isFinite(e)&&e>0?Math.min(e,60):0,this.clock.lastFrameAdvanceAt=performance.now()}wake(e,o,r,n,a,s){for(let c of this.slots)c.outgoing||c.kernel.wake?.(e,o,r,n,a,s)}setGlyphField(e){this.glyphField=e;for(let o of this.slots)o.kernel.setGlyphField?.(e)}destroy(){this.destroyed=!0,this.raf!==null&&cancelAnimationFrame(this.raf),this.initialHarvestRaf!==null&&cancelAnimationFrame(this.initialHarvestRaf),this.initialHarvestTimer!==null&&clearTimeout(this.initialHarvestTimer),this.initialReadabilityRaf!==null&&cancelAnimationFrame(this.initialReadabilityRaf),this.resizeObs?.disconnect(),this.intersectionObs?.disconnect(),document.removeEventListener("visibilitychange",this.onVisibility),window.removeEventListener("pointermove",this.onPointerMove),window.removeEventListener("pointerout",this.onPointerOut),window.removeEventListener("scroll",this.onScroll,!0),window.removeEventListener("click",this.onClick),this.mql?.removeEventListener("change",this.onReducedMotionChange);for(let e of[...this.slots])this.disposeSlot(e);this.slots=[],this.readabilityCanvas=null,this.readabilityContext=null,this.readabilityWorker?.terminate(),this.readabilityWorkerURL&&URL.revokeObjectURL(this.readabilityWorkerURL);for(let e of this.readabilityWorkerPending.values())clearTimeout(e.timeout),e.resolve(null);this.readabilityWorkerPending.clear(),this.readabilityWorker=null,this.readabilityWorkerURL=null,this.shutter.dispose()}resolveKernel(e){let o=A2(e,this.glCaps,this.glSupported),r=me(e);if(o.reason==="native"&&(r.requiresWebGPU||r.substrate==="webgpu")&&typeof navigator<"u"&&!("gpu"in navigator)){let n=r.fallbackId??D0,a=me(n);return{...o,resolvedId:n,resolvedSubstrate:a.substrate,reason:"webgpu-unavailable",fallback:n!==e}}return o}withSlotResolution(e,o){return o.id===e.resolvedId?e:{...e,resolvedId:o.id,resolvedSubstrate:o.substrate,reason:"context-unavailable",fallback:o.id!==e.requestedId}}publishResolution(e){this.onStatus?.(e),this.onResolve?.(e.resolvedId)}mountInitial(){let e=this.resolveKernel(this.activeId),o=this.createSlot(e.resolvedId);this.activeId=o.id,o.canvas.style.opacity="1",this.publishResolution(this.withSlotResolution(e,o)),this.reducedMotion&&o.kernel.renderStatic?.()}frameCtx(e){let o=Math.min(window.devicePixelRatio||1,k2[e]);return{width:this.width,height:this.height,dpr:o,theme:this.theme,palette:this.palette,reducedMotion:this.reducedMotion,caps:this.glCaps}}sizeCanvas(e){let o=Math.min(window.devicePixelRatio||1,k2[e.substrate]);e.canvas.width=Math.max(1,Math.round(this.width*o)),e.canvas.height=Math.max(1,Math.round(this.height*o)),e.canvas.style.width=`${this.width}px`,e.canvas.style.height=`${this.height}px`}createSlot(e,o=0){let r=me(e),n=e==="swarmEmber"&&this.swarmEmberOptions?Ce(this.swarmEmberOptions):r.create(),a=n.substrate,s=document.createElement("canvas");s.setAttribute("aria-hidden","true"),s.style.cssText=`position:absolute;inset:0;display:block;opacity:0;transition:opacity ${E2}ms ease;will-change:opacity;`,this.container.appendChild(s);let c={id:n.id,canvas:s,kernel:n,substrate:a,context:null,outgoing:!1,disposeTimer:null,contextLost:!1,onContextLost:null,onContextRestored:null};this.sizeCanvas(c),this.slots.push(c);let f=null;if(a==="webgpu"){if(f=s.getContext("webgpu"),!f)return this.disposeSlot(c),o<2?this.createSlot(D0,o+1):c}else if(a==="webgl2"){if(f=s.getContext("webgl2",{alpha:!0,antialias:!1,depth:!1,stencil:!1,premultipliedAlpha:!0,powerPreference:"low-power",preserveDrawingBuffer:!1}),!f)return this.disposeSlot(c),o<2?this.createSlot(D0,o+1):c}else if(f=s.getContext("2d",{alpha:!0}),!f)return this.disposeSlot(c),c;c.context=f,a==="webgl2"&&(c.onContextLost=y=>{y.preventDefault(),c.contextLost=!0,!c.outgoing&&this.slots.includes(c)&&(this.retryRequestedKernelOnVisible=!0,this.transitionKernel(this.requestedKernelId,!0))},c.onContextRestored=()=>{c.contextLost=!1},s.addEventListener("webglcontextlost",c.onContextLost,!1),s.addEventListener("webglcontextrestored",c.onContextRestored,!1));try{n.init(f,this.frameCtx(a))}catch(y){return console.error("[backdrop] %s init failed \u2014 falling back to %s:",e,D0,y),this.disposeSlot(c),o<2?this.createSlot(D0,o+1):c}return this.glyphField&&n.setGlyphField?.(this.glyphField),c}disposeSlot(e){e.disposeTimer!==null&&(clearTimeout(e.disposeTimer),e.disposeTimer=null),e.onContextLost&&(e.canvas.removeEventListener("webglcontextlost",e.onContextLost),e.onContextLost=null),e.onContextRestored&&(e.canvas.removeEventListener("webglcontextrestored",e.onContextRestored),e.onContextRestored=null);try{e.kernel.dispose()}catch{}e.substrate==="webgl2"&&e.context&&e.context.getExtension("WEBGL_lose_context")?.loseContext(),e.canvas.parentNode&&e.canvas.parentNode.removeChild(e.canvas),this.slots=this.slots.filter(o=>o!==e)}finalizeOutgoing(){for(let e of[...this.slots])e.outgoing&&this.disposeSlot(e)}startLoop(){this.lastNow=performance.now();let e=o=>{if(this.raf=requestAnimationFrame(e),!this.visible||!this.pageVisible||!this.hostVisible){this.lastNow=o,this.clock.lastNow=o,this.clock.lastFrameAdvanceAt=o;return}let r=Pe(this.clock,o,this.maxFps);if(!r.presented){this.cinematicDebug.skipCount+=1;return}let n=r.dt;if(this.lastNow=o,this.tMs+=n,this.cinematicDebug.lastDt=n,this.cinematicDebug.lastAlpha=r.alpha,this.cinematicDebug.presentCount+=1,this.scroll.vy=this.scroll.vy*J1(.82,n)+this.scrollDelta*Q1(.18,n),this.scrollDelta=0,this.scroll.vy>120?this.scroll.vy=120:this.scroll.vy<-120&&(this.scroll.vy=-120),Math.abs(this.scroll.vy)<.05&&(this.scroll.vy=0),this.scroll.vy!==0)for(let a of this.slots)a.kernel.scroll?.(this.scroll.y,this.scroll.vy,this.scroll.yMax);for(let a of this.slots)a.kernel.frame(this.tMs,n),this.applyShutter(a,r.alpha);o-this.lastReadabilitySample>=C2&&this.emitReadability(o)};this.raf=requestAnimationFrame(e)}applyShutter(e,o){if(!(o>=1))try{e.substrate==="2d"&&e.context?this.shutter.apply2d(e.canvas,e.context,o):e.substrate==="webgl2"&&e.context&&this.shutter.applyWebgl(e.context,o)}catch{}}emitPaletteReadability(){if(!this.onReadability)return;let e=this.readability.update({samples:[this.palette.bg,...this.palette.accents,this.palette.ink],source:"palette",nowMs:performance.now()});this.lastReadabilityProfile=e,this.onReadability(e)}scheduleReadabilitySample(){!this.hostVisible||!this.onReadability||this.initialReadabilityRaf!==null||(this.initialReadabilityRaf=requestAnimationFrame(e=>{this.initialReadabilityRaf=null,this.emitReadability(e,!0)}))}async emitReadability(e,o=!1){if(this.onReadability&&!(!o&&e-this.lastReadabilitySample<C2)){if(this.readabilitySampling){this.readabilityResampleRequested=!0;return}this.readabilitySampling=!0,this.lastReadabilitySample=e;try{let r=await this.readabilitySamples();if(this.destroyed)return;let a={...r.samples.length>0?this.readability.update({samples:r.samples,source:"canvas",nowMs:e}):P1(this.palette),samplingDurationMs:r.blockingDurationMs},s=this.lastReadabilityProfile;if(!(!s||s.tone!==a.tone||s.source!==a.source||Math.abs(s.scrimOpacity-a.scrimOpacity)>=.0125||Math.abs(s.minLuminance-a.minLuminance)>=.025||Math.abs(s.maxLuminance-a.maxLuminance)>=.025))return;this.lastReadabilityProfile=a,this.onReadability(a)}finally{this.readabilitySampling=!1,this.readabilityResampleRequested&&!this.destroyed&&(this.readabilityResampleRequested=!1,this.lastReadabilitySample=-1/0,this.scheduleReadabilitySample())}}}async readabilitySamples(){let e=[],o=this.readabilityRegionPoints(),r=0;for(let n of this.slots){let a=await this.readSlotSamples(n,o);e.push(...a.samples),r+=a.blockingDurationMs}return{samples:e,blockingDurationMs:r}}readabilityRegionPoints(){let e=this.readabilityRegions?.()??[];if(e.length===0)return P2.flatMap(a=>P2.map(s=>[s,a]));let o=this.container.getBoundingClientRect(),r=Math.max(1,o.width),n=Math.max(1,o.height);return e.slice(0,4).flatMap(a=>d1.map((s,c)=>{let f=d1[d1.length-1-c],y=a.left+a.width*s-o.left,I=a.top+a.height*f-o.top;return[Math.min(1,Math.max(0,y/r)),Math.min(1,Math.max(0,I/n))]}))}async readSlotSamples(e,o){let r=0,n=null;try{this.readabilityCanvas||(this.readabilityCanvas=document.createElement("canvas"),this.readabilityCanvas.width=O0,this.readabilityCanvas.height=z0,this.readabilityContext=this.readabilityCanvas.getContext("2d",{alpha:!0,willReadFrequently:!0}));let a=this.readabilityContext;if(!a)return{samples:[],blockingDurationMs:r};if(typeof createImageBitmap=="function"){let y=performance.now(),I=createImageBitmap(e.canvas,{resizeWidth:O0,resizeHeight:z0,resizeQuality:"low"});r+=performance.now()-y,n=await I}if(n){let y=performance.now(),I=this.readBitmapOffMainThread(n);if(r+=performance.now()-y,I){n=null;let p=await I;if(p){let m=performance.now(),S=this.samplesFromRgba(p,o);return r+=performance.now()-m,{samples:S,blockingDurationMs:r}}}}let s=performance.now();a.clearRect(0,0,O0,z0),a.drawImage(n??e.canvas,0,0,O0,z0);let c=a.getImageData(0,0,O0,z0).data,f=this.samplesFromRgba(c,o);return r+=performance.now()-s,{samples:f,blockingDurationMs:r}}catch{return{samples:[],blockingDurationMs:r}}finally{n?.close()}}samplesFromRgba(e,o){return o.map(([r,n])=>{let a=Math.min(O0-1,Math.max(0,Math.round(r*(O0-1)))),c=(Math.min(z0-1,Math.max(0,Math.round(n*(z0-1))))*O0+a)*4,f=(e[c+3]??255)/255;return[(e[c]??0)*f+this.palette.bg[0]*(1-f),(e[c+1]??0)*f+this.palette.bg[1]*(1-f),(e[c+2]??0)*f+this.palette.bg[2]*(1-f)]})}readBitmapOffMainThread(e){let o=this.getReadabilityWorker();if(!o)return null;let r=++this.readabilityWorkerRequest;return new Promise(n=>{let a=window.setTimeout(()=>{this.readabilityWorkerPending.delete(r),n(null)},750);this.readabilityWorkerPending.set(r,{resolve:n,timeout:a}),o.postMessage({id:r,bitmap:e},[e])})}getReadabilityWorker(){if(this.readabilityWorker!==void 0)return this.readabilityWorker;if(typeof Worker>"u"||typeof Blob>"u"||typeof URL>"u"||typeof OffscreenCanvas>"u")return this.readabilityWorker=null,null;let e=`
      const canvas = new OffscreenCanvas(${O0}, ${z0});
      const context = canvas.getContext("2d", { alpha: true, willReadFrequently: true });
      self.onmessage = (event) => {
        const { id, bitmap } = event.data;
        try {
          context.clearRect(0, 0, canvas.width, canvas.height);
          context.drawImage(bitmap, 0, 0, canvas.width, canvas.height);
          bitmap.close();
          const rgba = context.getImageData(0, 0, canvas.width, canvas.height).data;
          self.postMessage({ id, rgba: rgba.buffer }, [rgba.buffer]);
        } catch (error) {
          try { bitmap.close(); } catch (_) {}
          self.postMessage({ id, rgba: null });
        }
      };
    `;try{this.readabilityWorkerURL=URL.createObjectURL(new Blob([e],{type:"text/javascript"}));let o=new Worker(this.readabilityWorkerURL);return o.onmessage=r=>{let n=this.readabilityWorkerPending.get(r.data.id);n&&(clearTimeout(n.timeout),this.readabilityWorkerPending.delete(r.data.id),n.resolve(r.data.rgba?new Uint8ClampedArray(r.data.rgba):null))},o.onerror=()=>{o.terminate(),this.readabilityWorker=null;for(let r of this.readabilityWorkerPending.values())clearTimeout(r.timeout),r.resolve(null);this.readabilityWorkerPending.clear()},this.readabilityWorker=o,o}catch{return this.readabilityWorker=null,null}}attachObservers(){this.resizeObs=new ResizeObserver(e=>{let o=e[0];if(!o)return;let{width:r,height:n}=o.contentRect;if(!(r===0||n===0)){this.width=r,this.height=n;for(let a of this.slots)this.sizeCanvas(a),a.kernel.resize(this.frameCtx(a.substrate));this.harvestObstacles(!0),this.scheduleReadabilitySample()}}),this.resizeObs.observe(this.container),this.initialHarvestRaf=requestAnimationFrame(()=>this.harvestObstacles(!0)),this.initialHarvestTimer=window.setTimeout(()=>this.harvestObstacles(!0),700),this.intersectionObs=new IntersectionObserver(e=>{this.visible=e[0]?.isIntersecting??!0},{threshold:0}),this.intersectionObs.observe(this.container),document.addEventListener("visibilitychange",this.onVisibility),window.addEventListener("pointermove",this.onPointerMove,{passive:!0}),window.addEventListener("pointerout",this.onPointerOut,{passive:!0}),window.addEventListener("scroll",this.onScroll,{passive:!0,capture:!0}),window.addEventListener("click",this.onClick,{passive:!0}),this.mql=window.matchMedia("(prefers-reduced-motion: reduce)"),this.mql.addEventListener("change",this.onReducedMotionChange)}harvestObstacles(e=!1){let o=typeof performance<"u"?performance.now():0;if(!e&&o-this.lastHarvest<300||(this.lastHarvest=o,!this.slots.some(f=>!f.outgoing&&f.kernel.obstacles)))return;let n=this.container.getBoundingClientRect(),a=window.innerHeight,s=document.querySelectorAll(".glass-frost, .glass-refract, h1, h2"),c=[];s.forEach(f=>{if(c.length>=24)return;let y=f.getBoundingClientRect();y.width<8||y.height<8||y.bottom<-140||y.top>a+140||c.push({x:y.left-n.left,y:y.top-n.top,w:y.width,h:y.height})});for(let f of this.slots)f.outgoing||f.kernel.obstacles?.(c)}};var L2="fluid-aurora";function tn(){try{let t=(location.hash||"").replace(/^#/,"").trim();if(ue(t))return t;let e=new URLSearchParams(location.search).get("kernel");if(ue(e))return e}catch{}return ue(L2)?L2:$0[0].id}function on(){let t=Number(new URLSearchParams(location.search).get("maxFps"));return Number.isFinite(t)&&t>0?Math.min(t,60):0}function rn(){try{return new URLSearchParams(location.search).get("motion")==="full"?!1:void 0}catch{return}}function I2(){let t=document.getElementById("host");t||(t=document.createElement("div"),t.id="host",document.body.appendChild(t)),t.style.position="fixed",t.style.inset="0",t.style.width="100%",t.style.height="100%",t.style.overflow="hidden";let e=null,o=new Be(t,{theme:"dark",initialKernel:tn(),maxFps:on(),onReadability:r=>{e=r,window.webkit?.messageHandlers?.backdropReadability?.postMessage(r)},reducedMotionOverride:rn()});window.__setKernel=r=>ue(r)?(o.setKernel(r),!0):!1,window.__setTheme=r=>{(r==="dark"||r==="light")&&o.setTheme(r)},window.__setMaxFps=r=>o.setMaxFps(r),window.__getKernel=()=>o.getResolvedKernel(),window.__getReadability=()=>e,window.__getBackdropState=()=>o.getRuntimeState(),window.__setBackdropActive=r=>{o.setHostVisible(r===!0)},window.__cinematicClock={cinematicPresentFps:Y1,shouldAdvancePresent:Je,frameDeltaMs:Ze,shutterAlpha:$e,advanceCinematicPresent:Pe},window.__getCinematicDebug=()=>o.getCinematicDebug(),window.__kernels=$0.map(r=>({id:r.id,label:r.label,blurb:r.blurb,substrate:r.substrate})),window.__backdropReady=!0,window.addEventListener("hashchange",()=>{let r=(location.hash||"").replace(/^#/,"").trim();ue(r)&&o.setKernel(r)})}document.readyState==="loading"?document.addEventListener("DOMContentLoaded",I2,{once:!0}):I2();})();

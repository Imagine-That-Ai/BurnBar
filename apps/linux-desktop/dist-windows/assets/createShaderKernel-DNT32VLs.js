import{p as xe,N as ue,a as S}from"./index-PmASUbTN.js";const ve=`#version 300 es
void main(){
  // Fullscreen triangle from gl_VertexID — no attribute buffers needed.
  vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));
  gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}`,W=`#version 300 es
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
`,ce=`
void main(){
  vec2 fragCoord = gl_FragCoord.xy;
  vec2 uv = fragCoord / uResolution;
  vec3 col = renderKernel(uv, fragCoord);
  col += dither(fragCoord);
  fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}`;function g(e,t,u){const a=fe(e,e.VERTEX_SHADER,ve,`${u}:vert`),f=fe(e,e.FRAGMENT_SHADER,t,`${u}:frag`);if(!a||!f)return a&&e.deleteShader(a),f&&e.deleteShader(f),null;const i=e.createProgram();return i?(e.attachShader(i,a),e.attachShader(i,f),e.linkProgram(i),e.deleteShader(a),e.deleteShader(f),e.getProgramParameter(i,e.LINK_STATUS)?i:(console.error(`[backdrop] ${u} link failed:
${e.getProgramInfoLog(i)}`),e.deleteProgram(i),null)):(e.deleteShader(a),e.deleteShader(f),null)}function fe(e,t,u,a){const f=e.createShader(t);if(!f)return null;if(e.shaderSource(f,u),e.compileShader(f),!e.getShaderParameter(f,e.COMPILE_STATUS)){const i=e.getShaderInfoLog(f)??"unknown";return console.error(`[backdrop] ${a} shader compile failed:
${i}`),e.deleteShader(f),null}return f}const j=`
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
`,K=`
float fbm(vec3 p){
  float a = 0.5, s = 0.0;
  for(int i = 0; i < 3; i++){
    s += a * snoise(p);
    p *= 2.0;
    a *= 0.5;
  }
  return s;
}
`,Y=`
float hash21(vec2 p){
  p = fract(p * vec2(123.34, 456.21));
  p += dot(p, p + 45.32);
  return fract(p.x * p.y);
}
// Triangular-PDF dither, ~±1 LSB at 8-bit.
vec3 dither(vec2 fragCoord){
  float r = hash21(fragCoord);
  float r2 = hash21(fragCoord + 17.0);
  return vec3((r + r2 - 1.0)) / 255.0;
}
`,q=`
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
`,w={hasSim:`uniform float uHasSim;
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
`},Re=w.hasSim+w.scroll+w.impulses+w.obstacles;function se(e,t){return{uResolution:e.getUniformLocation(t,"uResolution"),uTime:e.getUniformLocation(t,"uTime"),uPointer:e.getUniformLocation(t,"uPointer"),uPointerActive:e.getUniformLocation(t,"uPointerActive"),uBg:e.getUniformLocation(t,"uBg"),uAccent0:e.getUniformLocation(t,"uAccent0"),uAccent1:e.getUniformLocation(t,"uAccent1"),uAccent2:e.getUniformLocation(t,"uAccent2"),uAccent3:e.getUniformLocation(t,"uAccent3"),uInk:e.getUniformLocation(t,"uInk"),uIntensity:e.getUniformLocation(t,"uIntensity"),uTheme:e.getUniformLocation(t,"uTheme"),uHasSim:e.getUniformLocation(t,"uHasSim"),uScroll:e.getUniformLocation(t,"uScroll"),uScrollVel:e.getUniformLocation(t,"uScrollVel"),uImpulses:e.getUniformLocation(t,"uImpulses"),uImpulseCount:e.getUniformLocation(t,"uImpulseCount"),uObstacleRects:e.getUniformLocation(t,"uObstacleRects"),uObstacleCount:e.getUniformLocation(t,"uObstacleCount"),uPrev:e.getUniformLocation(t,"uPrev"),uSim:e.getUniformLocation(t,"uSim"),uSimResolution:e.getUniformLocation(t,"uSimResolution"),uGlyphField:e.getUniformLocation(t,"uGlyphField"),uGlyphActive:e.getUniformLocation(t,"uGlyphActive"),uGlyphRect:e.getUniformLocation(t,"uGlyphRect"),uGlyphPhase:e.getUniformLocation(t,"uGlyphPhase")}}const ae=8,me=2,he=`${W}${Re}
uniform sampler2D uPrev;
uniform vec2  uSimResolution;
`,ye=`${W}
uniform vec2  uSimResolution;
`;function le(e){return`
void main(){
  vec2 uv = gl_FragCoord.xy / uSimResolution;
  fragColor = ${e}(uv);
}`}function Ae(e,t,u,a,f,i){e.getExtension("EXT_color_buffer_float");const U=xe(e,t.format,u),k=U.filterable?e.LINEAR:e.NEAREST,p=g(e,`${he}
${j}
${K}
${Y}
${q}
${t.step}
${le("simStep")}`,`${i}:sim`),_=g(e,`${ye}
${j}
${K}
${Y}
${q}
${t.seed}
${le("simSeed")}`,`${i}:seed`);let R=0,x=0,c=null,E=null,y=null,b=null,P=!1,D=null,$=null,G=null;p&&(D=e.getUniformLocation(p,"uPrev"),$=e.getUniformLocation(p,"uSimResolution")),_&&(G=e.getUniformLocation(_,"uSimResolution"));function z(s,d){R=Math.max(me,Math.round(s*t.scale)),x=Math.max(me,Math.round(d*t.scale))}function F(){const s=e.createTexture(),d=e.createFramebuffer();return!s||!d?(s&&e.deleteTexture(s),d&&e.deleteFramebuffer(d),null):(e.bindTexture(e.TEXTURE_2D,s),e.texImage2D(e.TEXTURE_2D,0,U.internalFormat,R,x,0,U.format,U.type,null),e.texParameteri(e.TEXTURE_2D,e.TEXTURE_MIN_FILTER,k),e.texParameteri(e.TEXTURE_2D,e.TEXTURE_MAG_FILTER,k),e.texParameteri(e.TEXTURE_2D,e.TEXTURE_WRAP_S,e.CLAMP_TO_EDGE),e.texParameteri(e.TEXTURE_2D,e.TEXTURE_WRAP_T,e.CLAMP_TO_EDGE),e.bindFramebuffer(e.FRAMEBUFFER,d),e.framebufferTexture2D(e.FRAMEBUFFER,e.COLOR_ATTACHMENT0,e.TEXTURE_2D,s,0),{tex:s,fbo:d})}function I(s){return s?(e.bindFramebuffer(e.FRAMEBUFFER,s.fbo),e.checkFramebufferStatus(e.FRAMEBUFFER)===e.FRAMEBUFFER_COMPLETE):!1}function v(){for(const s of[c,E])s&&(e.deleteTexture(s.tex),e.deleteFramebuffer(s.fbo));c=E=y=b=null}function M(){v(),c=F(),E=F(),P=U.renderable&&!!c&&!!E&&!!p&&!!_&&I(c)&&I(E),e.bindFramebuffer(e.FRAMEBUFFER,null),y=c,b=E,P||console.error(`[backdrop] ${i} sim target/program incomplete; display-only.`)}return z(a,f),M(),{get ok(){return P},get simW(){return R},get simH(){return x},get stepProgram(){return p},get seedProgram(){return _},current(){return P&&y?y.tex:null},resize(s,d){P&&(z(s,d),M())},reseed(s,d){if(!(!P||!_)){e.useProgram(_),d(_),e.bindVertexArray(s),G&&e.uniform2f(G,R,x),e.viewport(0,0,R,x);for(const A of[c,E])A&&(e.bindFramebuffer(e.FRAMEBUFFER,A.fbo),e.drawArrays(e.TRIANGLES,0,3));y=c,b=E,e.bindFramebuffer(e.FRAMEBUFFER,null)}},step(s,d){if(!P||!p)return;const A=Math.min(Math.max(t.stepsPerFrame|0,1),ae);e.useProgram(p),d(p),e.bindVertexArray(s),$&&e.uniform2f($,R,x),e.viewport(0,0,R,x);for(let T=0;T<A&&!(!y||!b);T++){e.bindFramebuffer(e.FRAMEBUFFER,b.fbo),e.activeTexture(e.TEXTURE0),e.bindTexture(e.TEXTURE_2D,y.tex),D&&e.uniform1i(D,0),e.drawArrays(e.TRIANGLES,0,3);const L=y;y=b,b=L}e.bindFramebuffer(e.FRAMEBUFFER,null)},settle(s,d,A){if(!P||s<=0)return;const T=Math.ceil(s/ae);for(let L=0;L<T;L++)this.step(d,A)},dispose(){v(),p&&e.deleteProgram(p),_&&e.deleteProgram(_)}}}const Z=8,Ee=24,Ue=3;function Pe(e){let t=null,u=null,a=null,f=null,i=null;const U=[.5,.5];let k=[.5,.5],p=0,_=!1,R=null;const x=!!(e.sim||e.textures||e.controls);let c=null,E=null;const y=[];let b=ue,P=0;const D=new Map,$=e.controls?.includes("scroll")??!1,G=e.controls?.includes("impulses")??!1,z=e.controls?.includes("obstacles")??!1,F=e.controls?.includes("glyph")??!1,I={y:0,yMax:0,vy:0},v=new Float32Array(Z*4);let M=0;const s=new Float32Array(Ee*4);let d=0,A=null,T=null,L=!1;const B=[.5,.5,.5,.5];let ee=1;const te=n=>{n.preventDefault(),_=!0},ne=()=>{_=!1,t&&(D.clear(),re(t),Q(),J(),x&&(oe(t),ie(t)),F&&(T=null,L=!!A))};function de(n){!F||!A||(T||(T=n.createTexture()),T&&(n.bindTexture(n.TEXTURE_2D,T),n.texImage2D(n.TEXTURE_2D,0,n.RGBA,A.size,A.size,0,n.RGBA,n.UNSIGNED_BYTE,A.data),n.texParameteri(n.TEXTURE_2D,n.TEXTURE_WRAP_S,n.CLAMP_TO_EDGE),n.texParameteri(n.TEXTURE_2D,n.TEXTURE_WRAP_T,n.CLAMP_TO_EDGE),n.texParameteri(n.TEXTURE_2D,n.TEXTURE_MIN_FILTER,n.LINEAR),n.texParameteri(n.TEXTURE_2D,n.TEXTURE_MAG_FILTER,n.LINEAR),L=!1))}function re(n){let r=W;e.sim&&(r+=w.hasSim),$&&(r+=w.scroll),G&&(r+=w.impulses),z&&(r+=w.obstacles),F&&(r+=w.glyph);const o=e.sim?`uniform sampler2D uSim;
uniform vec2 uSimResolution;
`:"",m=(e.textures??[]).map(h=>`uniform sampler2D ${h.name};`).join(`
`),l=x?`${r}${o}${m}
${j}
${K}
${Y}
${q}
${e.body}
${ce}`:`${W}
${j}
${K}
${Y}
${q}
${e.body}
${ce}`;u=g(n,l,e.id),u&&(x?E=se(n,u):f={uResolution:n.getUniformLocation(u,"uResolution"),uTime:n.getUniformLocation(u,"uTime"),uPointer:n.getUniformLocation(u,"uPointer"),uPointerActive:n.getUniformLocation(u,"uPointerActive"),uBg:n.getUniformLocation(u,"uBg"),uAccent0:n.getUniformLocation(u,"uAccent0"),uAccent1:n.getUniformLocation(u,"uAccent1"),uAccent2:n.getUniformLocation(u,"uAccent2"),uAccent3:n.getUniformLocation(u,"uAccent3"),uInk:n.getUniformLocation(u,"uInk"),uIntensity:n.getUniformLocation(u,"uIntensity"),uTheme:n.getUniformLocation(u,"uTheme")},a=n.createVertexArray())}function C(n){!t||!i||(t.uniform2f(n.uResolution,t.drawingBufferWidth,t.drawingBufferHeight),t.uniform1f(n.uTime,P),t.uniform2f(n.uPointer,U[0],U[1]),t.uniform1f(n.uPointerActive,p),t.uniform3fv(n.uBg,S(i.bg)),t.uniform3fv(n.uAccent0,S(i.accents[0]??i.ink)),t.uniform3fv(n.uAccent1,S(i.accents[1]??i.ink)),t.uniform3fv(n.uAccent2,S(i.accents[2]??i.ink)),t.uniform3fv(n.uAccent3,S(i.accents[3]??i.ink)),t.uniform3fv(n.uInk,S(i.ink)),t.uniform1f(n.uIntensity,i.intensity),t.uniform1f(n.uTheme,i.theme==="light"?1:0))}function N(n,r){t&&(t.uniform1f(n.uHasSim,r),$&&(t.uniform2f(n.uScroll,I.y,I.yMax),t.uniform1f(n.uScrollVel,I.vy)),G&&(t.uniform4fv(n.uImpulses,v),t.uniform1i(n.uImpulseCount,M)),z&&(t.uniform4fv(n.uObstacleRects,s),t.uniform1i(n.uObstacleCount,d)),F&&(t.uniform1f(n.uGlyphActive,A?1:0),t.uniform4f(n.uGlyphRect,B[0],B[1],B[2],B[3]),t.uniform1f(n.uGlyphPhase,ee)))}function X(n){let r=D.get(n);return!r&&t&&(r=se(t,n),D.set(n,r)),r??{}}function oe(n){if(!e.sim||!a)return;const r=pe(e.sim);c=Ae(n,r,b,n.drawingBufferWidth,n.drawingBufferHeight,e.id),c.stepProgram&&X(c.stepProgram),c.seedProgram&&X(c.seedProgram);const o=h=>C(X(h)),m=h=>{const V=X(h);C(V),N(V,1)};c.reseed(a,o);const l=e.sim.settleSteps??0;l>0&&c.settle(l,a,m)}function ie(n){if(!(!e.textures||!u||!E)){y.length=0;for(const r of e.textures){const o=n.createTexture();n.bindTexture(n.TEXTURE_2D,o),n.texImage2D(n.TEXTURE_2D,0,n.RGBA,1,1,0,n.RGBA,n.UNSIGNED_BYTE,new Uint8Array([0,0,0,255]));const m=r.wrap==="clamp"?n.CLAMP_TO_EDGE:n.REPEAT,l=r.filter==="nearest"?n.NEAREST:n.LINEAR;n.texParameteri(n.TEXTURE_2D,n.TEXTURE_WRAP_S,m),n.texParameteri(n.TEXTURE_2D,n.TEXTURE_WRAP_T,m),n.texParameteri(n.TEXTURE_2D,n.TEXTURE_MIN_FILTER,l),n.texParameteri(n.TEXTURE_2D,n.TEXTURE_MAG_FILTER,l);const h=new Image;h.onload=()=>{!t||!o||(t.bindTexture(t.TEXTURE_2D,o),t.texImage2D(t.TEXTURE_2D,0,t.RGBA,t.RGBA,t.UNSIGNED_BYTE,h))},h.src=r.dataUri,y.push({name:r.name,tex:o,loc:n.getUniformLocation(u,r.name)})}}}function J(){if(!(!t||!u))if(x&&E)t.useProgram(u),C(E);else{if(!i)return;t.useProgram(u),t.uniform3fv(f.uBg,S(i.bg)),t.uniform3fv(f.uAccent0,S(i.accents[0]??i.ink)),t.uniform3fv(f.uAccent1,S(i.accents[1]??i.ink)),t.uniform3fv(f.uAccent2,S(i.accents[2]??i.ink)),t.uniform3fv(f.uAccent3,S(i.accents[3]??i.ink)),t.uniform3fv(f.uInk,S(i.ink)),t.uniform1f(f.uIntensity,i.intensity),t.uniform1f(f.uTheme,i.theme==="light"?1:0)}}function Q(){t&&t.viewport(0,0,t.drawingBufferWidth,t.drawingBufferHeight)}function O(n,r){const o=t.drawingBufferHeight,m=o/(R?.clientHeight||o);return[n*m/t.drawingBufferWidth,1-r*m/o]}function Te(){let n=0;for(let r=0;r<M;r++){const o=v[r*4+3]+1;if(o<Ue){const m=r*4,l=n*4;v[l]=v[m],v[l+1]=v[m+1],v[l+2]=v[m+2],v[l+3]=o,n++}}M=n}return{id:e.id,label:e.label,substrate:"webgl2",init(n,r){t=n,i=r.palette,b=r.caps??ue,R=t.canvas,R.addEventListener("webglcontextlost",te,!1),R.addEventListener("webglcontextrestored",ne,!1),re(t),Q(),J(),x&&(oe(t),ie(t))},frame(n){if(!t||!u||_)return;if(P=n/1e3,U[0]+=(k[0]-U[0])*.08,U[1]+=(k[1]-U[1])*.08,!x||!E){t.useProgram(u),t.bindVertexArray(a),t.uniform2f(f.uResolution,t.drawingBufferWidth,t.drawingBufferHeight),t.uniform1f(f.uTime,P),t.uniform2f(f.uPointer,U[0],U[1]),t.uniform1f(f.uPointerActive,p),t.drawArrays(t.TRIANGLES,0,3),t.bindVertexArray(null);return}c?.ok&&c.step(a,m=>{const l=X(m);C(l),N(l,1)}),Te(),t.bindFramebuffer(t.FRAMEBUFFER,null),t.viewport(0,0,t.drawingBufferWidth,t.drawingBufferHeight),t.useProgram(u),t.bindVertexArray(a),C(E);const r=c?.ok?1:0;N(E,r);let o=0;if(r&&c){const m=c.current();m&&(t.activeTexture(t.TEXTURE0+o),t.bindTexture(t.TEXTURE_2D,m),t.uniform1i(E.uSim,o),t.uniform2f(E.uSimResolution,c.simW,c.simH),o++)}for(const m of y)m.tex&&(t.activeTexture(t.TEXTURE0+o),t.bindTexture(t.TEXTURE_2D,m.tex),m.loc&&t.uniform1i(m.loc,o),o++);F&&(L&&de(t),T&&(t.activeTexture(t.TEXTURE0+o),t.bindTexture(t.TEXTURE_2D,T),t.uniform1i(E.uGlyphField,o),o++)),t.drawArrays(t.TRIANGLES,0,3),t.bindVertexArray(null)},resize(){if(Q(),x&&c&&(c.resize(t.drawingBufferWidth,t.drawingBufferHeight),a)){const n=o=>C(X(o));c.reseed(a,n);const r=e.sim?.settleSteps??0;r>0&&c.settle(r,a,n)}},setTheme(n,r){i=r,J()},pointer(n,r,o){t&&(k=O(n,r),p=o?1:0)},click(n,r){if(!t||!G)return;const[o,m]=O(n,r);let l;M<Z?l=M++:(v.copyWithin(0,4),l=Z-1);const h=l*4;v[h]=o,v[h+1]=m,v[h+2]=1,v[h+3]=0},obstacles(n){if(!(!t||!z)){d=Math.min(n.length,Ee);for(let r=0;r<d;r++){const o=n[r],[m,l]=O(o.x,o.y),[h,V]=O(o.x+o.w,o.y+o.h),H=r*4;s[H]=m,s[H+1]=V,s[H+2]=h,s[H+3]=l}}},scroll(n,r,o){$&&(I.y=n,I.vy=r,I.yMax=o)},setGlyphField(n){if(F)if(A=n,n){const r=n.content.x+n.content.w*.5,o=n.content.y+n.content.h*.5;B[0]=r,B[1]=1-o,B[2]=n.content.w*.5,B[3]=n.content.h*.5,ee=1,L=!0}else L=!1,t&&T&&(t.deleteTexture(T),T=null)},renderStatic(){if(!x){this.frame(0,0);return}if(c?.ok&&a){const n=r=>{const o=X(r);C(o),N(o,1)};c.reseed(a,r=>C(X(r))),c.settle(e.sim?.settleSteps??0,a,n)}this.frame(0,0)},dispose(){if(R&&(R.removeEventListener("webglcontextlost",te),R.removeEventListener("webglcontextrestored",ne)),t){if(x){c?.dispose(),c=null;for(const n of y)n.tex&&t.deleteTexture(n.tex);y.length=0,D.clear()}T&&(t.deleteTexture(T),T=null),u&&t.deleteProgram(u),a&&t.deleteVertexArray(a),t.getExtension("WEBGL_lose_context")?.loseContext()}t=null,u=null,a=null,f=null,E=null,i=null,R=null,A=null}}}function pe(e){return{step:e.step,seed:e.seed,format:e.format??"RGBA16F",scale:e.scale??.5,stepsPerFrame:e.stepsPerFrame??1}}export{Pe as c};

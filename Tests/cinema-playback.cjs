const fs=require('fs'),path=require('path'),vm=require('vm'),assert=require('assert');
const source=fs.readFileSync(path.resolve(__dirname,'../HandARBrowser/MainViewController.swift'),'utf8');
const part=source.split('private static func directVideoRoleScript(role: String) -> String {')[1];
assert(part);const template=part.split('return """')[1].split('        """')[0];
let checks=0;function check(value,message){checks++;assert(value,message)}
function fixture(role='left'){
 let now=0,starts=0,pauses=0,seeks=0,time=5,failure=null;
 const intervals=[],timeouts=[],listeners={},styles=[],mutingAtPlay=[];
 const video={clientWidth:500,clientHeight:300,paused:true,muted:false,defaultMuted:false,volume:1,
  readyState:4,duration:100,seeking:false,ended:false,playbackRate:1,style:{setProperty(){}},setAttribute(){},
  seekable:{length:1,start(){return 0},end(){return 100}},
  play(){starts++;mutingAtPlay.push(this.muted);if(!failure)this.paused=false;
   return {then(resolve,reject){failure?reject({name:failure}):resolve()}}},
  pause(){pauses++;this.paused=true}
 };
 Object.defineProperty(video,'currentTime',{get(){return time},set(value){time=value;seeks++}});
 const context={Date:{now(){return now}},window:{addEventListener(name,fn){listeners[name]=fn}},
  document:{hidden:false,querySelectorAll(){return [video]},createElement(){return {}},
   documentElement:{classList:{add(){}}},head:{appendChild(style){styles.push(style.textContent)}},
   addEventListener(name,fn){listeners[name]=fn}},
  MutationObserver:class{observe(){}disconnect(){}},requestAnimationFrame(){},
  setInterval(fn){intervals.push(fn)},setTimeout(fn){timeouts.push(fn)}};
 vm.createContext(context);
 vm.runInContext(template.replaceAll('\\(role)',role).replaceAll('\\(muted)',role==='right'?'true':'false'),context);
 return {v:video,w:context.window,doc:context.document,listeners,styles,mutingAtPlay,
  tick(ms=1600){now+=ms;intervals.forEach(fn=>fn())},
  run(script){vm.runInContext(script,context)},runTimeouts(){timeouts.splice(0).forEach(fn=>fn())},
  get starts(){return starts},get pauses(){return pauses},get seeks(){return seeks},
  failure(value){failure=value},state(){return JSON.parse(context.window.__handarDirectState())},
  master(overrides={}){return {t:20,p:false,w:true,s:1,r:4,d:100,q:false,...overrides}}};
}
for(const role of ['left','right']){
 const f=fixture(role);f.w.__handarDirectPlay();
 check(f.v.muted===(role==='right'),'only left eye has audio');
 check(f.v.volume===(role==='right'?0:1),'slave volume is zero');
 check(f.starts===1&&f.mutingAtPlay[0]===(role==='right'),'role is configured before first play');
 for(let i=0;i<20;i++)f.tick();
 check(f.starts===1,'playing video is not repeatedly restarted by timer');
 check(!f.styles.join('').includes('body *{visibility:hidden'),'player ancestors must stay visible to the site');
}
{
 const f=fixture();f.w.__handarDirectPlay();f.v.pause();const time=f.v.currentTime;f.tick();
 check(!f.v.paused&&f.starts===2,'unexpected site pause resumes once');
 check(f.v.currentTime===time&&f.seeks===0,'recovering a pause preserves playback position');
 f.w.__handarSetPlaybackIntent(false);f.v.pause();for(let i=0;i<8;i++)f.tick();
 check(f.v.paused&&f.starts===2,'explicit pause survives watchdog and finger interaction');
 f.w.__handarDirectPlay();check(!f.v.paused,'explicit play rearms recovery');
 f.v.muted=true;f.v.volume=0.4;f.tick();
 check(f.v.muted&&f.v.volume===0.4,'timer preserves master mute and selected volume');
 f.doc.hidden=true;f.v.pause();f.tick();check(f.v.paused,'background document is not forcibly played');
 f.doc.hidden=false;f.tick();check(!f.v.paused,'visible document can recover');
 f.v.ended=true;f.v.pause();f.tick();
 check(f.v.paused&&f.state().w===false,'ended movie does not automatically restart');
}
{
 const f=fixture();f.failure('NotAllowedError');f.w.__handarDirectPlay();
 check(f.state().b===true,'autoplay rejection is surfaced');
 for(let i=0;i<8;i++)f.tick();check(f.starts===1,'autoplay rejection is not retried in a loop');
 f.failure(null);f.w.__handarDirectPlay();check(f.starts===2&&!f.v.paused&&!f.state().b,'explicit play retries rejected autoplay');
}
{
 const f=fixture('right');f.w.__handarSyncDirectVideo(f.master());
 check(f.v.currentTime===20&&f.seeks===1,'loaded matching timelines can resynchronize');
 check(f.v.muted&&!f.v.paused,'slave recovery remains silent');
 for(let i=0;i<4;i++)f.w.__handarSyncDirectVideo(f.master());
 check(f.seeks===1&&f.starts===1,'repeated samples do not restart or seek');
 f.v.currentTime=5;const count=f.seeks;f.w.__handarSyncDirectVideo(f.master());
 check(f.seeks===count,'seek cooldown prevents buffer reset storms');
 f.tick(2100);f.w.__handarSyncDirectVideo(f.master());check(f.v.currentTime===20,'large drift can be corrected after cooldown');
 f.w.__handarSyncDirectVideo(f.master({p:true,w:true}));
 check(!f.v.paused,'temporary master pause does not freeze the slave');
 f.w.__handarSyncDirectVideo(f.master({p:true,w:false}));
 for(let i=0;i<5;i++)f.tick();check(f.v.paused,'intentional master pause propagates and stays paused');
 f.w.__handarSyncDirectVideo(f.master({p:true,w:true,b:true}));
 check(f.v.paused,'autoplay rejection in master does not leave one eye running');
}
for(const kind of ['master-buffer','slave-buffer','seeking','master-seeking','advertisement','live','unseekable','small-drift']){
 const f=fixture('right'),master=f.master();
 if(kind==='master-buffer')master.r=2;
 if(kind==='slave-buffer')f.v.readyState=2;
 if(kind==='seeking')f.v.seeking=true;
 if(kind==='master-seeking')master.q=true;
 if(kind==='advertisement')f.v.duration=30;
 if(kind==='live')f.v.duration=Infinity;
 if(kind==='unseekable')f.v.seekable.length=0;
 if(kind==='small-drift')master.t=5.4;
 f.w.__handarSyncDirectVideo(master);check(f.seeks===0,kind+' must not trigger a seek');
}
{
 const f=fixture();f.w.__handarDirectPlay();
 const target={closest(){return this},getAttribute(){return 'Pause (k)'},matches(){return true}};
 f.listeners.click({isTrusted:true,target});f.v.pause();f.tick();
 check(f.v.paused&&!f.state().w,'site pause button is respected');
 f.listeners.click({isTrusted:false,handarConfirmed:true,target});f.v.play();f.tick();
 check(!f.v.paused&&f.state().w,'hand click on site play button restores intent');
}
{
 const f=fixture();f.w.__handarDirectPlay();
 const stop=source.match(/private func pauseAndMute\(_ webView:[\s\S]*?evaluateJavaScript\("([^"]+)"/);
 assert(stop,'native stop script must be available');f.run(stop[1]);f.runTimeouts();
 for(let i=0;i<5;i++)f.tick();
 check(f.v.paused&&f.v.muted&&!f.state().w&&f.starts===1,'exiting cinema cancels recovery and delayed autoplay');
}
console.log(`PASS: ${checks} cinema playback continuity, intent, visibility and synchronization checks`);

const input=fs.readFileSync(path.resolve(__dirname,'../HandARBrowser/WebInput.js'),'utf8');
const begin=input.indexOf('  function playbackVideo()');assert(begin>=0);
const movie={clientWidth:960,clientHeight:540,duration:100,currentTime:50,paused:false,volume:0.6,play(){this.paused=false;return Promise.resolve()},pause(){this.paused=true}};
const small={clientWidth:20,clientHeight:20,duration:10,currentTime:0};
const intents=[];
const pc={window:{__handarSetPlaybackIntent(value){intents.push(value)}},document:{querySelectorAll(){return [small,movie]}}};vm.createContext(pc);
vm.runInContext('(function(){'+input.slice(begin),pc);
pc.window.__handarSeekVideo(10,false);assert.equal(movie.currentTime,60);assert.equal(small.currentTime,0);
pc.window.__handarSeekVideo(-1000,false);assert.equal(movie.currentTime,0);
pc.window.__handarSeekVideo(1000,false);assert.equal(movie.currentTime,100);
pc.window.__handarSeekVideo(NaN,false);assert.equal(movie.currentTime,100);
pc.window.__handarSeekVideo(0,true);assert.equal(movie.currentTime,0);assert.equal(movie.paused,false);assert.equal(intents.at(-1),true);
pc.window.__handarTogglePlay();assert.equal(movie.paused,true);assert.equal(intents.at(-1),false);
pc.window.__handarSetVolume(-0.15);assert(Math.abs(movie.volume-0.45)<1e-9);
console.log('PASS: cinema web seek, restart, largest-video selection, explicit pause intent and volume');

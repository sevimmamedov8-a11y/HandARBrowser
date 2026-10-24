const fs=require('fs'),path=require('path'),vm=require('vm'),assert=require('assert');
const root=path.resolve(__dirname,'..');
const swift=fs.readFileSync(path.join(root,'HandARBrowser/MainViewController.swift'),'utf8');
const web=fs.readFileSync(path.join(root,'HandARBrowser/WebInput.js'),'utf8');
const role=swift.split('private static func directVideoRoleScript(role: String) -> String {')[1].split('return """')[1].split('        """')[0].replaceAll('\\(role)','left').replaceAll('\\(muted)','false');
const media=web.slice(web.indexOf('  function playbackVideo()'));
let checks=0;function check(value,label){checks++;assert(value,label)}
function fixture(){
 let now=1,plays=0,pauses=0,muted=true,pauseOnUnmute=false,removed=0;
 const timers=[],video={clientWidth:960,clientHeight:540,paused:false,defaultMuted:true,volume:0,
  currentTime:12,duration:100,playbackRate:1,readyState:4,seeking:false,ended:false,
  setAttribute(){},removeAttribute(name){if(name==='muted')removed++},
  play(){plays++;this.paused=false;return Promise.resolve()},pause(){pauses++;this.paused=true}};
 Object.defineProperty(video,'muted',{get(){return muted},set(value){const old=muted;muted=value;if(old&&!value&&pauseOnUnmute)video.paused=true}});
 const context={window:{addEventListener(){}},Date:{now(){return now}},
  document:{hidden:false,querySelector(){return null},querySelectorAll(selector){return selector==='audio'?[]:[video]},addEventListener(){},createElement(){return {}},
   head:{appendChild(){}},documentElement:{classList:{add(){},remove(){}}}},MutationObserver:class{observe(){}disconnect(){}},
  requestAnimationFrame(){},setInterval(fn){timers.push(fn)},setTimeout(){}};
 vm.createContext(context);vm.runInContext('(function(){'+media,context);vm.runInContext(role,context);
 return {w:context.window,v:video,tick(){now+=1600;timers.forEach(f=>f())},pauseOnUnmute(value){pauseOnUnmute=value},get plays(){return plays},get removed(){return removed}};
}
{
 const f=fixture();f.w.__handarSetVolume(0.15);
 check(!f.v.muted&&!f.v.defaultMuted&&Math.abs(f.v.volume-0.15)<1e-9,'+ sound clears mute, the muted attribute and zero volume');
 check(f.removed===1&&f.plays===0,'an already playing movie is not restarted to enable audio');
 check(f.v.currentTime===12,'audio changes preserve movie position');
 const state=JSON.parse(f.w.__handarDirectState());
 check(state.m===false&&state.v===f.v.volume,'native hall receives actual mute and volume state');
}
{
 const f=fixture();f.v.paused=true;f.w.__handarSetPlaybackIntent(false);f.w.__handarSetVolume(0.15);
 check(f.v.paused&&f.plays===0,'enabling volume preserves an explicit pause');
 const before=f.v.volume;f.w.__handarSetVolume(NaN);f.w.__handarSetVolume(Infinity);
 check(f.v.volume===before,'invalid volume changes are ignored');
}
{
 const f=fixture();f.v.volume=0.5;f.w.__handarSetVolume(-0.15);
 check(f.v.muted&&Math.abs(f.v.volume-0.35)<1e-9,'turning volume down never unmutes a silent player');
}
{
 const f=fixture();f.v.paused=true;f.w.__handarSetPlaybackIntent(false);
 check(f.w.__handarTogglePlay()==='play','explicit play is accepted');
 check(!f.v.muted&&!f.v.defaultMuted&&f.v.volume===0.65&&f.plays===1,'explicit play restores one audible source once');
 f.w.__handarTogglePlay();check(f.v.paused,'pause still works');
 for(let i=0;i<4;i++)f.tick();check(f.v.paused&&f.plays===1,'audio recovery does not override manual pause');
}
{
 const f=fixture();f.v.volume=0.4;f.pauseOnUnmute(true);f.w.__handarSetVolume(0.15);
 check(!f.v.paused&&!f.v.muted&&f.plays===1,'WebKit-style pause during unmute recovers once');
 check(f.v.currentTime===12,'recovery does not seek or restart the movie');
}
{
 const f=fixture();f.w.__handarCinemaSurface=true;
 f.tick();check(!f.v.muted&&f.v.volume>0,'first ready cinema video gets one audible startup attempt');
 f.v.muted=true;f.v.volume=0.3;for(let i=0;i<5;i++)f.tick();
 check(f.v.muted&&f.v.volume===0.3,'watchdog respects later manual mute and selected volume');
 f.w.__handarSetVolume(0.15);check(!f.v.muted,'sound button can restore a site-muted source later');
}
{
 const f=fixture();f.w.__handarCinemaSurface=true;f.w.__handarSetVolume(-0.15);f.tick();
 check(f.v.muted&&f.v.volume===0,'initial startup does not undo explicit zero volume');
}
{
 const f=fixture();f.w.__handarBrowseOnly=true;f.tick();
 check(f.v.muted&&f.v.volume===0,'normal browsing never forces audio on');
 f.w.__handarSetVolume(0.15);check(!f.v.muted,'an explicit sound request also works in a browser window');
}
console.log(`PASS: ${checks} source audio, mute/zero-volume recovery, explicit controls, pause and startup checks`);

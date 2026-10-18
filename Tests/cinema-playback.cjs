const fs=require('fs'),path=require('path'),vm=require('vm'),assert=require('assert');
const source=fs.readFileSync(path.resolve(__dirname,'../HandARBrowser/MainViewController.swift'),'utf8');
const part=source.split('private static func directVideoRoleScript(role: String) -> String {')[1];
assert(part);const template=part.split('return """')[1].split('        """')[0];
for(const role of ['left','right']){
 let starts=0;
 const video={clientWidth:500,clientHeight:300,style:{setProperty(){}},setAttribute(){},play(){starts++;return Promise.resolve()}};
 const context={window:{},document:{querySelectorAll(){return [video]},createElement(){return {}},head:{appendChild(){}}},setInterval(){},setTimeout(){}};
 vm.createContext(context);
 const script=template.replaceAll('\\(role)',role).replaceAll('\\(muted)',role==='right'?'true':'false');
 vm.runInContext(script,context);
 context.window.__handarTuneDirectVideo();context.window.__handarDirectPlay();
 assert.equal(video.muted,role==='right','only the left eye has audio');
 assert.equal(video.volume,role==='right'?0:1);assert.equal(starts,1);
}
console.log('PASS: left/right eye autoplay and audio isolation');

const input=fs.readFileSync(path.resolve(__dirname,'../HandARBrowser/WebInput.js'),'utf8');
const begin=input.indexOf('  function playbackVideo()');assert(begin>=0);
const movie={clientWidth:960,clientHeight:540,duration:100,currentTime:50,paused:false,volume:0.6,play(){this.paused=false;return Promise.resolve()},pause(){this.paused=true}};
const small={clientWidth:20,clientHeight:20,duration:10,currentTime:0};
const pc={window:{},document:{querySelectorAll(){return [small,movie]}}};vm.createContext(pc);
vm.runInContext('(function(){'+input.slice(begin),pc);
pc.window.__handarSeekVideo(10,false);assert.equal(movie.currentTime,60);assert.equal(small.currentTime,0);
pc.window.__handarSeekVideo(-1000,false);assert.equal(movie.currentTime,0);
pc.window.__handarSeekVideo(1000,false);assert.equal(movie.currentTime,100);
pc.window.__handarSeekVideo(NaN,false);assert.equal(movie.currentTime,100);
pc.window.__handarSeekVideo(0,true);assert.equal(movie.currentTime,0);assert.equal(movie.paused,false);
pc.window.__handarTogglePlay();assert.equal(movie.paused,true);
pc.window.__handarSetVolume(-0.15);assert(Math.abs(movie.volume-0.45)<1e-9);
console.log('PASS: cinema web seek, restart, largest-video selection, pause and volume');

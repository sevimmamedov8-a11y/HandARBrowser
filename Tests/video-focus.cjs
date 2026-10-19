const fs=require('fs'),path=require('path'),vm=require('vm'),assert=require('assert');
const source=fs.readFileSync(path.join(__dirname,'../HandARBrowser/WebInput.js'),'utf8');
let checks=0;function check(value,label){checks++;assert(value,label)}
class Node {
 constructor(){this.children=[];this.classes=new Set();this.dataset={};this.listeners={};this.classList={add:c=>this.classes.add(c),remove:c=>this.classes.delete(c)}}
 setAttribute(){}
 appendChild(node){if(!this.children.includes(node))this.children.push(node)}
 querySelector(selector){const action=selector.match(/data-action="(.*?)"/)[1];return this.children.find(n=>n.dataset.action===action)}
 addEventListener(name,fn){this.listeners[name]=fn}
}
class Video extends Node {
 constructor(){super();this.paused=false;this.ended=false;this.readyState=4;this.muted=true;this.defaultMuted=true;this.volume=0;this.isConnected=true;this.currentTime=20;this.duration=100;this.clientWidth=600;this.clientHeight=340;this.plays=0;this.container=new Node()}
 closest(){return this.container}
 removeAttribute(){}
 getBoundingClientRect(){return {left:0,top:0,right:600,bottom:340}}
 play(){this.plays++;this.paused=false;return Promise.resolve()}
 pause(){this.paused=true}
}
function fixture(){
 const v=new Video(),feedback=[],location={hostname:'www.youtube.com',pathname:'/',search:''};
 const document={hidden:false,documentElement:new Node(),body:new Node(),createElement:()=>new Node(),querySelectorAll:()=>v.isConnected?[v]:[]};
 const w={innerWidth:1280,innerHeight:720,__handarBrowseOnly:true,webkit:{messageHandlers:{handarFeedback:{postMessage:m=>feedback.push(m)}}}};
 const ctx={window:w,document,location,HTMLVideoElement:Video,postVideoState(){}};vm.createContext(ctx);
 vm.runInContext('(function(){'+source.slice(source.indexOf('  function playbackVideo()')),ctx);
 vm.runInContext(source.slice(source.indexOf('  function viewportCoverage('),source.indexOf('  function evaluateVideoState()')),ctx);
 vm.runInContext(source.slice(source.indexOf('  const handarPatchedVideos'),source.indexOf('  function patchVideo(video)'))+'\nwindow.focus=autoFocusPlayingVideo;window.exit=exitInlineFullscreen;',ctx);
 return {v,w,location,document,feedback,tools:()=>document.documentElement.children.find(n=>n.className==='handar-video-tools'),click(action){this.tools().querySelector('[data-action="'+action+'"]').listeners.click({preventDefault(){},stopPropagation(){}})}};
}
{
 const f=fixture();f.w.focus();check(!f.tools()&&f.v.muted,'home previews stay silent and inline');
 f.location.pathname='/watch';f.location.search='?v=first';f.w.focus();
 check(!!f.tools()&&!f.tools().hidden,'watch video automatically fills its existing window');
 check(f.v.container.classes.has('handar-inline-video-fullscreen'),'focus uses source container');
 check(!f.v.muted&&f.v.volume>0&&!f.v.defaultMuted,'menu video gets audible startup');
 check(f.feedback.filter(m=>m.type==='media-audio').length===1,'requests native activation once');
 check(f.v.plays===0&&f.v.currentTime===20,'focus does not restart playing media');
 f.v.muted=true;f.w.focus();f.w.focus();check(f.v.muted,'later manual mute is respected');
 f.click('sound');check(!f.v.muted,'sound control restores muted source');
 f.click('play');f.w.focus();check(f.v.paused,'manual pause survives focus evaluation');
 f.click('next');check(f.v.currentTime===30&&f.v.paused,'relative seek preserves pause');
 f.click('back');check(f.v.currentTime===20,'rewind is relative');
 f.click('play');check(!f.v.paused,'explicit resume works');
 f.click('page');for(let i=0;i<5;i++)f.w.focus();
 check(f.tools().hidden&&!f.v.container.classes.has('handar-inline-video-fullscreen'),'dismissal persists on the same video');
 check(!f.v.paused,'returning to page preserves playback');
 f.location.search='?v=second';f.w.focus();check(!f.tools().hidden,'SPA next video can open again');
 f.v.isConnected=false;f.w.focus();check(f.tools().hidden,'removed video cleans up focus');
}
{
 const f=fixture();f.location.pathname='/watch';f.document.hidden=true;f.w.focus();check(!f.tools(),'hidden pages never steal focus');
 f.document.hidden=false;f.v.paused=true;f.w.focus();check(!f.tools(),'paused media does not auto-open');
 f.v.paused=false;f.w.__handarCinemaSurface=true;f.w.focus();check(!f.tools(),'3D hall keeps its own presentation');
 f.w.__handarCinemaSurface=false;f.w.__handarSetVolume(-0.1);f.w.focus();check(f.v.volume===0&&f.v.muted,'explicit silence survives autofocus');
}
{
 const callbacks=[],doc={head:null,documentElement:null};let installed=0;
 const ctx={document:doc,fullscreenStyle:{},requestAnimationFrame:fn=>callbacks.push(fn)};vm.createContext(ctx);
 vm.runInContext(source.slice(source.indexOf('  function installFullscreenStyle()'),source.indexOf('  if (Element.prototype.requestFullscreen)')),ctx);
 check(callbacks.length===1,'document-start with no HTML root waits instead of throwing');
 doc.documentElement={appendChild(){installed++}};callbacks.shift()();check(installed===1,'style installs once root exists');
}
console.log(`PASS: ${checks} menu audio, video focus, controls, preview isolation, SPA and document-start checks`);

const fs=require('fs'),vm=require('vm'),assert=require('assert'),path=require('path');
const source=fs.readFileSync(path.resolve(__dirname,'../HandARBrowser/WebInput.js'),'utf8').split('  // --- Кинорежим:')[0]+'})();';
function fixture(){
  const listeners={},pending=[],root={scrollTop:0};let current,feedbacks=0,now=0,timerID=0;const timers=new Map(),rings=[];
  class Node {
    constructor(name,clickable=true){this.name=name;this.clickable=clickable;this.parentElement=null;this.disabled=false;this.isConnected=true;this.scrollHeight=0;this.clientHeight=0;this.scrollTop=0;this.overflowY='visible';this.events=[];this.classes=new Set();this.classList={add:c=>this.classes.add(c),remove:c=>this.classes.delete(c)};}
    closest(){for(let n=this;n;n=n.parentElement)if(n.clickable)return n;return null;}
    getAttribute(name){return name==='aria-disabled'&&this.ariaDisabled?'true':null;}
    dispatchEvent(event){this.events.push(event.type);if(event.type==='click')listeners.click?.(Object.assign(event,{target:this}));return true;}
    get clicks(){return this.events.filter(e=>e==='click').length;}
  }
  class Event {constructor(type,options){this.type=type;Object.assign(this,options)}}
  const context={window:{webkit:{messageHandlers:{handarFeedback:{postMessage(){feedbacks++}}}}},performance:{now:()=>now},document:{documentElement:{appendChild(n){rings.push(n)}},createElement(){return {style:{},setAttribute(){}}},elementFromPoint(){return current},scrollingElement:root,addEventListener(type,fn){listeners[type]=fn}},getComputedStyle:n=>({overflowY:n.overflowY}),PointerEvent:Event,MouseEvent:Event,setTimeout(fn,ms){const id=++timerID;timers.set(id,{fn,at:now+ms});return id},clearTimeout(id){timers.delete(id)}};
  vm.createContext(context);vm.runInContext(source,context);
  return {w:context.window,Node,root,rings,select(n){current=n},tick(ms){now+=ms;for(const [id,t] of timers){if(t.at<=now){timers.delete(id);t.fn()}}},get sounds(){return feedbacks}};
}
let checks=0;function check(value,msg){checks++;assert(value,msg)}
{
 const f=fixture(),a=new f.Node('a');f.select(a);
 f.w.__handarPointerUp(0,0,1);check(a.clicks===0&&f.sounds===0,'orphan release is never a click');
 f.w.__handarPointerDown(10,10,1);f.w.__handarPointerDown(10,10,1);f.w.__handarPointerUp(10,10,1);f.w.__handarPointerUp(10,10,1);
 check(a.clicks===1&&f.sounds===1,'one click and sound per complete cycle');
 f.w.__handarPointerDown(10,10,1);f.w.__handarPointerCancel(10,10,1);f.w.__handarPointerUp(10,10,1);
 check(a.clicks===1&&f.sounds===1,'lost tracking cancels even if a release arrives later');
}
{
 const f=fixture(),a=new f.Node('a');f.select(a);
 f.w.__handarPointerDown(20,20,1,14);
 for(const [x,y] of [[22,23],[18,19],[21,18],[20,20]])f.w.__handarPointerMove(x,y,1);
 f.w.__handarPointerUp(21,21,1);
 check(a.clicks===1&&f.root.scrollTop===0,'small tremor clicks without scrolling');
 f.w.__handarPointerDown(20,20,1,14);f.w.__handarPointerMove(20,60,1);f.w.__handarPointerMove(20,20,1);f.w.__handarPointerUp(20,20,1);
 check(a.clicks===1&&f.sounds===1,'drag returning to origin stays cancelled');
}
{
 const f=fixture(),a=new f.Node('a'),b=new f.Node('b');f.select(a);
 f.w.__handarPointerDown(10,10,1,18);f.select(b);f.w.__handarPointerUp(11,10,1);
 check(a.clicks===0&&b.clicks===0&&f.sounds===0,'release on a neighbor cannot click either target');
 f.select(a);f.w.__handarPointerDown(10,10,1,18);f.select(b);f.w.__handarPointerMove(11,10,1);f.select(a);f.w.__handarPointerUp(10,10,1);
 check(a.clicks===0&&f.sounds===0,'leaving and returning cancels even inside distance slop');
}
{
 const f=fixture(),a=new f.Node('button'),icon=new f.Node('svg',false),label=new f.Node('text',false);icon.parentElement=label.parentElement=a;f.select(icon);
 f.w.__handarPointerDown(10,10,1);f.select(label);f.w.__handarPointerUp(11,10,1);
 check(a.clicks===1&&f.sounds===1,'different children of the same button remain one target');
 f.select(a);f.w.__handarPointerDown(10,10,1);a.isConnected=false;f.w.__handarPointerUp(10,10,1);
 check(a.clicks===1&&f.sounds===1,'removed/replaced DOM cannot receive stale click');
}
{
 const f=fixture(),a=new f.Node('disabled');a.disabled=true;f.select(a);f.w.__handarPointerDown(0,0,1);f.w.__handarPointerUp(0,0,1);
 check(a.clicks===0&&f.sounds===0,'disabled target never confirms');
 a.disabled=false;a.ariaDisabled=true;f.w.__handarPointerDown(0,0,1);f.w.__handarPointerUp(0,0,1);
 check(a.clicks===0&&f.sounds===0,'aria-disabled target never confirms');
}
{
 const f=fixture(),panel=new f.Node('scroll panel',false),a=new f.Node('row');panel.scrollHeight=1000;panel.clientHeight=200;panel.overflowY='auto';a.parentElement=panel;f.select(a);
 f.w.__handarPointerDown(0,0,1,12);f.w.__handarPointerMove(0,30,1);f.w.__handarPointerMove(0,50,1);f.w.__handarPointerUp(0,50,1);
 check(panel.scrollTop===130&&f.root.scrollTop===0,'scroll reaches the inner panel with accumulated motion');
 check(a.clicks===0&&f.sounds===0,'scroll never clicks or sounds');
}
{
 const f=fixture(),a=new f.Node('a');f.select(a);f.w.__handarPointerDown(0,0,1);f.w.__handarPointerCancel(0,0,1);
 f.w.__handarPointerMove(100,100,1);f.w.__handarPointerUp(100,100,1);
 check(a.clicks===0&&f.root.scrollTop===0,'post-cancel moves cannot revive a gesture');
 f.w.__handarPointerDown(0,0,1);f.w.__handarPointerUp(0,0,1);check(a.clicks===1&&f.sounds===1,'next confirmed cycle works after cancellation');
}
{
 const f=fixture(),a=new f.Node('Safari'),b=new f.Node('neighbor');f.select(a);
 function frames(n){for(let i=0;i<n;i++){f.w.__handarDwell(30,30);f.tick(50)}}
 frames(20);check(a.clicks===0,'dwell cannot click before one second');
 frames(2);check(a.clicks===1&&f.sounds===1,'one-second dwell uses confirmed feedback');
 frames(35);check(a.clicks===1,'continued hover cannot repeat');
 f.select(b);frames(12);f.select(a);frames(22);check(a.clicks===2&&b.clicks===0,'switching targets restarts full dwell');
 f.w.__handarCancelDwell();frames(10);f.tick(350);frames(12);check(a.clicks===2,'missing fresh hand frames cancels incomplete dwell');
 check(f.rings.length===1,'progress ring is reused');
 f.w.__handarCancelDwell();check(f.rings[0].style.display==='none','hand loss hides progress ring');
 frames(15);f.w.__handarPointerDown(30,30,1,12,true);frames(10);f.w.__handarPointerUp(30,30,1);
 check(a.clicks===2,'pinch in dwell mode cannot finish dwell or synthesize a second click');
 f.w.__handarClearHover();a.disabled=true;frames(30);check(a.clicks===2,'disabled button cannot dwell-click');
 a.disabled=false;a.isConnected=false;frames(30);check(a.clicks===2,'removed target cannot dwell-click');
 a.isConnected=true;f.select(new f.Node('blank',false));frames(30);check(a.clicks===2,'blank page has no dwell action');
}
console.log(`PASS: ${checks} web gesture lifecycle checks`);

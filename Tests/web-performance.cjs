const fs=require('fs'),vm=require('vm'),assert=require('assert'),path=require('path');
const source=fs.readFileSync(path.resolve(__dirname,'../HandARBrowser/WebInput.js'),'utf8');
let mutationCallback,queue=[],evaluations=0;
const ctx={MutationObserver:class{constructor(callback){mutationCallback=callback}},requestAnimationFrame(fn){queue.push(fn)},document:{hidden:false},evaluateVideoState(){evaluations++}};
vm.createContext(ctx);
const begin=source.indexOf('  let evaluationPending = false;');
const end=source.indexOf('  function startObservingWhenReady()',begin);
assert(begin>=0&&end>begin);vm.runInContext(source.slice(begin,end),ctx);
for(let i=0;i<100;i++)mutationCallback();
assert.equal(queue.length,1,'100 DOM mutations schedule one layout evaluation');
queue.shift()();assert.equal(evaluations,1);
mutationCallback();ctx.document.hidden=true;queue.shift()();assert.equal(evaluations,1,'hidden document avoids geometry reads');
ctx.document.hidden=false;mutationCallback();queue.shift()();assert.equal(evaluations,2,'evaluation resumes after hidden state');
let added=[];
const pc={MutationObserver:class{constructor(callback){mutationCallback=callback}},patchVideos(node){added.push(node)}};
vm.createContext(pc);
const a=source.indexOf('  const videoObserver = new MutationObserver('),b=source.indexOf('  function startVideoObserver()',a);
assert(a>=0&&b>a);vm.runInContext(source.slice(a,b),pc);
const first={},second={};mutationCallback([{addedNodes:[first]},{addedNodes:[second]}]);
assert.deepEqual(added,[first,second],'patch only added subtrees');
console.log('PASS: mutation coalescing, hidden-page handling and incremental video patching');

const signalSource=source.slice(source.indexOf('  function startDesktopSnapshotSignals()'),source.lastIndexOf('})();'));
let signals=0,scheduled=[],changedMenu;
const menuContext={document:{readyState:'complete',hidden:false,documentElement:{},querySelector(){return {}}},
 window:{webkit:{messageHandlers:{handarFeedback:{postMessage(message){assert.equal(message.type,'menu-snapshot');signals++}}}}},
 setTimeout(fn){scheduled.push(fn)},MutationObserver:class{constructor(fn){changedMenu=fn}observe(){}}};
vm.createContext(menuContext);vm.runInContext(signalSource,menuContext);
for(let i=0;i<100;i++)changedMenu();
assert.equal(scheduled.length,1,'desktop DOM bursts coalesce into one signal');scheduled.shift()();assert.equal(signals,1);
menuContext.document.hidden=true;changedMenu();scheduled.shift()();assert.equal(signals,1,'hidden desktop sends no signal');
let outsideObservers=0;
const outsideContext={document:{readyState:'complete',querySelector(){return null}},MutationObserver:class{constructor(){outsideObservers++}}};
vm.createContext(outsideContext);vm.runInContext(signalSource,outsideContext);assert.equal(outsideObservers,0,'external pages do not get a desktop observer');
console.log('PASS: desktop dirty signaling, coalescing, visibility and external-page isolation');

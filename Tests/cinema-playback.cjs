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

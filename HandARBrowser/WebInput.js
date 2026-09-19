(function(){
  const active = new Map();
  function el(x,y){
    const e=document.elementFromPoint(x,y);
    return e || document.body;
  }
  window.__handarHover=function(x,y){};
  window.__handarPointerDown=function(x,y,id){
    active.set(id,{x,y});
    const target=el(x,y);
    target.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true,cancelable:true,pointerId:id,pointerType:'mouse',clientX:x,clientY:y,buttons:1}));
    target.dispatchEvent(new MouseEvent('mousedown',{bubbles:true,cancelable:true,clientX:x,clientY:y,buttons:1}));
  };
  window.__handarPointerMove=function(x,y,id){
    const target=el(x,y);
    target.dispatchEvent(new PointerEvent('pointermove',{bubbles:true,cancelable:true,pointerId:id,pointerType:'mouse',clientX:x,clientY:y,buttons:1}));
    target.dispatchEvent(new MouseEvent('mousemove',{bubbles:true,cancelable:true,clientX:x,clientY:y,buttons:1}));
    active.set(id,{x,y});
  };
  window.__handarPointerUp=function(x,y,id){
    const a=active.get(id)||{x,y};
    const target=el(x,y);
    target.dispatchEvent(new PointerEvent('pointerup',{bubbles:true,cancelable:true,pointerId:id,pointerType:'mouse',clientX:x,clientY:y,buttons:0}));
    target.dispatchEvent(new MouseEvent('mouseup',{bubbles:true,cancelable:true,clientX:x,clientY:y,buttons:0}));
    if(Math.hypot(x-a.x,y-a.y)<22){
      const clickable=target.closest('a,button,input,textarea,select,summary,label,[role=button]')||target;
      clickable.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,clientX:x,clientY:y}));
      if(typeof clickable.click==='function'){try{clickable.click();}catch(e){}}
    }
    active.delete(id);
  };
})();

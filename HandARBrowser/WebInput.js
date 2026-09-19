(function(){
  const active = new Map();

  function el(x, y){
    return document.elementFromPoint(x, y) || document.body;
  }

  function dispatchPointer(target, type, x, y, id, buttons){
    target.dispatchEvent(new PointerEvent(type, {
      bubbles: true,
      cancelable: true,
      pointerId: id,
      pointerType: 'mouse',
      clientX: x,
      clientY: y,
      buttons: buttons
    }));
    const mouseType = type === 'pointerdown' ? 'mousedown' :
                      type === 'pointerup' ? 'mouseup' : 'mousemove';
    target.dispatchEvent(new MouseEvent(mouseType, {
      bubbles: true,
      cancelable: true,
      clientX: x,
      clientY: y,
      buttons: buttons
    }));
  }

  function findScrollable(target){
    let node = target;
    while(node && node !== document.documentElement){
      if(node instanceof HTMLElement){
        const style = getComputedStyle(node);
        const canScroll = /(auto|scroll)/.test(style.overflowY) && node.scrollHeight > node.clientHeight + 2;
        if(canScroll){ return node; }
      }
      node = node.parentElement;
    }
    return document.scrollingElement || document.documentElement;
  }

  window.__handarHover = function(x, y){
    const target = el(x, y);
    target.dispatchEvent(new MouseEvent('mouseover', {
      bubbles: true,
      cancelable: true,
      clientX: x,
      clientY: y,
      buttons: 0
    }));
    target.dispatchEvent(new MouseEvent('mousemove', {
      bubbles: true,
      cancelable: true,
      clientX: x,
      clientY: y,
      buttons: 0
    }));
  };

  window.__handarPointerDown = function(x, y, id){
    const target = el(x, y);
    active.set(id, {startX: x, startY: y, x, y, target});
    dispatchPointer(target, 'pointerdown', x, y, id, 1);
  };

  window.__handarPointerMove = function(x, y, id){
    const state = active.get(id);
    const target = state && state.target ? state.target : el(x, y);
    dispatchPointer(target, 'pointermove', x, y, id, 1);
    if(state){ state.x = x; state.y = y; }
  };

  window.__handarPointerUp = function(x, y, id){
    const state = active.get(id);
    const dragTarget = state && state.target ? state.target : el(x, y);
    const releaseTarget = el(x, y);
    dispatchPointer(dragTarget, 'pointerup', x, y, id, 0);

    const startX = state ? state.startX : x;
    const startY = state ? state.startY : y;
    const moved = Math.hypot(x - startX, y - startY);
    if(moved < 24){
      const clickable = releaseTarget.closest('a,button,input,textarea,select,summary,label,[role=button]') || releaseTarget;
      clickable.dispatchEvent(new MouseEvent('click', {
        bubbles: true,
        cancelable: true,
        clientX: x,
        clientY: y
      }));
      if(typeof clickable.click === 'function'){
        try{ clickable.click(); }catch(e){}
      }
    }
    active.delete(id);
  };

  window.__handarScroll = function(x, y, deltaY){
    const amount = Number(deltaY) || 0;
    const target = el(x, y);
    const scrollable = findScrollable(target);
    if(scrollable && scrollable !== document.documentElement && scrollable !== document.body){
      scrollable.scrollTop += amount;
    } else {
      window.scrollBy(0, amount);
    }

    target.dispatchEvent(new WheelEvent('wheel', {
      bubbles: true,
      cancelable: true,
      clientX: x,
      clientY: y,
      deltaY: amount,
      deltaMode: 0
    }));
  };
})();

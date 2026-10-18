(function(){
  const active = new Map();
  function el(x,y){return document.elementFromPoint(x,y)||document.body;}
  function action(target){return target && target.closest ? target.closest('a,button,input,textarea,select,summary,label,[role=button],[onclick],.app,.file-row') : null;}
  function enabled(target){return target && !target.disabled && target.getAttribute('aria-disabled')!=='true' && target.isConnected!==false;}
  let hoverTarget=null;
  function updateHover(target){
    const next=action(target);
    if(next===hoverTarget)return;
    if(hoverTarget)hoverTarget.classList.remove('handar-hover');
    hoverTarget=next;
    if(hoverTarget)hoverTarget.classList.add('handar-hover');
  }
  function pointer(target,type,x,y,id,buttons){target.dispatchEvent(new PointerEvent(type,{bubbles:true,cancelable:true,pointerId:id,pointerType:'mouse',clientX:x,clientY:y,buttons}));}
  function mouse(target,type,x,y,buttons){target.dispatchEvent(new MouseEvent(type,{bubbles:true,cancelable:true,clientX:x,clientY:y,buttons}));}
  function scrollAt(target,amount){
    if(!amount)return;
    for(let node=target;node;node=node.parentElement){
      if(node.scrollHeight>node.clientHeight+1 && typeof getComputedStyle==='function'){
        const overflow=getComputedStyle(node).overflowY;
        if(overflow==='auto'||overflow==='scroll'){
          node.scrollTop+=amount;
          return;
        }
      }
    }
    const root=document.scrollingElement;
    if(root)root.scrollTop+=amount;
  }
  window.__handarHover=function(x,y){
    const target=el(x,y);updateHover(target);
    pointer(target,'pointermove',x,y,1,0);mouse(target,'mousemove',x,y,0);
  };
  window.__handarPointerDown=function(x,y,id,slop){
    if(active.has(id))return;
    const target=el(x,y),clickTarget=action(target)||target;
    if(clickTarget&&!enabled(clickTarget))return;
    active.set(id,{target,clickTarget,startX:x,startY:y,lastY:y,moved:false,slop:Number.isFinite(slop)?Math.max(4,slop):12});
    updateHover(target);pointer(target,'pointerdown',x,y,id,1);mouse(target,'mousedown',x,y,1);
  };
  window.__handarPointerMove=function(x,y,id){
    const a=active.get(id);if(!a)return;
    const under=el(x,y),underAction=action(under)||under;
    if(underAction!==a.clickTarget)a.cancelled=true;
    updateHover(under);
    const moved=a.moved||Math.hypot(x-a.startX,y-a.startY)>=a.slop;
    if(moved)scrollAt(a.target,(y-(a.moved?a.lastY:a.startY))*2.6);
    a.moved=moved;a.lastY=y;
    pointer(a.target,'pointermove',x,y,id,1);mouse(a.target,'mousemove',x,y,1);
  };
  window.__handarPointerUp=function(x,y,id){
    const a=active.get(id);if(!a)return;
    active.delete(id);
    pointer(a.target,'pointerup',x,y,id,0);mouse(a.target,'mouseup',x,y,0);
    const target=el(x,y),clickTarget=action(target)||target;
    if(!a.moved&&!a.cancelled&&Math.hypot(x-a.startX,y-a.startY)<a.slop&&a.clickTarget&&clickTarget===a.clickTarget&&enabled(clickTarget)){
      const click=new MouseEvent('click',{bubbles:true,cancelable:true,clientX:x,clientY:y});
      Object.defineProperty(click,'handarConfirmed',{value:true});clickTarget.dispatchEvent(click);
    }
  };
  window.__handarPointerCancel=function(x,y,id){
    const a=active.get(id);active.delete(id);
    if(a){pointer(a.target,'pointercancel',x,y,id,0);mouse(a.target,'mouseup',x,y,0);}
    updateHover(null);
  };
  window.__handarClearHover=function(){updateHover(null);};

  // --- Confirmation feedback (one click, no sound on hover/drag) ---
  document.addEventListener('click', function(event) {
    if (!event.isTrusted && !event.handarConfirmed) return;
    const target = event.target && event.target.closest && event.target.closest('button,a,input,select,summary,label,[role=button],[onclick],.app,.file-row');
    if (!target || target.disabled || target.getAttribute('aria-disabled') === 'true') return;
    target.classList.add('handar-confirmed');
    setTimeout(function(){target.classList.remove('handar-confirmed');}, 200);
    try { window.webkit.messageHandlers.handarFeedback.postMessage({type:'click'}); } catch(e) {}
  }, true);
  // --- End confirmation feedback ---

  // --- Кинорежим: сообщаем нативной стороне, когда на странице открыто
  // видео на весь экран (или почти на весь), чтобы она развернула панель
  // в "кинозал". У YouTube это обычная Fullscreen API на <video>. У TikTok
  // отдельной кнопки fullscreen обычно нет — каждое видео в ленте и так
  // занимает почти весь экран, поэтому там смотрим на геометрию <video>.
  let lastReported = null;
  function postVideoState(active) {
    if (active === lastReported) return;
    lastReported = active;
    try {
      window.webkit.messageHandlers.handarVideo.postMessage({ active: active });
    } catch (e) {
      // Скрипт может выполниться вне HandAR (например, в превью) — не мешаем странице.
    }
  }

  function viewportCoverage(rect) {
    const vw = window.innerWidth || 1;
    const vh = window.innerHeight || 1;
    const visibleW = Math.max(0, Math.min(rect.right, vw) - Math.max(rect.left, 0));
    const visibleH = Math.max(0, Math.min(rect.bottom, vh) - Math.max(rect.top, 0));
    return (visibleW * visibleH) / (vw * vh);
  }

  function findDominantVideo() {
    const videos = document.querySelectorAll('video');
    let best = null;
    let bestCoverage = 0;
    videos.forEach(function (video) {
      if (video.readyState < 2 || video.paused || video.ended) return;
      const coverage = viewportCoverage(video.getBoundingClientRect());
      if (coverage > bestCoverage) {
        bestCoverage = coverage;
        best = video;
      }
    });
    return { video: best, coverage: bestCoverage };
  }

  function evaluateVideoState() {
    if (document.fullscreenElement || document.webkitFullscreenElement) {
      postVideoState(true);
      return;
    }
    // Порог 0.55: не полный экран, но видео явно доминирует над страницей —
    // ровно так выглядит открытая карточка видео и в YouTube, и в TikTok.
    const dominant = findDominantVideo();
    postVideoState(dominant.coverage > 0.55);
  }

  document.addEventListener('fullscreenchange', evaluateVideoState, true);
  document.addEventListener('webkitfullscreenchange', evaluateVideoState, true);

  // WebKit на iOS для инлайн-видео шлёт эти события на самом <video>,
  // минуя Fullscreen API целиком — актуально для YouTube-плеера.
  document.addEventListener('webkitbeginfullscreen', function () { postVideoState(true); }, true);
  document.addEventListener('webkitendfullscreen', function () { evaluateVideoState(); }, true);

  document.addEventListener('play', evaluateVideoState, true);
  document.addEventListener('pause', evaluateVideoState, true);
  document.addEventListener('emptied', evaluateVideoState, true);

  // Лента TikTok прокручивается без событий play/pause на самой странице —
  // нужен таймер, а не только слушатели.
  setInterval(function () { if (!document.hidden) evaluateVideoState(); }, 700);

  let evaluationPending = false;
  const layoutObserver = new MutationObserver(function () {
    if (evaluationPending) return;
    evaluationPending = true;
    requestAnimationFrame(function () {
      evaluationPending = false;
      if (!document.hidden) evaluateVideoState();
    });
  });
  function startObservingWhenReady() {
    if (document.body) {
      layoutObserver.observe(document.body, { childList: true, subtree: true });
      evaluateVideoState();
    } else {
      requestAnimationFrame(startObservingWhenReady);
    }
  }
  startObservingWhenReady();

  // --- VR inline fullscreen --------------------------------------------------
  // YouTube/TikTok могут вызвать fullscreen у <video>. На iPhone такой вызов
  // способен создать отдельный системный видеоплеер, а HandAR должен держать
  // видео внутри WKWebView, чтобы оно попало в тот же стерео-VR-композитор.
  const handarPatchedVideos = new WeakSet();
  let handarFullscreenVideo = null;

  function videoContainer(video) {
    return video.closest('.html5-video-player, .html5-video-container, .video-js, .video-container, [data-video-player]')
      || video.parentElement
      || video;
  }

  function enterInlineFullscreen(video) {
    if (!(video instanceof HTMLVideoElement)) return;
    const container = videoContainer(video);
    handarFullscreenVideo = video;
    container.classList.add('handar-inline-video-fullscreen');
    video.classList.add('handar-inline-video-element');
    document.documentElement.classList.add('handar-video-fullscreen');
    if (document.body) document.body.classList.add('handar-video-fullscreen');
    try { video.play(); } catch (e) {}
    postVideoState(true);
  }

  function exitInlineFullscreen() {
    if (!handarFullscreenVideo) {
      document.documentElement.classList.remove('handar-video-fullscreen');
      if (document.body) document.body.classList.remove('handar-video-fullscreen');
      postVideoState(false);
      return;
    }
    const video = handarFullscreenVideo;
    const container = videoContainer(video);
    container.classList.remove('handar-inline-video-fullscreen');
    video.classList.remove('handar-inline-video-element');
    document.documentElement.classList.remove('handar-video-fullscreen');
    if (document.body) document.body.classList.remove('handar-video-fullscreen');
    handarFullscreenVideo = null;
    postVideoState(false);
  }

  function patchVideo(video) {
    if (!(video instanceof HTMLVideoElement) || handarPatchedVideos.has(video)) return;
    handarPatchedVideos.add(video);
    video.setAttribute('playsinline', '');
    video.setAttribute('webkit-playsinline', '');
    try { video.playsInline = true; } catch (e) {}

    const enter = function () { enterInlineFullscreen(video); };
    try {
      Object.defineProperty(video, 'webkitEnterFullscreen', {
        configurable: true,
        value: enter
      });
    } catch (e) {
      try { video.webkitEnterFullscreen = enter; } catch (ignored) {}
    }
  }

  function patchVideos(root) {
    if (!root || !root.querySelectorAll) return;
    root.querySelectorAll('video').forEach(patchVideo);
    if (root instanceof HTMLVideoElement) patchVideo(root);
  }

  const fullscreenStyle = document.createElement('style');
  fullscreenStyle.textContent = `
    html.handar-video-fullscreen,
    body.handar-video-fullscreen {
      width: 100% !important;
      height: 100% !important;
      overflow: hidden !important;
      background: #000 !important;
    }
    .handar-inline-video-fullscreen {
      position: fixed !important;
      inset: 0 !important;
      width: 100vw !important;
      height: 100vh !important;
      max-width: none !important;
      max-height: none !important;
      z-index: 2147483646 !important;
      background: #000 !important;
      overflow: hidden !important;
      margin: 0 !important;
    }
    .handar-inline-video-fullscreen video,
    .handar-inline-video-element {
      width: 100% !important;
      height: 100% !important;
      max-width: none !important;
      max-height: none !important;
      object-fit: contain !important;
    }
  `;
  (document.head || document.documentElement).appendChild(fullscreenStyle);

  if (Element.prototype.requestFullscreen) {
    const oldRequestFullscreen = Element.prototype.requestFullscreen;
    Element.prototype.requestFullscreen = function () {
      const video = this instanceof HTMLVideoElement ? this : (this.querySelector ? this.querySelector('video') : null);
      if (video) {
        enterInlineFullscreen(video);
        return Promise.resolve();
      }
      return oldRequestFullscreen.apply(this, arguments);
    };
  }

  if (Element.prototype.webkitRequestFullscreen) {
    const oldWebkitRequestFullscreen = Element.prototype.webkitRequestFullscreen;
    Element.prototype.webkitRequestFullscreen = function () {
      const video = this instanceof HTMLVideoElement ? this : (this.querySelector ? this.querySelector('video') : null);
      if (video) {
        enterInlineFullscreen(video);
        return;
      }
      return oldWebkitRequestFullscreen.apply(this, arguments);
    };
  }

  if (document.exitFullscreen) {
    const oldExitFullscreen = document.exitFullscreen.bind(document);
    document.exitFullscreen = function () {
      if (handarFullscreenVideo) {
        exitInlineFullscreen();
        return Promise.resolve();
      }
      return oldExitFullscreen();
    };
  }

  if (document.webkitExitFullscreen) {
    const oldWebkitExitFullscreen = document.webkitExitFullscreen.bind(document);
    document.webkitExitFullscreen = function () {
      if (handarFullscreenVideo) {
        exitInlineFullscreen();
        return;
      }
      return oldWebkitExitFullscreen();
    };
  }

  const videoObserver = new MutationObserver(function (mutations) {
    // Existing videos have already been patched. Visit only newly inserted trees.
    mutations.forEach(function (mutation) {
      mutation.addedNodes.forEach(function (node) { patchVideos(node); });
    });
  });
  function startVideoObserver() {
    if (!document.documentElement) {
      requestAnimationFrame(startVideoObserver);
      return;
    }
    videoObserver.observe(document.documentElement, { childList: true, subtree: true });
    patchVideos(document);
  }
  startVideoObserver();

  window.addEventListener('pagehide', function () {
    exitInlineFullscreen();
    postVideoState(false);
  });

  // --- Управление воспроизведением (панель 3D-кинотеатра) ---------------
  function playbackVideo(){
    const all=Array.from(document.querySelectorAll('video'));
    all.sort((a,b)=>(b.clientWidth*b.clientHeight)-(a.clientWidth*a.clientHeight));
    return all[0]||null;
  }
  window.__handarSeekVideo=function(seconds,absolute){
    const v=playbackVideo();if(!v||!Number.isFinite(seconds))return;
    const target=absolute?seconds:(v.currentTime||0)+seconds;
    const end=Number.isFinite(v.duration)?v.duration:Number.MAX_VALUE;
    try{v.currentTime=Math.max(0,Math.min(end,target));if(absolute){if(window.__handarSetPlaybackIntent)window.__handarSetPlaybackIntent(true);const p=v.play();if(p&&p.catch)p.catch(function(){});}}catch(e){}
  };
  window.__handarTogglePlay = function () {
    var v = playbackVideo();
    if (!v) return 'none';
    try {
      if(window.__handarSetPlaybackIntent)window.__handarSetPlaybackIntent(v.paused);
      if (v.paused) { const p=v.play(); if(p&&p.catch)p.catch(function(){}); return 'play'; }
      v.pause(); return 'pause';
    } catch (e) { return 'none'; }
  };
  window.__handarVideoState = function () {
    var v = playbackVideo();
    if (!v) return 'none';
    return v.paused ? 'paused' : 'playing';
  };
  window.__handarSetVolume = function (delta) {
    var v = playbackVideo();
    if (!v) return;
    try { v.volume = Math.max(0, Math.min(1, v.volume + delta)); } catch (e) {}
  };
})();

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
    if(Math.hypot(x-a.x,y-a.y)<52){
      const clickable=target.closest('a,button,input,textarea,select,summary,label,[role=button]')||target;
      clickable.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,clientX:x,clientY:y}));
      if(typeof clickable.click==='function'){try{clickable.click();}catch(e){}}
    }
    active.delete(id);
  };

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
  setInterval(evaluateVideoState, 700);

  const layoutObserver = new MutationObserver(function () {
    evaluateVideoState();
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

  const videoObserver = new MutationObserver(function () {
    patchVideos(document);
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
})();

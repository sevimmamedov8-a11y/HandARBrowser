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

  window.addEventListener('pagehide', function () { postVideoState(false); });
})();

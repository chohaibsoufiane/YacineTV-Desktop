(() => {
  'use strict';

  const isNativeHost = Boolean(window.chrome && window.chrome.webview);
  const STORAGE_KEYS = {
    settings: 'yacinetv.settings.v1',
    favorites: 'yacinetv.favorites.v1',
    bootstrap: 'yacinetv.bootstrap.v1',
  };

  const state = {
    settings: {
      appearanceMode: 'auto',
      aspectMode: 'fit',
      enhanceMode: 'auto_sd',
      sidebarCollapsed: false,
      theaterMode: false,
    },
    systemIsDark: window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches,
    isFullscreen: false,
    categories: [],
    channelsByCategory: {},
    events: [],
    favorites: [],
    subcategoryStack: [],
    activeNav: 'events',
    activeCategoryId: null,
    activeCategoryTitle: "Today's Matches",
    searchQuery: '',

    playToken: 0,
    currentMediaKey: null,
    currentMediaType: null,
    currentMediaId: null,
    currentMediaTitle: '',
    currentMediaMeta: '',
    servers: [],
    serverQueue: [],
    serverQueuePos: 0,
    activeServerIdx: -1,
    activeBaseProxyUrl: '',
    variants: [],
    autoVariantProxyUrl: '',
    activeVariantIndex: null,
    hls: null,
    statsTimer: null,
    matchCountdownTimer: null,
    playbackHasFirstFrame: false,
    sniffSessionId: 0,
    snifferActive: false,
    snifferVisible: false,
  };

  const el = {
    appShell: document.getElementById('app-shell'),
    sidebar: document.getElementById('sidebar'),
    brandLogo: document.getElementById('brand-logo'),
    sidebarToggleBtn: document.getElementById('sidebar-toggle-btn'),
    sidebarOpenBtn: document.getElementById('sidebar-open-btn'),
    navEvents: document.getElementById('nav-events'),
    navFavorites: document.getElementById('nav-favorites'),
    eventsCount: document.getElementById('events-count'),
    favCount: document.getElementById('fav-count'),
    categoryList: document.getElementById('category-list'),
    appearanceSegmented: document.getElementById('appearance-segmented'),

    backNavBtn: document.getElementById('back-nav-btn'),
    viewTitle: document.getElementById('view-title'),
    viewSubtitle: document.getElementById('view-subtitle'),
    searchInput: document.getElementById('search-input'),
    searchClearBtn: document.getElementById('search-clear-btn'),
    theaterBtn: document.getElementById('theater-btn'),
    refreshBtn: document.getElementById('refresh-btn'),

    inlineErrorBanner: document.getElementById('inline-error-banner'),
    inlineErrorText: document.getElementById('inline-error-text'),
    inlineErrorRetry: document.getElementById('inline-error-retry'),

    playerDock: document.getElementById('player-dock'),
    closePlayerBtn: document.getElementById('close-player-btn'),
    videoStage: document.getElementById('video-stage'),
    video: document.getElementById('hls-video'),
    rcasCanvas: document.getElementById('rcas-canvas'),
    playerLoading: document.getElementById('player-loading'),
    loadingText: document.getElementById('loading-text'),

    hudFsTitle: document.getElementById('hud-fs-title'),
    hudFsTitleText: document.getElementById('hud-fs-title-text'),
    fsQualityBtn: document.getElementById('fs-quality-btn'),
    fsQualityBtnLabel: document.getElementById('fs-quality-btn-label'),
    fsPopover: document.getElementById('fs-popover'),
    fsServersSection: document.getElementById('fs-servers-section'),
    fsQualitySection: document.getElementById('fs-quality-section'),
    fsServerPills: document.getElementById('fs-server-pills'),
    fsQualityPills: document.getElementById('fs-quality-pills'),
    fsEnhancePills: document.getElementById('fs-enhance-pills'),
    fsAspectPills: document.getElementById('fs-aspect-pills'),

    playPauseBtn: document.getElementById('play-pause-btn'),
    iconPlay: document.getElementById('icon-play'),
    iconPause: document.getElementById('icon-pause'),
    muteBtn: document.getElementById('mute-btn'),
    iconVolOn: document.getElementById('icon-vol-on'),
    iconVolOff: document.getElementById('icon-vol-off'),
    volumeSlider: document.getElementById('volume-slider'),
    pipBtn: document.getElementById('pip-btn'),
    fullscreenBtn: document.getElementById('fullscreen-btn'),
    iconFsEnter: document.getElementById('icon-fs-enter'),
    iconFsExit: document.getElementById('icon-fs-exit'),

    liveIndicator: document.getElementById('live-indicator'),
    nowPlayingTitle: document.getElementById('now-playing-title'),
    nowPlayingMeta: document.getElementById('now-playing-meta'),
    serversGroup: document.getElementById('servers-group'),
    qualityGroup: document.getElementById('quality-group'),
    serverPills: document.getElementById('server-pills'),
    qualityPills: document.getElementById('quality-pills'),
    aspectPills: document.getElementById('aspect-pills'),
    enhancePills: document.getElementById('enhance-pills'),
    statResWrap: document.getElementById('stat-res-wrap'),
    statRes: document.getElementById('stat-res'),
    statBitrateWrap: document.getElementById('stat-bitrate-wrap'),
    statBitrate: document.getElementById('stat-bitrate'),
    statModeWrap: document.getElementById('stat-mode-wrap'),
    statMode: document.getElementById('stat-mode'),

    contentBrowser: document.getElementById('content-browser'),
    contentGrid: document.getElementById('content-grid'),
  };

  function b64uEncode(str) {
    const bytes = new TextEncoder().encode(String(str || ''));
    let bin = '';
    for (let i = 0; i < bytes.length; i += 1) {
      bin += String.fromCharCode(bytes[i]);
    }
    return btoa(bin).replace(/\+/g, '-').replace(/\//g, '_');
  }

  function escapeHtml(str) {
    return String(str ?? '')
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }

  function postNative(payload) {
    if (isNativeHost) {
      try {
        window.chrome.webview.postMessage(payload);
      } catch (_) {}
    }
  }

  function persistSettings() {
    if (isNativeHost) {
      postNative({ type: 'setSettings', settings: state.settings });
    } else {
      try { localStorage.setItem(STORAGE_KEYS.settings, JSON.stringify(state.settings)); } catch (_) {}
    }
  }

  function persistFavorites() {
    if (isNativeHost) {
      postNative({ type: 'saveFavorites', favorites: state.favorites });
    } else {
      try { localStorage.setItem(STORAGE_KEYS.favorites, JSON.stringify(state.favorites)); } catch (_) {}
    }
  }

  function persistBootstrap() {
    const snapshot = {
      savedAt: Math.floor(Date.now() / 1000),
      categories: state.categories,
      channelsByCategory: state.channelsByCategory,
      events: state.events,
    };
    if (isNativeHost) {
      postNative({ type: 'saveBootstrap', bootstrap: snapshot });
    } else {
      try { localStorage.setItem(STORAGE_KEYS.bootstrap, JSON.stringify(snapshot)); } catch (_) {}
    }
  }

  async function apiGet(path) {
    const resp = await fetch(path, { cache: 'no-store' });
    if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
    return await resp.json();
  }

  function showError(msg) {
    el.inlineErrorText.textContent = msg;
    el.inlineErrorBanner.classList.remove('hidden');
  }

  function clearError() {
    el.inlineErrorBanner.classList.add('hidden');
  }

  function effectiveIsDark() {
    if (state.settings.appearanceMode === 'dark') return true;
    if (state.settings.appearanceMode === 'light') return false;
    return state.systemIsDark;
  }

  function applyThemeUI() {
    const dark = effectiveIsDark();
    document.documentElement.setAttribute('data-theme', dark ? 'dark' : 'light');
    document.documentElement.setAttribute('data-appearance', state.settings.appearanceMode);
    if (el.brandLogo) {
      el.brandLogo.src = dark ? '/AppBrand-Dark.png' : '/AppBrand-Default.png';
    }
    el.appearanceSegmented.querySelectorAll('.seg-btn').forEach((btn) => {
      const active = btn.dataset.appearance === state.settings.appearanceMode;
      btn.classList.toggle('active', active);
      btn.setAttribute('aria-checked', active ? 'true' : 'false');
    });
  }

  function applyLayoutPrefs() {
    el.appShell.classList.toggle('sidebar-collapsed', Boolean(state.settings.sidebarCollapsed));
    el.sidebarOpenBtn.classList.toggle('hidden', !state.settings.sidebarCollapsed);
    el.playerDock.classList.toggle('theater', Boolean(state.settings.theaterMode));
    el.theaterBtn.classList.toggle('active', Boolean(state.settings.theaterMode));
    el.videoStage.setAttribute('data-aspect', state.settings.aspectMode || 'fit');

    const syncButtons = (container, attr, val) => {
      if (!container) return;
      container.querySelectorAll(`[${attr}]`).forEach((btn) => {
        btn.classList.toggle('active', btn.getAttribute(attr) === val);
      });
    };
    syncButtons(el.aspectPills, 'data-aspect', state.settings.aspectMode);
    syncButtons(el.fsAspectPills, 'data-aspect', state.settings.aspectMode);
    syncButtons(el.enhancePills, 'data-enhance', state.settings.enhanceMode);
    syncButtons(el.fsEnhancePills, 'data-enhance', state.settings.enhanceMode);

    scheduleStageRectSync();
  }

  let browserFsHudTimer = null;
  function updateFullscreenUI(isFs) {
    state.isFullscreen = Boolean(isFs);
    el.appShell.classList.toggle('is-fullscreen', state.isFullscreen);
    el.hudFsTitle.classList.toggle('hidden', !state.isFullscreen);
    el.fsQualityBtn.classList.toggle('hidden', !state.isFullscreen);
    el.iconFsEnter.classList.toggle('hidden', state.isFullscreen);
    el.iconFsExit.classList.toggle('hidden', !state.isFullscreen);

    if (!state.isFullscreen) {
      closeFsPopover();
      el.appShell.classList.remove('hud-hidden');
    } else {
      el.hudFsTitleText.textContent = state.currentMediaTitle || 'Yacine TV';
      setFullscreenHudVisible(true);
    }
    scheduleStageRectSync();
  }

  function setFullscreenHudVisible(visible) {
    if (!state.isFullscreen) return;
    const popoverOpen = !el.fsPopover.classList.contains('hidden');
    const finalVis = visible || popoverOpen;
    el.appShell.classList.toggle('hud-hidden', !finalVis);
    el.videoStage.classList.toggle('hud-visible', finalVis);
  }

  function toggleFullscreen() {
    if (isNativeHost) {
      postNative({ type: 'toggleFullscreen' });
    } else if (!document.fullscreenElement) {
      el.videoStage.requestFullscreen?.().catch(() => {});
    } else {
      document.exitFullscreen?.().catch(() => {});
    }
  }

  function closeFsPopover() {
    el.fsPopover.classList.add('hidden');
    el.videoStage.classList.remove('popover-open');
  }

  let stageRectRaf = 0;
  function scheduleStageRectSync() {
    if (!isNativeHost) return;
    if (stageRectRaf) cancelAnimationFrame(stageRectRaf);
    stageRectRaf = requestAnimationFrame(() => {
      stageRectRaf = 0;
      if (el.playerDock.classList.contains('hidden')) {
        postNative({ type: 'setStageRect', x: 0, y: 0, width: 0, height: 0, dpr: 1 });
        return;
      }
      const rect = el.videoStage.getBoundingClientRect();
      postNative({
        type: 'setStageRect',
        x: rect.left,
        y: rect.top,
        width: rect.width,
        height: rect.height,
        dpr: window.devicePixelRatio || 1,
      });
    });
  }

  // --- GPU WebGL2 RCAS Shader (Port of MetalFXVideoRenderView) ---
  class RcasUpscaler {
    constructor(videoEl, canvasEl) {
      this.video = videoEl;
      this.canvas = canvasEl;
      this.gl = null;
      this.program = null;
      this.texture = null;
      this.uTexLoc = null;
      this.uTexelLoc = null;
      this.uScaleLoc = null;
      this.uSharpnessLoc = null;
      this.failed = false;
      this.running = false;
      this.rafId = 0;
      this.vfcId = 0;
      this.activeNow = false;
    }

    shouldRun() {
      if (this.failed || state.snifferVisible) return false;
      const vw = this.video.videoWidth || 0;
      const vh = this.video.videoHeight || 0;
      if (vw <= 0 || vh <= 0 || this.video.readyState < 2) return false;
      const mode = state.settings.enhanceMode;
      if (mode === 'off') return false;
      if (mode === 'on') return true;
      return vh < 720;
    }

    ensureGL() {
      if (this.gl) return true;
      const gl = this.canvas.getContext('webgl2', {
        alpha: false,
        antialias: false,
        depth: false,
        stencil: false,
        powerPreference: 'high-performance',
      });
      if (!gl) {
        this.failed = true;
        return false;
      }

      const vsSrc = `#version 300 es
        in vec2 aPos;
        uniform vec2 uScale;
        out vec2 vUv;
        void main() {
          vec2 uv = aPos * 0.5 + 0.5;
          vUv = vec2(uv.x, 1.0 - uv.y);
          gl_Position = vec4(aPos * uScale, 0.0, 1.0);
        }`;

      const fsSrc = `#version 300 es
        precision highp float;
        in vec2 vUv;
        uniform sampler2D uTex;
        uniform vec2 uTexel;
        uniform float uSharpness;
        out vec4 fragColor;

        float luma(vec3 c) {
          return dot(c, vec3(0.2126, 0.7152, 0.0722));
        }

        void main() {
          vec3 c = texture(uTex, vUv).rgb;
          vec3 n = texture(uTex, vUv + vec2(0.0, -uTexel.y)).rgb;
          vec3 s = texture(uTex, vUv + vec2(0.0,  uTexel.y)).rgb;
          vec3 w = texture(uTex, vUv + vec2(-uTexel.x, 0.0)).rgb;
          vec3 e = texture(uTex, vUv + vec2( uTexel.x, 0.0)).rgb;

          float lC = luma(c);
          float lN = luma(n);
          float lS = luma(s);
          float lW = luma(w);
          float lE = luma(e);

          float mnL = min(min(lN, lS), min(lW, min(lE, lC)));
          float mxL = max(max(lN, lS), max(lW, max(lE, lC)));
          float amp = clamp(min(mnL, 1.0 - mxL) / max(mxL, 0.001), 0.0, 1.0);
          float wSharp = -sqrt(amp) * (0.20 * clamp(uSharpness, 0.0, 0.6));
          float norm = 1.0 / max(1.0 + 4.0 * wSharp, 0.25);

          vec3 mnRGB = min(min(n, s), min(w, min(e, c)));
          vec3 mxRGB = max(max(n, s), max(w, max(e, c)));
          vec3 sharp = (c + wSharp * (n + s + w + e)) * norm;
          fragColor = vec4(clamp(sharp, mnRGB, mxRGB), 1.0);
        }`;

      const compile = (type, src) => {
        const sh = gl.createShader(type);
        gl.shaderSource(sh, src);
        gl.compileShader(sh);
        if (!gl.getShaderParameter(sh, gl.COMPILE_STATUS)) {
          gl.deleteShader(sh);
          return null;
        }
        return sh;
      };

      const vs = compile(gl.VERTEX_SHADER, vsSrc);
      const fs = compile(gl.FRAGMENT_SHADER, fsSrc);
      if (!vs || !fs) {
        this.failed = true;
        return false;
      }

      const prog = gl.createProgram();
      gl.attachShader(prog, vs);
      gl.attachShader(prog, fs);
      gl.linkProgram(prog);
      gl.deleteShader(vs);
      gl.deleteShader(fs);
      if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) {
        gl.deleteProgram(prog);
        this.failed = true;
        return false;
      }

      const buf = gl.createBuffer();
      gl.bindBuffer(gl.ARRAY_BUFFER, buf);
      gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 1, -1, -1, 1, 1, 1]), gl.STATIC_DRAW);

      const posLoc = gl.getAttribLocation(prog, 'aPos');
      gl.enableVertexAttribArray(posLoc);
      gl.vertexAttribPointer(posLoc, 2, gl.FLOAT, false, 0, 0);

      const tex = gl.createTexture();
      gl.bindTexture(gl.TEXTURE_2D, tex);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);

      this.gl = gl;
      this.program = prog;
      this.texture = tex;
      this.uTexLoc = gl.getUniformLocation(prog, 'uTex');
      this.uTexelLoc = gl.getUniformLocation(prog, 'uTexel');
      this.uScaleLoc = gl.getUniformLocation(prog, 'uScale');
      this.uSharpnessLoc = gl.getUniformLocation(prog, 'uSharpness');
      return true;
    }

    syncState() {
      const want = this.shouldRun();
      if (want === this.activeNow) {
        updateEnhanceBadge();
        return;
      }
      this.activeNow = want;
      if (want && this.ensureGL()) {
        this.canvas.classList.remove('hidden');
        this.startLoop();
      } else {
        this.stopLoop();
        this.canvas.classList.add('hidden');
      }
      updateEnhanceBadge();
    }

    startLoop() {
      if (this.running) return;
      this.running = true;
      const tick = () => {
        if (!this.running) return;
        this.renderFrame();
        if (typeof this.video.requestVideoFrameCallback === 'function') {
          this.vfcId = this.video.requestVideoFrameCallback(tick);
        } else {
          this.rafId = requestAnimationFrame(tick);
        }
      };
      tick();
    }

    stopLoop() {
      this.running = false;
      if (this.rafId) {
        cancelAnimationFrame(this.rafId);
        this.rafId = 0;
      }
      if (this.vfcId && typeof this.video.cancelVideoFrameCallback === 'function') {
        try { this.video.cancelVideoFrameCallback(this.vfcId); } catch (_) {}
        this.vfcId = 0;
      }
    }

    renderFrame() {
      if (!this.shouldRun()) {
        this.syncState();
        return;
      }
      const gl = this.gl;
      const vw = this.video.videoWidth;
      const vh = this.video.videoHeight;
      if (!gl || vw <= 0 || vh <= 0) return;

      const dpr = Math.min(window.devicePixelRatio || 1, 2);
      const cw = Math.max(vw, Math.round(el.videoStage.clientWidth * dpr));
      const ch = Math.max(vh, Math.round(el.videoStage.clientHeight * dpr));
      if (this.canvas.width !== cw || this.canvas.height !== ch) {
        this.canvas.width = cw;
        this.canvas.height = ch;
      }

      const aspect = state.settings.aspectMode || 'fit';
      let sx = 1.0;
      let sy = 1.0;
      if (aspect !== 'stretch') {
        const videoRatio = vw / vh;
        const viewRatio = cw / ch;
        if (aspect === 'fit') {
          if (videoRatio > viewRatio) sy = viewRatio / videoRatio;
          else sx = videoRatio / viewRatio;
        } else {
          if (videoRatio > viewRatio) sx = videoRatio / viewRatio;
          else sy = viewRatio / videoRatio;
        }
      }

      try {
        gl.viewport(0, 0, cw, ch);
        gl.clearColor(0, 0, 0, 1);
        gl.clear(gl.COLOR_BUFFER_BIT);
        gl.useProgram(this.program);
        gl.activeTexture(gl.TEXTURE0);
        gl.bindTexture(gl.TEXTURE_2D, this.texture);
        gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, this.video);
        gl.uniform1i(this.uTexLoc, 0);
        gl.uniform2f(this.uTexelLoc, 1.0 / vw, 1.0 / vh);
        gl.uniform2f(this.uScaleLoc, sx, sy);
        gl.uniform1f(this.uSharpnessLoc, 0.28);
        gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
      } catch (_) {
        this.failed = true;
        this.syncState();
      }
    }
  }

  const rcas = new RcasUpscaler(el.video, el.rcasCanvas);

  function updateEnhanceBadge() {
    if (rcas.activeNow) {
      el.statMode.textContent = 'GPU + RCAS';
      el.statModeWrap.classList.remove('hidden');
    } else if (state.snifferVisible) {
      el.statMode.textContent = 'Web Embed';
      el.statModeWrap.classList.remove('hidden');
    } else {
      el.statModeWrap.classList.add('hidden');
    }
  }

  function presentCategory(cat) {
    const raw = String(cat.name || '').trim();
    const upper = raw.toUpperCase();
    let title = raw;
    let badgeText = (cat.child_count && cat.child_count > 0) ? String(cat.child_count) : '';
    let isQualityTag = false;
    let iconSvg = `<svg viewBox="0 0 20 20" width="16" height="16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linejoin="round"><rect x="2.5" y="4.5" width="15" height="10.5" rx="2"/><path d="M7 17.5h6" stroke-linecap="round"/></svg>`;

    if (upper.includes('BEIN') && upper.includes('SPORT')) {
      title = 'beIN SPORTS';
      if (upper.includes('1080')) {
        badgeText = '1080P';
        isQualityTag = true;
      } else if (upper.includes('720')) {
        badgeText = '720P';
        isQualityTag = true;
      } else if (upper.includes('360')) {
        badgeText = '360P';
        isQualityTag = true;
      } else if (upper.includes('244') || upper.includes('240')) {
        badgeText = '244P';
        isQualityTag = true;
      }
      iconSvg = `<svg viewBox="0 0 20 20" width="16" height="16" fill="none" stroke="currentColor" stroke-width="1.6"><circle cx="10" cy="10" r="7"/><path d="M10 3v14M3.5 7.5c4.5 1.8 8.5 1.8 13 0M3.5 12.5c4.5-1.8 8.5-1.8 13 0"/></svg>`;
    } else if (upper.includes('SPORT')) {
      iconSvg = `<svg viewBox="0 0 20 20" width="16" height="16" fill="none" stroke="currentColor" stroke-width="1.6"><circle cx="10" cy="10" r="7"/><path d="M10 3v14M3.5 7.5c4.5 1.8 8.5 1.8 13 0M3.5 12.5c4.5-1.8 8.5-1.8 13 0"/></svg>`;
    } else if (upper.includes('KID') || upper.includes('ANIME') || raw.includes('أطفال')) {
      iconSvg = `<svg viewBox="0 0 20 20" width="16" height="16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"><circle cx="10" cy="10" r="7"/><path d="M7.5 8.5h.01M12.5 8.5h.01M7.2 12c.8 1.1 1.7 1.6 2.8 1.6s2-.5 2.8-1.6"/></svg>`;
    } else if (upper.includes('FILM') || upper.includes('MOVIE') || upper.includes('SHAHID') || upper.includes('WEYYAK')) {
      iconSvg = `<svg viewBox="0 0 20 20" width="16" height="16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linejoin="round"><rect x="3" y="4" width="14" height="12" rx="2"/><path d="M8.5 8v4l4-2-4-2z" fill="currentColor" stroke="none"/></svg>`;
    }

    return { title, badgeText, isQualityTag, iconSvg };
  }

  function normalizedUnixSeconds(raw) {
    const val = Number(raw);
    if (!Number.isFinite(val) || val <= 0) return null;
    return val > 10_000_000_000 ? Math.floor(val / 1000) : Math.floor(val);
  }

  function eventLifecycle(ev) {
    const startSec = normalizedUnixSeconds(ev.start_time);
    const endSec = normalizedUnixSeconds(ev.end_time) || (startSec ? startSec + 7200 : null);
    const nowSec = Math.floor(Date.now() / 1000);

    let kickoffText = '';
    if (startSec) {
      try {
        kickoffText = new Date(startSec * 1000).toLocaleTimeString([], {
          hour: '2-digit',
          minute: '2-digit',
        });
      } catch (_) {}
    }

    if (!startSec) {
      return { kind: 'live', statusBadge: 'LIVE', stateLabel: 'Live', arLabel: 'مباشر', kickoffText };
    }
    if (nowSec >= startSec && nowSec <= endSec) {
      return { kind: 'live', statusBadge: 'LIVE', stateLabel: 'Live', arLabel: 'جارية الآن', kickoffText };
    }
    if (nowSec > endSec) {
      return { kind: 'ended', statusBadge: 'ENDED', stateLabel: 'Ended', arLabel: 'إنتهت المباراة', kickoffText };
    }

    const diffMins = Math.max(1, Math.ceil((startSec - nowSec) / 60));
    const badge = diffMins < 60
      ? `IN ${diffMins}M`
      : `IN ${Math.floor(diffMins / 60)}H${diffMins % 60 > 0 ? ` ${diffMins % 60}M` : ''}`;
    return { kind: 'upcoming', statusBadge: badge, stateLabel: 'Upcoming', arLabel: '', kickoffText };
  }

  function isFavorited(channelId) {
    const target = String(channelId);
    return state.favorites.some((c) => String(c.id) === target);
  }

  function toggleFavorite(ch, eventObj) {
    if (eventObj) eventObj.stopPropagation();
    const id = String(ch.id);
    const idx = state.favorites.findIndex((c) => String(c.id) === id);
    if (idx >= 0) {
      state.favorites.splice(idx, 1);
    } else {
      state.favorites.push({ id: ch.id, name: ch.name, logo: ch.logo || '' });
    }
    updateSidebarNavHighlight();
    persistFavorites();
    renderCurrentGrid();
  }

  function renderCategories() {
    el.categoryList.innerHTML = '';
    for (const cat of state.categories) {
      const p = presentCategory(cat);
      const btn = document.createElement('button');
      btn.type = 'button';
      btn.className = 'nav-item';
      const activeCatMatch = state.activeNav === 'category' && String(state.activeCategoryId) === String(cat.id);
      const activeSubMatch = state.activeNav === 'category' && state.subcategoryStack.length > 0 && String(state.subcategoryStack[0].rootCategoryId) === String(cat.id);
      if (activeCatMatch || activeSubMatch) btn.classList.add('active');
      btn.innerHTML = `
        <span class="nav-icon" aria-hidden="true">${p.iconSvg}</span>
        <span class="nav-label">${escapeHtml(p.title)}</span>
        ${p.badgeText ? `<span class="nav-count ${p.isQualityTag ? 'quality-tag' : ''}">${escapeHtml(p.badgeText)}</span>` : ''}
      `;
      btn.addEventListener('click', () => openRootCategory(cat));
      el.categoryList.appendChild(btn);
    }
  }

  function updateSidebarNavHighlight() {
    el.navEvents.classList.toggle('active', state.activeNav === 'events');
    el.navFavorites.classList.toggle('active', state.activeNav === 'favorites');
    el.eventsCount.textContent = state.events.length ? String(state.events.length) : '';
    el.favCount.textContent = state.favorites.length ? String(state.favorites.length) : '';
    renderCategories();
  }

  function renderSkeletons(count, isEventsMode) {
    el.contentGrid.classList.toggle('events-mode', Boolean(isEventsMode));
    el.contentGrid.innerHTML = '';
    for (let i = 0; i < count; i += 1) {
      const sk = document.createElement('div');
      sk.className = 'skeleton-card';
      el.contentGrid.appendChild(sk);
    }
  }

  function renderEmptyState(title, desc, actionLabel, onAction) {
    el.contentGrid.classList.remove('events-mode');
    el.contentGrid.innerHTML = '';
    const box = document.createElement('div');
    box.className = 'empty-state-box';
    box.innerHTML = `
      <div class="empty-state-title">${escapeHtml(title)}</div>
      <div class="empty-state-desc">${escapeHtml(desc)}</div>
    `;
    if (actionLabel && onAction) {
      const btn = document.createElement('button');
      btn.type = 'button';
      btn.className = 'empty-action-btn';
      btn.textContent = actionLabel;
      btn.addEventListener('click', onAction);
      box.appendChild(btn);
    }
    el.contentGrid.appendChild(box);
  }

  function renderEventsGrid() {
    el.viewTitle.textContent = "Today's Matches";
    el.viewSubtitle.textContent = state.events.length ? `· ${state.events.length} matches scheduled` : '';
    el.backNavBtn.classList.add('hidden');
    el.contentGrid.classList.add('events-mode');

    if (!state.events.length) {
      renderEmptyState(
        'No Matches Scheduled',
        'Try refreshing live feeds in a moment.',
        'Refresh',
        () => refreshAll(true)
      );
      return;
    }

    el.contentGrid.innerHTML = '';
    for (const ev of state.events) {
      const life = eventLifecycle(ev);
      const t1 = ev.team_1 || {};
      const t2 = ev.team_2 || {};
      const title = `${t1.name || 'Team 1'} vs ${t2.name || 'Team 2'}`;
      const meta = [ev.champions, ev.channel, ev.commentary].filter(Boolean).join(' · ') || 'Live Match';
      const isPlaying = state.currentMediaKey === `event:${ev.id}`;

      const card = document.createElement('div');
      card.className = `event-card${isPlaying ? ' playing' : ''}`;
      card.tabIndex = 0;
      const badgeCls = life.kind === 'live' ? 'is-live' : (life.kind === 'upcoming' ? 'is-upcoming' : '');
      card.innerHTML = `
        <div class="event-top-bar">
          <span class="event-champ">${escapeHtml(ev.champions || 'Match Day')}</span>
          <span class="event-status-badge ${badgeCls}">${escapeHtml(life.statusBadge)}</span>
        </div>
        <div class="event-teams-row">
          <div class="team-col">
            ${t1.logo ? `<img class="team-logo" src="${escapeHtml(t1.logo)}" alt="" loading="lazy" />` : '<div class="team-logo"></div>'}
            <span class="team-name">${escapeHtml(t1.name || 'Home')}</span>
          </div>
          <div class="vs-box">
            <span class="vs-state">${escapeHtml(life.stateLabel)}</span>
            ${life.arLabel ? `<span class="vs-ar">${escapeHtml(life.arLabel)}</span>` : ''}
            ${life.kickoffText ? `<span class="vs-time">${escapeHtml(life.kickoffText)}</span>` : ''}
          </div>
          <div class="team-col">
            ${t2.logo ? `<img class="team-logo" src="${escapeHtml(t2.logo)}" alt="" loading="lazy" />` : '<div class="team-logo"></div>'}
            <span class="team-name">${escapeHtml(t2.name || 'Away')}</span>
          </div>
        </div>
        <div class="event-footer">
          <span class="event-footer-item">
            <svg viewBox="0 0 16 16" width="11" height="11" fill="none" stroke="currentColor" stroke-width="1.4" aria-hidden="true"><rect x="1.8" y="3" width="12.4" height="8.5" rx="1.4"/><path d="M5.5 13.5h5" stroke-linecap="round"/></svg>
            <span>${escapeHtml(ev.channel || 'Live Feed')}</span>
          </span>
          ${ev.commentary ? `
          <span class="event-footer-item">
            <svg viewBox="0 0 16 16" width="11" height="11" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" aria-hidden="true"><rect x="6" y="2" width="4" height="7" rx="2"/><path d="M4 7.5a4 4 0 0 0 8 0M8 11.5v2.5"/></svg>
            <span>${escapeHtml(ev.commentary)}</span>
          </span>` : ''}
        </div>
      `;
      const launch = () => playMedia('event', ev.id, title, meta);
      card.addEventListener('click', launch);
      card.addEventListener('keydown', (e) => {
        if (e.key === 'Enter' || e.key === ' ') {
          e.preventDefault();
          launch();
        }
      });
      el.contentGrid.appendChild(card);
    }
  }

  function renderChannelsGrid(channels, headingTitle, emptyTitle, emptyDesc) {
    el.viewTitle.textContent = headingTitle;
    el.viewSubtitle.textContent = channels.length ? `· ${channels.length} channels` : '';
    el.contentGrid.classList.remove('events-mode');

    if (!channels.length) {
      renderEmptyState(emptyTitle, emptyDesc, 'Browse Matches', () => switchToEvents());
      return;
    }

    el.contentGrid.innerHTML = '';
    for (const ch of channels) {
      const fav = isFavorited(ch.id);
      const isPlaying = state.currentMediaKey === `channel:${ch.id}`;
      const initials = String(ch.name || 'TV')
        .split(/\s+/)
        .slice(0, 2)
        .map((w) => w[0] || '')
        .join('')
        .toUpperCase();

      const card = document.createElement('div');
      card.className = `channel-card${isPlaying ? ' playing' : ''}`;
      card.tabIndex = 0;

      const favBtn = document.createElement('button');
      favBtn.type = 'button';
      favBtn.className = `fav-toggle-btn${fav ? ' favorited' : ''}`;
      favBtn.title = fav ? 'Remove from Favorites' : 'Add to Favorites';
      favBtn.setAttribute('aria-label', favBtn.title);
      favBtn.innerHTML = `
        <svg viewBox="0 0 16 16" width="12" height="12" fill="${fav ? 'currentColor' : 'none'}" stroke="currentColor" stroke-width="1.5" stroke-linejoin="round" aria-hidden="true">
          <path d="M8 2l1.8 3.7 4 .6-2.9 2.8.7 4-3.6-1.9-3.6 1.9.7-4-2.9-2.8 4-.6z"/>
        </svg>
      `;
      favBtn.addEventListener('click', (e) => toggleFavorite(ch, e));

      const logoBox = document.createElement('div');
      logoBox.className = 'channel-logo-box';
      if (ch.logo) {
        const img = document.createElement('img');
        img.src = ch.logo;
        img.alt = ch.name || 'Channel';
        img.loading = 'lazy';
        img.onerror = () => {
          logoBox.innerHTML = `<span class="channel-fallback-badge">${escapeHtml(initials)}</span>`;
        };
        logoBox.appendChild(img);
      } else {
        logoBox.innerHTML = `<span class="channel-fallback-badge">${escapeHtml(initials)}</span>`;
      }

      const nameDiv = document.createElement('div');
      nameDiv.className = 'channel-name';
      nameDiv.textContent = ch.name || 'Unknown Channel';

      card.appendChild(favBtn);
      card.appendChild(logoBox);
      card.appendChild(nameDiv);

      const launch = () => playMedia('channel', ch.id, ch.name || 'Live Channel', headingTitle);
      card.addEventListener('click', launch);
      card.addEventListener('keydown', (e) => {
        if (e.key === 'Enter' || e.key === ' ') {
          e.preventDefault();
          launch();
        }
      });
      el.contentGrid.appendChild(card);
    }
  }

  function renderSubcategoriesGrid(subcats, title) {
    el.viewTitle.textContent = title;
    el.viewSubtitle.textContent = subcats.length ? `· ${subcats.length} groups` : '';
    el.contentGrid.classList.remove('events-mode');
    el.contentGrid.innerHTML = '';

    for (const sub of subcats) {
      const p = presentCategory(sub);
      const card = document.createElement('div');
      card.className = 'channel-card';
      card.tabIndex = 0;

      const logoBox = document.createElement('div');
      logoBox.className = 'channel-logo-box';
      if (sub.logo) {
        const img = document.createElement('img');
        img.src = sub.logo;
        img.alt = p.title;
        img.loading = 'lazy';
        img.onerror = () => {
          logoBox.innerHTML = `<span class="channel-fallback-badge">${escapeHtml(p.badgeText || 'TV')}</span>`;
        };
        logoBox.appendChild(img);
      } else {
        logoBox.innerHTML = `<span class="channel-fallback-badge">${escapeHtml(p.badgeText || 'TV')}</span>`;
      }

      const nameDiv = document.createElement('div');
      nameDiv.className = 'channel-name';
      nameDiv.textContent = p.title;

      card.appendChild(logoBox);
      card.appendChild(nameDiv);

      const drill = () => drillIntoSubcategory(sub);
      card.addEventListener('click', drill);
      card.addEventListener('keydown', (e) => {
        if (e.key === 'Enter' || e.key === ' ') {
          e.preventDefault();
          drill();
        }
      });
      el.contentGrid.appendChild(card);
    }
  }

  function renderCurrentGrid() {
    el.backNavBtn.classList.toggle('hidden', state.subcategoryStack.length === 0);
    if (state.activeNav === 'events') {
      renderEventsGrid();
    } else if (state.activeNav === 'favorites') {
      renderChannelsGrid(
        state.favorites,
        'Favorites',
        'No Favorites Yet',
        'Click the star on any channel card to pin it here.'
      );
    } else if (state.activeNav === 'search') {
      const results = state._lastSearchResults || [];
      renderChannelsGrid(
        results,
        `Results for "${state.searchQuery}"`,
        'No Matching Channels',
        'Try another channel name or pick a category from the sidebar.'
      );
    } else if (state.activeNav === 'category') {
      if (state.subcategoryStack.length > 0) {
        const top = state.subcategoryStack[state.subcategoryStack.length - 1];
        if (top.kind === 'subcats') {
          renderSubcategoriesGrid(top.items, top.title);
        } else {
          renderChannelsGrid(top.items, top.title, 'No Channels Found', 'This group has no active streams.');
        }
      } else {
        const channels = state.channelsByCategory[String(state.activeCategoryId)] || [];
        renderChannelsGrid(channels, state.activeCategoryTitle, 'No Channels Available', 'Try refreshing.');
      }
    }
  }

  function switchToEvents() {
    state.activeNav = 'events';
    state.subcategoryStack = [];
    updateSidebarNavHighlight();
    renderCurrentGrid();
  }

  function switchToFavorites() {
    state.activeNav = 'favorites';
    state.subcategoryStack = [];
    updateSidebarNavHighlight();
    renderCurrentGrid();
  }

  async function openRootCategory(cat, forceRefresh = false) {
    state.activeNav = 'category';
    state.activeCategoryId = cat.id;
    const p = presentCategory(cat);
    state.activeCategoryTitle = p.title;
    state.subcategoryStack = [];
    updateSidebarNavHighlight();

    const catKey = String(cat.id);
    if (cat.child_count && cat.child_count > 0) {
      renderSkeletons(10, false);
      try {
        const res = await apiGet(`/api/categories?id=${encodeURIComponent(catKey)}${forceRefresh ? '&refresh=1' : ''}`);
        const subcats = res.data || [];
        if (subcats.length > 0) {
          state.subcategoryStack = [{ kind: 'subcats', id: catKey, rootCategoryId: catKey, title: p.title, items: subcats }];
          renderCurrentGrid();
          return;
        }
      } catch (err) {
        showError(`Failed to load groups: ${err.message}`);
      }
    }

    if (!forceRefresh && state.channelsByCategory[catKey]) {
      renderCurrentGrid();
      apiGet(`/api/channels?category_id=${encodeURIComponent(catKey)}`)
        .then((res) => {
          const filtered = (res.data || []).filter((c) => Number(c.is_hide || 0) === 0);
          state.channelsByCategory[catKey] = filtered;
          persistBootstrap();
          if (state.activeNav === 'category' && String(state.activeCategoryId) === catKey && state.subcategoryStack.length === 0) {
            renderCurrentGrid();
          }
        })
        .catch(() => {});
      return;
    }

    renderSkeletons(12, false);
    try {
      const res = await apiGet(`/api/channels?category_id=${encodeURIComponent(catKey)}${forceRefresh ? '&refresh=1' : ''}`);
      const filtered = (res.data || []).filter((c) => Number(c.is_hide || 0) === 0);
      state.channelsByCategory[catKey] = filtered;
      persistBootstrap();
      renderCurrentGrid();
      clearError();
    } catch (err) {
      showError(`Failed to load channels: ${err.message}`);
      renderCurrentGrid();
    }
  }

  async function drillIntoSubcategory(sub) {
    const p = presentCategory(sub);
    const subKey = String(sub.id);
    const rootId = state.subcategoryStack[0]?.rootCategoryId || state.activeCategoryId;
    renderSkeletons(10, false);

    if (sub.child_count && sub.child_count > 0) {
      try {
        const res = await apiGet(`/api/categories?id=${encodeURIComponent(subKey)}`);
        const children = res.data || [];
        if (children.length > 0) {
          state.subcategoryStack.push({ kind: 'subcats', id: subKey, rootCategoryId: rootId, title: p.title, items: children });
          renderCurrentGrid();
          return;
        }
      } catch (_) {}
    }

    try {
      const res = await apiGet(`/api/channels?category_id=${encodeURIComponent(subKey)}`);
      const filtered = (res.data || []).filter((c) => Number(c.is_hide || 0) === 0);
      state.subcategoryStack.push({ kind: 'channels', id: subKey, rootCategoryId: rootId, title: p.title, items: filtered });
      renderCurrentGrid();
      clearError();
    } catch (err) {
      showError(`Failed to load channels: ${err.message}`);
      renderCurrentGrid();
    }
  }

  // --- Playback ---
  function showPlayerDock(visible) {
    el.playerDock.classList.toggle('hidden', !visible);
    el.theaterBtn.classList.toggle('hidden', !visible);
    scheduleStageRectSync();
  }

  function closePlayer() {
    state.playToken += 1;
    state.currentMediaKey = null;
    state.servers = [];
    state.variants = [];
    stopActivePlayback();
    showPlayerDock(false);
    renderCurrentGrid();
  }

  function stopActivePlayback() {
    if (state.statsTimer) {
      clearInterval(state.statsTimer);
      state.statsTimer = null;
    }
    if (state.hls) {
      try { state.hls.destroy(); } catch (_) {}
      state.hls = null;
    }
    if (state.snifferActive) {
      state.snifferActive = false;
      state.snifferVisible = false;
      postNative({ type: 'sniffStop' });
    }

    rcas.stopLoop();
    el.rcasCanvas.classList.add('hidden');
    el.video.pause();
    el.video.removeAttribute('src');
    el.video.load();
    state.playbackHasFirstFrame = false;

    el.playerLoading.classList.add('hidden');
    el.statResWrap.classList.add('hidden');
    el.statBitrateWrap.classList.add('hidden');
    el.statModeWrap.classList.add('hidden');
  }

  function renderServerPills() {
    const show = state.servers.length > 0;
    el.serversGroup.classList.toggle('hidden', !show);
    el.fsServersSection.classList.toggle('hidden', !show);

    const targets = [el.serverPills, el.fsServerPills];
    targets.forEach((container) => {
      if (!container) return;
      container.innerHTML = '';
      state.servers.forEach((srv, idx) => {
        const btn = document.createElement('button');
        btn.type = 'button';
        btn.className = `ctrl-pill${idx === state.activeServerIdx ? ' active' : ''}`;
        const label = srv.name || `Server ${idx + 1}`;
        const tag = srv.probe_label ? `<span class="probe-tag">· ${escapeHtml(srv.probe_label)}</span>` : '';
        let dot = '';
        if (srv.probe_ok === true) dot = '<span class="probe-dot"></span>';
        else if (srv.probe_ok === false) dot = '<span class="probe-dot fail"></span>';
        btn.innerHTML = `${dot}<span>${escapeHtml(label)}</span>${tag}`;
        btn.addEventListener('click', () => {
          closeFsPopover();
          selectServerIndex(idx, state.playToken);
        });
        container.appendChild(btn);
      });
    });
  }

  function deduplicateVariants(rawVariants) {
    const videoOnly = rawVariants.filter((v) => !v.is_audio_only);
    const seen = new Set();
    const out = [];
    for (const v of videoOnly) {
      let height = 0;
      if (v.resolution) {
        const parts = String(v.resolution).toLowerCase().split('x');
        if (parts.length === 2) height = parseInt(parts[1], 10) || 0;
      }
      const fps = Math.round(Number(v.fps || 0));
      const bw = Number(v.avg_bandwidth || v.bandwidth || 0);
      const key = `${height}-${fps}-${bw}`;
      if (!seen.has(key)) {
        seen.add(key);
        out.push(v);
      }
    }
    return out;
  }

  function renderQualityPills() {
    const deduped = state.variants;
    const multiQuality = deduped.length > 1;
    el.qualityGroup.classList.toggle('hidden', !multiQuality);
    el.fsQualitySection.classList.toggle('hidden', !multiQuality);

    const currentLabel = state.activeVariantIndex == null
      ? (deduped.length === 1 ? (deduped[0].label || 'Live') : 'Auto')
      : (deduped.find((v) => v.index === state.activeVariantIndex)?.label || `${state.activeVariantIndex}`);
    el.fsQualityBtnLabel.textContent = currentLabel;

    if (!multiQuality) return;

    const targets = [el.qualityPills, el.fsQualityPills];
    targets.forEach((container) => {
      if (!container) return;
      container.innerHTML = '';

      const autoBtn = document.createElement('button');
      autoBtn.type = 'button';
      autoBtn.className = `ctrl-pill${state.activeVariantIndex == null ? ' active' : ''}`;
      autoBtn.textContent = 'Auto (Max)';
      autoBtn.addEventListener('click', () => {
        closeFsPopover();
        lockVariant(null);
      });
      container.appendChild(autoBtn);

      for (const v of deduped) {
        const btn = document.createElement('button');
        btn.type = 'button';
        btn.className = `ctrl-pill${state.activeVariantIndex === v.index ? ' active' : ''}`;
        btn.textContent = v.label || v.display_label || v.resolution || `Q${v.index}`;
        btn.addEventListener('click', () => {
          closeFsPopover();
          lockVariant(v.index);
        });
        container.appendChild(btn);
      }
    });
  }

  function lockVariant(variantIndex) {
    state.activeVariantIndex = variantIndex;
    renderQualityPills();
    if (!state.activeBaseProxyUrl) return;
    const targetUrl = variantIndex == null
      ? (state.autoVariantProxyUrl || state.activeBaseProxyUrl)
      : `${state.activeBaseProxyUrl}&variant=${variantIndex}`;
    startHlsPlayback(targetUrl, state.playToken, false);
  }

  function isInteractiveUrl(url, urlType) {
    if (Number(urlType) === 4) return true;
    try {
      const host = new URL(url).hostname.toLowerCase();
      return host.includes('youtube.com')
        || host.includes('youtu.be')
        || host.includes('dailymotion.com')
        || host.includes('twitch.tv');
    } catch (_) {
      return false;
    }
  }

  function buildServerOrder(resData, servers) {
    if (Array.isArray(resData.recommended_order) && resData.recommended_order.length) {
      const valid = resData.recommended_order.filter((i) => Number.isInteger(i) && i >= 0 && i < servers.length);
      for (let i = 0; i < servers.length; i += 1) {
        if (!valid.includes(i)) valid.push(i);
      }
      return valid;
    }
    const order = [];
    const rec = Number.isInteger(resData.recommended_index) ? resData.recommended_index : 0;
    if (rec >= 0 && rec < servers.length) order.push(rec);
    for (let i = 0; i < servers.length; i += 1) {
      if (!order.includes(i)) order.push(i);
    }
    return order;
  }

  async function playMedia(mediaType, mediaId, title, meta) {
    state.playToken += 1;
    const token = state.playToken;

    state.currentMediaKey = `${mediaType}:${mediaId}`;
    state.currentMediaType = mediaType;
    state.currentMediaId = mediaId;
    state.currentMediaTitle = title;
    state.currentMediaMeta = meta;
    state.servers = [];
    state.variants = [];
    state.activeVariantIndex = null;
    state.activeBaseProxyUrl = '';

    showPlayerDock(true);
    renderCurrentGrid();
    stopActivePlayback();

    el.playerLoading.classList.remove('hidden');
    el.loadingText.textContent = 'Resolving servers…';
    el.nowPlayingTitle.textContent = title;
    el.hudFsTitleText.textContent = title;
    el.nowPlayingMeta.textContent = meta || '';
    el.liveIndicator.textContent = 'CONNECTING';
    el.liveIndicator.classList.add('standby');
    renderServerPills();
    renderQualityPills();

    try {
      const res = await apiGet(`/api/stream?type=${encodeURIComponent(mediaType)}&id=${encodeURIComponent(mediaId)}`);
      if (token !== state.playToken) return;
      const servers = res.data || [];
      if (!servers.length) {
        closePlayer();
        showError('No live servers available for this stream.');
        return;
      }

      clearError();
      state.servers = servers;
      state.serverQueue = buildServerOrder(res, servers);
      state.serverQueuePos = 0;
      await selectServerIndex(state.serverQueue[0], token, true);
    } catch (err) {
      if (token !== state.playToken) return;
      closePlayer();
      showError(`Could not load stream: ${err.message}`);
    }
  }

  function tryAdvanceFallbackServer(token) {
    if (token !== state.playToken) return false;
    state.serverQueuePos += 1;
    if (state.serverQueuePos >= state.serverQueue.length) return false;
    const nextIdx = state.serverQueue[state.serverQueuePos];
    el.loadingText.textContent = `Switching to ${state.servers[nextIdx]?.name || `Server ${nextIdx + 1}`}…`;
    selectServerIndex(nextIdx, token, true);
    return true;
  }

  async function selectServerIndex(idx, token, allowFallback = false) {
    if (token !== state.playToken) return;
    const srv = state.servers[idx];
    if (!srv) return;

    state.activeServerIdx = idx;
    state.variants = [];
    state.activeVariantIndex = null;
    state.activeBaseProxyUrl = '';
    renderServerPills();
    renderQualityPills();

    stopActivePlayback();
    el.playerLoading.classList.remove('hidden');
    el.loadingText.textContent = `Connecting to ${srv.name || `Server ${idx + 1}`}…`;

    const urlType = Number(srv.url_type ?? 1);
    const rawUrl = srv.resolved_url || srv.url || '';
    const ua = srv.effective_ua || '';
    const ref = srv.effective_ref || '';
    const kw = srv.keyword || '';

    if (urlType === 4 || urlType === 5 || urlType === 6 || isInteractiveUrl(rawUrl, urlType)) {
      if (!isInteractiveUrl(rawUrl, urlType)) {
        try {
          el.loadingText.textContent = 'Extracting stream…';
          const q = `u=${encodeURIComponent(b64uEncode(rawUrl))}&ua=${encodeURIComponent(b64uEncode(ua))}&ref=${encodeURIComponent(b64uEncode(ref))}`;
          const ext = await apiGet(`/api/extract_m3u8?${q}`);
          if (token !== state.playToken) return;
          if (ext.ok && ext.found && ext.proxy_url) {
            await playProxyHlsUrl(ext.proxy_url, token, allowFallback);
            return;
          }
        } catch (_) {
          if (token !== state.playToken) return;
        }
      }

      if (isNativeHost) {
        state.sniffSessionId += 1;
        state.snifferActive = true;
        state.snifferVisible = isInteractiveUrl(rawUrl, urlType) || urlType === 5;
        scheduleStageRectSync();
        el.loadingText.textContent = 'Opening web stream…';
        postNative({
          type: 'sniffStart',
          sessionId: state.sniffSessionId,
          url: rawUrl,
          urlType,
          userAgent: ua,
          referer: ref,
          keyword: kw,
        });
        return;
      }

      if (srv.proxy_url) {
        await playProxyHlsUrl(srv.proxy_url, token, allowFallback);
      } else {
        el.playerLoading.classList.add('hidden');
        el.nowPlayingMeta.textContent = 'Interactive embed requires desktop YacineTV.exe.';
      }
      return;
    }

    const proxyUrl = srv.proxy_url || `/proxy/m3u8?u=${encodeURIComponent(b64uEncode(rawUrl))}&ua=${encodeURIComponent(b64uEncode(ua))}&ref=${encodeURIComponent(b64uEncode(ref))}`;
    await playProxyHlsUrl(proxyUrl, token, allowFallback);
  }

  async function playProxyHlsUrl(proxyUrl, token, allowFallback) {
    if (token !== state.playToken) return;
    const cleanBase = proxyUrl.replace(/&variant=\d+/gi, '');
    state.activeBaseProxyUrl = cleanBase;
    state.autoVariantProxyUrl = cleanBase;

    startHlsPlayback(cleanBase, token, allowFallback);
    fetchStrictVariants(cleanBase, token);
  }

  async function fetchStrictVariants(baseProxyUrl, token) {
    const qIdx = baseProxyUrl.indexOf('?');
    if (qIdx < 0) return;
    const qs = baseProxyUrl.slice(qIdx + 1);
    try {
      const res = await apiGet(`/api/variants?${qs}`);
      if (token !== state.playToken) return;
      if (res.ok && Array.isArray(res.variants)) {
        state.variants = deduplicateVariants(res.variants);
        if (res.auto_proxy_url) state.autoVariantProxyUrl = res.auto_proxy_url;
        renderQualityPills();
      }
    } catch (_) {}
  }

  function startHlsPlayback(streamUrl, token, allowFallback) {
    if (state.hls) {
      try { state.hls.destroy(); } catch (_) {}
      state.hls = null;
    }
    if (state.statsTimer) {
      clearInterval(state.statsTimer);
      state.statsTimer = null;
    }
    state.playbackHasFirstFrame = false;

    const markPlaying = () => {
      if (token !== state.playToken) return;
      state.playbackHasFirstFrame = true;
      el.playerLoading.classList.add('hidden');
      el.liveIndicator.textContent = 'LIVE';
      el.liveIndicator.classList.remove('standby');
      const srvName = state.servers[state.activeServerIdx]?.name || 'Direct';
      el.nowPlayingMeta.textContent = `Server: ${srvName}${state.currentMediaMeta ? ` · ${state.currentMediaMeta}` : ''}`;
      rcas.syncState();
    };

    if (window.Hls && window.Hls.isSupported()) {
      const hls = new window.Hls({
        enableWorker: true,
        lowLatencyMode: true,
        backBufferLength: 30,
        maxBufferLength: 24,
        maxMaxBufferLength: 60,
        manifestLoadingMaxRetry: 2,
        levelLoadingMaxRetry: 3,
        fragLoadingMaxRetry: 4,
      });
      state.hls = hls;
      let mediaRecoveredOnce = false;

      hls.on(window.Hls.Events.MANIFEST_PARSED, () => {
        if (token !== state.playToken) return;
        if (!state.variants.length && hls.levels && hls.levels.length > 1) {
          state.variants = deduplicateVariants(
            hls.levels.map((lvl, idx) => ({
              index: idx,
              label: lvl.height ? `${lvl.height}p` : `L${idx + 1}`,
              resolution: lvl.width && lvl.height ? `${lvl.width}x${lvl.height}` : '',
              bandwidth: lvl.bitrate || 0,
              fps: 0,
            }))
          );
          renderQualityPills();
        }
        el.video.play().catch(() => {});
      });

      hls.on(window.Hls.Events.FRAG_BUFFERED, markPlaying);

      hls.on(window.Hls.Events.ERROR, (_, data) => {
        if (token !== state.playToken || !data || !data.fatal) return;
        if (data.type === window.Hls.ErrorTypes.MEDIA_ERROR && !mediaRecoveredOnce) {
          mediaRecoveredOnce = true;
          hls.recoverMediaError();
          return;
        }
        if (allowFallback && !state.playbackHasFirstFrame && tryAdvanceFallbackServer(token)) return;
        el.playerLoading.classList.add('hidden');
        el.liveIndicator.textContent = 'OFFLINE';
        el.liveIndicator.classList.add('standby');
        showError(`Playback failed (${data.details || data.type}). Try another server.`);
      });

      hls.loadSource(streamUrl);
      hls.attachMedia(el.video);
    } else if (el.video.canPlayType('application/vnd.apple.mpegurl')) {
      el.video.src = streamUrl;
      el.video.play().catch(() => {});
    }

    state.statsTimer = setInterval(() => {
      if (token !== state.playToken) return;
      const vw = el.video.videoWidth || 0;
      const vh = el.video.videoHeight || 0;
      if (vw > 0 && vh > 0) {
        const aspect = (vw / vh).toFixed(2);
        el.statRes.textContent = `${vw}×${vh} (${aspect}:1)`;
        el.statResWrap.classList.remove('hidden');
      }
      if (state.hls) {
        const lvlIdx = state.hls.currentLevel >= 0 ? state.hls.currentLevel : state.hls.loadLevel;
        const lvl = lvlIdx >= 0 ? state.hls.levels?.[lvlIdx] : null;
        const bps = lvl?.bitrate || state.hls.bandwidthEstimate || 0;
        if (bps > 0) {
          el.statBitrate.textContent = `${(bps / 1_000_000).toFixed(1)} Mbps`;
          el.statBitrateWrap.classList.remove('hidden');
        }
      }
      rcas.syncState();
    }, 1000);
  }

  function loadBootstrapCache(boot) {
    if (!boot || typeof boot !== 'object') return false;
    let loaded = false;
    if (Array.isArray(boot.categories) && boot.categories.length) {
      state.categories = boot.categories;
      loaded = true;
    }
    if (boot.channelsByCategory && typeof boot.channelsByCategory === 'object') {
      state.channelsByCategory = boot.channelsByCategory;
    }
    if (Array.isArray(boot.events)) {
      state.events = boot.events;
      loaded = true;
    }
    return loaded;
  }

  async function refreshAll(forceNetwork = false) {
    clearError();
    const qs = forceNetwork ? '?refresh=1' : '';
    try {
      const [statusRes, catRes, evRes] = await Promise.all([
        apiGet('/api/status'),
        apiGet(`/api/categories${qs}`),
        apiGet(`/api/events${qs}`),
      ]);
      void statusRes;
      if (Array.isArray(catRes.data)) state.categories = catRes.data;
      if (Array.isArray(evRes.data)) state.events = evRes.data;

      persistBootstrap();
      updateSidebarNavHighlight();
      renderCurrentGrid();
    } catch (err) {
      showError(`Connection failed: ${err.message}`);
      renderCurrentGrid();
    }
  }

  function bindEvents() {
    if (window.matchMedia) {
      const mq = window.matchMedia('(prefers-color-scheme: dark)');
      mq.addEventListener?.('change', (e) => {
        state.systemIsDark = e.matches;
        if (state.settings.appearanceMode === 'auto') applyThemeUI();
      });
    }

    el.navEvents.addEventListener('click', switchToEvents);
    el.navFavorites.addEventListener('click', switchToFavorites);
    el.closePlayerBtn.addEventListener('click', closePlayer);

    el.backNavBtn.addEventListener('click', () => {
      if (state.subcategoryStack.length > 1) {
        state.subcategoryStack.pop();
        renderCurrentGrid();
      } else {
        state.subcategoryStack = [];
        switchToEvents();
      }
    });

    el.sidebarToggleBtn.addEventListener('click', () => {
      state.settings.sidebarCollapsed = !state.settings.sidebarCollapsed;
      applyLayoutPrefs();
      persistSettings();
    });

    el.sidebarOpenBtn.addEventListener('click', () => {
      state.settings.sidebarCollapsed = false;
      applyLayoutPrefs();
      persistSettings();
    });

    el.appearanceSegmented.addEventListener('click', (e) => {
      const btn = e.target.closest('.seg-btn');
      if (!btn) return;
      state.settings.appearanceMode = btn.dataset.appearance || 'auto';
      applyThemeUI();
      persistSettings();
    });

    el.theaterBtn.addEventListener('click', () => {
      state.settings.theaterMode = !state.settings.theaterMode;
      applyLayoutPrefs();
      persistSettings();
    });

    el.refreshBtn.addEventListener('click', () => {
      if (state.activeNav === 'category' && state.activeCategoryId) {
        const cat = state.categories.find((c) => String(c.id) === String(state.activeCategoryId));
        if (cat) openRootCategory(cat, true);
      } else {
        refreshAll(true);
      }
    });

    el.inlineErrorRetry.addEventListener('click', () => refreshAll(true));

    let searchTimer = null;
    const runSearch = async (q) => {
      if (!q) {
        el.searchClearBtn.classList.add('hidden');
        if (state.activeNav === 'search') switchToEvents();
        return;
      }
      el.searchClearBtn.classList.remove('hidden');
      state.activeNav = 'search';
      state.searchQuery = q;
      state.subcategoryStack = [];
      updateSidebarNavHighlight();
      renderSkeletons(8, false);
      try {
        const res = await apiGet(`/api/search?query=${encodeURIComponent(q)}`);
        if (state.searchQuery !== q) return;
        state._lastSearchResults = res.data || [];
        renderCurrentGrid();
        clearError();
      } catch (err) {
        showError(`Search error: ${err.message}`);
        state._lastSearchResults = [];
        renderCurrentGrid();
      }
    };

    el.searchInput.addEventListener('input', () => {
      const q = el.searchInput.value.trim();
      el.searchClearBtn.classList.toggle('hidden', q.length === 0);
      clearTimeout(searchTimer);
      searchTimer = setTimeout(() => runSearch(q), 260);
    });

    el.searchClearBtn.addEventListener('click', () => {
      el.searchInput.value = '';
      el.searchClearBtn.classList.add('hidden');
      switchToEvents();
    });

    const bindAspect = (container) => {
      container?.addEventListener('click', (e) => {
        const btn = e.target.closest('[data-aspect]');
        if (!btn) return;
        state.settings.aspectMode = btn.getAttribute('data-aspect');
        applyLayoutPrefs();
        persistSettings();
      });
    };
    const bindEnhance = (container) => {
      container?.addEventListener('click', (e) => {
        const btn = e.target.closest('[data-enhance]');
        if (!btn) return;
        state.settings.enhanceMode = btn.getAttribute('data-enhance');
        applyLayoutPrefs();
        persistSettings();
        rcas.syncState();
      });
    };
    bindAspect(el.aspectPills);
    bindAspect(el.fsAspectPills);
    bindEnhance(el.enhancePills);
    bindEnhance(el.fsEnhancePills);

    const syncPlayPauseIcons = () => {
      const paused = el.video.paused;
      el.videoStage.classList.toggle('paused', paused);
      el.iconPlay.classList.toggle('hidden', !paused);
      el.iconPause.classList.toggle('hidden', paused);
    };
    el.video.addEventListener('play', syncPlayPauseIcons);
    el.video.addEventListener('pause', syncPlayPauseIcons);
    el.video.addEventListener('loadeddata', () => {
      el.playerLoading.classList.add('hidden');
      rcas.syncState();
    });
    el.video.addEventListener('dblclick', toggleFullscreen);

    el.playPauseBtn.addEventListener('click', () => {
      if (el.video.paused) el.video.play().catch(() => {});
      else el.video.pause();
    });

    const syncMuteIcons = () => {
      const muted = el.video.muted || el.video.volume === 0;
      el.iconVolOn.classList.toggle('hidden', muted);
      el.iconVolOff.classList.toggle('hidden', !muted);
    };
    el.muteBtn.addEventListener('click', () => {
      el.video.muted = !el.video.muted;
      syncMuteIcons();
    });
    el.volumeSlider.addEventListener('input', () => {
      el.video.volume = Number(el.volumeSlider.value);
      el.video.muted = el.video.volume === 0;
      syncMuteIcons();
    });

    el.pipBtn.addEventListener('click', () => {
      if (document.pictureInPictureElement) {
        document.exitPictureInPicture().catch(() => {});
      } else if (el.video.requestPictureInPicture) {
        el.video.requestPictureInPicture().catch(() => {});
      }
    });

    el.fullscreenBtn.addEventListener('click', toggleFullscreen);

    el.fsQualityBtn.addEventListener('click', (e) => {
      e.stopPropagation();
      const willOpen = el.fsPopover.classList.contains('hidden');
      el.fsPopover.classList.toggle('hidden', !willOpen);
      el.videoStage.classList.toggle('popover-open', willOpen);
    });

    el.videoStage.addEventListener('mousemove', () => {
      if (!state.isFullscreen) return;
      if (isNativeHost) {
        postNative({ type: 'fullscreenMouseMove' });
      } else {
        setFullscreenHudVisible(true);
        clearTimeout(browserFsHudTimer);
        browserFsHudTimer = setTimeout(() => setFullscreenHudVisible(false), 2500);
      }
    });

    el.videoStage.addEventListener('click', (e) => {
      if (!el.fsPopover.contains(e.target) && !el.fsQualityBtn.contains(e.target)) {
        closeFsPopover();
      }
    });

    document.addEventListener('fullscreenchange', () => {
      if (!isNativeHost) updateFullscreenUI(Boolean(document.fullscreenElement));
    });

    document.addEventListener('keydown', (e) => {
      if (e.key === 'F11') {
        e.preventDefault();
        toggleFullscreen();
      } else if (e.key === 'Escape' && state.isFullscreen) {
        e.preventDefault();
        if (isNativeHost) postNative({ type: 'setFullscreen', value: false });
        else document.exitFullscreen?.().catch(() => {});
      } else if (e.key === ' ' && document.activeElement === el.videoStage) {
        e.preventDefault();
        if (el.video.paused) el.video.play().catch(() => {});
        else el.video.pause();
      }
    });

    if (typeof ResizeObserver !== 'undefined') {
      const ro = new ResizeObserver(scheduleStageRectSync);
      ro.observe(el.videoStage);
    }
    window.addEventListener('resize', scheduleStageRectSync);
    el.contentBrowser.addEventListener('scroll', scheduleStageRectSync);

    state.matchCountdownTimer = setInterval(() => {
      if (state.activeNav === 'events' && state.events.length) {
        renderEventsGrid();
      }
    }, 30_000);

    if (isNativeHost) {
      window.chrome.webview.addEventListener('message', (ev) => {
        const msg = ev.data;
        if (!msg || typeof msg !== 'object') return;
        switch (msg.type) {
          case 'initState':
            if (msg.settings) Object.assign(state.settings, msg.settings);
            if (typeof msg.effectiveIsDark === 'boolean') state.systemIsDark = msg.effectiveIsDark;
            if (Array.isArray(msg.favorites)) state.favorites = msg.favorites;
            updateFullscreenUI(Boolean(msg.isFullscreen));
            applyThemeUI();
            applyLayoutPrefs();
            if (loadBootstrapCache(msg.bootstrap)) {
              updateSidebarNavHighlight();
              renderCurrentGrid();
            } else {
              renderSkeletons(8, true);
            }
            refreshAll(false);
            break;

          case 'systemThemeChanged':
            if (typeof msg.effectiveIsDark === 'boolean') state.systemIsDark = msg.effectiveIsDark;
            applyThemeUI();
            break;

          case 'fullscreenChanged':
            updateFullscreenUI(Boolean(msg.isFullscreen));
            break;

          case 'fullscreenHudVisible':
            setFullscreenHudVisible(Boolean(msg.visible));
            break;

          case 'snifferState':
            if (msg.sessionId !== state.sniffSessionId || !state.snifferActive) break;
            state.snifferVisible = Boolean(msg.visible);
            if (state.snifferVisible) {
              el.playerLoading.classList.add('hidden');
              el.liveIndicator.textContent = 'LIVE';
              el.liveIndicator.classList.remove('standby');
              rcas.syncState();
              scheduleStageRectSync();
            }
            break;

          case 'sniffUpgraded':
            if (msg.sessionId !== state.sniffSessionId || !state.snifferActive) break;
            state.snifferActive = false;
            state.snifferVisible = false;
            el.loadingText.textContent = 'Loading stream…';
            playProxyHlsUrl(msg.proxyUrl, state.playToken, false);
            break;

          default:
            break;
        }
      });
    }
  }

  function init() {
    bindEvents();
    showPlayerDock(false);

    if (isNativeHost) {
      applyThemeUI();
      applyLayoutPrefs();
      renderSkeletons(8, true);
      postNative({ type: 'ready' });
    } else {
      try {
        const s = JSON.parse(localStorage.getItem(STORAGE_KEYS.settings) || 'null');
        if (s) Object.assign(state.settings, s);
        const f = JSON.parse(localStorage.getItem(STORAGE_KEYS.favorites) || 'null');
        if (Array.isArray(f)) state.favorites = f;
        const b = JSON.parse(localStorage.getItem(STORAGE_KEYS.bootstrap) || 'null');
        if (loadBootstrapCache(b)) {
          updateSidebarNavHighlight();
          renderCurrentGrid();
        } else {
          renderSkeletons(8, true);
        }
      } catch (_) {
        renderSkeletons(8, true);
      }
      applyThemeUI();
      applyLayoutPrefs();
      refreshAll(false);
    }
  }

  document.addEventListener('DOMContentLoaded', init);
})();

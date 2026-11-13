/**
 * Yacine TV Native macOS Widescreen Client
 */

(() => {
  const state = {
    activeTab: "live", // 'live' | 'events' | 'favorites' | 'search'
    categories: [],
    currentCategory: null,
    parentCategory: null,
    channels: [],
    events: [],
    favorites: JSON.parse(localStorage.getItem("yacine_mac_favorites") || "[]"),
    activeStreams: [],
    activeStreamIdx: 0,
    activePlayingId: null,
    hlsInstance: null,
  };

  // DOM Elements
  const els = {
    tabLive: document.getElementById("tab-live"),
    tabEvents: document.getElementById("tab-events"),
    tabFavorites: document.getElementById("tab-favorites"),
    eventsCountBadge: document.getElementById("events-count-badge"),
    favCountBadge: document.getElementById("fav-count-badge"),
    categoryList: document.getElementById("category-list"),
    apiStatusDot: document.getElementById("api-status-dot"),
    apiStatusText: document.getElementById("api-status-text"),
    resolutionInfo: document.getElementById("resolution-info"),
    subcatBackBtn: document.getElementById("subcat-back-btn"),
    sectionTitle: document.getElementById("current-section-title"),
    sectionSubtitle: document.getElementById("current-section-subtitle"),
    searchInput: document.getElementById("global-search-input"),
    theaterBtn: document.getElementById("toggle-theater-btn"),
    refreshBtn: document.getElementById("refresh-btn"),
    playerDock: document.getElementById("player-dock"),
    videoStage: document.getElementById("video-stage"),
    video: document.getElementById("hls-video"),
    idleOverlay: document.getElementById("player-idle-overlay"),
    loadingOverlay: document.getElementById("player-loading-overlay"),
    loadingText: document.getElementById("player-loading-text"),
    nowPlayingTitle: document.getElementById("now-playing-title"),
    nowPlayingMeta: document.getElementById("now-playing-meta"),
    serverPills: document.getElementById("server-pills"),
    qualityPills: document.getElementById("quality-pills"),
    pipBtn: document.getElementById("pip-btn"),
    fullscreenBtn: document.getElementById("fullscreen-btn"),
    statRes: document.getElementById("stat-res"),
    statEngine: document.getElementById("stat-engine"),
    gridContainer: document.getElementById("grid-container"),
  };

  function updateScreenMetrics() {
    const dpr = window.devicePixelRatio || 1;
    els.resolutionInfo.textContent = `Display ${window.screen.width}×${window.screen.height} (@${dpr}x Retina) · 16:9 Locked`;
  }

  function saveFavorites() {
    localStorage.setItem("yacine_mac_favorites", JSON.stringify(state.favorites));
    els.favCountBadge.textContent = String(state.favorites.length);
  }

  function isFavorited(channelId) {
    return state.favorites.some((c) => String(c.id) === String(channelId));
  }

  function toggleFavorite(channelObj, ev) {
    if (ev) ev.stopPropagation();
    const idStr = String(channelObj.id);
    const idx = state.favorites.findIndex((c) => String(c.id) === idStr);
    if (idx >= 0) {
      state.favorites.splice(idx, 1);
    } else {
      state.favorites.push({
        id: channelObj.id,
        name: channelObj.name,
        logo: channelObj.logo || "",
      });
    }
    saveFavorites();
    if (state.activeTab === "favorites") {
      renderChannelsGrid(state.favorites);
    } else {
      const btn = document.querySelector(`.fav-toggle-btn[data-fav-id="${CSS.escape(idStr)}"]`);
      if (btn) {
        btn.classList.toggle("favorited", isFavorited(idStr));
        btn.textContent = isFavorited(idStr) ? "★" : "☆";
      }
    }
  }

  async function apiFetch(url) {
    const res = await fetch(url);
    if (!res.ok) {
      throw new Error(`HTTP ${res.status}`);
    }
    return res.json();
  }

  function renderCategorySidebar() {
    els.categoryList.innerHTML = "";
    state.categories.forEach((cat) => {
      const btn = document.createElement("button");
      btn.type = "button";
      btn.className = "cat-item" + (state.currentCategory && String(state.currentCategory.id) === String(cat.id) ? " active" : "");
      const nameSpan = document.createElement("span");
      nameSpan.className = "cat-item-name";
      nameSpan.textContent = cat.name;
      btn.appendChild(nameSpan);

      if (Number(cat.child_count) > 0) {
        const badge = document.createElement("span");
        badge.className = "cat-sub-badge";
        badge.textContent = `${cat.child_count}`;
        btn.appendChild(badge);
      }

      btn.addEventListener("click", () => {
        setActiveTab("live", false);
        state.parentCategory = null;
        selectCategory(cat);
      });
      els.categoryList.appendChild(btn);
    });
  }

  async function selectCategory(cat, parentCat = null) {
    state.currentCategory = cat;
    state.parentCategory = parentCat;
    renderCategorySidebar();

    if (parentCat) {
      els.subcatBackBtn.classList.remove("hidden");
      els.sectionTitle.textContent = `${parentCat.name} › ${cat.name}`;
    } else {
      els.subcatBackBtn.classList.add("hidden");
      els.sectionTitle.textContent = cat.name;
    }

    els.gridContainer.classList.remove("events-mode");
    els.gridContainer.innerHTML = `<div class="muted-hint">Loading ${cat.name}...</div>`;

    try {
      if (Number(cat.child_count) > 0) {
        els.sectionSubtitle.textContent = `Select a region or package (${cat.child_count} subcategories)`;
        const subData = await apiFetch(`/api/categories?id=${encodeURIComponent(cat.id)}`);
        const subcats = subData.data || [];
        renderSubcategoriesGrid(subcats, cat);
      } else {
        const chData = await apiFetch(`/api/channels?category_id=${encodeURIComponent(cat.id)}`);
        const channels = (chData.data || []).filter((c) => !c.is_hide);
        state.channels = channels;
        els.sectionSubtitle.textContent = `${channels.length} live channels available`;
        renderChannelsGrid(channels);
      }
    } catch (err) {
      els.gridContainer.innerHTML = `<div class="muted-hint">Error loading category: ${err.message}</div>`;
    }
  }

  function makeInitials(name) {
    return (name || "TV")
      .split(/\s+/)
      .slice(0, 2)
      .map((w) => w[0] || "")
      .join("")
      .toUpperCase();
  }

  function renderSubcategoriesGrid(subcats, parentCat) {
    els.gridContainer.innerHTML = "";
    subcats.forEach((sc) => {
      const card = document.createElement("div");
      card.className = "channel-card";

      const logoBox = document.createElement("div");
      logoBox.className = "channel-logo-box";
      if (sc.logo) {
        const img = document.createElement("img");
        img.src = sc.logo;
        img.alt = sc.name;
        img.loading = "lazy";
        img.onerror = () => {
          logoBox.innerHTML = `<span class="channel-fallback-badge">${makeInitials(sc.name)}</span>`;
        };
        logoBox.appendChild(img);
      } else {
        logoBox.innerHTML = `<span class="channel-fallback-badge">${makeInitials(sc.name)}</span>`;
      }

      const title = document.createElement("div");
      title.className = "channel-name";
      title.textContent = sc.name;

      card.appendChild(logoBox);
      card.appendChild(title);
      card.addEventListener("click", () => selectCategory(sc, parentCat));
      els.gridContainer.appendChild(card);
    });
  }

  function renderChannelsGrid(channels) {
    els.gridContainer.classList.remove("events-mode");
    els.gridContainer.innerHTML = "";
    if (!channels || channels.length === 0) {
      els.gridContainer.innerHTML = `<div class="muted-hint">No channels found in this view.</div>`;
      return;
    }

    channels.forEach((ch) => {
      const card = document.createElement("div");
      const idStr = String(ch.id);
      card.className = "channel-card" + (state.activePlayingId === `channel:${idStr}` ? " playing" : "");
      card.dataset.cardId = `channel:${idStr}`;

      const favBtn = document.createElement("button");
      favBtn.type = "button";
      const fav = isFavorited(idStr);
      favBtn.className = "fav-toggle-btn" + (fav ? " favorited" : "");
      favBtn.dataset.favId = idStr;
      favBtn.title = "Toggle Favorite";
      favBtn.textContent = fav ? "★" : "☆";
      favBtn.addEventListener("click", (ev) => toggleFavorite(ch, ev));

      const logoBox = document.createElement("div");
      logoBox.className = "channel-logo-box";
      if (ch.logo) {
        const img = document.createElement("img");
        img.src = ch.logo;
        img.alt = ch.name;
        img.loading = "lazy";
        img.onerror = () => {
          logoBox.innerHTML = `<span class="channel-fallback-badge">${makeInitials(ch.name)}</span>`;
        };
        logoBox.appendChild(img);
      } else {
        logoBox.innerHTML = `<span class="channel-fallback-badge">${makeInitials(ch.name)}</span>`;
      }

      const title = document.createElement("div");
      title.className = "channel-name";
      title.textContent = ch.name;

      card.appendChild(favBtn);
      card.appendChild(logoBox);
      card.appendChild(title);
      card.addEventListener("click", () => loadAndPlayItem("channel", ch.id, ch.name, ch.logo));
      els.gridContainer.appendChild(card);
    });
  }

  function formatMatchTime(unixSec) {
    if (!unixSec) return "LIVE";
    const dt = new Date(Number(unixSec) * 1000);
    return dt.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
  }

  function renderEventsGrid(events) {
    els.gridContainer.classList.add("events-mode");
    els.gridContainer.innerHTML = "";
    if (!events || events.length === 0) {
      els.gridContainer.innerHTML = `<div class="muted-hint">No matches scheduled right now.</div>`;
      return;
    }

    const nowSec = Math.floor(Date.now() / 1000);
    events.forEach((ev) => {
      const idStr = String(ev.id);
      const isLive = nowSec >= Number(ev.start_time) && nowSec <= Number(ev.end_time);
      const card = document.createElement("div");
      card.className = "event-card" + (state.activePlayingId === `event:${idStr}` ? " playing" : "");
      card.dataset.cardId = `event:${idStr}`;

      const t1 = ev.team_1 || { name: "Team 1", logo: "" };
      const t2 = ev.team_2 || { name: "Team 2", logo: "" };

      card.innerHTML = `
        <div class="event-top-bar">
          <span class="event-champ">${ev.champions || "Live Match"}</span>
          <span class="event-status-badge ${isLive ? "is-live" : ""}">${isLive ? "● LIVE NOW" : formatMatchTime(ev.start_time)}</span>
        </div>
        <div class="event-teams-row">
          <div class="team-col">
            <img class="team-logo" src="${t1.logo || "/logo.png"}" alt="${t1.name}" loading="lazy" />
            <span class="team-name">${t1.name}</span>
          </div>
          <div class="vs-box">
            <span class="vs-time">${formatMatchTime(ev.start_time)}</span>
            <span class="vs-label">VS</span>
          </div>
          <div class="team-col">
            <img class="team-logo" src="${t2.logo || "/logo.png"}" alt="${t2.name}" loading="lazy" />
            <span class="team-name">${t2.name}</span>
          </div>
        </div>
        <div class="event-footer">
          <span>📺 ${ev.channel || "Live Feed"}</span>
          <span>🎙️ ${ev.commentary || "Live Audio"}</span>
        </div>
      `;

      const matchTitle = `${t1.name} vs ${t2.name} (${ev.channel || "Live"})`;
      card.addEventListener("click", () => loadAndPlayItem("event", ev.id, matchTitle, ""));
      els.gridContainer.appendChild(card);
    });
  }

  async function loadAndPlayItem(kind, id, title, logoUrl) {
    state.activePlayingId = `${kind}:${id}`;
    document.querySelectorAll(".channel-card, .event-card").forEach((el) => {
      el.classList.toggle("playing", el.dataset.cardId === state.activePlayingId);
    });

    els.idleOverlay.classList.add("hidden");
    els.loadingOverlay.classList.remove("hidden");
    els.loadingText.textContent = `Fetching encrypted stream keys for ${title}...`;
    els.nowPlayingTitle.textContent = title;
    els.nowPlayingMeta.textContent = `Resolving servers via Yacine TV API (${kind} #${id})...`;

    try {
      const resp = await apiFetch(`/api/stream?type=${encodeURIComponent(kind)}&id=${encodeURIComponent(id)}`);
      const streams = resp.data || [];
      if (streams.length === 0) {
        els.loadingOverlay.classList.add("hidden");
        els.nowPlayingMeta.textContent = "No active stream servers returned for this item.";
        return;
      }

      state.activeStreams = streams;
      state.activeStreamIdx = 0;
      renderServerPills();
      startStreamPlayback(0);
    } catch (err) {
      els.loadingOverlay.classList.add("hidden");
      els.nowPlayingMeta.textContent = `Failed to load stream: ${err.message}`;
    }
  }

  function renderServerPills() {
    els.serverPills.innerHTML = "";
    state.activeStreams.forEach((s, idx) => {
      const btn = document.createElement("button");
      btn.type = "button";
      btn.className = "ctrl-pill" + (idx === state.activeStreamIdx ? " active" : "");
      btn.textContent = s.name || `Server ${idx + 1}`;
      btn.addEventListener("click", () => {
        state.activeStreamIdx = idx;
        renderServerPills();
        startStreamPlayback(idx);
      });
      els.serverPills.appendChild(btn);
    });
  }

  function renderQualityPills(hls) {
    els.qualityPills.innerHTML = "";
    if (!hls || !hls.levels || hls.levels.length <= 1) {
      const span = document.createElement("span");
      span.className = "ctrl-pill active";
      span.textContent = "Direct Source (Native HD)";
      els.qualityPills.appendChild(span);
      return;
    }

    const autoBtn = document.createElement("button");
    autoBtn.type = "button";
    autoBtn.className = "ctrl-pill" + (hls.currentLevel === -1 ? " active" : "");
    autoBtn.textContent = "Auto";
    autoBtn.addEventListener("click", () => {
      hls.currentLevel = -1;
      renderQualityPills(hls);
    });
    els.qualityPills.appendChild(autoBtn);

    hls.levels.forEach((lvl, idx) => {
      const btn = document.createElement("button");
      btn.type = "button";
      btn.className = "ctrl-pill" + (hls.currentLevel === idx ? " active" : "");
      const label = lvl.height ? `${lvl.height}p` : `Level ${idx + 1}`;
      btn.textContent = label;
      btn.addEventListener("click", () => {
        hls.currentLevel = idx;
        renderQualityPills(hls);
      });
      els.qualityPills.appendChild(btn);
    });
  }

  function startStreamPlayback(streamIdx) {
    const stream = state.activeStreams[streamIdx];
    if (!stream) return;

    const proxyUrl = stream.proxy_url;
    els.loadingOverlay.classList.remove("hidden");
    els.loadingText.textContent = `Connecting to ${stream.name || "Server"}...`;
    els.nowPlayingMeta.textContent = `Server: ${stream.name || "Default"} · Widescreen Aspect-Locked`;

    if (state.hlsInstance) {
      state.hlsInstance.destroy();
      state.hlsInstance = null;
    }

    if (window.Hls && window.Hls.isSupported()) {
      const hls = new window.Hls({
        enableWorker: true,
        lowLatencyMode: true,
        backBufferLength: 60,
      });
      state.hlsInstance = hls;
      hls.loadSource(proxyUrl);
      hls.attachMedia(els.video);

      hls.on(window.Hls.Events.MANIFEST_PARSED, () => {
        els.loadingOverlay.classList.add("hidden");
        renderQualityPills(hls);
        els.video.play().catch(() => {});
      });

      hls.on(window.Hls.Events.LEVEL_SWITCHED, () => {
        updateVideoDiagnostics();
      });

      hls.on(window.Hls.Events.ERROR, (_event, data) => {
        if (data.fatal) {
          if (data.type === window.Hls.ErrorTypes.NETWORK_ERROR) {
            hls.startLoad();
          } else if (data.type === window.Hls.ErrorTypes.MEDIA_ERROR) {
            hls.recoverMediaError();
          } else {
            // Try fallback to native playback or next server
            els.loadingOverlay.classList.add("hidden");
            els.nowPlayingMeta.textContent = `Stream error (${data.details}) — try switching server pill above.`;
          }
        }
      });
    } else if (els.video.canPlayType("application/vnd.apple.mpegurl")) {
      els.video.src = proxyUrl;
      els.video.addEventListener(
        "loadedmetadata",
        () => {
          els.loadingOverlay.classList.add("hidden");
          els.video.play().catch(() => {});
        },
        { once: true }
      );
    }
  }

  function updateVideoDiagnostics() {
    const w = els.video.videoWidth;
    const h = els.video.videoHeight;
    if (w && h) {
      els.statRes.textContent = `${w}×${h} (${(w / h).toFixed(2)}:1)`;
    }
  }

  els.video.addEventListener("loadedmetadata", updateVideoDiagnostics);
  els.video.addEventListener("resize", updateVideoDiagnostics);
  els.video.addEventListener("playing", () => {
    els.loadingOverlay.classList.add("hidden");
    updateVideoDiagnostics();
  });

  function setActiveTab(tabName, triggerRender = true) {
    state.activeTab = tabName;
    els.tabLive.classList.toggle("active", tabName === "live");
    els.tabEvents.classList.toggle("active", tabName === "events");
    els.tabFavorites.classList.toggle("active", tabName === "favorites");

    if (!triggerRender) return;

    if (tabName === "live") {
      if (state.currentCategory) {
        selectCategory(state.currentCategory, state.parentCategory);
      } else if (state.categories.length > 0) {
        selectCategory(state.categories[0]);
      }
    } else if (tabName === "events") {
      els.subcatBackBtn.classList.add("hidden");
      els.sectionTitle.textContent = "Today's Live Matches & Events";
      els.sectionSubtitle.textContent = `${state.events.length} matches listed — click any match to watch live`;
      renderEventsGrid(state.events);
    } else if (tabName === "favorites") {
      els.subcatBackBtn.classList.add("hidden");
      els.sectionTitle.textContent = "Favorite Channels";
      els.sectionSubtitle.textContent = `${state.favorites.length} saved channels`;
      renderChannelsGrid(state.favorites);
    }
  }

  // Event Listeners
  els.tabLive.addEventListener("click", () => setActiveTab("live"));
  els.tabEvents.addEventListener("click", () => setActiveTab("events"));
  els.tabFavorites.addEventListener("click", () => setActiveTab("favorites"));

  els.subcatBackBtn.addEventListener("click", () => {
    if (state.parentCategory) {
      selectCategory(state.parentCategory, null);
    }
  });

  // Aspect Ratio Controls
  document.querySelectorAll("[data-aspect]").forEach((btn) => {
    btn.addEventListener("click", () => {
      document.querySelectorAll("[data-aspect]").forEach((b) => b.classList.remove("active"));
      btn.classList.add("active");
      els.video.style.objectFit = btn.dataset.aspect;
    });
  });

  // Theater Mode
  els.theaterBtn.addEventListener("click", () => {
    els.playerDock.classList.toggle("theater");
    els.theaterBtn.classList.toggle("active");
  });

  // Picture-in-Picture
  els.pipBtn.addEventListener("click", async () => {
    try {
      if (document.pictureInPictureElement) {
        await document.exitPictureInPicture();
      } else if (els.video.readyState >= 1) {
        await els.video.requestPictureInPicture();
      }
    } catch (e) {
      console.warn("PiP error:", e);
    }
  });

  // Fullscreen
  els.fullscreenBtn.addEventListener("click", () => {
    if (!document.fullscreenElement) {
      els.videoStage.requestFullscreen().catch(() => {});
    } else {
      document.exitFullscreen().catch(() => {});
    }
  });

  // Search with debounce
  let searchTimer = null;
  els.searchInput.addEventListener("input", () => {
    clearTimeout(searchTimer);
    const q = els.searchInput.value.trim();
    if (!q) {
      setActiveTab("live");
      return;
    }
    searchTimer = setTimeout(async () => {
      els.sectionTitle.textContent = `Search: "${q}"`;
      els.sectionSubtitle.textContent = "Searching across all Yacine TV packages...";
      try {
        const res = await apiFetch(`/api/search?query=${encodeURIComponent(q)}`);
        const found = (res.data || []).filter((c) => !c.is_hide);
        els.sectionSubtitle.textContent = `Found ${found.length} matching channels`;
        renderChannelsGrid(found);
      } catch (err) {
        els.sectionSubtitle.textContent = `Search error: ${err.message}`;
      }
    }, 260);
  });

  els.refreshBtn.addEventListener("click", () => bootstrap(true));
  window.addEventListener("resize", updateScreenMetrics);

  async function bootstrap(preserveSelection = false) {
    updateScreenMetrics();
    saveFavorites();

    try {
      const [statusData, catData, evtData] = await Promise.all([
        apiFetch("/api/status"),
        apiFetch("/api/categories"),
        apiFetch("/api/events").catch(() => ({ data: [] })),
      ]);

      els.apiStatusDot.classList.add("online");
      els.apiStatusText.textContent = `Connected (${statusData.active_host})`;
      state.categories = catData.data || [];
      state.events = evtData.data || [];
      els.eventsCountBadge.textContent = String(state.events.length);

      renderCategorySidebar();

      if (preserveSelection && state.currentCategory) {
        await selectCategory(state.currentCategory, state.parentCategory);
      } else if (state.categories.length > 0) {
        await selectCategory(state.categories[0]);
        // Automatically load the first channel's stream so the player is ready immediately
        if (state.channels && state.channels.length > 0 && !state.activePlayingId) {
          const firstCh = state.channels[0];
          loadAndPlayItem("channel", firstCh.id, firstCh.name, firstCh.logo);
        }
      }
    } catch (err) {
      els.apiStatusDot.classList.remove("online");
      els.apiStatusText.textContent = `Connection Error: ${err.message}`;
    }
  }

  bootstrap();
})();

import Foundation
import WinSDK
import CWebView2Bridge

final class WebSnifferController {
    static let revealTimerId: UINT_PTR = 1001

    private weak var ownerWindow: MainWindow?
    private let hwnd: HWND
    private let userDataDir: URL
    private let backendBaseURL: () -> String
    private var handle: OpaquePointer?

    private(set) var currentSessionId: Int = 0
    private var activeTargetUrl: String = ""
    private var activeReferer: String = ""
    private var activeUserAgent: String = ""
    private var activeKeyword: String = ""
    private var autoUpgradeEnabled: Bool = false
    private var isVisible: Bool = false
    private var hasUpgraded: Bool = false
    private var stageRect: (x: Int32, y: Int32, w: Int32, h: Int32) = (0, 0, 0, 0)
    private var isDark: Bool = true

    private var cookieRequestSeq: UInt64 = 0
    private var pendingCookieWork: [UInt64: (sessionId: Int, streamUrl: String, referer: String, ua: String)] = [:]
    private var firstCookieList: [UInt64: [[String: String]]] = [:]

    init(owner: MainWindow, hwnd: HWND, userDataDir: URL, isDark: Bool, backendBaseURL: @escaping () -> String) {
        self.ownerWindow = owner
        self.hwnd = hwnd
        self.userDataDir = userDataDir
        self.isDark = isDark
        self.backendBaseURL = backendBaseURL

        try? FileManager.default.createDirectory(at: userDataDir, withIntermediateDirectories: true)

        var callbacks = WV2Callbacks()
        callbacks.ctx = Unmanaged.passUnretained(self).toOpaque()
        callbacks.onReady = { ctx, ok in
            guard let ctx, ok else { return }
            let me = Unmanaged<WebSnifferController>.fromOpaque(ctx).takeUnretainedValue()
            me.onReady()
        }
        callbacks.onMessage = { ctx, jsonPtr in
            guard let ctx, let jsonPtr else { return }
            let me = Unmanaged<WebSnifferController>.fromOpaque(ctx).takeUnretainedValue()
            me.onWebMessage(String(cString: jsonPtr))
        }
        callbacks.onFullscreenChanged = { ctx, isFs in
            guard let ctx else { return }
            let me = Unmanaged<WebSnifferController>.fromOpaque(ctx).takeUnretainedValue()
            me.ownerWindow?.setFullscreen(isFs)
        }
        callbacks.onKeyDown = { ctx, vkey in
            guard let ctx else { return false }
            let me = Unmanaged<WebSnifferController>.fromOpaque(ctx).takeUnretainedValue()
            if vkey == UInt32(VK_F11) {
                me.ownerWindow?.toggleFullscreen()
                return true
            }
            if vkey == UInt32(VK_ESCAPE), me.ownerWindow?.isFullscreen == true {
                me.ownerWindow?.setFullscreen(false)
                return true
            }
            return false
        }

        self.handle = userDataDir.path.withCString { udf in
            wv2_create(
                UnsafeMutableRawPointer(hwnd),
                udf,
                0, 0, 0, 0,
                false,
                false,
                true,
                callbacks
            )
        }
        if let handle {
            wv2_set_background_color(handle, 255, 0, 0, 0)
            wv2_set_preferred_color_scheme(handle, isDark ? 2 : 1)
        }
    }

    deinit {
        KillTimer(hwnd, Self.revealTimerId)
        if let handle {
            wv2_destroy(handle)
        }
    }

    func updateTheme(isDark: Bool) {
        self.isDark = isDark
        if let handle {
            wv2_set_preferred_color_scheme(handle, isDark ? 2 : 1)
        }
    }

    func updateStageRect(x: Int32, y: Int32, width: Int32, height: Int32) {
        stageRect = (x, y, max(0, width), max(0, height))
        syncVisibilityAndBounds()
    }

    func notifyParentMoved() {
        if let handle {
            wv2_notify_parent_window_position_changed(handle)
        }
    }

    func start(
        sessionId: Int,
        url: String,
        urlType: Int,
        userAgent: String,
        referer: String,
        keyword: String
    ) {
        KillTimer(hwnd, Self.revealTimerId)
        currentSessionId = sessionId
        activeTargetUrl = url
        activeUserAgent = userAgent.isEmpty
            ? "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
            : userAgent
        activeReferer = referer
        activeKeyword = keyword
        hasUpgraded = false

        let interactive = Self.isInteractiveOnly(url: url, urlType: urlType)
        autoUpgradeEnabled = !interactive && (urlType == 5 || urlType == 6)

        if let handle {
            activeUserAgent.withCString { wv2_set_user_agent(handle, $0) }
            let script = Self.buildHookScript(sessionId: sessionId, keyword: keyword, referer: referer)
            script.withCString { wv2_set_doc_script(handle, $0) }
        }

        if interactive {
            isVisible = true
            syncVisibilityAndBounds()
            let finalURL = Self.youtubeEmbedURLIfNeeded(url) ?? url
            navigateWithOptionalReferer(finalURL, referer: referer)
            ownerWindow?.postToMain([
                "type": "snifferState",
                "sessionId": sessionId,
                "visible": true,
                "interactive": true,
                "revealedFallback": false,
            ])
        } else if urlType == 5 {
            isVisible = true
            syncVisibilityAndBounds()
            navigateWithOptionalReferer(url, referer: referer)
            ownerWindow?.postToMain([
                "type": "snifferState",
                "sessionId": sessionId,
                "visible": true,
                "interactive": false,
                "revealedFallback": false,
            ])
        } else {
            // Hidden sniffer mode (url_type == 6); reveal after 6s if no HLS/DASH stream sniffed
            isVisible = false
            syncVisibilityAndBounds()
            navigateWithOptionalReferer(url, referer: referer)
            SetTimer(hwnd, Self.revealTimerId, 6000, nil)
            ownerWindow?.postToMain([
                "type": "snifferState",
                "sessionId": sessionId,
                "visible": false,
                "interactive": false,
                "revealedFallback": false,
            ])
        }
    }

    func stop() {
        KillTimer(hwnd, Self.revealTimerId)
        currentSessionId += 1
        autoUpgradeEnabled = false
        hasUpgraded = true
        isVisible = false
        syncVisibilityAndBounds()
        if let handle {
            "about:blank".withCString { wv2_navigate(handle, $0) }
        }
    }

    func onRevealTimerFired() {
        KillTimer(hwnd, Self.revealTimerId)
        guard autoUpgradeEnabled, !hasUpgraded else { return }
        isVisible = true
        syncVisibilityAndBounds()
        ownerWindow?.postToMain([
            "type": "snifferState",
            "sessionId": currentSessionId,
            "visible": true,
            "interactive": false,
            "revealedFallback": true,
        ])
    }

    private func onReady() {
        syncVisibilityAndBounds()
    }

    private func syncVisibilityAndBounds() {
        guard let handle else { return }
        let validBounds = stageRect.w >= 10 && stageRect.h >= 10
        if isVisible && validBounds {
            wv2_set_bounds(handle, stageRect.x, stageRect.y, stageRect.w, stageRect.h)
            wv2_set_visible(handle, true)
        } else {
            wv2_set_bounds(handle, 0, 0, 0, 0)
            wv2_set_visible(handle, false)
        }
    }

    private func navigateWithOptionalReferer(_ url: String, referer: String) {
        guard let handle else { return }
        let effectiveRef = url.contains("youtube.com/embed/") ? "https://www.youtube.com/" : referer
        url.withCString { uPtr in
            if effectiveRef.isEmpty || url.contains("about:blank") {
                wv2_navigate(handle, uPtr)
            } else {
                effectiveRef.withCString { rPtr in
                    wv2_navigate_with_referer(handle, uPtr, rPtr)
                }
            }
        }
    }

    private func onWebMessage(_ rawJson: String) {
        guard let data = rawJson.data(using: .utf8),
              let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = msg["type"] as? String else {
            return
        }
        guard type == "sniffFound" else { return }
        let msgSession = msg["sessionId"] as? Int ?? 0
        guard msgSession == currentSessionId, autoUpgradeEnabled, !hasUpgraded else { return }
        guard let streamUrl = msg["url"] as? String, !streamUrl.isEmpty else { return }

        let ref = (msg["referer"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? activeReferer
        let ua = (msg["ua"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? activeUserAgent

        hasUpgraded = true
        KillTimer(hwnd, Self.revealTimerId)

        collectCookiesAndEmitUpgrade(sessionId: msgSession, streamUrl: streamUrl, referer: ref, ua: ua)
    }

    private func collectCookiesAndEmitUpgrade(sessionId: Int, streamUrl: String, referer: String, ua: String) {
        guard let handle else {
            emitUpgrade(sessionId: sessionId, streamUrl: streamUrl, referer: referer, ua: ua, cookieHeader: "")
            return
        }

        cookieRequestSeq += 1
        let reqId = cookieRequestSeq
        pendingCookieWork[reqId] = (sessionId, streamUrl, referer, ua)

        let ctxPtr = Unmanaged.passUnretained(self).toOpaque()
        streamUrl.withCString { uriPtr in
            wv2_get_cookies(handle, uriPtr, reqId, { ctx, rId, jsonPtr in
                guard let ctx else { return }
                let me = Unmanaged<WebSnifferController>.fromOpaque(ctx).takeUnretainedValue()
                let json = jsonPtr.map { String(cString: $0) } ?? "[]"
                me.onFirstCookies(reqId: rId, json: json)
            }, ctxPtr)
        }
    }

    private func onFirstCookies(reqId: UInt64, json: String) {
        guard let work = pendingCookieWork[reqId], work.sessionId == currentSessionId else {
            pendingCookieWork.removeValue(forKey: reqId)
            firstCookieList.removeValue(forKey: reqId)
            return
        }
        firstCookieList[reqId] = parseCookieArray(json)

        guard let handle, !work.referer.isEmpty else {
            finalizeCookiesAndEmit(reqId: reqId, secondJson: "[]")
            return
        }

        let ctxPtr = Unmanaged.passUnretained(self).toOpaque()
        work.referer.withCString { refPtr in
            wv2_get_cookies(handle, refPtr, reqId, { ctx, rId, jsonPtr in
                guard let ctx else { return }
                let me = Unmanaged<WebSnifferController>.fromOpaque(ctx).takeUnretainedValue()
                let second = jsonPtr.map { String(cString: $0) } ?? "[]"
                me.finalizeCookiesAndEmit(reqId: rId, secondJson: second)
            }, ctxPtr)
        }
    }

    private func finalizeCookiesAndEmit(reqId: UInt64, secondJson: String) {
        guard let work = pendingCookieWork.removeValue(forKey: reqId) else {
            firstCookieList.removeValue(forKey: reqId)
            return
        }
        let first = firstCookieList.removeValue(forKey: reqId) ?? []
        guard work.sessionId == currentSessionId else { return }

        let second = parseCookieArray(secondJson)
        var merged: [String: String] = [:]
        var orderedNames: [String] = []
        for c in (first + second) {
            guard let name = c["name"], let value = c["value"], !name.isEmpty else { continue }
            if merged[name] == nil {
                orderedNames.append(name)
            }
            merged[name] = value
        }
        let cookieHeader = orderedNames.compactMap { name -> String? in
            guard let val = merged[name] else { return nil }
            return "\(name)=\(val)"
        }.joined(separator: "; ")

        emitUpgrade(
            sessionId: work.sessionId,
            streamUrl: work.streamUrl,
            referer: work.referer,
            ua: work.ua,
            cookieHeader: cookieHeader
        )
    }

    private func parseCookieArray(_ json: String) -> [[String: String]] {
        guard let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else {
            return []
        }
        return arr
    }

    private func emitUpgrade(sessionId: Int, streamUrl: String, referer: String, ua: String, cookieHeader: String) {
        var qs = "u=\(b64uEncode(streamUrl))&ua=\(b64uEncode(ua))&ref=\(b64uEncode(referer))"
        if !cookieHeader.isEmpty {
            qs += "&ck=\(b64uEncode(cookieHeader))"
        }
        let proxyUrl = "\(backendBaseURL())/proxy/m3u8?\(qs)"

        isVisible = false
        syncVisibilityAndBounds()
        if let handle {
            "about:blank".withCString { wv2_navigate(handle, $0) }
        }

        ownerWindow?.postToMain([
            "type": "sniffUpgraded",
            "sessionId": sessionId,
            "streamUrl": streamUrl,
            "proxyUrl": proxyUrl,
            "referer": referer,
            "ua": ua,
        ])
    }

    static func isInteractiveOnly(url: String, urlType: Int) -> Bool {
        if urlType == 4 { return true }
        let host = URL(string: url)?.host?.lowercased() ?? ""
        return host.contains("youtube.com")
            || host.contains("youtu.be")
            || host.contains("dailymotion.com")
            || host.contains("twitch.tv")
    }

    static func youtubeEmbedURLIfNeeded(_ rawUrl: String) -> String? {
        guard let url = URL(string: rawUrl), let host = url.host?.lowercased() else { return nil }
        guard host.contains("youtube.com") || host.contains("youtu.be") else { return nil }
        var videoId: String?
        if host.contains("youtu.be") {
            let trimmed = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !trimmed.isEmpty {
                videoId = trimmed.components(separatedBy: "/").first
            }
        } else if url.path.contains("/embed/") {
            videoId = url.path.components(separatedBy: "/embed/").last?.components(separatedBy: "/").first
        } else if url.path.contains("/live/") {
            videoId = url.path.components(separatedBy: "/live/").last?.components(separatedBy: "/").first
        } else if url.path.contains("/shorts/") {
            videoId = url.path.components(separatedBy: "/shorts/").last?.components(separatedBy: "/").first
        } else if let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems {
            videoId = items.first(where: { $0.name == "v" })?.value
        }
        guard let vid = videoId, !vid.isEmpty else { return nil }
        return "https://www.youtube.com/embed/\(vid)?autoplay=1&playsinline=1&rel=0"
    }

    static func buildHookScript(sessionId: Int, keyword: String, referer: String) -> String {
        let kwLiteral = jsonStringLiteral(keyword)
        return """
        window.__yacineSessionId = \(sessionId);
        window.__yacineKeyword = \(kwLiteral);
        (function(){
          if (window.__yacineHooked) return;
          window.__yacineHooked = true;
          window.open = function(){ return null; };
          var seen = {};
          function isStream(u) {
            if (!u || typeof u !== 'string') return false;
            var low = u.toLowerCase();
            if (low.indexOf('blob:') === 0 || low.indexOf('data:') === 0) return false;
            if (/\\.(js|css|png|jpe?g|gif|svg|ico|woff2?|ttf|map)(\\?|$)/i.test(low)) return false;
            if (low.indexOf('doubleclick') >= 0 || low.indexOf('googlesyndication') >= 0 ||
                low.indexOf('googletagmanager') >= 0 || low.indexOf('google-analytics') >= 0 ||
                low.indexOf('adsystem') >= 0 || low.indexOf('popads') >= 0) return false;
            if (/\\.(m3u8|mp4|mov)(\\?|#|$)/i.test(low)) return true;
            if (/\\.m3u8(\\?|#|&|$)/i.test(low)) return true;
            if (low.indexOf('.mpd') >= 0 && (low.indexOf('.mpd?') >= 0 || low.endsWith('.mpd'))) return true;
            var kw = (window.__yacineKeyword || '').toLowerCase();
            if (kw && low.indexOf(kw) >= 0) return true;
            return false;
          }
          function report(u) {
            try {
              if (!u || typeof u !== 'string') return;
              var abs = u;
              if (abs.indexOf('http') !== 0) {
                try { abs = new URL(abs, location.href).href; } catch(_) {}
              }
              if (!isStream(abs)) return;
              if (seen[abs]) return;
              seen[abs] = 1;
              if (window.chrome && window.chrome.webview) {
                window.chrome.webview.postMessage({
                  type: 'sniffFound',
                  sessionId: window.__yacineSessionId || 0,
                  url: abs,
                  referer: location.href,
                  ua: navigator.userAgent
                });
              }
            } catch(_) {}
          }
          var origFetch = window.fetch;
          if (origFetch) {
            window.fetch = function(input) {
              try {
                var u = (typeof input === 'string') ? input : (input && input.url);
                report(u);
              } catch(_) {}
              return origFetch.apply(this, arguments);
            };
          }
          var origOpen = XMLHttpRequest.prototype.open;
          XMLHttpRequest.prototype.open = function(m, u) {
            try { report(u); } catch(_) {}
            return origOpen.apply(this, arguments);
          };
          var desc = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'src');
          if (desc && desc.set) {
            Object.defineProperty(HTMLMediaElement.prototype, 'src', {
              set: function(v) { report(v); return desc.set.call(this, v); },
              get: function() { return desc.get ? desc.get.call(this) : ''; }
            });
          }
          try {
            var po = new PerformanceObserver(function(list) {
              list.getEntries().forEach(function(e){ report(e.name); });
            });
            po.observe({ type: 'resource', buffered: true });
          } catch(_) {}
          setInterval(function() {
            try {
              document.querySelectorAll('video, source').forEach(function(el) {
                var s = el.currentSrc || el.src || el.getAttribute('src');
                if (s) report(s);
              });
              performance.getEntriesByType('resource').forEach(function(e){ report(e.name); });
            } catch(_) {}
          }, 600);
        })();
        """
    }
}

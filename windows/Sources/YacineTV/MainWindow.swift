import Foundation
import WinSDK
import CWebView2Bridge

private let wmAppBackendReady: UINT = UINT(WM_APP + 1)
private let wmAppBackendFailed: UINT = UINT(WM_APP + 2)
private let wmAppSplashRetry: UINT = UINT(WM_APP + 3)

final class MainWindow {
    static let windowClassName = "YacineTVWindowClass"
    static let fullscreenIdleTimerId: UINT_PTR = 1002

    private let paths: YacineTVPaths
    private let storage: StorageStore
    private let backend: BackendProcess
    private let iconManager = WindowIconManager()

    private(set) var hwnd: HWND!
    private var mainWeb: OpaquePointer?
    private var sniffer: WebSnifferController?

    private var allowDevTools: Bool
    private(set) var isFullscreen: Bool = false
    private var savedPlacement = WINDOWPLACEMENT()
    private var savedStyle: LONG_PTR = 0
    private var cursorHidden: Bool = false
    private var backendBooting: Bool = false

    private var darkBrush: HBRUSH
    private var lightBrush: HBRUSH

    init(paths: YacineTVPaths, storage: StorageStore, backend: BackendProcess) {
        self.paths = paths
        self.storage = storage
        self.backend = backend
        self.allowDevTools = ProcessInfo.processInfo.environment["YACINE_DEVTOOLS"] == "1"
        self.darkBrush = CreateSolidBrush(0x00141010)   // #101014
        self.lightBrush = CreateSolidBrush(0x00FAF6F5)  // #F5F6FA
    }

    deinit {
        DeleteObject(darkBrush)
        DeleteObject(lightBrush)
    }

    var effectiveIsDark: Bool {
        Win32Theme.effectiveIsDark(mode: storage.appearanceEnum)
    }

    func createAndShow() -> Bool {
        let hInstance = GetModuleHandleW(nil)
        let clsWide = makeWideString(Self.windowClassName)
        let titleWide = makeWideString("Yacine TV")

        var wc = WNDCLASSEXW()
        wc.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
        wc.style = UINT(CS_HREDRAW | CS_VREDRAW)
        wc.lpfnWndProc = MainWindow.wndProc
        wc.hInstance = hInstance
        wc.hCursor = LoadCursorW(nil, UnsafePointer<WCHAR>(bitPattern: 32512)) // IDC_ARROW
        wc.hbrBackground = effectiveIsDark ? darkBrush : lightBrush
        wc.lpszClassName = clsWide.withUnsafeBufferPointer { $0.baseAddress }

        // Note: clsWide must stay alive during RegisterClassExW
        let atom = clsWide.withUnsafeBufferPointer { clsPtr -> ATOM in
            wc.lpszClassName = clsPtr.baseAddress
            return RegisterClassExW(&wc)
        }
        if atom == 0 && GetLastError() != DWORD(ERROR_CLASS_ALREADY_EXISTS) {
            return false
        }

        // Compute DPI-aware default centered window frame (1480x920 logical, clamped to work area)
        var pt = POINT(x: 0, y: 0)
        GetCursorPos(&pt)
        let monitor = MonitorFromPoint(pt, DWORD(MONITOR_DEFAULTTOPRIMARY))
        var mi = MONITORINFO()
        mi.cbSize = DWORD(MemoryLayout<MONITORINFO>.size)
        GetMonitorInfoW(monitor, &mi)
        let workW = mi.rcWork.right - mi.rcWork.left
        let workH = mi.rcWork.bottom - mi.rcWork.top

        let targetW = min(Int32(1480), max(Int32(1080), workW - 60))
        let targetH = min(Int32(920), max(Int32(680), workH - 60))
        let x = mi.rcWork.left + max(0, (workW - targetW) / 2)
        let y = mi.rcWork.top + max(0, (workH - targetH) / 2)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let created = clsWide.withUnsafeBufferPointer { clsPtr in
            titleWide.withUnsafeBufferPointer { titlePtr in
                CreateWindowExW(
                    0,
                    clsPtr.baseAddress,
                    titlePtr.baseAddress,
                    DWORD(WS_OVERLAPPEDWINDOW) | DWORD(WS_CLIPCHILDREN),
                    x, y, targetW, targetH,
                    nil, nil, hInstance,
                    selfPtr
                )
            }
        }

        guard let created else { return false }
        self.hwnd = created

        // Adjust logical default size by actual window DPI if > 96
        let dpi = GetDpiForWindow(created)
        if dpi > 96 {
            let scaledW = min(workW - 40, MulDiv(1480, Int32(dpi), 96))
            let scaledH = min(workH - 40, MulDiv(920, Int32(dpi), 96))
            let sx = mi.rcWork.left + max(0, (workW - scaledW) / 2)
            let sy = mi.rcWork.top + max(0, (workH - scaledH) / 2)
            SetWindowPos(created, nil, sx, sy, scaledW, scaledH, UINT(SWP_NOZORDER | SWP_NOACTIVATE))
        }

        syncAppearanceChrome(forceIconRefresh: true)
        ShowWindow(created, SW_SHOW)
        UpdateWindow(created)

        initializeWebViews()
        startBackendAsync()
        return true
    }

    private func initializeWebViews() {
        var rc = RECT()
        GetClientRect(hwnd, &rc)

        let mainUdf = paths.appDataDir.appendingPathComponent("WebView2Main", isDirectory: true)
        try? FileManager.default.createDirectory(at: mainUdf, withIntermediateDirectories: true)

        var callbacks = WV2Callbacks()
        callbacks.ctx = Unmanaged.passUnretained(self).toOpaque()
        callbacks.onReady = { ctx, ok in
            guard let ctx, ok else { return }
            let me = Unmanaged<MainWindow>.fromOpaque(ctx).takeUnretainedValue()
            me.onMainWebReady()
        }
        callbacks.onMessage = { ctx, jsonPtr in
            guard let ctx, let jsonPtr else { return }
            let me = Unmanaged<MainWindow>.fromOpaque(ctx).takeUnretainedValue()
            me.handleMainWebMessage(String(cString: jsonPtr))
        }
        callbacks.onFullscreenChanged = { ctx, isFs in
            guard let ctx else { return }
            let me = Unmanaged<MainWindow>.fromOpaque(ctx).takeUnretainedValue()
            me.setFullscreen(isFs)
        }
        callbacks.onKeyDown = { ctx, vkey in
            guard let ctx else { return false }
            let me = Unmanaged<MainWindow>.fromOpaque(ctx).takeUnretainedValue()
            if vkey == UInt32(VK_F11) {
                me.toggleFullscreen()
                return true
            }
            if vkey == UInt32(VK_ESCAPE) && me.isFullscreen {
                me.setFullscreen(false)
                return true
            }
            return false
        }

        mainWeb = mainUdf.path.withCString { udf in
            wv2_create(
                UnsafeMutableRawPointer(hwnd),
                udf,
                0, 0, rc.right - rc.left, rc.bottom - rc.top,
                true,
                allowDevTools,
                true,
                callbacks
            )
        }

        if let mainWeb {
            let dark = effectiveIsDark
            wv2_set_preferred_color_scheme(mainWeb, dark ? 2 : 1)
            if dark {
                wv2_set_background_color(mainWeb, 255, 16, 16, 20)
            } else {
                wv2_set_background_color(mainWeb, 255, 245, 246, 250)
            }
            let splash = Self.buildSplashHTML(isDark: dark, errorMessage: nil)
            splash.withCString { wv2_navigate_to_string(mainWeb, $0) }
        }

        let sniffUdf = paths.appDataDir.appendingPathComponent("WebView2Sniff", isDirectory: true)
        sniffer = WebSnifferController(
            owner: self,
            hwnd: hwnd,
            userDataDir: sniffUdf,
            isDark: effectiveIsDark,
            backendBaseURL: { [weak self] in
                self?.backend.baseURL ?? "http://127.0.0.1:19485"
            }
        )
    }

    private func onMainWebReady() {
        var rc = RECT()
        GetClientRect(hwnd, &rc)
        if let mainWeb {
            wv2_set_bounds(mainWeb, 0, 0, rc.right - rc.left, rc.bottom - rc.top)
        }
        if LoopbackProbe.checkStatusOk(port: backend.port), !backendBooting {
            navigateMainToApp()
        }
    }

    private func startBackendAsync() {
        guard !backendBooting else { return }
        backendBooting = true
        let hwndRaw = Int(bitPattern: hwnd)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let started = self.backend.startIfNeeded()
            let ready = started && self.backend.waitUntilReady(timeoutSeconds: 8.0)
            let targetHwnd = HWND(bitPattern: hwndRaw)
            if ready {
                PostMessageW(targetHwnd, wmAppBackendReady, 0, 0)
            } else {
                PostMessageW(targetHwnd, wmAppBackendFailed, 0, 0)
            }
        }
    }

    private func navigateMainToApp() {
        guard let mainWeb else { return }
        let url = "\(backend.baseURL)/?native=1"
        url.withCString { wv2_navigate(mainWeb, $0) }
    }

    func postToMain(_ payload: [String: Any]) {
        guard let mainWeb,
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            return
        }
        json.withCString { wv2_post_web_message_json(mainWeb, $0) }
    }

    private func handleMainWebMessage(_ rawJson: String) {
        guard let data = rawJson.data(using: .utf8),
              let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = msg["type"] as? String else {
            return
        }

        switch type {
        case "ready":
            sendInitState()

        case "setSettings":
            if let settingsDict = msg["settings"] as? [String: Any] {
                storage.updateSettings(fromJsonDict: settingsDict)
                syncAppearanceChrome(forceIconRefresh: false)
            }

        case "saveFavorites":
            if let favs = msg["favorites"],
               let favData = try? JSONSerialization.data(withJSONObject: favs),
               let favStr = String(data: favData, encoding: .utf8) {
                storage.saveFavoritesJson(favStr)
            }

        case "saveBootstrap":
            if let boot = msg["bootstrap"],
               let bootData = try? JSONSerialization.data(withJSONObject: boot),
               let bootStr = String(data: bootData, encoding: .utf8) {
                storage.saveBootstrapJson(bootStr)
            }

        case "setStageRect":
            let dpr = (msg["dpr"] as? Double) ?? 1.0
            let x = Int32(((msg["x"] as? Double) ?? 0.0) * dpr)
            let y = Int32(((msg["y"] as? Double) ?? 0.0) * dpr)
            let w = Int32(((msg["width"] as? Double) ?? 0.0) * dpr)
            let h = Int32(((msg["height"] as? Double) ?? 0.0) * dpr)
            sniffer?.updateStageRect(x: x, y: y, width: w, height: h)

        case "sniffStart":
            let sessionId = msg["sessionId"] as? Int ?? 1
            let url = msg["url"] as? String ?? ""
            let urlType = msg["urlType"] as? Int ?? 6
            let ua = msg["userAgent"] as? String ?? ""
            let ref = msg["referer"] as? String ?? ""
            let kw = msg["keyword"] as? String ?? ""
            sniffer?.start(sessionId: sessionId, url: url, urlType: urlType, userAgent: ua, referer: ref, keyword: kw)

        case "sniffStop":
            sniffer?.stop()

        case "toggleFullscreen":
            toggleFullscreen()

        case "setFullscreen":
            let target = msg["value"] as? Bool ?? !isFullscreen
            setFullscreen(target)

        case "fullscreenMouseMove":
            onUserActivityInFullscreen()

        case "retryBackend":
            PostMessageW(hwnd, wmAppSplashRetry, 0, 0)

        default:
            break
        }
    }

    private func sendInitState() {
        guard let mainWeb else { return }
        let settingsObj = (try? JSONSerialization.jsonObject(with: Data(storage.settingsJsonString().utf8))) ?? [:]
        let favsObj = (try? JSONSerialization.jsonObject(with: Data(storage.loadFavoritesJson().utf8))) ?? []
        let bootObj = (try? JSONSerialization.jsonObject(with: Data(storage.loadBootstrapJson().utf8))) ?? NSNull()

        let payload: [String: Any] = [
            "type": "initState",
            "settings": settingsObj,
            "favorites": favsObj,
            "bootstrap": bootObj,
            "effectiveIsDark": effectiveIsDark,
            "backendBaseURL": backend.baseURL,
            "isFullscreen": isFullscreen,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let json = String(data: data, encoding: .utf8) {
            json.withCString { wv2_post_web_message_json(mainWeb, $0) }
        }
    }

    private func syncAppearanceChrome(forceIconRefresh: Bool) {
        let dark = effectiveIsDark
        Win32Theme.applyWindowChrome(hwnd: hwnd, isDark: dark, isFullscreen: isFullscreen)
        iconManager.updateIcons(hwnd: hwnd, isDark: dark, resourceDirs: paths.resourceDirs, force: forceIconRefresh)
        if let mainWeb {
            wv2_set_preferred_color_scheme(mainWeb, dark ? 2 : 1)
            if dark {
                wv2_set_background_color(mainWeb, 255, 16, 16, 20)
            } else {
                wv2_set_background_color(mainWeb, 255, 245, 246, 250)
            }
        }
        sniffer?.updateTheme(isDark: dark)
        postToMain([
            "type": "systemThemeChanged",
            "effectiveIsDark": dark,
            "appearanceMode": storage.settings.appearanceMode,
        ])
    }

    func toggleFullscreen() {
        setFullscreen(!isFullscreen)
    }

    func setFullscreen(_ enable: Bool) {
        if enable == isFullscreen { return }
        isFullscreen = enable

        if enable {
            savedPlacement.length = UINT(MemoryLayout<WINDOWPLACEMENT>.size)
            GetWindowPlacement(hwnd, &savedPlacement)
            savedStyle = GetWindowLongPtrW(hwnd, GWL_STYLE)

            let monitor = MonitorFromWindow(hwnd, DWORD(MONITOR_DEFAULTTONEAREST))
            var mi = MONITORINFO()
            mi.cbSize = DWORD(MemoryLayout<MONITORINFO>.size)
            GetMonitorInfoW(monitor, &mi)

            let newStyle = savedStyle & ~LONG_PTR(WS_OVERLAPPEDWINDOW)
            SetWindowLongPtrW(hwnd, GWL_STYLE, newStyle)
            Win32Theme.applyWindowChrome(hwnd: hwnd, isDark: effectiveIsDark, isFullscreen: true)
            SetWindowPos(
                hwnd,
                nil,
                mi.rcMonitor.left,
                mi.rcMonitor.top,
                mi.rcMonitor.right - mi.rcMonitor.left,
                mi.rcMonitor.bottom - mi.rcMonitor.top,
                UINT(SWP_NOOWNERZORDER | SWP_FRAMECHANGED)
            )
            onUserActivityInFullscreen()
        } else {
            KillTimer(hwnd, Self.fullscreenIdleTimerId)
            restoreCursorIfHidden()
            SetWindowLongPtrW(hwnd, GWL_STYLE, savedStyle != 0 ? savedStyle : (LONG_PTR(WS_OVERLAPPEDWINDOW) | LONG_PTR(WS_CLIPCHILDREN)))
            SetWindowPlacement(hwnd, &savedPlacement)
            Win32Theme.applyWindowChrome(hwnd: hwnd, isDark: effectiveIsDark, isFullscreen: false)
            SetWindowPos(hwnd, nil, 0, 0, 0, 0, UINT(SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOOWNERZORDER | SWP_FRAMECHANGED))
            postToMain(["type": "fullscreenHudVisible", "visible": true])
        }

        postToMain(["type": "fullscreenChanged", "isFullscreen": isFullscreen])
    }

    private func onUserActivityInFullscreen() {
        guard isFullscreen else { return }
        restoreCursorIfHidden()
        postToMain(["type": "fullscreenHudVisible", "visible": true])
        SetTimer(hwnd, Self.fullscreenIdleTimerId, 2500, nil)
    }

    private func hideCursorIfNeeded() {
        guard isFullscreen, !cursorHidden else { return }
        while ShowCursor(false) >= 0 {}
        cursorHidden = true
    }

    private func restoreCursorIfHidden() {
        guard cursorHidden else { return }
        while ShowCursor(true) < 0 {}
        cursorHidden = false
    }

    private func onShutdown() {
        backend.stop()
        KillTimer(hwnd, Self.fullscreenIdleTimerId)
        restoreCursorIfHidden()
        sniffer = nil
        if let mainWeb {
            wv2_destroy(mainWeb)
            self.mainWeb = nil
        }
    }

    private static let wndProc: WNDPROC = { hwnd, msg, wParam, lParam in
        if msg == UINT(WM_NCCREATE) {
            if let cs = UnsafePointer<CREATESTRUCTW>(bitPattern: Int(lParam))?.pointee,
               let userPtr = cs.lpCreateParams {
                SetWindowLongPtrW(hwnd, GWLP_USERDATA, LONG_PTR(Int(bitPattern: userPtr)))
            }
            return DefWindowProcW(hwnd, msg, wParam, lParam)
        }

        let ptrVal = GetWindowLongPtrW(hwnd, GWLP_USERDATA)
        guard ptrVal != 0, let rawPtr = UnsafeMutableRawPointer(bitPattern: Int(ptrVal)) else {
            return DefWindowProcW(hwnd, msg, wParam, lParam)
        }
        let me = Unmanaged<MainWindow>.fromOpaque(rawPtr).takeUnretainedValue()
        return me.handleMessage(hwnd: hwnd!, msg: msg, wParam: wParam, lParam: lParam)
    }

    private func handleMessage(hwnd: HWND, msg: UINT, wParam: WPARAM, lParam: LPARAM) -> LRESULT {
        switch Int32(bitPattern: msg) {
        case WM_GETMINMAXINFO:
            if !isFullscreen, let mmi = UnsafeMutablePointer<MINMAXINFO>(bitPattern: Int(lParam)) {
                let dpi = GetDpiForWindow(hwnd)
                let scaleDpi = dpi > 0 ? Int32(dpi) : 96
                mmi.pointee.ptMinTrackSize.x = MulDiv(1080, scaleDpi, 96)
                mmi.pointee.ptMinTrackSize.y = MulDiv(680, scaleDpi, 96)
                return 0
            }

        case WM_ERASEBKGND:
            if let hdc = HDC(bitPattern: UInt(wParam)) {
                var rc = RECT()
                GetClientRect(hwnd, &rc)
                FillRect(hdc, &rc, effectiveIsDark ? darkBrush : lightBrush)
                return 1
            }

        case WM_SIZE:
            var rc = RECT()
            GetClientRect(hwnd, &rc)
            if let mainWeb {
                wv2_set_bounds(mainWeb, 0, 0, rc.right - rc.left, rc.bottom - rc.top)
                wv2_notify_parent_window_position_changed(mainWeb)
            }
            sniffer?.notifyParentMoved()
            return 0

        case WM_MOVE, WM_WINDOWPOSCHANGED:
            if let mainWeb {
                wv2_notify_parent_window_position_changed(mainWeb)
            }
            sniffer?.notifyParentMoved()

        case WM_SETFOCUS:
            if let mainWeb {
                wv2_focus(mainWeb)
            }

        case WM_DPICHANGED:
            if let suggested = UnsafePointer<RECT>(bitPattern: Int(lParam))?.pointee {
                SetWindowPos(
                    hwnd,
                    nil,
                    suggested.left,
                    suggested.top,
                    suggested.right - suggested.left,
                    suggested.bottom - suggested.top,
                    UINT(SWP_NOZORDER | SWP_NOACTIVATE)
                )
            }
            iconManager.updateIcons(hwnd: hwnd, isDark: effectiveIsDark, resourceDirs: paths.resourceDirs, force: true)
            return 0

        case WM_SETTINGCHANGE:
            if storage.appearanceEnum == .auto {
                syncAppearanceChrome(forceIconRefresh: false)
            }
            return 0

        case WM_KEYDOWN:
            if wParam == WPARAM(VK_F11) {
                toggleFullscreen()
                return 0
            }
            if wParam == WPARAM(VK_ESCAPE) && isFullscreen {
                setFullscreen(false)
                return 0
            }

        case WM_MOUSEMOVE:
            if isFullscreen {
                onUserActivityInFullscreen()
            }

        case WM_TIMER:
            if wParam == WPARAM(WebSnifferController.revealTimerId) {
                sniffer?.onRevealTimerFired()
                return 0
            }
            if wParam == WPARAM(Self.fullscreenIdleTimerId) {
                KillTimer(hwnd, Self.fullscreenIdleTimerId)
                hideCursorIfNeeded()
                postToMain(["type": "fullscreenHudVisible", "visible": false])
                return 0
            }

        case Int32(wmAppBackendReady):
            backendBooting = false
            navigateMainToApp()
            return 0

        case Int32(wmAppBackendFailed):
            backendBooting = false
            if let mainWeb {
                let err = backend.lastError ?? "Backend server could not start."
                let html = Self.buildSplashHTML(isDark: effectiveIsDark, errorMessage: err)
                html.withCString { wv2_navigate_to_string(mainWeb, $0) }
            }
            return 0

        case Int32(wmAppSplashRetry):
            if let mainWeb {
                let html = Self.buildSplashHTML(isDark: effectiveIsDark, errorMessage: nil)
                html.withCString { wv2_navigate_to_string(mainWeb, $0) }
            }
            startBackendAsync()
            return 0

        case WM_CLOSE:
            onShutdown()
            DestroyWindow(hwnd)
            return 0

        case WM_DESTROY:
            PostQuitMessage(0)
            return 0

        case WM_NCDESTROY:
            SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0)
            return 0

        default:
            break
        }
        return DefWindowProcW(hwnd, msg, wParam, lParam)
    }

    private static func buildSplashHTML(isDark: Bool, errorMessage: String?) -> String {
        let bg = isDark ? "#101014" : "#F5F6FA"
        let card = isDark ? "#181920" : "#FFFFFF"
        let text = isDark ? "#F3F4F6" : "#111827"
        let sub = isDark ? "#9CA3AF" : "#6B7280"
        let border = isDark ? "rgba(255,255,255,0.08)" : "rgba(0,0,0,0.08)"

        if let errorMessage {
            let escaped = errorMessage
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            return """
            <!doctype html>
            <html>
            <head><meta charset="utf-8"><style>
            html,body{margin:0;height:100%;background:\(bg);color:\(text);font-family:"Segoe UI Variable","Segoe UI",sans-serif;display:flex;align-items:center;justify-content:center;user-select:none}
            .box{max-width:440px;padding:28px 30px;border-radius:18px;background:\(card);border:1px solid \(border);text-align:center}
            h2{margin:0 0 8px;font-size:18px;font-weight:600}
            p{margin:0 0 18px;font-size:13px;line-height:1.5;color:\(sub)}
            button{background:#e50914;color:#fff;border:0;border-radius:999px;padding:10px 22px;font-size:13px;font-weight:600;cursor:pointer}
            button:hover{filter:brightness(1.08)}
            </style></head>
            <body><div class="box">
              <h2>Unable to Start Local Stream Service</h2>
              <p>\(escaped)</p>
              <button onclick="window.chrome&&window.chrome.webview&&window.chrome.webview.postMessage({type:'retryBackend'})">Retry</button>
            </div></body></html>
            """
        }

        return """
        <!doctype html>
        <html>
        <head><meta charset="utf-8"><style>
        html,body{margin:0;height:100%;background:\(bg);color:\(text);font-family:"Segoe UI Variable","Segoe UI",sans-serif;display:flex;align-items:center;justify-content:center;user-select:none}
        .wrap{display:flex;flex-direction:column;align-items:center;gap:14px}
        .spin{width:28px;height:28px;border:2.5px solid \(border);border-top-color:#e50914;border-radius:50%;animation:s .8s linear infinite}
        .lbl{font-size:13px;font-weight:600;color:\(sub);letter-spacing:.2px}
        @keyframes s{to{transform:rotate(360deg)}}
        </style></head>
        <body><div class="wrap"><div class="spin"></div><div class="lbl">Starting Yacine TV…</div></div></body>
        </html>
        """
    }
}

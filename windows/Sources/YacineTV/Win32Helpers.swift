import Foundation
import WinSDK

enum YacineAppearanceMode: String {
    case auto
    case light
    case dark
}

func makeWideString(_ str: String) -> [WCHAR] {
    var result = Array(str.utf16)
    result.append(0)
    return result
}

func stringFromWideBuffer(_ buf: [WCHAR]) -> String {
    if let zeroIdx = buf.firstIndex(of: 0) {
        return String(decoding: buf[..<zeroIdx], as: UTF16.self)
    }
    return String(decoding: buf, as: UTF16.self)
}

func b64uEncode(_ str: String) -> String {
    let data = Data(str.utf8)
    return data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
}

func jsonStringLiteral(_ str: String) -> String {
    guard let data = try? JSONEncoder().encode(str),
          let encoded = String(data: data, encoding: .utf8) else {
        return "\"\""
    }
    return encoded
}

final class SingleInstanceGuard {
    private var handle: HANDLE?

    func acquireOrActivateExisting(windowClassName: String) -> Bool {
        let mutexName = makeWideString("Local\\YacineTVDesktop_SingleInstance_Mutex")
        let h = mutexName.withUnsafeBufferPointer { ptr in
            CreateMutexW(nil, false, ptr.baseAddress)
        }
        guard let h else { return true }
        if GetLastError() == DWORD(ERROR_ALREADY_EXISTS) {
            CloseHandle(h)
            let cls = makeWideString(windowClassName)
            let existing = cls.withUnsafeBufferPointer { ptr in
                FindWindowW(ptr.baseAddress, nil)
            }
            if let existing {
                if IsIconic(existing) {
                    ShowWindow(existing, SW_RESTORE)
                } else {
                    ShowWindow(existing, SW_SHOW)
                }
                SetForegroundWindow(existing)
            }
            return false
        }
        handle = h
        return true
    }

    deinit {
        if let handle {
            CloseHandle(handle)
        }
    }
}

final class Win32JobObject {
    private let job: HANDLE?

    init() {
        guard let handle = CreateJobObjectW(nil, nil) else {
            self.job = nil
            return
        }
        var info = JOBOBJECT_EXTENDED_LIMIT_INFORMATION()
        info.BasicLimitInformation.LimitFlags = DWORD(JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE)
        let ok = withUnsafeMutablePointer(to: &info) { ptr in
            SetInformationJobObject(
                handle,
                JobObjectExtendedLimitInformation,
                ptr,
                DWORD(MemoryLayout<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>.size)
            )
        }
        if !ok {
            CloseHandle(handle)
            self.job = nil
            return
        }
        self.job = handle
    }

    func assign(process: HANDLE) {
        guard let job else { return }
        _ = AssignProcessToJobObject(job, process)
    }

    deinit {
        if let job {
            CloseHandle(job)
        }
    }
}

enum Win32Theme {
    static func enableDPIAwareness() {
        _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)
    }

    static func isSystemDark() -> Bool {
        let subKey = makeWideString("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize")
        let valueName = makeWideString("AppsUseLightTheme")
        var data: DWORD = 0
        var dataSize = DWORD(MemoryLayout<DWORD>.size)
        let status = subKey.withUnsafeBufferPointer { keyPtr in
            valueName.withUnsafeBufferPointer { valPtr in
                RegGetValueW(
                    HKEY_CURRENT_USER,
                    keyPtr.baseAddress,
                    valPtr.baseAddress,
                    DWORD(RRF_RT_REG_DWORD),
                    nil,
                    &data,
                    &dataSize
                )
            }
        }
        if status == ERROR_SUCCESS {
            return data == 0
        }
        return true
    }

    static func effectiveIsDark(mode: YacineAppearanceMode) -> Bool {
        switch mode {
        case .auto: return isSystemDark()
        case .light: return false
        case .dark: return true
        }
    }

    static func applyWindowChrome(hwnd: HWND, isDark: Bool, isFullscreen: Bool) {
        var darkVal: Int32 = isDark ? 1 : 0
        let hr20 = withUnsafePointer(to: &darkVal) { ptr in
            DwmSetWindowAttribute(hwnd, 20, ptr, DWORD(MemoryLayout<Int32>.size))
        }
        if hr20 < 0 {
            _ = withUnsafePointer(to: &darkVal) { ptr in
                DwmSetWindowAttribute(hwnd, 19, ptr, DWORD(MemoryLayout<Int32>.size))
            }
        }

        // DWMWA_WINDOW_CORNER_PREFERENCE = 33 (2 = DWMWCP_ROUND, 1 = DWMWCP_DONOTROUND)
        var corner: Int32 = isFullscreen ? 1 : 2
        _ = withUnsafePointer(to: &corner) { ptr in
            DwmSetWindowAttribute(hwnd, 33, ptr, DWORD(MemoryLayout<Int32>.size))
        }

        // DWMWA_CAPTION_COLOR = 35 (COLORREF 0x00BBGGRR)
        var captionColor: DWORD = isDark ? 0x00141010 : 0x00F8F5F4
        _ = withUnsafePointer(to: &captionColor) { ptr in
            DwmSetWindowAttribute(hwnd, 35, ptr, DWORD(MemoryLayout<DWORD>.size))
        }
    }
}

final class WindowIconManager {
    private var bigIcon: HICON?
    private var smallIcon: HICON?
    private var currentIsDark: Bool?

    func updateIcons(hwnd: HWND, isDark: Bool, resourceDirs: [URL], force: Bool = false) {
        if !force, currentIsDark == isDark { return }
        currentIsDark = isDark

        let fileName = isDark ? "AppIcon-Dark.ico" : "AppIcon-Default.ico"
        var foundPath: String?
        for dir in resourceDirs {
            let candidate = dir.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: candidate.path) {
                foundPath = candidate.path
                break
            }
        }
        guard let iconPath = foundPath else { return }

        let dpi = GetDpiForWindow(hwnd)
        let cxBig = GetSystemMetricsForDpi(SM_CXICON, dpi)
        let cyBig = GetSystemMetricsForDpi(SM_CYICON, dpi)
        let cxSmall = GetSystemMetricsForDpi(SM_CXSMICON, dpi)
        let cySmall = GetSystemMetricsForDpi(SM_CYSMICON, dpi)

        let widePath = makeWideString(iconPath)
        let newBig = widePath.withUnsafeBufferPointer { ptr -> HICON? in
            guard let handle = LoadImageW(
                nil,
                ptr.baseAddress,
                UINT(IMAGE_ICON),
                cxBig > 0 ? cxBig : 32,
                cyBig > 0 ? cyBig : 32,
                UINT(LR_LOADFROMFILE)
            ) else { return nil }
            return handle.assumingMemoryBound(to: HICON__.self)
        }
        let newSmall = widePath.withUnsafeBufferPointer { ptr -> HICON? in
            guard let handle = LoadImageW(
                nil,
                ptr.baseAddress,
                UINT(IMAGE_ICON),
                cxSmall > 0 ? cxSmall : 16,
                cySmall > 0 ? cySmall : 16,
                UINT(LR_LOADFROMFILE)
            ) else { return nil }
            return handle.assumingMemoryBound(to: HICON__.self)
        }

        if let newBig {
            SendMessageW(hwnd, UINT(WM_SETICON), WPARAM(ICON_BIG), LPARAM(Int(bitPattern: newBig)))
            if let old = bigIcon { DestroyIcon(old) }
            bigIcon = newBig
        }
        if let newSmall {
            SendMessageW(hwnd, UINT(WM_SETICON), WPARAM(ICON_SMALL), LPARAM(Int(bitPattern: newSmall)))
            if let old = smallIcon { DestroyIcon(old) }
            smallIcon = newSmall
        }
    }

    deinit {
        if let bigIcon { DestroyIcon(bigIcon) }
        if let smallIcon { DestroyIcon(smallIcon) }
    }
}

enum LoopbackProbe {
    private static let wsaReady: Bool = {
        var data = WSADATA()
        return WSAStartup(0x0202, &data) == 0
    }()

    static func isPortAvailable(_ port: UInt16) -> Bool {
        _ = wsaReady
        let sock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP.rawValue)
        if sock == INVALID_SOCKET { return false }
        defer { closesocket(sock) }

        var addr = sockaddr_in()
        addr.sin_family = ADDRESS_FAMILY(AF_INET)
        addr.sin_port = htons(port)
        addr.sin_addr.S_un.S_addr = htonl(0x7F000001)

        let res = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sptr in
                bind(sock, sptr, Int32(MemoryLayout<sockaddr_in>.size))
            }
        }
        return res == 0
    }

    static func findFreePort(preferred: UInt16) -> UInt16 {
        if isPortAvailable(preferred) {
            return preferred
        }
        _ = wsaReady
        let sock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP.rawValue)
        if sock == INVALID_SOCKET { return preferred }
        defer { closesocket(sock) }

        var addr = sockaddr_in()
        addr.sin_family = ADDRESS_FAMILY(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.S_un.S_addr = htonl(0x7F000001)

        let ok = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sptr in
                bind(sock, sptr, Int32(MemoryLayout<sockaddr_in>.size))
            }
        }
        if ok != 0 { return preferred }
        var len = Int32(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sptr in
                getsockname(sock, sptr, &len)
            }
        }
        return ntohs(addr.sin_port)
    }

    static func checkStatusOk(port: UInt16) -> Bool {
        _ = wsaReady
        let sock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP.rawValue)
        if sock == INVALID_SOCKET { return false }
        defer { closesocket(sock) }

        var timeout: DWORD = 350
        _ = withUnsafePointer(to: &timeout) { ptr in
            setsockopt(
                sock,
                SOL_SOCKET,
                SO_RCVTIMEO,
                UnsafeRawPointer(ptr).assumingMemoryBound(to: CChar.self),
                Int32(MemoryLayout<DWORD>.size)
            )
        }
        _ = withUnsafePointer(to: &timeout) { ptr in
            setsockopt(
                sock,
                SOL_SOCKET,
                SO_SNDTIMEO,
                UnsafeRawPointer(ptr).assumingMemoryBound(to: CChar.self),
                Int32(MemoryLayout<DWORD>.size)
            )
        }

        var addr = sockaddr_in()
        addr.sin_family = ADDRESS_FAMILY(AF_INET)
        addr.sin_port = htons(port)
        addr.sin_addr.S_un.S_addr = htonl(0x7F000001)

        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sptr in
                connect(sock, sptr, Int32(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connected != 0 { return false }

        let req = "GET /api/status HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nConnection: close\r\n\r\n"
        _ = req.withCString { cstr in
            send(sock, cstr, Int32(strlen(cstr)), 0)
        }

        var accumulated = Data()
        var buf = [UInt8](repeating: 0, count: 2048)
        for _ in 0..<16 {
            let n = buf.withUnsafeMutableBytes { rawPtr in
                recv(sock, rawPtr.baseAddress?.assumingMemoryBound(to: CChar.self), Int32(rawPtr.count), 0)
            }
            if n <= 0 { break }
            accumulated.append(contentsOf: buf[..<Int(n)])
            if let text = String(data: accumulated, encoding: .utf8),
               text.contains("200 ") && text.contains("\"ok\"") {
                return true
            }
            if accumulated.count >= 65536 { break }
        }
        guard let reply = String(data: accumulated, encoding: .utf8) else { return false }
        return reply.contains("200 ") && reply.contains("\"ok\"")
    }
}

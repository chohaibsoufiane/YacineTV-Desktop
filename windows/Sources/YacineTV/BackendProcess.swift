import Foundation
import WinSDK

struct YacineTVPaths {
    let executableDir: URL
    let backendScript: URL?
    let uiDir: URL?
    let resourceDirs: [URL]
    let appDataDir: URL

    static func resolve() -> YacineTVPaths {
        var buf = [WCHAR](repeating: 0, count: 1024)
        let len = GetModuleFileNameW(nil, &buf, DWORD(buf.count))
        let exePath = len > 0 ? stringFromWideBuffer(Array(buf[..<Int(len)])) : ProcessInfo.processInfo.arguments[0]
        let exeUrl = URL(fileURLWithPath: exePath)
        let exeDir = exeUrl.deletingLastPathComponent()

        var backendScript: URL?
        var uiDir: URL?
        var resourceDirs: [URL] = [
            exeDir.appendingPathComponent("Resources", isDirectory: true),
            exeDir,
        ]

        var probeDir = exeDir
        for _ in 0..<7 {
            let candidateBackend = probeDir.appendingPathComponent("backend", isDirectory: true).appendingPathComponent("server.py")
            if backendScript == nil && FileManager.default.fileExists(atPath: candidateBackend.path) {
                backendScript = candidateBackend
                let candidateUI = probeDir.appendingPathComponent("ui", isDirectory: true)
                if FileManager.default.fileExists(atPath: candidateUI.appendingPathComponent("index.html").path) {
                    uiDir = candidateUI
                }
            }
            let winRes = probeDir.appendingPathComponent("windows", isDirectory: true).appendingPathComponent("Resources", isDirectory: true)
            if FileManager.default.fileExists(atPath: winRes.path) {
                resourceDirs.append(winRes)
            }
            let resDir = probeDir.appendingPathComponent("Resources", isDirectory: true)
            if FileManager.default.fileExists(atPath: resDir.path) && !resourceDirs.contains(resDir) {
                resourceDirs.append(resDir)
            }
            let parent = probeDir.deletingLastPathComponent()
            if parent.path == probeDir.path { break }
            probeDir = parent
        }

        let localAppData = ProcessInfo.processInfo.environment["LOCALAPPDATA"]
            ?? (NSHomeDirectory() + "\\AppData\\Local")
        let appDataDir = URL(fileURLWithPath: localAppData, isDirectory: true)
            .appendingPathComponent("YacineTV", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDataDir, withIntermediateDirectories: true)

        return YacineTVPaths(
            executableDir: exeDir,
            backendScript: backendScript,
            uiDir: uiDir,
            resourceDirs: resourceDirs,
            appDataDir: appDataDir
        )
    }
}

final class BackendProcess {
    private let paths: YacineTVPaths
    private let job = Win32JobObject()
    private var processHandle: HANDLE?
    private(set) var port: UInt16
    private(set) var lastError: String?

    init(paths: YacineTVPaths) {
        self.paths = paths
        let envPort = ProcessInfo.processInfo.environment["YACINE_PORT"].flatMap { UInt16($0) } ?? 19485
        self.port = envPort
    }

    var baseURL: String {
        "http://127.0.0.1:\(port)"
    }

    func startIfNeeded() -> Bool {
        if LoopbackProbe.checkStatusOk(port: port) {
            return true
        }
        port = LoopbackProbe.findFreePort(preferred: port)

        guard let serverScript = paths.backendScript else {
            lastError = "Could not locate backend/server.py next to YacineTV.exe."
            return false
        }
        guard let pythonExe = findPythonExecutable() else {
            lastError = "Python 3 was not found. Install Python 3.10+ (or set YACINE_PYTHON) and relaunch YacineTV."
            return false
        }

        let portKey = makeWideString("YACINE_PORT")
        let portVal = makeWideString("\(port)")
        let bufKey = makeWideString("PYTHONUNBUFFERED")
        let bufVal = makeWideString("1")
        let utfKey = makeWideString("PYTHONUTF8")
        let utfVal = makeWideString("1")
        _ = portKey.withUnsafeBufferPointer { k in portVal.withUnsafeBufferPointer { v in SetEnvironmentVariableW(k.baseAddress, v.baseAddress) } }
        _ = bufKey.withUnsafeBufferPointer { k in bufVal.withUnsafeBufferPointer { v in SetEnvironmentVariableW(k.baseAddress, v.baseAddress) } }
        _ = utfKey.withUnsafeBufferPointer { k in utfVal.withUnsafeBufferPointer { v in SetEnvironmentVariableW(k.baseAddress, v.baseAddress) } }

        let cmdLine = "\"\(pythonExe)\" -u \"\(serverScript.path)\""
        var cmdWide = makeWideString(cmdLine)
        let workDir = makeWideString(serverScript.deletingLastPathComponent().path)

        var si = STARTUPINFOW()
        si.cb = DWORD(MemoryLayout<STARTUPINFOW>.size)
        si.dwFlags = DWORD(STARTF_USESHOWWINDOW)
        si.wShowWindow = WORD(SW_HIDE)

        var pi = PROCESS_INFORMATION()
        let flags = DWORD(CREATE_NO_WINDOW | CREATE_SUSPENDED)

        let ok = cmdWide.withUnsafeMutableBufferPointer { cmdPtr in
            workDir.withUnsafeBufferPointer { wdPtr in
                CreateProcessW(
                    nil,
                    cmdPtr.baseAddress,
                    nil,
                    nil,
                    false,
                    flags,
                    nil,
                    wdPtr.baseAddress,
                    &si,
                    &pi
                )
            }
        }

        guard ok, let proc = pi.hProcess else {
            lastError = "Failed to launch backend/server.py (Win32 error \(GetLastError()))."
            return false
        }

        job.assign(process: proc)
        if let thread = pi.hThread {
            ResumeThread(thread)
            CloseHandle(thread)
        }
        self.processHandle = proc
        return true
    }

    func waitUntilReady(timeoutSeconds: Double = 6.0) -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if LoopbackProbe.checkStatusOk(port: port) {
                return true
            }
            if let proc = processHandle {
                var exitCode: DWORD = STILL_ACTIVE
                if GetExitCodeProcess(proc, &exitCode), exitCode != STILL_ACTIVE {
                    lastError = "backend/server.py exited prematurely with code \(exitCode)."
                    return false
                }
            }
            Sleep(50)
        }
        lastError = "Timed out waiting for backend server on 127.0.0.1:\(port)."
        return false
    }

    func stop() {
        guard let proc = processHandle else { return }
        TerminateProcess(proc, 0)
        WaitForSingleObject(proc, 1000)
        CloseHandle(proc)
        processHandle = nil
    }

    deinit {
        stop()
    }

    private func isValidPython(_ path: String) -> Bool {
        let lower = path.lowercased()
        if lower.contains("\\microsoft\\windowsapps\\") {
            return false
        }
        guard FileManager.default.fileExists(atPath: path) else { return false }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let size = attrs[.size] as? NSNumber {
            return size.int64Value > 10_000
        }
        return true
    }

    private func findPythonExecutable() -> String? {
        let bundled = paths.executableDir
            .appendingPathComponent("python", isDirectory: true)
            .appendingPathComponent("python.exe")
        if isValidPython(bundled.path) { return bundled.path }

        if let envPy = ProcessInfo.processInfo.environment["YACINE_PYTHON"], isValidPython(envPy) {
            return envPy
        }

        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for entry in pathEnv.split(separator: ";") {
                let candidate = String(entry).trimmingCharacters(in: .whitespacesAndNewlines)
                if candidate.isEmpty { continue }
                let exe = URL(fileURLWithPath: candidate).appendingPathComponent("python.exe").path
                if isValidPython(exe) {
                    return exe
                }
            }
        }

        var searchRoots: [String] = []
        if let localApp = ProcessInfo.processInfo.environment["LOCALAPPDATA"] {
            searchRoots.append(localApp + "\\Programs\\Python")
        }
        if let progFiles = ProcessInfo.processInfo.environment["ProgramFiles"] {
            searchRoots.append(progFiles)
        }
        searchRoots.append("C:\\")

        for root in searchRoots {
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: root) else { continue }
            let sorted = items.filter { $0.lowercased().hasPrefix("python3") }.sorted(by: >)
            for folder in sorted {
                let candidate = URL(fileURLWithPath: root)
                    .appendingPathComponent(folder)
                    .appendingPathComponent("python.exe").path
                if isValidPython(candidate) {
                    return candidate
                }
            }
        }
        return nil
    }
}

import Foundation
import WinSDK

Win32Theme.enableDPIAwareness()
_ = CoInitializeEx(nil, DWORD(COINIT_APARTMENTTHREADED.rawValue))

let singleInstance = SingleInstanceGuard()
guard singleInstance.acquireOrActivateExisting(windowClassName: MainWindow.windowClassName) else {
    CoUninitialize()
    exit(0)
}

let paths = YacineTVPaths.resolve()
let storage = StorageStore(appDataDir: paths.appDataDir)
let backend = BackendProcess(paths: paths)
let mainWindow = MainWindow(paths: paths, storage: storage, backend: backend)

guard mainWindow.createAndShow() else {
    backend.stop()
    CoUninitialize()
    exit(1)
}

var msg = MSG()
while GetMessageW(&msg, nil, 0, 0) {
    TranslateMessage(&msg)
    DispatchMessageW(&msg)
}

backend.stop()
CoUninitialize()

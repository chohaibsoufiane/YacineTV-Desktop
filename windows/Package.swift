// swift-tools-version: 6.0
import PackageDescription
import Foundation

let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let webView2Base = "\(packageDir)/.deps/webview2/build/native"
let webView2X64 = "\(webView2Base)/x64"
let resFilePath = "\(packageDir)/Resources/YacineTV.res"

var extraLinkerFlags: [String] = [
    "-L\(webView2X64)",
    "-Xlinker", "/SUBSYSTEM:WINDOWS",
    "-Xlinker", "/ENTRY:mainCRTStartup",
]
if FileManager.default.fileExists(atPath: resFilePath) {
    extraLinkerFlags.append(contentsOf: ["-Xlinker", resFilePath])
}

let package = Package(
    name: "YacineTV",
    products: [
        .executable(name: "YacineTV", targets: ["YacineTV"]),
    ],
    targets: [
        .target(
            name: "CWebView2Bridge",
            path: "Sources/CWebView2Bridge",
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("../../.deps/webview2/build/native/include"),
                .define("_CRT_SECURE_NO_WARNINGS"),
            ]
        ),
        .executableTarget(
            name: "YacineTV",
            dependencies: ["CWebView2Bridge"],
            path: "Sources/YacineTV",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ],
            linkerSettings: [
                .unsafeFlags(extraLinkerFlags),
                .linkedLibrary("WebView2LoaderStatic"),
                .linkedLibrary("User32"),
                .linkedLibrary("Gdi32"),
                .linkedLibrary("Dwmapi"),
                .linkedLibrary("Shell32"),
                .linkedLibrary("Ole32"),
                .linkedLibrary("OleAut32"),
                .linkedLibrary("Advapi32"),
                .linkedLibrary("Version"),
                .linkedLibrary("Shlwapi"),
                .linkedLibrary("Ws2_32"),
            ]
        ),
    ],
    cxxLanguageStandard: .cxx17
)

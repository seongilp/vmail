// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "vmail",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        // 프로토콜(IMAP/SMTP)과 MIME 처리 — UI 의존성 없음, 테스트 대상
        .target(
            name: "MailCore",
            path: "Sources/MailCore"
        ),
        .executableTarget(
            name: "vmail",
            dependencies: ["MailCore"],
            path: "Sources/vmail"
        ),
        .testTarget(
            name: "MailCoreTests",
            dependencies: ["MailCore"],
            path: "Tests/MailCoreTests"
        ),
    ]
)

// 앱 아이콘(1024px PNG) 생성 스크립트. build 시가 아니라 아이콘 갱신 때만 수동 실행.
// 사용: swift Resources/make-icon.swift <출력경로.png>
import AppKit

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

// macOS 아이콘 표준 여백을 가진 라운드 사각형 배경 (파란 그라디언트)
let margin: CGFloat = 100
let bgRect = NSRect(x: margin, y: margin, width: size - margin * 2, height: size - margin * 2)
let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: 185, yRadius: 185)
NSGradient(
    starting: NSColor(calibratedRed: 0.25, green: 0.62, blue: 1.0, alpha: 1),
    ending: NSColor(calibratedRed: 0.05, green: 0.33, blue: 0.90, alpha: 1)
)!.draw(in: bgPath, angle: -90)

// 흰 봉투
let envelope = NSRect(x: 232, y: 322, width: 560, height: 380)
let body = NSBezierPath(roundedRect: envelope, xRadius: 44, yRadius: 44)
NSColor.white.setFill()
body.fill()

// 봉투 덮개 선
let flap = NSBezierPath()
flap.move(to: NSPoint(x: envelope.minX + 34, y: envelope.maxY - 40))
flap.line(to: NSPoint(x: envelope.midX, y: envelope.midY - 20))
flap.line(to: NSPoint(x: envelope.maxX - 34, y: envelope.maxY - 40))
flap.lineWidth = 30
flap.lineCapStyle = .round
flap.lineJoinStyle = .round
NSColor(calibratedRed: 0.10, green: 0.42, blue: 0.95, alpha: 1).setStroke()
flap.stroke()

// 읽지 않음 점
let dot = NSBezierPath(ovalIn: NSRect(x: envelope.maxX - 70, y: envelope.maxY - 70, width: 130, height: 130))
NSColor(calibratedRed: 1.0, green: 0.27, blue: 0.23, alpha: 1).setFill()
dot.fill()
NSColor.white.setStroke()
dot.lineWidth = 16
dot.stroke()

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("PNG 인코딩 실패")
}
do {
    try png.write(to: URL(fileURLWithPath: outputPath))
    print("저장: \(outputPath)")
} catch {
    fatalError("저장 실패: \(error)")
}

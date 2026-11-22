import AppKit
import MailCore

/// 사용자가 브라우저에서 앱 비밀번호를 복사하는 순간을 잡아낸다.
/// 클립보드가 바뀔 때만 내용을 읽고, 앱 비밀번호 형식일 때만 전달한다. 제한 시간이 지나면 스스로 멈춘다.
final class ClipboardWatcher {
    private static let interval: TimeInterval = 0.5
    private static let lifetime: TimeInterval = 10 * 60

    private var timer: Timer?
    private var lastChangeCount = 0
    private var deadline = Date()

    var isRunning: Bool { timer != nil }

    func start(onAppPassword: @escaping (String) -> Void) {
        stop()
        lastChangeCount = NSPasteboard.general.changeCount
        deadline = Date().addingTimeInterval(Self.lifetime)
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            if Date() > self.deadline { return self.stop() }
            let count = NSPasteboard.general.changeCount
            guard count != self.lastChangeCount else { return }
            self.lastChangeCount = count
            guard let text = NSPasteboard.general.string(forType: .string),
                  let password = AppPassword.normalize(text) else { return }
            self.stop()
            onAppPassword(password)
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}

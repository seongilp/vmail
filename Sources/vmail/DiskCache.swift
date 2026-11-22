import Foundation
import MailCore

/// 사서함 목록과 메시지 목록을 디스크에 캐시해 실행 직후 바로 화면을 채운다.
/// 쓰기는 백그라운드 큐에서, 읽기는 작은 JSON이라 호출 스레드에서 한다.
final class DiskCache {
    private let directory: URL
    private let queue = DispatchQueue(label: "com.zihado.vmail.cache", qos: .utility)

    init(email: String) {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("com.zihado.vmail", isDirectory: true)
            .appendingPathComponent(Self.safeName(email), isDirectory: true)
    }

    func loadMailboxes() -> [Mailbox] {
        load([Mailbox].self, from: "mailboxes.json") ?? []
    }

    func saveMailboxes(_ mailboxes: [Mailbox]) {
        save(mailboxes, to: "mailboxes.json")
    }

    func loadEnvelopes(path: String) -> [Envelope] {
        load([Envelope].self, from: Self.envelopeFile(path)) ?? []
    }

    func saveEnvelopes(_ envelopes: [Envelope], path: String) {
        save(envelopes, to: Self.envelopeFile(path))
    }

    func removeAll() {
        let directory = self.directory
        queue.async {
            do {
                if FileManager.default.fileExists(atPath: directory.path) {
                    try FileManager.default.removeItem(at: directory)
                }
            } catch {
                NSLog("vmail: 캐시 삭제 실패 — \(error.localizedDescription)")
            }
        }
    }

    private func load<T: Decodable>(_ type: T.Type, from file: String) -> T? {
        let url = directory.appendingPathComponent(file)
        guard let data = try? Data(contentsOf: url) else { return nil }  // 캐시 없음은 정상
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            NSLog("vmail: 캐시 해석 실패(\(file)) — \(error.localizedDescription)")
            return nil
        }
    }

    private func save<T: Encodable>(_ value: T, to file: String) {
        let directory = self.directory
        queue.async {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try JSONEncoder().encode(value).write(to: directory.appendingPathComponent(file), options: .atomic)
            } catch {
                NSLog("vmail: 캐시 저장 실패(\(file)) — \(error.localizedDescription)")
            }
        }
    }

    private static func envelopeFile(_ path: String) -> String {
        "envelopes-\(safeName(path)).json"
    }

    private static func safeName(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
    }
}

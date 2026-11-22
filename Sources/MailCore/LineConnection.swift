import Foundation

public enum ConnectionSecurity: String, Codable, Sendable {
    case tls        // 접속 즉시 TLS (IMAP 993, SMTP 465)
    case startTLS   // 평문으로 시작해 STARTTLS로 승격 (SMTP 587, IMAP 143)
    case none       // 평문 — 로컬 테스트 전용
}

public enum MailError: LocalizedError, Equatable {
    case connection(String)
    case server(String)
    case auth(String)
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case .connection(let m): return "서버에 연결할 수 없습니다. \(m)"
        case .server(let m): return "서버가 요청을 거부했습니다. \(m)"
        case .auth(let m): return "로그인에 실패했습니다. \(m)"
        case .malformed(let m): return "서버 응답을 해석할 수 없습니다. \(m)"
        }
    }

    /// 재접속 후 재시도해 볼 만한 오류인지
    public var isConnectionFailure: Bool {
        if case .connection = self { return true }
        return false
    }
}

/// 줄 단위 텍스트 프로토콜용 동기 소켓. 반드시 백그라운드 큐에서만 사용한다.
/// CFStream 기반이라 평문 → TLS 승격(STARTTLS)이 가능하다.
/// 스트림 이벤트는 전용 큐에서 받고, 호출 스레드는 조건 변수로 timeout까지만 기다린다.
final class LineConnection: NSObject, StreamDelegate {
    private static let chunkSize = 64 * 1024

    let host: String
    let port: Int
    private let timeout: TimeInterval
    private let eventQueue = DispatchQueue(label: "com.zihado.vmail.stream")
    private let condition = NSCondition()
    private var input: InputStream?
    private var output: OutputStream?
    private var buffer = Data()
    private var scanOffset = 0

    init(host: String, port: Int, timeout: TimeInterval = 30) {
        self.host = host
        self.port = port
        self.timeout = timeout
    }

    func open(security: ConnectionSecurity) throws {
        var inStream: InputStream?
        var outStream: OutputStream?
        Stream.getStreamsToHost(withName: host, port: port, inputStream: &inStream, outputStream: &outStream)
        guard let inStream, let outStream else {
            throw MailError.connection("\(host):\(port) 주소가 올바르지 않습니다.")
        }
        input = inStream
        output = outStream
        if security == .tls { try startTLS() }
        inStream.delegate = self
        outStream.delegate = self
        CFReadStreamSetDispatchQueue(inStream, eventQueue)
        CFWriteStreamSetDispatchQueue(outStream, eventQueue)
        inStream.open()
        outStream.open()
    }

    /// 현재 스트림을 TLS로 승격한다. 호스트 이름 검증은 시스템 기본 정책을 따른다.
    func startTLS() throws {
        guard let input, let output else { throw MailError.connection("연결이 닫혀 있습니다.") }
        // 이미 열린 스트림에도 적용되도록 SSL 설정 딕셔너리로 지정한다(STARTTLS 승격).
        let settings = [kCFStreamSSLLevel as String: StreamSocketSecurityLevel.negotiatedSSL.rawValue] as CFDictionary
        let key = CFStreamPropertyKey(rawValue: kCFStreamPropertySSLSettings)
        let okIn = CFReadStreamSetProperty(input, key, settings)
        let okOut = CFWriteStreamSetProperty(output, key, settings)
        guard okIn, okOut else { throw MailError.connection("TLS를 시작할 수 없습니다.") }
    }

    func close() {
        if let input {
            CFReadStreamSetDispatchQueue(input, nil)
            input.delegate = nil
            input.close()
        }
        if let output {
            CFWriteStreamSetDispatchQueue(output, nil)
            output.delegate = nil
            output.close()
        }
        input = nil
        output = nil
        buffer = Data()
        scanOffset = 0
    }

    /// CRLF(또는 LF)로 끝나는 한 줄을 읽어 줄바꿈을 뗀 바이트를 돌려준다.
    func readLine() throws -> Data {
        while true {
            if let lf = buffer[scanOffset...].firstIndex(of: 0x0A) {
                var end = lf
                if end > 0, buffer[end - 1] == 0x0D { end -= 1 }
                let line = buffer.subdata(in: 0..<end)
                consume(lf + 1)
                return line
            }
            scanOffset = buffer.count
            try fill()
        }
    }

    func readBytes(_ count: Int) throws -> Data {
        while buffer.count < count { try fill() }
        let data = buffer.subdata(in: 0..<count)
        consume(count)
        return data
    }

    func write(_ data: Data) throws {
        guard let output else { throw MailError.connection("연결이 닫혀 있습니다.") }
        let bytes = [UInt8](data)
        var sent = 0
        while sent < bytes.count {
            try waitUntil(output) { output.hasSpaceAvailable }
            let n = bytes[sent...].withUnsafeBufferPointer { output.write($0.baseAddress!, maxLength: $0.count) }
            if n <= 0 { throw failure(output.streamError) }
            sent += n
        }
    }

    func write(_ text: String) throws {
        try write(Data(text.utf8))
    }

    // MARK: - StreamDelegate (eventQueue)

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        condition.lock()
        condition.broadcast()
        condition.unlock()
    }

    // MARK: - Private

    private func consume(_ count: Int) {
        buffer = buffer.subdata(in: count..<buffer.count)
        scanOffset = 0
    }

    private func fill() throws {
        guard let input else { throw MailError.connection("연결이 닫혀 있습니다.") }
        try waitUntil(input) { input.hasBytesAvailable }
        var chunk = [UInt8](repeating: 0, count: Self.chunkSize)
        let n = input.read(&chunk, maxLength: Self.chunkSize)
        if n > 0 {
            buffer.append(chunk, count: n)
        } else if n == 0 {
            throw MailError.connection("서버가 연결을 끊었습니다.")
        } else {
            throw failure(input.streamError)
        }
    }

    /// 스트림이 준비되거나 실패할 때까지 최대 timeout 동안 기다린다.
    private func waitUntil(_ stream: Stream, _ ready: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while true {
            if ready() { return }
            switch stream.streamStatus {
            case .error: throw failure(stream.streamError)
            case .atEnd, .closed: throw MailError.connection("서버가 연결을 끊었습니다.")
            default: break
            }
            // 이벤트를 놓쳐도 0.5초마다 상태를 다시 확인한다.
            let slice = min(deadline, Date().addingTimeInterval(0.5))
            if !condition.wait(until: slice), Date() >= deadline {
                throw MailError.connection("응답 시간이 초과되었습니다.")
            }
        }
    }

    private func failure(_ error: Error?) -> MailError {
        .connection(error?.localizedDescription ?? "응답 시간이 초과되었습니다.")
    }
}

import Foundation

/// 간단한 명령줄 인자 해석기: 위치 인자, 값을 받는 옵션(-n 20, --to a@b), 스위치(--json).
public struct CommandLineOptions: Equatable {
    public enum ParseError: LocalizedError, Equatable {
        case unknownOption(String)
        case missingValue(String)

        public var errorDescription: String? {
            switch self {
            case .unknownOption(let name): return "알 수 없는 옵션입니다: \(name)"
            case .missingValue(let name): return "\(name) 옵션에는 값이 필요합니다."
            }
        }
    }

    public let positionals: [String]
    private let values: [String: [String]]
    private let switches: Set<String>

    /// valued: 값을 받는 옵션 이름, flags: 스위치 이름. 짧은 이름은 aliases로 긴 이름에 연결한다 (["-n": "--count"]).
    public init(_ arguments: [String], valued: Set<String>, flags: Set<String>, aliases: [String: String] = [:]) throws {
        var positionals: [String] = []
        var values: [String: [String]] = [:]
        var switches: Set<String> = []
        var index = 0
        var optionsEnded = false
        while index < arguments.count {
            let raw = arguments[index]
            index += 1
            if optionsEnded || !raw.hasPrefix("-") || raw == "-" {
                positionals.append(raw)
                continue
            }
            if raw == "--" {
                optionsEnded = true
                continue
            }
            // --name=value 형태
            let parts = raw.split(separator: "=", maxSplits: 1).map(String.init)
            let name = aliases[parts[0]] ?? parts[0]
            if flags.contains(name) {
                switches.insert(name)
            } else if valued.contains(name) {
                if parts.count == 2 {
                    values[name, default: []].append(parts[1])
                } else {
                    guard index < arguments.count else { throw ParseError.missingValue(parts[0]) }
                    values[name, default: []].append(arguments[index])
                    index += 1
                }
            } else {
                throw ParseError.unknownOption(parts[0])
            }
        }
        self.positionals = positionals
        self.values = values
        self.switches = switches
    }

    public func value(_ name: String) -> String? { values[name]?.last }
    public func all(_ name: String) -> [String] { values[name] ?? [] }
    public func has(_ name: String) -> Bool { switches.contains(name) }
}

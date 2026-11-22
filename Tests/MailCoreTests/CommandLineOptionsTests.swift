import XCTest
@testable import MailCore

final class CommandLineOptionsTests: XCTestCase {
    private func parse(_ arguments: [String]) throws -> CommandLineOptions {
        try CommandLineOptions(arguments, valued: ["--count", "--to", "--mailbox"], flags: ["--json", "--unread"],
                               aliases: ["-n": "--count", "-m": "--mailbox"])
    }

    func testParsesPositionalsValuesAndFlags() throws {
        let options = try parse(["회의", "-n", "5", "--json", "--to", "a@x.io", "--to=b@x.io", "-m", "Sent"])
        XCTAssertEqual(options.positionals, ["회의"])
        XCTAssertEqual(options.value("--count"), "5")
        XCTAssertEqual(options.all("--to"), ["a@x.io", "b@x.io"])
        XCTAssertEqual(options.value("--mailbox"), "Sent")
        XCTAssertTrue(options.has("--json"))
        XCTAssertFalse(options.has("--unread"))
        XCTAssertNil(options.value("--missing"))
    }

    func testDoubleDashEndsOptions() throws {
        let options = try parse(["--", "--json", "-n"])
        XCTAssertEqual(options.positionals, ["--json", "-n"])
        XCTAssertFalse(options.has("--json"))
    }

    func testSingleDashIsPositional() throws {
        XCTAssertEqual(try parse(["-"]).positionals, ["-"])
    }

    func testErrors() {
        XCTAssertThrowsError(try parse(["--nope"])) { XCTAssertEqual($0 as? CommandLineOptions.ParseError, .unknownOption("--nope")) }
        XCTAssertThrowsError(try parse(["-n"])) { XCTAssertEqual($0 as? CommandLineOptions.ParseError, .missingValue("-n")) }
    }
}

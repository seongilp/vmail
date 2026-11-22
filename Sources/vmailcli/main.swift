import Foundation
import MailCore

/// vmail 명령줄 도구. 앱에 등록한 계정을 그대로 쓴다.
let usage = """
vmail — 터미널에서 쓰는 vmail

사용법:
  vmail accounts                          등록된 계정 목록
  vmail mailboxes [-a 계정]                사서함 목록
  vmail list [-m 사서함] [-n 개수] [--unread]  메일 목록 (기본: 받은편지함 최근 20통)
  vmail read <UID> [-m 사서함] [--raw] [--attachments 폴더]
  vmail search <검색어> [-m 사서함] [-n 개수] [--from]
  vmail send --to 주소 [--cc 주소] [--bcc 주소] --subject 제목 [--body 본문] [--attach 파일] [--dry-run]
             본문을 생략하면 표준 입력에서 읽습니다. --dry-run 은 보내지 않고 내용만 확인합니다.
  vmail mark <UID>... (--read | --unread | --flag | --unflag) [-m 사서함]
  vmail move <UID>... --dest 사서함 [-m 사서함]
  vmail delete <UID>... [-m 사서함]           휴지통으로 이동 (휴지통에서는 완전 삭제)
  vmail doctor                              계정별 키체인·로그인 점검
  vmail agent-guide                         AI 에이전트용 사용 안내
  vmail install-skill                       Claude Code·Codex용 스킬 설치

공통 옵션:
  -a, --account <이메일 일부>   사용할 계정 (기본: 첫 번째 계정)
  --json                       JSON으로 출력. 오류도 표준 오류에 {"error": "..."} 로 나옵니다.
  --config <파일>              앱에서 내보낸 설정 파일의 계정을 사용 (비밀번호는 VMAIL_PASSWORD 환경 변수)
  -h, --help                   도움말

사서함은 이름이나 역할(inbox, sent, drafts, trash, junk, all)로 지정합니다.
"""

/// 종료 코드: 0 성공, 1 실행 오류(연결·인증·서버), 64 사용법 오류
func fail(_ message: String, code: Int32 = 1) -> Never {
    var text = "vmail: \(message)\n"
    if CommandLine.arguments.contains("--json"),
       let data = try? JSONSerialization.data(withJSONObject: ["error": message], options: [.withoutEscapingSlashes]) {
        text = String(decoding: data, as: UTF8.self) + "\n"
    }
    FileHandle.standardError.write(Data(text.utf8))
    exit(code)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first, command != "-h", command != "--help", command != "help" else {
    print(usage)
    exit(arguments.isEmpty ? 64 : 0)
}

do {
    let options = try CommandLineOptions(
        Array(arguments.dropFirst()),
        valued: ["--account", "--mailbox", "--count", "--to", "--cc", "--bcc", "--subject", "--body", "--attach",
                 "--attachments", "--config", "--dest"],
        flags: ["--json", "--unread", "--raw", "--from", "--help", "--read", "--flag", "--unflag", "--dry-run"],
        aliases: ["-a": "--account", "-m": "--mailbox", "-n": "--count", "-h": "--help"])
    if options.has("--help") {
        print(usage)
        exit(0)
    }
    try Commands(options: options).run(command)
} catch let error as CommandLineOptions.ParseError {
    fail("\(error.localizedDescription)\n‘vmail --help’로 사용법을 확인하세요.", code: 64)
} catch let error as CLIError {
    fail(error.message, code: error.isUsage ? 64 : 1)
} catch {
    fail(error.localizedDescription)
}

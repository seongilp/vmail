# vmail

macOS용 빠르고 단순한 네이티브 메일 앱. AppKit + 시스템 프레임워크만 사용하고, IMAP/SMTP·MIME 처리를 직접 구현해 외부 의존성이 없습니다.

![vmail](docs/screenshot.png)

## 기능

- 3단 레이아웃: 계정별 사서함 트리 · 메시지 목록 · 본문
- 여러 계정 (설정 › 계정에서 추가·수정·제거)
- IMAP 수신 (TLS / STARTTLS), SMTP 발신 (465 TLS / 587 STARTTLS)
- 새 메일, 답장, 모두에게 답장, 전달, 숨은 참조, 서명, 파일 첨부, 임시 저장
- 읽음/읽지 않음, 깃발, 삭제, 보관, 스팸, 사서함 간 이동(메뉴·드래그)
- 목록 즉시 필터 + Enter로 서버 전체 검색, 읽지 않은 메일만 보기
- 폴더 만들기·이름 변경·삭제, 모두 읽음, 휴지통 비우기
- 새 메일 알림, mailto: 링크, 프린트, 원본(.eml) 저장, 본문 확대/축소
- HTML 메일 렌더링 — 스크립트 비활성화, 원격 이미지 기본 차단
- 첨부 파일 열기 / 다운로드 폴더에 저장
- 한국어 레거시 인코딩(EUC-KR, CP949) 지원
- 목록 디스크 캐시로 실행 즉시 표시, 60초마다 자동 새로 고침, Dock 배지

## 계정

이메일 주소를 입력하면 서버 설정이 자동으로 채워집니다 (Gmail, 네이버, 다음, 카카오, iCloud, Yahoo).

- Gmail · iCloud 등 2단계 인증 계정은 **앱 비밀번호**가 필요합니다. 시트의 ‘앱 비밀번호 발급 페이지 열기’ 버튼으로 바로 이동할 수 있습니다.
- ‘키체인에서 가져오기’는 다른 메일 앱이 로그인 키체인에 저장해 둔 IMAP 비밀번호를 불러옵니다. OAuth로 로그인한 계정(Apple Mail의 Gmail 등)은 비밀번호가 존재하지 않아 가져올 수 없습니다.
- 비밀번호는 이 Mac의 키체인에만 저장됩니다.

## 빌드

Xcode 프로젝트 없이 SwiftPM으로 빌드합니다. macOS 13 이상.

```bash
./build.sh                    # 릴리스 빌드 → vmail.app 조립 → 서명
open -a "$(pwd)/vmail.app"
swift test                    # 단위·프로토콜 테스트
VMAIL_NET=1 swift test        # 실제 서버와 TLS 핸드셰이크까지 확인
```

## 구조

```
Sources/MailCore/   프로토콜·파싱 (UI 의존성 없음)
  LineConnection    줄 단위 소켓 (TLS, STARTTLS 승격, 타임아웃)
  IMAPClient/Parser IMAP4rev1 클라이언트와 응답 파서
  SMTPClient        메시지 발송
  MIMEParser        헤더·multipart·전송 인코딩
  ParsedMessage     화면 표시용 메시지 해석
  MessageBuilder    보낼 메시지 조립
  MailSession       백그라운드 큐에서 연결 관리·재시도
Sources/vmail/      AppKit UI
```

## 단축키

| 동작 | 키 |
| --- | --- |
| 새로운 메일 | ⌘N |
| 메일 가져오기 | ⌘R |
| 답장 / 모두에게 답장 / 전달 | ⇧⌘R / ⌥⌘R / ⇧⌘F |
| 보관 / 스팸으로 이동 | ⌃⌘A / ⇧⌘J |
| 임시 저장 | ⌘S |
| 보내기 | ⇧⌘D 또는 ⌘↩ |
| 읽음 전환 / 깃발 | ⇧⌘U / ⇧⌘L |
| 삭제 | ⌫ |
| 검색 | ⌘F |
| 설정 | ⌘, |

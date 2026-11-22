#!/bin/bash
# vmail 릴리스 빌드 후 .app 번들을 조립한다.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="vmail"
APP_BUNDLE="${APP_NAME}.app"

echo "==> swift build (release)"
swift build -c release

echo "==> ${APP_BUNDLE} 조립"
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS" "${APP_BUNDLE}/Contents/Resources"
cp ".build/release/${APP_NAME}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
# 명령줄 도구 (Homebrew가 PATH에 vmail 로 연결한다)
cp ".build/release/vmailcli" "${APP_BUNDLE}/Contents/MacOS/vmail-cli"
cp "Resources/Info.plist" "${APP_BUNDLE}/Contents/Info.plist"
cp "Resources/AppIcon.icns" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"

echo "==> 코드 서명"
# Developer ID 인증서가 있으면 정식 서명(hardened runtime + timestamp), 없으면 ad-hoc
DEV_ID=$(security find-identity -v -p codesigning | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true)
if [ -n "${DEV_ID}" ]; then
    # 번들 안의 추가 실행 파일은 번들보다 먼저 따로 서명해야 공증을 통과한다
    codesign --force --options runtime --timestamp --sign "${DEV_ID}" "${APP_BUNDLE}/Contents/MacOS/vmail-cli"
    codesign --force --options runtime --timestamp --sign "${DEV_ID}" "${APP_BUNDLE}"
    echo "    서명: ${DEV_ID}"
else
    codesign --force --sign - "${APP_BUNDLE}/Contents/MacOS/vmail-cli"
    codesign --force --sign - "${APP_BUNDLE}"
    echo "    서명: ad-hoc (Developer ID 없음)"
fi

echo "완료: $(pwd)/${APP_BUNDLE}"

# Qt Base — macOS 한국어 IME 합성기 패치 포크

LGPL-3.0 준수를 위해 공개. PR 목적 없음 (upstream 기여 아님).

이 포크의 바이너리에 link 하는 다운스트림 프로젝트의 라이선스 의무
(수정된 소스 공개)를 만족시키기 위한 저장소.

## 해결하는 문제

Apple 의 default macOS 한국어 IME (`com.apple.inputmethod.Korean.2SetKorean`)
가 Qt 6 / QtWebEngine 의 `NSTextInputClient` 에 대해 **호환 자모를 raw 로
dispatch** (`ㄱ + ㅏ` 별도) 함. Chrome / Notion / Mail 같은 native NSView
앱에서는 발생 안 함 — Qt 의 `QNSView` 표면 한정 버그.

- [QTBUG-136128](https://bugreports.qt.io/browse/QTBUG-136128)
- [Mozilla #1233998](https://bugzilla.mozilla.org/show_bug.cgi?id=1233998)
- Apple Feedback FB17460926

수년간 upstream 미해결. Apple IMK 의 private SPI 영역.

## 추가한 기능

`src/plugins/platforms/cocoa/qnsview_complextext.mm` /
`qnsview_keys.mm` 에 **2-set 자모 합성기** 직접 구현:

- 노드 기반 FSM (S0/S1/S2/S3) — cho/jung/jong 노드와 명시적 transition.
- Apple 의 cold / warm dispatch / wrap-up / paired commit / 한영 토글
  orphan flush 모두 처리.
- 받침이동: single-dispatch (가가) + split-prev+new 두 dispatch
  (가고 / 고가 / 갈가) 두 경로 모두 지원.
- 출력은 `QInputMethodEvent::setCommitString` commit-only — preedit
  미송신 → QtWebEngine 의 Blink composition highlight 없음.

기존 Qt API / 비-한국어 IME 동작 무영향. 단일 squash 커밋, 876 라인 추가.

## 테스트한 내용

C++ 알고리즘을 그대로 미러한 Python reference (`composer_sim.py`,
다운스트림 저장소에 동반) 의 unittest 25 케이스로 회귀 검증:

- 기본 합성: 가 / 과 (cold combine + cold upgrade) / 황 (받침 흡수)
- Cross-syllable: 가가 / 가고 / 고가 / 갈가 (받침이동, same/diff jung
  모두), 과과 / 과과과 (warm 받침이동 + jung upgrade)
- Wrap-up: 감{한영} 의 ㅁ orphan, 괅{한영} 의 ㄱ orphan
- Dup 게이트 회귀: ㄱㄱ (cross-round 정상 입력), 각ㄱ / 글ㄹ ("더 갈
  노드 없으면 finalize + 새로 열기")
- Cho mismatch retroactive strip jong, 복합 받침 분리
- Backspace 분해 (libhangul 정책): 값 → 갑 → 가 → ㄱ → "", 왕 / 웡 4단계

실제 PySide6 앱 (macOS arm64) 에서도 위 케이스 + 한글 + 한영 토글 +
포커스 이동 시나리오 사용자 검증 완료.

## 빌드

```sh
git clone https://github.com/suhyun-hwang/qtbase.git
cd qtbase   # 기본 브랜치 = feature/macos-korean-ime-composer (패치 포함)
# 이후 일반 Qt 빌드와 동일
```

## 라이선스

수정된 두 파일 (`qnsview_complextext.mm` / `qnsview_keys.mm`) 의 SPDX
헤더 유지 — 기존 Qt 와 동일하게 LGPL-3.0-only / GPL-2.0-only /
GPL-3.0-only / commercial 다중 라이선스. 본 포크의 패치 부분도 동일
조건으로 제공.

The Qt Company 와 무관 (unofficial fork).

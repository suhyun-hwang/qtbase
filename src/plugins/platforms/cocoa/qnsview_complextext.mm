// Copyright (C) 2021 The Qt Company Ltd.
// SPDX-License-Identifier: LicenseRef-Qt-Commercial OR LGPL-3.0-only OR GPL-2.0-only OR GPL-3.0-only

// This file is included from qnsview.mm, and only used to organize the code

// ============================================================================
// Hangul composer — workaround for QTBUG-136128 / FB17460926.
//
// On Qt 6 with the default macOS Korean IME (2-set / 3-set), Apple's IMK
// dispatches raw 호환 자모 (Hangul compatibility jamo) to NSTextInputClient
// instead of pre-composed Hangul syllables (also reported as Mozilla
// #1233998). The dispatches arrive as a mix of compatibility jamo and
// pre-composed syllables, with extra wrap-up / paired-commit dispatches
// between key rounds.
//
// To work around the breakage in HTML inputs / QtWebEngine, we intercept
// the NSTextInputClient surface (insertText / setMarkedText) and run a
// 2-set state machine here. Syllables are emitted as commit-only
// QInputMethodEvents (no preedit), which keeps Blink from painting the
// yellow composition highlight while still letting Qt clients receive
// well-formed Hangul syllables.
//
// Apple dispatch patterns observed:
//   Cold (first syllable after locale switch):
//     insertText  ㄱ   (cho)
//     setMarkedText ㅏ (jung)
//     setMarkedText ㅏ (dup)
//     insertText  가   (paired commit)
//   Warm:
//     setMarkedText ㅎ (cho-only)
//     setMarkedText 호 (syllable)
//     setMarkedText 화 (복합 모음 syllable)
//     setMarkedText 활 (받침 syllable)
//     setMarkedText 홝 (복합 받침 syllable)
//     setMarkedText 홝 (dup)
//     insertText  홝   (paired commit)
//
// Additional quirks the composer must tolerate:
//   - Cross-round wrap-up: IMK re-emits the last raw jamo of the prior
//     syllable just before processing the new key (e.g. setMarkedText ㅏ
//     in a ㅇ keyDown that follows the syllable 화).
//   - 한영 (kVK_CapsLock) toggle orphan: IMK flushes the prior syllable's
//     jong as a raw cons just after the toggle.
//   - flagsChanged sometimes swallows the first keyDown after the KR↔EN
//     switch; hookKeyDown predispatches in parallel with a dup window.
// ============================================================================

static inline bool isHangulCompatCho(ushort u)  { return u >= 0x3131 && u <= 0x314E; }
static inline bool isHangulCompatJung(ushort u) { return u >= 0x314F && u <= 0x3163; }

static inline bool isHangulCompatJamoSingle(const QString &s)
{
    if (s.size() != 1) return false;
    const ushort u = s.at(0).unicode();
    return isHangulCompatCho(u) || isHangulCompatJung(u);
}

static inline bool isHangulSyllableSingle(const QString &s)
{
    if (s.size() != 1) return false;
    const ushort u = s.at(0).unicode();
    return u >= 0xAC00 && u <= 0xD7A3;
}

// Compat consonant -> cho index. -1 for cluster-only compat consonants
// (ㄳ/ㄵ/ㄶ/ㄺ/ㄻ/ㄼ/ㄽ/ㄾ/ㄿ/ㅀ/ㅄ) which cannot start a syllable.
static int choIdxFromCompat(ushort u)
{
    switch (u) {
    case 0x3131: return 0;   case 0x3132: return 1;   case 0x3134: return 2;
    case 0x3137: return 3;   case 0x3138: return 4;   case 0x3139: return 5;
    case 0x3141: return 6;   case 0x3142: return 7;   case 0x3143: return 8;
    case 0x3145: return 9;   case 0x3146: return 10;  case 0x3147: return 11;
    case 0x3148: return 12;  case 0x3149: return 13;  case 0x314A: return 14;
    case 0x314B: return 15;  case 0x314C: return 16;  case 0x314D: return 17;
    case 0x314E: return 18;
    default:     return -1;
    }
}

static int jungIdxFromCompat(ushort u)
{
    if (u < 0x314F || u > 0x3163) return -1;
    return int(u) - 0x314F;
}

static int jongIdxFromCompat(ushort u)
{
    switch (u) {
    case 0x3131: return 1;   case 0x3132: return 2;   case 0x3134: return 4;
    case 0x3137: return 7;   case 0x3139: return 8;   case 0x3141: return 16;
    case 0x3142: return 17;  case 0x3145: return 19;  case 0x3146: return 20;
    case 0x3147: return 21;  case 0x3148: return 22;  case 0x314A: return 23;
    case 0x314B: return 24;  case 0x314C: return 25;  case 0x314D: return 26;
    case 0x314E: return 27;
    default:     return 0;
    }
}

// 복합 모음 components, indexed by jung idx (0..20). For single jung both are
// -1. For 복합, .base is the first raw component, .second is the last.
typedef struct { int base; int second; } JungCombo;
static const JungCombo jungComboTable[21] = {
    {-1, -1}, {-1, -1}, {-1, -1}, {-1, -1}, {-1, -1}, {-1, -1},
    {-1, -1}, {-1, -1}, {-1, -1},                             // 0..8: single
    { 8,  0}, { 8,  1}, { 8, 20},                             // 9..11: ㅘㅙㅚ
    {-1, -1}, {-1, -1},                                       // 12..13
    {13,  4}, {13,  5}, {13, 20},                             // 14..16: ㅝㅞㅟ
    {-1, -1}, {-1, -1},                                       // 17..18
    {18, 20},                                                 // 19: ㅢ
    {-1, -1},                                                 // 20: ㅣ
};

// 받침 이동 / 복합 받침 split, indexed by jong idx (0..27). For each jong:
//   .movedCho   = cho idx of the cons that moves to the next syllable
//   .remJong    = jong idx that stays in the prev syllable (0 if single)
//   .baseCons   = first cons jong idx (for compound) — used by combine
//   .addedCons  = second cons jong idx (for compound)
// Single jong has baseCons = -1.
typedef struct { int movedCho; int remJong; int baseCons; int addedCons; }
    JongInfo;
static const JongInfo jongInfoTable[28] = {
    /*  0 none */ { -1, 0,  -1, -1 },
    /*  1 ㄱ  */ {  0, 0,  -1, -1 },
    /*  2 ㄲ  */ {  1, 0,  -1, -1 },
    /*  3 ㄳ  */ {  9, 1,   1, 19 },  // ㄱ + ㅅ
    /*  4 ㄴ  */ {  2, 0,  -1, -1 },
    /*  5 ㄵ  */ { 12, 4,   4, 22 },  // ㄴ + ㅈ
    /*  6 ㄶ  */ { 18, 4,   4, 27 },  // ㄴ + ㅎ
    /*  7 ㄷ  */ {  3, 0,  -1, -1 },
    /*  8 ㄹ  */ {  5, 0,  -1, -1 },
    /*  9 ㄺ  */ {  0, 8,   8,  1 },  // ㄹ + ㄱ
    /* 10 ㄻ  */ {  6, 8,   8, 16 },  // ㄹ + ㅁ
    /* 11 ㄼ  */ {  7, 8,   8, 17 },  // ㄹ + ㅂ
    /* 12 ㄽ  */ {  9, 8,   8, 19 },  // ㄹ + ㅅ
    /* 13 ㄾ  */ { 16, 8,   8, 25 },  // ㄹ + ㅌ
    /* 14 ㄿ  */ { 17, 8,   8, 26 },  // ㄹ + ㅍ
    /* 15 ㅀ  */ { 18, 8,   8, 27 },  // ㄹ + ㅎ
    /* 16 ㅁ  */ {  6, 0,  -1, -1 },
    /* 17 ㅂ  */ {  7, 0,  -1, -1 },
    /* 18 ㅄ  */ {  9,17,  17, 19 },  // ㅂ + ㅅ
    /* 19 ㅅ  */ {  9, 0,  -1, -1 },
    /* 20 ㅆ  */ { 10, 0,  -1, -1 },
    /* 21 ㅇ  */ { 11, 0,  -1, -1 },
    /* 22 ㅈ  */ { 12, 0,  -1, -1 },
    /* 23 ㅊ  */ { 14, 0,  -1, -1 },
    /* 24 ㅋ  */ { 15, 0,  -1, -1 },
    /* 25 ㅌ  */ { 16, 0,  -1, -1 },
    /* 26 ㅍ  */ { 17, 0,  -1, -1 },
    /* 27 ㅎ  */ { 18, 0,  -1, -1 },
};

static int  combineJung(int prev, int newJung)
{
    for (int i = 9; i < 21; i++) {
        if (jungComboTable[i].base == prev && jungComboTable[i].second == newJung)
            return i;
    }
    return -1;
}
static bool isUpgradeOfJung(int prev, int incoming)
{
    return incoming >= 0 && incoming < 21
        && jungComboTable[incoming].base == prev;
}
static int  lastRawJungOf(int combined)
{
    if (combined < 0 || combined >= 21) return -1;
    return jungComboTable[combined].second;
}
static int  movedChoFromJong(int jong)
{
    if (jong <= 0 || jong >= 28) return -1;
    return jongInfoTable[jong].movedCho;
}
static int  remainingJongAfterMove(int jong)
{
    if (jong <= 0 || jong >= 28) return 0;
    return jongInfoTable[jong].remJong;
}

// cho idx → compat consonant char (preview when only cho is set).
static QChar compatChoFromIdx(int choIdx)
{
    static const ushort table[19] = {
        0x3131, 0x3132, 0x3134, 0x3137, 0x3138, 0x3139, 0x3141,
        0x3142, 0x3143, 0x3145, 0x3146, 0x3147, 0x3148, 0x3149,
        0x314A, 0x314B, 0x314C, 0x314D, 0x314E
    };
    if (choIdx < 0 || choIdx > 18) return QChar();
    return QChar(table[choIdx]);
}


// ============================================================================
// HangulComposer — 2-set Korean state machine + Apple-IME dispatch tolerance
// ============================================================================
//
// State carries across keyDowns until reset(). Round-local fields are reset
// at enterRound() (called from hookKeyDown).
//
// Public API:
//   reset / hasState / enterRound  — lifecycle
//   feedCompatJamo                  — 호환 자모 한 개 처리 (cho 0x3131..0x314E,
//                                    jung 0x314F..0x3163)
//   feedSyllable                    — Hangul Syllable 한 개 처리 (0xAC00..0xD7A3)
//   handleBackspace                 — libhangul-style 분해
//
// All emits go through emitCurrent() / commit helpers — commit-only, no
// preedit, so Blink never paints the composition highlight.
struct HangulComposer {
    // 합성 중인 syllable 상태 — keyDown 간 유지, reset() 까지.
    int cho = -1;              // 0..18 or -1 (없음)
    int jung = -1;             // 0..20 or -1
    int jong = 0;              // 0=없음, 1..27
    int lastCommittedLen = 0;  // 다음 emit 시 replace 할 chars 수

    // 한 키 라운드 내에서만 유효 — enterRound() 에서 초기화.
    // fedXThisRound: 이 라운드 안에서 X (cho/jung/jong) 카테고리를
    // 한 번이라도 새로 integrate 했으면 true. Apple 의 cold dup /
    // 같은 라운드 wrap-up 을 cross-round 의 같은 jamo 입력과 구분.
    //   - cross-round (fed=false): 새 입력으로 간주, finalize+integrate
    //   - within-round (fed=true): dup wrap-up, DROP-preserve
    ushort keyChar = 0;        // 현재 keyDown 의 chars[0]
    bool fedChoThisRound = false;
    bool fedJungThisRound = false;
    bool fedJongThisRound = false;

    void reset();
    bool hasState() const;
    void enterRound(ushort kc);

    void feedCompatJamo(QNSView *view, ushort u);
    void feedSyllable(QNSView *view, QChar ch);
    bool handleBackspace(QNSView *view);

    QString preeditPreview() const;

private:
    void emitCurrent(QNSView *view);
    void commitAndClear();
};

// Single composer instance (main-thread only — file-static safe).
static HangulComposer composer;

// Apple-IME-quirk state — flagsChanged (Caps Lock = 한영) 직후 IMK 가 첫
// keyDown 을 삼키는 경우가 있어, 다음 keyDown 에서 우리가 parallel-path 로
// 직접 dispatch + IMK 의 동일 dispatch 가 도착하면 dup suppression.
static bool flagsChangedPending = false;
static unichar postFlagChar = 0;
static NSTimeInterval postFlagTimestamp = 0;
static const NSTimeInterval postFlagWindowSec = 0.2;

void hangulComposerMarkFlagsChanged() { flagsChangedPending = true; }


// --- HangulComposer method bodies ---

void HangulComposer::reset()
{
    cho = -1;
    jung = -1;
    jong = 0;
    lastCommittedLen = 0;
}

bool HangulComposer::hasState() const
{
    return cho >= 0 || jung >= 0 || jong > 0 || lastCommittedLen > 0;
}

void HangulComposer::enterRound(ushort kc)
{
    keyChar = kc;
    fedChoThisRound = false;
    fedJungThisRound = false;
    fedJongThisRound = false;
}

void HangulComposer::commitAndClear()
{
    cho = -1;
    jung = -1;
    jong = 0;
    lastCommittedLen = 0;
}

QString HangulComposer::preeditPreview() const
{
    if (cho >= 0 && jung >= 0) {
        const int idx = (cho * 21 + jung) * 28 + jong;
        return QString(QChar(ushort(0xAC00 + idx)));
    }
    if (cho >= 0)  return QString(compatChoFromIdx(cho));
    if (jung >= 0) return QString(QChar(ushort(0x314F + jung)));
    return QString();
}

// Emit current state as commit + replacement of our own previous emission.
// Empty state with lastCommittedLen>0 clears the previous emission.
void HangulComposer::emitCurrent(QNSView *view)
{
    QObject *focusObject = view.focusObject;
    if (!focusObject || !queryInputMethod(focusObject))
        return;

    QString preview;
    if (cho >= 0 && jung >= 0) {
        const int idx = (cho * 21 + jung) * 28 + jong;
        preview = QString(QChar(ushort(0xAC00 + idx)));
    } else if (cho >= 0) {
        preview = QString(compatChoFromIdx(cho));
    } else if (jung >= 0) {
        preview = QString(QChar(ushort(0x314F + jung)));
    } else {
        if (lastCommittedLen > 0) {
            QInputMethodEvent ev;
            ev.setCommitString(QString(), -lastCommittedLen, lastCommittedLen);
            QCoreApplication::sendEvent(focusObject, &ev);
        }
        lastCommittedLen = 0;
        return;
    }

    QInputMethodEvent ev;
    ev.setCommitString(preview, -lastCommittedLen, lastCommittedLen);
    QCoreApplication::sendEvent(focusObject, &ev);
    lastCommittedLen = preview.length();
}

// Feed one 호환 자모 through the FSM. Nodes: S0 (empty) / S1 (cho) /
// S2 (cho+jung) / S3 (cho+jung+jong). Each Apple dispatch either:
//   1) extends the current node along a valid transition, OR
//   2) is a wrap-up / dup of state we already hold → DROP-preserve, OR
//   3) cannot extend further → finalize current node + restart fresh.
//
// Dup vs new-input disambiguation:
//   - JUNG (full or last-raw of compound) matching state.jung: always
//     wrap-up DROP, except in S3 where keyChar==jungCompat → 받침이동.
//   - CHO matching state.cho: DROP only if fedChoThisRound (cold dup).
//     fedChoThisRound=false means cross-round → integrate (ㄱㄱ).
//   - JONG (full or compound's addedCons) matching state.jong: always
//     wrap-up DROP.
void HangulComposer::feedCompatJamo(QNSView *view, ushort u)
{
    const int newCho    = choIdxFromCompat(u);
    const int newJung   = jungIdxFromCompat(u);
    const int jongFromU = jongIdxFromCompat(u);
    const bool isCons   = (newCho >= 0);
    const bool isVow    = (newJung >= 0);
    if (!isCons && !isVow)
        return;

    // 한영 orphan jong flush — Apple 이 한영 토글 직후 직전 syllable 의
    // jong (단일/복합 전체 또는 복합의 마지막 raw cons) 를 flush.
    // FSM 외부 가드 (state 보존).
    if (flagsChangedPending && jong > 0 && isCons && jongFromU > 0) {
        const int added = jongInfoTable[jong].addedCons;
        if (jongFromU == jong || (added > 0 && jongFromU == added))
            return;
    }

    // === Wrap-up / dup detection (DROP-preserve, no state change) ===
    //
    // 세 카테고리 (jung / cho / jong) 모두 동일한 게이트:
    //   (1) fedXThisRound — 같은 라운드 안 재-dispatch (cold dup).
    //   (2) keyChar != u — 사용자가 이 키를 누른게 아닌데 dispatch 됨
    //       (cross-round wrap-up, 예: ㄱㄴ 의 ㄴ keyDown 에서 Apple 이
    //       prev marked ㄱ 을 insertText ㄱ 로 commit-signal; 갉+ㅏ 의
    //       ㄱ wrap-up).
    // 둘 다 false 면 사용자의 새 입력 → 통과 (ㄱㄱ, 각+ㄱ → 각ㄱ,
    // 글+ㄹ → 글ㄹ 등 "더 이상 갈 수 없는 노드 → finalize + 새로 열기").
    //
    // 단, S3 에서 jung dup 는 받침이동 trigger 가능성이 있어 별도 처리 —
    // keyChar == jungCompat 일 때만 받침이동 분기로 통과.

    if (isVow && jung >= 0) {
        const bool fullDup    = (newJung == jung);
        const bool lastRawDup = (lastRawJungOf(jung) == newJung);
        if (fullDup || lastRawDup) {
            const ushort jungCompat = ushort(0x314F + newJung);
            if (jong > 0) {
                // S3: 받침이동 disambiguation 우선
                if (keyChar != jungCompat)
                    return;
                // fall through to 받침이동 (S3 + jung)
            } else {
                if (fedJungThisRound)
                    return;
                if (keyChar != jungCompat)
                    return;
            }
        }
    }

    if (isCons && cho >= 0 && newCho == cho) {
        if (fedChoThisRound)
            return;
        if (keyChar != u)
            return;
    }

    if (isCons && jong > 0 && jongFromU > 0) {
        const int added = jongInfoTable[jong].addedCons;
        if (jongFromU == jong || (added > 0 && jongFromU == added)) {
            if (fedJongThisRound)
                return;
            if (keyChar != u)
                return;
        }
    }

    // === FSM transitions ===

    if (jong > 0) {
        // S3 (cho + jung + jong)
        if (isCons) {
            // jong combine 또는 새 syllable (finalize+restart).
            int combined = 0;
            int prevJ = jong, nxt = jongFromU;
            if      (prevJ == 1  && nxt == 19) combined = 3;
            else if (prevJ == 4  && nxt == 22) combined = 5;
            else if (prevJ == 4  && nxt == 27) combined = 6;
            else if (prevJ == 8  && nxt == 1)  combined = 9;
            else if (prevJ == 8  && nxt == 16) combined = 10;
            else if (prevJ == 8  && nxt == 17) combined = 11;
            else if (prevJ == 8  && nxt == 19) combined = 12;
            else if (prevJ == 8  && nxt == 25) combined = 13;
            else if (prevJ == 8  && nxt == 26) combined = 14;
            else if (prevJ == 8  && nxt == 27) combined = 15;
            else if (prevJ == 17 && nxt == 19) combined = 18;
            if (combined > 0) {
                jong = combined;
                fedJongThisRound = true;
            } else {
                commitAndClear();
                cho = newCho;
                fedChoThisRound = true;
            }
        } else {
            // S3 + jung → 받침이동
            const int movedCho = jongInfoTable[jong].movedCho;
            const int rem      = jongInfoTable[jong].remJong;
            jong = rem;
            commitAndClear();
            cho = (movedCho >= 0 ? movedCho : 11);
            jung = newJung;
            fedJungThisRound = true;
        }
        emitCurrent(view);
        return;
    }

    if (cho >= 0 && jung >= 0) {
        // S2 (cho + jung)
        if (isVow) {
            // Jung upgrade: state.jung 이 incoming combined 의 BASE.
            // Apple cold pattern 이 ㅗ marked → ㅏ keyDown 시 combined
            // ㅘ 를 setMarkedText 로 직접 dispatch.
            if (isUpgradeOfJung(jung, newJung)) {
                jung = newJung;
                fedJungThisRound = true;
            } else {
                const int combined = combineJung(jung, newJung);
                if (combined >= 0) {
                    jung = combined;
                    fedJungThisRound = true;
                } else {
                    // 같은 jung 도 아니고 combine 도 upgrade 도 아님 →
                    // 새 syllable orphan jung.
                    commitAndClear();
                    jung = newJung;
                    fedJungThisRound = true;
                }
            }
        } else {
            if (jongFromU > 0) {
                jong = jongFromU;
                fedJongThisRound = true;
            } else {
                commitAndClear();
                cho = newCho;
                fedChoThisRound = true;
            }
        }
        emitCurrent(view);
        return;
    }

    if (cho >= 0) {
        // S1 (cho only). 같은 cho 의 within-round dup 는 위에서 이미 DROP.
        // 여기 도달했다면 cross-round 새 입력 (ㄱㄱ) 또는 다른 cho.
        if (isCons) {
            commitAndClear();
            cho = newCho;
            fedChoThisRound = true;
        } else {
            jung = newJung;
            fedJungThisRound = true;
        }
        emitCurrent(view);
        return;
    }

    if (jung >= 0) {
        // jung only (드물지만 가능 — 위 wrap-up DROP 후 cleared 등).
        if (isVow) {
            const int combined = combineJung(jung, newJung);
            if (combined >= 0) {
                jung = combined;
                fedJungThisRound = true;
            } else {
                commitAndClear();
                jung = newJung;
                fedJungThisRound = true;
            }
        } else {
            commitAndClear();
            cho = newCho;
            fedChoThisRound = true;
        }
        emitCurrent(view);
        return;
    }

    // S0 (empty)
    if (isCons) {
        cho = newCho;
        fedChoThisRound = true;
    } else {
        jung = newJung;
        fedJungThisRound = true;
    }
    emitCurrent(view);
}

// Apple dispatched a pre-composed syllable (warm path). Trust it, with two
// special transitions:
//   1. 받침 이동: state has jong and the new syllable's cho equals state's
//      movedCho → commit prev as (cho, jung, remJong) and append new.
//   2. cho mismatch: state has wrong cho (Apple absorbed cons as 받침 we
//      should have treated as new syllable cho) → rewind prev, strip jong,
//      append new.
void HangulComposer::feedSyllable(QNSView *view, QChar ch)
{
    QObject *focusObject = view.focusObject;
    if (!focusObject || !queryInputMethod(focusObject))
        return;

    // Paired commit / warm dup: Apple dispatches the same syllable we
    // already emitted as preedit (cold paired insertText 가, warm dup
    // setMarkedText 홝). Swallow without state change.
    if (preeditPreview() == QString(ch))
        return;

    const int code   = ch.unicode() - 0xAC00;
    const int inCho  = code / (21 * 28);
    const int inJung = (code % (21 * 28)) / 28;
    const int inJong = code % 28;

    // 받침이동 prev-split detection. Cross-jung 받침이동 에서 Apple 은
    // post-split prev 와 new syllable 을 두 dispatch 로 나눠 보냄 (예:
    // 각+ㅗ → setMarkedText "가" + setMarkedText "고", 갉+ㅏ →
    // setMarkedText "갈" + setMarkedText "가"). 첫 dispatch 가 (cho,
    // jung, remJong) 형태인 prev-split 일 때 prev 를 잠그고 state 를
    // (cho, jung, rem) 유지 — paired commit insertText "가" 는 preedit
    // -match DROP, 후속 new syllable setMarkedText 는 lastCommittedLen=0
    // 으로 simple-replace 가 append 처리.
    //
    // 같은 representation 케이스 (가가, 가+가가 같은 prev-split == new-
    // syllable) 에서는 Apple 이 single dispatch 만 보냄 — diffJung OR
    // diffJong 조건으로 single-dispatch 케이스 (아래 받침이동 syllable
    // rule) 와 구분.
    if (jong > 0 && jung >= 0 && cho >= 0 && lastCommittedLen > 0
        && cho == inCho && jung == inJung) {
        const int rem = remainingJongAfterMove(jong);
        if (inJong == rem) {
            const ushort prevJungCompat = ushort(0x314F + jung);
            const bool diffJung = (keyChar != prevJungCompat);
            const bool diffJong = (rem != 0);
            if (diffJung || diffJong) {
                const int prevIdx = (cho * 21 + jung) * 28 + rem;
                const QChar prev(ushort(0xAC00 + prevIdx));
                QInputMethodEvent ev;
                ev.setCommitString(QString(prev), -lastCommittedLen, lastCommittedLen);
                QCoreApplication::sendEvent(focusObject, &ev);
                jong = rem;
                lastCommittedLen = 0;
                return;
            }
        }
    }

    // 받침 이동 syllable transition (single-dispatch): state cho+jung+jong
    // (받침) 인데 사용자가 모음 키를 누른 결과로 Apple 이 movedCho(state.jong)
    // 를 새 syllable 의 cho 로 한 syllable 을 dispatch (각+ㅏ → 가+가:
    // setMarkedText "가" 한 번으로 prev-split 과 new 가 동일).
    // keyChar 가 새 syllable jung 의 호환 모음 자체일 때만 fire — 그렇지
    // 않으면 같은 syllable 의 jong 변경 (예: 곽 → 과 finalize) 와 구분 안 됨.
    if (jong > 0 && jung >= 0 && cho >= 0 && lastCommittedLen > 0) {
        const int movedCho = movedChoFromJong(jong);
        const ushort jungCompat = ushort(0x314F + inJung);
        const bool keyIsNewJung = (keyChar == jungCompat);
        if (movedCho >= 0 && movedCho == inCho && keyIsNewJung) {
            const int rem = remainingJongAfterMove(jong);
            const int prevIdx = (cho * 21 + jung) * 28 + rem;
            const QChar prev(ushort(0xAC00 + prevIdx));
            QString combined;
            combined.append(prev);
            combined.append(ch);
            QInputMethodEvent ev;
            ev.setCommitString(combined, -lastCommittedLen, lastCommittedLen);
            QCoreApplication::sendEvent(focusObject, &ev);
            lastCommittedLen = 1;
            cho = inCho;
            jung = inJung;
            jong = inJong;
            return;
        }
    }

    // cho mismatch: rewind prev emit, strip jong
    if (cho >= 0 && cho != inCho && lastCommittedLen > 0) {
        QInputMethodEvent ev;
        if (jong > 0 && jung >= 0) {
            const int fixedIdx = (cho * 21 + jung) * 28 + 0;
            const QChar fixed(ushort(0xAC00 + fixedIdx));
            QString combined;
            combined.append(fixed);
            combined.append(ch);
            ev.setCommitString(combined, -lastCommittedLen, lastCommittedLen);
        } else {
            ev.setCommitString(QString(ch), 0, 0);
        }
        QCoreApplication::sendEvent(focusObject, &ev);
        lastCommittedLen = 1;
    } else {
        QInputMethodEvent ev;
        ev.setCommitString(QString(ch), -lastCommittedLen, lastCommittedLen);
        QCoreApplication::sendEvent(focusObject, &ev);
        lastCommittedLen = 1;
    }

    cho = inCho;
    jung = inJung;
    jong = inJong;
}

// libhangul / standard 한국어 IME 분해 정책 backspace.
// Returns true if the event was handled.
bool HangulComposer::handleBackspace(QNSView *view)
{
    if (jong > 0) {
        // 복합 받침 → 단일 받침 (or 단일 받침 → 없음)
        static const struct { int from; int to; } split[] = {
            {3,1}, {5,4}, {6,4}, {9,8}, {10,8}, {11,8},
            {12,8}, {13,8}, {14,8}, {15,8}, {18,17}
        };
        int newJong = 0;
        for (auto &e : split) {
            if (e.from == jong) { newJong = e.to; break; }
        }
        jong = newJong;
        emitCurrent(view);
        return true;
    }
    if (cho >= 0 && jung >= 0) {
        // 복합 모음 → base, or jung 통째로 제거
        static const struct { int from; int to; } split[] = {
            {9,8}, {10,8}, {11,8}, {14,13}, {15,13}, {16,13}, {19,18}
        };
        int newJung = -1;
        for (auto &e : split) {
            if (e.from == jung) { newJung = e.to; break; }
        }
        jung = newJung;
        emitCurrent(view);
        return true;
    }
    if (cho >= 0 || jung >= 0) {
        cho = -1;
        jung = -1;
        emitCurrent(view);
        return true;
    }
    return false;
}


// ============================================================================
// hookKeyDown — called from qnsview_keys.mm at the top of -handleKeyEvent:.
// ============================================================================
//
// Backspace 는 항상 우리가 consume — composer state 가 없을 때라도. Apple IME
// 가 자체 버퍼로 decomposition dispatch (setMarkedText syllable 또는 compat
// jamo) 를 보내면 우리가 commit-only emit 으로 이미 지운 글자가 다시 살아나는
// race ('가나다🔙🔙🔙🔙ㄴ → 단') 가 발생.
//
// Returns true if the event was fully handled (stock path skip).
bool hangulComposerHookKeyDown(QNSView *view, NSEvent *nsevent)
{
    if (nsevent.type != NSEventTypeKeyDown)
        return false;

    NSString *chars = nsevent.characters;
    if (chars.length == 0)
        return false;
    const unichar c = [chars characterAtIndex:0];

    composer.enterRound(c);

    // 한영 직후 첫 keyDown — parallel predispatch + dup window.
    // IMK 가 가끔 첫 keyDown 을 삼키므로 우리가 직접 dispatch (stock path 도
    // 그대로 진행). insertText/setMarkedText 의 post-flag dup 검사가 IMK 의
    // 중복 dispatch 를 잡아 한 글자만 emit.
    if (flagsChangedPending) {
        flagsChangedPending = false;
        const bool isControl = (c < 0x20) || (c == 0x7F)
                            || (c >= 0xF700 && c <= 0xF8FF);
        const bool hasModifier = (nsevent.modifierFlags
            & (NSEventModifierFlagCommand | NSEventModifierFlagControl
               | NSEventModifierFlagOption)) != 0;
        if (!isControl && !hasModifier) {
            postFlagChar = c;
            postFlagTimestamp = [[NSDate date] timeIntervalSince1970];
            // 한영 직후 새 글자 — state 비우고 fresh 시작. State 유지 시
            // 가{한영}가 → 각가 처럼 새 cho 가 직전 syllable 받침으로 흡수됨.
            composer.reset();
            if (c >= 0x3131 && c <= 0x3163) {
                composer.feedCompatJamo(view, c);
            } else if (c >= 0xAC00 && c <= 0xD7A3) {
                composer.feedSyllable(view, [chars characterAtIndex:0]);
            } else {
                QObject *focusObject = view.focusObject;
                if (focusObject && queryInputMethod(focusObject)) {
                    QInputMethodEvent ev;
                    ev.setCommitString(QString::fromNSString(chars), 0, 0);
                    QCoreApplication::sendEvent(focusObject, &ev);
                }
            }
            // Fall through (return false) so stock path also runs.
        }
    }

    // space / tab / enter — Apple IME treats as commit-and-insert. Drop our
    // cycle + Apple's marked buffer to avoid syllable finalize duplicates
    // ('초격차차 기술술' regression sample).
    if (c == ' ' || c == '\t' || c == '\r' || c == '\n') {
        if (composer.hasState())
            composer.reset();
        [view.inputContext discardMarkedText];
        return false;
    }

    // backspace (0x08 BS or 0x7F DEL) — selection-aware delete or composer
    // step-decompose. Always wipe Apple's marked buffer so it cannot replay
    // a stale syllable on the next keystroke.
    if (c == 0x08 || c == 0x7F) {
        QObject *focusObject = view.focusObject;
        int anchor = -1, cursor = -1;
        if (focusObject) {
            if (auto qr = queryInputMethod(focusObject,
                    Qt::ImAnchorPosition | Qt::ImCursorPosition)) {
                anchor = qr.value(Qt::ImAnchorPosition).toInt();
                cursor = qr.value(Qt::ImCursorPosition).toInt();
            }
        }
        const bool hasSelection = (anchor >= 0 && cursor >= 0 && anchor != cursor);

        if (hasSelection) {
            composer.reset();
            if (focusObject && queryInputMethod(focusObject)) {
                const int selStart = std::min(anchor, cursor);
                const int selEnd   = std::max(anchor, cursor);
                QInputMethodEvent ev;
                ev.setCommitString(QString(), selStart - cursor, selEnd - selStart);
                QCoreApplication::sendEvent(focusObject, &ev);
            }
        } else if (composer.hasState()) {
            composer.handleBackspace(view);
        } else {
            if (focusObject && queryInputMethod(focusObject)) {
                QInputMethodEvent ev;
                ev.setCommitString(QString(), -1, 1);
                QCoreApplication::sendEvent(focusObject, &ev);
            }
        }
        [view.inputContext discardMarkedText];
        return true;
    }
    return false;
}

@implementation QNSView (ComplexText)

// ------------- Text insertion -------------

- (QObject*)focusObject
{
    // The text input system may still hold a reference to our QNSView,
    // even after QCocoaWindow has been destructed, delivering text input
    // events to us, so we need to guard for this situation explicitly.
    if (!m_platformWindow)
        return nullptr;

    return m_platformWindow->window()->focusObject();
}

/*
    Inserts the given text, potentially replacing existing text.

    The text input management system calls this as a result of:

     - A normal key press, via [NSView interpretKeyEvents:] or
       [NSInputContext handleEvent:]

     - An input method finishing (confirming) composition

     - Pressing a key in the Keyboard Viewer panel

     - Confirming an inline input area (accent popup e.g.)

    \a replacementRange refers to the existing text to replace.
    Under normal circumstances this is {NSNotFound, 0}, and the
    implementation should replace either the existing marked text,
    the current selection, or just insert the text at the current
    cursor location.
*/

- (void)insertText:(id)text replacementRange:(NSRange)replacementRange
{
    qCDebug(lcQpaKeys).nospace() << "Inserting \"" << text << "\""
        << ", replacing range " << replacementRange;

    NSString *string = [self stringForText:text];

    // post-flag dup suppression: if IMK ends up dispatching the same char
    // we already predispatched, drop the duplicate. Also clear m_sendKeyEvent
    // so the raw keyDown is not delivered to Qt either.
    if (postFlagChar != 0 && string.length == 1) {
        unichar in = [string characterAtIndex:0];
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        if (in == postFlagChar && (now - postFlagTimestamp) < postFlagWindowSec) {
            postFlagChar = 0;
            m_sendKeyEvent = false;
            return;
        }
        postFlagChar = 0;
    }

    {
        QString s = QString::fromNSString(string);
        if (isHangulCompatJamoSingle(s)) {
            // insertText 도 compat jamo 면 FSM 으로 직접 라우팅.
            // dup / wrap-up 판단은 feedCompatJamo 안에서 통합 처리 —
            // 별도 jungPaired / choOnlyPaired 가드 불필요.
            composer.feedCompatJamo(self, s.at(0).unicode());
            return;
        }
        if (isHangulSyllableSingle(s)) {
            // insertText syllable 도 feedSyllable 로 라우팅 — preedit-match
            // 가드가 cold paired commit (state==preedit) / 받침이동 후속
            // paired+dup / warm dup 을 전부 DROP-preserve.
            // 과거 reset() 처리는 받침이동 직후 paired insertText 가 state
            // 를 날려서 후속 setMarkedText 가 가 새 syllable 로 누적되는
            // 회귀 발생 (가가가 → 가가가가).
            composer.feedSyllable(self, s.at(0));
            return;
        }
        if (composer.hasState())
            composer.reset();
    }

    if (m_composingText.isEmpty()) {
        // The input method may have transformed the incoming key event
        // to text that doesn't match what the original key event would
        // have produced, for example when 'Pinyin - Simplified' does smart
        // replacement of quotes. If that's the case we can't rely on
        // handleKeyEvent for sending the text.
        auto *currentEvent = NSApp.currentEvent;
        NSString *eventText = currentEvent.type == NSEventTypeKeyDown
                           || currentEvent.type == NSEventTypeKeyUp
                                ? currentEvent.characters : nil;

        if ([string isEqualToString:eventText]) {
            // We do not send input method events for simple text input,
            // and instead let handleKeyEvent send the key event.
            qCDebug(lcQpaKeys) << "Ignoring text insertion for simple text";
            m_sendKeyEvent = true;
            return;
        }
    }

    if (queryInputMethod(self.focusObject)) {
        QInputMethodEvent inputMethodEvent;

        QString commitString = QString::fromNSString(string);

        // Ensure we have a valid replacement range
        replacementRange = [self sanitizeReplacementRange:replacementRange];

        // Qt's QInputMethodEvent has different semantics for the replacement
        // range than AppKit does, so we need to sanitize the range first.
        auto [replaceFrom, replaceLength] = [self inputMethodRangeForRange:replacementRange];

        if (replaceFrom == NSNotFound) {
            qCWarning(lcQpaKeys) << "Failed to compute valid replacement range for text insertion";
            inputMethodEvent.setCommitString(commitString);
        } else {
            qCDebug(lcQpaKeys) << "Replacing from" << replaceFrom << "with length" << replaceLength
                << "based on replacement range" << replacementRange;
            inputMethodEvent.setCommitString(commitString, replaceFrom, replaceLength);
        }

        QCoreApplication::sendEvent(self.focusObject, &inputMethodEvent);
    }

    m_composingText.clear();
    m_composingFocusObject = nullptr;
}

- (void)insertNewline:(id)sender
{
    Q_UNUSED(sender);

    if (!m_platformWindow)
        return;

    // Depending on the input method, pressing enter may
    // result in simply dismissing the input method editor,
    // without confirming the composition. In other cases
    // it may confirm the composition as well. And in some
    // cases the IME will produce an explicit new line, which
    // brings us here.

    // Semantically, the input method has asked us to insert
    // a newline, and we should do so via an QInputMethodEvent,
    // either directly or via [self insertText:@"\r"]. This is
    // also how NSTextView handles the command. But, if we did,
    // we would bypass all the code in Qt (and clients) that
    // assume that pressing the return key results in a key
    // event, for example the QLineEdit::returnPressed logic.
    // To ensure that clients will still see the Qt::Key_Return
    // key event, we send it as a normal key event.

    // But, we can not fall back to handleKeyEvent for this,
    // as the original key event may have text that reflects
    // the combination of the inserted text and the newline,
    // e.g. "~\r". We have already inserted the composition,
    // so we need to follow up with a single newline event.

    KeyEvent newlineEvent(m_currentlyInterpretedKeyEvent ?
        m_currentlyInterpretedKeyEvent : NSApp.currentEvent);
    newlineEvent.type = QEvent::KeyPress;

    const bool isEnter = newlineEvent.modifiers & Qt::KeypadModifier;
    newlineEvent.key = isEnter ? Qt::Key_Enter : Qt::Key_Return;
    newlineEvent.text = isEnter ? QLatin1Char(kEnterCharCode)
                                : QLatin1Char(kReturnCharCode);
    newlineEvent.nativeVirtualKey = isEnter ? quint32(kVK_ANSI_KeypadEnter)
                                            : quint32(kVK_Return);

    qCDebug(lcQpaKeys) << "Inserting newline via" << newlineEvent;
    newlineEvent.sendWindowSystemEvent(m_platformWindow->window());
}

// ------------- Text composition -------------

/*
    Updates the composed text, potentially replacing existing text.

    The NSTextInputClient protocol refers to composed text as "marked",
    since it is "marked differently from the selection, using temporary
    attributes that affect only display, not layout or storage.""

    The concept maps to the preeditString of our QInputMethodEvent.

    \a selectedRange refers to the part of the marked text that
    is considered selected, for example when composing text with
    multiple clause segments (Hiragana - Kana e.g.).

    \a replacementRange refers to the existing text to replace.
    Under normal circumstances this is {NSNotFound, 0}, and the
    implementation should replace either the existing marked text,
    the current selection, or just insert the text at the current
    cursor location. But when initiating composition of existing
    committed text (Hiragana - Kana e.g.), the range will be valid.
*/
- (void)setMarkedText:(id)text selectedRange:(NSRange)selectedRange replacementRange:(NSRange)replacementRange
{
    qCDebug(lcQpaKeys).nospace() << "Marking \"" << text << "\""
        << " with selected range " << selectedRange
        << ", replacing range " << replacementRange;

    const bool isAttributedString = [text isKindOfClass:NSAttributedString.class];
    QString preeditString = QString::fromNSString([self stringForText:text]);

    // post-flag dup suppression
    if (postFlagChar != 0 && preeditString.length() == 1) {
        unichar in = preeditString.at(0).unicode();
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        if (in == postFlagChar && (now - postFlagTimestamp) < postFlagWindowSec) {
            postFlagChar = 0;
            m_sendKeyEvent = false;
            return;
        }
        postFlagChar = 0;
    }

    if (isHangulCompatJamoSingle(preeditString)) {
        composer.feedCompatJamo(self, preeditString.at(0).unicode());
        return;
    }
    if (isHangulSyllableSingle(preeditString)) {
        composer.feedSyllable(self, preeditString.at(0));
        return;
    }
    if (composer.hasState())
        composer.reset();

    QList<QInputMethodEvent::Attribute> preeditAttributes;

    // The QInputMethodEvent::Cursor specifies that the length
    // determines whether the cursor is visible or not, but uses
    // logic opposite of that of native AppKit application, where
    // the cursor is visible if there's no selection, and hidden
    // if there's a selection. Instead of passing on the length
    // directly we need to inverse the logic.
    const bool showCursor = !selectedRange.length;
    preeditAttributes << QInputMethodEvent::Attribute(
        QInputMethodEvent::Cursor, selectedRange.location, showCursor);

    // QInputMethodEvent::Selection unfortunately doesn't apply to the
    // preedit text, and QInputMethodEvent::Cursor which does, doesn't
    // support setting a selection. Until we've introduced attributes
    // that allow us to propagate the preedit selection semantically
    // we resort to styling the selection via the TextFormat attribute,
    // so that the preedit selection is visible to the user.
    QTextCharFormat selectionFormat;
    auto *platformTheme = QGuiApplicationPrivate::platformTheme();
    auto *systemPalette = platformTheme->palette();
    selectionFormat.setBackground(systemPalette->color(QPalette::Highlight));
    preeditAttributes << QInputMethodEvent::Attribute(
        QInputMethodEvent::TextFormat,
        selectedRange.location, selectedRange.length,
        selectionFormat);

    int index = 0;
    int composingLength = preeditString.length();
    while (index < composingLength) {
        NSRange range = NSMakeRange(index, composingLength - index);

        static NSDictionary *defaultMarkedTextAttributes = []{
            NSTextView *textView = [[NSTextView new] autorelease];
            return [textView.markedTextAttributes retain];
        }();

        NSDictionary *attributes = isAttributedString
            ? [text attributesAtIndex:index longestEffectiveRange:&range inRange:range]
            : defaultMarkedTextAttributes;

        qCDebug(lcQpaKeys) << "Decorating range" << range << "based on" << attributes;
        QTextCharFormat format;

        if (NSNumber *underlineStyle = attributes[NSUnderlineStyleAttributeName]) {
            format.setFontUnderline(true);
            NSUnderlineStyle style = underlineStyle.integerValue;
            if (style & NSUnderlineStylePatternDot)
                format.setUnderlineStyle(QTextCharFormat::DotLine);
            else if (style & NSUnderlineStylePatternDash)
                format.setUnderlineStyle(QTextCharFormat::DashUnderline);
            else if (style & NSUnderlineStylePatternDashDot)
                format.setUnderlineStyle(QTextCharFormat::DashDotLine);
            if (style & NSUnderlineStylePatternDashDotDot)
                format.setUnderlineStyle(QTextCharFormat::DashDotDotLine);
            else
                format.setUnderlineStyle(QTextCharFormat::SingleUnderline);

            // Unfortunately QTextCharFormat::UnderlineStyle does not distinguish
            // between NSUnderlineStyle{Single,Thick,Double}, which is used by CJK
            // input methods to highlight the selected clause segments.
        }
        if (NSColor *underlineColor = attributes[NSUnderlineColorAttributeName])
            format.setUnderlineColor(qt_mac_toQColor(underlineColor));
        if (NSColor *foregroundColor = attributes[NSForegroundColorAttributeName])
            format.setForeground(qt_mac_toQColor(foregroundColor));
        if (NSColor *backgroundColor = attributes[NSBackgroundColorAttributeName])
            format.setBackground(qt_mac_toQColor(backgroundColor));

        if (format != QTextCharFormat()) {
            preeditAttributes << QInputMethodEvent::Attribute(
                QInputMethodEvent::TextFormat, range.location, range.length, format);
        }

        index = range.location + range.length;
    }

    // Ensure we have a valid replacement range
    replacementRange = [self sanitizeReplacementRange:replacementRange];

    // Qt's QInputMethodEvent has different semantics for the replacement
    // range than AppKit does, so we need to sanitize the range first.
    auto [replaceFrom, replaceLength] = [self inputMethodRangeForRange:replacementRange];

    // Update the composition, now that we've computed the replacement range
    m_composingText = preeditString;

    if (QObject *focusObject = self.focusObject) {
        m_composingFocusObject = focusObject;
        if (queryInputMethod(focusObject)) {
            QInputMethodEvent event(preeditString, preeditAttributes);
            if (replaceLength > 0) {
                // The input method may extend the preedit into already
                // committed text. If so, we need to replace existing text
                // by committing an empty string.
                qCDebug(lcQpaKeys) << "Replacing from" << replaceFrom << "with length"
                    << replaceLength << "based on replacement range" << replacementRange;
                event.setCommitString(QString(), replaceFrom, replaceLength);
            }
            QCoreApplication::sendEvent(focusObject, &event);
        }
    }
}

- (NSArray<NSString *> *)validAttributesForMarkedText
{
    return @[
        NSUnderlineColorAttributeName,
        NSUnderlineStyleAttributeName,
        NSForegroundColorAttributeName,
        NSBackgroundColorAttributeName
    ];
}

- (BOOL)hasMarkedText
{
    return !m_composingText.isEmpty();
}

/*
    Returns the range of marked text or {cursorPosition, 0} if there's none.

    This maps to the location and length of the current preedit (composited) string.

    The returned range measures from the start of the receiver’s text storage,
    that is, from 0 to the document length.
*/
- (NSRange)markedRange
{
    if (auto queryResult = queryInputMethod(self.focusObject, Qt::ImAbsolutePosition)) {
        int absoluteCursorPosition = queryResult.value(Qt::ImAbsolutePosition).toInt();

        // The cursor position as reflected by Qt::ImAbsolutePosition is not
        // affected by the offset of the cursor in the preedit area. That means
        // that when composing text, the cursor position stays the same, at the
        // preedit insertion point, regardless of where the cursor is positioned within
        // the preedit string by the QInputMethodEvent::Cursor attribute. This means
        // we can use the cursor position to determine the range of the marked text.

        // The NSTextInputClient documentation says {NSNotFound, 0} should be returned if there
        // is no marked text, but in practice NSTextView seems to report {cursorPosition, 0},
        // so we do the same.
        return NSMakeRange(absoluteCursorPosition, m_composingText.length());
    } else {
        return {NSNotFound, 0};
    }
}

/*
    Confirms the marked (composed) text.

    The marked text is accepted as if it had been inserted normally,
    and the preedit string is cleared.

    If there is no marked text this method has no effect.
*/
- (void)unmarkText
{
    // End the Hangul composer cycle on explicit unmark.
    composer.reset();

    // FIXME: Match cancelComposingText in early exit and focus object handling

    qCDebug(lcQpaKeys) << "Unmarking" << m_composingText
        << "for focus object" << m_composingFocusObject;

    if (!m_composingText.isEmpty()) {
        QObject *focusObject = self.focusObject;
        if (queryInputMethod(focusObject)) {
            QInputMethodEvent e;
            e.setCommitString(m_composingText);
            QCoreApplication::sendEvent(focusObject, &e);
        }
    }

    m_composingText.clear();
    m_composingFocusObject = nullptr;
}

/*
    Cancels composition.

    The marked text is discarded, and the preedit string is cleared.

    If there is no marked text this method has no effect.
*/
- (void)cancelComposingText
{
    // End the Hangul composer cycle on explicit cancel.
    composer.reset();

    if (m_composingText.isEmpty())
        return;

    qCDebug(lcQpaKeys) << "Canceling composition" << m_composingText
        << "for focus object" << m_composingFocusObject;

    if (queryInputMethod(m_composingFocusObject)) {
        QInputMethodEvent e;
        QCoreApplication::sendEvent(m_composingFocusObject, &e);
    }

    m_composingText.clear();
    m_composingFocusObject = nullptr;
}

// ------------- Key binding command handling -------------

- (void)doCommandBySelector:(SEL)selector
{
    if (composer.hasState())
        composer.reset();

    // Note: if the selector cannot be invoked, then doCommandBySelector:
    // should not pass this message up the responder chain (nor should it
    // call super, as the NSResponder base class would in that case pass
    // the message up the responder chain, which we don't want). We will
    // pass the originating key event up the responder chain if applicable.

    qCDebug(lcQpaKeys) << "Trying to perform command" << selector;
    if (![self tryToPerform:selector with:self]) {
        m_sendKeyEvent = true;

        if (![NSStringFromSelector(selector) hasPrefix:@"insert"]) {
            // The text input system determined that the key event was not
            // meant for text insertion, and instead asked us to treat it
            // as a (possibly noop) command. This typically happens for key
            // events with either ⌘ or ⌃, function keys such as F1-F35,
            // arrow keys, etc. We reflect that when sending the key event
            // later on, by removing the text from the event, so that the
            // event does not result in text insertion on the client side.
            m_sendKeyEventWithoutText = true;
        }
    }
}

// ------------- Various text properties -------------

/*
    Returns the range of selected text, or {cursorPosition, 0} if there's none.

    The returned range measures from the start of the receiver’s text storage,
    that is, from 0 to the document length.
*/
- (NSRange)selectedRange
{
    if (auto queryResult = queryInputMethod(self.focusObject,
            Qt::ImCursorPosition | Qt::ImAbsolutePosition | Qt::ImAnchorPosition)) {

        // Unfortunately the Qt::InputMethodQuery values are all relative
        // to the start of the current editing block (paragraph), but we
        // need them in absolute values relative to the entire text.
        // Luckily we have one property, Qt::ImAbsolutePosition, that
        // we can use to compute the offset.
        int cursorPosition = queryResult.value(Qt::ImCursorPosition).toInt();
        int absoluteCursorPosition = queryResult.value(Qt::ImAbsolutePosition).toInt();
        int absoluteOffset = absoluteCursorPosition - cursorPosition;

        int anchorPosition = absoluteOffset + queryResult.value(Qt::ImAnchorPosition).toInt();
        int selectionStart = anchorPosition >= absoluteCursorPosition ? absoluteCursorPosition : anchorPosition;
        int selectionEnd = selectionStart == anchorPosition ? absoluteCursorPosition : anchorPosition;
        int selectionLength = selectionEnd - selectionStart;

        // Note: The cursor position as reflected by these properties are not
        // affected by the offset of the cursor in the preedit area. That means
        // that when composing text, the cursor position stays the same, at the
        // preedit insertion point, regardless of where the cursor is positioned within
        // the preedit string by the QInputMethodEvent::Cursor attribute.

        // The NSTextInputClient documentation says {NSNotFound, 0} should be returned if there is no
        // selection, but in practice NSTextView seems to report {cursorPosition, 0}, so we do the same.
        return NSMakeRange(selectionStart, selectionLength);
    } else {
        return {NSNotFound, 0};
    }
}

/*
    Returns an attributed string derived from the given range
    in the underlying focus object's text storage.

    Input methods may call this with a proposed range that is
    out of bounds. For example, the InkWell text input service
    may ask for the contents of the text input client that extends
    beyond the document's range. To remedy this we always compute
    the intersection between the proposed range and the available
    text.

    If the intersection is completely outside of the available text
    this method returns nil.
*/
- (NSAttributedString *)attributedSubstringForProposedRange:(NSRange)range actualRange:(NSRangePointer)actualRange
{
    if (auto queryResult = queryInputMethod(self.focusObject,
            Qt::ImAbsolutePosition | Qt::ImTextBeforeCursor | Qt::ImTextAfterCursor)) {
        const int absoluteCursorPosition = queryResult.value(Qt::ImAbsolutePosition).toInt();
        const QString textBeforeCursor = queryResult.value(Qt::ImTextBeforeCursor).toString();
        const QString textAfterCursor = queryResult.value(Qt::ImTextAfterCursor).toString();

        // The documentation doesn't say whether the marked text should be included
        // in the available text, but observing NSTextView shows that this is the
        // case, so we follow suit.
        const QString availableText = textBeforeCursor + m_composingText + textAfterCursor;
        const NSRange availableRange = NSMakeRange(absoluteCursorPosition - textBeforeCursor.length(),
                                  availableText.length());

        const NSRange intersectedRange = NSIntersectionRange(range, availableRange);
        if (actualRange)
            *actualRange = intersectedRange;

        if (!intersectedRange.length)
            return nil;

        NSString *substring = QStringView(availableText).mid(
            intersectedRange.location - availableRange.location,
            intersectedRange.length).toNSString();

        return [[[NSAttributedString alloc] initWithString:substring] autorelease];

    } else {
        return nil;
    }
}

/*
    Returns the first logical boundary rectangle for characters in the given range,
    in screen coordinates.

    The "first" in the name refers to the rectangle enclosing the first line when
    the range encompasses multiple lines of text. In that case, actualRange should
    be set to the range covered by the first rect, so all line fragments can
    be queried by invoking this method repeatedly.

    If the length of range is 0 (as it would be if there is nothing selected at
    the insertion point), then the rectangle coincides with the insertion point.
*/
- (NSRect)firstRectForCharacterRange:(NSRange)range actualRange:(NSRangePointer)actualRange
{
    Q_UNUSED(range);
    Q_UNUSED(actualRange);

    QWindow *window = m_platformWindow ? m_platformWindow->window() : nullptr;
    if (window && queryInputMethod(window->focusObject())) {
        if (range.length) // FIXME: Handle the case when range is non-zero
            qCWarning(lcQpaKeys) << "Can't satisfy firstRectForCharacterRange for" << range;
        QRect cursorRect = qApp->inputMethod()->cursorRectangle().toRect();
        cursorRect.moveBottomLeft(window->mapToGlobal(cursorRect.bottomLeft()));
        return QCocoaScreen::mapToNative(cursorRect);
    } else {
        return NSZeroRect;
    }
}

- (NSUInteger)characterIndexForPoint:(NSPoint)point
{
    // We don't support cursor movements using mouse while composing.
    Q_UNUSED(point);
    return NSNotFound;
}

/*
    Returns the window level of the text input.

    This allows the input method to place its input panel
    above the text input.
*/
- (NSInteger)windowLevel
{
    // The default level assumed by input methods is NSFloatingWindowLevel,
    // but our NSWindow level could be higher than that for many reasons,
    // including being set via QWindow::setFlags() or directly on the
    // NSWindow, or because we're embedded into a native view hierarchy.
    // Return the actual window level to account for this.
    auto level = m_platformWindow ? m_platformWindow->nativeWindow().level
                                  : NSNormalWindowLevel;

    // The logic above only covers our own window though. In some cases,
    // such as when a completer is active, the text input has a lower
    // window level than another window that's also visible, and we don't
    // want the input panel to be sandwiched between these two windows.
    // Account for this by explicitly using NSPopUpMenuWindowLevel as
    // the minimum window level, which corresponds to the highest level
    // one can get via QWindow::setFlags(), except for Qt::ToolTip.
    return qMax(level, NSPopUpMenuWindowLevel);
}

// ------------- Helper functions -------------

/*
    Sanitizes the replacement range, ensuring it's valid.

    If \a range is not valid the range of the current
    marked text will be used.

    If there's no marked text the range of the current
    selection will be used.

    If there's no selection the range will be {cursorPosition, 0}.
*/
- (NSRange)sanitizeReplacementRange:(NSRange)range
{
    if (range.location != NSNotFound)
        return range; // Use as is

    // If the replacement range is not specified we are expected to compute
    // the range ourselves, based on the current state of the input context.

    const auto markedRange = [self markedRange];
    const auto selectedRange = [self selectedRange];

    if (markedRange.length)
        return markedRange;
    else if (selectedRange.length)
        return selectedRange;
    else
        return markedRange; // Represents cursor position when length is 0

}

/*
    Computes the QInputMethodEvent commit string range,
    based on the NSTextInputClient replacement range.

    The two APIs have different semantics.
*/
- (std::pair<long long, long long>)inputMethodRangeForRange:(NSRange)replacementRange
{
    long long replaceFrom = replacementRange.location;
    long long replaceLength = replacementRange.length;

    const auto markedRange = [self markedRange];
    const auto selectedRange = [self selectedRange];

    if (markedRange.length && selectedRange.length) {
        // We assume below that we have either marked text or selected text
        qCWarning(lcQpaKeys) << "Got both markedRange" << markedRange
                             << "and selectedRange" << selectedRange;
    }

    if (markedRange.length) {
        // The replacement length of QInputMethodEvent already includes
        // the preedit string, as the documentation says that "When doing
        // replacement, the area of the preedit string is ignored".
        replaceLength -= markedRange.length;

        // The QInputMethodEvent replacement start is relative to the start
        // of the marked text (the location of the preedit string).
        replaceFrom -= markedRange.location;
    } else if (selectedRange.length) {
        if (!NSEqualRanges(NSIntersectionRange(replacementRange, selectedRange), selectedRange)) {
            qCWarning(lcQpaKeys) << "Replacement range" << replacementRange
                                 << "is a subset of selection" << selectedRange;
            // FIXME: To support this case we would need to extract parts of the
            // selection into the committed text. But for now we ignore it, as we
            // don't know if it happens in practice.
        }

        // Our input method protocol specifies that the entire selection
        // should be removed as the first step, and the replacement length
        // of the QInputMethodEvent refers to any additional text that should
        // be removed/replaced.
        replaceLength -= selectedRange.length;

        // Once the selection has been removed the cursor position will be
        // at the leftmost point of the selection, regardless of whether the
        // cursor was at the start or end of the selection. The replacement
        // start of QInputMethodEvent should be relative to this position.
        replaceFrom -= selectedRange.location;
    } else if (markedRange.location != NSNotFound) {
        // The QInputMethodEvent replacement start is relative to the cursor
        // position.
        replaceFrom -= markedRange.location;
    } else{
        replaceFrom = 0;
    }

    // What we're left with is any _additional_ replacement.
    // Make sure it's valid before passing it on.
    replaceLength = qMax(0ll, replaceLength);

    return {replaceFrom, replaceLength};
}

- (NSString*)stringForText:(id)text
{
    return [text isKindOfClass:NSAttributedString.class] ? [text string] : text;
}

@end

@implementation QNSView (ServicesMenu)

// Support for reading and writing from service menu pasteboards, which is also
// how the writing tools interact with custom NSView. Note that we only support
// plain text, which means that a rich text selection will lose all its styling
// when fed through a service that changes the text. To support rich text we
// need IM plumbing that operates on QMimeData.

- (id)validRequestorForSendType:(NSPasteboardType)sendType returnType:(NSPasteboardType)returnType
{
    bool canWriteToPasteboard = [&]{
        if (![sendType isEqualToString:NSPasteboardTypeString])
            return false;
        if (auto queryResult = queryInputMethod(self.focusObject, Qt::ImCurrentSelection)) {
            auto selectedText = queryResult.value(Qt::ImCurrentSelection).toString();
            if (!selectedText.isEmpty())
                return true;
        }
        return false;
    }();

    bool canReadFromPastboard = [returnType isEqualToString:NSPasteboardTypeString];

    if ((sendType && !canWriteToPasteboard) || (returnType && !canReadFromPastboard)) {
        return [super validRequestorForSendType:sendType returnType:returnType];
    } else {
        qCDebug(lcQpaServices) << "Accepting service interaction for send" << sendType << "and receive" << returnType;
        return self;
    }
}

- (BOOL)writeSelectionToPasteboard:(NSPasteboard *)pasteboard types:(NSArray<NSPasteboardType> *)types
{
    if ([types containsObject:NSPasteboardTypeString]
        // Check for the deprecated NSStringPboardType as well, as even if we
        // claim to only support NSPasteboardTypeString, we get callbacks for
        // the deprecated type.
        || QT_IGNORE_DEPRECATIONS([types containsObject:NSStringPboardType])) {
        if (auto queryResult = queryInputMethod(self.focusObject, Qt::ImCurrentSelection)) {
            auto selectedText = queryResult.value(Qt::ImCurrentSelection).toString();
            qCDebug(lcQpaServices) << "Writing" << selectedText << "to service pasteboard" << pasteboard.name;
            return [pasteboard writeObjects:@[ selectedText.toNSString() ]];
        }
    }
    return NO;
}

- (BOOL)readSelectionFromPasteboard:(NSPasteboard *)pasteboard
{
    NSString *insertedString = [pasteboard stringForType:NSPasteboardTypeString];
    if (!insertedString)
        return NO;

    qCDebug(lcQpaServices) << "Reading" << insertedString << "from service pasteboard" << pasteboard.name;
    [self insertText:insertedString replacementRange:{NSNotFound, 0}];
    return YES;
}

@end

#if QT_MACOS_PLATFORM_SDK_EQUAL_OR_ABOVE(150000)
@implementation QNSView (ContentSelectionInfo)

/*
    This method is used by AppKit for positioning of context menus in
    response to the context menu keyboard hotkey, and for placement of
    the Writing Tools popup.
*/
- (NSRect)selectionAnchorRect
{
    if (queryInputMethod(self.focusObject)) {
        // We don't have a way of querying the selection rectangle via
        // the input method protocol (yet), so we use crude heuristics.
        const auto *inputMethod = qApp->inputMethod();
        auto cursorRect = inputMethod->cursorRectangle();
        auto anchorRect = inputMethod->anchorRectangle();
        auto selectionRect = cursorRect.united(anchorRect);
        if (cursorRect.top() != anchorRect.top()) {
            // Multi line selection. Assume the selections extends to
            // the entire width of the input item. This does not account
            // for center-aligned text and a bunch of other cases. FIXME
            auto itemClipRect = inputMethod->inputItemClipRectangle();
            selectionRect.setLeft(itemClipRect.left());
            selectionRect.setRight(itemClipRect.right());
        }
        return selectionRect.toCGRect();
    } else {
        return NSZeroRect;
    }
}
@end
#endif // macOS 15 SDK

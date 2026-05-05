# Ribbind

🌐 [English](./README.md) · **한국어**

**macOS에서 Microsoft Word / Microsoft PowerPoint / Google Chrome의 모든 명령에 키보드 단축키를 바인딩하세요** — Format Painter 브러시, 도형 갤러리, Crop, Font Color 같은 **macOS 기본 키보드 커스터마이저로는 닿을 수 없는 Ribbon-전용 명령**까지. 거기에 Chrome 내장 **페이지 번역**도 한 키 토글로 사용 가능.

> ☕ **앱은 무료**입니다. 도와주실 분이 있으면 환영해요 — 대학원생입니다.
>
> [![Support on Ko-fi](https://img.shields.io/badge/Support%20on-Ko--fi-ff5e5b?logo=ko-fi&logoColor=white&style=for-the-badge)](https://ko-fi.com/minguk2)

---

## 설치

터미널에서 빌드합니다. 아래 블록을 그대로 복사해 붙여넣으세요. 개발 경험은 필요 없습니다.

**1. 터미널 열기.** `⌘ + Space` → **Terminal** 입력 → Enter.

**2. Apple Command Line Tools 설치** (1회, 무료, Apple 공식):

```sh
xcode-select --install
```

다이얼로그가 뜨면 **Install** 클릭, 약관 동의, 몇 분 대기. *(이미 깔려있으면 "command line tools are already installed" 표시 — 바로 3단계로.)*

**3. Ribbind 다운로드 / 빌드 / 설치.** 아래 블록을 한 번에 붙여넣으세요:

```sh
cd ~/Downloads
git clone https://github.com/minguk2/ribbind.git
cd ribbind
scripts/build-app.sh release
pkill -f /Applications/Ribbind.app 2>/dev/null; sleep 1
rm -rf /Applications/Ribbind.app
mv dist/Ribbind.app /Applications/
open /Applications/Ribbind.app
```

빌드는 ~30초. Ribbind은 메뉴바 (화면 우상단) 에 자리 잡습니다 — Dock 아이콘은 의도적으로 없음.

**4. 권한 요청이 뜨면 허용.**

- **Accessibility** (첫 실행). 다이얼로그에서 *Open System Settings* 클릭, Ribbind을 켭니다. *(놓쳤으면: System Settings → Privacy & Security → Accessibility → Ribbind 활성화.)*
- **Automation** (첫 색상/도형 단축키 사용 시). macOS가 *"Ribbind would like to control Microsoft Word/PowerPoint"* 라고 묻습니다 → **OK** 클릭. Office 앱당 1회, 그 이후엔 묵묵.

메뉴바 아이콘에서 Settings 열거나 `⌘,` 로 단축키 바인딩 시작.

---

## 바인딩 가능한 명령

### PowerPoint

![PowerPoint settings tab](docs/screenshots/settings-powerpoint.png)

- **Format:** Format Painter, Font Color 1/2/3 (per-binding RGB picker), Font Family
- **Picture:** Crop, Lock Aspect Ratio
- **Shapes:** Text Box (커서 위치에 생성), Oval, Rectangle, Rounded Rectangle, Down Arrow, Left Arrow
- **Slide Show:** Hide Slide

메뉴 접근 가능한 4개 도형 (Text Box / Oval / Rectangle / Rounded Rectangle) 은 PowerPoint 자체 메뉴를 통해 dispatch — 단축키를 누르면 **드래그 커서가 무장됩니다** (Insert 메뉴 직접 클릭과 동일). 화살표는 커서 슬라이드 좌표에 고정 크기로 즉시 생성.

### Word

![Word settings tab](docs/screenshots/settings-word.png)

- **Format:** Format Painter, Highlight 1/2/3 (per-binding 명명색: yellow / bright green / blue / pink / red 등), Font Color 1/2/3 (RGB picker), Font Family
- **Picture:** Crop, Lock Aspect Ratio

Highlight는 Word 표준 `<w:highlight>` 요소를 쓰므로 **홈 리본의 No Color 버튼이 정상적으로 지웁니다** — "Format Painter로만 지워지던" 문제 해결.

### Google Chrome

![Google Chrome settings tab](docs/screenshots/settings-chrome.png)

- **Translate Page (toggle)** — 18개 언어 중 선택 (한국어, 일본어, 중국어 간체/번체, 스페인어, 프랑스어, 독일어, 이탈리아어, 포르투갈어, 러시아어, 아랍어, 힌디어, 베트남어, 태국어, 인도네시아어, 터키어, 네덜란드어, 폴란드어). 단축키 1번 → Chrome 내장 on-device Translator API로 페이지 텍스트 in-place 번역. 1번 더 → 원본 복원. 커서 안 움직이고 메뉴 깜빡임 0, 번역 시 외부 네트워크 0, API key 0, rate limit 0.

Chrome 탭 안에서 안내되는 일회성 setup 두 가지:
1. *Chrome > View > Developer > Allow JavaScript from Apple Events* 토글 (Chrome 프로필별 보안 게이트)
2. Ribbind에서 "Initialize translation model" 클릭 → Chrome 페이지 어디든 1번 클릭. Chrome이 선택한 언어 페어용 on-device 모델을 다운로드 (페어당 ~50 MB, 1회).

### Per-binding 파라미터 picker

Highlight 행은 **명명색 swatch**, Font Color 행은 **RGB color well**, Font Family 행은 **시스템 폰트 picker**, Translate 행은 **타겟 언어 메뉴** — 각각 binding마다 기억되며 export/import 시에도 유지됩니다.

*Crop* / *Lock Aspect Ratio* 옆 오렌지 ⚠ 표시는 **선택된 객체가 필요**함을 의미 (이 명령들은 현재 선택된 그림에 작동).

**원하는 명령이 없나요?** 툴바의 *Add from Word…* / *Add from PowerPoint…* 클릭. Ribbind이 설치된 Office에서 직접 Ribbon 버튼 / 메뉴 항목을 읽어옵니다. 재시작 불필요.

**기존 명령 바인딩 외 새 기능이 필요하신가요?** **[Issue 열기](../../issues/new)** 로 알려주세요. 모든 issue 읽습니다.

---

## 권한 + General 탭

![General settings tab](docs/screenshots/settings-general.png)

macOS 권한 3가지 — 각각 필요 시 1회 요청:

| 권한 | 시점 | 이유 |
|---|---|---|
| **Accessibility** | 첫 실행 | Office / Chrome이 키 입력 받기 전에 Ribbind이 가로채기. Ribbon 버튼 클릭. |
| **Automation** (Word / PowerPoint) | 첫 Word/PPT 색상/도형 단축키 | Office에 직접 서식 적용 / 도형 삽입 명령 전달. |
| **Automation** (Google Chrome) | 첫 Translate Page 단축키 | Chrome 활성 탭에 번역 JavaScript 실행. |

추가로 Chrome 측 토글 1개 (시스템 권한 아님): **Chrome > View > Developer > Allow JavaScript from Apple Events**. Ribbind Settings → Google Chrome 탭이 한 번 클릭으로 안내합니다.

나중에 해제: *System Settings → Privacy & Security → Accessibility / Automation*.

**General** 탭은 setup 한눈에 보기:

- **Accessibility:** 초록 체크 = 활성. 빨강이면? *Re-grant Accessibility* 클릭.
- **Office detection:** Word/PowerPoint 검출 확인 + 버전 / 경로 표시.
- **Launch at login:** 자동 시작.
- **Import / Export:** Mac 간 binding 이동을 위한 JSON 라운드트립.

---

## FAQ

**단축키가 동작 안 함.** 순서대로 확인: (1) Word / PowerPoint / Chrome이 frontmost인지, (2) **현재** `/Applications/Ribbind.app`에 Accessibility 권한이 있는지 (재빌드 시 code signature 회전 — 업데이트 후 *System Settings → Privacy & Security → Accessibility* 에서 Ribbind 제거 후 재추가 필요할 수 있음), (3) PowerPoint 메뉴 단축키는 launch 시점에만 등록되므로 binding 후 PowerPoint 종료 / 재시작.

**Chrome ⌃⌘T 가 동작 안 함 / notification 뜸.** Translate Page 명령은 *Chrome > View > Developer > Allow JavaScript from Apple Events* 활성 (Chrome 프로필별 1회) + 선택한 언어 페어의 on-device 모델 1회 다운로드 필요. Ribbind Settings → Google Chrome 탭이 둘 다 안내합니다 — 초록 ✓ = 준비됨, 오렌지 ⚠ = 액션 필요.

**Apple Developer 계정 ($99/yr) 필요?** 아니오. Ribbind은 오픈소스이며 Apple 무료 Command Line Tools로 빌드합니다 — 그래서 설치가 다운로드 `.zip`이 아니라 터미널 복사-붙여넣기.

**인터넷 통신?** Chrome 번역 모델 1회 다운로드 외엔 없음. 다운로드 자체는 Chrome이 Google 모델 서버에 접속하는 작업. Ribbind의 다른 모든 동작은 100% 로컬 — 텔레메트리, 자동 업데이트, 분석 모두 없음. 런타임 번역은 Chrome on-device 모델 사용 (네트워크 호출 X).

**기존 Word 커스터마이즈와 충돌?** 없음. Ribbind은 Word/PowerPoint가 이미 사용하는 곳에 씁니다 (Word *Customize Keyboard* 다이얼로그 / PowerPoint 메뉴 단축키가 만지는 파일들). 기존 binding은 그대로 — 충돌 시 가장 최근 할당 우선.

**더 새 버전으로 업데이트?** 이 명령 실행:

```sh
cd ~/Downloads/ribbind && git pull && scripts/build-app.sh release && \
  pkill -f /Applications/Ribbind.app 2>/dev/null; sleep 1 && \
  rm -rf /Applications/Ribbind.app && \
  mv dist/Ribbind.app /Applications/ && open /Applications/Ribbind.app
```

(이후 Accessibility 재허용 필요할 수 있음 — 첫 FAQ 항목 참고.)

---

## 제거

1. 메뉴바에서 Ribbind 종료 (아이콘 → *Quit*).
2. `rm -rf /Applications/Ribbind.app` (또는 휴지통으로 이동).
3. *(선택)* `rm -rf ~/Downloads/ribbind` 로 소스 제거.
4. *(선택)* *System Settings → Privacy & Security* 에서 Accessibility / Automation 권한 해제.

---

## 라이선스 & 지원

[MIT](./LICENSE). Vendored [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) 는 자체 MIT 라이선스 유지 ([`Sources/Vendored/KeyboardShortcuts/LICENSE`](./Sources/Vendored/KeyboardShortcuts/LICENSE)).

Ribbind이 시간 절약에 도움이 됐고 커피 하나 보내고 싶으시면 [여기](https://ko-fi.com/minguk2). 진짜 큰 도움 됩니다.

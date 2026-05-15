# Ribbind

🌐 [English](./README.md) · **한국어**

macOS의 Microsoft Word, PowerPoint, Google Chrome 명령에 키보드 단축키를 할당합니다. System Settings의 키보드 단축키 화면으로는 닿지 않는 Ribbon 전용 버튼도 포함합니다.

현재 버전: **v0.6.3**

[![Support on Ko-fi](https://img.shields.io/badge/Support%20on-Ko--fi-ff5e5b?logo=ko-fi&logoColor=white&style=for-the-badge)](https://ko-fi.com/minguk2)

---

## 설치

**1단계. Ribbind.app 다운로드** — [최신 릴리즈](https://github.com/minguk2/ribbind/releases/latest) 페이지에서 `Ribbind-v0.6.3.zip` 을 받습니다.

**2단계. zip 파일 더블클릭** 으로 압축을 풉니다. `Ribbind.app` 이 생성됩니다.

**3단계. `Ribbind.app` 을 `/Applications` 폴더로 드래그** 합니다.

**4단계. 첫 실행만 우클릭으로 엽니다.** `/Applications` 안의 `Ribbind.app` 을 우클릭 → **열기** → **확인** (혹은 **Open Anyway**).

이건 1회만 거치면 되는 Gatekeeper 우회 단계입니다. Ribbind 은 ad-hoc 서명만 사용하기 때문에 (유료 Apple Developer 계정 불필요) macOS 가 첫 실행 때 한 번 확인을 요청합니다. 그 다음부터는 더블클릭으로 자연스럽게 실행됩니다.

Ribbind 은 메뉴바에서 동작하며 Dock 아이콘은 표시되지 않습니다. 설정창은 메뉴바 아이콘에서 열거나 `⌘,` 단축키로 엽니다.

**5단계. 권한 부여** — 시스템 다이얼로그가 뜨면 한 번씩 클릭만 하면 됩니다:
- **Accessibility** (첫 단축키 사용 시): 단축키를 Word / PowerPoint / Chrome 보다 먼저 가로채기 위해 필요합니다.
- **Automation** (Word / PowerPoint / Chrome): Apple Events 로 효과를 적용하기 위해 필요합니다. 각 앱에서 첫 단축키를 누를 때 한 번씩 묻습니다.

### 업데이트

새 릴리즈의 zip 을 받아 압축을 풀고, 새 `Ribbind.app` 을 `/Applications` 폴더로 드래그 (기존 것을 덮어쓰기) 한 다음 우클릭 → 열기를 1회 실행합니다. 단축키 바인딩, picker 설정값, Accessibility 권한 부여는 그대로 유지됩니다.

새 버전 교체 후에는 System Settings 의 Privacy & Security → Accessibility 에서 Ribbind 을 제거하고 다시 추가해야 할 수 있습니다 (릴리즈마다 코드 서명이 바뀝니다).

---

## 소스에서 직접 빌드 (선택)

다운로드 대신 직접 빌드하고 싶다면 터미널을 열고, Apple 의 무료 Command Line Tools 를 1회 설치 (`xcode-select --install`) 한 뒤 다음을 실행합니다:

```sh
mkdir -p ~/Downloads && cd ~/Downloads
rm -rf ribbind
git clone https://github.com/minguk2/ribbind.git
cd ribbind
scripts/build-app.sh release
pkill -f /Applications/Ribbind.app 2>/dev/null; sleep 1
rm -rf /Applications/Ribbind.app
mv dist/Ribbind.app /Applications/
open /Applications/Ribbind.app
```

처음 설치와 업데이트 모두 같은 블록을 그대로 실행하면 됩니다. 빌드는 약 30초입니다. 새 빌드 후에는 Accessibility 권한을 다시 부여해야 할 수 있습니다.

---

## 바인딩 가능한 명령

### PowerPoint

![PowerPoint settings tab](docs/screenshots/settings-powerpoint.png)

- **Format**: Format Painter, Font Color 1/2/3 (RGB picker), Font Family
- **Picture**: Crop, Lock Aspect Ratio
- **Shapes**: Text Box, Oval, Rectangle, Rounded Rectangle, Down Arrow, Left Arrow
- **Slide Show**: Hide Slide

메뉴에 등록된 4개 도형(Text Box, Oval, Rectangle, Rounded Rectangle)은 단축키를 누르면 PowerPoint의 드래그 그리기 커서가 활성화됩니다. 마우스로 Insert 메뉴에서 Shape를 직접 클릭한 것과 같은 동작입니다.

### Word

![Word settings tab](docs/screenshots/settings-word.png)

- **Format**: Format Painter, Highlight 1/2/3 (이름 있는 색상), Font Color 1/2/3 (RGB), Font Family
- **Picture**: Crop, Lock Aspect Ratio

Highlight 명령은 Word 표준 `<w:highlight>` 속성을 사용합니다. 따라서 홈 리본의 *No Color* 버튼으로 정상적으로 지울 수 있습니다.

### Google Chrome

![Google Chrome settings tab](docs/screenshots/settings-chrome.png)

**Translate Page (toggle)**: 18개 언어 중에서 원하는 언어를 선택할 수 있습니다. 단축키를 한 번 누르면 Chrome의 on-device Translator API로 페이지가 그 자리에서 번역됩니다. 한 번 더 누르면 원문이 복원됩니다.

마우스 커서가 움직이지 않고 UI 깜빡임도 없습니다. API key나 외부 네트워크 호출도 필요하지 않습니다.

설정창에서 일회성 준비 두 가지를 안내합니다.

1. *Chrome > View > Developer > Allow JavaScript from Apple Events* 메뉴를 켭니다 (Chrome 프로필 단위로 1회 설정).
2. Ribbind 설정창의 **Initialize translation model** 버튼을 누른 뒤, Chrome 페이지의 아무 곳이나 한 번 클릭합니다. Chrome이 선택한 언어용 on-device 모델을 다운로드합니다 (언어 페어당 약 50 MB).

### 행마다 따로 설정하는 옵션

각 Highlight, Font Color, Font Family, Translate 행마다 별도의 picker가 있습니다 (색상 swatch, RGB well, 폰트 메뉴, 언어 메뉴). 설정한 값은 Export / Import 사이에도 유지됩니다.

⚠ 표시는 Ribbon 전용 명령(AppleScript 대안 없이 Ribbon 버튼 클릭으로만 동작) 임을 뜻합니다. *Crop* 과 *Lock Aspect Ratio* 는 추가로 이미지가 선택된 상태여야 동작합니다.

**다른 명령이 필요하면** *Add from Word…* 또는 *Add from PowerPoint…* 버튼을 누릅니다. Ribbind이 실행 중인 Office에서 Ribbon 버튼과 메뉴 항목을 직접 읽어옵니다. 새 기능 요청은 [Issue 등록](../../issues/new)으로 알려주세요.

---

## 권한

![General settings tab](docs/screenshots/settings-general.png)

| 권한 | 시점 | 이유 |
|---|---|---|
| **Accessibility** | 첫 실행 시 | 단축키를 Office와 Chrome보다 먼저 가로채기 |
| **Automation** (Word / PPT) | 첫 Word / PPT 단축키 사용 시 | 서식 적용, 도형 삽입 |
| **Automation** (Chrome) | 첫 Translate 단축키 사용 시 | 활성 탭에서 번역 JavaScript 실행 |

이 외에 Chrome 자체 토글이 한 가지 더 필요합니다 (시스템 권한은 아닙니다). *View > Developer > Allow JavaScript from Apple Events* 메뉴이며, Ribbind 설정창에서 한 번에 안내합니다.

**General** 탭에서 Accessibility 상태, Office 검출 결과, Launch at login, Import / Export 를 한눈에 확인할 수 있습니다.

---

## FAQ

**단축키가 동작하지 않는 경우.** 다음을 순서대로 확인합니다.

1. 대상 앱이 frontmost 상태인지 확인합니다.
2. **현재** `/Applications/Ribbind.app` 에 Accessibility 권한이 부여되어 있는지 확인합니다. 릴리즈마다 코드 서명이 바뀌므로, System Settings 의 Privacy & Security → Accessibility 에서 Ribbind 을 제거한 뒤 다시 추가해야 할 수 있습니다.
3. PowerPoint 메뉴 단축키는 PowerPoint 가 실행될 때만 등록됩니다. 단축키를 새로 바인딩한 뒤에는 PowerPoint 를 종료하고 다시 켜야 합니다.

**"Ribbind 을(를) 열 수 없습니다 — 확인할 수 없는 개발자" 같은 다이얼로그가 뜨는 경우.** 첫 실행 때 한 번만 나오는 Gatekeeper 안내입니다. Finder 에서 `Ribbind.app` 을 우클릭 → **열기** → **확인** (혹은 **Open Anyway**) 을 누르면 됩니다. macOS 가 한 번 허용 받으면 그 이후로는 더블클릭만으로 정상 실행됩니다.

**Chrome 에서 ⌃⌘T 가 작동하지 않거나 알림창만 뜨는 경우.** 설정창의 Google Chrome 탭에서 두 단계가 모두 초록색 ✓ 상태인지 확인합니다. 첫 모델 다운로드는 *Initialize* 버튼을 누른 후 안내에 따라 진행합니다. 페이지가 크면 첫 번째 누름으로 번역이 끝나기까지 수 초가 걸릴 수 있습니다. 페이지가 안정되기 전에 한 번 더 누르면 *Translation in progress* 알림이 뜨고 다음 누름은 잠시 보류됩니다 (토글 상태가 어긋나지 않도록 의도된 동작입니다).

**"Couldn't detect page language" 알림이 뜨는 경우.** 해당 페이지에 `<html lang>` 속성이 없고 Chrome 의 `LanguageDetector` API 도 결과를 주지 못한 상황입니다. 탭을 새로 고치거나 일반 HTML 구조의 페이지로 시도해 보세요.

**Apple Developer 유료 계정이 필요한가요?** 필요하지 않습니다. 배포되는 `.app` 은 ad-hoc 서명만 사용합니다 (무료, 유료 계정 불필요). 그 대가로 위에서 안내한 첫 실행 시 *우클릭 → 열기* 단계가 1회 필요합니다.

**인터넷에 연결됩니까?** Chrome 번역 모델을 한 번 다운로드할 때를 제외하면 통신하지 않습니다. 그 이후의 번역은 모두 on-device 로 처리됩니다. 사용 통계 수집이나 자동 업데이트도 없습니다.

**기존 Word 사용자 정의 키와 충돌하지 않나요?** 충돌하지 않습니다. Ribbind 은 Word 의 *Customize Keyboard* 가 사용하는 파일에 같은 방식으로 기록합니다. 같은 키 조합이 겹치면 가장 최근에 설정한 값이 적용됩니다.

**업데이트하려면?** 두 가지 방법 모두 가능합니다. (1) 새 릴리즈의 zip 을 받아 압축을 풀고, 새 `Ribbind.app` 을 `/Applications` 폴더로 드래그 (기존 것을 덮어쓰기) 한 다음 우클릭 → 열기를 1회 실행합니다. (2) 또는 위 *소스에서 직접 빌드* 블록을 다시 실행하면 최신 원격을 받아 한 번에 교체합니다. 어느 쪽이든 단축키 바인딩과 picker 설정값은 유지됩니다.

---

## 제거

1. 메뉴바 아이콘에서 Quit 으로 Ribbind 을 종료합니다.
2. `rm -rf /Applications/Ribbind.app` 으로 앱을 삭제합니다.
3. (선택) `rm -rf ~/Downloads/ribbind` 으로 소스 코드를 삭제하고, System Settings 에서 Accessibility / Automation 권한도 해제합니다.

---

## 라이선스

[MIT](./LICENSE)

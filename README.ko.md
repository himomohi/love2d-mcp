# LÖVE2D MCP 2.1 — 게임 개발·테스트 도구

[English](README.md) · [도구 호출 예시](EXAMPLES.md) · [보안 범위](SECURITY.md)

AI가 실행 중인 LÖVE 게임의 **기능 발견 → 상태 조회 → 조작 → 프레임 진행 → 화면 캡처 → 변경 비교**를 수행하도록 구성한 로컬 MCP입니다. 임의 Lua 실행을 켜지 않아도 일반적인 개발·테스트 작업을 할 수 있습니다.

## 시작하기

Node.js **22.16 이상**, LÖVE **11.4 이상**이 필요합니다. LÖVE 엔진은 별도 설치합니다.

```sh
git clone https://github.com/himomohi/love2d-mcp.git
cd love2d-mcp
npm ci --ignore-scripts
npm run setup
npm run build
npm run game
```

이미 저장소가 있다면 새로 clone하지 말고 최신 master를 가져온 뒤 나머지 명령을 실행합니다.

`npm run setup`은 랜덤 인증 토큰을 `.env`에 생성하고, **현재 폴더의 절대 경로가 반영된 Codex MCP 설정**을 출력합니다. 토큰 자체는 출력하지 않으며 기존 `.env`를 덮어쓰지 않습니다. 출력된 설정 블록을 Codex 설정에 추가하세요. 게임은 별도 터미널에서 실행하고, MCP 서버 프로세스는 Codex가 시작합니다.

Windows에서 LÖVE를 찾지 못하면 PowerShell에서 실행 파일 경로를 지정합니다.

```powershell
$env:LOVE2D_EXECUTABLE = 'C:\Program Files\LOVE\love.exe'
npm run game
```

다른 경로에 설치했다면 실제 경로로 바꾸세요. 기존 게임을 실행할 때는 `npm run game -- "G:\Games\MyGame"`처럼 폴더를 지정할 수 있습니다. 해당 게임에는 먼저 아래 Lua 모듈 연동이 필요합니다.

## 제공 기능

| 작업 | 도구 |
|---|---|
| 연결·가능한 기능 확인 | `ping`, `get_status`, `list_actions` |
| 객체 검색·조회 | `list_objects`, `get_object` |
| 게임이 허용한 변경 | `set_object_property`, `invoke_action` |
| FPS·메모리·로그 | `get_metrics`, `get_logs` |
| 가상 입력·일시정지·프레임 진행·화면 | `send_input`, `control_game`, `capture_screenshot` |
| 상태 저장·변경 비교·복원 | `save_snapshot`, `diff_snapshot`, `restore_snapshot` |
| 여러 작은 요청 묶기 | `batch` |

기본 도구는 **16개**입니다. `run_lua`는 기본 목록에서 숨기며, Node 환경변수와 게임 설정 양쪽에서 켰을 때만 사용합니다. 일반적인 조작에는 켤 필요가 없습니다.

`capture_screenshot`은 **게임이 실제로 그린 화면**을 MCP 이미지로 반환합니다. 바탕화면 전체나 클립보드를 읽지 않으며, 캡처를 임의 파일 경로에 저장하지 않습니다. 게임이 렌더링 중이어야 합니다.

## 기존 게임에 붙이기

`game/`의 **mcp_bridge.lua, mcp_json.lua, mcp_runtime.lua** 세 파일을 게임의 Lua 모듈 경로에 복사합니다. 데모 `main.lua`로 기존 게임을 덮어쓰지 마세요. [영문 README의 연동 예제](README.md#integrate-your-own-game)를 기존 콜백에 합칩니다.

`setObjectGetter`로 공개할 게임 상태를 지정하고, `registerAction`으로 허용할 작업과 매개변수 범위를 등록합니다. 가상 입력·프레임 제어·스크린샷은 `mcp_runtime.attach`에서 각각 명시적으로 활성화합니다.

키 입력을 `love.keyboard.isDown`으로 확인하던 부분은 `runtime.isDown`으로 연결해야 가상 입력도 반영됩니다. 프레임 제어는 `runtime.advance(dt, simulate)`로 감싼 시뮬레이션에 적용됩니다. 일시정지해도 `mcp.update()`와 그리기는 계속 실행되어야 합니다.

로그는 `mcp.log`로 남긴 내용과 브리지 오류를 읽습니다. 스냅샷은 JSON으로 표현할 수 있는 게임 데이터만 다루며, 물리 엔진·GPU 상태를 자동으로 복사하지 않습니다. 복원에는 게임의 검증 콜백과 `allow_restore=true`가 모두 필요합니다. 데모만 복원을 활성화해 두었습니다.

## AI에 전달할 작업 예시

> 먼저 연결과 사용 가능한 액션을 확인해. 게임을 일시정지하고 baseline 스냅샷을 저장한 뒤 오른쪽 입력으로 6프레임 진행해. 입력을 해제하고 실제 게임 화면과 좌표 변화를 확인해. baseline과 비교한 다음, 게임이 복원을 허용한다면 원래 상태로 돌려줘. run_lua는 켜지 마.

## 알아둘 제한

로컬 개발 전용입니다. 브리지 파일과 `.env`를 게임 배포본에 포함하지 마세요. 기본은 loopback 연결과 인증 필수이며, 이미 PC 계정에 접근할 수 있는 악성 프로그램까지 격리하는 제품은 아닙니다.

스크린샷은 최대 4메가픽셀·PNG 2 MiB·초당 2회, 스냅샷은 메모리에 8개까지 저장합니다. `batch`는 트랜잭션이 아니므로 중간에 실패해도 먼저 실행된 변경은 남습니다. 타임아웃도 이미 실행된 변경을 취소하지 않습니다. 게임 조작을 마치면 `send_input`의 `reset`을 호출하세요.

2.0에서 올릴 때는 서버와 세 Lua 모듈을 함께 업데이트해야 합니다. 객체 목록은 페이지 방식으로 바뀌었으므로 `next_offset`을 따라 조회합니다. 한글·유니코드·빈 배열·null은 새 JSON 모듈로 처리합니다.

자동 검증 범위는 Node Linux/Windows, Lua 5.1/5.4/LuaJIT, Linux LÖVE 실제 화면·MCP 연결입니다. Windows/macOS에서의 엔진 실행과 개별 게임 호환성까지 자동으로 보증하지는 않습니다. 정확한 실행 결과는 해당 커밋의 GitHub Actions를 확인하세요.

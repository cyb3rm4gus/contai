# contai — containerized Claude agent for an Obsidian wiki & dev work

*Read this in [English](#english) · [Русский](#русский)*

---

## English

### What this is

`contai` runs the **Claude Code agent inside a hardened Docker container**, while you
drive it from your **normal desktop VSCodium** — same in-IDE UX as the Claude
extension, except the AI agent lives in the container, not on your machine.

The link between the desktop editor and the container is a **self-built, zero-dependency
VSCodium remote resolver** plus the **official VSCodium Remote Extension Host (REH)**
server baked into the image. There are **no third-party remote-access extensions** and
**no SSH** — the whole bridge is code you can read in this repo. That is a deliberate
supply-chain decision: the only remote code you trust is your own and the VSCodium
release you already run.

It serves two separate work domains:

- **`obsidian/`** — an Obsidian vault the agent reads and writes (research → wiki).
- **`dev/`** — cloned repositories you want the agent to work on.

### How it works

```
   ┌─────────────────── your machine ───────────────────┐        ┌──── Docker: wiki-agent ────┐
   │  Desktop VSCodium                                   │        │                             │
   │   └─ resolver ext "Contained claude for wiki and dev"        │  codium-server (REH) :8000  │
   │        id: local.wiki-reh-resolver  (runs locally)  │  ⇆     │   └─ Claude Code extension  │
   │        vscode-remote://wiki-reh+wiki-agent/… ───────┼─ ws ──▶│  /home/agent                │
   │                                                     │ token  │   ├─ obsidian/{raw,tpl,wiki} │
   │  argv.json     → enable-proposed-api                │  127.  │   ├─ dev/                    │
   │  settings.json → wikiReh.hosts (host, port, token)  │ 0.0.1  │   └─ CLAUDE.md (ro)          │
   └─────────────────────────────────────────────────────┘        └─────────────────────────────┘
```

1. The **REH server** is baked into the image from the **official VSCodium release that
   matches your desktop** (commit-pinned and verified at build time — same trust root as
   your editor).
2. `start-reh.sh` is **PID 1** of the container: it mints a persistent connection token,
   one-time-installs the Claude Code extension into the `agent-home` volume, and runs
   `codium-server` on `0.0.0.0:8000` (published only to `127.0.0.1`).
3. The **resolver extension** on the desktop maps the authority
   `wiki-reh+wiki-agent` to `localhost:8000` + the token. It declares
   `extensionKind: ["ui"]` so it runs locally (a resolver must run on the desktop side).

### Repository layout

```
contai/
├── Dockerfile            # image: Debian-slim + Claude Code CLI + VSCodium REH (baked last)
├── compose.yml           # host-OS-agnostic service definition + mounts
├── .dockerignore         # keep build context to start-reh.sh + reh/reh.tar.gz
│
├── obsidian/             # the wiki vault  →  mounted at /home/agent/obsidian/*
│   ├── raw/              #   read-only source material (ro)
│   ├── templates/        #   note templates (rw)
│   └── wiki/             #   generated wiki output (rw)
│   # .obsidian/ (vault config) is NEVER mounted — the agent can't touch it
│
├── dev/                  # pulled repositories  →  mounted whole at /home/agent/dev (rw)
│
└── harness/              # service layer (build / run / connect)
    ├── cook.sh / cook.ps1            # one-command build+start+install (Linux/macOS · Windows)
    ├── build-resolver.sh / .ps1      # package the resolver VSIX with zip only (no MS/npm tooling)
    ├── start-reh.sh                  # container PID 1
    ├── CLAUDE.md                     # agent instructions, bind-mounted ro to /home/agent/CLAUDE.md
    ├── resolver/                     # the ~60-line zero-dependency resolver extension
    └── reh/                          # downloaded REH tarballs (gitignored)
```

### Prerequisites

- **Docker** with the `docker compose` plugin, running.
- **Desktop VSCodium** with the `codium` CLI on `PATH` (macOS app path is auto-detected).
- **`zip`** on `PATH` (used to package the resolver VSIX).
- Works on **Linux, macOS, and Windows** — `compose.yml` is host-OS-agnostic.

### First-time setup

**1. Cook it.** From the repo root:

```bash
./harness/cook.sh          # Linux / macOS
```
```powershell
.\harness\cook.ps1         # Windows
```

`cook` detects your desktop VSCodium version/commit/arch, downloads the matching REH
release, builds and starts the container (verifying the REH commit matches your desktop),
then builds and installs the resolver into your desktop VSCodium. It finishes by printing
your **connection token** and the exact config to paste.

**2. One-time desktop config** (cook prints these with your real token):

- **Runtime args** — Command Palette → *Preferences: Configure Runtime Arguments*
  (`~/.vscode-oss/argv.json` on Linux), add and then **fully quit & reopen VSCodium**:
  ```jsonc
  "enable-proposed-api": ["local.wiki-reh-resolver"]
  ```
- **Settings** — add to your VSCodium `settings.json`:
  ```jsonc
  "wikiReh.hosts": [
    {
      "name": "wiki-agent",
      "host": "localhost",
      "port": 8000,
      "connectionToken": "<printed by cook>",
      "folders": [ { "name": "agent", "path": "/home/agent" } ]
    }
  ]
  ```

**3. Connect.** Command Palette → **“Wiki REH: Connect to Container.”** The window reloads
into the container; the Claude Code sidebar is already installed inside. **Sign in once**
(web auth) — it persists in the `agent-home` volume, so you won't repeat it.

### Everyday use

```bash
docker compose up -d                       # start (from repo root)
docker compose down                        # stop
docker exec -it wiki-agent claude          # a plain CLI session, no IDE
```

- Reconnect any time via the same *Connect to Container* command or the recent-remotes list.
- Drop repos into `dev/` — they appear at `/home/agent/dev` inside the container.
- The agent’s wiki work lives in `obsidian/{raw,templates,wiki}`; open `obsidian/` as an
  Obsidian vault on the host (its `.obsidian/` config stays yours and is never mounted).

### Keeping it in sync with VSCodium updates

When your desktop VSCodium updates, just re-run `./harness/cook.sh`. It detects the new
commit, rebuilds **only** the small REH layer, and re-verifies that the container’s server
matches your editor. Mismatches fail the build on purpose.

### Overrides

| Variable          | Purpose                                             |
|-------------------|-----------------------------------------------------|
| `VSCODIUM_VERSION`| Pin a version instead of auto-detecting             |
| `CODIUM_BIN`      | Point at a VSCodium binary that isn’t on `PATH`     |
| `REH_PORT`        | Change the loopback port (default `8000`)           |

### Security model

- **Agent is sandboxed** in the container (`no-new-privileges`, port bound to `127.0.0.1`).
- **No third-party remote code**: the REH server is the official VSCodium build matching
  your desktop (commit-pinned + verified); the resolver is ~60 lines, zero deps, built
  locally with `zip`. No SSH, no keys, no marketplace fetch.
- The vault’s **`.obsidian/` config is never mounted** — outside the agent’s reach.
- **Web-based auth**; the token lives in the `agent-home` volume, not in the repo.

### Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `No remote extension installed to resolve wiki-reh` | Resolver isn’t running locally. Ensure `extensionKind:["ui"]` in the installed manifest, `enable-proposed-api` is set, and VSCodium was **fully restarted** (not just “Reload Window”). |
| `curl 127.0.0.1:8000` returns **403** | Normal — the REH server is token-gated. |
| Need the token again | `docker exec wiki-agent cat /home/agent/.vscodium-server/connection-token` |
| Connect command missing | You’re already inside the remote window — there’s nothing left to connect to. |

---

## Русский

### Что это

`contai` запускает **агента Claude Code внутри изолированного Docker-контейнера**, а вы
управляете им из **обычного десктопного VSCodium** — тот же UX, что и у расширения Claude,
только сам ИИ-агент живёт в контейнере, а не на вашей машине.

Связь между десктопным редактором и контейнером — это **самостоятельно собранный резолвер
VSCodium без единой зависимости** плюс **официальный сервер VSCodium Remote Extension Host
(REH)**, вшитый в образ. Здесь **нет сторонних расширений удалённого доступа** и **нет
SSH** — весь мост это код, который можно прочитать в этом репозитории. Это осознанное
решение против атак на цепочку поставок: единственный удалённый код, которому вы доверяете,
это ваш собственный и та сборка VSCodium, которой вы уже пользуетесь.

Обслуживаются две независимые области работы:

- **`obsidian/`** — хранилище Obsidian, которое агент читает и наполняет (ресёрч → вики).
- **`dev/`** — склонированные репозитории, над которыми должен работать агент.

### Как это устроено

```
   ┌─────────────────── ваша машина ────────────────────┐        ┌──── Docker: wiki-agent ────┐
   │  Десктопный VSCodium                                │        │                             │
   │   └─ расширение-резолвер "Contained claude…"        │        │  codium-server (REH) :8000  │
   │        id: local.wiki-reh-resolver  (локально)      │  ⇆     │   └─ расширение Claude Code  │
   │        vscode-remote://wiki-reh+wiki-agent/… ───────┼─ ws ──▶│  /home/agent                │
   │                                                     │ токен  │   ├─ obsidian/{raw,tpl,wiki} │
   │  argv.json     → enable-proposed-api                │  127.  │   ├─ dev/                    │
   │  settings.json → wikiReh.hosts (host, port, token)  │ 0.0.1  │   └─ CLAUDE.md (ro)          │
   └─────────────────────────────────────────────────────┘        └─────────────────────────────┘
```

1. **Сервер REH** вшивается в образ из **официального релиза VSCodium, соответствующего
   вашему десктопу** (коммит закреплён и проверяется на этапе сборки — тот же корень
   доверия, что и у редактора).
2. `start-reh.sh` — это **PID 1** контейнера: он создаёт постоянный токен подключения,
   единожды устанавливает расширение Claude Code в том `agent-home` и запускает
   `codium-server` на `0.0.0.0:8000` (публикуется только на `127.0.0.1`).
3. **Расширение-резолвер** на десктопе сопоставляет authority `wiki-reh+wiki-agent` с
   `localhost:8000` и токеном. Оно объявляет `extensionKind: ["ui"]`, чтобы работать
   локально (резолвер обязан выполняться на стороне десктопа).

### Структура репозитория

```
contai/
├── Dockerfile            # образ: Debian-slim + Claude Code CLI + VSCodium REH (вшивается последним)
├── compose.yml           # описание сервиса, не зависящее от ОС хоста, + монтирования
├── .dockerignore         # оставить в контексте только start-reh.sh + reh/reh.tar.gz
│
├── obsidian/             # хранилище вики  →  монтируется в /home/agent/obsidian/*
│   ├── raw/              #   исходные материалы, только чтение (ro)
│   ├── templates/        #   шаблоны заметок (rw)
│   └── wiki/             #   сгенерированная вики (rw)
│   # .obsidian/ (конфиг хранилища) НЕ монтируется — агент его не трогает
│
├── dev/                  # склонированные репозитории  →  монтируется целиком в /home/agent/dev (rw)
│
└── harness/              # служебный слой (сборка / запуск / подключение)
    ├── cook.sh / cook.ps1            # сборка+запуск+установка одной командой (Linux/macOS · Windows)
    ├── build-resolver.sh / .ps1      # упаковка VSIX резолвера только через zip (без инструментов MS/npm)
    ├── start-reh.sh                  # PID 1 контейнера
    ├── CLAUDE.md                     # инструкции агенту, монтируются ro в /home/agent/CLAUDE.md
    ├── resolver/                     # тот самый резолвер (~60 строк, без зависимостей)
    └── reh/                          # скачанные архивы REH (в .gitignore)
```

### Требования

- **Docker** с плагином `docker compose`, запущенный.
- **Десктопный VSCodium** с CLI `codium` в `PATH` (путь приложения на macOS определяется
  автоматически).
- **`zip`** в `PATH` (нужен для упаковки VSIX резолвера).
- Работает на **Linux, macOS и Windows** — `compose.yml` не зависит от ОС хоста.

### Первый запуск

**1. Соберите.** Из корня репозитория:

```bash
./harness/cook.sh          # Linux / macOS
```
```powershell
.\harness\cook.ps1         # Windows
```

`cook` определяет версию/коммит/архитектуру вашего VSCodium, скачивает подходящий релиз
REH, собирает и запускает контейнер (сверяя коммит REH с вашим десктопом), затем собирает
и устанавливает резолвер в ваш VSCodium. В конце он печатает **токен подключения** и точную
конфигурацию для вставки.

**2. Разовая настройка десктопа** (cook печатает это с вашим реальным токеном):

- **Аргументы запуска** — Command Palette → *Preferences: Configure Runtime Arguments*
  (`~/.vscode-oss/argv.json` в Linux), добавьте и затем **полностью закройте и снова
  откройте VSCodium**:
  ```jsonc
  "enable-proposed-api": ["local.wiki-reh-resolver"]
  ```
- **Настройки** — добавьте в `settings.json` вашего VSCodium:
  ```jsonc
  "wikiReh.hosts": [
    {
      "name": "wiki-agent",
      "host": "localhost",
      "port": 8000,
      "connectionToken": "<напечатает cook>",
      "folders": [ { "name": "agent", "path": "/home/agent" } ]
    }
  ]
  ```

**3. Подключитесь.** Command Palette → **«Wiki REH: Connect to Container».** Окно
перезагрузится уже внутри контейнера; расширение Claude Code там уже установлено.
**Войдите один раз** (веб-авторизация) — сессия сохраняется в томе `agent-home`, повторять
не придётся.

### Повседневное использование

```bash
docker compose up -d                       # запуск (из корня репозитория)
docker compose down                        # остановка
docker exec -it wiki-agent claude          # обычная CLI-сессия, без IDE
```

- Переподключайтесь в любой момент той же командой *Connect to Container* или из списка
  недавних удалённых подключений.
- Кладите репозитории в `dev/` — внутри контейнера они появятся в `/home/agent/dev`.
- Работа агента над вики — в `obsidian/{raw,templates,wiki}`; открывайте `obsidian/` как
  хранилище Obsidian на хосте (его конфиг `.obsidian/` остаётся вашим и не монтируется).

### Синхронизация с обновлениями VSCodium

Когда ваш десктопный VSCodium обновится, просто запустите `./harness/cook.sh` заново. Он
определит новый коммит, пересоберёт **только** небольшой слой REH и снова проверит, что
сервер в контейнере совпадает с редактором. Несовпадение намеренно приводит к ошибке сборки.

### Переменные-переопределения

| Переменная        | Назначение                                                |
|-------------------|-----------------------------------------------------------|
| `VSCODIUM_VERSION`| Закрепить версию вместо автоопределения                   |
| `CODIUM_BIN`      | Указать бинарник VSCodium, которого нет в `PATH`          |
| `REH_PORT`        | Сменить локальный порт (по умолчанию `8000`)              |

### Модель безопасности

- **Агент изолирован** в контейнере (`no-new-privileges`, порт только на `127.0.0.1`).
- **Нет стороннего удалённого кода**: сервер REH — официальная сборка VSCodium под ваш
  десктоп (коммит закреплён и проверен); резолвер — ~60 строк, без зависимостей, собирается
  локально через `zip`. Ни SSH, ни ключей, ни загрузок из маркетплейса.
- Конфиг хранилища **`.obsidian/` никогда не монтируется** — вне досягаемости агента.
- **Веб-авторизация**; токен лежит в томе `agent-home`, а не в репозитории.

### Устранение неполадок

| Симптом | Причина / решение |
|---|---|
| `No remote extension installed to resolve wiki-reh` | Резолвер не запущен локально. Проверьте `extensionKind:["ui"]` в установленном манифесте, наличие `enable-proposed-api` и что VSCodium был **полностью перезапущен** (а не просто «Reload Window»). |
| `curl 127.0.0.1:8000` отвечает **403** | Это норма — сервер REH защищён токеном. |
| Снова нужен токен | `docker exec wiki-agent cat /home/agent/.vscodium-server/connection-token` |
| Команда подключения пропала | Вы уже внутри удалённого окна — подключаться больше не к чему. |

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
   ┌─────────────────── your machine ───────────────────┐        ┌────── Docker: contai ──────┐
   │  Desktop VSCodium                                   │        │                             │
   │   └─ resolver ext "Contained claude for wiki and dev"        │  codium-server (REH) :8000  │
   │        id: local.contai-resolver  (runs locally)    │  ⇆     │   └─ Claude Code extension  │
   │        vscode-remote://contai-reh+contai/… ─────────┼─ ws ──▶│  /home/agent                │
   │                                                     │ token  │   ├─ obsidian/{raw,tpl,wiki} │
   │  argv.json     → enable-proposed-api                │  127.  │   ├─ dev/                    │
   │  settings.json → contai.hosts (host, port, token)   │ 0.0.1  │   └─ CLAUDE.md (ro)          │
   └─────────────────────────────────────────────────────┘        └─────────────────────────────┘
```

1. The **REH server** is baked into the image from the **official VSCodium release that
   matches your desktop** (commit-pinned and verified at build time — same trust root as
   your editor).
2. `start-reh.sh` is **PID 1** of the container: it mints a persistent connection token,
   one-time-installs the Claude Code extension into the `agent-home` volume, and runs
   `codium-server` on `0.0.0.0:8000` (published only to `127.0.0.1`).
3. The **resolver extension** on the desktop maps the authority
   `contai-reh+contai` to `localhost:8000` + the token. It declares
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
    ├── start.sh / start.ps1          # one command: build + start + install + configure (Linux/macOS · Windows)
    ├── build-resolver.sh / .ps1      # package the resolver VSIX with zip only (no MS/npm tooling)
    ├── host-config.py                # writes argv.json + settings.json idempotently (zero deps, stdlib only)
    ├── start-reh.sh                  # container PID 1
    ├── CLAUDE.md                     # agent instructions, bind-mounted ro to /home/agent/CLAUDE.md
    ├── resolver/                     # the ~60-line zero-dependency resolver extension
    └── reh/                          # downloaded REH tarballs (gitignored)
```

### Prerequisites

- **Docker** with the `docker compose` plugin, running.
- **Desktop VSCodium** with the `codium` CLI on `PATH` (macOS app path is auto-detected).
- **`zip`** on `PATH` (used to package the resolver VSIX).
- **`python3`** on `PATH` (used to write the desktop config automatically). Optional — without
  it, `start` prints the two snippets for you to paste by hand instead.
- Works on **Linux, macOS, and Windows** — `compose.yml` is host-OS-agnostic.

### First-time setup

**1. Start it.** From the repo root:

```bash
./harness/start.sh          # Linux / macOS
```
```powershell
.\harness\start.ps1         # Windows
```

`start` detects your desktop VSCodium version/commit/arch, downloads the matching REH
release, builds and starts the container (verifying the REH commit matches your desktop),
installs the resolver into your desktop VSCodium, and then **writes the host config for you**:
it adds the resolver to `enable-proposed-api` in `argv.json` and writes the `contai.hosts`
entry (with the current token) into your `settings.json`. Your other settings and comments are
left intact. There is nothing to copy-paste.

**2. Restart VSCodium once.** `settings.json` is picked up live, but the `argv.json` change
(`enable-proposed-api`) only takes effect on a **full quit & reopen** — not "Reload Window".
Do this the first time and after any VSCodium update.

> Without `python3`, step 1 instead prints the `enable-proposed-api` line and the
> `contai.hosts` block (with your real token) for you to add to `argv.json` / `settings.json`
> manually.

**3. Connect.** Command Palette → **“contai: Connect to Container.”** The window reloads
into the container; the Claude Code sidebar is already installed inside. **Sign in once**
(web auth) — it persists in the `agent-home` volume, so you won't repeat it.

### Everyday use

```bash
docker compose up -d                       # start an already-built image (from repo root)
docker compose down                        # stop (keeps the volume + token)
docker compose down -v                     # stop and wipe the volume (token resets)
docker exec -it contai claude              # a plain CLI session, no IDE
```

- After `down -v`, just re-run `./harness/start.sh` — it refreshes the new token into
  `settings.json`, so the connection keeps working with no manual edits.
- Reconnect any time via the same *Connect to Container* command or the recent-remotes list.
- Drop repos into `dev/` — they appear at `/home/agent/dev` inside the container.
- The agent’s wiki work lives in `obsidian/{raw,templates,wiki}`; open `obsidian/` as an
  Obsidian vault on the host (its `.obsidian/` config stays yours and is never mounted).

### Keeping it in sync with VSCodium updates

When your desktop VSCodium updates, just re-run `./harness/start.sh`. It detects the new
commit, rebuilds **only** the small REH layer, re-verifies that the container’s server
matches your editor (mismatches fail the build on purpose), re-pins and reinstalls the
resolver, and re-ensures the host config. Fully quit & reopen VSCodium afterwards.

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
| `No remote extension installed to resolve contai-reh` | Resolver isn’t running locally. Ensure `extensionKind:["ui"]` in the installed manifest, `enable-proposed-api` is set, and VSCodium was **fully restarted** (not just “Reload Window”). |
| `curl 127.0.0.1:8000` returns **403** | Normal — the REH server is token-gated. |
| Need the token again | `docker exec contai cat /home/agent/.vscodium-server/connection-token` |
| Connect command missing | You’re already inside the remote window — there’s nothing left to connect to. |

---

## Русский

### Что это

`contai` держит **агента Claude Code в изолированном Docker-контейнере**, а управляете вы им
из **обычного десктопного VSCodium** — интерфейс тот же, что и у расширения Claude, только
сам агент сидит в контейнере, а не у вас в системе.

Десктопный редактор и контейнер связывает **самописный резолвер VSCodium без зависимостей** и
**официальный сервер VSCodium Remote Extension Host (REH)**, вшитый в образ. Никаких сторонних
расширений для удалёнки, никакого SSH — весь мост целиком лежит в этом репозитории, его можно
прочитать глазами. Так задумано: чтобы не тащить в систему чужой код, единственное удалённое
ПО, которому вы доверяете, — ваш собственный резолвер и та сборка VSCodium, что уже стоит на
машине.

Работа идёт по двум направлениям:

- **`obsidian/`** — хранилище Obsidian: агент читает исходники и пишет вики.
- **`dev/`** — репозитории, которые вы клонируете для работы агента.

### Как это устроено

```
   ┌─────────────────── ваша машина ────────────────────┐        ┌────── Docker: contai ──────┐
   │  Десктопный VSCodium                                │        │                             │
   │   └─ расширение-резолвер "Contained claude…"        │        │  codium-server (REH) :8000  │
   │        id: local.contai-resolver  (локально)        │  ⇆     │   └─ расширение Claude Code  │
   │        vscode-remote://contai-reh+contai/… ─────────┼─ ws ──▶│  /home/agent                │
   │                                                     │ токен  │   ├─ obsidian/{raw,tpl,wiki} │
   │  argv.json     → enable-proposed-api                │  127.  │   ├─ dev/                    │
   │  settings.json → contai.hosts (host, port, token)   │ 0.0.1  │   └─ CLAUDE.md (ro)          │
   └─────────────────────────────────────────────────────┘        └─────────────────────────────┘
```

1. **Сервер REH** берётся из **официального релиза VSCodium под вашу версию** и вшивается в
   образ. Коммит фиксируется и сверяется при сборке — корень доверия тот же, что и у редактора.
2. `start-reh.sh` — это **PID 1** контейнера: заводит постоянный токен, один раз ставит
   расширение Claude Code в том `agent-home` и поднимает `codium-server` на `0.0.0.0:8000`
   (наружу торчит только на `127.0.0.1`).
3. **Резолвер** на десктопе разбирает адрес `contai-reh+contai` в `localhost:8000` с токеном.
   У него стоит `extensionKind: ["ui"]` — иначе он уедет в контейнер, а работать должен на
   стороне десктопа.

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
    ├── start.sh / start.ps1          # одной командой: сборка + запуск + установка + настройка (Linux/macOS · Windows)
    ├── build-resolver.sh / .ps1      # упаковка VSIX резолвера только через zip (без инструментов MS/npm)
    ├── host-config.py                # идемпотентно правит argv.json и settings.json (только stdlib, без зависимостей)
    ├── start-reh.sh                  # PID 1 контейнера
    ├── CLAUDE.md                     # инструкции агенту, монтируются ro в /home/agent/CLAUDE.md
    ├── resolver/                     # тот самый резолвер (~60 строк, без зависимостей)
    └── reh/                          # скачанные архивы REH (в .gitignore)
```

### Что нужно

- **Docker** с плагином `docker compose`, запущенный.
- **Десктопный VSCodium**, команда `codium` в `PATH` (на macOS путь находится сам).
- **`zip`** в `PATH` — им пакуется VSIX резолвера.
- **`python3`** в `PATH` — им автоматически прописывается конфиг десктопа. Необязателен: без него
  `start` просто напечатает два фрагмента, чтобы вставить их руками.
- Идёт на **Linux, macOS и Windows** — `compose.yml` от ОС хоста не зависит.

### Первый запуск

**1. Запустите.** Из корня репозитория:

```bash
./harness/start.sh          # Linux / macOS
```
```powershell
.\harness\start.ps1         # Windows
```

`start` сам определит версию, коммит и архитектуру VSCodium, скачает нужный REH, соберёт и
поднимет контейнер (сверив коммит с десктопом), поставит резолвер в редактор и **сам пропишет
конфиг**: добавит резолвер в `enable-proposed-api` (`argv.json`) и запишет запись `contai.hosts`
с текущим токеном в ваш `settings.json`. Остальные настройки и комментарии не трогает. Вставлять
руками ничего не нужно.

**2. Перезапустите VSCodium один раз.** `settings.json` подхватывается на лету, а вот правка
`argv.json` (`enable-proposed-api`) применяется только при **полном закрытии и повторном запуске**
— не через «Reload Window». Сделайте это в первый раз и после каждого обновления VSCodium.

> Без `python3` шаг 1 вместо этого напечатает строку `enable-proposed-api` и блок
> `contai.hosts` (с настоящим токеном), чтобы вы сами добавили их в `argv.json` / `settings.json`.

**3. Подключитесь.** Command Palette → **«contai: Connect to Container».** Окно перезагрузится
уже внутри контейнера, расширение Claude Code там стоит. **Войдите один раз** (через браузер) —
сессия ляжет в том `agent-home`, больше вход не потребуется.

### Повседневно

```bash
docker compose up -d                       # запуск собранного образа (из корня репозитория)
docker compose down                        # остановка (том и токен сохраняются)
docker compose down -v                     # остановка со сносом тома (токен сбрасывается)
docker exec -it contai claude              # обычная CLI-сессия, без IDE
```

- После `down -v` просто прогоните `./harness/start.sh` — он впишет новый токен в `settings.json`,
  и подключение снова работает без ручной правки.
- Переподключение — той же командой *Connect to Container* или из списка недавних.
- Репозитории кидайте в `dev/` — внутри контейнера они окажутся в `/home/agent/dev`.
- Вики агент собирает в `obsidian/{raw,templates,wiki}`; на хосте открывайте `obsidian/` как
  хранилище Obsidian — его папка `.obsidian/` остаётся вашей и в контейнер не попадает.

### Обновление вслед за VSCodium

Обновился десктопный VSCodium — просто прогоните `./harness/start.sh` ещё раз. Он увидит новый
коммит, пересоберёт **только** слой REH, снова сверит сервер контейнера с редактором (не совпало —
сборка падает, так и задумано), перепакует и переустановит резолвер и заново пропишет конфиг.
После этого полностью закройте и откройте VSCodium.

### Переопределения

| Переменная         | Зачем                                            |
|--------------------|--------------------------------------------------|
| `VSCODIUM_VERSION` | Задать версию вручную, без автоопределения        |
| `CODIUM_BIN`       | Указать `codium`, которого нет в `PATH`           |
| `REH_PORT`         | Сменить локальный порт (по умолчанию `8000`)      |

### Про безопасность

- **Агент заперт** в контейнере (`no-new-privileges`, порт только на `127.0.0.1`).
- **Чужого удалённого кода нет**: REH — официальная сборка VSCodium под ваш десктоп (коммит
  зафиксирован и проверен), резолвер — полсотни строк без зависимостей, собран локально через
  `zip`. Ни SSH, ни ключей, ни похода в маркетплейс.
- Папка **`.obsidian/` не монтируется** — агенту до неё не дотянуться.
- **Вход через браузер**, токен лежит в томе `agent-home`, а не в репозитории.

### Если что-то не так

| Симптом | В чём дело |
|---|---|
| `No remote extension installed to resolve contai-reh` | Резолвер не поднялся локально. Проверьте `extensionKind:["ui"]` в установленном манифесте, что прописан `enable-proposed-api` и что VSCodium перезапущен **полностью**, а не через «Reload Window». |
| `curl 127.0.0.1:8000` отдаёт **403** | Так и должно быть — сервер закрыт токеном. |
| Опять нужен токен | `docker exec contai cat /home/agent/.vscodium-server/connection-token` |
| Команда подключения пропала из палитры | Вы уже внутри удалённого окна — подключаться больше не к чему. |

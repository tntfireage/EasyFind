[English](README.en.md) | **中文**

# EasyFind

macOS 菜单栏启动器：按一下快捷键，快速搜索并打开**网页地址、本机应用、目录或常用文件**。

浏览器会清空历史，EasyFind 不会。它把 Chrome/Chromium 系、Firefox、Safari 的历史按 host 聚合后存进自己的 SQLite，把打开的标签页存成完整 URL 书签，把已安装应用、最近访问过的目录，以及配置目录中的常用文件也纳入同一个搜索面板。网页档案只增不删；应用/目录/文件则反映当前机器状态。

- Bundle ID：`com.local.easyfind`（改名后保持不变，用于延续权限与登录项）
- 数据目录：`~/Library/Application Support/easyfind/`
- 当前 schema：`user_version = 4`

---

## 目录

- [系统概览](#系统概览)
- [功能一览](#功能一览)
- [安装与升级](#安装与升级)
- [配置文件](#配置文件)
- [使用方式](#使用方式)
- [数据来源与同步](#数据来源与同步)
- [数据模型](#数据模型)
- [搜索与排序](#搜索与排序)
- [按键与动作](#按键与动作)
- [权限](#权限)
- [隐私与安全](#隐私与安全)
- [已知限制](#已知限制)
- [授权](#授权)

---

## 系统概览

EasyFind 是一个常驻菜单栏的 `LSUIElement` 应用：没有 Dock 图标，面板只在用户按热键或点击菜单栏图标时出现。

```
┌────────────────────────────── EasyFind.app ──────────────────────────────┐
│                                                                          │
│  采集（后台，无界面）                          存储                 交互   │
│  ┌────────────────────┐                 ┌────────────────┐      ┌──────┐ │
│  │ Chrome History     │ 快照+按 host 聚合 │                │ 加载 │      │ │
│  │ 多 Profile         │────────────────▶│                │─────▶│ 搜索 │ │
│  ├────────────────────┤                 │  SQLite WAL    │      │ 面板 │ │
│  │ Chrome 打开的标签页 │ AppleScript      │  easyfind.db   │◀─────│      │ │
│  ├────────────────────┤                 │                │ 记录 │      │ │
│  │ 已安装 .app        │ 扫描 5 个目录     │  entries       │ 打开 │      │ │
│  ├────────────────────┤                 │  deep_links    │      │      │ │
│  │ Cursor/VS Code     │ state.vscdb      │  apps          │      │      │ │
│  │ Finder 最近文件夹   │ 书签解析          │  folders       │      └──┬───┘ │
│  │ zsh 绝对路径 cd     │ 历史文件          │  files         │         │     │
│  ├────────────────────┤                 │                │         │     │
│  │ 配置目录文件扫描    │ 后台队列遍历       │                │         │     │
│  │ 系统最近使用文件    │ Spotlight 元数据   │                │         │     │
│  └────────────────────┘                 └────────────────┘         │     │
│                                                                     ▼     │
│                                            默认浏览器 / 应用 / Finder /    │
│                                            iTerm2 / Terminal / 剪贴板      │
└──────────────────────────────────────────────────────────────────────────┘
```

关键设计：

- **采集与 UI 在同一进程**，但采集在后台队列，面板只读内存索引，不阻塞输入。
- **网页档案与磁盘语义不同**：网页只 upsert、永不删除；应用目录卸载即移除；目录/文件行保留但缺失路径不进入索引。
- **文件扫描在后台队列**：目录遍历不阻塞面板；搜索只读内存索引。
- **全路径去重**：目录以规范化真实路径为唯一键，跨来源合并。

---

## 功能一览

EasyFind 把“找东西并打开”收敛到一个面板，覆盖网页、应用、目录、文件和手动收藏五类目标。

### 网页档案

- 自动采集 Chrome/Chromium 系、Firefox、Safari 的历史，按 host 聚合：同一域名只有一条记录。
- 浏览器清空历史不会删除 EasyFind 的档案；访问次数只增不减。
- 每个 host 保留访问最多的 5 个完整页面作为深链，只在搜索中出现。
- 打开的 Chrome 标签页保存为完整 URL 书签；标签关掉后仍可找回。
- 手动添加 URL + 别名；空查询时置顶。

### 应用启动

- 扫描 5 个标准应用目录，按 bundle id 去重，`/Applications` 优先。
- 按名称或 bundle id 搜索，结果显示应用图标。
- 默认动作：Enter 启动，⌘Enter 在 Finder 中显示，⌥Enter 复制 bundle 路径。

### 目录跳转

- 来源：zsh 绝对路径 `cd`、Cursor/VS Code 最近项、Finder 最近文件夹。
- 唯一键是规范化全路径；符号链接、尾斜杠、大小写变体会合并为一条。
- 输入 `~` 只看目录；默认动作：Enter Finder，⌘Enter iTerm2/Terminal，⌥Enter 复制完整路径。

### 文件搜索

- 后台扫描 `config.json` 中 `files.directories` 配置的目录（默认桌面、文稿、下载），只索引文件名与路径，**不读取文件内容**。
- 合并系统“最近使用”文档（Spotlight 的 `kMDItemLastUsedDate`）与 EasyFind 内的打开次数，空查询时优先展示最常用的文件。
- 自动跳过隐藏文件、`.app` 等包、`node_modules`、`.build`、`Caches`、`Library` 等噪声目录，以及 `/System`、`/usr`、`/bin`、`/sbin`、`/Library`、`/Applications` 等系统位置；`/usr/local`、`/opt/homebrew` 例外。
- 输入 `@` 只看文件；默认动作：Enter 打开，⌘Enter 在 Finder 中显示，⌥Enter 复制完整路径。

### 搜索

- 统一匹配 host、标题、别名、URL 片段、应用名、bundle id、目录名、文件名和完整路径。
- 大小写不敏感；空格分隔的多个关键词按 AND 处理。
- 排序：精确匹配 → 前缀 → 子串 → 其他字段；同层按访问次数和时间。
- URL 路径做 percent-decode，`#锚点`参与，`?查询串`不参与。

### 交互与配置

- 全局热键（默认 ⌘G，可换 Space 组合）或菜单栏图标唤起；无 Dock 图标、不自动弹窗。
- `config.json` 配置热键、同步间隔与来源开关、各类结果 × 三种修饰键的动作、终端偏好和界面语言，支持热重载。
- 界面语言默认中文，可切换 English 或跟随系统。
- 菜单提供立即同步、添加地址、打开配置/数据目录、清除目录历史、清除文件索引、完全磁盘访问设置。
- 登录项自动注册；启动后后台同步。

### 本地与容错

- 采集和索引全部在本机完成，应用不发网络请求；数据库 `0600`、目录 `0700`。
- 浏览器缺失、锁定或无权限时只跳过该来源；Safari 无完全磁盘访问时给一次性引导。
- 文件扫描在后台同步队列执行，受 `files.maxFiles` 上限保护；桌面/文稿/下载首次访问时由 macOS 请求“文件与文件夹”权限。
- 网页档案只增不删；应用、目录和文件反映当前机器状态。

---

## 安装与升级

```bash
./install.sh                  # 选语言 → 配置 → 构建 → 安装 → 启动
./install.sh --no-launch      # 只安装（仍会询问配置）
./install.sh --dir ~/Apps     # 安装到指定目录
./install.sh --yes            # 非交互：保留现有配置或写入默认配置
./install.sh --reconfigure    # 强制重新询问配置
./install.sh --check          # 只检查构建依赖，不安装
./install.sh --uninstall      # 卸载（数据保留）
```

也可以使用：

```bash
make build      # 生成 EasyFind.app（ad-hoc 签名）
make run        # 开发用：启动仓库目录里的副本
make install    # 等同于 ./install.sh
make uninstall
```

安装脚本会先让你选择界面语言（中文 / English / Auto），之后的配置提示、确认和结果都使用该语言；然后询问热键、同步来源与间隔（含常用文件搜索）、终端偏好。已有配置默认保留，也可以选择重新配置；写入时会保留 `actions`、`files` 和未知键。

### 依赖

| 依赖 | 说明 |
|---|---|
| macOS 13+ | 系统要求 |
| Xcode Command Line Tools | 提供 `swift`、`make`、`xcrun`、`codesign`、`plutil`、`python3`；缺失时安装脚本会询问是否运行 `xcode-select --install` |
| SQLite | macOS 自带 `libsqlite3`，**不需要**额外安装或 Homebrew |
| python3 | CLT 自带；用于合并 `config.json`，缺失时回退为只写新文件 |
| iTerm2 | 可选；未安装时 ⌘Enter 回退 Terminal |

安装前可运行 `./install.sh --check` 只检查依赖，不做任何修改。

说明：

- 安装脚本会先退出旧实例（兼容旧名 `easyfind`），复制 app、去除 quarantine 属性并校验签名。
- `/Applications` 不可写时自动回退到 `~/Applications`。
- 正式使用请走 `install.sh`，避免仓库副本和 `/Applications` 副本同时存在，导致登录项或自动化授权指向错误的那一份。
- 每次重建都会产生新的 ad-hoc 签名，macOS 可能重新询问自动化权限，允许即可。

登录项通过 `SMAppService.mainApp` 注册；建议把 app 放在 `/Applications` 再启动。

---

## 配置文件

`~/Library/Application Support/easyfind/config.json`，首次启动时自动生成，权限 `0600`。仓库里的 `config.example.json` 是同一份默认值的参考。

> 配置只接受固定的键名和动作词表，**不能写入 shell 命令**。

### 完整示例

```json
{
  "actions": {
    "app": { "enter": "open", "commandEnter": "finder", "optionEnter": "copy" },
    "file": { "enter": "open", "commandEnter": "finder", "optionEnter": "copy" },
    "folder": { "enter": "open", "commandEnter": "terminal", "optionEnter": "copy" },
    "web": { "enter": "open", "commandEnter": "copy", "optionEnter": "copy" }
  },
  "files": {
    "directories": ["~/Desktop", "~/Documents", "~/Downloads"],
    "maxFiles": 20000
  },
  "hotkey": { "key": "g", "modifiers": ["command"] },
  "language": "zh",
  "sync": {
    "apps": true,
    "chromeHistory": true,
    "chromeTabs": true,
    "files": true,
    "folders": true,
    "intervalMinutes": 10
  },
  "terminal": { "application": "auto" }
}
```

### language

| 值 | 行为 |
|---|---|
| `zh`（默认） | 中文 |
| `en` | English |
| `auto` | 跟随系统首选语言：`zh*` → 中文，其他 → English |

### 切换语言

- 菜单栏 → **语言** → 自动 / 中文 / English：立即生效，并写回 `config.json`。
- 或修改 `config.json` 的 `language`，再点“重新加载配置”。
- 默认中文；`auto` 跟随系统首选语言；无法识别的值回退中文。

### hotkey

| 字段 | 说明 |
|---|---|
| `key` | `a`–`z`、`0`–`9`、`space`、`return`、`tab`、`escape`，以及常见标点 |
| `modifiers` | `command` / `option` / `control` / `shift`，可组合；为空时回退为 `command` |

无法映射的键名会回退到 **⌘G** 并写日志。菜单栏的“快捷键”子菜单会直接改写这里的值。

### sync

| 字段 | 说明 |
|---|---|
| `intervalMinutes` | 同步间隔，1–1440 分钟 |
| `chromeHistory` | 浏览器历史总开关（所有已发现浏览器） |
| `chromeTabs` | Chrome 标签页 |
| `apps` | 已安装应用 |
| `folders` | 目录历史 |
| `files` | 常用文件索引（扫描 `files.directories` + 系统最近使用） |

关闭某个来源不会删除已有数据，只是不再刷新。

### files

| 字段 | 说明 |
|---|---|
| `directories` | 要索引的目录，支持 `~`；默认 `~/Desktop`、`~/Documents`、`~/Downloads` |
| `maxFiles` | 单轮索引的文件上限，100–200000，默认 20000 |

系统位置（`/System`、`/usr`、`/bin`、`/sbin`、`/Library`、`/Applications` 等）不会被索引；`/usr/local` 与 `/opt/homebrew` 例外。隐藏文件、`.app` 包和 `node_modules`/`.build` 等噪声目录会自动跳过。只保存文件名与路径，不读取文件内容。

### actions

每种结果类型有三个动作位：

| 键 | 触发 |
|---|---|
| `enter` | 回车 / 单击 |
| `commandEnter` | ⌘Enter |
| `optionEnter` | ⌥Enter |

动作词表：

| 动作 | 网页 | 应用 | 目录 | 文件 |
|---|---|---|---|---|
| `open` | 默认浏览器 | 启动 | Finder | 默认应用打开 |
| `copy` | 复制 URL | 复制 bundle 路径 | 复制完整路径 | 复制完整路径 |
| `terminal` | 回退 `open` | 回退 `open` | iTerm2 / Terminal 打开 | 在父目录打开终端 |
| `finder` | 回退 `open` | 在 Finder 中显示 | Finder | 在 Finder 中显示 |

未知动作或不支持的动作组合一律回退到 `open`。

### terminal

| 值 | 行为 |
|---|---|
| `auto` | 有 iTerm2 就用 iTerm2，否则 Terminal |
| `iterm2` | 始终尝试 iTerm2，失败回退 Terminal |
| `terminal` | 始终使用 Terminal |

### 合并与重载

- 文件可以只写一部分，缺失字段使用默认值；未知键忽略。
- JSON 语法错误或类型错误 → 使用默认配置，**不会覆盖你的文件**。
- 修改后：菜单栏 → “重新加载配置”，或者下次打开面板时自动检测文件变化并重载。
- 热键、动作、终端偏好立即生效；同步开关从下一轮同步起生效；间隔变化会重排定时器。
- `EASYFIND_SYNC_INTERVAL` 环境变量仍可覆盖同步间隔，仅用于调试。

## 使用方式

- 按 **⌘G** 或左键点击菜单栏图标打开面板；`Esc`、失焦、再次触发都会关闭。
- 右键菜单栏图标可打开设置菜单：

| 菜单项 | 作用 |
|---|---|
| 打开 EasyFind | 显示面板 |
| 添加地址… | 保存 URL + 别名 |
| 立即同步 | 立刻执行一轮采集 |
| 快捷键 | ⌘G / ⌥Space / ⌃Space / ⌘⌥Space |
| 打开数据目录 | 在 Finder 中打开数据库所在目录 |
| 打开配置文件 | 用默认编辑器打开 `config.json` |
| 重新加载配置 | 立即应用配置修改 |
| 完全磁盘访问设置 | 打开 Safari 历史所需的权限面板 |
| 清除目录历史 | 只删除 EasyFind 的目录索引 |
| 清除文件索引 | 只删除文件索引与打开次数，不删除文件 |
| 退出 | 退出应用 |

### 空查询

手动添加的条目在前，随后是最常用的文件（最多 8 个），再后是历史 host（按访问次数降序）。应用、书签、深链只在搜索中出现；目录在搜索或 `~` 模式下出现，文件在搜索或 `@` 模式下出现。

### 搜索语法

- 大小写不敏感；多个关键词按 **AND** 匹配。
- 网页：匹配 host、标题、别名、URL 路径与 `#锚点`；`?查询串` 不参与（多为跟踪参数）。
- 应用：匹配显示名与 bundle id。
- 目录：匹配目录名与**完整路径**。
- 文件：匹配文件名与**完整路径**。
- `~` 开头进入目录模式：只输入 `~` 列出最近目录，`~mytools` 继续过滤。
- `@` 开头进入文件模式：只输入 `@` 按常用程度列出文件，`@report` 继续过滤。

### 结果动作

以下是**默认配置**下的动作，全部可通过 `config.json` 的 `actions` 修改：

| 结果类型 | `Enter` | `⌘Enter` | `⌥Enter` |
|---|---|---|---|
| 网页 / 标签页 / 手动地址 | 默认浏览器打开 | 复制 URL | 复制 URL |
| 应用 | 启动应用 | 在 Finder 中显示 | 复制 bundle 路径 |
| 目录 | Finder 打开 | iTerm2 新窗口并 `cd`（未安装/失败时回退 Terminal） | 复制完整路径 |
| 文件 | 默认应用打开 | 在 Finder 中显示 | 复制完整路径 |

`↑`/`↓` 选择，`Enter` 或单击激活，`Esc` 关闭。

---

## 数据来源与同步

启动时同步一次，之后每 10 分钟一次（开发可用 `EASYFIND_SYNC_INTERVAL` 覆盖）。

| 来源 | 读取方式 | 频率 | 权限 | 存什么 |
|---|---|---|---|---|
| 浏览器历史（Chromium 系） | 快照 `History` + `-wal` + `-shm` | 每轮，文件变化才重读 | 无 | 按 host 聚合：origin、标题、访问次数、Top-5 深链 |
| 浏览器历史（Firefox 系） | 快照 `places.sqlite` + WAL | 每轮，文件变化才重读 | 无 | 同上 |
| 浏览器历史（Safari） | 快照 `History.db` + WAL | 每轮 | **完全磁盘访问** | 同上 |
| Chrome 标签页 | AppleScript 读取窗口/标签标题与 URL | 每轮，Chrome 未运行则跳过 | 自动化 | 完整 URL + 标题 |
| 已安装应用 | 扫描 5 个标准目录，读 bundle 元数据 | 每轮 | 无 | 名称、bundle id、路径、启动次数 |
| 目录历史 | Cursor/VS Code `state.vscdb`、Finder `FXRecentFolders`、zsh 历史 | 每轮 | 无 | 规范化全路径、来源、次数 |
| 常用文件（扫描） | 后台队列遍历 `files.directories` | 每轮 | **文件与文件夹**（首次访问桌面/文稿/下载时弹窗） | 规范化路径、名称、修改时间 |
| 系统最近使用文件 | Spotlight `kMDItemLastUsedDate` | 每轮 | **文件与文件夹** | 最近使用时间 |
| 手动条目 | 应用内添加 | 即时 | 无 | URL + 别名 |

细节：

- **浏览器历史**：自动发现 Chromium 系（Chrome、Chrome Beta/Canary、Chromium、Brave、Edge、Vivaldi、Opera、Arc、Sidekick）、Firefox 系（Firefox、Developer Edition、Nightly、Zen、LibreWolf）和 Safari / Safari Technology Preview。`immutable=1` 会丢 WAL 中的最近记录，因此先复制数据库三件套再读；多 Profile 合并，访问次数求和后与已有值取 `MAX`。
- **时间纪元**：Chromium 是 1601 年起的微秒，Firefox 是 Unix 微秒，Safari 是 2001 年起的秒，均已转换为 Unix 秒。
- **Safari 权限**：读取 `~/Library/Safari/History.db` 需要完全磁盘访问；未授权时跳过 Safari，其他浏览器继续，并出现一次性引导。
- **标签页**：Chrome 未运行时不会启动它；两次采集之间关闭的标签不会进入档案。
- **应用**：`/Applications`、`/Applications/Utilities`、`/System/Applications`、`/System/Applications/Utilities`、`~/Applications` 的顶层 `.app`；按 bundle id 去重，`/Applications` 优先；嵌套 helper 不扫描。
- **目录**：只收绝对路径和 `~` 路径的 `cd`（相对路径无法还原当时 cwd）；编辑器取 `folderUri` 与 `fileUri` 的父目录；Finder 解析书签；包（`.app`、`.cannedSearch` 等）排除。
- **目录去重**：符号链接解析 + 标准化 + 去尾部 `/`，唯一键为小写全路径；跨来源合并次数/时间/来源标签。
- **文件**：只扫描 `files.directories` 中存在的目录；每轮最多 `files.maxFiles` 个文件；隐藏文件、包、符号链接和噪声目录跳过；系统位置不索引（`/usr/local`、`/opt/homebrew` 例外）。系统“最近使用”通过 Spotlight 按目录范围查询，与扫描结果按规范化路径合并，`last_seen` 取较新值。文件缺失时在读取快照阶段过滤，打开次数保留。

---

## 数据模型

```
~/Library/Application Support/easyfind/easyfind.db
```

- 目录 `0700`，数据库 `0600`，SQLite WAL。
- schema 通过 `PRAGMA user_version` 迁移；当前为 4（v1 网页、v2 应用、v3 目录、v4 文件）。

### `entries`

网页档案（`history` / `bookmark` / `manual`）：

| 列 | 说明 |
|---|---|
| `kind` | `history` / `bookmark` / `manual` |
| `host` | 展示与历史去重键 |
| `origin` | `scheme://host[:port]`，历史条目的打开目标 |
| `url` | 完整 URL（标签页/手动） |
| `title` / `alias` | 标题 / 用户别名 |
| `visits` | 浏览器观测访问次数，只增不减 |
| `own_opens` | 通过 EasyFind 打开的次数 |
| `last_seen` | 最近访问（Unix 秒） |

唯一性：

- `UNIQUE(host) WHERE kind='history'`
- `UNIQUE(url) WHERE kind IN ('bookmark','manual')`

### `deep_links`

每个 host 访问最多的 5 个完整页面，只参与搜索，不出现在空查询列表。

### `apps`

| 列 | 说明 |
|---|---|
| `bundle_id` / `name` / `path` | 应用标识与元数据 |
| `own_opens` | 通过 EasyFind 启动的次数 |

`path` 唯一，`bundle_id` 在非空时唯一。刷新会移除已卸载应用，保留仍存在应用的启动次数。

### `folders`

| 列 | 说明 |
|---|---|
| `path_key` | 小写规范化全路径，去重键 |
| `path` | 规范化完整路径（展示/打开） |
| `name` | 目录名 |
| `visits` | 来源观测次数 |
| `own_opens` | 通过 EasyFind 打开的次数 |
| `last_seen` | 最近出现时间 |
| `sources` | `shell,cursor,code,finder` 的组合 |

`path_key` 与 `path` 均唯一。缺失目录不进入索引但保留行，卷重新挂载后可再次出现。

### `files`

| 列 | 说明 |
|---|---|
| `path_key` | 小写规范化全路径，去重键 |
| `path` | 规范化完整路径（展示/打开） |
| `name` | 文件名 |
| `visits` | 来源观测次数（当前为 0，保留字段） |
| `own_opens` | 通过 EasyFind 打开的次数 |
| `last_seen` | 最近使用时间（系统最近使用优先，其次文件修改时间） |
| `sources` | `scan,recent` 的组合 |

`path_key` 与 `path` 均唯一。缺失文件在读取快照时过滤，行与打开次数保留。

---

## 搜索与排序

1. 查询按空白拆分为 token；每个 token 必须命中该条目的 haystack。
2. haystack：

| 类型 | haystack |
|---|---|
| 历史 host | `host + title + alias` |
| 标签页/手动 | `host + 解码后的路径与 #锚点 + title + alias` |
| 深链 | `host + 路径与 #锚点 + title` |
| 应用 | `name + bundle id` |
| 目录 | `name + 完整路径` |
| 文件 | `name + 完整路径` |

3. 排序层级：精确匹配 → 前缀 → 子串 → 其他字段；同层级按 `visits`、`last_seen`、路径字典序。
4. 空查询不参与上述搜索，直接返回“手动条目 + 最常用文件（最多 8 个）+ 历史”。
5. `~` 模式只在目录集合内搜索；`~` 后为空时按访问次数/时间列出最近目录。
6. `@` 模式只在文件集合内搜索；`@` 后为空时按打开次数/最近使用列出文件。

---

## 按键与动作

| 按键 | 行为 |
|---|---|
| `⌘G`（可改） | 唤起/隐藏面板 |
| `↑` / `↓` | 移动选中项 |
| `Enter` | 执行 `actions.<kind>.enter`（默认：网页→浏览器、应用→启动、目录→Finder、文件→默认应用） |
| `⌘Enter` | 执行 `actions.<kind>.commandEnter`（默认：目录→iTerm2、应用/文件→Finder 中显示、网页→复制 URL） |
| `⌥Enter` | 执行 `actions.<kind>.optionEnter`（默认：全部复制 URL/路径） |
| `Esc` | 关闭面板 |

以上为默认配置，可在 `config.json` 的 `actions` 中修改。

带修饰键的回车由面板的本地 `keyDown` 监视器在输入框之前拦截；中文输入法组字时会放行，让输入法先提交。

> 默认热键 ⌘G 会在 Chrome、VS Code、Xcode 等应用里覆盖“查找下一个”。可在菜单里换成 Space 组合。

---

## 权限

| 能力 | 权限 | 说明 |
|---|---|---|
| 读取 Chrome / Chromium / Firefox 历史 | 无 | 普通文件读取 |
| 读取 Safari 历史 | 完全磁盘访问 | 系统设置中手动添加 EasyFind，添加后重启 |
| 读取 Chrome 标签页 | 自动化 | 首次弹窗 |
| 在 iTerm2 中打开目录 | 自动化 | 首次弹窗；拒绝则回退 Terminal |
| 扫描桌面/文稿/下载等配置目录 | 文件与文件夹 | 首次访问时弹窗；拒绝后该目录为空，可在系统设置中重新授权 |
| 登录项 | `SMAppService` | 系统设置 → 通用 → 登录项 |

如果拒绝自动化权限：

- 历史、应用、目录、网页搜索都继续工作；
- 标签页采集跳过，并出现一次性提示；
- iTerm2 动作回退到 Terminal。

授权位置：系统设置 → 隐私与安全性 → 自动化 → EasyFind。

Safari 历史未授权时会被跳过，其他浏览器继续同步；菜单栏 → “完全磁盘访问设置”可打开对应面板。

---

## 隐私与安全

- 所有数据仅保存在本机 `~/Library/Application Support/easyfind/`，目录 `0700`、数据库 `0600`。
- 应用不发起任何网络请求；`lsof -a -p <pid> -i` 为空。
- 命令历史**不采集**；目录历史只存路径；文件索引只存文件名、路径与使用时间，**不读取文件内容**。
- 网页档案的“只增不删”是刻意设计：浏览器清空后仍可恢复。若需要彻底删除，退出应用后删除数据目录。
- 目录路径和文件名可能包含敏感项目名，仍仅存储在本地；可用菜单“清除目录历史”“清除文件索引”。

---

## 已知限制

- 浏览器历史支持 Chromium 系（Chrome、Chrome Beta/Canary、Chromium、Brave、Edge、Vivaldi、Opera、Arc、Sidekick）、Firefox 系和 Safari；Safari 需要完全磁盘访问。
- 标签页采集仍然只支持 Chrome。
- 历史只保留 host；URL 片段搜索覆盖标签页、手动条目和每 host 的 Top-5 深链。
- 标签页每 10 分钟采一次，两次采集之间关闭的标签不会进入档案。
- 应用只扫描 5 个目录的顶层 `.app`；应用只参与搜索，不出现在空查询列表。
- 相对路径 `cd` 无法还原；目录历史只收绝对路径和 `~` 路径；包会被排除。
- 目录来源目前是 Cursor、VS Code、Finder 和 zsh。
- 文件搜索只覆盖配置目录，不做整盘全文检索；系统位置不索引；默认最多 20000 个文件。
- 系统“最近使用”依赖 Spotlight 元数据；Spotlight 关闭或未索引的目录只能按文件修改时间排序。
- 未公证、ad-hoc 签名，仅建议本机自用。

---

## 授权

本项目采用 [Apache License 2.0](LICENSE.en.md)。

- 中文说明与官方英文原文：[LICENSE.md](LICENSE.md)
- 权威英文原文：[LICENSE.en.md](LICENSE.en.md)

Copyright 2026 The EasyFind Authors

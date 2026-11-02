**English** | [中文](README.md)

# EasyFind

A macOS menu-bar launcher: one hotkey to search and open **web addresses, local applications, folders, or frequently used files**.

Browsers clear their history; EasyFind doesn't. It aggregates the history of Chrome/Chromium-family browsers, Firefox, and Safari by host into its own SQLite database, saves open tabs as full-URL bookmarks, and adds installed applications, recently visited folders, and frequently used files from configured directories to the same search panel. The web archive is append-only; the app, folder, and file catalogs reflect the current machine state.

- Bundle ID: `com.local.easyfind` (kept after the rename to preserve permissions and the login item)
- Data directory: `~/Library/Application Support/easyfind/`
- Current schema: `user_version = 4`

---

## Contents

- [Overview](#overview)
- [Features](#features)
- [Installation and upgrades](#installation-and-upgrades)
- [Configuration](#configuration)
- [Usage](#usage)
- [Data sources and sync](#data-sources-and-sync)
- [Data model](#data-model)
- [Search and ranking](#search-and-ranking)
- [Keys and actions](#keys-and-actions)
- [Permissions](#permissions)
- [Privacy and security](#privacy-and-security)
- [Known limitations](#known-limitations)
- [License](#license)

---

## Overview

EasyFind is an `LSUIElement` menu-bar app: it has no Dock icon, and the panel appears only when you press the hotkey or click the menu-bar icon.

```
┌────────────────────────────── EasyFind.app ──────────────────────────────┐
│                                                                          │
│  Collection (background, no UI)          Storage              Interaction │
│  ┌────────────────────┐             ┌────────────────┐    ┌────────────┐ │
│  │ Browser history    │ snapshot +  │                │load│   Panel    │ │
│  │ Chromium/Firefox/  │ host agg.   │  SQLite WAL    │───▶│   search   │ │
│  │ Safari             │────────────▶│  easyfind.db   │    │  ↑/↓/Enter │ │
│  ├────────────────────┤             │  entries       │◀───│            │ │
│  │ Chrome open tabs   │ AppleScript │  deep_links    │    └─────┬──────┘ │
│  ├────────────────────┤             │  apps          │          │        │
│  │ Installed apps     │ scan roots  │  folders       │          ▼        │
│  │                    │             │  files         │  browser / app /  │
│  ├────────────────────┤             └────────────────┘  Finder / iTerm2 / │
│  │ Cursor/VS Code,    │ state.vscdb,                   Terminal /        │
│  │ Finder, zsh cd     │ bookmarks                      clipboard         │
│  ├────────────────────┤                                                  │
│  │ Configured folders │ background walk                                  │
│  │ Recent documents   │ Spotlight metadata                               │
│  └────────────────────┘                                                  │
└──────────────────────────────────────────────────────────────────────────┘
```

Key design points:

- **Collection and UI share one process**, but collection runs on a background queue; the panel reads an in-memory index and never blocks typing.
- **The web archive and the catalogs have different semantics**: web entries are upsert-only and never deleted; apps are removed when uninstalled; folder/file rows are kept but missing paths are filtered out of the index.
- **Full-path deduplication**: folders and files are keyed by a canonical real path and merged across sources.
- **File scanning stays off the UI thread**: directory walking runs on the background sync queue; search reads the in-memory index.

---

## Features

EasyFind turns "find it and open it" into one panel covering five kinds of targets: web pages, applications, folders, files, and manual bookmarks.

### Web archive

- Automatically collects history from Chromium-family browsers, Firefox, and Safari, aggregated by host: one row per domain.
- Clearing browser history never deletes EasyFind's archive; visit counts only grow.
- Each host keeps its five most-visited full pages as deep links, searchable only.
- Open Chrome tabs are saved as full-URL bookmarks and survive tab closure.
- Save any URL with an alias; manual entries are pinned in the empty-query list.

### Applications

- Scans five standard application roots, deduplicated by bundle ID with `/Applications` preferred.
- Search by name or bundle ID; results show the app icon.
- Default actions: Enter launches, ⌘Enter reveals in Finder, ⌥Enter copies the bundle path.

### Folders

- Sources: absolute `cd` commands in zsh, Cursor/VS Code recents, and Finder recent folders.
- The key is the canonical full path; symlinks, trailing slashes, and case variants merge into one row.
- Type `~` for folder-only results; default actions: Enter opens Finder, ⌘Enter opens iTerm2/Terminal, ⌥Enter copies the full path.

### Files

- Scans the directories configured in `files.directories` (Desktop, Documents, and Downloads by default) on a background queue and indexes file names and paths only; file contents are never read.
- Merges the system's recently used documents (Spotlight `kMDItemLastUsedDate`) with EasyFind open counts, so the most-used files appear first in the empty-query list.
- Skips hidden files, packages such as `.app`, noise directories (`node_modules`, `.build`, `Caches`, `Library`), and system locations (`/System`, `/usr`, `/bin`, `/sbin`, `/Library`, `/Applications`); `/usr/local` and `/opt/homebrew` are exempt.
- Type `@` for file-only results; default actions: Enter opens, ⌘Enter reveals in Finder, ⌥Enter copies the full path.

### Search

- Matches host, title, alias, URL fragment, app name, bundle ID, folder name, file name, and full path in one list.
- Case-insensitive; whitespace-separated tokens are ANDed.
- Ranking: exact → prefix → substring → other fields; ties by visits and recency.
- URL paths are percent-decoded; `#fragments` match, `?query` strings do not.

### Interaction and configuration

- Summon with a global hotkey (⌘G by default, Space combos available) or the menu-bar icon; no Dock icon, no spontaneous panel.
- `config.json` controls the hotkey, sync interval and source switches, all result types × three modifiers, terminal preference, and UI language, with hot reload.
- UI language defaults to Chinese; switch to English or follow the system in the config.
- The menu offers sync now, add address, open config/data folder, clear folder history, clear file index, and Full Disk Access settings.
- The login item is registered automatically; collection runs in the background after launch.

### Local-first and failure isolation

- All collection and indexing happen on-device; the app makes no network requests. Database `0600`, directory `0700`.
- A missing, locked, or unauthorized browser is skipped on its own; Safari gets a one-time Full Disk Access guide.
- File scanning runs on the background sync queue and is bounded by `files.maxFiles`; macOS asks for Files and Folders access the first time Desktop/Documents/Downloads are read.
- The web archive is append-only; apps, folders, and files reflect the current machine state.

---

## Installation and upgrades

```bash
./install.sh                  # choose language → configure → build → install → launch
./install.sh --no-launch      # install only (still prompts)
./install.sh --dir ~/Apps     # install into a custom directory
./install.sh --yes            # non-interactive: keep existing config or write defaults
./install.sh --reconfigure    # force the configuration questions
./install.sh --check          # check build dependencies only; no install
./install.sh --uninstall      # uninstall (data is kept)
```

You can also use:

```bash
make build      # produce EasyFind.app (ad-hoc signed)
make run        # development: launch the copy inside the repository
make install    # same as ./install.sh
make uninstall
```

The installer asks for the UI language first (中文 / English / Auto); every later prompt, confirmation, and message uses that language. It then asks for the hotkey, sync sources and interval (including frequent-file search), and terminal preference. An existing config is kept by default or can be reconfigured; `actions`, `files`, and unknown keys are preserved when writing.

### Dependencies

| Dependency | Notes |
|---|---|
| macOS 13+ | Required |
| Xcode Command Line Tools | Provides `swift`, `make`, `xcrun`, `codesign`, `plutil`, and `python3`; if missing, the installer offers `xcode-select --install` |
| SQLite | macOS ships `libsqlite3`; **no** extra install or Homebrew needed |
| python3 | Bundled with CLT; used to merge `config.json`; falls back to writing a new file only |
| iTerm2 | Optional; without it Command-Enter falls back to Terminal |

Run `./install.sh --check` first to inspect dependencies without changing anything.

Notes:

- The installer quits any running instance (including the legacy `easyfind` name), copies the app, removes the quarantine attribute, and verifies the signature.
- If `/Applications` is not writable it falls back to `~/Applications`.
- Prefer `install.sh` over running the repository copy, so the login item and Automation grants point at one app.
- Every rebuild changes the ad-hoc signature, so macOS may ask for Automation permission again. Approve it.

The login item is registered through `SMAppService.mainApp`; keep the app in `/Applications` before launching.

---

## Configuration

`~/Library/Application Support/easyfind/config.json` is created on first launch with mode `0600`. `config.example.json` in the repository contains the same defaults.

> Configuration accepts only fixed keys and a fixed action vocabulary. It **cannot inject shell commands**.

### Full example

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

| Value | Behavior |
|---|---|
| `zh` (default) | Chinese |
| `en` | English |
| `auto` | follow the system preferred language (`zh*` → Chinese, otherwise English) |

### Switching language

- Menu bar → **Language** → Auto / 中文 / English: applies immediately and writes `config.json`.
- Or edit `language` in `config.json` and choose "Reload Configuration".
- Defaults to Chinese; `auto` follows the system preferred language; unknown values fall back to Chinese.

### hotkey

| Field | Description |
|---|---|
| `key` | `a`–`z`, `0`–`9`, `space`, `return`, `tab`, `escape`, and common punctuation |
| `modifiers` | `command` / `option` / `control` / `shift`; combinable; empty falls back to `command` |

An unmappable key falls back to **⌘G** and is logged. The menu-bar "Hotkey" submenu writes these values directly.

### sync

| Field | Description |
|---|---|
| `intervalMinutes` | Sync interval, 1–1440 minutes |
| `chromeHistory` | Master switch for browser history (all discovered browsers) |
| `chromeTabs` | Chrome tabs |
| `apps` | Installed applications |
| `folders` | Folder history |
| `files` | File index (scans `files.directories` plus system recents) |

Disabling a source does not delete existing data; it only stops refreshing it.

### files

| Field | Description |
|---|---|
| `directories` | Directories to index; `~` is expanded. Defaults to `~/Desktop`, `~/Documents`, `~/Downloads` |
| `maxFiles` | Per-sync file cap, 100–200000, default 20000 |

System locations (`/System`, `/usr`, `/bin`, `/sbin`, `/Library`, `/Applications`, and similar) are never indexed; `/usr/local` and `/opt/homebrew` are exempt. Hidden files, `.app` packages, and noise directories such as `node_modules`/`.build` are skipped. Only file names and paths are stored; contents are never read.

### actions

Each result type has three action slots:

| Key | Trigger |
|---|---|
| `enter` | Return / click |
| `commandEnter` | ⌘Enter |
| `optionEnter` | ⌥Enter |

Action vocabulary:

| Action | Web | App | Folder | File |
|---|---|---|---|---|
| `open` | default browser | launch | Finder | open with default app |
| `copy` | copy URL | copy bundle path | copy full path | copy full path |
| `terminal` | fall back to `open` | fall back to `open` | open in iTerm2 / Terminal | open terminal at parent folder |
| `finder` | fall back to `open` | reveal in Finder | Finder | reveal in Finder |

Unknown actions and unsupported combinations fall back to `open`.

### terminal

| Value | Behavior |
|---|---|
| `auto` | use iTerm2 when installed, otherwise Terminal |
| `iterm2` | always try iTerm2, fall back to Terminal |
| `terminal` | always use Terminal |

### Merging and reloading

- A partial file is allowed; missing fields use defaults and unknown keys are ignored.
- Invalid JSON or invalid types fall back to defaults and **never overwrite your file**.
- After editing: menu bar → "Reload Configuration", or simply show the panel again and EasyFind will detect the changed file.
- Hotkey, actions, and terminal preference apply immediately; sync switches apply from the next sync; interval changes reschedule the timer.
- `EASYFIND_SYNC_INTERVAL` still overrides the interval for debugging.

---

## Usage

- Press **⌘G** or left-click the menu-bar icon to show the panel; `Esc`, losing focus, or triggering it again closes it.
- Right-click the menu-bar icon for the settings menu. Menu labels are Chinese in the current build; the English names below describe them.

| Menu item | Effect |
|---|---|
| Open EasyFind | Show the panel |
| Add Address… | Save a URL + alias |
| Sync Now | Run a collection immediately |
| Hotkey | ⌘G / ⌥Space / ⌃Space / ⌘⌥Space |
| Open Data Folder | Open the database folder in Finder |
| Open Config File | Open `config.json` in the default editor |
| Reload Configuration | Apply configuration changes immediately |
| Full Disk Access Settings | Open the privacy pane required for Safari history |
| Clear Folder History | Remove only EasyFind's folder index |
| Clear File Index | Remove only the file index and open counts; no files are deleted |
| Quit | Quit the app |

### Empty query

Manually saved entries come first, followed by the most-used files (up to 8), then history hosts ordered by visit count. Applications, bookmarks, and deep links appear only in search results; folders appear in search or `~` mode, files in search or `@` mode.

### Search syntax

- Case-insensitive; multiple tokens are combined with **AND**.
- Web: matches host, title, alias, URL path, and `#fragment`; the `?query` string is excluded (usually tracking noise).
- Applications: matches display name and bundle ID.
- Folders: matches folder name and **full path**.
- Files: matches file name and **full path**.
- A leading `~` switches to folder mode: `~` alone lists recent folders, `~mytools` filters further.
- A leading `@` switches to file mode: `@` alone lists files by usage, `@report` filters further.

### Result actions

These are the **default** actions; all of them are configurable in `config.json` under `actions`:

| Result type | `Enter` | `⌘Enter` | `⌥Enter` |
|---|---|---|---|
| Web / tab / manual address | open in default browser | copy URL | copy URL |
| Application | launch | reveal in Finder | copy bundle path |
| Folder | open in Finder | iTerm2 window with `cd` (Terminal fallback) | copy full path |
| File | open with default app | reveal in Finder | copy full path |

`↑`/`↓` to select, `Enter` or click to activate, `Esc` to close.

---

## Data sources and sync

One sync runs at launch, then every 10 minutes (development builds can override this with `EASYFIND_SYNC_INTERVAL`).

| Source | How it is read | Frequency | Permission | Stored |
|---|---|---|---|---|
| Browser history (Chromium family) | snapshot `History` + `-wal` + `-shm` | every cycle, re-read only when changed | none | host-level: origin, title, visits, Top-5 deep links |
| Browser history (Firefox family) | snapshot `places.sqlite` + WAL | every cycle, re-read only when changed | none | same |
| Browser history (Safari) | snapshot `History.db` + WAL | every cycle | **Full Disk Access** | same |
| Chrome tabs | AppleScript reads window/tab titles and URLs | every cycle, skipped when Chrome isn't running | Automation | full URL + title |
| Installed apps | scans 5 standard roots, reads bundle metadata | every cycle | none | name, bundle ID, path, launch count |
| Folder history | Cursor/VS Code `state.vscdb`, Finder `FXRecentFolders`, zsh history | every cycle | none | canonical full path, sources, count |
| File scan | walks `files.directories` on a background queue | every cycle | **Files and Folders** (first access to Desktop/Documents/Downloads) | canonical path, name, modification time |
| System recent documents | Spotlight `kMDItemLastUsedDate` | every cycle | **Files and Folders** | last-used time |
| Manual entries | added in the app | immediate | none | URL + alias |

Details:

- **Browser history**: automatically discovers the Chromium family (Chrome, Chrome Beta/Canary, Chromium, Brave, Edge, Vivaldi, Opera, Arc, Sidekick), the Firefox family (Firefox, Developer Edition, Nightly, Zen, LibreWolf), and Safari / Safari Technology Preview. `immutable=1` would lose recent WAL records, so the database trio is copied before reading; profiles are merged and visit counts are summed before taking `MAX` with the stored value.
- **Epochs**: Chromium uses microseconds since 1601, Firefox microseconds since Unix, Safari seconds since 2001 — all converted to Unix seconds.
- **Safari permission**: reading `~/Library/Safari/History.db` requires Full Disk Access. Without it Safari is skipped, other browsers continue, and a one-time guide appears.
- **Tabs**: EasyFind never launches Chrome; tabs closed between two collections are not archived.
- **Apps**: top-level `.app` bundles in `/Applications`, `/Applications/Utilities`, `/System/Applications`, `/System/Applications/Utilities`, and `~/Applications`; deduplicated by bundle ID with `/Applications` preferred; nested helpers are ignored.
- **Folders**: only absolute and `~`-rooted `cd` commands (relative paths cannot be resolved without the historical cwd); editor recents use `folderUri` and the parent of `fileUri`; Finder bookmarks are resolved; packages (`.app`, `.cannedSearch`, etc.) are excluded.
- **Folder deduplication**: symlinks resolved, path standardized, trailing `/` removed; the key is the lowercased full path; counts, timestamps, and source labels are merged across sources.
- **Files**: only directories listed in `files.directories` are walked, capped at `files.maxFiles` per cycle. Hidden files, packages, symlinks, and noise directories are skipped; system locations are excluded (`/usr/local` and `/opt/homebrew` are exempt). System recents are queried through Spotlight scoped to those directories and merged by canonical path, keeping the newer `last_seen`. Missing files are filtered when the snapshot is read; open counts are retained.

---

## Data model

```
~/Library/Application Support/easyfind/easyfind.db
```

- Directory `0700`, database `0600`, SQLite WAL.
- Schema is migrated with `PRAGMA user_version`; currently 4 (v1 web, v2 apps, v3 folders, v4 files).

### `entries`

The web archive (`history` / `bookmark` / `manual`):

| Column | Description |
|---|---|
| `kind` | `history` / `bookmark` / `manual` |
| `host` | display and history dedupe key |
| `origin` | `scheme://host[:port]`, open target for history entries |
| `url` | full URL (tabs/manual) |
| `title` / `alias` | title / user alias |
| `visits` | browser-observed visits, monotonically non-decreasing |
| `own_opens` | times opened through EasyFind |
| `last_seen` | last visit (Unix seconds) |

Uniqueness:

- `UNIQUE(host) WHERE kind='history'`
- `UNIQUE(url) WHERE kind IN ('bookmark','manual')`

### `deep_links`

The five most-visited full pages per host; searchable, but never shown in the empty-query list.

### `apps`

| Column | Description |
|---|---|
| `bundle_id` / `name` / `path` | app identity and metadata |
| `own_opens` | times launched through EasyFind |

`path` is unique; `bundle_id` is unique when non-null. Refreshes remove uninstalled apps and preserve launch counts of surviving apps.

### `folders`

| Column | Description |
|---|---|
| `path_key` | lowercased canonical full path, dedupe key |
| `path` | canonical full path (display/open) |
| `name` | folder name |
| `visits` | source-observed count |
| `own_opens` | times opened through EasyFind |
| `last_seen` | last observed time |
| `sources` | combination of `shell,cursor,code,finder` |

Both `path_key` and `path` are unique. Missing directories are filtered from the index but their rows are kept, so a remounted volume can reappear.

### `files`

| Column | Description |
|---|---|
| `path_key` | lowercased canonical full path, dedupe key |
| `path` | canonical full path (display/open) |
| `name` | file name |
| `visits` | source-observed count (currently 0, reserved) |
| `own_opens` | times opened through EasyFind |
| `last_seen` | last-used time (system recents preferred, then modification time) |
| `sources` | combination of `scan,recent` |

Both `path_key` and `path` are unique. Missing files are filtered when the snapshot is read; rows and open counts are retained.

---

## Search and ranking

1. The query is split into tokens on whitespace; every token must match the entry's haystack.
2. Haystacks:

| Type | Haystack |
|---|---|
| History host | `host + title + alias` |
| Tab / manual | `host + decoded path and #fragment + title + alias` |
| Deep link | `host + path and #fragment + title` |
| Application | `name + bundle id` |
| Folder | `name + full path` |
| File | `name + full path` |

3. Ranking tiers: exact → prefix → substring → other fields; ties by `visits`, then `last_seen`, then path order.
4. The empty query bypasses search and returns "manual entries + most-used files (up to 8) + history".
5. `~` mode searches the folder set only; an empty remainder lists recent folders by visits/time.
6. `@` mode searches the file set only; an empty remainder lists files by open count/last use.

---

## Keys and actions

| Key | Behavior |
|---|---|
| `⌘G` (configurable) | show/hide the panel |
| `↑` / `↓` | move the selection |
| `Enter` | run `actions.<kind>.enter` (default: web→browser, app→launch, folder→Finder, file→default app) |
| `⌘Enter` | run `actions.<kind>.commandEnter` (default: folder→iTerm2, app/file→reveal in Finder, web→copy URL) |
| `⌥Enter` | run `actions.<kind>.optionEnter` (default: copy URL/path) |
| `Esc` | close the panel |

These are the defaults; edit `actions` in `config.json` to change them.

Modified Return is intercepted by a local `keyDown` monitor before the text field sees it; when an input method is composing marked text, the event is passed through so the IME can commit first.

> The default ⌘G overrides "Find Next" in Chrome, VS Code, Xcode, and other apps. Switch to a Space combo in the menu if that matters.

---

## Permissions

| Capability | Permission | Notes |
|---|---|---|
| Read Chrome / Chromium / Firefox history | none | ordinary file reads |
| Read Safari history | Full Disk Access | add EasyFind manually in System Settings, then restart |
| Read Chrome tabs | Automation | first-use prompt |
| Open folders in iTerm2 | Automation | first-use prompt; denial falls back to Terminal |
| Scan Desktop/Documents/Downloads and other configured directories | Files and Folders | first-use prompt; denial leaves that directory empty until re-granted in System Settings |
| Login item | `SMAppService` | System Settings → General → Login Items |

If Automation is denied:

- history, apps, folders, and web search keep working;
- tab capture is skipped with a one-time notice;
- the iTerm2 action falls back to Terminal.

Grant Automation at System Settings → Privacy & Security → Automation → EasyFind.

Safari history is skipped without Full Disk Access while other browsers keep syncing; menu bar → "Full Disk Access Settings" opens the corresponding pane.

---

## Privacy and security

- All data stays in `~/Library/Application Support/easyfind/`, directory `0700`, database `0600`.
- The app makes no network requests; `lsof -a -p <pid> -i` is empty.
- Command history is **not** collected; folder history stores paths only; the file index stores names, paths, and usage times, and **never reads file contents**.
- The web archive is deliberately append-only: it survives a browser history wipe. To delete it completely, quit the app and remove the data directory.
- Folder paths and file names can contain sensitive project names; they stay local, and "Clear Folder History" / "Clear File Index" removes them.

---

## Known limitations

- Browser history supports the Chromium family (Chrome, Chrome Beta/Canary, Chromium, Brave, Edge, Vivaldi, Opera, Arc, Sidekick), the Firefox family, and Safari; Safari requires Full Disk Access.
- Tab capture still supports Chrome only.
- History keeps hosts only; URL-fragment search covers tabs, manual entries, and the Top-5 deep links per host.
- Tabs are collected every 10 minutes; tabs closed between collections are not archived.
- Apps are scanned only as top-level `.app` bundles in the five roots; apps are search-only and do not appear in the empty-query list.
- Relative `cd` targets cannot be reconstructed; folder history only keeps absolute and `~` paths, and packages are excluded.
- Folder sources are currently Cursor, VS Code, Finder, and zsh.
- File search covers the configured directories only, not arbitrary full-disk content; system locations are excluded; the default cap is 20,000 files.
- System recents depend on Spotlight metadata; directories that Spotlight has not indexed are ranked by modification time only.
- Not notarized; ad-hoc signed and intended for local use.

---

## License

Licensed under the [Apache License, Version 2.0](LICENSE.en.md).

- Chinese introduction and the official text: [LICENSE.md](LICENSE.md)
- Authoritative English text: [LICENSE.en.md](LICENSE.en.md)

Copyright 2026 The EasyFind Authors

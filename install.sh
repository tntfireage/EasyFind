#!/usr/bin/env bash
# 一键构建并安装 EasyFind。
#
#   ./install.sh                 选择语言 → 配置 → 构建 → 安装 → 启动
#   ./install.sh --no-launch     只安装，不启动
#   ./install.sh --dir ~/Apps    安装到指定目录
#   ./install.sh --yes           非交互：保留现有配置，或写入默认配置
#   ./install.sh --reconfigure   强制重新询问配置
#   ./install.sh --uninstall     卸载（数据保留）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="EasyFind"
BUNDLE="${APP_NAME}.app"
DEFAULT_DIR="/Applications"

INSTALL_DIR="${EASYFIND_INSTALL_DIR:-$DEFAULT_DIR}"
LAUNCH=1
UNINSTALL=0
ASSUME_YES=0
FORCE_RECONFIGURE=0
CHECK_ONLY=0

DATA_DIR="${EASYFIND_DATA_DIR:-$HOME/Library/Application Support/easyfind}"
CONFIG_PATH="$DATA_DIR/config.json"
CONFIG_WRITTEN=0
CONFIG_KEPT=0
UI_LANG="zh"
LANGUAGE=""

usage() {
    cat <<EOF
用法: $(basename "$0") [选项]

  --dir <path>      安装目录（默认 $DEFAULT_DIR；不可写时回退 ~/Applications）
  --no-launch       安装完成后不启动
  --yes, -y         非交互：保留现有配置，或写入默认配置
  --reconfigure     强制重新询问配置
  --check           仅检查构建依赖，不安装 / check dependencies only
  --uninstall       卸载已安装的 app（数据保留）
  -h, --help        显示帮助

环境变量:
  EASYFIND_INSTALL_DIR  等同于 --dir
  EASYFIND_DATA_DIR     覆盖配置/数据库目录（调试用）
EOF
}

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m警告:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m错误:\033[0m %s\n' "$*" >&2; exit 1; }

pick() {
    if [[ "$UI_LANG" == "zh" ]]; then
        printf '%s' "$1"
    else
        printf '%s' "$2"
    fi
}

system_language() {
    local first
    first="$(defaults read -g AppleLanguages 2>/dev/null | grep -o '"[^"]*"' | head -1 | tr -d '"' || true)"
    first="${first:-${LANG:-en}}"
    case "$first" in
        zh*) printf 'zh' ;;
        *)   printf 'en' ;;
    esac
}

existing_language_from_config() {
    local value=""
    if [[ -f "$CONFIG_PATH" ]] && command -v python3 >/dev/null 2>&1; then
        value="$(python3 -c '
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        value = json.load(handle).get("language", "zh")
except Exception:
    value = "zh"
print(value if value in ("zh", "en", "auto") else "zh")
' "$CONFIG_PATH" 2>/dev/null || true)"
    fi
    printf '%s' "${value:-zh}"
}

resolve_ui_language() {
    case "$1" in
        zh) printf 'zh' ;;
        en) printf 'en' ;;
        *)  system_language ;;
    esac
}

read_reply() {
    REPLY=""
    IFS= read -r REPLY || true
}

select_language() {
    local existing default_choice choice
    existing="$(existing_language_from_config)"
    case "$existing" in
        en) default_choice=2 ;;
        auto) default_choice=3 ;;
        *) default_choice=1 ;;
    esac

    printf '\nSelect language / 选择语言\n'
    printf '  [1] 中文\n'
    printf '  [2] English\n'
    printf '  [3] Auto / 自动（follow system / 跟随系统）\n'
    while :; do
        printf '(%s): ' "$default_choice"
        read_reply
        choice="${REPLY:-$default_choice}"
        case "$choice" in
            1) LANGUAGE="zh"; UI_LANG="zh"; return ;;
            2) LANGUAGE="en"; UI_LANG="en"; return ;;
            3) LANGUAGE="auto"; UI_LANG="$(system_language)"; return ;;
            *) printf '1/2/3\n' ;;
        esac
    done
}

ask_yes_no() {
    local prompt="$1" default="${2:-y}" answer hint err
    if [[ "$default" == "n" ]]; then hint="y/N"; else hint="Y/n"; fi
    err="$(pick '请输入 y 或 n' 'Enter y or n')"
    while :; do
        printf '%s [%s]: ' "$prompt" "$hint"
        read_reply
        answer="${REPLY:-$default}"
        answer="$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]')"
        case "$answer" in
            y|yes) return 0 ;;
            n|no) return 1 ;;
            *) printf '%s\n' "$err" ;;
        esac
    done
}

choose_hotkey() {
    local choice
    while :; do
        printf '%s  [1] ⌘G [2] ⌥Space [3] ⌃Space [4] ⌘⌥Space (1): ' \
            "$(pick '快捷键' 'Hotkey')"
        read_reply
        choice="${REPLY:-1}"
        case "$choice" in
            1) HOTKEY_KEY="g"; HOTKEY_MODS='["command"]'; HOTKEY_LABEL="⌘G"; return ;;
            2) HOTKEY_KEY="space"; HOTKEY_MODS='["option"]'; HOTKEY_LABEL="⌥Space"; return ;;
            3) HOTKEY_KEY="space"; HOTKEY_MODS='["control"]'; HOTKEY_LABEL="⌃Space"; return ;;
            4) HOTKEY_KEY="space"; HOTKEY_MODS='["command", "option"]'; HOTKEY_LABEL="⌘⌥Space"; return ;;
            *) printf '1/2/3/4\n' ;;
        esac
    done
}

choose_interval() {
    local value
    while :; do
        printf '%s (10): ' "$(pick '同步间隔分钟' 'Sync interval minutes')"
        read_reply
        value="${REPLY:-10}"
        if [[ "$value" =~ ^[0-9]+$ ]] && (( value >= 1 && value <= 1440 )); then
            INTERVAL="$value"
            return
        fi
        printf '%s\n' "$(pick '请输入 1-1440' 'Enter a value from 1 to 1440')"
    done
}

choose_terminal() {
    local choice
    while :; do
        printf '%s  [1] Auto [2] iTerm2 [3] Terminal (1): ' \
            "$(pick '终端' 'Terminal')"
        read_reply
        choice="${REPLY:-1}"
        case "$choice" in
            1) TERMINAL="auto"; return ;;
            2) TERMINAL="iterm2"; return ;;
            3) TERMINAL="terminal"; return ;;
            *) printf '1/2/3\n' ;;
        esac
    done
}

write_config() {
    mkdir -p "$DATA_DIR" 2>/dev/null || true
    chmod 700 "$DATA_DIR" 2>/dev/null || true

    if command -v python3 >/dev/null 2>&1; then
        CFG_LANGUAGE="$LANGUAGE" \
        CFG_HOTKEY_KEY="$HOTKEY_KEY" \
        CFG_HOTKEY_MODIFIERS="$HOTKEY_MODS" \
        CFG_INTERVAL="$INTERVAL" \
        CFG_HISTORY="$HISTORY" \
        CFG_TABS="$TABS" \
        CFG_APPS="$APPS" \
        CFG_FOLDERS="$FOLDERS" \
        CFG_TERMINAL="$TERMINAL" \
        python3 - "$CONFIG_PATH" <<'PY'
import json
import os
import shutil
import sys
import time

path = sys.argv[1]
existing = {}
if os.path.exists(path):
    try:
        with open(path, encoding="utf-8") as handle:
            existing = json.load(handle)
        if not isinstance(existing, dict):
            existing = {}
    except Exception:
        backup = path + ".bak-" + time.strftime("%Y%m%d-%H%M%S")
        shutil.copy2(path, backup)
        print(f"warning: invalid config backed up to {backup}", file=sys.stderr)
        existing = {}

if not isinstance(existing.get("hotkey"), dict):
    existing["hotkey"] = {}
if not isinstance(existing.get("sync"), dict):
    existing["sync"] = {}
if not isinstance(existing.get("terminal"), dict):
    existing["terminal"] = {}

existing["language"] = os.environ["CFG_LANGUAGE"]
existing["hotkey"]["key"] = os.environ["CFG_HOTKEY_KEY"]
existing["hotkey"]["modifiers"] = json.loads(os.environ["CFG_HOTKEY_MODIFIERS"])
existing["sync"]["intervalMinutes"] = int(os.environ["CFG_INTERVAL"])
existing["sync"]["chromeHistory"] = os.environ["CFG_HISTORY"] == "true"
existing["sync"]["chromeTabs"] = os.environ["CFG_TABS"] == "true"
existing["sync"]["apps"] = os.environ["CFG_APPS"] == "true"
existing["sync"]["folders"] = os.environ["CFG_FOLDERS"] == "true"
existing["terminal"]["application"] = os.environ["CFG_TERMINAL"]

directory = os.path.dirname(path)
os.makedirs(directory, mode=0o700, exist_ok=True)
try:
    os.chmod(directory, 0o700)
except OSError:
    pass

with open(path, "w", encoding="utf-8") as handle:
    json.dump(existing, handle, ensure_ascii=False, indent=2, sort_keys=True)
    handle.write("\n")
os.chmod(path, 0o600)
print(path)
PY
        CONFIG_WRITTEN=1
        return 0
    fi

    if [[ -f "$CONFIG_PATH" ]]; then
        warn "$(pick '未找到 python3，保留现有配置，未写入本次选择' 'python3 not found; existing config kept')"
        return 1
    fi

    cat > "$CONFIG_PATH" <<EOF
{
  "language": "$LANGUAGE",
  "hotkey": { "key": "$HOTKEY_KEY", "modifiers": $HOTKEY_MODS },
  "sync": {
    "apps": $APPS,
    "chromeHistory": $HISTORY,
    "chromeTabs": $TABS,
    "folders": $FOLDERS,
    "intervalMinutes": $INTERVAL
  },
  "terminal": { "application": "$TERMINAL" }
}
EOF
    chmod 600 "$CONFIG_PATH"
    CONFIG_WRITTEN=1
    return 0
}


check_dependencies() {
    local ok=1
    local ok_text missing_text
    ok_text="$(pick '可用' 'OK')"
    missing_text="$(pick '缺失' 'missing')"

    say "$(pick '依赖检查' 'Dependency check')"

    if command -v swift >/dev/null 2>&1; then
        printf '  %-20s %s\n' "swift" "$ok_text"
    else
        printf '  %-20s %s\n' "swift" "$missing_text"
        ok=0
    fi

    if command -v make >/dev/null 2>&1; then
        printf '  %-20s %s\n' "make" "$ok_text"
    else
        printf '  %-20s %s\n' "make" "$missing_text"
        ok=0
    fi

    local missing_tools=()
    local tool
    for tool in xcrun codesign plutil; do
        if command -v "$tool" >/dev/null 2>&1; then
            :
        else
            missing_tools+=("$tool")
            ok=0
        fi
    done
    if [[ ${#missing_tools[@]} -eq 0 ]]; then
        printf '  %-20s %s\n' "xcrun/codesign/plutil" "$ok_text"
    else
        printf '  %-20s %s (%s)\n' "xcrun/codesign/plutil" "$missing_text" "${missing_tools[*]}"
    fi

    local developer_dir
    developer_dir="$(xcode-select -p 2>/dev/null || true)"
    if [[ -n "$developer_dir" ]]; then
        printf '  %-20s %s\n' "Xcode CLT" "$developer_dir"
    else
        printf '  %-20s %s\n' "Xcode CLT" "$missing_text"
        ok=0
    fi

    local sdk
    sdk="$(xcrun --show-sdk-path 2>/dev/null || true)"
    if [[ -n "$sdk" && ( -e "$sdk/usr/lib/libsqlite3.tbd" || -e "$sdk/usr/lib/libsqlite3.dylib" ) ]]; then
        printf '  %-20s %s\n' "sqlite3" "$(pick '系统库，无需安装' 'system library, no install needed')"
    else
        printf '  %-20s %s\n' "sqlite3" "$(pick '未找到系统库' 'system library not found')"
        ok=0
    fi

    if command -v python3 >/dev/null 2>&1; then
        printf '  %-20s %s\n' "python3" "$(pick '可用（配置合并）' 'OK (config merge)')"
    else
        printf '  %-20s %s\n' "python3" "$(pick '缺失（配置合并将回退）' 'missing (config merge will fall back)')"
    fi

    if [[ -d "/Applications/iTerm.app" || -d "/Applications/iTerm2.app" ]]; then
        printf '  %-20s %s\n' "iTerm2" "$(pick '已安装（可选）' 'installed (optional)')"
    else
        printf '  %-20s %s\n' "iTerm2" "$(pick '未安装（可选，回退 Terminal）' 'not installed (optional, falls back to Terminal)')"
    fi

    if [[ "$ok" == "1" ]]; then
        return 0
    fi

    if [[ "$CHECK_ONLY" == "1" ]]; then
        exit 1
    fi

    warn "$(pick '构建依赖不完整' 'Build dependencies are incomplete')"
    if [[ -t 0 && "$ASSUME_YES" != "1" ]] && command -v xcode-select >/dev/null 2>&1; then
        if ask_yes_no "$(pick '现在运行 xcode-select --install 安装 Command Line Tools？' 'Run xcode-select --install now?')" y; then
            xcode-select --install >/dev/null 2>&1 || true
            say "$(pick '已打开安装窗口，完成后重新运行 ./install.sh' 'Installer opened; run ./install.sh again when it finishes')"
        fi
    else
        warn "$(pick '请先运行 xcode-select --install，或安装 Xcode' 'Run xcode-select --install, or install Xcode')"
    fi
    exit 1
}

configure_if_needed() {
    if [[ "$ASSUME_YES" == "1" ]]; then
        if [[ -f "$CONFIG_PATH" ]]; then
            CONFIG_KEPT=1
            say "$(pick '保留现有配置（应用语言不变）' 'Keeping existing config (app language unchanged)')"
            return
        fi

        LANGUAGE="zh"
        HOTKEY_KEY="g"
        HOTKEY_MODS='["command"]'
        HOTKEY_LABEL="⌘G"
        INTERVAL=10
        HISTORY=true
        TABS=true
        APPS=true
        FOLDERS=true
        TERMINAL="auto"
        if write_config >/dev/null; then
            say "$(pick '已写入默认配置' 'Default config written'): $CONFIG_PATH"
        else
            warn "$(pick '无法写入配置；应用首次启动时会创建默认值' 'Could not write config; defaults will be created on first launch')"
        fi
        return
    fi

    if [[ -f "$CONFIG_PATH" && "$FORCE_RECONFIGURE" != "1" ]]; then
        printf '\n%s: %s\n' "$(pick '检测到现有配置' 'Existing config found')" "$CONFIG_PATH"
        while :; do
            printf '  [1] %s (default)   [2] %s: ' \
                "$(pick '保留' 'Keep')" "$(pick '重新配置' 'Reconfigure')"
            read_reply
            case "${REPLY:-1}" in
                1) CONFIG_KEPT=1; say "$(pick '保留现有配置（应用语言不变）' 'Keeping existing config (app language unchanged)')"; return ;;
                2) break ;;
                *) printf '1/2\n' ;;
            esac
        done
    fi

    say "$(pick '配置' 'Configuration')"
    choose_hotkey
    choose_interval
    if ask_yes_no "$(pick '浏览器历史（全部浏览器）' 'Browser history (all browsers)')" y; then HISTORY=true; else HISTORY=false; fi
    if ask_yes_no "$(pick 'Chrome 标签页' 'Chrome tabs')" y; then TABS=true; else TABS=false; fi
    if ask_yes_no "$(pick '已安装应用' 'Applications')" y; then APPS=true; else APPS=false; fi
    if ask_yes_no "$(pick '目录历史' 'Folder history')" y; then FOLDERS=true; else FOLDERS=false; fi
    choose_terminal

    printf '\n'
    printf '  %s : %s\n' "$(pick '语言' 'Language')" "$LANGUAGE"
    printf '  %s : %s\n' "$(pick '热键' 'Hotkey')" "$HOTKEY_LABEL"
    printf '  %s : %s %s · browser=%s tabs=%s apps=%s folders=%s\n' \
        "$(pick '同步' 'Sync')" "$INTERVAL" "$(pick '分钟' 'min')" "$HISTORY" "$TABS" "$APPS" "$FOLDERS"
    printf '  %s : %s\n' "$(pick '终端' 'Terminal')" "$TERMINAL"
    printf '\n'

    if ! ask_yes_no "$(pick '写入配置' 'Write config')" y; then
        warn "$(pick '跳过配置写入' 'Skipped config write')"
        return
    fi

    if write_config >/dev/null; then
        say "$(pick '配置已写入' 'Config written'): $CONFIG_PATH"
    else
        warn "$(pick '配置写入失败；应用将使用默认值' 'Config write failed; defaults will be used')"
    fi
}

quit_running() {
    if [[ "${EASYFIND_SKIP_QUIT:-0}" == "1" ]]; then
        return
    fi
    for name in "$APP_NAME" "easyfind"; do
        if pgrep -x "$name" >/dev/null 2>&1; then
            say "$(pick "退出正在运行的 $name" "Quitting running $name")"
            osascript -e "tell application \"$name\" to quit" >/dev/null 2>&1 || true
            for _ in {1..20}; do
                pgrep -x "$name" >/dev/null 2>&1 || break
                sleep 0.2
            done
            pkill -x "$name" >/dev/null 2>&1 || true
        fi
    done
    sleep 0.3
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dir)
            [[ $# -ge 2 ]] || die "--dir 需要一个路径"
            INSTALL_DIR="$2"
            shift 2
            ;;
        --no-launch) LAUNCH=0; shift ;;
        --yes|-y) ASSUME_YES=1; shift ;;
        --reconfigure) FORCE_RECONFIGURE=1; shift ;;
        --check) CHECK_ONLY=1; shift ;;
        --uninstall) UNINSTALL=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "未知参数: $1" ;;
    esac
done

if [[ "$UNINSTALL" == "1" ]]; then
    UI_LANG="$(system_language)"
    quit_running
    for bundle in "$BUNDLE" "easyfind.app"; do
        TARGET="$INSTALL_DIR/$bundle"
        if [[ -d "$TARGET" ]]; then
            rm -rf "$TARGET"
            say "$(pick '已卸载' 'Uninstalled') $TARGET"
        fi
    done
    printf '%s %s\n' "$(pick '数据仍保留在' 'Data remains at')" "$DATA_DIR"
    exit 0
fi

if [[ "$CHECK_ONLY" == "1" ]]; then
    UI_LANG="$(system_language)"
elif [[ "$ASSUME_YES" == "1" ]]; then
    if [[ -f "$CONFIG_PATH" ]]; then
        UI_LANG="$(resolve_ui_language "$(existing_language_from_config)")"
    else
        UI_LANG="$(system_language)"
        LANGUAGE="zh"
    fi
else
    select_language
fi

check_dependencies

if [[ "$CHECK_ONLY" == "1" ]]; then
    exit 0
fi

say "$(pick "构建 $APP_NAME" "Building $APP_NAME")"
cd "$SCRIPT_DIR"
make build

[[ -d "$BUNDLE" ]] || die "构建失败：$BUNDLE 不存在"

if [[ ! -d "$INSTALL_DIR" ]]; then
    mkdir -p "$INSTALL_DIR" 2>/dev/null || true
fi

if [[ ! -d "$INSTALL_DIR" || ! -w "$INSTALL_DIR" ]]; then
    warn "$(pick "$INSTALL_DIR 不存在或不可写，改用 $HOME/Applications" "$INSTALL_DIR is missing or not writable; using $HOME/Applications")"
    INSTALL_DIR="$HOME/Applications"
    mkdir -p "$INSTALL_DIR"
fi

TARGET="$INSTALL_DIR/$BUNDLE"
quit_running
rm -rf "$INSTALL_DIR/easyfind.app"

say "$(pick "安装到 $TARGET" "Installing to $TARGET")"
rm -rf "$TARGET"
ditto "$BUNDLE" "$TARGET"
xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true

if ! codesign --verify --deep --strict "$TARGET" >/dev/null 2>&1; then
    warn "$(pick '签名校验未通过；如果是本机自用通常仍可运行' 'Signature check failed; a local build may still run')"
fi

configure_if_needed

if [[ "$LAUNCH" == "1" ]]; then
    say "$(pick '启动' 'Launching')"
    open "$TARGET"
    sleep 1
    if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
        say "$(pick "$APP_NAME 正在运行" "$APP_NAME is running")"
    else
        warn "$(pick "$APP_NAME 没有启动，请从 $TARGET 手动打开查看控制台日志" "$APP_NAME did not start; open $TARGET manually and check the console")"
    fi
fi

cat <<EOF

$(pick '安装完成' 'Installed'): $TARGET

  $(pick '数据目录' 'Data directory'): $DATA_DIR
  $(pick '配置文件' 'Config file'): $CONFIG_PATH
  $(pick '热键' 'Hotkey'): ${HOTKEY_LABEL:-$(pick '见配置文件' 'see config')}
  $(pick '同步间隔' 'Sync interval'): ${INTERVAL:-$(pick '见配置文件' 'see config')} $(pick '分钟' 'min')
  $(pick '首次同步' 'First sync'): $(pick '浏览器历史；Chrome 在运行时会请求“自动化”权限' 'Browser history; Chrome will request Automation permission while running')

$(pick '如果之前从仓库目录直接运行过 EasyFind，系统登录项里可能残留指向旧路径的记录，请在“系统设置 → 通用 → 登录项”中删除旧记录。' 'If you previously ran EasyFind from the repository, a stale login item may remain; remove it in System Settings → General → Login Items.')

$(pick '卸载' 'Uninstall'): $(basename "$0") --uninstall
EOF
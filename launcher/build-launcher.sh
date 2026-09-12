#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

GAME_DIR=
HTML_FILE=
BUILD_ONLY=0
OUT_DIR=
INSTALL_DEPS=0
NO_DESKTOP=0
DO_UNINSTALL=0
DO_CLEAN=0

APP_NAME="Degrees of Lewdity"
DESKTOP_FILE_NAME="dol-launcher.desktop"

usage() {
    cat <<EOF
用法: $(basename "$0") [选项]

在游戏目录中构建并安装 Degrees of Lewdity WebKitGTK 启动器。

选项:
  --dir <目录>      指定游戏目录（含 Degrees of Lewdity*.html）
  --html <文件>     指定游戏 HTML 文件（优先于 --dir）
  --build-only      仅编译启动器（需配合 --out，用于 CI/打包）
  --out <目录>      --build-only 的输出目录
  --install-deps    自动安装缺失的构建依赖（需要 sudo）
  --no-desktop      不安装桌面菜单项
  --uninstall       移除桌面菜单项
  --clean           删除游戏目录中的构建产物（保留存档目录 .dol-data）
  -h, --help        显示帮助
EOF
}

log() { printf '%s\n' "$*"; }
die() { printf '错误: %s\n' "$*" >&2; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1; }

detect_pm() {
    if need_cmd pacman; then printf '%s' pacman
    elif need_cmd apt-get; then printf '%s' apt
    elif need_cmd dnf; then printf '%s' dnf
    elif need_cmd zypper; then printf '%s' zypper
    fi
}

install_hint() {
    pm=$(detect_pm)
    case "$pm" in
        pacman) log "  sudo pacman -S --needed webkit2gtk-4.1 libsoup3 gtk3 gcc pkgconf" ;;
        apt)    log "  sudo apt-get install -y libwebkit2gtk-4.1-dev libsoup-3.0-dev libgtk-3-dev build-essential pkg-config" ;;
        dnf)    log "  sudo dnf install -y webkit2gtk4.1-devel libsoup3-devel gtk3-devel gcc pkgconf-pkg-config" ;;
        zypper) log "  sudo zypper install -y webkit2gtk4.1-devel libsoup3-devel gtk3-devel gcc pkg-config" ;;
        *)      log "  请安装 gcc、pkg-config 以及 webkit2gtk-4.1、libsoup3、gtk3 的开发包" ;;
    esac
}

do_install_deps() {
    pm=$(detect_pm)
    case "$pm" in
        pacman) sudo pacman -S --needed webkit2gtk-4.1 libsoup3 gtk3 gcc pkgconf ;;
        apt)    sudo apt-get update && sudo apt-get install -y libwebkit2gtk-4.1-dev libsoup-3.0-dev libgtk-3-dev build-essential pkg-config ;;
        dnf)    sudo dnf install -y webkit2gtk4.1-devel libsoup3-devel gtk3-devel gcc pkgconf-pkg-config ;;
        zypper) sudo zypper install -y webkit2gtk4.1-devel libsoup3-devel gtk3-devel gcc pkg-config ;;
        *)      die "未识别的包管理器，请手动安装依赖" ;;
    esac
}

missing_deps() {
    missing=
    need_cmd gcc || missing="$missing gcc"
    need_cmd pkg-config || missing="$missing pkg-config"
    if need_cmd pkg-config; then
        for p in webkit2gtk-4.1 libsoup-3.0 gtk+-3.0; do
            pkg-config --exists "$p" 2>/dev/null || missing="$missing $p"
        done
    fi
    printf '%s' "$missing"
}

check_deps() {
    missing=$(missing_deps)
    [ -z "$missing" ] && return 0
    log "缺少构建依赖:$missing"
    log "可执行以下命令安装:"
    install_hint
    if [ "$INSTALL_DEPS" = 1 ]; then
        do_install_deps
        missing=$(missing_deps)
        [ -z "$missing" ] || die "依赖仍缺失:$missing"
        return 0
    fi
    log "可使用 --install-deps 自动安装"
    exit 1
}

find_html_in() {
    dir=$1
    normal=
    poly=
    for f in "$dir"/Degrees\ of\ Lewdity*.html; do
        [ -f "$f" ] || continue
        case "$f" in
            *polyfill*) [ -n "$poly" ] || poly=$f ;;
            *) normal=$f ;;
        esac
    done
    if [ -n "$normal" ]; then printf '%s\n' "$normal"
    elif [ -n "$poly" ]; then printf '%s\n' "$poly"
    fi
}

compile() {
    out_dir=$1
    mkdir -p "$out_dir"
    gcc -O2 -s -o "$out_dir/dol-launcher" "$SCRIPT_DIR/launcher.c" \
        $(pkg-config --cflags --libs webkit2gtk-4.1 libsoup-3.0)
}

desktop_dir="${XDG_DATA_HOME:-$HOME/.local/share}/applications"

install_desktop() {
    mkdir -p "$desktop_dir"
    cat > "$desktop_dir/$DESKTOP_FILE_NAME" <<EOF
[Desktop Entry]
Type=Application
Name=$APP_NAME
Name[zh_CN]=欲都孤儿
Comment=$APP_NAME (WebKitGTK Launcher)
Exec=$GAME_DIR/dol.sh
Path=$GAME_DIR
Icon=$GAME_DIR/dol-icon.png
Terminal=false
Categories=Game;
StartupWMClass=dol-launcher
EOF
    if need_cmd update-desktop-database; then
        update-desktop-database "$desktop_dir" >/dev/null 2>&1 || true
    fi
    log "已安装桌面菜单项: $desktop_dir/$DESKTOP_FILE_NAME"
}

remove_desktop() {
    if [ -f "$desktop_dir/$DESKTOP_FILE_NAME" ]; then
        rm -f "$desktop_dir/$DESKTOP_FILE_NAME"
        if need_cmd update-desktop-database; then
            update-desktop-database "$desktop_dir" >/dev/null 2>&1 || true
        fi
        log "已移除桌面菜单项"
    else
        log "桌面菜单项不存在"
    fi
}

while [ $# -gt 0 ]; do
    case "$1" in
        --dir)          [ $# -ge 2 ] || die "--dir 缺少参数"; GAME_DIR=$2; shift 2 ;;
        --html)         [ $# -ge 2 ] || die "--html 缺少参数"; HTML_FILE=$2; shift 2 ;;
        --build-only)   BUILD_ONLY=1; shift ;;
        --out)          [ $# -ge 2 ] || die "--out 缺少参数"; OUT_DIR=$2; shift 2 ;;
        --install-deps) INSTALL_DEPS=1; shift ;;
        --no-desktop)   NO_DESKTOP=1; shift ;;
        --uninstall)    DO_UNINSTALL=1; shift ;;
        --clean)        DO_CLEAN=1; shift ;;
        -h|--help)      usage; exit 0 ;;
        *)              die "未知参数: $1" ;;
    esac
done

if [ "$BUILD_ONLY" = 1 ]; then
    [ -n "$OUT_DIR" ] || die "--build-only 需要 --out <目录>"
    check_deps
    compile "$OUT_DIR"
    log "已生成: $OUT_DIR/dol-launcher"
    exit 0
fi

if [ "$DO_UNINSTALL" = 1 ]; then
    remove_desktop
    exit 0
fi

if [ -n "$HTML_FILE" ]; then
    [ -f "$HTML_FILE" ] || die "找不到 HTML 文件: $HTML_FILE"
    GAME_DIR=$(CDPATH= cd -- "$(dirname -- "$HTML_FILE")" && pwd)
elif [ -n "$GAME_DIR" ]; then
    [ -d "$GAME_DIR" ] || die "目录不存在: $GAME_DIR"
    GAME_DIR=$(CDPATH= cd -- "$GAME_DIR" && pwd)
    [ -n "$(find_html_in "$GAME_DIR")" ] || die "在 $GAME_DIR 中找不到 Degrees of Lewdity*.html"
else
    if [ -n "$(find_html_in "$SCRIPT_DIR")" ]; then
        GAME_DIR=$SCRIPT_DIR
    elif [ -n "$(find_html_in "$(pwd)")" ]; then
        GAME_DIR=$(pwd)
    else
        die "找不到游戏 HTML，请用 --dir 或 --html 指定"
    fi
fi

if [ "$DO_CLEAN" = 1 ]; then
    rm -f "$GAME_DIR/dol-launcher" "$GAME_DIR/dol.sh" "$GAME_DIR/dol-icon.png"
    remove_desktop
    log "已清理构建产物（存档目录 .dol-data 保留）"
    exit 0
fi

check_deps
compile "$GAME_DIR"
cp "$SCRIPT_DIR/dol.sh" "$GAME_DIR/dol.sh"
cp "$SCRIPT_DIR/dol-icon.png" "$GAME_DIR/dol-icon.png"
chmod +x "$GAME_DIR/dol.sh"
[ "$NO_DESKTOP" = 1 ] || install_desktop

log "构建完成: $GAME_DIR"
log "启动方式: $GAME_DIR/dol.sh"

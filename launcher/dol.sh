#!/bin/sh
cd "$(dirname "$0")" || exit 1

export JSC_useWasmOSR=0
export JSC_useWasmIPIntLoopOSR=0
export JSC_useWasmIPIntPrologueOSR=0
export JSC_useWasmIPIntEpilogueOSR=0

normal=
poly=
for f in Degrees\ of\ Lewdity*.html; do
    [ -f "$f" ] || continue
    case "$f" in
        *polyfill*) [ -n "$poly" ] || poly=$f ;;
        *) normal=$f ;;
    esac
done

html=${normal:-$poly}
[ -n "$html" ] || { echo "未找到 Degrees of Lewdity*.html" >&2; exit 1; }
[ -x ./dol-launcher ] || { echo "未找到 dol-launcher，请先运行 build-launcher.sh" >&2; exit 1; }

exec ./dol-launcher "$html"

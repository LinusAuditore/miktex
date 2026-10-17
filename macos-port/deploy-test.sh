#!/bin/bash
##
## deploy-test.sh — make a staged MiKTeX install tree self-contained on macOS
##
## Collects the /opt/homebrew (and /usr/local) dynamic-library closure of
## every Mach-O file in the staging tree, copies the libraries into
## <staging>/lib, rewrites the references to @rpath, and re-signs the
## touched files with an ad-hoc signature (required on arm64).
##
## Usage: deploy-test.sh <staging-dir>
##
## The script only inspects and copies files; it never runs any MiKTeX
## binary.

set -euo pipefail

if [ $# -ne 1 ]; then
    echo "usage: $0 <staging-dir>" >&2
    exit 1
fi

STAGING=$1
LIBDIR="$STAGING/lib"

if [ ! -d "$LIBDIR" ]; then
    echo "error: $LIBDIR does not exist; is this a MiKTeX staging tree?" >&2
    exit 1
fi

# external tools required at run time: with USE_SYSTEM_FONTCONFIG, the
# font map manager requires fc-cache on the PATH
# (FontMapManager::BuildFontconfigCache); ship the Homebrew one so the
# tree works on machines without fontconfig
for tool in fc-cache; do
    if [ ! -e "$STAGING/bin/$tool" ]; then
        if toolpath=$(command -v "$tool"); then
            cp -L "$toolpath" "$STAGING/bin/$tool"
            # copied tools only have Homebrew rpaths; add one that
            # resolves inside the tree (their dependencies are rewritten
            # to @rpath below)
            install_name_tool -add_rpath @loader_path/../lib "$STAGING/bin/$tool" 2>/dev/null || true
            codesign --force --sign - "$STAGING/bin/$tool" >/dev/null 2>&1
            echo "  + $tool (external tool)"
        else
            echo "error: $tool is required on the build host" >&2
            exit 1
        fi
    fi
done

# Qt runtime bits: platform/style/image plugins must sit next to the
# application bundle executables (Contents/PlugIns), otherwise GUI apps
# cannot start on machines without Qt
if [ -d /opt/homebrew/share/qt/plugins ]; then
    find "$STAGING" -name '*.app' -type d | while read -r app; do
        rm -rf "$app/Contents/PlugIns"
        mkdir -p "$app/Contents/PlugIns"
        for p in platforms styles imageformats; do
            # -L: some plugin dirs are Homebrew symlinks into Cellar
            cp -R -L "/opt/homebrew/share/qt/plugins/$p" "$app/Contents/PlugIns/" 2>/dev/null || true
        done
        echo "  + Qt plugins -> ${app#$STAGING/}/Contents/PlugIns"
    done
fi

is_macho() {
    file -b "$1" | grep -q "Mach-O"
}

# resolve <dep-entry> <referencing-file> -> absolute path or "" if unsupported
resolve_dep() {
    local dep=$1 ref=$2
    case "$dep" in
        @executable_path/*)
            return 1
            ;;
        @loader_path/*)
            local rel=${dep#@loader_path/}
            local cand="$(dirname "$ref")/$rel"
            [ -f "$cand" ] && echo "$cand" && return 0
            # copied Homebrew libraries keep @loader_path references to
            # siblings that have not been copied yet
            local leaf2=$(basename "$rel")
            [ -f "/opt/homebrew/lib/$leaf2" ] && echo "/opt/homebrew/lib/$leaf2" && return 0
            return 1
            ;;
        @rpath/*)
            local leaf=${dep#@rpath/}
            # try the rpaths of the referencing image first
            while IFS= read -r rp; do
                case "$rp" in
                    @loader_path/*) rp="$(dirname "$ref")/${rp#@loader_path/}" ;;
                esac
                local cand="$rp/$leaf"
                [ -f "$cand" ] && echo "$cand" && return 0
            done < <(otool -l "$ref" 2>/dev/null | awk '/cmd LC_RPATH/{getline; getline; print $2}')
            # then the staging lib dir (the final home of the closure)
            [ -f "$LIBDIR/$leaf" ] && echo "$LIBDIR/$leaf" && return 0
            # then Homebrew, for not-yet-copied siblings of copied libraries
            [ -f "/opt/homebrew/lib/$leaf" ] && echo "/opt/homebrew/lib/$leaf" && return 0
            # and the Qt frameworks (framework-to-framework references)
            [ -f "/opt/homebrew/opt/qtbase/lib/$leaf" ] && echo "/opt/homebrew/opt/qtbase/lib/$leaf" && return 0
            return 1
            ;;
        /opt/homebrew/*|/usr/local/*)
            [ -f "$dep" ] && echo "$dep" && return 0
            return 1
            ;;
        *)
            return 1
            ;;
    esac
}

# deps of a Mach-O file, one per line; skips the header and the install id
dep_list() {
    local id
    id=$(otool -D "$1" 2>/dev/null | tail -n +2 | sed -e 's/^[[:space:]]*//' | head -1)
    if [ -n "$id" ]; then
        otool -L "$1" | tail -n +2 | sed -e 's/^[[:space:]]*//' -e 's/ (.*//' | grep -v '^$' | grep -v -F -x "$id"
    else
        otool -L "$1" | tail -n +2 | sed -e 's/^[[:space:]]*//' -e 's/ (.*//' | grep -v '^$'
    fi
}

process_file() {
    local f=$1
    local changed=0
    local dep resolved leaf
    while IFS= read -r dep; do
        case "$dep" in
            /opt/homebrew/*|/usr/local/*|@rpath/*|@loader_path/*) ;;
            *) continue ;;
        esac
        resolved=$(resolve_dep "$dep" "$f" || true)
        [ -z "$resolved" ] && continue
        case "$resolved" in
            /opt/homebrew/*|/usr/local/*) ;;
            *) continue ;;  # resolves inside the tree already (e.g. staging lib)
        esac
        if [[ "$resolved" == *.framework/* ]]; then
            # Qt & friends: copy the whole framework bundle, reference
            # the binary relative to the staging lib dir
            local rel=${resolved#*/lib/}
            local fwdir=${rel%%.framework/*}.framework
            if [ ! -d "$LIBDIR/$fwdir" ]; then
                # the framework directory itself may be a Homebrew
                # symlink into Cellar; resolve it, but keep the bundle's
                # internal symlinks (Versions/Current, root binary) intact
                local srcfw
                srcfw=$(realpath "${resolved%/$rel}/$fwdir")
                rsync -a "$srcfw" "$LIBDIR/"
                echo "  + $fwdir"
            fi
            local newfw="@rpath/$rel"
            if [ "$dep" != "$newfw" ]; then
                install_name_tool -change "$dep" "$newfw" "$f"
                changed=1
            fi
            realpath "$LIBDIR/$rel" >> "$WORKLIST"
            continue
        fi
        leaf=$(basename "$resolved")
        if [ ! -e "$LIBDIR/$leaf" ]; then
            cp "$resolved" "$LIBDIR/$leaf"
            echo "  + $leaf"
        fi
        local new="@rpath/$leaf"
        if [ "$dep" != "$new" ]; then
            install_name_tool -change "$dep" "$new" "$f"
            changed=1
        fi
        # queue the copied library for its own dependency walk
        realpath "$LIBDIR/$leaf" >> "$WORKLIST"
    done < <(dep_list "$f")
    if [ $changed -eq 1 ]; then
        codesign --force --sign - "$f" >/dev/null 2>&1
    fi
}

WORKLIST=$(mktemp /tmp/miktex-deploy.XXXXXX)
trap 'rm -f "$WORKLIST"' EXIT

echo "==> collecting Mach-O files in $STAGING"
find "$STAGING" -type f | while read -r f; do
    is_macho "$f" && printf '%s\n' "$f"
done > "$WORKLIST"

echo "==> rewriting Homebrew references"
total=0
while [ -s "$WORKLIST" ]; do
    CP=$(mktemp /tmp/miktex-deploy.XXXXXX)
    mv "$WORKLIST" "$CP"
    # dedupe
    sort -u "$CP" | while read -r f; do
        [ -f "$f" ] || continue
        is_macho "$f" || continue
        process_file "$f"
    done
    rm -f "$CP"
    total=$((total + 1))
    # guard against pathological loops
    if [ $total -gt 50 ]; then
        echo "error: too many closure rounds" >&2
        exit 1
    fi
done

# rewrite install ids of copied libraries to @rpath/<path relative to
# the staging lib dir> (covers flat libraries and framework binaries)
echo "==> normalizing install ids"
find "$LIBDIR" -type f | while read -r f; do
    is_macho "$f" || continue
    id=$(otool -D "$f" | tail -n +2 | sed -e 's/^[[:space:]]*//' | head -1)
    rel=${f#"$LIBDIR"/}
    if [ -n "$id" ] && [ "$id" != "@rpath/$rel" ]; then
        install_name_tool -id "@rpath/$rel" "$f"
        codesign --force --sign - "$f" >/dev/null 2>&1
    fi
done

# .app executables deep inside the tree need an rpath that reaches the
# shared staging lib dir (the build-time @loader_path/../lib does not)
echo "==> fixing .app rpaths"
find "$STAGING" -name '*.app' -type d | while read -r app; do
    find "$app/Contents/MacOS" -type f | while read -r exe; do
        is_macho "$exe" || continue
        reldepth=${app#"$STAGING"/}
        ups=$(echo "$reldepth" | awk -F/ '{print NF + 2}')
        rp="@executable_path/$(printf '../%.0s' $(seq 1 $ups))lib"
        if ! otool -l "$exe" | grep -q "path $rp "; then
            install_name_tool -add_rpath "$rp" "$exe"
            codesign --force --sign - "$exe" >/dev/null 2>&1
            echo "  rpath+ $rp"
        fi
    done
done

echo "==> self-check"
status=0
while IFS= read -r f; do
    bad=$(otool -L "$f" | grep -E '/opt/homebrew|/usr/local' || true)
    if [ -n "$bad" ]; then
        echo "FAIL: $f still references:" >&2
        echo "$bad" >&2
        status=1
    fi
    # every @rpath dependency must exist in the staging lib dir,
    # and every @loader_path dependency must exist next to its consumer
    for dep in $(dep_list "$f" | grep -E '^@rpath/|^@loader_path/' || true); do
        case "$dep" in
            @rpath/*)
                leaf=${dep#@rpath/}
                target="$LIBDIR/$leaf" ;;
            @loader_path/*)
                target="$(dirname "$f")/${dep#@loader_path/}" ;;
        esac
        if [ ! -e "$target" ]; then
            echo "FAIL: $f needs $dep but $target is missing" >&2
            status=1
        fi
    done
done < <(find "$STAGING" -type f | while read -r f; do is_macho "$f" && echo "$f"; done)

if [ $status -ne 0 ]; then
    echo "self-check FAILED" >&2
    exit 1
fi
echo "OK: staging tree is self-contained ($(ls "$LIBDIR" | wc -l | tr -d ' ') files in lib/)"

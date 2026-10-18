#!/bin/bash
# Verify the MiKTeX disk image produced by CPack (fork CI only).
#
# usage: verify-dmg.sh <dmg> [<max-min-version> [<volume-name>]]
#
# Mounts the image read-only and checks the application bundle in it:
# code signature, arm64-only Mach-O files, no load commands or rpaths that
# point outside the bundle (Homebrew, /usr/local, home/build directories).
# Prints the distribution of minimum macOS versions (minos) of all Mach-O
# files; the highest one is the effective minimum system version. If
# <max-min-version> (e.g. 26.0) is given, the effective minimum system
# version must not be higher, and the application's LSMinimumSystemVersion
# must be equal to it. If <volume-name> is given, the image must have that
# volume name. Warns if the Finder layout of the image is missing.

set -euo pipefail

if [ $# -lt 1 ] || [ $# -gt 3 ]; then
  echo "usage: verify-dmg.sh <dmg> [<max-min-version> [<volume-name>]]" >&2
  exit 2
fi
dmg=$1
max_min_version=${2:-}
volume_name=${3:-}
if [ -n "$max_min_version" ] && ! [[ $max_min_version =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
  echo "verify-dmg.sh: <max-min-version> must look like 26.0: $max_min_version" >&2
  exit 2
fi
work=$(mktemp -d)
mnt="$work/mnt"
mkdir "$mnt"
mounted=0

cleanup()
{
  if [ "$mounted" -eq 1 ]; then
    if ! hdiutil detach "$mnt" -quiet && ! hdiutil detach "$mnt" -force -quiet; then
      # never remove the work directory while the image is still mounted
      echo "warning: could not detach $mnt" >&2
      return
    fi
  fi
  rm -rf "$work"
}
trap 'rc=$?; cleanup || true; exit $rc' EXIT

shasum -a 256 "$dmg"
hdiutil verify -quiet "$dmg"

# the image carries a software license agreement, which makes a
# non-interactive attach fail; a converted (CD/DVD master) copy has none
hdiutil convert -quiet -format UDTO -o "$work/image" "$dmg"
hdiutil attach -quiet -nobrowse -readonly -noautoopen -mountpoint "$mnt" "$work/image.cdr"
mounted=1

bad=0

if [ -n "$volume_name" ]; then
  actual_volume_name=$(diskutil info "$mnt" | sed -n 's/^ *Volume Name: *//p')
  echo "volume name: $actual_volume_name"
  if [ "$actual_volume_name" != "$volume_name" ]; then
    echo "::error::volume name is '$actual_volume_name', expected '$volume_name'"
    bad=1
  fi
fi
for f in .DS_Store .background/background.tif; do
  if [ ! -e "$mnt/$f" ]; then
    echo "::warning::$f is missing: the Finder layout of the image was not applied"
  fi
done

app="$mnt/MiKTeX Console.app"
codesign --verify --deep --strict "$app"
echo "code signature: ok"

count=0
external='(/opt/homebrew|/usr/local|/Users/|/private/)'
while IFS= read -r -d '' f; do
  case "$(file -b "$f")" in
    *Mach-O*) ;;
    *) continue ;;
  esac
  count=$((count + 1))
  rel=${f#"$mnt"/}
  archs=$(lipo -archs "$f")
  if [ "$archs" != arm64 ]; then
    echo "::error::not arm64-only ($archs): $rel"
    bad=1
  fi
  if otool -L "$f" | tail -n +2 | grep -Eq "^[[:space:]]*$external"; then
    echo "::error::load command outside the bundle: $rel"
    otool -L "$f" | tail -n +2 | grep -E "^[[:space:]]*$external"
    bad=1
  fi
  if otool -l "$f" | grep -A2 'cmd LC_RPATH' | grep -Eq "path $external"; then
    echo "::error::rpath outside the bundle: $rel"
    bad=1
  fi
  vtool -show-build "$f" 2>/dev/null | awk '/minos/ { print $2; exit }' >> "$work/minos.txt"
done < <(find "$app" -type f -print0)

echo "Mach-O files: $count"
echo "minos distribution:"
sort -V "$work/minos.txt" | uniq -c
effective=$(sort -V "$work/minos.txt" | tail -1)
echo "effective minimum macOS version: $effective"
if [ -z "$effective" ]; then
  echo "::error::no minimum macOS version (minos) found"
  bad=1
elif [ -n "$max_min_version" ] \
  && [ "$(printf '%s\n%s\n' "$max_min_version" "$effective" | sort -V | tail -1)" != "$max_min_version" ]; then
  echo "::error::effective minimum macOS version $effective is higher than $max_min_version"
  bad=1
fi
if [ -n "$max_min_version" ]; then
  ls_min_version=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$app/Contents/Info.plist" 2>/dev/null || true)
  echo "LSMinimumSystemVersion: $ls_min_version"
  if [ "$ls_min_version" != "$max_min_version" ]; then
    echo "::error::LSMinimumSystemVersion is '$ls_min_version', expected $max_min_version"
    bad=1
  fi
fi

exit $bad

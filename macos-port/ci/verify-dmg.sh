#!/bin/bash
# Verify the MiKTeX disk image produced by CPack (fork CI only).
#
# usage: verify-dmg.sh <dmg>
#
# Mounts the image read-only and checks the application bundle in it:
# code signature, arm64-only Mach-O files, no load commands or rpaths that
# point outside the bundle (Homebrew, /usr/local, home/build directories).
# Prints the distribution of minimum macOS versions (minos) of all Mach-O
# files; the highest one is the effective minimum system version.

set -euo pipefail

dmg=$1
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

app="$mnt/MiKTeX Console.app"
codesign --verify --deep --strict "$app"
echo "code signature: ok"

bad=0
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
echo "effective minimum macOS version: $(sort -V "$work/minos.txt" | tail -1)"

exit $bad

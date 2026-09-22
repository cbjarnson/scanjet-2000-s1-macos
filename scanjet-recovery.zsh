#!/bin/zsh
# Source-only preparation helper. Never installs drivers or changes system settings.
set -euo pipefail
export LC_ALL=C
umask 077
ROOT=${0:A:h}
PACKAGE_URL='https://ftp.hp.com/pub/softlib/software12/HP_Quick_Start/osx/Installations/Essentials/Pinnacles_Canopus/hp-printer-essentials-SJ-5_15_5_7.pkg'
PACKAGE_SHA='92c986eaae53ab8e65a362e2c997f91a4903f91a398ea2db08b80a113cb78dac'
DEST='/Library/Image Capture/Devices/HP Scanner 4.app'

fail() { print -u2 -- "STOP: $*"; exit 1; }
usage() {
  cat <<'EOF'
ScanJet Pro 2000 s1 recovery helper (experimental)

  /bin/zsh scanjet-recovery.zsh check
      Read-only OS, Rosetta, USB and installed-driver checks.
  /bin/zsh scanjet-recovery.zsh prepare [--package /path/to/original.pkg]
      Download from HP (or use a local package), verify and extract to a private
      temporary folder. Prints the path for the manual installation guide.
  /bin/zsh scanjet-recovery.zsh verify '/path/to/HP Scanner 4.app'
      Check exact content, symlinks, original HP signature and Gatekeeper.

No sudo, installation, security-setting changes, or paper movement occurs.
Read README.md and THIRD-PARTY.md before downloading/using HP software.
EOF
}

verify_bundle() {
  local app="$1" expected relative
  [[ -d "$app" && ! -L "$app" ]] || fail 'Expected a real HP Scanner 4.app directory.'
  # Compare the entire non-directory inventory, then check every file and link.
  /usr/bin/diff -u "$ROOT/manifests/driver-paths.txt" \
    <(cd "$app" && /usr/bin/find . ! -type d -print | /usr/bin/sort) \
    || fail 'Bundle contains missing, extra, or unexpected entries.'
  /usr/bin/diff -u <(/usr/bin/cut -f 2 "$ROOT/manifests/driver-links.tsv" | /usr/bin/sort) \
    <(cd "$app" && /usr/bin/find . -type l -print | /usr/bin/sort) \
    || fail 'Bundle symlink inventory differs from the tested app.'
  (cd "$app" && /usr/bin/shasum --quiet -a 256 -c "$ROOT/manifests/driver-files.sha256") \
    || fail 'Driver file hash mismatch.'
  while IFS=$'\t' read -r expected relative; do
    [[ -L "$app/$relative" ]] || fail "Missing symlink: $relative"
    [[ "$(/usr/bin/readlink "$app/$relative")" == "$expected" ]] \
      || fail "Changed symlink: $relative"
  done < "$ROOT/manifests/driver-links.tsv"
  /usr/bin/codesign --verify --deep --strict \
    -R='anchor apple generic and identifier "com.hp.scanModule4" and certificate leaf[subject.OU] = "6HB5Y2QTA3"' \
    "$app" || fail 'Original HP signature/identity verification failed.'
  /usr/sbin/spctl --assess --type execute --verbose=2 "$app" \
    || fail 'Gatekeeper did not accept this driver. Do not bypass it.'
  print -- 'PASS: exact tested driver content, HP identity, and Gatekeeper acceptance.'
}

check_environment() {
  local version major machine rosetta usb_result
  version=$(/usr/bin/sw_vers -productVersion)
  major=${version%%.*}
  machine=$(/usr/sbin/sysctl -n hw.optional.arm64 2>/dev/null || print 0)
  print -- "macOS $version ($(/usr/bin/sw_vers -buildVersion))"
  [[ "$machine" == 1 ]] || fail 'This release is scoped to Apple Silicon Macs.'
  [[ "$major" == 27 ]] || fail 'Only macOS 27 has been physically tested. This helper stops on other versions.'
  if /usr/bin/arch -x86_64 /usr/bin/true 2>/dev/null; then
    print -- 'Rosetta: available.'
  else
    fail 'Rosetta is unavailable. Read Apple’s Rosetta instructions linked in README.md.'
  fi
  usb_result=$(/usr/sbin/ioreg -p IOUSB -l -w 0 | /usr/bin/awk '
    /\+-o / { vendor=0; product=0 }
    /"idVendor" = 1008$/ { vendor=1 }
    /"idProduct" = 22789$/ { product=1 }
    vendor && product { found=1 }
    END { print found ? "found" : "absent" }')
  print -- "USB 03f0:5905: $usb_result (no serial numbers printed)."
  if [[ -e "$DEST" || -L "$DEST" ]]; then
    print -- 'HP Scanner 4 already exists. Do not replace it.'
    verify_bundle "$DEST"
  else
    print -- 'HP Scanner 4 destination is absent; an add-only manual test is possible.'
  fi
  print -- 'These checks do not open the scanner or prove scanning works.'
}

prepare() {
  local source_pkg='' work_dir pkg digest signature
  if (( $# )); then
    [[ $# == 2 && "$1" == --package ]] || fail 'Use prepare [--package /path/to/original.pkg].'
    source_pkg=${2:A}
    [[ -f "$source_pkg" ]] || fail 'Local package does not exist.'
  fi
  check_environment
  work_dir=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/scanjet-recovery.XXXXXX")
  print -- "Private preparation folder (retained): $work_dir"
  pkg="$work_dir/hp-printer-essentials-SJ-5_15_5_7.pkg"
  if [[ -n "$source_pkg" ]]; then
    /bin/cp "$source_pkg" "$pkg"
  else
    print -- 'Downloading the original approximately 306 MiB package directly from HP.'
    /usr/bin/curl --fail --location --proto '=https' --proto-redir '=https' \
      --tlsv1.2 --retry 2 --connect-timeout 30 --max-time 1800 \
      --output "$pkg" "$PACKAGE_URL"
  fi
  digest=$(/usr/bin/shasum -a 256 "$pkg")
  [[ "${digest%% *}" == "$PACKAGE_SHA" ]] || fail 'Package SHA-256 differs from the tested HP download.'
  signature=$(/usr/sbin/pkgutil --check-signature "$pkg") || fail 'Package signature verification failed.'
  print -r -- "$signature"
  [[ "$signature" == *'Developer ID Installer: HP Inc. (6HB5Y2QTA3)'* ]] \
    || fail 'Unexpected package signer.'
  /usr/sbin/pkgutil --expand "$pkg" "$work_dir/expanded"
  /bin/mkdir "$work_dir/payload"
  # The pinned, signature-checked original payload is unpacked, never executed.
  /usr/bin/tar -xf "$work_dir/expanded/com.hp.scan.ica.module4.pkg/Payload" -C "$work_dir/payload"
  verify_bundle "$work_dir/payload/Library/Image Capture/Devices/HP Scanner 4.app"
  print -- "\nPREPARED, NOT INSTALLED: $work_dir/payload/Library/Image Capture/Devices/HP Scanner 4.app"
  print -- 'Follow docs/INSTALL.md for backups, the manual copy, verification and rollback.'
  print -- 'No package scripts were executed. The downloaded and extracted files remain local.'
}

[[ "$EUID" -ne 0 ]] || fail 'Run this helper as your normal user, without sudo.'
[[ "$(/usr/bin/uname -s)" == Darwin ]] || fail 'This helper requires macOS.'
command_name=${1:-help}
(( $# == 0 )) || shift
case "$command_name" in
  help|--help|-h) usage ;;
  check) (( $# == 0 )) || fail 'check takes no arguments.'; check_environment ;;
  prepare) prepare "$@" ;;
  verify) (( $# == 1 )) || fail 'verify requires one app path.'; verify_bundle "${1:a}" ;;
  *) usage; fail 'Unknown command.' ;;
esac

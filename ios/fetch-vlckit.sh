#!/bin/bash
# Downloads VLCKit for iOS (MobileVLCKit, VideoLAN, LGPL 2.1 or later) into Vendor/, checks it against VideoLAN's
# published SHA-256, and points Vendor/vlc-iphoneos and Vendor/vlc-iphonesimulator at its framework folders.
# Nightdial plays channels Apple's player can't show (HEVC or MPEG-2 video, often 24/7 channels) with it.
# Without it the app still builds, just without the built-in VLC engine.
set -euo pipefail
cd "$(dirname "$0")"
VERSION=3.7.5
URL="https://download.videolan.org/pub/cocoapods/prod/MobileVLCKit-3.7.5-a213fd11-6de05adc.tar.xz"
SHA256=a76f7a6cfcde4209b56f943e6e18400659d8a7a93ff482f8b1d059468d11e6be
mkdir -p Vendor
if [ ! -d Vendor/MobileVLCKit.xcframework ]; then
  curl -fL --retry 3 --retry-delay 5 -o Vendor/vlckit.tar.xz "$URL"
  echo "$SHA256  Vendor/vlckit.tar.xz" | shasum -a 256 -c -
  mkdir -p Vendor/unpack
  tar -xJf Vendor/vlckit.tar.xz -C Vendor/unpack
  fw=$(find Vendor/unpack -type d -name MobileVLCKit.xcframework -prune | head -1)
  [ -n "$fw" ] || { echo "MobileVLCKit.xcframework not found in the download"; exit 1; }
  mv "$fw" Vendor/MobileVLCKit.xcframework
  find Vendor/unpack -maxdepth 3 -iname 'COPYING*' -exec cp {} Vendor/VLCKit-COPYING.txt \; || true
  rm -rf Vendor/unpack Vendor/vlckit.tar.xz
fi
device=$(find Vendor/MobileVLCKit.xcframework -mindepth 1 -maxdepth 1 -type d -name 'ios-*' ! -name '*simulator*' | head -1)
simulator=$(find Vendor/MobileVLCKit.xcframework -mindepth 1 -maxdepth 1 -type d -name 'ios-*simulator*' | head -1)
[ -n "$device" ] || { echo "no iOS device slice in MobileVLCKit.xcframework"; ls Vendor/MobileVLCKit.xcframework; exit 1; }
ln -sfn "MobileVLCKit.xcframework/$(basename "$device")" Vendor/vlc-iphoneos
[ -n "$simulator" ] && ln -sfn "MobileVLCKit.xcframework/$(basename "$simulator")" Vendor/vlc-iphonesimulator
echo "VLCKit $VERSION ready: $(ls Vendor/vlc-iphoneos)"

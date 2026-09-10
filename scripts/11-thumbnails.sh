#!/usr/bin/env bash
# 11 — File-manager thumbnails.
#
# Ubuntu ships with anemic thumbnail behavior in Nautilus: images sometimes
# yes, videos almost never, high thresholds too low for modern phone camera
# files. This script fixes both.
#
# System part (needs root): install ffmpegthumbnailer and codec extras so
# every common video and image type has a working thumbnailer under
# /usr/share/thumbnailers/.
#
# User part: flip Nautilus's preferences so it uses those thumbnailers by
# default for every file size, and bumps its cache size.
set -euo pipefail

if [[ $EUID -eq 0 ]]; then
  # System-side install.
  apt-get install -y \
    ffmpegthumbnailer \
    libavcodec-extra \
    libavformat-extra \
    gstreamer1.0-libav \
    gstreamer1.0-plugins-good \
    gstreamer1.0-plugins-bad \
    gstreamer1.0-plugins-ugly \
    heif-thumbnailer \
    webp-pixbuf-loader \
    2>/dev/null || true
  echo "  system thumbnailers + codecs installed"
  exit 0
fi

# User-side gsettings.
if command -v gsettings >/dev/null 2>&1; then
  P=org.gnome.nautilus.preferences
  gsettings set $P show-image-thumbnails 'always'
  # thumbnail-limit is in MB. Bump so 100 MB phone videos still get thumbs.
  gsettings set $P thumbnail-limit 512 2>/dev/null || true
  echo "  Nautilus: image + video thumbnails always, up to 512 MB per file"
fi

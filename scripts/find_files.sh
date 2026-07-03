#!/bin/bash
# =============================================================================
# SamFWDumper - Automated Samsung Firmware Extraction
# Copyright (C) 2026 Xiatsuma
# Licensed under PolyForm Noncommercial License 1.0.0
# https://polyformproject.org/licenses/noncommercial/1.0.0
#
# You may NOT use this file except in compliance with the License.
# Commercial use, removal of this header, or distribution without attribution
# is strictly prohibited. For permissions: https://github.com/Xiatsuma
# =============================================================================
set -e

echo "═══════════════════════════════════════"
echo "   Universal Samsung Firmware File Finder"
echo "═══════════════════════════════════════"

URL="$1"
COMPRESSION_LEVEL="${2:-0}"
FIND_PATTERNS="$3"

[ -z "$URL" ] && { echo "❌ No URL"; exit 1; }
[ -z "$FIND_PATTERNS" ] && { echo "❌ No file pattern given"; exit 1; }

case "$COMPRESSION_LEVEL" in
  0) XZ_FLAGS="-0" ;;
  3) XZ_FLAGS="-3" ;;
  6) XZ_FLAGS="-6" ;;
  9) XZ_FLAGS="-9" ;;
  *) XZ_FLAGS="-0" ;;
esac

echo "Patterns to find: $FIND_PATTERNS"

chmod +x tools/android-tools/* tools/erofs-utils/* 2>/dev/null || true

FS_PARTS="system system_ext product vendor vendor_dlkm system_dlkm odm odm_dlkm"

echo ""; echo "[1/6] Downloading..."
wget --no-check-certificate --content-disposition \
  --user-agent="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36" \
  "$URL" 2>&1 | tail -20
ZIP_FILE=$(ls -t *.zip 2>/dev/null | head -1)
if [ ! -f "$ZIP_FILE" ]; then
  DOWNLOADED=$(ls -t 2>/dev/null | grep -v -E '^(tools|scripts|output|extracted|\.github|ap_code\.txt|csc_code\.txt)$' | head -1)
  echo "❌ Download failed: expected a firmware .zip, but got '${DOWNLOADED:-nothing}'."
  echo "   'url' must be the SamFW Direct Download Link for the full firmware package, not a link to a single extracted file."
  exit 1
fi
FILESIZE=$(stat -c%s "$ZIP_FILE")
[ "$FILESIZE" -eq 0 ] && { echo "❌ Empty file"; exit 1; }
echo "✅ Downloaded: $(numfmt --to=iec $FILESIZE)"

CSC_CODE=$(echo "$ZIP_FILE" | sed 's/\.zip$//' | tr '_' '\n' | grep -E '^[A-Z]{3}$' | grep -v -E '^(COM|SAM|FAC)$' | head -1)
AP_CODE=$(echo "$ZIP_FILE" | sed 's/\.zip$//' | tr '_' '\n' | grep -E '^[A-Z][A-Z0-9]{11,}$' | head -1)
echo "$CSC_CODE" > csc_code.txt
echo "$AP_CODE" > ap_code.txt
echo "Firmware: $AP_CODE | CSC: $CSC_CODE"

echo ""; echo "[2/6] Extracting ZIP..."
unzip -o "$ZIP_FILE" >/dev/null 2>&1
rm -f "$ZIP_FILE"
echo "✅ Done"

echo ""; echo "[3/6] Extracting AP..."
AP_FILE=$(find . -maxdepth 1 -name "AP_*.tar.md5" -o -maxdepth 1 -name "AP_*.tar" | head -n 1)
[ -z "$AP_FILE" ] && { echo "❌ AP file not found"; exit 1; }
tar -xf "$AP_FILE" >/dev/null 2>&1
rm -f "$AP_FILE"
echo "✅ Done"

echo ""; echo "[4/6] Preparing filesystem partitions..."
mkdir -p extracted

declare -A PART_IMAGES

SUPER_FILE=$(find . -maxdepth 1 -name "super.img*" | head -n 1)
if [ -n "$SUPER_FILE" ]; then
  echo "  Super partition detected"
  if [[ "$SUPER_FILE" == *.lz4 ]]; then
    lz4 -d "$SUPER_FILE" "super.img" 2>/dev/null
    SUPER_FILE="super.img"
  fi
  if file "$SUPER_FILE" 2>/dev/null | grep -q "sparse"; then
    simg2img "$SUPER_FILE" "super.raw.img" 2>/dev/null || tools/android-tools/simg2img "$SUPER_FILE" "super.raw.img"
    SUPER_FILE="super.raw.img"
  fi
  mkdir -p super_dump
  tools/android-tools/lpunpack "$SUPER_FILE" super_dump 2>/dev/null || echo "  ⚠️ lpunpack failed"

  for PART in $FS_PARTS; do
    IMG=$(find super_dump -maxdepth 1 \( -name "${PART}.img" -o -name "${PART}_a.img" \) | head -n 1)
    [ -n "$IMG" ] && PART_IMAGES["$PART"]="$IMG"
  done
else
  echo "  No super.img - checking standalone partition images"
  for PART in $FS_PARTS; do
    IMG=$(find . -maxdepth 1 \( -name "${PART}.img.lz4" -o -name "${PART}.img" \) | head -n 1)
    [ -z "$IMG" ] && continue
    if [[ "$IMG" == *.lz4 ]]; then
      lz4 -d "$IMG" "${PART}_raw.img" 2>/dev/null
      IMG="${PART}_raw.img"
    fi
    PART_IMAGES["$PART"]="$IMG"
  done
fi

echo ""; echo "[5/6] Extracting partition contents..."
for PART in "${!PART_IMAGES[@]}"; do
  IMG="${PART_IMAGES[$PART]}"
  [ ! -f "$IMG" ] && continue

  if file "$IMG" 2>/dev/null | grep -q "sparse"; then
    simg2img "$IMG" "${PART}_unsparse.img" 2>/dev/null && IMG="${PART}_unsparse.img"
  fi

  mkdir -p "extracted/$PART"
  if tools/erofs-utils/extract.erofs -i "$IMG" -x -o "extracted/$PART" >/dev/null 2>&1; then
    echo "    ✓ $PART extracted (erofs)"
  elif debugfs -R "rdump / extracted/$PART" "$IMG" >/dev/null 2>&1; then
    echo "    ✓ $PART extracted (debugfs)"
  else
    echo "    ⚠️ $PART extraction failed"
  fi
done

rm -rf super_dump super.img super.raw.img ./*_unsparse.img ./*_raw.img

echo ""; echo "[6/6] Searching for files..."
mkdir -p output

MATCH_COUNT=0
declare -A USED_NAMES

for PATTERN in $FIND_PATTERNS; do
  while IFS= read -r FOUND; do
    [ -z "$FOUND" ] && continue
    BASENAME=$(basename "$FOUND")
    RELPATH=$(echo "$FOUND" | sed 's|^extracted/||')

    if [ -n "${USED_NAMES[$BASENAME]:-}" ]; then
      SAFE_PATH=$(dirname "$RELPATH" | sed 's|/|__|g')
      DEST="output/${SAFE_PATH}__${BASENAME}"
    else
      DEST="output/${BASENAME}"
      USED_NAMES["$BASENAME"]=1
    fi

    cp "$FOUND" "$DEST"
    echo "    ✓ $RELPATH"
    MATCH_COUNT=$((MATCH_COUNT + 1))
  done < <(find extracted -type f -iname "$PATTERN" 2>/dev/null)
done

rm -rf extracted

[ "$MATCH_COUNT" -eq 0 ] && { echo "❌ No files matched the given pattern(s)"; exit 1; }

echo ""; echo "Compressing results..."
if [ "$COMPRESSION_LEVEL" != "0" ]; then
  for ITEM in output/*; do
    [ -f "$ITEM" ] || continue
    xz $XZ_FLAGS -T0 "$ITEM" 2>/dev/null && echo "    ✓ $(basename "$ITEM").xz" || true
  done
fi

echo ""; echo "═══════════════════════════════════════"
FILE_COUNT=$(ls -1 output 2>/dev/null | wc -l)
TOTAL_SIZE=$(du -sh output | cut -f1)
echo "✅ Found $FILE_COUNT file(s)"
echo "Total size: $TOTAL_SIZE"
echo ""; echo "Files:"
ls -lh output
echo "═══════════════════════════════════════"
echo "✅ Done!"

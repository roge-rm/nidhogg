#!/bin/sh
# Copy the Chompi firmware sources nidhogg builds from into third_party/chompi.
# Usage: tools/vendor-chompi.sh PATH_TO_CHOMPI_CLONE
# Only source and licences are copied; the vendored files are never edited by hand.
set -eu
src=${1:?path to a CHOMPI clone}
dst=$(dirname "$0")/../third_party/chompi
rm -rf "$dst"
mkdir -p "$dst"
cp "$src"/LICENSE "$src"/THIRD_PARTY.md "$src"/TRADEMARKS.md "$dst"/
for fw in tape tempo wave; do
    c="$src/firmware/chompi-$fw/code"
    d="$dst/$fw"
    mkdir -p "$d/libs/libDaisy" "$d/libs/DaisySP" "$d/libs/coreJSON"
    cp -r "$c/src" "$d/src"
    rm -rf "$d/src/build"
    cp -r "$c/libs/libDaisy/src" "$c/libs/libDaisy/LICENSE" "$d/libs/libDaisy/"
    # FatFs API headers; nidhogg implements the API over plain files
    mkdir -p "$d/libs/libDaisy/fatfs"
    cp "$c"/libs/libDaisy/Middlewares/Third_Party/FatFs/src/ff.h \
       "$c"/libs/libDaisy/Middlewares/Third_Party/FatFs/src/integer.h \
       "$c"/libs/libDaisy/Middlewares/Third_Party/FatFs/src/diskio.h "$d/libs/libDaisy/fatfs/"
    cp -r "$c/libs/DaisySP/Source" "$c/libs/DaisySP/LICENSE" "$d/libs/DaisySP/"
    cp -r "$c/libs/coreJSON/source" "$c/libs/coreJSON/LICENSE" "$d/libs/coreJSON/"
done
git -C "$src" log -1 --format='CHOMPI-Club/CHOMPI %H (%cs)' > "$dst/VERSION"

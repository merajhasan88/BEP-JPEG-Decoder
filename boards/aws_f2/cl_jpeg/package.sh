#!/bin/bash
# package.sh - the source tarball of one commit for build_on_aws.sh: git archive of the paths the CL needs (rtl/,
# boards/aws_f2/, boards/acorn_cle215/provenance.tcl, the licence files) plus a file COMMIT with the full hash, so the
# build on AWS reads exactly that commit and stamps it into the image (OCL register COMMIT).
#   package.sh [commit] [out_dir]       (default: HEAD, the current folder) -> bepjpeg_f2_<8 hex>.tar.gz
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../../.." && pwd)
C=$(git -C "$REPO" rev-parse --verify "${1:-HEAD}^{commit}")
OUT=$(cd "${2:-.}" && pwd)
NAME=bepjpeg_f2_${C:0:8}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
git -C "$REPO" archive --format=tar --prefix=$NAME/ "$C" rtl boards/aws_f2 boards/acorn_cle215/provenance.tcl LICENSE NOTICE.md \
  | tar -x -C "$TMP"
rm -rf "$TMP/$NAME/boards/aws_f2/sim/out"
echo "$C" > "$TMP/$NAME/COMMIT"
tar -czf "$OUT/$NAME.tar.gz" -C "$TMP" "$NAME"
echo "$OUT/$NAME.tar.gz  commit $C  sha256 $(sha256sum "$OUT/$NAME.tar.gz" | cut -d' ' -f1)"

#!/usr/bin/env bash
# Assert that a Windows build of this game imports ONLY system DLLs.
#
# WHY. The Windows release is a MinGW build linked with
# -DPSX_STATIC_RUNTIME=ON (runtime.cmake default for MinGW Release) precisely so
# the exe imports nothing but Windows system DLLs. When that guarantee breaks,
# the exe carries a side-by-side dependency on libgcc_s_seh-1.dll /
# libstdc++-6.dll / SDL*.dll, and the classic failure is 0xc000007b
# (STATUS_INVALID_IMAGE_FORMAT) on the player's machine the moment a
# different-architecture copy of one of those DLLs sits earlier on the search
# path. The zip then still extracts, still shows an icon, and still dies. This
# script turns that into a build-time failure.
#
# Usage:
#   scripts/check_windows_pe.sh <file.exe> [more.exe ...]
#
# Needs a PE-capable objdump: x86_64-w64-mingw32-objdump (cross binutils) or any
# binutils that reads COFF. Override with OBJDUMP=<path>.
set -euo pipefail

# The runtime families that must never appear as an import. Everything else an
# exe imports is either a Windows system DLL or loaded dynamically at run time.
DENY='^(libgcc_s|libstdc\+\+|libwinpthread|libssp|libatomic|libgfortran|libquadmath|libobjc|libgomp|libiconv|libintl|libz|zlib1|z\.dll|SDL2|SDL3|libSDL|libfreetype|libpng|libjpeg|libharfbuzz|libcurl)'

OBJDUMP="${OBJDUMP:-}"
VERBOSE="${VERBOSE:-0}"
if [[ "${1:-}" == "--verbose" ]]; then VERBOSE=1; shift; fi
if [[ -z "${OBJDUMP}" ]]; then
  for cand in x86_64-w64-mingw32-objdump llvm-objdump objdump; do
    if command -v "${cand}" >/dev/null 2>&1; then OBJDUMP="${cand}"; break; fi
  done
fi
[[ -n "${OBJDUMP}" ]] || { echo "error: no objdump found (set OBJDUMP=<path>)" >&2; exit 1; }
[[ $# -ge 1 ]] || { echo "usage: $0 <file.exe> [...]" >&2; exit 2; }

status=0
for exe in "$@"; do
  if [[ ! -f "${exe}" ]]; then echo "error: ${exe} not found" >&2; exit 1; fi
  head -c2 "${exe}" | grep -q 'MZ' \
    || { echo "FAIL ${exe}: not a PE (no MZ header) -- wrong platform built?"; status=1; continue; }

  imports="$("${OBJDUMP}" -p "${exe}" 2>/dev/null \
    | awk '/^[[:space:]]*DLL Name:/{print $3}' | sort -u || true)"
  [[ -n "${imports}" ]] || { echo "FAIL ${exe}: objdump found no imports"; status=1; continue; }

  bad="$(grep -Ei "${DENY}" <<<"${imports}" || true)"
  n="$(wc -l <<<"${imports}" | tr -d ' ')"
  if [[ -n "${bad}" ]]; then
    echo "FAIL ${exe}: imports non-system DLLs (0xc000007b risk):"
    printf '  %s\n' ${bad}
    echo "  rebuild with -DPSX_STATIC_RUNTIME=ON, or bundle these DLLs beside the exe"
    status=1
  else
    echo "OK   ${exe}: ${n} imports, all Windows system DLLs"
  fi
  if [[ "${VERBOSE}" == 1 ]]; then
    printf '       %s\n' ${imports}
  fi
done

exit "${status}"

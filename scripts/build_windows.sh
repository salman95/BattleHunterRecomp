#!/usr/bin/env bash
# Cross-build the Windows release from a Linux (or macOS) workstation.
#
# WHY THIS EXISTS. The artifact players download is cut on windows-2022 with
# MSYS2 MinGW-w64 by .github/workflows/release.yml — that is the route every
# psxrecomp title ships (psxrecomp/docs/ci/README.md: the release matrix is
# ubuntu-24.04 / windows-2022 / macos-15). This script is the developer-side
# mirror of that job: same framework packager, same static MinGW exe, built with
# a MinGW-w64 GCC cross toolchain so a Linux machine can produce the very file
# the release carries and immediately Proton-test it:
#
#   scripts/build_windows.sh
#   scripts/test_windows_proton.sh dist/stage-game-windows-x64
#
# It runs the same pieces CI runs — tools/ci/prefetch_sdl3.sh, Windows-built
# emitters for the shipped overlay_toolchain/, the runtime configure gate
# (PSXRECOMP_REQUIRE_GAME_C=ON) and tools/package_game_release.sh through
# scripts/package_release.sh — so dist/ gets a real bh-<version>-windows-x64.zip,
# not a hand-assembled folder.
#
# Usage (from the repo root):
#   scripts/build_windows.sh [options]
#
# Options:
#   --toolchain-root DIR   a MinGW-w64 unpack whose layout is <root>/bin +
#                          <root>/<triple> (default: $PSX_WIN_TOOLCHAIN_ROOT,
#                          then .cache/mingw-w64/usr, then ~/.local/opt, then
#                          <triple>-gcc on PATH)
#   --compiler FAMILY      gcc | clang | auto (default auto, which prefers gcc)
#   --build-dir DIR        runtime build dir             (default build-windows)
#   --emitters-dir DIR     Windows emitters build dir    (default build-recompiler-windows)
#   --no-package           stop after the exe; skip dist/*.zip staging
#   --no-emitters          reuse the emitters already in --emitters-dir
#   --fetch-toolchain      no root? unpack a MinGW-w64 GCC into .cache/mingw-w64
#   -h | --help            this text
#
# Toolchains, in order of preference — all speak the MinGW-w64 ABI and all are
# GCC, because that is what the release CI links with:
#
#   Arch/CachyOS   sudo pacman -S --needed mingw-w64-gcc mingw-w64-crt \
#                    mingw-w64-headers mingw-w64-binutils mingw-w64-winpthreads
#   Debian/Ubuntu  sudo apt-get install g++-mingw-w64-x86-64
#   no root at all scripts/build_windows.sh --fetch-toolchain
#                  (fetches those same Arch packages, pinned by SHA-256, and
#                  unpacks them under .cache/ — nothing is installed)
#
# Clang works for the runtime but NOT yet for the emitters: the framework's
# vendored rabbitizer and toml11 rely on transitive <cstdlib> / <exception>
# includes that libstdc++ provides and libc++ does not, so a clang build stops
# with "use of undeclared identifier 'malloc'". --compiler clang is therefore
# only worth trying after that is fixed upstream.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"

TOOLCHAIN_ROOT="${PSX_WIN_TOOLCHAIN_ROOT:-}"
COMPILER="${PSX_WIN_COMPILER:-auto}"
BUILD_DIR="build-windows"
EMITTERS_DIR="build-recompiler-windows"
TRIPLE="x86_64-w64-mingw32"
DO_PACKAGE=1
DO_EMITTERS=1
FETCH_TOOLCHAIN=0

# Arch [extra] MinGW-w64 set, pinned to the versions this script was validated
# with (GCC 16.2.0 / mingw-w64 14.0.0 / binutils 2.47). Geo-mirror is the Arch
# CDN. Digests are the published package files' SHA-256: a changed digest fails
# the fetch instead of silently building with different compilers.
MINGW_PACK_BASE="https://geo.mirror.pkgbuild.com/extra/os/x86_64"
MINGW_PACKS=(
  "mingw-w64-headers-14.0.0-1-any.pkg.tar.zst=5b8d6e83aa5c3b456d96a12a4af51518ddd71600d66048ced4b34c0b40a3fb19"
  "mingw-w64-crt-14.0.0-1-any.pkg.tar.zst=a809d9b6608235e5b693f1ebda97aa6c3539783c84509cb8db3306ef56ad0a4f"
  "mingw-w64-winpthreads-14.0.0-1-any.pkg.tar.zst=21a4dd95e8a5f0b802d8585e59024f2cfbbd435cee31ed31b511159d9d10579b"
  "mingw-w64-binutils-2.47-1-x86_64.pkg.tar.zst=a174f1b5894674b039d356878198e146053fa9527b282d6fac3acb46309b117d"
  "mingw-w64-gcc-16.2.0-2-x86_64.pkg.tar.zst=9fde71b655105ed8704fb1494a39f3b94d0a138df9dface881588e6cef4886f1"
)

usage() { sed -n '2,53p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --toolchain-root) TOOLCHAIN_ROOT="${2:?}"; shift 2 ;;
    --compiler) COMPILER="${2:?}"; shift 2 ;;
    --build-dir) BUILD_DIR="${2:?}"; shift 2 ;;
    --emitters-dir) EMITTERS_DIR="${2:?}"; shift 2 ;;
    --no-package) DO_PACKAGE=0; shift ;;
    --no-emitters) DO_EMITTERS=0; shift ;;
    --fetch-toolchain) FETCH_TOOLCHAIN=1; shift ;;
    -h|--help) usage ;;
    *) echo "error: unknown option: $1" >&2; usage 2 ;;
  esac
done

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die() { echo "error: $*" >&2; exit 1; }

# --- 1. Toolchain ------------------------------------------------------------
fetch_mingw_gcc() {
  local out="${ROOT}/.cache/mingw-w64"
  local dl="${ROOT}/.cache/mingw-w64-dl"
  local unpack=()
  if command -v bsdtar >/dev/null 2>&1; then
    unpack=(bsdtar -xf)
  elif tar --help 2>&1 | grep -q -- '--zstd'; then
    unpack=(tar --zstd -xf)
  else
    die "no .pkg.tar.zst extractor (need bsdtar, or GNU tar + zstd)"
  fi
  say "Unpacking a MinGW-w64 GCC into .cache/mingw-w64 (nothing is installed)"
  mkdir -p "${dl}" "${out}"
  local spec name sha
  for spec in "${MINGW_PACKS[@]}"; do
    name="${spec%%=*}"; sha="${spec#*=}"
    if [[ ! -f "${dl}/${name}" ]]; then
      curl -fsSL --http1.1 --retry 5 --retry-all-errors -o "${dl}/${name}" \
        "${MINGW_PACK_BASE}/${name}"
    fi
    printf '%s  %s\n' "${sha}" "${dl}/${name}" | sha256sum -c - >/dev/null \
      || die "${name} does not match its pinned SHA-256"
    "${unpack[@]}" "${dl}/${name}" -C "${out}"
  done
  TOOLCHAIN_ROOT="${out}/usr"
}

find_toolchain_root() {
  if [[ -n "${TOOLCHAIN_ROOT}" ]]; then
    [[ -d "${TOOLCHAIN_ROOT}/bin" ]] \
      || { echo "error: --toolchain-root ${TOOLCHAIN_ROOT} has no bin/" >&2; return 1; }
    return 0
  fi
  local cand
  for cand in "${ROOT}/.cache/mingw-w64/usr" "${ROOT}/.cache/llvm-mingw" \
              "${HOME}/.local/opt/mingw-w64/usr" /opt/mingw-w64/usr; do
    if [[ -d "${cand}/bin" ]]; then TOOLCHAIN_ROOT="${cand}"; return 0; fi
  done
  # A distro install puts the cross binutils + compilers on PATH with the
  # sysroot at /usr/<triple>; no --toolchain-root needed.
  if command -v "${TRIPLE}-gcc" >/dev/null 2>&1 || command -v "${TRIPLE}-clang" >/dev/null 2>&1; then
    TOOLCHAIN_ROOT=""
    return 0
  fi
  return 1
}

if ! find_toolchain_root; then
  if [[ "${FETCH_TOOLCHAIN}" -eq 1 ]]; then
    fetch_mingw_gcc
  else
    cat >&2 <<EOF
error: no Windows cross toolchain found.

  Arch/CachyOS   sudo pacman -S --needed mingw-w64-gcc mingw-w64-crt \\
                   mingw-w64-headers mingw-w64-binutils mingw-w64-winpthreads
  Debian/Ubuntu  sudo apt-get install g++-mingw-w64-x86-64
  no root here   rerun with --fetch-toolchain (unpacks a MinGW-w64 GCC under
                 .cache/, nothing installed), or pass
                 --toolchain-root <dir containing bin/ and ${TRIPLE}/>
EOF
    exit 1
  fi
fi

if [[ -n "${TOOLCHAIN_ROOT}" ]]; then
  TOOLCHAIN_ROOT="$(cd "${TOOLCHAIN_ROOT}" && pwd)"
  export PATH="${TOOLCHAIN_ROOT}/bin:${PATH}"
fi

# Where the MinGW runtime DLLs live (only needed if a PE turns out to import
# them — it must not) and where the PE-capable objdump lives. Both are looked up
# by content rather than by convention: Arch puts them in the sysroot's bin,
# llvm-mingw in <triple>/bin, MSYS2 in /mingw64/bin.
RUNTIME_BIN_DIR=""
for cand in "${TOOLCHAIN_ROOT}/${TRIPLE}/bin" "/usr/${TRIPLE}/bin" /mingw64/bin \
            "${TOOLCHAIN_ROOT}/bin"; do
  [[ -n "${cand}" && -d "${cand}" ]] || continue
  if [[ -f "${cand}/libwinpthread-1.dll" || -x "${cand}/${TRIPLE}-objdump" ]]; then
    RUNTIME_BIN_DIR="${cand}"
    break
  fi
done

say "Toolchain: ${TOOLCHAIN_ROOT:-<${TRIPLE} on PATH>} (compiler=${COMPILER})"
[[ -n "${RUNTIME_BIN_DIR}" ]] && echo "MinGW bin: ${RUNTIME_BIN_DIR}"

# --- 2. SDL3 source ----------------------------------------------------------
# Same pinned tarball CI prefetches (CMake's own download dies on HTTP/2).
SDL3_SRC="${ROOT}/.cache/sdl3-src"
if [[ ! -f "${SDL3_SRC}/CMakeLists.txt" ]]; then
  say "Prefetching the pinned SDL3 source"
  bash "${ROOT}/psxrecomp/tools/ci/prefetch_sdl3.sh" --out-dir "${SDL3_SRC}"
else
  say "SDL3 source cached at .cache/sdl3-src"
fi

# --- 3. Windows emitters -----------------------------------------------------
# overlay_toolchain/ ships psxrecomp-game.exe + psxrecomp-bios.exe: the game
# turns code it streams off the PLAYER's disc into native code on the PLAYER's
# machine, so the emitters have to be Windows binaries even though this script
# runs on Linux. psxrecomp/tools/ci/build_emitters.sh cannot be used here: it
# picks bare clang/clang++ from a toolchain pack, which is right on a Windows
# host and wrong for a cross build, where only <triple>-clang targets Windows.
if [[ "${DO_EMITTERS}" -eq 1 ]]; then
  say "Building Windows emitters -> ${EMITTERS_DIR}"
  cmake -S psxrecomp/recompiler -B "${EMITTERS_DIR}" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DPSXRECOMP_STATIC_CLI=ON \
    -DCMAKE_TOOLCHAIN_FILE="${ROOT}/toolchain/windows-x64.cmake" \
    -DPSX_WIN_TOOLCHAIN_ROOT="${TOOLCHAIN_ROOT}" \
    -DPSX_WIN_COMPILER="${COMPILER}" \
    -DMINGW_TRIPLE="${TRIPLE}"
  cmake --build "${EMITTERS_DIR}" --target psxrecomp-game psxrecomp-bios -j"$(nproc)"
fi
for bin in psxrecomp-game psxrecomp-bios; do
  found=0
  for cand in "${EMITTERS_DIR}/${bin}.exe" "${EMITTERS_DIR}/Release/${bin}.exe"; do
    [[ -f "${cand}" ]] && found=1
  done
  [[ "${found}" -eq 1 ]] || die "${bin}.exe missing under ${EMITTERS_DIR}"
done

# --- 4. The game -------------------------------------------------------------
# Flags mirror the release workflow's configure step. The Vulkan backend needs
# headers + glslc only (SPIR-V is host-independent, so the host's glslc compiles
# shaders for a Windows target); runtime.cmake stages a private include dir when
# /usr/include itself would not reach the cross compiler.
say "Configuring the Windows game runtime -> ${BUILD_DIR}"
EXTRA=()
if command -v glslc >/dev/null 2>&1; then
  EXTRA+=("-DGLSLC_EXE=$(command -v glslc)")
  if [[ -z "${VULKAN_SDK:-}" && -f /usr/include/vulkan/vulkan.h ]]; then
    export VULKAN_SDK=/usr
  fi
else
  echo "note: no glslc on PATH -> no Vulkan backend (OpenGL only); CI ships Vulkan on"
  EXTRA+=("-DPSX_ENABLE_VULKAN=OFF")
fi
[[ -f VERSION ]] || die "VERSION missing (the packager compares the build stamp to it)"
VERSION="$(tr -d '[:space:]' <VERSION)"

CONFIGURE_LOG="${BUILD_DIR}-configure.log"
cmake -S . -B "${BUILD_DIR}" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_TOOLCHAIN_FILE="${ROOT}/toolchain/windows-x64.cmake" \
  -DPSX_WIN_TOOLCHAIN_ROOT="${TOOLCHAIN_ROOT}" \
  -DPSX_WIN_COMPILER="${COMPILER}" \
  -DMINGW_TRIPLE="${TRIPLE}" \
  -DPSXRECOMP_REQUIRE_GAME_C=ON \
  -DPSXRECOMP_BIOS_STALE_FATAL=ON \
  -DPSX_SETUP_WIZARD=ON \
  -DPSX_GAME_VERSION="${VERSION}" \
  -DFETCHCONTENT_SOURCE_DIR_SDL3="${SDL3_SRC}" \
  "${EXTRA[@]}" 2>&1 | tee "${CONFIGURE_LOG}"

# The same asserts the release workflow makes. A cross configure that quietly
# took the setup-host path would package a build kit as a game.
grep -q 'linking generated game C (full runtime)' "${CONFIGURE_LOG}" \
  || die "CMake did not link the generated game C (see ${CONFIGURE_LOG})"
grep -qE 'BIOS backends linked: .*OpenBIOS' "${CONFIGURE_LOG}" \
  || die "OpenBIOS backend not linked"
grep -q 'PSX_STATIC_RUNTIME:BOOL=ON' "${BUILD_DIR}/CMakeCache.txt" \
  || die "not a statically linked MinGW build (PSX_STATIC_RUNTIME) — the exe would import libgcc/libstdc++"

say "Building psx-runtime"
cmake --build "${BUILD_DIR}" --target psx-runtime -j"$(nproc)"
ls -la "${BUILD_DIR}"/*.exe

# The static-runtime claim is worth less as a configure-time wish than as a
# fact about the bytes that just got built.
say "Checking the exe's DLL imports"
# check_windows_pe.sh falls back to <triple>-objdump on PATH, which we set up
# above -- but hand it the exact binary when we know where it is.
if [[ -n "${RUNTIME_BIN_DIR}" && -x "${RUNTIME_BIN_DIR}/${TRIPLE}-objdump" ]]; then
  export OBJDUMP="${RUNTIME_BIN_DIR}/${TRIPLE}-objdump"
fi
scripts/check_windows_pe.sh --verbose "${BUILD_DIR}/BattleHunter_Recompiled.exe"

# --- 5. Package --------------------------------------------------------------
if [[ "${DO_PACKAGE}" -eq 1 ]]; then
  say "Packaging dist/bh-${VERSION}-windows-x64.zip"
  export RELEASE_VERSION="${VERSION}"
  export PSXRECOMP_RUNTIME_BIN_DIR="${RUNTIME_BIN_DIR:-/usr/${TRIPLE}/bin}"
  scripts/package_release.sh "${BUILD_DIR}" windows-x64 "${EMITTERS_DIR}"
  echo
  echo "Next: scripts/test_windows_proton.sh dist/stage-game-windows-x64"
fi

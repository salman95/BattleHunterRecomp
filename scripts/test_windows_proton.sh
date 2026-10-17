#!/usr/bin/env bash
# Run the Windows build under Valve's Proton and say whether it actually works.
#
# WHY. There is no Windows box in the loop. Proton (Wine + DXVK/etc., shipped
# with Steam) runs PE binaries on this Linux machine, so a cross-built
# BattleHunter_Recompiled.exe can be executed here before anyone calls it a
# Windows release. It is a translation layer, not Windows: passing here proves
# the binary loads, finds its staged data, initialises SDL/GL/Vulkan and draws;
# it does not replace a Windows playtest. Say so in release notes.
#
# Usage:
#   scripts/test_windows_proton.sh [payload] [options] [-- extra game args]
#
#   payload   a staged release dir (dist/stage-game-windows-x64), a directory
#             holding BattleHunter_Recompiled.exe, or a bh-*-windows-x64.zip
#             (default: newest dist/stage-game-windows-x64, else newest zip)
#   --proton PATH      proton script to use (default: newest Proton* found in
#                      the Steam library folders; env PROTON also honoured)
#   --prefix DIR       Wine prefix to create/use
#                      (default: .cache/proton-windows)
#   --probe NAME       run one probe instead of the default set:
#                      headless | gl | launcher
#   --timeout SECS     per-probe wall clock (default 60; the first probe also
#                      pays prefix creation, so allow a few minutes once)
#   --headed           do not wrap GUI probes in Xvfb (needs a real DISPLAY)
#   --in-place         probe the payload where it lies, even inside this repo
#   --no-screenshot    do not grab the screen while the launcher is up. By
#                      default the launcher probe screenshots itself
#                      (.cache/proton-logs/launcher.png): "a process survived"
#                      is weak evidence next to a picture of the UI drawn.
#                      (the launcher then offers dev "Build tools" instead of
#                      the player's OpenBIOS + disc picker)
#   --disc PATH        hand the probe a .cue to boot with (a real dump turns
#                      the smoke test into a real playtest)
#
# Exit 0 = every probe behaved; 1 = at least one failed.
#
# Probes:
#   headless   --headless --no-launcher : boots far enough to look for the disc
#              and reports on it. Proves the PE runs and the runtime wires up.
#   gl         --headless-opengl        : drives the OpenGL renderer, so SDL's
#              GL path and the DLL-load dance under Wine get exercised.
#   launcher   no args                  : the recomp-ui launcher window, which
#              is what a player sees on first run. Must still be alive when the
#              timeout fires.
#
# Disc note: no PS1 disc image ships with, or is looked for by, this repo (the
# zip carries only OpenBIOS). Without --disc the game can only get as far as
# "no disc yet" -- which is still the exact code path a first-run player hits.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"

PROTON="${PROTON:-}"
PREFIX="${PROTON_PREFIX:-${ROOT}/.cache/proton-windows}"
PAYLOAD=""
PROBES=()
TIMEOUT=60
HEADED=0
DISC=""
IN_PLACE=0
SHOT=1
EXTRA_ARGS=()
EXE_NAME="BattleHunter_Recompiled.exe"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --proton) PROTON="${2:?}"; shift 2 ;;
    --prefix) PREFIX="${2:?}"; shift 2 ;;
    --probe) PROBES+=("${2:?}"); shift 2 ;;
    --timeout) TIMEOUT="${2:?}"; shift 2 ;;
    --headed) HEADED=1; shift ;;
    --disc) DISC="${2:?}"; shift 2 ;;
    --in-place) IN_PLACE=1; shift ;;
    --no-screenshot) SHOT=0; shift ;;
    --) shift; EXTRA_ARGS+=("$@"); break ;;
    -*) echo "error: unknown option $1" >&2; exit 2 ;;
    *) PAYLOAD="$1"; shift ;;
  esac
done
[[ "${#PROBES[@]}" -gt 0 ]] || PROBES=(headless gl launcher)

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die() { echo "error: $*" >&2; exit 1; }

# --- 1. The payload ----------------------------------------------------------
if [[ -z "${PAYLOAD}" ]]; then
  PAYLOAD="$(ls -1d dist/stage-game-windows-x64 2>/dev/null | head -1 || true)"
  [[ -n "${PAYLOAD}" ]] \
    || PAYLOAD="$(ls -1t dist/bh-*-windows-x64.zip 2>/dev/null | head -1 || true)"
fi
[[ -n "${PAYLOAD}" ]] || die "no Windows payload found; run scripts/build_windows.sh first"

if [[ -f "${PAYLOAD}" && "${PAYLOAD}" == *.zip ]]; then
  say "Extracting ${PAYLOAD}"
  WORK="${ROOT}/.cache/proton-run"
  rm -rf "${WORK}"; mkdir -p "${WORK}"
  python3 -m zipfile -e "${PAYLOAD}" "${WORK}"
  PAYLOAD="${WORK}"
fi
[[ -d "${PAYLOAD}" ]] || die "${PAYLOAD} is not a directory"
# Absolute, so the out-of-tree test below can compare against ${ROOT}.
PAYLOAD="$(cd "${PAYLOAD}" && pwd)"

# The zip stores the payload at the root; a raw build tree nests it one deeper.
EXE="${PAYLOAD}/${EXE_NAME}"
if [[ ! -f "${EXE}" ]]; then
  EXE="$(find "${PAYLOAD}" -maxdepth 3 -name "${EXE_NAME}" -type f | head -1 || true)"
fi
[[ -n "${EXE}" && -f "${EXE}" ]] || die "${EXE_NAME} not found under ${PAYLOAD}"
for must in game.toml bios/openbios.bin; do
  [[ -e "${PAYLOAD}/${must}" ]] || echo "note: ${must} missing from the payload"
done

# Run out of the tree. The launcher walks up from the exe looking for a psxrecomp
# checkout (psxrecomp/psxrecomp_cli.py); a payload staged under dist/ or .cache/
# is INSIDE this repo, and the launcher then behaves like a developer's setup
# host -- its first-run page becomes "Build tools: download the portable
# cmake/clang pack", which no player ever sees. Copy it out and probe what a
# player actually runs (OpenBIOS + disc picker).
if [[ "${IN_PLACE}" -eq 0 && "${PAYLOAD}/" == "${ROOT}"/* ]]; then
  OUT="${TMPDIR:-/tmp}/bh-windows-probe"
  say "Copying the payload out of the repo (the launcher detects a dev checkout otherwise)"
  rm -rf "${OUT}"; mkdir -p "${OUT}"
  cp -a "${PAYLOAD}/." "${OUT}/"
  PAYLOAD="${OUT}"
  EXE="${PAYLOAD}/${EXE_NAME}"
  [[ -f "${EXE}" ]] || EXE="$(find "${PAYLOAD}" -maxdepth 3 -name "${EXE_NAME}" -type f | head -1)"
fi

# --- 2. Proton ---------------------------------------------------------------
steam_roots() {
  # Every Steam library on the machine, including ones on other drives: Proton
  # lives in <library>/steamapps/common/<Proton ...>/proton.
  local root
  for root in "${HOME}/.local/share/Steam" "${HOME}/.steam/root" "${HOME}/.steam/steam"; do
    [[ -f "${root}/steamapps/libraryfolders.vdf" ]] || continue
    echo "${root}"
    grep -oE '"path"[[:space:]]*"[^"]+"' "${root}/steamapps/libraryfolders.vdf" \
      | sed -E 's/.*"([^"]+)"$/\1/'
  done
}

find_proton() {
  local root cand
  while read -r root; do            # "Proton - Experimental" first: newest Wine
    [[ -n "${root}" ]] || continue
    cand="${root}/steamapps/common/Proton - Experimental/proton"
    if [[ -x "${cand}" ]]; then echo "${cand}"; return 0; fi
  done < <(steam_roots)
  while read -r root; do            # then any other Proton tool in any library
    [[ -n "${root}" && -d "${root}/steamapps/common" ]] || continue
    for cand in "${root}"/steamapps/common/Proton*/proton; do
      if [[ -x "${cand}" ]]; then echo "${cand}"; return 0; fi
    done
  done < <(steam_roots)
  return 1
}

if [[ -z "${PROTON}" ]]; then
  PROTON="$(find_proton || true)"
fi
if [[ -z "${PROTON}" || ! -x "${PROTON}" ]]; then
  cat >&2 <<EOF
error: no Proton found.

  Install Steam and enable Steam Play (Steam -> Settings -> Compatibility ->
  "Enable Steam Play for all other titles") so a Proton tool gets downloaded,
  or point me straight at one:
      PROTON="/path/to/steamapps/common/Proton - Experimental/proton" \\
          scripts/test_windows_proton.sh
EOF
  exit 1
fi
say "Proton:  ${PROTON}"
say "Payload: ${PAYLOAD}"
echo "Exe:     ${EXE}"

mkdir -p "${PREFIX}"
STEAM_CLIENT="${STEAM_COMPAT_CLIENT_INSTALL_PATH:-${HOME}/.local/share/Steam}"

# --- 3. Display --------------------------------------------------------------
XVFB=()
if [[ "${HEADED}" -eq 0 && -z "${DISPLAY:-}" && "${XDG_SESSION_TYPE:-}" != "wayland" ]]; then
  if command -v xvfb-run >/dev/null 2>&1; then
    XVFB=(xvfb-run -a)
    echo "Display: virtual (xvfb-run)"
  else
    echo "note: no DISPLAY and no xvfb-run; GUI probes will fail to open a window"
  fi
else
  echo "Display: ${DISPLAY:-<wayland>}"
fi

# --- 4. Probes ---------------------------------------------------------------
# A PE that dies on load exits with an NTSTATUS (0xC0000005 & friends); map the
# common ones so a failure names its own cause.
status_name() {
  case "$1" in
    0) echo "clean exit" ;;
    124|137) echo "still running when the timeout fired" ;;
    3221225477|0xC0000005) echo "ACCESS_VIOLATION (crashed)" ;;
    3221225781|0xC0000135) echo "DLL NOT FOUND (a non-system DLL is missing beside the exe)" ;;
    3221225777|0xC0000131) echo "DLL INIT FAILED" ;;
    3221225495|0xC0000017) echo "STATUS_INVALID_IMAGE_FORMAT (wrong-architecture DLL on the search path)" ;;
    3221225620|0xC000007B) echo "STATUS_INVALID_IMAGE_FORMAT (0xc000007b: mixed 32/64-bit or missing DLL)" ;;
    *) echo "exit code $1" ;;
  esac
}

overall=0
LOGDIR="${ROOT}/.cache/proton-logs"
mkdir -p "${LOGDIR}"

run_probe() {
  local name="$1"; shift
  local log="${LOGDIR}/${name}.log"
  say "probe: ${name}  ($*)"
  local disc_args=()
  [[ -n "${DISC}" ]] && disc_args=(--disc "${DISC}")
  # `runinprefix` runs the exe inside Proton's session (its prefix, its DXVK /
  # wine geometry) with the child's stdout attached, so the runtime's own
  # psxrecomp: lines land in the log. `proton run` detaches them -- useful for
  # a real launch, useless for a smoke test.
  # cwd = the payload dir: the runtime finds game.toml, bios/ and
  # overlay_toolchain/ next to the exe, exactly as a player's copy would.
  set +e
  ( cd "$(dirname "${EXE}")" &&
    STEAM_COMPAT_DATA_PATH="${PREFIX}" \
    STEAM_COMPAT_CLIENT_INSTALL_PATH="${STEAM_CLIENT}" \
    WINEDEBUG="${WINEDEBUG:--all}" \
      timeout -k 5 "${TIMEOUT}" "${XVFB[@]+"${XVFB[@]}"}" "${PROTON}" runinprefix \
        "$(basename "${EXE}")" "$@" \
        "${disc_args[@]+"${disc_args[@]}"}" "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}" ) \
      >"${log}" 2>&1
  local code=$?
  set -e
  echo "  exit=${code} $(status_name "${code}")  log=${log}"

  # The runtime prints this as its first act. No line = the PE never got that
  # far (bad load, missing DLL, wrong arch) and nothing else is worth reading.
  if ! grep -q 'psxrecomp: main() entered' "${log}"; then
    echo "  FAIL: the runtime never started (no 'main() entered' in the log)"
    tail -25 "${log}" | sed 's/^/  | /'
    overall=1
    return 0
  fi

  case "${name}" in
    headless|gl)
      # These probes exit on their own. Without a disc the correct behaviour is
      # to say so and leave; with one, they should be running when the timeout
      # fires. A timeout with no disc, or an NTSTATUS crash either way, is a
      # real problem.
      if [[ "${code}" -ge 3221225472 ]]; then
        echo "  FAIL: crashed under translation"; tail -20 "${log}" | sed 's/^/  | /'; overall=1
      elif grep -q 'no disc image selected' "${log}"; then
        [[ -n "${DISC}" ]] \
          && { echo "  FAIL: --disc given but the runtime still found no disc" \
               ; tail -20 "${log}" | sed 's/^/  | /'; overall=1; } \
          || echo "  PASS: booted, looked for the disc, reported cleanly"
      elif [[ "${code}" -eq 124 || "${code}" -eq 137 ]]; then
        echo "  PASS: still running when the timeout fired (that is the goal with a disc)"
      else
        echo "  PASS: the runtime ran and exited on its own (exit ${code})"
      fi
      ;;
    launcher)
      # First run is the launcher window: it is supposed to sit there waiting
      # for a disc pick, so "killed by the timeout" is the pass condition.
      if [[ "${code}" -eq 124 || "${code}" -eq 137 || "${code}" -eq 0 ]]; then
        echo "  PASS: launcher came up and stayed up"
      else
        echo "  FAIL: launcher died early"; tail -20 "${log}" | sed 's/^/  | /'; overall=1
      fi
      ;;
    *) die "unknown probe ${name}" ;;
  esac
  grep -E 'psxrecomp:|err:' "${log}" | tail -6 | sed 's/^/  | /'
}

# "The process was alive" is weak evidence next to a picture of the launcher
# with its fonts, its tabs and its disc picker actually drawn. Grab one while
# the GUI probe is on screen (spectacle, maim or ImageMagick, whichever exists).
grab_shot() {
  local path="$1" tool=""
  if command -v spectacle >/dev/null 2>&1; then
    spectacle -b -n -o "${path}" >/dev/null 2>&1 && tool=spectacle
  fi
  if [[ -z "${tool}" ]] && command -v maim >/dev/null 2>&1; then
    maim "${path}" >/dev/null 2>&1 && tool=maim
  fi
  if [[ -z "${tool}" ]] && command -v import >/dev/null 2>&1; then
    import -window root "${path}" >/dev/null 2>&1 && tool=import
  fi
  if [[ -n "${tool}" && -s "${path}" ]]; then
    echo "  screenshot (${tool}): ${path}"
  else
    echo "  note: no screenshot taken (needs spectacle, maim or ImageMagick)"
  fi
}

for probe in "${PROBES[@]}"; do
  case "${probe}" in
    headless) run_probe headless --headless --no-launcher ;;
    gl)       run_probe gl --headless-opengl --no-launcher ;;
    launcher)
      if [[ "${SHOT}" -eq 1 ]]; then
        # Halfway through the probe window, with the launcher on screen.
        ( sleep "$(( TIMEOUT / 2 ))"; grab_shot "${LOGDIR}/launcher.png" ) &
      fi
      run_probe launcher ;;
    *) die "unknown probe '${probe}' (headless | gl | launcher)" ;;
  esac
done

say "Verdict"
if [[ "${overall}" -eq 0 ]]; then
  echo "  Proton ran the Windows build${DISC:+ with your disc}: $(
    [[ -n "${DISC}" ]] && echo 'booted and played' || echo 'no crashes in any probe')"
  [[ -n "${DISC}" ]] || echo "  (pass --disc <your.cue> to test an actual boot; no dump ships with this repo)"
else
  echo "  At least one probe failed -- see ${LOGDIR}/*.log"
fi
exit "${overall}"

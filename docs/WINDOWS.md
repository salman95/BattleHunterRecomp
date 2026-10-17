# Windows build

The Windows release is `bh-<version>-windows-x64.zip`: the compiled game, built from the same
committed `generated/` C as the Linux build, packaged by the same framework packager. There is no
installer and nothing to generate on the player's machine — extract, run `BattleHunter_Recompiled.exe`,
point the launcher at your own dump.

| Artifact | Cut by | What it is |
|---|---|---|
| `bh-<v>-windows-x64.zip` | CI, `windows-2022` + MSYS2 MinGW-w64 | the game exe (static MinGW build), `game.toml`, `assets/`, bundled OpenBIOS, mod catalog, `overlay_toolchain/` |
| `bh-<v>-linux-x64.zip` | CI, `ubuntu-24.04` | same payload, ELF |
| `BattleHunter-Recompiled-v<v>-x86_64.AppImage` | CI, `ubuntu-24.04` | the Linux payload in one file |

## How the Windows artifact is cut

Every psxrecomp title builds the same way — the framework's release matrix is
`ubuntu-24.04` (linux-x64) / `windows-2022` (windows-x64) / `macos-15` (macos-arm64, macos-x64), see
`psxrecomp/docs/ci/README.md` and the template `psxrecomp/docs/ci/templates/game-release.yml`. This
repo's [release workflow](../.github/workflows/release.yml) is that template with two title-specific
deltas: no macOS rows yet (nobody has built this title on a Mac), and the AppImage steps stay
Linux-only because they wrap the Linux payload.

The Windows job:

1. `msys2/setup-msys2` with `msystem: MINGW64`, and the whole job runs in the `msys2 {0}` shell — the
   build needs the MinGW-w64 toolchain and the `/mingw64` prefix, which the runner's default Git Bash
   does not put on PATH.
2. SDL3 is FetchContent-built from the pinned tarball (MSYS2 ships SDL2; the runtime defaults to SDL3).
   zlib likewise (`PSX_ZLIB_FETCH`), statically.
3. The **emitters** that ship inside `overlay_toolchain/` are built with the portable `cmake-clang-v1`
   pack (`fetch-toolchain` action) with `PSXRECOMP_STATIC_CLI=ON`, so `psxrecomp-game.exe` imports no
   MSYS2 DLLs on the player's machine.
4. Configure with `-DPSXRECOMP_REQUIRE_GAME_C=ON -DPSXRECOMP_BIOS_STALE_FATAL=ON`, then assert from the
   configure log that the generated game C and the OpenBIOS backend were linked and that
   `PSX_HAVE_VULKAN` is on. Vulkan needs only headers + `glslc`; the ICD is loaded dynamically via SDL.
5. `scripts/package_release.sh build-ci windows-x64 build-recompiler` → the shared packager stages the
   exe plus its runtime data, bundles any MinGW DLL the PE actually imports, runs
   `psxrecomp/tools/ci/sign_windows.sh`, and binds the execution contract to the **final** bytes
   (after signing, before zipping).
6. Two verification steps: the zip-content gates, and **`scripts/check_windows_pe.sh`** — see below.

### Why the exe is statically linked

`runtime.cmake` defaults `PSX_STATIC_RUNTIME=ON` for MinGW Release. A default MinGW build imports
`libgcc_s_seh-1.dll`, `libstdc++-6.dll` and SDL's DLL, and side-by-side DLL resolution is how
`0xc000007b` (`STATUS_INVALID_IMAGE_FORMAT`) happens: a different-architecture copy of one of those
names earlier on the search path (System32, another app on `PATH`) and the game dies on launch on a
machine where everything looked installed. Statically linking them makes the exe import **only**
Windows system DLLs, so it runs from any folder with nothing bundled beside it and that failure mode
becomes structurally impossible.

The guarantee is asserted on the bytes that ship, not assumed:

```sh
scripts/check_windows_pe.sh --verbose build-windows/BattleHunter_Recompiled.exe
# OK …: 31 imports, all Windows system DLLs
```

Measured for the current build: `KERNEL32 / USER32 / GDI32 / SHELL32 / OLE32 / ADVAPI32 / WINMM /
WS2_32 / VERSION / IMM32 / COMDLG32 / SETUPAPI / DBGHHELP / BCRYPT / OPENGL32 / D2D1 / DWRITE`
(recomp-ui's DirectWrite+Direct2D text path) and the `api-ms-win-crt-*` UCRT apiset. No `lib*` DLLs,
no `SDL*.dll`, no `zlib1.dll` — and the packager therefore stages no `.dll` at the zip root, which CI
also checks.

### Code signing

Unsigned: SmartScreen warns, and **Smart App Control** (on by default on new Windows 11 installs)
blocks an unsigned binary outright. The packager already signs when the repo has the secrets, so
signing is configuration, not code — see `psxrecomp/docs/ci/README.md` ("Windows code signing"):

| Secret | Value |
|---|---|
| `WINDOWS_SIGN_PFX_BASE64` | `base64 -w0 cert.pfx` |
| `WINDOWS_SIGN_PFX_PASSWORD` | its password (omit for a passwordless .pfx) |
| `WINDOWS_SIGN_TIMESTAMP_URL` | optional, defaults to DigiCert |

## Building the Windows exe on this Linux machine

CI is the release path. For iterating, `scripts/build_windows.sh` cross-builds and packages the same
artifact from Linux, so the .exe can be built and Proton-tested here:

```sh
scripts/build_windows.sh                 # -> build-windows/BattleHunter_Recompiled.exe
scripts/build_windows.sh --fetch-toolchain   # ... and unpack a MinGW-w64 GCC under .cache/ first
scripts/test_windows_proton.sh dist/stage-game-windows-x64
```

It runs the same framework pieces CI runs (pinned-SDL3 prefetch, `PSXRECOMP_REQUIRE_GAME_C=ON`,
`tools/package_game_release.sh` via `scripts/package_release.sh`), so `dist/` gets a real
`bh-<version>-windows-x64.zip`, and it refuses to continue if the configure took the setup-host path,
if OpenBIOS was not linked, or if the build is not statically linked.

Two things the cross build has to do differently from a native Windows build:

- **The emitters must be Windows binaries.** `overlay_toolchain/` ships `psxrecomp-game.exe` +
  `psxrecomp-bios.exe`, because the runtime compiles overlays (and a retail BIOS backend) from the
  *player's* disc on the *player's* machine. `psxrecomp/tools/ci/build_emitters.sh` picks bare
  `clang`/`clang++` from the portable pack — correct on a Windows host, wrong for a cross build, where
  only `<triple>-clang` targets Windows. So this script configures the recompiler itself with
  `toolchain/windows-x64.cmake`.
- **The toolchain file is ours.** `psxrecomp/cmake/toolchain-mingw-w64.cmake` hardcodes a sysroot at
  `/usr/<triple>` and a compiler family, so it cannot describe a toolchain unpacked under `.cache/`.
  `toolchain/windows-x64.cmake` takes `PSX_WIN_TOOLCHAIN_ROOT`, finds a compiler *pair*
  (`<triple>-gcc` **and** `<triple>-g++` — a guessed `<triple>-gcc++` resolves to the host's Linux
  compiler and then rejects every `-std=c++` flag), and points `CMAKE_RC_COMPILER` at `windres`,
  without which CMake silently skips the `.rc` and the exe ships icon-less.

Toolchains (all MinGW-w64 ABI, all GCC, because GCC is what CI links with):

```sh
sudo pacman -S --needed mingw-w64-gcc mingw-w64-crt mingw-w64-headers \
                        mingw-w64-binutils mingw-w64-winpthreads   # Arch / CachyOS
sudo apt-get install g++-mingw-w64-x86-64                          # Debian / Ubuntu
scripts/build_windows.sh --fetch-toolchain                         # no root at all
```

`--fetch-toolchain` unpacks those same Arch packages under `.cache/mingw-w64` (pinned SHA-256, nothing
installed) and works on any up-to-date x86-64 Linux host.

**Clang/llvm-mingw does not work yet.** The framework's vendored rabbitizer and toml11 rely on
transitive `<cstdlib>` / `<exception>` includes that libstdc++ happens to provide; a clang build stops
with `use of undeclared identifier 'malloc'` in
`psxrecomp/recompiler/lib/rabbitizer/cplusplus/src/instructions/InstructionBase.cpp` and
`no member named 'terminate' in namespace 'std'` in `lib/toml11/toml/comments.hpp`. Two includes would
fix it upstream; until then the emitter build fails, and the emitters are not optional (they ship in
every zip).

## Testing the Windows exe with Proton

`scripts/test_windows_proton.sh` runs the .exe under Valve's Proton (Wine + DXVK, installed with
Steam) and reports per probe. It finds Proton by reading every Steam library folder in
`libraryfolders.vdf`; override with `PROTON=<…>/Proton - Experimental/proton`.

```sh
scripts/test_windows_proton.sh                              # all probes
scripts/test_windows_proton.sh --disc "/path/BattleHunter.cue"   # an actual boot
scripts/test_windows_proton.sh --probe launcher --timeout 120    # just the UI, with a screenshot
```

| Probe | Runs | Pass condition |
|---|---|---|
| `headless` | `--headless --no-launcher` | the log contains `psxrecomp: main() entered`, and it reports on the disc instead of crashing |
| `gl` | `--headless-opengl --no-launcher` | same, through the GL renderer path |
| `launcher` | (nothing) | the launcher window is **still alive** when the timeout fires — that is first-run behaviour, not a hang |

Three details that make the difference between a useful smoke test and a lying one:

- **`proton runinprefix`, not `proton run`.** `run` detaches the child's stdout; you get a prefix, some
  `radv` warnings and an exit code, and nothing from the runtime. `runinprefix` attaches it, so the
  `psxrecomp:` lines land in `.cache/proton-logs/<probe>.log`.
- **Probe out of the tree.** The launcher walks up from the exe looking for a psxrecomp checkout
  (`game.toml` + `psxrecomp/psxrecomp_cli.py`). A payload staged under `dist/` is *inside this repo*, so
  the launcher decides it is a developer's setup host and its first-run page becomes *"Build tools —
  download the portable cmake/clang pack"*. Copied out of the tree it shows what a player sees:
  *"Setup required — BattleHunter needs a Disc"*, `OK OpenBIOS`, `Browse Disc`. The script copies the
  payload to `$TMPDIR/bh-windows-probe` unless you pass `--in-place`.
- **The launcher probe takes a screenshot** (spectacle / maim / ImageMagick) into
  `.cache/proton-logs/launcher.png` (`--no-screenshot` to skip it). "A process survived 60 s" is weak
  evidence next to a picture of the UI with its fonts and tabs drawn.

### What was measured (v0.1.0 cross build, Proton Experimental 11.0-100, RADV)

- Prefix creation and all three probes pass; no `err:` lines, no NTSTATUS exits.
- `[launcher] SDL runtime 3.4.10 (SDL-release-3.4.10-0-g8e37db5e7)` — the statically linked SDL3 is the
  one that loads.
- `[rui] color emoji backend: directwrite` — recomp-ui's Windows text path (D2D/DirectWrite) is live.
- `overlay autocompile enabled (tcc)` with `overlay_toolchain\python\python.exe` as the interpreter and
  `tcc tier using bundled toolchain` — the Windows overlay fallback (embedded Python + TinyCC) starts.
- With no disc: `headless — cannot prompt for 'Select BattleHunter disc image (…)'` then
  `no disc image selected; exiting.` — the first-run path, cleanly.

### What Proton does **not** prove

It is a translation layer, not Windows. It does not exercise SmartScreen / Smart App Control, real GPU
driver and ICD behaviour (this box ran the GL path on RADV), exclusive-fullscreen modes, XInput device
handling on real hardware, or antivirus interference. **Gameplay** needs a disc, and no dump ships with
or is looked for by this repo (the zip carries only OpenBIOS), so the probes above stop at the disc
prompt: pass `--disc` with your own `.cue` to make it an actual boot test. Until someone plays on real
Windows, release notes should say "runs under Proton; Windows playtest pending" rather than "tested on
Windows".

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `0xc000007b` on launch | a non-system DLL beside the exe, or an earlier one on `PATH`. `scripts/check_windows_pe.sh <exe>` must say "all Windows system DLLs"; delete stray `lib*.dll`/`SDL*.dll` next to it |
| "Windows protected your PC" / app blocked | unsigned (see Code signing). Unsigned builds also fail Smart App Control |
| Launcher shows "Build tools / download toolchain" | you ran it from inside a psxrecomp checkout — see *Probe out of the tree* above. A player's extracted copy never shows this |
| Game says no disc | expected on first run: point it at your `BattleHunter.cue` + `.bin` (`.ecm` must be unsqueezed first — README, "Have an .ecm file instead?") |
| Cross build stops in `rabbitizer` / `toml11` | clang was picked (`--compiler clang` or a clang-only unpack). Use a GCC MinGW-w64 |
| Cross build: `icon is missing` / no icon in Explorer | the toolchain has no `windres`; `toolchain/windows-x64.cmake` reports `rc=` at configure time |

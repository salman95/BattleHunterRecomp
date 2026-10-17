# Cross-compile toolchain: Linux/macOS host -> Windows x86_64 (MinGW-w64 ABI).
#
# The release binaries themselves are cut on windows-2022 with MSYS2 MinGW-w64
# (see .github/workflows/release.yml and psxrecomp/docs/ci/README.md). This file
# exists so the SAME Windows artifact can be produced from a Linux workstation:
# iterate on the Windows build, then smoke-test the .exe under Valve's Proton
# (scripts/build_windows.sh + scripts/test_windows_proton.sh) without a Windows
# box or a VM.
#
# Two toolchain families are supported, and both speak the MinGW-w64 ABI:
#
#   1. A rootless unpack (nothing installed system-wide):
#        curl -fLO https://github.com/mstorsjo/llvm-mingw/releases/download/\<rel\>/llvm-mingw-\<rel\>-ucrt-ubuntu-22.04-x86_64.tar.xz
#        tar -xf llvm-mingw-*.tar.xz
#        cmake -DCMAKE_TOOLCHAIN_FILE=toolchain/windows-x64.cmake \
#              -DPSX_WIN_TOOLCHAIN_ROOT=$PWD/llvm-mingw ...
#      or, unpacked inside the repo (which .gitignore keeps out):
#        scripts/build_windows.sh            # auto-detects .cache/llvm-mingw
#
#   2. A distro sysroot at /usr/<triple> — Arch/CachyOS `mingw-w64-gcc`
#      (the family psxrecomp/cmake/toolchain-mingw-w64.cmake expects, and the
#      closest match to the MSYS2 GCC that cuts the release), Debian/Ubuntu
#      `g++-mingw-w64-x86-64`. Just have <triple>-gcc on PATH and omit
#      PSX_WIN_TOOLCHAIN_ROOT.
#
# Cache knobs:
#   MINGW_TRIPLE            target triple (default x86_64-w64-mingw32)
#   PSX_WIN_TOOLCHAIN_ROOT  rootless unpack root (contains bin/ and <triple>/)
#   PSX_WIN_COMPILER        clang | gcc | auto (default auto: prefer gcc, because
#                           that is what the release CI links with; clang is the
#                           rootless-unpack default when no gcc is shipped)

set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR x86_64)

set(MINGW_TRIPLE "x86_64-w64-mingw32" CACHE STRING "MinGW target triple")
set(PSX_WIN_TOOLCHAIN_ROOT "" CACHE PATH
    "Root of a rootless MinGW-w64/llvm-mingw unpack (bin/ + <triple>/); empty = use PATH + /usr/<triple>")
set(PSX_WIN_COMPILER "auto" CACHE STRING "Compiler family for the cross build (clang, gcc or auto)")
set_property(CACHE PSX_WIN_COMPILER PROPERTY STRINGS auto clang gcc)

if(PSX_WIN_TOOLCHAIN_ROOT)
    get_filename_component(PSX_WIN_TOOLCHAIN_ROOT "${PSX_WIN_TOOLCHAIN_ROOT}" ABSOLUTE)
    if(NOT IS_DIRECTORY "${PSX_WIN_TOOLCHAIN_ROOT}/bin")
        message(FATAL_ERROR
            "PSX_WIN_TOOLCHAIN_ROOT=${PSX_WIN_TOOLCHAIN_ROOT} has no bin/ — point it at the "
            "root of an unpacked llvm-mingw / MinGW-w64 toolchain.")
    endif()
    set(_psx_win_bin "${PSX_WIN_TOOLCHAIN_ROOT}/bin")
    set(_psx_win_sysroot "${PSX_WIN_TOOLCHAIN_ROOT}/${MINGW_TRIPLE}")
else()
    set(_psx_win_bin "")
    set(_psx_win_sysroot "/usr/${MINGW_TRIPLE}")
endif()

# Prefix a tool name with the unpack's bin/ when that unpack is in use.
function(_psx_win_tool out name)
    if(_psx_win_bin AND EXISTS "${_psx_win_bin}/${name}")
        set(${out} "${_psx_win_bin}/${name}" PARENT_SCOPE)
    else()
        set(${out} "${name}" PARENT_SCOPE)
    endif()
endfunction()

# --- Compiler family ---------------------------------------------------------
# gcc first: release CI links the shipped exe with MSYS2 MinGW-w64 GCC, so a GCC
# cross build is the closest local reproduction of the artifact players get.
# A pair only counts when BOTH the C and the C++ driver exist: the C++ driver is
# what makes <triple>-gcc mean "C++ mode", and a missing one silently configures
# a CXX compiler that rejects every -std=c++ flag.
if(PSX_WIN_COMPILER STREQUAL "gcc")
    set(_psx_win_families "gcc")
elseif(PSX_WIN_COMPILER STREQUAL "clang")
    set(_psx_win_families "clang")
else()
    set(_psx_win_families "gcc" "clang")
endif()

set(_psx_win_cc "")
set(_psx_win_cxx "")
foreach(_fam IN LISTS _psx_win_families)
    if(_fam STREQUAL "gcc")
        set(_c "${MINGW_TRIPLE}-gcc")
        set(_cxx "${MINGW_TRIPLE}-g++")
    else()
        set(_c "${MINGW_TRIPLE}-clang")
        set(_cxx "${MINGW_TRIPLE}-clang++")
    endif()
    _psx_win_tool(_try_cc "${_c}")
    _psx_win_tool(_try_cxx "${_cxx}")
    if(_psx_win_bin)
        if(EXISTS "${_try_cc}" AND EXISTS "${_try_cxx}")
            set(_psx_win_cc "${_try_cc}")
            set(_psx_win_cxx "${_try_cxx}")
            break()
        endif()
    else()
        find_program(_found_cc NAMES "${_c}" NO_CMAKE_FIND_ROOT_PATH)
        find_program(_found_cxx NAMES "${_cxx}" NO_CMAKE_FIND_ROOT_PATH)
        if(_found_cc AND _found_cxx)
            set(_psx_win_cc "${_found_cc}")
            set(_psx_win_cxx "${_found_cxx}")
            break()
        endif()
    endif()
endforeach()
if(NOT _psx_win_cc)
    message(FATAL_ERROR
        "No Windows cross compiler pair found (looked for ${MINGW_TRIPLE}-{gcc,g++} "
        "then ${MINGW_TRIPLE}-{clang,clang++}).\n"
        "  Arch/CachyOS:  sudo pacman -S --needed mingw-w64-gcc mingw-w64-crt \\\n"
        "                   mingw-w64-headers mingw-w64-binutils mingw-w64-winpthreads\n"
        "  Debian/Ubuntu: sudo apt-get install g++-mingw-w64-x86-64\n"
        "  No root at all: unpack llvm-mingw and pass\n"
        "                   -DPSX_WIN_TOOLCHAIN_ROOT=<unpack-root>")
endif()

set(CMAKE_C_COMPILER   "${_psx_win_cc}")
set(CMAKE_CXX_COMPILER "${_psx_win_cxx}")

# --- binutils ---------------------------------------------------------------
_psx_win_tool(CMAKE_AR       "${MINGW_TRIPLE}-ar")
_psx_win_tool(CMAKE_RANLIB   "${MINGW_TRIPLE}-ranlib")
_psx_win_tool(CMAKE_STRIP    "${MINGW_TRIPLE}-strip")
_psx_win_tool(CMAKE_OBJCOPY  "${MINGW_TRIPLE}-objcopy")
_psx_win_tool(CMAKE_OBJDUTMP "${MINGW_TRIPLE}-objdump")
# The .rc that runtime.cmake builds for APP_ICON needs a resource compiler;
# without one CMake silently skips the icon and the exe ships without it.
_psx_win_tool(CMAKE_RC_COMPILER "${MINGW_TRIPLE}-windres")
if(NOT EXISTS "${CMAKE_RC_COMPILER}")
    _psx_win_tool(CMAKE_RC_COMPILER "llvm-windres")
endif()
message(STATUS "windows-x64 toolchain: cc=${CMAKE_C_COMPILER} rc=${CMAKE_RC_COMPILER} sysroot=${_psx_win_sysroot}")

# --- Isolate from the host --------------------------------------------------
# A Linux pkg-config knows the host's SDL2/GL; picking those up produces a
# configure that succeeds and a link that fails (or, worse, a Linux .so mixed
# into the PE).
find_program(_psx_win_pkgcfg NAMES "${MINGW_TRIPLE}-pkg-config" pkg-config
    NO_CMAKE_FIND_ROOT_PATH)
if(_psx_win_pkgcfg)
    set(PKG_CONFIG_EXECUTABLE "${_psx_win_pkgcfg}" CACHE FILEPATH
        "pkg-config for the MinGW sysroot" FORCE)
endif()
set(ENV{PKG_CONFIG_PATH} "")
if(DEFINED ENV{MINGW_PKG_CONFIG_LIBDIR} AND NOT "$ENV{MINGW_PKG_CONFIG_LIBDIR}" STREQUAL "")
    set(ENV{PKG_CONFIG_LIBDIR} "$ENV{MINGW_PKG_CONFIG_LIBDIR}")
elseif(EXISTS "${_psx_win_sysroot}/lib/pkgconfig")
    set(ENV{PKG_CONFIG_LIBDIR} "${_psx_win_sysroot}/lib/pkgconfig")
endif()

set(CMAKE_FIND_ROOT_PATH "${_psx_win_sysroot}")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)

# The generated game C is ~144 MB across ~110 translation units; a COFF object
# with more than 32768 sections needs the big-obj encoding (GNU as only — the
# LLVM integrated assembler does not take the flag).
if(CMAKE_C_COMPILER_ID STREQUAL "GNU")
    string(APPEND CMAKE_C_FLAGS_INIT " -Wa,-mbig-obj")
    string(APPEND CMAKE_CXX_FLAGS_INIT " -Wa,-mbig-obj")
endif()

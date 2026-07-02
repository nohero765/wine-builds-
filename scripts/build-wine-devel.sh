#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# build-wine-devel.sh
#
# Builds Wine *development* sources (e.g. wine-11.11) from WineHQ, then
# applies the macports-wine "wine-devel" patch set (the same set
# previously applied on top of CrossOver sources in build-wine.sh).
#
# Patch policy (per request):
#   - emulators/wine-devel/files/*.diff, *.patch   -> ALL applied, in order
#       (this includes 0005-kernelbase-CW-HACK-13322-17315-21883.diff and
#        1001-kernelbase-CW-HACK-19610.diff, the two Steam webhelper hacks)
#   - emulators/wine-devel/files/dwproton/0001-em-backports/*  -> applied
#   - emulators/wine-devel/files/dwproton/0002-misc-dw/*       -> applied
#   - emulators/wine-devel/files/dwproton/gi-timeout/*         -> SKIPPED
#       (these are the "curl timeout fix patches for certain games" -
#        excluded per request as "timeout patches for games")
#   - emulators/wine-devel/files/mf/*                          -> applied
#       (mfreadwrite video-processor fix for some games - NOT a timeout
#        patch, so included by default. Flip APPLY_MF=0 below to skip it.)
#
# Usage: ./build-wine-devel.sh <wine-version>
#   e.g. ./build-wine-devel.sh 11.11
# ---------------------------------------------------------------------------

APPLY_MF=1   # set to 0 to skip emulators/wine-devel/files/mf/* patches

if [[ $# -ne 1 ]]; then
    echo "usage: $0 <wine-version>" >&2
    echo "example: $0 11.11" >&2
    exit 2
fi

VERSION="$1"
MAJOR="$(echo "${VERSION}" | cut -d. -f1)"
BRANCH_DIR="${MAJOR}.x"

SCRIPTDIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE="$(cd "${SCRIPTDIR}/.." && pwd)"
SOURCE_URL="https://dl.winehq.org/wine/source/${BRANCH_DIR}/wine-${VERSION}.tar.xz"
TARBALL="${WORKSPACE}/wine-${VERSION}.tar.xz"
WORKDIR="${WORKSPACE}/workdir"
BUILDDIR="${WORKDIR}/build-wine"
STAGEDIR="${WORKDIR}/stage"
APPNAME="Wine Devel ${VERSION}"
APPDIR="${STAGEDIR}/${APPNAME}.app"
BUNDLE_CONTENTS="${APPDIR}/Contents"
BUNDLE_RES="${BUNDLE_CONTENTS}/Resources"
BUNDLE_MACOS="${BUNDLE_CONTENTS}/MacOS"
DESTROOT="${STAGEDIR}/destroot"
ARTIFACT="${WORKSPACE}/winedevel-${VERSION}-osx64.tar.gz"

group()    { echo "::group::$1"; }
endgroup() { echo "::endgroup::"; }

group "Download wine-${VERSION}.tar.xz"
echo "Source URL: ${SOURCE_URL}"
if [[ ! -f "${TARBALL}" ]]; then
    curl -fsSL -o "${TARBALL}" "${SOURCE_URL}"
fi
ls -lh "${TARBALL}"
endgroup

group "Extract sources"
rm -rf "${WORKDIR}"
mkdir -p "${WORKDIR}"
tar -xf "${TARBALL}" -C "${WORKDIR}"

# The tarball normally extracts to "wine-${VERSION}/", but fall back to a
# glob search in case the directory name doesn't match exactly.
if [[ -d "${WORKDIR}/wine-${VERSION}" ]]; then
    WINE_SRC="${WORKDIR}/wine-${VERSION}"
else
    WINE_SRC="$(find "${WORKDIR}" -maxdepth 1 -type d -name 'wine-*' | head -n1)"
fi
test -n "${WINE_SRC}" && test -x "${WINE_SRC}/configure"
echo "WINE_SRC=${WINE_SRC}"

echo "=== Initialize git repo in wine source (git apply -C needs a repo HERE not the parent) ==="
git -C "${WINE_SRC}" init -q
git -C "${WINE_SRC}" config user.email "build@local"
git -C "${WINE_SRC}" config user.name "build"
git -C "${WINE_SRC}" add -A
git -C "${WINE_SRC}" commit -q -m "vanilla wine-${VERSION}"
echo "  ✓ git repo initialized in ${WINE_SRC}"

echo "=== winemetal stub check ==="
ls "${WINE_SRC}/dlls/" | grep -i winemetal || echo "winemetal NOT found (expected on vanilla Wine - added by patch 0017)"
endgroup

group "Apply riverfog7/macports-wine wine-devel patch set"
echo "=== Cloning riverfog7/macports-wine (patches branch) ==="
git clone --depth 1 --branch patches https://github.com/riverfog7/macports-wine.git "${WORKDIR}/macports-src"

DEVEL="${WORKDIR}/macports-src/emulators/wine-devel/files"
DWPROTON_BASE="${DEVEL}/dwproton"
MF_DIR="${DEVEL}/mf"

apply_patch() {
    local patch="$1"
    local name
    name=$(basename "$patch")
    if [[ ! -f "$patch" ]]; then
        echo "  ⚠ SKIP: $name (file not found)"
        return 0
    fi
    git -C "${WINE_SRC}" apply --3way --whitespace=nowarn "$patch" \
        && echo "  ✓ $name" \
        || echo "  ⚠ SKIP: $name (already applied or conflict — not fatal)"
}

echo "=== Applying top-level wine-devel patches (in order) ==="
test -d "${DEVEL}" || { echo "  ✗ FATAL: ${DEVEL} not found"; exit 1; }
while IFS= read -r patch; do
    apply_patch "$patch"
done < <(find "${DEVEL}" -maxdepth 1 -type f \( -name '*.diff' -o -name '*.patch' \) | sort)

echo "=== Force-apply 0006 via patch --fuzz=5 (DXMT requires its Metal C exports) ==="
# git apply --3way fails for 0006 because it was written against CrossOver source
# (no shared git history → no base blob for 3-way merge). GNU patch with --fuzz
# is more permissive about context mismatches and can apply it anyway.
PATCH_0006="${DEVEL}/0006-winemac-CW-HACK-22435.diff"
if [[ -f "${PATCH_0006}" ]]; then
  if git -C "${WINE_SRC}" apply --check --whitespace=nowarn "${PATCH_0006}" 2>/dev/null; then
    git -C "${WINE_SRC}" apply --whitespace=nowarn "${PATCH_0006}"
    echo "  ✓ 0006 applied cleanly on retry"
  else
    patch -p1 --forward --fuzz=5 --ignore-whitespace \
      -d "${WINE_SRC}" < "${PATCH_0006}" 2>&1 | tail -8 || true
    METAL_AFTER=$(grep -c "WineMetalView" "${WINE_SRC}/dlls/winemac.drv/cocoa_window.m" 2>/dev/null || echo "0")
    if [[ "${METAL_AFTER}" -gt 0 ]]; then
      echo "  ✓ 0006 force-applied — WineMetalView refs in cocoa_window.m: ${METAL_AFTER}"
    else
      echo "  ✗ WARNING: 0006 still could not apply — DXMT Metal view will fail at runtime"
    fi
  fi
else
  echo "  ⚠ 0006 patch file not found at ${PATCH_0006}"
fi

echo "=== Fix: inject d3dmetal_client_surface ivar into WineContentView ==="
# patch --fuzz applied the getter/setter code that USES this member but
# dropped the hunk that DECLARES it (context mismatch vs vanilla wine-11.11).
# Inject it as void* into the @implementation ivar block.
COCOA_WIN="${WINE_SRC}/dlls/winemac.drv/cocoa_window.m"
if grep -q 'd3dmetal_client_surface' "${COCOA_WIN}" 2>/dev/null \
   && ! grep -qE '\*[[:space:]]*d3dmetal_client_surface[[:space:]]*;' "${COCOA_WIN}"; then
  perl -i -0pe \
    's/(\@implementation WineContentView\s*\{)/$1\n    \@public\n    void *d3dmetal_client_surface;/' \
    "${COCOA_WIN}"
  if grep -qE '\*[[:space:]]*d3dmetal_client_surface' "${COCOA_WIN}"; then
    echo "  ✓ d3dmetal_client_surface injected into WineContentView"
  else
    # fallback: try the @interface block instead
    perl -i -0pe \
      's/(\@interface WineContentView\s*:[^\{]+\{)/$1\n    \@public\n    void *d3dmetal_client_surface;/' \
      "${COCOA_WIN}"
    grep -qE '\*[[:space:]]*d3dmetal_client_surface' "${COCOA_WIN}" \
      && echo "  ✓ d3dmetal_client_surface injected via @interface" \
      || echo "  ✗ FATAL: injection failed — compile will error on d3dmetal_client_surface"
  fi
else
  echo "  ✓ d3dmetal_client_surface already present or unused — skipping"
fi

echo "=== Fix: resize DXMT Metal view on WineContentView setFrameSize: ==="
COCOA_WIN="${WINE_SRC}/dlls/winemac.drv/cocoa_window.m"
perl -i -0pe '
  s{(\@implementation WineContentView\b)(.*?)(\@end)}{
    my ($cls, $body, $end) = ($1, $2, $3);
    my $hook = "- (void)setFrameSize:(NSSize)sz\n{\n    [super setFrameSize:sz];\n    NSLog(\@\"[DXMT-RESIZE] setFrameSize:%.0fx%.0f sublayers=%lu subviews=%lu\", sz.width, sz.height, (unsigned long)[[[self layer] sublayers] count], (unsigned long)[[self subviews] count]);\n    NSRect vb = NSMakeRect(0, 0, sz.width, sz.height);\n    CGRect lb = CGRectMake(0, 0, sz.width, sz.height);\n    for (CALayer *sl in [[self layer] sublayers])\n        [sl setFrame:lb];\n    for (NSView *sv in [self subviews])\n        if (!NSEqualRects([sv frame], vb))\n            [sv setFrame:vb];\n}\n\n";
    if ($body !~ /- \(void\)setFrameSize:\(NSSize\)/) {
      $cls . $hook . $body . $end;
    } else {
      my $metal = "    { NSRect __vb = NSMakeRect(0,0,[self bounds].size.width,[self bounds].size.height); CGRect __lb = CGRectMake(0,0,__vb.size.width,__vb.size.height); for (CALayer *__sl in [[self layer] sublayers]) [__sl setFrame:__lb]; for (NSView *__sv in [self subviews]) if (!NSEqualRects([__sv frame],__vb)) [__sv setFrame:__vb]; }\n";
      $body =~ s{(\[super setFrameSize:[^\]]+\];)}{$1\n$metal};
      $cls . $body . $end;
    }
  }se
' "${COCOA_WIN}"
grep -q 'setFrame:lb\|setFrame:vb\|setFrame:__lb' "${COCOA_WIN}" \
  && echo "  ✓ Metal resize injected (no class filter, resizes all sublayers/subviews)" \
  || echo "  ✗ FATAL: injection failed"

echo "=== Manual fix for 1001-kernelbase-CW-HACK-19610 (corrupt upstream patch) ==="
# 1001-kernelbase-CW-HACK-19610.diff has a malformed hunk in riverfog7's repo
# (its second hunk header claims 7 lines but only 6 are present), so
# `git apply` reports "corrupt patch" and it gets skipped. The only
# functional change it makes is adding one Battle.net.exe entry to the
# options[] table in dlls/kernelbase/process.c, right after the
# steamwebhelper.exe entry added by 0005. Apply that directly, idempotently.
PROCESS_C="${WINE_SRC}/dlls/kernelbase/process.c"
if [[ -f "${PROCESS_C}" ]] && grep -q 'Battle\.net\.exe' "${PROCESS_C}"; then
    echo "  (Battle.net.exe entry already present — skipping)"
elif [[ -f "${PROCESS_C}" ]] && grep -q 'L"steamwebhelper\.exe"' "${PROCESS_C}"; then
    perl -i -pe 's/(\{L"steamwebhelper\.exe".*\},)/$1\n        {L"Battle.net.exe", L" --in-process-gpu --use-gl=swiftshader", NULL, NULL},/' "${PROCESS_C}"
    if grep -q 'Battle\.net\.exe' "${PROCESS_C}"; then
        echo "  ✓ Battle.net.exe entry inserted manually"
    else
        echo "  ⚠ insertion failed — steamwebhelper.exe line pattern not matched as expected"
    fi
else
    echo "  ⚠ steamwebhelper.exe entry not found in process.c — was 0005 applied? skipping Battle.net hack"
fi

echo "=== Diagnostic: did 0005 actually land in process.c? ==="
grep -n "steamwebhelper\|hack_append_command_line\|CROSSOVER HACK\|no.sandbox" \
    "${WINE_SRC}/dlls/kernelbase/process.c" 2>/dev/null | head -20 \
    || echo "  (nothing matched — 0005 may not have applied functionally)"

echo "=== Force-inject steamwebhelper CEF args if 0005 still missed ==="
PROCESS_C="${WINE_SRC}/dlls/kernelbase/process.c"
if [[ -f "${PROCESS_C}" ]]; then
    if grep -q 'steamwebhelper' "${PROCESS_C}"; then
        echo "  ✓ steamwebhelper entry confirmed present — no injection needed"
    elif grep -q 'hack_append_command_line' "${PROCESS_C}"; then
        # 0004 landed but 0005 didn't — inject steamwebhelper before the NULL sentinel
        perl -i -pe 's/^(\s+)\{\s*NULL\s*\}/$1{L"steamwebhelper.exe", L" --no-sandbox --in-process-gpu --disable-gpu", NULL, NULL},\n$&/' "${PROCESS_C}"
        grep -q 'steamwebhelper' "${PROCESS_C}" \
            && echo "  ✓ steamwebhelper.exe force-injected before NULL sentinel" \
            || echo "  ⚠ injection regex missed — dump options[] array manually to debug"
    else
        echo "  ⚠ FATAL: hack_append_command_line not found — 0004 also missed; git init may not have worked"
    fi
else
    echo "  ⚠ process.c not found at ${PROCESS_C} — check WINE_SRC path"
fi

echo "=== Ensure steamwebhelper has renderer-safe CEF flags ==="
# --disable-accelerated-video-decode: prevents VideoToolbox pixel format crash
# --disable-features=DirectComposition: prevents DXMT being triggered in CEF renderer
PROCESS_C="${WINE_SRC}/dlls/kernelbase/process.c"
if grep -q 'steamwebhelper.*no-sandbox' "${PROCESS_C}" 2>/dev/null; then
  if ! grep -q 'DirectComposition' "${PROCESS_C}"; then
    perl -i -pe \
      's/(L"steamwebhelper\.exe",\s*L"\s*--no-sandbox[^"]*)"/$1 --disable-accelerated-video-decode --disable-features=DirectComposition"/' \
      "${PROCESS_C}"
    grep -q 'DirectComposition' "${PROCESS_C}" \
      && echo "  ✓ renderer-safe flags added to steamwebhelper" \
      || echo "  ⚠ flag injection failed — check steamwebhelper line pattern"
  else
    echo "  ✓ renderer-safe flags already present"
  fi
fi

echo "=== Diagnostic: is_rosetta2 references ==="
grep -rn "is_rosetta2" "${WINE_SRC}/dlls/ntdll" 2>/dev/null || echo "  (no references found in dlls/ntdll)"

echo "=== Force-define is_rosetta2 if used but undeclared (Rosetta 2 detection) ==="
SIGNAL_X64_C="${WINE_SRC}/dlls/ntdll/unix/signal_x86_64.c"
if [[ -f "${SIGNAL_X64_C}" ]] && grep -q 'is_rosetta2' "${SIGNAL_X64_C}"; then
    if grep -rqE '(BOOL|int|bool)[[:space:]]+is_rosetta2[[:space:]]*[=;]' \
        "${WINE_SRC}/dlls/ntdll/unix"/*.c "${WINE_SRC}/dlls/ntdll/unix"/*.h 2>/dev/null; then
        echo "  ✓ is_rosetta2 already declared somewhere — no injection needed"
    else
        LAST_INCLUDE_LINE=$(grep -n '^#include' "${SIGNAL_X64_C}" | tail -1 | cut -d: -f1)
        if [[ -n "${LAST_INCLUDE_LINE}" ]]; then
            perl -i -pe 'if ($. == '"${LAST_INCLUDE_LINE}"') {
                $_ .= "\n#include <sys/sysctl.h>\n\nstatic BOOL is_rosetta2;\n\nstatic void __attribute__((constructor)) wine_init_is_rosetta2(void)\n{\n    int ret = 0;\n    size_t size = sizeof(ret);\n    if (sysctlbyname(\"sysctl.proc_translated\", &ret, &size, NULL, 0) != -1)\n        is_rosetta2 = (ret == 1);\n}\n";
            }' "${SIGNAL_X64_C}"
            grep -q 'wine_init_is_rosetta2' "${SIGNAL_X64_C}" \
                && echo "  ✓ is_rosetta2 definition injected after #include block (line ${LAST_INCLUDE_LINE})" \
                || echo "  ⚠ injection failed — patch signal_x86_64.c manually near line 2645"
        else
            echo "  ⚠ could not locate #include lines in signal_x86_64.c — manual fix needed"
        fi
    fi
fi

echo "=== Applying dwproton backport patches (gi-timeout excluded) ==="
if [[ -d "${DWPROTON_BASE}" ]]; then
    for subdir in "${DWPROTON_BASE}/0001-em-backports" "${DWPROTON_BASE}/0002-misc-dw"; do
        [[ -d "$subdir" ]] || { echo "  (not found: $(basename "$subdir"))"; continue; }
        echo "  → $(basename "$subdir")"
        while IFS= read -r patch; do
            apply_patch "$patch"
        done < <(find "$subdir" -maxdepth 1 -type f \( -name '*.patch' -o -name '*.diff' \) | sort)
    done
    echo "  (skipped: dwproton/gi-timeout — game timeout patches excluded per request)"
else
    echo "  ✗ FATAL: dwproton base dir not found at: ${DWPROTON_BASE}"
    ls "${DEVEL}" 2>/dev/null
    exit 1
fi

if [[ "${APPLY_MF}" -eq 1 ]]; then
    echo "=== Applying mf/ (mediafoundation) patches ==="
    if [[ -d "${MF_DIR}" ]]; then
        while IFS= read -r patch; do
            apply_patch "$patch"
        done < <(find "${MF_DIR}" -maxdepth 1 -type f \( -name '*.patch' -o -name '*.diff' \) | sort)
    else
        echo "  (no mf/ directory found — skipping)"
    fi
else
    echo "  (APPLY_MF=0 — skipping mf/ patches)"
fi

echo ""
echo "=== Verify 0006 WineMetalView landed (critical) ==="
METAL_VIEW=$(grep -c "WineMetalView" \
    "${WINE_SRC}/dlls/winemac.drv/cocoa_window.m" 2>/dev/null || echo "0")
if [[ "$METAL_VIEW" -gt 0 ]]; then
    echo "  ✓ WineMetalView in cocoa_window.m (${METAL_VIEW} refs)"
else
    echo "  ✗ FATAL: 0006-winemac-CW-HACK-22435.diff did not land WineMetalView."
    exit 1
fi

echo ""
echo "=== Diagnostic: winemetal module (from 0017) — informational only ==="
echo "--- find dlls/ -iname '*metal*' ---"
find "${WINE_SRC}/dlls" -maxdepth 2 -iname '*metal*' 2>/dev/null || true
echo "--- git status (new/modified files, first 60) ---"
git -C "${WINE_SRC}" status --porcelain 2>/dev/null | head -60 || true
endgroup

group "Configure environment"
BREW_PREFIX="$(brew --prefix)"
export CC="ccache clang"
export CXX="ccache clang++"
export i386_CC="ccache i686-w64-mingw32-gcc"
export x86_64_CC="ccache x86_64-w64-mingw32-gcc"
export CPATH="${BREW_PREFIX}/include"
export LIBRARY_PATH="${BREW_PREFIX}/lib"
export MACOSX_DEPLOYMENT_TARGET=10.15
export CFLAGS="-O2 -Wno-deprecated-declarations -Wno-format"
export CROSSCFLAGS="-O2 -Wno-incompatible-pointer-types"
export LDFLAGS="-Wl,-headerpad_max_install_names -Wl,-rpath,@loader_path/../lib -Wl,-rpath,@loader_path/../../ -Wl,-rpath,${BREW_PREFIX}/lib"
export PATH="${BREW_PREFIX}/opt/bison/bin:${PATH}"
export ac_cv_lib_soname_vulkan="libMoltenVK.dylib"
endgroup

group "Configure wine"
mkdir -p "${BUILDDIR}"
pushd "${BUILDDIR}" >/dev/null
"${WINE_SRC}/configure" \
    --prefix= \
    --disable-tests \
    --disable-winedbg \
    --enable-win64 \
    --enable-archs=i386,x86_64 \
    --with-coreaudio \
    --with-cups \
    --with-freetype \
    --with-gettext \
    --with-gnutls \
    --with-mingw \
    --with-opencl \
    --with-pcap \
    --with-pthread \
    --with-sdl \
    --with-unwind \
    --with-vulkan \
    --without-alsa \
    --without-capi \
    --without-dbus \
    --without-fontconfig \
    --without-gettextpo \
    --without-gphoto \
    --without-gssapi \
    --with-gstreamer \
    --without-inotify \
    --without-krb5 \
    --without-netapi \
    --without-opengl \
    --without-oss \
    --without-pulse \
    --without-sane \
    --without-udev \
    --without-usb \
    --without-v4l2 \
    --without-x
popd >/dev/null
endgroup

group "Build wine"
make -C "${BUILDDIR}" -j"$(sysctl -n hw.ncpu)"
endgroup

group "Stage bundle"
rm -rf "${STAGEDIR}"
mkdir -p "${BUNDLE_RES}/wine" "${BUNDLE_MACOS}" "${DESTROOT}"
make -C "${BUILDDIR}" install DESTDIR="${DESTROOT}"
mv "${DESTROOT}"/* "${BUNDLE_RES}/wine/"
rmdir "${DESTROOT}"
test -x "${BUNDLE_RES}/wine/bin/wine"
file "${BUNDLE_RES}/wine/bin/wine"
"${BUNDLE_RES}/wine/bin/wine" --version
DLL_COUNT=$(find "${BUNDLE_RES}/wine/lib/wine/x86_64-windows" -name "*.dll" 2>/dev/null | wc -l | tr -d ' ')
echo "=== Build sanity: ${DLL_COUNT} PE DLLs ==="
[[ "${DLL_COUNT}" -lt 200 ]] && { echo "✗ FATAL: build incomplete — only ${DLL_COUNT} PE DLLs (expect 200+)"; exit 1; }
cat > "${BUNDLE_MACOS}/wine" <<'EOF'
#!/bin/sh
exec "$(dirname "$0")/../Resources/wine/bin/wine" "$@"
EOF
chmod +x "${BUNDLE_MACOS}/wine"
cp "${SCRIPTDIR}/bundle/PkgInfo" "${BUNDLE_CONTENTS}/PkgInfo"
sed "s/@VERSION@/${VERSION}/g" "${SCRIPTDIR}/bundle/Info.plist.in" > "${BUNDLE_CONTENTS}/Info.plist"
endgroup

group "Bundle external dylibs"
set +o pipefail
WINE_LIB="${BUNDLE_RES}/wine/lib"
WINE_UNIX_LIB="${BUNDLE_RES}/wine/lib/wine/x86_64-unix"

echo "=== Bundle all Wine runtime deps (otool-recursive) ==="
bundle_dep() {
  local src="$1" depname
  depname=$(basename "$src")
  [[ -f "${WINE_LIB}/${depname}" ]] && return 0
  [[ -f "$src" ]] || return 0
  cp -Lf "$src" "${WINE_LIB}/"
  echo "  ✓ ${depname}"
  while IFS= read -r tdep; do
    [[ "$tdep" =~ ^(/usr/local/|/opt/homebrew/) ]] || continue
    bundle_dep "$tdep"
  done < <(otool -L "$src" 2>/dev/null | awk 'NR>1{print $1}')
}
find "${BUNDLE_RES}/wine/bin" "${WINE_UNIX_LIB}" -type f \
  \( -name "wine" -o -name "wine64" -o -name "wineserver" -o -name "*.so" \) \
| while read -r f; do
  while IFS= read -r dep; do
    [[ "$dep" =~ ^(/usr/local/|/opt/homebrew/) ]] || continue
    bundle_dep "$dep"
  done < <(otool -L "$f" 2>/dev/null | awk 'NR>1{print $1}')
done

echo "=== Bundle dlopen dependencies (freetype / gnutls / SDL2) ==="
for candidate in \
  "${BREW_PREFIX}/opt/freetype/lib/libfreetype.6.dylib" \
  "/usr/local/opt/freetype/lib/libfreetype.6.dylib"; do
  [[ -f "$candidate" ]] && { bundle_dep "$candidate"; break; }
done
for candidate in \
  "${BREW_PREFIX}/opt/gnutls/lib/libgnutls.30.dylib" \
  "/usr/local/opt/gnutls/lib/libgnutls.30.dylib"; do
  [[ -f "$candidate" ]] && { bundle_dep "$candidate"; break; }
done
for candidate in \
  "${BREW_PREFIX}/opt/sdl2/lib/libSDL2-2.0.0.dylib" \
  "/usr/local/opt/sdl2/lib/libSDL2-2.0.0.dylib" \
  "${BREW_PREFIX}/lib/libSDL2-2.0.0.dylib" \
  "/usr/local/lib/libSDL2-2.0.0.dylib"; do
  [[ -f "$candidate" ]] && { bundle_dep "$candidate"; break; }
done

echo "=== Bundle MoltenVK ==="
MOLTEN_FOUND=""
for candidate in \
  "${BREW_PREFIX}/opt/molten-vk/lib/libMoltenVK.dylib" \
  "${BREW_PREFIX}/lib/libMoltenVK.dylib" \
  "/usr/local/opt/molten-vk/lib/libMoltenVK.dylib" \
  "/usr/local/lib/libMoltenVK.dylib"; do
  if [[ -f "$candidate" ]]; then
    cp -Lf "$candidate" "${WINE_LIB}/"
    echo "  ✓ libMoltenVK.dylib"
    MOLTEN_FOUND=1; break
  fi
done
[[ -n "$MOLTEN_FOUND" ]] || echo "  ✗ WARNING: libMoltenVK.dylib not found — Vulkan/Metal bridge absent"

echo "=== Rewrite Homebrew paths in bundled dylibs ==="
for dylib in "${WINE_LIB}"/*.dylib; do
  [[ -f "$dylib" ]] || continue
  while IFS= read -r dep; do
    [[ "$dep" =~ ^(/usr/local/|/opt/homebrew/) ]] || continue
    depname=$(basename "$dep")
    [[ -f "${WINE_LIB}/${depname}" ]] || continue
    install_name_tool -change "$dep" "@loader_path/${depname}" "$dylib" 2>/dev/null \
      && echo "  ✓ $(basename $dylib) → ${depname}"
  done < <(otool -L "$dylib" 2>/dev/null | awk 'NR>1{print $1}')
done

echo "=== Rewrite Homebrew paths in Wine binaries ==="
find "${BUNDLE_RES}/wine/bin" -type f \( -name "wine" -o -name "wine64" -o -name "wineserver" \) \
| while read -r binary; do
  while IFS= read -r dep; do
    [[ "$dep" =~ ^(/usr/local/|/opt/homebrew/) ]] || continue
    depname=$(basename "$dep")
    [[ -f "${WINE_LIB}/${depname}" ]] || continue
    install_name_tool -change "$dep" "@loader_path/../lib/${depname}" "$binary" 2>/dev/null \
      && echo "  ✓ bin/$(basename $binary) → ${depname}"
  done < <(otool -L "$binary" 2>/dev/null | awk 'NR>1{print $1}')
done

echo "=== Rewrite Homebrew paths in .so modules ==="
find "${WINE_UNIX_LIB}" -name "*.so" | while read -r sofile; do
  while IFS= read -r dep; do
    [[ "$dep" =~ ^(/usr/local/|/opt/homebrew/) ]] || continue
    depname=$(basename "$dep")
    [[ -f "${WINE_LIB}/${depname}" ]] || continue
    install_name_tool -change "$dep" "@loader_path/../../${depname}" "$sofile" 2>/dev/null \
      && echo "  ✓ $(basename $sofile) → ${depname}"
  done < <(otool -L "$sofile" 2>/dev/null | awk 'NR>1{print $1}')
done

echo "=== GStreamer plugins ==="
mkdir -p "${WINE_LIB}/gstreamer-1.0"
for gst_dir in \
  "${BREW_PREFIX}/lib/gstreamer-1.0" \
  "/usr/local/lib/gstreamer-1.0" \
  "/Library/Frameworks/GStreamer.framework/Versions/1.0/lib/gstreamer-1.0"; do
  [[ -d "$gst_dir" ]] || continue
  cp "$gst_dir"/*.dylib "${WINE_LIB}/gstreamer-1.0/" 2>/dev/null || true
  echo "  ✓ GStreamer plugins from ${gst_dir}"
done

echo "=== Bundle GStreamer core libs ==="
for gst_core in gstreamer-1.0 gstbase-1.0 gstaudio-1.0 gstvideo-1.0 gstpbutils-1.0 gsttag-1.0; do
  for candidate in \
    "${BREW_PREFIX}/lib/lib${gst_core}.0.dylib" \
    "/usr/local/lib/lib${gst_core}.0.dylib"; do
    [[ -f "$candidate" ]] && { bundle_dep "$candidate"; break; }
  done
done

echo "=== Rewrite Homebrew paths in GStreamer plugins ==="
find "${WINE_LIB}/gstreamer-1.0" -name "*.dylib" | while read -r plugin; do
  while IFS= read -r dep; do
    [[ "$dep" =~ ^(/usr/local/|/opt/homebrew/) ]] || continue
    depname=$(basename "$dep")
    if [[ -f "${WINE_LIB}/gstreamer-1.0/${depname}" ]]; then
      install_name_tool -change "$dep" "@loader_path/${depname}" "$plugin" 2>/dev/null
    elif [[ -f "${WINE_LIB}/${depname}" ]]; then
      install_name_tool -change "$dep" "@loader_path/../${depname}" "$plugin" 2>/dev/null
    fi
  done < <(otool -L "$plugin" 2>/dev/null | awk 'NR>1{print $1}')
done
echo "  ✓ GStreamer plugin paths rewritten"

echo "Total dylibs bundled: $(ls -1 "${WINE_LIB}" | grep '\.dylib$' | wc -l | tr -d ' ')"
echo "=== Critical lib check ==="
ls "${WINE_LIB}" | grep -iE 'freetype|gnutls|MoltenVK|SDL' || echo "WARNING: missing critical libs"

echo "Total dylibs bundled: $(ls -1 "${WINE_LIB}" | grep '\.dylib$' | wc -l | tr -d ' ')"
echo "=== Critical lib check ==="
ls "${WINE_LIB}" | grep -iE 'freetype|gnutls|MoltenVK|SDL' || echo "WARNING: missing critical libs"
echo "=== GStreamer dependency check ==="
ls "${WINE_LIB}" | grep -cE 'libgst' | xargs echo "  gst-libs bundled:"
ls "${WINE_LIB}" | grep -E 'libgio|libvideo|libgstriff|libgstnet|libgstfft' || echo "  WARNING: some expected gst deps still missing"
endgroup

group "Package artifact"
rm -f "${ARTIFACT}"
tar -C "${STAGEDIR}" -czf "${ARTIFACT}" "${APPNAME}.app"
ls -lh "${ARTIFACT}"
endgroup

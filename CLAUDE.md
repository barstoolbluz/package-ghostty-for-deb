# Nix-to-Deb Packaging Pattern for GTK/GPU Applications

This document describes a reusable pattern for building applications with Nix
and packaging them as `.deb` files for Debian/Ubuntu, with particular attention
to GPU-accelerated GTK applications on systems with proprietary NVIDIA drivers.

## The Problem

Nix-built GUI applications on non-NixOS Linux face a three-way incompatibility:

1. **glibc mismatch** — Nix ships a newer glibc (2.42+) that removed legacy
   malloc hooks (`__malloc_hook`, `__realloc_hook`, `__free_hook`). NVIDIA's
   proprietary `libnvidia-eglcore.so` still uses these symbols. Result: EGL
   initialization fails with "Failed to create EGL display."

2. **NixGL doesn't solve it** — NixGL rebuilds the NVIDIA userspace driver from
   nixpkgs source. Even when the version number matches the host kernel module
   exactly, the nix-rebuilt binary is compiled differently (different patches,
   link-time deps) and is binary-incompatible. The LD_DEBUG trace shows libs
   load successfully but `eglGetDisplay()` still fails.

3. **GTK version pinning** — Nix pins GTK4 to a specific version (e.g., 4.20.3)
   that may be newer than what the distro ships (Debian trixie has 4.18.6).
   Symbols like `gtk_interface_color_scheme_get_type` exist in 4.20 but not
   4.18, so the binary can't use the system GTK4.

## The Solution: Bundle Everything Except glibc and GPU Drivers

The key insight: **glibc and GPU drivers must come from the host system** (they
must match the running kernel), but **everything else can come from nix**.

### Architecture

```
+-----------------------------------------+
|           Ghostty Binary                |
|  (patchelf'd: system interpreter,       |
|   RUNPATH: /usr/lib/ghostty first)      |
+-----------+-----------------------------+
            |
     +------+------+
     |              |
+----v----+   +-----v-----------+
| Bundled |   | System libs     |
| from Nix|   | (host)          |
+---------+   +-----------------+
| GTK4    |   | glibc           |
| libadw  |   | libEGL_nvidia   |
| pango   |   | libnvidia-*     |
| harfbuzz|   | libglvnd        |
| cairo   |   | (from ld.so.cache)
| libepoxy|   +-----------------+
| ...     |
+---------+
```

### Why This Works

- **Host glibc** provides `__malloc_hook` → NVIDIA EGL can initialize
- **Host NVIDIA drivers** match the kernel module exactly → GPU works
- **Nix GTK4** provides the exact version the binary was compiled against → no
  missing symbols
- **RUNPATH ordering** (`/usr/lib/ghostty` before `/usr/lib/x86_64-linux-gnu`)
  ensures bundled libs are found first, system libs are the fallback

## Applying the Pattern to Other Projects

A generic [`nix-to-deb`](../nix-to-deb) flake implements the full pipeline.
For most projects, you only need to configure it — not reimplement the steps
below. See `flake.nix` for a complete GTK example and the
[nix-to-deb README](../nix-to-deb/README.md) for the full API reference.
The manual steps are documented here for understanding and for cases that
need customization.

### Step 1: Build with nix

Use the project's nix flake or nixpkgs package. The key is that nix handles
all the complex build dependencies — you get a working binary with all its
library dependencies resolved in `/nix/store`.

### Step 2: Identify the real binary

Nix often wraps binaries with `makeBinaryWrapper` (a compiled C wrapper that
sets environment variables and exec's the real binary). Find the actual binary:

```bash
# Check if the binary is a wrapper
file result/bin/myapp
# → If it shows "ELF" but only links libc, it's likely a wrapper

# Find the real binary
ls result/bin/.myapp-wrapped
strings result/bin/myapp | grep '.myapp-wrapped'
```

**Important**: Extract the environment variables the wrapper sets — you'll need
to replicate them in a shell wrapper script. Look for:
- `GDK_PIXBUF_MODULE_FILE`
- `GIO_EXTRA_MODULES`
- `XDG_DATA_DIRS`
- `GI_TYPELIB_PATH`
- `GST_PLUGIN_SYSTEM_PATH_1_0`

### Step 3: Bundle shared libraries

```bash
# Get all .so dependencies from nix store, excluding glibc
ldd /nix/store/.../bin/.myapp-wrapped \
  | grep '/nix/store' \
  | grep -v glibc \
  | awk '{print $3}'
```

**Critical exclusion**: Always exclude glibc (`grep -v glibc`). The host's
glibc must be used for GPU driver compatibility.

**Don't forget dlopen'd modules** — these don't appear in `ldd` output:
- GIO modules (dconf): `libdconfsettings.so`
- GDK pixbuf loaders: `libpixbufloader_*.so`
- GStreamer plugins (if applicable)

For each dlopen'd module, also run `ldd` on it and bundle any missing deps.

### Step 4: Patch the binary with patchelf

```bash
# System dynamic linker
patchelf --set-interpreter /lib64/ld-linux-x86-64.so.2 myapp

# RUNPATH: bundled libs first, system libs second
patchelf --set-rpath '/usr/lib/myapp:/usr/lib/x86_64-linux-gnu' myapp
```

Use `--set-rpath` (sets `DT_RUNPATH`), NOT `--force-rpath` (sets `DT_RPATH`).
`RUNPATH` allows `LD_LIBRARY_PATH` to override, which is essential for:
- Pre-install testing
- Debugging library issues
- User customization

Also patch all bundled `.so` files with the same RUNPATH.

### Step 5: Handle GTK runtime resources

GTK applications need more than just shared libraries. Bundle and configure:

#### GDK Pixbuf loaders
Without these, GTK can't load PNG/SVG images (no icons).
```
/usr/lib/myapp/gdk-pixbuf-2.0/2.10.0/loaders/*.so
/usr/lib/myapp/gdk-pixbuf-2.0/2.10.0/loaders.cache  # rewrite nix paths!
```

#### GSettings schemas
Without these, GTK4 and libadwaita crash or misbehave.
```
/usr/share/myapp-schemas/glib-2.0/schemas/gschemas.compiled
```
Compile from XML sources of `gsettings-desktop-schemas` + the toolkit.

#### GIO modules
Without the dconf module, settings don't persist.
```
/usr/lib/myapp/gio/modules/libdconfsettings.so
```

#### GObject introspection typelibs
```
/usr/lib/myapp/girepository-1.0/*.typelib
```

### Step 6: Create a wrapper script

The wrapper sets environment variables pointing to the bundled resources:

```sh
#!/bin/sh
export GIO_EXTRA_MODULES="/usr/lib/myapp/gio/modules${GIO_EXTRA_MODULES:+:$GIO_EXTRA_MODULES}"
export GDK_PIXBUF_MODULE_FILE=/usr/lib/myapp/gdk-pixbuf-2.0/2.10.0/loaders.cache
export XDG_DATA_DIRS="/usr/share/myapp-schemas:/usr/share${XDG_DATA_DIRS:+:$XDG_DATA_DIRS}"
export GI_TYPELIB_PATH="/usr/lib/myapp/girepository-1.0${GI_TYPELIB_PATH:+:$GI_TYPELIB_PATH}"
exec /usr/bin/.myapp-bin "$@"
```

### Step 7: Fix data files

Data files from the nix build contain hardcoded `/nix/store/...` paths. Fix:
- `.desktop` files: `sed 's|/nix/store/[^/]*/bin/myapp|/usr/bin/myapp|g'`
- D-Bus service files: same sed pattern
- Systemd service files: same sed pattern
- Symlinks to nix store: use `cp -rL` to dereference

### Step 8: Package as .deb

Use `dpkg-deb` from nixpkgs (`pkgs.dpkg` in `nativeBuildInputs`).

Key `DEBIAN/control` considerations:
- `Depends: libc6 (>= X.XX)` — check actual glibc version symbols needed
- Don't depend on system GTK/libadwaita since you're bundling them
- Add `postinst`/`postrm` for `update-desktop-database` and
  `gtk-update-icon-cache`
- Watch for file conflicts with system packages (e.g., terminfo vs
  `ncurses-term`)

## Debugging

### Pre-install testing

Since RUNPATH points to `/usr/lib/myapp` (which doesn't exist before install),
test with `LD_LIBRARY_PATH`:

```bash
LD_LIBRARY_PATH=result/myapp_*/usr/lib/myapp \
  GDK_PIXBUF_MODULE_FILE=result/myapp_*/usr/lib/myapp/gdk-pixbuf-2.0/2.10.0/loaders.cache \
  XDG_DATA_DIRS=result/myapp_*/usr/share/myapp-schemas:result/myapp_*/usr/share \
  result/myapp_*/usr/bin/.myapp-bin
```

### Library loading issues

```bash
# Which libEGL is loaded?
LD_DEBUG=libs myapp 2>&1 | grep -i egl

# Check for missing symbols
LD_DEBUG=symbols myapp 2>&1 | grep 'undefined symbol'

# Verify RUNPATH
readelf -d /usr/bin/.myapp-bin | grep RUNPATH
```

### Common failures

| Symptom | Cause | Fix |
|---------|-------|-----|
| `Failed to create EGL display` | glibc mismatch with NVIDIA | Exclude glibc from bundle |
| `undefined symbol: gtk_*` | GTK version mismatch | Bundle nix GTK, don't use system |
| `undefined symbol: __malloc_hook` | Nix glibc too new for NVIDIA | Use host glibc (don't bundle it) |
| No icons / broken images | Missing pixbuf loaders | Bundle loaders + fix `loaders.cache` |
| `GSettings schema not found` | Missing compiled schemas | Bundle + set `XDG_DATA_DIRS` |
| `cannot open shared object` | Library not in RUNPATH | Check `ldd`, add to bundle |

## GPU Driver Independence

This pattern produces packages that are **GPU driver version independent**.
The `.deb` contains zero NVIDIA/AMD/Intel-specific libraries. The host's
`libglvnd` dispatches to whatever GPU vendor library is installed. Driver
updates require no rebuild.

This works because:
1. The bundled `libepoxy` and `libglvnd` (from nix) handle GL/EGL dispatch
2. `libglvnd` reads vendor ICDs from system paths (`/usr/share/glvnd/egl_vendor.d/`)
3. Vendor libraries (`libEGL_nvidia.so.0`) are loaded from the system's `ld.so.cache`
4. The host's glibc provides symbols (like `__malloc_hook`) that vendor drivers need
5. glibc ABI is extremely stable — nix-built libs work with any host glibc >= their build version

## Stripping Nix Store References

`patchelf` handles ELF metadata (interpreter, RUNPATH), but compiled binaries
and data files can contain hardcoded `/nix/store/...` paths as string literals.
Nix provides two tools for this (distinct from patchelf):

### `remove-references-to` — Surgical removal

Replaces specific store path hashes with `eeeeeeee...` (same length, preserves
binary structure). Use when you want to strip build-time deps while keeping
runtime deps:

```nix
{ removeReferencesTo, stdenv, ... }:

stdenv.mkDerivation {
  nativeBuildInputs = [ removeReferencesTo ];

  postFixup = ''
    # Strip compiler references from the output
    find $out -type f -exec remove-references-to -t ${stdenv.cc} '{}' +
  '';

  # Safety net: fail build if compiler refs leak through
  disallowedReferences = [ stdenv.cc ];
}
```

### `nukeReferences` — Blanket removal

Removes ALL `/nix/store/` references. Use for fully self-contained binaries
(especially CLI tools) that should have zero nix store dependencies:

```nix
{ nukeReferences, ... }:

stdenv.mkDerivation {
  nativeBuildInputs = [ nukeReferences ];

  postFixup = ''
    nuke-refs $out/bin/mytool
  '';
}
```

### When to use which

| Scenario | Tool | Why |
|----------|------|-----|
| CLI tool → .deb | `nukeReferences` + `patchelf` | No nix deps needed at runtime |
| GTK app → .deb | `remove-references-to` (selective) | Keep refs to bundled libs, strip build deps |
| Strip compiler from output | `remove-references-to -t ${stdenv.cc}` | Common practice in nixpkgs |
| Safety check | `disallowedReferences` attribute | Fails build if unwanted refs remain |

### How it works internally

Nix determines runtime dependencies by scanning output files for the 32-char
base32 hash portion of store paths. Both tools replace matching hashes with
`eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee` (32 `e`s). The substitution is the same
length, so binary offsets and file sizes are preserved. The resulting path
`/nix/store/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee-...` doesn't exist, so nix no
longer considers it a dependency.

## Applying the Pattern: CLI vs GUI Apps

### CLI applications

The simplest case — no GTK resources, minimal wrapper:

```nix
nixToDeb = import ./nix-to-deb.nix;

ripgrepDeb = nixToDeb {
  inherit pkgs;
  package = pkgs.ripgrep;
  binName = "rg";
  shareFiles = [ "man" ];
  description = "Fast regex search tool";
};
```

The function handles: `ldd` closure collection, `patchelf` (interpreter +
RUNPATH), `remove-references-to` (strip compiler refs), soname symlinks,
wrapper script, and `dpkg-deb` packaging. The result is a binary that uses
only system libs plus any bundled nix libs it needs.

### GTK applications (this project)

Enable `gtkSupport = true` and the function automatically handles GIO modules,
pixbuf loaders, GSettings schemas, typelibs, and the wrapper env vars:

```nix
ghosttyDeb = nixToDeb {
  inherit pkgs;
  package = pkgs.ghostty;
  realBinary = "${pkgs.ghostty}/bin/.ghostty-wrapped";
  gtkSupport = true;
  gtkPackage = pkgs.gtk4;
  typelibPackages = [ pkgs.gtk4 pkgs.libadwaita pkgs.pango ... ];
  extraLibPackages = [ pkgs.gtk4-layer-shell ];
  shareFiles = [ "ghostty" "applications" "icons" "man" ... ];
  extraWrapperEnv = [
    { name = "GHOSTTY_RESOURCES_DIR"; value = "/usr/share/ghostty"; append = false; }
  ];
};
```

See `flake.nix` for the complete configuration.

### Qt applications

Similar to GTK but different plugin system:

1. Steps 1-3 same as GTK
2. Bundle: shared libs + Qt plugins (platforms, imageformats, xcbglintegrations)
3. Set `QT_PLUGIN_PATH` in wrapper to bundled plugin directory
4. May need `qt.conf` file alongside the binary
5. Steps 7-8 same as GTK

## Limitations

- **Architecture-specific** — interpreter path, lib path, and Debian arch
  string are all platform-dependent
- **Large packages** — bundling ~250 .so files adds ~40MB compressed
- **No automatic updates** — this isn't a PPA; rebuilds are manual
- **glibc floor** — if the nix-built libs use `GLIBC_2.39` symbols, the host
  must have glibc >= 2.39

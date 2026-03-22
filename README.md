# Ghostty .deb Releases

Pre-built `.deb` packages of [Ghostty](https://ghostty.org) for Debian/Ubuntu
(amd64). Download from
[Releases](https://github.com/barstoolbluz/package-ghostty-for-deb/releases)
or build from source with Nix.

## Why?

Ghostty is a GPU-accelerated terminal emulator. On non-NixOS Linux with
proprietary NVIDIA drivers, the standard Nix-built binary can't create an EGL
display because:

1. NVIDIA's `libnvidia-eglcore.so` uses legacy glibc symbols (`__malloc_hook`)
   removed in glibc 2.34+. Nix ships glibc 2.42, which lacks them.
2. NixGL rebuilds the NVIDIA userspace from nixpkgs. Even with matching version
   numbers, the rebuild is binary-incompatible with the host kernel module.
3. Ghostty's nix build pins GTK4 4.20.x, which may be newer than what the
   distro ships (Debian trixie has 4.18.x), so system GTK4 can't be used either.

This flake solves the problem by building a `.deb` that **bundles all nix-built
libraries** (GTK4, libadwaita, harfbuzz, etc.) while using the **host's glibc
and GPU drivers**, giving you the best of both worlds.

## Install from Release

```bash
# Download the latest .deb from GitHub releases
gh release download --repo barstoolbluz/package-ghostty-for-deb -p '*.deb'

# Install
sudo dpkg -i ghostty_*_amd64.deb
```

## Build from Source

```bash
# Requires nix with flakes enabled
nix build .
sudo dpkg -i result/ghostty_*_amd64.deb
```

No `--impure` flag needed. No NixGL. No Flox workarounds.

## What's in the .deb

| Component | Source | Why |
|-----------|--------|-----|
| Ghostty binary | Nix (patchelf'd) | System interpreter, bundled RUNPATH |
| GTK4, libadwaita, pango, harfbuzz, ... | Nix (bundled) | Distro version may be too old |
| GDK pixbuf loaders + cache | Nix (bundled) | Needed for icon rendering |
| GIO modules (dconf) | Nix (bundled) | Settings persistence |
| GSettings schemas | Nix (compiled) | GTK4/libadwaita require them |
| GObject introspection typelibs | Nix (bundled) | Runtime GI functionality |
| Shell integration, themes, completions | Nix (copied) | Dereferenced from nix store symlinks |
| Desktop entry, icons, man pages | Nix (path-fixed) | Nix store paths rewritten to `/usr/` |
| glibc | **Host system** | NVIDIA drivers need `__malloc_hook` |
| GPU drivers (EGL/GL/Vulkan) | **Host system** | Must match running kernel module |

### Installed layout

```
/usr/bin/ghostty              # Wrapper script (sets env vars)
/usr/bin/.ghostty-bin          # Actual binary (patchelf'd)
/usr/lib/ghostty/              # ~245 bundled shared libraries
/usr/lib/ghostty/gio/modules/  # GIO dconf module
/usr/lib/ghostty/gdk-pixbuf-2.0/  # Pixbuf loaders + cache
/usr/lib/ghostty/girepository-1.0/ # Typelibs
/usr/share/ghostty/            # Themes, shell integration, docs
/usr/share/ghostty-schemas/    # Compiled GSettings schemas
/usr/share/applications/       # Desktop entry
/usr/share/icons/              # App icons
```

## How It Works

The build uses [nix-to-deb](../nix-to-deb), a generic function that takes any
nix package and produces a `.deb`. The ghostty-specific configuration is in
`flake.nix`; all the bundling, patching, and packaging logic lives in
`nix-to-deb`.

The function does four things:

### 1. Bundle libraries from nix

All shared library dependencies (from `ldd`) are copied into
`/usr/lib/ghostty/`, excluding glibc. Additional runtime-loaded modules (GIO,
pixbuf loaders, SVG loader from librsvg) are bundled separately since they
don't appear in `ldd` output.

### 2. Patch the binary

`patchelf` rewrites the ELF binary:
- **Interpreter**: `/lib64/ld-linux-x86-64.so.2` (system ld-linux)
- **RUNPATH**: `/usr/lib/ghostty:/usr/lib/x86_64-linux-gnu`

The bundled libs are found first. glibc and GPU drivers fall through to the
system path. Using `RUNPATH` (not `RPATH`) follows the modern convention and
allows `LD_LIBRARY_PATH` overrides for debugging.

### 3. Strip nix store references

`remove-references-to` strips residual `/nix/store/...` paths from binaries
and data files (replacing the 32-char hash with `eeee...` to preserve binary
layout). `sed` rewrites paths in `.desktop`, D-Bus, and systemd service files.

### 4. Wrapper script

A shell wrapper at `/usr/bin/ghostty` sets environment variables that the nix
`makeBinaryWrapper` normally provides:

- `GIO_EXTRA_MODULES` — dconf settings backend
- `GDK_PIXBUF_MODULE_FILE` — image loader cache
- `XDG_DATA_DIRS` — GSettings schemas
- `GI_TYPELIB_PATH` — GObject introspection
- `GHOSTTY_RESOURCES_DIR` — themes, shell integration

## NVIDIA Driver Updates

The `.deb` contains **zero NVIDIA-specific libraries**. GPU drivers are loaded
at runtime from the host's `/usr/lib/x86_64-linux-gnu/` via libglvnd's EGL
vendor dispatch. When NVIDIA updates from 595.x to 600.x or beyond, ghostty
picks up the new drivers automatically. No rebuild needed.

## Releasing a New Version

```bash
# Build and release the latest stable ghostty tag
./release.sh latest

# Or a specific version
./release.sh v1.3.1
```

The script pins the flake input to the tag, builds the `.deb`, and optionally
creates a GitHub release with the artifact attached.

Historical releases are preserved — users can download any version from the
[Releases](https://github.com/barstoolbluz/package-ghostty-for-deb/releases)
page.

## Remote Hosts and Terminal Multiplexers

Ghostty sets `TERM=xterm-ghostty`. When you SSH to a remote host, this value
propagates, and programs like **tmux**, **byobu**, and **screen** will fail
with `missing or unsuitable terminal: xterm-ghostty` if the remote doesn't
have the terminfo entry.

**Copy the terminfo to a remote host (one-time):**

```bash
infocmp xterm-ghostty | ssh user@remote 'tic -x -'
```

This compiles the entry into `~/.terminfo/` on the remote. You only need to do
it once per host.

**Or override TERM per-session:**

```bash
TERM=xterm-256color byobu
```

**Or install the .deb on the remote** — it includes `xterm-ghostty` terminfo
alongside the full application.

## Limitations

- **x86_64 only** — architecture is hardcoded. Adapting for aarch64 requires
  changing `system`, `debArch`, `libDir`, and `interpreter`. This is not
  necessarily a huge lift. But documenting this here in any case.
- **Terminfo**: bundles `xterm-ghostty` (which ghostty sets as `$TERM`) but not
  `ghostty` (already provided by `ncurses-term`, would conflict on install).
- **glibc >= 2.38 required** — the nix-built libraries reference symbols up to
  `GLIBC_2.38`. Debian trixie (2.41) and Ubuntu 24.04+ (2.39) satisfy this.
- **No auto-updates** — this is a local build, not a PPA.

## The Packaging System

This repo uses [nix-to-deb](https://github.com/barstoolbluz/nix-to-deb), a
generic function for packaging any nix-built application as a `.deb`. See
[CLAUDE.md](CLAUDE.md) for a detailed writeup of the underlying technique.

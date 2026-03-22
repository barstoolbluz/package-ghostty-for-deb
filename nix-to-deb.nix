# nix-to-deb.nix — Generic function for packaging nix-built applications as .deb
#
# Usage:
#   nixToDeb = import ./nix-to-deb.nix;
#   myDeb = nixToDeb {
#     inherit pkgs;
#     package = pkgs.myapp;
#     ...
#   };

{ pkgs
, package                     # The nix package to convert
, pname ? package.pname       # Debian package name
, version ? package.version   # Debian package version
, debArch ? "amd64"           # Debian architecture string
, interpreter ? "/lib64/ld-linux-x86-64.so.2"
, systemLibDir ? "/usr/lib/x86_64-linux-gnu"
, bundleLibDir ? "/usr/lib/${pname}"  # Where bundled libs install to

  # --- Binary discovery ---
  # Path to the real binary (unwrapped). If the package uses makeBinaryWrapper,
  # this is typically "${package}/bin/.${binName}-wrapped".
  # Set to null to auto-detect.
, realBinary ? null
, binName ? pname             # Name of the binary in the package's bin/

  # --- What to bundle ---
, excludeLibs ? [ "glibc" ]   # Grep patterns for libs to exclude from bundling
, extraLibs ? []              # Additional .so files/dirs to bundle
                              # e.g. [ "${pkgs.gtk4-layer-shell}/lib/libgtk4-layer-shell.so.1.3.0" ]
, extraLibPackages ? []       # Additional packages whose ldd deps should be bundled

  # --- GTK resources (set to true for GTK apps) ---
, gtkSupport ? false
, gdkPixbuf ? pkgs.gdk-pixbuf
, librsvg ? pkgs.librsvg
, dconfLib ? pkgs.dconf.lib
, gsettingsSchemas ? pkgs.gsettings-desktop-schemas
, gtkPackage ? pkgs.gtk4
, typelibPackages ? []        # Packages providing .typelib files

  # --- Wrapper script ---
  # Extra environment variables for the wrapper script.
  # List of { name = "VAR"; value = "/some/path"; append = true; }
  # If append is true, appends to existing value with ':' separator.
, extraWrapperEnv ? []

  # --- Data files ---
  # Paths within the package's share/ to copy. Symlinks are dereferenced.
, shareFiles ? []             # e.g. [ "applications" "icons" "man" ]
, fixDesktopFiles ? true      # sed nix store paths in .desktop files
, fixDbusServices ? true      # sed nix store paths in dbus service files
, fixSystemdServices ? true   # sed nix store paths in systemd user services
  # Note: control what gets copied by listing dirs in shareFiles.
  # Omit dirs like "terminfo" to avoid conflicts with system packages.
, extraShareCopies ? []       # Additional share files from other nix paths.
                              # List of { src = "/nix/store/.../share/foo"; dst = "foo"; }
                              # dst is relative to /usr/share/

  # --- Debian metadata ---
, depends ? [ "libc6 (>= 2.38)" ]
, recommends ? []
, section ? "utils"
, homepage ? ""
, maintainer ? "Local Build <noreply@localhost>"
, description ? "${pname} (built from nix)"
, longDescription ? "Built from source using Nix with bundled library dependencies."
, postinst ? null             # Custom postinst script content (string)
, postrm ? null               # Custom postrm script content (string)
}:

let
  lib = pkgs.lib;

  bundlePath = bundleLibDir;

  # Auto-detect the real binary: check for .${binName}-wrapped, then fall back to binName
  detectedBinary =
    if realBinary != null then realBinary
    else "${package}/bin/.${binName}-wrapped";

  excludePattern = builtins.concatStringsSep "\\|" excludeLibs;

  # Build the wrapper script
  wrapperEnvLines =
    let
      gtkEnv = lib.optionals gtkSupport [
        { name = "GIO_EXTRA_MODULES"; value = "${bundlePath}/gio/modules"; append = true; }
        { name = "GDK_PIXBUF_MODULE_FILE"; value = "${bundlePath}/gdk-pixbuf-2.0/2.10.0/loaders.cache"; append = false; }
        { name = "XDG_DATA_DIRS"; value = "/usr/share/${pname}-schemas:/usr/share"; append = true; }
        { name = "GI_TYPELIB_PATH"; value = "${bundlePath}/girepository-1.0"; append = true; }
      ];
      allEnv = gtkEnv ++ extraWrapperEnv;
      mkEnvLine = e:
        if e.append or false
        then "export ${e.name}=\"${e.value}\${${e.name}:+:\$${e.name}}\""
        else "export ${e.name}=\"${e.value}\"";
    in
    builtins.concatStringsSep "\n" (map mkEnvLine allEnv);

  # Default postinst for desktop apps
  defaultPostinst = ''
    #!/bin/sh
    set -e
    if command -v update-desktop-database >/dev/null 2>&1; then
      update-desktop-database -q /usr/share/applications 2>/dev/null || true
    fi
    if command -v gtk-update-icon-cache >/dev/null 2>&1; then
      gtk-update-icon-cache -q /usr/share/icons/hicolor 2>/dev/null || true
    fi
  '';

  defaultPostrm = ''
    #!/bin/sh
    set -e
    if [ "$1" = "remove" ] || [ "$1" = "purge" ]; then
      if command -v update-desktop-database >/dev/null 2>&1; then
        update-desktop-database -q /usr/share/applications 2>/dev/null || true
      fi
      if command -v gtk-update-icon-cache >/dev/null 2>&1; then
        gtk-update-icon-cache -q /usr/share/icons/hicolor 2>/dev/null || true
      fi
    fi
  '';

  actualPostinst = if postinst != null then postinst else defaultPostinst;
  actualPostrm = if postrm != null then postrm else defaultPostrm;

in pkgs.stdenv.mkDerivation {
  pname = "${pname}-deb";
  inherit version;

  dontUnpack = true;
  dontBuild = true;
  dontFixup = true;

  nativeBuildInputs = [
    pkgs.patchelf
    pkgs.dpkg
    pkgs.removeReferencesTo
  ];

  installPhase = ''
    runHook preInstall

    PKG=$out/${pname}_${version}_${debArch}
    LIBDIR=$PKG${bundlePath}
    SHAREDIR=$PKG/usr/share

    mkdir -p $PKG/DEBIAN $PKG/usr/bin $LIBDIR

    # =================================================================
    # 1. Shared libraries
    # =================================================================

    # Helper: bundle ldd deps of a binary, excluding glibc
    bundle_ldd_deps() {
      local binary="$1"
      for lib in $(ldd "$binary" 2>/dev/null \
                   | grep '/nix/store' \
                   | grep -v '${excludePattern}' \
                   | awk '{print $3}' \
                   | sort -u); do
        if [ -f "$lib" ]; then
          target=$(basename "$lib")
          if [ ! -e "$LIBDIR/$target" ]; then
            cp "$lib" "$LIBDIR/$target"
          fi
        fi
      done
    }

    # Bundle deps of the main binary
    bundle_ldd_deps "${detectedBinary}"

    # Bundle extra library files
    ${builtins.concatStringsSep "\n" (map (lib: ''
      if [ -f "${lib}" ]; then
        cp "${lib}" "$LIBDIR/"
      elif [ -L "${lib}" ]; then
        linkto=$(basename "$(readlink "${lib}")")
        target=$(basename "${lib}")
        [ "$linkto" != "$target" ] && ln -sf "$linkto" "$LIBDIR/$target"
      fi
    '') extraLibs)}

    # Bundle deps of extra packages
    ${builtins.concatStringsSep "\n" (map (pkg: ''
      for so in ${pkg}/lib/*.so*; do
        if [ -f "$so" ] && ! [ -L "$so" ]; then
          target=$(basename "$so")
          [ ! -e "$LIBDIR/$target" ] && cp "$so" "$LIBDIR/$target"
        elif [ -L "$so" ]; then
          linkto=$(basename "$(readlink "$so")")
          target=$(basename "$so")
          [ "$linkto" != "$target" ] && [ ! -e "$LIBDIR/$target" ] && \
            ln -sf "$linkto" "$LIBDIR/$target"
        fi
      done
      for so in ${pkg}/lib/*.so*; do
        [ -f "$so" ] && bundle_ldd_deps "$so"
      done
    '') extraLibPackages)}

    # Create soname symlinks
    for lib in $LIBDIR/*.so.*; do
      [ ! -e "$lib" ] && continue
      base=$(basename "$lib")
      soname=$(echo "$base" | sed 's/\.so\..*/\.so/')
      [ ! -e "$LIBDIR/$soname" ] && ln -sf "$base" "$LIBDIR/$soname"
    done

    # Fix permissions and RPATH on all bundled libs
    for lib in $LIBDIR/*.so*; do
      if [ -f "$lib" ] && ! [ -L "$lib" ]; then
        chmod u+w "$lib"
        patchelf --set-rpath '${bundlePath}:${systemLibDir}' "$lib" 2>/dev/null || true
        # Strip nix store references from the binary
        remove-references-to -t ${pkgs.stdenv.cc} "$lib" 2>/dev/null || true
      fi
    done

    # =================================================================
    # 2. GTK resources (only if gtkSupport is enabled)
    # =================================================================
    ${lib.optionalString gtkSupport ''
      # GIO modules (dconf)
      mkdir -p $LIBDIR/gio/modules
      cp ${dconfLib}/lib/gio/modules/libdconfsettings.so $LIBDIR/gio/modules/
      chmod u+w $LIBDIR/gio/modules/libdconfsettings.so
      patchelf --set-rpath '${bundlePath}:${systemLibDir}' \
        $LIBDIR/gio/modules/libdconfsettings.so 2>/dev/null || true
      bundle_ldd_deps "${dconfLib}/lib/gio/modules/libdconfsettings.so"

      # GDK pixbuf loaders
      mkdir -p $LIBDIR/gdk-pixbuf-2.0/2.10.0/loaders
      for loader in ${gdkPixbuf}/lib/gdk-pixbuf-2.0/2.10.0/loaders/*.so; do
        cp "$loader" $LIBDIR/gdk-pixbuf-2.0/2.10.0/loaders/
      done
      if [ -f ${librsvg}/lib/gdk-pixbuf-2.0/2.10.0/loaders/libpixbufloader_svg.so ]; then
        cp ${librsvg}/lib/gdk-pixbuf-2.0/2.10.0/loaders/libpixbufloader_svg.so \
          $LIBDIR/gdk-pixbuf-2.0/2.10.0/loaders/
        bundle_ldd_deps "${librsvg}/lib/gdk-pixbuf-2.0/2.10.0/loaders/libpixbufloader_svg.so"
      fi
      for loader in $LIBDIR/gdk-pixbuf-2.0/2.10.0/loaders/*.so; do
        chmod u+w "$loader"
        patchelf --set-rpath '${bundlePath}:${systemLibDir}' "$loader" 2>/dev/null || true
      done

      # Regenerate loaders.cache with bundled paths
      sed "s|/nix/store/[^/]*/lib/gdk-pixbuf-2.0/2.10.0/loaders|${bundlePath}/gdk-pixbuf-2.0/2.10.0/loaders|g" \
        ${librsvg}/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache \
        > $LIBDIR/gdk-pixbuf-2.0/2.10.0/loaders.cache

      # GSettings schemas
      mkdir -p $SHAREDIR/${pname}-schemas/glib-2.0/schemas
      cp ${gsettingsSchemas}/share/gsettings-schemas/*/glib-2.0/schemas/*.xml \
        $SHAREDIR/${pname}-schemas/glib-2.0/schemas/ 2>/dev/null || true
      cp ${gtkPackage}/share/gsettings-schemas/*/glib-2.0/schemas/*.xml \
        $SHAREDIR/${pname}-schemas/glib-2.0/schemas/ 2>/dev/null || true
      # Strip nix store paths from schema XML before compiling
      find $SHAREDIR/${pname}-schemas -name '*.xml' -exec \
        sed -i 's|/nix/store/[^<]*|/usr/share/backgrounds/gnome/placeholder|g' '{}' + 2>/dev/null || true
      ${pkgs.glib.dev}/bin/glib-compile-schemas \
        $SHAREDIR/${pname}-schemas/glib-2.0/schemas/ 2>/dev/null || true

      # GObject introspection typelibs
      ${lib.optionalString (typelibPackages != []) ''
        mkdir -p $LIBDIR/girepository-1.0
        ${builtins.concatStringsSep "\n" (map (pkg: ''
          if [ -d ${pkg}/lib/girepository-1.0 ]; then
            cp ${pkg}/lib/girepository-1.0/*.typelib $LIBDIR/girepository-1.0/ 2>/dev/null || true
          fi
        '') typelibPackages)}
      ''}
    ''}

    # =================================================================
    # 3. Binary + wrapper
    # =================================================================
    # Copy the real binary — try the detected path, fall back to the unwrapped name
    if [ -f "${detectedBinary}" ]; then
      cp "${detectedBinary}" $PKG/usr/bin/.${binName}-bin
    elif [ -f "${package}/bin/${binName}" ]; then
      cp "${package}/bin/${binName}" $PKG/usr/bin/.${binName}-bin
    else
      echo "ERROR: could not find binary '${binName}' in package" >&2
      exit 1
    fi
    chmod u+w,+x $PKG/usr/bin/.${binName}-bin
    patchelf --set-interpreter ${interpreter} $PKG/usr/bin/.${binName}-bin
    patchelf --set-rpath '${bundlePath}:${systemLibDir}' $PKG/usr/bin/.${binName}-bin

    # Strip nix store references from the binary
    remove-references-to -t ${pkgs.stdenv.cc} $PKG/usr/bin/.${binName}-bin 2>/dev/null || true

    # Wrapper script
    cat > $PKG/usr/bin/${binName} <<'WRAPPER_EOF'
#!/bin/sh
${wrapperEnvLines}
exec /usr/bin/.${binName}-bin "$@"
WRAPPER_EOF
    chmod +x $PKG/usr/bin/${binName}

    # =================================================================
    # 4. Data files from share/
    # =================================================================
    ${builtins.concatStringsSep "\n" (map (dir: ''
      if [ -d "${package}/share/${dir}" ]; then
        mkdir -p "$SHAREDIR/${dir}"
        cp -rL "${package}/share/${dir}/." "$SHAREDIR/${dir}/"
        chmod -R u+w "$SHAREDIR/${dir}"
      fi
    '') shareFiles)}

    # Extra share copies from other nix store paths
    ${builtins.concatStringsSep "\n" (map (copy: ''
      if [ -e "${copy.src}" ]; then
        mkdir -p "$SHAREDIR/${copy.dst}"
        cp -rL "${copy.src}/." "$SHAREDIR/${copy.dst}/"
        chmod -R u+w "$SHAREDIR/${copy.dst}"
      fi
    '') extraShareCopies)}

    # Fix nix store paths in data files
    ${lib.optionalString fixDesktopFiles ''
      for f in $SHAREDIR/applications/*.desktop; do
        [ -f "$f" ] && sed -i 's|/nix/store/[^/]*/bin/${binName}|/usr/bin/${binName}|g' "$f"
      done
    ''}
    ${lib.optionalString fixDbusServices ''
      for f in $SHAREDIR/dbus-1/services/*.service; do
        [ -f "$f" ] && sed -i 's|/nix/store/[^/]*/bin/${binName}|/usr/bin/${binName}|g' "$f"
      done
    ''}
    ${lib.optionalString fixSystemdServices ''
      for f in $SHAREDIR/systemd/user/*.service; do
        [ -f "$f" ] && sed -i 's|/nix/store/[^/]*|/usr|g' "$f"
      done
    ''}

    # Strip any remaining nix store references from data files
    find $SHAREDIR -type f \( -name "*.desktop" -o -name "*.service" -o -name "*.xml" \) \
      -exec remove-references-to -t ${pkgs.stdenv.cc} '{}' + 2>/dev/null || true

    # =================================================================
    # 5. DEBIAN metadata
    # =================================================================
    INSTALLED_SIZE=$(du -sk "$PKG" | awk '{print $1}')
    cat > $PKG/DEBIAN/control <<CTRL_EOF
Package: ${pname}
Version: ${version}
Section: ${section}
Priority: optional
Architecture: ${debArch}
Installed-Size: $INSTALLED_SIZE
Depends: ${builtins.concatStringsSep ", " depends}
${lib.optionalString (recommends != []) "Recommends: ${builtins.concatStringsSep ", " recommends}\n"}Maintainer: ${maintainer}
Description: ${description}
 ${longDescription}
${lib.optionalString (homepage != "") "Homepage: ${homepage}"}
CTRL_EOF

    cat > $PKG/DEBIAN/postinst <<'POSTINST_EOF'
${actualPostinst}
POSTINST_EOF
    chmod 755 $PKG/DEBIAN/postinst

    cat > $PKG/DEBIAN/postrm <<'POSTRM_EOF'
${actualPostrm}
POSTRM_EOF
    chmod 755 $PKG/DEBIAN/postrm

    # =================================================================
    # 6. Build .deb
    # =================================================================
    dpkg-deb --build --root-owner-group $PKG $out/${pname}_${version}_${debArch}.deb

    runHook postInstall
  '';
}

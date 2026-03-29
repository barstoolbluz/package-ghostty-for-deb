{
  description = "Ghostty terminal - build with nix, package as .deb for Debian/Ubuntu";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    ghostty.url = "github:ghostty-org/ghostty/v1.3.1";
    nix-to-deb = {
      url = "github:barstoolbluz/nix2deb";
      flake = true;
    };
  };

  outputs = { self, nixpkgs, ghostty, nix-to-deb, ... }:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
      nixToDeb = nix-to-deb.lib.nixToDeb;

      mkPackages = system:
        let
          pkgs = (import nixpkgs {
            inherit system;
            config.allowUnfree = true;
          }).extend ghostty.overlays.default;

          ghosttyDeb = nixToDeb {
            inherit pkgs;
            package = pkgs.ghostty;
            pname = "ghostty";
            version = builtins.replaceStrings [ "-dev" ] [ "" ] pkgs.ghostty.version;
            binName = "ghostty";
            realBinary = "${pkgs.ghostty}/bin/.ghostty-wrapped";

            # GTK4 app — bundle the full GTK runtime
            gtkSupport = true;
            gtkPackage = pkgs.gtk4;
            typelibPackages = [
              pkgs.cairo
              pkgs.gdk-pixbuf
              pkgs.glib
              pkgs.gobject-introspection
              pkgs.graphene
              pkgs.gtk4
              pkgs.gtk4-layer-shell
              pkgs.harfbuzz
              pkgs.libadwaita
              pkgs.pango
              pkgs.librsvg
            ];

            # Bundle libgtk4-layer-shell (may not be in distro repos)
            extraLibPackages = [ pkgs.gtk4-layer-shell ];

            # Extra env var specific to ghostty
            extraWrapperEnv = [
              { name = "GHOSTTY_RESOURCES_DIR"; value = "/usr/share/ghostty"; append = false; }
              { name = "XDG_CONFIG_DIRS"; value = "/usr/share/ghostty/default-config"; append = true; }
            ];

            # Data files to copy from the nix package's share/
            shareFiles = [
              "ghostty"
              "applications"
              "icons"
              "bash-completion"
              "zsh"
              "fish"
              "man"
              "dbus-1"
              "systemd"
              "metainfo"
              "locale"
              "bat"
              "kio"
              "nautilus-python"
              "nvim"
              "vim"
            ];

            # Terminfo: the main package's share/terminfo is empty; the xterm-ghostty
            # entry lives in a separate nix output. We bundle only xterm-ghostty
            # (under terminfo/x/) to avoid conflicting with ncurses-term's ghostty entry
            # (under terminfo/g/).
            extraShareCopies = [
              { src = "${pkgs.ghostty.terminfo}/share/terminfo/x"; dst = "terminfo/x"; }
              # Bundle JetBrains Mono (ghostty's default font) as a system font
              { src = "${pkgs.jetbrains-mono}/share/fonts/truetype"; dst = "fonts/truetype/jetbrains-mono"; }
              # Bundle default ghostty config (system-wide fallback via XDG_CONFIG_DIRS)
              { src = ./config.ghostty; dst = "ghostty/default-config/ghostty/config.ghostty"; }
            ];

            # Note: "terminfo" omitted from shareFiles to avoid conflict with ncurses-term

            section = "x11";
            homepage = "https://ghostty.org";
            description = "Ghostty terminal emulator";
            longDescription = "A fast, feature-rich, and cross-platform terminal emulator that uses platform-native UI and GPU acceleration.\n .\n Built from source using Nix with bundled GTK4 and library dependencies.\n Uses the system glibc and GPU drivers for hardware compatibility.";
            depends = [ "libc6 (>= 2.38)" "dbus" "fontconfig" "xdg-utils" ];
            recommends = [ "fonts-noto-color-emoji" ];

            postinst = ''
              #!/bin/sh
              set -e
              if command -v update-desktop-database >/dev/null 2>&1; then
                update-desktop-database -q /usr/share/applications 2>/dev/null || true
              fi
              if command -v gtk-update-icon-cache >/dev/null 2>&1; then
                gtk-update-icon-cache -q /usr/share/icons/hicolor 2>/dev/null || true
              fi
              if command -v fc-cache >/dev/null 2>&1; then
                fc-cache -f /usr/share/fonts/truetype/jetbrains-mono 2>/dev/null || true
              fi
            '';
          };

        in {
          default = ghosttyDeb;
          deb = ghosttyDeb;
          unwrapped = pkgs.ghostty;
        };

    in {
      packages = forAllSystems mkPackages;
    };
}

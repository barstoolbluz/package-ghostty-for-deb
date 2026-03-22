{
  description = "Ghostty terminal - build with nix, package as .deb for Debian/Ubuntu";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    ghostty.url = "github:ghostty-org/ghostty";
  };

  outputs = { self, nixpkgs, ghostty, ... }:
    let
      system = "x86_64-linux";
      pkgs = (import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      }).extend ghostty.overlays.default;

      nixToDeb = import ./nix-to-deb.nix;

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
        ];

        # Terminfo: the main package's share/terminfo is empty; the xterm-ghostty
        # entry lives in a separate nix output. We bundle only xterm-ghostty
        # (under terminfo/x/) to avoid conflicting with ncurses-term's ghostty entry
        # (under terminfo/g/).
        extraShareCopies = [
          { src = "${pkgs.ghostty.terminfo}/share/terminfo/x"; dst = "terminfo/x"; }
        ];

        section = "x11";
        homepage = "https://ghostty.org";
        description = "Ghostty terminal emulator";
        longDescription = "A fast, feature-rich, and cross-platform terminal emulator that uses platform-native UI and GPU acceleration.\n .\n Built from source using Nix with bundled GTK4 and library dependencies.\n Uses the system glibc and GPU drivers for hardware compatibility.";
        recommends = [ "fonts-noto-color-emoji" "xdg-utils" "dbus" ];
      };

    in
    {
      packages.${system} = {
        default = ghosttyDeb;
        deb = ghosttyDeb;
        unwrapped = pkgs.ghostty;
      };
    };
}

# SPDX-License-Identifier: MIT
{
  pkgs,
  coreSrc,
  sourceInfo ? { },
}:
let
  inherit (pkgs) lib;
  core = import (coreSrc + "/nix") {
    inherit pkgs;
    namespace = "brl-impurifier";
  };
  installer = pkgs.fetchurl {
    url = "https://github.com/bedrocklinux/bedrocklinux-userland/releases/download/0.7.31/bedrock-linux-0.7.31-x86_64.sh";
    hash = "sha256-vIGR6uc1B7tsUQgF6r6bqyLg34prRVRmsUGAL//U1cU=";
  };
  sdk = pkgs.linkFarm "brl-impurifier-sdk" [
    {
      name = "python";
      path = pkgs.python3;
    }
    {
      name = "nix";
      path = pkgs.nix;
    }
  ];
  package = pkgs.writeShellApplication {
    name = "brl-impurifier";
    runtimeInputs = [
      pkgs.nix
      pkgs.python3
    ];
    text = ''
      case "''${1:-}" in
        prepare) shift; exec ${sdk}/python/bin/python3 ${../src}/prepare.py "$@" ;;
        prune) shift; exec ${sdk}/python/bin/python3 ${../src}/prune.py "$@" ;;
        *) echo 'usage: brl-impurifier prepare [--owner USER] STRATUM | prune' >&2; exit 2 ;;
      esac
    '';
  };
  makeNativeStratum =
    { name, payload }:
    assert lib.assertMsg (
      builtins.match "[A-Za-z0-9_][A-Za-z0-9_.+-]*" name != null
    ) "invalid stratum name";
    pkgs.runCommand "${name}-native-stratum"
      {
        nativeBuildInputs = [
          pkgs.gnutar
          pkgs.gzip
        ];
      }
      ''
        mkdir -p $out
        tar --sort=name --mtime=@1 --owner=0 --group=0 --numeric-owner -C ${payload} -cf - . | gzip -n > $out/stratum.tar.gz
      '';
  makeStratum =
    {
      pkg,
      program ? pkg.meta.mainProgram or pkg.pname,
      offline ? false,
      hardware ? null,
      bundledNixStore ? null,
      bundledNixNotices ? [ ],
    }:
    assert lib.assertMsg (
      builtins.match "[A-Za-z0-9_][A-Za-z0-9_.+-]*" program != null
    ) "invalid executable name";
    let
      appSdk =
        if bundledNixStore == null then
          sdk
        else
          pkgs.linkFarm "brl-python-sdk" [
            {
              name = "python";
              path = pkgs.python3;
            }
          ];
      bundle = core.makeRuntimeTree { inherit bundledNixStore bundledNixNotices; };
    in
    pkgs.runCommand "${pkg.pname}-${pkg.version}-bedrock-stratum"
      {
        __structuredAttrs = true;
        unsafeDiscardReferences.out = true;
        nativeBuildInputs = [
          pkgs.gnutar
          pkgs.gzip
        ];
      }
      ''
        test -x ${pkg}/bin/${program}
        mkdir -p root/usr/bin root/usr/share/brl-impurifier root/etc $out
        implementation=root/usr/share/brl-impurifier
        cp ${../src/launch.py} "$implementation/launch.py"
        cp ${../src/state.py} "$implementation/state.py"
        cp ${coreSrc}/src/engine.py "$implementation/engine.py"
        cp ${../LICENSE} "$implementation/LICENSE"
        ${lib.optionalString (bundledNixStore != null) ''
          cp ${bundle}/usr/lib/brl-impurifier/nix-store "$implementation/nix-store"
          mkdir -p "$implementation/share/licenses/bundled-nix"
          cp -r ${bundle}/usr/share/licenses/brl-impurifier/bundled-nix/. "$implementation/share/licenses/bundled-nix/"
        ''}
        cp ${
          pkgs.writeText "application.json" (
            builtins.toJSON {
              inherit program offline;
              inherit (pkg) pname version;
              installable = toString pkg;
              sdk = toString appSdk;
              nixBin = "${pkgs.nix}/bin";
              implementationDigest =
                builtins.hashFile "sha256" ../src/launch.py
                + builtins.hashFile "sha256" ../src/state.py
                + builtins.hashFile "sha256" (coreSrc + "/src/engine.py");
              hardware = if hardware == null then null else { preload = [ ]; } // hardware;
            }
          )
        } "$implementation/application.json"
        cat > root/usr/bin/${program} <<'PY'
        #!${pkgs.python3}/bin/python3
        import runpy
        import sys
        sys.dont_write_bytecode = True
        sys.path.insert(0, '/usr/share/brl-impurifier')
        runpy.run_path('/usr/share/brl-impurifier/launch.py', run_name='__main__')
        PY
        chmod 755 root/usr/bin/${program}
        printf 'root:x:0:0:root:/root:/bin/sh\n' > root/etc/passwd
        printf 'root:x:0:\n' > root/etc/group
        printf 'NAME="Nix application stratum"\nID=nix-impurifiers\nVERSION_ID="${pkg.version}"\n' > root/etc/os-release
        ${lib.optionalString offline ''
          cp -r ${core.offlineCache pkg} "$implementation/cache"
          cp -r ${core.offlineCache appSdk} "$implementation/sdk-cache"
        ''}
        tar --sort=name --mtime=@1 --owner=0 --group=0 --numeric-owner -C root -cf - . | gzip -n > $out/stratum.tar.gz
      '';
in
{
  inherit
    package
    sdk
    installer
    makeStratum
    makeNativeStratum
    ;
  makeNetStratum = args: makeStratum (args // { offline = false; });
  makeOfflineStratum = args: makeStratum (args // { offline = true; });
  makePackage = args: {
    net = makeStratum (args // { offline = false; });
    offline = makeStratum (args // { offline = true; });
  };
}

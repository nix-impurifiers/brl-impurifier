# SPDX-License-Identifier: MIT
{
  pkgs,
  impurifier,
  coreSrc,
  bundled ? false,
}:
let
  installer = impurifier.installer;
  app = pkgs.writeShellScriptBin "brl-app" "echo bedrock-one" // {
    pname = "brl-app";
    version = "1";
  };
  app2 = pkgs.writeShellScriptBin "brl-app" "echo bedrock-two" // {
    pname = "brl-app";
    version = "2";
  };
  staticNix = import (coreSrc + "/tests/static-nix.nix") { inherit pkgs; };
  bundleArgs = pkgs.lib.optionalAttrs bundled {
    bundledNixStore = "${staticNix}/bin/nix-store";
    bundledNixNotices = [ "${pkgs.nix.src}/COPYING" ];
  };
  builder = impurifier // {
    makeNetStratum = args: impurifier.makeNetStratum (args // bundleArgs);
    makeOfflineStratum = args: impurifier.makeOfflineStratum (args // bundleArgs);
  };
  native =
    version:
    impurifier.makeNativeStratum {
      name = "native-proof";
      payload =
        pkgs.runCommand "native-brl-${version}" { nativeBuildInputs = [ pkgs.pkgsStatic.stdenv.cc ]; }
          ''
            mkdir -p $out/usr/bin $out/etc
            echo '#include <stdio.h>' > proof.c
            echo 'int main(void) { puts("native-brl-${version}"); return 0; }' >> proof.c
            $CC -static proof.c -o $out/usr/bin/native-proof
            printf 'NAME="Native proof"\nID=native-proof\n' > $out/etc/os-release
            printf 'root:x:0:0:root:/root:/bin/sh\n' > $out/etc/passwd
            printf 'root:x:0:\n' > $out/etc/group
          '';
    };
  net = builder.makeNetStratum { pkg = app; };
  offline = builder.makeOfflineStratum { pkg = app; };
  upgrade = builder.makeOfflineStratum { pkg = app2; };
  fixture = import (coreSrc + "/tests/hardware-fixture.nix") { inherit pkgs; };
  hardware = builder.makeOfflineStratum {
    pkg = fixture.tool;
    hardware = fixture.hardware // {
      libraries."libimpurifier-driver.so.1" = "/bedrock/strata/nixos/usr/lib/libimpurifier-driver.so.1";
    };
  };
in
{
  native-vm = pkgs.testers.runNixOSTest {
    name = "brl-native-contract${pkgs.lib.optionalString bundled "-bundled"}";
    globalTimeout = 900;
    requiredFeatures = {
      kvm = false;
      devnet = false;
    };
    nodes.machine = { lib, ... }: {
      imports = [
        ({ lib, ... }: {
          options.environment.etc = lib.mkOption {
            type = lib.types.attrsOf (
              lib.types.submodule (
                { lib, ... }: {
                  config.mode = lib.mkOverride 900 "direct-symlink";
                }
              )
            );
          };
        })
      ];
      virtualisation.qemu.package = lib.mkForce pkgs.qemu;
      virtualisation.qemu.forceAccel = false;
      virtualisation.memorySize = 2048;
      virtualisation.diskSize = 8192;
      virtualisation.writableStoreUseTmpfs = false;
      boot.kernelModules = [ "fuse" ];
      boot.initrd.kernelModules = [
        "fuse"
        "af_packet"
        "loop"
      ];
      networking.useDHCP = lib.mkForce false;
      networking.firewall.enable = false;
      environment.systemPackages = [
        pkgs.grub2
        pkgs.gnutar
        pkgs.gzip
        pkgs.attr
        pkgs.libcap
        pkgs.nix
        pkgs.python3
        impurifier.package
      ];
      users.users.consumer.isNormalUser = true;
      nix.settings.substituters = lib.mkForce [ ];
    };
    testScript = ''
      import os
      import shlex
      start_all()
      machine.wait_for_unit("multi-user.target", timeout=60)
      machine.succeed("cp -r ${hardware} /root/hardware; mkdir -p /root/drivers; cp ${fixture.driver "1"}/usr/lib/libimpurifier-driver.so.1 /root/drivers/1.so; cp ${fixture.driver "2"}/usr/lib/libimpurifier-driver.so.1 /root/drivers/2.so")
      machine.succeed("cp -r ${net} /root/net; cp -r ${offline} /root/offline; cp -r ${upgrade} /root/upgrade")
      machine.succeed("mkdir -p /sbin /bin; ln -sf ${pkgs.systemd}/bin/udevadm /bin/udevadm; printf '#!/bedrock/libexec/busybox sh\\nexec %s/init\\n' $(readlink -f /run/current-system) > /sbin/init; chmod 755 /sbin/init")
      machine.succeed("cp -L /etc/fstab /etc/fstab.real; rm /etc/fstab; mv /etc/fstab.real /etc/fstab")
      machine.succeed("printf 'Not reversible!\\n' | sh ${installer} --hijack nixos")
      machine.succeed("sed -i 's|^share = |share = /nix, |' /bedrock/etc/bedrock.conf; sed -i 's/^timeout =.*/timeout = 0/' /bedrock/etc/bedrock.conf; sed -i '/^bin = /s|$|, nixos:/run/current-system/sw/bin, /usr/bin, /bin|' /bedrock/etc/bedrock.conf")
      machine.succeed("cp /sbin/init /bedrock/libexec/native-init; printf '#!/bedrock/libexec/busybox sh\\n/bedrock/libexec/busybox mount --rbind /nix /nix\\n/bedrock/libexec/busybox ln -sfn %s /run/current-system\\nexec /bedrock/libexec/native-init\\n' $(readlink -f /run/current-system) > /sbin/init; chmod 755 /sbin/init")
      machine.shutdown()
      os.environ["QEMU_KERNEL_PARAMS"] = "init=/sbin/init console=ttyS0"
      machine.start()
      machine.wait_for_unit("multi-user.target", timeout=60)
      machine.succeed("/bedrock/bin/brl list; /bedrock/bin/strat nixos /run/current-system/sw/bin/true")
      machine.succeed("/bedrock/bin/brl import native-proof ${native "1"}/stratum.tar.gz")
      assert machine.succeed("/bedrock/bin/strat native-proof /usr/bin/native-proof").strip() == "native-brl-1"
      machine.succeed("mkdir -p /srv/native/usr/bin; cp /bedrock/strata/native-proof/usr/bin/native-proof /srv/native/usr/bin/native-proof")
      assert machine.succeed("chroot /srv/native /usr/bin/native-proof").strip() == "native-brl-1"
      machine.succeed("test ! -e /srv/native/nix; test ! -e /bedrock/strata/native-proof/usr/share/brl-impurifier")
      machine.succeed("/bedrock/bin/brl remove -d native-proof; /bedrock/bin/brl import native-proof ${native "2"}/stratum.tar.gz")
      assert machine.succeed("/bedrock/bin/strat native-proof /usr/bin/native-proof").strip() == "native-brl-2"
      machine.succeed("/bedrock/bin/brl remove -d native-proof; test ! -e /bedrock/strata/native-proof")
      machine.succeed("/bedrock/bin/brl import demo /root/net/stratum.tar.gz")
      machine.succeed("nix-store --gc; test ! -e ${builtins.unsafeDiscardStringContext (toString app)}")
      ${pkgs.lib.optionalString bundled ''
        machine.succeed("mkdir -p /home/consumer/no-nix; printf '#!${pkgs.runtimeShell}\\necho incompatible-client\\n' > /home/consumer/no-nix/nix-store; chmod 755 /home/consumer/no-nix/nix-store")
      ''}
      def user(command):
          return "su - consumer -c " + shlex.quote(("PATH=/home/consumer/no-nix:$PATH " if ${
            if bundled then "True" else "False"
          } else "") + command)
      ${pkgs.lib.optionalString bundled ''
        assert machine.succeed(user("nix-store --version")).strip() == "incompatible-client"
      ''}
      machine.fail(user("/bedrock/bin/strat demo /usr/bin/brl-app"))
      machine.succeed("/bedrock/bin/brl remove -d demo")
      machine.succeed("/bedrock/bin/brl import demo /root/offline/stratum.tar.gz")
      machine.fail(user("brl-impurifier prepare demo"))
      checksum = machine.succeed("find /bedrock/strata/demo/usr/share/brl-impurifier -type f -exec sha256sum {} + | sort")
      machine.succeed("brl-impurifier prepare --owner consumer demo; nix-store --gc")
      assert machine.succeed(user("/bedrock/bin/strat demo /usr/bin/brl-app")).strip() == "bedrock-one"
      assert machine.succeed(user("/bedrock/cross/bin/brl-app")).strip() == "bedrock-one"
      assert machine.succeed("find /bedrock/strata/demo/usr/share/brl-impurifier -type f -exec sha256sum {} + | sort") == checksum
      assert machine.succeed("systemctl show bedrock-fix-mounts.service --property=Result --value").strip() == "success"
      machine.shutdown()
      machine.start()
      machine.wait_for_unit("multi-user.target", timeout=60)
      machine.succeed("nix-store --gc")
      assert machine.succeed(user("/bedrock/cross/bin/brl-app")).strip() == "bedrock-one"
      machine.succeed("/bedrock/bin/brl disable demo; /bedrock/bin/brl copy demo retained")
      machine.fail(user("/bedrock/bin/strat demo /usr/bin/brl-app"))
      machine.succeed(user("brl-impurifier prune"))
      machine.succeed("nix-store --gc; test -e ${builtins.unsafeDiscardStringContext (toString app)}")
      machine.succeed("/bedrock/bin/brl enable demo")
      assert machine.succeed(user("/bedrock/bin/strat demo /usr/bin/brl-app")).strip() == "bedrock-one"
      machine.succeed("/bedrock/bin/brl disable demo; /bedrock/bin/brl rename demo previous; /bedrock/bin/brl enable previous")
      machine.succeed(user("brl-impurifier prune"))
      machine.succeed("nix-store --gc; test -e ${builtins.unsafeDiscardStringContext (toString app)}")
      assert machine.succeed(user("/bedrock/bin/strat previous /usr/bin/brl-app")).strip() == "bedrock-one"
      machine.succeed("/bedrock/bin/brl import demo /root/upgrade/stratum.tar.gz")
      machine.fail(user("/bedrock/bin/strat demo /usr/bin/brl-app"))
      machine.succeed("brl-impurifier prepare --owner consumer demo")
      assert machine.succeed(user("/bedrock/bin/strat demo /usr/bin/brl-app")).strip() == "bedrock-two"
      machine.succeed("/bedrock/bin/brl remove -d previous")
      machine.succeed(user("brl-impurifier prune"))
      machine.succeed("nix-store --gc; test -e ${builtins.unsafeDiscardStringContext (toString app)}")
      machine.succeed("/bedrock/bin/brl remove -d retained")
      machine.succeed(user("brl-impurifier prune"))
      machine.succeed("nix-store --gc; test ! -e ${builtins.unsafeDiscardStringContext (toString app)}; test -e ${builtins.unsafeDiscardStringContext (toString app2)}")
      machine.succeed("/bedrock/bin/brl remove -d demo")
      machine.succeed(user("brl-impurifier prune"))
      machine.succeed("nix-store --gc; test ! -e ${builtins.unsafeDiscardStringContext (toString app2)}")
      machine.succeed("/bedrock/bin/brl import hardware /root/hardware/stratum.tar.gz; brl-impurifier prepare --owner consumer hardware; mkdir -p /usr/lib; cp /root/drivers/1.so /usr/lib/libimpurifier-driver.so.1")
      assert machine.succeed(user("/bedrock/bin/strat hardware /usr/bin/hardware-tool")).strip() == "1"
      machine.succeed("cp /root/drivers/2.so /usr/lib/libimpurifier-driver.so.1")
      assert machine.succeed(user("/bedrock/cross/bin/hardware-tool")).strip() == "2"
      machine.succeed("/bedrock/bin/brl remove -d hardware")
      machine.succeed(user("brl-impurifier prune"))
      machine.succeed("nix-store --gc; test ! -e ${builtins.unsafeDiscardStringContext (toString fixture.tool)}")
    '';
  };
}

# brl impurifier

Native Bedrock Linux application strata backed by Nix.
Original adapter code uses MIT; Bedrock retains its GPL license.

`makeStratum { pkg; program ? pkg.meta.mainProgram or pkg.pname;
offline ? false; hardware ? null; }` emits `stratum.tar.gz` for native
`brl import NAME PATH`. `makeNetStratum` and `makeOfflineStratum` select the
transport; `makePackage` returns both. The output is a minimal application
stratum, rather than a complete distribution or an init provider.

Nix must already be installed. Configure `/nix` as a global shared directory
in Bedrock's `[global] share` list and apply the configuration through Bedrock.
The store and daemon socket must refer to the same host Nix installation in
all participating strata. When the init stratum stores executables outside
standard FHS directories, include its real command directory in Bedrock's
`[cross-bin] bin` list. The VM uses `nixos:/run/current-system/sw/bin` and
publishes that profile before native init configures crossfs. Native Nix provisioning is deferred installer work.

After import, `brl-impurifier prepare --owner USER STRATUM` explicitly imports
bundled closure data with the host's trusted Nix executable, then drops root
before registering the user's roots. No application code runs as root.
A restricted daemon rejects ordinary unsigned cache imports.

Commands run through native `strat NAME /usr/bin/PROGRAM` and crossfs exports.
Launchers derive their native stratum identity from the root's Bedrock xattr.
They maintain per-user Nix roots and, when requested, immutable host-library
snapshots. Specify hardware library paths through `/bedrock/strata/PROVIDER/...`
when the library belongs to a different stratum.

Run `brl-impurifier prune` as each participating user after native removal or
replacement. Disabled strata retain their closures. Renaming or copying a
stratum retains roots while the same payload remains installed in any stratum.
Application versions can coexist in separate native strata; use Bedrock's own
selection, visibility, enable/disable, rename and removal operations. Disable
strata before native rename/copy; `brl remove -d NAME` disables and removes an
enabled stratum. Crossfs command collisions follow Bedrock's configured
priority; select a particular version explicitly with `strat`.

The VM fixture invokes the real pinned Bedrock 0.7.31 installer inside a
throwaway NixOS VM, then reboots through Bedrock's native init, pivot, etcfs,
crossfs and stratum setup. Its fixture boot wrapper makes `/nix` a recursive
bind mount before native setup so that Bedrock's parent bind does not obscure
the VM's nested overlay store. The fixture also uses NixOS's supported `direct-symlink` mode for generated
`/etc` entries: indirect `/etc/static/...` links recurse through native etcfs.
Native Bedrock implementation files are unchanged.
`nix flake check -L` passes a three-boot native VM suite: real installation
and boot, native import, crossfs/strat launch, net failure and unsigned-cache
rejection, trusted offline preparation, unchanged payload checksums, retention
across reboot and GC, enable/disable, rename/copy, version coexistence,
host-library replacement, removal and pruning. The writable Nix store persists
on the VM disk so the reboot test exercises installed data and roots.

```nix
let adapter = import (brlImpurifier + "/nix") {
  inherit pkgs;
  coreSrc = impurifier;
}; in adapter.makeOfflineStratum { pkg = myApplication; }
```

```sh
sudo brl import example result/stratum.tar.gz
sudo brl-impurifier prepare --owner "$USER" example
strat example /usr/bin/my-application
```

Coverage is x86_64 Linux, application strata and explicit per-user preparation.
System services/accounts, `pmm` frontend operations, complete distribution
strata, other architectures and concurrent import/launch/prune are not claimed.
The NixOS boot bridge is a test fixture, rather than a general NixOS-to-Bedrock
migration installer. The fixture disables networking/firewall, preloads the
required modules and provides the real FHS udevadm expected by Bedrock's unit.

## Prepared native strata and bundled clients

`makeNativeStratum { name; payload; }` archives a complete producer-prepared
stratum tree. Supply target-compatible executables and the native stratum
metadata, such as `/etc/os-release`; the constructor adds no engine or Nix
activation. Import its `stratum.tar.gz` with native `brl import`. This does not
relocate binaries or install a whole distribution. The VM imports, executes,
removes and replaces native strata through real Bedrock, and executes an
installed static proof in an isolated root without `/nix`. The Bedrock host
remains the documented NixOS fixture with its shared store.

Nix-backed constructors accept a static ELF `bundledNixStore` and upstream
`bundledNixNotices` files. They carry a private client with a Python-only SDK.
Launch chooses a compatible external client first, then the bundle, before
registration or hardware capture; explicit `IMPURIFIER_NIX_STORE` disables
fallback. Trusted root preparation still uses host tools and never executes the
stratum-owned client. An existing store, daemon and initial SDK preparation
remain required. The bundled VM repeats the native stratum lifecycle with an
incompatible external candidate.

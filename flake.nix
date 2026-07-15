{
  description = "kyzrlabs local-llm NixOS hosts";

  inputs = {
    # Box reports 26.11pre-git and has no tagged nixos-26.11 branch — it tracks
    # the unstable/pre-release channel (the 26.05 nix-channel reg is stale).
    # stateVersion is a separate data-compat marker and must NOT follow this.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # microvm.nix: builds NixOS microVMs as declarative systemd services.
    # Backend: cloud-hypervisor (Rust/virtio, <100ms boot). Used for Slicer.
    microvm.url = "github:microvm-nix/microvm.nix";
  };

  outputs = { self, nixpkgs, microvm, ... }:
    let
      mkHost = { hostName, system ? "x86_64-linux", extraModules ? [ ] }:
        nixpkgs.lib.nixosSystem {
          inherit system;
          specialArgs = { inherit hostName; };
          modules = [
            # hostName lived commented-out in the imperative config; set it here.
            { networking.hostName = hostName; }
            ./hosts/${hostName}/configuration.nix
            ./hosts/${hostName}/hardware-configuration.nix
            ./hosts/${hostName}/strix-halo-single.nix
            # microvm.nix host module: enables KVM, sysctl, and VM service management.
            # Required for microvm.vms.<name> options to be defined.
            microvm.nixosModules.host
          ] ++ extraModules;
        };
    in
    {
      nixosConfigurations.kyzrknecht = mkHost {
        hostName = "kyzrknecht";
        extraModules = [
          # Slicer: minimal microvm.nix guest (Stage 1 — boot + workspace mount only).
          # Egress filtering, DNS audit, secrets, and agent/Node/Pi come in later stages.
          ./hosts/kyzrknecht/slicer.nix
        ];
      };
    };
}

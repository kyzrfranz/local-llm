{
  description = "kyzrlabs local-llm NixOS hosts";

  inputs = {
    # Box reports 26.11pre-git and has no tagged nixos-26.11 branch — it tracks
    # the unstable/pre-release channel (the 26.05 nix-channel reg is stale).
    # stateVersion is a separate data-compat marker and must NOT follow this.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs, ... }:
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
          ] ++ extraModules;
        };
    in
    {
      nixosConfigurations.kyzrknecht = mkHost { hostName = "kyzrknecht"; };
    };
}

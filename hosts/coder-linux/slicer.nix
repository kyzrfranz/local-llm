{ config, lib, pkgs, ... }:
{
  microvm.vms.slicer = {
    config = { pkgs, ... }: {
      networking.hostName = "slicer";
      # Key-only root login over VSOCK-SSH (vsock-ssh.nix auto-listens on vsock::22
      # via systemd's ssh-generator; no extra sshd config needed for VSOCK transport).
      services.openssh.settings = {
        PermitRootLogin = "prohibit-password";  # keys only for root
        PasswordAuthentication = false;          # no password auth anywhere
      };
      # Authorize host root's SSH key via relative path (pure eval compatible).
      # The .pub file is committed to the repo — public keys are not secrets.
      users.users.root.openssh.authorizedKeys.keyFiles = [
        ./slicer-access.pub
      ];
      services.getty.helpLine = "slicer boot test — root, key auth configured.";

      microvm = {
        hypervisor = "cloud-hypervisor";
        vcpu = 2;
        mem = 512;
        shares = [
          { tag = "ro-store"; source = "/nix/store"; mountPoint = "/nix/.ro-store"; proto = "virtiofs"; }
        ];
        # VSOCK: enables `microvm -s slicer` without giving the guest a network
        # interface. cid=3 (0=hypervisor, 1=loopback, 2=host are reserved).
        vsock = {
          cid = 3;
          ssh.enable = true;  # auto-enables services.openssh in the guest
        };
      };

      system.stateVersion = "26.05";
    };
  };
}
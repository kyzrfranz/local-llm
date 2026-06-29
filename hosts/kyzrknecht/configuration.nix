{ config, lib, pkgs, ... }:

{
  imports = [ ./hardware-configuration.nix ];

  # Bootloader: systemd-boot on the EFI System Partition (confirmed live).
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # NOTE: GPU/GTT tuning (boot.kernelParams ttm.*, hardware.graphics) is owned
  # entirely by strix-halo.nix. The deprecated amdgpu.gttsize is intentionally
  # dropped. Do NOT define boot.kernelParams or hardware.graphics here.

  # console.keyMap and the pciutils/usbutils/kbd recovery tooling are owned by
  # strix-halo.nix (section 5). Keep only general base tools here to avoid
  # defining the same options in two modules.
  environment.systemPackages = with pkgs; [
    vim
    git
    wget
    curl
    jq
    tmux
  ];

  # hostName is set by the flake's mkHost helper (= "kyzrknecht").
  # Box is wired-only (eno1); the imperative WiFi profile with its plaintext
  # PSK has been dropped intentionally.
  networking.networkmanager.enable = true;

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # Preserve current remote access exactly: password + root login over SSH.
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = true;
      PermitRootLogin = "yes";
    };
  };

  virtualisation.docker.enable = true;

  # Data-compat marker — the real install version. NOT the nixpkgs channel.
  system.stateVersion = "26.05";
}

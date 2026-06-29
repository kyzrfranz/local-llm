# bootstrap strix halo

### corsair ai workstation 300

```shell
mkdir -p /tmp/local-llm/iso
wget https://channels.nixos.org/nixos-26.05/latest-nixos-minimal-x86_64-linux.iso -O /tmp/local-llm/iso/latest-nixos-minimal-x86_64-linux.iso
```

#### Mac

```shell
diskutil list
# (find your USB drive, for example /dev/disk4)

diskutil unmountDisk /dev/disk4
sudo dd if=/tmp/local-llm/iso/latest-nixos-minimal-x86_64-linux.iso of=/dev/rdisk4 bs=1m
diskutil eject /dev/disk4
```

#### Linux

```shell
lsblk
# (find your USB drive, for example /dev/sdX)

sudo dd if=/tmp/local-llm/iso/latest-nixos-minimal-x86_64-linux.iso of=/dev/sdX bs=4M status=progress conv=fsync
```

# Bootstrap Strix Halo (Playground)

## 1. Connect to WiFi
sudo nmcli --ask device wifi connect "SSID"

## 2. Partitioning (fdisk /dev/nvme0n1)
```
g (GPT label)
n -> 1 -> [Enter] -> +500M
t -> 1 -> 1 (EFI System)
n -> 2 -> [Enter] -> [Enter]
w (Write)
```

## 3. Format & Mount
```shell
sudo mkfs.fat -F 32 -n NIXBOOT /dev/nvme0n1p1
sudo mkfs.ext4 -L NIXROOT /dev/nvme0n1p2
```

```shell
sudo mount /dev/disk/by-label/NIXROOT /mnt
sudo mkdir -p /mnt/boot
sudo mount /dev/disk/by-label/NIXBOOT /mnt/boot
```

## 4. Configure & Install
Generate base config
```shell
sudo nixos-generate-config --root /mnt
```

Edit config to ensure bootloader and user are set
File:`/mnt/etc/nixos/configuration.nix`

```shell
boot.loader.systemd-boot.enable = true;
boot.loader.efi.canTouchEfiVariables = true;
users.users.yourname = { isNormalUser = true; extraGroups = [ "wheel" ]; };
```

# Install
```shell
sudo nixos-install
```

# Set root password
```shell
sudo nixos-enter --command 'passwd'
exit
reboot
```

# Model provisioning (BEFORE the first switch that enables llama-swap)

The `llama-swap` service runs with `HF_HUB_OFFLINE=1` and loads models from
`/var/lib/llama/hf/hub`. It **never downloads**. Models must be provisioned by
hand first; a missing/corrupt file will **not** auto-heal — the service fails or
serves garbage.

- [ ] Start a **tmux** session (a dropped SSH mid-pull is how a corrupt 78 GB
      download happened): `tmux new -s fetch-models`
- [ ] Confirm the architect filename TODO in `scripts/fetch-models.sh`
      (`ARCHITECT_FILE`) against the HF repo file list — do not guess; note if it
      is **sharded** (then pull all shards, not one file).
- [ ] Run the provisioning script as root, inside tmux:
      `sudo hosts/kyzrknecht/scripts/fetch-models.sh`
      (downloads as user `llama`, `HF_HUB_OFFLINE` unset, size-asserts each blob)
- [ ] Verify the three blobs landed with sane sizes:
      `sudo du -shL /var/lib/llama/hf/hub/models--*/snapshots/*/*.gguf`
      expect ~47 GB (coder), ~43 GB (architect), ~23 GB (mtp)
- [ ] Confirm ownership is `llama:llama`: `sudo ls -ld /var/lib/llama/hf/hub`
- [ ] Only now run the switch that enables `llama-swap`.

Notes:
- The RADV shader cache lives at `/var/lib/llama/.cache` — created on the first
  GPU run, owned by `llama`. Don't pre-create or chown it to root.
- `HF_HUB_OFFLINE=1` is a **service-only** setting; the fetch script unsets it so
  it can actually download. Re-running the script is safe (idempotent: it skips
  correct files, resumes partials, re-fetches size mismatches).
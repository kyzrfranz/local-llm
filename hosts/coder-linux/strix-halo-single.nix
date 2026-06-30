# strix-halo-single.nix — Node B (Corsair AI Workstation 300 / Ryzen AI Max+ 395, gfx1151)
#
# SINGLE-model replacement for the two-model strix-halo.nix. The agentic eval
# PASSED: Qwen3.6-35B-A3B (~21 GiB) serves BOTH roles from one resident model,
# proven live — retiring the Coder-Next + Next-Thinking pair (~89 GiB weights,
# ~2 min llama-swap reloads between turns). No swap, one always-warm server.
#
# Role is chosen by the CALLER, per request, via chat-template kwargs:
#     architect -> chat_template_kwargs {"enable_thinking": true}   (plans, thinks)
#     coder     -> chat_template_kwargs {"enable_thinking": false}  (direct output)
# Confirmed working on this build. Thinking is therefore NOT configured
# server-side — one endpoint, both behaviours. --jinja is what makes that toggle
# work (see below); do not drop it.
#
# This module STAGES ALONGSIDE strix-halo.nix as a fallback. The flake imports
# exactly ONE of the two — never both (they would collide on the GPU and on
# port 8080). Switch the import here when ready, validate it serves + toggles,
# then retire strix-halo.nix.
#
# Import:  imports = [ ./hardware-configuration.nix ./strix-halo-single.nix ];

{ config, lib, pkgs, ... }:

let
  # MTP is embedded in this GGUF, but we do NOT enable speculative decoding —
  # see the NO-MTP note on ExecStart. Exact pin (repo:quant), never a bare default.
  model    = "unsloth/Qwen3.6-35B-A3B-MTP-GGUF:UD-Q4_K_XL";

  modelDir = "/var/lib/llama";   # persistent — NOT /tmp
  svcUser  = "llama";
  port     = 8080;               # same port as the old llama-swap — downstream callers unchanged

  llamaServer = lib.getExe' pkgs.llama-cpp-vulkan "llama-server";
in
{
  ##########################################################################
  # 1. Unified-memory / GTT ceiling (lets the iGPU reach ~115 GiB)
  ##########################################################################
  # OWNED HERE because this module replaces strix-halo.nix (only one is imported
  # at a time). Mirrors strix-halo.nix verbatim — keep them identical.
  boot.kernelParams = [
    "ttm.pages_limit=30146560"      # ~115 GiB GTT
    "ttm.page_pool_size=30146560"
  ];
  # Needs >= 6.16.9 for the gfx1151 fixes. `latest` works but floats — once you
  # capture a known-good `uname -r`, consider pinning (e.g. linuxPackages_6_16)
  # so a future bump can't silently regress hardware.
  boot.kernelPackages = lib.mkDefault pkgs.linuxPackages_latest;

  ##########################################################################
  # 2. RADV Vulkan driver (the headless gap that caused CPU fallback)
  ##########################################################################
  hardware.graphics.enable = true;

  ##########################################################################
  # 3. Service user + persistent model storage
  ##########################################################################
  users.users.${svcUser} = {
    isSystemUser = true;
    group = svcUser;
    extraGroups = [ "video" "render" ];   # /dev/dri/renderD128 access
    home = modelDir;
  };
  users.groups.${svcUser} = { };

  systemd.tmpfiles.rules = [
    "d ${modelDir}    0750 ${svcUser} ${svcUser} -"
    "d ${modelDir}/hf 0750 ${svcUser} ${svcUser} -"   # HuggingFace hub cache (the model lands here)
  ];

  ##########################################################################
  # 4. The single llama-server serving unit (both roles, one endpoint)
  ##########################################################################
  systemd.services.llama-serve = {
    description = "llama-server (Vulkan) — Node B single-model: Qwen3.6-35B-A3B (dual-role)";
    wantedBy = [ "multi-user.target" ];
    after    = [ "network-online.target" ];
    wants    = [ "network-online.target" ];

    # After 3 failures in 5 min, stop and sit `failed` — a visible alert, not a loop.
    startLimitBurst = 3;
    startLimitIntervalSec = 300;

    # Reused verbatim from strix-halo.nix (validated). HF_HOME alone resolves to
    # hf/hub/ — do NOT add LLAMA_CACHE, it caused a path-collision download loop.
    environment = {
      MESA_VK_DEVICE_SELECT = "1002:1586";
      HF_HOME = "${modelDir}/hf";
      HF_HUB_OFFLINE = "1";        # trust the local cache, never hit the network
    };

    serviceConfig = {
      User  = svcUser;
      Group = svcUser;

      # Stage 1 (reused verbatim): refuse to start if the RADV GPU isn't visible.
      ExecStartPre = pkgs.writeShellScript "verify-radv-gpu" ''
        if ! ${pkgs.vulkan-tools}/bin/vulkaninfo --summary 2>/dev/null \
             | ${pkgs.gnugrep}/bin/grep -q "RADV STRIX_HALO"; then
          echo "FATAL: RADV STRIX_HALO not visible to Vulkan — refusing to start." >&2
          exit 1
        fi
      '';

      # ONE server, both roles. Notes:
      #   --jinja      REQUIRED — applies the model's chat template, which is what
      #                makes the per-request {enable_thinking} toggle work. Keep it.
      #   NO MTP       --spec-type/--spec-draft-* are intentionally absent: MTP is
      #                mutually exclusive with --parallel > 1, and concurrency for
      #                the coder swarm wins for the multi-agent target.
      #   --ctx-size   65536 is a starting value — tune later.
      #   --parallel 4 peak concurrent coder workers.
      ExecStart = ''
        ${llamaServer} \
          -hf ${model} \
          --host 127.0.0.1 --port ${toString port} \
          -ngl 99 -fa on \
          --ctx-size 65536 --parallel 4 \
          --jinja --metrics --no-webui
      '';

      # Stage 2 (root via "+", reads this invocation's journal): the single
      # always-loaded llama-serve prints its device table — or the CPU-fallback
      # warning — at backend init, so we catch a fallback within seconds. More
      # useful here than under llama-swap: there's no preload indirection, the
      # serving model itself is what we're verifying.
      ExecStartPost = "+${pkgs.writeShellScript "verify-gpu-offload" ''
        for ((i=0; i<30; i++)); do
          log="$(${pkgs.systemd}/bin/journalctl _SYSTEMD_INVOCATION_ID="$INVOCATION_ID" --no-pager 2>/dev/null || true)"
          if printf '%s\n' "$log" | ${pkgs.gnugrep}/bin/grep -qE "no usable GPU found|compiled without GPU support"; then
            echo "FATAL: llama-serve fell back to CPU — halting per the driver-fallback rule." >&2
            exit 1
          fi
          if printf '%s\n' "$log" | ${pkgs.gnugrep}/bin/grep -q "Vulkan0"; then
            exit 0
          fi
          ${pkgs.coreutils}/bin/sleep 1
        done
        exit 0
      ''}";

      TimeoutStartSec = "infinity";   # model load is slow
      Restart = "on-failure";
      RestartSec = 5;

      # Hardening + GPU device access (reused verbatim — all tested serving-safe).
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ReadWritePaths = [ modelDir ];
      PrivateTmp = true;
      DevicePolicy = "closed";
      DeviceAllow = [ "/dev/dri/renderD128 rw" "/dev/dri/card0 rw" ];
    };
  };

  ##########################################################################
  # 5. Recovery tooling + console (owned here too — see GPU/GTT note)
  ##########################################################################
  # Same rationale as strix-halo.nix section 5: keep diagnostics on-disk and the
  # DE keymap. Owned here because only one of the two modules is ever imported.
  environment.systemPackages = with pkgs; [ pciutils usbutils kbd ];
  console.keyMap = "de";

  ##########################################################################
  # 6. Network exposure
  ##########################################################################
  # Local-only by default. For LiteLLM on Node A, change --host to 0.0.0.0 (or the
  # LAN IP) and open the port to your subnet:
  #
  # networking.firewall.extraInputRules = ''
  #   ip saddr 192.168.1.0/24 tcp dport ${toString port} accept
  # '';
  #
  # One model name is exposed; callers pick the role via enable_thinking.
}

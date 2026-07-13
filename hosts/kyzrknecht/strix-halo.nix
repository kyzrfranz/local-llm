# strix-halo.nix — Node B (Corsair AI Workstation 300 / Ryzen AI Max+ 395, gfx1151)
#
# Single-box deployment (Mac Studio / Node C comes later). Runs the confirmed
# Qwen3-Next pair behind one OpenAI-compatible endpoint via llama-swap:
#
#     coder      = Qwen3-Coder-Next  (80B-A3B, ~46 GiB)  -> execution
#     architect  = Qwen3-Next-Thinking (80B-A3B, ~43 GiB) -> planning
#
# Both are the SAME 80B-A3B "Next" architecture, so they share tuning and swap
# cleanly. At ~43-46 GiB each they don't co-reside comfortably (89 GiB weights +
# KV crowds the ~115 GiB GTT ceiling), so llama-swap keeps ONE resident at a
# time — which is exactly the turn-by-turn tri-agent loop (plan, then execute).
# Each model gets the full pool when active.
#
# Benchmarked on this box (build b9608): coder 51.7 t/s decode / 849 prefill;
# architect 58.7 t/s decode (flat over long CoT) / 712 prefill. Neither wedged
# the GPU. (gpt-oss-120b was rejected: lost the P1/P2 quality eval on fatal
# protobuf/Kotlin errors AND hard-wedged the GPU under concurrency — see the
# benchmark suite .md.)
#
# Provides:
#   - unified-memory (GTT) tuning so the iGPU can address large models
#   - RADV Vulkan userspace driver (headless boxes don't get it by default)
#   - llama-swap on :8080 fronting both models behind one API
#   - two-stage guard: refuse to start if RADV is missing, AND fail the unit if
#     the preloaded coder falls back to CPU
#   - recovery tooling on-disk (pciutils/kbd) so a downed network doesn't strip
#     your diagnostics, plus the DE console keymap
#
# Import:  imports = [ ./hardware-configuration.nix ./strix-halo.nix ];

{ config, lib, pkgs, ... }:

let
  # --- model catalog (both verified working on this box) -----------------
  # Coder-Next ships a single (non-sharded) GGUF -> use --hf-repo + --hf-file.
  coderRepo = "unsloth/Qwen3-Coder-Next-GGUF";
  coderFile = "Qwen3-Coder-Next-UD-Q4_K_XL.gguf";
  # Architect resolves via the repo:quant shorthand.
  architectRepo = "unsloth/Qwen3-Next-80B-A3B-Thinking-GGUF:Q4_K_XL";

  modelDir = "/var/lib/llama";   # persistent — NOT /tmp
  svcUser  = "llama";
  port     = 8080;

  llamaServer = lib.getExe' pkgs.llama-cpp-vulkan "llama-server";
  llamaSwap   = lib.getExe pkgs.llama-swap;

  # Sampling differs per model — do NOT share settings:
  #   coder (instruct):  temp 0.7 / top-p 0.8 / top-k 20 / repeat-penalty 1.05
  #   architect (think): temp 0.6 / top-p 0.95 / top-k 20 / min-p 0 / presence 1.0
  # -fa 1 (flash attention) verified on this build; shrinks KV. KV left at f16
  # on purpose — quantized KV on the hybrid "Next" attention is unproven, and
  # with ~74 GiB free there's no need to risk it.
  #
  # ''${PORT} is a llama-swap runtime placeholder (kept literal); everything
  # else is Nix-interpolated at build time.
  swapConfig = pkgs.writeText "llama-swap.yaml" ''
    logLevel: info
    logToStdout: both        # forward child llama-server logs -> journal (the GPU guard reads them)
    healthCheckTimeout: 1800 # seconds; covers a ~46 GB first-time download/load. VERIFY key vs llama-swap schema.

    models:
      "coder":
        cmd: "${llamaServer} --port ''${PORT} --hf-repo ${coderRepo} --hf-file ${coderFile} --alias coder --n-gpu-layers 99 -fa 1 --ctx-size 131072 --parallel 4 --cache-reuse 256 --temp 0.7 --top-p 0.8 --top-k 20 --repeat-penalty 1.05 --jinja --metrics --no-webui"

      "architect":
        cmd: "${llamaServer} --port ''${PORT} -hf ${architectRepo} --alias architect --n-gpu-layers 99 -fa 1 --ctx-size 131072 --parallel 1 --cache-reuse 256 --temp 0.6 --top-p 0.95 --top-k 20 --min-p 0.0 --presence-penalty 1.0 --jinja --metrics --no-webui"

    # Preload the coder so it's warm at boot AND so the startup GPU guard has a
    # running llama-server to inspect. The architect loads on first request
    # (swapping the coder out), then swaps back — the turn-by-turn loop.
    hooks:
      on_startup:
        preload:
          - coder
  '';
in
{
  ##########################################################################
  # 1. Unified-memory / GTT ceiling (lets the iGPU reach ~115 GiB)
  ##########################################################################
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
    "d ${modelDir}/hf 0750 ${svcUser} ${svcUser} -"   # HuggingFace hub cache (both models land here)
  ];

  ##########################################################################
  # 4. The llama-swap serving unit (hand-rolled to keep the GPU guard)
  ##########################################################################
  systemd.services.llama-swap = {
    description = "llama-swap (Vulkan) — Node B: Qwen3-Coder-Next + Qwen3-Next-Thinking";
    wantedBy = [ "multi-user.target" ];
    after    = [ "network-online.target" ];
    wants    = [ "network-online.target" ];

    # After 3 failures in 5 min, stop and sit `failed` — a visible alert, not a loop.
    startLimitBurst = 3;
    startLimitIntervalSec = 300;

    environment = {
      MESA_VK_DEVICE_SELECT = "1002:1586";
      HF_HOME = "${modelDir}/hf";
      HF_HUB_OFFLINE = "1";        # trust the local cache, never hit the network
    };

    serviceConfig = {
      User  = svcUser;
      Group = svcUser;

      # Stage 1: refuse to start if the RADV GPU isn't visible at all.
      ExecStartPre = pkgs.writeShellScript "verify-radv-gpu" ''
        if ! ${pkgs.vulkan-tools}/bin/vulkaninfo --summary 2>/dev/null \
             | ${pkgs.gnugrep}/bin/grep -q "RADV STRIX_HALO"; then
          echo "FATAL: RADV STRIX_HALO not visible to Vulkan — refusing to start." >&2
          exit 1
        fi
      '';

      # VERIFY: llama-swap CLI is Go-flag style; --config / --listen should work
      # (single-dash -config/-listen are equivalent). Check `llama-swap --help`.
      ExecStart = "${llamaSwap} --config ${swapConfig} --listen 127.0.0.1:${toString port}";

      # Stage 2 (root via "+", reads this invocation's journal): the preloaded
      # coder prints its device table — or the CPU-fallback warning — at backend
      # init, so we can catch a fallback within seconds. (logToStdout: both makes
      # the child logs visible here.)
      ExecStartPost = "+${pkgs.writeShellScript "verify-gpu-offload" ''
        for ((i=0; i<30; i++)); do
          log="$(${pkgs.systemd}/bin/journalctl _SYSTEMD_INVOCATION_ID="$INVOCATION_ID" --no-pager 2>/dev/null || true)"
          if printf '%s\n' "$log" | ${pkgs.gnugrep}/bin/grep -qE "no usable GPU found|compiled without GPU support"; then
            echo "FATAL: preloaded model fell back to CPU — halting per the driver-fallback rule." >&2
            exit 1
          fi
          if printf '%s\n' "$log" | ${pkgs.gnugrep}/bin/grep -q "Vulkan0"; then
            exit 0
          fi
          ${pkgs.coreutils}/bin/sleep 1
        done
        exit 0
      ''}";

      TimeoutStartSec = "infinity";   # first-run downloads ~46 GB (coder), then ~43 GB (architect, on demand)
      Restart = "on-failure";
      RestartSec = 5;

      # Hardening + GPU device access (children inherit the cgroup)
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
  # 5. Recovery tooling + console (lessons from the GPU-wedge sessions)
  ##########################################################################
  # Keep diagnostics ON-DISK so a downed WiFi link doesn't also strip the tools
  # you need to diagnose it (the `nix shell` catch-22). German console layout.
  environment.systemPackages = with pkgs; [ pciutils usbutils kbd ];
  console.keyMap = "de";
  # A headless inference node should not depend on WiFi that a GPU wedge can
  # knock out — prefer wired ethernet for this box.

  ##########################################################################
  # 6. Network exposure
  ##########################################################################
  # Local-only by default. For LiteLLM on Node A, change --listen to
  # 0.0.0.0:${toString port} (or the LAN IP) and open the port to your subnet:
  #
  # networking.firewall.extraInputRules = ''
  #   ip saddr 192.168.1.0/24 tcp dport ${toString port} accept
  # '';
  #
  # LiteLLM then routes by model name: "coder" and "architect".

  ##########################################################################
  # PRE-SEED (optional): skip the ~90 GB of first-run downloads. If you've
  # already pulled either model as root, copy the HF cache to the service path:
  #   sudo mkdir -p ${modelDir}/hf
  #   sudo cp -a /root/.cache/huggingface/. ${modelDir}/hf/
  #   sudo chown -R ${svcUser}:${svcUser} ${modelDir}
  ##########################################################################
}

#!/usr/bin/env bash
#
# fetch-models.sh — provision the GGUF models into the llama-swap service cache.
#
# WHY THIS EXISTS
#   The llama-swap service (strix-halo.nix) runs with HF_HUB_OFFLINE=1 and loads
#   models from /var/lib/llama/hf/hub. It NEVER downloads anything. So on a fresh
#   / bare-metal install the models must be provisioned HERE, by hand, BEFORE the
#   first `nixos-rebuild switch` that starts llama-swap. A missing or corrupt file
#   will NOT auto-heal at runtime — the service just fails (or worse, serves
#   garbage). This script is that manual pre-install step.
#
# !! RUN INSIDE tmux !!
#   A dropped SSH connection mid-pull is exactly how a corrupt 78 GB download
#   happened before (it loaded fine but emitted garbage). tmux survives the
#   disconnect:
#       tmux new -s fetch-models
#       sudo hosts/kyzrknecht/scripts/fetch-models.sh
#
# This is a MANUAL step. It is intentionally NOT wired into the flake build or any
# systemd unit — do not run it at activation.
#
# Run as root (uses `sudo -u llama` for the downloads so files land owned by the
# service user; chowns /var/lib/llama at the end).
#
set -euo pipefail

# --- config ----------------------------------------------------------------
HF_HOME=/var/lib/llama/hf          # models land in $HF_HOME/hub/models--<org>--<repo>/...
LLAMA_USER=llama
SIZE_TOL=0.20                      # ±20%: catches the 78 GB-vs-47 GB corruption, absorbs GiB/GB + variance

# Exact pins — NEVER use a bare `-hf repo` that auto-picks a default quant; that
# ambiguity is what produced the corrupt download. repo | file | expected GB.
#
# NOTE: the 3rd model (Qwen3.6-35B-A3B-MTP) is for the EXPERIMENTAL single-model
# variant (strix-halo-single.nix), not the current two-model service. Provisioned
# here so a fresh box can switch to either layout without a second download pass.
CODER_REPO="unsloth/Qwen3-Coder-Next-GGUF"
CODER_FILE="Qwen3-Coder-Next-UD-Q4_K_XL.gguf"
CODER_GB=47

# TODO(CONFIRM): the exact filename/quant string for the Thinking model is NOT
# verified. The service references it via the `:Q4_K_XL` shorthand (auto-resolved),
# but this script must pin an exact file. Confirm the real name from the repo file
# list before running — DO NOT guess:
#     nix shell nixpkgs#huggingface-hub -c \
#       huggingface-cli download "$ARCHITECT_REPO" --quiet >/dev/null  # then browse the cache, OR
#     open https://huggingface.co/unsloth/Qwen3-Next-80B-A3B-Thinking-GGUF/tree/main
# Likely (UD = Unsloth Dynamic), one of:
#     Qwen3-Next-80B-A3B-Thinking-UD-Q4_K_XL.gguf                              (single file)
#     UD-Q4_K_XL/Qwen3-Next-80B-A3B-Thinking-UD-Q4_K_XL-00001-of-0000N.gguf    (sharded)
# If it is SHARDED (like GLM-4.5-Air was), a single-file fetch is WRONG — you must
# pull every shard (huggingface-cli download ... --include 'UD-Q4_K_XL/*') and the
# size check must sum the shards. Resolve this before relying on the architect.
ARCHITECT_REPO="unsloth/Qwen3-Next-80B-A3B-Thinking-GGUF"
ARCHITECT_FILE="__CONFIRM_ME__"
ARCHITECT_GB=43

MTP_REPO="unsloth/Qwen3.6-35B-A3B-MTP-GGUF"
MTP_FILE="Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf"
MTP_GB=23

# --- helpers ---------------------------------------------------------------
[[ $EUID -eq 0 ]] || { echo "FATAL: run as root (uses sudo -u $LLAMA_USER + chowns /var/lib/llama)." >&2; exit 1; }

# Download one exact file as the service user, offline mode OFF, with the
# ACCELERATED transfer backends wired in — plain `nix shell nixpkgs#huggingface-hub`
# ships NEITHER, so its default single-stream Python download is slow:
#   - hf-xet     : parallel Xet chunk transfer. unsloth repos are Xet-backed, so
#                  this is the one that actually matters here.
#   - hf-transfer: parallel multipart for any non-Xet (LFS) blobs.
#                  Needs HF_HUB_ENABLE_HF_TRANSFER=1 (set below).
# Both must be importable by the SAME python that runs huggingface-cli, so we
# build one env with withPackages rather than adding them as sibling nix pkgs
# (whose site-packages wouldn't be on the CLI wrapper's PYTHONPATH).
# Still idempotent online (skip complete / resume partial / re-fetch mismatch)
# and still prints the resolved local path on stdout (last line).
hf_get() {
  local repo="$1" file="$2"
  sudo -u "$LLAMA_USER" env -u HF_HUB_OFFLINE HF_HOME="$HF_HOME" HF_HUB_ENABLE_HF_TRANSFER=1 \
    nix shell --impure --expr \
      'with builtins.getFlake "nixpkgs"; legacyPackages.${builtins.currentSystem}.python3.withPackages (p: [ p.huggingface-hub p.hf-transfer p.hf-xet ])' \
      -c huggingface-cli download "$repo" "$file" | tail -n1
}

# Assert the on-disk blob is within ±SIZE_TOL of expected — the corrupt/oversized
# download guard. FAILS LOUDLY (a truncated or 78 GB file loads but emits garbage).
assert_size() {
  local name="$1" path="$2" expect_gb="$3" bytes gib min max
  [[ -e "$path" ]] || { echo "FATAL: $name — expected file not found at: $path" >&2; exit 1; }
  bytes=$(stat -L -c %s "$path")
  gib=$(awk "BEGIN{printf \"%.1f\", $bytes/1073741824}")
  min=$(awk "BEGIN{printf \"%d\", $expect_gb*1000000000*(1-$SIZE_TOL)}")
  max=$(awk "BEGIN{printf \"%d\", $expect_gb*1000000000*(1+$SIZE_TOL)}")
  if (( bytes < min || bytes > max )); then
    echo "FATAL: $name is ${gib} GiB ($bytes bytes) — expected ~${expect_gb} GB ±$(awk "BEGIN{printf \"%d\", $SIZE_TOL*100}")%." >&2
    echo "       Path: $path" >&2
    echo "       An interrupted/oversized pull yields a file that LOADS but emits garbage." >&2
    echo "       Delete the blob and re-run (inside tmux):" >&2
    echo "         rm -f \"\$(readlink -f '$path')\" '$path'" >&2
    exit 1
  fi
  echo "OK: $name = ${gib} GiB ($(du -shL "$path" | cut -f1)), within ±$(awk "BEGIN{printf \"%d\", $SIZE_TOL*100}")% of ~${expect_gb} GB"
}

fetch() {
  local name="$1" repo="$2" file="$3" expect_gb="$4" path
  echo "==> $name  ($repo : $file)"
  if [[ "$file" == "__CONFIRM_ME__" ]]; then
    echo "FATAL: $name filename is an unconfirmed placeholder. See the TODO(CONFIRM)" >&2
    echo "       block at the top of this script; set ARCHITECT_FILE, then re-run." >&2
    exit 1
  fi
  path=$(hf_get "$repo" "$file")
  assert_size "$name" "$path" "$expect_gb"
}

# --- run -------------------------------------------------------------------
echo "HF_HOME=$HF_HOME  (cache layout: \$HF_HOME/hub/models--<org>--<repo>/snapshots/<rev>/<file>)"
echo "Downloading as user '$LLAMA_USER', HF_HUB_OFFLINE unset. Idempotent — re-run is safe."
echo

fetch "coder"     "$CODER_REPO"     "$CODER_FILE"     "$CODER_GB"
fetch "architect" "$ARCHITECT_REPO" "$ARCHITECT_FILE" "$ARCHITECT_GB"
fetch "mtp"       "$MTP_REPO"       "$MTP_FILE"       "$MTP_GB"

echo
echo "==> chown -R $LLAMA_USER:$LLAMA_USER /var/lib/llama"
chown -R "$LLAMA_USER:$LLAMA_USER" /var/lib/llama

echo
echo "All models provisioned and size-verified under $HF_HOME/hub."
echo "Safe to nixos-rebuild switch (llama-swap will load them offline)."

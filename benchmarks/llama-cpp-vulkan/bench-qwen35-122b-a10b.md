# Benchmark spec — Qwen3.5-122B-A10B (architect candidate)

Drop-in addition to `node-b-benchmark-suite.md`. Same box, same methodology,
same P1–P3 prompts/rubric, so results land in the existing comparison tables.

**The question this run answers:** does 10B-active reasoning produce *materially
better architecture blueprints* than the current architect bar (Qwen3-Next-80B-A3B-
Thinking, 3/3 clean) and the 35B-A3B (2/3), by enough to justify ~18–20 t/s decode
and ~70 GB resident — i.e. enough to revert Node B to a two-model (fast-coder +
deep-architect) split? Speed is *not* the deciding factor for an architect; the
load-bearing-detail correctness is. Same discipline as every prior row.

**Predicted before running (from the box's ~256 GB/s + active-param law):**
- Decode ≈ 35B-A3B's 59.7 t/s × (3B/10B) ≈ **~18–20 t/s** single-stream (a bit
  lower for the larger total-weight memory footprint). "Deep-think architect,"
  not interactive. This prediction is itself a test — if decode comes in wildly
  off ~18–20, something's wrong (CPU fallback, bad quant).
- Fits: UD-Q4_K_XL ≈ **~70 GB** vs ~115 GB usable GTT → ~40 GB left for KV. OK.
- Same Qwen family/architecture as the 35B-A3B → `enable_thinking` toggle +
  `reasoning_content` handling carry over, no new integration surprises.

**Model pin (confirm exact filename against the repo before pulling):**
`unsloth/Qwen3.5-122B-A10B-GGUF` → file `Qwen3.5-122B-A10B-UD-Q4_K_XL.gguf`
Size-assert on download (~70 GB). A wrong/oversized file loads fine and emits
garbage — the corrupt-GGUF lesson. Verify with `du -sh` before trusting.

---

## 0. Sanity (same as suite §0)

```bash
nix shell nixpkgs#vulkan-tools -c vulkaninfo --summary | grep -i radv   # RADV STRIX_HALO
```
Every command carries the device pin `MESA_VK_DEVICE_SELECT=1002:1586`. Confirm
`load_backend: loaded Vulkan backend` in the banner. If prefill is single-digit /
decode ~12, it fell back to CPU — re-check pin + package. (For this model CPU
fallback would look like ~2–4 t/s, even more obviously wrong.)

---

## 1. Throughput — single-stream (`llama-bench`)

llama-bench measures plain single-stream throughput. (**Correction, post-run:**
the "A10B" naming suggested embedded MTP, but this GGUF has **no MTP layers** —
see §1b — so this figure is simply *the* single-stream decode, not a floor under
an MTP ceiling.)

```bash
MESA_VK_DEVICE_SELECT=1002:1586 \
HF_HOME=/var/lib/llama/hf HF_HUB_OFFLINE=0 \
nix shell nixpkgs#llama-cpp-vulkan -c llama-bench \
  --hf-repo unsloth/Qwen3.5-122B-A10B-GGUF \
  --hf-file Qwen3.5-122B-A10B-UD-Q4_K_XL.gguf \
  -ngl 99 -p 1024 -n 256
```
Record: size (GiB) · `pp1024` · `tg256`. Predicted ~ pp ~700–900 · tg ~18–20.
**Measured: 71.7 GiB · decode 22.2 t/s** (confirmed ~21–23 on `llama-server` —
the predicted ~3× slowdown vs the 3B-active MoEs held). Prefill **~380 t/s at a
real 1817-token context**; the 53 t/s short-prompt reading was a
per-request-overhead artifact, not a throughput wall.

## 1b. Throughput — MTP single-stream (`llama-server` + per-request timings)

> **RESULT: NOT APPLICABLE — this model has no MTP.** Despite the "A10B" naming,
> the published GGUF contains **no MTP layers**: `llama-server` refuses
> `--spec-type draft-mtp` with *"model doesn't contain MTP layers"* and exits.
> There is no speculative-decode bump to measure or to "claw back" decode with —
> the single-stream number is the §1 `llama-bench` figure (**22.2 t/s**), full
> stop. The commands below are kept for the record but **fail at startup on this
> GGUF**; the ~30–35 t/s MTP figure this section originally predicted does not
> exist for this model.

The architect is single-stream (one planner, not a swarm), so **MTP is allowed
here** (`--parallel 1`) — unlike the coder endpoint. This is where 122B-A10B
claws back decode speed, and the number that matters for real architect use.
Same method the suite used to measure MTP on the 27B/35B (llama-bench can't).

```bash
# start server with MTP (own tmux; loads ~70 GB — give it time)
MESA_VK_DEVICE_SELECT=1002:1586 \
HF_HOME=/var/lib/llama/hf HF_HUB_OFFLINE=0 \
nix shell nixpkgs#llama-cpp-vulkan -c llama-server \
  --hf-repo unsloth/Qwen3.5-122B-A10B-GGUF \
  --hf-file Qwen3.5-122B-A10B-UD-Q4_K_XL.gguf \
  --host 127.0.0.1 --port 8091 \
  -ngl 99 -fa on -c 65536 --parallel 1 \
  --spec-type draft-mtp --spec-draft-n-max 2 \
  --jinja --metrics --no-webui
```
```bash
# measure decode from the response timings (predicted_per_second)
curl -s http://127.0.0.1:8091/v1/chat/completions -H 'content-type: application/json' -d '{
  "model":"x","max_tokens":400,"chat_template_kwargs":{"enable_thinking":true},
  "messages":[{"role":"user","content":"Explain the CAP theorem with one concrete example per property."}]
}' | jq '.timings | {prefill_tps:.prompt_per_second, decode_tps:.predicted_per_second}'
```
Record MTP decode t/s + the draft acceptance rate from the server log. Compare the
MTP vs non-MTP decode: the 27B saw ~1.9× on this RADV box; a similar bump would
put 122B-A10B around ~30–35 t/s MTP — the realistic architect speed to quote.

## 1c. (optional) Concurrency sweep — only if you'd ever run it multi-stream

Only relevant if 122B-A10B would serve concurrent architect requests (unlikely —
one planner). Skip unless needed. If run, mirror the suite's `llama-batched-bench`
(`-npl 1,2,4,8`), expect MoE flattening like the other A-series.

---

## 2. Add to the consolidated comparison table (suite §2)

New row, same columns:

| Model | Role | Params (tot/act) | Size GiB | Decode t/s (B=1) | Prefill t/s | S_TG @ B=8 |
|-------|------|------------------|----------|------------------|-------------|------------|
| Qwen3.5-122B-A10B | REJECTED (arch. cand.) | 122B / 10B | 71.7 | 22.2 (no MTP) | ~380 @ 1817-tok | single-stream only |

Reference rows already in the table (do not re-run, compare against):
- Qwen3.6-35B-A3B — 35B/3B — 21.27 GiB — **59.7** (MTP↑) — 1106 — 159.8 (2.7×)
- Qwen3-Next-80B-A3B-Thinking — 80B/3B — 42.8 GiB — 58.7 — 712 — single-stream
- Qwen3.6-27B dense — 27B — 16.39 — **11.9** (22.9 MTP) — 328 — (active-param wall)

Interpret decode against the **active-param law**: 10B-active *should* sit ~3×
slower than the 3B-active MoEs. If it does, the box behaves as characterized and
the number is trustworthy. If MTP lifts it toward ~30 t/s, architect use is
comfortable.

---

## 3. Quality eval — the deciding part (suite §3, identical prompts)

**Same P1/P2/P3 text, verbatim** (protobuf rename / Java→Kotlin split / test-hang
diagnosis). Same sampling as the 35B run: temp 0.6 / top-p 0.95 / top-k 20 /
presence 1.5, thinking ON. Serve on 8091 (the MTP server above is fine).

Run each prompt, save the full blueprint + CoT. Score on the **existing rubric**:
blueprint correctness, dependency-order validity, real-vs-hallucinated touch-points,
whether verification catches regressions, CoT token count (cheaper wins ties).

The bar to beat is explicit and already recorded:
- **Qwen3-Next-80B-A3B-Thinking = 3/3 clean** (current architect).
- **Qwen3.6-35B-A3B = 2/3** (lean P2 miss: `@JvmRecord` trap + missed
  call-site/type-identity insight).

Fill this table (mirror the challenger table format):

| Prompt | vs Qwen3-Next (3/3) | 122B-A10B observed errors / notes |
|--------|---------------------|-----------------------------------|
| **P1** protobuf | **loss** | correct additive-migration reasoning + JSON/binary-name boundary — but **did NOT finish in 4000 tokens** (blueprint cut off mid-Prerequisites); ~a dozen "Wait/Correction" CoT reversals re-deriving the same conclusion |
| **P2** Kotlin | **loss** (beats 35B) | **beats the 35B** on the adapter-as-facade / keep-original-API-manifest call-site insight — but **STILL hits the `@JvmRecord`/JDK-16 trap**, so it fails the discriminator Qwen3-Next passes |
| **P3** hang | **tie** (doesn't beat) | correct CPU=0/deadlock vs CPU=100/loop isolation + futex/`strace` instinct — but **no `D`-state awareness** (same gap as the smaller models; doesn't beat them) |

**P2 is the discriminator.** It's the one both smaller models stumbled on (35B
lean-missed, gpt-oss verbatim-failed). If 122B-A10B *nails P2* — avoids the
`@JvmRecord` trap AND states the keep-original-type-name shim mechanism — that's
the "catches a load-bearing detail the others miss" signal that justifies it.
If it also just repeats `@JvmRecord`, the extra 10B active bought nothing here.

---

## 4. Decision (fill after running) — the actual fork

**Pass bar (decide before reading results, from TODO):** catches a load-bearing
architectural detail the 80B-A3B / 35B-A3B miss, **reproducibly, on >1 prompt**.
A nicer-*sounding* plan is not a pass. A single-prompt edge is not a pass.

- [ ] **PASS** → 122B-A10B becomes the **architect**; 35B-A3B stays the **coder**.
  This *re-splits* Node B into two models (deep-slow planner + fast coder) —
  reverting the single-model collapse, but for a principled quality reason, not
  the old swap-latency reason. Memory: 70 GB (architect) + 21 GB (coder) = ~91 GB,
  fits ~115 GB GTT but tight on KV — re-check the budget. New serving config
  needed (two endpoints, or architect-on-demand).
- [x] **FAIL / tie** → 80B-A3B-Thinking or the single 35B-A3B stays the architect.
  122B-A10B rejected: bigger, slower, no reproducible quality edge. Single-model
  Node B stands. Money/complexity saved.

### Verdict (recorded): **REJECTED**

Does NOT clear the bar ("catches a load-bearing detail the others miss,
reproducibly, and justifies the systems cost"):
- Caught one detail the **35B** missed, on **one** prompt (P2 call-site insight).
- **Beat the 80B-A3B-Thinking architect (3/3 clean) on nothing** — P1 loss (didn't
  finish in 4000 tok), P2 loss (shares the `@JvmRecord` bug), P3 tie (no `D`-state edge).
- Verbose/indecisive CoT (2600–4000+ tokens, repeated "Wait/Correction" reversals)
  at **~21–22 t/s**, with **no MTP** to recover speed.
- **Strictly dominated by the 80B-A3B** on every systems axis — decode (22 vs 59),
  prefill (~380 vs 712), memory (71.7 vs 42.8 GiB) — for **no** reasoning gain.

Same "bigger ≠ better on this ~256 GB/s box" pattern as the dense-27B rejection.
**Architect stays Qwen3-Next-80B-A3B-Thinking / Qwen3.6-35B-A3B; single-model
Node B unchanged.** The 235B-A22B tier (Node C) remains the real open question —
unaffected by this result.

**Load-bearing caveat (unchanged):** every model so far — including the winners —
emitted interop bugs. The blueprint is a draft; the **Slicer compile-gate is
mandatory regardless**. Since both finalists get verified downstream anyway,
weigh carefully whether you're really paying ~3× decode + 3.5× memory for
precision the gate would catch anyway. That argument *kept* the 35B in contention
last time; apply it here too.

---

## 5. Notes / gotchas specific to this model

- **Multimodal:** it's a vision-language model (`--mmproj`). You're testing text
  reasoning — skip the mmproj (`--no-mmproj` if it complains) so you're not
  loading the vision tower into the memory budget for nothing. MTP + `--mmproj`
  were mutually exclusive on the 35B; same expected here (another reason to drop
  mmproj for this run).
- **HF_HUB_OFFLINE=0 for the pull only.** The download needs online; once cached,
  the service runs offline like the rest. Don't leave offline off on the
  production service.
- **Don't touch the live `llama-serve` (8080).** This whole eval runs on a
  separate port (8091) so the production single-model node keeps serving. Same
  isolation as the 8090 agentic-test server.
- **If PASS and you re-split:** the two-endpoint / architect-on-demand serving
  config is a real design task — see TODO "single-model vs two-endpoint." The
  thinking-toggle plumbing is already proven; the memory budget is the new
  constraint at 70+21 GB.

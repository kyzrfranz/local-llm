# Node B — Local LLM Benchmark Suite (Strix Halo)

Re-runnable throughput + quality benchmarks for the local serving node.
Re-run occasionally (new llama.cpp builds, new model quants, driver bumps) and
compare against the baseline tables.

- **Hardware:** Corsair AI Workstation 300 — AMD Ryzen AI MAX+ 395 (Strix Halo),
  Radeon 8060S iGPU (gfx1151 / RADV STRIX_HALO), 128 GB unified LPDDR5X (~256 GB/s)
- **OS:** headless NixOS
- **Backend:** `llama.cpp` Vulkan/RADV (`nixpkgs#llama-cpp-vulkan`)
- **Baseline captured:** 2026-06, llama.cpp build `b9608-70b54e1`
- **Memory tuning in effect:** `ttm.pages_limit=30146560` (~115 GiB GTT),
  `hardware.graphics.enable = true`

> Numbers below are *this box's* baseline. They will drift with llama.cpp builds
> and quant updates — that drift is the reason to re-run.

---

## 0. Prerequisites & sanity checks

The device pin is mandatory on every run — without `MESA_VK_DEVICE_SELECT`
llama.cpp may pick `llvmpipe` (CPU software rasterizer) and silently run slow.

```bash
# GPU visible to Vulkan? Must list "AMD Radeon 8060S Graphics (RADV STRIX_HALO)"
nix shell nixpkgs#vulkan-tools -c vulkaninfo --summary | grep -i radv
```

Standard prefix for every benchmark (pins the iGPU, vendor:device = 1002:1586):

```bash
MESA_VK_DEVICE_SELECT=1002:1586 nix shell nixpkgs#llama-cpp-vulkan -c <tool> ...
```

On every run, confirm the startup banner shows the Vulkan device line and
`load_backend: loaded Vulkan backend`. If you ever see `pp` in the single
digits / `tg` ~12, it fell back to CPU — re-check the package and the pin.

**Tools used:**
- `llama-bench` — single-stream prefill (`pp`) + decode (`tg`)
- `llama-batched-bench` — concurrency sweep (`S_PP`, `S_TG` per batch size `B`)

---

## 1. Throughput benchmarks

Each model: a single-stream `llama-bench`, then a `llama-batched-bench`
concurrency sweep. Baseline results follow each command.

### 1.1 Qwen2.5-Coder-7B-Instruct Q8 — *validation baseline (historical)*

First model used to prove the GPU path works; not part of the final lineup.

```bash
MESA_VK_DEVICE_SELECT=1002:1586 \
nix shell nixpkgs#llama-cpp-vulkan -c llama-bench \
  -hf unsloth/Qwen2.5-Coder-7B-Instruct-GGUF:Q8_0 \
  -ngl 99 -p 1024 -n 256

MESA_VK_DEVICE_SELECT=1002:1586 \
nix shell nixpkgs#llama-cpp-vulkan -c llama-batched-bench \
  -hf unsloth/Qwen2.5-Coder-7B-Instruct-GGUF:Q8_0 \
  -c 16384 -ngl 99 -npp 1024 -ntg 256 -npl 1,2,4,8
```

Size 7.54 GiB · `llama-bench`: **pp1024 1239.97 · tg256 28.14**

| B | S_PP t/s | S_TG t/s |
|---|----------|----------|
| 1 | 1188.69  | 28.19    |
| 2 | 1138.93  | 55.20    |
| 4 | 1102.17  | 104.29   |
| 8 | 1102.43  | 192.94   |

*Note: near-linear decode scaling (6.84× at B=8) — dense model, weights shared
across the batch.*

### 1.2 Qwen3-Coder-30B-A3B-Instruct Q4_K_XL — *MoE coder (superseded)*

```bash
MESA_VK_DEVICE_SELECT=1002:1586 \
nix shell nixpkgs#llama-cpp-vulkan -c llama-bench \
  -hf unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF:Q4_K_XL \
  -ngl 99 -p 1024 -n 256

MESA_VK_DEVICE_SELECT=1002:1586 \
nix shell nixpkgs#llama-cpp-vulkan -c llama-batched-bench \
  -hf unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF:Q4_K_XL \
  -c 16384 -ngl 99 -npp 1024 -ntg 256 -npl 1,2,4,8
```

Size 16.45 GiB · `llama-bench`: **pp1024 1288.12 · tg256 91.88**

| B | S_PP t/s | S_TG t/s |
|---|----------|----------|
| 1 | 1074.43  | 83.32    |
| 2 | 1274.05  | 120.49   |
| 4 | 1206.93  | 159.56   |
| 8 | 1174.47  | 195.53   |

*Note: flattens hard under concurrency (only 2.35× at B=8) — MoE expert
divergence across the batch. Superseded by Coder-Next.*

### 1.3 Qwen3-Coder-Next 80B-A3B UD-Q4_K_XL — *current coder*

```bash
MESA_VK_DEVICE_SELECT=1002:1586 \
nix shell nixpkgs#llama-cpp-vulkan -c llama-bench \
  --hf-repo unsloth/Qwen3-Coder-Next-GGUF \
  --hf-file Qwen3-Coder-Next-UD-Q4_K_XL.gguf \
  -ngl 99 -p 1024 -n 256

MESA_VK_DEVICE_SELECT=1002:1586 \
nix shell nixpkgs#llama-cpp-vulkan -c llama-batched-bench \
  --hf-repo unsloth/Qwen3-Coder-Next-GGUF \
  --hf-file Qwen3-Coder-Next-UD-Q4_K_XL.gguf \
  -c 16384 -ngl 99 -npp 1024 -ntg 256 -npl 1,2,4,8
```

Size 46.20 GiB · `llama-bench`: **pp1024 849.46 · tg256 51.67**

| B | S_PP t/s | S_TG t/s |
|---|----------|----------|
| 1 | 856.02   | 51.69    |
| 2 | 881.35   | 72.87    |
| 4 | 859.55   | 105.40   |
| 8 | 849.51   | 131.77   |

*Note: 80B quality at 3B-active speed; scales 2.6× at B=8 (better than the
30B-A3B). Hybrid Gated-DeltaNet attention → cheaper KV growth under concurrency.*

### 1.4 GLM-4.5-Air 106B-A12B UD-Q4_K_XL — *rejected (too slow)*

Sharded GGUF — point `--hf-file` at part 1.

```bash
MESA_VK_DEVICE_SELECT=1002:1586 \
nix shell nixpkgs#llama-cpp-vulkan -c llama-bench \
  --hf-repo unsloth/GLM-4.5-Air-GGUF \
  --hf-file UD-Q4_K_XL/GLM-4.5-Air-UD-Q4_K_XL-00001-of-00002.gguf \
  -ngl 99 -p 1024 -n 256

MESA_VK_DEVICE_SELECT=1002:1586 \
nix shell nixpkgs#llama-cpp-vulkan -c llama-batched-bench \
  --hf-repo unsloth/GLM-4.5-Air-GGUF \
  --hf-file UD-Q4_K_XL/GLM-4.5-Air-UD-Q4_K_XL-00001-of-00002.gguf \
  -c 16384 -ngl 99 -npp 1024 -ntg 256 -npl 1,2,4
```

Size 63.06 GiB · `llama-bench`: **pp1024 253.47 · tg256 24.89**

| B | S_PP t/s | S_TG t/s |
|---|----------|----------|
| 1 | 288.43   | 24.37    |
| 2 | 283.81   | 35.07    |
| 4 | 285.85   | 45.90    |

*Note: A12B → ~half the decode of the A3B models and a third of the prefill.
Eliminated as architect candidate on speed.*

### 1.5 gpt-oss-120b MXFP4 — *thinking candidate · SINGLE-STREAM ONLY*

> ⚠️ **Do NOT run `llama-batched-bench` with multi-slot / large `-c` on this model.**
> It overran the GTT budget and hard-wedged the GPU (`ErrorDeviceLost`,
> uninterruptible D-state, survived `kill -9`) — recovery required a full
> power-drain reboot (see §4). Single-slot `llama-bench` is safe.
> For the real service it runs fine at `--parallel 1` (architect = turn-by-turn).

```bash
# Single-stream, short generation
MESA_VK_DEVICE_SELECT=1002:1586 \
nix shell nixpkgs#llama-cpp-vulkan -c llama-bench \
  -hf ggml-org/gpt-oss-120b-GGUF \
  -ngl 99 -p 1024 -n 256

# Single-stream, long generation (sustained-decode check)
MESA_VK_DEVICE_SELECT=1002:1586 \
nix shell nixpkgs#llama-cpp-vulkan -c llama-bench \
  -hf ggml-org/gpt-oss-120b-GGUF \
  -ngl 99 -p 1024 -n 2048
```

Size 59.02 GiB (116.83B, 5.1B active, MXFP4 native)

| test    | pp1024 | tg     |
|---------|--------|--------|
| n=256   | 645.31 | 54.31  |
| n=2048  | 602.23 | 52.75  |

*Note: ~3% decode sag over the longer run. Use `-fa 1` and keep `--parallel 1`
in production. Sampling: temp 1.0, top_p 1.0, NO repetition penalty.*

### 1.6 Qwen3-Next-80B-A3B-Thinking UD-Q4_K_XL — *chosen architect*

```bash
# Single-stream, short generation
MESA_VK_DEVICE_SELECT=1002:1586 \
nix shell nixpkgs#llama-cpp-vulkan -c llama-bench \
  -hf unsloth/Qwen3-Next-80B-A3B-Thinking-GGUF:Q4_K_XL \
  -ngl 99 -p 1024 -n 256

# Single-stream, long generation (the metric that matters for a reasoning model)
MESA_VK_DEVICE_SELECT=1002:1586 \
nix shell nixpkgs#llama-cpp-vulkan -c llama-bench \
  -hf unsloth/Qwen3-Next-80B-A3B-Thinking-GGUF:Q4_K_XL \
  -ngl 99 -p 1024 -n 2048
```

Size 42.77 GiB

| test    | pp1024 | tg     |
|---------|--------|--------|
| n=256   | 712.43 | 58.66  |
| n=2048  | 726.25 | 58.73  |

*Note: decode is FLAT across 8× longer generation (58.66 → 58.73) — no sag as
CoT grows. Sampling: temp 0.6, top_p 0.95, top_k 20, min_p 0.0, presence_penalty 1.0.*

---

## 2. Consolidated comparison (single-stream baseline)

| Model | role | total / active | size GiB | decode t/s | prefill t/s | concurrency (B=8 S_TG) |
|-------|------|----------------|----------|------------|-------------|------------------------|
| Qwen2.5-Coder-7B Q8 | validation | 7B dense | 7.54 | 28.1 | 1240 | 192.9 (6.84×) |
| Qwen3-Coder-30B-A3B | coder (old) | 30B / 3B | 16.45 | 91.9 | 1288 | 195.5 (2.35×) |
| **Qwen3-Coder-Next** | **coder** | 80B / 3B | 46.20 | 51.7 | 849 | 131.8 (2.6×) |
| GLM-4.5-Air | rejected | 106B / 12B | 63.06 | 24.9 | 253 | — (45.9 @ B=4) |
| gpt-oss-120b | architect cand. | 117B / 5.1B | 59.02 | 54.3 | 645 | single-stream only |
| **Qwen3-Next-Thinking** | **architect** | 80B / 3B | 42.77 | 58.7 | 712 | single-stream only |
| **Qwen3.6-35B-A3B** | **dual-role candidate** | 35B / 3B | 21.27 | 59.7 (MTP↑) | 1106 | **159.8 (2.7×)** |
| Qwen3.6-27B (dense) | rejected | 27B dense | 16.39 | **11.9** (22.9 MTP) | 328 | single-stream only |
| Qwen3.5-122B-A10B | rejected (arch. cand.) | 122B / 10B | 71.7 | 22.2 (no MTP) | ~380 | single-stream only |

> **Qwen3.6-27B is the active-parameter wall, stated plainly:** a 16 GiB dense
> model decodes ~5× *slower* than the 46 GiB Qwen3-Coder-Next, because decode is
> bandwidth-bound on *active* params — dense streams all 27B/token, the Next MoEs
> stream ~3B. On this ~256 GB/s box, **dense is the wrong architecture for
> serving regardless of quality.** RTX/Metal review numbers do NOT transfer —
> those boxes have far more bandwidth.
>
> **MTP retested (it IS in the GGUF — runtime flags, not a separate file):**
> with `--spec-type draft-mtp --spec-draft-n-max 2` on `llama-server`, decode
> went **11.9 → 22.9 t/s** at **0.717 draft acceptance** (301/420 tokens). So
> MTP delivers a real ~1.9× *on this RADV/Vulkan box* — speculative decoding is
> proven viable on gfx1151, which is the useful finding. But ~23 t/s is still
> under half the Next pair's ~55–59, so the dense 27B stays **rejected** even
> doubled. Note: MTP is `-np 1` only (no concurrency, no `--mmproj`).
> `llama-bench` cannot measure MTP — must use `llama-server` + per-request timings.
>
> The de-risked finding (MTP works here) is what makes the **35B-A3B** worth a
> real test: MoE 3B-active speed floor PLUS a proven MTP bump. That's the one
> Qwen3.6 model with a path to competing — see §3.x test below.
>
> **Qwen3.5-122B-A10B (10B-active architect candidate) — REJECTED.** 71.7 GiB,
> decode **22.2 t/s** (`llama-bench`; ~21–23 on `llama-server`, the predicted ~3×
> slowdown vs the 3B-active MoEs held), prefill **~380 t/s at real 1817-token
> context** (the 53 t/s short-prompt figure was a per-request-overhead artifact).
> **No MTP:** despite the "A10B" naming the GGUF ships *no MTP layers* —
> `llama-server` refuses `--spec-type draft-mtp` (*"model doesn't contain MTP
> layers"*), so there's no speculative bump to reclaim decode. Quality (P1–P3,
> thinking on, same rubric): beat the *35B* on P2's adapter-as-facade / keep-
> original-API insight, but STILL hit the `@JvmRecord`/JDK-16 trap (the
> discriminator Qwen3-Next passes), didn't finish P1 in 4000 tokens (~a dozen
> "Wait/Correction" CoT reversals), and only matched the smaller models on P3
> (no `D`-state awareness). Net: caught one detail the *35B* missed on one
> prompt; **beat the 80B-A3B-Thinking architect (3/3) on nothing**, shares its
> `@JvmRecord` bug, and is strictly dominated on every systems axis (decode,
> prefill, memory) at ~3× the active-param cost. Same "bigger ≠ better on this
> ~256 GB/s box" verdict as the dense-27B. Architect stays 80B-A3B-Thinking /
> 35B-A3B; the 235B-A22B (Node C) tier is untouched by this. Full write-up:
> `bench-qwen35-122b-a10b.md`.

---

## 3. Quality eval (the part the throughput numbers can't decide)

Throughput between the two thinking candidates is a near-tie (~55 vs ~59 t/s),
so the architect choice comes down to reasoning quality. Run the SAME prompt
through each model **at its own sampling settings** and judge the output +
the CoT token count (printed in `llama-cli` end-of-run timings).

> `-no-cnv` is not supported on this `llama-cli` build (use `llama-completion`
> for scripted runs). Interactive paste into the `>` prompt works fine for eval.

**Architect candidate — Qwen3-Next-Thinking** (temp 0.6 / top_p 0.95 / top_k 20):

```bash
MESA_VK_DEVICE_SELECT=1002:1586 \
nix shell nixpkgs#llama-cpp-vulkan -c llama-cli \
  -hf unsloth/Qwen3-Next-80B-A3B-Thinking-GGUF:Q4_K_XL \
  --jinja -ngl 99 -fa 1 -c 40960 \
  --temp 0.6 --top-p 0.95 --top-k 20 --min-p 0.0 --presence-penalty 1.0 \
  -p "<PROMPT>"
```

**Architect candidate — gpt-oss-120b** (temp 1.0 / top_p 1.0 / no penalty / effort=high):

```bash
MESA_VK_DEVICE_SELECT=1002:1586 \
nix shell nixpkgs#llama-cpp-vulkan -c llama-cli \
  -hf ggml-org/gpt-oss-120b-GGUF \
  --jinja -ngl 99 -fa 1 -c 40960 \
  --temp 1.0 --top-p 1.0 \
  --chat-template-kwargs '{"reasoning_effort":"high"}' \
  -p "<PROMPT>"
```

### Fixed prompt set (use identical text for both models)

**P1 — cross-language dependency reasoning**
> A TypeScript React frontend calls a Go REST service that shares protobuf-defined types with a Python analytics worker. A field is being renamed in the protobuf schema. Produce a strict, ordered execution blueprint to roll out this rename across all three services with zero downtime, listing the dependency order, the touch-points in each language, and the verification step after each stage.

**P2 — refactor planning under constraints**
> A 4,000-line Java module handles auth, and we're splitting it into a Kotlin auth-core library plus a thin Java adapter, with no behavior change and no break to the 30+ call sites. Produce a strict execution blueprint: the decomposition, the safe ordering of extractions, what must be verified at each step, and where the risks are.

**P3 — failure-recovery reasoning**
> A coding agent applied a patch, the test suite now hangs instead of failing, and the only signal is that one new integration test never returns. Produce a strict diagnostic blueprint: the ordered hypotheses to check, how to isolate a hang from a failure, and the decision tree for where to look first.

### Scoring rubric
For each (model × prompt): blueprint correctness, dependency-order validity,
real vs hallucinated touch-points, whether verification actually catches
regressions, and **CoT token count** (cheaper thinking wins ties).

### Results (recorded)

Generation speed held the ~10% gap from the throughput benches across all three
(Qwen3-Next ~55–57 t/s vs gpt-oss ~50–52). Speed was never the deciding factor;
correctness of the load-bearing detail was.

| Prompt | Winner | Margin | gpt-oss observed errors | Qwen3-Next observed errors |
|--------|--------|--------|--------------------------|-----------------------------|
| **P1** protobuf rename | Qwen3-Next | decisive | **both fields tag `= 1`** → `protoc` compile error; entire "wire format identical" justification built on the impossibility | none — `old=1 [deprecated]`, `new=2`; also caught the JSON-vs-protobuf boundary |
| **P2** Java→Kotlin split | Qwen3-Next | clear | **extends a `@JvmInline value class`** (structurally impossible); **`@JvmRecord` with `sourceCompatibility=1.8`** (needs JDK 16+, self-contradictory); new-name adapter classes muddle the call-site contract | **`@JvmRecord`** (no JDK pinned → latent JDK-16 trap); **silently swaps Jackson→kotlinx.serialization** (forbidden behavior change); misapplies `@JvmDefault` to "fix" nullability |
| **P3** test-hang diagnosis | Qwen3-Next | lean | no `D`-state awareness; leans on `jstack`/`SIGQUIT` which may not dump on an uninterruptible block | leans on signals that may not dump in `D`-state (but at least names `D`/`S`/`R`) |

**Key pattern:** Qwen3-Next beats gpt-oss on all three; margin shrinks as tasks
move from "needs a precise correctness fact" (P1) toward "needs broad tooling
breadth" (P3). gpt-oss committed a *verbatim-fatal* error in both P1 and P2.

### Later challenger: Qwen3.6-35B-A3B (P1–P3 vs Qwen3-Next)

Re-run after the 35B-A3B's throughput shocked the table (see §2). Same prompts,
Qwen3.6 reasoning sampling (temp 0.6 / top-p 0.95 / top-k 20 / presence 1.5,
`preserve_thinking`).

| Prompt | vs Qwen3-Next | Qwen3.6-35B-A3B observed errors / notes |
|--------|---------------|------------------------------------------|
| **P1** protobuf | tie (35B arguably sharper) | clean — `new=5`, `old=3 [deprecated]`, explicit "never reuse a tag"; **best treatment of the JSON/`json_name` boundary** of all three |
| **P2** Kotlin | **lean loss to Qwen3-Next** | repeats the **`@JvmRecord` trap** (qualified "if Java 16+", better than gpt-oss but still reaches for it); **misses the call-site/type-identity insight** — builds a new `AuthFacade` class, asserts "zero caller changes" without the mechanism (keep the original type name as the delegating shim) |
| **P3** hang | tie | clean — gets the **`D`-state** signature, notes **SIGKILL won't dump** on a wedged proc, evidence-driven tree, **best agent-diff-first framing**; minor: degenerate "Ready✅" looping in the CoT scratchpad |

**Scorecard:** Qwen3-Next = 3/3 clean. Qwen3.6-35B-A3B = 2/3 clean + 1 lean
miss (P2). This is **one hair of reasoning precision**, NOT a class gap like the
gpt-oss rejection. On sub-points the 35B was *sharper* than Next twice (JSON
boundary P1, agent-diff P3).

**Load-bearing caveat (unchanged, reinforced):** every model — including the
winners — emitted interop-detail bugs (`@JvmRecord`, Jackson swap, value-class
extension). **An architect blueprint is a strong draft, not ground truth.** The
Slicer compile/verify gate is mandatory. Since both finalists get verified
downstream anyway, you are NOT really paying for Next's extra precision.

### Decision (revised)

- **Architect (pure reasoning):** Qwen3-Next-80B-A3B-Thinking still edges it
  (3/3 clean). But Qwen3.6-35B-A3B reasons at *nearly* the same level while
  winning decisively on every systems axis: **159.8 t/s @ B=8** (vs Next's
  single-stream-only), **1106 prefill** (vs 712), **21.3 GiB** (vs 42.8), MTP
  support, and 2.7× concurrency scaling.
- **The structural opportunity:** at 21 GiB, hybrid-thinking, fast *and*
  concurrency-scaling, the 35B-A3B could plausibly serve **BOTH** roles —
  thinking-on = architect, thinking-off = coder — co-resident with room to
  spare, **deleting llama-swap entirely**. One 21 GiB model replacing the
  46+43 GiB Next pair.
- **Not finalized on 3 one-shot prompts.** Before collapsing the stack, run a
  **real multi-turn agentic coding session** with the 35B-A3B (tool calls, long
  context, `preserve_thinking`) — that tests coherence-over-a-task, which
  one-shot blueprints can't. That's the gate for the single-model Node B.

---

## 4. Known issues & recovery

**gpt-oss-120b can hard-wedge the GPU** under concurrent/large-KV load on this
box. Symptom: `radv/amdgpu: Not enough memory for command submission` →
`ErrorDeviceLost` → process stuck in `D+` (uninterruptible), survives `kill -9`.

Recovery (nothing in userspace works — only a cold power cycle):
```bash
sudo poweroff          # if it hangs on shutdown, wait ~30s then:
sudo sh -c 'echo b > /proc/sysrq-trigger'   # forced kernel reboot
# then: physically pull wall power ~60s before cold boot
```

**WiFi disappears after a forced reboot** (`nmcli: no wifi devices found`,
no `wlp*` in `/sys/class/net/`). This is firmware failing to re-enumerate the
adapter after a GPU/SoC wedge — a *symptom* of the hang, not a kernel bug.
Fix: full **power-drain** cold boot (pull power ~60s). Do NOT keep raising the
BIOS UMA buffer — that's a side-effect "fix" that permanently steals RAM.
Check hardware presence: `ls /sys/class/net/` (look for `wlp*`).

Prevention: never point concurrent load at gpt-oss; treat any `ErrorDeviceLost`
as a hard stop, not a retry; prefer a wired link for a headless node.

---

## 5. Decisions log

- **Backend:** Vulkan/RADV, not ROCm. Stable + fastest single-stream on gfx1151.
  `nixpkgs#llama-cpp` is CPU-only — must use `llama-cpp-vulkan`.
- **Coder:** Qwen3-Coder-Next (80B-A3B). 80B quality at ~52 t/s; replaced the
  30B-A3B (which flattened under concurrency).
- **Architect:** Qwen3-Next-80B-A3B-Thinking — fastest decode (58.7), flat over
  long CoT, smallest footprint (42.8 GiB), never wedged the GPU, and won P1 on
  correctness. gpt-oss-120b was close on speed but failed P1's protobuf detail
  and is a GPU-stability risk under load.
- **Elegant outcome:** coder + architect are the same Qwen3-Next 80B-A3B family
  (~43–46 GiB each) → clean `llama-swap` between them, shared tuning.
- **Frontier:** reserved for genuine escalation only (deep reasoning beyond local).
```
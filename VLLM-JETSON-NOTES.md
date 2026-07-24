# Running vLLM on the Orin — effort & tradeoffs (for the Arya call)

The RAG client already speaks vLLM (`RAG_ENGINE=vllm`, validated end-to-end against an OpenAI-compatible endpoint). The only remaining work is standing up a vLLM **server** on the Jetson. This note is the effort/risk picture so we can decide whether it's worth it — it is **not** a to-do list to execute solo.

## TL;DR

- **It's possible and doesn't need a from-scratch build** — `jetson-containers` ships a **prebuilt** vLLM image on Docker Hub (`dustynv/vllm`, ~6GB), CUDA 12.6 + PyTorch 2.8 + FlashAttention/xFormers/Triton baked in. Requires L4T ≥ 34.1 (JetPack 5.1+); our Orin is Ubuntu 22.04 → JetPack 6.x → the `r36.x` tags.
- **Compatible with Arya's host rules** — it's a container, uses the NVIDIA runtime that's already configured for Ollama; no host installs, no sudo needed.
- **The real cost isn't the build — it's memory coexistence and downloads.** vLLM and the resident Ollama stack both draw on the same 64GB unified memory, and getting the model + image down on this box's flaky network is the actual risk.
- **Effort: ~2–4 hrs if the version matches and the network cooperates; a day+ if not.**

## Prerequisites to check first (5 minutes, settles most unknowns)

1. **L4T version** → picks the exact image tag:
   ```
   cat /etc/nv_tegra_release        # e.g. R36 (release), REVISION: 4.x  -> use an r36.4 tag
   ```
2. **Free memory** — Ollama currently keeps ~20GB resident (`OLLAMA_KEEP_ALIVE=-1`: 7B + gpt-oss + 64k-expand + embed). vLLM pre-grabs a fraction of the 64GB on launch. Check headroom (`free -h`, `tegrastats`). **This is the crux — see risks below.**
3. **Free disk under `/opt/ataru/llm`** — need ~6GB (image) + ~5–15GB (model, depending on quantization). `df -h /opt`.
4. **Network** — the gpt-oss pull failed repeatedly here (Cloudflare resets). The vLLM image and the HF model are both large pulls facing the same risk.

## The path (concrete shape — do NOT run before the call / version check)

```bash
# 1. Pull the prebuilt image matching the Orin's L4T (VERIFY the tag first):
docker pull dustynv/vllm:0.8.6-r36.4-cu128-24.04

# 2. Launch vLLM serving an HF-format model (NOT an Ollama GGUF -- see risks).
#    Quantized (AWQ) strongly preferred on Jetson for memory:
docker run --runtime nvidia --ipc host -p 8000:8000 \
  -v /opt/ataru/llm/hf-cache:/root/.cache/huggingface \
  dustynv/vllm:0.8.6-r36.4-cu128-24.04 \
  vllm serve Qwen/Qwen2.5-7B-Instruct-AWQ \
    --gpu-memory-utilization 0.45 \   # LEAVE ROOM for the Ollama stack
    --max-model-len 8192 --quantization awq

# 3. Point the RAG at it (already built; validated):
docker compose run --rm \
  -e RAG_ENGINE=vllm -e RAG_VLLM_URL=http://<orin-ip>:8000/v1 \
  -e RAG_CHAT_MODEL=Qwen/Qwen2.5-7B-Instruct-AWQ \
  rag python cli.py query "..." --timing
```

## The hard parts (the honest risks)

1. **Memory coexistence is the #1 issue.** On the 64GB *unified* Orin, vLLM's pre-allocated pool and Ollama's ~20GB resident models compete for the same RAM. Options, none free:
   - Run vLLM with a low `--gpu-memory-utilization` and shrink the Ollama footprint — fiddly, and you lose the "all models warm" behavior we tuned for.
   - Or **stop the Ollama stack while vLLM runs** — simplest, but then you can't A/B both engines live, and it changes the box's steady state.
   This is why it's an ATARU-level decision, not a local one: it affects what else can run on the Orin.
2. **Model format changes.** vLLM loads HF safetensors, not Ollama's GGUF — so the model is a *separate* multi-GB download (mitigate with AWX/GPTQ quantization + a cached HF volume). Same flaky-network exposure as before.
3. **Tag/JetPack matching** is the usual failure mode — an r35 image on a JetPack 6 box (or vice-versa) won't run. The `cat /etc/nv_tegra_release` check up front avoids it.
4. **aarch64 kernel coverage** — most attention/quant kernels are present in these images, but Jetson is a smaller-tested target than x86; expect occasional "unsupported on this arch" edges and slower-than-datacenter numbers.

## Recommendation for the call

Because the RAG client is **already done and validated**, this is purely a "do we want vLLM *serving* on the Orin" infrastructure question — and it's really an **ATARU-level** one, for two reasons:

1. **It competes for the Orin's 64GB with the existing Ollama + ATARU containers.** Whoever owns the box's memory budget owns this decision.
2. **OpenJarvis already supports vLLM** in its `engine/`. If ATARU standardizes on vLLM, the server should be a shared ATARU deployment that everything points at — not a local-rag-assistant side-install. If it doesn't, there's little reason to pay the memory/complexity cost for a single-user assistant where Ollama already performs well.

**Proposed stance:** keep the engine switch parked (it costs nothing idle), and only stand up a vLLM server if ATARU decides to standardize on it — at which point it's Arya's infra call and a shared endpoint, and our client just points at it. The prebuilt image means that's a ~half-day job whenever the decision lands, not a research project.

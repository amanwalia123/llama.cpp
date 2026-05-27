#!/bin/sh
# Optimized for Dual RTX 4090 Setup
# Total VRAM: 48GB | Model: Qwen3.6-27B

export PATH="$PATH:$HOME/build/bin"

# 1. Enable both GPUs for maximum VRAM headroom and context scalability
CUDA_VISIBLE_DEVICES=0,1 llama-server -m /home/aman.walia/models/Qwen3.6/Qwen3.6-27B-GGUF/Qwen3.6-27B-Q8_0.gguf \
		--mmproj /home/aman.walia/models/Qwen3.6/Qwen3.6-27B-GGUF/mmproj-Qwen3.6-27B-Q8_0.gguf \
		--threads 9 \
		--n-gpu-layers -1 \
		--ctx-size 70000 \
		--flash-attn "on" \
		--jinja \
		-ub 4096 -b 4096 \
		--cache-type-k q8_0 \
		--cache-type-v q8_0 \
		--temp 0.7 --top-p 0.9 --top-k 40 \
		--host 0.0.0.0 --port 11434 \
		--webui-mcp-proxy \
		--tensor-split 50,50 \
		--chat-template-kwargs '{"reasoning_effort":"high"}' \
		--tools all

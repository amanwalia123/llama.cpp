#!/bin/sh
export PATH="$PATH:$HOME/build/bin"
CUDA_VISIBLE_DEVICES=1 llama-server -hf ggml-org/gemma-4-31B-it-GGUF \
		--threads 9 \
		--n-gpu-layers -1 \
		--flash-attn "on" \
		--jinja \
		-ub 4096 -b 4096 \
		--temp 0.7 --top-p 0.9 --top-k 40 \
		--host 0.0.0.0 --port 11434 \
		--webui-mcp-proxy \
#		--tensor-split 50,50 \
#  		-np 1 \
 		 --chat-template-kwargs '{"reasoning_effort":"high"}'

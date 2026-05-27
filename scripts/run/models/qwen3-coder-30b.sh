#!/bin/sh
CUDA_VISIBLE_DEVICES=0,1 llama-server -hf  ggml-org/Qwen3-Coder-30B-A3B-Instruct-Q8_0-GGUF \
		--ctx-size 100000 \
		--threads 9 \
		--n-gpu-layers -1 \
		--flash-attn "on" \
		--jinja \
		-ub 4096 -b 4096 \
		--temp 0.7 --top-p 0.9 --top-k 40 \
		--host 0.0.0.0 --port 11434 \
#		--tensor-split 50,50 \
#  		-np 1 \
 		 --chat-template-kwargs '{"reasoning_effort":"high"}' 


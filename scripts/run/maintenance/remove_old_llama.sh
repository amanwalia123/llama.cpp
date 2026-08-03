#!/bin/sh
sudo rm -f /usr/local/lib/libllama.so*
sudo rm -f /usr/local/lib/libggml.so*
sudo rm -f /usr/local/lib/libggml-base.so*
sudo rm -f /usr/local/lib/libggml-cpu.so*
sudo rm -f /usr/local/lib/libggml-cuda.so*

sudo rm -f /usr/local/include/llama.h
sudo rm -f /usr/local/include/llama-cpp.h
sudo rm -f /usr/local/include/ggml*.h

sudo rm -rf /usr/local/lib/cmake/llama/
sudo rm -rf /usr/local/lib/cmake/ggml/

sudo rm -f /usr/local/lib/pkgconfig/llama.pc

sudo rm -f /usr/local/bin/test-llama-grammar
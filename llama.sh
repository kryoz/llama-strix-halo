#!/bin/bash

export GGML_HIP_MAX_BATCH_SIZE=2048
export GGML_HIP_ENABLE_UNIFIED_MEMORY=1
export ROCBLAS_USE_HIPBLASLT=1
export HSA_OVERRIDE_GFX_VERSION=11.5.1

export LLAMA_ARG_TIMEOUT=1800
export LLM_PORT=9999

CMD="./llama-server --numa numactl \
  -t 7 -tb 7 --threads-http 7 --parallel 1 -dio --kv-unified --no-ui --metrics \
  -ngl 999 -ngld all --no-mmap -fa 1 -nocb \
  --models-preset ${HOME}/llama.ini --models-max 1 \
  --host 0.0.0.0 --port ${LLM_PORT}"

# you can build at ~/llama your custom llama.cpp or get it from https://github.com/lemonade-sdk/llamacpp-rocm/releases
cd $HOME/llama && numactl --cpunodebind=0 --membind=0 $CMD

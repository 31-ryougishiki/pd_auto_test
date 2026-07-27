#!/bin/bash
python launch_online_dp.py \
  --dp-size 16 \
  --tp-size 1 \
  --dp-size-local 16 \
  --dp-rank-start 0 \
  --dp-address 7.246.78.74 \
  --dp-rpc-port 12321 \
  --vllm-start-port 7100
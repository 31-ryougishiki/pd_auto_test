nic_name="eth2"
local_ip=7.246.78.73

export HCCL_OP_EXPANSION_MODE="AIV"

export HCCL_IF_IP=$local_ip
export GLOO_SOCKET_IFNAME=$nic_name
export TP_SOCKET_IFNAME=$nic_name
export HCCL_SOCKET_IFNAME=$nic_name

export VLLM_RPC_TIMEOUT=3600000
export VLLM_EXECUTE_MODEL_TIMEOUT_SECONDS=30000
export HCCL_EXEC_TIMEOUT=204
export HCCL_CONNECT_TIMEOUT=120

export OMP_PROC_BIND=false
export OMP_NUM_THREADS=10
export PYTORCH_NPU_ALLOC_CONF=expandable_segments:True
export HCCL_BUFFSIZE=1600
export TASK_QUEUE_ENABLE=1

export LD_PRELOAD=/usr/lib/aarch64-linux-gnu/libjemalloc.so.2:$LD_PRELOAD
export USE_MULTI_GROUPS_KV_CACHE=1
export USE_MULTI_BLOCK_POOL=1

export ASCEND_RT_VISIBLE_DEVICES=$1

export LD_LIBRARY_PATH=/vllm-workspace/vllm-ascend/its-opt/ascend_custom_ops/_cann_ops_custom/vendors/its-vllm-ascend/op_api/lib/:${LD_LIBRARY_PATH}
export ASCEND_CUSTOM_OPP_PATH=/vllm-workspace/vllm-ascend/its-opt/ascend_custom_ops/_cann_ops_custom/vendors/its-vllm-ascend:${ASCEND_CUSTOM_OPP_PATH}
export PYTHONPATH=/vllm-workspace/vllm-ascend/its-opt:$PYTHONPATH


# vllm-ascend-its:deepseekv4镜像必须
# export LD_LIBRARY_PATH=/vllm-workspace/vllm-ascend/its-opt/ascend_custom_ops/_cann_ops_custom/vendors/its-vllm-ascend/op_api/lib/:${LD_LIBRARY_PATH}
# export ASCEND_CUSTOM_OPP_PATH=/vllm-workspace/vllm-ascend/its-opt/ascend_custom_ops/_cann_ops_custom/vendors/its-vllm-ascend:${ASCEND_CUSTOM_OPP_PATH}
# export PYTHONPATH=/vllm-workspace/vllm-ascend/its-opt:$PYTHONPATH
export PYTHONPATH=/opt/its/z30055003/vllm-ascend:$PYTHONPATH
export PYTHONPATH=/opt/its/z30055003/vllm:$PYTHONPATH
source /vllm-workspace/vllm-ascend/vllm_ascend/_cann_ops_custom/vendors/custom_transformer/bin/set_env.bash


vllm serve /opt/its/model/DeepSeek-V4-Flash-w8a8-mtp-self \
    --host 0.0.0.0 \
    --port $2 \
    --data-parallel-size $3 \
    --data-parallel-rank $4 \
    --data-parallel-address $5 \
    --data-parallel-rpc-port $6 \
    --tensor-parallel-size $7 \
    --enable-expert-parallel \
    --seed 1024 \
    --served-model-name auto \
    --max-model-len 135000 \
    --max-num-batched-tokens 9728 \
    --max-num-seqs 2 \
    --no-disable-hybrid-kv-cache-manager \
    --no-enable-prefix-caching \
    --safetensors-load-strategy 'prefetch' \
    --trust-remote-code \
    --tokenizer-mode deepseek_v4 \
    --tool-call-parser deepseek_v4 \
    --enable-auto-tool-choice \
    --reasoning-parser deepseek_v4 \
    --gpu-memory-utilization 0.85 \
    --quantization ascend \
    --enforce-eager \
    --additional_config '{"enable_cpu_binding": "True", "callstack_tracing": {"enabled": false, "enable_timing":true, "flush_interval": 100}}' \
    --kv-transfer-config \
    '{"kv_connector": "MooncakeHybridConnector",
    "kv_role": "kv_producer",
    "kv_port": "30000",
    "engine_id": "0",
    "kv_connector_extra_config": {
                "prefill": {
                        "dp_size": 16,
                        "tp_size": 1
                },
                "decode": {
                        "dp_size": 16,
                        "tp_size": 1
                }
        }
    }'
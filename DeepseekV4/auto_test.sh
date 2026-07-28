#!/bin/bash
#=============================================================================
# DeepSeekV4 1P1D 自动化测试脚本
#
# 功能说明:
#   遍历不同的 (dp, tp) 配置，自动拉起P/D实例并运行aisbench性能测试。
#
# 运行方式:
#   在节点 7.246.78.73 上直接运行:
#     bash auto_test.sh
#
#   强制运行 (跳过 IP 检查):
#     bash auto_test.sh --force
#
# 测试流程:
#   对每个 (dp, tp) 配置:
#     1. 停止旧服务
#     2. 更新 run_dp_template.sh 中的 kv_connector_extra_config
#     3. 在 7.246.78.73 上拉起 P 实例 (vllm_deepseek_v4 容器)
#     4. 在 7.246.78.74 上拉起 D 实例 (vllm_deepseek_v4 容器)
#     5. 在 7.246.78.73 上拉起 load_balance_proxy
#     6. 等待服务就绪
#     7. 在 7.246.78.74 的 vllm_performance_test 容器中运行 run.sh (连测两次)
#     8. 停止服务，进入下一个配置
#
# 测试的 dp/tp 配置:
#   (16,1) (8,2) (4,4) (2,8) (1,16)
#   每种配置下 dp * tp = 16 (对应16卡)
#=============================================================================

# 注意: 不使用 set -e，因为部分命令需要处理非零退出码

# ==================== 基础配置 ====================
P_NODE="7.246.78.73"
D_NODE="7.246.78.74"

VLLM_CONTAINER="vllm_deepseek_v4"
TEST_CONTAINER="vllm_performance_test"

# 容器内路径
PD_AUTO_TEST_PATH="/opt/its/z30055003/pd_auto_test"
AISBENCH_PATH="/opt/its/z30055003/aisbench_auto_tools_prefix-main"
DOCKER_SCRIPTS_PATH="/opt/its/z30055003/DeepSeekV4/docker"

# 脚本路径 (容器内)
P_SCRIPT_DIR="${PD_AUTO_TEST_PATH}/DeepseekV4/1P1D/P0"
D_SCRIPT_DIR="${PD_AUTO_TEST_PATH}/DeepseekV4/1P1D/D0"

# 端口配置
DP_RPC_PORT=12321
VLLM_START_PORT=7100
PROXY_PORT=9000

# 结果保存路径 (容器内)
RESULT_BASE="${PD_AUTO_TEST_PATH}/DeepseekV4/test_results"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# 主机临时目录
HOST_TMP="/tmp/dsv4_auto_test_${TIMESTAMP}"
mkdir -p "${HOST_TMP}"

# 最大等待时间 (秒)
MAX_WAIT=900
WAIT_INTERVAL=15

# ==================== 日志函数 ====================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

log_sep() {
    echo ""
    echo "================================================================================"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "================================================================================"
}

# ==================== 远程执行函数 ====================
# 使用 stdin 方式传递命令，避免嵌套引号问题

# 在 P 节点的 vllm 容器内执行命令 (命令通过 stdin 传入)
run_p() {
    docker exec -i "$VLLM_CONTAINER" bash -s <<< "$*"
}

# 在 D 节点的 vllm 容器内执行命令 (命令通过 stdin 传入)
run_d() {
    ssh "$D_NODE" "docker exec -i $VLLM_CONTAINER bash -s" <<< "$*"
}

# 在 D 节点的 test 容器内执行命令 (命令通过 stdin 传入)
run_test_d() {
    ssh "$D_NODE" "docker exec -i $TEST_CONTAINER bash -s" <<< "$*"
}

# ==================== 服务管理函数 ====================

stop_all_services() {
    log_sep "停止所有服务..."

    # 停止 P 节点上的 vllm 进程
    log "停止 P 节点 (${P_NODE}) 上的 vllm 进程..."
    run_p "pkill -9 -f 'vllm serve' 2>/dev/null || true"
    run_p "pkill -9 -f 'launch_online_dp' 2>/dev/null || true"
    run_p "pkill -9 -f 'run_dp_template' 2>/dev/null || true"

    # 停止 D 节点上的 vllm 进程
    log "停止 D 节点 (${D_NODE}) 上的 vllm 进程..."
    run_d "pkill -9 -f 'vllm serve' 2>/dev/null || true"
    run_d "pkill -9 -f 'launch_online_dp' 2>/dev/null || true"
    run_d "pkill -9 -f 'run_dp_template' 2>/dev/null || true"

    # 停止 P 节点上的代理
    log "停止代理..."
    run_p "pkill -9 -f 'load_balance_proxy_server_example' 2>/dev/null || true"

    # 等待进程完全退出
    sleep 10

    # 释放 GPU 资源 (尝试清理，失败不中断)
    log "清理 P 节点 GPU 资源..."
    run_p "for i in \$(seq 0 15); do fuser -k /dev/npu\$i 2>/dev/null; done" 2>/dev/null || true

    log "清理 D 节点 GPU 资源..."
    run_d "for i in \$(seq 0 15); do fuser -k /dev/npu\$i 2>/dev/null; done" 2>/dev/null || true

    sleep 5
    log "所有服务已停止."
}

# 在两个节点上拉起容器 (容器已在运行则跳过)
setup_containers() {
    log_sep "拉起容器..."

    # P 节点: 启动 vllm_deepseek_v4 容器
    if docker ps --format '{{.Names}}' | grep -q "^${VLLM_CONTAINER}$"; then
        log "P 节点 ${VLLM_CONTAINER} 容器已在运行，跳过."
    else
        log "P 节点 (${P_NODE}): 启动 ${VLLM_CONTAINER} 容器..."
        docker rm -f "${VLLM_CONTAINER}" 2>/dev/null || true
        cd "${DOCKER_SCRIPTS_PATH}" && bash start_docker.sh
        log "P 节点 ${VLLM_CONTAINER} 容器已启动."
    fi

    # P 节点: 启动 benchmark 容器
    if docker ps --format '{{.Names}}' | grep -q "^${TEST_CONTAINER}$"; then
        log "P 节点 ${TEST_CONTAINER} 容器已在运行，跳过."
    else
        log "P 节点 (${P_NODE}): 启动 ${TEST_CONTAINER} 容器..."
        docker rm -f "${TEST_CONTAINER}" 2>/dev/null || true
        cd "${DOCKER_SCRIPTS_PATH}" && bash start_docker_benckmark.sh
        log "P 节点 ${TEST_CONTAINER} 容器已启动."
    fi

    # D 节点: 启动 vllm_deepseek_v4 容器
    if ssh "$D_NODE" "docker ps --format '{{.Names}}'" 2>/dev/null | grep -q "^${VLLM_CONTAINER}$"; then
        log "D 节点 ${VLLM_CONTAINER} 容器已在运行，跳过."
    else
        log "D 节点 (${D_NODE}): 启动 ${VLLM_CONTAINER} 容器..."
        ssh "$D_NODE" "docker rm -f ${VLLM_CONTAINER} 2>/dev/null || true"
        ssh "$D_NODE" "cd ${DOCKER_SCRIPTS_PATH} && bash start_docker.sh"
        log "D 节点 ${VLLM_CONTAINER} 容器已启动."
    fi

    # D 节点: 启动 benchmark 容器
    if ssh "$D_NODE" "docker ps --format '{{.Names}}'" 2>/dev/null | grep -q "^${TEST_CONTAINER}$"; then
        log "D 节点 ${TEST_CONTAINER} 容器已在运行，跳过."
    else
        log "D 节点 (${D_NODE}): 启动 ${TEST_CONTAINER} 容器..."
        ssh "$D_NODE" "docker rm -f ${TEST_CONTAINER} 2>/dev/null || true"
        ssh "$D_NODE" "cd ${DOCKER_SCRIPTS_PATH} && bash start_docker_benckmark.sh"
        log "D 节点 ${TEST_CONTAINER} 容器已启动."
    fi

    # 等待容器完全就绪
    sleep 5
    log "所有容器已拉起."
}

update_kv_config() {
    local dp=$1
    local tp=$2

    log "更新 kv_connector_extra_config: dp_size=${dp}, tp_size=${tp}"

    # 创建 sed 脚本文件 (避免嵌套引号问题)
    cat > "${HOST_TMP}/update_kv.sed" << SEDEOF
s/"dp_size": [0-9]*/"dp_size": ${dp}/g
s/"tp_size": [0-9]*/"tp_size": ${tp}/g
SEDEOF

    # 复制到 P 容器并执行
    docker cp "${HOST_TMP}/update_kv.sed" "${VLLM_CONTAINER}:/tmp/update_kv.sed"
    run_p "sed -i -f /tmp/update_kv.sed ${P_SCRIPT_DIR}/run_dp_template.sh"

    # 复制到 D 节点主机, 再 docker cp 到 D 容器
    scp -q "${HOST_TMP}/update_kv.sed" "${D_NODE}:/tmp/update_kv.sed"
    ssh "$D_NODE" "docker cp /tmp/update_kv.sed ${VLLM_CONTAINER}:/tmp/update_kv.sed"
    run_d "sed -i -f /tmp/update_kv.sed ${D_SCRIPT_DIR}/run_dp_template.sh"

    # 验证更新结果
    log "P 节点 kv_connector_extra_config 更新后:"
    run_p "grep -A6 'kv_connector_extra_config' ${P_SCRIPT_DIR}/run_dp_template.sh | head -12" || true

    log "D 节点 kv_connector_extra_config 更新后:"
    run_d "grep -A6 'kv_connector_extra_config' ${D_SCRIPT_DIR}/run_dp_template.sh | head -12" || true

    log "kv_connector_extra_config 更新完成."
}

start_p_instance() {
    local dp=$1
    local tp=$2

    log "在 P 节点 (${P_NODE}) 上拉起 P 实例 (dp=${dp}, tp=${tp})..."

    run_p "cd ${P_SCRIPT_DIR} && nohup python launch_online_dp.py \
        --dp-size ${dp} \
        --tp-size ${tp} \
        --dp-size-local ${dp} \
        --dp-rank-start 0 \
        --dp-address ${P_NODE} \
        --dp-rpc-port ${DP_RPC_PORT} \
        --vllm-start-port ${VLLM_START_PORT} \
        > /tmp/p_instance_dp${dp}_tp${tp}.log 2>&1 &"

    log "P 实例已通过 nohup 启动 (容器内日志: /tmp/p_instance_dp${dp}_tp${tp}.log)"
}

start_d_instance() {
    local dp=$1
    local tp=$2

    log "在 D 节点 (${D_NODE}) 上拉起 D 实例 (dp=${dp}, tp=${tp})..."

    run_d "cd ${D_SCRIPT_DIR} && nohup python launch_online_dp.py \
        --dp-size ${dp} \
        --tp-size ${tp} \
        --dp-size-local ${dp} \
        --dp-rank-start 0 \
        --dp-address ${D_NODE} \
        --dp-rpc-port ${DP_RPC_PORT} \
        --vllm-start-port ${VLLM_START_PORT} \
        > /tmp/d_instance_dp${dp}_tp${tp}.log 2>&1 &"

    log "D 实例已通过 nohup 启动 (容器内日志: /tmp/d_instance_dp${dp}_tp${tp}.log)"
}

start_proxy() {
    local dp=$1

    log "在 P 节点上拉起 load_balance_proxy (dp=${dp})..."

    # 根据 dp 大小生成主机和端口列表
    local prefiller_hosts=""
    local decoder_hosts=""
    local prefiller_ports=""
    local decoder_ports=""

    for (( i=0; i<dp; i++ )); do
        if [ $i -gt 0 ]; then
            prefiller_hosts+=" "
            decoder_hosts+=" "
            prefiller_ports+=" "
            decoder_ports+=" "
        fi
        prefiller_hosts+="${P_NODE}"
        decoder_hosts+="${D_NODE}"
        prefiller_ports+="$(( VLLM_START_PORT + i ))"
        decoder_ports+="$(( VLLM_START_PORT + i ))"
    done

    log "  prefill 实例数: ${dp}, 端口: ${prefiller_ports}"
    log "  decode 实例数: ${dp}, 端口: ${decoder_ports}"

    run_p "cd ${PD_AUTO_TEST_PATH}/DeepseekV4/1P1D && nohup python load_balance_proxy_server_example.py \
        --port ${PROXY_PORT} \
        --host 0.0.0.0 \
        --prefiller-hosts ${prefiller_hosts} \
        --prefiller-ports ${prefiller_ports} \
        --decoder-hosts ${decoder_hosts} \
        --decoder-ports ${decoder_ports} \
        > /tmp/proxy_dp${dp}.log 2>&1 &"

    log "代理已启动 (容器内日志: /tmp/proxy_dp${dp}.log)"
}

# ==================== 服务就绪检测 ====================

check_service_health() {
    local dp=$1

    # 通过代理健康检查端点检测所有实例是否就绪
    local health
    health=$(run_p "curl -s --connect-timeout 5 http://localhost:${PROXY_PORT}/healthcheck" 2>/dev/null || echo "")

    if [ -z "$health" ]; then
        return 1
    fi

    # 检查返回的 JSON 是否包含正确的实例数
    local p_count
    p_count=$(echo "$health" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('prefill_instances',0))" 2>/dev/null || echo "0")
    local d_count
    d_count=$(echo "$health" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('decode_instances',0))" 2>/dev/null || echo "0")

    if [ "$p_count" -eq "$dp" ] 2>/dev/null && [ "$d_count" -eq "$dp" ] 2>/dev/null; then
        return 0
    fi

    return 1
}

wait_for_services() {
    local dp=$1
    local tp=$2

    log_sep "等待服务就绪 (dp=${dp}, tp=${tp}, 最大等待 ${MAX_WAIT}s)..."

    local elapsed=0

    while [ $elapsed -lt $MAX_WAIT ]; do
        if check_service_health "$dp"; then
            log "所有服务就绪! (耗时 ${elapsed}s)"
            # 额外等待确保稳定
            sleep 10
            return 0
        fi

        log "等待中... (${elapsed}s / ${MAX_WAIT}s)"

        # 每60秒打印一次日志尾部用于排查
        if [ $(( elapsed % 60 )) -eq 0 ] && [ $elapsed -gt 0 ]; then
            log "--- P 实例日志尾部 ---"
            run_p "tail -5 /tmp/p_instance_dp${dp}_tp${tp}.log 2>/dev/null" 2>/dev/null || true
            log "--- D 实例日志尾部 ---"
            run_d "tail -5 /tmp/d_instance_dp${dp}_tp${tp}.log 2>/dev/null" 2>/dev/null || true
            log "--- 代理日志尾部 ---"
            run_p "tail -5 /tmp/proxy_dp${dp}.log 2>/dev/null" 2>/dev/null || true
        fi

        sleep $WAIT_INTERVAL
        elapsed=$(( elapsed + WAIT_INTERVAL ))
    done

    log "错误: 服务在 ${MAX_WAIT}s 内未就绪!"
    log "=== P 实例完整日志 ==="
    run_p "cat /tmp/p_instance_dp${dp}_tp${tp}.log 2>/dev/null" 2>/dev/null || true
    log "=== D 实例完整日志 ==="
    run_d "cat /tmp/d_instance_dp${dp}_tp${tp}.log 2>/dev/null" 2>/dev/null || true
    log "=== 代理完整日志 ==="
    run_p "cat /tmp/proxy_dp${dp}.log 2>/dev/null" 2>/dev/null || true
    return 1
}

# ==================== 性能测试 ====================

run_benchmark() {
    local dp=$1
    local tp=$2
    local config_name="dp${dp}_tp${tp}"

    log_sep "开始性能测试: config=${config_name}"

    local config_result_dir="${RESULT_BASE}/${TIMESTAMP}/${config_name}"

    # 在 P 节点的容器内创建结果目录
    run_p "mkdir -p ${config_result_dir}"

    for run_idx in 1 2; do
        local run_name="run_${run_idx}"
        log_sep "执行第 ${run_idx} 次测试: config=${config_name}"

        # 记录服务健康状态 (保存到容器内)
        log "记录服务健康状态..."
        run_p "curl -s http://localhost:${PROXY_PORT}/healthcheck > ${config_result_dir}/health_${run_name}.json 2>/dev/null" 2>/dev/null || true

        # 在 D 节点的 vllm_performance_test 容器中运行测试
        log "在 D 节点 (${D_NODE}) 的 ${TEST_CONTAINER} 容器中运行 run.sh..."

        local test_start=$(date +%s)

        # 运行测试，输出保存到主机临时文件，同时显示在终端
        local host_log="${HOST_TMP}/benchmark_${config_name}_${run_name}.log"
        ssh "$D_NODE" "docker exec ${TEST_CONTAINER} bash -c 'cd ${AISBENCH_PATH} && bash run.sh'" \
            > "${host_log}" 2>&1

        local test_exit_code=$?
        local test_end=$(date +%s)
        local test_duration=$(( test_end - test_start ))

        # 使用 docker cp 将日志从主机复制到容器结果目录
        docker cp "${host_log}" "${VLLM_CONTAINER}:${config_result_dir}/${run_name}.log" 2>/dev/null || {
            log "警告: 无法将日志复制到容器内，保存在主机: ${host_log}"
        }

        # 打印日志尾部摘要
        log "--- 测试日志尾部 (最后20行) ---"
        tail -20 "${host_log}" 2>/dev/null || true
        log "--- 日志尾部结束 ---"

        if [ $test_exit_code -eq 0 ]; then
            log "第 ${run_idx} 次测试完成 (耗时 ${test_duration}s, 退出码: ${test_exit_code})"
        else
            log "警告: 第 ${run_idx} 次测试退出码非零: ${test_exit_code} (耗时 ${test_duration}s)"
            # 采集错误诊断信息
            log "--- 错误诊断: 采集后端日志 ---"
            log "Proxy 健康状态:"
            run_p "curl -s http://localhost:${PROXY_PORT}/healthcheck 2>/dev/null" 2>/dev/null || echo "(无法连接)"
            log "P 节点 vllm 日志 (尾部):"
            run_p "tail -30 /tmp/p_instance_dp${dp}_tp${tp}.log 2>/dev/null" 2>/dev/null || echo "(无日志)"
            log "D 节点 vllm 日志 (尾部):"
            run_d "tail -30 /tmp/d_instance_dp${dp}_tp${tp}.log 2>/dev/null" 2>/dev/null || echo "(无日志)"
            log "Proxy 日志 (尾部):"
            run_p "tail -30 /tmp/proxy_dp${dp}.log 2>/dev/null" 2>/dev/null || echo "(无日志)"
            log "--- 错误诊断结束 ---"
        fi
        log "日志已保存: 容器内 ${config_result_dir}/${run_name}.log"

        # 两次测试之间短暂休息
        if [ $run_idx -eq 1 ]; then
            log "等待 10 秒后执行第二次测试..."
            sleep 10
        fi
    done

    log "配置 ${config_name} 测试全部完成."
}

# ==================== 结果汇总 ====================

generate_summary() {
    log_sep "生成测试汇总..."

    local summary_file="${RESULT_BASE}/${TIMESTAMP}/summary.txt"

    # 先在主机上创建汇总文件，再复制到容器
    local host_summary="${HOST_TMP}/summary.txt"

    cat > "${host_summary}" << SUMMARY_EOF
=============================================================================
DeepSeekV4 1P1D 自动化测试汇总报告
=============================================================================
测试时间: ${TIMESTAMP}
P 节点: ${P_NODE}
D 节点: ${D_NODE}

测试配置:
  (16,1) - dp=16, tp=1  (16 P ranks x 1 GPU, 16 D ranks x 1 GPU)
  (8,2)  - dp=8,  tp=2  (8 P ranks x 2 GPU,  8 D ranks x 2 GPU)
  (4,4)  - dp=4,  tp=4  (4 P ranks x 4 GPU,  4 D ranks x 4 GPU)
  (2,8)  - dp=2,  tp=8  (2 P ranks x 8 GPU,  2 D ranks x 8 GPU)
  (1,16) - dp=1,  tp=16 (1 P rank  x 16 GPU, 1 D rank  x 16 GPU)

结果目录: ${RESULT_BASE}/${TIMESTAMP}/
=============================================================================
SUMMARY_EOF

    # 复制到容器
    docker cp "${host_summary}" "${VLLM_CONTAINER}:${summary_file}" 2>/dev/null || {
        log "警告: 无法将汇总复制到容器，保存在主机: ${host_summary}"
    }

    log "汇总已保存到: ${summary_file}"
}

# ==================== 主流程 ====================

main() {
    log_sep "DeepSeekV4 1P1D 自动化测试开始"
    log "测试时间戳: ${TIMESTAMP}"
    log "P 节点: ${P_NODE}"
    log "D 节点: ${D_NODE}"
    log "主机临时目录: ${HOST_TMP}"

    # 测试配置列表: "dp tp"
    local CONFIGS=(
        "16 1"
        "8 2"
        "4 4"
        "2 8"
        "1 16"
    )

    local total_configs=${#CONFIGS[@]}
    local current_config=0
    local failed_configs=""

    for config in "${CONFIGS[@]}"; do
        current_config=$(( current_config + 1 ))
        local dp=$(echo "$config" | awk '{print $1}')
        local tp=$(echo "$config" | awk '{print $2}')

        log_sep ">>>>>> 测试配置 ${current_config}/${total_configs}: dp=${dp}, tp=${tp} <<<<<<"

        # ---- Step 1: 停止旧服务 ----
        stop_all_services || {
            log "警告: 停止服务时出现错误，继续执行..."
        }

        # ---- Step 2: 更新 kv_connector_extra_config ----
        update_kv_config "$dp" "$tp" || {
            log "错误: 更新 KV 配置失败，跳过此配置."
            failed_configs="${failed_configs} dp${dp}_tp${tp}(kv_update_failed)"
            continue
        }

        # ---- Step 3: 启动 P 实例 ----
        start_p_instance "$dp" "$tp"
        log "等待 30 秒让 P 实例初始化..."
        sleep 30

        # ---- Step 4: 启动 D 实例 ----
        start_d_instance "$dp" "$tp"
        log "等待 30 秒让 D 实例初始化..."
        sleep 30

        # ---- Step 5: 启动代理 ----
        start_proxy "$dp"

        # ---- Step 6: 等待服务就绪 ----
        if ! wait_for_services "$dp" "$tp"; then
            log "错误: 配置 dp=${dp}, tp=${tp} 服务启动失败，跳过测试."
            log "保留日志用于排查:"
            log "  P: 容器内 /tmp/p_instance_dp${dp}_tp${tp}.log"
            log "  D: 容器内 /tmp/d_instance_dp${dp}_tp${tp}.log"
            log "  Proxy: 容器内 /tmp/proxy_dp${dp}.log"
            failed_configs="${failed_configs} dp${dp}_tp${tp}(service_start_failed)"
            continue
        fi

        # ---- Step 7: 运行性能测试 ----
        run_benchmark "$dp" "$tp" || {
            log "警告: 配置 dp=${dp}, tp=${tp} 测试过程中出现错误."
            failed_configs="${failed_configs} dp${dp}_tp${tp}(test_error)"
        }

        log ">>>>>> 配置 ${current_config}/${total_configs} (dp=${dp}, tp=${tp}) 测试完成 <<<<<<"
    done

    # ---- 最终清理 ----
    log_sep "所有配置测试完成，执行最终清理..."
    stop_all_services || true

    # ---- 生成汇总 ----
    generate_summary

    # ---- 最终报告 ----
    log_sep "自动化测试全部结束!"
    log "结果保存在容器内: ${RESULT_BASE}/${TIMESTAMP}/"
    log "主机临时文件: ${HOST_TMP}/"

    if [ -n "$failed_configs" ]; then
        log "警告: 以下配置测试出现问题:${failed_configs}"
        log "请检查对应日志文件排查问题."
    else
        log "所有配置测试均已完成."
    fi

    # 打印结果目录结构
    log ""
    log "结果目录结构:"
    run_p "find ${RESULT_BASE}/${TIMESTAMP} -type f 2>/dev/null | sort" 2>/dev/null || true
}

# ==================== 脚本入口 ====================

# 检查是否在正确的节点上运行
CURRENT_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "")
if [ -z "$CURRENT_IP" ]; then
    CURRENT_IP=$(ip addr show 2>/dev/null | grep 'inet ' | grep -v '127.0.0.1' | head -1 | awk '{print $2}' | cut -d/ -f1)
fi

log "当前节点 IP: ${CURRENT_IP}"
log "主机临时目录: ${HOST_TMP}"

if [ "$1" = "--force" ] || [ "$1" = "-f" ]; then
    log "强制模式: 跳过 IP 检查"
elif ! echo "$CURRENT_IP" | grep -q "7.246.78.73"; then
    log "警告: 当前节点 IP 似乎不是 7.246.78.73."
    log "此脚本设计在 7.246.78.73 节点上运行."
    log "如果确认无误，请使用 --force 或 -f 参数强制运行."
    log "用法: bash auto_test.sh --force"
    exit 1
fi

# 检查必要的依赖
log "检查依赖..."

if ! command -v docker &> /dev/null; then
    log "错误: docker 命令不可用"
    exit 1
fi

if ! command -v ssh &> /dev/null; then
    log "错误: ssh 命令不可用"
    exit 1
fi

if ! command -v scp &> /dev/null; then
    log "错误: scp 命令不可用"
    exit 1
fi

# 拉起所有需要的容器
if [ "$1" = "--skip-setup" ] || [ "$2" = "--skip-setup" ]; then
    log "跳过容器拉起 (--skip-setup)"
else
    log "检查并拉起容器..."
    setup_containers
fi

# 验证 P 节点容器
if ! docker ps --format '{{.Names}}' | grep -q "^${VLLM_CONTAINER}$"; then
    log "错误: P 节点上容器 ${VLLM_CONTAINER} 启动失败"
    exit 1
fi
log "P 节点容器 ${VLLM_CONTAINER} 运行中."

# 检查是否能免密 SSH 到 D 节点
if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "$D_NODE" "echo ok" &> /dev/null; then
    log "错误: 无法免密 SSH 到 D 节点 ${D_NODE}"
    log "请确保 SSH 免密登录已配置"
    exit 1
fi
log "SSH 到 D 节点 (${D_NODE}) 免密登录正常."

# 验证 D 节点容器
if ! ssh "$D_NODE" "docker ps --format '{{.Names}}'" 2>/dev/null | grep -q "^${VLLM_CONTAINER}$"; then
    log "错误: D 节点上容器 ${VLLM_CONTAINER} 启动失败"
    exit 1
fi
log "D 节点容器 ${VLLM_CONTAINER} 运行中."

if ! ssh "$D_NODE" "docker ps --format '{{.Names}}'" 2>/dev/null | grep -q "^${TEST_CONTAINER}$"; then
    log "错误: D 节点上容器 ${TEST_CONTAINER} 启动失败"
    exit 1
fi
log "D 节点容器 ${TEST_CONTAINER} 运行中."

log "所有依赖检查通过."

# 清理函数 - 脚本退出时执行
cleanup_on_exit() {
    log ""
    log "脚本退出，执行清理..."
    log "主机临时文件保留在: ${HOST_TMP} (请手动清理)"
}

trap cleanup_on_exit EXIT

# 执行主流程
main "$@"

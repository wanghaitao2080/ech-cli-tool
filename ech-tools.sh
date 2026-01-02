#!/bin/bash

# ECH Workers Client 一键管理脚本
# 支持系统: Debian / Ubuntu / Armbian / CentOS 7+ / OpenWrt (iStoreOS)
# 功能: 自动安装、配置、服务管理、日志查看

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;36m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
PLAIN='\033[0m'

# 变量定义
REPO_OWNER="byJoey"
REPO_NAME="ech-wk"

# 获取脚本运行目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ECH_DIR="${SCRIPT_DIR}/ech-tools"
# 本地优选域名列表文件
CUSTOM_LIST="${ECH_DIR}/custom_domains.txt"

# 安装路径（使用脚本运行目录下的 ech-tools 文件夹）
BIN_PATH="${ECH_DIR}/ech-workers"
CONF_FILE="${ECH_DIR}/ech-workers.conf"

# 服务文件路径（保持在系统目录）
SERVICE_FILE_SYSTEMD="/etc/systemd/system/ech-workers.service"
SERVICE_FILE_OPENWRT="/etc/init.d/ech-workers"

# 全局变量：是否为 OpenWrt
IS_OPENWRT=0

# 检查是否为 Root 用户
[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}" && exit 1

# 检查系统类型
check_os() {
    if [ -f /etc/openwrt_release ]; then
        IS_OPENWRT=1
    elif [ -f /etc/os-release ] && grep -q "OpenWrt" /etc/os-release;
 then
        IS_OPENWRT=1
    else
        IS_OPENWRT=0
    fi
}

# 检查系统架构
check_arch() {
    ARCH=$(uname -m)
    case $ARCH in
        x86_64)
            ARCH="amd64"
            ;;
        aarch64|armv8)
            ARCH="arm64"
            ;;
        *)
            echo -e "${RED}不支持的架构: $ARCH${PLAIN}"
            exit 1
            ;;
    esac
    echo -e "${GREEN}检测到系统架构: linux-${ARCH}${PLAIN}"
}

# 安装依赖
install_dependencies() {
    echo -e "${YELLOW}正在检查并安装依赖...${PLAIN}"
    check_os
    
    if [ "$IS_OPENWRT" -eq 1 ]; then
        echo -e "${GREEN}检测到 OpenWrt/iStoreOS 系统${PLAIN}"
        echo -e "${YELLOW}正在更新 opkg 软件源...${PLAIN}"
        opkg update
        echo -e "${YELLOW}正在安装依赖 (curl, wget, jq, tar, ca-bundle)...${PLAIN}"
        # 安装 wget-ssl 以支持 https，安装 ca-bundle / ca-certificates
        opkg install curl wget-ssl tar jq ca-bundle ca-certificates
        # 部分固件 wget 可能是 busybox 版本，确保有完整版或 curl 可用
    elif [ -f /etc/debian_version ]; then
        apt-get update -y
        apt-get install -y curl wget tar jq
    elif [ -f /etc/redhat-release ]; then
        yum install -y curl wget tar jq
    else
        echo -e "${RED}无法识别的系统，请手动安装 curl, wget, tar, jq${PLAIN}"
    fi
    
    # 确保 ech-tools 目录存在
    mkdir -p "$ECH_DIR"
}

# 获取配置
load_config() {
    if [ -f "$CONF_FILE" ]; then
        source "$CONF_FILE"
    else
        # 默认配置
        SERVER_ADDR="ech.example.com:443"
        LISTEN_ADDR="0.0.0.0:30000"
        TOKEN=""
        BEST_IP="www.visa.com.sg"
        DNS="dns.alidns.com/dns-query"
        ECH_DOMAIN="cloudflare-ech.com"
        ROUTING="bypass_cn"
    fi
}

# 备份配置

# 优选域名/IP测速
init_custom_domains_if_needed() {
    # 默认列表
    local DEFAULT_DOMAINS=(
        "ip.164746.xyz"
        "cdn.2020111.xyz"
        "bestcf.top"
        "cfip.cfcdn.vip"
        "freeyx.cloudflare88.eu.org"
        "cfip.xxxxxxxx.tk"
        "saas.sin.fan"
        "cf.090227.xyz"
        "cloudflare.182682.xyz"
        "bestcf.030101.xyz"
    )

    if [ ! -s "$CUSTOM_LIST" ]; then
        echo -e "${YELLOW}检测到本地列表为空，正在初始化默认优选域名...${PLAIN}"
        for domain in "${DEFAULT_DOMAINS[@]}"; do
            echo "$domain" >> "$CUSTOM_LIST"
        done
        echo -e "${GREEN}初始化完成${PLAIN}"
    fi
}
# 添加自定义域名/IP (支持批量，逗号或空格分隔)
add_custom_domain() {
    echo -e "${YELLOW}请输入要添加的域名或IP (支持批量，用逗号或空格分隔):${PLAIN}"
    read -p "> " input_str
    
    if [ -z "$input_str" ]; then
        echo "已取消"
        return
    fi
    
    # 将逗号替换为空格，以便按空格分割
    local clean_input=${input_str//,/ }
    # 转为数组
    local new_domains=($clean_input)
    
    local added_count=0
    for domain in "${new_domains[@]}"; do
        if [ -z "$domain" ]; then continue; fi
        
        # 简单的去重检查
        if [ -f "$CUSTOM_LIST" ] && grep -q "^${domain}$" "$CUSTOM_LIST"; then
            echo -e "${RED}已存在: ${domain}${PLAIN}"
        else
            echo "$domain" >> "$CUSTOM_LIST"
            echo -e "${GREEN}添加成功: ${domain}${PLAIN}"
            ((added_count++))
        fi
    done
    
    if [ $added_count -gt 0 ]; then
        echo -e "${GREEN}共添加 $added_count 个条目${PLAIN}"
    fi
}

# 删除自定义域名/IP (支持批量，逗号或空格分隔)
delete_custom_domain() {
    
    if [ ! -f "$CUSTOM_LIST" ] || [ ! -s "$CUSTOM_LIST" ]; then
        echo -e "${RED}自定义列表为空或文件不存在！${PLAIN}"
        return
    fi
    
    echo -e "${YELLOW}当前自定义列表:${PLAIN}"
    # 显示带行号的列表
    nl -w2 -s". " "$CUSTOM_LIST"
    
    echo -e "${YELLOW}--------------------------------${PLAIN}"
    echo -e "请输入要删除的序号，支持批量 (示例: 1,3,5 或 1 3 5)"
    read -p "输入 0 或回车返回: " input_str
    
    if [ -z "$input_str" ] || [[ "$input_str" == "0" ]]; then
        return
    fi
    
    # 将逗号替换为空格
    local clean_input=${input_str//,/ }
    local del_nums=($clean_input)
    
    if [ ${#del_nums[@]} -eq 0 ] || [[ "${del_nums[0]}" == "0" ]]; then
        return
    fi
    
    # 验证输入有效性
    local total_lines=$(wc -l < "$CUSTOM_LIST")
    local valid_nums=()
    
    for num in "${del_nums[@]}"; do
        if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -gt 0 ] && [ "$num" -le "$total_lines" ]; then
            valid_nums+=("$num")
        else
            echo -e "${RED}忽略无效序号: $num${PLAIN}"
        fi
    done
    
    if [ ${#valid_nums[@]} -eq 0 ]; then
        echo -e "${RED}无有效操作${PLAIN}"
        return
    fi
    
    # 排序 (降序)，防止删除前面的行导致后面序号错位
    # 使用 sort -rn 进行数字倒序排序
    local sorted_nums=($(printf "%s\n" "${valid_nums[@]}" | sort -rn | uniq))
    
    echo -e "${YELLOW}正在删除 ${#sorted_nums[@]} 个条目...${PLAIN}"
    
    for num in "${sorted_nums[@]}"; do
        del_content=$(sed -n "${num}p" "$CUSTOM_LIST")
        
        # 执行删除
        if sed --version 2>/dev/null | grep -q GNU; then
            sed -i "${num}d" "$CUSTOM_LIST"
        else
            sed -i '' "${num}d" "$CUSTOM_LIST"
        fi
        echo -e "${GREEN}已删除 [${num}]: $del_content${PLAIN}"
    done
    
    echo -e "${GREEN}批量删除完成${PLAIN}"
}

# 优选域名/IP 管理菜单
manage_best_ip_menu() {
    # 进入菜单时先确保列表已初始化
    init_custom_domains_if_needed
    
    while true; do
        echo -e "========================="
        echo -e "    优选域名/IP 管理"
        echo -e "========================="
        echo -e " ${GREEN}1.${PLAIN} 添加自定义域名/IP"
        echo -e " ${GREEN}2.${PLAIN} 删除自定义域名/IP"
        echo -e " ${GREEN}3.${PLAIN} 查看当前列表 (自定义)"
        echo -e " ${GREEN}4.${PLAIN} 开始测速"
        echo -e " ${GREEN}5.${PLAIN} 返回主菜单"
        echo -e "-------------------------"
        read -p "请输入选择 [1-5]: " sub_choice
        
        case $sub_choice in
            1) 
                add_custom_domain 
                read -p "按回车键继续..."
                ;;
            2) 
                delete_custom_domain 
                read -p "按回车键继续..."
                ;;
            3)
                echo -e "${YELLOW}--- 自定义列表内容 ---${PLAIN}"
                if [ -f "$CUSTOM_LIST" ]; then
                    cat "$CUSTOM_LIST"
                else
                    echo "（空）"
                fi
                echo -e "${YELLOW}----------------------${PLAIN}"
                read -p "按回车键继续..."
                ;;
            4) 
                test_best_ip 
                read -p "按回车键继续..."
                ;;
            5) return ;;
            *) echo -e "${RED}无效选择${PLAIN}" ;;
        esac
    done
}
test_best_ip() {
    echo -e "${YELLOW}============================================${PLAIN}"
    echo -e "${YELLOW}       优选域名/IP测速${PLAIN}"
    echo -e "${YELLOW}============================================${PLAIN}"
    
    
    # ---------------- 1. 准备域名列表 ----------------
    
    
    
    # [列表初始化已移动到菜单入口处统一处理]

    echo -e "${CYAN}[1/3] 正在加载域名列表...${PLAIN}"
    
    declare -a TEST_IPS
    
    # 加载列表 (仅读取 custom_domains.txt)
    if [ -f "$CUSTOM_LIST" ]; then
        echo -e "加载列表: $CUSTOM_LIST"
        mapfile -t CUSTOM_IPS < <(grep -v '^#' "$CUSTOM_LIST" | grep -v '^$' | sed 's/\r$//')
        TEST_IPS+=("${CUSTOM_IPS[@]}")
    else
        echo -e "${RED}错误：列表文件不存在${PLAIN}"
        return
    fi
 
    # 如果总数为空
    if [ ${#TEST_IPS[@]} -eq 0 ]; then
        echo -e "${RED}错误：列表中没有有效域名${PLAIN}"
        return
    fi
    
    # 去重
    mapfile -t TEST_IPS < <(printf "%s\n" "${TEST_IPS[@]}" | awk '!a[$0]++')
    
    COUNT=${#TEST_IPS[@]}
    echo -e "共加载 ${GREEN}${COUNT}${PLAIN} 个待测域名"
    echo -e ""
    
    # ---------------- 2. 全量下载测速 ----------------
    
    # 调整并发数至 2 (因为每个节点内部会有 4 线程, 总线程=8, 避免软路由卡死)
    MAX_CONCURRENT=2
    echo -e "${CYAN}[2/2] 正在进行全量测速 (${MAX_CONCURRENT}节点并发 x 4线程下载)...${PLAIN}"
    echo -e "注意: 多线程测速较耗时且占用带宽,请耐心等待..."
    
    RESULT_FILE="/tmp/ech_speed_test_$$"
    > "$RESULT_FILE"
    
    # 进度条函数
    show_progress() {
        local total=$1
        local pid=$2
        local file=$3
        local delay=0.5
        local spin='-\|/'
        local i=0
        
        # 隐藏光标
        tput civis 2>/dev/null
        
        while kill -0 $pid 2>/dev/null; do
            local done_cnt=0
            [ -f "$file" ] && done_cnt=$(wc -l < "$file")
            
            # 即使文件行数没变，也刷新一下旋转特效
            local percent=0
            if [ $total -gt 0 ]; then
                percent=$((done_cnt * 100 / total))
            fi
            
            # 绘制进度条 [####....]
            local bars=$((percent / 2)) # 50个字符宽
            local spaces=$((50 - bars))
            
            # 使用 printf 动态生成填充
            local bar_str=$(printf "%${bars}s" | tr ' ' '#')
            local space_str=$(printf "%${spaces}s" | tr ' ' '.')
            
            # 旋转字符
            local temp=${spin#?}
            spin=$temp${spin%"$temp"}
            local char=${spin:0:1}
            
            # 打印: \r 清除行首
            printf "\r[${GREEN}%s${PLAIN}%s] %d%% (%d/%d) %s " "$bar_str" "$space_str" "$percent" "$done_cnt" "$total" "$char"
            
            # 防止过快刷新
            sleep $delay
            
            # 如果已完成，跳出循环
            if [ $done_cnt -ge $total ]; then break; fi
        done
        
        # 补全最后一次显示为 100%
        printf "\r[${GREEN}%s${PLAIN}] 100%% (%d/%d) DONE \n" "$(printf "%50s" | tr ' ' '#')" "$total" "$total"
        
        # 恢复光标
        tput cnorm 2>/dev/null
    }
    
    test_single_ip() {
        local ip=$1
        local idx=$2
        
        # 检测是否为 IPv6 地址 (包含 : 且不是纯 IPv4)
        local IS_IPV6=0
        if [[ "$ip" == *:* ]] && ! [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            IS_IPV6=1
        fi
        
        # 1. 尝试获取节点信息 (快速请求)
        local colo="N/A"
        if [ "$IS_IPV6" -eq 1 ]; then
            colo=$(curl -s -m 2 "http://[${ip}]/cdn-cgi/trace" 2>/dev/null | grep "colo=" | cut -d'=' -f2)
        else
            colo=$(curl -s -m 2 "http://${ip}/cdn-cgi/trace" 2>/dev/null | grep "colo=" | cut -d'=' -f2)
        fi
        [ -z "$colo" ] && colo="N/A"
        
        # 2. 丢包测试 (Ping) - IPv6 需要使用 ping6 或 ping -6
        local LOSS="100%"
        local PING_RES
        if [ "$IS_IPV6" -eq 1 ]; then
            # 尝试 ping6 或 ping -6
            if command -v ping6 >/dev/null 2>&1; then
                PING_RES=$(ping6 -c 4 -i 0.2 -W 2 "$ip" 2>&1)
            else
                PING_RES=$(ping -6 -c 4 -i 0.2 -W 2 "$ip" 2>&1)
            fi
        else
            PING_RES=$(ping -c 4 -i 0.2 -W 2 "$ip" 2>&1)
        fi
        if [[ $? -eq 0 ]]; then
            LOSS=$(echo "$PING_RES" | grep -oP '\d+(?=% packet loss)' | head -n1)
            [ -z "$LOSS" ] && LOSS="0"
            LOSS="${LOSS}%"
        else
            LOSS="100%"
        fi
        
        # 3. 4线程并发下载测速 (100MB x 4 = 400MB total cap, but limit time)
        # 为了平衡速度, 每个线程 50MB, 超时 15秒 (全量不需要测 400MB 那么大,太慢)
        local THREAD_BYTES=50000000
        local THREAD_TIMEOUT=15
        
        local CURL_PREFIX="curl"
        # 优化 curl 构造逻辑: 纯 IP 优先使用 --resolve (兼容性最稳), 域名才用 --connect-to
        if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            # IPv4
            CURL_PREFIX="curl --resolve speed.cloudflare.com:443:${ip}"
        elif [ "$IS_IPV6" -eq 1 ]; then
            # IPv6 - 使用 --resolve 并用方括号包裹
            CURL_PREFIX="curl -6 --resolve speed.cloudflare.com:443:[${ip}]"
        elif curl --help all 2>&1 | grep -q "connect-to"; then
            # 域名
            CURL_PREFIX="curl --connect-to speed.cloudflare.com:443:${ip}:443"
        fi
        local TEST_URL="https://speed.cloudflare.com/__down?bytes=${THREAD_BYTES}"
        
        # 定义输出格式: HTTP码|TCP延迟|速度
        local OPTS="-L -o /dev/null -s -w %{http_code}|%{time_connect}|%{speed_download} --connect-timeout 5 -m ${THREAD_TIMEOUT}"
        
        # 启动 4 个线程
        local pids=""
        local tmp_base="/tmp/ech_thread_${$}_${idx}"
        
        for t in 1 2 3 4; do
            ($CURL_PREFIX $OPTS "$TEST_URL" > "${tmp_base}_${t}" 2>/dev/null) &
            pids="$pids $!"
        done
        wait $pids
        
        # 汇总结果
        # 需要取: 任意一个成功的 HTTP code (200), 最小的 TCP latency, 以及 总 Speed
        local final_code="000"
        local min_tcp=9999
        local total_speed=0
        local success_cnt=0
        
        for t in 1 2 3 4; do
            if [ -f "${tmp_base}_${t}" ]; then
                local res=$(cat "${tmp_base}_${t}")
                if [ ! -z "$res" ]; then
                    local code=$(echo "$res" | cut -d'|' -f1)
                    local tcp=$(echo "$res" | cut -d'|' -f2)
                    local spd=$(echo "$res" | cut -d'|' -f3)
                    
                    if [ "$code" == "200" ]; then
                        success_cnt=$((success_cnt + 1))
                        final_code="200"
                        # 找最小延迟
                        # awk 比较浮点数
                        local is_smaller=$(awk -v a="$tcp" -v b="$min_tcp" 'BEGIN {print (a<b)?1:0}')
                        if [ "$is_smaller" -eq 1 ]; then min_tcp=$tcp; fi
                        
                        # 累加速度
                        total_speed=$(awk -v a="$total_speed" -v b="$spd" 'BEGIN {printf "%.0f", a+b}')
                    fi
                fi
                rm -f "${tmp_base}_${t}"
            fi
        done
        
        if [ "$final_code" == "200" ] && [ "$success_cnt" -gt 0 ]; then
             # 计算延迟 (秒 -> 毫秒)
             local latency=$(awk -v t="$min_tcp" 'BEGIN {printf "%.0f", t * 1000}')
             
             # 计算速度 (Bps -> MB/s)
             local speed_mb=$(awk -v speed="$total_speed" 'BEGIN {printf "%.2f", speed / 1024 / 1024}')
             
             # 输出: idx|ip|latency|speed_mb|colo|loss
             echo "${idx}|${ip}|${latency}|${speed_mb}|${colo}|${LOSS}" >> "$RESULT_FILE"
        else
             # 失败
             echo "${idx}|${ip}|99999|0.00|${colo}|${LOSS}" >> "$RESULT_FILE"
        fi
    }
    
    # 启动进度条 (后台运行)
    # 传入当前Shell PID，以便在Shell退出时进度条也能退出
    show_progress "$COUNT" "$$" "$RESULT_FILE" &
    PID_PROGRESS=$!
    
    # 动态并发执行
    INDEX=0
    for ip in "${TEST_IPS[@]}"; do
        INDEX=$((INDEX + 1))
        test_single_ip "$ip" "$INDEX" &
        
        # 动态控制并发数: 如果后台任务数 >= MAX，则等待
        while [ $(jobs -r | wc -l) -ge $MAX_CONCURRENT ]; do
            sleep 0.2
        done
    done
    wait
    
    # 确保进度条结束
    sleep 0.5
    kill "$PID_PROGRESS" 2>/dev/null
    wait "$PID_PROGRESS" 2>/dev/null
    
    echo -e " 完成"
    echo -e ""
    
    # 解析结果并排序 (按速度倒序)
    declare -a SORTED_RESULTS
    # 排序逻辑: 按第4列(速度)数字倒序, 然后按第3列(延迟)数字升序
    mapfile -t SORTED_RESULTS < <(sort -t'|' -k4,4nr -k3,3n "$RESULT_FILE")
    
    # ---------------- 3. 显示结果 ----------------
    
    echo -e "${YELLOW}---------------------------------------------------------------------------------${PLAIN}"
    printf "${CYAN}%-4s %-40s %-10s %-8s %-10s %-12s${PLAIN}\n" "排名" "域名/IP" "节点" "丢包" "延迟(TCP)" "速度(4线程)"
    echo -e "${YELLOW}---------------------------------------------------------------------------------${PLAIN}"
    
    declare -a TOP_IPS
    RANK=0
    BEST_IP_FINAL=""
    BEST_INFO_FINAL=""
    
    for line in "${SORTED_RESULTS[@]}"; do
        IFS='|' read -r idx ip latency speed colo loss <<< "$line"
        RANK=$((RANK + 1))
        
        # 速度颜色
        raw_speed=$(awk -v s="$speed" 'BEGIN {print int(s * 100)}')
        if [ "$raw_speed" -ge 500 ]; then # 5MB/s
            SPEED_COLOR="${GREEN}"
        elif [ "$raw_speed" -ge 100 ]; then # 1MB/s
            SPEED_COLOR="${YELLOW}"
        else
            SPEED_COLOR="${RED}"
        fi
        
        if [ "$speed" == "0.00" ]; then
            SPEED_VAL="失败"
            SPEED_COLOR="${RED}"
            latency="-"
        else
            SPEED_VAL="${speed} MB/s"
        fi
        
        # 丢包颜色
        LOSS_VAL="${loss}"
        if [[ "$loss" == "0%" ]]; then
            LOSS_COLOR="${GREEN}"
        elif [[ "$loss" == "100%" ]]; then
            LOSS_COLOR="${RED}"
        else
            LOSS_COLOR="${YELLOW}"
        fi

        # 延迟颜色
        if [ "$latency" == "-" ]; then
             LAT_COLOR="${RED}"
        elif [ "$latency" -lt 100 ]; then # 100ms 以内绿色
             LAT_COLOR="${GREEN}"
             latency="${latency}ms"
        elif [ "$latency" -lt 200 ]; then
             LAT_COLOR="${YELLOW}"
             latency="${latency}ms"
        else
             LAT_COLOR="${RED}"
             latency="${latency}ms"
        fi

        printf "${SPEED_COLOR}%-4s${PLAIN} %-40s %-10s ${LOSS_COLOR}%-8s${PLAIN} ${LAT_COLOR}%-10s${PLAIN} ${SPEED_COLOR}%-12s${PLAIN}\n" \
            "${RANK}" "${ip}" "${colo}" "${LOSS_VAL}" "${latency}" "${SPEED_VAL}"
            
        TOP_IPS+=("$ip")
        
        # 记录第一名作为推荐
        if [ "$RANK" -eq 1 ]; then
            if [ "$speed" != "0.00" ]; then
                BEST_IP_FINAL="$ip"
                BEST_INFO_FINAL="${speed} MB/s (4线程)"
            fi
        fi
    done
    
    echo -e "${YELLOW}---------------------------------------------------------------------------------${PLAIN}"
    rm -f "$RESULT_FILE"
    
    if [ -z "$BEST_IP_FINAL" ]; then
        echo -e "${RED}所有域名测速失败${PLAIN}"
        return
    fi
    
    echo -e ""
    echo -e "${GREEN}★ 智能推荐: ${BEST_IP_FINAL} [${BEST_INFO_FINAL}]${PLAIN}"
    echo -e ""
    
    # 允许选择任意排名
    echo -e "${CYAN}提示: 输入 y 使用推荐 / 输入排名编号 (如 1, 2...) / 回车取消${PLAIN}"
    read -p "请选择: " confirm
    
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        SELECTED_IP="$BEST_IP_FINAL"
    elif [[ "$confirm" =~ ^[0-9]+$ ]]; then
        idx=$((confirm - 1))
        # 检查索引是否有效
        if [ "$idx" -ge 0 ] && [ "$idx" -lt ${#TOP_IPS[@]} ]; then
            SELECTED_IP="${TOP_IPS[$idx]}"
        else
            echo -e "${RED}编号无效${PLAIN}"
            return
        fi
    else
        echo -e "${YELLOW}已取消${PLAIN}"
        return
    fi
    
    echo -e "${GREEN}已选择: ${SELECTED_IP}${PLAIN}"
    
    # 应用配置
    BEST_IP="$SELECTED_IP"
    save_config
    create_service
    
    read -p "是否立即重启服务生效？[y/N]: " restart_now
    if [[ "$restart_now" == "y" || "$restart_now" == "Y" ]]; then
        svc_restart
        echo -e "${GREEN}服务已重启！${PLAIN}"
    fi
}

# 状态检查
status_check() {
    echo -e "${YELLOW}执行状态检查...${PLAIN}"
    
    # 确保配置已加载
    load_config
    check_os
    
    # 检查进程
    if svc_is_active; then
        echo -e "  服务状态: ${GREEN}运行中${PLAIN}"
    else
        echo -e "  服务状态: ${RED}未运行${PLAIN}"
        read -p "服务未运行，是否启动？[y/N]: " confirm
        if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
            svc_start
        fi
        return
    fi
    
    # 检查端口 - 从 LISTEN_ADDR 提取端口号
    if [ -z "$LISTEN_ADDR" ]; then
        echo -e "  端口监听: ${RED}配置异常 (LISTEN_ADDR 未设置)${PLAIN}"
        return
    fi
    
    # 提取端口号
    CONF_PORT=$(echo "$LISTEN_ADDR" | grep -oE '[0-9]+$')
    if [ -z "$CONF_PORT" ]; then
        echo -e "  端口监听: ${RED}无法解析端口 (LISTEN_ADDR=$LISTEN_ADDR)${PLAIN}"
        return
    fi
    
    echo -e "  监听地址: ${CYAN}$LISTEN_ADDR${PLAIN}"
    
    # 检查端口是否监听
    PORT_OK=0
    if command -v ss >/dev/null 2>&1; then
        if ss -ln | grep -q ":${CONF_PORT} \|:${CONF_PORT}$"; then
            PORT_OK=1
        fi
    elif command -v netstat >/dev/null 2>&1; then
        if netstat -ln | grep -q ":${CONF_PORT} \|:${CONF_PORT}$"; then
            PORT_OK=1
        fi
    else
        PORT_OK=2
    fi
    
    if [ "$PORT_OK" -eq 1 ]; then
        echo -e "  端口监听: ${GREEN}正常${PLAIN}"
    elif [ "$PORT_OK" -eq 0 ]; then
        echo -e "  端口监听: ${RED}异常 - 端口 $CONF_PORT 未监听${PLAIN}"
        return
    else
        echo -e "  端口监听: ${YELLOW}无法检测${PLAIN}"
    fi
    
    # 测试代理连接 - 使用轻量级请求
    echo -e "  测试代理连接..."
    
    # 测试 1: 使用 curl 通过代理获取 IP 和归属地
    TEST_OK=0
    PROXY_IP=""
    IP_INFO=""
    
    # 尝试通过 ip.sb 获取 IP 和详细信息
    IP_RESULT=$(curl -x socks5h://127.0.0.1:$CONF_PORT -s -m 8 "https://api.ip.sb/geoip" 2>/dev/null)
    if [ ! -z "$IP_RESULT" ]; then
        PROXY_IP=$(echo "$IP_RESULT" | grep -oE '"ip":"[^"]+"' | cut -d'"' -f4)
        IP_COUNTRY=$(echo "$IP_RESULT" | grep -oE '"country":"[^"]+"' | cut -d'"' -f4)
        IP_CITY=$(echo "$IP_RESULT" | grep -oE '"city":"[^"]+"' | cut -d'"' -f4)
        IP_ISP=$(echo "$IP_RESULT" | grep -oE '"isp":"[^"]+"' | cut -d'"' -f4)
        IP_ORG=$(echo "$IP_RESULT" | grep -oE '"organization":"[^"]+"' | cut -d'"' -f4)
        
        if [ ! -z "$PROXY_IP" ]; then
            TEST_OK=1
            # 构建归属地信息
            if [ ! -z "$IP_COUNTRY" ]; then
                IP_INFO="$IP_COUNTRY"
                # 只有当城市与国家不同时才追加城市
                if [ ! -z "$IP_CITY" ] && [ "$IP_CITY" != "$IP_COUNTRY" ]; then
                    IP_INFO="$IP_INFO $IP_CITY"
                fi
            fi
            [ ! -z "$IP_ISP" ] && IP_INFO="$IP_INFO | $IP_ISP"
            [ -z "$IP_ISP" ] && [ ! -z "$IP_ORG" ] && IP_INFO="$IP_INFO | $IP_ORG"
        fi
    fi
    
    # 备用方案：httpbin
    if [ "$TEST_OK" -eq 0 ]; then
        PROXY_IP=$(curl -x socks5h://127.0.0.1:$CONF_PORT -s -m 8 "https://httpbin.org/ip" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        if [ ! -z "$PROXY_IP" ]; then
            TEST_OK=1
        fi
    fi
    
    if [ "$TEST_OK" -eq 1 ]; then
        echo -e "  优选出口: ${GREEN}$PROXY_IP${PLAIN}"
        if [ ! -z "$IP_INFO" ]; then
            echo -e "  IP 归属: ${CYAN}$IP_INFO${PLAIN}"
        fi
        
        # 额外测试 Cloudflare CDN 站点（通过 ProxyIP 访问）
        echo -e "  ${YELLOW}--- CF 反代测试 ---${PLAIN}"
        CF_RESULT=$(curl -x socks5h://127.0.0.1:$CONF_PORT -s -m 5 "https://cloudflare.com/cdn-cgi/trace" 2>/dev/null)
        if echo "$CF_RESULT" | grep -q "warp="; then
            CF_IP=$(echo "$CF_RESULT" | grep "ip=" | cut -d'=' -f2)
            CF_COLO=$(echo "$CF_RESULT" | grep "colo=" | cut -d'=' -f2)
            CF_LOC=$(echo "$CF_RESULT" | grep "loc=" | cut -d'=' -f2)
            
            if [ ! -z "$CF_IP" ]; then
                echo -e "  反代出口: ${GREEN}$CF_IP${PLAIN}"
            fi
            if [ ! -z "$CF_LOC" ] && [ ! -z "$CF_COLO" ]; then
                echo -e "  CF 节点: ${CYAN}$CF_LOC ($CF_COLO)${PLAIN}"
            elif [ ! -z "$CF_COLO" ]; then
                echo -e "  CF 节点: ${CYAN}$CF_COLO${PLAIN}"
            fi
        else
            echo -e "  反代状态: ${RED}失败${PLAIN}"
            echo -e "${YELLOW}可能原因: ProxyIP 配置错误或不可用${PLAIN}"
        fi
    else
        echo -e "  优选测试: ${RED}失败${PLAIN}"
        echo -e ""
        echo -e "${YELLOW}=== 故障排查 ===${PLAIN}"
        echo -e "  1. 检查服务端地址是否正确: ${CYAN}$SERVER_ADDR${PLAIN}"
        echo -e "  2. 检查 Token 是否与服务端一致"
        echo -e "  3. 检查网络连接是否正常"
        echo -e "  4. 查看日志: ${CYAN}journalctl -u ech-workers -n 50${PLAIN}"
    fi
}

# 保存配置
save_config() {
    cat > "$CONF_FILE" <<EOF
SERVER_ADDR="$SERVER_ADDR"
LISTEN_ADDR="$LISTEN_ADDR"
TOKEN="$TOKEN"
BEST_IP="$BEST_IP"
DNS="$DNS"
ECH_DOMAIN="$ECH_DOMAIN"
ROUTING="$ROUTING"
EOF
}

# 生成 OpenWrt Procd 服务文件
create_service_openwrt() {
    cat > "$SERVICE_FILE_OPENWRT" <<EOF
#!/bin/sh /etc/rc.common

START=99
USE_PROCD=1

CONF_FILE="$CONF_FILE"
BIN_PATH="$BIN_PATH"

start_service() {
    if [ -f "\$CONF_FILE" ]; then
        . "\$CONF_FILE"
    else
        echo "Config file not found!"
        return 1
    fi

    procd_open_instance
    procd_set_param command \$BIN_PATH
    procd_append_param command -f "\$SERVER_ADDR"
    procd_append_param command -l "\$LISTEN_ADDR"
    procd_append_param command -token "\$TOKEN"
    procd_append_param command -ip "\$BEST_IP"
    procd_append_param command -dns "\$DNS"
    procd_append_param command -ech "\$ECH_DOMAIN"
    procd_append_param command -routing "\$ROUTING"
    
    procd_set_param respawn
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}
EOF
    chmod +x "$SERVICE_FILE_OPENWRT"
    /etc/init.d/ech-workers enable >/dev/null 2>&1
}

# 生成 Systemd 服务文件
create_service_systemd() {
    cat > "$SERVICE_FILE_SYSTEMD" <<EOF
[Unit]
Description=ECH Workers Client Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${ECH_DIR}
ExecStart=${BIN_PATH} -f ${SERVER_ADDR} -l ${LISTEN_ADDR} -token ${TOKEN} -ip ${BEST_IP} -dns ${DNS} -ech ${ECH_DOMAIN} -routing ${ROUTING}
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable ech-workers >/dev/null 2>&1
}

# 统一创建服务入口
create_service() {
    if [ "$IS_OPENWRT" -eq 1 ]; then
        create_service_openwrt
    else
        create_service_systemd
    fi
}

# 服务操作封装
svc_start() {
    if [ "$IS_OPENWRT" -eq 1 ]; then
        /etc/init.d/ech-workers start
    else
        systemctl start ech-workers
    fi
}

svc_stop() {
    if [ "$IS_OPENWRT" -eq 1 ]; then
        /etc/init.d/ech-workers stop
    else
        systemctl stop ech-workers
    fi
}

svc_restart() {
    if [ "$IS_OPENWRT" -eq 1 ]; then
        /etc/init.d/ech-workers restart
    else
        systemctl restart ech-workers
    fi
}

svc_disable() {
    if [ "$IS_OPENWRT" -eq 1 ]; then
        /etc/init.d/ech-workers disable
    else
        systemctl disable ech-workers
    fi
}

svc_is_active() {
    if [ "$IS_OPENWRT" -eq 1 ]; then
        # OpenWrt 检查进程是否存在
        if pgrep -f "$BIN_PATH" >/dev/null; then
            return 0
        else
            return 1
        fi
    else
        systemctl is-active --quiet ech-workers
    fi
}

# 安装/更新
install_ech() {
    install_dependencies
    check_arch
    
    echo -e "${YELLOW}正在获取最新版本信息...${PLAIN}"
    
    # 先检测网络环境
    IS_CN=0
    if ! curl -s -m 2 https://www.google.com >/dev/null; then
        IS_CN=1
        echo -e "${YELLOW}网络环境: 中国大陆 (或无法访问 Google)，使用镜像加速${PLAIN}"
    else
        echo -e "${GREEN}网络环境: 国际互联${PLAIN}"
    fi
    
    # 根据网络环境选择 API 地址
    if [ "$IS_CN" -eq 1 ]; then
        API_URL="https://gh-proxy.org/https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases/latest"
    else
        API_URL="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases/latest"
    fi
    
    # 获取 Release JSON
    RELEASE_JSON=$(curl -s "$API_URL")
    
    # 尝试使用 jq 解析
    LATEST_URL=""
    if command -v jq >/dev/null 2>&1; then
        LATEST_URL=$(echo "$RELEASE_JSON" | jq -r ".assets[] | select(.name | contains(\"linux-${ARCH}\")) | .browser_download_url" 2>/dev/null | head -n 1)
    fi
    
    # 如果 jq 失败或未安装，使用 fallback 解析
    if [[ -z "$LATEST_URL" || "$LATEST_URL" == "null" ]]; then
        LATEST_URL=$(echo "$RELEASE_JSON" | grep "browser_download_url" | grep "linux-${ARCH}" | head -n 1 | cut -d '"' -f 4)
    fi
    
    # 如果 API 完全失败，使用硬编码的最新已知版本
    if [[ -z "$LATEST_URL" || "$LATEST_URL" == "null" ]]; then
        echo -e "${YELLOW}API 获取失败，使用备用下载链接...${PLAIN}"
        LATEST_URL="https://github.com/byJoey/ech-wk/releases/download/v1.4/ECHWorkers-linux-${ARCH}-softrouter.tar.gz"
    fi
    
    # 国内环境添加代理前缀
    if [ "$IS_CN" -eq 1 ]; then
        # 避免重复添加代理前缀
        if [[ "$LATEST_URL" != *"gh-proxy.org"* ]]; then
            LATEST_URL="https://gh-proxy.org/${LATEST_URL}"
        fi
    fi
    
    echo -e "${GREEN}下载链接: $LATEST_URL${PLAIN}"
    
    wget --no-check-certificate -O /tmp/ech-workers.tar.gz "$LATEST_URL"
    if [ $? -ne 0 ]; then
        echo -e "${RED}下载失败！${PLAIN}"
        return
    fi
    
    # 解压
    mkdir -p /tmp/ech_install
    tar -zxvf /tmp/ech-workers.tar.gz -C /tmp/ech_install
    
    # 安装
    # 假设解压后文件在根目录或 bin 目录，这里暴力查找一下
    FIND_BIN=$(find /tmp/ech_install -type f -name "ech-workers" | head -n 1)
    if [ -f "$FIND_BIN" ]; then
        mv "$FIND_BIN" "$BIN_PATH"
        chmod +x "$BIN_PATH"
        echo -e "${GREEN}安装成功！${PLAIN}"
        rm -rf /tmp/ech-workers.tar.gz /tmp/ech_install
        
        # 如果是首次安装，提示配置
        if [ ! -f "$CONF_FILE" ]; then
            echo -e "${YELLOW}检测到首次安装，开始初始化配置...${PLAIN}"
            configure_ech
        else
            load_config
            create_service
            echo -e "${GREEN}服务已更新，正在重启...${PLAIN}"
            svc_restart
        fi

        # 创建快捷指令
        create_shortcut
    else
        echo -e "${RED}解压后未找到二进制文件，安装失败${PLAIN}"
    fi
}

# 创建快捷指令
create_shortcut() {
    # 获取脚本的绝对路径
    SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
    cat > /usr/bin/ech <<EOF
#!/bin/bash
bash "${SCRIPT_PATH}"
EOF
    chmod +x /usr/bin/ech
    echo -e "${GREEN}快捷指令 'ech' 已创建，以后输入 ech 即可启动此脚本！${PLAIN}"
}

# 配置菜单
configure_ech() {
    load_config
    echo -e "========================="
    echo -e "      配置向导"
    echo -e "========================="
    
    read -p "请输入 服务端地址 (当前: $SERVER_ADDR): " input
    [ ! -z "$input" ] && SERVER_ADDR="$input"
    
    read -p "请输入 本地监听地址 (当前: $LISTEN_ADDR): " input
    [ ! -z "$input" ] && LISTEN_ADDR="$input"
    
    read -p "请输入 Token (当前: $TOKEN): " input
    [ ! -z "$input" ] && TOKEN="$input"
    
    read -p "请输入 优选域名/IP (当前: $BEST_IP): " input
    [ ! -z "$input" ] && BEST_IP="$input"

    read -p "请输入 DOH服务器 (当前: $DNS): " input
    [ ! -z "$input" ] && DNS="$input"
    
    read -p "请输入 分流模式 (global/bypass_cn/none) (当前: $ROUTING): " input
    [ ! -z "$input" ] && ROUTING="$input"
    
    save_config
    create_service
    echo -e "${GREEN}配置已保存并应用！${PLAIN}"
    
    read -p "是否立即重启服务生效？[y/N]: " restart_now
    if [[ "$restart_now" == "y" || "$restart_now" == "Y" ]]; then
        svc_restart
        check_status
    fi
}

# 检查系统信息
get_sys_info() {
    if [ -f /etc/openwrt_release ]; then
        # 直接 source 文件读取变量，兼容性最好 (忽略错误输出)
        # 使用子 shell 避免污染当前环境
        OS=$(
            . /etc/openwrt_release >/dev/null 2>&1
            echo "$DISTRIB_DESCRIPTION" | awk '{print $1,$2}'
        )
        # 如果获取失败，回退到默认
        [ -z "$OS" ] && OS="OpenWrt"
    elif [ -f /etc/os-release ]; then
        OS=$(grep -oP 'PRETTY_NAME="\K[^"]+' /etc/os-release 2>/dev/null)
        # 如果 grep -P 不支持，尝试 source 方式
        if [ -z "$OS" ]; then
            OS=$(
                . /etc/os-release >/dev/null 2>&1
                echo "$PRETTY_NAME"
            )
        fi
    else
        OS=$(uname -s)
    fi
    ARCH=$(uname -m)
    KERNEL=$(uname -r)
}

# 检查状态
check_status() {
    get_sys_info
    if svc_is_active; then
        STATUS="${GREEN}运行中${PLAIN}"
        PID=$(pgrep -f $BIN_PATH | head -n 1)
        
        # 尝试获取格式化运行时长
        RUN_TIME=$(ps -o etime= -p $PID 2>/dev/null | tr -d ' ')
        
        # 如果 ps 不支持 etime (常见于 OpenWrt/Busybox)
        if [ -z "$RUN_TIME" ] && [ -f "/proc/$PID/stat" ]; then
            UPTIME_SEC=$(cat /proc/uptime | awk '{print int($1)}')
            # 第22位是启动时的 jiffies
            START_TICKS=$(cat /proc/$PID/stat | awk '{print $22}')
            # 获取系统每秒 ticks (通常为 100)
            CLK_TCK=$(getconf CLK_TCK 2>/dev/null || echo 100)
            START_SEC=$((START_TICKS / CLK_TCK))
            DIFF_SEC=$((UPTIME_SEC - START_SEC))
            
            if [ $DIFF_SEC -lt 0 ]; then DIFF_SEC=0; fi
            H=$((DIFF_SEC / 3600))
            M=$(( (DIFF_SEC % 3600) / 60 ))
            S=$((DIFF_SEC % 60))
            RUN_TIME=$(printf "%02d:%02d:%02d" $H $M $S)
        fi
        
        [ -z "$RUN_TIME" ] && RUN_TIME="Running"
    else
        STATUS="${RED}未运行${PLAIN}"
        PID="N/A"
        RUN_TIME="N/A"
    fi
}

# 获取日志
view_logs() {
    # 尝试提取端口
    CONF_PORT=${LISTEN_ADDR##*:}
    
    echo -e "------------------------------------------------------"
    echo -e "${YELLOW}>>> 当前活跃连接统计${PLAIN}"
    
    CLIENTS=""
    if command -v ss >/dev/null 2>&1; then
        CLIENTS=$(ss -an state established | grep ":$CONF_PORT" | awk '{print $5}' | sed 's/\\[//g; s/\\]//g' | rev | cut -d: -f2- | rev | sort | uniq | grep -v "127.0.0.1")
    elif command -v netstat >/dev/null 2>&1; then
        CLIENTS=$(netstat -an | grep ":$CONF_PORT" | grep ESTABLISHED | awk '{print $5}' | sed 's/\\[//g; s/\\]//g' | rev | cut -d: -f2- | rev | sort | uniq | grep -v "127.0.0.1")
    fi
    
    # 统计数量
    COUNT=$(echo "$CLIENTS" | sed '/^$/d' | wc -l)
    
    if [ "$COUNT" -eq "0" ] || [ -z "$CLIENTS" ]; then
         echo -e "当前无活跃客户端连接"
    else
         echo -e "在线客户端数: ${GREEN}$COUNT${PLAIN}"
         echo -e "客户端列表:"
         
         # 循环查询 IP 归属地
         while read -r ip; do
             if [ ! -z "$ip" ]; then
                 clean_ip=$(echo "$ip" | sed 's/:[0-9]*$//')
                 LOCATION=$(curl -s -m 2 "http://ip-api.com/line/${clean_ip}?fields=country,regionName,city,isp&lang=zh-CN")
                 if [ ! -z "$LOCATION" ]; then
                     LOC_STR=$(echo "$LOCATION" | tr '\n' ' ' | sed 's/ $//')
                     echo -e " ${CYAN}$ip${PLAIN} 	-> ${YELLOW}[$LOC_STR]${PLAIN}"
                 else
                     echo -e " ${CYAN}$ip${PLAIN} 	-> ${RED}[位置查询超时]${PLAIN}"
                 fi
             fi
         done <<< "$CLIENTS"
    fi
    echo -e "------------------------------------------------------"

    echo -e "${YELLOW}正在获取最后 50 行日志 (按 Ctrl+C 退出)...${PLAIN}"
    if [ "$IS_OPENWRT" -eq 1 ]; then
        logread -e "ech-workers" | tail -n 50
        echo -e "${YELLOW}(OpenWrt 请使用 'logread -f -e ech-workers' 查看实时日志)${PLAIN}"
    else
        journalctl -u ech-workers -n 50 -f
    fi
}

# 脚本版本
SCRIPT_VER="v1.3.0"

# 版本号比较函数：判断 $1 是否大于 $2
# 返回 0 表示 $1 > $2，返回 1 表示 $1 <= $2
version_gt() {
    # 去掉 v 前缀
    local v1="${1#v}"
    local v2="${2#v}"
    
    # 纯 Shell 实现版本比较，兼容 BusyBox
    local IFS='.'
    set -- $v1
    local v1_major=${1:-0} v1_minor=${2:-0} v1_patch=${3:-0}
    set -- $v2
    local v2_major=${1:-0} v2_minor=${2:-0} v2_patch=${3:-0}
    
    # 逐位比较
    if [ "$v1_major" -gt "$v2_major" ] 2>/dev/null; then return 0; fi
    if [ "$v1_major" -lt "$v2_major" ] 2>/dev/null; then return 1; fi
    if [ "$v1_minor" -gt "$v2_minor" ] 2>/dev/null; then return 0; fi
    if [ "$v1_minor" -lt "$v2_minor" ] 2>/dev/null; then return 1; fi
    if [ "$v1_patch" -gt "$v2_patch" ] 2>/dev/null; then return 0; fi
    
    return 1
}

check_script_update() {
    # 如果已有缓存结果，直接使用
    if [ ! -z "$UPDATE_TIP" ]; then return; fi
    
    UPDATE_TMP="/tmp/ech_update_check"
    UPDATE_TMP_TIME="/tmp/ech_update_time"
    
    # 检查缓存是否过期（1小时 = 3600秒）
    CACHE_EXPIRED=1
    if [ -f "$UPDATE_TMP" ] && [ -f "$UPDATE_TMP_TIME" ]; then
        CACHE_TIME=$(cat "$UPDATE_TMP_TIME" 2>/dev/null || echo 0)
        NOW_TIME=$(date +%s)
        DIFF=$((NOW_TIME - CACHE_TIME))
        if [ "$DIFF" -lt 3600 ] 2>/dev/null; then
            CACHE_EXPIRED=0
        fi
    fi
    
    if [ "$CACHE_EXPIRED" -eq 1 ]; then
        # 同步获取版本（最多等待 3 秒）
        CHECK_URL="https://raw.githubusercontent.com/lzban8/ech-tools/main/ech-tools.sh"
        if ! curl -s -m 2 --head https://raw.githubusercontent.com >/dev/null 2>&1; then
            CHECK_URL="https://gh-proxy.org/https://raw.githubusercontent.com/lzban8/ech-tools/main/ech-tools.sh"
        fi
        
        REMOTE_VERSION=$(curl -s -m 3 "$CHECK_URL" 2>/dev/null | grep 'SCRIPT_VER="' | head -n 1 | cut -d '"' -f 2)
        if [ ! -z "$REMOTE_VERSION" ]; then
            echo "$REMOTE_VERSION" > "$UPDATE_TMP"
            date +%s > "$UPDATE_TMP_TIME"
        fi
    else
        REMOTE_VERSION=$(cat "$UPDATE_TMP" 2>/dev/null)
    fi
    
    # 判断版本
    if [ -z "$REMOTE_VERSION" ]; then
        UPDATE_TIP="${YELLOW}检查失败${PLAIN}"
        CAN_UPDATE=0
    elif version_gt "$REMOTE_VERSION" "$SCRIPT_VER"; then
        UPDATE_TIP="${GREEN}新版本: ${REMOTE_VERSION}${PLAIN}"
        CAN_UPDATE=1
    else
        UPDATE_TIP="${GREEN}最新${PLAIN}"
        CAN_UPDATE=0
    fi
}

# 更新脚本
update_script() {
    CURRENT_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
    wget --no-check-certificate -O "$CURRENT_SCRIPT" "https://raw.githubusercontent.com/lzban8/ech-tools/main/ech-tools.sh" && chmod +x "$CURRENT_SCRIPT"
    echo -e "${GREEN}脚本更新成功！请重新运行脚本。${PLAIN}"
    exit 0
}

# 卸载脚本和客户端
uninstall_all() {
    echo -e "${YELLOW}警告：此操作将彻底卸载 ECH 客户端服务，并删除脚本文件及所有配置！${PLAIN}"
    echo -e "${RED}所有数据将被清除且不可恢复。${PLAIN}"
    read -p "确定要继续吗？[y/N]: " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        # 1. 停止并禁用服务
        echo -e "${YELLOW}正在停止服务...${PLAIN}"
        svc_stop >/dev/null 2>&1
        svc_disable >/dev/null 2>&1
        
        # 2. 删除服务文件
        echo -e "${YELLOW}正在清理文件...${PLAIN}"
        rm -f "$SERVICE_FILE_SYSTEMD" "$SERVICE_FILE_OPENWRT"
        if [ "$IS_OPENWRT" -eq 0 ]; then
            systemctl daemon-reload >/dev/null 2>&1
        fi
        
        # 3. 删除二进制和配置
        rm -f "$BIN_PATH" "$CONF_FILE"
        
        # 4. 删除快捷指令
        rm -f /usr/bin/ech
        
        # 5. 删除脚本自身
        SCRIPT_PATH=$(readlink -f "$0")
        rm -f "$SCRIPT_PATH"
        
        echo -e "${GREEN}卸载完成！所有相关文件已清除。${PLAIN}"
        exit 0
    else
        echo -e "${GREEN}已取消${PLAIN}"
    fi
}

# 主菜单
show_menu() {
    clear
    check_os # 重新检测
    load_config
    check_script_update
    
    # 检查客户端是否已安装
    if [ ! -f "$BIN_PATH" ]; then
        # 未安装客户端，显示精简菜单
        echo -e "${BLUE}
    ███████╗ ██████╗██╗  ██╗    ████████╗ ██████╗  ██████╗ ██╗     ███████╗
    ██╔════╝██╔════╝██║  ██║    ╚══██╔══╝██╔═══██╗██╔═══██╗██║     ██╔════╝
    █████╗  ██║     ███████║       ██║   ██║   ██║██║   ██║██║     ███████╗
    ██╔══╝  ██║     ██╔══██║       ██║   ██║   ██║██║   ██║██║     ╚════██║
    ███████╗╚██████╗██║  ██║       ██║   ╚██████╔╝╚██████╔╝███████╗███████║
    ╚══════╝ ╚═════╝╚═╝  ╚═╝       ╚═╝    ╚═════╝  ╚═════╝ ╚══════╝╚══════╝
    ${PLAIN}"
        echo -e "${YELLOW}检测到客户端未安装，请先安装客户端！${PLAIN}"
        echo -e "当前版本: ${GREEN}${SCRIPT_VER}${PLAIN}  状态: ${UPDATE_TIP}"
        echo -e "------------------------------------------------------"
        echo -e " ${GREEN}1.${PLAIN} 安装/更新客户端"
        echo -e " ${GREEN}0.${PLAIN} 退出脚本"
        echo -e "------------------------------------------------------"
        read -p "请输入选择 [0-1]: " choice
        
        case $choice in
            1) install_ech ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效选择${PLAIN}" ;;
        esac
        
        read -p "按回车键继续..."
        return
    fi
    
    # 客户端已安装，显示完整菜单
    check_status

    echo -e "${BLUE}
    ███████╗ ██████╗██╗  ██╗    ████████╗ ██████╗  ██████╗ ██╗     ███████╗
    ██╔════╝██╔════╝██║  ██║    ╚══██╔══╝██╔═══██╗██╔═══██╗██║     ██╔════╝
    █████╗  ██║     ███████║       ██║   ██║   ██║██║   ██║██║     ███████╗
    ██╔══╝  ██║     ██╔══██║       ██║   ██║   ██║██║   ██║██║     ╚════██║
    ███████╗╚██████╗██║  ██║       ██║   ╚██████╔╝╚██████╔╝███████╗███████║
    ╚══════╝ ╚═════╝╚═╝  ╚═╝       ╚═╝    ╚═════╝  ╚═════╝ ╚══════╝╚══════╝
    ${PLAIN}"
    echo -e "快捷键已设置为 ${YELLOW}ech${PLAIN} , 下次运行输入 ${YELLOW}ech${PLAIN} 即可"
    echo -e "当前版本: ${GREEN}${SCRIPT_VER}${PLAIN}  状态: ${UPDATE_TIP}"
    echo -e "------------------------------------------------------"
    echo -e "状态     : $STATUS"
    echo -e "系统     : $OS ($ARCH)"
    echo -e "内核     : $KERNEL"
    echo -e "运行时长 : $RUN_TIME"
    echo -e "------------------------------------------------------"
    echo -e "服务端地址   : ${BLUE}$SERVER_ADDR${PLAIN}"
    echo -e "本地监听地址 : ${BLUE}$LISTEN_ADDR${PLAIN}"
    echo -e "优选域名/IP  : ${CYAN}$BEST_IP${PLAIN}"
    echo -e "DOH服务器    : ${CYAN}$DNS${PLAIN}"
    echo -e "ECH 域名     : ${CYAN}$ECH_DOMAIN${PLAIN}"
    echo -e "Token        : ${PURPLE}$TOKEN${PLAIN}"
    echo -e "分流模式     : ${YELLOW}$ROUTING${PLAIN}"
    echo -e "------------------------------------------------------"
    echo -e " ${GREEN}1.${PLAIN} 安装/更新客户端"
    echo -e " ${GREEN}2.${PLAIN} 更新脚本"
    echo -e " ${GREEN}3.${PLAIN} 修改配置"
    echo -e " ${GREEN}4.${PLAIN} 启动服务"
    echo -e " ${GREEN}5.${PLAIN} 停止服务"
    echo -e " ${GREEN}6.${PLAIN} 重启服务"
    echo -e " ${GREEN}7.${PLAIN} 查看日志"
    echo -e " ${GREEN}8.${PLAIN} 状态检查"
    echo -e " ${GREEN}9.${PLAIN} 优选域名/IP"
    echo -e " ${GREEN}10.${PLAIN} 卸载客户端"
    echo -e " ${GREEN}11.${PLAIN} 创建快捷指令"
    echo -e " ${GREEN}12.${PLAIN} 彻底卸载"
    echo -e " ${GREEN}0.${PLAIN} 退出脚本"
    echo -e "------------------------------------------------------"
    read -p "请输入选择 [0-12]: " choice
    
    case $choice in
        1) install_ech ;;
        2) update_script ;;
        3) configure_ech ;;
        4) svc_start && echo -e "${GREEN}已启动${PLAIN}" ;;
        5) svc_stop && echo -e "${RED}已停止${PLAIN}" ;;
        6) svc_restart && echo -e "${GREEN}已重启${PLAIN}" ;;
        7) view_logs ;;
        8) status_check ;;
        9) manage_best_ip_menu ;;
        10) 
            svc_stop
            svc_disable
            rm -f $SERVICE_FILE_SYSTEMD $SERVICE_FILE_OPENWRT $BIN_PATH /usr/bin/ech
            if [ "$IS_OPENWRT" -eq 0 ]; then
                systemctl daemon-reload
            fi
            echo -e "${GREEN}已卸载${PLAIN}"
            ;;
        11) create_shortcut ;;
        12) uninstall_all ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选择${PLAIN}" ;;
    esac
    
    read -p "按回车键继续..."
}

# 命令行参数处理
if [ "$1" == "install" ]; then
    install_ech
    exit 0
fi

# 循环显示菜单
while true; do
    show_menu
done
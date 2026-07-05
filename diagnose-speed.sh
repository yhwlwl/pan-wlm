#!/bin/bash
# =============================================
# 百度网盘下载速度诊断脚本
# 在 ECS 服务器上运行: bash diagnose-speed.sh
# =============================================

ALIST_URL="https://pan.tantantan.tech"
ALIST_USER="admin"
ALIST_PASS="admin666"
TEST_SIZE_MB=5  # 测试下载 5MB

echo "========================================"
echo "  百度网盘全链路速度诊断"
echo "  $(date)"
echo "========================================"

# ── 1. 服务器基础性能 ──
echo ""
echo "──── 1. 服务器基础 ────"
echo "CPU: $(nproc)核, 内存: $(free -h | awk '/^Mem/{print $2}')"
echo "负载: $(uptime | awk -F'load average:' '{print $2}')"
echo "磁盘: $(df -h / | awk 'NR==2{print $5 " used of " $2}')"

# ── 2. 网络延迟 ──
echo ""
echo "──── 2. 网络延迟测试 ────"
# 到百度 CDN
BAIDU_CDN="d.pcs.baidu.com"
PING_RESULT=$(ping -c 5 -W 2 $BAIDU_CDN 2>&1 | tail -1)
echo "百度 CDN ($BAIDU_CDN): $PING_RESULT"

# 到 d.pcs.baidu.com 的 HTTPS 连接时间
HTTPS_TIME=$(curl -o /dev/null -s -w '%{time_connect}' --max-time 10 "https://$BAIDU_CDN/" 2>/dev/null)
echo "百度 CDN HTTPS 连接时间: ${HTTPS_TIME}s"

# ── 3. Alist API 响应速度 ──
echo ""
echo "──── 3. Alist API 响应速度 ────"

# 登录
LOGIN_START=$(date +%s%3N)
LOGIN=$(curl -sk -X POST "$ALIST_URL/api/auth/login" \
  -H 'Content-Type: application/json' \
  -d "{\"username\":\"$ALIST_USER\",\"password\":\"$ALIST_PASS\"}" \
  -w "\n%{time_total}" 2>/dev/null)
LOGIN_TIME=$(echo "$LOGIN" | tail -1)
TOKEN=$(echo "$LOGIN" | head -1 | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('data',{}).get('token',''))" 2>/dev/null)
echo "  登录: ${LOGIN_TIME}s"

if [ -z "$TOKEN" ]; then
    echo "  ❌ 登录失败，无法继续"
    exit 1
fi

# 列出根目录
LIST_TIME=$(curl -sk -X POST "$ALIST_URL/api/fs/list" \
  -H 'Content-Type: application/json' \
  -H "Authorization: $TOKEN" \
  -d '{"path":"/sta","page":1,"per_page":10,"refresh":false}' \
  -o /dev/null -w '%{time_total}' 2>/dev/null)
echo "  列出 /sta: ${LIST_TIME}s"

# 搜索文件（用于找测试文件）
SEARCH=$(curl -sk -X POST "$ALIST_URL/api/fs/search" \
  -H 'Content-Type: application/json' \
  -H "Authorization: $TOKEN" \
  -d '{"keywords":"","parent":"/sta","scope":1,"page":1,"per_page":30}' 2>/dev/null)

# 提取最大文件
BIGGEST=$(echo "$SEARCH" | python3 -c "
import sys, json
d = json.load(sys.stdin)
files = [i for i in d.get('data',{}).get('content',[]) if not i.get('is_dir') and i.get('size',0) > 0]
if files:
    biggest = max(files, key=lambda x: x.get('size',0))
    print(f\"{biggest['path']}|{biggest['name']}|{biggest['size']}\")
" 2>/dev/null)

if [ -z "$BIGGEST" ]; then
    echo "  ❌ 没找到可测试的文件"
    exit 1
fi

FPATH=$(echo "$BIGGEST" | cut -d'|' -f1)
FNAME=$(echo "$BIGGEST" | cut -d'|' -f2)
FSIZE=$(echo "$BIGGEST" | cut -d'|' -f3)
FSIZE_MB=$(echo "scale=1; $FSIZE/1048576" | bc 2>/dev/null)
echo "  测试文件: $FNAME (${FSIZE_MB}MB)"

# ── 4. 获取 raw_url 时间 ──
echo ""
echo "──── 4. 获取 raw_url ────"
GET_START=$(date +%s%3N)
GET_RESP=$(curl -sk -X POST "$ALIST_URL/api/fs/get" \
  -H 'Content-Type: application/json' \
  -H "Authorization: $TOKEN" \
  -d "{\"path\":\"$FPATH\"}" \
  -w "\n%{time_total}" 2>/dev/null)
GET_TIME=$(echo "$GET_RESP" | tail -1)
RAW_URL=$(echo "$GET_RESP" | head -1 | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('data',{}).get('raw_url',''))" 2>/dev/null)
echo "  fs/get 耗时: ${GET_TIME}s"

if [ -z "$RAW_URL" ]; then
    echo "  ❌ 没有 raw_url（非百度盘文件？）"
else
    # 提取域名
    RAW_HOST=$(echo "$RAW_URL" | sed 's|https\?://||' | cut -d'/' -f1)
    RAW_TYPE="其他"
    echo "$RAW_URL" | grep -qi 'baidu' && RAW_TYPE="百度CDN"
    echo "  来源: $RAW_TYPE ($RAW_HOST)"

    # ── 5. 直链下载速度（核心测试） ──
    echo ""
    echo "──── 5. 百度直链下载速度 ────"
    MAX_BYTES=$((TEST_SIZE_MB * 1048576))
    echo "  下载 ${TEST_SIZE_MB}MB..."

    # 单线程测速
    echo -n "  单线程: "
    SINGLE_RESULT=$(curl -sk -o /dev/null -w "size=%{size_download}|speed=%{speed_download}|time=%{time_total}" \
      -H 'User-Agent: pan.baidu.com' \
      --max-time 30 \
      --range "0-$((MAX_BYTES - 1))" \
      "$RAW_URL" 2>/dev/null)

    SINGLE_SIZE=$(echo "$SINGLE_RESULT" | grep -oP 'size=\K[^|]+')
    SINGLE_SPEED=$(echo "$SINGLE_RESULT" | grep -oP 'speed=\K[^|]+')
    SINGLE_TIME=$(echo "$SINGLE_RESULT" | grep -oP 'time=\K.*')

    if [ -n "$SINGLE_SPEED" ] && [ "$SINGLE_SPEED" != "0" ]; then
        SINGLE_MBs=$(echo "scale=2; $SINGLE_SPEED / 1048576" | bc)
        SINGLE_Mbps=$(echo "scale=2; $SINGLE_SPEED * 8 / 1000000" | bc)
        echo "${SINGLE_MBs}MB/s = ${SINGLE_Mbps}Mbps"
    else
        echo "失败或返回 0 字节"
    fi

    # 双线程并发测速
    echo -n "  双线程: "
    HALF_BYTES=$((MAX_BYTES / 2))
    DUAL_RESULT=$(curl -sk -o /dev/null -w "size=%{size_download}|speed=%{speed_download}" \
      -H 'User-Agent: pan.baidu.com' \
      --max-time 30 \
      --range "0-$((HALF_BYTES - 1))" \
      "$RAW_URL" 2>/dev/null)&
    DUAL_RESULT2=$(curl -sk -o /dev/null -w "size=%{size_download}|speed=%{speed_download}" \
      -H 'User-Agent: pan.baidu.com' \
      --max-time 30 \
      --range "$HALF_BYTES-$((MAX_BYTES - 1))" \
      "$RAW_URL" 2>/dev/null)&
    wait

    S1=$(echo "$DUAL_RESULT" | grep -oP 'speed=\K[^|]+' 2>/dev/null)
    S2=$(echo "$DUAL_RESULT2" | grep -oP 'speed=\K[^|]+' 2>/dev/null)
    if [ -n "$S1" ] && [ -n "$S2" ] && [ "$S1" != "0" ] && [ "$S2" != "0" ]; then
        TOTAL_SPEED=$((S1 + S2))
        TOTAL_MBs=$(echo "scale=2; $TOTAL_SPEED / 1048576" | bc)
        TOTAL_Mbps=$(echo "scale=2; $TOTAL_SPEED * 8 / 1000000" | bc)
        echo "${TOTAL_MBs}MB/s = ${TOTAL_Mbps}Mbps"
        echo "  线程1: $(echo "scale=2; $S1 / 1048576" | bc)MB/s"
        echo "  线程2: $(echo "scale=2; $S2 / 1048576" | bc)MB/s"
    else
        echo "失败"
    fi

    # ── 6. 标记测试（判断是否 IP 限速） ──
    echo ""
    echo "──── 6. IP 限速判断 ────"
    echo "  注意: 如果单线程 < 双线程总和，说明百度做了单连接限速"
    if [ -n "$SINGLE_Mbps" ] && [ -n "$TOTAL_Mbps" ]; then
        echo "  单线程: ${SINGLE_Mbps}Mbps, 双线程: ${TOTAL_Mbps}Mbps"
        if (( $(echo "$TOTAL_Mbps > $SINGLE_Mbps * 1.5" | bc -l) )); then
            echo "  ⚠️ 百度对单连接限速! 建议多线程下载"
        fi
    fi

    # ── 7. ECS → 百度链路质量 ──
    echo ""
    echo "──── 7. ECS → 百度 CDN 链路 ────"
    if [ -n "$RAW_HOST" ]; then
        MTR_COUNT=$(mtr -r -c 5 -n "$RAW_HOST" 2>/dev/null || traceroute -n "$RAW_HOST" 2>/dev/null || echo "mtr/traceroute 不可用")
        echo "$MTR_COUNT" | head -10
    fi
fi

# ── 8. 服务状态 ──
echo ""
echo "──── 8. 服务进程检查 ────"
echo "  Nginx: $(systemctl is-active nginx 2>/dev/null || pgrep -c nginx 2>/dev/null || echo '?')"
echo "  Alist: $(pgrep -c alist 2>/dev/null || echo '?')"
echo "  Next.js: $(pgrep -c 'next' 2>/dev/null || echo '?')"
echo "  PostgREST: $(pgrep -c postgrest 2>/dev/null || echo '?')"

# ── 9. Nginx 配置检查 ──
echo ""
echo "──── 9. Nginx 缓冲配置 ────"
if [ -f /www/server/panel/vhost/nginx/pan.tantantan.tech.conf ]; then
    echo "  检查 /pan/ 的 proxy_buffering 配置:"
    grep -A 10 'location /pan/' /www/server/panel/vhost/nginx/pan.tantantan.tech.conf 2>/dev/null | grep -E 'proxy_buffering|proxy_buffer|proxy_read_timeout' || echo "  ⚠️ 未找到 proxy_buffering 配置（使用默认值 on）"
fi

echo ""
echo "========================================"
echo "  诊断完成"
echo "========================================"

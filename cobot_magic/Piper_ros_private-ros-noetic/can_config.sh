#!/bin/bash
set -euo pipefail

# -------------------------- 配置区 --------------------------
# 可通过外部配置文件覆盖，格式：USB_PORTS["usb_port"]="can_name:bitrate"
declare -A USB_PORTS=(
    ["1-13:1.0"]="can_left:1000000"
    ["1-12:1.0"]="can_right:1000000"
    ["1-4:1.0"]="can_ugv:500000"
)

# 是否忽略CAN数量检查（默认false）
IGNORE_CHECK=false

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # 重置颜色

# -------------------------- 工具函数 --------------------------
# 日志输出函数
log_info() { echo -e "${BLUE}[INFO]${NC}: $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC}: $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC}: $1"; }
log_error() { echo -e "${RED}[ERROR]${NC}: $1"; }

# 权限检查
check_permission() {
    if [ "$(id -u)" -ne 0 ] && [ -z "$SUDO_USER" ]; then
        log_error "This script must be run as root or with sudo."
        exit 1
    fi
}

# -------------------------- 主逻辑 --------------------------
# 1. 初始化检查
check_permission

# 2. 解析参数
for arg in "$@"; do
    if [ "$arg" == "--ignore" ]; then
        IGNORE_CHECK=true
        log_info "Ignoring CAN quantity check."
    fi
done

# 3. 检查USB_PORTS配置（重复目标名）
log_info "Checking USB_PORTS configuration..."
declare -A TARGET_NAMES_COUNT
HAS_DUPLICATE=false

for k in "${!USB_PORTS[@]}"; do
    IFS=':' read -r name bitrate <<< "${USB_PORTS[$k]}"
    # 使用${变量:-}避免未定义变量错误
    if [[ -n "${TARGET_NAMES_COUNT[$name]:-}" ]]; then
        log_error "Duplicate target CAN name: '$name' (USB port: $k)"
        HAS_DUPLICATE=true
    else
        TARGET_NAMES_COUNT["$name"]=1
    fi
done

if $HAS_DUPLICATE; then
    log_error "Found duplicate target CAN interface names. Exiting."
    exit 1
fi

# -------------------------- 检查目标名是否已存在 --------------------------
log_info "Checking for existing target CAN interface names..."
HAS_EXISTING_TARGET=false

for k in "${!USB_PORTS[@]}"; do
    IFS=':' read -r TARGET_NAME TARGET_BITRATE <<< "${USB_PORTS[$k]}"
    # 静默检查目标名是否存在
    if ip link show "$TARGET_NAME" &>/dev/null; then
        log_error "Target CAN interface name '$TARGET_NAME' already exists (mapped to USB port: $k)"
        HAS_EXISTING_TARGET=true
    fi
done

if $HAS_EXISTING_TARGET; then
    log_error "Found existing target CAN interface names. Script execution aborted.Please remove and insert all USB_CAN device"
    exit -1
fi
# -------------------------- 检查目标名是否已存在 --------------------------

# 4. CAN数量校验
PREDEFINED_COUNT=${#USB_PORTS[@]}
CURRENT_CAN_COUNT=$(ip link show type can | grep -c "link/can")

if [ "$IGNORE_CHECK" = false ] && [ "$CURRENT_CAN_COUNT" -ne "$PREDEFINED_COUNT" ]; then
    log_warn "Detected CAN modules ($CURRENT_CAN_COUNT) != Expected ($PREDEFINED_COUNT)"
    read -p "Do you want to continue? (y/N): " user_input
    if [[ ! "$user_input" =~ ^[yY]([eE][sS])?$ ]]; then
        log_info "Exited by user."
        exit 1
    fi
fi

# 5. 加载gs_usb驱动
log_info "Loading gs_usb module..."
if ! sudo modprobe gs_usb; then
    log_error "Failed to load gs_usb module."
    exit 1
fi

# 6. 初始化统计
SUCCESS_COUNT=0
FAILED_COUNT=0
declare -A USB_PORT_STATUS
for k in "${!USB_PORTS[@]}"; do
    USB_PORT_STATUS["$k"]="pending"
done

# 7. 获取系统CAN接口列表
mapfile -t SYS_INTERFACE < <(ip -br link show type can | awk '{print $1}')
log_info "Detected CAN interfaces: ${SYS_INTERFACE[*]}"

# 8. 配置每个CAN接口
for iface in "${SYS_INTERFACE[@]}"; do
    log_info "Processing interface: $iface"
    
    # 获取bus-info并清洗
    BUS_INFO=$(sudo ethtool -i "$iface" | grep "bus-info" | awk '{print $2}' | tr -d ' ' | tr '[:upper:]' '[:lower:]')
    if [ -z "$BUS_INFO" ]; then
        log_error "Failed to get bus-info for $iface"
        continue
    fi

    # 匹配预定义USB端口（使用${变量:-}避免未定义变量）
    if [ -z "${USB_PORTS[$BUS_INFO]:-}" ]; then
        log_warn "USB port $BUS_INFO (interface $iface) not in predefined list."
        continue
    fi

    # 解析目标配置
    IFS=':' read -r TARGET_NAME TARGET_BITRATE <<< "${USB_PORTS[$BUS_INFO]}"

    # 检查目标名是否已存在
    if ip link show "$TARGET_NAME" &>/dev/null; then
        log_warn "Target name $TARGET_NAME already exists. Deleting it..."
        sudo ip link set "$TARGET_NAME" down
        sudo ip link delete "$TARGET_NAME" || {
            log_error "Failed to delete $TARGET_NAME"
            continue
        }
    fi

    # 获取当前接口状态
    IS_LINK_UP=$(ip link show "$iface" | grep -q "UP" && echo "yes" || echo "no")
    CURRENT_BITRATE=$(ip -details link show "$iface" | grep -oP 'bitrate \K\d+' || echo 0)

    # 配置比特率和激活
    if [ "$IS_LINK_UP" != "yes" ] || [ "$CURRENT_BITRATE" -ne "$TARGET_BITRATE" ]; then
        log_info "Configuring $iface to bitrate $TARGET_BITRATE..."
        sudo ip link set "$iface" down
        sudo ip link set "$iface" type can bitrate "$TARGET_BITRATE"
        sudo ip link set "$iface" up
    fi

    # 重命名接口
    if [ "$iface" != "$TARGET_NAME" ]; then
        log_info "Renaming $iface to $TARGET_NAME..."
        sudo ip link set "$iface" down
        sudo ip link set "$iface" name "$TARGET_NAME"
        sudo ip link set "$TARGET_NAME" up
    fi

    # 更新统计
    SUCCESS_COUNT=$((SUCCESS_COUNT+1))
    USB_PORT_STATUS["$BUS_INFO"]="success"
    log_success "Interface $TARGET_NAME configured successfully."
done

# 9. 统计失败的USB端口
for k in "${!USB_PORT_STATUS[@]}"; do
    # 使用${变量:-}避免未定义变量错误
    if [ "${USB_PORT_STATUS[$k]:-}" != "success" ]; then
        log_error "Expected CAN interface on USB port $k not found/activated."
        FAILED_COUNT=$((FAILED_COUNT+1))
    fi
done

# 10. 输出最终结果
echo -e "\n===================== Result ====================="
if [ "$SUCCESS_COUNT" -gt 0 ]; then
    log_success "$SUCCESS_COUNT CAN interfaces configured successfully."
else
    log_error "No CAN interfaces matched the configuration."
fi

if [ "$FAILED_COUNT" -gt 0 ]; then
    log_error "$FAILED_COUNT CAN interfaces failed to configure."
fi

# 11. 返回退出码
if [ "$FAILED_COUNT" -gt 0 ]; then
    exit 2
elif [ "$SUCCESS_COUNT" -eq 0 ]; then
    exit 1
else
    exit 0
fi

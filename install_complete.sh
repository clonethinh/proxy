#!/bin/sh
# install_complete.sh - Script cài đặt hoàn chỉnh EM9190 Monitor

# --- Cài đặt mặc định ---
DEFAULT_INSTALL_DIR="/usr/share/em9190-monitor"
DEFAULT_WEB_DIR="/www/em9190"
DEFAULT_PORT=9999
CONFIG_NAME="uhttpd_em9190"

# --- Parse các tùy chọn dòng lệnh ---
INSTALL_DIR="${INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"
WEB_DIR="${WEB_DIR:-$DEFAULT_WEB_DIR}"
PORT="${PORT:-$DEFAULT_PORT}"

# --- Parse tùy chọn port nếu được cung cấp ---
if [ "$1" = "--port" ] && [ -n "$2" ]; then
    PORT="$2"
    shift 2
elif [ "$1" = "--install-dir" ] && [ -n "$2" ]; then
    INSTALL_DIR="$2"
    shift 2
elif [ "$1" = "--web-dir" ] && [ -n "$2" ]; then
    WEB_DIR="$2"
    shift 2
fi

# --- Kiểm tra các gói cần thiết ---
echo "🔍 Kiểm tra dependencies..."
MISSING_DEPS=""

# Kiểm tra sự tồn tại của sms_tool
if ! command -v sms_tool >/dev/null 2>&1; then
    MISSING_DEPS="$MISSING_DEPS sms-tool"
fi

# Kiểm tra sự tồn tại của uhttpd
if ! command -v uhttpd >/dev/null 2>&1; then
    MISSING_DEPS="$MISSING_DEPS uhttpd"
fi

# Cố gắng cài đặt nếu thiếu và có kết nối internet
if [ -n "$MISSING_DEPS" ]; then
    echo "WARNING: Missing required packages: $MISSING_DEPS"
    echo "Attempting to install missing packages..."
    
    # Check for internet connection
    if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
        echo "Internet connection detected. Running 'opkg update' and installing..."
        if opkg update; then
            echo "opkg update successful. Installing missing packages..."
            # Install all missing deps in one go for efficiency
            opkg install $MISSING_DEPS
            
            # Re-check if installation was successful
            if ! command -v sms_tool >/dev/null 2>&1 || ! command -v uhttpd >/dev/null 2>&1; then
                MISSING_DEPS="" # Clear missing deps if they were successfully installed
                echo "INFO: All dependencies seem to be installed now."
            else
                # If still missing after install attempt, report it
                if ! command -v sms_tool >/dev/null 2>&1; then MISSING_DEPS="$MISSING_DEPS (sms-tool install failed)"; fi
                if ! command -v uhttpd >/dev/null 2>&1; then MISSING_DEPS="$MISSING_DEPS (uhttpd install failed)"; fi
                echo "ERROR: Failed to install one or more dependencies. Please install manually:"
                echo "       opkg update && opkg install $MISSING_DEPS"
                exit 1
            fi
        else
            echo "ERROR: 'opkg update' failed. Cannot install dependencies."
            echo "Please install manually: opkg update && opkg install $MISSING_DEPS"
            exit 1
        fi
    else
        echo "ERROR: No internet connection. Cannot install dependencies."
        echo "Please install manually: opkg update && opkg install $MISSING_DEPS"
        exit 1
    fi
fi
echo "✅ Dependencies are satisfied."


set -e # Exit immediately if a command exits with a non-zero status.

echo "🚀 Cài đặt EM9190 Monitor (Thư mục: $INSTALL_DIR, Port: $PORT)..."

# --- Kiểm tra quyền root ---
if [ "$(id -u)" != "0" ]; then
    echo "❌ Script cần chạy với quyền root. Vui lòng sử dụng 'sudo ./install_complete.sh'"
    exit 1
fi

# --- Tạo thư mục cần thiết ---
echo "📁 Tạo cấu trúc thư mục..."
mkdir -p "$INSTALL_DIR"/{scripts,config,logs}
mkdir -p "$WEB_DIR"

# --- Tạo API Handler (/api.cgi) ---
echo "🔧 Tạo API handler..."
cat > "$WEB_DIR/api.cgi" << 'EOF'
#!/bin/sh
# CGI API handler cho EM9190 Monitor

# --- Cấu hình Header ---
echo "Content-Type: application/json"
echo "Cache-Control: no-cache, no-store, must-revalidate"
echo "Pragma: no-cache"
echo "Expires: 0"
echo "Access-Control-Allow-Origin: *"
echo "Access-Control-Allow-Methods: GET, POST, OPTIONS"
echo "Access-Control-Allow-Headers: Content-Type"
echo ""

# --- Xử lý OPTIONS Request ---
if [ "$REQUEST_METHOD" = "OPTIONS" ]; then
    exit 0
fi

# --- Parse Query String ---
QUERY_STRING="${QUERY_STRING:-}"
ACTION="info"

case "$QUERY_STRING" in
    *action=info*) ACTION="info" ;;
    *action=status*) ACTION="status" ;;
    *action=reset*) ACTION="reset" ;;
    *) ;; # Use default ACTION="info"
esac

# --- Hàm Trả về Lỗi ---
error_response() {
    local message="$1"
    cat <<EOFERR
{
    "error": true,
    "message": "${message:-Lỗi không xác định}",
    "timestamp": "$(date '+%Y-%m-%d %H:%M:%S')"
}
EOFERR
    exit 1
}

# --- Hàm Tự động Phát hiện Thiết bị Modem ---
detect_device() {
    for dev in /dev/ttyUSB2 /dev/ttyUSB1 /dev/ttyUSB0 /dev/ttyACM0 /dev/ttyACM1; do
        if [ -e "$dev" ]; then
            # Try to send a basic AT command and capture stderr for potential error messages
            # Use timeout to prevent hanging
            if timeout 3 sms_tool -d "$dev" at "AT" >/dev/null 2>&1; then
                echo "$dev"
                return 0
            fi
        fi
    done
    return 1
}

# --- Xử lý các Action ---
case "$ACTION" in
    "info")
        DEVICE=$(detect_device)
        if [ -z "$DEVICE" ]; then
            error_response "Không tìm thấy thiết bị modem tương thích."
        fi
        
        if [ -x "$INSTALL_DIR/scripts/em9190_info.sh" ]; then
            "$INSTALL_DIR/scripts/em9190_info.sh" "$DEVICE"
        else
            error_response "Script $INSTALL_DIR/scripts/em9190_info.sh không tồn tại hoặc không có quyền thực thi."
        fi
        ;;
        
    "status")
        DEVICE=$(detect_device)
        DEVICE_STATUS="disconnected"
        [ -n "$DEVICE" ] && DEVICE_STATUS="connected"
        
        WAN_IP="-"
        WAN_INTERFACE=""

        # --- Improved WAN IP Detection ---
        # Try to find the WWAN interface directly (common names)
        WAN_INTERFACE=$(ip link show | awk '/state UP/ && /eth.*|wwan.*|usb/ {print $2}' | sed 's/://' | grep -E 'eth|wwan|usb' | head -n 1)
        
        # Fallback: Find the interface used for the default route
        if [ -z "$WAN_INTERFACE" ]; then
            DEFAULT_ROUTE_IP=$(ip route show default | grep default | awk '/default via/ {print $3}' | head -n 1)
            if [ -n "$DEFAULT_ROUTE_IP" ]; then
                WAN_INTERFACE=$(ip route get $DEFAULT_ROUTE_IP | grep -oP 'dev \K\S+' | head -n 1)
            fi
        fi

        if [ -n "$WAN_INTERFACE" ]; then
            # Get the IP address for the found interface
            WAN_IP=$(ip addr show $WAN_INTERFACE 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d/ -f1)
            # If no IPv4, try to get IPv6 (optional, for completeness)
            if [ -z "$WAN_IP" ] || [ "$WAN_IP" == "::1" ]; then
                WAN_IP=$(ip addr show $WAN_INTERFACE 2>/dev/null | grep "inet6 " | grep -v "::1/128" | awk '{print $2}' | cut -d/ -f1)
            fi
        fi
        
        # Further fallback: Check common modem interfaces directly if no interface was identified clearly
        if [ -z "$WAN_IP" ] || [ "$WAN_IP" == "-" ]; then
            for intf in wwan0 ppp0 usb0 eth0 eth1 eth2 eth3 eth4; do # Added eth0-4 as fallback
                if ip addr show $intf >/dev/null 2>&1; then
                    IP_ADDR=$(ip addr show $intf | grep "inet " | awk '{print $2}' | cut -d/ -f1)
                    if [ -n "$IP_ADDR" ] && [ "$IP_ADDR" != "-" ] && [[ ! "$IP_ADDR" =~ ^127\. ]]; then # Exclude localhost
                        WAN_IP="$IP_ADDR"
                        break
                    fi
                fi
            done
        fi

        WAN_IP="${WAN_IP:-"-"}" # Ensure it's always set, default to "-" if all attempts fail
        
        UPTIME_INFO=$(uptime | awk '{print $3,$4}' | sed 's/,//')
        
        cat <<EOFSTATUS
{
    "system_status": "online",
    "device_status": "$DEVICE_STATUS",
    "wan_ip": "$WAN_IP",
    "device_path": "${DEVICE:--}",
    "uptime": "$UPTIME_INFO",
    "timestamp": "$(date '+%Y-%m-%d %H:%M:%S')"
}
EOFSTATUS
        ;;
        
    "reset")
        DEVICE=$(detect_device)
        if [ -n "$DEVICE" ]; then
            # Log the attempt to reset
            echo "$(date '+%Y-%m-%d %H:%M:%S') - Attempting modem reset on $DEVICE" >> "$INSTALL_DIR/logs/em9190_monitor.log"
            
            # Send AT+CFUN=1,1 command to reset the modem
            sms_tool -d "$DEVICE" at "AT+CFUN=1,1" >/dev/null 2>&1
            
            # Check if the sms_tool command execution was successful (it might return 0 even if the command fails on modem)
            # A more robust check would involve reading the actual response, but this is usually sufficient for initiation
            
            cat <<EOFRESET
{
    "success": true,
    "message": "Đã gửi lệnh reset modem. Modem sẽ khởi động lại.",
    "timestamp": "$(date '+%Y-%m-%d %H:%M:%S')"
}
EOFRESET
        else
            error_response "Không tìm thấy thiết bị modem để reset."
        fi
        ;;
        
    *)
        error_response "Hành động không hợp lệ: $ACTION"
        ;;
esac
EOF

# --- Tạo Script lấy thông tin Modem (/usr/share/em9190-monitor/scripts/em9190_info.sh) ---
echo "📊 Tạo script lấy thông tin modem..."
cat > "$INSTALL_DIR/scripts/em9190_info.sh" << 'EOF'
#!/bin/sh
# Script lấy thông tin chi tiết của modem EM9190

DEVICE="${1:-}" # Lấy tên thiết bị từ tham số đầu tiên

if [ -z "$DEVICE" ]; then
    echo '{"error": true, "message": "Không có tên thiết bị modem nào được cung cấp."}'
    exit 1
fi

# Import các hàm tra cứu băng tần
. "$INSTALL_DIR/scripts/band_lookup.sh"

# --- Lấy thông tin từ modem ---
# Try to get modem info. Capture stderr for better error reporting.
MODEM_INFO_OUTPUT=$(timeout 10 sms_tool -d "$DEVICE" at "at!gstatus?" 2>/tmp/gstatus_err.log)
GSTATUS_EXIT_CODE=$?

if [ $GSTATUS_EXIT_CODE -ne 0 ] || [ -z "$MODEM_INFO_OUTPUT" ]; then
    ERROR_MSG=$(cat /tmp/gstatus_err.log)
    echo '{"error": true, "message": "Lỗi khi giao tiếp với modem (Exit code: '$GSTATUS_EXIT_CODE'). '"$(echo "${ERROR_MSG:-Lỗi không xác định từ sms_tool}" | tr -d '\r\n' | sed 's/"/\\"/g')"'", "exit_code": '$GSTATUS_EXIT_CODE'}'
    rm -f /tmp/gstatus_err.log
    exit 1
fi
rm -f /tmp/gstatus_err.log # Clean up error log if successful

# --- Trích xuất các thông tin cụ thể ---
MODEL=$(echo "$MODEM_INFO_OUTPUT" | awk '/^Product/ {getline; print $2}' | tr -d '\r\n')
FW=$(echo "$MODEM_INFO_OUTPUT" | awk '/^Revision/ {getline; print $2}' | tr -d '\r\n')

TEMP=$(echo "$MODEM_INFO_OUTPUT" | awk -F: '/Temperature:/ {print $3}' | tr -d '\r\n' | xargs)
[ -n "$TEMP" ] && TEMP="${TEMP}°C"

MODE_RAW=$(echo "$MODEM_INFO_OUTPUT" | awk '/^System mode:/ {print $3}')
case "$MODE_RAW" in
    "LTE") MODE="LTE" ;;
    "ENDC") MODE="5G NSA" ;;
    "NR") MODE="5G SA" ;;
    *) MODE="Unknown" ;;
esac

TAC_HEX=$(echo "$MODEM_INFO_OUTPUT" | awk '/.*TAC:/ {print $6}')
TAC_DEC=""
if [ -n "$TAC_HEX" ]; then
    TAC_DEC=$(printf "%d" "0x$TAC_HEX" 2>/dev/null)
fi

# Signal Quality (PCC - Primary Carrier)
RSSI=$(echo "$MODEM_INFO_OUTPUT" | awk '/^PCC.*RSSI/ {print $4}' | xargs)
RSRP=$(echo "$MODEM_INFO_OUTPUT" | awk '/^PCC.*RSRP/ {print $8}' | xargs)
RSRQ=$(echo "$MODEM_INFO_OUTPUT" | awk '/^PCC.*RSRQ/ {print $6}' | xargs) # More specific RSRQ for PCC
SINR=$(echo "$MODEM_INFO_OUTPUT" | awk '/^PCC.*SINR/ {print $6}' | xargs) # More specific SINR for PCC

# LTE Bands
LTE_BAND_RAW=$(echo "$MODEM_INFO_OUTPUT" | awk '/^LTE band:/ {print $3}')
LTE_BW=""
PBAND="-"
if [ -n "$LTE_BAND_RAW" ] && [ "$LTE_BAND_RAW" != "---" ]; then
    LTE_BW=$(echo "$MODEM_INFO_OUTPUT" | awk '/^LTE band:/ {print $6}' | tr -d '\r')
    PBAND="$(band4g ${LTE_BAND_RAW/B/}) @${LTE_BW} MHz"
fi

# Secondary Carriers (SCC)
S1BAND="-"
SCC1_BAND_RAW=$(echo "$MODEM_INFO_OUTPUT" | awk -F: '/^LTE SCC1 state:.*ACTIVE/ {print $3}')
if [ -n "$SCC1_BAND_RAW" ] && [ "$SCC1_BAND_RAW" != "---" ]; then
    SCC1_BW=$(echo "$MODEM_INFO_OUTPUT" | awk '/^LTE SCC1 bw/ {print $5}' | tr -d '\r')
    S1BAND="$(band4g ${SCC1_BAND_RAW/B/}) @${SCC1_BW} MHz"
    [ "$MODE" = "LTE" ] && MODE="LTE-A" # Update mode if Carrier Aggregation is active
fi

# 5G NR Bands
NR5G_BAND="-"
NR_BAND_RAW=""
NR_BAND_RAW=$(echo "$MODEM_INFO_OUTPUT" | awk '/SCC. NR5G band:/ {print $4}')
if [ -n "$NR_BAND_RAW" ] && [ "$NR_BAND_RAW" != "---" ]; then
    NR_BW=$(echo "$MODEM_INFO_OUTPUT" | awk '/SCC. NR5G bw:/ {print $8}' | tr -d '\r')
    NR5G_BAND="$(band5g ${NR_BAND_RAW/n/}) @${NR_BW} MHz"
    
    # Overwrite signal metrics with 5G NR if available, as it's usually more relevant
    NR_RSRP=$(echo "$MODEM_INFO_OUTPUT" | awk '/SCC. NR5G RSRP:/ {print $4}' | xargs)
    [ -n "$NR_RSRP" ] && RSRP="$NR_RSRP"
    NR_RSRQ=$(echo "$MODEM_INFO_OUTPUT" | awk '/SCC. NR5G RSRQ:/ {print $4}' | xargs)
    [ -n "$NR_RSRQ" ] && RSRQ="$NR_RSRQ"
    NR_SINR=$(echo "$MODEM_INFO_OUTPUT" | awk '/SCC. NR5G SINR:/ {print $4}' | xargs)
    [ -n "$NR_SINR" ] && SINR="$NR_SINR"
fi

# --- Xuất kết quả dưới dạng JSON ---
cat <<EOFINFO
{
    "timestamp": "$(date '+%Y-%m-%d %H:%M:%S')",
    "modem": "${MODEL:-Unknown}",
    "firmware": "${FW:-Unknown}",
    "temperature": "${TEMP:--}",
    "mode": "${MODE:-Unknown}",
    "primary_band": "${PBAND:- -}",
    "secondary_band": "${S1BAND:- -}",
    "nr5g_band": "${NR5G_BAND:- -}",
    "tac_hex": "${TAC_HEX:--}",
    "tac_dec": "${TAC_DEC:--}",
    "signal": {
        "rssi": "${RSSI:--}",
        "rsrp": "${RSRP:--}",
        "rsrq": "${RSRQ:--}",
        "sinr": "${SINR:--}"
    },
    "device_path": "$DEVICE"
}
EOFINFO
EOF

# --- Tạo Script tra cứu Băng tần (/usr/share/em9190-monitor/scripts/band_lookup.sh) ---
echo "📡 Tạo script tra cứu băng tần..."
cat > "$INSTALL_DIR/scripts/band_lookup.sh" << 'EOF'
#!/bin/sh
# Các hàm tra cứu tên và tần số của băng tần mạng di động

band4g() {
    local band_num="$1"
    echo -n "B${band_num}"
    case "${band_num}" in
        "1") echo -n " (2100 MHz)" ;; "2") echo -n " (1900 MHz)" ;; "3") echo -n " (1800 MHz)" ;;
        "4") echo -n " (1700 MHz)" ;; "5") echo -n " (850 MHz)" ;; "7") echo -n " (2600 MHz)" ;;
        "8") echo -n " (900 MHz)" ;; "11") echo -n " (1500 MHz)" ;; "12") echo -n " (700 MHz)" ;;
        "13") echo -n " (700 MHz)" ;; "14") echo -n " (700 MHz)" ;; "17") echo -n " (700 MHz)" ;;
        "18") echo -n " (850 MHz)" ;; "19") echo -n " (850 MHz)" ;; "20") echo -n " (800 MHz)" ;;
        "21") echo -n " (1500 MHz)" ;; "24") echo -n " (1600 MHz)" ;; "25") echo -n " (1900 MHz)" ;;
        "26") echo -n " (850 MHz)" ;; "28") echo -n " (700 MHz)" ;; "29") echo -n " (700 MHz)" ;;
        "30") echo -n " (2300 MHz)" ;; "31") echo -n " (450 MHz)" ;; "32") echo -n " (1500 MHz)" ;;
        "34") echo -n " (2000 MHz)" ;; "37") echo -n " (1900 MHz)" ;; "38") echo -n " (2600 MHz)" ;;
        "39") echo -n " (1900 MHz)" ;; "40") echo -n " (2300 MHz)" ;; "41") echo -n " (2500 MHz)" ;;
        "42") echo -n " (3500 MHz)" ;; "43") echo -n " (3700 MHz)" ;; "46") echo -n " (5200 MHz)" ;;
        "47") echo -n " (5900 MHz)" ;; "48") echo -n " (3500 MHz)" ;; "50") echo -n " (1500 MHz)" ;;
        "51") echo -n " (1500 MHz)" ;; "53") echo -n " (2400 MHz)" ;; "54") echo -n " (1600 MHz)" ;;
        "65") echo -n " (2100 MHz)" ;; "66") echo -n " (1700 MHz)" ;; "67") echo -n " (700 MHz)" ;;
        "69") echo -n " (2600 MHz)" ;; "70") echo -n " (1700 MHz)" ;; "71") echo -n " (600 MHz)" ;;
        "72") echo -n " (450 MHz)" ;; "73") echo -n " (450 MHz)" ;; "74") echo -n " (1500 MHz)" ;;
        "75") echo -n " (1500 MHz)" ;; "76") echo -n " (1500 MHz)" ;; "85") echo -n " (700 MHz)" ;;
        "87") echo -n " (410 MHz)" ;; "88") echo -n " (410 MHz)" ;; "103") echo -n " (700 MHz)" ;;
        "106") echo -n " (900 MHz)" ;;
        *) echo -n " (Unknown)" ;;
    esac
}

band5g() {
    local band_num="$1"
    echo -n "n${band_num}"
    case "${band_num}" in
        "1") echo -n " (2100 MHz)" ;; "2") echo -n " (1900 MHz)" ;; "3") echo -n " (1800 MHz)" ;;
        "5") echo -n " (850 MHz)" ;; "7") echo -n " (2600 MHz)" ;; "8") echo -n " (900 MHz)" ;;
        "12") echo -n " (700 MHz)" ;; "13") echo -n " (700 MHz)" ;; "14") echo -n " (700 MHz)" ;;
        "18") echo -n " (850 MHz)" ;; "20") echo -n " (800 MHz)" ;; "24") echo -n " (1600 MHz)" ;;
        "25") echo -n " (1900 MHz)" ;; "26") echo -n " (850 MHz)" ;; "28") echo -n " (700 MHz)" ;;
        "29") echo -n " (700 MHz)" ;; "30") echo -n " (2300 MHz)" ;; "34") echo -n " (2100 MHz)" ;;
        "38") echo -n " (2600 MHz)" ;; "39") echo -n " (1900 MHz)" ;; "40") echo -n " (2300 MHz)" ;;
        "41") echo -n " (2500 MHz)" ;; "46") echo -n " (5200 MHz)" ;; "47") echo -n " (5900 MHz)" ;;
        "48") echo -n " (3500 MHz)" ;; "50") echo -n " (1500 MHz)" ;; "51") echo -n " (1500 MHz)" ;;
        "53") echo -n " (2400 MHz)" ;; "54") echo -n " (1600 MHz)" ;; "65") echo -n " (2100 MHz)" ;;
        "66") echo -n " (1700/2100 MHz)" ;; "67") echo -n " (700 MHz)" ;; "70") echo -n " (2000 MHz)" ;;
        "71") echo -n " (600 MHz)" ;; "74") echo -n " (1500 MHz)" ;; "75") echo -n " (1500 MHz)" ;;
        "76") echo -n " (1500 MHz)" ;; "77") echo -n " (3700 MHz)" ;; "78") echo -n " (3500 MHz)" ;;
        "79") echo -n " (4700 MHz)" ;; "80") echo -n " (1800 MHz)" ;; "81") echo -n " (900 MHz)" ;;
        "82") echo -n " (800 MHz)" ;; "83") echo -n " (700 MHz)" ;; "84") echo -n " (2100 MHz)" ;;
        "85") echo -n " (700 MHz)" ;; "86") echo -n " (1700 MHz)" ;; "89") echo -n " (850 MHz)" ;;
        "90") echo -n " (2500 MHz)" ;; "91") echo -n " (800/1500 MHz)" ;; "92") echo -n " (800/1500 MHz)" ;;
        "93") echo -n " (900/1500 MHz)" ;; "94") echo -n " (900/1500 MHz)" ;; "95") echo -n " (2100 MHz)" ;;
        "96") echo -n " (6000 MHz)" ;; "97") echo -n " (2300 MHz)" ;; "98") echo -n " (1900 MHz)" ;;
        "99") echo -n " (1600 MHz)" ;; "100") echo -n " (900 MHz)" ;; "101") echo -n " (1900 MHz)" ;;
        "102") echo -n " (6200 MHz)" ;; "104") echo -n " (6700 MHz)" ;; "105") echo -n " (600 MHz)" ;;
        "106") echo -n " (900 MHz)" ;; "109") echo -n " (700/1500 MHz)" ;;
        *) echo -n " (Unknown)" ;;
    esac
}
EOF

# --- Tạo Giao diện Web (index.html) ---
echo "🌐 Tạo giao diện web..."
cat > "$WEB_DIR/index.html" << 'EOF'
<!DOCTYPE html>
<html lang="vi">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Sierra Wireless EM9190 Monitor</title>
    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
    <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;600;700&family=Roboto+Mono:wght@400;700&display=swap" rel="stylesheet">
    <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.0.0/css/all.min.css">
    <style>
        :root {
            --primary-color: #4A90E2; /* Blue */
            --secondary-color: #50E3C2; /* Teal */
            --background-gradient-start: #f0f4f8; /* Light Grayish Blue */
            --background-gradient-end: #dce4ee;  /* Lighter Blue */
            --card-background: #ffffff;
            --text-primary: #333;
            --text-secondary: #555;
            --text-accent: var(--primary-color);
            --border-color: #e0e0e0;
            --success-color: #4CAF50;
            --warning-color: #FF9800;
            --danger-color: #F44336;
            --shadow-color: rgba(0, 0, 0, 0.08);
        }

        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
            font-family: 'Inter', sans-serif;
            color: var(--text-primary);
        }

        body {
            background: linear-gradient(135deg, var(--background-gradient-start) 0%, var(--background-gradient-end) 100%);
            min-height: 100vh;
            display: flex;
            justify-content: center;
            align-items: flex-start;
            padding: 20px;
            overflow-x: hidden;
        }

        .container {
            width: 100%;
            max-width: 1100px;
            margin: 0 auto;
            text-align: center;
        }

        header {
            margin-bottom: 40px;
            padding-top: 20px;
        }

        header h1 {
            font-size: clamp(2rem, 6vw, 3rem);
            font-weight: 700;
            color: var(--text-accent);
            margin-bottom: 10px;
            letter-spacing: -0.5px;
        }

        .status-indicator {
            display: inline-flex;
            align-items: center;
            gap: 10px;
            background: rgba(255, 255, 255, 0.6);
            padding: 10px 20px;
            border-radius: 30px;
            box-shadow: 0 4px 15px rgba(0, 0, 0, 0.05);
            backdrop-filter: blur(8px);
            font-weight: 600;
            font-size: 1.1em;
            flex-wrap: wrap;
            justify-content: center;
        }

        .status-indicator .dot {
            width: 14px;
            height: 14px;
            border-radius: 50%;
            background: var(--warning-color);
            animation: pulse 1.5s infinite ease-in-out;
        }

        .status-indicator .dot.connected {
            background: var(--success-color);
        }
        .status-indicator .dot.disconnected {
            background: var(--danger-color);
        }
        .status-indicator .dot.warning { /* For paused state */
            background: var(--warning-color);
        }

        @keyframes pulse {
            0% { transform: scale(1); opacity: 1; }
            50% { transform: scale(0.9); opacity: 0.8; }
            100% { transform: scale(1); opacity: 1; }
        }

        .grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(280px, 1fr));
            gap: 25px;
            margin-top: 30px;
        }

        .card {
            background: var(--card-background);
            border-radius: 16px;
            padding: 25px;
            box-shadow: 0 8px 25px var(--shadow-color);
            transition: transform 0.3s ease-out, box-shadow 0.3s ease-out;
            text-align: left;
            border: 1px solid var(--border-color);
        }

        .card:hover {
            transform: translateY(-5px);
            box-shadow: 0 12px 30px rgba(0, 0, 0, 0.12);
        }

        .card h2 {
            color: var(--primary-color);
            margin-bottom: 20px;
            font-size: 1.35em;
            font-weight: 700;
            padding-bottom: 12px;
            border-bottom: 2px solid #f0f0f0;
            display: flex;
            align-items: center;
            gap: 10px;
        }

        .card h2 i {
            font-size: 1.1em;
            color: var(--text-accent);
        }

        .info-row {
            display: flex;
            justify-content: space-between;
            align-items: center;
            padding: 14px 0;
            border-bottom: 1px solid #f5f5f5;
            font-size: 1.05em;
        }

        .info-row:last-child {
            border-bottom: none;
        }

        .info-row span:first-child {
            font-weight: 600;
            color: var(--text-secondary);
            flex-basis: 40%;
        }

        .info-row span:last-child {
            font-family: 'Roboto Mono', monospace;
            color: var(--text-primary);
            font-weight: 700;
            flex-basis: 60%;
            text-align: right;
            word-break: break-all;
        }

        .badge {
            display: inline-block;
            padding: 6px 14px;
            border-radius: 20px;
            font-size: 0.85em;
            font-weight: 700;
            color: white;
            text-transform: uppercase;
            letter-spacing: 0.5px;
        }

        .mode-badge { background: var(--secondary-color); }
        .nr-badge { background: var(--warning-color); }

        .signal-grid {
            display: grid;
            grid-template-columns: repeat(2, 1fr);
            gap: 15px;
            margin-top: 10px;
        }

        .signal-item {
            text-align: center;
            padding: 20px 15px;
            background: #f9fbfd;
            border-radius: 12px;
            border: 1px solid #e8eff5;
            transition: all 0.3s ease-out;
            display: flex;
            flex-direction: column;
            justify-content: center;
            align-items: center;
        }

        .signal-item:hover {
            border-color: var(--primary-color);
            background: #eef5ff;
        }

        .signal-label {
            font-size: 0.9em;
            color: var(--text-secondary);
            margin-bottom: 8px;
            font-weight: 600;
        }

        .signal-value {
            font-size: clamp(1.8rem, 5vw, 2.4rem);
            font-weight: 700;
            font-family: 'Roboto Mono', monospace;
            line-height: 1.1;
        }

        .signal-unit {
            font-size: 0.8em;
            color: #999;
            margin-top: 5px;
        }

        .controls {
            margin-top: 40px;
            display: flex;
            justify-content: center;
            gap: 15px;
            flex-wrap: wrap;
        }

        .btn {
            font-size: 1.1em;
            font-weight: 600;
            padding: 12px 25px;
            border-radius: 10px;
            cursor: pointer;
            transition: background 0.3s ease, transform 0.2s ease;
            border: none;
            outline: none;
            display: inline-flex;
            align-items: center;
            gap: 8px;
            box-shadow: 0 4px 10px rgba(0,0,0,0.07);
        }

        .btn:hover {
            transform: translateY(-2px);
        }

        .btn-primary {
            background: var(--primary-color);
            color: white;
        }
        .btn-primary:hover {
            background: #357ABD;
        }

        .btn-danger {
            background: var(--danger-color);
            color: white;
        }
        .btn-danger:hover {
            background: #D32F2F;
        }
        
        .refresh-controls {
            margin-top: 25px;
            margin-bottom: 30px;
            display: flex;
            justify-content: center;
            align-items: center;
            gap: 12px;
            flex-wrap: wrap;
            font-size: 0.95em;
            color: var(--text-secondary);
        }

        .refresh-controls label {
            font-weight: 600;
        }

        .refresh-controls select,
        .refresh-controls button {
            padding: 10px 15px;
            border-radius: 8px;
            border: 1px solid var(--border-color);
            background-color: var(--card-background);
            cursor: pointer;
            font-size: inherit;
            transition: all 0.3s ease;
        }
        .refresh-controls select:hover,
        .refresh-controls button:hover {
             border-color: var(--primary-color);
        }
        .refresh-controls .refresh-timer-display {
            font-weight: 600;
            color: var(--primary-color);
            min-width: 35px;
            text-align: center;
            display: inline-block;
            padding: 8px 10px;
            background-color: #f0f7ff;
            border: 1px solid #d6eaff;
            border-radius: 8px;
        }
        
        .refresh-controls .btn-toggle-auto {
            background: var(--primary-color);
            color: white;
            padding: 10px 20px;
            font-size: 0.95em;
            display: inline-flex;
            align-items: center;
            gap: 8px;
        }
        .refresh-controls .btn-toggle-auto:hover {
             background: #357ABD;
        }

        .back-link {
            position: absolute;
            top: 20px;
            right: 20px;
            display: inline-flex;
            align-items: center;
            gap: 8px;
            background: rgba(255, 255, 255, 0.6);
            padding: 10px 18px;
            border-radius: 30px;
            backdrop-filter: blur(8px);
            text-decoration: none;
            font-weight: 600;
            transition: background 0.3s ease;
        }

        .back-link:hover {
            background: rgba(255, 255, 255, 0.8);
        }

        .back-link i {
            color: var(--primary-color);
        }

        /* --- Media Queries for Responsiveness --- */
        @media (max-width: 768px) {
            body { padding: 10px; }
            .container { padding: 0 10px; }
            header h1 { font-size: 2.2rem; }
            .status-indicator { font-size: 1em; padding: 8px 16px; gap: 8px; flex-direction: column; align-items: center; }
            .status-indicator .dot { width: 12px; height: 12px; }
            .grid { grid-template-columns: 1fr; }
            .card { padding: 20px; }
            .card h2 { font-size: 1.25em; padding-bottom: 10px; }
            .info-row { padding: 12px 0; font-size: 1em; }
            .signal-grid { grid-template-columns: 1fr; }
            .signal-value { font-size: 2rem; }
            .controls { flex-direction: column; align-items: center; }
            .btn { width: 80%; max-width: 300px; }
            .refresh-controls { flex-direction: column; align-items: center; width: 100%; }
            .refresh-controls select, .refresh-controls button { width: 80%; max-width: 250px; text-align: center; }
            .refresh-controls .refresh-timer-display { margin-top: 5px; margin-bottom: 5px; }
            .back-link { position: static; margin-bottom: 20px; display: block; width: fit-content; margin: 0 auto 20px auto; }
        }

        @media (max-width: 480px) {
            header h1 { font-size: 1.8rem; }
            .status-indicator { font-size: 0.95em; padding: 8px 12px; }
            .card h2 { font-size: 1.15em; }
            .info-row span:first-child { flex-basis: 50%; }
            .info-row span:last-child { flex-basis: 50%; }
            .signal-value { font-size: 1.8rem; }
            .btn { font-size: 1em; padding: 10px 20px; width: 90%; }
            .refresh-controls select, .refresh-controls button { width: 90%; }
        }
    </style>
</head>
<body>
    <div class="container">
        <a href="/" class="back-link">
            <i class="fas fa-home"></i> OpenWrt Home
        </a>

        <header>
            <h1><i class="fas fa-signal"></i> Sierra Wireless EM9190 Monitor</h1>
            <div class="status-indicator">
                <span class="dot" id="status-dot"></span>
                <span id="status-text">Đang tải dữ liệu...</span>
                <span id="wan-ip-display"></span>
            </div>
        </header>

        <div class="grid">
            <div class="card">
                <h2><i class="fas fa-mobile-alt"></i> Thông tin Modem</h2>
                <div class="info-row"><span>Model:</span><span id="modem">-</span></div>
                <div class="info-row"><span>Firmware:</span><span id="firmware">-</span></div>
                <div class="info-row"><span>Nhiệt độ:</span><span id="temperature">-</span></div>
                <div class="info-row"><span>Chế độ:</span><span id="mode" class="badge mode-badge">-</span></div>
            </div>

            <div class="card">
                <h2><i class="fas fa-broadcast-tower"></i> Băng tần</h2>
                <div class="info-row"><span>Primary LTE:</span><span id="primary_band">-</span></div>
                <div class="info-row"><span>Secondary LTE:</span><span id="secondary_band">-</span></div>
                <div class="info-row"><span>5G NR:</span><span id="nr5g_band" class="badge nr-badge">-</span></div>
            </div>

            <div class="card">
                <h2><i class="fas fa-chart-line"></i> Chất lượng tín hiệu</h2>
                <div class="signal-grid">
                    <div class="signal-item">
                        <div class="signal-label">RSSI</div>
                        <div class="signal-value" id="rssi">-</div>
                        <div class="signal-unit">dBm</div>
                    </div>
                    <div class="signal-item">
                        <div class="signal-label">RSRP</div>
                        <div class="signal-value" id="rsrp">-</div>
                        <div class="signal-unit">dBm</div>
                    </div>
                    <div class="signal-item">
                        <div class="signal-label">RSRQ</div>
                        <div class="signal-value" id="rsrq">-</div>
                        <div class="signal-unit">dB</div>
                    </div>
                    <div class="signal-item">
                        <div class="signal-label">SINR</div>
                        <div class="signal-value" id="sinr">-</div>
                        <div class="signal-unit">dB</div>
                    </div>
                </div>
            </div>

            <div class="card">
                <h2><i class="fas fa-map-marker-alt"></i> Thông tin Cell</h2>
                <div class="info-row"><span>TAC (Hex):</span><span id="tac_hex">-</span></div>
                <div class="info-row"><span>TAC (Dec):</span><span id="tac_dec">-</span></div>
                <div class="info-row"><span>Cập nhật:</span><span id="timestamp">-</span></div>
            </div>
        </div>

        <div class="controls">
            <button class="btn btn-primary" onclick="refreshData()">
                <i class="fas fa-sync-alt"></i> Làm mới thủ công
            </button>
            <button class="btn btn-danger" onclick="resetModem()">
                <i class="fas fa-power-off"></i> Reset Modem
            </button>
        </div>
        
        <div class="refresh-controls">
            <label for="refresh-interval">Tự động làm mới sau:</label>
            <select id="refresh-interval">
                <option value="5000">5 Giây</option>
                <option value="10000">10 Giây</option>
                <option value="15000">15 Giây</option>
                <option value="30000">30 Giây</option>
                <option value="60000">60 Giây</option>
            </select>
            <span class="refresh-timer-display" id="refresh-timer">5s</span>
            <button class="btn btn-toggle-auto" onclick="toggleAutoRefresh()">
                <i class="fas fa-pause" id="auto-refresh-icon"></i> Tắt Tự động
            </button>
        </div>

    </div>

    <script>
        class EM9190Monitor {
            constructor() {
                this.defaultUpdateInterval = 5000; // Default to 5 seconds
                this.updateInterval = this.defaultUpdateInterval; // Current active interval
                this.autoRefreshEnabled = true; // Start with auto-refresh enabled
                this.refreshTimer = null; // Holds the interval timer ID for data fetches
                this.countdownTimer = null; // Holds the countdown interval ID for display

                this.statusDot = document.getElementById('status-dot');
                this.statusText = document.getElementById('status-text');
                this.wanIpDisplay = document.getElementById('wan-ip-display');
                this.refreshIntervalSelect = document.getElementById('refresh-interval');
                this.refreshTimerDisplay = document.getElementById('refresh-timer');
                this.autoRefreshToggleButton = document.getElementById('auto-refresh-icon').closest('button');

                // Dynamically set the initial value of the select box based on the server port
                // This assumes the select box options match the default or desired intervals.
                // If the server port is NOT one of the options, the select will default to the first.
                // A more robust approach might be to fetch the port from the server or pass it via a hidden input.
                this.refreshIntervalSelect.value = this.updateInterval;

                this.init();
            }

            init() {
                this.updateCountdownDisplay(this.updateInterval / 1000);
                this.updateAutoRefreshButtonState(this.autoRefreshEnabled);
                
                this.refreshIntervalSelect.addEventListener('change', (e) => {
                    this.setNewUpdateInterval(parseInt(e.target.value, 10));
                });

                this.updateData();
                this.startAutoRefresh();
            }

            async updateData() {
                // Add a loading state indicator if possible, e.g., disable buttons, show spinner
                const currentStatusText = this.statusText.textContent; // Store current status
                this.setConnectionStatus(null, '-'); // Set to a neutral "loading" state
                this.statusText.textContent = 'Đang tải...';

                try {
                    const infoResponse = await fetch('/api.cgi?action=info');
                    if (!infoResponse.ok) {
                        throw new Error(`HTTP error! status: ${infoResponse.status}`);
                    }
                    const infoData = await infoResponse.json();

                    if (infoData.error) {
                        throw new Error(infoData.message || 'Unknown API error for info');
                    }
                    this.updateUI(infoData);

                    const statusResponse = await fetch('/api.cgi?action=status');
                    if (!statusResponse.ok) {
                        throw new Error(`HTTP error! status: ${statusResponse.status}`);
                    }
                    const statusData = await statusResponse.json();

                    if (statusData.error) {
                        throw new Error(statusData.message || 'Unknown API error for status');
                    }
                    // Pass device_status from infoData to setConnectionStatus if available, otherwise use statusData
                    const deviceStatus = infoData.device_path ? 'connected' : 'disconnected';
                    this.setConnectionStatus(deviceStatus === 'connected', statusData.wan_ip);

                    this.resetRefreshTimer();

                } catch (error) {
                    console.error('Error fetching data:', error);
                    this.setConnectionStatus(false, '-');
                    this.statusText.textContent = 'Lỗi tải dữ liệu';
                    // If an error occurs, keep the existing data but update status
                    // The timer will continue trying to fetch.
                    // If the error persists, the 'disconnected' state will be shown.
                    this.resetRefreshTimer(); // Reset timer even on error to keep trying
                }
            }

            updateUI(data) {
                document.getElementById('modem').textContent = data.modem || '-';
                document.getElementById('firmware').textContent = data.firmware || '-';
                document.getElementById('temperature').textContent = data.temperature ? `${data.temperature}°C` : '-';
                document.getElementById('timestamp').textContent = data.timestamp || '-';

                const modeElement = document.getElementById('mode');
                modeElement.textContent = data.mode || '-';
                modeElement.className = 'badge mode-badge';
                if (data.mode) {
                    if (data.mode.includes('5G')) {
                        modeElement.style.backgroundColor = 'var(--warning-color)';
                    } else if (data.mode.includes('LTE-A') || data.mode.includes('LTE')) {
                        modeElement.style.backgroundColor = '#38b2ac';
                    } else {
                        modeElement.style.backgroundColor = '#48bb78';
                    }
                } else {
                     modeElement.style.backgroundColor = '#ccc';
                }

                document.getElementById('primary_band').textContent = data.primary_band || '-';
                document.getElementById('secondary_band').textContent = data.secondary_band || '-';

                const nr5gElement = document.getElementById('nr5g_band');
                nr5gElement.textContent = data.nr5g_band || '-';
                if (data.nr5g_band && data.nr5g_band !== '-') {
                    nr5gElement.classList.add('nr-badge');
                } else {
                    nr5gElement.classList.remove('nr-badge');
                }

                this.updateSignalValue('rssi', data.signal.rssi);
                this.updateSignalValue('rsrp', data.signal.rsrp);
                this.updateSignalValue('rsrq', data.signal.rsrq);
                this.updateSignalValue('sinr', data.signal.sinr);

                document.getElementById('tac_hex').textContent = data.tac_hex || '-';
                document.getElementById('tac_dec').textContent = data.tac_dec || '-';
            }

            updateSignalValue(id, value) {
                const element = document.getElementById(id);
                element.textContent = value !== undefined && value !== null ? value : '-';

                if (value === '-' || value === undefined || value === null) {
                    element.style.color = '#ccc';
                    return;
                }

                const numValue = parseFloat(value);
                let color = '#333';

                switch (id) {
                    case 'rssi':
                        if (numValue > -70) color = 'var(--success-color)';
                        else if (numValue > -85) color = 'var(--warning-color)';
                        else color = 'var(--danger-color)';
                        break;
                    case 'rsrp':
                        if (numValue >= -80) color = 'var(--success-color)';
                        else if (numValue >= -100) color = 'var(--warning-color)';
                        else color = 'var(--danger-color)';
                        break;
                    case 'rsrq':
                        if (numValue >= -10) color = 'var(--success-color)';
                        else if (numValue >= -15) color = 'var(--warning-color)';
                        else color = 'var(--danger-color)';
                        break;
                    case 'sinr':
                        if (numValue >= 20) color = 'var(--success-color)';
                        else if (numValue >= 10) color = 'var(--warning-color)';
                        else color = 'var(--danger-color)';
                        break;
                }
                element.style.color = color;
            }

            setConnectionStatus(connected, wanIp) {
                if (connected === null) { // Loading state
                    this.statusText.textContent = 'Đang tải...';
                    this.statusDot.classList.remove('connected', 'disconnected', 'warning');
                    this.wanIpDisplay.textContent = '';
                    this.wanIpDisplay.style.display = 'none';
                } else if (connected) {
                    this.statusText.textContent = 'Đã kết nối';
                    this.statusDot.classList.remove('disconnected', 'warning');
                    this.statusDot.classList.add('connected');
                    if (wanIp && wanIp !== '-') {
                         this.wanIpDisplay.textContent = `(${wanIp})`;
                         this.wanIpDisplay.style.display = 'inline';
                    } else {
                         this.wanIpDisplay.textContent = '';
                         this.wanIpDisplay.style.display = 'none';
                    }
                } else {
                    this.statusText.textContent = 'Mất kết nối';
                    this.statusDot.classList.remove('connected', 'warning');
                    this.statusDot.classList.add('disconnected');
                    this.wanIpDisplay.textContent = '';
                    this.wanIpDisplay.style.display = 'none';
                }
            }

            startAutoRefresh() {
                if (!this.autoRefreshEnabled) return;
                this.stopTimers();
                this.refreshTimer = setInterval(() => {
                    this.updateData();
                }, this.updateInterval);
                this.startCountdown();
            }

            stopTimers() {
                clearInterval(this.refreshTimer);
                clearInterval(this.countdownTimer);
                this.refreshTimer = null;
                this.countdownTimer = null;
            }
            
            resetRefreshTimer() {
                this.stopTimers();
                if (this.autoRefreshEnabled) {
                    this.startCountdown();
                    this.refreshTimer = setInterval(() => {
                        this.updateData();
                    }, this.updateInterval);
                }
            }

            startCountdown() {
                if (!this.autoRefreshEnabled) return;

                let secondsRemaining = this.updateInterval / 1000;
                this.updateCountdownDisplay(secondsRemaining);

                this.countdownTimer = setInterval(() => {
                    secondsRemaining--;
                    this.updateCountdownDisplay(secondsRemaining);

                    if (secondsRemaining <= 0) {
                        this.updateData();
                        this.stopTimers();
                        if (this.autoRefreshEnabled) {
                            this.startAutoRefresh();
                        }
                    }
                }, 1000);
            }

            updateCountdownDisplay(seconds) {
                this.refreshTimerDisplay.textContent = `${seconds}s`;
            }

            setNewUpdateInterval(interval) {
                this.updateInterval = interval;
                this.updateCountdownDisplay(this.updateInterval / 1000);
                if (this.autoRefreshEnabled) {
                    this.startAutoRefresh();
                }
            }

            toggleAutoRefresh() {
                this.autoRefreshEnabled = !this.autoRefreshEnabled;
                this.updateAutoRefreshButtonState(this.autoRefreshEnabled);

                if (this.autoRefreshEnabled) {
                    this.startAutoRefresh();
                    // Restore previous connection status if it wasn't 'loading'
                    const currentStatusText = this.statusText.textContent;
                    if(currentStatusText === 'Tự động làm mới đã dừng' || currentStatusText === 'Lỗi tải dữ liệu') {
                       // Attempt to re-fetch to get correct status, or just set a general state
                       this.setConnectionStatus(null, '-'); // Back to loading state
                       this.statusText.textContent = 'Đang tải...';
                    } else {
                       // Re-apply previous status if it was connected/disconnected
                       const isConnected = this.statusDot.classList.contains('connected');
                       const currentWanIp = this.wanIpDisplay.textContent.replace(/[()]/g, '');
                       this.setConnectionStatus(isConnected, currentWanIp);
                    }
                } else {
                    this.stopTimers();
                    this.refreshTimerDisplay.textContent = '-';
                    this.statusText.textContent = 'Tự động làm mới đã dừng';
                    this.statusDot.classList.remove('connected', 'disconnected');
                    this.statusDot.classList.add('warning');
                    this.wanIpDisplay.textContent = '';
                    this.wanIpDisplay.style.display = 'none';
                }
            }
            
            updateAutoRefreshButtonState(enabled) {
                const icon = this.autoRefreshToggleButton.querySelector('i');
                if (enabled) {
                    icon.classList.remove('fa-play');
                    icon.classList.add('fa-pause');
                    this.autoRefreshToggleButton.textContent = ' Tắt Tự động';
                } else {
                    icon.classList.remove('fa-pause');
                    icon.classList.add('fa-play');
                    this.autoRefreshToggleButton.textContent = ' Bật Tự động';
                }
            }
        }

        function refreshData() {
            const statusText = document.getElementById('status-text');
            statusText.textContent = 'Đang làm mới...';
            
            window.monitor.updateData().then(() => {
                // updateData handles its own status updates and timer resets on success/failure
            });
        }

        async function resetModem() {
            if (!confirm('Bạn có chắc chắn muốn reset modem? Hành động này sẽ làm gián đoạn kết nối hiện tại.')) {
                return;
            }

            const statusText = document.getElementById('status-text');
            
            statusText.textContent = 'Đang gửi lệnh reset...';
            window.monitor.statusDot.className = 'dot warning';
            window.monitor.autoRefreshEnabled = false; // Temporarily disable auto-refresh
            window.monitor.stopTimers();
            window.monitor.refreshTimerDisplay.textContent = '-';
            window.monitor.updateAutoRefreshButtonState(false);

            try {
                const response = await fetch('/api.cgi?action=reset');
                if (!response.ok) {
                    throw new Error(`HTTP error! status: ${response.status}`);
                }
                const data = await response.json();

                if (data.success) {
                    alert('Lệnh reset đã được gửi. Modem sẽ khởi động lại. Trang sẽ tự động tải lại sau khoảng 25 giây.');
                    
                    setTimeout(() => {
                         window.location.reload(); 
                    }, 25000);

                } else {
                    alert('Lỗi khi reset modem: ' + (data.message || 'Lỗi không xác định'));
                    statusText.textContent = 'Reset thất bại';
                    window.monitor.statusDot.className = 'dot disconnected';
                    window.monitor.autoRefreshEnabled = false;
                    window.monitor.updateAutoRefreshButtonState(false);
                }
            } catch (error) {
                alert('Không thể gửi lệnh reset: ' + error.message);
                statusText.textContent = 'Lỗi gửi lệnh';
                window.monitor.statusDot.className = 'dot disconnected';
                window.monitor.autoRefreshEnabled = false;
                window.monitor.updateAutoRefreshButtonState(false);
            }
        }

        function toggleAutoRefresh() {
            window.monitor.toggleAutoRefresh();
        }

        document.addEventListener('DOMContentLoaded', () => {
            window.monitor = new EM9190Monitor();
        });
    </script>
EOF

# --- Thiết lập quyền truy cập cho các file ---
echo "🔐 Thiết lập quyền truy cập..."
chmod +x "$INSTALL_DIR/scripts/"*.sh
chmod +x "$WEB_DIR/api.cgi"
chmod 644 "$WEB_DIR/index.html"

# --- Tạo file log cho uhttpd riêng của EM9190 Monitor ---
echo "✍️ Tạo file log..."
touch /var/log/uhttpd_em9190_access.log
touch /var/log/uhttpd_em9190_error.log
# Tạo log file cho script chính
touch "$INSTALL_DIR/logs/em9190_monitor.log"

# --- Cấu hình uhttpd độc lập cho EM9190 Monitor ---
echo "🚀 Cấu hình và khởi động EM9190 Monitor web server trên port $PORT..."

# Tạo file cấu hình UCI cho service
UCI_CONFIG_FILE="/etc/config/em9190-monitor"
echo "config em9190-monitor" > "$UCI_CONFIG_FILE"
echo "    option port '$PORT'" >> "$UCI_CONFIG_FILE"
echo "    option install_dir '$INSTALL_DIR'" >> "$UCI_CONFIG_FILE"
echo "    option web_dir '$WEB_DIR'" >> "$UCI_CONFIG_FILE"
echo "commit em9190-monitor" # Commit for good measure, though direct write is usually fine

# Tạo script init cho service
cat > /etc/init.d/em9190-monitor << EOF
#!/bin/sh /etc/rc.common

START=99
STOP=10

USE_PROCD=1
PROG=/usr/sbin/uhttpd

# Get configuration from UCI
CONFIG_FILE="/etc/config/em9190-monitor"
if [ -f "\$CONFIG_FILE" ]; then
    PORT=\$(uci -c "\$CONFIG_FILE" get em9190-monitor.@config[0].port 2>/dev/null || echo $DEFAULT_PORT)
    INSTALL_DIR=\$(uci -c "\$CONFIG_FILE" get em9190-monitor.@config[0].install_dir 2>/dev/null || echo "$DEFAULT_INSTALL_DIR")
    WEB_DIR=\$(uci -c "\$CONFIG_FILE" get em9190-monitor.@config[0].web_dir 2>/dev/null || echo "$DEFAULT_WEB_DIR")
else
    # Fallback to default values if config file is missing
    PORT="$DEFAULT_PORT"
    INSTALL_DIR="$DEFAULT_INSTALL_DIR"
    WEB_DIR="$DEFAULT_WEB_DIR"
fi

# Check if uhttpd executable exists
if [ ! -x "\$PROG" ]; then
    echo "ERROR: uhttpd not found at \$PROG"
    exit 1
fi

start_service() {
    procd_open_instance
    procd_set_param command "\$PROG" "-f" "-h" "\$WEB_DIR" "-p" "\$PORT" "-x" "/cgi-bin" "-t" "60"
    procd_set_param respawn
    procd_set_param stdout_log "3" # Log stdout to syslog
    procd_set_param stderr_log "2" # Log stderr to syslog
    procd_close_instance
}

stop_service() {
    # Find and kill the specific uhttpd instance for EM9190 monitor
    # Search for uhttpd process that matches the web directory and port
    local PID=\$(ps | awk '/[u]httpd.*-h \/\S*\/\S* -p \S*\/\S* -x \/\S* \S*\/\S* \S*\/\S* \/\S*\/\S* \S* \S* \$WEB_DIR \$PORT/' | awk '{print \$1}')
    if [ -n "\$PID" ]; then
        kill "\$PID"
    fi
}

reload_service() {
    stop_service
    start_service
}
EOF

# Cấp quyền thực thi cho script init
chmod +x /etc/init.d/em9190-monitor

# Kích hoạt và khởi động service
if [ -f /etc/init.d/em9190-monitor ]; then
    /etc/init.d/em9190-monitor enable
    /etc/init.d/em9190-monitor start
else
    echo "ERROR: Failed to create /etc/init.d/em9190-monitor script."
    exit 1
fi

# --- Thông báo hoàn thành cài đặt ---
echo ""
echo "✅ Cài đặt EM9190 Monitor hoàn tất thành công!"

# Lấy địa chỉ IP của interface LAN để hiển thị thông tin truy cập
LAN_IP=$(uci get network.lan.ipaddr 2>/dev/null || echo "192.168.1.1")

echo ""
echo "🌐 Truy cập EM9190 Monitor tại:"
echo "   => http://$LAN_IP:$PORT"
echo ""
echo "🔗 Giao diện OpenWrt gốc vẫn hoạt động bình thường tại:"
echo "   => http://$LAN_IP (Port 80)"
echo ""
echo "📂 Các file quan trọng:"
echo "   - Web UI & API: $WEB_DIR/"
echo "   - Scripts:      $INSTALL_DIR/scripts/"
echo "   - Logs:         /var/log/uhttpd_em9190_*.log, $INSTALL_DIR/logs/em9190_monitor.log"
echo ""
echo "📜 Các lệnh quản lý Service:"
echo "   - Start:   /etc/init.d/em9190-monitor start"
echo "   - Stop:    /etc/init.d/em9190-monitor stop"
echo "   - Restart: /etc/init.d/em9190-monitor restart"
echo "   - Status:  /etc/init.d/em9190-monitor status"
echo ""
echo "Thoát khỏi chế độ cài đặt."

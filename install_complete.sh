#!/bin/sh
# install_complete.sh - Script cài đặt hoàn chỉnh EM9190 Monitor

set -e

INSTALL_DIR="/usr/share/em9190-monitor"
WEB_DIR="/www/em9190" # Thư mục web server riêng cho EM9190 Monitor
CONFIG_NAME="uhttpd_em9190"

echo "🚀 Cài đặt EM9190 Monitor (Thư mục: $INSTALL_DIR, Port: 9999)..."

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
# Set headers cho JSON response và hỗ trợ CORS (Cross-Origin Resource Sharing)
echo "Content-Type: application/json"
echo "Cache-Control: no-cache, no-store, must-revalidate"
echo "Pragma: no-cache"
echo "Expires: 0"
echo "Access-Control-Allow-Origin: *" # Cho phép mọi domain truy cập
echo "Access-Control-Allow-Methods: GET, POST, OPTIONS" # Các phương thức HTTP được phép
echo "Access-Control-Allow-Headers: Content-Type" # Các header được phép
echo "" # Kết thúc phần header

# --- Xử lý OPTIONS Request ---
# Các trình duyệt gửi request OPTIONS trước khi gửi request chính (ví dụ: POST, PUT)
# để kiểm tra quyền truy cập (CORS preflight). Ta chỉ cần trả về thành công cho request này.
if [ "$REQUEST_METHOD" = "OPTIONS" ]; then
    exit 0
fi

# --- Parse Query String ---
QUERY_STRING="${QUERY_STRING:-}" # Lấy query string, nếu rỗng thì gán là ""
ACTION="info" # Mặc định là lấy thông tin modem

# Phân tích action từ query string. Tìm kiếm chuỗi "action=" và lấy giá trị phía sau.
case "$QUERY_STRING" in
    *action=info*) ACTION="info" ;;
    *action=status*) ACTION="status" ;;
    *action=reset*) ACTION="reset" ;;
    *)
        # Nếu không tìm thấy action cụ thể trong query string,
        # thì vẫn sử dụng action mặc định là 'info'.
        ;;
esac

# --- Hàm Trả về Lỗi ---
# Hàm này in ra một JSON chứa thông báo lỗi và thoát script với mã lỗi 1.
error_response() {
    local message="$1" # Lấy thông báo lỗi từ tham số đầu tiên
    cat <<EOFERR
{
    "error": true,
    "message": "${message:-Lỗi không xác định}", # Sử dụng thông báo lỗi hoặc mặc định
    "timestamp": "$(date '+%Y-%m-%d %H:%M:%S')" # Thêm dấu thời gian
}
EOFERR
    exit 1 # Thoát với mã lỗi 1 (thường chỉ lỗi)
}

# --- Hàm Tự động Phát hiện Thiết bị Modem ---
# Hàm này cố gắng tìm ra cổng nối tiếp mà modem đang kết nối.
detect_device() {
    # Thử các đường dẫn thiết bị phổ biến cho modem USB, theo thứ tự ưu tiên.
    for dev in /dev/ttyUSB2 /dev/ttyUSB1 /dev/ttyUSB0 /dev/ttyACM0 /dev/ttyACM1; do
        # Kiểm tra xem tệp thiết bị có tồn tại không
        if [ -e "$dev" ]; then
            # Sử dụng 'sms_tool' để gửi lệnh AT cơ bản ("AT") đến thiết bị.
            # 'timeout 3' đảm bảo lệnh không bị treo quá 3 giây.
            # '>/dev/null 2>&1' bỏ qua mọi output hoặc lỗi từ lệnh sms_tool.
            if timeout 3 sms_tool -d "$dev" at "AT" >/dev/null 2>&1; then
                echo "$dev" # Nếu lệnh AT thành công, trả về tên thiết bị
                return 0 # Thoát với mã 0 (thành công)
            fi
        fi
    done
    return 1 # Trả về 1 (lỗi) nếu không tìm thấy thiết bị nào phù hợp
}

# --- Xử lý các Action ---
case "$ACTION" in
    "info")
        # Lấy tên thiết bị modem
        DEVICE=$(detect_device)
        # Nếu không tìm thấy thiết bị, trả về lỗi
        if [ -z "$DEVICE" ]; then
            error_response "Không tìm thấy thiết bị modem tương thích."
        fi
        
        # Kiểm tra xem script lấy thông tin chi tiết có tồn tại và có thể thực thi không
        if [ -x "$INSTALL_DIR/scripts/em9190_info.sh" ]; then
            # Thực thi script lấy thông tin và in kết quả ra stdout
            "$INSTALL_DIR/scripts/em9190_info.sh" "$DEVICE"
        else
            # Nếu script không tồn tại hoặc không có quyền thực thi, trả về lỗi
            error_response "Script $INSTALL_DIR/scripts/em9190_info.sh không tồn tại hoặc không có quyền thực thi."
        fi
        ;;
        
    "status")
        # Lấy tên thiết bị modem
        DEVICE=$(detect_device)
        DEVICE_STATUS="disconnected" # Mặc định trạng thái là disconnected
        # Nếu tìm thấy thiết bị, cập nhật trạng thái là connected
        [ -n "$DEVICE" ] && DEVICE_STATUS="connected"
        
        # --- Lấy địa chỉ IP WAN ---
        # Cách lấy IP WAN có thể khác nhau tùy thuộc vào cấu hình mạng OpenWrt của bạn.
        # Dưới đây là một số phương pháp phổ biến, bạn có thể cần điều chỉnh cho phù hợp.
        
        WAN_IP="-" # Mặc định IP là "-"
        
        # Phương pháp 1: Kiểm tra interface 'eth1' (thường là WAN trên một số router)
        if command -v ifconfig >/dev/null 2>&1; then
            WAN_IP=$(ifconfig eth1 | grep 'inet addr:' | awk -F: '{print $2}' | awk '{print $1}')
        fi
        
        # Phương pháp 2: Sử dụng 'ip route' để tìm default gateway (thường là router của nhà mạng)
        if [ -z "$WAN_IP" ] && command -v ip >/dev/null 2>&1; then
            WAN_IP=$(ip route show default | grep default | awk '/default via/ {print $3}' | head -n 1)
        fi
        
        # Phương pháp 3: Kiểm tra 'ip addr' cho các interface có thể là WWAN (tùy thuộc modem)
        if [ -z "$WAN_IP" ]; then
             # Thử lấy IP từ interface có thể là WWAN, ví dụ 'wwan0' hoặc 'ppp0'
             WAN_IP=$(ip addr show wwan0 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d/ -f1)
             [ -z "$WAN_IP" ] && WAN_IP=$(ip addr show ppp0 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d/ -f1)
        fi
        
        # Nếu sau tất cả mà WAN_IP vẫn rỗng, giữ giá trị mặc định "-"
        WAN_IP="${WAN_IP:-"-"}"
        
        # Lấy thông tin uptime của hệ thống
        UPTIME_INFO=$(uptime | awk '{print $3,$4}' | sed 's/,//')
        
        # Trả về JSON chứa trạng thái hệ thống và IP WAN
        cat <<EOFSTATUS
{
    "system_status": "online",
    "device_status": "$DEVICE_STATUS",     # Trạng thái kết nối modem: "connected" hoặc "disconnected"
    "wan_ip": "$WAN_IP",                   # Địa chỉ IP WAN của kết nối di động
    "device_path": "${DEVICE:--}",         # Đường dẫn thiết bị modem (/dev/tty...)
    "uptime": "$UPTIME_INFO",              # Thời gian hoạt động của hệ thống OpenWrt
    "timestamp": "$(date '+%Y-%m-%d %H:%M:%S')" # Thời gian hiện tại
}
EOFSTATUS
        ;;
        
    "reset")
        # Lấy tên thiết bị modem
        DEVICE=$(detect_device)
        # Chỉ thực hiện reset nếu tìm thấy thiết bị
        if [ -n "$DEVICE" ]; then
            # Gửi lệnh AT+CFUN=1,1 để reset modem.
            # Lệnh này có nghĩa là:
            # CFUN = 0: Minimum functionality (chỉ cho phép nghe/gọi)
            # CFUN = 1: Full functionality (cho phép mọi chức năng)
            # CFUN = 4: Flight mode (tắt mọi chức năng radio)
            # CFUN = 1,1: Full functionality, và reset modem.
            sms_tool -d "$DEVICE" at "AT+CFUN=1,1" >/dev/null 2>&1
            # Trả về JSON thông báo lệnh đã được gửi
            cat <<EOFRESET
{
    "success": true,
    "message": "Đã gửi lệnh reset modem.",
    "timestamp": "$(date '+%Y-%m-%d %H:%M:%S')"
}
EOFRESET
        else
            # Nếu không tìm thấy thiết bị, trả về lỗi
            error_response "Không tìm thấy thiết bị modem để reset."
        fi
        ;;
        
    *)
        # Nếu action không hợp lệ (ví dụ: query string không chứa action hoặc action không xác định)
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
# Sử dụng timeout để tránh script bị treo nếu modem không phản hồi
O=$(timeout 10 sms_tool -d "$DEVICE" at "at!gstatus?" 2>/dev/null)
if [ $? -ne 0 ] || [ -z "$O" ]; then
    echo '{"error": true, "message": "Không thể giao tiếp với modem hoặc timeout."}'
    exit 1
fi

# --- Trích xuất các thông tin cụ thể ---

# Model và Firmware
MODEL=$(echo "$O" | awk '/^Product/ {getline; print $2}' | tr -d '\r\n')
FW=$(echo "$O" | awk '/^Revision/ {getline; print $2}' | tr -d '\r\n')

# Nhiệt độ
TEMP=$(echo "$O" | awk -F: '/Temperature:/ {print $3}' | tr -d '\r\n' | xargs)
[ -n "$TEMP" ] && TEMP="${TEMP}°C"

# Chế độ mạng (System mode)
MODE_RAW=$(echo "$O" | awk '/^System mode:/ {print $3}')
case "$MODE_RAW" in
    "LTE") MODE="LTE" ;;
    "ENDC") MODE="5G NSA" ;; # 5G Non-Standalone
    "NR") MODE="5G SA" ;; # 5G Standalone (ít phổ biến hơn trên modem này)
    *) MODE="Unknown" ;;
esac

# TAC (Tracking Area Code)
TAC_HEX=$(echo "$O" | awk '/.*TAC:/ {print $6}')
TAC_DEC=""
if [ -n "$TAC_HEX" ]; then
    # Chuyển đổi Hex sang Dec nếu có thể
    TAC_DEC=$(printf "%d" "0x$TAC_HEX" 2>/dev/null)
fi

# Thông số tín hiệu (Lấy từ Primary Carrier - PCC)
RSSI=$(echo "$O" | awk '/^PCC.*RSSI/ {print $4}' | xargs)
RSRP=$(echo "$O" | awk '/^PCC.*RSRP/ {print $8}' | xargs)
RSRQ=$(echo "$O" | awk '/^RSRQ/ {print $3}') # RSRQ chung
SINR=$(echo "$O" | awk '/^SINR/ {print $3}') # SINR chung

# Băng tần LTE chính (Primary Band)
LTE_BAND_RAW=$(echo "$O" | awk '/^LTE band:/ {print $3}')
LTE_BW=""
if [ -n "$LTE_BAND_RAW" ] && [ "$LTE_BAND_RAW" != "---" ]; then
    LTE_BW=$(echo "$O" | awk '/^LTE band:/ {print $6}' | tr -d '\r')
    PBAND="$(band4g ${LTE_BAND_RAW/B/}) @${LTE_BW} MHz"
fi

# Các băng tần Secondary Carriers (SCC)
S1BAND="-"
SCC1_BAND_RAW=$(echo "$O" | awk -F: '/^LTE SCC1 state:.*ACTIVE/ {print $3}')
if [ -n "$SCC1_BAND_RAW" ] && [ "$SCC1_BAND_RAW" != "---" ]; then
    SCC1_BW=$(echo "$O" | awk '/^LTE SCC1 bw/ {print $5}' | tr -d '\r')
    S1BAND="$(band4g ${SCC1_BAND_RAW/B/}) @${SCC1_BW} MHz"
    # Nếu có SCC, cập nhật chế độ mạng là LTE-A (Carrier Aggregation)
    [ "$MODE" = "LTE" ] && MODE="LTE-A"
fi

# Băng tần 5G NR (nếu có)
NR5G_BAND="-"
NR_BAND_RAW=""
NR_BAND_RAW=$(echo "$O" | awk '/SCC. NR5G band:/ {print $4}')

if [ -n "$NR_BAND_RAW" ] && [ "$NR_BAND_RAW" != "---" ]; then
    NR_BW=$(echo "$O" | awk '/SCC.*SCC. NR5G bw:/ {print $8}' | tr -d '\r')
    NR5G_BAND="$(band5g ${NR_BAND_RAW/n/}) @${NR_BW} MHz"
    
    # Ghi đè thông số tín hiệu nếu có dữ liệu 5G NR
    NR_RSRP=$(echo "$O" | awk '/SCC. NR5G RSRP:/ {print $4}' | xargs)
    [ -n "$NR_RSRP" ] && RSRP="$NR_RSRP" # Ưu tiên RSRP của 5G nếu có
    
    NR_RSRQ=$(echo "$O" | awk '/SCC. NR5G RSRQ:/ {print $4}' | xargs)
    [ -n "$NR_RSRQ" ] && RSRQ="$NR_RSRQ"
    
    NR_SINR=$(echo "$O" | awk '/SCC. NR5G SINR:/ {print $4}' | xargs)
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
    }
}
EOFINFO
EOF

# --- Tạo Script tra cứu Băng tần (/usr/share/em9190-monitor/scripts/band_lookup.sh) ---
echo "📡 Tạo script tra cứu băng tần..."
cat > "$INSTALL_DIR/scripts/band_lookup.sh" << 'EOF'
#!/bin/sh
# Các hàm tra cứu tên và tần số của băng tần mạng di động

# Hàm tra cứu băng tần 4G LTE
band4g() {
    local band_num="$1"
    echo -n "B${band_num}" # Trả về định dạng B<số>
    
    # Tra cứu tần số tương ứng với số băng tần
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
        *) echo -n " (Unknown)" ;; # Trường hợp không xác định
    esac
}

# Hàm tra cứu băng tần 5G NR
band5g() {
    local band_num="$1"
    echo -n "n${band_num}" # Trả về định dạng n<số>
    
    # Tra cứu tần số tương ứng với số băng tần
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
        # mmWave bands (VHF/UHF bands)
        "257") echo -n " (28 GHz)" ;; "258") echo -n " (26 GHz)" ;; "259") echo -n " (41 GHz)" ;;
        "260") echo -n " (39 GHz)" ;; "261") echo -n " (28 GHz)" ;; "262") echo -n " (47 GHz)" ;;
        "263") echo -n " (60 GHz)" ;;
        *) echo -n " (Unknown)" ;; # Trường hợp không xác định
    esac
}

# Xuất các hàm để có thể import ở script khác
export -f band4g band5g
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
            overflow-x: hidden; /* Prevent horizontal scroll */
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
            font-size: clamp(2rem, 6vw, 3rem); /* Responsive font size */
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
            flex-wrap: wrap; /* Allow wrapping for IP address */
            justify-content: center; /* Center items if they wrap */
        }

        .status-indicator .dot {
            width: 14px;
            height: 14px;
            border-radius: 50%;
            background: var(--warning-color); /* Default to yellow */
            animation: pulse 1.5s infinite ease-in-out;
        }

        .status-indicator .dot.connected {
            background: var(--success-color);
        }
        .status-indicator .dot.disconnected {
            background: var(--danger-color);
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
            flex-basis: 40%; /* Give label some space */
        }

        .info-row span:last-child {
            font-family: 'Roboto Mono', monospace;
            color: var(--text-primary);
            font-weight: 700;
            flex-basis: 60%; /* Give value space */
            text-align: right;
            word-break: break-all; /* Prevent long strings from breaking layout */
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
            margin-top: 10px; /* Adjust spacing */
        }

        .signal-item {
            text-align: center;
            padding: 20px 15px;
            background: #f9fbfd; /* Lighter background for signal items */
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
            background: #eef5ff; /* Light blue on hover */
        }

        .signal-label {
            font-size: 0.9em;
            color: var(--text-secondary);
            margin-bottom: 8px;
            font-weight: 600;
        }

        .signal-value {
            font-size: clamp(1.8rem, 5vw, 2.4rem); /* Responsive font size for values */
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
            flex-wrap: wrap; /* Allow buttons to wrap on smaller screens */
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
            background: #357ABD; /* Darker blue */
        }

        .btn-danger {
            background: var(--danger-color);
            color: white;
        }
        .btn-danger:hover {
            background: #D32F2F; /* Darker red */
        }
        
        /* Refresh interval controls */
        .refresh-controls {
            margin-top: 25px; /* Add space above this section */
            margin-bottom: 30px; /* Add space below this section */
            display: flex;
            justify-content: center;
            align-items: center;
            gap: 12px; /* Space between elements */
            flex-wrap: wrap; /* Allow wrapping on smaller screens */
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
            font-size: inherit; /* Use parent font size */
            transition: all 0.3s ease;
        }
        .refresh-controls select:hover,
        .refresh-controls button:hover {
             border-color: var(--primary-color);
        }
        .refresh-controls .refresh-timer-display {
            font-weight: 600;
            color: var(--primary-color);
            min-width: 35px; /* Ensure enough space for numbers */
            text-align: center;
            display: inline-block;
            padding: 8px 10px; /* Match button padding */
            background-color: #f0f7ff; /* Light background */
            border: 1px solid #d6eaff;
            border-radius: 8px;
        }
        
        /* Style for the toggle button specifically to match the rest */
        .refresh-controls .btn-toggle-auto {
            background: var(--primary-color);
            color: white;
            padding: 10px 20px; /* Adjust padding to match select/label */
            font-size: 0.95em; /* Match label font size */
            display: inline-flex;
            align-items: center;
            gap: 8px;
        }
        .refresh-controls .btn-toggle-auto:hover {
             background: #357ABD; /* Darker blue */
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
            body {
                padding: 10px;
            }
            .container {
                padding: 0 10px; /* Less padding inside container */
            }
            header h1 {
                font-size: 2.2rem;
            }
            .status-indicator {
                font-size: 1em;
                padding: 8px 16px;
                gap: 8px;
                flex-direction: column; /* Stack items vertically */
                align-items: center;
            }
            .status-indicator .dot {
                width: 12px;
                height: 12px;
            }
            .grid {
                grid-template-columns: 1fr; /* Stack cards vertically */
            }
            .card {
                padding: 20px;
            }
            .card h2 {
                font-size: 1.25em;
                padding-bottom: 10px;
            }
            .info-row {
                padding: 12px 0;
                font-size: 1em;
            }
            .signal-grid {
                grid-template-columns: 1fr; /* Stack signal items */
            }
            .signal-value {
                font-size: 2rem;
            }
            .controls {
                flex-direction: column; /* Stack buttons */
                align-items: center;
            }
            .btn {
                width: 80%; /* Make buttons wider */
                max-width: 300px;
            }
            .refresh-controls {
                flex-direction: column; /* Stack refresh controls */
                align-items: center;
                width: 100%;
            }
            .refresh-controls select,
            .refresh-controls button {
                width: 80%;
                max-width: 250px;
                text-align: center;
            }
            .refresh-controls .refresh-timer-display {
                margin-top: 5px; /* Space below the select box */
                margin-bottom: 5px; /* Space above the button */
            }
            .back-link {
                position: static;
                margin-bottom: 20px;
                display: block; /* Make it take full width */
                width: fit-content; /* Adjust width */
                margin: 0 auto 20px auto; /* Center it */
            }
        }

        @media (max-width: 480px) {
            header h1 {
                font-size: 1.8rem;
            }
            .status-indicator {
                font-size: 0.95em;
                padding: 8px 12px;
            }
            .card h2 {
                font-size: 1.15em;
            }
            .info-row span:first-child {
                flex-basis: 50%;
            }
            .info-row span:last-child {
                flex-basis: 50%;
            }
            .signal-value {
                font-size: 1.8rem;
            }
            .btn {
                font-size: 1em;
                padding: 10px 20px;
                width: 90%;
            }
             .refresh-controls select,
            .refresh-controls button {
                width: 90%;
            }
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
                <span id="wan-ip-display"></span> <!-- NEW: Span to display WAN IP -->
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
        
        <!-- SECTION: Refresh Controls -->
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
                this.wanIpDisplay = document.getElementById('wan-ip-display'); // Get the new span element
                this.refreshIntervalSelect = document.getElementById('refresh-interval');
                this.refreshTimerDisplay = document.getElementById('refresh-timer');
                this.autoRefreshToggleButton = document.getElementById('auto-refresh-icon').closest('button');

                this.init();
            }

            // Initializes the monitor, sets up event listeners, and starts first refresh
            init() {
                // Set initial state for refresh controls based on defaults
                this.refreshIntervalSelect.value = this.defaultUpdateInterval;
                this.updateCountdownDisplay(this.defaultUpdateInterval / 1000); // Display seconds
                this.updateAutoRefreshButtonState(this.autoRefreshEnabled);
                
                // Setup event listener for interval change
                this.refreshIntervalSelect.addEventListener('change', (e) => {
                    this.setNewUpdateInterval(parseInt(e.target.value, 10));
                });

                this.updateData(); // Fetch data immediately on load
                this.startAutoRefresh(); // Start the auto-refresh cycle
            }

            // Fetches data from the API (both info and status for IP)
            async updateData() {
                try {
                    // Fetch modem info
                    const infoResponse = await fetch('/api.cgi?action=info');
                    if (!infoResponse.ok) {
                        throw new Error(`HTTP error! status: ${infoResponse.status}`);
                    }
                    const infoData = await infoResponse.json();

                    if (infoData.error) {
                        throw new Error(infoData.message || 'Unknown API error for info');
                    }
                    this.updateUI(infoData);

                    // Fetch system status (including WAN IP)
                    const statusResponse = await fetch('/api.cgi?action=status');
                    if (!statusResponse.ok) {
                        throw new Error(`HTTP error! status: ${statusResponse.status}`);
                    }
                    const statusData = await statusResponse.json();

                    if (statusData.error) {
                        throw new Error(statusData.message || 'Unknown API error for status');
                    }
                    this.setConnectionStatus(infoData.device_status === 'connected', statusData.wan_ip); // Pass WAN IP here

                    this.resetRefreshTimer(); // Reset countdown after successful fetch

                } catch (error) {
                    console.error('Error fetching data:', error);
                    this.setConnectionStatus(false, '-'); // Indicate disconnection and no IP
                    // If connection fails, we keep the existing data and countdown
                    // The timer will continue, and another fetch will be attempted.
                }
            }

            // Updates the HTML elements with the fetched data
            updateUI(data) {
                document.getElementById('modem').textContent = data.modem || '-';
                document.getElementById('firmware').textContent = data.firmware || '-';
                document.getElementById('temperature').textContent = data.temperature ? `${data.temperature}°C` : '-';
                document.getElementById('timestamp').textContent = data.timestamp || '-';

                // Update Mode Badge styling and text
                const modeElement = document.getElementById('mode');
                modeElement.textContent = data.mode || '-';
                modeElement.className = 'badge mode-badge'; // Reset classes
                if (data.mode) {
                    if (data.mode.includes('5G')) {
                        modeElement.style.backgroundColor = 'var(--warning-color)'; // Orange for 5G
                    } else if (data.mode.includes('LTE-A') || data.mode.includes('LTE')) {
                        modeElement.style.backgroundColor = '#38b2ac'; // Teal for LTE-A
                    } else {
                        modeElement.style.backgroundColor = '#48bb78'; // Green for other LTE
                    }
                } else {
                     modeElement.style.backgroundColor = '#ccc'; // Gray if no mode
                }

                document.getElementById('primary_band').textContent = data.primary_band || '-';
                document.getElementById('secondary_band').textContent = data.secondary_band || '-';

                // Update 5G NR Band badge
                const nr5gElement = document.getElementById('nr5g_band');
                nr5gElement.textContent = data.nr5g_band || '-';
                if (data.nr5g_band && data.nr5g_band !== '-') {
                    nr5gElement.classList.add('nr-badge');
                } else {
                    nr5gElement.classList.remove('nr-badge');
                }

                // Update signal quality values
                this.updateSignalValue('rssi', data.signal.rssi);
                this.updateSignalValue('rsrp', data.signal.rsrp);
                this.updateSignalValue('rsrq', data.signal.rsrq);
                this.updateSignalValue('sinr', data.signal.sinr);

                document.getElementById('tac_hex').textContent = data.tac_hex || '-';
                document.getElementById('tac_dec').textContent = data.tac_dec || '-';
            }

            // Updates the color of signal values based on quality
            updateSignalValue(id, value) {
                const element = document.getElementById(id);
                element.textContent = value !== undefined && value !== null ? value : '-';

                if (value === '-' || value === undefined || value === null) {
                    element.style.color = '#ccc'; // Lighter gray for missing values
                    return;
                }

                const numValue = parseFloat(value);
                let color = '#333'; // Default color

                // Assign colors based on common signal quality thresholds
                switch (id) {
                    case 'rssi':
                        if (numValue > -70) color = 'var(--success-color)'; // Good
                        else if (numValue > -85) color = 'var(--warning-color)'; // Fair
                        else color = 'var(--danger-color)'; // Poor
                        break;
                    case 'rsrp':
                        if (numValue >= -80) color = 'var(--success-color)'; // Excellent
                        else if (numValue >= -100) color = 'var(--warning-color)'; // Good to Fair
                        else color = 'var(--danger-color)'; // Poor
                        break;
                    case 'rsrq':
                        if (numValue >= -10) color = 'var(--success-color)'; // Good
                        else if (numValue >= -15) color = 'var(--warning-color)'; // Fair
                        else color = 'var(--danger-color)'; // Poor
                        break;
                    case 'sinr': // Signal-to-Noise Ratio
                        if (numValue >= 20) color = 'var(--success-color)'; // Excellent
                        else if (numValue >= 10) color = 'var(--warning-color)'; // Good
                        else color = 'var(--danger-color)'; // Poor
                        break;
                }
                element.style.color = color;
            }

            // Sets the visual status (dot, text, and IP) for connection
            setConnectionStatus(connected, wanIp) {
                if (connected) {
                    this.statusText.textContent = 'Đã kết nối';
                    this.statusDot.classList.remove('disconnected', 'warning');
                    this.statusDot.classList.add('connected');
                    // Display WAN IP if provided
                    if (wanIp && wanIp !== '-') {
                         this.wanIpDisplay.textContent = `(${wanIp})`;
                         this.wanIpDisplay.style.display = 'inline'; // Make sure it's visible
                    } else {
                         this.wanIpDisplay.textContent = '';
                         this.wanIpDisplay.style.display = 'none'; // Hide if no IP
                    }

                } else {
                    this.statusText.textContent = 'Mất kết nối';
                    this.statusDot.classList.remove('connected', 'warning');
                    this.statusDot.classList.add('disconnected');
                    this.wanIpDisplay.textContent = ''; // Clear IP on disconnect
                    this.wanIpDisplay.style.display = 'none'; // Hide the IP display
                }
            }

            // Starts the automatic refresh process
            startAutoRefresh() {
                if (this.autoRefreshEnabled) {
                    this.stopTimers(); // Clear any existing timers before starting new ones
                    // Set up the interval to fetch data every `updateInterval` milliseconds
                    this.refreshTimer = setInterval(() => {
                        this.updateData();
                    }, this.updateInterval);
                    // Start the countdown display and logic
                    this.startCountdown();
                }
            }

            // Stops all active timers (data fetch interval and countdown interval)
            stopTimers() {
                clearInterval(this.refreshTimer);
                clearInterval(this.countdownTimer);
                this.refreshTimer = null;
                this.countdownTimer = null;
            }
            
            // Resets the countdown timer and the data fetch interval
            resetRefreshTimer() {
                this.stopTimers(); // Stop existing timers
                if (this.autoRefreshEnabled) {
                    this.startCountdown(); // Restart the countdown display
                    // Re-schedule the next data fetch
                    this.refreshTimer = setInterval(() => {
                        this.updateData();
                    }, this.updateInterval);
                }
            }

            // Starts the countdown display and triggers update when it reaches zero
            startCountdown() {
                if (!this.autoRefreshEnabled) return; // Do nothing if auto-refresh is disabled

                let secondsRemaining = this.updateInterval / 1000;
                this.updateCountdownDisplay(secondsRemaining);

                // Set up the interval to decrement the countdown every second
                this.countdownTimer = setInterval(() => {
                    secondsRemaining--;
                    this.updateCountdownDisplay(secondsRemaining);

                    if (secondsRemaining <= 0) {
                        this.updateData(); // Fetch data when countdown finishes
                        this.stopTimers(); // Stop current timers
                        if (this.autoRefreshEnabled) { // If auto-refresh is still enabled, restart the cycle
                            this.startAutoRefresh();
                        }
                    }
                }, 1000);
            }

            // Updates the text content of the countdown display element
            updateCountdownDisplay(seconds) {
                this.refreshTimerDisplay.textContent = `${seconds}s`;
            }

            // Sets a new interval for auto-refresh and restarts the process
            setNewUpdateInterval(interval) {
                this.updateInterval = interval; // Update the active interval
                this.updateCountdownDisplay(this.updateInterval / 1000); // Update the display with new time
                if (this.autoRefreshEnabled) {
                    this.startAutoRefresh(); // Restart refresh with the new interval
                }
            }

            // Toggles the auto-refresh feature on or off
            toggleAutoRefresh() {
                this.autoRefreshEnabled = !this.autoRefreshEnabled; // Flip the state
                this.updateAutoRefreshButtonState(this.autoRefreshEnabled); // Update the button's appearance

                if (this.autoRefreshEnabled) {
                    this.startAutoRefresh(); // Start refreshing if enabled
                } else {
                    this.stopTimers(); // Stop all timers if disabled
                    this.refreshTimerDisplay.textContent = '-'; // Clear the countdown display
                    // Update status to reflect that auto-refresh is paused
                    this.statusText.textContent = 'Tự động làm mới đã dừng';
                    this.statusDot.classList.remove('connected', 'disconnected');
                    this.statusDot.classList.add('warning'); // Use warning color for paused state
                    this.wanIpDisplay.textContent = ''; // Clear IP when paused
                    this.wanIpDisplay.style.display = 'none';
                }
            }
            
            // Updates the icon and text on the toggle button to reflect the current state
            updateAutoRefreshButtonState(enabled) {
                const icon = this.autoRefreshToggleButton.querySelector('i');
                if (enabled) {
                    icon.classList.remove('fa-play'); // Show pause icon
                    icon.classList.add('fa-pause');
                    this.autoRefreshToggleButton.textContent = ' Tắt Tự động'; // Update button text
                } else {
                    icon.classList.remove('fa-pause'); // Show play icon
                    icon.classList.add('fa-play');
                    this.autoRefreshToggleButton.textContent = ' Bật Tự động'; // Update button text
                }
            }
        }

        // --- Global Helper Functions ---

        // Manually trigger data refresh and reset the auto-refresh timer
        function refreshData() {
            const statusText = document.getElementById('status-text');
            statusText.textContent = 'Đang làm mới...'; // Provide visual feedback
            
            window.monitor.updateData().then(() => {
                // updateData() handles status update and timer reset on success
            }).catch(() => {
                // updateData() handles status update on failure
            });
            window.monitor.resetRefreshTimer(); // Ensure the countdown is reset
        }

        // Resets the modem, with user confirmation
        async function resetModem() {
            if (!confirm('Bạn có chắc chắn muốn reset modem? Hành động này sẽ làm gián đoạn kết nối hiện tại.')) {
                return; // Exit if user cancels
            }

            const statusText = document.getElementById('status-text');
            
            // Provide immediate feedback that the action is in progress
            statusText.textContent = 'Đang gửi lệnh reset...';
            window.monitor.statusDot.className = 'dot warning'; // Change dot to warning color
            window.monitor.autoRefreshEnabled = false; // Temporarily disable auto-refresh
            window.monitor.stopTimers(); // Stop any active timers
            window.monitor.refreshTimerDisplay.textContent = '-'; // Clear countdown
            window.monitor.updateAutoRefreshButtonState(false); // Update button to reflect paused state

            try {
                const response = await fetch('/api.cgi?action=reset');
                if (!response.ok) {
                    throw new Error(`HTTP error! status: ${response.status}`);
                }
                const data = await response.json();

                if (data.success) {
                    alert('Lệnh reset đã được gửi. Modem sẽ khởi động lại. Trang sẽ tự động tải lại sau khoảng 25 giây.');
                    
                    // After a successful reset, the modem will reboot.
                    // We wait for a period to allow the modem to boot up and then reload the page.
                    setTimeout(() => {
                         window.location.reload(); 
                    }, 25000); // 25 seconds to allow modem to boot

                } else {
                    // If reset failed, alert the user and restore previous status/timers if possible
                    alert('Lỗi khi reset modem: ' + (data.message || 'Lỗi không xác định'));
                    // Attempt to restore the previous state
                    statusText.textContent = 'Reset thất bại';
                    window.monitor.statusDot.className = 'dot disconnected'; // Show as disconnected
                    window.monitor.autoRefreshEnabled = false; // Keep disabled until user re-enables
                    window.monitor.updateAutoRefreshButtonState(false); // Ensure button shows "Bật Tự động"
                }
            } catch (error) {
                // Handle network errors or other exceptions during the reset process
                alert('Không thể gửi lệnh reset: ' + error.message);
                statusText.textContent = 'Lỗi gửi lệnh';
                window.monitor.statusDot.className = 'dot disconnected'; // Show as disconnected
                window.monitor.autoRefreshEnabled = false; // Keep disabled
                window.monitor.updateAutoRefreshButtonState(false); // Ensure button shows "Bật Tự động"
            }
        }

        // Toggles the auto-refresh feature on or off
        function toggleAutoRefresh() {
            window.monitor.toggleAutoRefresh();
        }

        // Initialize the monitor when the DOM is ready
        document.addEventListener('DOMContentLoaded', () => {
            window.monitor = new EM9190Monitor();
        });
    </script>
</body>
</html>
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

# --- Kiểm tra các dependencies cần thiết ---
echo "🔍 Kiểm tra dependencies..."
MISSING_DEPS=""

# Kiểm tra sự tồn tại của sms_tool
if ! command -v sms_tool >/dev/null 2>&1; then
    MISSING_DEPS="$MISSING_DEPS sms_tool"
fi

# Kiểm tra sự tồn tại của uhttpd (cần cho web server)
# Lưu ý: uhttpd thường có sẵn trên OpenWrt, nhưng vẫn kiểm tra
if ! command -v uhttpd >/dev/null 2>&1; then
    MISSING_DEPS="$MISSING_DEPS uhttpd"
fi

if [ -n "$MISSING_DEPS" ]; then
    echo "⚠️ Cảnh báo: Thiếu các gói cần thiết: $MISSING_DEPS"
    echo "   Vui lòng cài đặt bằng lệnh: opkg update && opkg install $MISSING_DEPS"
    exit 1
fi

# --- Cấu hình và khởi động uhttpd độc lập cho EM9190 Monitor ---
echo "🚀 Khởi động EM9190 Monitor web server trên port 9999..."

# Tạo script init cho service
cat > /etc/init.d/em9190-monitor << 'EOF'
#!/bin/sh /etc/rc.common

START=99
STOP=10

USE_PROCD=1
PROG=/usr/sbin/uhttpd

# Hàm khởi động service
start_service() {
    procd_open_instance # Mở một instance mới cho uhttpd
    # Cấu hình uhttpd:
    # -f: Chạy ở chế độ foreground
    # -h /www/em9190: Sử dụng /www/em9190 làm thư mục gốc web
    # -p 9999: Lắng nghe trên port 9999
    # -x /cgi-bin: Chỉ định thư mục cho các script CGI (dù ta đang dùng /api.cgi trực tiếp)
    # -t 60: Timeout cho kết nối là 60 giây
    procd_set_param command $PROG -f -h /www/em9190 -p 9999 -x /cgi-bin -t 60
    procd_set_param respawn # Tự động khởi động lại nếu uhttpd bị lỗi
    procd_close_instance # Đóng instance
}

# Hàm dừng service
stop_service() {
    # Tìm và dừng PID của uhttpd đang chạy trên port 9999
    local PID=$(ps | grep "[u]httpd.*-p 9999" | awk '{print $1}')
    if [ -n "$PID" ]; then
        kill $PID
    fi
}

# Hàm khởi động lại service
reload_service() {
    stop_service
    start_service
}
EOF

# Cấp quyền thực thi cho script init
chmod +x /etc/init.d/em9190-monitor

# Kích hoạt và khởi động service
/etc/init.d/em9190-monitor enable
/etc/init.d/em9190-monitor start

# --- Thông báo hoàn thành cài đặt ---
echo ""
echo "✅ Cài đặt EM9190 Monitor hoàn tất thành công!"

# Lấy địa chỉ IP của interface LAN để hiển thị thông tin truy cập
LAN_IP=$(uci get network.lan.ipaddr 2>/dev/null || echo "192.168.1.1") # Mặc định là 192.168.1.1 nếu không lấy được

echo ""
echo "🌐 Truy cập EM9190 Monitor tại:"
echo "   => http://$LAN_IP:9999"
echo ""
echo "🔗 Giao diện OpenWrt gốc vẫn hoạt động bình thường tại:"
echo "   => http://$LAN_IP (Port 80)"
echo ""
echo "📂 Các file quan trọng:"
echo "   - Web UI & API: $WEB_DIR/"
echo "   - Scripts:      $INSTALL_DIR/scripts/"
echo "   - Logs:         /var/log/uhttpd_em9190_*.log"
echo ""
echo "📜 Các lệnh quản lý Service:"
echo "   - Start:   /etc/init.d/em9190-monitor start"
echo "   - Stop:    /etc/init.d/em9190-monitor stop"
echo "   - Restart: /etc/init.d/em9190-monitor restart"
echo "   - Status:  ps | grep 'uhttpd.*9999'"
echo ""
echo "Thoát khỏi chế độ cài đặt."

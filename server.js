const express = require('express');
const bodyParser = require('body-parser');
const cors = require('cors'); // Middleware để xử lý Cross-Origin Resource Sharing (CORS)

const app = express();
const PORT = 3000; // Cổng mà máy chủ của bạn sẽ lắng nghe. Bạn có thể thay đổi nó.

// --- Cấu hình Middleware ---
// body-parser: Cho phép Express đọc dữ liệu JSON từ body của các yêu cầu HTTP (đặc biệt là POST)
app.use(bodyParser.json());

// CORS: Cho phép các yêu cầu từ bất kỳ nguồn gốc (origin) nào truy cập vào API này.
// Điều này cực kỳ quan trọng vì frontend (trên router của bạn) và backend (máy chủ Node.js)
// sẽ chạy trên các địa chỉ IP/port khác nhau, mà trình duyệt sẽ ngăn chặn nếu không có CORS.
// Trong môi trường thực tế, bạn nên giới hạn các origins cụ thể để tăng cường bảo mật.
app.use(cors());

// Middleware ghi log yêu cầu: Ghi lại thông tin về mỗi yêu cầu HTTP đến, hữu ích cho debug
app.use((req, res, next) => {
    const timestamp = new Date().toISOString();
    console.log(`[${timestamp}] ${req.method} ${req.url}`);
    // Sửa lỗi: Chỉ ghi log body nếu req.body tồn tại và là một đối tượng
    if (req.body && typeof req.body === 'object' && Object.keys(req.body).length > 0) {
        console.log('  Body:', JSON.stringify(req.body));
    }
    next();
});

// --- Dữ liệu giả định và trạng thái mô phỏng ---
// Biến này mô phỏng token xác thực được lưu trên bộ nhớ của router.
// Nó sẽ được cập nhật khi frontend gửi yêu cầu lưu token.
let storedTokenOnRouter = null; // Khởi tạo là null, mô phỏng router chưa có token

// Địa chỉ MAC giả định mà máy chủ này sẽ trả về khi frontend yêu cầu MAC của router.
// Đây là chìa khóa để bypass kiểm tra "Không đúng thiết bị cho phép!".
// Bạn có thể thay đổi nó thành một địa chỉ MAC hợp lệ bất kỳ (ví dụ: từ router của bạn).
const DUMMY_ROUTER_MAC = "00:11:22:33:44:55";

// Hàm trợ giúp: Tạo một timestamp hết hạn rất xa trong tương lai (ví dụ: 100 năm tới)
// Điều này giúp đảm bảo key/token luôn được coi là hợp lệ và không bao giờ hết hạn.
const createFutureExpiresAt = (years = 100) => {
    return Date.now() + (years * 365 * 24 * 60 * 60 * 1000); // 100 năm tính bằng miligiây
};

// --- Các Endpoint của API ---

// 1. Endpoint: Xác thực Key mới ('/api/verify-key')
//    - Phương thức: POST
//    - Chức năng: Được frontend gọi khi người dùng nhập một key mới vào màn hình đăng nhập.
app.post('/api/verify-key', (req, res) => {
    const { key, mac } = req.body; // Lấy key và mac từ body của yêu cầu

    // Logic xác thực bypass: Luôn coi mọi key là hợp lệ
    const isValid = true;
    const message = 'Key hợp lệ (bypass). Chào mừng bạn!';
    // Tạo một token giả định mới. Token này sẽ được frontend lưu lại và sử dụng cho các yêu cầu sau.
    const responseToken = `bypass_token_for_${key || 'any_key'}_${Date.now()}`;
    const expiresAt = createFutureExpiresAt(); // Thời gian hết hạn rất xa

    // Cập nhật token giả định đang "lưu trên router" trong máy chủ mô phỏng này
    storedTokenOnRouter = responseToken;

    console.log(`  -> Xử lý Verify Key: Key='${key}', MAC='${mac}'. Phản hồi: HỢP LỆ.`);
    res.json({
        valid: true,         // Báo hiệu key là hợp lệ
        expiresAt: expiresAt, // Timestamp hết hạn (rất xa trong tương lai)
        success: true,       // Luôn là true cho quá trình đăng nhập ban đầu
        message: message,    // Thông báo cho frontend
        token: responseToken // Token mới được cấp cho frontend để lưu
    });
});

// 2. Endpoint: Kiểm tra trạng thái Key ('/api/key-status')
//    - Phương thức: POST
//    - Chức năng: Được frontend gọi định kỳ để cập nhật trạng thái key trên giao diện người dùng.
app.post('/api/key-status', (req, res) => {
    const { token, mac } = req.body; // Lấy token và mac từ body của yêu cầu

    // Logic xác thực bypass: Luôn coi mọi token là hợp lệ
    const isValid = true;
    const message = 'Key đang hoạt động (bypass).';
    const expiresAt = createFutureExpiresAt(); // Thời gian hết hạn rất xa

    console.log(`  -> Xử lý Key Status: Token='${token}', MAC='${mac}'. Phản hồi: HỢP LỆ.`);
    res.json({
        valid: true,
        expiresAt: expiresAt,
        message: message
    });
});

// 3. Endpoint: Xác thực Token đã lưu ('/api/validate-token')
//    - Phương thức: POST
//    - Chức năng: Được frontend gọi khi khởi động để kiểm tra token đã được lưu trên router.
app.post('/api/validate-token', (req, res) => {
    const { token, mac } = req.body; // Lấy token và mac từ body của yêu cầu

    // Logic xác thực bypass: Luôn coi mọi token là hợp lệ
    const isValid = true;
    const message = 'Token đã được xác thực (bypass).';
    const expiresAt = createFutureExpiresAt(); // Thời gian hết hạn rất xa

    console.log(`  -> Xử lý Validate Token: Token='${token}', MAC='${mac}'. Phản hồi: HỢP LỆ.`);
    res.json({
        valid: true,
        expiresAt: expiresAt,
        message: message
    });
});

// --- Endpoint mô phỏng các API tương tác với Token trên Router (các file Lua) ---
// Frontend gọi các API Lua này trên router. Chúng ta chuyển hướng chúng tới Node.js server.

// 4. Endpoint: Lấy địa chỉ MAC của Router ('/lua-api/get_router_mac.lua')
//    - Phương thức: GET
//    - Chức năng: Được frontend gọi để lấy địa chỉ MAC của router (để kiểm tra thiết bị).
app.get('/lua-api/get_router_mac.lua', (req, res) => {
    console.log('  -> Xử lý Get Router MAC: Phản hồi: MAC giả định.');
    res.json({ mac: DUMMY_ROUTER_MAC }); // Trả về địa chỉ MAC giả định
});

// 5. Endpoint: Đọc Token từ Router ('/lua-api/read_token.lua')
//    - Phương thức: GET
//    - Chức năng: Được frontend gọi để đọc token được "lưu" trên router.
app.get('/lua-api/read_token.lua', (req, res) => {
    console.log(`  -> Xử lý Read Token: Phản hồi: Token='${storedTokenOnRouter}'.`);
    res.json({
        token: storedTokenOnRouter // Trả về token đang được máy chủ mô phỏng là đã lưu
    });
});

// 6. Endpoint: Lưu Token vào Router ('/lua-api/save_token.lua')
//    - Phương thức: POST
//    - Chức năng: Được frontend gọi để lưu một token mới vào "bộ nhớ" của router.
app.post('/lua-api/save_token.lua', (req, res) => {
    const { token } = req.body; // Lấy token từ body của yêu cầu
    console.log(`  -> Xử lý Save Token: Lưu token='${token}'.`);
    storedTokenOnRouter = token; // Cập nhật token giả định
    res.json({ status: "ok", message: "Token đã được lưu vào router (mô phỏng)." });
});

// 7. Endpoint: Xóa Token khỏi Router ('/lua-api/delete_token.lua')
//    - Phương thức: POST
//    - Chức năng: Được frontend gọi để xóa token khỏi "bộ nhớ" của router.
app.post('/lua-api/delete_token.lua', (req, res) => {
    console.log('  -> Xử lý Delete Token: Xóa token đã lưu.');
    storedTokenOnRouter = null; // Xóa token giả định (đặt về null)
    res.json({ status: "ok", message: "Token đã được xóa khỏi router (mô phỏng)." });
});

// --- Khởi động Máy chủ ---
app.listen(PORT, () => {
    console.log('-------------------------------------------------------------------');
    console.log(`Máy chủ xác thực VWRT Manager đang chạy trên: http://localhost:${PORT}`);
    console.log('\nCác Endpoint (đường dẫn) ĐẦY ĐỦ để bạn trỏ file vwrtfinal.js tới:');
    console.log(`  - /api/verify-key          -> http://localhost:${PORT}/api/verify-key`);
    console.log(`  - /api/key-status          -> http://localhost:${PORT}/api/key-status`);
    console.log(`  - /api/validate-token      -> http://localhost:${PORT}/api/validate-token`);
    console.log(`  - /lua-api/get_router_mac.lua -> http://localhost:${PORT}/lua-api/get_router_mac.lua`);
    console.log(`  - /lua-api/read_token.lua  -> http://localhost:${PORT}/lua-api/read_token.lua`);
    console.log(`  - /lua-api/save_token.lua  -> http://localhost:${PORT}/lua-api/save_token.lua`);
    console.log(`  - /lua-api/delete_token.lua-> http://localhost:${PORT}/lua-api/delete_token.lua`);
    console.log('-------------------------------------------------------------------');
    console.log('\nHƯỚNG DẪN QUAN TRỌNG:');
    console.log('1. Đảm bảo bạn đã cài đặt Node.js và các dependencies (express, body-parser, cors).');
    console.log('2. Chạy máy chủ này bằng lệnh: `node server.js`');
    console.log('3. **Sửa file `vwrtfinal.js`:**');
    console.log('   - Tìm và thay thế TẤT CẢ các URL gốc (`glitch.me` và các đường dẫn `/lua-api/...` tương đối)');
    console.log('     bằng các URL đầy đủ trỏ đến máy chủ này (ví dụ: `http://<IP_MAY_CHU>:${PORT}/...`).');
    console.log('   - Thay thế `<IP_MAY_CHU>` bằng địa chỉ IP thực tế của máy tính bạn đang chạy máy chủ này.');
    console.log('4. **Sửa file `index.html` (Nếu có):**');
    console.log('   - Tìm dòng: `window.vwrt_mac = \'$(cat /sys/class/net/eth0/address)\';`');
    console.log('   - Thay thế bằng: `window.vwrt_mac = \'' + DUMMY_ROUTER_MAC + '\';` (Để bypass kiểm tra MAC ban đầu).');
    console.log('5. Upload các file `vwrtfinal.js` và `index.html` đã sửa đổi lên router.');
    console.log('6. Xóa bộ nhớ cache của trình duyệt khi truy cập lại dashboard.');
    console.log('\nSau khi làm đúng, bạn có thể nhập BẤT KỲ KEY NÀO để đăng nhập!');
});
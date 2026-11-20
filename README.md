# Supply Chain & Warehouse Logistics Network

Đồ án môn **INT1313 — Cơ sở dữ liệu (Databases)** · Học kỳ 1, Năm học 2026–2027 (PTIT HCM).

## Team DATAFORGE
| Thành viên | Email |
| :--- | :--- |
| Trần Gia Huy | `n24dccn126@student.ptithcm.edu.vn` |
| Lê Huy Khánh | `n24dccn132@student.ptithcm.edu.vn` |
| Nguyễn Minh Khôi | `n24dccn135@student.ptithcm.edu.vn` |

---

## Tổng quan bài toán
- **Bối cảnh:** Quản lý tồn kho thời gian thực trên nhiều kho hàng khu vực, quản lý đơn đặt hàng nhà cung cấp (`Purchase Order`) và theo dõi vận chuyển hai chiều (chuyển kho nội bộ `Warehouse Transfer` và giao hàng khách hàng `Customer Delivery`).
- **2 Thách thức CSDL trọng tâm:**
  1. **Quan hệ đệ quy nhiều cấp (Recursive BOM):** Biểu diễn cấu trúc lắp ráp sản phẩm (`product_component`), truy vấn đệ quy `WITH RECURSIVE` và chặn vòng lặp trực tiếp/gián tiếp (**BR4**).
  2. **Trigger kiểm soát tồn kho & Cảnh báo restock:** Tự động chặn xuất vượt tồn kho (**BR7**), chặn tồn kho âm (**BR3**), tự động phát sinh cảnh báo (`v_restock_alerts`) và sinh đơn đặt hàng bổ sung (`Pending` PO) khi tồn kho xuống dưới `reorder_level` (**FR5**).
- **Công nghệ:** MySQL 8.0+ (InnoDB, chuẩn **SQLStyle.guide**, Data Dictionary **ISO/IEC 11179**) · Backend **Python / Flask + PyMySQL**.

---

## Cấu trúc Repository

```text
.
├── README.md
├── .gitignore
├── Bao_Cao_Phase1_Supply_Chain_Warehouse_Logistics.pdf     # Báo cáo Phase 1 gốc (SRS & EER)
├── Bao_Cao_Tong_Hop_Supply_Chain_Warehouse_Logistics.pdf   # Báo cáo tổng hợp toàn bộ Phase 1 – Phase 4 (Full Report)
├── EER Diagram.png                                         # Phase 1: Sơ đồ EER
├── Phase2/
│   └── Physical_Schema_Diagram.drawio                      # Phase 2: Sơ đồ vật lý chuẩn IE Crow's Foot (MySQL 8.0+)
├── Phase3/
│   └── sql/
│       ├── 01_ddl_schema.sql                               # 14 bảng chuẩn BCNF, 19 FKs, CHECK/REGEXP, 7 Secondary Indexes
│       ├── 02_views_and_triggers.sql                       # 3 Views & 116 Triggers (BR1, BR2, BR4 đệ quy, BR7, FR5)
│       ├── 03_dml_mock_data.sql                            # Dữ liệu mẫu 5 kho, 5 NCC, 12 SP (BOM 3 cấp), 6 PO, 6 Shipment
│       ├── 04_complex_queries.sql                          # 12 truy vấn phức tạp (WITH RECURSIVE, Window Functions, EXPLAIN)
│       └── 05_verification_and_rbac.sql                    # 16 Test Cases kiểm chứng ràng buộc & RBAC 6 Roles (GRANT/REVOKE)
└── Phase4/
    ├── app.py                                              # Backend Flask kết nối trực tiếp MySQL 8.0
    ├── templates/index.html                                # Giao diện Web Dashboard 5 tab (FR1-FR7, BR1-BR7)
    ├── pyproject.toml                                      # Khai báo thư viện Python (Flask, PyMySQL, python-dotenv)
    ├── .env.example                                        # Mẫu cấu hình kết nối MySQL
    └── run_demo.bat                                        # Script chạy nhanh demo trên Windows
```

---

## Hướng dẫn chạy hệ thống

### 1. Khởi tạo Cơ sở dữ liệu (MySQL 8.0 / MySQL Workbench)
Chạy tuần tự 5 script trong thư mục `Phase3/sql/`:
1. `01_ddl_schema.sql` — Tạo database `supply_chain_logistics_db`, 14 bảng và 7 secondary indexes.
2. `02_views_and_triggers.sql` — Khởi tạo 3 views nghiệp vụ và 116 triggers bảo vệ toàn vẹn dữ liệu.
3. `03_dml_mock_data.sql` — Nạp dữ liệu mẫu.
4. `04_complex_queries.sql` — Chạy 12 câu truy vấn phân tích & kiểm thử hiệu năng `EXPLAIN`.
5. `05_verification_and_rbac.sql` — Kiểm thử các test case chặn dữ liệu lỗi (`TC1–TC16`) và thiết lập phân quyền RBAC.

### 2. Chạy ứng dụng Web Demo (Phase 4 — Flask + MySQL 8.0)
1. Vào thư mục `Phase4/`, copy file `.env.example` thành `.env` và điền `MYSQL_PASSWORD` của máy bạn.
2. Chạy `run_demo.bat` (hoặc chạy lệnh `uv run app.py` / `python app.py`).
3. Mở trình duyệt tại **`http://127.0.0.1:5000`**.

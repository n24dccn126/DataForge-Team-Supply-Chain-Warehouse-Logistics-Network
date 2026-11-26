# Project #6 — Supply Chain & Warehouse Logistics Network

Đồ án môn **INT1313 — Cơ sở dữ liệu (Databases)** · Học kỳ 1, Năm học 2026–2027 (PTIT HCM).

> **Stack & Chuẩn thiết kế:** MySQL 8.0+ (InnoDB) · Elmasri & Navathe (Option 8A) · BCNF · IE Crow's Foot · ISO/IEC/IEEE 29148 · ISO/IEC 11179 · SQLStyle.guide · Python / Flask + PyMySQL

---

## Team DATAFORGE

| Thành viên | MSSV | Email | Phụ trách chính |
| :--- | :--- | :--- | :--- |
| **Trần Gia Huy** | `n24dccn126` | `n24dccn126@student.ptithcm.edu.vn` | Phân tích SRS (ISO/IEC/IEEE 29148), thiết kế EER & Logical Schema Mapping (Elmasri Option 8A), quản lý GitHub repo |
| **Lê Huy Khánh** | `n24dccn132` | `n24dccn132@student.ptithcm.edu.vn` | Chứng minh chuẩn hóa BCNF, Data Dictionary (ISO/IEC 11179), DDL/Indexes, Verification Test Cases (`TC1–TC24`) & RBAC |
| **Nguyễn Minh Khôi** | `n24dccn135` | `n24dccn135@student.ptithcm.edu.vn` | 2 DB Challenges (Recursive CTE BOM & 24 Triggers Restock/Inventory/Capacity/Catalog), 12 Complex Queries, Web App Flask + MySQL |

---

## Tổng quan bài toán & 2 Thách thức CSDL trọng tâm

- **Bối cảnh:** Quản lý tồn kho thời gian thực trên mạng lưới nhiều kho hàng khu vực (`warehouse`), quản lý danh mục cung ứng & đơn đặt hàng nhà cung cấp (`purchase_order`, `goods_receipt`), cấu trúc lắp ráp sản phẩm đa cấp và theo dõi vận chuyển hai chiều gồm chuyển kho nội bộ (`warehouse_transfer`) và giao hàng khách hàng (`customer_delivery`).
- **2 Thách thức CSDL trọng tâm:**
  1. **Quan hệ đệ quy nhiều cấp (Recursive BOM):** Biểu diễn cấu trúc lắp ráp sản phẩm (`product_component`), phân rã định mức & truy vấn ngược *where-used* bằng `WITH RECURSIVE`, đồng thời chặn vòng lặp trực tiếp/gián tiếp bằng trigger đệ quy (**BR4**).
  2. **Trigger kiểm soát tồn kho, sức chứa & tự động Restock:** Tự động chặn xuất vượt tồn kho (**BR7**), chặn tồn kho âm (**BR3**), kiểm soát sức chứa kho (**capacity**), phát sinh cảnh báo qua `v_restock_alerts` và tự động tạo đơn đặt hàng bổ sung (`Pending` PO) khi `quantity_on_hand < reorder_level` (**FR5**).

---

## Điểm nổi bật kỹ thuật (Phase 1 – Phase 4)

| Giai đoạn | Hạng mục triển khai chính |
| :--- | :--- |
| **Phase 1 — Conceptual Design** | Đặc tả SRS chuẩn ISO/IEC/IEEE 29148 (`UR1–UR5`, `FR1–FR7`, `NFR1–NFR7`, `BR1–BR7`); sơ đồ EER gồm **14 thực thể cốt lõi** với Specialization Disjoint + Total (`SHIPMENT`). |
| **Phase 2 — Logical & Physical Design** | Ánh xạ Elmasri 9 bước (**Option 8A** cho `shipment`), chứng minh chuẩn hóa **1NF → 2NF → 3NF → BCNF** cho đủ **14 bảng**, Data Dictionary **62 thuộc tính** (`snake_case` theo ISO/IEC 11179), **19 khóa ngoại** (gồm Composite FK `fk_gr_supplier_product`) và **7 Secondary Indexes** (5 composite + 2 đơn cột). |
| **Phase 3 — MySQL 8.0 Implementation** | **3 Business Views** (`v_restock_alerts`, `v_warehouse_inventory_summary`, `v_shipment_tracking_overview`), **24 Triggers** (BR1–BR7, FR5, Capacity, khóa PO đóng, chặn PO/Shipment rỗng, danh mục NCC), bộ dữ liệu **1.768 bản ghi**, **12 Complex Queries (`Q1–Q12`)** kèm `EXPLAIN`, **24 Test Cases (`TC1–TC24`)**, **6 RBAC Roles** (có Column-Level Privilege ẩn PII) & minh họa mã hóa **AES-256-CBC** (`NFR2`). |
| **Phase 4 — Web Application Demo** | Backend **Flask + PyMySQL** kết nối trực tiếp MySQL 8.0 với giao dịch ACID (`autocommit=False`) và khóa đồng thời `GET_LOCK` (`NFR6`); Dashboard **5 tab** hỗ trợ phân trang phía server, tìm kiếm động và live demo 2 DB Challenges. |

---

## Cấu trúc Repository

```text
.
├── README.md
├── .gitignore
├── Supply_Chain_Warehouse_Logistics_Report.pdf             # Báo cáo Phase 1 & Phase 2 hoàn chỉnh (22 trang — bản nộp)
├── Phase1/
│   └── EER_Diagram.drawio                                  # Phase 1: File nguồn sơ đồ EER chuẩn Elmasri
├── Phase2/
│   └── Physical_Schema_Diagram.drawio                      # Phase 2: Sơ đồ Quan hệ Vật lý IE Crow's Foot (MySQL 8.0+)
├── Phase3/
│   └── sql/
│       ├── 01_ddl_schema.sql                               # 14 bảng chuẩn BCNF, 62 cột, 19 FKs, CHECK/REGEXP, 7 Secondary Indexes
│       ├── 02_views_and_triggers.sql                       # 3 Views & 24 Triggers (BR1–BR7, FR5, Capacity, PO Catalog, Guard Triggers)
│       ├── 03_dml_mock_data.sql                            # Bộ dữ liệu 1.768 bản ghi (20 kho, 25 NCC, 80 SP, 40 KH, 120 PO, 140 Shipment, 90 GR)
│       ├── 04_complex_queries.sql                          # 12 truy vấn phức tạp Q1–Q12 (WITH RECURSIVE, Window Functions, EXPLAIN)
│       └── 05_verification_and_rbac.sql                    # 24 Test Cases (TC1–TC24), 6 MySQL RBAC Roles & NFR2 AES-256-CBC Demo
└── Phase4/
    ├── app.py                                              # Backend Flask + PyMySQL (ACID Transactions, GET_LOCK, Server-side Pagination)
    ├── templates/index.html                                # Giao diện Web Dashboard 5 tab (FR1–FR7, BR1–BR7)
    ├── pyproject.toml                                      # Khai báo thư viện Python (Flask, PyMySQL, python-dotenv)
    ├── .env.example                                        # Mẫu cấu hình kết nối MySQL
    └── run_demo.bat                                        # Script khởi chạy nhanh demo trên Windows
```

---

## Hướng dẫn chạy hệ thống

### 1. Khởi tạo Cơ sở dữ liệu (MySQL 8.0 / MySQL Workbench)
Chạy tuần tự 5 script trong thư mục `Phase3/sql/`:
1. `01_ddl_schema.sql` — Tạo database `supply_chain_logistics_db`, 14 bảng chuẩn BCNF, 19 khóa ngoại và 7 secondary indexes.
2. `02_views_and_triggers.sql` — Khởi tạo 3 views nghiệp vụ và 24 triggers bảo vệ toàn vẹn dữ liệu.
3. `03_dml_mock_data.sql` — Nạp bộ dữ liệu mẫu 1.768 bản ghi trên đủ 14 bảng (20 kho, 25 NCC, 80 sản phẩm, 40 khách hàng, 364 dòng tồn kho, 120 PO / 250 `po_line`, 140 Shipment / 265 `shipment_line`, 90 `goods_receipt`).
4. `04_complex_queries.sql` — Chạy 12 câu truy vấn phân tích (`Q1–Q12`) & kiểm thử hiệu năng bằng `EXPLAIN`.
5. `05_verification_and_rbac.sql` — Chạy 24 test case kiểm chứng ràng buộc (`TC1–TC24`), thiết lập 6 RBAC roles (kèm Column-Level Privilege) và minh họa mã hóa `NFR2` (AES-256-CBC).

### 2. Chạy ứng dụng Web Demo (Phase 4 — Flask + MySQL 8.0)
1. Vào thư mục `Phase4/`, copy file `.env.example` thành `.env` và điền thông tin kết nối (`MYSQL_HOST`, `MYSQL_PORT`, `MYSQL_USER`, `MYSQL_PASSWORD`, `MYSQL_DATABASE`).
2. Chạy `run_demo.bat` (hoặc chạy trực tiếp `uv run app.py` / `python app.py`).
3. Mở trình duyệt tại **`http://127.0.0.1:5000`**.

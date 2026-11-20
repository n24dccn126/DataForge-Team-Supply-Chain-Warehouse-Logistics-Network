-- =============================================================================
-- Project #6: Supply Chain & Warehouse Logistics Network (Team DATAFORGE)
-- Phase 3 — Script 03: Mock Data Insertion (DML)
-- Target DBMS : MySQL 8.0+
-- =============================================================================

USE supply_chain_logistics_db;

-- -----------------------------------------------------------------------------
-- 1. WAREHOUSE (5 Geographical Warehouses across Vietnam)
-- -----------------------------------------------------------------------------
INSERT INTO warehouse (warehouse_id, name, address, manager, capacity) VALUES
    ('WH-000001', 'Kho Trung Tam TP.HCM',  'KCN Tan Binh, Quan Tan Phu, TP.HCM',          'Nguyen Van An',   50000),
    ('WH-000002', 'Kho Mien Bac Ha Noi',   'KCN Bac Thang Long, Dong Anh, Ha Noi',        'Tran Thi Bich',   40000),
    ('WH-000003', 'Kho Mien Trung Da Nang','KCN Hoa Khanh, Lien Chieu, Da Nang',          'Le Hoang Cuong',  25000),
    ('WH-000004', 'Kho DBSCL Can Tho',     'KCN Tra Noc 1, Binh Thuy, Can Tho',           'Pham Minh Dung',  20000),
    ('WH-000005', 'Kho Cang Hai Phong',    'KCN Dinh Vu, Hai An, Hai Phong',              'Vo Thanh Em',     35000);

-- -----------------------------------------------------------------------------
-- 2. SUPPLIER (5 Suppliers)
-- -----------------------------------------------------------------------------
INSERT INTO supplier (supplier_id, name, contact_email, phone, address) VALUES
    ('SUP-000001', 'VietTech Semiconductor JSC',  'sales@viettech-semi.vn',     '028-3811-1001', 'Khu Cong Nghe Cao, TP. Thu Duc, TP.HCM'),
    ('SUP-000002', 'Saigon Carbon & Composites',  'orders@saigoncarbon.vn',     '028-3822-2002', 'KCN Hiep Phuoc, Nha Be, TP.HCM'),
    ('SUP-000003', 'HaNoi Precision Motors Ltd',  'supply@hanoimotors.vn',      '024-3711-3003', 'KCN Quang Minh, Me Linh, Ha Noi'),
    ('SUP-000004', 'Mekong Power Cells Co.',      'contact@mekongcells.vn',     '0292-3844-4004','KCN Hung Phu, Cai Rang, Can Tho'),
    ('SUP-000005', 'Asia Global Optics & LiDAR',  'b2b@asiaoptics.com',         '0236-3855-5005','KCN An Don, Son Tra, Da Nang');

-- -----------------------------------------------------------------------------
-- 3. PRODUCT (12 Products forming a 3-Level Recursive BOM Hierarchy)
--    Level 0 (Finished Goods) : PRD-000001 (Logistics Drone X1), PRD-000002 (AGV Warehouse Robot)
--    Level 1 (Sub-Assemblies) : PRD-000003 (Flight Controller), PRD-000004 (Battery Pack 48V),
--                               PRD-000005 (Carbon Frame Kit), PRD-000006 (Propulsion Unit)
--    Level 2 (Raw Components) : PRD-000007..PRD-000012
-- -----------------------------------------------------------------------------
INSERT INTO product (product_id, name, category, unit_price, reorder_level, reorder_qty) VALUES
    ('PRD-000001', 'Smart Logistics Drone X1',      'Finished Good', 2500.00,  15,  30),
    ('PRD-000002', 'Autonomous AGV Robot V2',       'Finished Good', 4200.00,  10,  20),
    ('PRD-000003', 'Flight Controller Module FC9',  'Sub-Assembly',   320.00,  40,  80),
    ('PRD-000004', 'Lithium Battery Pack 48V',      'Sub-Assembly',   450.00,  50, 100),
    ('PRD-000005', 'Carbon Fiber Frame Kit',        'Sub-Assembly',   280.00,  35,  70),
    ('PRD-000006', 'Brushless Propulsion Unit',     'Sub-Assembly',   190.00,  60, 120),
    ('PRD-000007', 'STM32H7 Microcontroller Chip',  'Raw Component',   25.00, 200, 500),
    ('PRD-000008', 'IMU 9-Axis Gyro Sensor',        'Raw Component',   18.50, 150, 400),
    ('PRD-000009', 'Lithium Cell 21700 5000mAh',    'Raw Component',    6.50, 500, 1500),
    ('PRD-000010', 'Smart BMS Protection PCB',      'Raw Component',   32.00, 120, 300),
    ('PRD-000011', 'Carbon Fiber Tube 25mm',        'Raw Component',   14.00, 300, 600),
    ('PRD-000012', '360-Degree LiDAR Scanner',      'Raw Component',  210.00,  30,  60);

-- -----------------------------------------------------------------------------
-- 4. CUSTOMER (5 B2B Customers)
-- -----------------------------------------------------------------------------
INSERT INTO customer (customer_id, name, address, contact_email, phone) VALUES
    ('CUS-000001', 'Giao Hang Nhanh Express',   '155 Phan Xich Long, Phu Nhuan, TP.HCM', 'procurement@ghn-demo.vn',    '028-7300-1111'),
    ('CUS-000002', 'Viettel Post Logistics',    '1 Giang Van Minh, Ba Dinh, Ha Noi',     'supply@vtp-demo.vn',         '024-6270-2222'),
    ('CUS-000003', 'Tiki Smart Fulfillment',    '52 Ut Tich, Tan Binh, TP.HCM',          'ops@tiki-demo.vn',           '028-7305-3333'),
    ('CUS-000004', 'Shopee Xpress Central Hub', 'KCN Hoa Cam, Cam Le, Da Nang',          'warehouse@spx-demo.vn',      '0236-7309-4444'),
    ('CUS-000005', 'Gemadept Port Operations',  'So 6 Le Thanh Tong, Ngo Quyen, HP',     'tech@gemadept-demo.vn',      '0225-3836-5555');

-- -----------------------------------------------------------------------------
-- 5. PRODUCT_COMPONENT (3-Level Recursive Bill of Materials — 14 Edges)
-- -----------------------------------------------------------------------------
INSERT INTO product_component (parent_product_id, component_product_id, quantity_required) VALUES
    -- Level 0 -> Level 1 (Smart Logistics Drone X1)
    ('PRD-000001', 'PRD-000003', 1),  -- 1x Flight Controller Module
    ('PRD-000001', 'PRD-000004', 1),  -- 1x Battery Pack 48V
    ('PRD-000001', 'PRD-000005', 1),  -- 1x Carbon Fiber Frame Kit
    ('PRD-000001', 'PRD-000006', 4),  -- 4x Brushless Propulsion Units
    ('PRD-000001', 'PRD-000012', 1),  -- 1x LiDAR Scanner
    -- Level 0 -> Level 1 (Autonomous AGV Robot V2)
    ('PRD-000002', 'PRD-000003', 1),  -- 1x Controller Module
    ('PRD-000002', 'PRD-000004', 2),  -- 2x Battery Pack 48V
    ('PRD-000002', 'PRD-000012', 2),  -- 2x LiDAR Scanners
    -- Level 1 -> Level 2 (Sub-Assemblies -> Raw Components)
    ('PRD-000003', 'PRD-000007', 2),  -- Flight Controller needs 2x STM32H7
    ('PRD-000003', 'PRD-000008', 1),  -- Flight Controller needs 1x IMU Gyro
    ('PRD-000004', 'PRD-000009', 16), -- Battery Pack 48V needs 16x Lithium Cells
    ('PRD-000004', 'PRD-000010', 1),  -- Battery Pack 48V needs 1x BMS PCB
    ('PRD-000005', 'PRD-000011', 6),  -- Carbon Frame Kit needs 6x Carbon Tubes
    ('PRD-000006', 'PRD-000007', 1);  -- Propulsion Unit ESC needs 1x STM32H7

-- -----------------------------------------------------------------------------
-- 6. SUPPLIER_PRODUCT (Multiple Suppliers per Product for FR6 Comparison)
-- -----------------------------------------------------------------------------
INSERT INTO supplier_product (supplier_id, product_id, supply_cost, lead_time_days) VALUES
    ('SUP-000001', 'PRD-000003', 260.00, 5),
    ('SUP-000001', 'PRD-000007',  19.50, 4),
    ('SUP-000001', 'PRD-000008',  14.00, 4),
    ('SUP-000001', 'PRD-000010',  25.00, 6),
    ('SUP-000002', 'PRD-000005', 220.00, 7),
    ('SUP-000002', 'PRD-000011',  10.50, 3),
    ('SUP-000003', 'PRD-000006', 145.00, 5),
    ('SUP-000003', 'PRD-000007',  21.00, 2), -- Faster but slightly pricier than SUP-000001
    ('SUP-000003', 'PRD-000008',  15.20, 3),
    ('SUP-000004', 'PRD-000004', 370.00, 6),
    ('SUP-000004', 'PRD-000009',   5.10, 4),
    ('SUP-000004', 'PRD-000010',  23.50, 5), -- Cheaper BMS PCB than SUP-000001
    ('SUP-000005', 'PRD-000012', 175.00, 8),
    ('SUP-000005', 'PRD-000003', 275.00, 3), -- Faster Flight Controller than SUP-000001
    ('SUP-000005', 'PRD-000001', 2100.00, 12),
    ('SUP-000003', 'PRD-000002', 3600.00, 14);

-- -----------------------------------------------------------------------------
-- 7. INVENTORY (22 Rows across 5 Warehouses — Several Below ReorderLevel for FR5)
-- -----------------------------------------------------------------------------
INSERT INTO inventory (warehouse_id, product_id, quantity_on_hand) VALUES
    -- WH-000001 (TP.HCM — Main Assembly Hub)
    ('WH-000001', 'PRD-000001',  45),
    ('WH-000001', 'PRD-000002',  22),
    ('WH-000001', 'PRD-000003',  60),
    ('WH-000001', 'PRD-000004',  35), -- Below reorder_level (50) -> Restock Alert!
    ('WH-000001', 'PRD-000005',  50),
    ('WH-000001', 'PRD-000006', 120),
    ('WH-000001', 'PRD-000007', 650),
    ('WH-000001', 'PRD-000008', 240),
    ('WH-000001', 'PRD-000009', 960),
    ('WH-000001', 'PRD-000010', 180),
    ('WH-000001', 'PRD-000011', 420),
    ('WH-000001', 'PRD-000012',  45),
    -- WH-000002 (Ha Noi)
    ('WH-000002', 'PRD-000001',  12), -- Below reorder_level (15) -> Restock Alert!
    ('WH-000002', 'PRD-000002',  18),
    ('WH-000002', 'PRD-000006',  40), -- Below reorder_level (60) -> Restock Alert!
    ('WH-000002', 'PRD-000007', 150), -- Below reorder_level (200) -> Restock Alert!
    ('WH-000002', 'PRD-000012',  35),
    -- WH-000003 (Da Nang)
    ('WH-000003', 'PRD-000001',  20),
    ('WH-000003', 'PRD-000004',  55),
    ('WH-000003', 'PRD-000012',  18), -- Below reorder_level (30) -> Restock Alert!
    -- WH-000004 (Can Tho)
    ('WH-000004', 'PRD-000004',  90),
    ('WH-000004', 'PRD-000009', 1800),
    -- WH-000005 (Hai Phong)
    ('WH-000005', 'PRD-000002',  14),
    ('WH-000005', 'PRD-000011', 260); -- Below reorder_level (300) -> Restock Alert!

-- -----------------------------------------------------------------------------
-- 8. PURCHASE_ORDER & 9. PO_LINE (6 POs, 11 Lines — Inserted before Shipments)
-- -----------------------------------------------------------------------------
INSERT INTO purchase_order (po_id, supplier_id, warehouse_id, order_date, expected_delivery_date, status) VALUES
    ('PO-000001', 'SUP-000001', 'WH-000001', '2026-09-10', '2026-09-15', 'Received'),
    ('PO-000002', 'SUP-000004', 'WH-000001', '2026-09-18', '2026-09-24', 'Received'),
    ('PO-000003', 'SUP-000002', 'WH-000005', '2026-10-05', '2026-10-12', 'Ordered'),
    ('PO-000004', 'SUP-000003', 'WH-000002', '2026-10-12', '2026-10-17', 'Approved'),
    ('PO-000005', 'SUP-000005', 'WH-000003', '2026-10-20', '2026-10-28', 'Pending'),
    ('PO-000006', 'SUP-000001', 'WH-000002', '2026-10-25', '2026-10-30', 'Cancelled');

INSERT INTO po_line (po_id, product_id, quantity_ordered, unit_cost) VALUES
    ('PO-000001', 'PRD-000007', 500,  19.00), -- Historical negotiated cost < current 19.50
    ('PO-000001', 'PRD-000008', 300,  13.80),
    ('PO-000002', 'PRD-000009', 1500,  5.00),
    ('PO-000002', 'PRD-000010', 250,  23.50),
    ('PO-000003', 'PRD-000011', 600,  10.50),
    ('PO-000003', 'PRD-000005',  50, 220.00),
    ('PO-000004', 'PRD-000006', 100, 145.00),
    ('PO-000004', 'PRD-000007', 400,  21.00),
    ('PO-000005', 'PRD-000012',  60, 175.00),
    ('PO-000005', 'PRD-000003',  40, 275.00),
    ('PO-000006', 'PRD-000007', 200,  19.50);

-- -----------------------------------------------------------------------------
-- 10. SHIPMENT, 11. WAREHOUSE_TRANSFER, 12. CUSTOMER_DELIVERY, 13. SHIPMENT_LINE
-- -----------------------------------------------------------------------------
INSERT INTO shipment (shipment_id, origin_warehouse_id, carrier_name, ship_date, delivery_date, status, shipment_type) VALUES
    ('SHP-000001', 'WH-000001', 'DataForge Internal Fleet', '2026-10-01 08:00:00', '2026-10-03 14:30:00', 'Delivered',  'WAREHOUSE_TRANSFER'),
    ('SHP-000002', 'WH-000004', 'Mekong Freight Co.',       '2026-10-15 09:15:00', NULL,                  'In Transit', 'WAREHOUSE_TRANSFER'),
    ('SHP-000003', 'WH-000001', 'VietCargo Air',            '2026-11-01 10:00:00', NULL,                  'Pending',    'WAREHOUSE_TRANSFER'),
    ('SHP-000004', 'WH-000001', 'GHN Heavy Express',        '2026-10-08 07:30:00', '2026-10-09 16:00:00', 'Delivered',  'CUSTOMER_DELIVERY'),
    ('SHP-000005', 'WH-000002', 'Viettel Post Cargo',       '2026-10-22 11:00:00', '2026-10-24 10:20:00', 'Delivered',  'CUSTOMER_DELIVERY'),
    ('SHP-000006', 'WH-000003', 'Central Express Logistics','2026-11-05 13:45:00', NULL,                  'In Transit', 'CUSTOMER_DELIVERY');

INSERT INTO warehouse_transfer (shipment_id, dest_warehouse_id) VALUES
    ('SHP-000001', 'WH-000003'),
    ('SHP-000002', 'WH-000001'),
    ('SHP-000003', 'WH-000002');

INSERT INTO customer_delivery (shipment_id, customer_id) VALUES
    ('SHP-000004', 'CUS-000001'),
    ('SHP-000005', 'CUS-000002'),
    ('SHP-000006', 'CUS-000004');

-- Note: Inserting shipment_line validates stock & deducts inventory via Trigger 4!
INSERT INTO shipment_line (shipment_id, product_id, quantity_shipped) VALUES
    ('SHP-000001', 'PRD-000001',  5),
    ('SHP-000001', 'PRD-000005', 10),
    ('SHP-000002', 'PRD-000004', 20),
    ('SHP-000002', 'PRD-000009', 300),
    ('SHP-000003', 'PRD-000001',  8),
    ('SHP-000004', 'PRD-000001',  6),
    ('SHP-000004', 'PRD-000002',  4),
    ('SHP-000005', 'PRD-000002',  5),
    ('SHP-000006', 'PRD-000001',  4);

-- -----------------------------------------------------------------------------
-- 14. GOODS_RECEIPT (6 Receipts linked to valid supplier_product pairs)
-- -----------------------------------------------------------------------------
INSERT INTO goods_receipt (receipt_id, warehouse_id, supplier_id, product_id, receipt_date, status) VALUES
    ('GR-000001', 'WH-000001', 'SUP-000001', 'PRD-000007', '2026-09-14 10:00:00', 'Completed'),
    ('GR-000002', 'WH-000001', 'SUP-000001', 'PRD-000008', '2026-09-14 10:30:00', 'Completed'),
    ('GR-000003', 'WH-000001', 'SUP-000004', 'PRD-000009', '2026-09-23 15:10:00', 'Completed'),
    ('GR-000004', 'WH-000001', 'SUP-000004', 'PRD-000010', '2026-09-23 15:45:00', 'Inspected'),
    ('GR-000005', 'WH-000005', 'SUP-000002', 'PRD-000011', '2026-10-11 09:20:00', 'Rejected'),
    ('GR-000006', 'WH-000003', 'SUP-000005', 'PRD-000012', '2026-10-27 14:00:00', 'Pending');

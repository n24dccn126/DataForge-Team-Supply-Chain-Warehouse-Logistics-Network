-- =============================================================================
-- Project #6: Supply Chain & Warehouse Logistics Network (Team DATAFORGE)
-- Phase 3 — Script 05: Verification Test Cases (5.1) & RBAC Security (5.2)
-- Target DBMS : MySQL 8.0+
-- =============================================================================

USE supply_chain_logistics_db;

-- =============================================================================
-- SECTION 5.1: CONSTRAINT & TRIGGER VERIFICATION TEST CASES (BAD DATA TESTS)
-- Note: Execute each negative test case individually to observe the expected
--       SQL error proving that constraints & triggers block bad data.
-- =============================================================================

-- TC1: Invalid Primary Key Format (Expected: ERROR 3819 — chk_warehouse_id_fmt)
-- INSERT INTO warehouse (warehouse_id, name, address, manager, capacity)
-- VALUES ('BAD-123', 'Kho Sai Ma', 'Dia chi test', 'Tester', 1000);

-- TC2: Negative Inventory Quantity — BR3 & NFR3 (Expected: ERROR 1264 — Out of range UNSIGNED)
-- UPDATE inventory
-- SET quantity_on_hand = -10
-- WHERE warehouse_id = 'WH-000001' AND product_id = 'PRD-000001';

-- TC3: Non-Positive Supply Cost / Lead Time — BR6 (Expected: ERROR 3819 — chk_sp_supply_cost)
-- INSERT INTO supplier_product (supplier_id, product_id, supply_cost, lead_time_days)
-- VALUES ('SUP-000001', 'PRD-000001', 0.00, 5);

-- TC4: Direct Self-Loop in BOM — BR4 Trigger (Expected: ERROR 1644 (45000) — direct component of itself)
-- INSERT INTO product_component (parent_product_id, component_product_id, quantity_required)
-- VALUES ('PRD-000001', 'PRD-000001', 1);

-- TC5: Indirect 3-Level Cycle in BOM — BR4 Recursive Trigger
--      Existing chain: PRD-000001 -> PRD-000003 -> PRD-000007
--      Attempting:     PRD-000007 -> PRD-000001 (creates cycle!)
--      Expected: ERROR 1644 (45000) — BR4 Violation: Circular dependency detected
-- INSERT INTO product_component (parent_product_id, component_product_id, quantity_required)
-- VALUES ('PRD-000007', 'PRD-000001', 1);

-- TC6: Warehouse Transfer to Same Warehouse — BR2 Trigger
--      SHP-000001 has origin_warehouse_id = 'WH-000001'
--      Expected: ERROR 1644 (45000) — BR2 Violation: Destination warehouse cannot be same as origin
-- INSERT INTO shipment (shipment_id, origin_warehouse_id, carrier_name, status, shipment_type)
-- VALUES ('SHP-999901', 'WH-000001', 'Test Fleet', 'Pending', 'WAREHOUSE_TRANSFER');
-- INSERT INTO warehouse_transfer (shipment_id, dest_warehouse_id)
-- VALUES ('SHP-999901', 'WH-000001');

-- TC7: Disjoint Subtype Violation — BR1 Trigger
--      SHP-000004 is a 'CUSTOMER_DELIVERY'; inserting into warehouse_transfer must fail!
--      Expected: ERROR 1644 (45000) — BR1 Violation: Shipment must have shipment_type = WAREHOUSE_TRANSFER
-- INSERT INTO warehouse_transfer (shipment_id, dest_warehouse_id)
-- VALUES ('SHP-000004', 'WH-000002');

-- TC8: Over-Shipping Beyond Available Inventory — BR7 Trigger
--      WH-000001 has < 9999 units of PRD-000001
--      Expected: ERROR 1644 (45000) — BR7 Violation: Insufficient inventory quantity_on_hand
-- INSERT INTO shipment_line (shipment_id, product_id, quantity_shipped)
-- VALUES ('SHP-000003', 'PRD-000002', 9999);

-- TC9: Purchase Order without Valid Supplier or Warehouse — BR5 (Expected: ERROR 1048 / 1452)
-- INSERT INTO purchase_order (po_id, supplier_id, warehouse_id, status)
-- VALUES ('PO-999901', NULL, 'WH-000001', 'Pending');

-- TC10: Positive Trigger Verification — FR5 Automatic Restock PO & Alert
--       Drop WH-000001 stock of PRD-000005 (reorder_level = 35, current = 40) to 20:
--       Expected:
--         1) Row appears in v_restock_alerts
--         2) Trigger 5 automatically inserts a new 'Pending' PO + PO_LINE for SUP-000002 (qty = 70)
START TRANSACTION;
    UPDATE inventory
    SET quantity_on_hand = 20
    WHERE warehouse_id = 'WH-000001'
      AND product_id = 'PRD-000005';

    SELECT * FROM v_restock_alerts
    WHERE warehouse_id = 'WH-000001'
      AND product_id = 'PRD-000005';

    SELECT po.po_id, po.supplier_id, po.warehouse_id, po.status, pol.product_id, pol.quantity_ordered, pol.unit_cost
    FROM purchase_order AS po
    INNER JOIN po_line AS pol ON po.po_id = pol.po_id
    WHERE po.warehouse_id = 'WH-000001'
      AND pol.product_id = 'PRD-000005'
      AND po.status = 'Pending';
ROLLBACK;

-- TC11: Bypassing BR4 via UPDATE on product_component (Expected: ERROR 1644 — Trigger 1b)
-- UPDATE product_component SET component_product_id = parent_product_id
-- WHERE parent_product_id = 'PRD-000006' AND component_product_id = 'PRD-000007';

-- TC12: Reverting a Delivered shipment back to Pending (Expected: ERROR 1644 — Trigger 6b)
-- UPDATE shipment SET status = 'Pending' WHERE shipment_id = 'SHP-000001';

-- TC13: Inserting a new shipment directly as 'Delivered' (Expected: ERROR 1644 — Trigger 6a)
-- INSERT INTO shipment (shipment_id, origin_warehouse_id, carrier_name, status, shipment_type)
-- VALUES ('SHP-999902', 'WH-000001', 'Test Fleet', 'Delivered', 'CUSTOMER_DELIVERY');

-- TC14: Deleting an undelivered shipment restores origin inventory (Positive Test — Trigger 6d)
START TRANSACTION;
    SELECT quantity_on_hand AS before_delete FROM inventory
    WHERE warehouse_id = 'WH-000001' AND product_id = 'PRD-000001';

    DELETE FROM shipment WHERE shipment_id = 'SHP-000003'; -- Pending transfer of 8x PRD-000001

    SELECT quantity_on_hand AS after_delete_restored_plus_8 FROM inventory
    WHERE warehouse_id = 'WH-000001' AND product_id = 'PRD-000001';
ROLLBACK;

-- TC15: Receiving a Purchase Order credits receiving warehouse inventory (Positive Test — Trigger 7c)
START TRANSACTION;
    SELECT quantity_on_hand AS before_po_receive FROM inventory
    WHERE warehouse_id = 'WH-000005' AND product_id = 'PRD-000011';

    UPDATE purchase_order SET status = 'Received' WHERE po_id = 'PO-000003'; -- +600x PRD-000011

    SELECT quantity_on_hand AS after_po_receive_plus_600 FROM inventory
    WHERE warehouse_id = 'WH-000005' AND product_id = 'PRD-000011';
ROLLBACK;

-- TC16: Reverting a Received PO back to Ordered (Expected: ERROR 1644 — Trigger 7b)
-- UPDATE purchase_order SET status = 'Ordered' WHERE po_id = 'PO-000001';


-- =============================================================================
-- SECTION 5.2: ROLE-BASED ACCESS CONTROL (RBAC — MySQL 8.0 Roles)
-- Mapped directly to Phase 1 Actors (FR1-FR7) & Security Requirement (NFR2)
-- =============================================================================

-- 1. Create Roles (Idempotent)
CREATE ROLE IF NOT EXISTS
    'role_db_admin',
    'role_warehouse_manager',
    'role_purchasing_staff',
    'role_warehouse_staff',
    'role_product_manager',
    'role_auditor_readonly';

-- 2. Grant Privileges per Role (Principle of Least Privilege)

-- (a) Database Administrator: Full schema & data management
GRANT ALL PRIVILEGES ON supply_chain_logistics_db.* TO 'role_db_admin';

-- (b) Warehouse Manager (FR1, FR3, FR7): Manage warehouses, real-time inventory, shipments & receipts
GRANT SELECT, INSERT, UPDATE ON supply_chain_logistics_db.warehouse TO 'role_warehouse_manager';
GRANT SELECT, INSERT, UPDATE ON supply_chain_logistics_db.inventory TO 'role_warehouse_manager';
GRANT SELECT, INSERT, UPDATE ON supply_chain_logistics_db.shipment TO 'role_warehouse_manager';
GRANT SELECT, INSERT, UPDATE ON supply_chain_logistics_db.warehouse_transfer TO 'role_warehouse_manager';
GRANT SELECT, INSERT, UPDATE ON supply_chain_logistics_db.customer_delivery TO 'role_warehouse_manager';
GRANT SELECT, INSERT, UPDATE ON supply_chain_logistics_db.shipment_line TO 'role_warehouse_manager';
GRANT SELECT, INSERT, UPDATE ON supply_chain_logistics_db.goods_receipt TO 'role_warehouse_manager';
GRANT SELECT ON supply_chain_logistics_db.product TO 'role_warehouse_manager';
GRANT SELECT ON supply_chain_logistics_db.v_restock_alerts TO 'role_warehouse_manager';
GRANT SELECT ON supply_chain_logistics_db.v_warehouse_inventory_summary TO 'role_warehouse_manager';
GRANT SELECT ON supply_chain_logistics_db.v_shipment_tracking_overview TO 'role_warehouse_manager';

-- (c) Purchasing Staff (FR2, FR6): Manage POs & supplier catalogs; NO access to customer PII (NFR2)
GRANT SELECT, INSERT, UPDATE ON supply_chain_logistics_db.purchase_order TO 'role_purchasing_staff';
GRANT SELECT, INSERT, UPDATE ON supply_chain_logistics_db.po_line TO 'role_purchasing_staff';
GRANT SELECT, INSERT, UPDATE ON supply_chain_logistics_db.supplier_product TO 'role_purchasing_staff';
GRANT SELECT ON supply_chain_logistics_db.supplier TO 'role_purchasing_staff';
GRANT SELECT ON supply_chain_logistics_db.product TO 'role_purchasing_staff';
GRANT SELECT ON supply_chain_logistics_db.warehouse TO 'role_purchasing_staff';
GRANT SELECT ON supply_chain_logistics_db.inventory TO 'role_purchasing_staff';
GRANT SELECT ON supply_chain_logistics_db.v_restock_alerts TO 'role_purchasing_staff';

-- (d) Warehouse Staff (FR3, FR7): Process shipments & goods receipts; read-only on inventory/products
GRANT SELECT, INSERT, UPDATE ON supply_chain_logistics_db.shipment TO 'role_warehouse_staff';
GRANT SELECT, INSERT, UPDATE ON supply_chain_logistics_db.warehouse_transfer TO 'role_warehouse_staff';
GRANT SELECT, INSERT, UPDATE ON supply_chain_logistics_db.customer_delivery TO 'role_warehouse_staff';
GRANT SELECT, INSERT, UPDATE ON supply_chain_logistics_db.shipment_line TO 'role_warehouse_staff';
GRANT SELECT, INSERT, UPDATE ON supply_chain_logistics_db.goods_receipt TO 'role_warehouse_staff';
GRANT SELECT ON supply_chain_logistics_db.inventory TO 'role_warehouse_staff';
GRANT SELECT ON supply_chain_logistics_db.product TO 'role_warehouse_staff';
GRANT SELECT ON supply_chain_logistics_db.warehouse TO 'role_warehouse_staff';
GRANT SELECT ON supply_chain_logistics_db.v_shipment_tracking_overview TO 'role_warehouse_staff';

-- (e) Product Manager (FR4): Manage product catalog & recursive BOM structure
GRANT SELECT, INSERT, UPDATE, DELETE ON supply_chain_logistics_db.product TO 'role_product_manager';
GRANT SELECT, INSERT, UPDATE, DELETE ON supply_chain_logistics_db.product_component TO 'role_product_manager';
GRANT SELECT ON supply_chain_logistics_db.inventory TO 'role_product_manager';
GRANT SELECT ON supply_chain_logistics_db.supplier_product TO 'role_product_manager';

-- (f) Read-Only Auditor: Analytics & Views only, excluding raw Customer/Supplier PII (NFR2)
GRANT SELECT ON supply_chain_logistics_db.warehouse TO 'role_auditor_readonly';
GRANT SELECT ON supply_chain_logistics_db.product TO 'role_auditor_readonly';
GRANT SELECT ON supply_chain_logistics_db.product_component TO 'role_auditor_readonly';
GRANT SELECT ON supply_chain_logistics_db.inventory TO 'role_auditor_readonly';
GRANT SELECT ON supply_chain_logistics_db.purchase_order TO 'role_auditor_readonly';
GRANT SELECT ON supply_chain_logistics_db.po_line TO 'role_auditor_readonly';
GRANT SELECT ON supply_chain_logistics_db.v_restock_alerts TO 'role_auditor_readonly';
GRANT SELECT ON supply_chain_logistics_db.v_warehouse_inventory_summary TO 'role_auditor_readonly';
GRANT SELECT ON supply_chain_logistics_db.v_shipment_tracking_overview TO 'role_auditor_readonly';

-- 3. Example User Accounts & Role Assignment (Replace placeholders before production!)
CREATE USER IF NOT EXISTS 'wh_mgr_hcm'@'localhost' IDENTIFIED BY '<CHANGE_ME_WHMGR_PWD>';
CREATE USER IF NOT EXISTS 'buyer_01'@'localhost'   IDENTIFIED BY '<CHANGE_ME_BUYER_PWD>';
CREATE USER IF NOT EXISTS 'staff_01'@'localhost'   IDENTIFIED BY '<CHANGE_ME_STAFF_PWD>';
CREATE USER IF NOT EXISTS 'pm_01'@'localhost'      IDENTIFIED BY '<CHANGE_ME_PM_PWD>';
CREATE USER IF NOT EXISTS 'auditor_01'@'localhost' IDENTIFIED BY '<CHANGE_ME_AUDIT_PWD>';

GRANT 'role_warehouse_manager' TO 'wh_mgr_hcm'@'localhost';
GRANT 'role_purchasing_staff'  TO 'buyer_01'@'localhost';
GRANT 'role_warehouse_staff'   TO 'staff_01'@'localhost';
GRANT 'role_product_manager'   TO 'pm_01'@'localhost';
GRANT 'role_auditor_readonly'  TO 'auditor_01'@'localhost';

SET DEFAULT ROLE ALL TO
    'wh_mgr_hcm'@'localhost',
    'buyer_01'@'localhost',
    'staff_01'@'localhost',
    'pm_01'@'localhost',
    'auditor_01'@'localhost';

-- Explicit REVOKE example: Revoke DELETE privilege on product from Product Manager
-- to prevent accidental catalog deletion while keeping full BOM (product_component) editing.
REVOKE DELETE ON supply_chain_logistics_db.product FROM 'role_product_manager';

FLUSH PRIVILEGES;

-- =============================================================================
-- Project #6: Supply Chain & Warehouse Logistics Network (Team DATAFORGE)
-- Phase 3 — Script 02: Views & Triggers (Business Rules & DB Challenges)
-- Target DBMS : MySQL 8.0+ (InnoDB)
-- =============================================================================

USE supply_chain_logistics_db;

-- =============================================================================
-- PART A: VIEWS (3 Views)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- VIEW 1: v_restock_alerts (FR5 & DB Challenge — Real-time Restock Alerts)
-- Lists every (warehouse, product) below reorder_level with recommended cheapest supplier.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_restock_alerts AS
SELECT
    w.warehouse_id,
    w.name AS warehouse_name,
    p.product_id,
    p.name AS product_name,
    p.category,
    i.quantity_on_hand,
    p.reorder_level,
    (p.reorder_level - i.quantity_on_hand) AS shortage_qty,
    p.reorder_qty AS recommended_order_qty,
    best_sup.supplier_id AS recommended_supplier_id,
    s.name AS recommended_supplier_name,
    best_sup.supply_cost AS best_unit_cost,
    best_sup.lead_time_days,
    i.last_updated
FROM inventory AS i
INNER JOIN warehouse AS w
    ON i.warehouse_id = w.warehouse_id
INNER JOIN product AS p
    ON i.product_id = p.product_id
LEFT JOIN (
    SELECT
        sp.product_id,
        sp.supplier_id,
        sp.supply_cost,
        sp.lead_time_days,
        ROW_NUMBER() OVER (
            PARTITION BY sp.product_id
            ORDER BY sp.supply_cost ASC, sp.lead_time_days ASC
        ) AS rn
    FROM supplier_product AS sp
) AS best_sup
    ON p.product_id = best_sup.product_id
   AND best_sup.rn = 1
LEFT JOIN supplier AS s
    ON best_sup.supplier_id = s.supplier_id
WHERE i.quantity_on_hand < p.reorder_level;

-- -----------------------------------------------------------------------------
-- VIEW 2: v_warehouse_inventory_summary
-- Summarizes total units, capacity utilization %, and stock valuation per warehouse.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_warehouse_inventory_summary AS
SELECT
    w.warehouse_id,
    w.name AS warehouse_name,
    w.manager,
    w.capacity,
    COUNT(i.product_id) AS distinct_skus,
    COALESCE(SUM(i.quantity_on_hand), 0) AS total_units_in_stock,
    ROUND(
        COALESCE(SUM(i.quantity_on_hand), 0) * 100.0 / w.capacity,
        2
    ) AS utilization_pct,
    COALESCE(SUM(i.quantity_on_hand * p.unit_price), 0.00) AS total_stock_value,
    SUM(CASE WHEN i.quantity_on_hand < p.reorder_level THEN 1 ELSE 0 END) AS low_stock_sku_count
FROM warehouse AS w
LEFT JOIN inventory AS i
    ON w.warehouse_id = i.warehouse_id
LEFT JOIN product AS p
    ON i.product_id = p.product_id
GROUP BY w.warehouse_id, w.name, w.manager, w.capacity;

-- -----------------------------------------------------------------------------
-- VIEW 3: v_shipment_tracking_overview (FR3 & FR7 — Unified Polymorphic Tracking)
-- Combines shipment supertype with warehouse_transfer and customer_delivery subtypes.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_shipment_tracking_overview AS
SELECT
    s.shipment_id,
    s.shipment_type,
    s.status,
    s.carrier_name,
    s.origin_warehouse_id,
    w_orig.name AS origin_warehouse_name,
    COALESCE(wt.dest_warehouse_id, cd.customer_id) AS destination_id,
    COALESCE(w_dest.name, c.name) AS destination_name,
    s.ship_date,
    s.delivery_date,
    COALESCE(sl_agg.total_items, 0) AS total_units_shipped,
    COALESCE(sl_agg.distinct_products, 0) AS distinct_products
FROM shipment AS s
INNER JOIN warehouse AS w_orig
    ON s.origin_warehouse_id = w_orig.warehouse_id
LEFT JOIN warehouse_transfer AS wt
    ON s.shipment_id = wt.shipment_id
LEFT JOIN warehouse AS w_dest
    ON wt.dest_warehouse_id = w_dest.warehouse_id
LEFT JOIN customer_delivery AS cd
    ON s.shipment_id = cd.shipment_id
LEFT JOIN customer AS c
    ON cd.customer_id = c.customer_id
LEFT JOIN (
    SELECT
        shipment_id,
        SUM(quantity_shipped) AS total_items,
        COUNT(product_id) AS distinct_products
    FROM shipment_line
    GROUP BY shipment_id
) AS sl_agg
    ON s.shipment_id = sl_agg.shipment_id;

-- =============================================================================
-- PART B: TRIGGERS (22 Triggers Enforcing BR1-BR7, FR2, FR3, FR5, FR7, NFR6)
-- =============================================================================

DELIMITER $$

-- -----------------------------------------------------------------------------
-- TRIGGER 1a: trg_prevent_bom_cycle_insert (BR4 — Direct & Recursive Cycle Guard)
-- Blocks both direct self-loops (A -> A) and indirect cycles (A -> B -> C -> A).
-- -----------------------------------------------------------------------------
CREATE TRIGGER trg_prevent_bom_cycle_insert
BEFORE INSERT ON product_component
FOR EACH ROW
BEGIN
    DECLARE v_cycle_found INT DEFAULT 0;

    IF NEW.parent_product_id = NEW.component_product_id THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'BR4 Violation: A product cannot be a direct component of itself.';
    END IF;

    WITH RECURSIVE bom_descendants AS (
        SELECT
            component_product_id AS node_id,
            1 AS depth
        FROM product_component
        WHERE parent_product_id = NEW.component_product_id

        UNION ALL

        SELECT
            pc.component_product_id AS node_id,
            bd.depth + 1 AS depth
        FROM product_component AS pc
        INNER JOIN bom_descendants AS bd
            ON pc.parent_product_id = bd.node_id
        WHERE bd.depth < 20
    )
    SELECT COUNT(*)
    INTO v_cycle_found
    FROM bom_descendants
    WHERE node_id = NEW.parent_product_id;

    IF v_cycle_found > 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'BR4 Violation: Circular dependency detected in Bill of Materials (product_component).';
    END IF;
END$$

-- -----------------------------------------------------------------------------
-- TRIGGER 1b: trg_prevent_bom_cycle_update (BR4 — Cycle Guard on UPDATE)
-- Prevents bypassing BR4 via UPDATE on product_component.
-- -----------------------------------------------------------------------------
CREATE TRIGGER trg_prevent_bom_cycle_update
BEFORE UPDATE ON product_component
FOR EACH ROW
BEGIN
    DECLARE v_cycle_found INT DEFAULT 0;

    IF NEW.parent_product_id = NEW.component_product_id THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'BR4 Violation: A product cannot be a direct component of itself.';
    END IF;

    IF NEW.parent_product_id <> OLD.parent_product_id
       OR NEW.component_product_id <> OLD.component_product_id THEN
        WITH RECURSIVE bom_descendants AS (
            SELECT
                pc.component_product_id AS node_id,
                1 AS depth
            FROM product_component AS pc
            WHERE pc.parent_product_id = NEW.component_product_id
              AND NOT (pc.parent_product_id = OLD.parent_product_id
                       AND pc.component_product_id = OLD.component_product_id)

            UNION ALL

            SELECT
                pc.component_product_id AS node_id,
                bd.depth + 1 AS depth
            FROM product_component AS pc
            INNER JOIN bom_descendants AS bd
                ON pc.parent_product_id = bd.node_id
            WHERE bd.depth < 20
              AND NOT (pc.parent_product_id = OLD.parent_product_id
                       AND pc.component_product_id = OLD.component_product_id)
        )
        SELECT COUNT(*)
        INTO v_cycle_found
        FROM bom_descendants
        WHERE node_id = NEW.parent_product_id;

        IF v_cycle_found > 0 THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'BR4 Violation: Circular dependency detected on UPDATE in product_component.';
        END IF;
    END IF;
END$$

-- -----------------------------------------------------------------------------
-- TRIGGER 2a: trg_validate_warehouse_transfer_insert (BR1 & BR2)
-- -----------------------------------------------------------------------------
CREATE TRIGGER trg_validate_warehouse_transfer_insert
BEFORE INSERT ON warehouse_transfer
FOR EACH ROW
BEGIN
    DECLARE v_ship_type VARCHAR(30);
    DECLARE v_origin_wh VARCHAR(10);
    DECLARE v_exists_cd INT DEFAULT 0;

    SELECT shipment_type, origin_warehouse_id
    INTO v_ship_type, v_origin_wh
    FROM shipment
    WHERE shipment_id = NEW.shipment_id;

    IF v_ship_type <> 'WAREHOUSE_TRANSFER' THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'BR1 Violation: Shipment must have shipment_type = WAREHOUSE_TRANSFER.';
    END IF;

    SELECT COUNT(*)
    INTO v_exists_cd
    FROM customer_delivery
    WHERE shipment_id = NEW.shipment_id;

    IF v_exists_cd > 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'BR1 Violation: Shipment already exists in customer_delivery (disjoint constraint).';
    END IF;

    IF NEW.dest_warehouse_id = v_origin_wh THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'BR2 Violation: Destination warehouse cannot be the same as origin warehouse.';
    END IF;
END$$

-- -----------------------------------------------------------------------------
-- TRIGGER 2b: trg_validate_warehouse_transfer_update (BR1 & BR2 on UPDATE)
-- -----------------------------------------------------------------------------
CREATE TRIGGER trg_validate_warehouse_transfer_update
BEFORE UPDATE ON warehouse_transfer
FOR EACH ROW
BEGIN
    DECLARE v_ship_type VARCHAR(30);
    DECLARE v_origin_wh VARCHAR(10);
    DECLARE v_status VARCHAR(20);
    DECLARE v_exists_cd INT DEFAULT 0;

    IF NEW.shipment_id <> OLD.shipment_id THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'BR1 Violation: Cannot reassign shipment_id on an existing warehouse_transfer record.';
    END IF;

    SELECT shipment_type, origin_warehouse_id, status
    INTO v_ship_type, v_origin_wh, v_status
    FROM shipment
    WHERE shipment_id = NEW.shipment_id;

    IF v_ship_type <> 'WAREHOUSE_TRANSFER' THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'BR1 Violation: Shipment must have shipment_type = WAREHOUSE_TRANSFER.';
    END IF;

    SELECT COUNT(*)
    INTO v_exists_cd
    FROM customer_delivery
    WHERE shipment_id = NEW.shipment_id;

    IF v_exists_cd > 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'BR1 Violation: Shipment already exists in customer_delivery (disjoint constraint).';
    END IF;

    IF v_status = 'Delivered' THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'State Violation: Cannot modify a Delivered warehouse transfer.';
    END IF;

    IF NEW.dest_warehouse_id = v_origin_wh THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'BR2 Violation: Destination warehouse cannot be the same as origin warehouse.';
    END IF;
END$$

-- -----------------------------------------------------------------------------
-- TRIGGER 2c: trg_prevent_warehouse_transfer_delete (BR1 Total Specialization)
-- Blocks direct deletion of subtype row while parent shipment exists.
-- (Note: Deleting an undelivered parent shipment cascades cleanly because
--  InnoDB FK ON DELETE CASCADE does not activate child table triggers.)
-- -----------------------------------------------------------------------------
CREATE TRIGGER trg_prevent_warehouse_transfer_delete
BEFORE DELETE ON warehouse_transfer
FOR EACH ROW
BEGIN
    SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'BR1 Violation: Cannot delete warehouse_transfer subtype directly while parent shipment exists (total specialization).';
END$$

-- -----------------------------------------------------------------------------
-- TRIGGER 3a: trg_validate_customer_delivery_insert (BR1)
-- -----------------------------------------------------------------------------
CREATE TRIGGER trg_validate_customer_delivery_insert
BEFORE INSERT ON customer_delivery
FOR EACH ROW
BEGIN
    DECLARE v_ship_type VARCHAR(30);
    DECLARE v_exists_wt INT DEFAULT 0;

    SELECT shipment_type
    INTO v_ship_type
    FROM shipment
    WHERE shipment_id = NEW.shipment_id;

    IF v_ship_type <> 'CUSTOMER_DELIVERY' THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'BR1 Violation: Shipment must have shipment_type = CUSTOMER_DELIVERY.';
    END IF;

    SELECT COUNT(*)
    INTO v_exists_wt
    FROM warehouse_transfer
    WHERE shipment_id = NEW.shipment_id;

    IF v_exists_wt > 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'BR1 Violation: Shipment already exists in warehouse_transfer (disjoint constraint).';
    END IF;
END$$

-- -----------------------------------------------------------------------------
-- TRIGGER 3b: trg_validate_customer_delivery_update (BR1 & State Guard on UPDATE)
-- -----------------------------------------------------------------------------
CREATE TRIGGER trg_validate_customer_delivery_update
BEFORE UPDATE ON customer_delivery
FOR EACH ROW
BEGIN
    DECLARE v_ship_type VARCHAR(30);
    DECLARE v_status VARCHAR(20);
    DECLARE v_exists_wt INT DEFAULT 0;

    IF NEW.shipment_id <> OLD.shipment_id THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'BR1 Violation: Cannot reassign shipment_id on an existing customer_delivery record.';
    END IF;

    SELECT shipment_type, status
    INTO v_ship_type, v_status
    FROM shipment
    WHERE shipment_id = NEW.shipment_id;

    IF v_ship_type <> 'CUSTOMER_DELIVERY' THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'BR1 Violation: Shipment must have shipment_type = CUSTOMER_DELIVERY.';
    END IF;

    SELECT COUNT(*)
    INTO v_exists_wt
    FROM warehouse_transfer
    WHERE shipment_id = NEW.shipment_id;

    IF v_exists_wt > 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'BR1 Violation: Shipment already exists in warehouse_transfer (disjoint constraint).';
    END IF;

    IF v_status = 'Delivered' THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'State Violation: Cannot modify a Delivered customer delivery.';
    END IF;
END$$

-- -----------------------------------------------------------------------------
-- TRIGGER 3c: trg_prevent_customer_delivery_delete (BR1 Total Specialization)
-- Blocks direct deletion of subtype row while parent shipment exists.
-- -----------------------------------------------------------------------------
CREATE TRIGGER trg_prevent_customer_delivery_delete
BEFORE DELETE ON customer_delivery
FOR EACH ROW
BEGIN
    SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'BR1 Violation: Cannot delete customer_delivery subtype directly while parent shipment exists (total specialization).';
END$$

-- -----------------------------------------------------------------------------
-- TRIGGER 4a: trg_check_and_deduct_inventory_on_ship (BR7, BR3, BR1 & NFR6 FOR UPDATE)
-- Verifies subtype existence, locks inventory row with FOR UPDATE, validates stock, and deducts atomically.
-- -----------------------------------------------------------------------------
CREATE TRIGGER trg_check_and_deduct_inventory_on_ship
BEFORE INSERT ON shipment_line
FOR EACH ROW
BEGIN
    DECLARE v_origin_wh VARCHAR(10);
    DECLARE v_ship_status VARCHAR(20);
    DECLARE v_ship_type VARCHAR(30);
    DECLARE v_subtype_cnt INT DEFAULT 0;
    DECLARE v_available_qty INT UNSIGNED DEFAULT NULL;

    SELECT origin_warehouse_id, status, shipment_type
    INTO v_origin_wh, v_ship_status, v_ship_type
    FROM shipment
    WHERE shipment_id = NEW.shipment_id;

    IF v_ship_status = 'Delivered' THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'State Violation: Cannot add items to an already Delivered shipment.';
    END IF;

    IF v_ship_type = 'WAREHOUSE_TRANSFER' THEN
        SELECT COUNT(*) INTO v_subtype_cnt
        FROM warehouse_transfer
        WHERE shipment_id = NEW.shipment_id;
    ELSE
        SELECT COUNT(*) INTO v_subtype_cnt
        FROM customer_delivery
        WHERE shipment_id = NEW.shipment_id;
    END IF;

    IF v_subtype_cnt = 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'BR1 Violation: Shipment must have a matching subtype record before adding shipment lines.';
    END IF;

    SELECT quantity_on_hand
    INTO v_available_qty
    FROM inventory
    WHERE warehouse_id = v_origin_wh
      AND product_id = NEW.product_id
    FOR UPDATE;

    IF v_available_qty IS NULL OR NEW.quantity_shipped > v_available_qty THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'BR7 Violation: Insufficient inventory quantity_on_hand at origin warehouse.';
    END IF;

    UPDATE inventory
    SET quantity_on_hand = quantity_on_hand - NEW.quantity_shipped
    WHERE warehouse_id = v_origin_wh
      AND product_id = NEW.product_id;
END$$

-- -----------------------------------------------------------------------------
-- TRIGGER 4b: trg_adjust_inventory_on_ship_line_update (BR7 & Anti-Leak)
-- Adjusts origin warehouse inventory when quantity_shipped is modified before delivery.
-- -----------------------------------------------------------------------------
CREATE TRIGGER trg_adjust_inventory_on_ship_line_update
BEFORE UPDATE ON shipment_line
FOR EACH ROW
BEGIN
    DECLARE v_origin_wh VARCHAR(10);
    DECLARE v_ship_status VARCHAR(20);
    DECLARE v_available_qty INT UNSIGNED DEFAULT NULL;
    DECLARE v_delta INT;

    SELECT origin_warehouse_id, status
    INTO v_origin_wh, v_ship_status
    FROM shipment
    WHERE shipment_id = NEW.shipment_id;

    IF v_ship_status = 'Delivered' THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'State Violation: Cannot update shipment lines after shipment is Delivered.';
    END IF;

    IF NEW.shipment_id <> OLD.shipment_id OR NEW.product_id <> OLD.product_id THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Integrity Violation: Cannot change shipment_id or product_id on an existing shipment_line.';
    END IF;

    SET v_delta = CAST(NEW.quantity_shipped AS SIGNED) - CAST(OLD.quantity_shipped AS SIGNED);

    IF v_delta > 0 THEN
        SELECT quantity_on_hand
        INTO v_available_qty
        FROM inventory
        WHERE warehouse_id = v_origin_wh
          AND product_id = NEW.product_id
        FOR UPDATE;

        IF v_available_qty IS NULL OR v_delta > v_available_qty THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'BR7 Violation: Insufficient inventory for increased shipment quantity.';
        END IF;

        UPDATE inventory
        SET quantity_on_hand = quantity_on_hand - v_delta
        WHERE warehouse_id = v_origin_wh
          AND product_id = NEW.product_id;
    ELSEIF v_delta < 0 THEN
        UPDATE inventory
        SET quantity_on_hand = quantity_on_hand + ABS(v_delta)
        WHERE warehouse_id = v_origin_wh
          AND product_id = NEW.product_id;
    END IF;
END$$

-- -----------------------------------------------------------------------------
-- TRIGGER 4c: trg_restore_inventory_on_ship_line_delete (Anti-Leak on Cancel/Delete)
-- Restores stock to origin warehouse if an undelivered shipment_line is deleted.
-- -----------------------------------------------------------------------------
CREATE TRIGGER trg_restore_inventory_on_ship_line_delete
BEFORE DELETE ON shipment_line
FOR EACH ROW
BEGIN
    DECLARE v_origin_wh VARCHAR(10);
    DECLARE v_ship_status VARCHAR(20);

    SELECT origin_warehouse_id, status
    INTO v_origin_wh, v_ship_status
    FROM shipment
    WHERE shipment_id = OLD.shipment_id;

    IF v_ship_status = 'Delivered' THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'State Violation: Cannot delete shipment lines from an already Delivered shipment.';
    END IF;

    UPDATE inventory
    SET quantity_on_hand = quantity_on_hand + OLD.quantity_shipped
    WHERE warehouse_id = v_origin_wh
      AND product_id = OLD.product_id;
END$$

-- -----------------------------------------------------------------------------
-- TRIGGER 5: trg_auto_restock_po_on_low_inventory (FR5 & DB Challenge)
-- Automatically creates a Pending restock Purchase Order + PO Line whenever
-- quantity_on_hand decreases and is below reorder_level (with duplicate-PO guard).
-- -----------------------------------------------------------------------------
CREATE TRIGGER trg_auto_restock_po_on_low_inventory
AFTER UPDATE ON inventory
FOR EACH ROW
BEGIN
    DECLARE v_reorder_level INT UNSIGNED DEFAULT 0;
    DECLARE v_reorder_qty INT UNSIGNED DEFAULT 1;
    DECLARE v_open_po_count INT DEFAULT 0;
    DECLARE v_best_supplier VARCHAR(10) DEFAULT NULL;
    DECLARE v_best_cost DECIMAL(12,2) DEFAULT NULL;
    DECLARE v_best_lead SMALLINT UNSIGNED DEFAULT 7;
    DECLARE v_next_po_num INT DEFAULT 1;
    DECLARE v_new_po_id VARCHAR(10);

    SELECT reorder_level, reorder_qty
    INTO v_reorder_level, v_reorder_qty
    FROM product
    WHERE product_id = NEW.product_id;

    -- Fire whenever stock drops and is below reorder_level (even if already below)
    IF NEW.quantity_on_hand < v_reorder_level
       AND NEW.quantity_on_hand < OLD.quantity_on_hand THEN

        -- Prevent duplicate open restock POs for the same (warehouse, product)
        SELECT COUNT(*)
        INTO v_open_po_count
        FROM purchase_order AS po
        INNER JOIN po_line AS pol
            ON po.po_id = pol.po_id
        WHERE po.warehouse_id = NEW.warehouse_id
          AND pol.product_id = NEW.product_id
          AND po.status IN ('Pending', 'Approved', 'Ordered');

        IF v_open_po_count = 0 THEN
            SELECT supplier_id, supply_cost, lead_time_days
            INTO v_best_supplier, v_best_cost, v_best_lead
            FROM supplier_product
            WHERE product_id = NEW.product_id
            ORDER BY supply_cost ASC, lead_time_days ASC
            LIMIT 1;

            IF v_best_supplier IS NOT NULL THEN
                SELECT COALESCE(MAX(CAST(SUBSTRING(po_id, 4) AS UNSIGNED)), 0) + 1
                INTO v_next_po_num
                FROM purchase_order
                FOR UPDATE;

                SET v_new_po_id = CONCAT('PO-', LPAD(v_next_po_num, 6, '0'));

                INSERT INTO purchase_order (
                    po_id, supplier_id, warehouse_id, order_date, expected_delivery_date, status
                )
                VALUES (
                    v_new_po_id,
                    v_best_supplier,
                    NEW.warehouse_id,
                    CURRENT_DATE,
                    DATE_ADD(CURRENT_DATE, INTERVAL v_best_lead DAY),
                    'Pending'
                );

                INSERT INTO po_line (po_id, product_id, quantity_ordered, unit_cost)
                VALUES (v_new_po_id, NEW.product_id, v_reorder_qty, v_best_cost);
            END IF;
        END IF;
    END IF;
END$$

-- -----------------------------------------------------------------------------
-- TRIGGER 6a: trg_enforce_initial_shipment_status (Prevents bypassing Delivery trigger)
-- -----------------------------------------------------------------------------
CREATE TRIGGER trg_enforce_initial_shipment_status
BEFORE INSERT ON shipment
FOR EACH ROW
BEGIN
    IF NEW.status = 'Delivered' THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'State Violation: New shipment cannot be inserted directly as Delivered; create as Pending/In Transit first.';
    END IF;
END$$

-- -----------------------------------------------------------------------------
-- TRIGGER 6b: trg_validate_shipment_update (State Machine + BR1 Total/Disjoint + BR2 + Anti-Leak)
-- Blocks reverting Delivered status, changing shipment_type, updating without a
-- valid subtype record (BR1 total), or changing origin_warehouse_id after lines exist.
-- -----------------------------------------------------------------------------
CREATE TRIGGER trg_validate_shipment_update
BEFORE UPDATE ON shipment
FOR EACH ROW
BEGIN
    DECLARE v_dest_wh VARCHAR(10) DEFAULT NULL;
    DECLARE v_subtype_cnt INT DEFAULT 0;
    DECLARE v_line_count INT DEFAULT 0;

    IF NEW.shipment_type <> OLD.shipment_type THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'BR1 Violation: Cannot change shipment_type after shipment creation.';
    END IF;

    IF NEW.shipment_type = 'WAREHOUSE_TRANSFER' THEN
        SELECT COUNT(*) INTO v_subtype_cnt
        FROM warehouse_transfer
        WHERE shipment_id = NEW.shipment_id;
    ELSE
        SELECT COUNT(*) INTO v_subtype_cnt
        FROM customer_delivery
        WHERE shipment_id = NEW.shipment_id;
    END IF;

    IF v_subtype_cnt = 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'BR1 Violation: Shipment is missing its required subtype record (total specialization).';
    END IF;

    IF NEW.origin_warehouse_id <> OLD.origin_warehouse_id THEN
        SELECT COUNT(*) INTO v_line_count
        FROM shipment_line
        WHERE shipment_id = NEW.shipment_id;

        IF v_line_count > 0 THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'Integrity Violation: Cannot change origin_warehouse_id after shipment_lines exist.';
        END IF;
    END IF;

    -- Monotonic state machine: Pending -> In Transit -> Delivered (no backward transition)
    IF OLD.status = 'Delivered' AND NEW.status <> 'Delivered' THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'State Violation: Cannot revert a Delivered shipment back to Pending or In Transit.';
    END IF;

    IF OLD.status = 'In Transit' AND NEW.status = 'Pending' THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'State Violation: Cannot revert an In Transit shipment back to Pending.';
    END IF;

    IF NEW.shipment_type = 'WAREHOUSE_TRANSFER'
       AND NEW.origin_warehouse_id <> OLD.origin_warehouse_id THEN
        SELECT dest_warehouse_id
        INTO v_dest_wh
        FROM warehouse_transfer
        WHERE shipment_id = NEW.shipment_id;

        IF v_dest_wh IS NOT NULL AND NEW.origin_warehouse_id = v_dest_wh THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'BR2 Violation: Origin warehouse cannot be set equal to destination warehouse.';
        END IF;
    END IF;
END$$

-- -----------------------------------------------------------------------------
-- TRIGGER 6c: trg_transfer_delivered_add_dest_inventory (FR3 & FR7)
-- Credits destination warehouse inventory when WAREHOUSE_TRANSFER -> Delivered.
-- -----------------------------------------------------------------------------
CREATE TRIGGER trg_transfer_delivered_add_dest_inventory
AFTER UPDATE ON shipment
FOR EACH ROW
BEGIN
    DECLARE v_dest_wh VARCHAR(10) DEFAULT NULL;

    IF NEW.shipment_type = 'WAREHOUSE_TRANSFER'
       AND NEW.status = 'Delivered'
       AND OLD.status <> 'Delivered' THEN

        SELECT dest_warehouse_id
        INTO v_dest_wh
        FROM warehouse_transfer
        WHERE shipment_id = NEW.shipment_id;

        IF v_dest_wh IS NOT NULL THEN
            INSERT INTO inventory (warehouse_id, product_id, quantity_on_hand)
            SELECT
                v_dest_wh,
                sl.product_id,
                sl.quantity_shipped
            FROM shipment_line AS sl
            WHERE sl.shipment_id = NEW.shipment_id
            ON DUPLICATE KEY UPDATE
                quantity_on_hand = inventory.quantity_on_hand + VALUES(quantity_on_hand);
        END IF;
    END IF;
END$$

-- -----------------------------------------------------------------------------
-- TRIGGER 6d: trg_restore_inventory_on_shipment_delete (Anti-Leak on Cascade Delete)
-- Because MySQL FK ON DELETE CASCADE does not fire child triggers on shipment_line,
-- this trigger restores origin inventory before an undelivered shipment is deleted,
-- and blocks deleting an already Delivered shipment to preserve audit history.
-- -----------------------------------------------------------------------------
CREATE TRIGGER trg_restore_inventory_on_shipment_delete
BEFORE DELETE ON shipment
FOR EACH ROW
BEGIN
    IF OLD.status = 'Delivered' THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'State Violation: Cannot delete an already Delivered shipment.';
    END IF;

    UPDATE inventory AS i
    INNER JOIN shipment_line AS sl
        ON sl.product_id = i.product_id
    SET i.quantity_on_hand = i.quantity_on_hand + sl.quantity_shipped
    WHERE sl.shipment_id = OLD.shipment_id
      AND i.warehouse_id = OLD.origin_warehouse_id;
END$$

-- -----------------------------------------------------------------------------
-- TRIGGER 7a: trg_enforce_initial_po_status (Prevents bypassing PO Receive trigger)
-- -----------------------------------------------------------------------------
CREATE TRIGGER trg_enforce_initial_po_status
BEFORE INSERT ON purchase_order
FOR EACH ROW
BEGIN
    IF NEW.status = 'Received' THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'State Violation: New purchase order cannot be inserted directly as Received; create as Pending/Approved/Ordered first.';
    END IF;
END$$

-- -----------------------------------------------------------------------------
-- TRIGGER 7b: trg_validate_po_update (PO State Machine & Supplier Catalog Guard)
-- -----------------------------------------------------------------------------
CREATE TRIGGER trg_validate_po_update
BEFORE UPDATE ON purchase_order
FOR EACH ROW
BEGIN
    DECLARE v_invalid_lines INT DEFAULT 0;

    IF OLD.status = 'Received' AND NEW.status <> 'Received' THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'State Violation: Cannot revert a Received purchase order.';
    END IF;

    IF OLD.status = 'Cancelled' AND NEW.status <> 'Cancelled' THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'State Violation: Cannot reactivate a Cancelled purchase order.';
    END IF;

    IF OLD.status IN ('Received', 'Cancelled')
       AND (NEW.supplier_id <> OLD.supplier_id OR NEW.warehouse_id <> OLD.warehouse_id) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'State Violation: Cannot change supplier_id or warehouse_id on a closed (Received/Cancelled) purchase order.';
    END IF;

    IF NEW.supplier_id <> OLD.supplier_id THEN
        SELECT COUNT(*)
        INTO v_invalid_lines
        FROM po_line AS pol
        WHERE pol.po_id = NEW.po_id
          AND NOT EXISTS (
              SELECT 1
              FROM supplier_product AS sp
              WHERE sp.supplier_id = NEW.supplier_id
                AND sp.product_id = pol.product_id
          );

        IF v_invalid_lines > 0 THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'Catalog Violation: New supplier does not supply all existing products in po_line.';
        END IF;
    END IF;
END$$

-- -----------------------------------------------------------------------------
-- TRIGGER 7c: trg_po_received_add_inventory (Closes the Restock Loop — FR2 & FR5)
-- When a Purchase Order transitions to 'Received', automatically credits all
-- po_line quantities into the receiving warehouse's inventory!
-- -----------------------------------------------------------------------------
CREATE TRIGGER trg_po_received_add_inventory
AFTER UPDATE ON purchase_order
FOR EACH ROW
BEGIN
    IF NEW.status = 'Received' AND OLD.status <> 'Received' THEN
        INSERT INTO inventory (warehouse_id, product_id, quantity_on_hand)
        SELECT
            NEW.warehouse_id,
            pol.product_id,
            pol.quantity_ordered
        FROM po_line AS pol
        WHERE pol.po_id = NEW.po_id
        ON DUPLICATE KEY UPDATE
            quantity_on_hand = inventory.quantity_on_hand + VALUES(quantity_on_hand);
    END IF;
END$$

-- -----------------------------------------------------------------------------
-- TRIGGER 8a: trg_validate_po_line_insert (Locks Closed POs & Enforces supplier_product)
-- -----------------------------------------------------------------------------
CREATE TRIGGER trg_validate_po_line_insert
BEFORE INSERT ON po_line
FOR EACH ROW
BEGIN
    DECLARE v_po_status VARCHAR(20);
    DECLARE v_supplier_id VARCHAR(10);
    DECLARE v_sp_exists INT DEFAULT 0;

    SELECT status, supplier_id
    INTO v_po_status, v_supplier_id
    FROM purchase_order
    WHERE po_id = NEW.po_id;

    IF v_po_status IN ('Received', 'Cancelled') THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'State Violation: Cannot add po_line items to an already Received or Cancelled purchase order.';
    END IF;

    SELECT COUNT(*)
    INTO v_sp_exists
    FROM supplier_product
    WHERE supplier_id = v_supplier_id
      AND product_id = NEW.product_id;

    IF v_sp_exists = 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Catalog Violation: Selected supplier does not supply this product in supplier_product.';
    END IF;
END$$

-- -----------------------------------------------------------------------------
-- TRIGGER 8b: trg_validate_po_line_update (Locks Closed POs & Enforces supplier_product)
-- -----------------------------------------------------------------------------
CREATE TRIGGER trg_validate_po_line_update
BEFORE UPDATE ON po_line
FOR EACH ROW
BEGIN
    DECLARE v_po_status VARCHAR(20);
    DECLARE v_supplier_id VARCHAR(10);
    DECLARE v_sp_exists INT DEFAULT 0;

    IF NEW.po_id <> OLD.po_id THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Integrity Violation: Cannot reassign po_id on an existing po_line.';
    END IF;

    SELECT status, supplier_id
    INTO v_po_status, v_supplier_id
    FROM purchase_order
    WHERE po_id = OLD.po_id;

    IF v_po_status IN ('Received', 'Cancelled') THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'State Violation: Cannot modify po_line items of an already Received or Cancelled purchase order.';
    END IF;

    IF NEW.product_id <> OLD.product_id THEN
        SELECT COUNT(*)
        INTO v_sp_exists
        FROM supplier_product
        WHERE supplier_id = v_supplier_id
          AND product_id = NEW.product_id;

        IF v_sp_exists = 0 THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'Catalog Violation: Selected supplier does not supply this product in supplier_product.';
        END IF;
    END IF;
END$$

-- -----------------------------------------------------------------------------
-- TRIGGER 8c: trg_prevent_po_line_delete_on_closed_po (Locks Closed PO Audit History)
-- -----------------------------------------------------------------------------
CREATE TRIGGER trg_prevent_po_line_delete_on_closed_po
BEFORE DELETE ON po_line
FOR EACH ROW
BEGIN
    DECLARE v_po_status VARCHAR(20);

    SELECT status
    INTO v_po_status
    FROM purchase_order
    WHERE po_id = OLD.po_id;

    IF v_po_status IN ('Received', 'Cancelled') THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'State Violation: Cannot delete po_line items from an already Received or Cancelled purchase order.';
    END IF;
END$$

DELIMITER ;

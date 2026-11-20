-- =============================================================================
-- Project #6: Supply Chain & Warehouse Logistics Network (Team DATAFORGE)
-- Phase 3 — Script 02: Views & Triggers (Business Rules & DB Challenges)
-- Target DBMS : MySQL 8.0+
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
-- PART B: TRIGGERS (6 Triggers Enforcing BR1, BR2, BR4, BR7, FR5)
-- =============================================================================

DELIMITER $$

-- -----------------------------------------------------------------------------
-- TRIGGER 1: trg_prevent_bom_cycle_insert (BR4 — Direct & Recursive Cycle Detection)
-- Blocks both direct self-loops (A -> A) and indirect cycles (A -> B -> C -> A).
-- -----------------------------------------------------------------------------
CREATE TRIGGER trg_prevent_bom_cycle_insert
BEFORE INSERT ON product_component
FOR EACH ROW
BEGIN
    DECLARE v_cycle_found INT DEFAULT 0;

    -- 1) Block direct self-loop (A -> A)
    IF NEW.parent_product_id = NEW.component_product_id THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'BR4 Violation: A product cannot be a direct component of itself.';
    END IF;

    -- 2) Traverse descendants starting from NEW.component_product_id.
    --    If we can reach NEW.parent_product_id, inserting this edge creates an indirect cycle.
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
-- TRIGGER 2: trg_validate_warehouse_transfer_insert (BR1 & BR2)
-- Ensures shipment_type = 'WAREHOUSE_TRANSFER', disjoint from customer_delivery,
-- and dest_warehouse_id <> origin_warehouse_id.
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
-- TRIGGER 3: trg_validate_customer_delivery_insert (BR1)
-- Ensures shipment_type = 'CUSTOMER_DELIVERY' and disjoint from warehouse_transfer.
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
-- TRIGGER 4: trg_check_and_deduct_inventory_on_ship (BR7 & BR3)
-- Validates available stock at origin warehouse before shipping and deducts stock.
-- -----------------------------------------------------------------------------
CREATE TRIGGER trg_check_and_deduct_inventory_on_ship
BEFORE INSERT ON shipment_line
FOR EACH ROW
BEGIN
    DECLARE v_origin_wh VARCHAR(10);
    DECLARE v_available_qty INT UNSIGNED DEFAULT NULL;

    SELECT origin_warehouse_id
    INTO v_origin_wh
    FROM shipment
    WHERE shipment_id = NEW.shipment_id;

    SELECT quantity_on_hand
    INTO v_available_qty
    FROM inventory
    WHERE warehouse_id = v_origin_wh
      AND product_id = NEW.product_id;

    IF v_available_qty IS NULL OR NEW.quantity_shipped > v_available_qty THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'BR7 Violation: Insufficient inventory quantity_on_hand at origin warehouse.';
    END IF;

    -- Deduct inventory atomically (also triggers AFTER UPDATE restock check)
    UPDATE inventory
    SET quantity_on_hand = quantity_on_hand - NEW.quantity_shipped
    WHERE warehouse_id = v_origin_wh
      AND product_id = NEW.product_id;
END$$

-- -----------------------------------------------------------------------------
-- TRIGGER 5: trg_auto_restock_po_on_low_inventory (FR5 & DB Challenge)
-- Automatically creates a Pending restock Purchase Order + PO Line when
-- quantity_on_hand drops below product.reorder_level (without duplicate POs).
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

    -- Fire only when inventory crosses below reorder_level
    IF NEW.quantity_on_hand < v_reorder_level
       AND OLD.quantity_on_hand >= v_reorder_level THEN

        -- Avoid duplicate open restock POs for the same (warehouse, product)
        SELECT COUNT(*)
        INTO v_open_po_count
        FROM purchase_order AS po
        INNER JOIN po_line AS pol
            ON po.po_id = pol.po_id
        WHERE po.warehouse_id = NEW.warehouse_id
          AND pol.product_id = NEW.product_id
          AND po.status IN ('Pending', 'Approved', 'Ordered');

        IF v_open_po_count = 0 THEN
            -- Pick cheapest supplier (tie-break by fastest lead time)
            SELECT supplier_id, supply_cost, lead_time_days
            INTO v_best_supplier, v_best_cost, v_best_lead
            FROM supplier_product
            WHERE product_id = NEW.product_id
            ORDER BY supply_cost ASC, lead_time_days ASC
            LIMIT 1;

            IF v_best_supplier IS NOT NULL THEN
                SELECT COALESCE(MAX(CAST(SUBSTRING(po_id, 4) AS UNSIGNED)), 0) + 1
                INTO v_next_po_num
                FROM purchase_order;

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
-- TRIGGER 6: trg_transfer_delivered_add_dest_inventory (FR3 & FR7)
-- When a WAREHOUSE_TRANSFER shipment transitions to 'Delivered', automatically
-- credits the shipped quantities into the destination warehouse's inventory.
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

DELIMITER ;

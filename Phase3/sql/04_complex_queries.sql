-- =============================================================================
-- Project #6: Supply Chain & Warehouse Logistics Network (Team DATAFORGE)
-- Phase 3 — Script 04: 12 Complex Queries & Performance Test Cases
-- Target DBMS : MySQL 8.0+
-- Style Guide : SQLStyle.guide / Google SQL Style Guide
-- =============================================================================

USE supply_chain_logistics_db;

-- -----------------------------------------------------------------------------
-- Q1: Multi-Level Recursive BOM Explosion (FR4 & DB Challenge)
-- Explodes 'PRD-000001' (Smart Logistics Drone X1) across all hierarchy levels,
-- computing cumulative required quantity and estimated unit material cost.
-- -----------------------------------------------------------------------------
WITH RECURSIVE bom_tree AS (
    SELECT
        pc.parent_product_id,
        pc.component_product_id,
        pc.quantity_required AS qty_per_parent,
        pc.quantity_required AS total_qty_needed,
        1 AS bom_level,
        CAST(CONCAT(pc.parent_product_id, ' -> ', pc.component_product_id) AS CHAR(1000)) AS bom_path
    FROM product_component AS pc
    WHERE pc.parent_product_id = 'PRD-000001'

    UNION ALL

    SELECT
        pc.parent_product_id,
        pc.component_product_id,
        pc.quantity_required AS qty_per_parent,
        bt.total_qty_needed * pc.quantity_required AS total_qty_needed,
        bt.bom_level + 1 AS bom_level,
        CONCAT(bt.bom_path, ' -> ', pc.component_product_id) AS bom_path
    FROM product_component AS pc
    INNER JOIN bom_tree AS bt
        ON pc.parent_product_id = bt.component_product_id
    WHERE bt.bom_level < 15
)
SELECT
    bt.bom_level,
    bt.bom_path,
    p.product_id,
    p.name AS component_name,
    p.category,
    bt.qty_per_parent,
    bt.total_qty_needed,
    p.unit_price,
    (bt.total_qty_needed * p.unit_price) AS extended_catalog_value
FROM bom_tree AS bt
INNER JOIN product AS p
    ON bt.component_product_id = p.product_id
ORDER BY bt.bom_level ASC, bt.bom_path ASC;

-- -----------------------------------------------------------------------------
-- Q2: Reverse BOM / Where-Used Impact Analysis (Recursive CTE)
-- Given a critical raw component ('PRD-000007' STM32H7), finds all parent
-- sub-assemblies and finished goods impacted by a component shortage.
-- -----------------------------------------------------------------------------
WITH RECURSIVE where_used AS (
    SELECT
        pc.component_product_id AS target_component,
        pc.parent_product_id AS affected_product_id,
        pc.quantity_required AS cumulative_usage,
        1 AS levels_up
    FROM product_component AS pc
    WHERE pc.component_product_id = 'PRD-000007'

    UNION ALL

    SELECT
        wu.target_component,
        pc.parent_product_id AS affected_product_id,
        wu.cumulative_usage * pc.quantity_required AS cumulative_usage,
        wu.levels_up + 1 AS levels_up
    FROM product_component AS pc
    INNER JOIN where_used AS wu
        ON pc.component_product_id = wu.affected_product_id
    WHERE wu.levels_up < 15
)
SELECT
    wu.levels_up,
    p.product_id AS affected_product_id,
    p.name AS affected_product_name,
    p.category,
    SUM(wu.cumulative_usage) AS total_stm32_per_unit
FROM where_used AS wu
INNER JOIN product AS p
    ON wu.affected_product_id = p.product_id
GROUP BY wu.levels_up, p.product_id, p.name, p.category
ORDER BY wu.levels_up DESC, total_stm32_per_unit DESC;

-- -----------------------------------------------------------------------------
-- Q3: Active Restock Alerts with Optimal Supplier Comparison (FR5 & FR6)
-- Uses v_restock_alerts and checks whether an open PO already exists.
-- -----------------------------------------------------------------------------
SELECT
    ra.warehouse_id,
    ra.warehouse_name,
    ra.product_id,
    ra.product_name,
    ra.quantity_on_hand,
    ra.reorder_level,
    ra.shortage_qty,
    ra.recommended_order_qty,
    ra.recommended_supplier_name,
    ra.best_unit_cost,
    (ra.recommended_order_qty * ra.best_unit_cost) AS estimated_restock_budget,
    ra.lead_time_days,
    CASE
        WHEN EXISTS (
            SELECT 1
            FROM purchase_order AS po
            INNER JOIN po_line AS pol
                ON po.po_id = pol.po_id
            WHERE po.warehouse_id = ra.warehouse_id
              AND pol.product_id = ra.product_id
              AND po.status IN ('Pending', 'Approved', 'Ordered')
        ) THEN 'Open PO Exists'
        ELSE 'Action Required: Create PO'
    END AS procurement_status
FROM v_restock_alerts AS ra
ORDER BY ra.shortage_qty DESC, estimated_restock_budget DESC;

-- -----------------------------------------------------------------------------
-- Q4: Warehouse Capacity Utilization & Valuation Report (Multi-Table JOIN + Agg)
-- Identifies warehouses with high inventory value (> $50,000) or low-stock alerts.
-- -----------------------------------------------------------------------------
SELECT
    warehouse_id,
    warehouse_name,
    manager,
    distinct_skus,
    total_units_in_stock,
    capacity,
    utilization_pct,
    total_stock_value,
    low_stock_sku_count
FROM v_warehouse_inventory_summary
WHERE total_stock_value > 50000.00
   OR low_stock_sku_count > 0
ORDER BY total_stock_value DESC;

-- -----------------------------------------------------------------------------
-- Q5: Supplier Performance & Spend Ranking (Subquery + Window Function RANK)
-- Compares suppliers on catalog breadth, average lead time, and total PO spend.
-- -----------------------------------------------------------------------------
SELECT
    s.supplier_id,
    s.name AS supplier_name,
    COUNT(DISTINCT sp.product_id) AS products_offered,
    ROUND(AVG(sp.lead_time_days), 1) AS avg_lead_time_days,
    COALESCE(po_stats.total_orders, 0) AS total_po_count,
    COALESCE(po_stats.total_spend, 0.00) AS total_po_spend,
    RANK() OVER (ORDER BY COALESCE(po_stats.total_spend, 0.00) DESC) AS spend_rank
FROM supplier AS s
LEFT JOIN supplier_product AS sp
    ON s.supplier_id = sp.supplier_id
LEFT JOIN (
    SELECT
        po.supplier_id,
        COUNT(DISTINCT po.po_id) AS total_orders,
        SUM(pol.quantity_ordered * pol.unit_cost) AS total_spend
    FROM purchase_order AS po
    INNER JOIN po_line AS pol
        ON po.po_id = pol.po_id
    WHERE po.status <> 'Cancelled'
    GROUP BY po.supplier_id
) AS po_stats
    ON s.supplier_id = po_stats.supplier_id
GROUP BY
    s.supplier_id,
    s.name,
    po_stats.total_orders,
    po_stats.total_spend
ORDER BY spend_rank ASC;

-- -----------------------------------------------------------------------------
-- Q6: Multi-Supplier Price & Lead-Time Comparison per Product (FR6 — Subquery)
-- Shows only products offered by >= 2 suppliers with price delta vs cheapest.
-- -----------------------------------------------------------------------------
SELECT
    p.product_id,
    p.name AS product_name,
    s.supplier_id,
    s.name AS supplier_name,
    sp.supply_cost,
    sp.lead_time_days,
    MIN(sp.supply_cost) OVER (PARTITION BY sp.product_id) AS min_market_cost,
    ROUND(
        sp.supply_cost - MIN(sp.supply_cost) OVER (PARTITION BY sp.product_id),
        2
    ) AS cost_premium_over_best
FROM supplier_product AS sp
INNER JOIN product AS p
    ON sp.product_id = p.product_id
INNER JOIN supplier AS s
    ON sp.supplier_id = s.supplier_id
WHERE sp.product_id IN (
    SELECT product_id
    FROM supplier_product
    GROUP BY product_id
    HAVING COUNT(supplier_id) >= 2
)
ORDER BY p.product_id ASC, sp.supply_cost ASC;

-- -----------------------------------------------------------------------------
-- Q7: Polymorphic Shipment Audit & Delivery Lead Time (EER Supertype/Subtype)
-- Audits both Warehouse Transfers and Customer Deliveries with transit duration.
-- -----------------------------------------------------------------------------
SELECT
    st.shipment_id,
    st.shipment_type,
    st.status,
    st.carrier_name,
    st.origin_warehouse_name,
    st.destination_name,
    st.total_units_shipped,
    st.ship_date,
    st.delivery_date,
    CASE
        WHEN st.delivery_date IS NOT NULL
            THEN TIMESTAMPDIFF(HOUR, st.ship_date, st.delivery_date)
        ELSE TIMESTAMPDIFF(HOUR, st.ship_date, CURRENT_TIMESTAMP)
    END AS elapsed_hours
FROM v_shipment_tracking_overview AS st
ORDER BY st.ship_date DESC;

-- -----------------------------------------------------------------------------
-- Q8: Purchase Order Spend Breakdown by Warehouse & Status (Conditional Agg)
-- Pivots PO totals across lifecycle statuses for executive budget tracking.
-- -----------------------------------------------------------------------------
SELECT
    w.warehouse_id,
    w.name AS warehouse_name,
    COUNT(DISTINCT po.po_id) AS total_pos,
    SUM(CASE WHEN po.status = 'Received'  THEN pol.quantity_ordered * pol.unit_cost ELSE 0 END) AS received_spend,
    SUM(CASE WHEN po.status IN ('Pending', 'Approved', 'Ordered')
             THEN pol.quantity_ordered * pol.unit_cost ELSE 0 END) AS committed_open_spend,
    SUM(CASE WHEN po.status = 'Cancelled' THEN pol.quantity_ordered * pol.unit_cost ELSE 0 END) AS cancelled_value
FROM warehouse AS w
LEFT JOIN purchase_order AS po
    ON w.warehouse_id = po.warehouse_id
LEFT JOIN po_line AS pol
    ON po.po_id = pol.po_id
GROUP BY w.warehouse_id, w.name
ORDER BY received_spend DESC, committed_open_spend DESC;

-- -----------------------------------------------------------------------------
-- Q9: Cumulative Procurement Spend Over Time (Window Function Running Total)
-- Tracks chronological PO spend growth and percentage share of total budget.
-- -----------------------------------------------------------------------------
WITH po_totals AS (
    SELECT
        po.po_id,
        po.order_date,
        s.name AS supplier_name,
        po.status,
        SUM(pol.quantity_ordered * pol.unit_cost) AS po_amount
    FROM purchase_order AS po
    INNER JOIN po_line AS pol
        ON po.po_id = pol.po_id
    INNER JOIN supplier AS s
        ON po.supplier_id = s.supplier_id
    WHERE po.status <> 'Cancelled'
    GROUP BY po.po_id, po.order_date, s.name, po.status
)
SELECT
    po_id,
    order_date,
    supplier_name,
    status,
    po_amount,
    SUM(po_amount) OVER (ORDER BY order_date ASC, po_id ASC) AS cumulative_spend,
    ROUND(po_amount * 100.0 / SUM(po_amount) OVER (), 2) AS pct_of_total_spend
FROM po_totals
ORDER BY order_date ASC, po_id ASC;

-- -----------------------------------------------------------------------------
-- Q10: BOM Assembly Feasibility Calculator (Recursive CTE + Inventory Check)
-- Computes the maximum number of 'PRD-000001' Drones that can be assembled
-- right now at 'WH-000001' based on leaf-level raw component inventory!
-- -----------------------------------------------------------------------------
WITH RECURSIVE bom_leaf AS (
    SELECT
        pc.component_product_id,
        pc.quantity_required AS qty_needed,
        1 AS depth
    FROM product_component AS pc
    WHERE pc.parent_product_id = 'PRD-000001'

    UNION ALL

    SELECT
        pc.component_product_id,
        bl.qty_needed * pc.quantity_required AS qty_needed,
        bl.depth + 1 AS depth
    FROM product_component AS pc
    INNER JOIN bom_leaf AS bl
        ON pc.parent_product_id = bl.component_product_id
    WHERE bl.depth < 15
),
leaf_requirements AS (
    SELECT
        bl.component_product_id,
        SUM(bl.qty_needed) AS total_required_per_drone
    FROM bom_leaf AS bl
    WHERE NOT EXISTS (
        SELECT 1
        FROM product_component AS child
        WHERE child.parent_product_id = bl.component_product_id
    )
    GROUP BY bl.component_product_id
)
SELECT
    lr.component_product_id,
    p.name AS raw_component_name,
    lr.total_required_per_drone,
    COALESCE(i.quantity_on_hand, 0) AS stock_at_wh000001,
    FLOOR(COALESCE(i.quantity_on_hand, 0) / lr.total_required_per_drone) AS max_drones_supported,
    MIN(FLOOR(COALESCE(i.quantity_on_hand, 0) / lr.total_required_per_drone)) OVER () AS bottleneck_max_buildable_drones
FROM leaf_requirements AS lr
INNER JOIN product AS p
    ON lr.component_product_id = p.product_id
LEFT JOIN inventory AS i
    ON lr.component_product_id = i.product_id
   AND i.warehouse_id = 'WH-000001'
ORDER BY max_drones_supported ASC;

-- -----------------------------------------------------------------------------
-- Q11: Products Missing from Active Warehouses (Correlated NOT EXISTS)
-- Lists finished goods that are NOT currently stocked at each warehouse.
-- -----------------------------------------------------------------------------
SELECT
    w.warehouse_id,
    w.name AS warehouse_name,
    p.product_id,
    p.name AS missing_finished_good
FROM warehouse AS w
CROSS JOIN product AS p
WHERE p.category = 'Finished Good'
  AND NOT EXISTS (
      SELECT 1
      FROM inventory AS i
      WHERE i.warehouse_id = w.warehouse_id
        AND i.product_id = p.product_id
        AND i.quantity_on_hand > 0
  )
ORDER BY w.warehouse_id ASC, p.product_id ASC;

-- -----------------------------------------------------------------------------
-- Q12: Performance Verification Test Cases (EXPLAIN for NFR1 < 200ms)
-- Verifies Clustered PK & Secondary Index usage (const / ref, no full scan).
-- -----------------------------------------------------------------------------
EXPLAIN
SELECT
    warehouse_id,
    product_id,
    quantity_on_hand,
    last_updated
FROM inventory
WHERE warehouse_id = 'WH-000001'
  AND product_id = 'PRD-000007';

EXPLAIN
SELECT
    shipment_id,
    carrier_name,
    ship_date,
    status
FROM shipment
WHERE origin_warehouse_id = 'WH-000001'
  AND status = 'In Transit'
ORDER BY ship_date DESC;

-- =============================================================================
-- Project #6: Supply Chain & Warehouse Logistics Network (Team DATAFORGE)
-- Phase 3 — Script 01: DDL Schema (Tables, Constraints & Secondary Indexes)
-- Target DBMS : MySQL 8.0+ / MariaDB 10.5+
-- Style Guide : SQLStyle.guide / Google SQL Style Guide (lowercase snake_case)
-- =============================================================================

DROP DATABASE IF EXISTS supply_chain_logistics_db;
CREATE DATABASE supply_chain_logistics_db
    CHARACTER SET utf8mb4
    COLLATE utf8mb4_unicode_ci;

USE supply_chain_logistics_db;

-- -----------------------------------------------------------------------------
-- 1. WAREHOUSE (Kho hang khu vuc)
-- -----------------------------------------------------------------------------
CREATE TABLE warehouse (
    warehouse_id VARCHAR(10)   NOT NULL,
    name         VARCHAR(100)  NOT NULL,
    address      VARCHAR(255)  NOT NULL,
    manager      VARCHAR(100)  NOT NULL,
    capacity     INT UNSIGNED  NOT NULL,
    CONSTRAINT pk_warehouse PRIMARY KEY (warehouse_id),
    CONSTRAINT uq_warehouse_name UNIQUE (name),
    CONSTRAINT chk_warehouse_id_fmt CHECK (REGEXP_LIKE(warehouse_id, '^WH-[0-9]{6}$')),
    CONSTRAINT chk_warehouse_capacity CHECK (capacity > 0)
) ENGINE=InnoDB;

-- -----------------------------------------------------------------------------
-- 2. SUPPLIER (Nha cung cap)
-- -----------------------------------------------------------------------------
CREATE TABLE supplier (
    supplier_id   VARCHAR(10)   NOT NULL,
    name          VARCHAR(150)  NOT NULL,
    contact_email VARCHAR(150)  NOT NULL,
    phone         VARCHAR(20)   NOT NULL,
    address       VARCHAR(255)  NOT NULL,
    CONSTRAINT pk_supplier PRIMARY KEY (supplier_id),
    CONSTRAINT uq_supplier_email UNIQUE (contact_email),
    CONSTRAINT chk_supplier_id_fmt CHECK (REGEXP_LIKE(supplier_id, '^SUP-[0-9]{6}$')),
    CONSTRAINT chk_supplier_email_fmt CHECK (contact_email LIKE '%_@__%.__%')
) ENGINE=InnoDB;

-- -----------------------------------------------------------------------------
-- 3. PRODUCT (Danh muc san pham)
-- -----------------------------------------------------------------------------
CREATE TABLE product (
    product_id    VARCHAR(10)    NOT NULL,
    name          VARCHAR(150)   NOT NULL,
    category      VARCHAR(80)    NOT NULL,
    unit_price    DECIMAL(12,2)  NOT NULL DEFAULT 0.00,
    reorder_level INT UNSIGNED   NOT NULL DEFAULT 0,
    reorder_qty   INT UNSIGNED   NOT NULL DEFAULT 1,
    CONSTRAINT pk_product PRIMARY KEY (product_id),
    CONSTRAINT chk_product_id_fmt CHECK (REGEXP_LIKE(product_id, '^PRD-[0-9]{6}$')),
    CONSTRAINT chk_product_unit_price CHECK (unit_price >= 0.00),
    CONSTRAINT chk_product_reorder_qty CHECK (reorder_qty > 0)
) ENGINE=InnoDB;

-- -----------------------------------------------------------------------------
-- 4. CUSTOMER (Khach hang)
-- -----------------------------------------------------------------------------
CREATE TABLE customer (
    customer_id   VARCHAR(10)   NOT NULL,
    name          VARCHAR(150)  NOT NULL,
    address       VARCHAR(255)  NOT NULL,
    contact_email VARCHAR(150)  NOT NULL,
    phone         VARCHAR(20)   NOT NULL,
    CONSTRAINT pk_customer PRIMARY KEY (customer_id),
    CONSTRAINT uq_customer_email UNIQUE (contact_email),
    CONSTRAINT chk_customer_id_fmt CHECK (REGEXP_LIKE(customer_id, '^CUS-[0-9]{6}$')),
    CONSTRAINT chk_customer_email_fmt CHECK (contact_email LIKE '%_@__%.__%')
) ENGINE=InnoDB;

-- -----------------------------------------------------------------------------
-- 5. PRODUCT_COMPONENT (Cau truc lap rap de quy — Bill of Materials, BR4)
-- -----------------------------------------------------------------------------
CREATE TABLE product_component (
    parent_product_id    VARCHAR(10)   NOT NULL,
    component_product_id VARCHAR(10)   NOT NULL,
    quantity_required    INT UNSIGNED  NOT NULL DEFAULT 1,
    CONSTRAINT pk_product_component PRIMARY KEY (parent_product_id, component_product_id),
    CONSTRAINT fk_pc_parent FOREIGN KEY (parent_product_id)
        REFERENCES product (product_id)
        ON UPDATE CASCADE
        ON DELETE CASCADE,
    CONSTRAINT fk_pc_component FOREIGN KEY (component_product_id)
        REFERENCES product (product_id)
        ON UPDATE CASCADE
        ON DELETE RESTRICT,
    -- Note: Direct self-loop (parent_product_id <> component_product_id) and indirect
    --       cycles (BR4) are enforced by trg_prevent_bom_cycle_insert / _update
    --       because MySQL 8.0 disallows CHECK constraints on FK columns with ON UPDATE CASCADE (Error 3823).
    CONSTRAINT chk_pc_qty_positive CHECK (quantity_required > 0)
) ENGINE=InnoDB;

-- -----------------------------------------------------------------------------
-- 6. INVENTORY (Ton kho theo tung kho & san pham — BR3, NFR1, NFR3, NFR7)
-- -----------------------------------------------------------------------------
CREATE TABLE inventory (
    warehouse_id     VARCHAR(10)   NOT NULL,
    product_id       VARCHAR(10)   NOT NULL,
    quantity_on_hand INT UNSIGNED  NOT NULL DEFAULT 0,
    last_updated     TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    CONSTRAINT pk_inventory PRIMARY KEY (warehouse_id, product_id),
    CONSTRAINT fk_inv_warehouse FOREIGN KEY (warehouse_id)
        REFERENCES warehouse (warehouse_id)
        ON UPDATE CASCADE
        ON DELETE RESTRICT,
    CONSTRAINT fk_inv_product FOREIGN KEY (product_id)
        REFERENCES product (product_id)
        ON UPDATE CASCADE
        ON DELETE RESTRICT
) ENGINE=InnoDB;

-- -----------------------------------------------------------------------------
-- 7. SUPPLIER_PRODUCT (Danh muc cung ung cua NCC — BR6, FR6)
-- -----------------------------------------------------------------------------
CREATE TABLE supplier_product (
    supplier_id    VARCHAR(10)        NOT NULL,
    product_id     VARCHAR(10)        NOT NULL,
    supply_cost    DECIMAL(12,2)      NOT NULL,
    lead_time_days SMALLINT UNSIGNED  NOT NULL,
    CONSTRAINT pk_supplier_product PRIMARY KEY (supplier_id, product_id),
    CONSTRAINT fk_sp_supplier FOREIGN KEY (supplier_id)
        REFERENCES supplier (supplier_id)
        ON UPDATE CASCADE
        ON DELETE CASCADE,
    CONSTRAINT fk_sp_product FOREIGN KEY (product_id)
        REFERENCES product (product_id)
        ON UPDATE CASCADE
        ON DELETE CASCADE,
    CONSTRAINT chk_sp_supply_cost CHECK (supply_cost > 0.00),
    CONSTRAINT chk_sp_lead_time CHECK (lead_time_days > 0)
) ENGINE=InnoDB;

-- -----------------------------------------------------------------------------
-- 8. PURCHASE_ORDER (Don dat hang nha cung cap — BR5, FR2)
-- -----------------------------------------------------------------------------
CREATE TABLE purchase_order (
    po_id                  VARCHAR(10)  NOT NULL,
    supplier_id            VARCHAR(10)  NOT NULL,
    warehouse_id           VARCHAR(10)  NOT NULL,
    order_date             DATE         NOT NULL DEFAULT (CURRENT_DATE),
    expected_delivery_date DATE         NULL,
    status                 ENUM('Pending', 'Approved', 'Ordered', 'Received', 'Cancelled')
                                        NOT NULL DEFAULT 'Pending',
    CONSTRAINT pk_purchase_order PRIMARY KEY (po_id),
    CONSTRAINT fk_po_supplier FOREIGN KEY (supplier_id)
        REFERENCES supplier (supplier_id)
        ON UPDATE CASCADE
        ON DELETE RESTRICT,
    CONSTRAINT fk_po_warehouse FOREIGN KEY (warehouse_id)
        REFERENCES warehouse (warehouse_id)
        ON UPDATE CASCADE
        ON DELETE RESTRICT,
    CONSTRAINT chk_po_id_fmt CHECK (REGEXP_LIKE(po_id, '^PO-[0-9]{6}$')),
    CONSTRAINT chk_po_expected_date CHECK (
        expected_delivery_date IS NULL OR expected_delivery_date >= order_date
    )
) ENGINE=InnoDB;

-- -----------------------------------------------------------------------------
-- 9. PO_LINE (Chi tiet dong san pham trong PO — NFR3)
-- -----------------------------------------------------------------------------
CREATE TABLE po_line (
    po_id            VARCHAR(10)    NOT NULL,
    product_id       VARCHAR(10)    NOT NULL,
    quantity_ordered INT UNSIGNED   NOT NULL,
    unit_cost        DECIMAL(12,2)  NOT NULL,
    CONSTRAINT pk_po_line PRIMARY KEY (po_id, product_id),
    CONSTRAINT fk_pol_po FOREIGN KEY (po_id)
        REFERENCES purchase_order (po_id)
        ON UPDATE CASCADE
        ON DELETE CASCADE,
    CONSTRAINT fk_pol_product FOREIGN KEY (product_id)
        REFERENCES product (product_id)
        ON UPDATE CASCADE
        ON DELETE RESTRICT,
    CONSTRAINT chk_pol_qty CHECK (quantity_ordered > 0),
    CONSTRAINT chk_pol_unit_cost CHECK (unit_cost > 0.00)
) ENGINE=InnoDB;

-- -----------------------------------------------------------------------------
-- 10. SHIPMENT (Lo hang van chuyen — Supertype, BR1, FR3, FR7)
-- -----------------------------------------------------------------------------
CREATE TABLE shipment (
    shipment_id         VARCHAR(10)   NOT NULL,
    origin_warehouse_id VARCHAR(10)   NOT NULL,
    carrier_name        VARCHAR(100)  NOT NULL,
    ship_date           DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    delivery_date       DATETIME      NULL,
    status              ENUM('Pending', 'In Transit', 'Delivered')
                                      NOT NULL DEFAULT 'Pending',
    shipment_type       ENUM('WAREHOUSE_TRANSFER', 'CUSTOMER_DELIVERY')
                                      NOT NULL,
    CONSTRAINT pk_shipment PRIMARY KEY (shipment_id),
    CONSTRAINT fk_ship_origin_wh FOREIGN KEY (origin_warehouse_id)
        REFERENCES warehouse (warehouse_id)
        ON UPDATE CASCADE
        ON DELETE RESTRICT,
    CONSTRAINT chk_shipment_id_fmt CHECK (REGEXP_LIKE(shipment_id, '^SHP-[0-9]{6}$')),
    CONSTRAINT chk_shipment_dates CHECK (
        delivery_date IS NULL OR delivery_date >= ship_date
    )
) ENGINE=InnoDB;

-- -----------------------------------------------------------------------------
-- 11. WAREHOUSE_TRANSFER (Chuyen kho noi bo — Subtype, BR1, BR2)
-- -----------------------------------------------------------------------------
CREATE TABLE warehouse_transfer (
    shipment_id       VARCHAR(10)  NOT NULL,
    dest_warehouse_id VARCHAR(10)  NOT NULL,
    CONSTRAINT pk_warehouse_transfer PRIMARY KEY (shipment_id),
    CONSTRAINT fk_wt_shipment FOREIGN KEY (shipment_id)
        REFERENCES shipment (shipment_id)
        ON UPDATE CASCADE
        ON DELETE CASCADE,
    CONSTRAINT fk_wt_dest_wh FOREIGN KEY (dest_warehouse_id)
        REFERENCES warehouse (warehouse_id)
        ON UPDATE CASCADE
        ON DELETE RESTRICT
) ENGINE=InnoDB;

-- -----------------------------------------------------------------------------
-- 12. CUSTOMER_DELIVERY (Giao hang cho khach — Subtype, BR1)
-- -----------------------------------------------------------------------------
CREATE TABLE customer_delivery (
    shipment_id VARCHAR(10)  NOT NULL,
    customer_id VARCHAR(10)  NOT NULL,
    CONSTRAINT pk_customer_delivery PRIMARY KEY (shipment_id),
    CONSTRAINT fk_cd_shipment FOREIGN KEY (shipment_id)
        REFERENCES shipment (shipment_id)
        ON UPDATE CASCADE
        ON DELETE CASCADE,
    CONSTRAINT fk_cd_customer FOREIGN KEY (customer_id)
        REFERENCES customer (customer_id)
        ON UPDATE CASCADE
        ON DELETE RESTRICT
) ENGINE=InnoDB;

-- -----------------------------------------------------------------------------
-- 13. SHIPMENT_LINE (Chi tiet san pham trong lo hang — BR7, NFR3)
-- -----------------------------------------------------------------------------
CREATE TABLE shipment_line (
    shipment_id      VARCHAR(10)   NOT NULL,
    product_id       VARCHAR(10)   NOT NULL,
    quantity_shipped INT UNSIGNED  NOT NULL,
    CONSTRAINT pk_shipment_line PRIMARY KEY (shipment_id, product_id),
    CONSTRAINT fk_sl_shipment FOREIGN KEY (shipment_id)
        REFERENCES shipment (shipment_id)
        ON UPDATE CASCADE
        ON DELETE CASCADE,
    CONSTRAINT fk_sl_product FOREIGN KEY (product_id)
        REFERENCES product (product_id)
        ON UPDATE CASCADE
        ON DELETE RESTRICT,
    CONSTRAINT chk_sl_qty CHECK (quantity_shipped > 0)
) ENGINE=InnoDB;

-- -----------------------------------------------------------------------------
-- 14. GOODS_RECEIPT (Phieu nhap hang tu NCC vao kho)
-- -----------------------------------------------------------------------------
CREATE TABLE goods_receipt (
    receipt_id   VARCHAR(10)  NOT NULL,
    warehouse_id VARCHAR(10)  NOT NULL,
    supplier_id  VARCHAR(10)  NOT NULL,
    product_id   VARCHAR(10)  NOT NULL,
    receipt_date DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    status       ENUM('Pending', 'Inspected', 'Completed', 'Rejected')
                              NOT NULL DEFAULT 'Pending',
    CONSTRAINT pk_goods_receipt PRIMARY KEY (receipt_id),
    CONSTRAINT fk_gr_warehouse FOREIGN KEY (warehouse_id)
        REFERENCES warehouse (warehouse_id)
        ON UPDATE CASCADE
        ON DELETE RESTRICT,
    CONSTRAINT fk_gr_supplier_product FOREIGN KEY (supplier_id, product_id)
        REFERENCES supplier_product (supplier_id, product_id)
        ON UPDATE CASCADE
        ON DELETE RESTRICT,
    CONSTRAINT chk_gr_id_fmt CHECK (REGEXP_LIKE(receipt_id, '^GR-[0-9]{6}$'))
) ENGINE=InnoDB;

-- =============================================================================
-- SECONDARY INDEXES (Performance Optimization for NFR1 < 200ms & NFR5)
-- =============================================================================

-- Reverse lookup for inventory by product across all warehouses
CREATE INDEX idx_inventory_product_qty
    ON inventory (product_id, quantity_on_hand);

-- Fast supplier comparison by product ordered by cost and lead time (FR6)
CREATE INDEX idx_sp_product_cost_lead
    ON supplier_product (product_id, supply_cost, lead_time_days);

-- Reverse BOM traversal (Where-Used analysis, FR4)
CREATE INDEX idx_pc_component
    ON product_component (component_product_id);

-- Fast filtering of active purchase orders per warehouse & status
CREATE INDEX idx_po_warehouse_status
    ON purchase_order (warehouse_id, status, order_date);

-- Fast shipment tracking by origin warehouse, status & ship date (FR7)
CREATE INDEX idx_shipment_origin_status_date
    ON shipment (origin_warehouse_id, status, ship_date);

-- Fast product category lookups
CREATE INDEX idx_product_category
    ON product (category);

-- Fast goods receipt audit by warehouse & date
CREATE INDEX idx_gr_warehouse_date
    ON goods_receipt (warehouse_id, receipt_date, status);

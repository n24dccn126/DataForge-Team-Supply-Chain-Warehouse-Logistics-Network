import os
from flask import Flask, jsonify, render_template, request
import pymysql
from pymysql.cursors import DictCursor
from dotenv import load_dotenv

load_dotenv()

app = Flask(__name__)


def get_db_connection():
    return pymysql.connect(
        host=os.getenv("MYSQL_HOST", "127.0.0.1"),
        port=int(os.getenv("MYSQL_PORT", "3306")),
        user=os.getenv("MYSQL_USER", "root"),
        password=os.getenv("MYSQL_PASSWORD", ""),
        database=os.getenv("MYSQL_DATABASE", "supply_chain_logistics_db"),
        charset="utf8mb4",
        cursorclass=DictCursor,
        autocommit=False,
    )


def serialize_rows(rows):
    """Convert Decimal / datetime / date objects cleanly to JSON-friendly types."""
    out = []
    for row in rows:
        item = {}
        for k, v in row.items():
            if hasattr(v, "isoformat"):
                item[k] = v.isoformat(sep=" ") if "T" not in v.isoformat() else v.isoformat().replace("T", " ")
            elif hasattr(v, "is_finite"):  # Decimal
                item[k] = float(v)
            else:
                item[k] = v
        out.append(item)
    return out


@app.route("/")
def index():
    return render_template("index.html")


@app.route("/api/health")
def api_health():
    try:
        conn = get_db_connection()
        with conn.cursor() as cur:
            cur.execute("SELECT DATABASE() AS db, VERSION() AS version")
            info = cur.fetchone()
        conn.close()
        return jsonify({"ok": True, "database": info["db"], "version": info["version"]})
    except Exception as exc:
        return jsonify({"ok": False, "error": str(exc)}), 500


# =============================================================================
# 1. DASHBOARD & RESTOCK ALERTS (FR5 + Views)
# =============================================================================
@app.route("/api/dashboard")
def api_dashboard():
    try:
        conn = get_db_connection()
        with conn.cursor() as cur:
            cur.execute("SELECT * FROM v_warehouse_inventory_summary ORDER BY warehouse_id")
            warehouses = serialize_rows(cur.fetchall())

            cur.execute("""
                SELECT
                    ra.*,
                    CASE
                        WHEN EXISTS (
                            SELECT 1
                            FROM purchase_order AS po
                            INNER JOIN po_line AS pol ON po.po_id = pol.po_id
                            WHERE po.warehouse_id = ra.warehouse_id
                              AND pol.product_id = ra.product_id
                              AND po.status IN ('Pending', 'Approved', 'Ordered')
                        ) THEN 'Open PO Exists'
                        ELSE 'Action Required'
                    END AS procurement_status
                FROM v_restock_alerts AS ra
                ORDER BY ra.shortage_qty DESC
            """)
            alerts = serialize_rows(cur.fetchall())

            cur.execute("SELECT COUNT(*) AS cnt FROM product")
            total_products = cur.fetchone()["cnt"]

            cur.execute("SELECT COUNT(*) AS cnt FROM shipment WHERE status = 'In Transit'")
            in_transit_shipments = cur.fetchone()["cnt"]

        conn.close()
        total_value = sum(w["total_stock_value"] for w in warehouses)
        return jsonify({
            "ok": True,
            "kpis": {
                "total_warehouses": len(warehouses),
                "total_products": total_products,
                "total_stock_value": round(total_value, 2),
                "active_alerts": len(alerts),
                "in_transit_shipments": in_transit_shipments,
            },
            "warehouses": warehouses,
            "alerts": alerts,
        })
    except Exception as exc:
        return jsonify({"ok": False, "error": str(exc)}), 500


# =============================================================================
# 2. REAL-TIME INVENTORY MANAGEMENT (FR1, BR3, FR5 Trigger)
# =============================================================================
@app.route("/api/inventory")
def api_inventory():
    warehouse_id = request.args.get("warehouse_id", "").strip()
    try:
        conn = get_db_connection()
        with conn.cursor() as cur:
            sql = """
                SELECT
                    i.warehouse_id,
                    w.name AS warehouse_name,
                    i.product_id,
                    p.name AS product_name,
                    p.category,
                    i.quantity_on_hand,
                    p.reorder_level,
                    p.reorder_qty,
                    i.last_updated
                FROM inventory AS i
                INNER JOIN warehouse AS w ON i.warehouse_id = w.warehouse_id
                INNER JOIN product AS p ON i.product_id = p.product_id
            """
            params = []
            if warehouse_id:
                sql += " WHERE i.warehouse_id = %s"
                params.append(warehouse_id)
            sql += " ORDER BY i.warehouse_id ASC, i.product_id ASC"
            cur.execute(sql, params)
            rows = serialize_rows(cur.fetchall())
        conn.close()
        return jsonify({"ok": True, "items": rows})
    except Exception as exc:
        return jsonify({"ok": False, "error": str(exc)}), 500


@app.route("/api/inventory/update", methods=["POST"])
def api_inventory_update():
    data = request.get_json(force=True)
    warehouse_id = data.get("warehouse_id")
    product_id = data.get("product_id")
    new_qty = data.get("quantity_on_hand")

    try:
        conn = get_db_connection()
        with conn.cursor() as cur:
            # Count open POs before update so we can tell UI if Trigger 5 auto-created a Restock PO!
            cur.execute("SELECT COUNT(*) AS cnt FROM purchase_order")
            po_before = cur.fetchone()["cnt"]

            cur.execute(
                """
                UPDATE inventory
                SET quantity_on_hand = %s
                WHERE warehouse_id = %s AND product_id = %s
                """,
                (new_qty, warehouse_id, product_id),
            )
            cur.execute("SELECT COUNT(*) AS cnt FROM purchase_order")
            po_after = cur.fetchone()["cnt"]
            conn.commit()
        conn.close()

        msg = f"Updated {product_id} at {warehouse_id} to {new_qty}."
        if po_after > po_before:
            msg += " [TRIGGER FR5 FIRED] Auto-generated a new Pending Restock Purchase Order!"
        return jsonify({"ok": True, "message": msg, "auto_po_created": po_after > po_before})
    except Exception as exc:
        return jsonify({"ok": False, "error": str(exc)}), 400


# =============================================================================
# 3. RECURSIVE BOM EXPLORER & CYCLE TEST (FR4, BR4, Q1 & Q10)
# =============================================================================
@app.route("/api/products")
def api_products():
    try:
        conn = get_db_connection()
        with conn.cursor() as cur:
            cur.execute("SELECT * FROM product ORDER BY product_id")
            products = serialize_rows(cur.fetchall())
            cur.execute("SELECT warehouse_id, name FROM warehouse ORDER BY warehouse_id")
            warehouses = serialize_rows(cur.fetchall())
            cur.execute("SELECT supplier_id, name FROM supplier ORDER BY supplier_id")
            suppliers = serialize_rows(cur.fetchall())
            cur.execute("SELECT customer_id, name FROM customer ORDER BY customer_id")
            customers = serialize_rows(cur.fetchall())
        conn.close()
        return jsonify({
            "ok": True,
            "products": products,
            "warehouses": warehouses,
            "suppliers": suppliers,
            "customers": customers,
        })
    except Exception as exc:
        return jsonify({"ok": False, "error": str(exc)}), 500


@app.route("/api/bom/<product_id>")
def api_bom(product_id):
    warehouse_id = request.args.get("warehouse_id", "WH-000001")
    try:
        conn = get_db_connection()
        with conn.cursor() as cur:
            # Q1: Multi-level BOM Explosion
            cur.execute("""
                WITH RECURSIVE bom_tree AS (
                    SELECT
                        pc.parent_product_id,
                        pc.component_product_id,
                        pc.quantity_required AS qty_per_parent,
                        pc.quantity_required AS total_qty_needed,
                        1 AS bom_level,
                        CAST(CONCAT(pc.parent_product_id, ' -> ', pc.component_product_id) AS CHAR(500)) AS bom_path
                    FROM product_component AS pc
                    WHERE pc.parent_product_id = %s

                    UNION ALL

                    SELECT
                        pc.parent_product_id,
                        pc.component_product_id,
                        pc.quantity_required,
                        bt.total_qty_needed * pc.quantity_required,
                        bt.bom_level + 1,
                        CONCAT(bt.bom_path, ' -> ', pc.component_product_id)
                    FROM product_component AS pc
                    INNER JOIN bom_tree AS bt ON pc.parent_product_id = bt.component_product_id
                    WHERE bt.bom_level < 10
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
                    (bt.total_qty_needed * p.unit_price) AS extended_value
                FROM bom_tree AS bt
                INNER JOIN product AS p ON bt.component_product_id = p.product_id
                ORDER BY bt.bom_level ASC, bt.bom_path ASC
            """, (product_id,))
            bom_rows = serialize_rows(cur.fetchall())

            # Q10: Assembly Feasibility at selected warehouse
            cur.execute("""
                WITH RECURSIVE bom_leaf AS (
                    SELECT component_product_id, quantity_required AS qty_needed
                    FROM product_component
                    WHERE parent_product_id = %s
                    UNION ALL
                    SELECT pc.component_product_id, bl.qty_needed * pc.quantity_required
                    FROM product_component AS pc
                    INNER JOIN bom_leaf AS bl ON pc.parent_product_id = bl.component_product_id
                ),
                leaf_req AS (
                    SELECT bl.component_product_id, SUM(bl.qty_needed) AS required_per_unit
                    FROM bom_leaf AS bl
                    WHERE NOT EXISTS (
                        SELECT 1 FROM product_component AS c WHERE c.parent_product_id = bl.component_product_id
                    )
                    GROUP BY bl.component_product_id
                )
                SELECT
                    lr.component_product_id,
                    p.name AS raw_component_name,
                    lr.required_per_unit,
                    COALESCE(i.quantity_on_hand, 0) AS stock_available,
                    FLOOR(COALESCE(i.quantity_on_hand, 0) / lr.required_per_unit) AS max_units_supported
                FROM leaf_req AS lr
                INNER JOIN product AS p ON lr.component_product_id = p.product_id
                LEFT JOIN inventory AS i
                    ON lr.component_product_id = i.product_id AND i.warehouse_id = %s
                ORDER BY max_units_supported ASC
            """, (product_id, warehouse_id))
            feasibility = serialize_rows(cur.fetchall())
        conn.close()
        max_buildable = min((r["max_units_supported"] for r in feasibility), default=0)
        return jsonify({
            "ok": True,
            "bom": bom_rows,
            "feasibility": feasibility,
            "max_buildable": max_buildable,
        })
    except Exception as exc:
        return jsonify({"ok": False, "error": str(exc)}), 500


@app.route("/api/bom/add", methods=["POST"])
def api_bom_add():
    data = request.get_json(force=True)
    parent_id = data.get("parent_product_id")
    comp_id = data.get("component_product_id")
    qty = data.get("quantity_required", 1)
    try:
        conn = get_db_connection()
        with conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO product_component (parent_product_id, component_product_id, quantity_required)
                VALUES (%s, %s, %s)
                """,
                (parent_id, comp_id, qty),
            )
            conn.commit()
        conn.close()
        return jsonify({"ok": True, "message": f"Added BOM link {parent_id} -> {comp_id} (qty={qty})."})
    except Exception as exc:
        return jsonify({"ok": False, "error": str(exc)}), 400


# =============================================================================
# 4. PURCHASE ORDERS & SUPPLIER COMPARISON (FR2, FR6, BR5)
# =============================================================================
@app.route("/api/procurement")
def api_procurement():
    try:
        conn = get_db_connection()
        with conn.cursor() as cur:
            cur.execute("""
                SELECT
                    po.po_id,
                    po.order_date,
                    po.expected_delivery_date,
                    po.status,
                    s.name AS supplier_name,
                    w.name AS warehouse_name,
                    COUNT(pol.product_id) AS line_count,
                    COALESCE(SUM(pol.quantity_ordered * pol.unit_cost), 0) AS total_amount
                FROM purchase_order AS po
                INNER JOIN supplier AS s ON po.supplier_id = s.supplier_id
                INNER JOIN warehouse AS w ON po.warehouse_id = w.warehouse_id
                LEFT JOIN po_line AS pol ON po.po_id = pol.po_id
                GROUP BY po.po_id, po.order_date, po.expected_delivery_date, po.status, s.name, w.name
                ORDER BY po.po_id DESC
            """)
            pos = serialize_rows(cur.fetchall())

            cur.execute("""
                SELECT
                    p.product_id,
                    p.name AS product_name,
                    s.supplier_id,
                    s.name AS supplier_name,
                    sp.supply_cost,
                    sp.lead_time_days
                FROM supplier_product AS sp
                INNER JOIN product AS p ON sp.product_id = p.product_id
                INNER JOIN supplier AS s ON sp.supplier_id = s.supplier_id
                ORDER BY p.product_id ASC, sp.supply_cost ASC
            """)
            catalog = serialize_rows(cur.fetchall())
        conn.close()
        return jsonify({"ok": True, "purchase_orders": pos, "supplier_catalog": catalog})
    except Exception as exc:
        return jsonify({"ok": False, "error": str(exc)}), 500


@app.route("/api/procurement/create-po", methods=["POST"])
def api_create_po():
    data = request.get_json(force=True)
    supplier_id = data.get("supplier_id")
    warehouse_id = data.get("warehouse_id")
    product_id = data.get("product_id")
    quantity_ordered = data.get("quantity_ordered")
    unit_cost = data.get("unit_cost")
    expected_date = data.get("expected_delivery_date") or None

    conn = None
    try:
        conn = get_db_connection()
        with conn.cursor() as cur:
            cur.execute("SELECT COALESCE(MAX(CAST(SUBSTRING(po_id, 4) AS UNSIGNED)), 0) + 1 AS nxt FROM purchase_order")
            next_num = cur.fetchone()["nxt"]
            po_id = f"PO-{next_num:06d}"

            cur.execute(
                """
                INSERT INTO purchase_order (po_id, supplier_id, warehouse_id, order_date, expected_delivery_date, status)
                VALUES (%s, %s, %s, CURRENT_DATE, %s, 'Pending')
                """,
                (po_id, supplier_id, warehouse_id, expected_date),
            )
            cur.execute(
                """
                INSERT INTO po_line (po_id, product_id, quantity_ordered, unit_cost)
                VALUES (%s, %s, %s, %s)
                """,
                (po_id, product_id, quantity_ordered, unit_cost),
            )
            conn.commit()
        conn.close()
        return jsonify({"ok": True, "message": f"Created Purchase Order {po_id} ({quantity_ordered}x {product_id} @ ${unit_cost})."})
    except Exception as exc:
        if conn:
            conn.rollback()
            conn.close()
        return jsonify({"ok": False, "error": str(exc)}), 400


# =============================================================================
# 5. SHIPMENTS & LOGISTICS TRACKING (FR3, FR7, BR1, BR2, BR7)
# =============================================================================
@app.route("/api/shipments")
def api_shipments():
    try:
        conn = get_db_connection()
        with conn.cursor() as cur:
            cur.execute("SELECT * FROM v_shipment_tracking_overview ORDER BY ship_date DESC")
            rows = serialize_rows(cur.fetchall())
        conn.close()
        return jsonify({"ok": True, "shipments": rows})
    except Exception as exc:
        return jsonify({"ok": False, "error": str(exc)}), 500


@app.route("/api/shipments/create", methods=["POST"])
def api_create_shipment():
    data = request.get_json(force=True)
    shipment_type = data.get("shipment_type")  # WAREHOUSE_TRANSFER or CUSTOMER_DELIVERY
    origin_warehouse_id = data.get("origin_warehouse_id")
    dest_warehouse_id = data.get("dest_warehouse_id")
    customer_id = data.get("customer_id")
    carrier_name = (data.get("carrier_name") or "DataForge Express").strip()
    product_id = data.get("product_id")
    quantity_shipped = data.get("quantity_shipped")

    conn = None
    try:
        conn = get_db_connection()
        with conn.cursor() as cur:
            cur.execute("SELECT COUNT(*) AS cnt FROM purchase_order")
            po_before = cur.fetchone()["cnt"]

            cur.execute("SELECT COALESCE(MAX(CAST(SUBSTRING(shipment_id, 5) AS UNSIGNED)), 0) + 1 AS nxt FROM shipment")
            next_num = cur.fetchone()["nxt"]
            shipment_id = f"SHP-{next_num:06d}"

            cur.execute(
                """
                INSERT INTO shipment (shipment_id, origin_warehouse_id, carrier_name, status, shipment_type)
                VALUES (%s, %s, %s, 'Pending', %s)
                """,
                (shipment_id, origin_warehouse_id, carrier_name, shipment_type),
            )

            if shipment_type == "WAREHOUSE_TRANSFER":
                cur.execute(
                    "INSERT INTO warehouse_transfer (shipment_id, dest_warehouse_id) VALUES (%s, %s)",
                    (shipment_id, dest_warehouse_id),
                )
            else:
                cur.execute(
                    "INSERT INTO customer_delivery (shipment_id, customer_id) VALUES (%s, %s)",
                    (shipment_id, customer_id),
                )

            cur.execute(
                """
                INSERT INTO shipment_line (shipment_id, product_id, quantity_shipped)
                VALUES (%s, %s, %s)
                """,
                (shipment_id, product_id, quantity_shipped),
            )

            cur.execute("SELECT COUNT(*) AS cnt FROM purchase_order")
            po_after = cur.fetchone()["cnt"]
            conn.commit()
        conn.close()

        msg = f"Created {shipment_type} {shipment_id} ({quantity_shipped}x {product_id}). Inventory deducted at {origin_warehouse_id}."
        if po_after > po_before:
            msg += " [TRIGGER FR5 FIRED] Stock dropped below reorder level -> Auto-generated Pending Restock PO!"
        return jsonify({"ok": True, "message": msg})
    except Exception as exc:
        if conn:
            conn.rollback()
            conn.close()
        return jsonify({"ok": False, "error": str(exc)}), 400


@app.route("/api/shipments/status", methods=["POST"])
def api_shipment_status():
    data = request.get_json(force=True)
    shipment_id = data.get("shipment_id")
    new_status = data.get("status")
    try:
        conn = get_db_connection()
        with conn.cursor() as cur:
            if new_status == "Delivered":
                cur.execute(
                    "UPDATE shipment SET status = %s, delivery_date = CURRENT_TIMESTAMP WHERE shipment_id = %s",
                    (new_status, shipment_id),
                )
            else:
                cur.execute(
                    "UPDATE shipment SET status = %s WHERE shipment_id = %s",
                    (new_status, shipment_id),
                )
            conn.commit()
        conn.close()
        return jsonify({"ok": True, "message": f"Updated {shipment_id} status to '{new_status}'."})
    except Exception as exc:
        return jsonify({"ok": False, "error": str(exc)}), 400


@app.route("/api/shipments/add-line", methods=["POST"])
def api_shipment_add_line():
    data = request.get_json(force=True)
    shipment_id = data.get("shipment_id")
    product_id = data.get("product_id")
    qty = data.get("quantity_shipped")
    try:
        conn = get_db_connection()
        with conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO shipment_line (shipment_id, product_id, quantity_shipped)
                VALUES (%s, %s, %s)
                """,
                (shipment_id, product_id, qty),
            )
            conn.commit()
        conn.close()
        return jsonify({"ok": True, "message": f"Added {qty}x {product_id} to {shipment_id} (inventory deducted via BR7 trigger)."})
    except Exception as exc:
        return jsonify({"ok": False, "error": str(exc)}), 400


if __name__ == "__main__":
    port = int(os.getenv("FLASK_PORT", "5000"))
    app.run(host="127.0.0.1", port=port, debug=True)

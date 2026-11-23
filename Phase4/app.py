import os
from datetime import date, datetime
from decimal import Decimal
from flask import Flask, jsonify, render_template, request
import pymysql
from pymysql.constants import CLIENT
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
        client_flag=CLIENT.FOUND_ROWS,
    )


def serialize_rows(rows):
    """Safely convert datetime, date, and Decimal values to JSON-friendly types."""
    out = []
    for row in rows:
        item = {}
        for k, v in row.items():
            if isinstance(v, datetime):
                item[k] = v.strftime("%Y-%m-%d %H:%M:%S")
            elif isinstance(v, date):
                item[k] = v.isoformat()
            elif isinstance(v, Decimal):
                item[k] = float(v)
            else:
                item[k] = v
        out.append(item)
    return out


def format_db_error(exc):
    """Return clean MySQL error message without leaking internal Python tracebacks."""
    if isinstance(exc, pymysql.MySQLError) and len(exc.args) >= 2:
        return f"MySQL Error {exc.args[0]}: {exc.args[1]}"
    return str(exc)


@app.route("/")
def index():
    return render_template("index.html")


@app.route("/api/health")
def api_health():
    conn = None
    try:
        conn = get_db_connection()
        with conn.cursor() as cur:
            cur.execute("SELECT DATABASE() AS db, VERSION() AS version")
            info = cur.fetchone()
        return jsonify({"ok": True, "database": info["db"], "version": info["version"]})
    except Exception as exc:
        return jsonify({"ok": False, "error": format_db_error(exc)}), 500
    finally:
        if conn:
            conn.close()


# =============================================================================
# 1. DASHBOARD & RESTOCK ALERTS (FR5 + Views)
# =============================================================================
@app.route("/api/dashboard")
def api_dashboard():
    conn = None
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
        return jsonify({"ok": False, "error": format_db_error(exc)}), 500
    finally:
        if conn:
            conn.close()


# =============================================================================
# 2. REAL-TIME INVENTORY MANAGEMENT (FR1, BR3, FR5 Trigger)
# =============================================================================
@app.route("/api/inventory")
def api_inventory():
    warehouse_id = request.args.get("warehouse_id", "").strip()
    conn = None
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
        return jsonify({"ok": True, "items": rows})
    except Exception as exc:
        return jsonify({"ok": False, "error": format_db_error(exc)}), 500
    finally:
        if conn:
            conn.close()


@app.route("/api/inventory/update", methods=["POST"])
def api_inventory_update():
    conn = None
    try:
        data = request.get_json(silent=True) or {}
        warehouse_id = data.get("warehouse_id")
        product_id = data.get("product_id")
        new_qty = data.get("quantity_on_hand")

        if not warehouse_id or not product_id or new_qty is None or new_qty == "":
            return jsonify({"ok": False, "error": "warehouse_id, product_id, and quantity_on_hand are required."}), 400

        conn = get_db_connection()
        with conn.cursor() as cur:
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
            if cur.rowcount == 0:
                conn.rollback()
                return jsonify({"ok": False, "error": f"Inventory record ({warehouse_id}, {product_id}) not found."}), 404

            cur.execute("SELECT COUNT(*) AS cnt FROM purchase_order")
            po_after = cur.fetchone()["cnt"]
            conn.commit()

        msg = f"Updated {product_id} at {warehouse_id} to {new_qty}."
        if po_after > po_before:
            msg += " [TRIGGER FR5 FIRED] Auto-generated a new Pending Restock Purchase Order!"
        return jsonify({"ok": True, "message": msg, "auto_po_created": po_after > po_before})
    except Exception as exc:
        if conn:
            conn.rollback()
        return jsonify({"ok": False, "error": format_db_error(exc)}), 400
    finally:
        if conn:
            conn.close()


# =============================================================================
# 3. RECURSIVE BOM EXPLORER & CYCLE TEST (FR4, BR4, Q1 & Q10)
# =============================================================================
@app.route("/api/products")
def api_products():
    conn = None
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
        return jsonify({
            "ok": True,
            "products": products,
            "warehouses": warehouses,
            "suppliers": suppliers,
            "customers": customers,
        })
    except Exception as exc:
        return jsonify({"ok": False, "error": format_db_error(exc)}), 500
    finally:
        if conn:
            conn.close()


@app.route("/api/bom/<product_id>")
def api_bom(product_id):
    warehouse_id = request.args.get("warehouse_id", "WH-000001")
    conn = None
    try:
        conn = get_db_connection()
        with conn.cursor() as cur:
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

            cur.execute("""
                WITH RECURSIVE bom_leaf AS (
                    SELECT component_product_id, quantity_required AS qty_needed, 1 AS depth
                    FROM product_component
                    WHERE parent_product_id = %s
                    UNION ALL
                    SELECT pc.component_product_id, bl.qty_needed * pc.quantity_required, bl.depth + 1
                    FROM product_component AS pc
                    INNER JOIN bom_leaf AS bl ON pc.parent_product_id = bl.component_product_id
                    WHERE bl.depth < 10
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
        max_buildable = min((r["max_units_supported"] for r in feasibility), default=0)
        return jsonify({
            "ok": True,
            "bom": bom_rows,
            "feasibility": feasibility,
            "max_buildable": max_buildable,
        })
    except Exception as exc:
        return jsonify({"ok": False, "error": format_db_error(exc)}), 500
    finally:
        if conn:
            conn.close()


@app.route("/api/bom/add", methods=["POST"])
def api_bom_add():
    conn = None
    try:
        data = request.get_json(silent=True) or {}
        parent_id = data.get("parent_product_id")
        comp_id = data.get("component_product_id")
        qty = data.get("quantity_required")
        if not parent_id or not comp_id or qty is None or qty == "":
            return jsonify({"ok": False, "error": "parent_product_id, component_product_id, and quantity_required are required."}), 400

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
        return jsonify({"ok": True, "message": f"Added BOM link {parent_id} -> {comp_id} (qty={qty})."})
    except Exception as exc:
        if conn:
            conn.rollback()
        return jsonify({"ok": False, "error": format_db_error(exc)}), 400
    finally:
        if conn:
            conn.close()


# =============================================================================
# 4. PURCHASE ORDERS & SUPPLIER COMPARISON (FR2, FR6, BR5)
# =============================================================================
@app.route("/api/procurement")
def api_procurement():
    conn = None
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
        return jsonify({"ok": True, "purchase_orders": pos, "supplier_catalog": catalog})
    except Exception as exc:
        return jsonify({"ok": False, "error": format_db_error(exc)}), 500
    finally:
        if conn:
            conn.close()


@app.route("/api/procurement/create-po", methods=["POST"])
def api_create_po():
    conn = None
    try:
        data = request.get_json(silent=True) or {}
        supplier_id = data.get("supplier_id")
        warehouse_id = data.get("warehouse_id")
        expected_date = data.get("expected_delivery_date") or None
        lines = data.get("lines")

        if not lines:
            # Backward-compatible single-line payload
            lines = [{
                "product_id": data.get("product_id"),
                "quantity_ordered": data.get("quantity_ordered"),
                "unit_cost": data.get("unit_cost"),
            }]

        if not supplier_id or not warehouse_id or not lines:
            return jsonify({"ok": False, "error": "supplier_id, warehouse_id, and at least one PO line are required."}), 400

        conn = get_db_connection()
        with conn.cursor() as cur:
            cur.execute("SELECT COALESCE(MAX(CAST(SUBSTRING(po_id, 4) AS UNSIGNED)), 0) + 1 AS nxt FROM purchase_order FOR UPDATE")
            next_num = int(cur.fetchone()["nxt"])
            po_id = f"PO-{next_num:06d}"

            cur.execute(
                """
                INSERT INTO purchase_order (po_id, supplier_id, warehouse_id, order_date, expected_delivery_date, status)
                VALUES (%s, %s, %s, CURRENT_DATE, %s, 'Pending')
                """,
                (po_id, supplier_id, warehouse_id, expected_date),
            )
            for line in lines:
                cur.execute(
                    """
                    INSERT INTO po_line (po_id, product_id, quantity_ordered, unit_cost)
                    VALUES (%s, %s, %s, %s)
                    """,
                    (po_id, line.get("product_id"), line.get("quantity_ordered"), line.get("unit_cost")),
                )
            conn.commit()
        return jsonify({"ok": True, "message": f"Created Purchase Order {po_id} with {len(lines)} line(s)."})
    except Exception as exc:
        if conn:
            conn.rollback()
        return jsonify({"ok": False, "error": format_db_error(exc)}), 400
    finally:
        if conn:
            conn.close()


@app.route("/api/procurement/status", methods=["POST"])
def api_po_status():
    conn = None
    try:
        data = request.get_json(silent=True) or {}
        po_id = data.get("po_id")
        new_status = data.get("status")
        if not po_id or not new_status:
            return jsonify({"ok": False, "error": "po_id and status are required."}), 400

        conn = get_db_connection()
        with conn.cursor() as cur:
            cur.execute(
                "UPDATE purchase_order SET status = %s WHERE po_id = %s",
                (new_status, po_id),
            )
            if cur.rowcount == 0:
                conn.rollback()
                return jsonify({"ok": False, "error": f"Purchase Order {po_id} not found."}), 404
            conn.commit()

        extra = " (Trigger 7c credited receiving warehouse inventory!)" if new_status == "Received" else ""
        return jsonify({"ok": True, "message": f"Updated {po_id} status to '{new_status}'.{extra}"})
    except Exception as exc:
        if conn:
            conn.rollback()
        return jsonify({"ok": False, "error": format_db_error(exc)}), 400
    finally:
        if conn:
            conn.close()


# =============================================================================
# 5. SHIPMENTS & LOGISTICS TRACKING (FR3, FR7, BR1, BR2, BR7)
# =============================================================================
@app.route("/api/shipments")
def api_shipments():
    conn = None
    try:
        conn = get_db_connection()
        with conn.cursor() as cur:
            cur.execute("SELECT * FROM v_shipment_tracking_overview ORDER BY ship_date DESC")
            rows = serialize_rows(cur.fetchall())
        return jsonify({"ok": True, "shipments": rows})
    except Exception as exc:
        return jsonify({"ok": False, "error": format_db_error(exc)}), 500
    finally:
        if conn:
            conn.close()


@app.route("/api/shipments/create", methods=["POST"])
def api_create_shipment():
    conn = None
    try:
        data = request.get_json(silent=True) or {}
        shipment_type = data.get("shipment_type")
        origin_warehouse_id = data.get("origin_warehouse_id")
        dest_warehouse_id = data.get("dest_warehouse_id")
        customer_id = data.get("customer_id")
        carrier_name = (data.get("carrier_name") or "DataForge Express").strip()
        product_id = data.get("product_id")
        quantity_shipped = data.get("quantity_shipped")

        if not shipment_type or not origin_warehouse_id or not product_id or quantity_shipped is None or quantity_shipped == "":
            return jsonify({"ok": False, "error": "Missing required shipment fields."}), 400

        conn = get_db_connection()
        with conn.cursor() as cur:
            cur.execute("SELECT COUNT(*) AS cnt FROM purchase_order")
            po_before = cur.fetchone()["cnt"]

            cur.execute("SELECT COALESCE(MAX(CAST(SUBSTRING(shipment_id, 5) AS UNSIGNED)), 0) + 1 AS nxt FROM shipment FOR UPDATE")
            next_num = int(cur.fetchone()["nxt"])
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

        msg = f"Created {shipment_type} {shipment_id} ({quantity_shipped}x {product_id}). Inventory deducted at {origin_warehouse_id}."
        if po_after > po_before:
            msg += " [TRIGGER FR5 FIRED] Stock dropped below reorder level -> Auto-generated Pending Restock PO!"
        return jsonify({"ok": True, "message": msg})
    except Exception as exc:
        if conn:
            conn.rollback()
        return jsonify({"ok": False, "error": format_db_error(exc)}), 400
    finally:
        if conn:
            conn.close()


@app.route("/api/shipments/status", methods=["POST"])
def api_shipment_status():
    conn = None
    try:
        data = request.get_json(silent=True) or {}
        shipment_id = data.get("shipment_id")
        new_status = data.get("status")
        if not shipment_id or not new_status:
            return jsonify({"ok": False, "error": "shipment_id and status are required."}), 400

        conn = get_db_connection()
        with conn.cursor() as cur:
            if new_status == "Delivered":
                cur.execute(
                    "UPDATE shipment SET status = %s, delivery_date = GREATEST(CURRENT_TIMESTAMP, ship_date) WHERE shipment_id = %s",
                    (new_status, shipment_id),
                )
            else:
                cur.execute(
                    "UPDATE shipment SET status = %s WHERE shipment_id = %s",
                    (new_status, shipment_id),
                )
            if cur.rowcount == 0:
                conn.rollback()
                return jsonify({"ok": False, "error": f"Shipment {shipment_id} not found."}), 404
            conn.commit()
        return jsonify({"ok": True, "message": f"Updated {shipment_id} status to '{new_status}'."})
    except Exception as exc:
        if conn:
            conn.rollback()
        return jsonify({"ok": False, "error": format_db_error(exc)}), 400
    finally:
        if conn:
            conn.close()


@app.route("/api/shipments/add-line", methods=["POST"])
def api_shipment_add_line():
    conn = None
    try:
        data = request.get_json(silent=True) or {}
        shipment_id = data.get("shipment_id")
        product_id = data.get("product_id")
        qty = data.get("quantity_shipped")
        if not shipment_id or not product_id or qty is None or qty == "":
            return jsonify({"ok": False, "error": "shipment_id, product_id, and quantity_shipped are required."}), 400

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
        return jsonify({"ok": True, "message": f"Added {qty}x {product_id} to {shipment_id} (inventory deducted via BR7 trigger)."})
    except Exception as exc:
        if conn:
            conn.rollback()
        return jsonify({"ok": False, "error": format_db_error(exc)}), 400
    finally:
        if conn:
            conn.close()


if __name__ == "__main__":
    port = int(os.getenv("FLASK_PORT", "5000"))
    debug_mode = os.getenv("FLASK_DEBUG", "0") == "1"
    app.run(host="127.0.0.1", port=port, debug=debug_mode)

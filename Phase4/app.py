import json
import math
import os
import random
import re
import time
import unicodedata
from datetime import date, datetime
from decimal import Decimal, InvalidOperation, ROUND_HALF_UP
from flask import Flask, jsonify, render_template, request
import pymysql
from pymysql.constants import CLIENT
from pymysql.cursors import DictCursor
from dotenv import load_dotenv

load_dotenv()

app = Flask(__name__)

INT_RE = re.compile(r"^[+-]?\d+$")
BUSINESS_MYSQL_ERRNOS = {
    1048,  # Column cannot be null (BR5)
    1062,  # Duplicate entry (PK / UNIQUE)
    1142,  # Table-level RBAC command denied (NFR2)
    1143,  # Column-level RBAC command denied (NFR2)
    1264,  # Out of range value for UNSIGNED column (BR3)
    1292,  # Incorrect date/datetime value
    1406,  # Data too long for column
    1451,  # Foreign key restrict on parent delete/update
    1452,  # Foreign key violation on child insert/update
    1644,  # Custom trigger SIGNAL SQLSTATE '45000' (BR1-BR7, State, Capacity)
    3819,  # CHECK constraint violation (ID format, positive cost/qty, dates)
}


class ValidationError(Exception):
    """Raised when client input fails strict schema or type validation (HTTP 400)."""


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
    """Extract safe business-rule messages without leaking internal Python tracebacks."""
    if isinstance(exc, ValidationError):
        return str(exc)
    if isinstance(exc, pymysql.MySQLError) and len(exc.args) >= 2:
        errno, msg = exc.args[0], exc.args[1]
        if errno in BUSINESS_MYSQL_ERRNOS:
            return f"MySQL Error {errno}: {msg}"
    return "Internal server error."


def handle_api_exception(exc):
    """Map ValidationError / business MySQL errors to 400/403; hide unexpected crashes behind 500."""
    if isinstance(exc, ValidationError):
        return jsonify({"ok": False, "error": str(exc)}), 400
    if isinstance(exc, pymysql.MySQLError) and len(exc.args) >= 2:
        errno = exc.args[0]
        if errno in BUSINESS_MYSQL_ERRNOS:
            http_code = 403 if errno in (1142, 1143) else 400
            return jsonify({"ok": False, "error": format_db_error(exc)}), http_code
    app.logger.exception("Unhandled API error")
    return jsonify({"ok": False, "error": "Internal server error."}), 500


@app.errorhandler(400)
@app.errorhandler(404)
@app.errorhandler(405)
@app.errorhandler(500)
def handle_http_errors(err):
    if request.path.startswith("/api/"):
        code = getattr(err, "code", 500)
        msg = getattr(err, "description", "Request failed.") if code < 500 else "Internal server error."
        return jsonify({"ok": False, "error": msg}), code
    return err


def get_json_object():
    """Ensure the request body is a valid JSON object (dict), rejecting arrays/primitives/broken JSON."""
    raw = request.get_data(as_text=True)
    if not raw or not raw.strip():
        raise ValidationError("Request body must be a non-empty JSON object.")
    try:
        data = json.loads(raw)
    except (ValueError, TypeError) as exc:
        raise ValidationError("Malformed JSON payload.") from exc
    if not isinstance(data, dict):
        raise ValidationError("JSON payload must be an object (dictionary).")
    return data


def parse_required_str(val, field_name, max_len=255):
    if val is None or isinstance(val, bool) or not isinstance(val, str):
        raise ValidationError(f"Invalid {field_name}: must be a string.")
    cleaned = val.strip()
    if not cleaned:
        raise ValidationError(f"{field_name} is required and cannot be blank.")
    if len(cleaned) > max_len:
        raise ValidationError(f"{field_name} exceeds maximum length of {max_len} characters.")
    return cleaned


def parse_carrier_name(val):
    if val is None:
        return "DataForge Express"
    if isinstance(val, bool) or not isinstance(val, str):
        raise ValidationError("Invalid carrier_name: must be a string.")
    cleaned = val.strip()
    if len(cleaned) > 100:
        raise ValidationError("Invalid carrier_name: exceeds maximum length of 100 characters.")
    return cleaned or "DataForge Express"


def parse_optional_iso_date(val, field_name):
    if val is None or val == "":
        return None
    if isinstance(val, bool) or not isinstance(val, str):
        raise ValidationError(f"Invalid {field_name}: must be a YYYY-MM-DD date string.")
    cleaned = val.strip()
    if not cleaned:
        return None
    try:
        return date.fromisoformat(cleaned).isoformat()
    except ValueError as exc:
        raise ValidationError(f"Invalid {field_name}: must be a valid YYYY-MM-DD date.") from exc


def parse_strict_int(val, field_name, min_val=0, max_val=4294967295):
    """Reject bool, float, NaN/Inf, dicts/lists, and non-integer strings strictly."""
    if isinstance(val, bool) or val is None:
        raise ValidationError(f"Invalid {field_name}: boolean or null is not allowed; expected integer.")
    if isinstance(val, int):
        n = val
    elif isinstance(val, float):
        raise ValidationError(f"Invalid {field_name}: floating-point numbers are not allowed; expected integer.")
    elif isinstance(val, str):
        s = val.strip()
        if not s or not INT_RE.match(s):
            raise ValidationError(f"Invalid {field_name}: must be a whole integer.")
        n = int(s)
    else:
        raise ValidationError(f"Invalid {field_name}: unsupported type; expected integer.")

    if n < min_val or n > max_val:
        raise ValidationError(f"Invalid {field_name}: must be an integer >= {min_val} (and <= {max_val}).")
    return n


def parse_strict_decimal(val, field_name, min_val=Decimal("0.01"), max_val=Decimal("9999999999.99")):
    """Reject bool, NaN/Inf, dicts/lists, and non-positive values strictly for currency fields."""
    if isinstance(val, bool) or val is None or isinstance(val, (dict, list, tuple, set)):
        raise ValidationError(f"Invalid {field_name}: must be a positive decimal number.")
    if isinstance(val, float) and (math.isnan(val) or math.isinf(val)):
        raise ValidationError(f"Invalid {field_name}: NaN or Infinity is not allowed.")
    raw_str = str(val).strip()
    if not raw_str:
        raise ValidationError(f"Invalid {field_name}: cannot be empty.")
    try:
        d = Decimal(raw_str)
    except InvalidOperation as exc:
        raise ValidationError(f"Invalid {field_name}: must be a valid decimal number.") from exc
    if not d.is_finite():
        raise ValidationError(f"Invalid {field_name}: NaN or Infinity is not allowed.")
    if d < min_val or d > max_val:
        raise ValidationError(f"Invalid {field_name}: must be between {min_val} and {max_val}.")
    return d.quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)


def escape_like(term: str) -> str:
    """Escape backslash, percent, and underscore for SQL LIKE ... ESCAPE '\\\\'."""
    return (
        term.replace("\\", "\\\\")
        .replace("%", "\\%")
        .replace("_", "\\_")
    )


def fold_vietnamese(text: str) -> str:
    """Strip Unicode NFD combining diacritics and map Vietnamese Đ/đ -> D/d."""
    nfd = unicodedata.normalize("NFD", text)
    no_marks = "".join(ch for ch in nfd if unicodedata.category(ch) != "Mn")
    return no_marks.replace("đ", "d").replace("Đ", "D")


def build_like_filter(columns, raw_query: str):
    """Build parameterized anti-wildcard LIKE clause supporting Vietnamese accents & Đ/đ."""
    q = (raw_query or "").strip()
    if not q:
        return "", []

    raw_pat = f"%{escape_like(q)}%"
    folded_q = fold_vietnamese(q)
    folded_pat = f"%{escape_like(folded_q)}%"

    sub_clauses = []
    params = []
    for col in columns:
        col_d_folded = f"REPLACE(REPLACE({col}, 'đ', 'd'), 'Đ', 'D')"
        if folded_pat != raw_pat:
            sub_clauses.append(f"{col} LIKE %s ESCAPE '\\\\'")
            params.append(raw_pat)
            sub_clauses.append(f"{col_d_folded} LIKE %s ESCAPE '\\\\'")
            params.append(folded_pat)
        else:
            sub_clauses.append(f"{col_d_folded} LIKE %s ESCAPE '\\\\'")
            params.append(raw_pat)

    return "(" + " OR ".join(sub_clauses) + ")", params


def parse_page_args(page_param="page", size_param="page_size", default_size=20, max_size=200):
    try:
        page = max(1, int(request.args.get(page_param, 1)))
    except (TypeError, ValueError):
        page = 1
    try:
        page_size = min(max_size, max(1, int(request.args.get(size_param, default_size))))
    except (TypeError, ValueError):
        page_size = default_size
    return page, page_size


def clamp_pagination(requested_page: int, page_size: int, total: int):
    """Clamp requested_page into [1, total_pages] before computing SQL OFFSET."""
    total_pages = max(1, math.ceil(total / page_size)) if total > 0 else 1
    clamped_page = min(max(1, requested_page), total_pages)
    offset = (clamped_page - 1) * page_size
    meta = {
        "page": clamped_page,
        "page_size": page_size,
        "total": total,
        "total_pages": total_pages,
    }
    return clamped_page, offset, meta


def run_serialized_tx(lock_names, tx_fn, max_retries=5, retry_on_seq_dup=True):
    """
    Execute tx_fn(conn, cur) under MySQL named locks (GET_LOCK / RELEASE_LOCK),
    releasing locks in finally AFTER commit/rollback, with bounded jittered retries
    on InnoDB Deadlock (1213), Lock Timeout (1205), or transient sequence collision (1062).
    """
    for attempt in range(1, max_retries + 1):
        conn = None
        acquired = []
        try:
            conn = get_db_connection()
            with conn.cursor() as cur:
                for lname in lock_names:
                    cur.execute("SELECT GET_LOCK(%s, 10) AS locked", (lname,))
                    lock_row = cur.fetchone()
                    if not lock_row or lock_row.get("locked") != 1:
                        raise RuntimeError(f"Could not acquire MySQL sequence lock '{lname}'.")
                    acquired.append(lname)

                result = tx_fn(conn, cur)
            conn.commit()
            return result
        except pymysql.MySQLError as exc:
            if conn:
                try:
                    conn.rollback()
                except Exception:
                    pass
            errno = exc.args[0] if exc.args else None
            err_msg = str(exc.args[1]) if len(exc.args) >= 2 else ""
            is_seq_dup = (
                errno == 1062
                and retry_on_seq_dup
                and (
                    "purchase_order" in err_msg
                    or ("shipment" in err_msg and "shipment_line" not in err_msg)
                )
            )
            if (errno in (1213, 1205) or is_seq_dup) and attempt < max_retries:
                if conn and acquired:
                    try:
                        with conn.cursor() as rcur:
                            for lname in reversed(acquired):
                                rcur.execute("SELECT RELEASE_LOCK(%s)", (lname,))
                    except Exception:
                        pass
                    acquired.clear()
                if conn:
                    conn.close()
                    conn = None
                time.sleep(random.uniform(0.015, 0.060) * attempt)
                continue
            raise
        except Exception:
            if conn:
                try:
                    conn.rollback()
                except Exception:
                    pass
            raise
        finally:
            if conn:
                if acquired:
                    try:
                        with conn.cursor() as rcur:
                            for lname in reversed(acquired):
                                rcur.execute("SELECT RELEASE_LOCK(%s)", (lname,))
                    except Exception:
                        pass
                conn.close()


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
    except Exception:
        app.logger.exception("Database health check failed")
        return jsonify({"ok": False, "error": "Database connection unavailable."}), 500
    finally:
        if conn:
            conn.close()


# =============================================================================
# 1. DASHBOARD & RESTOCK ALERTS (FR5 + Views + Full-DB KPIs + Paginated Alerts)
# =============================================================================
@app.route("/api/dashboard")
def api_dashboard():
    q = (request.args.get("q") or "").strip()
    wh_q = (request.args.get("wh_q") or "").strip()
    req_page, page_size = parse_page_args("page", "page_size", default_size=15)
    req_wh_page, wh_size = parse_page_args("wh_page", "wh_page_size", default_size=25)

    conn = None
    try:
        conn = get_db_connection()
        with conn.cursor() as cur:
            cur.execute("SELECT COUNT(*) AS cnt FROM warehouse")
            total_warehouses = int(cur.fetchone()["cnt"])

            cur.execute("SELECT COUNT(*) AS cnt FROM product")
            total_products = int(cur.fetchone()["cnt"])

            cur.execute("""
                SELECT COALESCE(SUM(i.quantity_on_hand * p.unit_price), 0.00) AS total_val
                FROM inventory AS i
                INNER JOIN product AS p ON i.product_id = p.product_id
            """)
            total_value = float(cur.fetchone()["total_val"] or 0.0)

            cur.execute("SELECT COUNT(*) AS cnt FROM v_restock_alerts")
            total_active_alerts = int(cur.fetchone()["cnt"])

            cur.execute("SELECT COUNT(*) AS cnt FROM shipment WHERE status = 'In Transit'")
            in_transit_shipments = int(cur.fetchone()["cnt"])

            # Filtered + Clamped Paginated Alerts
            alert_expr, alert_params = build_like_filter(
                [
                    "ra.warehouse_id",
                    "ra.warehouse_name",
                    "ra.product_id",
                    "ra.product_name",
                    "COALESCE(ra.recommended_supplier_name, '')",
                ],
                q,
            )
            alert_where = f"WHERE {alert_expr}" if alert_expr else ""

            cur.execute(f"SELECT COUNT(*) AS cnt FROM v_restock_alerts AS ra {alert_where}", alert_params)
            filtered_alerts_total = int(cur.fetchone()["cnt"])
            _, offset, alerts_meta = clamp_pagination(req_page, page_size, filtered_alerts_total)

            cur.execute(
                f"""
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
                {alert_where}
                ORDER BY ra.shortage_qty DESC, ra.warehouse_id ASC
                LIMIT %s OFFSET %s
                """,
                alert_params + [page_size, offset],
            )
            alerts = serialize_rows(cur.fetchall())

            # Filtered + Clamped Paginated Warehouse Summary
            wh_expr, wh_params = build_like_filter(
                ["warehouse_id", "warehouse_name", "manager"],
                wh_q,
            )
            wh_where = f"WHERE {wh_expr}" if wh_expr else ""

            cur.execute(f"SELECT COUNT(*) AS cnt FROM v_warehouse_inventory_summary {wh_where}", wh_params)
            wh_total = int(cur.fetchone()["cnt"])
            _, wh_offset, wh_meta = clamp_pagination(req_wh_page, wh_size, wh_total)

            cur.execute(
                f"""
                SELECT *
                FROM v_warehouse_inventory_summary
                {wh_where}
                ORDER BY warehouse_id ASC
                LIMIT %s OFFSET %s
                """,
                wh_params + [wh_size, wh_offset],
            )
            warehouses = serialize_rows(cur.fetchall())

        return jsonify({
            "ok": True,
            "kpis": {
                "total_warehouses": total_warehouses,
                "total_products": total_products,
                "total_stock_value": round(total_value, 2),
                "active_alerts": total_active_alerts,
                "in_transit_shipments": in_transit_shipments,
            },
            "warehouses": warehouses,
            "warehouses_pagination": wh_meta,
            "alerts": alerts,
            "alerts_pagination": alerts_meta,
        })
    except Exception as exc:
        return handle_api_exception(exc)
    finally:
        if conn:
            conn.close()


# =============================================================================
# 2. REAL-TIME INVENTORY MANAGEMENT (FR1, BR3, FR5 Trigger + Search & Pagination)
# =============================================================================
@app.route("/api/inventory")
def api_inventory():
    warehouse_id = (request.args.get("warehouse_id") or "").strip()
    q = (request.args.get("q") or "").strip()
    low_only = (request.args.get("low_only") or "").strip() == "1"
    req_page, page_size = parse_page_args("page", "page_size", default_size=20)

    conn = None
    try:
        conn = get_db_connection()
        with conn.cursor() as cur:
            base_from = """
                FROM inventory AS i
                INNER JOIN warehouse AS w ON i.warehouse_id = w.warehouse_id
                INNER JOIN product AS p ON i.product_id = p.product_id
            """
            clauses = []
            params = []
            if warehouse_id:
                clauses.append("i.warehouse_id = %s")
                params.append(warehouse_id)
            if low_only:
                clauses.append("i.quantity_on_hand < p.reorder_level")
            if q:
                like_expr, like_params = build_like_filter(
                    ["i.product_id", "p.name", "p.category", "i.warehouse_id", "w.name", "w.address"],
                    q,
                )
                clauses.append(like_expr)
                params.extend(like_params)

            where_sql = (" WHERE " + " AND ".join(clauses)) if clauses else ""

            cur.execute(f"SELECT COUNT(*) AS cnt {base_from} {where_sql}", params)
            total = int(cur.fetchone()["cnt"])
            _, offset, page_meta = clamp_pagination(req_page, page_size, total)

            cur.execute(
                f"""
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
                {base_from}
                {where_sql}
                ORDER BY i.warehouse_id ASC, i.product_id ASC
                LIMIT %s OFFSET %s
                """,
                params + [page_size, offset],
            )
            rows = serialize_rows(cur.fetchall())
        return jsonify({
            "ok": True,
            "items": rows,
            "pagination": page_meta,
        })
    except Exception as exc:
        return handle_api_exception(exc)
    finally:
        if conn:
            conn.close()


@app.route("/api/inventory/update", methods=["POST"])
def api_inventory_update():
    try:
        data = get_json_object()
        warehouse_id = parse_required_str(data.get("warehouse_id"), "warehouse_id", max_len=10)
        product_id = parse_required_str(data.get("product_id"), "product_id", max_len=10)
        new_qty = parse_strict_int(data.get("quantity_on_hand"), "quantity_on_hand", min_val=0)

        def _tx(conn, cur):
            cur.execute("SELECT COUNT(*) AS cnt FROM purchase_order")
            po_before = int(cur.fetchone()["cnt"])

            cur.execute(
                """
                UPDATE inventory
                SET quantity_on_hand = %s
                WHERE warehouse_id = %s AND product_id = %s
                """,
                (new_qty, warehouse_id, product_id),
            )
            if cur.rowcount == 0:
                return None

            cur.execute("SELECT COUNT(*) AS cnt FROM purchase_order")
            po_after = int(cur.fetchone()["cnt"])
            return po_after > po_before

        auto_po_created = run_serialized_tx(("dataforge_seq_po",), _tx)
        if auto_po_created is None:
            return jsonify({"ok": False, "error": f"Inventory record ({warehouse_id}, {product_id}) not found."}), 404

        msg = f"Updated {product_id} at {warehouse_id} to {new_qty}."
        if auto_po_created:
            msg += " [TRIGGER FR5 FIRED] Auto-generated a new Pending Restock Purchase Order!"
        return jsonify({"ok": True, "message": msg, "auto_po_created": auto_po_created})
    except Exception as exc:
        return handle_api_exception(exc)


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
            cur.execute("""
                SELECT
                    sp.supplier_id,
                    sp.product_id,
                    p.name AS product_name,
                    sp.supply_cost,
                    sp.lead_time_days
                FROM supplier_product AS sp
                INNER JOIN product AS p ON sp.product_id = p.product_id
                ORDER BY sp.supplier_id ASC, sp.product_id ASC
            """)
            supplier_products = serialize_rows(cur.fetchall())
        return jsonify({
            "ok": True,
            "products": products,
            "warehouses": warehouses,
            "suppliers": suppliers,
            "customers": customers,
            "supplier_products": supplier_products,
        })
    except Exception as exc:
        return handle_api_exception(exc)
    finally:
        if conn:
            conn.close()


@app.route("/api/bom/<product_id>")
def api_bom(product_id):
    warehouse_id = (request.args.get("warehouse_id") or "WH-000001").strip()
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
                        CAST(CONCAT(pc.parent_product_id, ' -> ', pc.component_product_id) AS CHAR(1000)) AS bom_path
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
                    WHERE bl.depth < 15
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
        return handle_api_exception(exc)
    finally:
        if conn:
            conn.close()


@app.route("/api/bom/add", methods=["POST"])
def api_bom_add():
    conn = None
    try:
        data = get_json_object()
        parent_id = parse_required_str(data.get("parent_product_id"), "parent_product_id", max_len=10)
        comp_id = parse_required_str(data.get("component_product_id"), "component_product_id", max_len=10)
        qty = parse_strict_int(data.get("quantity_required"), "quantity_required", min_val=1)

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
        return handle_api_exception(exc)
    finally:
        if conn:
            conn.close()


# =============================================================================
# 4. PURCHASE ORDERS & SUPPLIER COMPARISON (FR2, FR6, BR5 + Search & Pagination)
# =============================================================================
@app.route("/api/procurement")
def api_procurement():
    q = (request.args.get("q") or "").strip()
    status = (request.args.get("status") or "").strip()
    req_page, page_size = parse_page_args("page", "page_size", default_size=15)

    cat_q = (request.args.get("cat_q") or "").strip()
    req_cat_page, cat_size = parse_page_args("cat_page", "cat_page_size", default_size=15)

    conn = None
    try:
        conn = get_db_connection()
        with conn.cursor() as cur:
            po_base = """
                FROM purchase_order AS po
                INNER JOIN supplier AS s ON po.supplier_id = s.supplier_id
                INNER JOIN warehouse AS w ON po.warehouse_id = w.warehouse_id
            """
            po_clauses = []
            po_params = []
            if status:
                po_clauses.append("po.status = %s")
                po_params.append(status)
            if q:
                po_like_expr, po_like_params = build_like_filter(
                    [
                        "po.po_id",
                        "s.name",
                        "po.supplier_id",
                        "w.name",
                        "po.warehouse_id",
                        "COALESCE(s.address, '')",
                    ],
                    q,
                )
                po_clauses.append(po_like_expr)
                po_params.extend(po_like_params)
            po_where = (" WHERE " + " AND ".join(po_clauses)) if po_clauses else ""

            cur.execute(f"SELECT COUNT(*) AS cnt {po_base} {po_where}", po_params)
            po_total = int(cur.fetchone()["cnt"])
            _, offset, po_meta = clamp_pagination(req_page, page_size, po_total)

            cur.execute(
                f"""
                SELECT
                    po.po_id,
                    po.order_date,
                    po.expected_delivery_date,
                    po.status,
                    s.name AS supplier_name,
                    w.name AS warehouse_name,
                    COUNT(pol.product_id) AS line_count,
                    COALESCE(SUM(pol.quantity_ordered * pol.unit_cost), 0) AS total_amount
                {po_base}
                LEFT JOIN po_line AS pol ON po.po_id = pol.po_id
                {po_where}
                GROUP BY po.po_id, po.order_date, po.expected_delivery_date, po.status, s.name, w.name
                ORDER BY po.po_id DESC
                LIMIT %s OFFSET %s
                """,
                po_params + [page_size, offset],
            )
            pos = serialize_rows(cur.fetchall())

            cat_base = """
                FROM supplier_product AS sp
                INNER JOIN product AS p ON sp.product_id = p.product_id
                INNER JOIN supplier AS s ON sp.supplier_id = s.supplier_id
            """
            cat_expr, cat_params = build_like_filter(
                ["p.product_id", "p.name", "s.supplier_id", "s.name", "COALESCE(s.address, '')"],
                cat_q,
            )
            cat_where = f" WHERE {cat_expr}" if cat_expr else ""

            cur.execute(f"SELECT COUNT(*) AS cnt {cat_base} {cat_where}", cat_params)
            cat_total = int(cur.fetchone()["cnt"])
            _, cat_offset, cat_meta = clamp_pagination(req_cat_page, cat_size, cat_total)

            cur.execute(
                f"""
                SELECT
                    p.product_id,
                    p.name AS product_name,
                    s.supplier_id,
                    s.name AS supplier_name,
                    sp.supply_cost,
                    sp.lead_time_days
                {cat_base}
                {cat_where}
                ORDER BY p.product_id ASC, sp.supply_cost ASC
                LIMIT %s OFFSET %s
                """,
                cat_params + [cat_size, cat_offset],
            )
            catalog = serialize_rows(cur.fetchall())

        return jsonify({
            "ok": True,
            "purchase_orders": pos,
            "pagination": po_meta,
            "po_pagination": po_meta,
            "supplier_catalog": catalog,
            "catalog_pagination": cat_meta,
        })
    except Exception as exc:
        return handle_api_exception(exc)
    finally:
        if conn:
            conn.close()


@app.route("/api/procurement/create-po", methods=["POST"])
def api_create_po():
    try:
        data = get_json_object()
        supplier_id = parse_required_str(data.get("supplier_id"), "supplier_id", max_len=10)
        warehouse_id = parse_required_str(data.get("warehouse_id"), "warehouse_id", max_len=10)
        expected_date = parse_optional_iso_date(data.get("expected_delivery_date"), "expected_delivery_date")

        if "lines" in data:
            raw_lines = data["lines"]
            if not isinstance(raw_lines, list) or len(raw_lines) == 0:
                raise ValidationError("Invalid lines: must be a non-empty list of PO line objects.")
            for idx, item in enumerate(raw_lines):
                if not isinstance(item, dict):
                    raise ValidationError(f"Invalid lines[{idx}]: each line item must be a JSON object.")
        else:
            if data.get("product_id") is None and data.get("quantity_ordered") is None:
                raise ValidationError("At least one PO line (lines) is required.")
            raw_lines = [{
                "product_id": data.get("product_id"),
                "quantity_ordered": data.get("quantity_ordered"),
                "unit_cost": data.get("unit_cost"),
            }]

        validated_lines = []
        seen_products = set()
        for idx, line in enumerate(raw_lines):
            pid = parse_required_str(line.get("product_id"), f"lines[{idx}].product_id", max_len=10)
            if pid in seen_products:
                raise ValidationError(f"Duplicate product_id '{pid}' in PO lines.")
            seen_products.add(pid)
            qty = parse_strict_int(line.get("quantity_ordered"), f"lines[{idx}].quantity_ordered", min_val=1)
            cost = parse_strict_decimal(line.get("unit_cost"), f"lines[{idx}].unit_cost", min_val=Decimal("0.01"))
            validated_lines.append((pid, qty, str(cost)))

        def _tx(conn, cur):
            cur.execute(
                "SELECT CAST(SUBSTRING(po_id, 4) AS UNSIGNED) AS last_num "
                "FROM purchase_order ORDER BY po_id DESC LIMIT 1 FOR UPDATE"
            )
            row = cur.fetchone()
            next_num = (int(row["last_num"]) + 1) if row else 1
            new_po_id = f"PO-{next_num:06d}"

            cur.execute(
                """
                INSERT INTO purchase_order (po_id, supplier_id, warehouse_id, order_date, expected_delivery_date, status)
                VALUES (%s, %s, %s, CURRENT_DATE, %s, 'Pending')
                """,
                (new_po_id, supplier_id, warehouse_id, expected_date),
            )
            for pid, qty, cost_str in validated_lines:
                cur.execute(
                    """
                    INSERT INTO po_line (po_id, product_id, quantity_ordered, unit_cost)
                    VALUES (%s, %s, %s, %s)
                    """,
                    (new_po_id, pid, qty, cost_str),
                )
            return new_po_id

        po_id = run_serialized_tx(("dataforge_seq_po",), _tx, retry_on_seq_dup=True)
        return jsonify({
            "ok": True,
            "po_id": po_id,
            "message": f"Created Purchase Order {po_id} with {len(validated_lines)} line(s).",
        })
    except Exception as exc:
        return handle_api_exception(exc)


@app.route("/api/procurement/status", methods=["POST"])
def api_po_status():
    conn = None
    try:
        data = get_json_object()
        po_id = parse_required_str(data.get("po_id"), "po_id", max_len=10)
        new_status = parse_required_str(data.get("status"), "status", max_len=20)

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
        return handle_api_exception(exc)
    finally:
        if conn:
            conn.close()


# =============================================================================
# 5. SHIPMENTS & LOGISTICS TRACKING (FR3, FR7, BR1, BR2, BR7 + Search & Pagination)
# =============================================================================
@app.route("/api/shipments")
def api_shipments():
    q = (request.args.get("q") or "").strip()
    status = (request.args.get("status") or "").strip()
    shipment_type = (request.args.get("shipment_type") or "").strip()
    req_page, page_size = parse_page_args("page", "page_size", default_size=20)

    conn = None
    try:
        conn = get_db_connection()
        with conn.cursor() as cur:
            clauses = []
            params = []
            if status:
                clauses.append("status = %s")
                params.append(status)
            if shipment_type:
                clauses.append("shipment_type = %s")
                params.append(shipment_type)
            if q:
                ship_like_expr, ship_like_params = build_like_filter(
                    [
                        "shipment_id",
                        "carrier_name",
                        "origin_warehouse_id",
                        "origin_warehouse_name",
                        "COALESCE(destination_id, '')",
                        "COALESCE(destination_name, '')",
                    ],
                    q,
                )
                clauses.append(ship_like_expr)
                params.extend(ship_like_params)
            where_sql = (" WHERE " + " AND ".join(clauses)) if clauses else ""

            cur.execute(f"SELECT COUNT(*) AS cnt FROM v_shipment_tracking_overview {where_sql}", params)
            total = int(cur.fetchone()["cnt"])
            _, offset, page_meta = clamp_pagination(req_page, page_size, total)

            cur.execute(
                f"""
                SELECT *
                FROM v_shipment_tracking_overview
                {where_sql}
                ORDER BY ship_date DESC, shipment_id DESC
                LIMIT %s OFFSET %s
                """,
                params + [page_size, offset],
            )
            rows = serialize_rows(cur.fetchall())
        return jsonify({
            "ok": True,
            "shipments": rows,
            "pagination": page_meta,
        })
    except Exception as exc:
        return handle_api_exception(exc)
    finally:
        if conn:
            conn.close()


@app.route("/api/shipments/create", methods=["POST"])
def api_create_shipment():
    try:
        data = get_json_object()
        shipment_type = parse_required_str(data.get("shipment_type"), "shipment_type", max_len=30)
        origin_warehouse_id = parse_required_str(data.get("origin_warehouse_id"), "origin_warehouse_id", max_len=10)
        carrier_name = parse_carrier_name(data.get("carrier_name"))

        if shipment_type == "WAREHOUSE_TRANSFER":
            dest_warehouse_id = parse_required_str(data.get("dest_warehouse_id"), "dest_warehouse_id", max_len=10)
            customer_id = None
        elif shipment_type == "CUSTOMER_DELIVERY":
            customer_id = parse_required_str(data.get("customer_id"), "customer_id", max_len=10)
            dest_warehouse_id = None
        else:
            raise ValidationError("Invalid shipment_type: must be WAREHOUSE_TRANSFER or CUSTOMER_DELIVERY.")

        if "lines" in data:
            raw_lines = data["lines"]
            if not isinstance(raw_lines, list) or len(raw_lines) == 0:
                raise ValidationError("Invalid lines: must be a non-empty list of shipment line objects.")
            for idx, item in enumerate(raw_lines):
                if not isinstance(item, dict):
                    raise ValidationError(f"Invalid lines[{idx}]: each line item must be a JSON object.")
        else:
            raw_lines = [{
                "product_id": data.get("product_id"),
                "quantity_shipped": data.get("quantity_shipped"),
            }]

        validated_lines = []
        seen_products = set()
        for idx, line in enumerate(raw_lines):
            pid_label = f"lines[{idx}].product_id" if "lines" in data else "product_id"
            qty_label = f"lines[{idx}].quantity_shipped" if "lines" in data else "quantity_shipped"
            pid = parse_required_str(line.get("product_id"), pid_label, max_len=10)
            if pid in seen_products:
                raise ValidationError(f"Duplicate product_id '{pid}' in shipment lines.")
            seen_products.add(pid)
            qty = parse_strict_int(line.get("quantity_shipped"), qty_label, min_val=1)
            validated_lines.append((pid, qty))

        def _tx(conn, cur):
            cur.execute("SELECT COUNT(*) AS cnt FROM purchase_order")
            po_before = int(cur.fetchone()["cnt"])

            cur.execute(
                "SELECT CAST(SUBSTRING(shipment_id, 5) AS UNSIGNED) AS last_num "
                "FROM shipment ORDER BY shipment_id DESC LIMIT 1 FOR UPDATE"
            )
            row = cur.fetchone()
            next_num = (int(row["last_num"]) + 1) if row else 1
            new_shipment_id = f"SHP-{next_num:06d}"

            cur.execute(
                """
                INSERT INTO shipment (shipment_id, origin_warehouse_id, carrier_name, status, shipment_type)
                VALUES (%s, %s, %s, 'Pending', %s)
                """,
                (new_shipment_id, origin_warehouse_id, carrier_name, shipment_type),
            )

            if shipment_type == "WAREHOUSE_TRANSFER":
                cur.execute(
                    "INSERT INTO warehouse_transfer (shipment_id, dest_warehouse_id) VALUES (%s, %s)",
                    (new_shipment_id, dest_warehouse_id),
                )
            else:
                cur.execute(
                    "INSERT INTO customer_delivery (shipment_id, customer_id) VALUES (%s, %s)",
                    (new_shipment_id, customer_id),
                )

            for pid, qty in validated_lines:
                cur.execute(
                    """
                    INSERT INTO shipment_line (shipment_id, product_id, quantity_shipped)
                    VALUES (%s, %s, %s)
                    """,
                    (new_shipment_id, pid, qty),
                )

            cur.execute("SELECT COUNT(*) AS cnt FROM purchase_order")
            po_after = int(cur.fetchone()["cnt"])
            return new_shipment_id, (po_after > po_before)

        # Fixed lock acquisition order: dataforge_seq_po -> dataforge_seq_shp prevents lock-order inversion
        shipment_id, auto_po = run_serialized_tx(
            ("dataforge_seq_po", "dataforge_seq_shp"),
            _tx,
            retry_on_seq_dup=True,
        )

        summary = ", ".join(f"{q}x {p}" for p, q in validated_lines)
        msg = f"Created {shipment_type} {shipment_id} ({summary}). Inventory deducted at {origin_warehouse_id}."
        if auto_po:
            msg += " [TRIGGER FR5 FIRED] Stock dropped below reorder level -> Auto-generated Pending Restock PO!"
        return jsonify({"ok": True, "shipment_id": shipment_id, "carrier_name": carrier_name, "message": msg})
    except Exception as exc:
        return handle_api_exception(exc)


@app.route("/api/shipments/status", methods=["POST"])
def api_shipment_status():
    conn = None
    try:
        data = get_json_object()
        shipment_id = parse_required_str(data.get("shipment_id"), "shipment_id", max_len=10)
        new_status = parse_required_str(data.get("status"), "status", max_len=20)

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
        return handle_api_exception(exc)
    finally:
        if conn:
            conn.close()


@app.route("/api/shipments/add-line", methods=["POST"])
def api_shipment_add_line():
    try:
        data = get_json_object()
        shipment_id = parse_required_str(data.get("shipment_id"), "shipment_id", max_len=10)
        product_id = parse_required_str(data.get("product_id"), "product_id", max_len=10)
        qty = parse_strict_int(data.get("quantity_shipped"), "quantity_shipped", min_val=1)

        def _tx(conn, cur):
            cur.execute(
                """
                INSERT INTO shipment_line (shipment_id, product_id, quantity_shipped)
                VALUES (%s, %s, %s)
                """,
                (shipment_id, product_id, qty),
            )

        run_serialized_tx(("dataforge_seq_po",), _tx, retry_on_seq_dup=True)
        return jsonify({
            "ok": True,
            "message": f"Added {qty}x {product_id} to {shipment_id} (inventory deducted via BR7 trigger).",
        })
    except Exception as exc:
        return handle_api_exception(exc)


if __name__ == "__main__":
    port = int(os.getenv("FLASK_PORT", "5000"))
    debug_mode = os.getenv("FLASK_DEBUG", "0") == "1"
    app.run(host="127.0.0.1", port=port, debug=debug_mode)

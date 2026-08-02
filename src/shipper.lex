# shipper.lex — the demand side: shipper (buyer) + consignee (receiver) personas.
#
# The shipper places and tracks freight orders against lex-tms — including
# STANDING orders: an autonomy tick (agent_schedules) prompts it on an
# interval, it checks whether the recurring order already exists and creates
# it only if missing. The consignee watches inbound orders and confirms
# delivery. Together they close the loop the fleet-side personas
# (tms/truck/depot) execute in the middle of.

import "std.str" as str

import "std.http" as http

import "std.bytes" as bytes

import "std.map" as map

import "std.int" as int

import "lex-schema/json_value" as jv

import "lex-schema/schema" as sch

import "lex-schema/error" as e

import "lex-spec/capability" as cap

import "lex-llm/src/tool" as t

import "lex-agent/src/server" as srv

import "lex-agent/src/agent_card" as card

import "lex-soft/src/runner" as runner

import "./intents" as intents

fn tenant_req(method :: Str, url :: Str, body :: Option[Bytes], tenant :: Str) -> { method :: Str, url :: Str, headers :: Map[Str, Str], body :: Option[Bytes], timeout_ms :: Option[Int] } {
  let base := { method: method, url: url, headers: map.new(), body: body, timeout_ms: Some(30000) }
  let with_ct := http.with_header(base, "Content-Type", "application/json")
  if str.is_empty(tenant) {
    with_ct
  } else {
    http.with_header(with_ct, "X-Tenant-Id", tenant)
  }
}

fn http_get_json(url :: Str, tenant :: Str) -> [net] jv.Json {
  match http.send(tenant_req("GET", url, None, tenant)) {
    Err(_) => JObj([("error", JStr("unreachable"))]),
    Ok(resp) => match bytes.to_str(resp.body) {
      Err(_) => JObj([("error", JStr("decode error"))]),
      Ok(body) => match jv.parse(body) {
        Err(_) => JStr(body),
        Ok(j) => j,
      },
    },
  }
}

fn http_post_json(url :: Str, body :: Str, tenant :: Str) -> [net] jv.Json {
  match http.send(tenant_req("POST", url, Some(bytes.from_str(body)), tenant)) {
    Err(_) => JObj([("error", JStr("unreachable"))]),
    Ok(resp) => match bytes.to_str(resp.body) {
      Err(_) => JObj([("error", JStr("decode error"))]),
      Ok(b) => match jv.parse(b) {
        Err(_) => JStr(b),
        Ok(j) => j,
      },
    },
  }
}

fn http_patch_json(url :: Str, body :: Str, tenant :: Str) -> [net] jv.Json {
  match http.send(tenant_req("PATCH", url, Some(bytes.from_str(body)), tenant)) {
    Err(_) => JObj([("error", JStr("unreachable"))]),
    Ok(resp) => match bytes.to_str(resp.body) {
      Err(_) => JObj([("error", JStr("decode error"))]),
      Ok(b) => match jv.parse(b) {
        Err(_) => JStr(b),
        Ok(j) => j,
      },
    },
  }
}

fn arg_str(args :: jv.Json, key :: Str) -> Str {
  match jv.get_field(args, key) {
    Some(JStr(s)) => s,
    _ => "",
  }
}

fn shipper_capability() -> cap.Capability {
  cap.inbound("handle", "Accept demand-side events: standing-order ticks, order confirmations, dispatch updates.", { title: "ShipperMessage", description: "Inbound message for a shipper agent.", fields: [sch.required_str("text", [])] })
}

fn consignee_capability() -> cap.Capability {
  cap.inbound("handle", "Accept receiving-side events: inbound ETAs, arrival notices, delivery confirmations.", { title: "ConsigneeMessage", description: "Inbound message for a consignee agent.", fields: [sch.required_str("text", [])] })
}

# ── Shipper (buyer) ───────────────────────────────────────────────────────────
fn make_shipper_tools(tms_url :: Str, inventory_url :: Str, tenant :: Str) -> List[t.Tool] {
  [t.define("get_stock", "Get current stock levels for all items: quantity, min/target and a below_min flag.", { title: "GetStock", description: "No parameters.", fields: [] }, fn (_args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    Ok(http_get_json(str.concat(inventory_url, "/api/v1/stock"), tenant))
  }), t.define("get_reorder_proposals", "Items whose stock is below the reorder point, each with a suggested order quantity (up to target).", { title: "GetReorderProposals", description: "No parameters.", fields: [] }, fn (_args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    Ok(http_get_json(str.concat(inventory_url, "/api/v1/reorder-proposals"), tenant))
  }), t.define("get_my_orders", "List freight orders, optionally filtered by status (pending, assigned, in_transit, delivered, cancelled).", { title: "GetMyOrders", description: "Order listing.", fields: [sch.optional(sch.required_str("status", []))] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    let s := arg_str(args, "status")
    if str.is_empty(s) {
      Ok(http_get_json(str.concat(tms_url, "/api/v1/orders"), tenant))
    } else {
      Ok(http_get_json(str.concat(tms_url, str.concat("/api/v1/orders?status=", s)), tenant))
    }
  }), t.define("create_order", "Create a new freight order. Use a unique order_number (e.g. include the week or date).", { title: "CreateOrder", description: "Freight order creation.", fields: [sch.required_str("order_number", []), sch.required_str("shipper_name", []), sch.required_str("consignee_name", []), sch.required_str("pickup_address", []), sch.required_str("delivery_address", []), sch.required_str("requested_pickup_date", []), sch.required_float("weight_kg", []), sch.optional(sch.required_str("cargo_description", []))] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    Ok(http_post_json(str.concat(tms_url, "/api/v1/orders"), jv.stringify(args), tenant))
  }), t.define("track_order", "Get full details and current status for a specific order.", { title: "TrackOrder", description: "Order lookup.", fields: [sch.required_str("order_id", [])] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    Ok(http_get_json(str.concat(tms_url, str.concat("/api/v1/orders/", arg_str(args, "order_id"))), tenant))
  }), t.define("cancel_order", "Cancel an order that is no longer needed.", { title: "CancelOrder", description: "Order cancellation.", fields: [sch.required_str("order_id", [])] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    Ok(http_patch_json(str.concat(tms_url, str.concat("/api/v1/orders/", str.concat(arg_str(args, "order_id"), "/status"))), "{\"status\":\"cancelled\"}", tenant))
  })]
}

fn shipper_system_prompt(shipper_id :: Str) -> Str {
  str.join(["You are purchasing and shipping agent ", shipper_id, ". You represent the demand side: you place freight orders and keep standing (recurring) orders fulfilled.", " Respond directly and decisively to messages you receive:", " - For a standing-order tick (e.g. 'ensure this week's coffee order exists'): call get_my_orders first; if an open order (pending/assigned/in_transit) already covers that cargo, report it and do NOT create a duplicate; otherwise create_order with a unique order_number that includes the period (e.g. <SKU>-<year>-W<week>).", " - For a stock check tick ('replenish what is low'): call get_reorder_proposals; for each proposal not already covered by an open order, create_order for the suggested quantity. If nothing is below minimum, report stock is healthy and do nothing.", " - For a dispatch or delivery update: acknowledge it and note the order status.", " - For general queries: summarise your open orders and their statuses.", " Be professional and concise. Never invent order data — always check via tools first."], "")
}

fn make_shipper_def(db :: Db, shipper_id :: Str, base_url :: Str, tms_url :: Str, inventory_url :: Str, provider_name :: Str, provider_url :: Str, provider_key :: Str, model_name :: Str) -> srv.AgentDef {
  let capability := shipper_capability()
  let cfg := { id: shipper_id, kind: "shipper", system_prompt: shipper_system_prompt(shipper_id), model_name: model_name, provider_name: provider_name, provider_url: provider_url, provider_key: provider_key, backends: [{ key: "tms_url", url: tms_url }, { key: "inventory_url", url: inventory_url }], intent_roles: intents.fleet(), tools: make_shipper_tools(tms_url, inventory_url, "") }
  let handler := runner.make_handler(db, cfg)
  let c := card.make(shipper_id, str.concat("Shipper (demand-side) agent ", shipper_id), "0.3.0", base_url, [capability])
  srv.make_agent_def(c, [{ capability: capability, handle: handler }])
}

# ── Consignee (receiver) ──────────────────────────────────────────────────────
fn make_consignee_tools(tms_url :: Str, inventory_url :: Str, tenant :: Str) -> List[t.Tool] {
  [t.define("get_my_orders", "List freight orders, optionally filtered by status (pending, assigned, in_transit, delivered, cancelled).", { title: "GetMyOrders", description: "Order listing.", fields: [sch.optional(sch.required_str("status", []))] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    let s := arg_str(args, "status")
    if str.is_empty(s) {
      Ok(http_get_json(str.concat(tms_url, "/api/v1/orders"), tenant))
    } else {
      Ok(http_get_json(str.concat(tms_url, str.concat("/api/v1/orders?status=", s)), tenant))
    }
  }), t.define("get_inbound_orders", "List orders currently on their way (status in_transit) plus assigned ones not yet moving.", { title: "GetInboundOrders", description: "No parameters.", fields: [] }, fn (_args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    Ok(http_get_json(str.concat(tms_url, "/api/v1/orders?status=in_transit"), tenant))
  }), t.define("track_order", "Get full details and current status for a specific order.", { title: "TrackOrder", description: "Order lookup.", fields: [sch.required_str("order_id", [])] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    Ok(http_get_json(str.concat(tms_url, str.concat("/api/v1/orders/", arg_str(args, "order_id"))), tenant))
  }), t.define("confirm_delivery", "Confirm goods arrived in order: marks the order delivered (proof of delivery).", { title: "ConfirmDelivery", description: "Delivery confirmation.", fields: [sch.required_str("order_id", [])] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    Ok(http_patch_json(str.concat(tms_url, str.concat("/api/v1/orders/", str.concat(arg_str(args, "order_id"), "/status"))), "{\"status\":\"delivered\"}", tenant))
  }), t.define("receive_goods", "Record received goods into stock (positive inventory movement). Use after confirming a delivery.", { title: "ReceiveGoods", description: "Goods receipt into inventory.", fields: [sch.required_str("sku", []), sch.required_float("qty", []), sch.optional(sch.required_str("reason", []))] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    let qty := match jv.get_field(args, "qty") {
      Some(JFloat(n)) => n,
      Some(JInt(n)) => int.to_float(n),
      _ => 0.0,
    }
    let body := jv.stringify(JObj([("sku", JStr(arg_str(args, "sku"))), ("delta", JFloat(qty)), ("reason", JStr(arg_str(args, "reason")))]))
    Ok(http_post_json(str.concat(inventory_url, "/api/v1/movements"), body, tenant))
  })]
}

fn consignee_system_prompt(consignee_id :: Str) -> Str {
  str.join(["You are receiving agent ", consignee_id, ". You watch inbound freight for your site and confirm deliveries.", " Respond directly and decisively to messages you receive:", " - For an arrival notice or delivery hand-over: verify the order via track_order, then confirm_delivery, then receive_goods for the delivered sku and quantity so stock is updated.", " - For an ETA query: check get_inbound_orders and report what is on its way.", " - For general queries: summarise inbound orders and recent receipts.", " Be professional and concise. Only confirm_delivery when a message states goods actually arrived."], "")
}

fn make_consignee_def(db :: Db, consignee_id :: Str, base_url :: Str, tms_url :: Str, inventory_url :: Str, provider_name :: Str, provider_url :: Str, provider_key :: Str, model_name :: Str) -> srv.AgentDef {
  let capability := consignee_capability()
  let cfg := { id: consignee_id, kind: "consignee", system_prompt: consignee_system_prompt(consignee_id), model_name: model_name, provider_name: provider_name, provider_url: provider_url, provider_key: provider_key, backends: [{ key: "tms_url", url: tms_url }, { key: "inventory_url", url: inventory_url }], intent_roles: intents.fleet(), tools: make_consignee_tools(tms_url, inventory_url, "") }
  let handler := runner.make_handler(db, cfg)
  let c := card.make(consignee_id, str.concat("Consignee (receiving) agent ", consignee_id), "0.3.0", base_url, [capability])
  srv.make_agent_def(c, [{ capability: capability, handle: handler }])
}

# ── Seller (supplier / ATP) ───────────────────────────────────────────────────
fn seller_capability() -> cap.Capability {
  cap.inbound("handle", "Accept supply-side events: availability requests (ATP), order confirmations, stock commitments.", { title: "SellerMessage", description: "Inbound message for a seller agent.", fields: [sch.required_str("text", [])] })
}

fn make_seller_tools(inventory_url :: Str, tenant :: Str) -> List[t.Tool] {
  [t.define("get_stock", "Get current finished-goods stock levels for all items.", { title: "GetStock", description: "No parameters.", fields: [] }, fn (_args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    Ok(http_get_json(str.concat(inventory_url, "/api/v1/stock"), tenant))
  }), t.define("check_atp", "Check available-to-promise for one sku: how much can be committed to a buyer right now.", { title: "CheckAtp", description: "ATP lookup.", fields: [sch.required_str("sku", [])] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    Ok(http_get_json(str.concat(inventory_url, str.concat("/api/v1/atp/", arg_str(args, "sku"))), tenant))
  }), t.define("commit_stock", "Commit stock to a confirmed order: records a negative movement (reservation/shipment).", { title: "CommitStock", description: "Stock commitment.", fields: [sch.required_str("sku", []), sch.required_float("qty", []), sch.optional(sch.required_str("reason", []))] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    let qty := match jv.get_field(args, "qty") {
      Some(JFloat(n)) => n,
      Some(JInt(n)) => int.to_float(n),
      _ => 0.0,
    }
    let body := jv.stringify(JObj([("sku", JStr(arg_str(args, "sku"))), ("delta", JFloat(0.0 - qty)), ("reason", JStr(arg_str(args, "reason")))]))
    Ok(http_post_json(str.concat(inventory_url, "/api/v1/movements"), body, tenant))
  })]
}

fn seller_system_prompt(seller_id :: Str) -> Str {
  str.join(["You are supply-side (seller) agent ", seller_id, ". You represent a goods producer: you answer availability requests and commit stock to confirmed orders.", " Respond directly and decisively to messages you receive:", " - For an availability request: call check_atp for the sku and answer with the quantity you can promise and by when.", " - For an order confirmation: verify availability via check_atp, then commit_stock for the confirmed quantity with the order number as reason.", " - After committing stock for an order, TENDER the transport: call find_peers with intent dispatch; if a dispatcher peer exists, send_message to it (topic handle) with: transport tender, the order number, weight in kg, pickup at your own site (as recorded in your profile or named in the request), and the delivery address and consignee named in the request.", " - For general queries: summarise stock via get_stock.", " Be professional and concise. Never promise more than check_atp reports."], "")
}

fn make_seller_def(db :: Db, seller_id :: Str, base_url :: Str, inventory_url :: Str, provider_name :: Str, provider_url :: Str, provider_key :: Str, model_name :: Str) -> srv.AgentDef {
  let capability := seller_capability()
  let cfg := { id: seller_id, kind: "seller", system_prompt: seller_system_prompt(seller_id), model_name: model_name, provider_name: provider_name, provider_url: provider_url, provider_key: provider_key, backends: [{ key: "inventory_url", url: inventory_url }], intent_roles: intents.fleet(), tools: make_seller_tools(inventory_url, "") }
  let handler := runner.make_handler(db, cfg)
  let c := card.make(seller_id, str.concat("Seller (supply-side) agent ", seller_id), "0.3.0", base_url, [capability])
  srv.make_agent_def(c, [{ capability: capability, handle: handler }])
}


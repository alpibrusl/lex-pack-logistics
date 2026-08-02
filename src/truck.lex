# truck.lex — LLM-driven truck agent (lex-agent A2A + lex-llm).
#
# Exposes one inbound A2A capability ("handle") that accepts any
# operational message (dispatch, charging grant/deny, status query).
# Domain tools: lex-telemetry (SoC + live readings), lex-tms (orders,
# assignments, status), lex-logistics (CAW energy estimation).
# Platform tools (find_peers, send_message via A2A) are injected by
# runner.make_handler.

import "std.str" as str

import "std.int" as int

import "std.http" as http

import "std.map" as map

import "std.bytes" as bytes

import "lex-schema/json_value" as jv

import "lex-schema/schema" as sch

import "lex-schema/error" as e

import "lex-spec/capability" as cap

import "lex-llm/src/tool" as t

import "lex-agent/src/server" as srv

import "lex-agent/src/agent_card" as card

import "lex-soft/src/runner" as runner

import "./intents" as intents

import "lex-soft/src/platform/client" as pclient

fn tenant_hdr(req :: { method :: Str, url :: Str, headers :: Map[Str, Str], body :: Option[Bytes], timeout_ms :: Option[Int] }, tenant :: Str) -> { method :: Str, url :: Str, headers :: Map[Str, Str], body :: Option[Bytes], timeout_ms :: Option[Int] } {
  if str.is_empty(tenant) {
    req
  } else {
    http.with_header(req, "X-Tenant-Id", tenant)
  }
}

fn http_get_json(url :: Str, tenant :: Str) -> [net] jv.Json {
  let base := { method: "GET", url: url, headers: map.new(), body: None, timeout_ms: Some(30000) }
  match http.send(tenant_hdr(base, tenant)) {
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

fn truck_capability() -> cap.Capability {
  cap.inbound("handle", "Accept operational messages: dispatch, charging grant/deny, status requests.", { title: "TruckMessage", description: "Inbound message for a truck agent.", fields: [sch.required_str("text", [])] })
}

# Map a demo agent id (truck-07) to its seeded fleet VIN (VIN-EV-007).
# The telemetry/TMS services key vehicles by VIN, not by agent id.
fn vin_for(truck_id :: Str) -> Str {
  match str.strip_prefix(truck_id, "truck-") {
    None => truck_id,
    Some(num) => {
      let n := match str.to_int(num) {
        Some(x) => x,
        None => 0,
      }
      let padded := if n < 10 {
        str.concat("00", int.to_str(n))
      } else {
        if n < 100 {
          str.concat("0", int.to_str(n))
        } else {
          int.to_str(n)
        }
      }
      str.concat("VIN-EV-", padded)
    },
  }
}

fn make_tools(truck_id :: Str, tms_url :: Str, telemetry_url :: Str, logistics_url :: Str, tenant :: Str) -> List[t.Tool] {
  let vin := vin_for(truck_id)
  [t.define("get_telemetry", "Get live telemetry (SoC%, odometer, speed, status) for this vehicle.", { title: "GetTelemetry", description: "No parameters needed.", fields: [] }, fn (_args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    Ok(http_get_json(str.concat(telemetry_url, str.concat("/vehicles/", str.concat(vin, "/telemetry/latest"))), tenant))
  }), t.define("get_pending_orders", "Get orders pending assignment or currently assigned to this truck from TMS.", { title: "GetPendingOrders", description: "No parameters.", fields: [] }, fn (_args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    Ok(http_get_json(str.concat(tms_url, str.concat("/api/v1/orders?status=pending&assigned_to=", truck_id)), tenant))
  }), t.define("estimate_route_energy", "Estimate energy (kWh) needed for a route using the logistics CAW model.", { title: "EstimateRouteEnergy", description: "Route energy estimation.", fields: [sch.required_str("origin", []), sch.required_str("destination", [])] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    let origin := match jv.get_field(args, "origin") {
      Some(JStr(s)) => s,
      _ => "",
    }
    let dest := match jv.get_field(args, "destination") {
      Some(JStr(s)) => s,
      _ => "",
    }
    let body := jv.stringify(JObj([("vin", JStr(truck_id)), ("origin", JStr(origin)), ("destination", JStr(dest))]))
    match http.send(tenant_hdr(http.with_header({ method: "POST", url: str.concat(logistics_url, "/api/v1/caw/compute"), headers: map.new(), body: Some(bytes.from_str(body)), timeout_ms: Some(30000) }, "Content-Type", "application/json"), tenant)) {
      Err(_) => Ok(JObj([("error", JStr("unreachable"))])),
      Ok(resp) => match bytes.to_str(resp.body) {
        Err(_) => Ok(JObj([("error", JStr("decode error"))])),
        Ok(b) => match jv.parse(b) {
          Err(_) => Ok(JStr(b)),
          Ok(j) => Ok(j),
        },
      },
    }
  }), t.define("report_status", "Report truck status to TMS (available, on_route, charging, breakdown).", { title: "ReportStatus", description: "Status update.", fields: [sch.required_str("status", []), sch.optional(sch.required_str("notes", []))] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    let status := match jv.get_field(args, "status") {
      Some(JStr(s)) => s,
      _ => "available",
    }
    let notes := match jv.get_field(args, "notes") {
      Some(JStr(s)) => s,
      _ => "",
    }
    let body := jv.stringify(JObj([("truck_id", JStr(truck_id)), ("status", JStr(status)), ("notes", JStr(notes))]))
    match http.send(tenant_hdr(http.with_header({ method: "POST", url: str.concat(tms_url, "/api/v1/vehicles/status"), headers: map.new(), body: Some(bytes.from_str(body)), timeout_ms: Some(30000) }, "Content-Type", "application/json"), tenant)) {
      Err(_) => Ok(JObj([("error", JStr("unreachable"))])),
      Ok(_) => Ok(JObj([("ok", JBool(true))])),
    }
  })]
}

fn system_prompt(truck_id :: Str) -> Str {
  str.join(["You are autonomous truck agent ", truck_id, ". You make operational decisions for your vehicle.", " Respond directly and decisively to messages you receive:", " - For a load_assigned message: acknowledge and confirm you will pick up the load.", " - For a charging_grant: confirm you are proceeding to the assigned bay.", " - For a charging_deny: acknowledge and state your plan (find another depot, wait, etc.).", " - For a status query: report your current state, estimated SoC, and current task.", " - For a dispatch_request: state your availability and estimated SoC.", " Be concise, professional, and realistic. You are an electric truck with a battery.", " Your typical SoC range is 15-95%. Below 20% you need to charge before taking new loads."], "")
}

fn make_agent_def(db :: Db, truck_id :: Str, base_url :: Str, tms_url :: Str, telemetry_url :: Str, logistics_url :: Str, provider_name :: Str, provider_url :: Str, provider_key :: Str, model_name :: Str) -> srv.AgentDef {
  let capability := truck_capability()
  let cfg := { id: truck_id, kind: "truck", system_prompt: system_prompt(truck_id), model_name: model_name, provider_name: provider_name, provider_url: provider_url, provider_key: provider_key, backends: [{ key: "tms_url", url: tms_url }, { key: "telemetry_url", url: telemetry_url }, { key: "logistics_url", url: logistics_url }], intent_roles: intents.fleet(), tools: make_tools(truck_id, tms_url, telemetry_url, logistics_url, "") }
  let handler := runner.make_handler(db, cfg)
  let c := card.make(truck_id, str.concat("Autonomous truck agent ", truck_id), "0.3.0", base_url, [capability])
  srv.make_agent_def(c, [{ capability: capability, handle: handler }])
}

# Distributed variant — state and peers come from the platform API;
# outbound messages are routed through the platform's /v1/messages.
#
# Caller boot sequence (before serving requests):
#   1. outbox.init(local_db)
#   2. pclient.register(client, truck_id, "truck", name, "", capabilities)
#   3. conc.spawn(fn () -> ... { outbox.flush_loop(local_db, client.url, 500) })
fn make_agent_def_remote(client :: pclient.PlatformClient, local_db :: Db, truck_id :: Str, base_url :: Str, tms_url :: Str, telemetry_url :: Str, logistics_url :: Str, provider_name :: Str, provider_url :: Str, provider_key :: Str, model_name :: Str) -> srv.AgentDef {
  let capability := truck_capability()
  let cfg := { id: truck_id, kind: "truck", system_prompt: system_prompt(truck_id), model_name: model_name, provider_name: provider_name, provider_url: provider_url, provider_key: provider_key, backends: [{ key: "tms_url", url: tms_url }, { key: "telemetry_url", url: telemetry_url }, { key: "logistics_url", url: logistics_url }], intent_roles: intents.fleet(), tools: make_tools(truck_id, tms_url, telemetry_url, logistics_url, "") }
  let handler := runner.make_handler_remote(client, local_db, cfg)
  let c := card.make(truck_id, str.concat("Autonomous truck agent ", truck_id), "0.3.0", base_url, [capability])
  srv.make_agent_def(c, [{ capability: capability, handle: handler }])
}


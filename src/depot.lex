# depot.lex — LLM-driven charging depot agent (lex-agent A2A + lex-llm).
#
# Responds to charging requests from trucks. Checks charger availability via the
# charge service (lex-charge /v1/chargers) before granting or denying.
#
# Auth: the charge service requires a Bearer JWT. Agents carry a service token
# (CHARGE_TOKEN, scoped to the tenant that owns the chargers) so they can read
# availability and schedule charging — see make_tools(charge_url, token).

import "std.str" as str

import "std.map" as map

import "std.http" as http

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

# Authenticated GET against the charge service (Bearer service token).
# The charge service scopes chargers by X-Tenant-Id, so stamp the depot's
# tenant on every call — the CPO's agent sees the CPO's chargers (#90).
fn http_get_auth(url :: Str, token :: Str, tenant :: Str) -> [net] jv.Json {
  let base := { method: "GET", url: url, headers: map.new(), body: None, timeout_ms: Some(15000) }
  let req := http.with_header(http.with_header(base, "Authorization", str.concat("Bearer ", token)), "X-Tenant-Id", tenant)
  match http.send(req) {
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

fn depot_capability() -> cap.Capability {
  cap.inbound("handle", "Accept charging requests from trucks. Grant or deny based on capacity and grid load.", { title: "DepotMessage", description: "Inbound message for a depot agent.", fields: [sch.required_str("text", [])] })
}

fn make_tools(charge_url :: Str, token :: Str, tenant :: Str) -> List[t.Tool] {
  [t.define("get_available_chargers", "List this depot's chargers with their live status. 'Available' means a free bay ready to charge.", { title: "GetAvailableChargers", description: "No parameters.", fields: [] }, fn (_args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    Ok(http_get_auth(str.concat(charge_url, "/v1/chargers"), token, tenant))
  }), t.define("reserve_charger", "Reserve a charging bay for an incoming truck. Returns a session id on success.", { title: "ReserveCharger", description: "Charger reservation parameters.", fields: [sch.required_str("vin", []), sch.required_str("charger_id", []), sch.required_float("target_soc_pct", []), sch.required_float("available_minutes", [])] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    let base := { method: "POST", url: str.concat(charge_url, "/api/v1/charge-schedule"), headers: map.new(), body: Some(bytes.from_str(jv.stringify(args))), timeout_ms: Some(15000) }
    let req := http.with_header(http.with_header(http.with_header(base, "Authorization", str.concat("Bearer ", token)), "Content-Type", "application/json"), "X-Tenant-Id", tenant)
    match http.send(req) {
      Err(_) => Ok(JObj([("error", JStr("unreachable"))])),
      Ok(resp) => match bytes.to_str(resp.body) {
        Err(_) => Ok(JObj([("error", JStr("decode error"))])),
        Ok(b) => match jv.parse(b) {
          Err(_) => Ok(JStr(b)),
          Ok(j) => Ok(j),
        },
      },
    }
  })]
}

fn system_prompt(depot_id :: Str) -> Str {
  str.join(["You are autonomous charging depot agent ", depot_id, ". You manage a set of EV charging bays.", " When a truck requests charging, call get_available_chargers, then respond with a clear decision:", " - Grant: name an available charger/bay and an estimated session duration in minutes.", " - Deny only with a concrete reason (e.g., no Available bays, or the truck is not contracted).", " Reply in plain conversational English and state the topic ('charging_grant' or 'charging_deny'),", " the bay/charger id, and estimated minutes. Be concise and decisive. Prioritise contracted trucks."], "")
}

fn make_agent_def(db :: Db, depot_id :: Str, base_url :: Str, charge_url :: Str, charge_token :: Str, provider_name :: Str, provider_url :: Str, provider_key :: Str, model_name :: Str) -> srv.AgentDef {
  let capability := depot_capability()
  let cfg := { id: depot_id, kind: "depot", system_prompt: system_prompt(depot_id), model_name: model_name, provider_name: provider_name, provider_url: provider_url, provider_key: provider_key, backends: [{ key: "charge_url", url: charge_url }], intent_roles: intents.fleet(), tools: make_tools(charge_url, charge_token, "") }
  let handler := runner.make_handler(db, cfg)
  let c := card.make(depot_id, str.concat("Charging depot agent ", depot_id), "0.3.0", base_url, [capability])
  srv.make_agent_def(c, [{ capability: capability, handle: handler }])
}


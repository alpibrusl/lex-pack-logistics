# emsp.lex — the e-Mobility Service Provider persona.
#
# The commercial actor of the roaming loop: manages fleet accounts (which
# customer org owns which contract), issues and revokes the roaming tokens
# vehicles present at charge points, watches the CDRs the CPOs bill, and
# registers CPO connections. The lex-emsp service is its system of record;
# CPOs learn its tokens over OCPI (lex-csms token_sync).

import "std.str" as str

import "std.int" as int

import "std.list" as list

import "std.map" as map

import "std.http" as http

import "std.bytes" as bytes

import "lex-schema/json_value" as jv

import "lex-spec/capability" as cap

import "lex-schema/schema" as sch

import "lex-llm/src/tool" as t

import "lex-schema/error" as e

import "lex-agent/src/server" as srv

import "lex-agent/src/agent_card" as card

import "lex-soft/src/runner" as runner

import "./intents" as intents

fn req(method :: Str, url :: Str, body :: Option[Bytes]) -> { method :: Str, url :: Str, headers :: Map[Str, Str], body :: Option[Bytes], timeout_ms :: Option[Int] } {
  http.with_header({ method: method, url: url, headers: map.new(), body: body, timeout_ms: Some(30000) }, "Content-Type", "application/json")
}

fn get_json(url :: Str) -> [net] jv.Json {
  match http.send(req("GET", url, None)) {
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

fn post_json(url :: Str, body :: Str) -> [net] jv.Json {
  match http.send(req("POST", url, Some(bytes.from_str(body)))) {
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

fn delete_json(url :: Str) -> [net] jv.Json {
  match http.send(req("DELETE", url, None)) {
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

fn jarg(args :: jv.Json, k :: Str) -> Str {
  match jv.get_field(args, k) {
    Some(JStr(s)) => s,
    _ => "",
  }
}

fn make_tools(emsp_url :: Str) -> List[t.Tool] {
  [t.define("get_fleet_accounts", "List the fleet accounts (customers) this eMSP serves, with their customer org.", { title: "GetFleetAccounts", description: "All fleet accounts.", fields: [] }, fn (_args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    Ok(get_json(str.concat(emsp_url, "/api/v1/drivers")))
  }), t.define("get_account_tokens", "List the roaming tokens issued to one fleet account. Pass the account id from get_fleet_accounts.", { title: "GetAccountTokens", description: "Tokens of one account.", fields: [sch.required_str("account_id", [])] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    Ok(get_json(str.join([emsp_url, "/api/v1/drivers/", jarg(args, "account_id"), "/tokens"], "")))
  }), t.define("issue_token", "Issue a roaming token for a vehicle on a fleet account: the uid is what the vehicle presents at a charge point (usually its VIN). CPOs pick it up over OCPI within a minute.", { title: "IssueToken", description: "Issue a roaming token.", fields: [sch.required_str("account_id", []), sch.required_str("uid", []), sch.optional(sch.required_str("contract_id", []))] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    let body := jv.stringify(JObj([("uid", JStr(jarg(args, "uid"))), ("contract_id", JStr(jarg(args, "contract_id")))]))
    Ok(post_json(str.join([emsp_url, "/api/v1/drivers/", jarg(args, "account_id"), "/tokens"], ""), body))
  }), t.define("revoke_token", "Revoke a roaming token by uid. CPOs drop it from their whitelists on the next OCPI sync.", { title: "RevokeToken", description: "Revoke a token.", fields: [sch.required_str("uid", [])] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    Ok(delete_json(str.join([emsp_url, "/api/v1/tokens/", jarg(args, "uid")], "")))
  }), t.define("get_cdrs", "Charge detail records pulled from the CPOs — what each vehicle charged, where, and at what cost. Optionally filter to one customer org.", { title: "GetCdrs", description: "Billing records.", fields: [sch.optional(sch.required_str("org", []))] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    let org := jarg(args, "org")
    let url := if str.is_empty(org) {
      str.concat(emsp_url, "/api/v1/cdrs")
    } else {
      str.join([emsp_url, "/api/v1/cdrs?org=", org], "")
    }
    Ok(get_json(url))
  }), t.define("get_network", "The charging network as this eMSP knows it: every registered CPO's locations with coordinates.", { title: "GetNetwork", description: "Merged CPO locations.", fields: [] }, fn (_args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    Ok(get_json(str.concat(emsp_url, "/api/v1/locations")))
  }), t.define("register_cpo", "Register a CPO connection so its CDRs and locations flow in: party_id, country_code, its OCPI base url and access token.", { title: "RegisterCpo", description: "Add a CPO connection.", fields: [sch.required_str("party_id", []), sch.required_str("country_code", []), sch.required_str("ocpi_url", []), sch.required_str("token", [])] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    let body := jv.stringify(JObj([("party_id", JStr(jarg(args, "party_id"))), ("country_code", JStr(jarg(args, "country_code"))), ("ocpi_url", JStr(jarg(args, "ocpi_url"))), ("token", JStr(jarg(args, "token")))]))
    Ok(post_json(str.concat(emsp_url, "/api/v1/cpos"), body))
  })]
}

fn system_prompt(emsp_id :: Str) -> Str {
  str.join(["You are e-mobility service provider (eMSP) operator agent ", emsp_id, ". You run the commercial side of vehicle charging: fleet accounts, roaming tokens, and billing.", " Respond directly and decisively to messages you receive:", " - To onboard a fleet: find (or note the absence of) its account via get_fleet_accounts, then issue_token per vehicle (uid = the VIN the vehicle presents when it plugs in). Report that CPO whitelists pick tokens up within about a minute.", " - To offboard or block a vehicle: revoke_token by uid and say when it takes effect.", " - For billing questions: get_cdrs (filter by the customer's org when asked about one fleet) and summarise energy, cost and sites.", " - For network/coverage questions: get_network and describe the sites.", " - To connect a new charging operator: register_cpo with the OCPI details provided.", " Be professional and concise. Never invent tokens, accounts or charges — always check via tools first."], "")
}

fn emsp_capability() -> cap.Capability {
  cap.inbound("handle", "Accept eMSP requests: fleet onboarding, roaming token issue/revoke, CDR/billing queries, CPO registration.", { title: "EmspMessage", description: "Inbound message for an eMSP agent.", fields: [sch.required_str("text", [])] })
}

fn make_agent_def(db :: Db, emsp_id :: Str, base_url :: Str, emsp_url :: Str, provider_name :: Str, provider_url :: Str, provider_key :: Str, model_name :: Str) -> srv.AgentDef {
  let capability := emsp_capability()
  let cfg := { id: emsp_id, kind: "emsp", system_prompt: system_prompt(emsp_id), model_name: model_name, provider_name: provider_name, provider_url: provider_url, provider_key: provider_key, backends: [{ key: "emsp_url", url: emsp_url }], intent_roles: intents.fleet(), tools: make_tools(emsp_url) }
  let handler := runner.make_handler(db, cfg)
  let c := card.make(emsp_id, str.concat("e-Mobility Service Provider agent ", emsp_id), "0.3.0", base_url, [capability])
  srv.make_agent_def(c, [{ capability: capability, handle: handler }])
}


# tms.lex — LLM-driven transport management system agent (lex-agent A2A + lex-llm).
#
# Manages load assignments across the fleet. Receives route requests,
# queries lex-tms for pending orders, dispatches to contracted trucks
# first then freelance for overflow.

import "std.str" as str

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

fn tenant_hdr(req :: { method :: Str, url :: Str, headers :: Map[Str, Str], body :: Option[Bytes], timeout_ms :: Option[Int] }, tenant :: Str) -> { method :: Str, url :: Str, headers :: Map[Str, Str], body :: Option[Bytes], timeout_ms :: Option[Int] } {
  if str.is_empty(tenant) {
    req
  } else {
    http.with_header(req, "X-Tenant-Id", tenant)
  }
}

fn http_post_json(url :: Str, body :: Str, tenant :: Str) -> [net] jv.Json {
  let req0 := { method: "POST", url: url, headers: map.new(), body: Some(bytes.from_str(body)), timeout_ms: Some(60000) }
  let req1 := http.with_header(req0, "Content-Type", "application/json")
  let req := if str.is_empty(tenant) {
    req1
  } else {
    http.with_header(req1, "X-Tenant-Id", tenant)
  }
  match http.send(req) {
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

fn tms_capability() -> cap.Capability {
  cap.inbound("handle", "Accept fleet events: dispatch requests, load completions, truck status updates.", { title: "TmsMessage", description: "Inbound message for a TMS agent.", fields: [sch.required_str("text", [])] })
}

# Route geometry is DATA-DRIVEN: sites come from the TMS locations registry
# (tenant-scoped; each has a name + coordinates) and distances from the
# routing service when configured. With no ROUTING_URL, great-circle
# distances x a 1.3 road factor keep the tool honest (marked "estimated").
fn deg2rad(d :: Float) -> Float {
  d * 3.141592653589793 / 180.0
}

# great-circle km (mechanism, not map data)
fn haversine_km(lat1 :: Float, lon1 :: Float, lat2 :: Float, lon2 :: Float) -> Float {
  let dlat := deg2rad(lat2 - lat1)
  let dlon := deg2rad(lon2 - lon1)
  let a := math.sin(dlat / 2.0) * math.sin(dlat / 2.0) + math.cos(deg2rad(lat1)) * math.cos(deg2rad(lat2)) * math.sin(dlon / 2.0) * math.sin(dlon / 2.0)
  12742.0 * math.atan2(math.sqrt(a), math.sqrt(1.0 - a))
}

type Site = { name :: Str, lat :: Float, lon :: Float }

fn fetch_sites(tms_url :: Str, tenant :: Str) -> [net, io, proc] List[Site] {
  let j := http_get_json(str.concat(tms_url, "/api/v1/locations"), tenant)
  let rows := match j {
    JList(xs) => xs,
    _ => match jv.get_field(j, "items") {
      Some(JList(xs)) => xs,
      _ => [],
    },
  }
  list.map(rows, fn (r :: jv.Json) -> Site {
    { name: cstr(r, "name", ""), lat: cnum(r, "lat"), lon: cnum(r, "lon") }
  })
}

fn find_site(sites :: List[Site], name :: Str) -> Option[Site] {
  list.fold(sites, None, fn (acc :: Option[Site], site :: Site) -> Option[Site] {
    match acc {
      Some(x) => Some(x),
      None => if str.trim(site.name) == str.trim(name) {
        Some(site)
      } else {
        None
      },
    }
  })
}

# per-leg km via the routing service; None = unavailable (caller estimates)
fn routed_legs(routing_url :: Str, points :: List[Site]) -> [net, io, proc] Option[List[Float]] {
  if str.is_empty(routing_url) {
    None
  } else {
    let wps := jv.stringify(JObj([("waypoints", JList(list.map(points, fn (site :: Site) -> jv.Json {
      JObj([("lat", JFloat(site.lat)), ("lon", JFloat(site.lon))])
    }))), ("include_shape", JBool(false))]))
    let j := http_post_json(str.concat(routing_url, "/route"), wps, "")
    match jv.get_field(j, "legs") {
      Some(JList(legs)) => if list.len(legs) == list.len(points) - 1 {
        Some(list.map(legs, fn (l :: jv.Json) -> Float {
          cnum(l, "distance_km")
        }))
      } else {
        None
      },
      _ => None,
    }
  }
}

fn estimated_legs(points :: List[Site]) -> List[Float] {
  if list.is_empty(points) {
    []
  } else {
    list.map(list.enumerate(list.tail(points)), fn (p :: (Int, Site)) -> Float {
      match p {
        (i, site) => list.fold(list.enumerate(points), 0.0, fn (acc :: Float, q :: (Int, Site)) -> Float {
          match q {
            (k, prev) => if k == i {
              haversine_km(prev.lat, prev.lon, site.lat, site.lon) * 1.3
            } else {
              acc
            },
          }
        }),
      }
    })
  }
}

fn cnum(j :: jv.Json, k :: Str) -> Float {
  match jv.get_field(j, k) {
    Some(JFloat(f)) => f,
    Some(JInt(n)) => int.to_float(n),
    _ => 0.0,
  }
}

fn cint(j :: jv.Json, k :: Str, dflt :: Int) -> Int {
  match jv.get_field(j, k) {
    Some(JInt(n)) => n,
    _ => dflt,
  }
}

fn cstr(j :: jv.Json, k :: Str, dflt :: Str) -> Str {
  match jv.get_field(j, k) {
    Some(JStr(v)) => v,
    _ => dflt,
  }
}

fn corridor_via(c :: jv.Json) -> List[jv.Json] {
  match jv.get_field(c, "via") {
    Some(JList(xs)) => list.map(xs, fn (v :: jv.Json) -> jv.Json {
      JObj([("lat", JFloat(cnum(v, "lat"))), ("lon", JFloat(cnum(v, "lon"))), ("name", JStr(cstr(v, "name", "via"))), ("dist_km", JFloat(cnum(v, "dist_km")))])
    }),
    _ => [],
  }
}

fn make_tools(tms_url :: Str, tenant :: Str, routing_url :: Str, self_url :: Str) -> List[t.Tool] {
  [t.define("get_pending_orders", "Get orders waiting to be assigned to a truck.", { title: "GetPendingOrders", description: "No parameters.", fields: [] }, fn (_args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    Ok(http_get_json(str.concat(tms_url, "/api/v1/orders?status=pending"), tenant))
  }), t.define("get_order_details", "Get full details for a specific order: origin, destination, weight, deadlines.", { title: "GetOrderDetails", description: "Order lookup.", fields: [sch.required_str("order_id", [])] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    let id := match jv.get_field(args, "order_id") {
      Some(JStr(s)) => s,
      _ => "",
    }
    Ok(http_get_json(str.concat(tms_url, str.concat("/api/v1/orders/", id)), tenant))
  }), t.define("list_routes", "List the planned routes in this TMS with their ids, origin, destination and distance. Use to pick a route_id for assign_order.", { title: "ListRoutes", description: "No parameters.", fields: [] }, fn (_args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    Ok(http_get_json(str.concat(tms_url, "/api/v1/routes"), tenant))
  }), t.define("list_drivers", "List drivers with their ids and availability. Use to pick a driver_id for assign_order.", { title: "ListDrivers", description: "No parameters.", fields: [] }, fn (_args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    Ok(http_get_json(str.concat(tms_url, "/api/v1/drivers"), tenant))
  }), t.define("assign_order", "Assign an order to a truck on a route. driver_id comes from list_drivers for crewed tractors; OMIT it for an autonomous truck (autonomy != none in get_fleet_status) - a driverless assignment is valid and exceptions go to the human supervisor via escalate.", { title: "AssignOrder", description: "Order assignment (driver optional: autonomous trucks).", fields: [sch.required_str("order_id", []), sch.required_str("truck_id", []), sch.required_str("route_id", []), sch.optional(sch.required_str("driver_id", []))] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    let vin := match jv.get_field(args, "truck_id") {
      Some(JStr(s)) => s,
      _ => "",
    }
    let order_id := match jv.get_field(args, "order_id") {
      Some(JStr(s)) => s,
      _ => "",
    }
    let route_id := match jv.get_field(args, "route_id") {
      Some(JStr(s)) => s,
      _ => "",
    }
    let driver_id := match jv.get_field(args, "driver_id") {
      Some(JStr(s)) => s,
      _ => "",
    }
    let body := jv.stringify(JObj([("order_id", JStr(order_id)), ("route_id", JStr(route_id)), ("vin", JStr(vin)), ("driver_id", JStr(driver_id))]))
    match http.send(tenant_hdr(http.with_header({ method: "POST", url: str.concat(tms_url, "/api/v1/assignments"), headers: map.new(), body: Some(bytes.from_str(body)), timeout_ms: Some(30000) }, "Content-Type", "application/json"), tenant)) {
      Err(_) => Ok(JObj([("error", JStr("unreachable"))])),
      Ok(resp) => match bytes.to_str(resp.body) {
        Err(_) => Ok(JObj([("error", JStr("decode error"))])),
        Ok(b) => match jv.parse(b) {
          Err(_) => Ok(JStr(b)),
          Ok(j) => Ok(j),
        },
      },
    }
  }), t.define("plan_multistop_route", "Consolidate pending transport orders into ONE multi-stop route: pickup at origin_site (a location name from the locations registry), then one delivery stop per order at each order's consignee site. Distances come from the road network. Pass a route name, the order ids joined by commas, and origin_site. Returns route_id and the stop list - then assign_order EACH order to the SAME truck and driver with that route_id.", { title: "PlanMultistopRoute", description: "Multi-stop route consolidation over registered sites.", fields: [sch.required_str("name", []), sch.required_str("order_ids", []), sch.required_str("origin_site", [])] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    let route_name := match jv.get_field(args, "name") {
      Some(JStr(s)) => s,
      _ => "RUN",
    }
    let ids_raw := match jv.get_field(args, "order_ids") {
      Some(JStr(s)) => s,
      _ => "",
    }
    let ids := list.filter(list.map(str.split(ids_raw, ","), fn (x :: Str) -> Str {
      str.trim(x)
    }), fn (x :: Str) -> Bool {
      not str.is_empty(x)
    })
    let origin_name := match jv.get_field(args, "origin_site") {
      Some(JStr(v)) => v,
      _ => "",
    }
    if str.is_empty(origin_name) {
      Ok(JObj([("error", JStr("origin_site is required: the pickup location's name as registered in the locations registry"))]))
    } else {
      let sites := fetch_sites(tms_url, tenant)
      let stop_names := list.map(ids, fn (oid :: Str) -> [net, io, proc] Str {
        let o := http_get_json(str.concat(tms_url, str.concat("/api/v1/orders/", oid)), tenant)
        match jv.get_field(o, "consignee_name") {
          Some(JStr(v)) => v,
          _ => oid,
        }
      })
      let wanted := list.concat([origin_name], stop_names)
      let missing := list.filter(wanted, fn (n :: Str) -> Bool {
        match find_site(sites, n) {
          Some(_) => false,
          None => true,
        }
      })
      if not list.is_empty(missing) {
        Ok(JObj([("error", JStr(str.concat("unknown site(s) — register them in the locations registry first: ", str.join(missing, ", "))))]))
      } else {
        let points := list.map(wanted, fn (n :: Str) -> Site {
          match find_site(sites, n) {
            Some(site) => site,
            None => { name: n, lat: 0.0, lon: 0.0 },
          }
        })
        let legs0 := routed_legs(routing_url, points)
        let estimated := match legs0 {
          Some(_) => false,
          None => true,
        }
        let legs := match legs0 {
          Some(ls) => ls,
          None => estimated_legs(points),
        }
        let total := list.fold(legs, 0.0, fn (acc :: Float, d :: Float) -> Float {
          acc + d
        })
        let stops := list.map(list.enumerate(stop_names), fn (p :: (Int, Str)) -> jv.Json {
          match p {
            (i, who) => {
              let cum := list.fold(list.enumerate(legs), 0.0, fn (acc :: Float, q :: (Int, Float)) -> Float {
                match q {
                  (k, d) => if k <= i {
                    acc + d
                  } else {
                    acc
                  },
                }
              })
              let site := match find_site(sites, who) {
                Some(x) => x,
                None => { name: who, lat: 0.0, lon: 0.0 },
              }
              JObj([("lat", JFloat(site.lat)), ("lon", JFloat(site.lon)), ("name", JStr(who)), ("dist_km", JFloat(cum))])
            },
          }
        })
        let origin := match find_site(sites, origin_name) {
          Some(x) => x,
          None => { name: origin_name, lat: 0.0, lon: 0.0 },
        }
        let waypoints := list.concat([JObj([("lat", JFloat(origin.lat)), ("lon", JFloat(origin.lon)), ("name", JStr(str.concat(origin_name, " (pickup)"))), ("dist_km", JFloat(0.0))])], stops)
        let n := list.len(ids)
        let minutes := if estimated {
          total / 65.0 * 60.0
        } else {
          total / 65.0 * 60.0
        }
        let last_stop := list.fold(stop_names, "", fn (_acc :: Str, x :: Str) -> Str {
          x
        })
        let body := jv.stringify(JObj([("name", JStr(route_name)), ("origin", JStr(origin_name)), ("destination", JStr(str.concat(last_stop, " (multi-stop)"))), ("waypoints_json", JStr(jv.stringify(JList(waypoints)))), ("distance_km", JFloat(total)), ("estimated_duration_min", JInt(float.to_int(minutes))), ("road_type", JStr(if estimated {
          "estimated"
        } else {
          "highway"
        })), ("avg_speed_kmh", JFloat(65.0))]))
        let req0 := { method: "POST", url: str.concat(tms_url, "/api/v1/routes"), headers: map.new(), body: Some(bytes.from_str(body)), timeout_ms: Some(30000) }
        match http.send(tenant_hdr(http.with_header(req0, "Content-Type", "application/json"), tenant)) {
          Err(_) => Ok(JObj([("error", JStr("unreachable"))])),
          Ok(resp) => match bytes.to_str(resp.body) {
            Err(_) => Ok(JObj([("error", JStr("decode error"))])),
            Ok(b) => match jv.parse(b) {
              Err(_) => Ok(JStr(b)),
              Ok(j) => {
                let rid := match jv.get_field(j, "id") {
                  Some(JStr(s)) => s,
                  _ => "",
                }
                Ok(JObj([("route_id", JStr(rid)), ("stop_count", JInt(n)), ("stops", JList(list.map(stops, fn (w :: jv.Json) -> jv.Json {
                  match jv.get_field(w, "name") {
                    Some(nm) => nm,
                    None => JStr(""),
                  }
                })))]))
              },
            },
          },
        }
      }
    }
  }), t.define("plan_relay", "Plan a two-leg relay for a corridor: leg 1 tractor_a hauls the trailer origin_site -> swap_site, atomic trailer swap in a BOOKED slot, leg 2 tractor_b hauls swap_site -> dest_site. Books the swap slot (fails with the reason if the window is full - rebook_swap_slot another window or escalate), routes both legs over the road network, and computes the charging budget so tractor_b leaves the swap fully able to finish leg 2 (the swap stop is the charging stop). Legs without a driver id are autonomous legs. Returns the plan with both legs, the slot, and the charge target.", { title: "PlanRelay", description: "Heuristic two-leg relay plan with slot booking + charge budget.", fields: [sch.required_str("name", []), sch.required_str("origin_site", []), sch.required_str("swap_site", []), sch.required_str("dest_site", []), sch.required_str("trailer_ref", []), sch.required_str("tractor_a", []), sch.required_str("tractor_b", []), sch.required_str("swap_window", []), sch.optional(sch.required_str("driver_a", [])), sch.optional(sch.required_str("driver_b", []))] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    let g := fn (k :: Str) -> Str {
      match jv.get_field(args, k) {
        Some(JStr(v)) => v,
        _ => "",
      }
    }
    let plan_ref := g("name")
    let sites := fetch_sites(tms_url, tenant)
    let wanted := [g("origin_site"), g("swap_site"), g("dest_site")]
    let missing := list.filter(wanted, fn (n :: Str) -> Bool {
      match find_site(sites, n) {
        Some(_) => false,
        None => true,
      }
    })
    if not list.is_empty(missing) {
      Ok(JObj([("error", JStr(str.concat("unknown site(s) - register them in the locations registry first: ", str.join(missing, ", "))))]))
    } else {
      let points := list.map(wanted, fn (n :: Str) -> Site {
        match find_site(sites, n) {
          Some(x) => x,
          None => { name: n, lat: 0.0, lon: 0.0 },
        }
      })
      let booked := http_post_json(str.concat(tms_url, "/api/v1/swap-slots/book"), jv.stringify(JObj([("site", JStr(g("swap_site"))), ("window_start", JStr(g("swap_window")))])), tenant)
      match jv.get_field(booked, "error") {
        Some(JStr(msg)) => Ok(JObj([("error", JStr(msg)), ("hint", JStr("pick another window with rebook_swap_slot, or escalate if no window fits"))])),
        _ => {
          let routed := routed_legs(routing_url, points)
          let dists := match routed {
            Some(ds) => ds,
            None => estimated_legs(points),
          }
          let road := match routed {
            Some(_) => "highway",
            None => "estimated",
          }
          let dist_a := match list.head(dists) {
            Some(x) => x,
            None => 0.0,
          }
          let dist_b := match list.head(list.tail(dists)) {
            Some(x) => x,
            None => 0.0,
          }
          let kwh_per_km := match jv.get_field(args, "kwh_per_km") {
            Some(JFloat(v)) => v,
            Some(JInt(n)) => int.to_float(n),
            _ => 1.2,
          }
          let charge_kwh := dist_b * kwh_per_km * 1.15
          let leg1 := http_post_json(str.concat(tms_url, "/api/v1/relay-legs"), jv.stringify(JObj([("plan_ref", JStr(plan_ref)), ("seq", JInt(1)), ("origin_site", JStr(g("origin_site"))), ("dest_site", JStr(g("swap_site"))), ("trailer_ref", JStr(g("trailer_ref"))), ("vin", JStr(g("tractor_a"))), ("driver_id", JStr(g("driver_a"))), ("distance_km", JFloat(dist_a)), ("est_duration_min", JFloat(dist_a / 65.0 * 60.0)), ("charge_kwh", JFloat(0.0)), ("depart_at", JStr(""))])), tenant)
          let leg2 := http_post_json(str.concat(tms_url, "/api/v1/relay-legs"), jv.stringify(JObj([("plan_ref", JStr(plan_ref)), ("seq", JInt(2)), ("origin_site", JStr(g("swap_site"))), ("dest_site", JStr(g("dest_site"))), ("trailer_ref", JStr(g("trailer_ref"))), ("vin", JStr(g("tractor_b"))), ("driver_id", JStr(g("driver_b"))), ("distance_km", JFloat(dist_b)), ("est_duration_min", JFloat(dist_b / 65.0 * 60.0)), ("charge_kwh", JFloat(charge_kwh)), ("depart_at", JStr(g("swap_window")))])), tenant)
          Ok(JObj([("plan_ref", JStr(plan_ref)), ("road_type", JStr(road)), ("swap_slot", booked), ("legs", JList([leg1, leg2])), ("charging", JObj([("at", JStr(g("swap_site"))), ("tractor", JStr(g("tractor_b"))), ("target_kwh", JFloat(charge_kwh)), ("note", JStr("charge during the swap turnaround so leg 2 departs on schedule"))]))]))
        },
      }
    }
  }), t.define("plan_shuttle", "Roster ONE relay shuttle: the same tractor and driver run site_a -> site_b and BACK in one shift, so the driver ends the day at home. Checks shift legality (2 x leg time <= 9 h driving) and, when a driver is given, that the driver's home_depot anchors the shuttle at site_a — never roster someone onto a leg that strands them. Pass outbound_order_id and (if a counter-load exists) return_order_id; without a return order the return leg is recorded empty_return=true — fill it from the spot market. Records two paired legs under name.", { title: "PlanShuttle", description: "Paired out-and-back relay legs: the driver goes home.", fields: [sch.required_str("name", []), sch.required_str("site_a", []), sch.required_str("site_b", []), sch.required_str("tractor", []), sch.optional(sch.required_str("driver_id", [])), sch.optional(sch.required_str("outbound_order_id", [])), sch.optional(sch.required_str("return_order_id", [])), sch.optional(sch.required_str("depart_at", []))] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    let g := fn (k :: Str) -> Str {
      match jv.get_field(args, k) {
        Some(JStr(v)) => v,
        _ => "",
      }
    }
    let name := g("name")
    let sites := fetch_sites(tms_url, tenant)
    let missing := list.filter([g("site_a"), g("site_b")], fn (n :: Str) -> Bool {
      match find_site(sites, n) {
        Some(_) => false,
        None => true,
      }
    })
    if not list.is_empty(missing) {
      Ok(JObj([("error", JStr(str.concat("unknown site(s) — register them in the locations registry first: ", str.join(missing, ", "))))]))
    } else {
      let home_problem := if str.is_empty(g("driver_id")) {
        ""
      } else {
        let drv := http_get_json(str.concat(tms_url, str.concat("/api/v1/drivers/", g("driver_id"))), tenant)
        let home := match jv.get_field(drv, "home_depot") {
          Some(JStr(h)) => h,
          _ => "",
        }
        if str.is_empty(home) or str.trim(home) == str.trim(g("site_a")) {
          ""
        } else {
          str.concat("driver's home_depot is ", str.concat(home, str.concat(" but the shuttle is anchored at ", str.concat(g("site_a"), " — pick a driver based there, or anchor the shuttle at their home"))))
        }
      }
      if not str.is_empty(home_problem) {
        Ok(JObj([("error", JStr(home_problem))]))
      } else {
        let points := list.map([g("site_a"), g("site_b")], fn (n :: Str) -> Site {
          match find_site(sites, n) {
            Some(x) => x,
            None => { name: n, lat: 0.0, lon: 0.0 },
          }
        })
        let dists := match routed_legs(routing_url, points) {
          Some(ds) => ds,
          None => estimated_legs(points),
        }
        let dist := match list.head(dists) {
          Some(x) => x,
          None => 0.0,
        }
        let leg_h := dist / 65.0
        if leg_h * 2.0 > 9.0 {
          Ok(JObj([("error", JStr("shuttle is not shift-legal: two crossings exceed the 9 h daily driving cap — split the corridor with another swap point")), ("leg_hours", JFloat(leg_h))]))
        } else {
          let kwh_per_km := match jv.get_field(args, "kwh_per_km") {
            Some(JFloat(v)) => v,
            Some(JInt(n)) => int.to_float(n),
            _ => 1.2,
          }
          let charge_kwh := dist * kwh_per_km * 1.15
          let empty := str.is_empty(g("return_order_id"))
          let leg_out := http_post_json(str.concat(tms_url, "/api/v1/relay-legs"), jv.stringify(JObj([("plan_ref", JStr(name)), ("seq", JInt(1)), ("origin_site", JStr(g("site_a"))), ("dest_site", JStr(g("site_b"))), ("vin", JStr(g("tractor"))), ("driver_id", JStr(g("driver_id"))), ("distance_km", JFloat(dist)), ("est_duration_min", JFloat(leg_h * 60.0)), ("charge_kwh", JFloat(0.0)), ("depart_at", JStr(g("depart_at"))), ("pair_ref", JStr(name)), ("direction", JStr("out")), ("empty_return", JBool(false)), ("order_id", JStr(g("outbound_order_id")))])), tenant)
          let leg_back := http_post_json(str.concat(tms_url, "/api/v1/relay-legs"), jv.stringify(JObj([("plan_ref", JStr(name)), ("seq", JInt(2)), ("origin_site", JStr(g("site_b"))), ("dest_site", JStr(g("site_a"))), ("vin", JStr(g("tractor"))), ("driver_id", JStr(g("driver_id"))), ("distance_km", JFloat(dist)), ("est_duration_min", JFloat(leg_h * 60.0)), ("charge_kwh", JFloat(charge_kwh)), ("depart_at", JStr("")), ("pair_ref", JStr(name)), ("direction", JStr("return")), ("empty_return", JBool(empty)), ("order_id", JStr(g("return_order_id")))])), tenant)
          Ok(JObj([("pair_ref", JStr(name)), ("driver_ends_at", JStr(g("site_a"))), ("shift_driving_h", JFloat(leg_h * 2.0)), ("empty_return", JBool(empty)), ("charge_before_return_kwh", JFloat(charge_kwh)), ("legs", JList([leg_out, leg_back]))]))
        }
      }
    }
  }), t.define("rebook_swap_slot", "Disruption re-planning: move a swap booking to a different window at the same site. Releases the old window (best effort) and atomically books the new one; fails with the reason if the new window is full.", { title: "RebookSwapSlot", description: "Release one swap window, book another.", fields: [sch.required_str("site", []), sch.required_str("from_window", []), sch.required_str("to_window", [])] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    let g := fn (k :: Str) -> Str {
      match jv.get_field(args, k) {
        Some(JStr(v)) => v,
        _ => "",
      }
    }
    let __rel := http_post_json(str.concat(tms_url, "/api/v1/swap-slots/release"), jv.stringify(JObj([("site", JStr(g("site"))), ("window_start", JStr(g("from_window")))])), tenant)
    Ok(http_post_json(str.concat(tms_url, "/api/v1/swap-slots/book"), jv.stringify(JObj([("site", JStr(g("site"))), ("window_start", JStr(g("to_window")))])), tenant))
  }), t.define("get_relay_plan", "Fetch a relay plan's legs (and current swap-slot occupancy) by plan name. Empty name lists every leg.", { title: "GetRelayPlan", description: "Relay legs + swap slot occupancy.", fields: [sch.optional(sch.required_str("name", []))] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    let name := match jv.get_field(args, "name") {
      Some(JStr(v)) => v,
      _ => "",
    }
    let legs := http_get_json(str.concat(tms_url, str.concat("/api/v1/relay-legs?plan_ref=", name)), tenant)
    let slots := http_get_json(str.concat(tms_url, "/api/v1/swap-slots"), tenant)
    Ok(JObj([("legs", legs), ("swap_slots", slots)]))
  }), t.define("get_co2_report", "Auditable CO2 for a delivered/assigned order: derived from the assigned route distance, the vehicle's declared consumption and the tenant's registered grid intensity factor for the given country - every input is returned with the figure. Requires a grid factor registered for that country.", { title: "GetCo2Report", description: "Per-order CO2 with the inputs that produced it.", fields: [sch.required_str("order_id", []), sch.required_str("country", [])] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    let oid := match jv.get_field(args, "order_id") {
      Some(JStr(v)) => v,
      _ => "",
    }
    let country := match jv.get_field(args, "country") {
      Some(JStr(v)) => v,
      _ => "",
    }
    Ok(http_get_json(str.concat(tms_url, str.concat("/api/v1/orders/", str.concat(oid, str.concat("/co2?country=", country)))), tenant))
  }), t.define("list_trailers", "List the fleet's trailers with their current coupled tractor (empty coupled_vin = parked). Trailers are the cargo unit in relay operations; use swap_trailer to move one between tractors at a registered site.", { title: "ListTrailers", description: "Trailer registry with live couplings.", fields: [] }, fn (_args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    Ok(http_get_json(str.concat(tms_url, "/api/v1/trailers"), tenant))
  }), t.define("swap_trailer", "Relay swap: atomically decouple a trailer from its current tractor and couple it to another at a registered site (locations registry, e.g. a swap_point). Pass the trailer plate, the receiving tractor's VIN, and the site name. Returns from_vin/to_vin so you can confirm the handoff.", { title: "SwapTrailer", description: "Atomic trailer handoff between tractors at a site.", fields: [sch.required_str("plate", []), sch.required_str("to_vin", []), sch.required_str("site", [])] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    let plate := match jv.get_field(args, "plate") {
      Some(JStr(v)) => v,
      _ => "",
    }
    let to_vin := match jv.get_field(args, "to_vin") {
      Some(JStr(v)) => v,
      _ => "",
    }
    let site := match jv.get_field(args, "site") {
      Some(JStr(v)) => v,
      _ => "",
    }
    let body := jv.stringify(JObj([("plate", JStr(plate)), ("to_vin", JStr(to_vin)), ("site", JStr(site))]))
    Ok(http_post_json(str.concat(tms_url, "/api/v1/swaps"), body, tenant))
  }), t.define("record_handoff", "Record a signed custody handoff for a trailer AFTER a physical swap: the evidence-gated record (seal state, optional photo hashes) that transfers liability from the releasing tractor to the receiving one. Chained per trailer and Ed25519-signed by this deployment; the receiving party countersigns. Pass the trailer plate as trailer_ref plus from_vin, to_vin, site, seal_state (e.g. intact/broken/resealed).", { title: "RecordHandoff", description: "Signed, hash-chained trailer custody handoff.", fields: [sch.required_str("trailer_ref", []), sch.required_str("from_vin", []), sch.required_str("to_vin", []), sch.required_str("site", []), sch.optional(sch.required_str("seal_state", [])), sch.optional(sch.required_str("to_agent", []))] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    let g := fn (k :: Str) -> Str {
      match jv.get_field(args, k) {
        Some(JStr(v)) => v,
        _ => "",
      }
    }
    let body := jv.stringify(JObj([("trailer_ref", JStr(g("trailer_ref"))), ("from_vin", JStr(g("from_vin"))), ("to_vin", JStr(g("to_vin"))), ("site", JStr(g("site"))), ("seal_state", JStr(g("seal_state"))), ("to_agent", JStr(g("to_agent"))), ("from_agent", JStr(tenant))]))
    Ok(http_post_json(str.concat(self_url, "/custody/handoffs"), body, ""))
  }), t.define("get_trailer_journey", "The trailer's full custody journey: every signed handoff in its hash chain, re-verified (chain intact + signature validity) on read. Pass the trailer plate as trailer_ref.", { title: "GetTrailerJourney", description: "Chained, re-verified custody journey for a trailer.", fields: [sch.required_str("trailer_ref", [])] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    let ref := match jv.get_field(args, "trailer_ref") {
      Some(JStr(v)) => v,
      _ => "",
    }
    Ok(http_get_json(str.concat(self_url, str.concat("/custody/trailers/", str.concat(ref, "/journey"))), ""))
  }), t.define("create_transport_order", "Create a transport order in this carrier's TMS from a shipper/seller request (cross-company tender). Use a unique order_number.", { title: "CreateTransportOrder", description: "Transport order intake.", fields: [sch.required_str("order_number", []), sch.required_str("shipper_name", []), sch.required_str("consignee_name", []), sch.required_str("pickup_address", []), sch.required_str("delivery_address", []), sch.required_str("requested_pickup_date", []), sch.required_float("weight_kg", []), sch.optional(sch.required_str("cargo_description", []))] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    let body := jv.stringify(args)
    let req0 := { method: "POST", url: str.concat(tms_url, "/api/v1/orders"), headers: map.new(), body: Some(bytes.from_str(body)), timeout_ms: Some(30000) }
    match http.send(tenant_hdr(http.with_header(req0, "Content-Type", "application/json"), tenant)) {
      Err(_) => Ok(JObj([("error", JStr("unreachable"))])),
      Ok(resp) => match bytes.to_str(resp.body) {
        Err(_) => Ok(JObj([("error", JStr("decode error"))])),
        Ok(b) => match jv.parse(b) {
          Err(_) => Ok(JStr(b)),
          Ok(j) => Ok(j),
        },
      },
    }
  }), t.define("get_fleet_status", "Get status summary for all vehicles in the fleet.", { title: "GetFleetStatus", description: "No parameters.", fields: [] }, fn (_args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    Ok(http_get_json(str.concat(tms_url, "/api/v1/vehicles"), tenant))
  })]
}

fn system_prompt(tms_id :: Str) -> Str {
  str.join(["You are transport management system agent ", tms_id, ". You coordinate load assignments across a fleet of EV trucks.", " Respond directly and decisively to messages you receive:", " - For a transport request/tender from a shipper or seller (another company): create_transport_order with the given details and reply that the order is QUEUED for the next dispatch run. Do NOT assign it now — assignment happens in the periodic dispatch review so orders can be consolidated.", " - For a dispatch review (periodic): call get_pending_orders. If TWO or more pending orders share a corridor (same pickup city), consolidate them with plan_multistop_route (one route, one delivery stop per order), then assign_order EVERY one of them to the SAME available truck and driver using the returned route_id. If exactly ONE order is pending, assign it alone on a matching route from list_routes. Reply with what you dispatched.", " - For a dispatch_request: acknowledge the load and indicate which truck you will assign it to.", " - For a load_completed: confirm receipt and note the truck is now available.", " - For a capacity_report from a depot: acknowledge and update your routing decisions.", " - For a relay/trailer swap request: check list_trailers, then swap_trailer (plate, receiving tractor VIN, registered site), then record_handoff with the same pair and the seal state — the signed custody record IS the liability transfer. Use get_trailer_journey to answer custody questions.", " - For a relay corridor plan: plan_relay (origin/swap/dest sites from the locations registry, a booked swap_window, the trailer and both tractors), then at execution time swap_trailer + record_handoff at the swap site. If the slot is full, rebook_swap_slot or escalate.", " - To roster the tractors that serve a relay leg: plan_shuttle — the SAME tractor and driver go out and back in one shift, the driver ends at home. Pair a return order whenever one exists; an empty_return is a cost, flag it and look for spot backhaul.", " - Autonomous trucks (autonomy != none in get_fleet_status) are assigned WITHOUT a driver; any exception on a driverless leg (charging failure, route deviation, custody dispute) goes to the human supervisor via escalate - never invent a driver for it.", " - For an emissions/CO2 question about an order: get_co2_report with the corridor country and report the figure WITH its inputs.", " - For general queries: explain your current dispatch state and available fleet capacity.", " Be professional and concise. Use get_fleet_status and list_drivers for your ACTUAL fleet — never assume trucks or depots that the tools don't report."], "")
}

fn make_agent_def(db :: Db, tms_id :: Str, base_url :: Str, tms_url :: Str, provider_name :: Str, provider_url :: Str, provider_key :: Str, model_name :: Str, routing_url :: Str, self_url :: Str) -> srv.AgentDef {
  let capability := tms_capability()
  let cfg := { id: tms_id, kind: "tms", system_prompt: system_prompt(tms_id), model_name: model_name, provider_name: provider_name, provider_url: provider_url, provider_key: provider_key, backends: [{ key: "tms_url", url: tms_url }], intent_roles: intents.fleet(), tools: make_tools(tms_url, "", routing_url, self_url) }
  let handler := runner.make_handler(db, cfg)
  let c := card.make(tms_id, str.concat("Transport management system agent ", tms_id), "0.3.0", base_url, [capability])
  srv.make_agent_def(c, [{ capability: capability, handle: handler }])
}


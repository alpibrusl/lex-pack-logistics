# seed.lex — populate the registry and relationship graph for the demo.
#
# 20 trucks, 4 depots, 2 TMS providers with realistic relationship topology:
#   - Trucks 01-10  contracted to TMS-primary,   freelance to TMS-secondary
#   - Trucks 11-20  contracted to TMS-secondary, freelance to TMS-primary
#   - Trucks 01-05  preferred_charger at depot-north  + depot-west
#   - Trucks 06-10  preferred_charger at depot-south  + depot-west
#   - Trucks 11-15  preferred_charger at depot-east   + depot-north
#   - Trucks 16-20  preferred_charger at depot-south  + depot-east
#   - All depots report to both TMS providers

import "std.sql" as sql

import "std.str" as str

import "std.int" as int

import "std.list" as list

import "lex-soft/src/registry" as reg

import "lex-soft/src/relationships" as rel

fn truck_id(n :: Int) -> Str {
  let ns := int.to_str(n)
  if n < 10 {
    str.concat("truck-0", ns)
  } else {
    str.concat("truck-", ns)
  }
}

fn base_url(port :: Int) -> Str {
  str.concat("http://localhost:", int.to_str(port))
}

# The real A2A inbox for a locally-hosted agent: every agent is mounted on the
# one server (port 8100) at /agents/<id>/ — NOT on a per-agent port. Registering
# the actual endpoint is what makes internal agent-to-agent send_message work.
fn a2a_inbox(agent_id :: Str) -> Str {
  str.concat("http://localhost:8100/agents/", str.concat(agent_id, "/"))
}

fn fold_ok(xs :: List[Int], f :: (Int) -> [sql, fs_write, time] Result[Unit, Str]) -> [sql, fs_write, time] Result[Unit, Str] {
  list.fold(xs, Ok(()), fn (acc :: Result[Unit, Str], n :: Int) -> [sql, fs_write, time] Result[Unit, Str] {
    match acc {
      Err(e) => Err(e),
      Ok(_) => f(n),
    }
  })
}

fn fold_ok_str(xs :: List[Str], f :: (Str) -> [sql, fs_write, crypto, random, time] Result[Unit, Str]) -> [sql, fs_write, crypto, random, time] Result[Unit, Str] {
  list.fold(xs, Ok(()), fn (acc :: Result[Unit, Str], s :: Str) -> [sql, fs_write, crypto, random, time] Result[Unit, Str] {
    match acc {
      Err(e) => Err(e),
      Ok(_) => f(s),
    }
  })
}

fn fold_ok_n_crypto(xs :: List[Int], f :: (Int) -> [sql, fs_write, crypto, random, time] Result[Unit, Str]) -> [sql, fs_write, crypto, random, time] Result[Unit, Str] {
  list.fold(xs, Ok(()), fn (acc :: Result[Unit, Str], n :: Int) -> [sql, fs_write, crypto, random, time] Result[Unit, Str] {
    match acc {
      Err(e) => Err(e),
      Ok(_) => f(n),
    }
  })
}

fn register_agents(db :: Db) -> [sql, fs_write, time] Result[Unit, Str] {
  match reg.register_in(db, "acme-logistics", "depot-north", "depot", "Depot North", a2a_inbox("depot-north"), ["charging"]) {
    Err(e) => Err(e),
    Ok(_) => match reg.register_in(db, "acme-logistics", "depot-south", "depot", "Depot South", a2a_inbox("depot-south"), ["charging"]) {
      Err(e) => Err(e),
      Ok(_) => match reg.register_in(db, "acme-logistics", "depot-east", "depot", "Depot East", a2a_inbox("depot-east"), ["charging"]) {
        Err(e) => Err(e),
        Ok(_) => match reg.register_in(db, "acme-logistics", "depot-west", "depot", "Depot West", a2a_inbox("depot-west"), ["charging"]) {
          Err(e) => Err(e),
          Ok(_) => match reg.register_in(db, "acme-logistics", "tms-primary", "tms", "TMS Primary", a2a_inbox("tms-primary"), ["dispatch"]) {
            Err(e) => Err(e),
            Ok(_) => match reg.register_in(db, "acme-logistics", "tms-secondary", "tms", "TMS Secondary", a2a_inbox("tms-secondary"), ["dispatch"]) {
              Err(e) => Err(e),
              Ok(_) => match reg.register_in(db, "acme-logistics", "shipper-01", "shipper", "Shipper 01", a2a_inbox("shipper-01"), ["ordering"]) {
                Err(e) => Err(e),
                Ok(_) => match reg.register_in(db, "acme-logistics", "consignee-01", "consignee", "Consignee 01", a2a_inbox("consignee-01"), ["receiving"]) {
                  Err(e) => Err(e),
                  Ok(_) => fold_ok(list.range(1, 21), fn (n :: Int) -> [sql, fs_write, time] Result[Unit, Str] {
                    reg.register_in(db, "acme-logistics", truck_id(n), "truck", str.concat("Truck ", int.to_str(n)), a2a_inbox(truck_id(n)), ["transport"])
                  }),
                },
              },
            },
          },
        },
      },
    },
  }
}

fn wire_tms(db :: Db) -> [sql, fs_write, crypto, random, time] Result[Unit, Str] {
  match fold_ok_n_crypto(list.range(1, 11), fn (n :: Int) -> [sql, fs_write, crypto, random, time] Result[Unit, Str] {
    match rel.add(db, truck_id(n), "tms-primary", "contracted", "{}") {
      Err(e) => Err(e),
      Ok(_) => rel.add(db, truck_id(n), "tms-secondary", "freelance", "{}"),
    }
  }) {
    Err(e) => Err(e),
    Ok(_) => fold_ok_n_crypto(list.range(11, 21), fn (n :: Int) -> [sql, fs_write, crypto, random, time] Result[Unit, Str] {
      match rel.add(db, truck_id(n), "tms-secondary", "contracted", "{}") {
        Err(e) => Err(e),
        Ok(_) => rel.add(db, truck_id(n), "tms-primary", "freelance", "{}"),
      }
    }),
  }
}

fn wire_group(db :: Db, trucks :: List[Int], depots :: List[Str]) -> [sql, fs_write, crypto, random, time] Result[Unit, Str] {
  fold_ok_n_crypto(trucks, fn (n :: Int) -> [sql, fs_write, crypto, random, time] Result[Unit, Str] {
    fold_ok_str(depots, fn (depot_id :: Str) -> [sql, fs_write, crypto, random, time] Result[Unit, Str] {
      rel.add(db, truck_id(n), depot_id, "preferred_charger", "{}")
    })
  })
}

fn wire_depots(db :: Db) -> [sql, fs_write, crypto, random, time] Result[Unit, Str] {
  match wire_group(db, list.range(1, 6), ["depot-north", "depot-west"]) {
    Err(e) => Err(e),
    Ok(_) => match wire_group(db, list.range(6, 11), ["depot-south", "depot-west"]) {
      Err(e) => Err(e),
      Ok(_) => match wire_group(db, list.range(11, 16), ["depot-east", "depot-north"]) {
        Err(e) => Err(e),
        Ok(_) => wire_group(db, list.range(16, 21), ["depot-south", "depot-east"]),
      },
    },
  }
}

fn wire_depot_reporting(db :: Db) -> [sql, fs_write, crypto, random, time] Result[Unit, Str] {
  let depots := ["depot-north", "depot-south", "depot-east", "depot-west"]
  let tmss := ["tms-primary", "tms-secondary"]
  fold_ok_str(depots, fn (depot_id :: Str) -> [sql, fs_write, crypto, random, time] Result[Unit, Str] {
    fold_ok_str(tmss, fn (tms_id :: Str) -> [sql, fs_write, crypto, random, time] Result[Unit, Str] {
      rel.add(db, depot_id, tms_id, "reporting", "{}")
    })
  })
}

# Demand side: the shipper tenders to both TMS providers (dispatch), and the
# consignee reports receipts back to them — closing the order loop.
fn wire_demand_side(db :: Db) -> [sql, fs_write, crypto, random, time] Result[Unit, Str] {
  let tmss := ["tms-primary", "tms-secondary"]
  match fold_ok_str(tmss, fn (tms_id :: Str) -> [sql, fs_write, crypto, random, time] Result[Unit, Str] {
    rel.add(db, "shipper-01", tms_id, "dispatch", "{}")
  }) {
    Err(e) => Err(e),
    Ok(_) => fold_ok_str(tmss, fn (tms_id :: Str) -> [sql, fs_write, crypto, random, time] Result[Unit, Str] {
      rel.add(db, "consignee-01", tms_id, "reporting", "{}")
    }),
  }
}

fn run(db :: Db) -> [sql, fs_write, crypto, random, time] Result[Unit, Str] {
  match register_agents(db) {
    Err(e) => Err(e),
    Ok(_) => match wire_tms(db) {
      Err(e) => Err(e),
      Ok(_) => match wire_depots(db) {
        Err(e) => Err(e),
        Ok(_) => match wire_depot_reporting(db) {
          Err(e) => Err(e),
          Ok(_) => wire_demand_side(db),
        },
      },
    },
  }
}


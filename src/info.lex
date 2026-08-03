# info.lex — the logistics agent-domain manifest (pack.PackInfo).
#
# The DomainPack counterpart of a REST pack's pos.PackManifest: how a console
# should PRESENT this pack's personas — labels, taglines, and the starter
# prompts each persona actually handles (they exercise the persona's own
# tools, which is why they live here and not in a frontend table). Served by
# the host under /platform/packs's agent_packs field.

import "lex-soft/src/pack" as pack

fn info() -> pack.PackInfo {
  { name: "logistics", title: "Logistics", tagline: "Moving goods: orders, tours, vehicles, depots and the energy behind them.", personas: [{ kind: "truck", title: "Truck", tagline: "An autonomous vehicle agent: state of charge, next stop, charging needs.", suggested_prompts: ["What is your current SOC and status?", "Do you need to charge soon?", "What is your next stop?"] }, { kind: "depot", title: "Depot", tagline: "A charging-depot operator: bay availability, grid load, reservations.", suggested_prompts: ["How many chargers are available?", "What is the current grid load?", "Reserve a charger for an inbound truck."] }, { kind: "tms", title: "TMS", tagline: "The dispatcher: orders, tours, assignments and fleet status.", suggested_prompts: ["How many pending orders are there?", "Give me a fleet status summary.", "Assign the next pending order."] }, { kind: "shipper", title: "Shipper", tagline: "The cargo owner: creates the orders and tenders the loads.", suggested_prompts: ["Create a new transport order.", "What is the status of my shipments?"] }, { kind: "emsp", title: "eMSP", tagline: "Roaming accounts: driver tokens and charge sessions at foreign CPOs.", suggested_prompts: ["Issue a roaming token for a vehicle.", "List active roaming sessions."] }] }
}


# lex-pack-logistics

Logistics domain pack — truck, depot, TMS, shipper/consignee/seller, and eMSP LLM-driven agent personas + the demo registry seed, built on `lex-soft`/`lex-agent`.

Extracted from [`lex-ev-fleet`](https://github.com/alpibrusl/lex-ev-fleet) (see [issue #236](https://github.com/alpibrusl/lex-ev-fleet/issues/236)). Matches `main.lex`'s own `pack.DomainPack` boundary named `"logistics"` — eMSP is part of it, not part of the energy pack, despite the name suggesting otherwise; the actual grouping is by which personas that `DomainPack` value bundles, not by industry label.

## Contents

- `src/truck.lex` — autonomous truck agent (telemetry, orders, route-energy estimation, custody handoffs)
- `src/depot.lex` — charging depot agent (charger availability, reservations)
- `src/tms.lex` — transport management system agent (dispatch, multi-stop routing, relay planning, trailer swaps)
- `src/shipper.lex` — demand-side personas: shipper (buyer), consignee (receiver), seller (supplier/ATP)
- `src/emsp.lex` — e-Mobility Service Provider agent (fleet accounts, roaming tokens, CDR billing, CPO registration)
- `src/intents.lex` — this pack's `find_peers` intent → relationship-role map
- `src/seed.lex` — the demo registry + relationship-graph seed (20 trucks, 4 depots, 2 TMS providers, shipper/consignee)

## Usage

Each agent file exports a `make_*_def(db, id, base_url, ...) -> srv.AgentDef` the host composes into a `pack.DomainPack` and mounts via `lex-soft/src/pack`'s `mount_pack`. See `lex-ev-fleet/main.lex` for the reference composition.

## Layering

Part of the lex-soft pack family: `lex-soft` (engine) -> this pack (persona builders + `pack.DomainPack` personas) -> the deployment (e.g. `lex-ev-fleet`, eventually [`lex-soft-node`](https://github.com/alpibrusl/lex-soft-node)) that composes the `DomainPack` and mounts it.

## License

Matches the rest of the lex ecosystem.

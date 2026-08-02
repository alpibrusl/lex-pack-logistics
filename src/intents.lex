# intents.lex — the fleet pack's find_peers intent → relationship-roles map.
#
# DOMAIN DATA the core (lex-soft) intentionally does NOT hardcode (lex-soft#34):
# the pack owns which roles satisfy each intent. Threaded into every agent's
# AgentConfig.intent_roles, serialized to the subprocess, and consumed by
# mesh.make_mesh_tools' find_peers. The intent name is included as a role so a
# peer registered with role == intent (e.g. an external connector) is reachable.

import "lex-soft/src/resolver" as resolver

fn fleet() -> List[resolver.IntentRoles] {
  [{ intent: "charging", roles: ["preferred_charger", "charger", "charging"] }, { intent: "dispatch", roles: ["contracted", "freelance", "dispatch"] }, { intent: "reporting", roles: ["reporting"] }, { intent: "roaming", roles: ["emsp", "roaming"] }, { intent: "flexibility", roles: ["flex", "ems", "flexibility"] }]
}


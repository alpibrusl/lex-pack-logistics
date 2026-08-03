# verdict_specs.lex — logistics's legality rules as DATA (lex-spec values).
#
# Moved here from the host's main.lex (lex-soft-node#10): the rule is
# logistics domain policy, so it ships with the pack, and a host composes
# it into verdict.mount_verify alongside every other mounted pack's specs.
#
# The one rule today: a depot agent that claims a charging request succeeded
# must have actually been in-grant. The verifier re-derives this over a
# task's settlement trail (POST /verify); it bites once a run records a
# structured outcome `{claimed_success, in_grant}`.

import "lex-spec/spec" as sp

import "lex-soft/src/verdict" as verdict

fn depot_grant_spec() -> sp.Spec {
  { name: "logistics.grant_on_success", quantifiers: [QRecord({ name: "outcome", fields: [{ name: "claimed_success", ty: TBool }, { name: "in_grant", ty: TBool }] })], predicate: EImplies(EField({ binding: "outcome", field: "claimed_success" }), EField({ binding: "outcome", field: "in_grant" })) }
}

fn verdict_specs() -> List[verdict.CapSpec] {
  [{ capability_id: "logistics.depot.handle", spec: depot_grant_spec(), binding: "outcome" }]
}


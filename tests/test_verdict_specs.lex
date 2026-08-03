# tests/test_verdict_specs.lex — the pack's legality rules are DATA; assert
# the shape a host composes into verdict.mount_verify: exactly one rule
# today, bound to the depot capability, over the {claimed_success, in_grant}
# outcome record.

import "../src/verdict_specs" as vs

fn assert_true(cond :: Bool, label :: Str) -> Result[Unit, Str] {
  if cond {
    Ok(())
  } else {
    Err(label)
  }
}

fn test_exactly_one_spec() -> Result[Unit, Str] {
  assert_true(list.len(vs.verdict_specs()) == 1, "exactly one verdict spec ships today")
}

fn test_spec_binds_depot_capability() -> Result[Unit, Str] {
  match list.head(vs.verdict_specs()) {
    Some(s) => assert_true(s.capability_id == "logistics.depot.handle", "the rule binds the depot capability"),
    None => Err("expected a verdict spec"),
  }
}

fn test_spec_name_survives_move() -> Result[Unit, Str] {
  match list.head(vs.verdict_specs()) {
    Some(s) => assert_true(s.spec.name == "logistics.grant_on_success", "rule name survives the move from the host"),
    None => Err("expected a verdict spec"),
  }
}

fn test_spec_binds_outcome_record() -> Result[Unit, Str] {
  match list.head(vs.verdict_specs()) {
    Some(s) => assert_true(s.binding == "outcome", "the rule binds the structured outcome record"),
    None => Err("expected a verdict spec"),
  }
}

fn run_all() -> List[Result[Unit, Str]] {
  [test_exactly_one_spec(), test_spec_binds_depot_capability(), test_spec_name_survives_move(), test_spec_binds_outcome_record()]
}


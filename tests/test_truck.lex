# tests/test_truck.lex — pure-logic coverage for src/truck.lex.
#
# vin_for is the one pure, non-trivial function here (id -> VIN padding); the
# rest of the file is HTTP-tool wiring and LLM system-prompt text, verified
# live against a running deployment rather than unit-tested, matching how the
# rest of this pack's agent files (depot, tms, shipper, emsp) were verified
# before this extraction.

import "../src/truck" as truck

fn pass() -> Result[Unit, Str] {
  Ok(())
}

fn assert_true(cond :: Bool, label :: Str) -> Result[Unit, Str] {
  if cond {
    pass()
  } else {
    Err(label)
  }
}

fn test_vin_for_single_digit_pads_to_three() -> Result[Unit, Str] {
  assert_true(truck.vin_for("truck-07") == "VIN-EV-007", "single-digit truck numbers pad to three digits")
}

fn test_vin_for_two_digit_pads_to_three() -> Result[Unit, Str] {
  assert_true(truck.vin_for("truck-42") == "VIN-EV-042", "two-digit truck numbers pad to three digits")
}

fn test_vin_for_three_digit_unpadded() -> Result[Unit, Str] {
  assert_true(truck.vin_for("truck-123") == "VIN-EV-123", "three-digit truck numbers are used as-is")
}

fn test_vin_for_non_truck_prefix_passes_through() -> Result[Unit, Str] {
  assert_true(truck.vin_for("pool-truck-01") == "pool-truck-01", "an id without the truck- prefix is returned unchanged")
}

fn run_all() -> List[Result[Unit, Str]] {
  [test_vin_for_single_digit_pads_to_three(), test_vin_for_two_digit_pads_to_three(), test_vin_for_three_digit_unpadded(), test_vin_for_non_truck_prefix_passes_through()]
}


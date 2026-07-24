# Narrow, documented Dialyzer suppressions.
#
# Ecto.Multi stores its step names in a MapSet, whose internal representation is
# opaque under Elixir 1.20/OTP 29. Analyzing the first Ecto.Multi.insert/3 in a
# chain therefore reports a spurious `call_without_opaque` even though the code
# is correct. This is a known Ecto + Dialyzer interaction, not a real defect.
[
  {"lib/sdd_orchestrator/accounts.ex", :call_without_opaque}
]

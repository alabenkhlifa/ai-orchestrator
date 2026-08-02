# Narrow, documented Dialyzer suppressions.
#
# Ecto.Multi stores its step names in a MapSet, whose internal representation is
# opaque under Elixir 1.20/OTP 29. Analyzing the first Ecto.Multi operation in
# a chain therefore reports a spurious `call_without_opaque` even though the
# code is correct. This is a known Ecto + Dialyzer interaction, not a real defect.
[
  {"lib/sdd_orchestrator/accounts.ex", :call_without_opaque},
  {"lib/sdd_orchestrator/projects.ex", :call_without_opaque},
  {"lib/sdd_orchestrator/hosted_access.ex", :call_without_opaque},
  {"lib/sdd_orchestrator/hosted_access/magic_links.ex", :call_without_opaque},
  {"lib/sdd_orchestrator/privacy/rights.ex", :call_without_opaque},
  {"lib/sdd_orchestrator/portability/hosted_restore.ex", :call_without_opaque},
  {"lib/sdd_orchestrator/participation.ex", :call_without_opaque, {450, 11}},
  {"lib/sdd_orchestrator/participation.ex", :call_without_opaque, {480, 11}},
  {"lib/sdd_orchestrator/specifications/specification_store/hosted.ex", :call_without_opaque},
  {"lib/sdd_orchestrator/participation/acceptance.ex", :call_without_opaque},
  {"lib/sdd_orchestrator/participation/revocations.ex", :call_without_opaque},
  {"lib/sdd_orchestrator/delivery/activity.ex", :call_without_opaque},
  {"lib/sdd_orchestrator/delivery/assignment.ex", :call_without_opaque},
  {"lib/sdd_orchestrator/delivery/command_outbox.ex", :call_without_opaque},
  {"lib/sdd_orchestrator/delivery/delivery_store/hosted.ex", :call_without_opaque}
]

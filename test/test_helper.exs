ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(SddOrchestrator.Repo, :manual)

# The `:live` tag marks proofs that make a real network round trip to GitHub with
# secret-backed credentials. They are excluded from the standard deterministic
# gate and run only when explicitly opted in (for example in the secret-backed
# staging environment) with `mix test --include live`.
ExUnit.configure(exclude: [:live])

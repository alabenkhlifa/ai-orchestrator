defmodule SddOrchestrator.Mailer do
  @moduledoc "Adapter-backed email delivery boundary."

  use Swoosh.Mailer, otp_app: :sdd_orchestrator
end

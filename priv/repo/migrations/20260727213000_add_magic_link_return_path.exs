defmodule SddOrchestrator.Repo.Migrations.AddMagicLinkReturnPath do
  use Ecto.Migration

  def change do
    alter table(:magic_link_attempts) do
      add :return_to, :string
    end
  end
end

defmodule Stage3Queue.Repo.Migrations.CreatePersistenceTable do
  use Ecto.Migration

  def change do
    create table("persistence", primary_key: false) do
      add :id, :uuid, primary_key: true
      add :priority, :integer
      add :function_name, :string
      add :args, :string
      add :start_at, :integer
      add :run_count, :integer
      add :status, :string
    end
  end
end

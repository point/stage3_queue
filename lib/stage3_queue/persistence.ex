defmodule Stage3Queue.Persistence do
  use Ecto.Schema
  import Ecto.Changeset
  require Ecto.Query

  alias __MODULE__
  alias Stage3Queue.Queue.Task
  alias Stage3Queue.Repo
  alias Ecto.Query

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "persistence" do
    field :priority, :integer
    field :function_name, :string
    field :args, :string
    field :start_at, :integer
    field :run_count, :integer
    field :status, :string
  end

  def changeset(persistence, %Task{} = task) do
    persistence
    |> cast(Map.from_struct(task), [:id, :priority, :function_name, :start_at, :run_count])
    |> put_change(:args, Jason.encode!(task.args))
    |> put_change(:status, "queued")
  end

  def insert(%Task{} = task) do
    changeset(%Persistence{}, task) |> Repo.insert()
  end

  def update(%Task{id: id} = task, extra_updates \\ %{}) do
    Repo.get!(Persistence, id)
    |> changeset(task)
    |> then(fn p -> merge(p, cast(p, extra_updates, [:status])) end)
    |> Repo.update()
  end

  def fail_running!() do
    Persistence
    |> Query.where(status: "running")
    |> Repo.update_all(set: [status: "failed"])
  end

  def queued_to_tasks_by_priority() do
    Persistence
    |> Query.where(status: "queued")
    |> Repo.all()
    |> Enum.map(&decode_args/1)
    |> Enum.map(&Task.from_persistence/1)
    |> Enum.group_by(& &1.priority)
  end

  defp decode_args(p), do: %{p | args: Jason.decode!(p.args)}
end

defmodule Stage3Queue.Queue.Task do
  alias Stage3Queue.Persistence
  alias __MODULE__

  @enforce_keys [:id, :function_name, :args, :start_at, :run_count, :priority]
  defstruct [
    :id,
    :function_name,
    :args,
    :start_at,
    :run_count,
    :pid,
    :ref,
    :priority,
    :fail_reasons
  ]

  @type t() :: %Task{
          id: String.t(),
          function_name: String.t(),
          args: list(),
          start_at: integer() | nil,
          run_count: non_neg_integer(),
          pid: pid() | nil,
          ref: reference() | nil,
          priority: non_neg_integer(),
          fail_reasons: list()
        }

  @spec new(String.t(), non_neg_integer(), String.t(), list()) :: t()
  def new(id, priority, function_name, args) do
    %__MODULE__{
      id: id,
      priority: priority,
      function_name: function_name,
      args: args,
      start_at: nil,
      run_count: 0,
      fail_reasons: [],
      pid: nil,
      ref: nil
    }
  end

  @spec from_persistence(%Persistence{}) :: t()
  def from_persistence(%Persistence{} = p) do
    t = new(p.id, p.priority, p.function_name, p.args)
    %{t | start_at: p.start_at, run_count: p.run_count}
  end
end

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

  def new(id, priority, function_name, args) do
    %Task{
      id: id,
      priority: priority,
      function_name: function_name,
      args: args,
      start_at: nil,
      run_count: 0,
      fail_reasons: []
    }
  end

  def from_persistence(%Persistence{} = p) do
    t = new(p.id, p.priority, p.function_name, p.args)
    %{t | start_at: p.start_at, run_count: p.run_count}
  end
end

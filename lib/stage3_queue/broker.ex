defmodule Stage3Queue.Broker do
  alias Stage3Queue.Queue

  def enqueue(topic, function_name, args, opts \\ []) do
    {:ok, _task_id} = Queue.enqueue(topic, function_name, args, opts)
  end

  def status(id) do
    cond do
      queued?(id) -> :queued
      running?(id) -> :running
      in_dlq?(id) -> :in_dead_letter_queue
      :otherwise -> :finished
    end
  end

  def abort(id) do
    case Registry.lookup(Stage3Queue.QueueRegistry, id) do
      [{pid, _}] ->
        Process.exit(pid, :kill)

      _ ->
        get_all_queues()
        |> Enum.find_value(false, fn
          %{key: "queue_" <> _, pid: pid} ->
            Queue.dequeue(pid, id)

          _ ->
            false
        end)
    end
  end

  def running?(id) do
    match?([{_pid, _}], Registry.lookup(Stage3Queue.QueueRegistry, id))
  end

  def queued?(id) do
    get_all_queues()
    |> Enum.find_value(false, fn
      %{key: "queue_" <> _, pid: pid} ->
        Queue.in_queue?(pid, id)

      _ ->
        false
    end)
  end

  def in_dlq?(id) do
    get_all_queues()
    |> Enum.find_value(false, fn
      %{key: "queue_" <> _, pid: pid} ->
        Queue.in_dlq?(pid, id)

      _ ->
        false
    end)
  end

  defp get_all_queues() do
    Registry.select(Stage3Queue.QueueRegistry, [
      {{:"$1", :"$2", :_}, [], [%{key: :"$1", pid: :"$2"}]}
    ])
  end
end

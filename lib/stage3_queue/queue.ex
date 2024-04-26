defmodule Stage3Queue.Queue do
  use GenServer, shutdown: :infinity, restart: :transient

  alias Stage3Queue.Queue.State
  alias Stage3Queue.Queue.Task
  alias Stage3Queue.Dispatcher
  alias Stage3Queue.Persistence
  require Logger

  @max_concurrency 1
  @max_queue_len 200
  @max_restarts 5
  @max_backoff 10_000
  @persistent true

  def start_link(params) do
    topic = Keyword.fetch!(params, :topic)
    GenServer.start_link(__MODULE__, params, name: queue_name(topic))
  end

  def enqueue(topic, function_name, args, opts \\ []) do
    with priority when priority in 1..10 <- Keyword.get(opts, :priority, 10),
         {:ok, pid} <- find_queue(topic) do
      GenServer.call(pid, {:enqueue, function_name, args, priority})
    else
      {:error, _} = err -> err
      _ -> {:error, "Priority should be in the range 1.10 (1 is the most urgent)"}
    end
  end

  def dequeue(pid, task_id), do: GenServer.call(pid, {:dequeue, task_id})

  def in_queue?(pid, task_id), do: GenServer.call(pid, {:in_queue?, task_id})

  def in_dlq?(pid, task_id), do: GenServer.call(pid, {:in_dlq, task_id})

  @impl true
  def init(params) do
    Process.flag(:trap_exit, true)

    topic = Keyword.fetch!(params, :topic)

    params =
      Keyword.merge(
        [
          max_concurrency: Keyword.get(params, :max_concurrency, @max_concurrency),
          max_queue_len: Keyword.get(params, :max_concurrency, @max_queue_len),
          max_restarts: Keyword.get(params, :max_restarts, @max_restarts),
          persistent: Keyword.get(params, :persistent, @persistent),
          # use 0 to disable backoff
          max_backoff: Keyword.get(params, :max_backoff, @max_backoff)
        ],
        params
      )

    state = State.new(topic, params)

    Logger.info("Queue with topic #{inspect(topic)} started")
    {:ok, state, {:continue, :init}}
  end

  def register_and_dispatch(id, args) do
    Registry.register_name({Stage3Queue.QueueRegistry, id}, self())
    apply(Dispatcher, :dispatch, args)
  end

  @impl true
  def handle_call(
        {:enqueue, function_name, args, priority},
        _,
        %State{max_queue_len: max_queue_len, task_queue: task_queue} = state
      ) do
    if length(Map.get(task_queue, priority, [])) < max_queue_len do
      id = UUID.uuid4()
      Logger.info("Add task with id #{id} to Q with priority #{priority}")

      task = Task.new(id, priority, function_name, args)

      if state.persistent, do: Persistence.insert(task)

      task_queue = Map.update(task_queue, priority, [task], fn existing -> existing ++ [task] end)
      new_state = %{state | task_queue: task_queue}
      {:reply, {:ok, id}, new_state, {:continue, :run_queue}}
    else
      {:reply, {:error, "Queue reached its max capacity of #{state.max_queue_len} elements"},
       state}
    end
  end

  def handle_call({:in_queue?, id}, _, state) do
    result =
      state.task_queue
      |> Map.values()
      |> List.flatten()
      |> Enum.any?(&(&1.id == id))

    {:reply, result, state}
  end

  def handle_call({:in_dlq, id}, _, state) do
    result =
      state.dead_letter_queue
      |> Enum.any?(&(&1.id == id))

    {:reply, result, state}
  end

  def handle_call({:dequeue, id}, _, state) do
    state.task_queue
    |> Enum.map_reduce(nil, fn
      {p, tasks}, nil ->
        case Enum.find(tasks, &(&1.id == id)) do
          %Task{} = t ->
            Logger.info("Dequeue task id #{id} from the queue #{state.topic}")
            {{p, Enum.reject(tasks, &(&1 == t))}, t}

          nil ->
            {{p, tasks}, nil}
        end

      {_p, _tasks} = entry, found ->
        {entry, found}
    end)
    |> case do
      {_, nil} -> {:reply, :notfound, state}
      {tasks_as_list, _} -> {:reply, :ok, %{state | task_queue: Enum.into(tasks_as_list, %{})}}
    end
  end

  @impl true
  def handle_continue(:init, %State{} = state) do
    if state.persistent do
      Persistence.fail_running!()

      {:noreply, %{state | task_queue: Persistence.queued_to_tasks_by_priority()},
       {:continue, :run_queue}}
    else
      {:noreply, state}
    end
  end

  def handle_continue(
        :run_queue,
        %State{task_queue: task_queue} = state
      )
      when map_size(task_queue) == 0,
      do: {:noreply, state}

  def handle_continue(
        :run_queue,
        %State{run_queue: run_queue, max_concurrency: max_concurrency} = state
      )
      when length(run_queue) < max_concurrency do
    to_take = max_concurrency - length(run_queue)

    {task_queue_as_list, tasks_to_take} =
      state.task_queue
      |> Enum.sort()
      |> Enum.map_reduce([], fn
        queue_entry, acc when length(acc) == to_take ->
          {queue_entry, acc}

        {priority, tasks}, acc ->
          # Enum.split(tasks, to_take - length(acc))
          {tasks_to_take, rest_tasks} = choose_tasks(tasks, to_take - length(acc))
          {{priority, rest_tasks}, acc ++ tasks_to_take}
      end)

    new_tasks =
      tasks_to_take
      |> Enum.map(fn %Task{id: id, function_name: function_name, args: args} = task ->
        {pid, ref} =
          spawn_monitor(__MODULE__, :register_and_dispatch, [id, [function_name | args]])

        if state.persistent, do: Persistence.update(task, %{status: "running"})

        Logger.info("Running task id #{id}", pid: pid, ref: ref)
        %{task | pid: pid, ref: ref, run_count: task.run_count + 1}
      end)

    task_queue = Enum.into(task_queue_as_list, %{})

    {:noreply, %{state | run_queue: run_queue ++ new_tasks, task_queue: task_queue}}
  end

  def handle_continue(:run_queue, state) do
    Logger.info("Run Q is full. Waiting for free slots")
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, finished_ref, _, finished_pid, :normal}, state) do
    task =
      Enum.find(state.run_queue, fn %Task{pid: pid, ref: ref} ->
        pid == finished_pid and ref == finished_ref
      end)

    Logger.info(
      "Task with pid #{inspect(finished_pid)} ref #{inspect(finished_ref)} id #{task.id} finished normally"
    )

    if state.persistent, do: Persistence.update(task, %{status: "finished"})

    run_queue = Enum.reject(state.run_queue, &(&1.id == task.id))

    {:noreply, %{state | run_queue: run_queue}, {:continue, :run_queue}}
  end

  def handle_info({:DOWN, finished_ref, _, finished_pid, {reason, _}}, state)
      when reason in [:undef, :function_clause] do
    task =
      Enum.find(state.run_queue, fn %Task{pid: pid, ref: ref} ->
        pid == finished_pid and ref == finished_ref
      end)

    Logger.warning("""
    Task with pid #{inspect(finished_pid)} ref #{inspect(finished_ref)} id #{task.id} failed to execute: \
    no function clause matching in Stage3Queue.Dispatcher.dispatch/2
    Giving up.
    """)

    if state.persistent, do: Persistence.update(task, %{status: "failed"})

    run_queue = Enum.reject(state.run_queue, &(&1.id == task.id))

    {:noreply, %{state | run_queue: run_queue}, {:continue, :run_queue}}
  end

  def handle_info({:DOWN, finished_ref, _, finished_pid, fail_reason}, state) do
    Logger.warning(
      "Task with pid #{inspect(finished_pid)} ref #{inspect(finished_ref)} failed to run. Maybe restarting",
      fail_reason: fail_reason
    )

    task =
      Enum.find(state.run_queue, fn %Task{pid: pid, ref: ref} ->
        pid == finished_pid and ref == finished_ref
      end)

    state =
      with %Task{} <- task,
           true <- task.run_count < state.max_restarts do
        Logger.info(
          "Restarting task id #{task.id} #{if state.max_backoff > 0, do: "with backoff"}"
        )

        run_queue = Enum.reject(state.run_queue, &(&1.id == task.id))

        task =
          %{task | fail_reasons: [fail_reason | task.fail_reasons], pid: nil, ref: nil}
          |> backoff(state.max_backoff)

        if state.persistent, do: Persistence.update(task, %{status: "failed"})

        task_queue =
          Map.update(state.task_queue, task.priority, [task], fn existing ->
            existing ++ [task]
          end)

        %{state | run_queue: run_queue, task_queue: task_queue}
      else
        false ->
          move_to_dlq(state, %{task | fail_reasons: [fail_reason | task.fail_reasons]})

        _ ->
          %{state | run_queue: Enum.reject(state.run_queue, &(&1.id == task.id))}
      end

    {:noreply, state, {:continue, :run_queue}}
  end

  def handle_info(:run_queue, state), do: {:noreply, state, {:continue, :run_queue}}

  # def handle_info({:EXIT, pid, _reason}, state) do
  #   {:noreply, state}
  # end

  @impl true
  def terminate(_reason, state) do
    for %Task{pid: pid} = task <- state.run_queue do
      Logger.info("Shutting down task with pid #{inspect(pid)}")

      if state.persistent, do: Persistence.update(task, %{status: "exited"})
      Process.exit(pid, :shutdown)

      receive do
        {:EXIT, ^pid, _reason} -> :ok
      after
        1000 ->
          if state.persistent, do: Persistence.update(task, %{status: "killed"})
          Logger.info("Killing task with pid #{inspect(pid)}")
          Process.exit(pid, :kill)
      end
    end

    :ok
  end

  def queue_name(topic),
    do: {:via, Registry, {Stage3Queue.QueueRegistry, make_queue_name(topic)}}

  def find_queue(topic) do
    topic = make_queue_name(topic)

    case Registry.lookup(Stage3Queue.QueueRegistry, topic) do
      [{pid, _}] ->
        {:ok, pid}

      _ ->
        {:error, "Topic #{inspect(topic)} not started"}
    end
  end

  defp make_queue_name(topic), do: "queue_#{topic}"

  defp move_to_dlq(state, %Task{} = task) do
    Logger.warning("Task id #{task.id} reached max_restarts. Moving to dead letter queue")

    if state.persistent, do: Persistence.update(task, %{status: "in_dead_lettter_queue"})

    run_queue = Enum.reject(state.run_queue, &(&1.id == task.id))
    dlq = [task | state.dead_letter_queue]
    %{state | run_queue: run_queue, dead_letter_queue: dlq}
  end

  def choose_tasks(tasks, how_many) do
    current_time = System.monotonic_time(:millisecond)

    tasks
    |> Enum.reduce({[], []}, fn
      t, {tasks_to_take, tasks_to_leave} when length(tasks_to_take) == how_many ->
        {tasks_to_take, [t | tasks_to_leave]}

      %Task{start_at: nil} = t, {tasks_to_take, tasks_to_leave} ->
        {[t | tasks_to_take], tasks_to_leave}

      %Task{start_at: start_at} = t, {tasks_to_take, tasks_to_leave}
      when current_time > start_at ->
        {[t | tasks_to_take], tasks_to_leave}

      t, {tasks_to_take, tasks_to_leave} ->
        {tasks_to_take, [t | tasks_to_leave]}
    end)
    |> then(fn {l1, l2} -> {Enum.reverse(l1), Enum.reverse(l2)} end)
  end

  defp backoff(t, 0), do: t

  defp backoff(%Task{} = task, max_backoff) do
    interval = min(Integer.pow(2, task.run_count) * 1000 + Enum.random(1..1000), max_backoff)
    Process.send_after(self(), :run_queue, interval)
    %{task | start_at: System.monotonic_time(:millisecond) + interval}
  end
end

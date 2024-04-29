defmodule Stage3Queue.Queue do
  @moduledoc """
  Queue holds all the tasks, which are scheduled to run, running, or failed to execute after configured amount of retries.
  Also, it monitors the running tasks to know when one failed or finished successfully.

  Queue is a `GenServer` but with `shutdown: :infinity` and `Process.flag(:trap_exit, true)`, which
  lets it take care about running tasks when crash or exit happens.

  Each queue has its own unique topic. So many Queues could be started simultaneously with different 
  settings, in isolated environment. So one crash doesn't affect other queues.
  To keep the `pid` of a queue, the Registry module is used. 
  Queue's `pid` is stored under `queue_<topic>` name and could be easily retrieved later.

  ## Enqueue 

  The beginning of a task lifecycle is `enqueue` call. 
  Each task has:

  * topic name (as atom) to find out the queue to add the task to
  * function name, which is passed to the dispatcher, and `dispatch` function with this function name is called.
    By default, `Stage3Queue.Dispatcher.dispatch` set of functions are used. The dispatcher module could be overridden 
    on a per-queue basis with `dispatcher_module` setting: `{Queue, topic: :topic, dispatcher_module: SomeOtherDispatcher}`
  * args as list to be passed as arguments to the `dispatch` function call. It follows usual `apply(MFA)` convention.
  * extra task options. Now only `[priority: <prio>]` is supported, which defines task priority. 
    Queue allows priories in a range 1..10, where 10 is a default priority, 1 - is the highest task priority. 

  When a task is about to be enqueued, the system checks `max_queue_len` setting. And if there are already this number of tasks sit waiting
  to be picked for processing, the `enqueue` call fails with a message fail message.

  Otherwise, the `Task` structure is created and placed into the `task_queue` map, which has `%{priority => [Task1, Task2]}` shape.
  If persistence is turned on (see [Settings]), a new record in the DB is created.

  In case of success, function return `{:ok, task_id}` tuple, where `task_id` is a UUIDv4 string.

  Immediately after, Queue invokes the `:run_queue` routine.


  ## Running the queue

  Each queue has `max_concurrency` setting, which defines how many tasks Queue can run simultaneously.
  If the limit is reached, new tasks execution is postponed until at least one already running task is finished.

  When there are available run slots, Queue takes as many new tasks from the `task_queue` to fill the available slots, 
  with respect to the priority. Meaning, if all tasks with priority 1 are taken, the rest of `taks_queue` would be filled with 
  tasks of priority 2,3,4 and so on. Less important tasks wait longer to be peeked up.

  Queue uses `spawn_monitor` function to start a `Task` and monitor, when it finished or crushed. So that Queue does bookkeeping of
  running tasks and acts like a supervisor for them, by restarting configured number of times (see [Settings]) or by putting into
  dead letter queue, if all previous tries failed. 
  When task finishes with whatever reason, Queue receives `{:DOWN, ref, _, pid, reason}` and tracks the task.

  The `register_and_dispatch` function is an entry point for a task's actual job. It registers new task `pid` under its UUIDv4 id, and then passes
  execution flow to configured dispatcher module, the `dispatch` function, where the actual job is executed.

  If persistence is turned on (see [Settings]), a task record in DB is updated with new `running` status.

       
  ## Task end-of-life

  When task finishes successfully (with exit status `:normal`), Queue removes the `Task` structure out of `run_queue`, and a new round of 
  peeking up task with respect to priority is started. 

  If persistence is turned on (see [Settings]), a task record in DB is updated with `finished` status.

  Otherwise, Queue will try to restart the task by placing the `Task` structure back into `task_queue` under its priority in the end of the list 
  (only if `max_restarts` count for a specific task is not reached. See [Settings]). 

  If `max_restarts` is reached, the `Task` is moved to `dead_letter_queue` for further investigations. 
  All fail reasons of all restarts are stored in `Task`-s `fail_reasons` field.

  If `max_backoff` (see [Settings]) is not equal to 0, the next restart will happen with a delay. 
  The formula: 2^<retry_number>sec + 0..100ms, but not greater than `max_backoff`. 
  Meaning, the second retry would be in 4s + 0..100ms, 4rd in 8 + 0..100ms and so on. But not greater than `max_backoff`. 
  Random delay of 0..100ms is added to prevent massive simultaneous tasks restarts.

  If persistence is turned on (see [Settings]), a task record in DB is updated with `failed` status.


  ## Queue termination
  When Queue process is terminated, Queue tries to `exit(:shutdown)` all running tasks. 
  If after 1s the task process is not finished, it's gonna be killed `exit(:kill)`.

  During the subsequent Queue restart, if persistence is turned on (see [Settings]), all scheduled tasks are loaded 
  into the `task_queue` and Queue immediately continues task processing.
       
  ## Settings:

    * `dispatcher_module`: defines a module which holds `dispatch` function responsible for task execution and function call-forwarding.
      Default: `Stage3Queue.Dispatcher`
    * `max_concurrency`: sets the number of simultaneously running tasks. 
      Default: 10
    * `max_queue_len`: sets the by-priority length of the `task_queue` and the maximum number of tasks that could be placed into the queue. 
      Default: 200. Meaning, each priority has a queue of at most 200 elements in it.
    * `max_restarts`: defines how many times the task should be restarted (potentially with a backoff) before placing into dead letter queue.
      Default: 5
    * `max_backoff`: sets the maximum delay in milliseconds until the next task retry. See backoff formula above for more explanation. 
      Could be 0, to turn off delay at all. Then task is placed in the end of the queue and when `run_queue` is available, the task is executed immediately.
      Default: 10_000
    * `persistent`: sets whether to store and track tasks in the DB or not. See [Persistence].
      Default: true

  ## Persistence:
  If `persistent` setting is turned on, Queue tracks each `Task` in the database. It saves `priority`, `function_name`,
  `args`, `start_at`, `run_count` and `status`. It's important to have `function_name` and values in `args` list which are JSON-encodable.
  So no tuples, atoms or pids.
  When persistence is off and DB is not used, those could be any values without limits.

  """

  use GenServer, shutdown: :infinity, restart: :transient

  alias Stage3Queue.Queue.State
  alias Stage3Queue.Queue.Task
  alias Stage3Queue.Persistence
  require Logger

  @max_concurrency 10
  @max_queue_len 200
  @max_restarts 5
  @max_backoff 10_000
  @persistent true
  @dispatcher_module Stage3Queue.Dispatcher

  @dialyzer {:nowarn_function, handle_info: 2}
  @type start_option() ::
          {:topic, atom}
          | {:max_concurrency, non_neg_integer()}
          | {:max_queue_len, non_neg_integer()}
          | {:task_queue, %{non_neg_integer() => list(Stage3Queue.Queue.Task.t())}}
          | {:run_queue, list(Stage3Queue.Queue.Task.t())}
          | {:max_restarts, non_neg_integer()}
          | {:dead_letter_queue, list(Stage3Queue.Queue.Task.t())}
          | {:max_backoff, non_neg_integer()}
          | {:persistent, boolean()}
  @type start_options() :: [start_option()]

  @spec start_link(start_options()) :: GenServer.on_start()
  def start_link(params) do
    topic = Keyword.fetch!(params, :topic)
    GenServer.start_link(__MODULE__, params, name: queue_name(topic))
  end

  @spec enqueue(atom(), String.t(), list(), priority: non_neg_integer()) :: {:ok, String.t()}
  def enqueue(topic, function_name, args, opts \\ []) do
    with priority when priority in 1..10 <- Keyword.get(opts, :priority, 10),
         {:ok, pid} <- find_queue(topic) do
      GenServer.call(pid, {:enqueue, function_name, args, priority})
    else
      {:error, _} = err -> err
      _ -> {:error, "Priority should be in the range 1.10 (1 is the most urgent)"}
    end
  end

  @spec dequeue(pid(), String.t()) :: boolean()
  def dequeue(pid, task_id), do: GenServer.call(pid, {:dequeue, task_id})

  @spec abort(pid(), String.t()) :: boolean()
  def abort(pid, task_id), do: GenServer.call(pid, {:abort, task_id})

  @spec in_queue?(pid(), String.t()) :: boolean()
  def in_queue?(pid, task_id), do: GenServer.call(pid, {:in_queue?, task_id})

  @spec in_dlq?(pid(), String.t()) :: boolean()
  def in_dlq?(pid, task_id), do: GenServer.call(pid, {:in_dlq, task_id})

  @spec register_and_dispatch(String.t(), module(), list()) :: any()
  def register_and_dispatch(id, mod, args) do
    Registry.register_name({Stage3Queue.QueueRegistry, id}, self())
    apply(mod, :dispatch, args)
  end

  @impl true
  def init(params) do
    Process.flag(:trap_exit, true)

    topic = Keyword.fetch!(params, :topic)

    params =
      Keyword.merge(
        [
          dispatcher_module: Keyword.get(params, :dispatcher_module, @dispatcher_module),
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

  def handle_call({:abort, task_id}, _, state) do
    case dequeue_from_task_queue(state, task_id) do
      {_, nil} ->
        state.run_queue
        |> Enum.find(&(&1.id == task_id))
        |> case do
          %Task{pid: pid} = task ->
            Process.exit(pid, :kill)
            {:reply, true, %{state | run_queue: List.delete(state.run_queue, task)}}

          nil ->
            {:reply, false, state}
        end

      {state, _} ->
        {:reply, true, state}
    end
  end

  def handle_call({:dequeue, task_id}, _, state) do
    case dequeue_from_task_queue(state, task_id) do
      {_, nil} -> {:reply, false, state}
      {state, _} -> {:reply, true, state}
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
          spawn_monitor(__MODULE__, :register_and_dispatch, [
            id,
            state.dispatcher_module,
            [function_name | args]
          ])

        task = %{task | pid: pid, ref: ref, run_count: task.run_count + 1}
        if state.persistent, do: Persistence.update(task, %{status: "running"})

        Logger.info("Running task id #{id}", pid: pid, ref: ref)
        task
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
    no function clause matching with dispatch/2
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
          _state = move_to_dlq(state, %{task | fail_reasons: [fail_reason | task.fail_reasons]})

        _ ->
          %{state | run_queue: Enum.reject(state.run_queue, &(&1.pid == finished_pid))}
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

  @spec queue_name(atom()) :: tuple()
  def queue_name(topic),
    do: {:via, Registry, {Stage3Queue.QueueRegistry, make_queue_name(topic)}}

  @spec find_queue(atom()) :: {:ok, pid()} | {:error, String.t()}
  def find_queue(topic) do
    topic = make_queue_name(topic)

    case Registry.lookup(Stage3Queue.QueueRegistry, topic) do
      [{pid, _}] ->
        {:ok, pid}

      _ ->
        {:error, "Topic #{inspect(topic)} not started"}
    end
  end

  @spec make_queue_name(atom()) :: String.t()
  defp make_queue_name(topic), do: "queue_#{topic}"

  @spec move_to_dlq(State.t(), Task.t()) :: State.t()
  defp move_to_dlq(state, %Task{} = task) do
    Logger.warning("Task id #{task.id} reached max_restarts. Moving to dead letter queue")

    if state.persistent, do: Persistence.update(task, %{status: "in_dead_lettter_queue"})

    run_queue = Enum.reject(state.run_queue, &(&1.id == task.id))
    dlq = [task | state.dead_letter_queue]
    %{state | run_queue: run_queue, dead_letter_queue: dlq}
  end

  @spec choose_tasks([Task.t()], non_neg_integer()) :: {list(Task.t()), list(Task.t())}
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

  @spec backoff(Task.t(), non_neg_integer()) :: Task.t()
  defp backoff(t, 0), do: t

  defp backoff(%Task{} = task, max_backoff) do
    interval = min(Integer.pow(2, task.run_count) * 1000 + Enum.random(1..100), max_backoff)
    Process.send_after(self(), :run_queue, interval)
    %{task | start_at: System.monotonic_time(:millisecond) + interval}
  end

  @spec dequeue_from_task_queue(State.t(), String.t()) :: {State.t(), Task.t()} | {State.t(), nil}
  defp dequeue_from_task_queue(%State{} = state, id) do
    state.task_queue
    |> Enum.map_reduce(nil, fn
      {p, tasks}, nil ->
        case Enum.find(tasks, &(&1.id == id)) do
          %Task{} = t ->
            {{p, Enum.reject(tasks, &(&1 == t))}, t}

          nil ->
            {{p, tasks}, nil}
        end

      {_p, _tasks} = entry, found ->
        {entry, found}
    end)
    |> case do
      {_, nil} -> {state, nil}
      {tasks_as_list, task} -> {%{state | task_queue: Enum.into(tasks_as_list, %{})}, task}
    end
  end
end

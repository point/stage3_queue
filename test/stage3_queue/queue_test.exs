defmodule Stage3Queue.QueueTest do
  use ExUnit.Case
  use Stage3Queue.DataCase

  require Ecto.Query

  alias Stage3Queue.Queue
  alias Stage3Queue.Broker
  alias Stage3Queue.Queue.State
  alias Stage3Queue.Queue.Task
  alias Stage3Queue.Persistence

  test "basic happy path" do
    assert {:ok, pid} =
             start_supervised(
               {Queue,
                topic: :basic1, persistent: false, dispatcher_module: Stage3Queue.TestDispatcher}
             )

    assert {:ok, id} = Broker.enqueue(:basic1, "sleep", [50])
    assert :running == Broker.status(id)
    assert true == Broker.running?(id)

    assert %State{run_queue: [%Task{id: ^id}]} = :sys.get_state(pid)
  end

  test "basic happy path with queuing" do
    assert {:ok, pid} =
             start_supervised(
               {Queue,
                topic: :basic2,
                persistent: false,
                max_concurrency: 1,
                dispatcher_module: Stage3Queue.TestDispatcher}
             )

    assert {:ok, id1} = Broker.enqueue(:basic2, "sleep", [50])
    assert {:ok, id2} = Broker.enqueue(:basic2, "sleep", [50])
    assert :running == Broker.status(id1)
    assert :queued == Broker.status(id2)

    assert true == Broker.queued?(id2)

    assert %State{run_queue: [%Task{id: ^id1}], task_queue: %{10 => [%Task{id: ^id2}]}} =
             :sys.get_state(pid)
  end

  test "basic happy path with priorities" do
    assert {:ok, pid} =
             start_supervised(
               {Queue,
                topic: :basic3,
                persistent: false,
                max_concurrency: 1,
                dispatcher_module: Stage3Queue.TestDispatcher}
             )

    assert {:ok, id1} = Broker.enqueue(:basic3, "sleep", [50])
    assert {:ok, id2} = Broker.enqueue(:basic3, "sleep", [50], priority: 5)
    assert {:ok, id3} = Broker.enqueue(:basic3, "sleep", [50], priority: 1)
    assert :running == Broker.status(id1)
    assert :queued == Broker.status(id2)
    assert :queued == Broker.status(id3)

    assert %State{
             run_queue: [%Task{id: ^id1}],
             task_queue: %{1 => [%Task{id: ^id3}], 5 => [%Task{id: ^id2}]}
           } =
             :sys.get_state(pid)

    Process.sleep(80)

    assert :finished == Broker.status(id1)
    assert :queued == Broker.status(id2)
    assert :running == Broker.status(id3)
  end

  test "basic happy path with abort queued task" do
    assert {:ok, _pid} =
             start_supervised(
               {Queue,
                topic: :basic4,
                persistent: false,
                max_concurrency: 1,
                dispatcher_module: Stage3Queue.TestDispatcher}
             )

    assert {:ok, id1} = Broker.enqueue(:basic4, "sleep", [50])
    assert {:ok, id2} = Broker.enqueue(:basic4, "sleep", [50], priority: 5)
    assert :running == Broker.status(id1)
    assert :queued == Broker.status(id2)

    Broker.abort(id2)
    Process.sleep(80)
    assert :finished == Broker.status(id2)
  end

  test "max_queue_len works" do
    assert {:ok, pid} =
             start_supervised(
               {Queue,
                topic: :max_q,
                persistent: false,
                max_concurrency: 1,
                max_queue_len: 1,
                dispatcher_module: Stage3Queue.TestDispatcher}
             )

    assert {:ok, id1} = Broker.enqueue(:max_q, "sleep", [50])
    assert {:ok, id2} = Broker.enqueue(:max_q, "sleep", [50])

    assert {:error, "Queue reached its max capacity of 1 elements"} =
             Broker.enqueue(:max_q, "sleep", [50])

    assert %State{
             run_queue: [%Task{id: ^id1}],
             task_queue: %{10 => [%Task{id: ^id2}]}
           } =
             :sys.get_state(pid)
  end

  test "max_restarts works" do
    assert {:ok, pid} =
             assert(
               {:ok, _pid} =
                 start_supervised(
                   {Queue,
                    topic: :max_restarts,
                    persistent: false,
                    max_restarts: 2,
                    max_backoff: 0,
                    dispatcher_module: Stage3Queue.TestDispatcher}
                 )
             )

    assert {:ok, id1} = Broker.enqueue(:max_restarts, "die", [])

    assert %State{
             run_queue: [%Task{id: ^id1}]
           } =
             :sys.get_state(pid)

    Process.sleep(50)

    # no backoff
    assert %State{
             dead_letter_queue: [%Task{id: ^id1, run_count: 2, fail_reasons: fail_reasons}]
           } =
             :sys.get_state(pid)

    assert 2 == length(fail_reasons)

    assert :in_dead_letter_queue == Broker.status(id1)
  end

  test "backoff works" do
    assert {:ok, pid} =
             assert(
               {:ok, _pid} =
                 start_supervised(
                   {Queue,
                    topic: :max_backoff,
                    persistent: false,
                    max_restarts: 2,
                    dispatcher_module: Stage3Queue.TestDispatcher}
                 )
             )

    assert {:ok, id1} = Broker.enqueue(:max_backoff, "die", [])

    assert %State{
             run_queue: [%Task{id: ^id1}]
           } =
             :sys.get_state(pid)

    Process.sleep(50)

    assert %State{
             task_queue: %{10 => [%Task{id: ^id1, run_count: 1}]}
           } =
             :sys.get_state(pid)

    # second restart happens with 2s + 0..100ms backoff
    Process.sleep(2100)

    assert %State{
             dead_letter_queue: [%Task{id: ^id1, run_count: 2}]
           } =
             :sys.get_state(pid)
  end

  test "persistent happy path" do
    assert {:ok, _pid} =
             start_supervised(
               {Queue,
                topic: :pers1,
                max_concurrency: 1,
                max_restarts: 2,
                max_backoff: 0,
                dispatcher_module: Stage3Queue.TestDispatcher}
             )

    assert {:ok, id1} = Broker.enqueue(:pers1, "sleep&die", [])
    assert {:ok, id2} = Broker.enqueue(:pers1, "sleep&die", [])

    tasks = Repo.all(Persistence)

    assert %Persistence{
             id: ^id1,
             priority: 10,
             function_name: "sleep&die",
             args: "[]",
             run_count: 1,
             status: "running"
           } = Enum.find(tasks, &(&1.id == id1))

    assert %Persistence{
             id: ^id2,
             priority: 10,
             function_name: "sleep&die",
             args: "[]",
             run_count: 0,
             status: "queued"
           } = Enum.find(tasks, &(&1.id == id2))

    Process.sleep(70)

    tasks = Repo.all(Persistence)

    assert %Persistence{
             id: ^id1,
             priority: 10,
             function_name: "sleep&die",
             args: "[]",
             run_count: 1,
             status: "failed"
           } = Enum.find(tasks, &(&1.id == id1))

    assert %Persistence{
             id: ^id2,
             priority: 10,
             function_name: "sleep&die",
             args: "[]",
             run_count: 1,
             status: "running"
           } = Enum.find(tasks, &(&1.id == id2))

    Process.sleep(70)

    tasks = Repo.all(Persistence)

    assert %Persistence{
             id: ^id1,
             run_count: 2,
             status: "running"
           } = Enum.find(tasks, &(&1.id == id1))

    Process.sleep(200)

    tasks = Repo.all(Persistence)

    assert %Persistence{
             id: ^id1,
             run_count: 2,
             status: "in_dead_lettter_queue"
           } = Enum.find(tasks, &(&1.id == id1))

    assert %Persistence{
             id: ^id2,
             run_count: 2,
             status: "in_dead_lettter_queue"
           } = Enum.find(tasks, &(&1.id == id2))
  end

  test "resurrect (with priority)" do
    assert {:ok, _pid} =
             start_supervised(
               {Queue,
                topic: :res,
                max_concurrency: 1,
                max_restarts: 2,
                dispatcher_module: Stage3Queue.TestDispatcher}
             )

    assert {:ok, id1} = Broker.enqueue(:res, "sleep&die", [])
    assert {:ok, id2} = Broker.enqueue(:res, "sleep&die", [])
    assert {:ok, id3} = Broker.enqueue(:res, "sleep&die", [], priority: 1)

    Process.sleep(10)
    stop_supervised(Queue)

    tasks = Repo.all(Persistence)

    assert %Persistence{
             id: ^id1,
             status: "killed"
           } = Enum.find(tasks, &(&1.id == id1))

    assert %Persistence{
             id: ^id2,
             status: "queued"
           } = Enum.find(tasks, &(&1.id == id2))

    assert %Persistence{
             id: ^id3,
             status: "queued"
           } = Enum.find(tasks, &(&1.id == id3))

    assert {:ok, pid} =
             start_supervised(
               {Queue,
                topic: :res,
                max_concurrency: 1,
                max_restarts: 2,
                dispatcher_module: Stage3Queue.TestDispatcher}
             )

    assert %State{run_queue: [%Task{id: ^id3, run_count: 1}]} = :sys.get_state(pid)
    tasks = Repo.all(Persistence)

    assert %Persistence{
             id: ^id1,
             status: "killed"
           } = Enum.find(tasks, &(&1.id == id1))

    assert %Persistence{
             id: ^id3,
             status: "running",
             run_count: 1
           } = Enum.find(tasks, &(&1.id == id3))

    assert %Persistence{
             id: ^id2,
             status: "queued",
             run_count: 0
           } = Enum.find(tasks, &(&1.id == id2))
  end
end

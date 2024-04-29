# Stage3Queue - Asynchronous Task Processing System

Stage3Queue designed for receiving tasks, enqueueing them, and processing those
in the background asynchronously. 
Each task can be a distinct background operation, such as sending an email, generating a report, or any CPU-bound job.

It provides:

  * Robust internal API
  * REST API for basic operations
  * New task definition is lean and straightforward
  * Priority-based task processing
  * Task concurrency limit per queue
  * Task retry mechanism in case of task failure
  * Dead-letter queue with failed tasks
  * Retries with backoff
  * Database persistence for tasks to survive during system restarts or crashes

## Setup

You can configure and run as many task processing queues. 
Since Stage3Queue is a regular `GenServer`, you may add those to the `Application` supervisor tree:

```elixir
    children = [
      .... 
      {Registry, keys: :unique, name: Stage3Queue.QueueRegistry},
      {Stage3Queue.Queue, topic: :default},
      {Stage3Queue.Queue, topic: :emails, max_concurrency: 100}
      {Stage3Queue.Queue, topic: :report, max_restarts: 10}
    ]
    opts = [strategy: :one_for_one, name: MyApp]
    Supervisor.start_link(children, opts)
```

The `topic` parameter is required in the `Queue` definition. Check [internals](#internals) section for more options. 

## Start and running

You may start the application with `iex -S mix phx.server` and fire commands from iex the console

Or use docker-compose if you don't want to bother with setting up an environment: `docker-compose up --build app`
And then use [REST interface](#REST_API)

## Elixir API

The high-level module `Stage3Queue.Broker` should be used to perform all the operations with task queuing. 

### Enqueuing a task

To add the task, call `Stage3Queue.Broker.enqueue`

```elixir
{:ok, task_id} = Broker.enqueue(:emails, "send emails", ["admin@example.com", [emails]], priority: 10)
```

Before running, the task is always put into the internal waiting queue (default size is 200 tasks in it).
Here. `:emails` is a queue name, `"send emails"` is a function name, `["admin@example.com", [email1, email2]]` the list of parameters.

By default, the `Stage3Queue.Dispatcher` dispatcher module is used to dispatch and start tasks.
For this particular case, you should define a `dispatch` function with `send emails` pattern:

```elixir
defmodule Stage3Queue.Dispatcher do
  def dispatch("send emails", from, emails) do
    # do task processing
    # and send emails
  end
```

More on dispatchers and priorities in [internals](#internals) section

### Checking task status

To get the task status, call `Stage3Queue.Broker.status`:

```elixir
status = Broker.status(task_id)
```

Possible statuses are:
  * `:queued` if the task is still in a queue waiting to be started
  * `:running` if it's running
  * `:in_dead_letter_queue` if task run but failed constantly, even after retries
  * `:finished` if finished correctly

### Aborting the task

To cancel task execution, call `Stage3Queue.Broker.abort`:

```elixir
Broker.abort(task_id)
```

It will move the task out of the queue if it's still in a waiting queue. Or will kill the running task.
Otherwise, if task is not found, `false` is returned and `abort` finishes safely.


### Auxiliary funcitons

To check whether task is running you may call `Stage3Queue.Broker.running?(task_id)`

To check whether task is still queued and not yet run `Stage3Queue.Broker.queued?(task_id)`

To check whether task is failed and in dead letter queue `Stage3Queue.Broker.in_dlq?(task_id)`


## REST API

Alongside with the Elixir API, you may use REST API to enqueue a task, check the status, or abort it.

To add a task, send `POST` request to the `/`:

```bash
curl --header "Content-Type: application/json" --request POST --data '{"topic":"default","function":"send emails","args":["admin@example.com", ["customer@example.com"]]}' http://localhost:4000
```
Here `topic`, `function` and `args` are required parameters and correspond to the appropriate Elixir API function.

In case of success, the result would look like this: `{"id":"a1c971ee-ce0e-4a06-9638-a339ddbd2b9e","status":"ok"}`
The failed result returns `error` status: `{"message":"Topic is not found","status":"error"}`


To check the task status, send `GET` request to `/<task_id>`:

```bash
curl --header "Content-Type: application/json" --request GET http://localhost:4000/a1c971ee-ce0e-4a06-9638-a339ddbd2b9e
```
The task status looks this way: `{"status":"running"}`


To abort the task, send `DELETE` request to `/<task_id>`:
```bash
curl --header "Content-Type: application/json" --request DELETE http://localhost:4000/7cd9f600-6eda-4d76-8811-122f8b1d08c0
```
The return result is `{"message":"Task aborted","status":"ok"}`


## Internals

### Queue internals

Queue holds all the tasks, which are scheduled to run, running, or failed to execute after configured amount of retries.
Also, it monitors the running tasks to know when one failed or finished successfully.

Queue is a `GenServer` but with `shutdown: :infinity` and `Process.flag(:trap_exit, true)`, which
lets it take care about running tasks when crash or exit happens.

Each queue has its own unique topic. So many Queues could be started simultaneously with different 
settings, in isolated environment. So one crash doesn't affect other queues.
To keep the `pid` of a queue, the Registry module is used. 
Queue's `pid` is stored under `queue_<topic>` name and could be easily retrieved later.

#### Enqueue 

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


#### Running the queue

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

     
#### Task end-of-life

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


#### Queue termination
When Queue process is terminated, Queue tries to `exit(:shutdown)` all running tasks. 
If after 1s the task process is not finished, it's gonna be killed `exit(:kill)`.

During the subsequent Queue restart, if persistence is turned on (see [Settings]), all scheduled tasks are loaded 
into the `task_queue` and Queue immediately continues task processing.
     
#### Settings:

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

#### Persistence:
If `persistent` setting is turned on, Queue tracks each `Task` in the database. It saves `priority`, `function_name`,
`args`, `start_at`, `run_count` and `status`. It's important to have `function_name` and values in `args` list which are JSON-encodable.
So no tuples, atoms or pids.
When persistence is off and DB is not used, those could be any values without limits.


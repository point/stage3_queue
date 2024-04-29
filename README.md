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
Here. `:emails` is a queue name, `"send emails"` is a function name, `["admin@example.com", [emails]]` the list of parameters.

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

To get the task status, call `Stage3Queue.Broker.enqueue`:

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

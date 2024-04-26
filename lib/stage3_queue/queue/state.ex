defmodule Stage3Queue.Queue.State do
  alias __MODULE__

  @enforce_keys [
    :topic,
    :max_concurrency,
    :max_queue_len,
    :task_queue,
    :run_queue,
    :max_restarts,
    :dead_letter_queue,
    :max_backoff,
    :persistent
  ]
  defstruct [
    :topic,
    :max_concurrency,
    :max_queue_len,
    :task_queue,
    :run_queue,
    :max_restarts,
    :dead_letter_queue,
    :max_backoff,
    :persistent
  ]

  def new(topic, params \\ []) do
    %State{
      topic: topic,
      max_concurrency: Keyword.fetch!(params, :max_concurrency),
      max_queue_len: Keyword.fetch!(params, :max_queue_len),
      max_restarts: Keyword.fetch!(params, :max_restarts),
      max_backoff: Keyword.fetch!(params, :max_backoff),
      persistent: Keyword.fetch!(params, :persistent),
      task_queue: %{},
      run_queue: [],
      dead_letter_queue: []
    }
  end
end

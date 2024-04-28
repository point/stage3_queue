defmodule Stage3QueueWeb.QueueController do
  use Stage3QueueWeb, :controller
  alias Stage3Queue.Broker

  def create(conn, %{"topic" => topic, "function" => function, "args" => args} = params) do
    opts =
      case Map.fetch(params, "priority") do
        {:ok, priority} -> [priority: priority]
        _ -> []
      end

    topic =
      try do
        String.to_existing_atom(topic)
      rescue
        ArgumentError -> nil
      end

    if topic do
      with {:ok, id} <- Broker.enqueue(topic, function, args, opts) do
        render(conn, :create, %{status: :ok, id: id})
      end
    else
      conn
      |> put_status(:bad_request)
      |> json(%{status: :error, message: "Topic is not found"})
    end
  end

  def status(conn, %{"id" => id}) do
    render(conn, :status, %{status: Broker.status(id)})
  end

  def abort(conn, %{"id" => id}) do
    render(conn, :abort, %{status: Broker.abort(id)})
  end
end

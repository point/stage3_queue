defmodule Stage3QueueWeb.QueueFallbackController do
  use Phoenix.Controller

  def call(conn, _) do
    conn
    |> put_status(:not_implemented)
  end
end

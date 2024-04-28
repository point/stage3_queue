defmodule Stage3QueueWeb.QueueJSON do
  def create(%{id: id, status: :ok}) do
    %{id: id, status: "ok"}
  end

  def status(%{status: status}) do
    %{status: status}
  end

  def abort(%{status: true}) do
    %{status: "ok", message: "Task aborted"}
  end

  def abort(%{status: false}) do
    %{status: "error", message: "Failed to abort task"}
  end
end

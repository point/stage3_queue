defmodule Stage3Queue.Repo do
  use Ecto.Repo,
    otp_app: :stage3_queue,
    adapter: Ecto.Adapters.SQLite3
end

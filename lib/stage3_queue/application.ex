defmodule Stage3Queue.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Stage3QueueWeb.Telemetry,
      Stage3Queue.Repo,
      {Ecto.Migrator,
       repos: Application.fetch_env!(:stage3_queue, :ecto_repos), skip: skip_migrations?()},
      # {DNSCluster, query: Application.get_env(:stage3_queue, :dns_cluster_query) || :ignore},
      # {Phoenix.PubSub, name: Stage3Queue.PubSub},
      # Start a worker by calling: Stage3Queue.Worker.start_link(arg)
      # {Stage3Queue.Worker, arg},
      # Start to serve requests, typically the last entry
      {Registry, keys: :unique, name: Stage3Queue.QueueRegistry},
      {Stage3Queue.Queue, topic: :default, max_concurrency: 1},
      Stage3QueueWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Stage3Queue.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    Stage3QueueWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations?() do
    # By default, sqlite migrations are run when using a release
    System.get_env("RELEASE_NAME") != nil
  end
end

defmodule Stage3QueueWeb.Router do
  use Stage3QueueWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", Stage3QueueWeb do
    pipe_through :api

    post "/", QueueController, :create
    get "/:id", QueueController, :status
    delete "/:id", QueueController, :abort
  end

  # Other scopes may use custom stacks.
  # scope "/api", Stage3QueueWeb do
  #   pipe_through :api
  # end
end

defmodule Stage3QueueWeb.Router do
  use Stage3QueueWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    # plug :fetch_live_flash
    # plug :put_root_layout, html: {Stage3QueueWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", Stage3QueueWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  # Other scopes may use custom stacks.
  # scope "/api", Stage3QueueWeb do
  #   pipe_through :api
  # end
end

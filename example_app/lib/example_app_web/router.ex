defmodule ExampleAppWeb.Router do
  use ExampleAppWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ExampleAppWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", ExampleAppWeb do
    pipe_through :browser

    get "/", PageController, :home
    get "/todos", TodoController, :index
    post "/todos", TodoController, :create
    post "/todos/:id/toggle", TodoController, :toggle
    delete "/todos/:id", TodoController, :delete
    get "/crash", TodoController, :crash
    get "/sentinel/status", TodoController, :sentinel_status
  end

  # Other scopes may use custom stacks.
  # scope "/api", ExampleAppWeb do
  #   pipe_through :api
  # end
end

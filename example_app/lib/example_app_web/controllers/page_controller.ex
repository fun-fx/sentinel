defmodule ExampleAppWeb.PageController do
  use ExampleAppWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end

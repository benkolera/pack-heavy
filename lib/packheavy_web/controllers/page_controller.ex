defmodule PackheavyWeb.PageController do
  use PackheavyWeb, :controller

  def home(conn, _params) do
    if conn.assigns[:current_user] do
      redirect(conn, to: ~p"/dashboard")
    else
      redirect(conn, to: ~p"/sign-in")
    end
  end
end

defmodule PackheavyWeb.BackupController do
  use PackheavyWeb, :controller

  alias Packheavy.Backup

  def export(conn, _params) do
    case conn.assigns[:current_user] do
      nil ->
        conn |> redirect(to: ~p"/sign-in") |> halt()

      user ->
        payload = Backup.export(user)
        body = Jason.encode!(payload, pretty: true)
        filename = "packheavy-backup-#{Date.utc_today()}.json"

        conn
        |> put_resp_content_type("application/json")
        |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
        |> send_resp(200, body)
    end
  end
end

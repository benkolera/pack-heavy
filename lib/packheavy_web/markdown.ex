defmodule PackheavyWeb.Markdown do
  @moduledoc """
  Trivial Earmark wrapper used to render free-form Markdown fields
  (currently `Trip.notes`). Inline raw HTML is escaped (Earmark default
  with `escape: true`) so a stray `<script>` in user input can't
  execute, while normal Markdown — links, lists, **bold**, etc. — passes
  through.
  """

  @doc """
  Render Markdown to a `Phoenix.HTML.safe()` value. Empty / nil input
  returns a safe empty string.
  """
  def render(nil), do: Phoenix.HTML.raw("")
  def render(""), do: Phoenix.HTML.raw("")

  def render(text) when is_binary(text) do
    {:ok, html, _warnings} =
      Earmark.as_html(text, escape: true, smartypants: false, breaks: true)

    Phoenix.HTML.raw(html)
  end
end

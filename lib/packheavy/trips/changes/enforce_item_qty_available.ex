defmodule Packheavy.Trips.Changes.EnforceItemQtyAvailable do
  @moduledoc """
  Validates that the requested qty for a trip item, plus the qty already
  reserved by *other* TripItem rows for the same item on the same trip,
  does not exceed `Item.qty` (units owned). Per-trip cap only — does not
  account for items reserved by other in-flight trips.
  """
  use Ash.Resource.Change

  require Ash.Query

  @impl true
  def change(changeset, _opts, _ctx) do
    Ash.Changeset.before_action(changeset, fn cs ->
      requested = Ash.Changeset.get_attribute(cs, :qty) || 1
      trip_id = Ash.Changeset.get_attribute(cs, :trip_id)
      item_id = Ash.Changeset.get_attribute(cs, :item_id)
      self_id = cs.data && cs.data.id

      cond do
        is_nil(trip_id) or is_nil(item_id) ->
          cs

        true ->
          item =
            Packheavy.Inventory.Item
            |> Ash.get!(item_id, authorize?: false)

          owned = item.qty || 0

          query =
            Packheavy.Trips.TripItem
            |> Ash.Query.filter(trip_id == ^trip_id and item_id == ^item_id)

          query =
            if self_id, do: Ash.Query.filter(query, id != ^self_id), else: query

          already_on_trip =
            query
            |> Ash.read!(authorize?: false)
            |> Enum.map(& &1.qty)
            |> Enum.sum()

          if requested + already_on_trip > owned do
            Ash.Changeset.add_error(cs,
              field: :qty,
              message:
                "exceeds available (#{owned} owned, #{already_on_trip} already on trip)"
            )
          else
            cs
          end
      end
    end)
  end
end

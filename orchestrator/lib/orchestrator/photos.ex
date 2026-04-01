defmodule Orchestrator.Photos do
  import Ecto.Query
  alias Orchestrator.Repo
  alias Orchestrator.Photos.Photo

  def create_photo(attrs) do
    %Photo{}
    |> Photo.changeset(attrs)
    |> Repo.insert()
  end

  def list_photos do
    Repo.all(from p in Photo, order_by: [desc: p.inserted_at])
  end

  def list_style_matches do
    Repo.all(from p in Photo, where: p.style_match == true, order_by: [desc: p.inserted_at])
  end

  def shortcode_exists?(shortcode) when is_binary(shortcode) do
    Repo.exists?(from p in Photo, where: p.instagram_shortcode == ^shortcode)
  end

  def shortcode_exists?(_), do: false
end

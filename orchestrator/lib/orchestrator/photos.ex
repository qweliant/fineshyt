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

  # Returns a MapSet of urls already in the DB for the given basenames.
  # Used to deduplicate local ingest batches across runs.
  def existing_basenames(basenames) do
    urls = Enum.map(basenames, &"/uploads/#{&1}")
    Repo.all(from p in Photo, where: p.url in ^urls, select: p.url)
    |> Enum.map(&Path.basename/1)
    |> MapSet.new()
  end

  def get_photo!(id), do: Repo.get!(Photo, id)

  def rate_photo(id, rating) do
    get_photo!(id)
    |> Photo.changeset(%{user_rating: rating})
    |> Repo.update()
  end

  def set_project(id, project) do
    get_photo!(id)
    |> Photo.changeset(%{project: project})
    |> Repo.update()
  end

  def override_curation(id, attrs) do
    get_photo!(id)
    |> Photo.changeset(attrs)
    |> Repo.update()
  end

  # Photos approved for blog export: rated >= 4 stars OR style_score >= 75.
  # Unrated photos are never included. Newer first.
  def list_approved do
    Repo.all(
      from p in Photo,
        where: not is_nil(p.user_rating) and (p.user_rating >= 4 or p.style_score >= 75),
        order_by: [desc: p.inserted_at]
    )
  end

  # Returns a map of %{tag => mean_rating} for all rated photos.
  # This is the user's learned preference profile.
  def tag_affinity_profile do
    rated = Repo.all(from p in Photo, where: not is_nil(p.user_rating), select: {p.suggested_tags, p.user_rating})

    rated
    |> Enum.flat_map(fn {tags, rating} -> Enum.map(tags, &{String.downcase(&1), rating}) end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {tag, ratings} -> {tag, Enum.sum(ratings) / length(ratings)} end)
  end

  # Computes a 0-100 vibe score for a photo against the affinity profile.
  # Falls back to the LLM style_score when no profile exists yet.
  def vibe_score(%Photo{suggested_tags: tags}, profile) when map_size(profile) == 0 do
    nil
  end

  def vibe_score(%Photo{suggested_tags: []}, _profile), do: nil

  def vibe_score(%Photo{suggested_tags: tags}, profile) do
    scores = tags
      |> Enum.map(&Map.get(profile, String.downcase(&1)))
      |> Enum.reject(&is_nil/1)

    if scores == [] do
      nil
    else
      mean = Enum.sum(scores) / length(scores)
      round((mean - 1) / 4 * 100)  # normalize 1-5 → 0-100
    end
  end
end

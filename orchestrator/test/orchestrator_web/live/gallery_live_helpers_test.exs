defmodule OrchestratorWeb.GalleryLiveHelpersTest do
  use ExUnit.Case, async: true

  alias Orchestrator.Photos.Photo
  alias OrchestratorWeb.GalleryLive

  defp photo(opts \\ []) do
    %Photo{
      id: opts[:id] || System.unique_integer([:positive]),
      file_path: opts[:file_path] || "/uploads/x.jpg",
      sharpness_score: opts[:sharpness_score],
      exposure_score: opts[:exposure_score],
      technical_score: opts[:technical_score],
      preference_score: opts[:preference_score],
      user_rating: opts[:user_rating]
    }
  end

  describe "survey_reason/2 — burst classification" do
    test "singleton group yields a CLEAR label" do
      assert %{type: :clear, label: "CLEAR PICK"} = GalleryLive.survey_reason(:burst, [photo()])
    end

    test "≥30 sharpness lead is a CLEAR PICK" do
      [keeper, runner] = [photo(sharpness_score: 95), photo(sharpness_score: 50)]
      r = GalleryLive.survey_reason(:burst, [keeper, runner])
      assert r.type == :clear
      assert r.text =~ "95 vs next-best 50"
    end

    test "tied sharpness + better exposure is a TIE-BREAK" do
      [keeper, runner] =
        [
          photo(sharpness_score: 100, exposure_score: 88),
          photo(sharpness_score: 100, exposure_score: 71)
        ]

      r = GalleryLive.survey_reason(:burst, [keeper, runner])
      assert r.type == :tie
      assert r.text =~ "Sharpness tied at 100"
      assert r.text =~ "88 vs 71"
    end

    test "1–6 sharpness gap is a CLOSE CALL" do
      [keeper, runner] = [photo(sharpness_score: 14), photo(sharpness_score: 10)]
      r = GalleryLive.survey_reason(:burst, [keeper, runner])
      assert r.type == :close
      assert r.text =~ "14 vs 10"
    end

    test "sharp+expo tied falls back to preference TIE-BREAK" do
      keeper = photo(sharpness_score: 100, exposure_score: 100, preference_score: 69)
      runner = photo(sharpness_score: 100, exposure_score: 100, preference_score: 60)
      r = GalleryLive.survey_reason(:burst, [keeper, runner])
      assert r.type == :tie
      assert r.text =~ "Sharp/Expo tied"
      assert r.text =~ "69 vs 60"
    end

    test "all scores tied → tie-break by ordering" do
      keeper = photo(sharpness_score: 80, exposure_score: 80, technical_score: 80, preference_score: 50)
      runner = photo(sharpness_score: 80, exposure_score: 80, technical_score: 80, preference_score: 50)
      r = GalleryLive.survey_reason(:burst, [keeper, runner])
      assert r.type == :tie
      assert r.text =~ "All scores tied"
    end

    test "missing scores falls through to the generic CLEAR label" do
      [keeper, runner] = [photo(), photo()]
      r = GalleryLive.survey_reason(:burst, [keeper, runner])
      assert r.type == :clear
    end
  end

  describe "survey_reason/2 — copy classification" do
    test "single duplicate uses singular wording" do
      r = GalleryLive.survey_reason(:copy, [photo(), photo()])
      assert r.type == :original
      assert r.text =~ "the other is a duplicate"
    end

    test "multiple duplicates use plural wording" do
      r = GalleryLive.survey_reason(:copy, [photo(), photo(), photo()])
      assert r.type == :original
      assert r.text =~ "the others are duplicates"
    end
  end

  describe "metric_leaders/1" do
    test "picks the unique top scorer for each metric" do
      p1 = photo(sharpness_score: 80, exposure_score: 60, technical_score: 70, preference_score: 50)
      p2 = photo(sharpness_score: 70, exposure_score: 90, technical_score: 75, preference_score: 50)
      p3 = photo(sharpness_score: 60, exposure_score: 50, technical_score: 65, preference_score: 80)

      assert %{sharp: 0, exp: 1, tech: 1, pref: 2} = GalleryLive.metric_leaders([p1, p2, p3])
    end

    test "ties on the high score return -1 for that metric" do
      p1 = photo(sharpness_score: 100, exposure_score: 50)
      p2 = photo(sharpness_score: 100, exposure_score: 80)
      assert %{sharp: -1, exp: 1} = GalleryLive.metric_leaders([p1, p2])
    end

    test "all-nil metric returns -1" do
      assert %{sharp: -1} = GalleryLive.metric_leaders([photo(), photo()])
    end
  end

  describe "copy_tag/1" do
    test "no copy suffix is original" do
      assert GalleryLive.copy_tag("/a/b/IMG_001.jpg") == "original"
    end

    test "macOS \"X copy.jpg\" pattern" do
      assert GalleryLive.copy_tag("/a/000366490014 copy.jpg") == "copy"
    end

    test "macOS \"X copy 2.jpg\" pattern" do
      assert GalleryLive.copy_tag("/a/000366490014 copy 2.jpg") == "copy"
    end

    test "browser-style \"X (1).jpg\" emits the index" do
      assert GalleryLive.copy_tag("/a/Untitled (3).jpg") == "(3)"
    end
  end

  describe "grid_template/2" do
    test "n<=3 uses even columns" do
      assert GalleryLive.grid_template(1, false) =~ "repeat(1, minmax(0, 1fr))"
      assert GalleryLive.grid_template(2, false) =~ "repeat(2, minmax(0, 1fr))"
      assert GalleryLive.grid_template(3, false) =~ "repeat(3, minmax(0, 1fr))"
    end

    test "overflow appends a narrower MoreCell column" do
      assert GalleryLive.grid_template(6, true) =~ "0.66fr"
    end
  end
end

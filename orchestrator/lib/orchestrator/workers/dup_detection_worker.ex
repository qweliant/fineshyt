defmodule Orchestrator.Workers.DupDetectionWorker do
  @moduledoc """
  Oban worker that scans the whole photo library, groups photos whose
  filenames collapse onto the same canonical stem (macOS-style copies:
  `X copy.jpg`, `X copy 2.jpg`, `X (1).jpg`, …), and writes a per-group
  integer into the `dup_group` column.

  Pure DB + string-normalisation — no ML, no LLM call. Triggered from
  the gallery's "Copies" tab and broadcasts `{:dup_detection_complete,
  n_groups}` so the LiveView refreshes.

  See `Orchestrator.Photos.detect_and_assign_dup_groups/0` for the actual
  grouping/keeper logic; this worker just owns the lifecycle.
  """

  use Oban.Worker, queue: :preference, max_attempts: 3

  require Logger

  @impl Oban.Worker
  def perform(_job) do
    Logger.info("DupDetectionWorker: scanning for filename copies...")
    {n_groups, n_extras} = Orchestrator.Photos.detect_and_assign_dup_groups()

    Logger.info(
      "DupDetectionWorker: #{n_groups} group(s), #{n_extras} extra copies"
    )

    Phoenix.PubSub.broadcast(
      Orchestrator.PubSub,
      "photo_updates",
      {:dup_detection_complete, n_groups}
    )

    :ok
  end
end

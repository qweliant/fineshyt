"""Burst / sequence detection — CLIP cosine similarity + temporal proximity."""

from collections import defaultdict
from datetime import datetime

import numpy as np

from fineshyt_ai.config import logger
from fineshyt_ai.schemas.burst import BurstDetectRequest, BurstDetectResponse, BurstGroup


def detect_bursts(request: BurstDetectRequest) -> BurstDetectResponse:
    """Group visually similar + temporally close photos, pick the sharpest per group.

    Embeddings are assumed L2-normalized so `X @ X.T` is cosine similarity.
    A pair is an edge iff `cos >= similarity_threshold` AND (both have
    timestamps within `max_time_gap_seconds` OR at least one is missing
    a timestamp). The union-find is delegated to scipy.
    """
    if len(request.photos) < 2:
        return BurstDetectResponse(groups=[], n_singletons=len(request.photos))

    from scipy.sparse import csr_matrix
    from scipy.sparse.csgraph import connected_components

    ids = [p.id for p in request.photos]
    sharpness = {p.id: p.sharpness_score for p in request.photos}
    X = np.asarray([p.embedding for p in request.photos], dtype=np.float32)

    timestamps: list[datetime | None] = []
    for p in request.photos:
        if p.captured_at:
            try:
                timestamps.append(datetime.fromisoformat(p.captured_at))
            except ValueError:
                timestamps.append(None)
        else:
            timestamps.append(None)

    # Cosine similarity (X is already L2-normalized upstream).
    S = X @ X.T
    np.fill_diagonal(S, 0.0)

    visual_adj = S >= request.similarity_threshold

    n = len(request.photos)
    temporal_adj = np.ones((n, n), dtype=bool)
    max_gap = request.max_time_gap_seconds
    for i in range(n):
        if timestamps[i] is None:
            continue
        for j in range(i + 1, n):
            if timestamps[j] is None:
                continue
            gap = abs((timestamps[i] - timestamps[j]).total_seconds())
            if gap > max_gap:
                temporal_adj[i, j] = False
                temporal_adj[j, i] = False

    adj = csr_matrix(visual_adj & temporal_adj)
    _n_components, labels = connected_components(adj, directed=False)

    groups_map: dict[int, list[int]] = defaultdict(list)
    for idx, label in enumerate(labels):
        groups_map[int(label)].append(ids[idx])

    burst_groups: list[BurstGroup] = []
    group_id = 0
    for _label, member_ids in sorted(groups_map.items()):
        if len(member_ids) < 2:
            continue
        best_id = max(member_ids, key=lambda pid: sharpness.get(pid, 0))
        burst_groups.append(BurstGroup(
            group_id=group_id,
            photo_ids=member_ids,
            best_pick_id=best_id,
            best_pick_sharpness=sharpness.get(best_id, 0),
            size=len(member_ids),
        ))
        group_id += 1

    n_singletons = sum(1 for member_ids in groups_map.values() if len(member_ids) == 1)

    logger.info(
        "Burst detection: %d photos → %d bursts (%d photos in bursts), %d singletons",
        len(request.photos), len(burst_groups),
        sum(g.size for g in burst_groups), n_singletons,
    )
    return BurstDetectResponse(groups=burst_groups, n_singletons=n_singletons)

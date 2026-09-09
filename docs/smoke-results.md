# Phase 0 Smoke Results: mineflayer × Cuberite

> Date: 2026-09-06 | Server: Cuberite (port 25568, offline mode) | mineflayer 4.38.0 / minecraft-protocol 1.68.0 / prismarine-chunk 1.41.0 / Node v22.22.3
> Script: `bot/smoke.js` (rerunnable; `--stay` mode combined with an external lava kill for the death-gate verification)
> **Conclusion: all hard gates passed, moving to Phase 1.** Bot version pinned to **1.8.9** (or auto-detected); 1.12.2 has a chunk data compatibility issue (see §4) that does not block the migration.

## 1. Version Matrix Overview

All checks were run against both protocol versions (1.8.9, 1.12.2) and auto-detection:

## 2. Death & Respawn Gate

External lava kill; control group in docs/baseline-mcc-tools.md §4. Verified on both versions — the bot stood on solid-block ground with lava placed at its feet:

- 1.8.9 (SmokeBot_9420): health 20→16→12→8→4→0 → `[DEATH] was melted by lava` → `death` event → **`respawn` packet** → server-side confirmation of respawn at the spawn point (100,70,1), health=20, **no void fall**.
- 1.12.2 (SmokeBot_1742): same flow, respawned at (100,70,1), health=20, **no void fall**.

**Comparison with MCC**: this run's MCC control also auto-respawned normally (no void fall); MCC's void fall is its occasional state corruption (reproduced once at session start; needs a fresh identity and restart). The mineflayer state machine is clean — death → respawn carries no historical baggage — **better than MCC**.

## 3. /kill Permission Notes

The default group lacks `/kill` and `/time` permissions (`[INFO] Forbidden command; insufficient privileges: "/kill"`). The smoke script instead uses `/help` (executable by default players) to verify the command pipeline; the death gate instead uses server-side placed lava (the same method as the MCC control).

## 4. 1.12.2 Chunk Data Compatibility Issue

Root cause located, non-blocking.

Symptoms: under a 1.12.2 connection prismarine-chunk fails to parse (`varint is too big`), `blockAt` returns air, right-click reads air, and walking may fall into holes.

Root cause (confirmed by testing):

1. **Network layer**: Cuberite sends zlib-stream-compressed packets ending with Z_SYNC_FLUSH; `minecraft-protocol`'s `Decompressor` calls `zlib.unzipSync(payload, { finishFlush: 2 })`, which **throws and drops the packet** for that stream; removing that option decompresses fully and successfully (64807 bytes). → This is a `minecraft-protocol` compatibility issue with streams that do not end with Z_FINISH.
2. **Inside the packet**: map_chunk's data field is a `[varint length][zlib]` pre-compressed whole-chunk blob (`a7 fa 03 78 9c…`, decompressing yields 64807 bytes), and the decompressed inner structure is **not** the standard 1.9+ palette chunk format (prismarine still reports a varint error) — i.e. Cuberite uses a private serialization for 1.9+ chunks. A full fix requires reverse-engineering Cuberite's chunk encoding (far more effort than benefit).

Resolution: **bot pinned to 1.8.9** (Cuberite adapts the protocol per client; 1.8.9 has none of this problem, block data is fully functional, and it can coexist with MCC's 1.12.2 connection). A 1.12.2 fix is left for later (a prismarine compatibility layer or Cuberite-side configuration are possible options).

## 5. Phase 0 Acceptance

- [x] `bot/` directory ready, mineflayer 4.38.0 installed successfully (npm cache used `--cache ../.npmcache`)
- [x] 1.8.9: all items PASS (including the death gate)
- [x] 1.12.2: non-chunk items PASS (including the death gate); chunk items limited, root cause recorded
- [x] Auto-detection works (≈1.12.2 or the adapted version; behaved normally during the smoke run)
- [x] Conclusion: **all PASS (stop-loss conditions not triggered), moving to Phase 1**
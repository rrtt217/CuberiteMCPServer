# mineflayer Version Compatibility: 1.9 - 1.12.2 × Cuberite (fixed)

> Updated: 2026-09-07 (previous conclusion in git history; the old claim that 1.9+ was hopeless was disproven by measurement)
> Server: Cuberite master #445 (README claims 1.8 - 1.12) | port 25568, offline mode
> Client libs: mineflayer 4.38.0 / minecraft-protocol 1.68.0 / prismarine-chunk 1.41.0 / Node v22.22.3

## Conclusion (measured after the 2026-09-07 fix)

**The whole 1.9 - 1.12.2 range (protocols 107/109/110/210/315/316/340) is now fully compatible; pinning the bot to 1.12.2 is recommended.**
The former 'chunk data varint is too big' root cause was **a parsing bug inside prismarine-chunk itself** (details below) — unrelated to Cuberite's Zlib or private serialization. The fix is bot/patches/prismarine-chunk+1.41.0.patch (patch-package, applied automatically via postinstall on npm install).

## Verified matrix after fix (bot/smoke.js <version>)

| Version | Proto | Login | Chat/cmd | Move | Jump(ground) | Chunk data | Right-click target |
|---|---|---|---|---|---|---|---|
| 1.8.9 | 47 | PASS | PASS | PASS 1.20 | PASS y68->68 | PASS | PASS stone |
| 1.9 | 107 | PASS | PASS | PASS 1.20 | PASS | PASS | PASS stone |
| 1.9.2 | 109 | PASS | PASS | PASS 1.20 | PASS | PASS | PASS stone |
| 1.9.4 | 110 | PASS | PASS | PASS 1.20 | PASS | PASS | PASS stone |
| 1.10 / 1.10.2 | 210 | PASS | PASS | PASS 1.20 | PASS | PASS | PASS stone |
| 1.11 / 1.11.2 | 315 / 316 | PASS | PASS | PASS 1.20 | PASS | PASS | PASS stone |
| **1.12.2 (recommended)** | 340 | PASS | PASS | PASS 1.20 | PASS | PASS | PASS stone |

Re-test highlights: no chunk errors across 8 versions, walking no longer falls through blocks (moved 1.20 blocks = normal ground-hugging value), right-click blockAt returns stone (was all-air before the fix), jump Y stays rock steady.

## The real root cause (verified byte-by-byte against Cuberite source)

1. Pull cuberite/cuberite src/Protocol to confirm:
   - ChunkDataSerializer.cpp folds protocol versions to v47 (1.8), v107 (1.9), v110 (1.9.4, also used for 1.10/1.11/1.12).
   - Serialize107/110 output 1.9+ chunks in **fully standard vanilla format**: per section BitsPerEntry=13 (global palette) + Palette length 0 + DataArray length 832 longs + 13-bit block data + 2048 block light + 2048 sky light (overworld), then 256 bytes of biome data.
   - Packet-level compression (CompressPacket, CircularBufferCompressor with libdeflate zlib) is also standard.
2. Captured packets (packet.chunkData):
   - The 1.9 data header is 0d 00 c0 06 ... = bits=13 / palette length 0 / data length 832, total 64792 = 6x10756 + 256, exactly matching Serialize110's math; **the data itself is standard, already-decompressed data**.
   - The earlier 'Z_SYNC_FLUSH / Zlib compatibility issue' attribution was a misdiagnosis (transport decompression was always fine).
3. The bug in prismarine-chunk pc/1.9/ChunkColumn.js load():
   - It sizes the block-data BitArray with this.maxBitsPerBlock (derived from minecraft-data's maxStateId); local minecraft-data 1.9-1.12 reports maxStateId=4095 → neededBits=12 → BitArray.data.length=1536.
   - The wire DataArrayLength=832 longs → load passes readBuffer(reader, 832*2=1664).
   - BitArray.readBuffer **returns immediately without consuming a byte** when size(1664) !== this.data.length(1536); the cursor stops after the data-length field → every later read desyncs → the next section reads garbage (bits<=8 enters the palette branch) → varint is too big.
   - The upstream ChunkSection.js itself defines GLOBAL_BITS_PER_BLOCK = 13, matching the wire's 13 bits; so the correct fix is to **use the wire bitsPerBlock (13)** instead of maxBitsPerBlock (12).
   - Vanilla servers are rarely affected because most sections use 4-8 bit local palettes and 13-bit global sections are rare; Cuberite always sends 13-bit global sections, so it triggers 100% of the time.

## The fix (patch-package)

- bot/patches/prismarine-chunk+1.41.0.patch: in ChunkColumn.load, bitsPerValue changed from the conditional to bitsPerBlock (one line, plus 8 comment lines).
- bot/package.json adds postinstall: patch-package so every npm install applies it automatically.
- Regenerate: cd bot && npx patch-package prismarine-chunk (add npm_config_cache=<workspace>/.npmcache if the sandbox refuses to write the npm cache).
- If prismarine-chunk is upgraded later, regenerate the patch with the new version number.

## Version recommendation

- config.ini [Bot] MinecraftVersion and bot/bot.ini Version are set to **1.12.2** (Cuberite's protocol ceiling; the 1.12 item set includes shields/elytra/observers and all 1.9+ content).
- Measured: on 1.12.2, give shield(442)/elytra(443)/observer(218) all enter inventory and are queryable; mcc_select_item equips, container open/deposit/withdraw all work.
- Do not attempt 1.13+ (Cuberite's protocol goes up to 1.12.2 only; the 1.13/1.14 entries under Protocol/ are just data files — the client protocol is not enabled).

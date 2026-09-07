# mineflayer 版本兼容：1.9 - 1.12.2 与 Cuberite（已修复）

> 更新时间：2026-09-07（修正前结论见 git 历史；旧版认为 1.9+ 无解，已被实测推翻）
> 服务器：Cuberite master #445（README 声称兼容 1.8 - 1.12）| 端口 25568，离线模式
> 客户端库：mineflayer 4.38.0 / minecraft-protocol 1.68.0 / prismarine-chunk 1.41.0 / Node v22.22.3

## 结论（2026-09-07 修复后实测）

**1.9 - 1.12.2 全段（协议 107/109/110/210/315/316/340）现已全部兼容，推荐 bot 固定 1.12.2。**
此前"区块数据 varint is too big"的根因是 **prismarine-chunk 自身的一个解析 bug**（详见下），
与 Cuberite 的 Zlib、私有序列化无关。修复方式是 bot/patches/prismarine-chunk+1.41.0.patch
（patch-package，npm install 时经 postinstall 自动应用）。

## 修复后实测矩阵（bot/smoke.js <version>）

| 版本 | 协议 | 登录/spawn | 聊天/命令 | 移动 | 跳跃(地面) | 区块数据 | 右键目标块 |
|---|---|---|---|---|---|---|---|
| 1.8.9 | 47 | PASS | PASS | PASS 1.20格 | PASS y68->68 | PASS | PASS stone |
| 1.9 | 107 | PASS | PASS | PASS 1.20格 | PASS | PASS | PASS stone |
| 1.9.2 | 109 | PASS | PASS | PASS 1.20格 | PASS | PASS | PASS stone |
| 1.9.4 | 110 | PASS | PASS | PASS 1.20格 | PASS | PASS | PASS stone |
| 1.10 / 1.10.2 | 210 | PASS | PASS | PASS 1.20格 | PASS | PASS | PASS stone |
| 1.11 / 1.11.2 | 315 / 316 | PASS | PASS | PASS 1.20格 | PASS | PASS | PASS stone |
| **1.12.2（推荐）** | 340 | PASS | PASS | PASS 1.20格 | PASS | PASS | PASS stone |

复测要点：8 个版本无 chunk error、行走不再穿空（moved 1.20 格 = 贴地正常值）、
右键 blockAt 返回 stone（修复前全为 air）、跳跃 y 纹丝不动。

## 真正的根因（对照 Cuberite 源码逐字节验证）

1. 拉取 cuberite/cuberite 的 src/Protocol 确认：
   - ChunkDataSerializer.cpp：协议版本折叠为 v47（1.8）、v107（1.9）、v110（1.9.4，同时用于 1.10/1.11/1.12）
   - Serialize107/110 输出的 1.9+ 区块是**完全标准的 vanilla 格式**：每 section 写
     BitsPerEntry=13（全局调色板）+ Palette长度=0 + DataArray长度=832 longs + 13bit 块数据
     + 2048 方块光 + 2048 天空光（主世界），最后 256 字节生物群系。
   - 包级压缩 CompressPacket 与 CircularBufferCompressor（libdeflate zlib）同样是标准实现。
2. 抓包实测（packet.chunkData）：
   - 1.9 的 data 头为 0d 00 c0 06 ... = bits=13 / 调色板长度 0 / 数据长度 832，长度 64792 =
     6x10756 + 256，与 Serialize110 的计算完全一致；**数据本身就是解压后的标准数据**。
   - 之前的 "Z_SYNC_FLUSH / Zlib 兼容问题" 归因是误判（传输层解压一直正常）。
3. prismarine-chunk pc/1.9/ChunkColumn.js load() 的 bug：
   - 它用 this.maxBitsPerBlock（由 minecraft-data 的 maxStateId 推导）构造块数据 BitArray；
     而本机 minecraft-data 1.9-1.12 报 maxStateId=4095 → neededBits=12 → BitArray.data.length=1536。
   - 协议里 DataArrayLength=832 longs → load 传 readBuffer(reader, 832*2=1664)。
   - BitArray.readBuffer 发现 size(1664) !== this.data.length(1536) 时**直接 return，一个字节都不读**，
     游标停在数据长度字段后 → 后续所有读取错位 → 下一个 section 读到垃圾字节（bits<=8 走入调色板分支）
     → varint is too big。
   - 官方仓库 ChunkSection.js 自己就定义了 GLOBAL_BITS_PER_BLOCK = 13，与 wires 的 13 位一致；
     所以正确做法是**直接用 wire 的 bitsPerBlock**（13），而不是 maxBitsPerBlock（12）。
   - 对 vanilla 服务器影响小，是因为 vanilla 大多数 section 用 4-8 位局部调色板，13 位全局段不常见；
     Cuberite 一律发 13 位全局段，于是 100% 触发。

## 修复内容（patch-package）

- bot/patches/prismarine-chunk+1.41.0.patch：ChunkColumn.load 中
  bitsPerValue: bitsPerBlock > MAX_BITS_PER_BLOCK ? this.maxBitsPerBlock : bitsPerBlock
  改为 bitsPerValue: bitsPerBlock（一行，另加 8 行注释）。
- bot/package.json 增加 "postinstall": "patch-package"，任何 npm install 后自动应用。
- 重新生成补丁：cd bot && npx patch-package prismarine-chunk（若沙盒拒绝写 npm 缓存，
  加 npm_config_cache=<workspace>/.npmcache）。
- 若后续升级 prismarine-chunk，需按新版本号重新生成并更新 patch 文件。

## 版本选择建议

- config.ini [Bot] MinecraftVersion 与 bot/bot.ini Version 已设为 **1.12.2**
  （Cuberite 支持的协议上限；1.12 物品表含盾牌/鞘翅/侦测器等全部 1.9+ 内容）。
- 实测：1.12.2 下 give 盾牌(442)/鞘翅(443)/侦测器(218) 均可入背包并查询，
  mcc_select_item 装备、容器开箱/存取均正常。
- 不要尝试 1.13+（Cuberite 只收到 1.12.2；Protocol/ 里的 1.13/1.14 仅数据文件，客户端协议未开放）。


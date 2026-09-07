# mineflayer 版本兼容矩阵：1.9 – 1.11 与 Cuberite

> 日期：2026-09-07 | 服务器：Cuberite master #445（README 声称兼容 1.8 – 1.12）| 端口 25568，离线模式
> 客户端库：mineflayer 4.38.0 / minecraft-protocol 1.68.0 / prismarine-chunk 1.41.0 / Node v22.22.3
> 方法：bot/smoke.js <version>（独立连接，与运行中的 TestBot 互不干扰），每个协议号各实跑一次。

## 结论

**1.9 – 1.11 整段（协议 107/109/110/210/315/316）均与 Cuberite 不兼容。**
所有版本都能通过握手、登录、聊天、命令、物品栏，但**区块数据全部解析失败**
（varint is too big @ prismarine-chunk/src/pc/1.9/ChunkColumn.js:218），导致：
- blockAt 全返回 air（右键读不到方块、mcc_world_block_at 同样失效）
- 地面"不存在"，bot 行走时直接穿进地面掉坑（本次冒烟被 void_guard 两次救援，无坠虚空损失）
- 任何依赖方块/地形的能力（寻路、放置、挖掘、交互）不可用

**唯一兼容档位是 1.8.x（协议 47，实测 1.8.9）——保持现状，不要改。**

## 版本矩阵

| 版本 (mineflayer version) | 协议 | 登录+spawn | 聊天 | /help | 移动 | 跳跃(地面) | 区块数据 | 右键目标块 |
|---|---|---|---|---|---|---|---|---|
| **1.8.9** | 47 | PASS 71ms | PASS | PASS | PASS 1.20格 | PASS y68->68 | PASS 完整 | PASS **stone** |
| 1.9 | 107 | PASS 94ms | PASS | PASS | PASS 4.89 | FAIL y74->69.9 下坠 | FAIL varint is too big | FAIL air |
| 1.9.2 | 109 | PASS 114ms | PASS | PASS | PASS 4.89 | FAIL y74->69.2 | FAIL 同左 | FAIL air |
| 1.9.4 | 110 | PASS 131ms | PASS | PASS | PASS 4.89 | FAIL y74->69.2 | FAIL 同左 | FAIL air |
| 1.10 | 210 | PASS 91ms | PASS | PASS | PASS 4.87 | FAIL y74->69.2 | FAIL 同左 | FAIL air |
| 1.10.2 | 210 | PASS 113ms | PASS | PASS | PASS 4.89 | FAIL y74->69.9 | FAIL 同左 | FAIL air |
| 1.11 | 315 | PASS 106ms | PASS | PASS | PASS 4.89 | FAIL y74->69.9 | FAIL 同左 | FAIL air |
| 1.11.2 | 316 | PASS 93ms | PASS | PASS | PASS 4.87 | FAIL y74->69.2 | FAIL 同左 | FAIL air |
| 1.12.2 | 340 | PASS 109ms | PASS | PASS | PASS 4.87 | FAIL y74->70.7 | FAIL 同左 | FAIL air |

> 空格注释：1.9+ 全部伴随 "Ignoring block entities as chunk failed to load"。
> "跳跃"列的真值是**地面完整性**：1.8.9 跳跃 y 纹丝不动（实体地面）；
> 其余版本同一步骤 y 掉 4–5 格，即 bot 站在服务器把持的"看不见的地面"上，客户端侧判定穿空。
> 服务器视图中 1.9 段 bot 被 [VoidGuard] rescued ... from void fall (y=38.4) 救援（见 MCPServer 日志）。

## 根因辨析（本日补测，纠正 Phase 0 的模糊归因）

Phase 0（docs/smoke-results.md §4）曾把 1.12.2 的失败归因成两层：
网络层 Z_SYNC_FLUSH 终止的 zlib 流 + 包内层私有序列化。本日针对 1.9 段做了对照实验：

1. 临时把 node_modules/minecraft-protocol/src/transforms/compression.js 的
   zlib.unzipSync(buf, { finishFlush: 2 }) 改为默认参数（使 Z_SYNC_FLUSH 流可完整解压），
   重测 1.9 与 1.11.2 —— **失败完全相同**（仍是 ChunkColumn.load 的 varint 错）。
2. 结论：**传输层的 finishFlush 兼容问题不是 1.9 段的拦路虎**（至少不是导致 varint 错的原因；
   它可能只在特定超大包上触发）。真正不可逾越的是**包内层**：Cuberite 面向 1.9+ 客户端发送的
   map_chunk 负载（[varint 长度][zlib 预压缩 blob]，解压后为非标准结构）与
   prismarine-chunk 的 1.9 palette 格式不匹配。想修复只能逆向 Cuberite 的 1.9+ 区块编码
   （Protocol/1.12.2、1.13、1.14.4 只有数据文件，源码未随发行版带）——投入远大于收益。
3. 因此**没有任何 1.9 – 1.11 的 mineflayer 配置组合（版本串、换旧版 nmp）能换来可用性**；
   "换 nmp 版本"的诉求可以关掉。1.8.9 之所以完美，是因为 Cuberite 对 1.8 客户端
   （协议 47）走原始 §8 区块格式（无 palette），与 prismarine-chunk 的 1.8 解码器严格对应。

## 操作建议

- config.ini [Bot] MinecraftVersion 与 bot/bot.ini Version 保持 **1.8.9**，勿误改成 1.9+。
- 若日后需要更高协议特性（如 1.12 的物品 ID/槽位布局），唯一正路是服务端升级到
  支持相应协议的标准实现（非本 Cuberite 构建），或为 prismarine-chunk 编写 Cuberite 私有格式
  的自定义 ChunkColumn（工作量以天计）。
- 冒烟期间依赖 void_guard.lua 兜底（本次救回 SmokeBot_2552 / SmokeBot_7504），该守卫保持启用。


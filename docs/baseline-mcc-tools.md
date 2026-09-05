# MCC 工具基线（迁移对照快照）

> **来源**：2026-09-06 从运行中的 MCC（v26.2, build 507, MC 1.12.2 / protocol 340）的嵌入式 MCP 端点 `http://127.0.0.1:33333/mcp` 直接捕获。
> 捕获脚本：`docs/capture-baseline.mjs`（可复跑）。本文档是 §5 的交付物，Phase 1 的 mineflayer bot 工具名/参数/返回文本以此为准对齐。
> **会话与响应格式**：MCC 返回 SSE 帧（`event: message\ndata: {...}`）+ 跟踪 `mcp-session-id`——这正是不兼容 preset 桥（`mcp-mcc.mjs` 用 `JSON.parse`）的原因。mineflayer 端点应返回**纯 JSON** 且无状态。

## 1. 工具总数与命名

- 工具总数：**62**，全部以 `mcc_` 前缀命名，注册为会话工具 `mcp__mcc__<name>`。
- 返回形状统一：`content[0].text` 为 JSON 字符串 `{"success":true,"data":{...}}` 或 `{"success":false,"errorCode":"..."}`。
- 采样基线见 §3；死亡基线见 §4。

## 2. 完整工具面（名称 + inputSchema）

### SessionStatus (6 个)

**`mcc_session_status`** — Get current MCC session and feature status.
```json
{
  "type": "object",
  "properties": {}
}
```

**`mcc_server_info`** — Get active MCC server connection info and current TPS.
```json
{
  "type": "object",
  "properties": {}
}
```

**`mcc_world_state`** — Get current world state, chunk loading progress, and last observed runtime time/weather values.
```json
{
  "type": "object",
  "properties": {}
}
```

**`mcc_chunk_status`** — Get chunk loading status for the player location or an explicit world coordinate.
```json
{
  "type": "object",
  "properties": {
    "x": {
      "type": [
        "number",
        "null"
      ],
      "default": null
    },
    "y": {
      "type": [
        "number",
        "null"
      ],
      "default": null
    },
    "z": {
      "type": [
        "number",
        "null"
      ],
      "default": null
    }
  }
}
```

**`mcc_loaded_bots`** — List currently loaded MCC bots and scripts.
```json
{
  "type": "object",
  "properties": {}
}
```

**`mcc_recent_events`** — Get recent high-signal MCP runtime events after a given event ID.
```json
{
  "type": "object",
  "properties": {
    "afterId": {
      "type": "integer",
      "default": 0
    },
    "maxCount": {
      "type": "integer",
      "default": 50
    },
    "typeFilter": {
      "type": [
        "string",
        "null"
      ],
      "default": null
    }
  }
}
```

### ChatAndCommands (6 个)

**`mcc_send_chat`** — Send chat text or slash-command to the connected Minecraft server.
```json
{
  "type": "object",
  "properties": {
    "text": {
      "description": "Text to send to server chat.",
      "type": "string"
    }
  },
  "required": [
    "text"
  ]
}
```

**`mcc_chat_history`** — Get recent chat/system lines seen by MCC.
```json
{
  "type": "object",
  "properties": {
    "maxCount": {
      "type": "integer",
      "default": 50
    },
    "includeJson": {
      "type": "boolean",
      "default": false
    }
  }
}
```

**`mcc_run_internal_command`** — Run an internal MCC command.
```json
{
  "type": "object",
  "properties": {
    "command": {
      "description": "MCC command line without leading slash.",
      "type": "string"
    }
  },
  "required": [
    "command"
  ]
}
```

**`mcc_internal_commands_list`** — List available MCC internal commands with usage and description.
```json
{
  "type": "object",
  "properties": {}
}
```

**`mcc_quit_client`** — Quit MCC client process cleanly.
```json
{
  "type": "object",
  "properties": {}
}
```

**`mcc_disconnect`** — Disconnect MCC from the current server without quitting the process.
```json
{
  "type": "object",
  "properties": {}
}
```

### Movement (12 个)

**`mcc_move_to`** — Request movement/pathing to a world coordinate and verify arrival.
```json
{
  "type": "object",
  "properties": {
    "x": {
      "type": "number"
    },
    "y": {
      "type": "number"
    },
    "z": {
      "type": "number"
    },
    "allowUnsafe": {
      "type": "boolean",
      "default": false
    },
    "allowDirectTeleport": {
      "type": "boolean",
      "default": false
    },
    "maxOffset": {
      "type": "integer",
      "default": 0
    },
    "minOffset": {
      "type": "integer",
      "default": 0
    },
    "timeoutMs": {
      "type": "integer",
      "default": 0
    }
  },
  "required": [
    "x",
    "y",
    "z"
  ]
}
```

**`mcc_move_to_player`** — Locate a tracked player entity, request movement/pathing, and verify arrival.
```json
{
  "type": "object",
  "properties": {
    "playerName": {
      "type": "string"
    },
    "allowUnsafe": {
      "type": "boolean",
      "default": false
    },
    "allowDirectTeleport": {
      "type": "boolean",
      "default": false
    },
    "maxOffset": {
      "type": "integer",
      "default": 0
    },
    "minOffset": {
      "type": "integer",
      "default": 0
    },
    "timeoutMs": {
      "type": "integer",
      "default": 0
    }
  },
  "required": [
    "playerName"
  ]
}
```

**`mcc_look_at`** — Rotate player view toward world coordinates.
```json
{
  "type": "object",
  "properties": {
    "x": {
      "type": "number"
    },
    "y": {
      "type": "number"
    },
    "z": {
      "type": "number"
    }
  },
  "required": [
    "x",
    "y",
    "z"
  ]
}
```

**`mcc_look_angles`** — Rotate player view to explicit yaw and pitch angles.
```json
{
  "type": "object",
  "properties": {
    "yaw": {
      "type": "number"
    },
    "pitch": {
      "type": "number"
    }
  },
  "required": [
    "yaw",
    "pitch"
  ]
}
```

**`mcc_look_direction`** — Rotate player view to a cardinal direction or straight up/down.
```json
{
  "type": "object",
  "properties": {
    "direction": {
      "type": "string"
    }
  },
  "required": [
    "direction"
  ]
}
```

**`mcc_toggle_sprint`** — Explicitly send start or stop sprinting entity actions.
```json
{
  "type": "object",
  "properties": {
    "enabled": {
      "type": "boolean"
    }
  },
  "required": [
    "enabled"
  ]
}
```

**`mcc_toggle_sneak`** — Explicitly enable or disable sneaking.
```json
{
  "type": "object",
  "properties": {
    "enabled": {
      "type": "boolean"
    }
  },
  "required": [
    "enabled"
  ]
}
```

**`mcc_animation`** — Play a hand-swing animation with the selected hand.
```json
{
  "type": "object",
  "properties": {
    "hand": {
      "type": "string",
      "default": "MainHand"
    }
  }
}
```

**`mcc_change_hotbar_slot`** — Change active hotbar slot (1-9).
```json
{
  "type": "object",
  "properties": {
    "slot": {
      "type": "integer"
    }
  },
  "required": [
    "slot"
  ]
}
```

**`mcc_raycast_block`** — Raycast from the player's current view and return the first non-air block hit.
```json
{
  "type": "object",
  "properties": {
    "maxDistance": {
      "type": "number",
      "default": 8
    },
    "includeNeighbors": {
      "type": "boolean",
      "default": false
    }
  }
}
```

**`mcc_path_preview`** — Compute a path preview to a target world coordinate without moving there.
```json
{
  "type": "object",
  "properties": {
    "x": {
      "type": "number"
    },
    "y": {
      "type": "number"
    },
    "z": {
      "type": "number"
    },
    "allowUnsafe": {
      "type": "boolean",
      "default": false
    },
    "maxOffset": {
      "type": "integer",
      "default": 0
    },
    "minOffset": {
      "type": "integer",
      "default": 0
    },
    "timeoutMs": {
      "type": "integer",
      "default": 0
    },
    "maxWaypoints": {
      "type": "integer",
      "default": 128
    }
  },
  "required": [
    "x",
    "y",
    "z"
  ]
}
```

**`mcc_can_reach_position`** — Check whether MCC can currently path to a world coordinate without moving there.
```json
{
  "type": "object",
  "properties": {
    "x": {
      "type": "number"
    },
    "y": {
      "type": "number"
    },
    "z": {
      "type": "number"
    },
    "allowUnsafe": {
      "type": "boolean",
      "default": false
    },
    "maxOffset": {
      "type": "integer",
      "default": 0
    },
    "minOffset": {
      "type": "integer",
      "default": 0
    },
    "timeoutMs": {
      "type": "integer",
      "default": 0
    }
  },
  "required": [
    "x",
    "y",
    "z"
  ]
}
```

### Inventory (12 个)

**`mcc_inventory_snapshot`** — Get a snapshot of one inventory.
```json
{
  "type": "object",
  "properties": {
    "inventoryId": {
      "description": "Inventory ID. 0 is the player inventory.",
      "type": "integer",
      "default": 0
    }
  }
}
```

**`mcc_inventory_search`** — Search the player inventory and optionally open containers for items matching a query.
```json
{
  "type": "object",
  "properties": {
    "query": {
      "type": "string"
    },
    "maxCount": {
      "type": "integer",
      "default": 100
    },
    "exactMatch": {
      "type": "boolean",
      "default": false
    },
    "includeContainers": {
      "type": "boolean",
      "default": true
    }
  },
  "required": [
    "query"
  ]
}
```

**`mcc_inventory_drop_item`** — Drop an exact item count from an inventory by item type.
```json
{
  "type": "object",
  "properties": {
    "itemType": {
      "description": "Item type enum name (e.g. Diamond).",
      "type": "string"
    },
    "count": {
      "description": "Exact number of items to drop.",
      "type": "integer"
    },
    "inventoryId": {
      "description": "Inventory ID. 0 is the player inventory.",
      "type": "integer",
      "default": 0
    },
    "preferStack": {
      "description": "Prefer dropping from larger stacks first when true.",
      "type": "boolean",
      "default": false
    }
  },
  "required": [
    "itemType",
    "count"
  ]
}
```

**`mcc_inventory_window_action`** — Perform a window action on an inventory slot.
```json
{
  "type": "object",
  "properties": {
    "inventoryId": {
      "type": "integer"
    },
    "slotId": {
      "type": "integer"
    },
    "actionType": {
      "description": "WindowActionType enum name, e.g. LeftClick or ShiftClick.",
      "type": "string"
    }
  },
  "required": [
    "inventoryId",
    "slotId",
    "actionType"
  ]
}
```

**`mcc_select_item`** — Select a hotbar item by item type without rearranging inventory contents.
```json
{
  "type": "object",
  "properties": {
    "itemType": {
      "type": "string"
    },
    "preferLowestSlot": {
      "type": "boolean",
      "default": true
    }
  },
  "required": [
    "itemType"
  ]
}
```

**`mcc_items_list`** — List nearby dropped item entities with optional item type filtering.
```json
{
  "type": "object",
  "properties": {
    "itemType": {
      "type": [
        "string",
        "null"
      ],
      "default": null
    },
    "radius": {
      "type": "number",
      "default": 32
    },
    "maxCount": {
      "type": "integer",
      "default": 100
    }
  }
}
```

**`mcc_items_pickup`** — Move to and pick up nearby dropped items of a given item type.
```json
{
  "type": "object",
  "properties": {
    "itemType": {
      "type": "string"
    },
    "radius": {
      "type": "number",
      "default": 32
    },
    "maxItems": {
      "type": "integer",
      "default": 20
    },
    "allowUnsafe": {
      "type": "boolean",
      "default": false
    },
    "timeoutMs": {
      "type": "integer",
      "default": 0
    }
  },
  "required": [
    "itemType"
  ]
}
```

**`mcc_inventories_list`** — List currently open inventories and containers known to MCC.
```json
{
  "type": "object",
  "properties": {}
}
```

**`mcc_container_open_at`** — Open an interactable container block at world coordinates and wait for the container inventory to appear.
```json
{
  "type": "object",
  "properties": {
    "x": {
      "type": "integer"
    },
    "y": {
      "type": "integer"
    },
    "z": {
      "type": "integer"
    },
    "timeoutMs": {
      "type": "integer",
      "default": 0
    },
    "closeCurrent": {
      "type": "boolean",
      "default": true
    }
  },
  "required": [
    "x",
    "y",
    "z"
  ]
}
```

**`mcc_container_close`** — Close an open non-player container. Use inventoryId=-1 to close the active container.
```json
{
  "type": "object",
  "properties": {
    "inventoryId": {
      "description": "Container inventory ID, or -1 for the active non-player container.",
      "type": "integer",
      "default": -1
    },
    "timeoutMs": {
      "type": "integer",
      "default": 0
    }
  }
}
```

**`mcc_container_withdraw_item`** — Move an exact item count from an open container into the player inventory and verify the transfer.
```json
{
  "type": "object",
  "properties": {
    "itemType": {
      "description": "Item type enum name (e.g. Diamond).",
      "type": "string"
    },
    "count": {
      "description": "Exact number of items to move into the player inventory.",
      "type": "integer"
    },
    "inventoryId": {
      "description": "Container inventory ID, or -1 for the active non-player container.",
      "type": "integer",
      "default": -1
    },
    "preferLargestStack": {
      "description": "Prefer larger source stacks first when true.",
      "type": "boolean",
      "default": true
    }
  },
  "required": [
    "itemType",
    "count"
  ]
}
```

**`mcc_container_deposit_item`** — Move an exact item count from the player inventory into an open container and verify the transfer.
```json
{
  "type": "object",
  "properties": {
    "itemType": {
      "description": "Item type enum name (e.g. Diamond).",
      "type": "string"
    },
    "count": {
      "description": "Exact number of items to move into the container.",
      "type": "integer"
    },
    "inventoryId": {
      "description": "Container inventory ID, or -1 for the active non-player container.",
      "type": "integer",
      "default": -1
    },
    "preferLargestStack": {
      "description": "Prefer larger source stacks first when true.",
      "type": "boolean",
      "default": true
    }
  },
  "required": [
    "itemType",
    "count"
  ]
}
```

### EntityWorld (26 个)

**`mcc_entities_query`** — Query tracked entities.
```json
{
  "type": "object",
  "properties": {
    "maxCount": {
      "description": "Maximum entities to return.",
      "type": "integer",
      "default": 50
    }
  }
}
```

**`mcc_entities_list`** — List tracked entities with optional type and radius filtering.
```json
{
  "type": "object",
  "properties": {
    "maxCount": {
      "type": "integer",
      "default": 100
    },
    "typeFilter": {
      "type": [
        "string",
        "null"
      ],
      "default": null
    },
    "radius": {
      "type": "number",
      "default": 0
    }
  }
}
```

**`mcc_entity_info`** — Get detailed info for one tracked entity.
```json
{
  "type": "object",
  "properties": {
    "entityId": {
      "type": "integer"
    },
    "includeMetadata": {
      "type": "boolean",
      "default": false
    },
    "includeEquipment": {
      "type": "boolean",
      "default": true
    },
    "includeEffects": {
      "type": "boolean",
      "default": true
    }
  },
  "required": [
    "entityId"
  ]
}
```

**`mcc_entity_nearest`** — Return the nearest tracked entity matching the requested filters.
```json
{
  "type": "object",
  "properties": {
    "typeFilter": {
      "type": [
        "string",
        "null"
      ],
      "default": null
    },
    "nameFilter": {
      "type": [
        "string",
        "null"
      ],
      "default": null
    },
    "radius": {
      "type": "number",
      "default": 64
    },
    "includePlayers": {
      "type": "boolean",
      "default": true
    }
  }
}
```

**`mcc_entity_attack`** — Attack a tracked entity explicitly.
```json
{
  "type": "object",
  "properties": {
    "entityId": {
      "type": "integer"
    }
  },
  "required": [
    "entityId"
  ]
}
```

**`mcc_entity_interact`** — Interact with a tracked entity.
```json
{
  "type": "object",
  "properties": {
    "entityId": {
      "type": "integer"
    },
    "interaction": {
      "type": "string",
      "default": "Interact"
    },
    "hand": {
      "type": "string",
      "default": "MainHand"
    }
  },
  "required": [
    "entityId"
  ]
}
```

**`mcc_entity_types_list`** — List known MCC entity type names with optional filtering.
```json
{
  "type": "object",
  "properties": {
    "filter": {
      "type": [
        "string",
        "null"
      ],
      "default": null
    },
    "maxCount": {
      "type": "integer",
      "default": 500
    }
  }
}
```

**`mcc_players_list`** — List currently known online players.
```json
{
  "type": "object",
  "properties": {}
}
```

**`mcc_players_detailed`** — List online players with UUID, latency, gamemode, and tracked coordinates when available.
```json
{
  "type": "object",
  "properties": {
    "includeSelf": {
      "type": "boolean",
      "default": false
    },
    "includeCoordinates": {
      "type": "boolean",
      "default": true
    }
  }
}
```

**`mcc_player_nearby`** — Check if any player, or a specific player, is nearby.
```json
{
  "type": "object",
  "properties": {
    "playerName": {
      "type": [
        "string",
        "null"
      ],
      "default": null
    },
    "radius": {
      "type": "number",
      "default": 32
    },
    "includeSelf": {
      "type": "boolean",
      "default": false
    }
  }
}
```

**`mcc_player_locate`** — Locate a tracked player entity by name and return exact coordinates when available.
```json
{
  "type": "object",
  "properties": {
    "playerName": {
      "type": "string"
    },
    "includeSelf": {
      "type": "boolean",
      "default": false
    }
  },
  "required": [
    "playerName"
  ]
}
```

**`mcc_player_state`** — Get current controlled player state.
```json
{
  "type": "object",
  "properties": {}
}
```

**`mcc_player_stats`** — Get current controlled player stats, orientation, and location.
```json
{
  "type": "object",
  "properties": {}
}
```

**`mcc_respawn`** — Send the respawn packet when the controlled player is dead.
```json
{
  "type": "object",
  "properties": {}
}
```

**`mcc_world_block_at`** — Get block information at world coordinates.
```json
{
  "type": "object",
  "properties": {
    "x": {
      "type": "integer"
    },
    "y": {
      "type": "integer"
    },
    "z": {
      "type": "integer"
    }
  },
  "required": [
    "x",
    "y",
    "z"
  ]
}
```

**`mcc_blocks_find`** — Find nearby blocks by block name/type query or block ID.
```json
{
  "type": "object",
  "properties": {
    "query": {
      "type": [
        "string",
        "null"
      ],
      "default": null
    },
    "radius": {
      "type": "integer",
      "default": 6
    },
    "maxCount": {
      "type": "integer",
      "default": 200
    },
    "exactMatch": {
      "type": "boolean",
      "default": false
    }
  }
}
```

**`mcc_block_scan`** — Scan nearby blocks around player location.
```json
{
  "type": "object",
  "properties": {
    "radius": {
      "type": "integer",
      "default": 3
    },
    "maxCount": {
      "type": "integer",
      "default": 200
    },
    "materialFilter": {
      "type": [
        "string",
        "null"
      ],
      "default": null
    }
  }
}
```

**`mcc_block_types_list`** — List known MCC block type names with optional filtering.
```json
{
  "type": "object",
  "properties": {
    "filter": {
      "type": [
        "string",
        "null"
      ],
      "default": null
    },
    "maxCount": {
      "type": "integer",
      "default": 500
    }
  }
}
```

**`mcc_materials_list`** — List known MCC material names with optional filtering.
```json
{
  "type": "object",
  "properties": {
    "filter": {
      "type": [
        "string",
        "null"
      ],
      "default": null
    },
    "maxCount": {
      "type": "integer",
      "default": 500
    }
  }
}
```

**`mcc_signs_find`** — Find nearby signs whose text exactly matches or contains the requested text.
```json
{
  "type": "object",
  "properties": {
    "text": {
      "type": "string"
    },
    "exactMatch": {
      "type": "boolean",
      "default": false
    },
    "radius": {
      "type": "integer",
      "default": 16
    },
    "maxCount": {
      "type": "integer",
      "default": 50
    },
    "includeBackText": {
      "type": "boolean",
      "default": true
    }
  },
  "required": [
    "text"
  ]
}
```

**`mcc_dig_block`** — Dig a block at target location.
```json
{
  "type": "object",
  "properties": {
    "x": {
      "type": "number"
    },
    "y": {
      "type": "number"
    },
    "z": {
      "type": "number"
    },
    "durationSeconds": {
      "type": "number",
      "default": 0
    }
  },
  "required": [
    "x",
    "y",
    "z"
  ]
}
```

**`mcc_use_item_on_block`** — Use currently held item on a target block location.
```json
{
  "type": "object",
  "properties": {
    "x": {
      "type": "number"
    },
    "y": {
      "type": "number"
    },
    "z": {
      "type": "number"
    }
  },
  "required": [
    "x",
    "y",
    "z"
  ]
}
```

**`mcc_use_item_on_hand`** — Use the currently held item.
```json
{
  "type": "object",
  "properties": {}
}
```

**`mcc_place_block`** — Place the currently held block/item at a target block location.
```json
{
  "type": "object",
  "properties": {
    "x": {
      "type": "integer"
    },
    "y": {
      "type": "integer"
    },
    "z": {
      "type": "integer"
    },
    "face": {
      "type": "string",
      "default": "Up"
    },
    "hand": {
      "type": "string",
      "default": "MainHand"
    },
    "lookAtBlock": {
      "type": "boolean",
      "default": false
    }
  },
  "required": [
    "x",
    "y",
    "z"
  ]
}
```

**`mcc_status_effects`** — Get active player status effects only.
```json
{
  "type": "object",
  "properties": {}
}
```

**`mcc_agent_guidance`** — Get the canonical MCC MCP Operator Prompt bundle for external agents using this MCP server.
```json
{
  "type": "object",
  "properties": {}
}
```

## 3. 样本返回（捕获时的真实输出）

```

===== mcc_session_status args={} =====
{
  "content": [
    {
      "type": "text",
      "text": "{\"success\":true,\"data\":{\"host\":\"127.0.0.1\",\"port\":25568,\"username\":\"TestBot2_3090\",\"protocolVersion\":340,\"terrainEnabled\":true,\"inventoryEnabled\":true,\"entityEnabled\":true,\"location\":{\"x\":100.5,\"y\":74,\"z\":1.5}}}"
    }
  ]
}

===== mcc_player_state args={} =====
{
  "content": [
    {
      "type": "text",
      "text": "{\"success\":true,\"data\":{\"nickname\":\"TestBot2_3090\",\"username\":\"TestBot2_3090\",\"health\":20,\"saturation\":20,\"gamemode\":0,\"currentSlot\":1,\"yaw\":0,\"pitch\":0,\"location\":{\"x\":100.5,\"y\":74,\"z\":1.5},\"effects\":[]}}"
    }
  ]
}

===== mcc_player_stats args={} =====
{
  "content": [
    {
      "type": "text",
      "text": "{\"success\":true,\"data\":{\"username\":\"TestBot2_3090\",\"health\":20,\"saturation\":20,\"level\":0,\"totalExperience\":0,\"gamemode\":0,\"playerEntityId\":558,\"currentSlot\":1,\"yaw\":0,\"pitch\":0,\"location\":{\"x\":100.5,\"y\":74,\"z\":1.5},\"tps\":19.87631223802928}}"
    }
  ]
}

===== mcc_server_info args={} =====
{
  "content": [
    {
      "type": "text",
      "text": "{\"success\":true,\"data\":{\"host\":\"127.0.0.1\",\"port\":25568,\"tps\":19.87631223802928}}"
    }
  ]
}

===== mcc_world_state args={} =====
{
  "content": [
    {
      "type": "text",
      "text": "{\"success\":true,\"data\":{\"host\":\"127.0.0.1\",\"port\":25568,\"username\":\"TestBot2_3090\",\"protocol\":340,\"protocolVersion\":340,\"terrainEnabled\":true,\"inventoryEnabled\":true,\"entityEnabled\":true,\"entityHandlingEnabled\":true,\"location\":{\"x\":100.5,\"y\":74,\"z\":1.5},\"tps\":19.87631223802928,\"dimension\":\"minecraft:overworld\",\"dimensionDetails\":{\"name\":\"minecraft:overworld\",\"minY\":0,\"maxY\":256,\"height\":256,\"logicalHeight\":256,\"coordinateScale\":1,\"hasSkylight\":true,\"hasCeiling\":false},\"loadedChunkCount\":289,\"pendingChunkCount\":0,\"totalChunkCount\":289,\"loadRatio\":1,\"worldAge\":10540081,\"timeOfDay\":10389139}}"
    }
  ]
}

===== mcc_chunk_status args={"x":null,"y":null,"z":null} =====
{
  "content": [
    {
      "type": "text",
      "text": "{\"success\":true,\"data\":{\"location\":{\"x\":100.5,\"y\":74,\"z\":1.5},\"chunk\":{\"x\":6,\"z\":0},\"chunkX\":6,\"chunkZ\":0,\"loaded\":true,\"fullyLoaded\":true,\"loadedChunkCount\":289,\"pendingChunkCount\":0,\"totalChunkCount\":289,\"loadRatio\":1}}"
    }
  ]
}

===== mcc_send_chat args={"text":"TestPing683"} =====
{
  "content": [
    {
      "type": "text",
      "text": "{\"success\":true}"
    }
  ]
}

===== mcc_run_internal_command args={"command":"TestPing746"} =====
{
  "content": [
    {
      "type": "text",
      "text": "{\"success\":true,\"data\":{\"success\":false,\"status\":\"NotRun\",\"output\":\"Command did not run, cannot determine the result of the command.\"}}"
    }
  ]
}

===== mcc_look_at args={"x":0,"y":0,"z":0} =====
{
  "content": [
    {
      "type": "text",
      "text": "{\"success\":true,\"data\":{\"success\":true,\"yaw\":0,\"pitch\":0,\"location\":{\"x\":100.5,\"y\":74,\"z\":1.5},\"target\":{\"x\":0,\"y\":0,\"z\":0}}}"
    }
  ]
}

===== mcc_change_hotbar_slot args={"slot":0} =====
{
  "content": [
    {
      "type": "text",
      "text": "{\"success\":false,\"errorCode\":\"invalid_args\"}"
    }
  ]
}

===== mcc_toggle_sprint args={"enabled":false} =====
{
  "content": [
    {
      "type": "text",
      "text": "{\"success\":true,\"data\":{\"success\":true,\"enabled\":false}}"
    }
  ]
}

===== mcc_entity_attack args={"entityId":0} =====
{
  "content": [
    {
      "type": "text",
      "text": "{\"success\":false,\"errorCode\":\"invalid_state\",\"data\":{\"entityId\":0}}"
    }
  ]
}

===== mcc_raycast_block args={"maxDistance":0,"includeNeighbors":false} =====
{
  "content": [
    {
      "type": "text",
      "text": "{\"success\":false,\"errorCode\":\"invalid_args\",\"data\":{\"parameter\":\"maxDistance\",\"minExclusive\":0,\"max\":128}}"
    }
  ]
}

===== mcc_items_list args={"itemType":"TestPing740","radius":0,"maxCount":0} =====
{
  "content": [
    {
      "type": "text",
      "text": "{\"success\":false,\"errorCode\":\"invalid_args\"}"
    }
  ]
}

===== mcc_select_item args={"itemType":"TestPing325","preferLowestSlot":false} =====
{
  "content": [
    {
      "type": "text",
      "text": "{\"success\":false,\"errorCode\":\"invalid_args\"}"
    }
  ]
}

===== mcc_loaded_bots args={} =====
{
  "content": [
    {
      "type": "text",
      "text": "{\"success\":true,\"data\":{\"count\":2,\"bots\":[{\"name\":\"McpServer\",\"fullTypeName\":\"MinecraftClient.ChatBots.McpServer\",\"isScript\":false},{\"name\":\"RemoteControl\",\"fullTypeName\":\"MinecraftClient.ChatBots.RemoteControl\",\"isScript\":false}]}}"
    }
  ]
}

===== mcc_entities_query args={"maxCount":0} =====
{
  "content": [
    {
      "type": "text",
      "text": "{\"success\":true,\"data\":{\"count\":129,\"entities\":[{\"id\":559,\"type\":\"Chicken\",\"typeLabel\":\"Chicken\",\"uuid\":\"00000000-0000-0000-0000-00000000022f\",\"x\":107.01,\"y\":28.74,\"z\":7,\"health\":1,\"pose\":\"Standing\",\"latency\":0}]}}"
    }
  ]
}

===== mcc_entities_list args={"maxCount":0,"typeFilter":"TestPing350","radius":0} =====
{
  "content": [
    {
      "type": "text",
      "text": "{\"success\":true,\"data\":{\"totalTracked\":129,\"count\":0,\"entities\":[]}}"
    }
  ]
}

===== mcc_entity_types_list args={"filter":"TestPing381","maxCount":0} =====
{
  "content": [
    {
      "type": "text",
      "text": "{\"success\":true,\"data\":{\"total\":162,\"count\":0,\"filter\":\"TestPing381\",\"entityTypes\":[]}}"
    }
  ]
}

===== mcc_blocks_find args={"query":"TestPing705","radius":0,"maxCount":0,"exactMatch":false} =====
{
  "content": [
    {
      "type": "text",
      "text": "{\"success\":false,\"errorCode\":\"invalid_args\",\"data\":{\"parameter\":\"radius\",\"min\":1,\"max\":32}}"
    }
  ]
}

===== mcc_respawn args={} =====
{
  "content": [
    {
      "type": "text",
      "text": "{\"success\":false,\"errorCode\":\"invalid_state\",\"data\":{\"health\":20}}"
    }
  ]
}
```

## 4. 死亡基线（对照组）

> 由死亡重现实测补充（见下文）。

## 4.1 死亡重现实测（2026-09-06）

**方法**：bot（TestBot2_3090，survival 逻辑在外观上 gm=-1）在 (100,74,1) 先被实心方块包裹（未触发窒息），随后脚下放置熔岩 (100,73,1)。

**观测序列**：

| 时间 | health | y | 现象 |
|---|---|---|---|
| 0s | 20 | 74.0 | 站立，熔岩开始伤害 |
| +2.5s | 20 | 48.9 | 坠落（熔岩柱中） |
| +5s | 20 | 74.0 | **重生回 y=74**（死亡→自动重生成功） |
| +7.5s | 20 | 74.0 | 站立 |
| +10s | 20 | 72.8 | 再次坠落（熔岩柱仍在） |
| +15s | 18 | 61.9 | 熔岩伤害中 |
| +17.5s | 17 | 53.7 | 持续坠落 |
| +20s | 17 | 40 | 坠落至较低处 |
| 清除熔岩后 | 20 | 70.6 | 存活，MCP 端点仍响应 |

**结论（对照组）**：
1. MCC 的死亡自动重生**正常**：死亡后重生回出生点 y≈74，未触发坠虚空卡死（本测例）。
2. 若死亡点仍危险（熔岩等），会进入"重生→再死"循环；MCC 状态在循环中持续掉血但不立即损坏。
3. 与已知背景一致：MCC 偶发"客户端状态损坏 → 坠虚空无法重生 → 断线 + MCP 停止"（本次会话开始时即处于该状态，需 mcc_stop/mcc_start force 重建）。
4. **对比标尺**：mineflayer Phase 0 冒烟将用同样方法（熔岩 kill）验证死亡→重生位置正常、不坠虚空。
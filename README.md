# MoneyManager-Lua

A Roblox server economy and progression system for handling passive income, rebirths, inventory slots, stealing mechanics, base themes, and global luck scaling.

This project was built to practice large-scale gameplay systems, server authority, player progression logic, and multiplayer economy balancing

## Features

- handles player economy and passive income
- rebirth system with scaling rewards and requirements
- server luck calculation and multipliers
- inventory and storage slot management
- character protection and save systems
- steal mechanic for traveling characters
- player base themes and unlock progression
- index rewards with permanent bonuses
- multiplayer-safe server authority logic

## Usage

Place the module in `ServerScriptService` and require it:

```lua
local MoneyManager = require(game.ServerScriptService.src.MoneyManager)

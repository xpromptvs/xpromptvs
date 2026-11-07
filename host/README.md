# Native host modules

The Mac app links RdevAppHost and RdevHostKit in process. RdevCore holds portable state and wire logic. RdevE2E/RdevNoise provide authenticated encrypted signaling; RdevSimKit isolates simulator interoperability. The imported streaming engine supplies encoding and transport. See [architecture](../docs/architecture.md) and [building](../docs/building.md).

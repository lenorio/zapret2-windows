# Manual strategies

This folder contains the manual Flowseal-inspired strategy launchers.

The 22 launchers are named after Flowseal's `general*.bat` variants. Each
launcher starts this project's `winws2.exe` in its foreground console, without
installing autostart. Stop it with Ctrl+C. The runner refuses to start when
another `winws2.exe` process is present; it never stops that process itself.

`catalog.json` records the translated YouTube and general TLS actions. The
translation covers Flowseal's `fake`, `multisplit`, `multidisorder`,
`fakedsplit`, and `hostfakesplit` ideas. The ALT5 IPv4-wide SYN profile was
restricted to the domain-list TLS profile. Options specific to zapret1,
including its dynamic game filter, IP set layout and some packet fooling
details, cannot be copied directly. The common HTTP, QUIC and Minecraft
profiles come from the local working zapret2 config. These launchers are
candidate strategies, not claims of identical behavior or network success.

`run.ps1 -StrategyId <id> -RenderOnly` generates a config without starting
WinDivert, useful for inspection. Generated configs are placed in `runtime/`.
No Python or other runtime is required on the user's computer.


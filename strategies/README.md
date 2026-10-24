# Manual strategies

This folder contains the manual Flowseal-inspired strategy launchers.

The 22 Flowseal launchers are named after its `general*.bat` variants. Three
baseline variants and `current-custom.bat` are included too. Each
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

`targets.txt` uses `Name = "https://host"` or `Name = "PING:address"` lines.
The manager's test option runs every entry in `catalog.json` against those
targets and checks HTTP, TLS 1.2, TLS 1.3 and ping. Reports are saved to
`test results/test_results_YYYY-MM-DD_HH-mm-ss.txt`. Ping is diagnostic;
successful HTTP/TLS checks determine the recommendation. Testing does not
select or install a strategy. The original bypass is restored afterward.


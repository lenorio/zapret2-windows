# Third-party components

This package bundles code and binaries from independent projects. The root
MIT license covers original manager scripts and the independently compiled
domain lists. It does not replace the licenses below.

| Component | Version / provenance | License and source |
| --- | --- | --- |
| zapret2 (`winws2.exe`, Lua) | v1.0.6, binary matched `bol-van/zapret-win-bundle` commit `de9795d71287fdb21cf8c20b8af1a09d0eb10ab2`; Lua matched zapret2 commit `221d7dff24bfec0cd5ac0a5070b8acef2008af3d` | MIT, `third_party/licenses/zapret2-MIT.txt`; [source](https://github.com/bol-van/zapret2/tree/v1.0.6) |
| Cygwin runtime (`cygwin1.dll`) | 3.4.10 | LGPL-3.0-or-later with Cygwin linking exception; license texts in `third_party/licenses/`; corresponding source archive: `third_party/source/cygwin-3.4.10-1-src.tar.xz` |
| WinDivert (`WinDivert.dll`, `WinDivert64.sys`) | 2.2.2 | Dual LGPL-3.0/GPL-2.0; `third_party/licenses/WinDivert-LICENSE.txt`; source archive: `third_party/source/WinDivert-v2.2.2-source.zip` |
| Flowseal strategy reference and TLS sample blobs | [Flowseal/zapret-discord-youtube](https://github.com/Flowseal/zapret-discord-youtube) | MIT, `third_party/licenses/Flowseal-MIT.txt`; converted profiles are documented in `strateries/README.md` |

No third-party binaries are covered by the root MIT license. The included
source archives are for license compliance; users do not need to build them.

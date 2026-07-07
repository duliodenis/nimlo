# Vendored WebView2 loader

`WebView2Loader.dll` is Microsoft's redistributable bootstrap for the WebView2
runtime, taken from the `Microsoft.Web.WebView2` NuGet package, version
**1.0.2903.40** (`runtimes/win-x64/native` and `runtimes/win-arm64/native`).
Redistribution terms are in `LICENSE.txt` and `NOTICE.txt` (from the same
package).

The build copies the architecture-matching DLL next to `nimlo.exe`; at runtime
`src/webview/webview_win32.zig` loads it with `LoadLibraryW` and resolves
`CreateCoreWebView2EnvironmentWithOptions` with `GetProcAddress` — no import
library is linked. Everything past that entry point is direct COM vtable calls
from Zig (see `src/webview/webview2.zig`).

To upgrade: download the new `.nupkg`, replace the two DLLs plus
`LICENSE.txt`/`NOTICE.txt`, and update the version here.

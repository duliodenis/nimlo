pub const html =
    \\<!doctype html>
    \\<html lang="en">
    \\<head>
    \\  <meta charset="utf-8">
    \\  <meta name="viewport" content="width=device-width, initial-scale=1">
    \\  <title>About Nimlo</title>
    \\  <style>
    \\    :root{color-scheme:light dark;--bg:#f6f7f9;--panel:#fff;--text:#101828;--muted:#667085;--line:#d0d5dd;--accent:#315cff}
    \\    @media (prefers-color-scheme:dark){:root{--bg:#171719;--panel:#242428;--text:#f4f4f5;--muted:#c4c7cf;--line:#34363d;--accent:#7d96ff}}
    \\    *{box-sizing:border-box}
    \\    body{margin:0;background:var(--bg);color:var(--text);font:14px -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
    \\    main{max-width:880px;margin:0 auto;padding:28px}
    \\    h1{font-size:15px;margin:0 0 16px;font-weight:700}
    \\    h2{font-size:13px;margin:0;color:var(--text)}
    \\    p{margin:0;color:var(--muted);line-height:1.45}
    \\    a{color:var(--accent);text-underline-offset:2px}
    \\    .panel{background:var(--panel);border:1px solid var(--line);border-radius:8px;overflow:hidden;margin-bottom:20px}
    \\    .hero{display:flex;gap:14px;align-items:center;padding:18px 20px;border-bottom:1px solid var(--line)}
    \\    .mark{width:34px;height:34px;border-radius:8px;background:linear-gradient(135deg,#4b6cff,#6c3df4);display:grid;place-items:center;color:#fff;font-size:25px;font-weight:800;line-height:1}
    \\    .name{font-size:22px;font-weight:650;letter-spacing:0}
    \\    .status{display:flex;gap:14px;align-items:flex-start;padding:16px 20px}
    \\    .check{width:18px;height:18px;flex:0 0 auto;margin-top:1px;color:var(--accent)}
    \\    .grid{display:grid;grid-template-columns:180px 1fr;border-top:1px solid var(--line)}
    \\    .grid div{padding:10px 14px;border-bottom:1px solid var(--line)}
    \\    .grid div:nth-child(odd){color:var(--muted)}
    \\    .grid div:nth-last-child(-n+2){border-bottom:0}
    \\    .section{padding:16px 20px;border-top:1px solid var(--line)}
    \\    .section:first-child{border-top:0}
    \\    ul{list-style:none;margin:12px 0 0;padding:0}
    \\    li{display:grid;grid-template-columns:1fr auto;gap:12px;padding:12px 0;border-top:1px solid var(--line)}
    \\    li:first-child{border-top:0}
    \\    .license{color:var(--muted);white-space:nowrap}
    \\    .small{font-size:12px}
    \\    @media (max-width:640px){main{padding:18px}.grid{grid-template-columns:1fr}.grid div:nth-child(odd){padding-bottom:2px}.grid div:nth-child(even){padding-top:2px}li{grid-template-columns:1fr}.license{white-space:normal}}
    \\  </style>
    \\</head>
    \\<body>
    \\  <main>
    \\    <h1>About Nimlo</h1>
    \\    <section class="panel">
    \\      <div class="hero">
    \\        <div class="mark" aria-hidden="true">N</div>
    \\        <div>
    \\          <div class="name">Nimlo</div>
    \\          <p>Version 0.1.0 (Prototype Build)</p>
    \\        </div>
    \\      </div>
    \\      <div class="status">
    \\        <svg class="check" viewBox="0 0 24 24" fill="none" aria-hidden="true"><path d="M20 6 9 17l-5-5" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"/></svg>
    \\        <div>
    \\          <h2>Nimlo is up to date for this local build.</h2>
    \\          <p>Experimental macOS browser shell built in Zig with a native AppKit interface and system WebKit rendering.</p>
    \\        </div>
    \\      </div>
    \\    </section>
    \\    <section class="panel">
    \\      <div class="section">
    \\        <h2>System Info</h2>
    \\      </div>
    \\      <div class="grid">
    \\        <div>Internal URL</div><div>nimlo://about</div>
    \\        <div>Rendering Engine</div><div id="engine">WebKit WKWebView</div>
    \\        <div>Platform</div><div id="platform">macOS</div>
    \\        <div>Language</div><div id="language">Unknown</div>
    \\        <div>Viewport</div><div id="viewport">Unknown</div>
    \\        <div>Website Data</div><div>Nonpersistent WebKit data store by default</div>
    \\      </div>
    \\    </section>
    \\    <section class="panel">
    \\      <div class="section">
    \\        <h2>Open Source Software</h2>
    \\        <p>Nimlo currently has a small dependency surface. These are the open-source projects and components this prototype relies on directly.</p>
    \\        <ul>
    \\          <li><span><a href="https://ziglang.org/">Zig</a><br><span class="small">Compiler, standard library, and build system used to build Nimlo.</span></span><span class="license">MIT</span></li>
    \\          <li><span><a href="https://webkit.org/">WebKit</a><br><span class="small">System web rendering engine used through macOS WKWebView.</span></span><span class="license">LGPL/BSD-style</span></li>
    \\        </ul>
    \\      </div>
    \\      <div class="section">
    \\        <p class="small">Nimlo also uses macOS platform frameworks such as AppKit, Foundation, and Security. Those are operating system frameworks rather than bundled open-source dependencies.</p>
    \\      </div>
    \\    </section>
    \\  </main>
    \\  <script>
    \\    const ua = navigator.userAgent || "";
    \\    const match = ua.match(/AppleWebKit\/([^\s]+)/);
    \\    document.getElementById("engine").textContent = match ? `WebKit ${match[1]} via WKWebView` : "WebKit WKWebView";
    \\    document.getElementById("platform").textContent = navigator.platform || "macOS";
    \\    document.getElementById("language").textContent = navigator.language || "Unknown";
    \\    const viewport = () => `${window.innerWidth} x ${window.innerHeight}`;
    \\    const viewportNode = document.getElementById("viewport");
    \\    viewportNode.textContent = viewport();
    \\    window.addEventListener("resize", () => { viewportNode.textContent = viewport(); });
    \\  </script>
    \\</body>
    \\</html>
;

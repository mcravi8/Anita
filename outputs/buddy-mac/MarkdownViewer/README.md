# Embedded Markdown Viewer

Buddy reuses our Markdown Viewer’s `Renderer.swift`, `Highlighter.swift`,
`Math.swift`, and reading stylesheet. Native symbols are prefixed in
`BuddyMarkdownRenderer.swift` and resource lookup points into this directory.
The standalone Markdown Viewer application and its Library are unchanged.

`BuddyMarkdownPreview.swift` renders only bytes already read through Buddy’s
connected-folder tools. The bundled KaTeX engine and data-URI fonts work offline;
its license is in `Math/LICENSE`. Documents have no JavaScript, bridge, disk or
network access. The frontend sanitizes the rendered body and embeds it in an
opaque sandboxed frame. Relative raster images are bounded and resolved through
the same connected-folder boundary. The full preview is limited to 256 KB of
source and 4 MB of rendered HTML, with at most 128 typeset equations. Additional equations remain as source,
with a note in the reading caption; larger documents use the plain preview. These are preview limits, not write
permission changes. Saving uses the existing versioned original-file tools.

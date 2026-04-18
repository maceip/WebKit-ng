# Windows MiniBrowser Fluent Tabs

Windows-only MiniBrowser demo lane for a Windows 11 browser shell.

This intentionally stays in Win32/WebKit MiniBrowser plumbing instead of adding
Windows App SDK or XAML packaging to the WebKit tree. It uses the native Windows
11 DWM system backdrop attributes directly:

- tabbed Mica for the main browser window
- transient/acrylic-style backdrop for dialogs
- dark caption, border, and text colors
- rounded window corners
- Segoe UI Variable Text for the location field
- Segoe Fluent Icons glyphs for navigation toolbar buttons

The same patch also wires the portable `Tools/MiniBrowser/common` tab state
model into the Windows build so later horizontal and vertical tab controls have
one source of truth.

---

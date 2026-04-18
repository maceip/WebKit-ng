# Tabs

`BrowserStateModel` is the portable tab/window state owner. It tracks windows,
tabs, active selection, tab movement, and horizontal versus vertical tab mode.

Platform UI renders this state and calls `BrowserCommandController` for user
actions. MiniBrowser can be used as a test host, but it should not own product
state semantics.

---

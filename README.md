# Cloyster

Groups macOS windows into clusters that behave like one window. Windows in a cluster share edges,
with a draggable divider between them, and move together.

This is a prototype. You run it from a terminal, which needs Accessibility access.

```sh
swift build
.build/debug/cloyster list
.build/debug/cloyster run 'h(Safari,v(Terminal,Notes))'
```

`h(...)` puts windows side by side and `v(...)` stacks them. Leaves are window IDs from `list`, or
app names. Pass `--frame x,y,width,height` to choose where the cluster goes. Ctrl-C stops it and
prints how far windows fell behind.

## Rules

- Dragging a window moves the whole cluster.
- Dragging a divider moves only that divider. The combined size of its neighbours stays the same.
- Resizing a window changes only the windows that have to match it: its column for width, its row
  for height. The cluster's outer size changes instead.
- A window that refuses a size wins. After a divider drag the divider gives way, otherwise its row
  or column follows it.

## Development

```sh
swift run cloyster-tests
```

Use this instead of `swift test`, which silently runs nothing without a full Xcode install.

`demo-window` opens a throwaway window to test against. `--step`, `--min` and `--busy` make it snap
like a terminal, refuse small sizes or respond slowly.

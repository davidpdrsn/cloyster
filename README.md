# Cloyster

Groups macOS windows into clusters that behave like one window. Windows in a cluster share edges,
with a draggable divider between them, and move together.

## Running

```sh
just install
```

This builds the app, installs it into `/Applications` and restarts it.

Cloyster lives in the menu bar and asks for Accessibility access on first launch. The first build
adds a self-signed certificate to your login keychain, so the permission survives rebuilds.

Hold Cmd and drag a window by its title bar, with the cursor near an edge of another window. Cmd can
go down before or during the drag, and has to be the only modifier held. A preview shows where it
will land.

- Release to join. Near a cluster's outer edge, the window runs along that whole side.
- Let go of Cmd first to cancel.
- Cmd+drag a clustered window into the middle of anything, or empty space, to take it out.

Clusters aren't saved, so they're gone when Cloyster quits. The windows stay where they are.

## From a terminal

```sh
swift build
.build/debug/cloyster list
.build/debug/cloyster run 'h(Safari,v(Terminal,Notes))'
```

`run` starts with a cluster in place. `h(...)` puts windows side by side and `v(...)` stacks them.
Leaves are window IDs from `list`, or app names. Pass `--frame x,y,width,height` to choose where it
goes. Ctrl-C stops it and prints how far windows fell behind.

## Rules

- Dragging a window moves the whole cluster.
- Bringing a window forward brings the whole cluster forward.
- Dragging a divider moves only that divider. The combined size of its neighbours stays the same.
- Resizing a window changes only the windows that have to match it: its column for width, its row
  for height. The cluster's outer size changes instead.
- A joining window keeps its size along the side it joins and matches the cluster across it, so the
  cluster grows and the window it joined stays put.
- A window that refuses a size wins. After a divider drag the divider gives way, otherwise its row
  or column follows it.

## Development

```sh
swift run cloyster-tests
```

Use this instead of `swift test`, which silently runs nothing without a full Xcode install.

`demo-window` opens a throwaway window to test against. `--step`, `--min` and `--busy` make it snap
like a terminal, refuse small sizes or respond slowly.

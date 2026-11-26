# git-seed-worktree

Create a normal Git worktree and seed it with copy-on-write clones of selected
cache directories from another checkout. File data initially shares disk blocks
on APFS. Writes to a cloned file affect that checkout alone.

## Use

Build with Swift 6.4 or later on macOS 27 or later. Copy the release binary to a
directory on your `PATH`, then invoke it as a Git subcommand.

```sh
swift build -c release
install -m 755 "$(swift build -c release --show-bin-path)/git-seed-worktree" ~/Developer/tools/
git seed-worktree -b feat/login ../login main --seed ../finished-build --cache .uv-cache
```

Run the last command from the repository where you want to create the worktree.
Automation can invoke the binary directly with the same arguments. Omitting
`main` lets Git choose the starting revision. Use `git worktree remove` for
cleanup.

- The seed must be a worktree root of the same repository. Finish building and
  stop cache writers there before invoking the tool.
- Repeat `--cache` for each relative cache directory. A cache must be ignored
  and contain no tracked files in either Git index. Choose caches that work
  after relocation. Symlinks must be relative and resolve inside the cache.
- The command prints the new worktree path and the outcome for each cache.
  Unsupported volumes, missing caches, and occupied destinations leave a
  usable worktree with a skip message. Other cache errors produce a nonzero
  exit after reporting the worktree path. Git failures preserve Git's status.
- Incomplete clones are staged in hidden directories in the new worktree. The
  command removes its staging directory on ordinary completion. After an
  abrupt process termination, remove any leftover `.git-seed-worktree-*`
  directories once the command has stopped.

Run `swift test` on APFS to exercise native Git worktree creation and cloning.

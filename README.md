# git-seed-worktree

Create a Git worktree and seed it with copy-on-write clones from another
checkout. File data initially shares disk blocks on APFS. Writes to a cloned
file affect that checkout alone.

## Use

Build with Swift 6.4 or later on macOS 27 or later. Copy the release binary to a
directory on your `PATH`, then invoke it as a Git subcommand.

```sh
swift build -c release
install -m 755 "$(swift build -c release --show-bin-path)/git-seed-worktree" ~/Developer/tools/
git seed-worktree -b feat/login ../login main --seed ../finished-build --cache .uv-cache
git seed-worktree -b feat/share ../share main --seed ../finished-build --clone-tracked --cache .uv-cache
```

Run the last command from the repository where you want to create the worktree.
Automation can invoke the binary directly with the same arguments. Omitting
`main` lets Git choose the starting revision. Use `git worktree remove` for
cleanup.

- The seed must be a worktree root of the same repository. Finish building and
  stop cache writers there before invoking the tool.
- Add `--clone-tracked` to share tracked regular files that match the target
  commit. The command checks each clone against its Git object before publishing
  it. Git checks out changed files, filtered paths, symlinks and submodule
  entries. When cloning is unavailable, Git writes the tracked files. Sparse
  checkout, automatic line-ending conversion, and recursive submodule settings
  in the destination use Git's standard checkout. When Git lists a
  `post-checkout` hook, it creates and checks out the worktree itself. Requested
  caches are still cloned after the hooks succeed.
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
  directories once the command has stopped. A checkout or hook failure after
  Git registers the worktree reports its path for recovery or removal.

Run `swift test` on APFS to exercise native Git worktree creation and cloning.

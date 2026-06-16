---
name: git-extras
description: "Extended Git operations: interactive rebase, branch cleanup, bisect automation, stash management, commit inspection, and diff navigation. Triggers on: 'rebase', 'squash commits', 'cleanup branches', 'git bisect', 'stash', 'find commit', 'blame', 'log grep', 'reflog', 'worktree'."
---

# Git Extras

Extended Git operations for complex workflows. Use when standard `git add/commit/push` aren't enough.

## Core Commands

### Interactive Rebase

```bash
# Squashes last N commits into one
git rebase -i HEAD~N

# Rebase onto a specific branch
git rebase -i <branch>

# Continue after resolving conflicts
git rebase --continue

# Abort a rebase in progress
git rebase --abort
```

### Branch Cleanup

```bash
# List merged branches (safe to delete)
git branch --merged main | grep -v "main\|*"

# Delete merged branches
git branch --merged main | grep -v "main\|*" | xargs -r git branch -d

# Force delete unmerged branches
git branch -D <branch-name>

# List all branches sorted by last commit
git for-each-ref --sort=-committerdate --format='%(committerdate:short) %(refname:short)' refs/heads/

# Prune stale remote tracking branches
git fetch --prune
```

### Git Bisect

```bash
# Start bisect with known bad and good commits
git bisect start
git bisect bad <bad-commit>
git bisect good <good-commit>

# Run bisect with a test script (automated)
git bisect start
git bisect bad HEAD
git bisect good <good-commit>
git bisect run <test-command>

# Reset when done
git bisect reset
```

### Stash Management

```bash
# Stash with message
git stash push -m "WIP: feature X"

# List stashes
git stash list

# Show stash contents
git stash show -p stash@{0}

# Apply stash (keep in list)
git stash apply stash@{0}

# Pop stash (remove from list)
git stash pop

# Drop stash
git stash drop stash@{0}

# Stash specific files
git stash push -m "partial work" -- path/to/file1 path/to/file2

# Stash including untracked files
git stash -u
```

### Commit Inspection

```bash
# Search commits by message
git log --all --grep="fix bug" --oneline

# Search commits by content
git log -S "function_name" --oneline

# Show commits that touched a specific file
git log -- path/to/file

# Show who changed each line (blame)
git blame path/to/file

# Show blame ignoring whitespace
git blame -w path/to/file

# Detailed blame for a function
git blame -L start,end path/to/file
```

### Diff Navigation

```bash
# Show changed files between commits
git diff --name-status <commitA>..<commitB>

# Show diff stats (no patch)
git diff --stat <commitA>..<commitB>

# Show diff for a specific file between commits
git diff <commitA>..<commitB> -- path/to/file

# Show staged changes
git diff --cached

# Show diff with word-level changes
git diff --word-diff
```

### Reflog (Recovery)

```bash
# Show reflog (all HEAD movements)
git reflog

# Find lost commits
git reflog | grep <commit-message>

# Recover a lost commit
git checkout <commit-hash>
git branch recovered-branch
```

### Worktrees

```bash
# List worktrees
git worktree list

# Create worktree for a branch
git worktree add ../feature-branch feature-branch

# Create worktree from a specific commit
git worktree add ../temp-checkout <commit-hash>

# Remove worktree
git worktree remove ../feature-branch
```

## Templates

### Interactive Rebase Instructions

When asked to squash commits, provide clear steps:
1. Run `git log --oneline -n` to confirm the commit range
2. Run `git rebase -i HEAD~N` where N = number of commits
3. In the editor, change `pick` to `squash` (or `s`) for commits to combine
4. Save and close; a second editor will open for the combined commit message
5. Edit the final message, save, and close

### Branch Cleanup Report

```bash
echo "=== Stale Branches (merged into main) ==="
git branch --merged main | grep -v "main\|*" || echo "None found"

echo "=== Recent Branches (last 10) ==="
git for-each-ref --sort=-committerdate --format='%(committerdate:short) %(refname:short)' refs/heads/ | head -10

echo "=== Remote Tracking Branches (prunable) ==="
git remote prune --dry-run origin
```

### Bisect Progress Report

```bash
echo "=== Bisect Range ==="
echo "Good: $(git rev-parse $(git bisect start 2>/dev/null | grep -oP 'good commit is \K[a-f0-9]+'))"
echo "Bad:  $(git rev-parse HEAD)"

echo "=== Current Bisect Step ==="
git bisect log | tail -5
```

## Safety Checks

- **Never force push** to shared branches without confirming
- **Abort rebase** instead of merging if unsure
- **Use `-D` (force delete)** only for branches you personally own
- **Backup** before bisect if the codebase is fragile
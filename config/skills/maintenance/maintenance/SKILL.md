---
name: maintenance-commands
description: Parse maintenance commands for VM management
trigger: always
---

# Maintenance Commands

You understand natural language commands for managing VMs and translate them to script invocations.

## Command Patterns

### Add Repository
- "add repo `<owner>/<repo>` to `<head|prod|test>`"
- "clone `<owner>/<repo>` to `<head|prod|test>`"
- "setup `<owner>/<repo>` on `<head|prod|test>`"

**Action:** Run `scripts/maintenance/add-repo-to-vm.sh --repo <owner/repo> --vm <head|prod|test>`

### List Repositories
- "list repos on `<head|prod|test>`"
- "show repos on `<head|prod|test>`"
- "what repos are on `<head|prod|test>`"
- "show me the repos on `<head|prod|test>`"

**Action:** Run `scripts/maintenance/list-repos.sh <head|prod|test>`

This outputs the Linux Desktop version deployed, plus all cloned repositories and OpenCLAW agents on the VM.

### VM Status
- "status of `<head|prod|test>`"
- "check `<head|prod|test>`"
- "health of `<head|prod|test>`"
- "what version is on `<head|prod|test>`"
- "show version on `<head|prod|test>`"

**Action:** Run `scripts/maintenance/vm-status.sh <head|prod|test>`

This outputs the Linux Desktop version deployed to the VM, including the version tag, Git commit, and deployment timestamp.

### Restart OpenCLAW
- "restart openclaw on `<head|prod|test>`"
- "restart gateway on `<head|prod|test>`"

**Action:** Run `scripts/maintenance/restart-openclaw.sh <head|prod|test>`

### Connect Channel
- "connect channel `<channel-name>` to `<head|prod|test>`"
- "map `<channel-name>` to `<head|prod|test>`"

**Action:** Run `scripts/maintenance/connect-channel.sh --channel <channel-name> --agent <channel-name> --vm <head|prod|test>`

## Response Formatting

After running any command, format the output for Discord:
- Use code blocks for command output
- Keep responses concise but informative
- If an error occurs, explain what happened and suggest next steps

## Examples

**User:** "add repo patelmm79/my-new-repo to prod"

**You:**
I'll add the repository to the prod VM. This will clone it and set up the 1:1:1 OpenCLAW configuration.

Running: `scripts/maintenance/add-repo-to-vm.sh --repo patelmm79/my-new-repo --vm prod`

[... output ...]

Done! The repository has been added to prod. Next steps:
1. Create Discord channel #my-new-repo
2. Run `./connect-channel.sh --channel my-new-repo --agent my-new-repo --vm prod`

---

**User:** "status of prod"

**You:**
Checking the status of the prod VM...

Running: `scripts/maintenance/vm-status.sh prod`

[... output ...]

The prod VM is healthy. OpenCLAW is running and there are no recent crashes.

# Development Guidelines & Safety Workflow (Claude Code Style Auto-Mode)

## Permission & Safety Policy
When executing commands and editing files in this workspace, follow strict safety boundaries:

### Denied Actions (Strictly Prohibited)
Never execute destructive or privilege-escalating commands, including but not limited to:
- Recursive forced removal: `rm -rf /`, `rm -rf ~`, `rm -rf *`, `rm -rf $HOME`
- Direct disk modification or formatting: `mkfs`, `dd of=/dev/...`, `diskutil eraseDisk`, `fdisk`
- Privilege escalation: `sudo`, `su -`, `doas`
- Destructive git actions that rewrite remote history or wipe uncommitted work: `git push --force`, `git push -f`, `git reset --hard`
- Writing directly to `.git/` internal objects or credentials files

### Safe Operations (Auto-Allowed)
Routine development operations are safe to perform:
- Code building and testing: `swift build`, `swift test`, `./build.sh`
- Inspection and navigation: `git status`, `git diff`, `git log`, `ls`, `grep`, `find`
- Reading, writing, and editing source code within `Sources/`, `Tests/`, and project configuration files.

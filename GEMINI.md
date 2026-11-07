# Development Guidelines & Safety Workflow (Claude Code Style Auto-Mode)

## 1. Permission & Safety Policy
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

---

## 2. Standard Operating Procedure (SOP) Git & PR Lifecycle

Setiap ada task baru, wajib mengikuti urutan langkah ini secara disiplin:

### Langkah Wajib Sebelum Membuat Branch Baru (Selalu Mulai dari Main/Master Fresh):
1. **Pastikan berada di branch utama:**
   ```bash
   git checkout main
   ```
2. **Tarik perubahan paling mutakhir dari remote GitHub:**
   ```bash
   git pull origin main
   ```
3. **BARU setelah main up-to-date, buat branch baru dengan kode penomoran standar:**
   ```bash
   git checkout -b <type>/#<id>-<short-description>
   ```
   - `feat/#<id>-<slug>` (Fitur baru)
   - `fix/#<id>-<slug>` (Perbaikan bug)
   - `perf/#<id>-<slug>` (Optimasi performa / energy)
   - `refactor/#<id>-<slug>` (Restrukturisasi kode)
   - `chore/#<id>-<slug>` (Build script, toolings, config)
   *Contoh:* `fix/#1-multi-monitor-screen-focus`, `feat/#2-battery-status`
4. **Konfirmasi User:** Tanyakan ke user sebelum branch dibuat dan sebelum coding dimulai.

### Langkah Saat Pengerjaan & Commit:
- Kerjakan perubahan kode dan uji dengan `swift test` atau `./build.sh`.
- Lakukan commit berkala menggunakan Conventional Commits:
  - `fix(#<id>): <deskripsi>`
  - `feat(#<id>): <deskripsi>`
- Push branch ke GitHub: `git push -u origin <branch-name>`

### Langkah Saat Membuka PR (Format Matt Pocock + UI Screenshot):
Ketika user meminta membuat PR:
1. Susun template PR dengan isi:
   - **Summary:** Diagram alur / arsitektur visual.
   - **Evidence:** Wajib tabel screenshot Before vs After jika ada perubahan UI, serta log test.
   - **Merge Danger:** One-way / Two-way door & Blast radius.
2. Minta konfirmasi user, lalu submit PR via GitHub CLI (`gh pr create`) atau link perbandingan GitHub.

### Langkah Setelah PR Ter-merge (Post-Merge Cleanup):
Ketika user memberitahu bahwa PR sudah di-merge:
1. `git checkout main`
2. `git pull origin main`
3. `git branch -d <branch-lama>`
4. `git fetch --prune`
5. Konfirmasi ke user bahwa branch lama sudah dibersihkan dan `main` sudah sinkron, lalu bersiap untuk task berikutnya.

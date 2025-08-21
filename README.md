# zfsdu

**`zfsdu.sh` — ncdu-like single-window navigation for ZFS (with marking/deleting)**  
A terminal-based user interface (TUI) for inspecting ZFS datasets, volumes, and snapshots. Inspired by `ncdu`, but tailored for ZFS environments like Proxmox and OpenZFS.

---

## 📦 Features

- Human-readable overview of ZFS filesystems, sorted by usage
- Interactive navigation through datasets, volumes, and snapshots
- Snapshot size toggle (`used` vs `referenced`)
- Multi-select and deletion of marked entries
- Optional color output and filtering via `fzf`
- No recursion beyond level 1 for clarity and performance

---

## 🧭 Display & Navigation

- **Main list**: Filesystems (sorted by `used`)
- **Enter/→ on a filesystem**: Shows level-1 volumes + snapshots of the filesystem
- **Enter/→ on a volume**: Shows snapshots of that volume (filesystem remains open)
- **No recursion** beyond level 1; snapshots appear only when pressing Enter
---

## ⚙️ Usage

```bash
zfsdu.sh [OPTIONS]

Usage: zfsdu.sh [OPTIONS]
  -d DATASET     Focus on DATASET (shows DATASET + level-1 filesystems)
  -m MODE        'used' (default) or 'refer' (== referenced; for snapshot display size)
  --show-zero    (compatibility option) show 0B snapshots — default is already to show them
  --hide-zero    hide 0B snapshots (only effective in MODE=used)
  --no-color     Disable colors
  -h, --help     Help

Keys:
  ↑/↓              Move
  Enter/→          Open/close
  Backspace/←      Go back (collapse)   [in fzf: 'bspace']
  Spacebar         Mark/unmark (multi-select)
  d                Delete marked entries (with confirmation)
  r                Toggle snapshot display size (used ↔ referenced)
  z                Toggle 0B snapshots (only in MODE=used)
  q / ESC / Ctrl-C Exit
  Typing           Filter (fzf)

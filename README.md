# Steam Game Cleaner

Removes extra files from Steam game installations by comparing against depot manifests.

## How it works

1. Reads local depot manifests from `Steam/depotcache/`
2. Scans the installed game directory
3. Compares the two file lists
4. Shows you what would be deleted (dry-run)
5. Asks for confirmation before removing anything

## Scripts

### Python (Linux/Windows)

Requires Python 3.8+ with `steam` and `vdf` libraries.

```bash
python -m venv venv
source venv/bin/activate  # On Windows: venv\Scripts\activate
pip install steam vdf
python steam_games_cleaner.py
```

## Features

- **No Steam login required** - uses local manifests only
- **Auto-detects** Steam installation and library folders
- **Case-insensitive** file comparison (handles NTFS on Linux)
- **Safety checks** - warns when depot manifests are missing and refuses to delete if none are found
- **Dry-run first** - shows extra files and total size before asking for confirmation
- **Cleans up** empty directories after deletion

## Notes

- Depot manifests are cached by Steam only for recently accessed/updated games. If a game hasn't been updated in a while, its manifests may be missing. Try updating/ verifying the game files in Steam first.
- Mod files or other user-added files not in manifests will be flagged as extra. Move them to a backup location before running the script.
- The script only removes files, never directories with content.

# Steam Game Cleaner

Removes extra files from Steam game installations by comparing against depot manifests.

## How it works

1. Reads local depot manifests from `Steam/depotcache/`
2. Scans the installed game directory
3. Compares the two file lists
4. Shows you what would be deleted (dry-run)
5. Asks for confirmation before removing anything

## Requirements

- Python 3.8+
- `steam` library
- `vdf` library

## Installation

```bash
python -m venv venv
source venv/bin/activate
pip install steam vdf
```

## Usage

```bash
python steam_games_cleaner.py
```

The script will:
1. Auto-detect your Steam installation
2. List all installed games
3. Let you select which game to clean
4. Parse local depot manifests for that game
5. Show extra files and total size
6. Ask for confirmation before deleting

## Notes

- No Steam login required - uses local manifests only
- If depot manifests are missing (game hasn't been updated recently), the script will warn you
- Mod files not in manifests will be flagged as extra - move them elsewhere first

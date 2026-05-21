#!/usr/bin/env python3
"""Steam Game Cleaner - Removes extra files not in Steam depot manifests."""

import os
import sys
import logging
from pathlib import Path

import vdf
from steam.core.manifest import DepotManifest

logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")
logger = logging.getLogger(__name__)

STEAM_PATHS = [
    Path.home() / ".steam" / "steam",
    Path.home() / ".steam" / "root",
    Path.home() / ".local" / "share" / "Steam",
]

COMMON_MOUNT_POINTS = [
    "/run/media",
    "/media",
    "/mnt",
]


def find_steam_path():
    for p in STEAM_PATHS:
        if p.exists():
            return p.resolve()

    def scan_level(base, depth=3):
        if depth <= 0 or not base.exists():
            return None
        for entry in sorted(base.iterdir()):
            if not entry.is_dir():
                continue
            candidate = entry / "Steam"
            if (candidate / "steamapps" / "libraryfolders.vdf").exists():
                return candidate.resolve()
            candidate2 = entry / "Program Files (x86)" / "Steam"
            if (candidate2 / "steamapps" / "libraryfolders.vdf").exists():
                return candidate2.resolve()
            result = scan_level(entry, depth - 1)
            if result:
                return result
        return None

    for mount_base in COMMON_MOUNT_POINTS:
        result = scan_level(Path(mount_base))
        if result:
            return result

    return None


def prompt_steam_path():
    print("\nSteam installation not auto-detected.")
    print("Searching for Steam installations...")
    found = []

    def scan_level(base, depth=3):
        if depth <= 0 or not base.exists():
            return
        for entry in sorted(base.iterdir()):
            if not entry.is_dir():
                continue
            candidate = entry / "Steam"
            if (candidate / "steamapps").exists():
                found.append(candidate.resolve())
            candidate2 = entry / "Program Files (x86)" / "Steam"
            if (candidate2 / "steamapps").exists():
                found.append(candidate2.resolve())
            scan_level(entry, depth - 1)

    for mount_base in COMMON_MOUNT_POINTS:
        scan_level(Path(mount_base))

    if found:
        print(f"  Found: {found[0]}")
        return found[0]

    while True:
        path = input("\nEnter Steam installation path: ").strip()
        if not path:
            return None
        p = Path(path).resolve()
        if (p / "steamapps").exists():
            return p
        print(f"  Not a valid Steam path: {p}")


def find_all_steamapps_dirs(steam_path):
    steamapps_dirs = []
    sa = steam_path / "steamapps"
    if sa.exists():
        steamapps_dirs.append(sa.resolve())

    def scan_level(base, depth=3):
        if depth <= 0 or not base.exists():
            return
        for entry in sorted(base.iterdir()):
            if not entry.is_dir():
                continue
            sa = entry / "steamapps"
            if sa.exists() and sa.resolve() not in steamapps_dirs:
                steamapps_dirs.append(sa.resolve())
            sa2 = entry / "SteamLibrary" / "steamapps"
            if sa2.exists() and sa2.resolve() not in steamapps_dirs:
                steamapps_dirs.append(sa2.resolve())
            scan_level(entry, depth - 1)

    for mount_base in COMMON_MOUNT_POINTS:
        scan_level(Path(mount_base))

    return steamapps_dirs


def find_library_folders(steam_path):
    all_steamapps = find_all_steamapps_dirs(steam_path)
    folders = []
    for sa in all_steamapps:
        folder = sa.parent
        if folder not in folders:
            folders.append(folder)
    if not folders:
        folders.append(steam_path)
    return folders


def get_installed_games(library_folders):
    games = []
    for folder in library_folders:
        steamapps = folder / "steamapps"
        if not steamapps.exists():
            continue
        for acf in sorted(steamapps.glob("appmanifest_*.acf")):
            try:
                with open(acf, "r") as f:
                    data = vdf.load(f)
                appinfo = data.get("AppState", {})
                appid = int(appinfo.get("appid", 0))
                name = appinfo.get("name", appinfo.get("Universe", "Unknown"))
                installdir = appinfo.get("installdir", "")
                if appid and installdir:
                    install_path = steamapps / "common" / installdir
                    games.append({
                        "appid": appid,
                        "name": name,
                        "installdir": installdir,
                        "install_path": install_path,
                        "library": folder,
                    })
            except Exception as e:
                logger.debug("Failed to parse %s: %s", acf, e)
    return games


def get_app_depot_ids(steam_path, appid, library_folders=None):
    depot_ids = set()

    if library_folders is None:
        library_folders = find_library_folders(steam_path)

    for folder in library_folders:
        acf_path = folder / "steamapps" / f"appmanifest_{appid}.acf"
        if acf_path.exists():
            try:
                with open(acf_path, "r") as f:
                    acf_data = vdf.load(f)
                app_state = acf_data.get("AppState", {})
                for key in app_state.get("InstalledDepots", {}):
                    if key.isdigit():
                        depot_ids.add(int(key))
                for key in app_state.get("SharedDepots", {}):
                    if key.isdigit():
                        depot_ids.add(int(key))
                if depot_ids:
                    break
            except Exception as e:
                logger.debug("Failed to parse %s: %s", acf_path, e)

    appinfo_vdf = steam_path / "appcache" / "appinfo.vdf"
    if not depot_ids and appinfo_vdf.exists():
        try:
            with open(appinfo_vdf, "rb") as f:
                data = vdf.binary_load(f)
            app_data = data.get(str(appid), {})
            depots = app_data.get("depots", {})
            for key, value in depots.items():
                if key.isdigit() and isinstance(value, dict):
                    depot_ids.add(int(key))
        except Exception as e:
            logger.debug("Failed to parse appinfo.vdf: %s", e)

    return depot_ids


def get_manifest_files(steam_path, appid, library_folders=None):
    depotcache_dirs = [
        steam_path / "depotcache",
        steam_path / "config" / "depotcache",
    ]

    app_depot_ids = get_app_depot_ids(steam_path, appid, library_folders)
    if app_depot_ids:
        logger.info("AppID %d has %d depot(s): %s", appid, len(app_depot_ids), sorted(app_depot_ids))
    else:
        logger.warning("Could not determine depot IDs for AppID %d, using all manifests", appid)

    all_files = set()
    manifest_count = 0
    parse_errors = 0
    depots_with_manifests = set()

    for depotcache in depotcache_dirs:
        if not depotcache.exists():
            continue

        for manifest_path in sorted(depotcache.glob("*.manifest")):
            filename = manifest_path.name.replace(".manifest", "")
            parts = filename.split("_", 1)
            if len(parts) != 2:
                continue

            try:
                depot_id = int(parts[0])
            except ValueError:
                continue

            if app_depot_ids and depot_id not in app_depot_ids:
                continue

            try:
                with open(manifest_path, "rb") as f:
                    manifest = DepotManifest(f.read())

                manifest_count += 1
                depots_with_manifests.add(depot_id)

                if manifest.filenames_encrypted:
                    logger.warning("  %s: filenames encrypted, skipping", manifest_path.name)
                    continue

                for mf in manifest.iter_files():
                    if not mf.filename.endswith("/"):
                        all_files.add(mf.filename.replace("\\", "/").lower())

            except Exception as e:
                parse_errors += 1
                logger.debug("  Failed to parse %s: %s", manifest_path.name, e)

    logger.info("Parsed %d manifest(s) from %d depot(s), %d unique files (%d errors)", manifest_count, len(depots_with_manifests), len(all_files), parse_errors)

    if app_depot_ids:
        missing_depots = app_depot_ids - depots_with_manifests
        if missing_depots:
            logger.warning("Missing manifests for %d depot(s): %s", len(missing_depots), sorted(missing_depots))

    return all_files, depots_with_manifests


def get_installed_files(install_path):
    logger.info("Scanning installed files in %s...", install_path)
    installed = {}
    file_count = 0

    for root, dirs, files in os.walk(install_path):
        for f in files:
            full_path = Path(root) / f
            rel_path = full_path.relative_to(install_path)
            rel_str = str(rel_path).replace("\\", "/")
            installed[rel_str.lower()] = rel_str
            file_count += 1

    logger.info("Found %d installed files", file_count)
    return installed


def format_size(size_bytes):
    for unit in ["B", "KB", "MB", "GB", "TB"]:
        if size_bytes < 1024:
            return f"{size_bytes:.1f} {unit}"
        size_bytes /= 1024
    return f"{size_bytes:.1f} PB"


def select_game(games):
    print("\nInstalled games:")
    for i, game in enumerate(games, 1):
        print(f"  {i:3d}. {game['name']} (AppID: {game['appid']})")

    while True:
        try:
            choice = input("\nSelect game (number): ").strip()
            idx = int(choice) - 1
            if 0 <= idx < len(games):
                return games[idx]
            print(f"Please enter a number between 1 and {len(games)}")
        except ValueError:
            print("Please enter a valid number")


def main():
    print("=" * 60)
    print("Steam Game Cleaner")
    print("=" * 60)

    steam_path = find_steam_path()
    if not steam_path:
        steam_path = prompt_steam_path()
        if not steam_path:
            logger.error("Steam installation not found")
            sys.exit(1)
    logger.info("Steam path: %s", steam_path)

    library_folders = find_library_folders(steam_path)
    if not library_folders:
        logger.error("No Steam library folders found")
        sys.exit(1)
    logger.info("Found %d library folder(s)", len(library_folders))

    games = get_installed_games(library_folders)
    if not games:
        logger.error("No installed games found")
        sys.exit(1)
    logger.info("Found %d installed game(s)", len(games))

    game = select_game(games)
    print(f"\nSelected: {game['name']} (AppID: {game['appid']})")
    print(f"Install path: {game['install_path']}")

    if not game["install_path"].exists():
        logger.error("Game install path does not exist: %s", game["install_path"])
        sys.exit(1)

    manifest_files, depots_with_manifests = get_manifest_files(steam_path, game["appid"], library_folders)
    installed_files = get_installed_files(game["install_path"])

    app_depot_ids = get_app_depot_ids(steam_path, game["appid"], library_folders)
    if app_depot_ids:
        missing_count = len(app_depot_ids - depots_with_manifests)
        total_depots = len(app_depot_ids)
        if missing_count > 0 and missing_count == total_depots:
            logger.error("No depot manifests found for this game. Cannot safely determine extra files.")
            logger.error("This usually means the game hasn't been updated recently enough to cache manifests.")
            logger.error("Try updating the game via Steam first, then run this script again.")
            return
        elif missing_count > total_depots * 0.5:
            logger.warning("Missing manifests for %d/%d depots. Results may be inaccurate.", missing_count, total_depots)
            answer = input("Continue anyway? (yes/no): ").strip().lower()
            if answer not in ("yes", "y"):
                print("Aborted.")
                return

    extra_files = {}
    for lower_path, original_path in installed_files.items():
        if lower_path not in manifest_files:
            extra_files[lower_path] = original_path

    if not extra_files:
        print("\nNo extra files found. Game is clean!")
        return

    print(f"\nFound {len(extra_files)} extra file(s) not in Steam manifests")

    extra_paths = []
    total_size = 0
    for lower_path in sorted(extra_files.keys()):
        original_path = extra_files[lower_path]
        full = game["install_path"] / original_path
        if full.exists() and full.is_file():
            size = full.stat().st_size
            total_size += size
            extra_paths.append((full, original_path, size))

    print(f"Total extra size: {format_size(total_size)}")
    print("\nExtra files (first 50):")
    for full, rel, size in extra_paths[:50]:
        print(f"  {rel} ({format_size(size)})")
    if len(extra_paths) > 50:
        print(f"  ... and {len(extra_paths) - 50} more")

    answer = input("\nDelete these extra files? (yes/no): ").strip().lower()
    if answer not in ("yes", "y"):
        print("Aborted. No files deleted.")
        return

    print("\nDeleting extra files...")
    deleted_count = 0
    deleted_size = 0
    failed = []

    for full, rel, size in extra_paths:
        try:
            full.unlink()
            deleted_count += 1
            deleted_size += size
        except Exception as e:
            failed.append((rel, str(e)))

    print(f"\nDeleted {deleted_count} files ({format_size(deleted_size)})")

    if failed:
        print(f"\nFailed to delete {len(failed)} file(s):")
        for rel, err in failed:
            print(f"  {rel}: {err}")

    print("\nRemoving empty directories...")
    removed_dirs = 0
    for root, dirs, files in os.walk(game["install_path"], topdown=False):
        for d in dirs:
            dir_path = Path(root) / d
            try:
                if not any(dir_path.iterdir()):
                    dir_path.rmdir()
                    removed_dirs += 1
            except Exception:
                pass

    print(f"Removed {removed_dirs} empty director{'y' if removed_dirs == 1 else 'ies'}")

    print("\nDone!")


if __name__ == "__main__":
    main()

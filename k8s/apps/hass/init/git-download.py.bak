import os
import asyncio
import hashlib
from pathlib import Path
from typing import Optional, Any
import logging
import yaml
from git import Repo, GitCommandError, InvalidGitRepositoryError
import httpx
import aiofiles

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("fast_git_clone")

CACHE_DIR = Path(os.environ.get("CLONE_CACHE_DIR", "/tmp/git-clones"))  # Temporary cache for cloned repos


async def ensure_directory(path: Path) -> None:
    """Ensure a directory exists asynchronously."""
    path.mkdir(parents=True, exist_ok=True)


async def calculate_md5(file_path: Path) -> Optional[str]:
    """
    Calculate the MD5 checksum of a file asynchronously.

    Args:
        file_path: Path to the file.

    Returns:
        The MD5 checksum as a string, or None if the file does not exist.
    """
    if not file_path.exists():
        return None

    hash_md5 = hashlib.md5()
    async with aiofiles.open(file_path, "rb") as f:
        while chunk := await f.read(4096):
            hash_md5.update(chunk)

    return hash_md5.hexdigest()


async def download_file(url: str, dest: Path, expected_md5: Optional[str] = None) -> None:
    """
    Download a file from a URL to the destination path asynchronously.

    Args:
        url: The URL to download from.
        dest: The destination path.
        expected_md5: The expected MD5 checksum of the file.

    Raises:
        ValueError: If the MD5 checksum does not match.
    """
    async with httpx.AsyncClient(follow_redirects=True) as client:
        response = await client.get(url)
        response.raise_for_status()

        # Ensure the destination directory exists
        await ensure_directory(dest.parent)

        # Save the file content to the destination path
        async with aiofiles.open(dest, "wb") as f:
            await f.write(response.content)

    # Validate the MD5 checksum, if provided
    if expected_md5:
        downloaded_md5 = await calculate_md5(dest)
        if downloaded_md5 != expected_md5:
            dest.unlink()  # Remove the invalid file
            raise ValueError(
                f"MD5 mismatch for {dest}: expected {expected_md5}, got {downloaded_md5}"
            )

   

async def clone_or_update_repo(url: str, cache_dir: Path, ref: Optional[str] = None) -> Optional[Path]:
    """
    Clone the repository if not cached; update if already cached.

    Args:
        url: The URL of the repository.
        cache_dir: Path to the cache directory.
        ref: A specific branch, tag, or commit SHA to checkout.

    Returns:
        Path to the local repository if successful, otherwise None.
    """
    repo_name = url.split("/")[-1].replace(".git", "")
    repo_path = cache_dir / repo_name

    try:
        if repo_path.exists():
            repo = Repo(repo_path)
            repo.git.fetch()  # Fetch latest changes
        else:
            repo = Repo.clone_from(url, repo_path)

        if ref:
            repo.git.checkout(ref)  # Checkout tag, branch, or SHA
        else:
            repo.git.checkout(repo.remotes.origin.refs[0].name)  # Default branch
    except (GitCommandError, InvalidGitRepositoryError) as e:
        logger.error(f"Failed to clone/update repo {url}: {e}")
        return None
    return repo_path


import aiofiles.os
import os


async def copy_path(src: Path, dest: Path) -> None:
    """
    Copy a file or directory from the source to the destination asynchronously.

    Args:
        src: The source path (file or directory).
        dest: The destination path.
    """
    try:
        if src.is_file():
            # Ensure the destination directory exists
            await ensure_directory(dest.parent)

            # Asynchronously copy the file
            async with aiofiles.open(src, "rb") as src_file, aiofiles.open(dest, "wb") as dest_file:
                while chunk := await src_file.read(65535):
                    await dest_file.write(chunk)

            logger.info(f"Copied file {src} to {dest}")
        elif src.is_dir():
            # Ensure the destination directory exists
            await ensure_directory(dest)

            # Recursively copy all contents
            async for item in aiofiles.os.scandir(src):
                item_path = Path(item.path)
                await copy_path(item_path, dest / item_path.name)

            logger.info(f"Copied directory {src} to {dest}")
        else:
            logger.error(f"Source path {src} does not exist or is unsupported.")
    except Exception as e:
        logger.error(f"Failed to copy {src} to {dest}: {e}")



async def process_repo(repo_data: dict[str, Any], cache_dir: Path, default_target_dir: str) -> None:
    """
    Process a single repository: clone/update or download and copy paths.

    Args:
        repo_data: A dictionary containing repo details.
        cache_dir: Path to the cache directory.
        default_target_dir: Default target directory for copies.
    """
    url = repo_data.get("url")
    ref = repo_data.get("tag")
    src = repo_data.get("src")
    dest = repo_data.get("dest", default_target_dir)
    md5 = repo_data.get("md5")
    copy_contents = repo_data.get("copy_contents", False)  # New flag to control copying contents

    if not url or not src:
        logger.error("Invalid repo data: 'url' and 'src' are required.")
        return

    if "/releases/" in url and ref and ref.startswith("release_"):
        # Handle GitHub release downloads
        release_version = ref.replace("release_", "")
        file_url = f"{url.replace('/tag', '')}/download/{release_version}/{src}"
        cached_file = cache_dir / f"{release_version}-{src}"

        if cached_file.exists() and md5 and (await calculate_md5(cached_file)) == md5:
            logger.info(f"Using cached release file: {cached_file}")
        else:
            logger.info(f"Downloading release file from {file_url} to {cached_file}")
            try:
                await download_file(file_url, cached_file, expected_md5=md5)
            except ValueError as e:
                logger.error(f"Failed to download file: {e}")
                return

        await copy_path(cached_file, Path(dest))
    else:
        # Handle regular repository processing
        repo_path = await clone_or_update_repo(url, cache_dir, ref)  # Await this directly
        if repo_path:
            # Check if src is a directory and if we need to copy contents
            src_path = repo_path / src
            if src_path.is_dir() and copy_contents:
                # If copy_contents is True, copy the contents of the src directory
                for item in await aiofiles.os.scandir(src_path):
                    item_path = Path(item.path)
                    await copy_path(item_path, Path(dest) / item_path.name)
                logger.info(f"Copied contents from {src_path} to {dest}")
            else:
                # Otherwise, copy the whole src directory
                await copy_path(src_path, Path(dest))

def load_repo_data(file_path: str) -> list[dict[str, Any]]:
    """
    Load repository data from a YAML file.

    Args:
        file_path: Path to the YAML file containing repository data.

    Returns:
        A list of dictionaries representing repositories.
    """
    try:
        with open(file_path, "r") as f:
            return yaml.safe_load(f)
    except (FileNotFoundError, yaml.YAMLError) as e:
        logger.error(f"Failed to load repo data from {file_path}: {e}")
        return []


async def main() -> None:
    """
    Main function to orchestrate repository processing.
    """
    repo_data_file = os.getenv("REPO_DATA_FILE")
    default_target_dir = os.getenv("TARGET_DIR")

    if not repo_data_file or not default_target_dir:
        logger.error(
            "Environment variables REPO_DATA_FILE and TARGET_DIR are required."
        )
        return

    repo_list = load_repo_data(repo_data_file)

    await ensure_directory(CACHE_DIR)

    # Process all repositories in parallel
    tasks = [
        process_repo(repo, CACHE_DIR, default_target_dir)
        for repo in repo_list
    ]
    await asyncio.gather(*tasks)


if __name__ == "__main__":
    asyncio.run(main())

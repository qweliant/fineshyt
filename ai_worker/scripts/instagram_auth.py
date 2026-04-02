"""
One-time Instagram session setup. Run via: make instagram-auth
Reads INSTAGRAM_USERNAME and INSTAGRAM_PASSWORD from the environment (loaded from ai_worker/.env).
Saves a session file so the API worker never needs to do a fresh password login.
"""

import os
import sys

import instaloader

username = os.environ.get("INSTAGRAM_USERNAME", "")
password = os.environ.get("INSTAGRAM_PASSWORD", "")

PINK = "\033[38;5;212m"
BOLD = "\033[1m"
RESET = "\033[0m"


def say(msg):
    print(f"{PINK}{BOLD}  (◕‿◕✿) {msg}{RESET}")


def err(msg):
    print(f"\033[38;5;135m{BOLD}  (=｀ω´=) {msg}{RESET}")


if not username or not password:
    err("INSTAGRAM_USERNAME and INSTAGRAM_PASSWORD must be set in ai_worker/.env")
    sys.exit(1)

say(f"logging in as @{username}...")
loader = instaloader.Instaloader()

try:
    loader.login(username, password)
except instaloader.exceptions.BadCredentialsException:
    err(f"bad credentials for @{username} — double check your password in ai_worker/.env")
    sys.exit(1)
except instaloader.exceptions.TwoFactorAuthRequiredException:
    err(f"@{username} has 2FA — run interactively instead:")
    print(f"        cd ai_worker && uv run instaloader --login={username}")
    sys.exit(1)
except Exception as e:
    err(f"login failed: {e}")
    sys.exit(1)

loader.save_session_to_file()
say(f"session saved for @{username} ✦")

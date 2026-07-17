# minecraft-deb-ubuntu-fix

Install the official **Minecraft Launcher `.deb`** on modern **Ubuntu (24.04+, incl. 26.04)** when it fails with a dependency error like:

```
minecraft-launcher : Depends: libgdk-pixbuf2.0-0 (>= 2.22.0) but it is not installable
```

or when the installer complains about a missing **Java** runtime.

This isn't a Minecraft bug — it's package metadata that hasn't kept up with Ubuntu's library renames. The launcher itself runs fine once the `.deb` installs.

## TL;DR

```bash
# 1. Download the Debian/Ubuntu launcher from https://www.minecraft.net/download
#    (usually lands in ~/Downloads/Minecraft.deb)

# 2. Run the script
chmod +x install-minecraft.sh
./install-minecraft.sh              # uses ~/Downloads/Minecraft.deb
# or point it at the file:
./install-minecraft.sh ~/Downloads/Minecraft.deb
```

Then launch from your app menu, or run `minecraft-launcher`.

## What it does

1. **Installs Java first.** The `.deb` depends on `default-jre`, but a fresh system has none, so the install aborts before it starts. The script installs `default-jre` up front. *(If you already have any JRE/JDK, it's left alone.)*
2. **Repairs stale dependency names.** It simulates the install (`apt-get install -s`), reads back exactly which dependencies apt calls *"not installable"*, finds the current package that satisfies each, rewrites them in a repacked copy of the `.deb`, and installs that. Your original download is never modified.
3. **Verifies** that `minecraft-launcher` landed on your `PATH`.

If a stale dependency can't be matched to any current package, the script **stops and tells you** rather than installing something broken.

## Why the vendor `.deb` breaks on new Ubuntu

Two rounds of renaming:

- **The 64-bit `time_t` transition (Ubuntu 24.04+)** renamed many libraries with a `t64` suffix — `libcurl4` → `libcurl4t64`, `libasound2` → `libasound2t64`, `libgcc1` → `libgcc-s1`, and so on. These carry a compatibility `Provides:`, so apt matches the old names automatically. **Not** the problem.
- **`libgdk-pixbuf2.0-0` → `libgdk-pixbuf-2.0-0`** (note the extra dash) has **no** such `Provides:`. The library is installed and newer than required, but apt can't match the old name — so the whole install fails. **This** is the blocker.

The script's rename detection handles both shapes (and appends/inserts the common patterns for forward-compatibility with future renames).

## Requirements

- Ubuntu / Debian with `apt-get` and `dpkg-deb` (standard).
- `sudo` access (for installing packages).
- The official Minecraft launcher `.deb` from <https://www.minecraft.net/download>.

## Manual fix (if you prefer to do it by hand)

```bash
# Java
sudo apt-get update && sudo apt-get install -y default-jre

# Repack the .deb with the corrected dependency name
mkdir /tmp/mc && dpkg-deb -R ~/Downloads/Minecraft.deb /tmp/mc
sed -i 's/libgdk-pixbuf2\.0-0/libgdk-pixbuf-2.0-0/g' /tmp/mc/DEBIAN/control
dpkg-deb -b /tmp/mc ~/Downloads/Minecraft-fixed.deb

# Install (apt resolves the rest via Provides)
sudo apt-get install -y ~/Downloads/Minecraft-fixed.deb
```

## Contributing

Hit a *different* "not installable" dependency? Open an issue with your Ubuntu
version (`cat /etc/os-release`) and the script output — or send a PR adding the
mapping to `KNOWN_RENAMES` in `install-minecraft.sh`.

## License

MIT — see [LICENSE](LICENSE). Not affiliated with or endorsed by Mojang or Microsoft. "Minecraft" is a trademark of Mojang Synergies AB.

#!/usr/bin/env fish
# Build macOS ARM64 (.dmg) locally and upload it to the matching GitHub Release.

set -l skip_prebuild false
set -l release_tag ''

for arg in $argv
    switch $arg
        case --skip-prebuild
            set skip_prebuild true
        case '-h' '--help'
            echo 'Usage: ./scripts/release-mac.fish [release_tag] [--skip-prebuild]'
            exit 0
        case '*'
            set release_tag $arg
    end
end

set -l repo_root (git rev-parse --show-toplevel)
or exit 1
cd $repo_root

set -l app_version (node -p "require('./package.json').version")
or exit 1
if test -z "$release_tag"
    set release_tag "v$app_version"
end

set -l toolchain_channel (sed -n 's/^channel *= *"\([^"]*\)"/\1/p' rust-toolchain.toml)
set -l toolchain_bin "$HOME/.rustup/toolchains/$toolchain_channel-aarch64-apple-darwin/bin"
if test -d "$toolchain_bin"
    set -gx PATH "$toolchain_bin" $PATH
end

set -l tmp_conf (mktemp /tmp/tauri.local-nosign.XXXXXX.json)
set -l stage_dir (mktemp -d /tmp/verge-mac-release.XXXXXX)
function cleanup --inherit-variable tmp_conf --inherit-variable stage_dir
    rm -rf "$tmp_conf" "$stage_dir"
end
trap cleanup EXIT

node -e "require('fs').writeFileSync(process.argv[1], JSON.stringify({bundle:{createUpdaterArtifacts:false}}))" "$tmp_conf"
or exit 1

if test "$skip_prebuild" = false
    pnpm install --frozen-lockfile
    or exit 1
    pnpm run prebuild aarch64-apple-darwin
    or exit 1
end

set -lx RUSTFLAGS ''
pnpm build --target aarch64-apple-darwin -b dmg -c "$tmp_conf"
or exit 1

set -l origin_url (git remote get-url origin)
or exit 1
set -l origin_repo (string replace -r '^.*github\.com[:/]([^/]+/[^/.]+)(\.git)?$' '$1' "$origin_url")

set -l expected_dmg "target/aarch64-apple-darwin/release/bundle/dmg/Clash Verge_"$app_version"_aarch64.dmg"
if not test -f "$expected_dmg"
    set -l dmg_files target/aarch64-apple-darwin/release/bundle/dmg/*.dmg
    if test (count $dmg_files) -eq 0
        echo 'Error: no .dmg bundle found' >&2
        exit 1
    end
    set expected_dmg (ls -t $dmg_files | head -n 1)
end

set -l normalized_name (string replace -a ' ' '.' (basename "$expected_dmg"))
set -l staged_dmg "$stage_dir/$normalized_name"
ln -sf "$repo_root/$expected_dmg" "$staged_dmg"

if not gh release view "$release_tag" --repo "$origin_repo" >/dev/null 2>&1
    gh release create "$release_tag" \
        --repo "$origin_repo" \
        --target (git rev-parse --abbrev-ref HEAD) \
        --title "Clash Verge Rev $release_tag" \
        --generate-notes
    or exit 1
end

gh release upload "$release_tag" "$staged_dmg" --repo "$origin_repo" --clobber
or exit 1

echo "Uploaded $normalized_name to $origin_repo release $release_tag"

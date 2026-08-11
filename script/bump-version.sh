#!/usr/bin/env bash
# Bump the patch version, commit, tag vX.Y.Z, and push to main.
#
# Mirrors yatfa's script/bump-version.sh, adapted for a gem:
#   - the version source is lib/specguard/rspec/version.rb (the gemspec reads
#     SpecGuard::RSpec::VERSION from it), not a VERSION file
#   - release is tag-based like warden's: the GitHub Release and the pushed gem
#     both correspond to vX.Y.Z. There is no `prod` deploy-mirror branch —
#     nothing here is deployed to a cluster.
#
# Strategy carried over verbatim: must be on main with a clean tree, patch-only
# bump, commit "bump: X -> Y", pull --rebase + push with up to 3 retries.
#
# When run inside GitHub Actions (GITHUB_OUTPUT set), exports `version` and
# `tag` to the step's job outputs. Locally it just prints the new version.
set -e

VERSION_FILE="lib/specguard/rspec/version.rb"

# Ensure we're on the main branch
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [ "$CURRENT_BRANCH" != "main" ]; then
    echo "Error: Not on main branch. Current branch: $CURRENT_BRANCH"
    exit 1
fi

# Check if working directory is clean
if [ -n "$(git status --porcelain)" ]; then
    echo "Error: Working directory has uncommitted changes"
    exit 1
fi

if [ ! -f "$VERSION_FILE" ]; then
    echo "Error: $VERSION_FILE not found"
    exit 1
fi

CURRENT_VERSION=$(ruby -e 'require "./lib/specguard/rspec/version"; print SpecGuard::RSpec::VERSION')
echo "Current version: $CURRENT_VERSION"

# Bump patch version (0.2.0 -> 0.2.1)
IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT_VERSION"
NEW_VERSION="$MAJOR.$MINOR.$((PATCH + 1))"
echo "New version: $NEW_VERSION"

# A published gem version is immutable — RubyGems refuses a re-push and yanking
# does not free the number. Refuse locally rather than discovering it after a
# build, and refuse a reused tag for the same reason the release does.
if git rev-parse -q --verify "refs/tags/v$NEW_VERSION" >/dev/null || \
   git ls-remote --exit-code --tags origin "refs/tags/v$NEW_VERSION" >/dev/null 2>&1; then
    echo "Error: tag v$NEW_VERSION already exists — the version file and the tags disagree"
    exit 1
fi
if command -v curl >/dev/null 2>&1; then
    if curl -fsS --max-time 10 "https://rubygems.org/api/v1/versions/specguard-rspec.json" 2>/dev/null \
       | grep -q "\"number\":\"$NEW_VERSION\""; then
        echo "Error: specguard-rspec $NEW_VERSION is already published on RubyGems"
        exit 1
    fi
fi

# Rewrite the VERSION constant in place. A targeted sed on the one line, so the
# surrounding file (frozen_string_literal, module nesting) is untouched.
sed -i.bak -E "s/(VERSION = \")[0-9]+\.[0-9]+\.[0-9]+(\")/\1$NEW_VERSION\2/" "$VERSION_FILE"
rm -f "$VERSION_FILE.bak"
WROTE=$(ruby -e 'load "./lib/specguard/rspec/version.rb"; print SpecGuard::RSpec::VERSION')
if [ "$WROTE" != "$NEW_VERSION" ]; then
    echo "Error: $VERSION_FILE still reports $WROTE after the rewrite"
    exit 1
fi

# Create commit
git add "$VERSION_FILE"
git commit -m "bump: $CURRENT_VERSION -> $NEW_VERSION"

# Tag the release. The GitHub Release and the pushed .gem both correspond to it.
git tag "v$NEW_VERSION"

# Pull with rebase to incorporate any commits that landed on main since checkout,
# then push the branch and the tag. Retry up to 3 times to handle concurrent pushes.
MAX_RETRIES=3
RETRY_COUNT=0
PUSH_SUCCESS=false

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    if git pull --rebase origin main; then
        if git push origin main && git push origin "v$NEW_VERSION"; then
            PUSH_SUCCESS=true
            break
        fi
    fi
    RETRY_COUNT=$((RETRY_COUNT + 1))
    if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
        echo "Push failed, retrying ($RETRY_COUNT/$MAX_RETRIES)..."
        sleep 5
    fi
done

if [ "$PUSH_SUCCESS" = false ]; then
    echo "Error: Failed to push version bump after $MAX_RETRIES attempts"
    exit 1
fi

echo "Version bumped to $NEW_VERSION and pushed to main with tag v$NEW_VERSION"

# Export to GitHub Actions job outputs when run in CI
if [ -n "$GITHUB_OUTPUT" ]; then
    echo "version=$NEW_VERSION" >> "$GITHUB_OUTPUT"
    echo "tag=v$NEW_VERSION" >> "$GITHUB_OUTPUT"
fi

#!/bin/sh
# Copy the current main tree to the `public` branch as one new commit by
# Opticell Limited, leaving out the internal notes. `public` is what GitHub
# gets (remote "origin" pushes public -> main only); main, with its own
# history and author details, never leaves this Mac.
#   scripts/publish.sh "commit message"     then: git push
set -eu
cd "$(dirname "$0")/.."
msg=${1:?"say what changed: scripts/publish.sh \"message\""}
private="PLAN.md HANDOVER.md"
PUBLIC_EMAIL="287963324+TeamDzX@users.noreply.github.com"

[ -z "$(git status --porcelain --untracked-files=no)" ] || { echo "commit or stash first" >&2; exit 1; }
index=$(mktemp); trap 'rm -f "$index"' EXIT
GIT_INDEX_FILE=$index git read-tree main
GIT_INDEX_FILE=$index git rm --cached --quiet --ignore-unmatch $private
tree=$(GIT_INDEX_FILE=$index git write-tree)

parent=""
if git rev-parse --verify --quiet refs/heads/public >/dev/null; then
    [ "$(git rev-parse public^{tree})" = "$tree" ] && { echo "public already matches main"; exit 0; }
    parent="-p public"
fi
commit=$(GIT_AUTHOR_NAME="Opticell Limited" GIT_AUTHOR_EMAIL="$PUBLIC_EMAIL" \
         GIT_COMMITTER_NAME="Opticell Limited" GIT_COMMITTER_EMAIL="$PUBLIC_EMAIL" \
         git commit-tree "$tree" $parent -m "$msg")
git update-ref refs/heads/public "$commit"
echo "public -> $(git log --oneline -1 public)"

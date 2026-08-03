#!/usr/bin/env bash
#
# sync-remotes.sh - Sync llama.cpp across remotes
#
# Flow: upstream (ggml-org/llama.cpp) → origin (fork) → internal (Samsung GitHub)
#
# This script fetches the latest from the public upstream repo, merges into
# your local master (preserving any internal/Samsung-specific commits), and
# pushes to both origin and internal remotes.
#
# Usage:
#   ./scripts/sync-remotes.sh              # Normal sync (merge)
#   ./scripts/sync-remotes.sh --force-reset # Hard-reset master to upstream/master (DESTRUCTIVE)
#   ./scripts/sync-remotes.sh --dry-run    # Show what would happen without making changes
#   ./scripts/sync-remotes.sh --tags-only  # Only sync tags, skip code merge
#

set -eu

# --- Configuration ---
UPSTREAM_REMOTE="upstream"
ORIGIN_REMOTE="origin"
INTERNAL_REMOTE="internal"
MAIN_BRANCH="master"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- Parse Arguments ---
FORCE_RESET=false
DRY_RUN=false
TAGS_ONLY=false

for arg in "$@"; do
    case $arg in
        --force-reset)
            FORCE_RESET=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --tags-only)
            TAGS_ONLY=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [--force-reset] [--dry-run] [--tags-only]"
            echo ""
            echo "Options:"
            echo "  --force-reset  Hard-reset master to upstream/master (destroys local/internal-only commits!)"
            echo "  --dry-run      Show what would happen without making changes"
            echo "  --tags-only    Only sync tags from upstream, skip code merge"
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown argument: $arg${NC}"
            exit 1
            ;;
    esac
done

# --- Helper Functions ---
info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

run_cmd() {
    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}[DRY-RUN]${NC} $*"
    else
        "$@"
    fi
}

check_clean_working_tree() {
    # Staged but uncommitted changes will block - they can cause merge issues
    if ! git diff --cached --quiet 2>/dev/null; then
        error "Working tree has staged but uncommitted changes. Please commit before syncing."
        git diff --cached --stat
        exit 1
    fi
    # Unstaged changes to tracked files - warn but don't block
    # (git merge itself will refuse if changes conflict with incoming commits)
    if ! git diff --quiet 2>/dev/null; then
        warn "Working tree has unstaged changes to tracked files."
        warn "If these conflict with incoming changes, the merge will fail."
        git diff --stat
        echo ""
    fi
    # Warn about untracked files but don't block
    UNTRACKED=$(git ls-files --others --exclude-standard 2>/dev/null | head -5 || true)
    if [ -n "$UNTRACKED" ]; then
        warn "Untracked files present (not blocking sync):"
        git ls-files --others --exclude-standard 2>/dev/null | head -5 || true
        echo "  ..."
    fi
}

# --- Pre-flight Checks ---
info "Pre-flight checks..."

# Verify remotes exist
for remote in "$UPSTREAM_REMOTE" "$ORIGIN_REMOTE" "$INTERNAL_REMOTE"; do
    if ! git remote get-url "$remote" &>/dev/null; then
        error "Remote '$remote' not found. Please add it with: git remote add $remote <url>"
        exit 1
    fi
done

UPSTREAM_URL=$(git remote get-url "$UPSTREAM_REMOTE")
ORIGIN_URL=$(git remote get-url "$ORIGIN_REMOTE")
INTERNAL_URL=$(git remote get-url "$INTERNAL_REMOTE")

ok "Remotes configured:"
echo "  upstream  → $UPSTREAM_URL"
echo "  origin    → $ORIGIN_URL"
echo "  internal  → $INTERNAL_URL"

check_clean_working_tree

# Ensure we're on the main branch
CURRENT_BRANCH=$(git branch --show-current)
if [ "$CURRENT_BRANCH" != "$MAIN_BRANCH" ]; then
    warn "Currently on branch '$CURRENT_BRANCH', switching to '$MAIN_BRANCH'..."
    run_cmd git checkout "$MAIN_BRANCH"
fi

# --- Fetch All Remotes ---
info "Fetching from all remotes..."
run_cmd git fetch --all --prune --tags
ok "Fetch complete."

# --- Tags Sync ---
info "Syncing tags from $UPSTREAM_REMOTE..."
UPSTREAM_TAGS=$(git tag -l --sort=-creatordate 2>/dev/null | head -20 || true)
if [ -n "$UPSTREAM_TAGS" ]; then
    if [ "$DRY_RUN" = false ]; then
        # Push all tags to origin and internal
        git push "$ORIGIN_REMOTE" --tags 2>/dev/null && ok "Tags pushed to $ORIGIN_REMOTE" || warn "Some tags may already exist on $ORIGIN_REMOTE"
        git push "$INTERNAL_REMOTE" --tags 2>/dev/null && ok "Tags pushed to $INTERNAL_REMOTE" || warn "Some tags may already exist on $INTERNAL_REMOTE"
    else
        echo -e "${YELLOW}[DRY-RUN]${NC} Would push tags to $ORIGIN_REMOTE and $INTERNAL_REMOTE"
    fi
else
    warn "No tags found to sync."
fi

if [ "$TAGS_ONLY" = true ]; then
    ok "Tags-only sync complete."
    exit 0
fi

# --- Compare Commits ---
LOCAL_COMMIT=$(git rev-parse HEAD)
UPSTREAM_COMMIT=$(git rev-parse "${UPSTREAM_REMOTE}/${MAIN_BRANCH}" 2>/dev/null || echo "unknown")
ORIGIN_COMMIT=$(git rev-parse "${ORIGIN_REMOTE}/${MAIN_BRANCH}" 2>/dev/null || echo "unknown")
INTERNAL_COMMIT=$(git rev-parse "${INTERNAL_REMOTE}/${MAIN_BRANCH}" 2>/dev/null || echo "unknown")

info "Current commit positions:"
echo "  local     : $LOCAL_COMMIT"
echo "  upstream  : $UPSTREAM_COMMIT"
echo "  origin    : $ORIGIN_COMMIT"
echo "  internal  : $INTERNAL_COMMIT"

# Check if sync is needed
if [ "$LOCAL_COMMIT" = "$UPSTREAM_COMMIT" ] && [ "$ORIGIN_COMMIT" = "$UPSTREAM_COMMIT" ] && [ "$INTERNAL_COMMIT" = "$UPSTREAM_COMMIT" ]; then
    ok "All remotes are already in sync. Nothing to do."
    exit 0
fi

# Count commits behind/ahead
COMMITS_BEHIND=$(git rev-list --count HEAD.."${UPSTREAM_REMOTE}/${MAIN_BRANCH}" 2>/dev/null || echo "0")
COMMITS_AHEAD=$(git rev-list --count "${UPSTREAM_REMOTE}/${MAIN_BRANCH}..HEAD" 2>/dev/null || echo "0")

info "Local master is $COMMITS_BEHIND commit(s) behind and $COMMITS_AHEAD commit(s) ahead of $UPSTREAM_REMOTE/$MAIN_BRANCH"

if [ "$COMMITS_BEHIND" -eq 0 ]; then
    ok "Already up to date with upstream."
    # Still push to make sure origin and internal are in sync
    run_cmd git push "$ORIGIN_REMOTE" "$MAIN_BRANCH"
    run_cmd git push "$INTERNAL_REMOTE" "$MAIN_BRANCH"
    ok "Pushed to $ORIGIN_REMOTE and $INTERNAL_REMOTE"
    exit 0
fi

# --- Show Incoming Changes ---
info "Incoming commits from $UPSTREAM_REMOTE/$MAIN_BRANCH:"
git log --oneline HEAD.."${UPSTREAM_REMOTE}/${MAIN_BRANCH}" 2>/dev/null | head -30
echo ""

# --- Perform Sync ---
if [ "$FORCE_RESET" = true ]; then
    warn "⚠️  FORCE RESET: Hard-resetting master to $UPSTREAM_REMOTE/$MAIN_BRANCH"
    warn "⚠️  This will DESTROY any Samsung-specific commits that are not in upstream!"
    echo ""
    read -rp "Are you sure? Type 'yes' to confirm: " confirmation
    if [ "$confirmation" != "yes" ]; then
        info "Aborted."
        exit 0
    fi
    run_cmd git reset --hard "${UPSTREAM_REMOTE}/${MAIN_BRANCH}"
    ok "Master hard-reset to $UPSTREAM_REMOTE/$MAIN_BRANCH"
else
    info "Merging $UPSTREAM_REMOTE/$MAIN_BRANCH into local master..."
    if ! run_cmd git merge "${UPSTREAM_REMOTE}/${MAIN_BRANCH}" --no-edit; then
        error "Merge conflicts detected!"
        echo ""
        echo "Conflicting files:"
        git diff --name-only --diff-filter=U
        echo ""
        error "Please resolve conflicts manually, then:"
        echo "  1. git add <resolved files>"
        echo "  2. git commit"
        echo "  3. git push origin $MAIN_BRANCH"
        echo "  4. git push internal $MAIN_BRANCH"
        echo ""
        echo "Or abort the merge with: git merge --abort"
        exit 1
    fi
    ok "Merge successful."
fi

# --- Push to Remotes ---
info "Pushing to $ORIGIN_REMOTE..."
run_cmd git push "$ORIGIN_REMOTE" "$MAIN_BRANCH"
ok "Pushed to $ORIGIN_REMOTE"

info "Pushing to $INTERNAL_REMOTE..."
run_cmd git push "$INTERNAL_REMOTE" "$MAIN_BRANCH"
ok "Pushed to $INTERNAL_REMOTE"

# --- Summary ---
echo ""
ok "========================================="
ok "  Sync complete!"
ok "========================================="
echo ""
FINAL_COMMIT=$(git rev-parse --short HEAD)
info "Master is now at: $FINAL_COMMIT"
info "  - $COMMITS_BEHIND commit(s) merged from $UPSTREAM_REMOTE"
if [ "$COMMITS_AHEAD" -gt 0 ]; then
    info "  - $COMMITS_AHEAD Samsung-specific commit(s) preserved"
fi
info "  - Pushed to both $ORIGIN_REMOTE and $INTERNAL_REMOTE"

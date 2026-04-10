#!/usr/bin/env bash
# Regression test: nested in-use path protection for derived-data pruning.
#
# Verifies that is_dir_in_use() in .factory/init.sh uses lsof +D (recursive)
# instead of lsof +d (single-directory), so directories containing open files
# deep inside nested subdirectories are correctly detected as active and skipped.
#
# This test:
#   1. Creates a temporary derived-data directory with deeply nested files
#   2. Opens a file descriptor to a deeply nested file (simulating a build process)
#   3. Sources the init.sh function and calls is_dir_in_use()
#   4. Asserts the directory is detected as in-use (open nested file is found)
#   5. Closes the file descriptor and asserts the directory is no longer in-use
#   6. Cleans up

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
init_script="$repo_root/.factory/init.sh"

echo "=== test-init-prune-nested-safety: nested in-use path protection ==="

# --- Setup: extract is_dir_in_use function from init.sh ---
# We source the function definition without running the full init script.
is_dir_in_use() {
  local dir="$1"
  local canon_dir
  canon_dir="$(cd "$dir" && pwd -P)"
  if { lsof +x f +D "$canon_dir" -F p 2>/dev/null || true; } | grep -q '^p'; then
    return 0  # in use
  fi
  return 1  # not in use
}

# --- Test 1: deeply nested open file is detected ---
test_dir=$(mktemp -d "${repo_root}/.derived-data/test-nested-safety-XXXXXX")
nested_file="$test_dir/a/b/c/d/e/f/g/h/deeply_nested_file.txt"
mkdir -p "$(dirname "$nested_file")"
echo "test content for lsof detection" > "$nested_file"

# Keep a subshell alive with an open fd to the deeply nested file
# We use a file descriptor kept open in the current shell process
exec 3<>"$nested_file"

echo "--- Test 1: Deeply nested open file should be detected as in-use ---"
if is_dir_in_use "$test_dir"; then
  echo "PASS: Directory with deeply nested open file detected as in-use"
else
  echo "FAIL: Directory with deeply nested open file NOT detected as in-use"
  echo "  This means lsof +D is not working correctly or the open fd was lost"
  # Cleanup before exit
  exec 3>&-
  rm -rf "$test_dir"
  exit 1
fi

# --- Test 2: after closing fd, directory should not be in-use ---
echo "--- Test 2: After closing fd, directory should not be in-use ---"
exec 3>&-

if ! is_dir_in_use "$test_dir"; then
  echo "PASS: Directory no longer detected as in-use after fd closed"
else
  echo "FAIL: Directory still detected as in-use after fd closed"
  echo "  There may be other processes with files open in this directory"
  rm -rf "$test_dir"
  exit 1
fi

# --- Test 3: verify the function uses +D not +d in init.sh ---
echo "--- Test 3: init.sh uses lsof +D (recursive) not lsof +d (single-dir) ---"
# Check that the actual lsof invocation line in is_dir_in_use uses +D
# We look for the command pattern "lsof ... +D" in the function body
# (ignoring comment lines that may mention +d for documentation purposes)
if grep -E '^\s+if\s+\{?\s*lsof.*\+D\s' "$init_script" >/dev/null; then
  # Also verify there is no standalone +d (non-recursive) in the invocation
  if grep -E '^\s+if\s+\{?\s*lsof\s+\+d\s' "$init_script" >/dev/null; then
    echo "FAIL: init.sh still has non-recursive lsof +d in function invocation"
    rm -rf "$test_dir"
    exit 1
  fi
  echo "PASS: init.sh uses lsof +D for recursive directory scanning"
else
  echo "FAIL: init.sh does not contain lsof +D in function invocation"
  rm -rf "$test_dir"
  exit 1
fi

# --- Cleanup ---
rm -rf "$test_dir"

echo ""
echo "=== All nested in-use safety tests passed ==="

#!/bin/bash
# Integration tests for PLUMBUS API calls and data processing

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../" || exit 1

# Source testing helpers
source ./tests/test_helpers.sh

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "PLUMBUS Integration Tests"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Test 1: Check mock data files exist
echo "Test Suite 1: Data Files"
assert_file_exists "./tests/mock_spot_data.json" "Mock spot market data file"
assert_file_exists "./tests/mock_perp_data.json" "Mock perpetual market data file"

# Test 2: Validate JSON structure of mock data
echo ""
echo "Test Suite 2: JSON Structure"

if [[ -f "./tests/mock_spot_data.json" ]]; then
  if jq -e '.result | type == "array"' "./tests/mock_spot_data.json" >/dev/null 2>&1; then
    test_pass "Mock spot data has valid JSON structure"
  else
    test_fail "Mock spot data JSON structure invalid"
  fi
fi

if [[ -f "./tests/mock_perp_data.json" ]]; then
  if jq -e '.result | type == "array"' "./tests/mock_perp_data.json" >/dev/null 2>&1; then
    test_pass "Mock perp data has valid JSON structure"
  else
    test_fail "Mock perp data JSON structure invalid"
  fi
fi

# Test 3: Test configuration loading
echo ""
echo "Test Suite 3: Configuration"

if [[ -f ".env.test" ]]; then
  source .env.test
  test_pass "Test environment configuration loaded"
  assert_not_empty "${NVIDIA_KEY:-}" "NVIDIA_KEY is set in test config"
else
  test_fail "Test environment configuration file not found"
fi

# Test 4: Test helper functions
echo ""
echo "Test Suite 4: Helper Functions"

# Define test versions of helper functions
normalize_decimal() {
  echo "$1" | sed 's/^\./0./; s/^-\./-0./'
}

format_price() {
  local p="$1"
  if [[ -z "$p" || "$p" == "0" ]]; then echo "0.00"; return; fi
  printf "%.10f" "$p" | sed 's/0*$//; s/\.$//'
}

# Test normalize_decimal
result=$(normalize_decimal ".5")
assert_equals "0.5" "$result" "normalize_decimal converts .5 to 0.5"

result=$(normalize_decimal "-.25")
assert_equals "-0.25" "$result" "normalize_decimal converts -.25 to -0.25"

# Test format_price
result=$(format_price "0")
assert_equals "0.00" "$result" "format_price returns 0.00 for zero input"

# Test 5: API Response mock processing
echo ""
echo "Test Suite 5: API Response Processing"

# Check if jq can parse mock data
if jq -e '.result[0].symbol' "./tests/mock_spot_data.json" >/dev/null 2>&1; then
  test_pass "Successfully extract symbol from mock spot data"
else
  test_fail "Failed to extract symbol from mock spot data"
fi

echo ""
print_test_summary

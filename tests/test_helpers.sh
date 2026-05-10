#!/bin/bash
# Simple test framework for PLUMBUS

# Test counter
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RESET='\033[0m'

# Test result recording
test_pass() {
  echo -e "${GREEN}✓${RESET} $1"
  ((TESTS_PASSED++))
  ((TESTS_RUN++))
}

test_fail() {
  echo -e "${RED}✗${RESET} $1"
  ((TESTS_FAILED++))
  ((TESTS_RUN++))
}

# Assert functions
assert_equals() {
  local expected="$1"
  local actual="$2"
  local msg="$3"
  
  if [[ "$expected" == "$actual" ]]; then
    test_pass "$msg (expected: '$expected')"
  else
    test_fail "$msg (expected: '$expected', got: '$actual')"
  fi
}

assert_not_empty() {
  local value="$1"
  local msg="$2"
  
  if [[ -n "$value" ]]; then
    test_pass "$msg"
  else
    test_fail "$msg (value is empty)"
  fi
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local msg="$3"
  
  if [[ "$haystack" == *"$needle"* ]]; then
    test_pass "$msg"
  else
    test_fail "$msg (string does not contain '$needle')"
  fi
}

assert_file_exists() {
  local filepath="$1"
  local msg="$2"
  
  if [[ -f "$filepath" ]]; then
    test_pass "$msg"
  else
    test_fail "$msg (file not found: $filepath)"
  fi
}

# Print summary
print_test_summary() {
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo -e "Tests run: ${TESTS_RUN}"
  echo -e "  ${GREEN}Passed: ${TESTS_PASSED}${RESET}"
  echo -e "  ${RED}Failed: ${TESTS_FAILED}${RESET}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  
  if [[ $TESTS_FAILED -eq 0 ]]; then
    echo -e "${GREEN}All tests passed!${RESET}"
    return 0
  else
    return 1
  fi
}

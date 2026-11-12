#!/bin/bash
# Generate code coverage report for Bitekey
#
# This script runs tests with coverage enabled and generates a human-readable report.
#
# Usage: ./scripts/coverage-report.sh [options]
#
# Options:
#   --json          Output coverage as JSON (for CI/badge generation)
#   --html          Generate HTML coverage report (opens in browser)
#   --summary       Show only the summary line
#   --help          Show this help message

set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Parse arguments
JSON_OUTPUT=false
HTML_OUTPUT=false
SUMMARY_ONLY=false

for arg in "$@"; do
    case $arg in
        --json)
            JSON_OUTPUT=true
            ;;
        --html)
            HTML_OUTPUT=true
            ;;
        --summary)
            SUMMARY_ONLY=true
            ;;
        --help)
            head -15 "$0" | tail -11
            exit 0
            ;;
    esac
done

# Run tests with coverage
echo -e "${CYAN}Running tests with code coverage...${NC}"
swift test --enable-code-coverage > /dev/null 2>&1

# Get paths using swift test's built-in path detection
BIN_PATH=$(swift build --show-bin-path)
PROFDATA_PATH="${BIN_PATH}/codecov/default.profdata"
XCTEST_PATH="${BIN_PATH}/BitekeyPackageTests.xctest/Contents/MacOS/BitekeyPackageTests"

if [ ! -f "$PROFDATA_PATH" ]; then
    echo "Error: Coverage data not found. Run 'swift test --enable-code-coverage' first."
    exit 1
fi

# Generate JSON output if requested
if [ "$JSON_OUTPUT" = true ]; then
    swift test --show-codecov-path | xargs cat
    exit 0
fi

# Generate HTML output if requested
if [ "$HTML_OUTPUT" = true ]; then
    HTML_DIR=".build/coverage-html"
    mkdir -p "$HTML_DIR"
    
    xcrun llvm-cov show "$XCTEST_PATH" \
        -instr-profile="$PROFDATA_PATH" \
        -ignore-filename-regex='.build|Tests' \
        -format=html \
        -output-dir="$HTML_DIR"
    
    echo -e "${GREEN}HTML coverage report generated at: $HTML_DIR/index.html${NC}"
    open "$HTML_DIR/index.html"
    exit 0
fi

# Generate text report
echo ""
echo -e "${GREEN}=== Code Coverage Report ===${NC}"
echo ""

if [ "$SUMMARY_ONLY" = true ]; then
    xcrun llvm-cov report "$XCTEST_PATH" \
        -instr-profile="$PROFDATA_PATH" \
        -ignore-filename-regex='.build|Tests' 2>&1 | tail -1
else
    xcrun llvm-cov report "$XCTEST_PATH" \
        -instr-profile="$PROFDATA_PATH" \
        -ignore-filename-regex='.build|Tests'
fi

echo ""
echo -e "${CYAN}Tip: Use --html to generate an interactive HTML report${NC}"

#!/usr/bin/env python3
"""
Generate coverage badge JSON for shields.io

This script parses the LLVM coverage JSON and outputs a simple JSON
file that can be used to create a dynamic badge.

Usage: python3 scripts/coverage-badge.py

Output format (coverage-badge.json):
{
    "schemaVersion": 1,
    "label": "coverage",
    "message": "65%",
    "color": "yellow"
}
"""

import json
import os
import sys
import subprocess

def get_coverage_json_path():
    """Get the path to the coverage JSON file."""
    result = subprocess.run(
        ['swift', 'test', '--show-codecov-path'],
        capture_output=True,
        text=True
    )
    return result.stdout.strip()

def calculate_source_coverage(data):
    """Calculate coverage for source files only (excluding Tests and .build)."""
    total_lines = 0
    covered_lines = 0
    
    for entry in data.get('data', []):
        for file_data in entry.get('files', []):
            filename = file_data.get('filename', '')
            
            # Skip test files and build artifacts
            if '/Tests/' in filename or '/.build/' in filename:
                continue
            
            # Skip if not a source file
            if '/Sources/' not in filename:
                continue
            
            summary = file_data.get('summary', {})
            lines = summary.get('lines', {})
            
            total_lines += lines.get('count', 0)
            covered_lines += lines.get('covered', 0)
    
    if total_lines == 0:
        return 0.0
    
    return (covered_lines / total_lines) * 100

def get_badge_color(percentage):
    """Get badge color based on coverage percentage."""
    if percentage >= 80:
        return 'brightgreen'
    elif percentage >= 60:
        return 'green'
    elif percentage >= 40:
        return 'yellow'
    elif percentage >= 20:
        return 'orange'
    else:
        return 'red'

def main():
    # Get coverage data path
    coverage_path = get_coverage_json_path()
    
    if not os.path.exists(coverage_path):
        print("Error: Coverage data not found. Run 'swift test --enable-code-coverage' first.", file=sys.stderr)
        sys.exit(1)
    
    # Load and parse coverage data
    with open(coverage_path, 'r') as f:
        data = json.load(f)
    
    # Calculate coverage for source files
    coverage = calculate_source_coverage(data)
    
    # Generate badge JSON
    badge = {
        'schemaVersion': 1,
        'label': 'coverage',
        'message': f'{coverage:.0f}%',
        'color': get_badge_color(coverage)
    }
    
    # Output badge JSON
    print(json.dumps(badge, indent=2))
    
    # Also save to file
    output_path = 'coverage-badge.json'
    with open(output_path, 'w') as f:
        json.dump(badge, f, indent=2)
    
    print(f'\nBadge JSON saved to: {output_path}', file=sys.stderr)
    print(f'Coverage: {coverage:.2f}%', file=sys.stderr)

if __name__ == '__main__':
    main()

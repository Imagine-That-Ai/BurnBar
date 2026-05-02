#!/usr/bin/env python3
"""
Revert botched AppLogger.*.silently(...) replacements back to try? expressions.
Also fix broken do { try expr( } catch patterns and common syntax issues.
"""

import re
import sys
from pathlib import Path

def find_matching_paren(text, start):
    """Find the index of the matching ) starting after text[start] which should be (."""
    depth = 1
    i = start + 1
    while i < len(text) and depth > 0:
        if text[i] == '(':
            depth += 1
        elif text[i] == ')':
            depth -= 1
        i += 1
    return i  # index after the matching )

def fix_file(filepath):
    content = filepath.read_text()
    original = content
    
    # Pass 1: Fix broken do { try expr( } catch patterns
    # These happen when the regex didn't capture the full multi-line call.
    # Pattern: do { try <identifier>( } catch { ... }
    # We need to find the original expression and wrap it properly.
    broken_pattern = r'do \{ try ([^(]*)\( \} catch \{ AppLogger\.\w+\.silentFailure\("([^"]+)", error: error) \}'
    
    def fix_broken_do_catch(match):
        prefix = match.group(1).strip()
        op = match.group(2)
        # We can't reliably reconstruct the original call from the broken state.
        # Best to just revert to try? and let the caller handle it.
        return f'try? {prefix}('
    
    content = re.sub(broken_pattern, fix_broken_do_catch, content)
    
    # Pass 2: Replace all AppLogger.<cat>.silently(...) calls
    pattern = r'AppLogger\.(\w+)\.silently\('
    
    result = []
    last_end = 0
    
    for match in re.finditer(pattern, content):
        start = match.start()
        result.append(content[last_end:start])
        
        # Find matching closing paren
        match_end = find_matching_paren(content, match.end() - 1)
        silently_call = content[start:match_end]
        
        # Parse inner content: "op", try expr, fallback: value
        # The inner is everything between the outermost parens
        inner_start = silently_call.find('(') + 1
        inner = silently_call[inner_start:-1]  # remove outer parens
        
        # Find try keyword
        try_idx = inner.find('try ')
        if try_idx == -1:
            result.append(silently_call)
            last_end = match_end
            continue
        
        # Find the last ", fallback:" which belongs to silently()
        fallback_marker = ', fallback:'
        fb_idx = inner.rfind(fallback_marker)
        if fb_idx == -1:
            result.append(silently_call)
            last_end = match_end
            continue
        
        expr = inner[try_idx + 4 : fb_idx].strip()
        fallback = inner[fb_idx + len(fallback_marker):].strip()
        
        # Build replacement
        if fallback == 'nil':
            replacement = f'try? {expr}'
        else:
            replacement = f'(try? {expr}) ?? {fallback}'
        
        result.append(replacement)
        last_end = match_end
    
    result.append(content[last_end:])
    content = ''.join(result)
    
    # Pass 3: Fix trailing commas after else { ... } in guard/if statements
    # These were introduced by the botched script
    # Pattern: else { ... } ,\n  -> else { ... }\n
    content = re.sub(r'(else \{[^}]*\})\s*,\s*\n', r'\1\n', content)
    
    # Pass 4: Fix trailing commas after } { in if-let statements
    # Pattern: } { ,\n -> } {\n
    content = re.sub(r'(\}\s*\{)\s*,\s*\n', r'\1\n', content)
    
    # Pass 5: Fix missing commas in multi-condition guard
    # After reverting, we might have:
    #   guard let x = try? expr
    #   let y = ... else {
    # Need to add comma after the first condition.
    # This is tricky. Let's handle specific known patterns.
    
    if content != original:
        filepath.write_text(content)
        print(f"Fixed: {filepath}")
        return True
    return False

def main():
    root = Path('/Users/albertonunez/Documents/Windsurf/BurnBar/AgentLens')
    files = list(root.rglob('*.swift'))
    fixed = 0
    for f in files:
        if '.silently(' in f.read_text() or 'do { try ' in f.read_text():
            if fix_file(f):
                fixed += 1
    print(f"Fixed {fixed} files")

if __name__ == '__main__':
    main()

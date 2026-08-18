import fs from 'node:fs';
import path from 'node:path';

export function isInside(parent, child) {
  return child === parent || child.startsWith(`${parent}${path.sep}`);
}

/**
 * Resolve a repository-relative POSIX path without allowing ../ or symlink escape.
 * The leaf may be missing; ancestors must stay inside the real repo root.
 */
export function resolveConfinedPath(repoRoot, relativePath) {
  const root = fs.realpathSync(repoRoot);
  if (typeof relativePath !== 'string' || relativePath.length === 0) {
    return { error: 'path must be a non-empty string' };
  }
  if (path.isAbsolute(relativePath)) return { error: 'absolute paths are forbidden' };
  if (relativePath.includes('\\') || path.posix.normalize(relativePath) !== relativePath) {
    return { error: 'path is not a canonical repository-relative POSIX path' };
  }

  const lexical = path.resolve(root, relativePath);
  if (!isInside(root, lexical)) return { error: 'path escapes the repository' };

  let current = root;
  let ancestor = root;
  for (const component of path.relative(root, lexical).split(path.sep).filter(Boolean)) {
    current = path.join(current, component);
    let stat;
    try {
      stat = fs.lstatSync(current);
    } catch (error) {
      if (error.code === 'ENOENT') break;
      return { error: `path inspection failed: ${error.message}` };
    }
    if (stat.isSymbolicLink()) return { error: 'path traverses a symlink' };
    ancestor = current;
  }
  const realAncestor = fs.realpathSync(ancestor);
  if (!isInside(root, realAncestor)) return { error: 'path escapes the repository through a symlink' };

  const exists = fs.existsSync(lexical);
  if (exists) {
    const real = fs.realpathSync(lexical);
    if (!isInside(root, real)) return { error: 'path escapes the repository through a symlink' };
    return { path: real, exists: true };
  }
  return { path: lexical, exists: false };
}

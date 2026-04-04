# Governance and Maintainer Expectations

## Current Maintainer

OpenBurnBar is maintained by [@Ajnunezg](https://github.com/Ajnunezg).

## Decision-Making

This is a single-maintainer project. Design decisions, roadmap priorities, and merge authority rest with the maintainer.

Contributions are welcome through pull requests. The maintainer will review and merge at their discretion. There is no formal RFC or proposal process at this stage.

## Support Model

OpenBurnBar is an **experimental source release** with **best-effort support**.

What this means in practice:

- **Issues** are triaged when the maintainer has time. There is no SLA.
- **Pull requests** are reviewed when the maintainer has time. Small, focused PRs are easier to review and more likely to land quickly.
- **Security reports** are taken seriously and handled as quickly as possible. See [SECURITY.md](../SECURITY.md).
- **Breaking changes** may happen without deprecation periods before `1.0`.
- **Releases** happen when the maintainer decides a tag is warranted. There is no fixed cadence.

## What "Experimental" Means

- The API and data model may change without notice.
- Features documented as "experimental" may be removed or redesigned.
- The project does not promise backwards compatibility across commits.
- Build-from-source is the only supported install path today.

## How to Help

The most valuable contributions right now:

- Bug reports with clear reproduction steps
- Parser implementations for new AI agent providers
- Test coverage for active test suites (see `AgentLensTests/README.md`)
- Documentation fixes and improvements

Less helpful at this stage:

- Large architectural refactors without prior discussion
- Feature requests that expand scope beyond the current roadmap
- PRs that touch shared contracts (`OpenBurnBarCore`) without coordinating

## Future Governance

If the project grows to the point where single-maintainer governance becomes a bottleneck, the maintainer will revisit this document. Until then, keep it simple.

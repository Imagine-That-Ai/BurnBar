# Governance

## Project Ownership

**Maintainer:** @Ajnunezg

BurnBar is an independent, single-maintainer open-source project. The maintainer owns the codebase, makes final decisions on architecture and design, and is responsible for releases, security responses, and community management.

## Decision Making

Decisions are made by the maintainer with input from the community through:
- GitHub Issues and Discussions
- Pull Request reviews and feedback
- Feature requests and bug reports

No formal governance body exists. For a project of this scope, informal consensus-building through issue discussion is the intended process.

## Roadmap Authority

The maintainer controls the roadmap direction documented in `docs/ROADMAP.md`. The roadmap reflects current priorities and is subject to change based on user feedback, maintainer capacity, and project evolution. Roadmap changes do not require community approval.

## Code Review and Merges

All changes are reviewed by the maintainer. The repository requires at least one approval before merge (enforced via branch protection).

Pull requests from external contributors are welcome. The maintainer will review and provide feedback but cannot guarantee timely responses or acceptance.

## Release Decisions

Releases are cut at the maintainer's discretion. Version numbering follows Semantic Versioning:
- `0.x.y` for pre-1.0 releases (experimental, breaking changes may occur)
- `1.0.0` and above when the API surface is considered stable

The current release model:
- **Build from source**: `make install` builds and copies to /Applications
- **GitHub Releases**: DMG and ZIP artifacts attached to tagged releases (notarization pending Apple Developer secrets in CI)
- **Homebrew Cask**: formula at `homebrew/burnbar.rb`, ready to publish to a tap once notarized builds are live
- No VS Marketplace / Open VSX listing (editor extension)

## Security

Security vulnerabilities are handled via private disclosure:
- See [SECURITY.md](SECURITY.md) for reporting procedures
- The maintainer responds on a best-effort basis
- No formal SLA for security patches

## Support

Support is provided on a best-effort basis with no SLA:
- GitHub Issues for bugs, feature requests, and documentation fixes
- No guaranteed response time
- No guaranteed compatibility across commits

See [SUPPORT.md](SUPPORT.md) for full details.

## Contribution Expectations

Contributors are expected to:
- Follow the [CONTRIBUTING.md](CONTRIBUTING.md) guidelines
- Use the provided PR template
- Run repo-native tests before submitting
- Keep discussions respectful and constructive

The [Code of Conduct](CODE_OF_CONDUCT.md) applies to all project spaces.

## Future Governance Changes

If the project grows beyond what a single maintainer can sustain, the following would be considered:
- Adding co-maintainers or a steering committee
- Establishing a formal decision-making process
- Creating a foundation or organizational home

There is no timeline or commitment for such changes today.

## Contact

For governance questions or concerns, open a GitHub Discussion or contact the maintainer through their GitHub profile: https://github.com/Ajnunezg

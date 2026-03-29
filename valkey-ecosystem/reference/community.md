# Valkey Community

Use when looking for Valkey communication channels, contributing to the project, understanding governance, submitting RFCs, reporting security issues, or finding community events.

---

## Communication Channels

| Channel | URL | Purpose |
|---------|-----|---------|
| Discord | [discord.gg/zbcPa5umUB](https://discord.gg/zbcPa5umUB) | Real-time chat, questions, community discussion |
| Matrix | [#valkey:matrix.org](https://matrix.to/#/#valkey:matrix.org) | Alternative to Discord, bridged chat |
| Slack | [valkey.io/slack](https://valkey.io/slack) | Dedicated channels: #valkey-k8s-operator, #Valkey-helm |
| GitHub Discussions | [github.com/valkey-io/valkey/discussions](https://github.com/valkey-io/valkey/discussions) | Longer-form questions, proposals, announcements |
| Mailing lists | `security@lists.valkey.io`, `maintainers@lists.valkey.io` | Security reports, maintainer communication |
| YouTube | [youtube.com/@valkeyproject](https://www.youtube.com/@valkeyproject) | Official channel with tutorials and updates |
| Newsletter | [valkey.io/blog](https://valkey.io/blog/) | Valkey Newsletter launched 2026-02-04 |

Discord is the most active channel for real-time help. GitHub Discussions is preferred for proposals or questions that benefit from threaded, persistent conversation.

## Project Stats (as of 2026-03)

| Metric | Value |
|--------|-------|
| GitHub stars | 25,287 |
| Forks | 1,072 |
| Open issues | 622 |
| Contributors | 100+ |
| Watchers | 127 |

### Current Releases

| Branch | Version | Date |
|--------|---------|------|
| 9.1 (RC) | 9.1.0-rc1 | 2026-03-16 |
| 9.0 (stable) | 9.0.3 | 2026-02-24 |
| 8.1 | 8.1.6 | - |
| 8.0 | 8.0.7 | - |
| 7.2 (LTS) | 7.2.12 | - |

## Events

### Keyspace Conference

The first dedicated Valkey conference - Keyspace 2025 - was held August 28, 2025
at RAI Amsterdam Convention Centre, co-located with Linux Foundation Open Source
Summit Europe.

- **Format**: General sessions, breakout rooms, lightning talks, workshops in two
  tracks
- **Registration**: Free of Open Source Summit ticket requirement
- **CFP**: Received high volume and quality submissions
- **URL**: [valkey.io/events/keyspace-2025](https://valkey.io/events/keyspace-2025)

This established a precedent for an annual Valkey community event.

### Valkey Blog Activity (2026)

Active publication cadence in 2026:

- 2026-01-06: Valkey Helm Chart
- 2026-01-22: 2025 Year End Review
- 2026-02-04: Valkey Newsletter launch
- 2026-02-19: Operational Lessons
- 2026-02-25: Introducing Valkey Admin
- 2026-03-10: Valkey Search 1.2
- 2026-03-27: Valkey Tooling Primitives (calls out ecosystem tooling gaps)

## Governance

Valkey is a Linux Foundation project governed by a Technical Steering Committee (TSC). The TSC comprises the maintainers of the main valkey-io/valkey repository.

### Key Governance Rules

- **Organization diversity** - No more than one third of TSC members may be from the same organization or its affiliates
- **Consensus-first** - The TSC strives for consensus; votes are called only when consensus cannot be reached
- **Technical major decisions** require a simple majority vote or +2 from two TSC members within two weeks
- **Governance major decisions** (adding/removing TSC members, modifying governance) require a two-thirds super-majority
- **Chair** - The TSC appoints a Chair responsible for organizing meetings. Current Chair: Madelyn Olson (since March 2024)

### Current TSC Members

| Maintainer | GitHub | Affiliation |
|------------|--------|-------------|
| Binbin Zhu | @enjoy-binbin | Tencent |
| Harkrishn Patro | @hpatro | Amazon |
| Lucas Yang | @lucasyonge | - |
| Madelyn Olson (Chair) | @madolson | Amazon |
| Jacob Murphy | @murphyjacob4 | Google |
| Ping Xie | @pingxie | Oracle |
| Ran Shidlansik | @ranshid | Amazon |
| Zhao Zhao | @soloestoy | Alibaba |
| Viktor Soderqvist | @zuiderkwast | Ericsson |

The full governance document is at [GOVERNANCE.md](https://github.com/valkey-io/valkey/blob/unstable/GOVERNANCE.md) and the maintainer list at [MAINTAINERS.md](https://github.com/valkey-io/valkey/blob/unstable/MAINTAINERS.md).

## RFC Process

Large proposed changes go through the RFC repository at [valkey-io/valkey-rfc](https://github.com/valkey-io/valkey-rfc).

### Workflow

1. Author writes an RFC as a markdown file and submits it as a pull request
2. The PR is reviewed for formatting, style, consistency, and content quality
3. On merge, the RFC enters **Proposed** status - this does not mean the feature is approved
4. The TSC evaluates the proposal and changes the status to **Approved** or **Rejected**

### RFC Statuses

| Status | Meaning |
|--------|---------|
| Proposed | Merged but no decision yet |
| Approved | TSC has accepted the feature |
| Rejected | TSC has decided not to accept the feature |
| Informational | Not a feature proposal (e.g., process documentation) |

### What to Include in an RFC

- **Abstract** - A few sentences describing the feature
- **Motivation** - What problem it solves and why existing functionality is insufficient
- **Design considerations** - Constraints, requirements, comparisons with similar features elsewhere
- **Specification** - Detailed description with rationale for design choices
- **Links** - Related issues, PRs, papers, or references

A template is available at [TEMPLATE.md](https://github.com/valkey-io/valkey-rfc/blob/main/TEMPLATE.md) in the RFC repo.

RFCs are referenced by their pull request number (e.g., RFC #1 is the README itself).

## Contributing

The contribution workflow is documented in [CONTRIBUTING.md](https://github.com/valkey-io/valkey/blob/unstable/CONTRIBUTING.md).

### Quick Start

1. Check for consensus on larger features by opening a GitHub issue first
2. Fork the repository
3. Create a topic branch
4. Make changes and commit with DCO sign-off (`git commit -s`)
5. Push and open a pull request
6. Link to related issues with "Fixes #xyz" in the PR description

### Developer Certificate of Origin (DCO)

Every commit must include a `Signed-off-by` line certifying that the contributor has the right to submit the code under the project's open-source license. Use `git commit -s` to add it automatically.

```
Signed-off-by: Jane Smith <jane.smith@email.com>
```

Real or preferred names are required - anonymous contributions and pseudonyms are not accepted.

### Development Guide

Code style, testing best practices, and implementation guidance are in [DEVELOPMENT_GUIDE.md](https://github.com/valkey-io/valkey/blob/unstable/DEVELOPMENT_GUIDE.md).

### Where to Contribute

| Area | Repository |
|------|-----------|
| Valkey server | [valkey-io/valkey](https://github.com/valkey-io/valkey) |
| Documentation | [valkey-io/valkey-doc](https://github.com/valkey-io/valkey-doc) |
| GLIDE client | [valkey-io/valkey-glide](https://github.com/valkey-io/valkey-glide) |
| Modules (JSON, Bloom, Search) | Individual repos under valkey-io |
| RFCs | [valkey-io/valkey-rfc](https://github.com/valkey-io/valkey-rfc) |

### Running CI on Your Fork

The daily workflow supports `workflow_dispatch` for manual runs on any branch:

1. Go to **Actions** > **Daily** in your fork
2. Click **Run workflow** and select your branch
3. Set `use_repo` to your fork and `use_git_ref` to your branch
4. Set `skipjobs` and `skiptests` to `none` for the full test matrix

## Reporting Security Vulnerabilities

Security issues must be reported privately - do not create a public GitHub issue.

- **Email**: `security@lists.valkey.io`
- **Process**: Responsible disclosure - the team may notify vendors before public release depending on severity
- **Vendor list**: Contact `maintainers@lists.valkey.io` to be added to the vendor notification list

For the full vulnerability disclosure process, supply chain security practices, and enterprise authentication, see [tools/security.md](tools/security.md).

## Community Resources

### Valkey-Samples (Awesome List)

The [Valkey-Samples](https://github.com/valkey-io/Valkey-Samples) repository is the official curated list of community resources - demos, tutorials, integrations, MCP servers, and cloud platform guides. It focuses on AI ecosystem use cases but covers general Valkey resources too.

### Official Resources

| Resource | URL |
|----------|-----|
| Website | [valkey.io](https://valkey.io/) |
| Blog | [valkey.io/blog](https://valkey.io/blog/) |
| Documentation | [valkey.io/docs](https://valkey.io/docs/) |
| Command reference | [valkey.io/commands](https://valkey.io/commands/) |
| Download | [valkey.io/download](https://valkey.io/download/) |
| GitHub organization | [github.com/valkey-io](https://github.com/valkey-io) |

## Related Files

- [tools/migration.md](tools/migration.md) - migrating from Redis to Valkey
- [tools/security.md](tools/security.md) - supply chain security and vulnerability disclosure
- [tools/ci-cd.md](tools/ci-cd.md) - running CI on forks and integration testing
- [clients/landscape.md](clients/landscape.md) - client library ecosystem
- [modules/overview.md](modules/overview.md) - module system and official modules

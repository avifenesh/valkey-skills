# Governance

Use when you need to understand Valkey's decision-making process, who the maintainers are, or how major changes are approved.

## Contents

- Technical Steering Committee (TSC) (line 20)
- Roles (line 55)
- Decision Making (line 61)
- Major Decisions (line 79)
- Termination of Membership (line 106)
- Delegation (line 114)
- Process Transparency (line 120)
- How to Influence Decisions (line 127)
- License (line 139)
- See Also (line 143)

---

## Technical Steering Committee (TSC)

The TSC manages all technical, project, approval, and policy matters for Valkey. TSC membership is composed of the maintainers of the main Valkey repository. Maintainers of other valkey-io repositories are not TSC members unless explicitly added.

### Organizational Diversity Rule

No more than one-third of TSC members may be from the same organization (including affiliates). If this limit is exceeded due to employment changes or acquisitions, the TSC must restore compliance within 30 days.

### Current TSC Members

Source: `MAINTAINERS.md`

**Chair**: Madelyn Olson (since March 28, 2024)

| Maintainer | GitHub | Affiliation |
|------------|--------|-------------|
| Binbin Zhu | @enjoy-binbin | Tencent |
| Harkrishn Patro | @hpatro | Amazon |
| Lucas Yang | @lucasyonge | - |
| Madelyn Olson | @madolson | Amazon |
| Jacob Murphy | @murphyjacob4 | Google |
| Ping Xie | @pingxie | Oracle |
| Ran Shidlansik | @ranshid | Amazon |
| Zhao Zhao | @soloestoy | Alibaba |
| Viktor Soderqvist | @zuiderkwast | Ericsson |

### Current Committers

Committers have write access to the repository but are not TSC members:

| Committer | GitHub | Affiliation |
|-----------|--------|-------------|
| Jim Brunner | @JimB123 | Amazon |
| Ricardo Dias | @rjd15372 | Percona |

## Roles

- **Maintainer**: Full repository access, TSC membership, governance authority. Listed in `MAINTAINERS.md`.
- **Committer**: Write access to the codebase. Listed in `MAINTAINERS.md`. Can merge PRs but does not vote on TSC decisions.
- **TSC Chair**: Organizes TSC meetings. Appointed by the TSC. If the chair leaves, the TSC appoints a new one.

## Decision Making

### Consensus First

The TSC strives for consensus on all decisions. Explicit agreement of every member is preferred but not required. Consensus is determined in good faith based on the dominant view and the nature of support and objections.

### Voting

A formal vote is called when:
- Consensus cannot be reached
- An issue or PR is marked as a **major decision**

Voting rules:
- Each TSC member gets one vote
- At least two weeks for members to submit votes
- Ties preserve the status quo
- The Chair facilitates the process

## Major Decisions

### Technical Major Decisions

These require a formal vote:

- Fundamental changes to core data structures
- Adding a new data structure or API
- Changes affecting backward compatibility
- New user-visible fields that need ongoing maintenance
- Adding or removing external libraries that affect runtime behavior

**Approval**: Simple majority. If a simple majority cannot be reached within two weeks and no member has voted against, the decision can be approved with explicit "+2" from at least two TSC members. If the proposer is a TSC member, their +1 counts toward the +2. Any negative vote blocks the +2 mechanism and requires the simple majority process.

### Governance Major Decisions

These require a supermajority:

- Adding or involuntary removal of TSC members
- Modifying the governance document
- Delegating maintainership or governance authority
- Creating, modifying, or removing roles
- Changing voting rules, TSC responsibilities, or oversight
- Structural changes to the TSC

**Approval**: Two-thirds (2/3) supermajority of the entire TSC.

## Termination of Membership

A maintainer's access and TSC position can be removed by:

- **Involuntary removal**: Via the governance major decision voting process (2/3 supermajority)
- **Resignation**: Written notice to the TSC
- **Unreachable member**: If unresponsive for more than six months, remaining active members can vote to remove by simple majority

## Delegation

The TSC can delegate decision-making for other valkey-io repositories to the maintainers of those projects. Delegation itself is a governance major decision (requires 2/3 vote). The TSC retains the right to overrule delegated decisions, though with restraint.

Projects within the organization must list their committers in their own `MAINTAINERS.md`.

## Process Transparency

- Discussions are open to the public
- Exceptions: embargoed security issues and addition/removal of maintainers (private)
- Votes and decisions are documented
- Discussions can be in person or electronic (text, voice, video)

## How to Influence Decisions

As a contributor, you cannot vote, but you can:

1. Open an issue describing your proposal with clear use cases
2. Gather community support - comments, upvotes, real-world usage data
3. Participate in GitHub Discussions, Discord, or Matrix
4. Submit a well-tested PR that demonstrates the value of the change
5. Be patient - maintainers are volunteers with competing priorities

The TSC explicitly weighs community input ("the dominant view of the TSC and nature of support and objections") when determining consensus.

## License

The governance document itself is licensed under CC-BY-4.0.

## See Also

- [Contribution Workflow](workflow.md) - how to submit patches, coding style, and the PR process
- [CI Pipeline](../testing/ci-pipeline.md) - required CI checks that must pass before merge

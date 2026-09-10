import Foundation

/// Why a branch is considered already integrated. Most cases describe
/// *content* equivalence against the base, not merge provenance: a branch is
/// a candidate when its work is already represented on the base, however it
/// got there. `prMerged` is the exception — it is provenance-based and does
/// not require the content to have reached `base` at all.
public enum CleanReason: Sendable {
    /// The branch tip is an ancestor of the base (a normal, non-squash merge).
    case merged
    /// The branch's aggregate diff from the merge-base already exists on the
    /// base as an equivalent patch — the typical squash-merge signature.
    case patchEquivalent
    /// The branch has no net change from the merge-base (e.g. work then revert).
    case sameTree
    /// A GitHub pull request for this branch was merged, per `gh pr list`.
    /// Unlike the other cases, this does not certify that the branch's
    /// content ever reached `base`: the pull request may have merged into a
    /// topic branch, `develop`, or a release branch instead. `mergedInto`
    /// names the actual target.
    case prMerged(mergedInto: String)

    public var label: String {
        switch self {
        case .merged: return "merged"
        case .patchEquivalent: return "patch-equivalent"
        case .sameTree: return "no-diff"
        case .prMerged: return "pr-merged"
        }
    }

    public func explanation(base: String) -> String {
        switch self {
        case .merged: return "merged into \(base)"
        case .patchEquivalent: return "patch already on \(base) (squash-merged)"
        case .sameTree: return "no net change since the merge-base with \(base)"
        case .prMerged(let mergedInto):
            return "pull request for this branch was merged into \(mergedInto) on GitHub"
        }
    }
}

public struct CleanCandidate: Sendable {
    public let branch: String
    public let tip: String
    public let reason: CleanReason
}

public enum BranchCleaner {
    /// Non-protected local branches whose content is already represented on
    /// `base` (e.g. `origin/main`). Branches with unrelated history (no
    /// merge-base) are left untouched.
    public static func candidates(
        base: String,
        protectedBranches: Set<String>,
        protectedPrefixes: [String],
        mergedPullRequestHeads: [String: Set<GitHub.MergedPullRequestHead>]? = nil,
        defaultBranchName: String? = nil
    ) -> [CleanCandidate] {
        var result: [CleanCandidate] = []
        for branch in Git.localBranches() {
            if protectedBranches.contains(branch) { continue }
            if protectedPrefixes.contains(where: branch.hasPrefix) { continue }
            // Resolve through the fully-qualified ref everywhere: a bare short
            // name fed to revision-parsing plumbing is ambiguous (a tag of the
            // same name wins) and a name starting with `-` could be read as an
            // option.
            let branchRef = "refs/heads/\(branch)"
            if let reason = classify(branchRef: branchRef, base: base) {
                result.append(CleanCandidate(branch: branch, tip: Git.tipSHA(branchRef), reason: reason))
                continue
            }
            // Fallback for branches whose pull request merged somewhere other
            // than `base` (a topic branch, `develop`, a release branch) — or
            // via a merge strategy content comparison can miss, like
            // rebase-and-merge. Trusted only when the branch has no commits
            // beyond a commit GitHub actually merged under this name, so a
            // branch that kept committing after its PR merged is never
            // caught by name alone, and a branch with no merged PR at all is
            // never touched by this check. This does not require the merge
            // target to be `base`: any merged pull request counts.
            //
            // A reused branch name can have several qualifying merges (e.g.
            // merged into a topic branch once, into the default branch
            // later); sort deterministically and prefer one that landed on
            // the default branch, so the reported target is reproducible and
            // as informative as possible rather than whichever `Set`
            // iteration happened to surface first.
            let mergedHeads = (mergedPullRequestHeads?[branch] ?? [])
                .filter { Git.hasNoCommitsSince($0.commit, on: branchRef) }
                .sorted { $0.mergedInto < $1.mergedInto }
            let preferred = mergedHeads.first { $0.mergedInto == defaultBranchName }
            if let match = preferred ?? mergedHeads.first {
                result.append(
                    CleanCandidate(
                        branch: branch, tip: Git.tipSHA(branchRef),
                        reason: .prMerged(mergedInto: match.mergedInto)))
            }
        }
        return result
    }

    private static func classify(branchRef: String, base: String) -> CleanReason? {
        if Git.isAncestor(branchRef, of: base) {
            return .merged
        }
        guard let mergeBase = Git.mergeBase(branchRef, base) else {
            return nil  // unrelated history; never a candidate
        }
        if Git.hasNoDiff(from: mergeBase, to: branchRef) {
            return .sameTree
        }
        // Squash detection: a synthetic commit carrying the branch's whole diff
        // from the merge-base; if its patch already exists upstream, the branch
        // was squash-merged.
        guard let tree = try? Git.run(["rev-parse", "\(branchRef)^{tree}"])
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !tree.isEmpty,
            let synthetic = try? Git.commitTree(tree: tree, parent: mergeBase)
        else { return nil }
        return Git.patchExistsUpstream(base: base, commit: synthetic, limit: mergeBase)
            ? .patchEquivalent : nil
    }
}

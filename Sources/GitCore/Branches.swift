import Foundation

extension Git {
    /// The checked-out branch, or `nil` when HEAD is detached.
    public static func currentBranch() -> String? {
        guard let result = try? capture(["symbolic-ref", "--quiet", "--short", "HEAD"]),
            result.status == 0
        else { return nil }
        let name = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// Short name of the remote's default branch (e.g. `main`), resolved from
    /// `refs/remotes/origin/HEAD`. When that symbolic ref is missing — common in
    /// clones made without it — falls back to whichever of `main`/`master`
    /// exists as a remote-tracking branch.
    public static func defaultBranch(remote: String = "origin") -> String? {
        if let result = try? capture(["symbolic-ref", "--quiet", "refs/remotes/\(remote)/HEAD"]),
            result.status == 0
        {
            let ref = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let prefix = "refs/remotes/\(remote)/"
            if ref.hasPrefix(prefix) {
                return String(ref.dropFirst(prefix.count))
            }
        }
        for candidate in ["main", "master"] where remoteTrackingExists(remote: remote, branch: candidate) {
            return candidate
        }
        return nil
    }

    private static func remoteTrackingExists(remote: String, branch: String) -> Bool {
        // Verify the fully-qualified remote-tracking ref: a bare `origin/main`
        // could otherwise resolve to a local branch of that literal name.
        let ref = "refs/remotes/\(remote)/\(branch)^{commit}"
        guard let result = try? capture(["rev-parse", "--verify", "--quiet", ref])
        else { return false }
        return result.status == 0
    }

    /// Whether `ref` resolves to an actual commit (not a dangling symbolic ref).
    public static func commitExists(_ ref: String) -> Bool {
        guard let result = try? capture(["rev-parse", "--verify", "--quiet", "\(ref)^{commit}"])
        else { return false }
        return result.status == 0
    }

    /// All local branch names (e.g. `feature/x`). Uses `lstrip=2` rather than
    /// `:short` so the name is always the exact ref under `refs/heads/`; `:short`
    /// can render as `heads/x` to disambiguate from a same-named tag.
    public static func localBranches() -> [String] {
        guard let out = try? run(["for-each-ref", "--format=%(refname:lstrip=2)", "refs/heads/"])
        else { return [] }
        return out.split(whereSeparator: \.isNewline).map(String.init)
    }

    public static func fetchPrune(remote: String = "origin") throws {
        try run(["fetch", "--prune", remote])
    }

    /// Whether `ancestor` is an ancestor of `descendant` (a normal merge).
    public static func isAncestor(_ ancestor: String, of descendant: String) -> Bool {
        guard let result = try? capture(["merge-base", "--is-ancestor", ancestor, descendant])
        else { return false }
        return result.status == 0
    }

    /// The best common ancestor of two refs, or `nil` for unrelated histories.
    public static func mergeBase(_ a: String, _ b: String) -> String? {
        guard let result = try? capture(["merge-base", a, b]), result.status == 0 else { return nil }
        let sha = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return sha.isEmpty ? nil : sha
    }

    /// True when `from` and `to` point at identical trees (no net change).
    public static func hasNoDiff(from: String, to: String) -> Bool {
        guard let result = try? capture(["diff", "--quiet", from, to]) else { return false }
        return result.status == 0
    }

    /// Creates an in-memory commit holding `tree` on top of `parent` and returns
    /// its SHA. Touches neither the index nor the working tree. A synthetic
    /// identity is supplied so the probe succeeds even when the repo has no
    /// `user.name`/`user.email` configured (otherwise `commit-tree` exits 128).
    public static func commitTree(tree: String, parent: String) throws -> String {
        let identity = [
            "GIT_AUTHOR_NAME": "git-branch-clean",
            "GIT_AUTHOR_EMAIL": "git-branch-clean@localhost",
            "GIT_COMMITTER_NAME": "git-branch-clean",
            "GIT_COMMITTER_EMAIL": "git-branch-clean@localhost",
        ]
        let out = try run(
            ["commit-tree", tree, "-p", parent, "-m", "branch-clean-probe"],
            environment: identity)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether `commit`'s patch is already present on `base`, by patch-id
    /// comparison. `limit` bounds the range so only `commit` itself is
    /// considered: `git cherry` then prints a single line, `-` when an
    /// equivalent patch exists upstream and `+` when it does not.
    public static func patchExistsUpstream(base: String, commit: String, limit: String) -> Bool {
        guard let out = try? run(["cherry", base, commit, limit]) else { return false }
        // The limit pins the range to exactly the synthetic commit, so expect a
        // single line; treat anything else as "not equivalent" to stay safe.
        let lines = out.split(whereSeparator: \.isNewline)
        return lines.count == 1 && lines[0].hasPrefix("-")
    }

    /// Short SHA of a ref's tip, or empty when it cannot be resolved.
    public static func tipSHA(_ ref: String) -> String {
        (try? run(["rev-parse", "--short", ref]))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Whether `branchRef` has no commits beyond `commit` — `branchRef` is at
    /// or behind `commit`, with nothing added on top. Fails closed (`false`,
    /// i.e. "new work exists") when `commit` cannot be resolved, e.g. it was
    /// never fetched locally.
    public static func hasNoCommitsSince(_ commit: String, on branchRef: String) -> Bool {
        guard let out = try? run(["rev-list", "--count", "\(commit)..\(branchRef)"]) else {
            return false
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines) == "0"
    }

    /// Force-deletes a local branch. Returns the captured result rather than
    /// throwing so callers can report a per-branch failure (e.g. the branch is
    /// checked out in another worktree) and continue.
    public static func forceDeleteBranch(_ branch: String) -> Result {
        // `--` ends option parsing so a branch name beginning with `-` is never
        // mistaken for a flag.
        (try? capture(["branch", "-D", "--", branch]))
            ?? Result(status: 1, stdout: "", stderr: "could not run git branch -D \(branch)")
    }
}

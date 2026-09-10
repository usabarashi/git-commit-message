import Foundation

/// Thin wrapper over the `gh` CLI. Used only as a supplementary signal beyond
/// content-based git comparison: some merge strategies (notably GitHub's
/// "rebase and merge") replay commits with new SHAs, so the branch no longer
/// diffs cleanly or patch-matches against the base even though its pull
/// request was merged.
public enum GitHub {
    /// Runs `gh` and returns its captured streams plus exit status, never
    /// throwing — every caller here treats failure (missing binary, no auth,
    /// no GitHub remote) as "no signal available", not an error.
    private static func capture(_ arguments: [String]) -> Git.Result? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["gh"] + arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        guard (try? process.run()) != nil else { return nil }

        nonisolated(unsafe) var errData = Data()
        let errSemaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            errData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
            errSemaphore.signal()
        }
        let outData = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
        errSemaphore.wait()
        process.waitUntilExit()

        return Git.Result(
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self))
    }

    private struct PullRequest: Decodable {
        let headRefName: String
        let headRefOid: String
        let baseRefName: String
    }

    /// One merged pull request's head commit and the branch it was merged
    /// into. Kept together (rather than flattened to just a commit set) so
    /// callers can report *where* a branch actually landed — which may not be
    /// the repo's default branch at all.
    public struct MergedPullRequestHead: Hashable, Sendable {
        public let commit: String
        public let mergedInto: String
    }

    public struct MergedPullRequests: Sendable {
        /// Each merged pull request's head branch name mapped to the head(s)
        /// merged under that name. Callers should not treat membership alone
        /// as "safe to delete": they must also confirm the local branch has
        /// no commits beyond one of these, so a branch that kept committing
        /// after its PR merged is never mistaken for fully integrated.
        public let heads: [String: Set<MergedPullRequestHead>]
        /// True when the result hit `limit` and may be missing older merged
        /// pull requests.
        public let truncated: Bool
    }

    /// Every merged pull request in this repo, regardless of which branch it
    /// was merged into — a pull request merged into a topic branch, `develop`,
    /// or a release branch counts equally to one merged into the default
    /// branch. Use this only when "the branch was merged somewhere via GitHub"
    /// is itself the criterion for deletion; it does not imply the branch's
    /// content ever reached the default branch.
    ///
    /// Returns `nil` when `gh` is missing, unauthenticated, or this repo has
    /// no GitHub remote — callers must treat `nil` as "no additional signal",
    /// never as "nothing was merged".
    public static func mergedPullRequests(limit: Int = 500) -> MergedPullRequests? {
        guard
            let result = capture([
                "pr", "list", "--state", "merged",
                "--limit", String(limit), "--json", "headRefName,headRefOid,baseRefName",
            ]),
            result.status == 0,
            let data = result.stdout.data(using: .utf8),
            let pullRequests = try? JSONDecoder().decode([PullRequest].self, from: data)
        else { return nil }

        var map: [String: Set<MergedPullRequestHead>] = [:]
        for pullRequest in pullRequests {
            map[pullRequest.headRefName, default: []].insert(
                MergedPullRequestHead(commit: pullRequest.headRefOid, mergedInto: pullRequest.baseRefName))
        }
        return MergedPullRequests(heads: map, truncated: pullRequests.count >= limit)
    }
}

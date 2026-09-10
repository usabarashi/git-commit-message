import Darwin  // isatty
import Foundation
import GitCore

let helpText = """
git-branch-clean — delete local branches already integrated into the default
branch, including squash-merged ones, plus branches merged anywhere via a
GitHub pull request.

USAGE:
    git branch-clean [--dry-run] [--no-fetch] [--no-gh] [--yes] [--help]

    Compares every local branch against the remote default branch
    (origin/HEAD) and lists those whose work is already represented there:

      - merged           tip is an ancestor of the default branch
      - patch-equivalent the branch diff already exists (squash-merged)
      - no-diff          the branch has no net change since its merge-base
      - pr-merged        a GitHub pull request under this branch's name was
                         merged (per `gh pr list`, into ANY branch — not
                         necessarily the default branch) and the branch
                         has no commits beyond that merged commit

    Protected branches are never deleted: the current branch, the default
    branch, and main / master / develop / release/*.

    The first three reasons are content-based: a branch is a candidate when
    its final content is already on the default branch, however it got
    there. `pr-merged` is different and weaker: it fires whenever a GitHub
    pull request under the branch's name was merged into any branch at
    all — a topic branch, `develop`, a release branch — even if that content
    has not yet reached the default branch. It is trusted only when the
    local branch has no commits beyond the exact commit GitHub merged, so a
    branch that kept committing after its pull request merged is never
    caught by name alone, and a branch with no merged pull request at all is
    never touched by this check. Only the 500 most recently merged pull
    requests are considered; an older one may go unmatched. Pass --no-gh to
    disable this check and keep detection strictly content-based. Deletion
    uses `git branch -D`; recover any branch with `git branch <name> <sha>`.

OPTIONS:
    --dry-run    List candidates and exit without deleting.
    --no-fetch   Skip the `git fetch --prune` that refreshes origin first.
    --no-gh      Skip the `gh pr list` pull-request check.
    --yes, -y    Delete without the confirmation prompt (for scripts).
    -h, --help   Show this help.
"""

func fail(_ message: String) -> Never {
    try? FileHandle.standardError.write(contentsOf: Data("error: \(message)\n".utf8))
    exit(1)
}

func note(_ message: String) {
    try? FileHandle.standardError.write(contentsOf: Data("\(message)\n".utf8))
}

// MARK: - Argument parsing

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.contains("--help") || arguments.contains("-h") {
    print(helpText)
    exit(0)
}
let isDryRun = arguments.contains("--dry-run")
let skipFetch = arguments.contains("--no-fetch")
let skipGitHub = arguments.contains("--no-gh")
let assumeYes = arguments.contains("--yes") || arguments.contains("-y")

let recognizedOptions: Set<String> = ["--dry-run", "--no-fetch", "--no-gh", "--yes", "-y"]
for argument in arguments where !recognizedOptions.contains(argument) {
    fail("unknown option '\(argument)'. See --help")
}

// MARK: - Refresh and resolve the base

if !skipFetch {
    note("fetching origin…")
    do {
        try Git.fetchPrune()
    } catch {
        // Fail closed: a stale tracking ref is not always merely behind. If the
        // remote default was force-pushed or rewound, judging against the old
        // ref can invent false candidates and delete unmerged work. Require an
        // explicit --no-fetch to accept current refs.
        fail("fetch failed (\(error)); re-run with --no-fetch to judge against current local refs")
    }
}

guard let defaultBranch = Git.defaultBranch() else {
    fail(
        "could not determine the default branch. Set it with `git remote set-head origin --auto`")
}
// Compare against the fully-qualified remote-tracking ref so a local branch
// that happens to be named like `origin/<default>` cannot shadow it; show the
// short form to the user.
let base = "refs/remotes/origin/\(defaultBranch)"
let baseLabel = "origin/\(defaultBranch)"

// Guard against a dangling origin/HEAD or a remote with no commits: without
// this every classification would fail closed and we'd misreport "nothing to
// delete" instead of the real setup problem.
guard Git.commitExists(base) else {
    fail("\(baseLabel) does not resolve to a commit (origin/HEAD may be dangling). Run `git fetch` or `git remote set-head origin --auto`")
}

// MARK: - Collect candidates

var protectedBranches: Set<String> = ["main", "master", "develop", defaultBranch]
if let current = Git.currentBranch() {
    protectedBranches.insert(current)
}

var mergedPullRequestHeads: [String: Set<GitHub.MergedPullRequestHead>]? = nil
if !skipGitHub {
    if let mergedPullRequests = GitHub.mergedPullRequests() {
        mergedPullRequestHeads = mergedPullRequests.heads
        if mergedPullRequests.truncated {
            note("gh pr list hit its query limit; an older merged pull request may go unmatched")
        }
    } else {
        note(
            "gh unavailable, unauthenticated, or no GitHub remote; skipping the pull-request check "
                + "(pass --no-gh to silence this)")
    }
}

let candidates = BranchCleaner.candidates(
    base: base,
    protectedBranches: protectedBranches,
    protectedPrefixes: ["release/"],
    mergedPullRequestHeads: mergedPullRequestHeads,
    defaultBranchName: defaultBranch)

if candidates.isEmpty {
    print("Nothing to delete — no local branch is fully integrated into \(baseLabel), and none matched a merged GitHub pull request.")
    exit(0)
}

// MARK: - Present

print("Branches ready to delete (integrated into \(baseLabel), or merged via a GitHub pull request):\n")
let width = candidates.map(\.branch.count).max() ?? 0
for candidate in candidates {
    let name = candidate.branch.padding(toLength: width, withPad: " ", startingAt: 0)
    print("  \(name)  \(candidate.tip)  \(candidate.reason.explanation(base: baseLabel))")
}
print("\nRecover any branch with: git branch <name> <sha>")

if isDryRun {
    print("\n--dry-run: nothing deleted.")
    exit(0)
}

// MARK: - Confirm

if !assumeYes {
    guard isatty(FileHandle.standardInput.fileDescriptor) != 0 else {
        fail("stdin is not a terminal; re-run with --yes to delete non-interactively")
    }
    print("\nDelete these \(candidates.count) local branch(es) with `git branch -D`? [y/N] ", terminator: "")
    let answer = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    guard answer == "y" || answer == "yes" else {
        print("Aborted; nothing deleted.")
        exit(0)
    }
}

// MARK: - Delete

var deleted = 0
var failed = 0
for candidate in candidates {
    let result = Git.forceDeleteBranch(candidate.branch)
    if result.status == 0 {
        print("deleted \(candidate.branch) (\(candidate.tip))")
        deleted += 1
    } else {
        let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        note("skipped \(candidate.branch): \(detail.isEmpty ? "git branch -D failed" : detail)")
        failed += 1
    }
}

if failed > 0 {
    fail("deleted \(deleted) branch(es); \(failed) could not be deleted")
}
print("deleted \(deleted) branch(es).")

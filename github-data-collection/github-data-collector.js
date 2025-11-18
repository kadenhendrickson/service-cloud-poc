import { DXDataCloudClient } from "./dxdc-api.js";
import { Octokit } from "octokit";
import fs from "fs";
import yargs from "yargs/yargs";
import { hideBin } from "yargs/helpers";

// The DX_API_TOKEN can be obtained from DX in the "Settings > Data Cloud API" section.
const dx = new DXDataCloudClient({
  token: process.env.DX_API_KEY,
  url: process.env.DX_URL
});

// The GITHUB_TOKEN needs to be a Personal Access Token, created by an owner of the GitHub organization,
// with access to all of the target repositories and the following permissions:
//
// - Metadata: Read
// - Contents: Read
// - Administration: Read
if (!process.env.GITHUB_TOKEN) {
  throw new Error("GITHUB_TOKEN environment variable is not set. Please set it before running this script.");
}
const github = new Octokit({ auth: process.env.GITHUB_TOKEN });

const main = async () => {
  const argv = yargs(hideBin(process.argv))
    .scriptName("github-data-collector")
    .usage("$0 [options]")
    .option("org", {
      type: "string",
      describe: "GitHub organization to scan",
      required: true,
    })
    .option("output", {
      type: "string",
      choices: ["dx", "csv"],
      describe: "Output mode - select 'dx' to write to DX custom data, 'csv' to write to a CSV file",
      default: "csv",
    })
    .option("pageSize", {
      type: "number",
      describe: "Max results per GitHub API page",
      default: 1000,
    })
    .option("csv", {
      type: "string",
      describe: "CSV output path when --output=csv",
      default: "github_data.csv",
    })
    .help()
    .strict()
    .parse();

  const outputMode = argv.output;
  const org = argv.org;
  const pageSize = argv.pageSize;
  const csvPath = argv.csv;

  // Get all repos for the organization
  const repos = await safeCall(
    () => github.rest.search.repos({ q: `org:${org}`, per_page: pageSize }),
    { context: `search.repos(org:${org})` }
  );
  const repoItems = repos?.data?.items ?? [];
  console.log("Found", repoItems.length, "repos in organization:", org);

  // Collect data for each repo
  const records = [];
  for (const repo of repoItems) {
    console.log(`\nProcessing repo: ${repo.name}`);

    // Get conventional README file
    const readmeData = await getFileLastCommit(
      github,
      repo.owner.login,
      repo.name,
      "README.md"
    );
    const readmeRootExists = readmeData.timestamp !== null;
    const readmeRootLastCommitTimestamp = readmeData.timestamp ?? null;
    
    // Try to get CODEOWNERS from .github/CODEOWNERS, then fall back to root CODEOWNERS
    const codeownersPaths = [".github/CODEOWNERS", "CODEOWNERS"];
    let codeownersExists = false;
    let codeownersLastCommitTimestamp = null;

    for (const path of codeownersPaths) {
      const data = await getFileLastCommit(
        github,
        repo.owner.login,
        repo.name,
        path
      );
      if (data.timestamp !== null) {
        codeownersExists = true;
        codeownersLastCommitTimestamp = data.timestamp;
        break;
      }
    }

    // Branch protection rules
    let branchProtectionData = null;
    try {
      const branchProtection = await github.rest.repos.getBranchProtection({
        owner: repo.owner.login,
        repo: repo.name,
        branch: repo.default_branch,
      });
      branchProtectionData = branchProtection.data ?? null;
      console.log('Branch protection data found');
    } catch (error) {
      if (error.status === 404) {
        console.log(`No branch protection on ${repo.full_name}@${repo.default_branch}`);
        branchProtectionData = null;
      } else {
        console.warn(`Failed to fetch branch protection for ${repo.full_name}:`, {
          status: error?.status,
          message: error?.message,
        });
      }
    }

    // Get repository languages
    const languagesData = await github.rest.repos.listLanguages({
      owner: repo.owner.login,
      repo: repo.name,
    });
    const languages = languagesData.data ?? null;

    const recObj = {
      repo_full_name: repo.full_name,
      repo_id: repo.id,
      readme_root_exists: readmeRootExists,
      readme_root_last_commit_timestamp: readmeRootLastCommitTimestamp,
      codeowners_exists: codeownersExists,
      codeowners_file_last_commit_timestamp: codeownersLastCommitTimestamp,
      branch_protection_enforce_admins: branchProtectionData?.enforce_admins?.enabled ?? null,
      branch_protection_linear_history: branchProtectionData?.required_linear_history?.enabled ?? null,
      branch_protection_allow_force_pushes: branchProtectionData?.allow_force_pushes?.enabled ?? null,
      branch_protection_allow_deletions: branchProtectionData?.allow_deletions?.enabled ?? null,
      branch_protection_block_creations: branchProtectionData?.block_creations?.enabled ?? null,
      branch_protection_required_conversation_resolution: branchProtectionData?.required_conversation_resolution?.enabled ?? null,
      branch_protection_lock_branch: branchProtectionData?.lock_branch?.enabled ?? null,
      branch_protection_allow_fork_syncing: branchProtectionData?.allow_fork_syncing?.enabled ?? null,
      branch_protection_required_pr_reviews: branchProtectionData?.required_pull_request_reviews ?? null, // JSON object
      branch_protection_required_status_checks: branchProtectionData?.required_status_checks ?? null, // JSON object
      language: languages ?? null
    };

    if (outputMode === "csv") {
      records.push(recObj);
    } else {
      try {
        const entries = buildEntries(recObj);
        await dx.customData.setAll(entries);
        console.log(`DX custom_data.setAll successful for ${repo.name}`);
      } catch (e) {
        console.warn(`DX custom_data.setAll failed for ${repo.name}:`, e.message || e);
      }
    }
  }

  if (outputMode === "csv") {
    try {
      writeCsv(records, csvPath);
      console.log(`Wrote CSV: ${csvPath}`);
    } catch (e) {
      console.warn("Failed to write CSV:", e.message || e);
    }
  }
};

const getFileLastCommit = async (github, owner, repo, path) => {
  try {
    await github.rest.repos.getContent({ owner, repo, path });
    const lastCommit = await github.rest.repos.listCommits({
      owner,
      repo,
      path,
      per_page: 1,
    });
    console.log(`${path} file found`)
    return { timestamp: lastCommit.data[0].commit.author.date };
  } catch (error) {
    if (error.status === 404) {
      console.log(`No ${path} file found`);
      return { timestamp: null };
    }
    throw error;
  }
};

const csvEscape = (value) => {
  if (value === null || value === undefined) return "";
  const str =
    typeof value === "string"
      ? value
      : typeof value === "object"
      ? JSON.stringify(value)
      : String(value);
  const needsQuoting = /[",\n\r]/.test(str);
  const escaped = str.replace(/"/g, '""');
  return needsQuoting ? `"${escaped}"` : escaped;
};

const writeCsv = (records, filePath) => {
  const columns = [
    "repo_full_name",
    "repo_id",
    "readme_root_exists",
    "readme_root_last_commit_timestamp",
    "codeowners_exists",
    "codeowners_file_last_commit_timestamp",
    "branch_protection_enforce_admins",
    "branch_protection_linear_history",
    "branch_protection_allow_force_pushes",
    "branch_protection_allow_deletions",
    "branch_protection_block_creations",
    "branch_protection_required_conversation_resolution",
    "branch_protection_lock_branch",
    "branch_protection_allow_fork_syncing",
    "branch_protection_required_pr_reviews",
    "branch_protection_required_status_checks",
    "language",
  ];
  const header = columns.join(",");
  const lines = records.map((rec) =>
    columns.map((col) => csvEscape(rec[col])).join(",")
  );
  const csv = [header, ...lines].join("\n");
  fs.writeFileSync(filePath, csv, "utf-8");
};

const safeCall = async (fn, { context } = {}) => {
  try {
    return await fn();
  } catch (e) {
    const status = e?.status;
    const msg = e?.message || e;
    console.warn(`API error${context ? ` @ ${context}` : ""}:`, status || "", msg);
    return null;
  }
};

function buildEntries(rec) {
    return [
      {
        reference: rec.repo_full_name,
        key: "readme:exists",
        value: { exists: rec.readme_root_exists },
      },
      {
        reference: rec.repo_full_name,
        key: "readme:last_commit",
        value: { timestamp: rec.readme_root_last_commit_timestamp },
      },
      {
        reference: rec.repo_full_name,
        key: "codeowners:exists",
        value: { exists: rec.codeowners_exists },
      },
      {
        reference: rec.repo_full_name,
        key: "codeowners:last_commit",
        value: { timestamp: rec.codeowners_file_last_commit_timestamp },
      },
      {
        reference: rec.repo_full_name,
        key: "branch_protection:enforce_admins",
        value: { enforce_admins: rec.branch_protection_enforce_admins },
      },
      {
        reference: rec.repo_full_name,
        key: "branch_protection:linear_history",
        value: { linear_history: rec.branch_protection_linear_history },
      },
      {
        reference: rec.repo_full_name,
        key: "branch_protection:allow_force_pushes",
        value: { allow_force_pushes: rec.branch_protection_allow_force_pushes },
      },
      {
        reference: rec.repo_full_name,
        key: "branch_protection:allow_deletions",
        value: { allow_deletions: rec.branch_protection_allow_deletions },
      },
      {
        reference: rec.repo_full_name,
        key: "branch_protection:block_creations",
        value: { block_creations: rec.branch_protection_block_creations },
      },
      {
        reference: rec.repo_full_name,
        key: "branch_protection:required_conversation_resolution",
        value: { required_conversation_resolution: rec.branch_protection_required_conversation_resolution },
      },
      {
        reference: rec.repo_full_name,
        key: "branch_protection:lock_branch",
        value: { lock_branch: rec.branch_protection_lock_branch },
      },
      {
        reference: rec.repo_full_name,
        key: "branch_protection:allow_fork_syncing",
        value: { allow_fork_syncing: rec.branch_protection_allow_fork_syncing },
      },
      {
        reference: rec.repo_full_name,
        key: "branch_protection:required_pr_reviews",
        value: { required_pr_reviews: rec.branch_protection_required_pr_reviews },
      },
      {
        reference: rec.repo_full_name,
        key: "branch_protection:required_status_checks",
        value: { required_status_checks: rec.branch_protection_required_status_checks },
      },
      {
        reference: rec.repo_full_name,
        key: "language",
        value: { most_used_language: rec.most_used_language },
      },
    ];
  }

main();
